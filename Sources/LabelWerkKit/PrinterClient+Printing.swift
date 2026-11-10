import Foundation
import LabelWerkCore
import LabelWerkImaging

extension PrinterClient {

    // MARK: - Bilder drucken

    /// Druckt Graustufenbilder (je Bild ein Etikett) mit den Treibereinstellungen.
    ///
    /// Die Bilder werden mit `JobEncoder` gerastert und kodiert – byte-gleich zum CUPS-Filter
    /// (ARCHITECTURE.md §8). Ist das Modell aus ``identify()`` bekannt, werden zu breite Bilder
    /// auf die Kopfbreite abgeschnitten. Die Bilder sollten bereits auf Etikettengröße gebracht
    /// sein (siehe ``ImageLayout``).
    ///
    /// - Throws: ``PrinterClientError/emptyJob`` ohne Bilder, ``PrinterClientError/invalidArgument(_:)``
    ///   bei Bildern ohne Fläche, ``PrinterClientError/encodingFailed(_:)`` bei Kodierungsfehlern.
    public func printImages(_ images: [GrayImage], settings: PrintSettings, resolution: Resolution,
                            stock: LabelStock?, copies: Int = 1) async throws {
        try await guarded {
            let data = try await self.encodeImages(images, settings: settings, resolution: resolution,
                                                   stock: stock, copies: copies)
            try await self.transmit(data)
        }
    }

    func encodeImages(_ images: [GrayImage], settings: PrintSettings, resolution: Resolution,
                      stock: LabelStock?, copies: Int) async throws -> Data {
        guard !images.isEmpty else { throw PrinterClientError.emptyJob }
        guard images.allSatisfy({ $0.width > 0 && $0.height > 0 }) else {
            throw PrinterClientError.invalidArgument("Mindestens ein Bild hat keine Fläche (Breite oder Höhe 0).")
        }
        guard copies >= 1 else {
            throw PrinterClientError.invalidArgument("Die Anzahl der Kopien muss mindestens 1 sein.")
        }
        let maxWidth = lastIdentity?.matchedModel?.printWidthDots(resolution)
        let encoder = JobEncoder(language: language, resolution: resolution, settings: settings,
                                 stock: stock, maxPrintWidthDots: maxWidth)
        // Rastern und Komprimieren außerhalb des Actors, damit andere Aufrufer (z. B. die
        // Statusanzeige) nicht auf die Rechenarbeit warten müssen.
        return try await Task.detached(priority: .userInitiated) {
            try encoder.encode(images: images, copies: copies, collate: true)
        }.value
    }

    // MARK: - Einstellungen übertragen

    /// Überträgt Druckereinstellungen als Gerätebefehle.
    ///
    /// * ZPL: `~SD` (Schwärzung), `~TA` (Abreißposition), `~JS` (Rückzugsfolge), dann ein Format
    ///   mit `^MT`, `^MN`, `^MM`, `^PR`, `^LT`, `^LS` und – bei `permanently` – `^JUS`. Die
    ///   Steuerbefehle stehen vor dem Format, damit `^JUS` auch sie dauerhaft speichert.
    ///   Der Rückzug wird bewusst mit dem Steuerbefehl `~JS` gesetzt: `^JS` ist in ZPL II die
    ///   Sensorwahl (`A` automatisch, `R` reflektiv, `T` transmissiv) – `^JSA` würde dort den
    ///   Mediensensor umstellen, `^JSB`/`^JSN`/`^JSO` wären ungültig, und der Rückzug bliebe
    ///   unverändert. (`ZPL.backfeed(_:)` aus LabelWerkCore erzeugt `^JS` und wird hier deshalb
    ///   nicht verwendet.)
    /// * EPL: `S` (Geschwindigkeit), `D` (Schwärzung), `O` (Thermodirekt/Schneider/Spender) und
    ///   `R` (Bezugspunkt aus Versatz links/oben, nur positive Werte). EPL speichert Einstellungen
    ///   selbständig; die Medienerkennung (`Q`) braucht die Etikettenlänge und wird über den
    ///   Druckauftrag gesetzt.
    /// * CPCL: SGD-Variablen (`print.tone`, `media.speed`, `ezpl.print_method`,
    ///   `ezpl.media_type`, `media.printmode`, `ezpl.tear_off`, `zpl.left_position`,
    ///   `zpl.label_top`); Link-OS speichert sie selbständig.
    ///
    /// Nur gesetzte (nicht-`nil`) Werte werden übertragen; alle Befehle setzen absolute Werte,
    /// die Übertragung ist daher idempotent. Ohne gesetzte Werte und ohne `permanently` wird
    /// nichts gesendet.
    public func applySettings(_ settings: PrintSettings, permanently: Bool) async throws {
        try await guarded {
            let payload = Self.settingsPayload(settings, permanently: permanently, language: self.language)
            try await self.transmit(payload)
        }
    }

    /// `~JS{A|B|N|O}` – Rückzugsfolge („Change Backfeed Sequence“, ZPL-II-Steuerbefehl).
    static func backfeedSequence(_ mode: BackfeedMode) -> ZPLCommand {
        ZPLCommand(.tilde, "JS", [mode.zplCode])
    }

    /// Befehle für ``applySettings(_:permanently:)`` (ohne zu senden).
    public static func settingsPayload(_ settings: PrintSettings, permanently: Bool,
                                       language: PrinterLanguage) -> Data {
        let s = settings.clamped()
        switch language {
        case .zpl:
            var lines: [String] = []
            if let darkness = s.darkness { lines.append(ZPL.setDarkness(darkness).description) }
            if let tearOff = s.tearOffAdjust { lines.append(ZPL.tearOffAdjust(tearOff).description) }
            if let backfeed = s.backfeed { lines.append(backfeedSequence(backfeed).description) }
            var format: [ZPLCommand] = []
            if let mediaType = s.mediaType { format.append(ZPL.mediaType(mediaType)) }
            if let tracking = s.tracking { format.append(ZPL.mediaTracking(tracking)) }
            if let mode = s.printMode { format.append(ZPL.printMode(mode)) }
            if let speed = s.speed { format.append(ZPL.printRate(speed)) }
            if let top = s.labelTop { format.append(ZPL.labelTop(top)) }
            if let left = s.labelLeft { format.append(ZPL.labelShift(left)) }
            if permanently { format.append(ZPL.saveSettings()) }
            if !format.isEmpty {
                lines.append(ZPL.startFormat().description)
                lines += format.map(\.description)
                lines.append(ZPL.endFormat().description)
            }
            return Data(lines.map { $0 + "\n" }.joined().utf8)

        case .epl:
            var lines: [String] = []
            if let speed = s.speed { lines.append(EPL.speed(speed)) }
            if let darkness = s.darkness { lines.append(EPL.density((darkness + 1) / 2)) }
            if s.mediaType != nil || s.printMode != nil {
                // Gleiche Regel wie im Druckauftrag (ARCHITECTURE.md §8).
                var options: [EPL.HardwareOption] = []
                if s.mediaType == .directThermal { options.append(.directThermal) }
                if s.printMode == .cutter { options.append(.cutter) } else if s.printMode == .peelOff { options.append(.peel) }
                lines.append(EPL.options(options))
            }
            if s.labelLeft != nil || s.labelTop != nil {
                lines.append(EPL.referencePoint(x: max(0, s.labelLeft ?? 0), y: max(0, s.labelTop ?? 0)))
            }
            guard !lines.isEmpty else { return Data() }
            // Führender Zeilenvorschub schließt eine evtl. offene Befehlszeile ab.
            return EPL.encode(EPL.lineEnding + EPL.render(lines))

        case .cpcl:
            var commands = ""
            for (name, value) in SGDValueMapping.variables(for: s) {
                commands += SGD.setvar(name, value)
            }
            return Data(commands.utf8)
        }
    }
}

// MARK: - Zuordnung Einstellungen ↔ SGD-Werte

/// Abbildung der Druckeinstellungen auf Link-OS-SGD-Werte (gemeinsam für ``PrinterClient`` und
/// ``VirtualPrinter``).
enum SGDValueMapping {
    /// `media.printmode`.
    static func printMode(_ mode: PrintMode) -> String {
        switch mode {
        case .tearOff: return "tear off"
        case .peelOff: return "peel off"
        case .cutter: return "cutter"
        case .delayedCut: return "delayed cut"
        case .rewind: return "rewind"
        case .applicator: return "applicator"
        case .kiosk: return "kiosk"
        }
    }

    static func printMode(sgd value: String) -> PrintMode? {
        let v = value.lowercased()
        if v.contains("delayed") { return .delayedCut }
        if v.contains("peel") { return .peelOff }
        if v.contains("cut") { return .cutter }
        if v.contains("rewind") { return .rewind }
        if v.contains("applicator") { return .applicator }
        if v.contains("kiosk") { return .kiosk }
        if v.contains("tear") { return .tearOff }
        return nil
    }

    /// `ezpl.print_method`.
    static func printMethod(_ type: MediaType) -> String {
        type == .thermalTransfer ? "thermal trans" : "direct thermal"
    }

    static func mediaType(sgd value: String) -> MediaType? {
        let v = value.lowercased()
        if v.contains("trans") { return .thermalTransfer }
        if v.contains("direct") { return .directThermal }
        return nil
    }

    /// `ezpl.media_type`; `nil` für die automatische Erkennung (kein eigener Wert).
    static func mediaTracking(_ tracking: MediaTracking) -> String? {
        switch tracking {
        case .gap: return "gap/notch"
        case .blackMark: return "mark"
        case .continuous: return "continuous"
        case .autoDetect: return nil
        }
    }

    static func mediaTracking(sgd value: String) -> MediaTracking? {
        let v = value.lowercased()
        if v.contains("continuous") { return .continuous }
        if v.contains("mark") { return .blackMark }
        if v.contains("gap") || v.contains("notch") || v.contains("web") { return .gap }
        return nil
    }

    /// SGD-Zuweisungen für die gesetzten Werte (Reihenfolge stabil).
    static func variables(for settings: PrintSettings) -> [(name: String, value: String)] {
        let s = settings.clamped()
        var result: [(name: String, value: String)] = []
        if let darkness = s.darkness { result.append((SGD.Variable.tone, String(darkness))) }
        if let speed = s.speed { result.append((SGD.Variable.speed, String(speed))) }
        if let mediaType = s.mediaType { result.append((SGD.Variable.printMethod, printMethod(mediaType))) }
        if let tracking = s.tracking, let value = mediaTracking(tracking) { result.append((SGD.Variable.mediaType, value)) }
        if let mode = s.printMode { result.append((SGD.Variable.printMode, printMode(mode))) }
        if let tearOff = s.tearOffAdjust { result.append((SGD.Variable.tearOff, String(tearOff))) }
        if let left = s.labelLeft { result.append((SGD.Variable.leftPosition, String(left))) }
        if let top = s.labelTop { result.append(("zpl.label_top", String(top))) }
        return result
    }
}

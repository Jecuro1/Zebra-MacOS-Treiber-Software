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
    ///
    /// „Aufträge vor dem Drucken abbrechen“ (`cancelJobsBeforePrint`): Der Auftrag wird nach der
    /// `~JA`-Zeile geteilt; dazwischen wartet der Client `cancelDelayMs` Millisekunden – wie der
    /// CUPS-Filter –, damit der Drucker den Abbruch ausführt, bevor die neuen Etiketten ankommen.
    public func printImages(_ images: [GrayImage], settings: PrintSettings, resolution: Resolution,
                            stock: LabelStock?, copies: Int = 1) async throws {
        try await guarded {
            let job = try await self.encodeImageJob(images, settings: settings, resolution: resolution,
                                                    stock: stock, copies: copies)
            try await self.transmitJob(job.data, cancelPrefixLength: job.cancelPrefixLength,
                                       delayMilliseconds: settings.clamped().cancelDelayMs)
        }
    }

    /// Sendet einen bereits kodierten Auftrag (z. B. aus ``JobEncoder``) – mit
    /// „Aufträge vor dem Drucken abbrechen“ in zwei Teilen: zuerst die ersten `cancelPrefixLength`
    /// Bytes (die `~JA`-Zeile, siehe `JobEncoder.cancelPrefixLength()`), dann nach
    /// `delayMilliseconds` Millisekunden der Rest – wie der CUPS-Filter. Ohne gültige Teilungsstelle
    /// (`nil`, ≤ 0 oder größer als die Daten) wird der Auftrag in einem Stück gesendet.
    public func sendJob(_ data: Data, cancelPrefixLength: Int?, delayMilliseconds: Int) async throws {
        try await guarded {
            try await self.transmitJob(data, cancelPrefixLength: cancelPrefixLength,
                                       delayMilliseconds: delayMilliseconds)
        }
    }

    /// Länge der `~JA`-Zeile am Anfang eines gespeicherten Auftrags (`~JA\n` bzw. mit eigenem
    /// Steuerzeichen `<c>JA\n` aus ``JobEncoder``), sonst `nil` – damit „Erneut drucken“ wie der
    /// ursprüngliche Druck nach dem Abbrechen warten kann.
    public static func cancelPrefixLength(of data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4, ControlCharacters.validRange.contains(bytes[0]),
              bytes[1] == 0x4A, bytes[2] == 0x41, bytes[3] == 0x0A else { return nil }   // "JA\n"
        return 4
    }

    /// Sendet einen kodierten Auftrag; mit `cancelPrefixLength` in zwei Teilen mit Wartezeit.
    func transmitJob(_ data: Data, cancelPrefixLength: Int?, delayMilliseconds: Int) async throws {
        guard let split = cancelPrefixLength, split > 0, split <= data.count else {
            try await transmit(data)
            return
        }
        try await transmit(Data(data.prefix(split)))
        if delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        try await transmit(Data(data.dropFirst(split)))
    }

    func encodeImages(_ images: [GrayImage], settings: PrintSettings, resolution: Resolution,
                      stock: LabelStock?, copies: Int) async throws -> Data {
        try await encodeImageJob(images, settings: settings, resolution: resolution, stock: stock, copies: copies).data
    }

    func encodeImageJob(_ images: [GrayImage], settings: PrintSettings, resolution: Resolution,
                        stock: LabelStock?, copies: Int) async throws -> (data: Data, cancelPrefixLength: Int?) {
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
        let data = try await Task.detached(priority: .userInitiated) {
            try encoder.encode(images: images, copies: copies, collate: true)
        }.value
        return (data, encoder.cancelPrefixLength())
    }

    // MARK: - Echtzeituhr

    /// Stellt die Echtzeituhr des Druckers („Echtzeituhr (RTC) synchronisieren“).
    ///
    /// * ZPL: `^XA^ST{MM},{DD},{YYYY},{HH},{mm},{SS},M^XZ` (Ortszeit in `timeZone`, 24 Stunden).
    /// * EPL/CPCL: SGD `rtc.date` (`MM-DD-YYYY`) und `rtc.time` (`HH:MM:SS`).
    public func syncClock(now: Date = Date(), timeZone: TimeZone = .current) async throws {
        try await guarded {
            try await self.transmit(Self.clockPayload(now: now, timeZone: timeZone, language: self.language))
        }
    }

    /// Befehle für ``syncClock(now:timeZone:)`` (ohne zu senden).
    public static func clockPayload(now: Date, timeZone: TimeZone, language: PrinterLanguage) -> Data {
        switch language {
        case .zpl:
            return Data((ZPL.realTimeClockFormat(now, timeZone: timeZone) + "\n").utf8)
        case .epl, .cpcl:
            let c = ZPL.clockComponents(now, timeZone: timeZone)
            func pad(_ value: Int, _ width: Int) -> String {
                let digits = String(value)
                return String(repeating: "0", count: max(0, width - digits.count)) + digits
            }
            let date = "\(pad(c.month, 2))-\(pad(c.day, 2))-\(pad(c.year, 4))"
            let time = "\(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2))"
            return Data((SGD.setvar(SGD.Variable.rtcDate, date) + SGD.setvar(SGD.Variable.rtcTime, time)).utf8)
        }
    }

    // MARK: - Einstellungen lesen

    /// Liest die Druckeinstellungen des Druckers per SGD („Alle Einstellungen des Druckers
    /// verwenden“) und trägt sie in `base` ein.
    ///
    /// Gelesen werden `print.tone` (Schwärzung), `media.speed` (Geschwindigkeit),
    /// `ezpl.media_type` bzw. ersatzweise `media.type`/`media.sense_mode` (Medienerkennung),
    /// `ezpl.print_method` (Druckverfahren), `media.printmode` (Druckmodus inkl. Linerless),
    /// `zpl.label_top`, `zpl.left_position`, `ezpl.tear_off`, `ezpl.power_up_action`,
    /// `ezpl.head_close_action` und `zpl.caret`/`zpl.control_character`/`zpl.delimiter`
    /// (Steuerzeichen: `nil` bei `^ ~ ,`, sonst die Zeichen des Druckers). Fehlende oder
    /// unverständliche Variablen lassen den Wert aus `base` unverändert.
    ///
    /// - Throws: ``PrinterClientError/notBidirectional(_:)`` ohne Rückkanal,
    ///   ``PrinterClientError/noResponse(_:)``, wenn der Drucker keine einzige Variable liefert.
    public func readPrintSettings(into base: PrintSettings = PrintSettings()) async throws -> PrintSettings {
        try await guarded {
            guard self.supportsBidirectional else {
                throw PrinterClientError.notBidirectional("Druckeinstellungen lesen")
            }
            let values = try await self.fetchVariables(SGD.printSettingsVariables)
            guard !values.isEmpty else { throw PrinterClientError.noResponse("Druckeinstellungen lesen") }
            return SGDValueMapping.settings(from: values, base: base)
        }
    }

    // MARK: - Einstellungen übertragen

    /// Überträgt Druckereinstellungen als Gerätebefehle.
    ///
    /// * ZPL: `~SD` (Schwärzung), `~TA` (Abreißposition), `~JS` (Rückzugsfolge), bei
    ///   Linerless-Modi `! U1 setvar "media.printmode" "…"`, dann ein Format mit `^MT`, `^MN`
    ///   (bei schwarzer Markierung mit Versatz `^MNM,{offset}`), `^MM` (nur klassische Modi),
    ///   `^PR`, `^LT`, `^LS`, `^MF` (nur wenn Einschalt- **und** Kopfschließ-Aktion gesetzt sind)
    ///   und – bei `permanently` – `^JUS`. Die Steuerbefehle stehen vor dem Format, damit `^JUS`
    ///   auch sie dauerhaft speichert. Sind „interne“ Steuerzeichen eingestellt
    ///   (`controlCharacters`), werden alle ZPL-Befehle mit diesen Zeichen erzeugt.
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
    ///   `zpl.label_top`, `ezpl.power_up_action`, `ezpl.head_close_action`); Link-OS speichert
    ///   sie selbständig.
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
            let characters = s.effectiveControlCharacters
            var text = ""
            if let darkness = s.darkness { text += ZPL.setDarkness(darkness).rendered(with: characters) + "\n" }
            if let tearOff = s.tearOffAdjust { text += ZPL.tearOffAdjust(tearOff).rendered(with: characters) + "\n" }
            if let backfeed = s.backfeed { text += backfeedSequence(backfeed).rendered(with: characters) + "\n" }
            // Linerless-Modi kennen kein ^MM – per SGD setzen (SGD ist von ^CC/^CT unabhängig).
            if let mode = s.printMode, mode.usesSGD { text += SGD.setPrintMode(mode) }
            var format: [ZPLCommand] = []
            if let mediaType = s.mediaType { format.append(ZPL.mediaType(mediaType)) }
            if let tracking = s.tracking { format.append(ZPL.mediaTracking(tracking, markOffset: s.markOffset)) }
            if let mode = s.printMode, let command = ZPL.printModeCommand(mode) { format.append(command) }
            if let speed = s.speed { format.append(ZPL.printRate(speed)) }
            if let top = s.labelTop { format.append(ZPL.labelTop(top)) }
            if let left = s.labelLeft { format.append(ZPL.labelShift(left)) }
            if let powerUp = s.powerUpAction, let headClose = s.headCloseAction {
                format.append(ZPL.mediaFeed(powerUpAction: powerUp, headCloseAction: headClose))
            }
            if permanently { format.append(ZPL.saveSettings()) }
            if !format.isEmpty {
                let commands = [ZPL.startFormat()] + format + [ZPL.endFormat()]
                text += commands.map { $0.rendered(with: characters) + "\n" }.joined()
            }
            return Data(text.utf8)

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
    /// `media.printmode`, wie der Drucker ihn meldet (`getvar`); gesetzt wird mit
    /// ``PrintMode/sgdSetValue`` (Kennbuchstaben wie `T` oder `L`).
    static func printMode(_ mode: PrintMode) -> String { mode.sgdValue }

    static func printMode(sgd value: String) -> PrintMode? {
        if let exact = PrintMode(sgdValue: value) { return exact }
        let v = value.lowercased()
        if v.contains("linerless") {
            if v.contains("delayed") { return .linerlessDelayedCut }
            if v.contains("peel") { return .linerlessPeel }
            if v.contains("cut") { return .linerlessCut }
            if v.contains("rewind") { return .linerlessRewind }
            if v.contains("tear") { return .linerlessTear }
            return nil
        }
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

    /// `ezpl.media_type`; `nil` für die automatische Erkennung (kein eigener Wert). Seitenkerben
    /// teilen sich bei Link-OS den Wert `gap/notch` mit Einzeletiketten.
    static func mediaTracking(_ tracking: MediaTracking) -> String? {
        switch tracking {
        case .gap, .notch: return "gap/notch"
        case .blackMark: return "mark"
        case .continuous: return "continuous"
        case .autoDetect: return nil
        }
    }

    static func mediaTracking(sgd value: String) -> MediaTracking? {
        let v = value.lowercased()
        if v.contains("continuous") { return .continuous }
        if v.contains("mark") { return .blackMark }
        if v.contains("gap") || v.contains("web") { return .gap }
        if v.contains("notch") { return .notch }
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
        if let mode = s.printMode { result.append((SGD.Variable.printMode, mode.sgdSetValue)) }
        if let tearOff = s.tearOffAdjust { result.append((SGD.Variable.tearOff, String(tearOff))) }
        if let left = s.labelLeft { result.append((SGD.Variable.leftPosition, String(left))) }
        if let top = s.labelTop { result.append((SGD.Variable.labelTop, String(top))) }
        if let action = s.powerUpAction { result.append((SGD.Variable.powerUpAction, action.sgdValue)) }
        if let action = s.headCloseAction { result.append((SGD.Variable.headCloseAction, action.sgdValue)) }
        return result
    }

    /// Ganzzahl aus einem SGD-Wert (`"15.0"` → 15, `"-12"` → −12); kaufmännisch gerundet.
    static func integer(_ value: String?) -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite,
              abs(number) < 1e9 else { return nil }
        return Int(number.rounded())
    }

    /// Druckeinstellungen aus SGD-Werten (``SGD/printSettingsVariables``); fehlende oder
    /// unverständliche Werte lassen `base` unverändert. Ergebnis ist begrenzt (`clamped()`).
    static func settings(from values: [String: String], base: PrintSettings) -> PrintSettings {
        var s = base
        func value(_ name: String) -> String? {
            guard let raw = values[name]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "?" else { return nil }
            return raw
        }
        if let darkness = integer(value(SGD.Variable.tone)) { s.darkness = darkness }
        if let speed = integer(value(SGD.Variable.speed)) { s.speed = speed }
        if let tracking = value(SGD.Variable.mediaType).flatMap(mediaTracking(sgd:)) {
            s.tracking = tracking
        } else if value(SGD.Variable.mediaKind)?.lowercased() == "journal" {
            s.tracking = .continuous
        } else if let sense = value(SGD.Variable.senseMode)?.lowercased() {
            if sense.contains("bar") || sense.contains("mark") {
                s.tracking = .blackMark
            } else if sense.contains("gap") {
                s.tracking = .gap
            }
        }
        if let mediaType = value(SGD.Variable.printMethod).flatMap(mediaType(sgd:)) { s.mediaType = mediaType }
        if let mode = value(SGD.Variable.printMode).flatMap(printMode(sgd:)) { s.printMode = mode }
        if let top = integer(value(SGD.Variable.labelTop)) { s.labelTop = top }
        if let left = integer(value(SGD.Variable.leftPosition)) { s.labelLeft = left }
        if let tearOff = integer(value(SGD.Variable.tearOff)) { s.tearOffAdjust = tearOff }
        if let action = value(SGD.Variable.powerUpAction).flatMap(MediaFeedAction.init(sgdValue:)) {
            s.powerUpAction = action
        }
        if let action = value(SGD.Variable.headCloseAction).flatMap(MediaFeedAction.init(sgdValue:)) {
            s.headCloseAction = action
        }
        let caret = values[SGD.Variable.caret].flatMap(ControlCharacters.character(from:))
        let control = values[SGD.Variable.controlCharacter].flatMap(ControlCharacters.character(from:))
        let delimiter = values[SGD.Variable.delimiter].flatMap(ControlCharacters.character(from:))
        if caret != nil || control != nil || delimiter != nil {
            let characters = ControlCharacters(formatPrefix: caret ?? 0x5E, controlPrefix: control ?? 0x7E,
                                               delimiter: delimiter ?? 0x2C)
            s.controlCharacters = characters.isStandard ? nil : characters
        }
        return s.clamped()
    }
}

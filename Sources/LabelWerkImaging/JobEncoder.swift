import Foundation
import LabelWerkCore

/// Baut komplette Druckaufträge (ZPL II, EPL2, CPCL) aus Bitmaps.
///
/// Das erzeugte Byteformat ist verbindlich in ARCHITECTURE.md §8 festgelegt und identisch zum
/// CUPS-Filter `rastertolabelwerk`. Ein Druckauftrag aus der App (`PrinterClient.printImages`)
/// und einer über CUPS sind dadurch byte-gleich.
///
/// Vor dem Rastern (nur ``encode(images:pageSizes:copies:collate:)``): Schritt F „An Etikett
/// anpassen“ (``LabelFit``) für Seiten, deren Größe nicht zum Etikett passt – Inhalt zuschneiden,
/// bei Bedarf um 90° drehen, auf das Etikett abzüglich 1,5 mm Rand skalieren, mittig setzen.
///
/// Ablauf je Seite (Vorverarbeitung):
/// 0. Wirksame Drehung (``PrintSettings/effectiveRotation``) 90° bzw. 270° → Bitmap im
///    Uhrzeigersinn drehen (alle Sprachen), **vor** dem Abschneiden.
/// 1. Breite > `maxPrintWidthDots` → rechts abschneiden. Seiten ohne Fläche (Breite oder
///    Höhe 0) werden danach übersprungen – wie im C-Filter (`lw_job_add_page`), der sie mit
///    einer Warnung auslässt, statt den ganzen Auftrag scheitern zu lassen.
///    1b. `stopAtLastElement` bei Endlosmaterial → Seitenhöhe = letzte Zeile mit schwarzen
///    Punkten + 1 + `stopOffset` (mindestens 1; fehlende Zeilen werden weiß ergänzt).
/// 2. `negative` → invertieren.
/// 3. `skipBlankLabels` und Seite leer → Seite überspringen.
/// 4. Nur EPL/CPCL: `mirror` → horizontal spiegeln (ZPL nutzt `^PM`).
/// 5. Nur CPCL: wirksame Drehung 180° → um 180° drehen (ZPL nutzt `^PO`, EPL `ZB`).
///
/// Kopien: Bei `collate == false` oder nur einer (nicht übersprungenen) Seite wird jede Seite
/// einmal mit Menge `copies` gesendet. Bei `collate == true` und mehreren Seiten wird die
/// gesamte Seitenfolge `copies`-mal wiederholt, jeweils mit Menge 1.
///
/// Echtzeituhr (`^ST`, nur ZPL): Die Zeit liefert ``now`` (Standard: Systemzeit), umgerechnet in
/// ``timeZone`` (Standard: aktuelle Zeitzone) und auf ganze Sekunden abgerundet; Etikett k
/// (0-basiert) sieht zusätzlich k · ``timeStepSeconds`` (Standard 0). Tests und
/// `lwctl encode --fixed-time … --time-step …` setzen eine feste Zeit – wie `LW_FIXED_TIME` und
/// `LW_TIME_STEP_SECONDS` beim C-Filter.
///
/// „Aufträge vor dem Drucken abbrechen“: Der Encoder schreibt nur die `~JA`-Zeile – ganz am
/// Anfang, vor den Startbefehlen, weil `~JA` die Daten vor sich im Eingangspuffer löscht; warten
/// muss der Aufrufer (``cancelPrefixLength()`` liefert die Stelle, `PrinterClient.printImages`
/// bzw. `PrinterClient.sendJob` wartet dort `cancelDelayMs`).
///
/// Alle Einstellungen werden vor der Verwendung mit `PrintSettings.clamped()` auf gültige
/// Bereiche begrenzt.
public struct JobEncoder: Sendable {
    public let language: PrinterLanguage
    public let resolution: Resolution
    /// Einstellungen wie übergeben (kodiert wird mit `settings.clamped()`).
    public let settings: PrintSettings
    public let stock: LabelStock?
    /// Maximale Druckbreite in Punkten; breitere Seiten werden rechts abgeschnitten.
    /// `nil` oder ≤ 0 = keine Begrenzung.
    public let maxPrintWidthDots: Int?
    /// Zeitzone für `^ST` (Ortszeit des Druckers).
    public var timeZone: TimeZone
    /// Zeitquelle für `^ST`; wird beim Auftragsbeginn und – je nach ``PrintSettings/rtcUpdate`` –
    /// vor Etiketten abgefragt.
    public var now: @Sendable () -> Date
    /// Für Tests: Etikett k (0-basiert, Auftragsreihenfolge inkl. Sortierwiederholungen) sieht die
    /// Zeit `now() + k · timeStepSeconds` (Standard 0 = Systemzeit bzw. feste Zeit für alle).
    public var timeStepSeconds: Int64 = 0

    /// Höchstmenge je Etikett (`^PQ` erlaubt bis 99 999 999).
    static let maxQuantity = 99_999_999

    /// Standardlücke in Punkten, wenn kein Etikettenformat bekannt ist (EPL `Q`).
    public static let defaultGapDots = 24

    /// Abstand in Sekunden, nach dem ``RTCUpdate/everyMinute`` die Uhr erneut stellt.
    public static let rtcMinuteInterval: Int64 = 60

    public init(language: PrinterLanguage, resolution: Resolution, settings: PrintSettings,
                stock: LabelStock? = nil, maxPrintWidthDots: Int? = nil,
                timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.language = language
        self.resolution = resolution
        self.settings = settings
        self.stock = stock
        self.maxPrintWidthDots = maxPrintWidthDots
        self.timeZone = timeZone
        self.now = now
    }

    // MARK: - Öffentliche API

    /// Kodiert einen Auftrag aus fertigen 1-Bit-Seiten (1 = schwarz).
    ///
    /// - Parameters:
    ///   - pages: Seiten (je Seite ein Etikett).
    ///   - copies: Anzahl Kopien (Werte < 1 werden als 1 behandelt).
    ///   - collate: Sortieren (ganze Seitenfolge wiederholen) statt Kopien je Seite.
    ///
    /// Seiten ohne Fläche (Breite oder Höhe 0 nach dem Abschneiden) und – bei
    /// `skipBlankLabels` – leere Seiten werden übersprungen und zählen für die Kopien-Regel
    /// nicht mit. Bleibt keine Seite übrig, enthält der Auftrag nur Kopf- und Endbefehle.
    ///
    /// - Throws: `ImagingError` (z. B. `.compressionFailed`), falls die Z64-Kompression scheitert.
    public func encode(pages: [MonoBitmap], copies: Int = 1, collate: Bool = true) throws -> Data {
        let s = settings.clamped()
        let processed = pages.compactMap { preprocess($0, settings: s) }

        let quantity = min(max(copies, 1), Self.maxQuantity)
        let sequence = collate && processed.count > 1
            ? LabelSequence(pageCount: processed.count, repetitions: quantity, quantity: 1)
            : LabelSequence(pageCount: processed.count, repetitions: 1, quantity: quantity)

        switch language {
        case .zpl: return try encodeZPL(processed, sequence: sequence, settings: s)
        case .epl: return encodeEPL(processed, sequence: sequence, settings: s)
        case .cpcl: return encodeCPCL(processed, sequence: sequence, settings: s)
        }
    }

    /// Kodiert einen Auftrag aus Graustufenbildern; jedes Bild wird zuvor gemäß
    /// `settings.dither` und `settings.threshold` gerastert (vor dem Drehen und Abschneiden).
    public func encode(images: [GrayImage], copies: Int = 1, collate: Bool = true) throws -> Data {
        let s = settings.clamped()
        let pages = images.map { Ditherer.dither($0, algorithm: s.dither, threshold: s.threshold) }
        return try encode(pages: pages, copies: copies, collate: collate)
    }

    /// Wie ``encode(images:copies:collate:)``, legt aber jedes Bild vorher mit seiner Seitengröße
    /// auf das Etikett (Schritt F aus ARCHITECTURE.md §8, ``LabelFit``) – wie der CUPS-Filter mit
    /// `cupsPageSize`. `nil` = Bild ist etikettengroß (keine Anpassung).
    ///
    /// - Throws: `ImagingError.invalidArgument`, wenn `pageSizes` nicht genau ein Element je Bild hat.
    public func encode(images: [GrayImage], pageSizes: [PageSizePoints?], copies: Int = 1,
                       collate: Bool = true) throws -> Data {
        guard pageSizes.count == images.count else {
            throw ImagingError.invalidArgument("\(pageSizes.count) Seitengrößen für \(images.count) Bilder")
        }
        let fittedImages = zip(images, pageSizes).map { fitted($0, pageSize: $1) }
        return try encode(images: fittedImages, copies: copies, collate: collate)
    }

    /// Schritt F aus §8 für ein Bild: legt eine Seite, deren Größe (`pageSize`, Punkte) um mehr als
    /// 2 mm vom Etikett (`settings.labelWidthHundredthsMM` × `labelHeightHundredthsMM`) abweicht,
    /// auf das Etikett (Auflösung des Encoders in beide Richtungen; Inhalt ggf. gedreht und
    /// vergrößert bzw. verkleinert, 1,5 mm Rand). Sonst unverändert.
    public func fitted(_ image: GrayImage, pageSize: PageSizePoints?) -> GrayImage {
        guard let plan = LabelFit.plan(settings: settings, pageSize: pageSize, xDPI: resolution.dpi,
                                       yDPI: resolution.dpi, imageWidth: image.width, imageHeight: image.height)
        else { return image }
        return LabelFit.apply(image, plan: plan)
    }

    /// Wendet die Vorverarbeitung (Schritte 0–5) auf eine Seite an, z. B. für eine
    /// Druckvorschau. Liefert `nil`, wenn die Seite übersprungen würde (keine Fläche nach dem
    /// Abschneiden oder leer bei `skipBlankLabels`).
    public func preprocess(_ page: MonoBitmap) -> MonoBitmap? {
        preprocess(page, settings: settings.clamped())
    }

    /// Anzahl Bytes der `~JA`-Zeile am Auftragsanfang („Aufträge vor dem Drucken abbrechen“),
    /// `nil` ohne `~JA` (Einstellung aus oder CPCL). Der Aufrufer sendet diesen Teil, wartet
    /// `cancelDelayMs` und sendet dann den Rest (Startbefehle und Etiketten) – wie der CUPS-Filter.
    public func cancelPrefixLength() -> Int? {
        let s = settings.clamped()
        guard s.cancelJobsBeforePrint, language != .cpcl else { return nil }
        let prefix = language == .zpl ? s.effectiveControlCharacters.controlPrefixString : "~"
        return prefix.utf8.count + 3   // "JA\n"
    }

    // MARK: - Vorverarbeitung

    private func preprocess(_ page: MonoBitmap, settings s: PrintSettings) -> MonoBitmap? {
        // Seiten ohne Fläche bleiben es auch nach Drehen und Abschneiden.
        if page.width == 0 || page.height == 0 { return nil }
        var bitmap = page
        let rotation = s.effectiveRotation
        // (0) Vierteldrehungen in Software (alle Sprachen), vor dem Abschneiden
        switch rotation {
        case .r90: bitmap = bitmap.rotated(.r90)
        case .r270: bitmap = bitmap.rotated(.r270)
        case .r0, .r180: break
        }
        // (1) Abschneiden
        if let maxWidth = maxPrintWidthDots, maxWidth > 0, bitmap.width > maxWidth {
            bitmap = bitmap.cropped(x: 0, y: 0, width: maxWidth, height: bitmap.height)
        }
        // Seiten ohne Fläche überspringen (wie der C-Filter, unabhängig von skipBlankLabels)
        if bitmap.width == 0 || bitmap.height == 0 { return nil }
        // (1b) Bei letztem Element stoppen (nur Endlosmaterial)
        if s.stopAtLastElement && s.tracking == .continuous {
            bitmap = Self.trimmedToLastElement(bitmap, stopOffset: s.stopOffset)
        }
        // (2) Negativ
        if s.negative { bitmap = bitmap.inverted() }
        // (3) Leere Seiten überspringen
        if s.skipBlankLabels && bitmap.isBlank { return nil }
        // (4) Spiegeln (nur EPL/CPCL)
        if s.mirror && language != .zpl { bitmap = bitmap.mirrored() }
        // (5) 180° drehen (nur CPCL)
        if rotation == .r180 && language == .cpcl { bitmap = bitmap.rotated180() }
        return bitmap
    }

    /// Seitenhöhe = letzte Zeile mit schwarzen Punkten + 1 + `stopOffset`, mindestens 1.
    /// Kürzere Seiten werden unten abgeschnitten, längere mit weißen Zeilen ergänzt.
    static func trimmedToLastElement(_ bitmap: MonoBitmap, stopOffset: Int) -> MonoBitmap {
        var lastBlack = -1
        var y = bitmap.height - 1
        while y >= 0 {
            if !bitmap.isRowBlank(y) {
                lastBlack = y
                break
            }
            y -= 1
        }
        let height = max(1, lastBlack + 1 + max(0, stopOffset))
        if height == bitmap.height { return bitmap }
        let bpr = bitmap.bytesPerRow
        var data = [UInt8](repeating: 0, count: bpr * height)
        let kept = min(height, bitmap.height) * bpr
        if kept > 0 {
            data.replaceSubrange(0..<kept, with: bitmap.data[0..<kept])
        }
        return MonoBitmap(width: bitmap.width, height: height, data: data)
    }

    // MARK: - ZPL

    private func encodeZPL(_ pages: [MonoBitmap], sequence: LabelSequence,
                           settings s: PrintSettings) throws -> Data {
        var out = JobWriter(lineEnding: [0x0A])
        let z = ZPLDialect(s.effectiveControlCharacters)
        var clock = RTCClock(update: s.rtcUpdate, now: now, timeStep: timeStepSeconds, timeZone: timeZone, dialect: z)

        // ~JA zuerst: Es löscht die Daten vor sich im Eingangspuffer – stünden die Startbefehle
        // davor, würfe der Drucker sie mit weg.
        if s.cancelJobsBeforePrint { out.line(z.control("JA")) }
        if !s.startCommands.isEmpty { out.line(s.startCommands) }
        if let darkness = s.darkness { out.line(z.control("SD", Self.zeroPadded(darkness, width: 2))) }
        if let tearOff = s.tearOffAdjust { out.line(z.control("TA", Self.zeroPadded(tearOff, width: 3))) }
        // Rückzugsfolge ist der Steuerbefehl ~JS (^JS wäre die Sensorwahl).
        if let backfeed = s.backfeed { out.line(z.control("JS", backfeed.zplCode)) }
        if s.calibrateBeforeJob { out.line(z.control("JC")) }
        // Linerless-Modi haben kein ^MM: per SGD setzen (unabhängig von den Steuerzeichen).
        if let mode = s.printMode, mode.usesSGD { out.raw(Data(SGD.setPrintMode(mode).utf8)) }
        if let powerUp = s.powerUpAction, let headClose = s.headCloseAction {
            out.line(z.format("XA") + z.format("MF", powerUp.zplCode, headClose.zplCode) + z.format("XZ"))
        }
        if let line = clock.jobStart() { out.line(line) }

        // Grafikfelder je Seite nur einmal kodieren (Sortierung wiederholt Seiten).
        var fields = [String?](repeating: nil, count: pages.count)
        var isFirstLabel = true
        for (labelIndex, item) in sequence.enumerated() {
            let page = pages[item.page]
            let payload: String
            if let cached = fields[item.page] {
                payload = cached
            } else {
                // zlib-Fehler werden gemeldet statt still auf ACS auszuweichen (byte-genaue
                // Übereinstimmung mit dem C-Filter).
                payload = try Self.graphicPayload(page, compression: s.compression)
                fields[item.page] = payload
            }
            if let line = clock.beforeLabel(labelIndex) { out.line(line) }
            out.line(z.format("XA"))
            if !s.labelStartCommands.isEmpty { out.line(s.labelStartCommands) }
            if let code = s.printMode?.mmCode { out.line(z.format("MM", code)) }
            if let tracking = s.tracking {
                if tracking == .blackMark, let offset = s.markOffset {
                    out.line(z.format("MN", tracking.zplCode, String(offset)))
                } else {
                    out.line(z.format("MN", tracking.zplCode))
                }
            }
            if let mediaType = s.mediaType { out.line(z.format("MT", mediaType.zplCode)) }
            if let speed = s.speed { out.line(z.format("PR", String(speed), String(speed), String(speed))) }
            out.line(z.format("PW", String(page.width)))
            out.line(z.format("LL", String(page.height)))
            out.line(z.format("LH", "0", "0"))
            if let top = s.labelTop { out.line(z.format("LT", String(top))) }
            if let left = s.labelLeft { out.line(z.format("LS", String(left))) }
            out.line(z.format("PO", s.effectiveRotation == .r180 ? "I" : "N"))
            out.line(z.format("PM", s.mirror ? "Y" : "N"))
            let total = String(page.data.count)
            out.line(z.format("FO", "0", "0")
                     + z.format("GF", "A", total, total, String(page.bytesPerRow), payload)
                     + z.format("FS"))
            let quantity = String(item.quantity)
            if s.pauseEvery > 0 {
                out.line(z.format("PQ", quantity, String(s.pauseEvery), "0", "N"))
            } else if s.cutEvery > 0 {
                out.line(z.format("PQ", quantity, String(s.cutEvery), "0", "Y"))
            } else {
                out.line(z.format("PQ", quantity))
            }
            if isFirstLabel && s.saveToPrinter { out.line(z.format("JU", "S")) }
            if !s.labelEndCommands.isEmpty { out.line(s.labelEndCommands) }
            out.line(z.format("XZ"))
            isFirstLabel = false
        }
        if !s.endCommands.isEmpty { out.line(s.endCommands) }
        return out.data
    }

    /// Datenteil eines `^GFA`-Feldes (Hex, ACS oder Z64); zlib-Fehler werden geworfen.
    static func graphicPayload(_ bitmap: MonoBitmap, compression: GraphicCompression) throws -> String {
        switch compression {
        case .hex: return Hex.encode(bitmap.data)
        case .acs: return ACS.encode(bitmap)
        case .z64: return try Z64.encode(bytes: bitmap.data)
        }
    }

    // MARK: - EPL2

    private func encodeEPL(_ pages: [MonoBitmap], sequence: LabelSequence,
                           settings s: PrintSettings) -> Data {
        var out = JobWriter(lineEnding: [0x0A])
        // Wie ZPL: ~JA vor den Startbefehlen (ohne Ersatz-Steuerzeichen – die gelten nur für ZPL).
        if s.cancelJobsBeforePrint { out.line("~JA") }
        if !s.startCommands.isEmpty { out.line(s.startCommands) }
        let gap = stock.map { $0.gapDots(resolution) } ?? Self.defaultGapDots
        var graphics = [Data?](repeating: nil, count: pages.count)
        for item in sequence {
            let page = pages[item.page]
            let gw: Data
            if let cached = graphics[item.page] {
                gw = cached
            } else {
                gw = EPLGraphicEncoder.gw(x: 0, y: 0, bitmap: page)
                graphics[item.page] = gw
            }
            out.raw([0x0A])   // führendes LF leert evtl. Restdaten
            out.line("N")
            if !s.labelStartCommands.isEmpty { out.line(s.labelStartCommands) }
            out.line("q\(page.width)")
            switch s.tracking {
            case .blackMark?: out.line("Q\(page.height),B\(gap)")
            case .continuous?: out.line("Q\(page.height),0")
            case .gap?, .autoDetect?, .notch?, nil: out.line("Q\(page.height),\(gap)")
            }
            if let speed = s.speed { out.line("S\(min(max(speed, 1), 6))") }
            if let darkness = s.darkness { out.line("D\(min(max((darkness + 1) / 2, 0), 15))") }
            out.line(s.effectiveRotation == .r180 ? "ZB" : "ZT")
            if s.mediaType != nil || s.printMode != nil {
                var option = "O"
                if s.mediaType == .directThermal { option += "D" }
                if s.printMode == .cutter {
                    option += "C"
                } else if s.printMode == .peelOff {
                    option += "P"
                }
                out.line(option)
            }
            out.raw(gw)   // enthält bereits das abschließende LF
            // Vor „P“: Nach dem Druck leert das nächste „N“ den Bildpuffer – wie bei ZPL vor ^XZ.
            if !s.labelEndCommands.isEmpty { out.line(s.labelEndCommands) }
            out.line("P\(item.quantity)")
        }
        if !s.endCommands.isEmpty { out.line(s.endCommands) }
        return out.data
    }

    // MARK: - CPCL

    private func encodeCPCL(_ pages: [MonoBitmap], sequence: LabelSequence,
                            settings s: PrintSettings) -> Data {
        var out = JobWriter(lineEnding: [0x0D, 0x0A])
        let res = resolution == .dpi203 ? 200 : resolution.dpi
        var graphics = [Data?](repeating: nil, count: pages.count)
        for item in sequence {
            let page = pages[item.page]
            let cg: Data
            if let cached = graphics[item.page] {
                cg = cached
            } else {
                cg = CPCLGraphicEncoder.cg(x: 0, y: 0, bitmap: page)
                graphics[item.page] = cg
            }
            out.line("! 0 \(res) \(res) \(page.height) \(item.quantity)")
            out.line("PAGE-WIDTH \(page.width)")
            if let darkness = s.darkness { out.line("CONTRAST \(min(max((darkness * 3 + 15) / 30, 0), 3))") }
            if let speed = s.speed { out.line("SPEED \(min(max(speed, 0), 5))") }
            out.raw(cg)   // enthält bereits CR LF
            if s.tracking != .continuous { out.line("FORM") }
            out.line("PRINT")
        }
        return out.data
    }

    // MARK: - Hilfen

    /// Ganzzahl wie `printf("%0*d")`: Breite inklusive Vorzeichen, Nullen nach dem Vorzeichen
    /// (`zeroPadded(10, 3)` → `010`, `zeroPadded(-10, 3)` → `-10`, `zeroPadded(-5, 3)` → `-05`).
    static func zeroPadded(_ value: Int, width: Int) -> String {
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : ""
        let padding = max(0, width - sign.count - digits.count)
        return sign + String(repeating: "0", count: padding) + digits
    }
}

/// Reihenfolge der Etiketten eines Auftrags: die Seitenfolge `repetitions`-mal, jedes Etikett
/// mit Menge `quantity` (wird nicht als Liste aufgebaut – auch große Kopienzahlen bleiben günstig).
struct LabelSequence: Sequence {
    let pageCount: Int
    let repetitions: Int
    let quantity: Int

    struct Iterator: IteratorProtocol {
        let sequence: LabelSequence
        var repetition = 0
        var page = 0

        mutating func next() -> (page: Int, quantity: Int)? {
            guard sequence.pageCount > 0, repetition < sequence.repetitions else { return nil }
            let item = (page: page, quantity: sequence.quantity)
            page += 1
            if page == sequence.pageCount {
                page = 0
                repetition += 1
            }
            return item
        }
    }

    func makeIterator() -> Iterator { Iterator(sequence: self) }
}

/// Puffer für Auftragsdaten mit fester Zeilenendung.
struct JobWriter {
    let lineEnding: [UInt8]
    private(set) var data = Data()

    init(lineEnding: [UInt8]) {
        self.lineEnding = lineEnding
    }

    mutating func line(_ text: String) {
        data.append(contentsOf: Array(text.utf8))
        data.append(contentsOf: lineEnding)
    }

    mutating func raw(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func raw(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }
}

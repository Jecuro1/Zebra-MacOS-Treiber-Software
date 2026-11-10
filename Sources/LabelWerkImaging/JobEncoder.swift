import Foundation
import LabelWerkCore

/// Baut komplette Druckaufträge (ZPL II, EPL2, CPCL) aus Bitmaps.
///
/// Das erzeugte Byteformat ist verbindlich in ARCHITECTURE.md §8 festgelegt und identisch zum
/// CUPS-Filter `rastertolabelwerk`. Ein Druckauftrag aus der App (`PrinterClient.printImages`)
/// und einer über CUPS sind dadurch byte-gleich.
///
/// Ablauf je Seite (Vorverarbeitung):
/// 1. Breite > `maxPrintWidthDots` → rechts abschneiden. Seiten ohne Fläche (Breite oder
///    Höhe 0) werden danach übersprungen – wie im C-Filter (`lw_job_add_page`), der sie mit
///    einer Warnung auslässt, statt den ganzen Auftrag scheitern zu lassen.
/// 2. `negative` → invertieren.
/// 3. `skipBlankLabels` und Seite leer → Seite überspringen.
/// 4. Nur EPL/CPCL: `mirror` → horizontal spiegeln (ZPL nutzt `^PM`).
/// 5. Nur CPCL: `rotate180` → um 180° drehen (ZPL nutzt `^PO`, EPL `ZB`).
///
/// Kopien: Bei `collate == false` oder nur einer (nicht übersprungenen) Seite wird jede Seite
/// einmal mit Menge `copies` gesendet. Bei `collate == true` und mehreren Seiten wird die
/// gesamte Seitenfolge `copies`-mal wiederholt, jeweils mit Menge 1.
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

    /// Höchstmenge je Etikett (`^PQ` erlaubt bis 99 999 999).
    static let maxQuantity = 99_999_999

    /// Standardlücke in Punkten, wenn kein Etikettenformat bekannt ist (EPL `Q`).
    public static let defaultGapDots = 24

    public init(language: PrinterLanguage, resolution: Resolution, settings: PrintSettings,
                stock: LabelStock? = nil, maxPrintWidthDots: Int? = nil) {
        self.language = language
        self.resolution = resolution
        self.settings = settings
        self.stock = stock
        self.maxPrintWidthDots = maxPrintWidthDots
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
    /// `settings.dither` und `settings.threshold` gerastert (vor dem Abschneiden).
    public func encode(images: [GrayImage], copies: Int = 1, collate: Bool = true) throws -> Data {
        let s = settings.clamped()
        let pages = images.map { Ditherer.dither($0, algorithm: s.dither, threshold: s.threshold) }
        return try encode(pages: pages, copies: copies, collate: collate)
    }

    /// Wendet die Vorverarbeitung (Schritte 1–5) auf eine Seite an, z. B. für eine
    /// Druckvorschau. Liefert `nil`, wenn die Seite übersprungen würde (keine Fläche nach dem
    /// Abschneiden oder leer bei `skipBlankLabels`).
    public func preprocess(_ page: MonoBitmap) -> MonoBitmap? {
        preprocess(page, settings: settings.clamped())
    }

    // MARK: - Vorverarbeitung

    private func preprocess(_ page: MonoBitmap, settings s: PrintSettings) -> MonoBitmap? {
        var bitmap = page
        // (1) Abschneiden
        if let maxWidth = maxPrintWidthDots, maxWidth > 0, bitmap.width > maxWidth {
            bitmap = bitmap.cropped(x: 0, y: 0, width: maxWidth, height: bitmap.height)
        }
        // Seiten ohne Fläche überspringen (wie der C-Filter, unabhängig von skipBlankLabels)
        if bitmap.width == 0 || bitmap.height == 0 { return nil }
        // (2) Negativ
        if s.negative { bitmap = bitmap.inverted() }
        // (3) Leere Seiten überspringen
        if s.skipBlankLabels && bitmap.isBlank { return nil }
        // (4) Spiegeln (nur EPL/CPCL)
        if s.mirror && language != .zpl { bitmap = bitmap.mirrored() }
        // (5) Drehen (nur CPCL)
        if s.rotate180 && language == .cpcl { bitmap = bitmap.rotated180() }
        return bitmap
    }

    // MARK: - ZPL

    private func encodeZPL(_ pages: [MonoBitmap], sequence: LabelSequence,
                           settings s: PrintSettings) throws -> Data {
        var out = JobWriter(lineEnding: [0x0A])
        if !s.startCommands.isEmpty { out.line(s.startCommands) }
        if let darkness = s.darkness { out.line("~SD" + Self.zeroPadded(darkness, width: 2)) }
        if let tearOff = s.tearOffAdjust { out.line("~TA" + Self.zeroPadded(tearOff, width: 3)) }
        if s.calibrateBeforeJob { out.line("~JC") }

        // Grafikfelder je Seite nur einmal kodieren (Sortierung wiederholt Seiten).
        var fields = [String?](repeating: nil, count: pages.count)
        var isFirstLabel = true
        for item in sequence {
            let page = pages[item.page]
            let field: String
            if let cached = fields[item.page] {
                field = cached
            } else {
                // zlib-Fehler werden gemeldet statt still auf ACS auszuweichen (byte-genaue
                // Übereinstimmung mit dem C-Filter).
                field = try ZPLGraphicEncoder.strictGraphicField(page, compression: s.compression)
                fields[item.page] = field
            }
            out.line("^XA")
            if let mode = s.printMode { out.line("^MM" + mode.zplCode) }
            if let tracking = s.tracking { out.line("^MN" + tracking.zplCode) }
            if let mediaType = s.mediaType { out.line("^MT" + mediaType.zplCode) }
            if let speed = s.speed { out.line("^PR\(speed),\(speed),\(speed)") }
            if let backfeed = s.backfeed { out.line("^JS" + backfeed.zplCode) }
            out.line("^PW\(page.width)")
            out.line("^LL\(page.height)")
            out.line("^LH0,0")
            if let top = s.labelTop { out.line("^LT\(top)") }
            if let left = s.labelLeft { out.line("^LS\(left)") }
            out.line(s.rotate180 ? "^POI" : "^PON")
            out.line(s.mirror ? "^PMY" : "^PMN")
            out.line("^FO0,0" + field + "^FS")
            if s.cutEvery > 0 {
                out.line("^PQ\(item.quantity),\(s.cutEvery),0,Y")
            } else {
                out.line("^PQ\(item.quantity)")
            }
            if isFirstLabel && s.saveToPrinter { out.line("^JUS") }
            out.line("^XZ")
            isFirstLabel = false
        }
        if !s.endCommands.isEmpty { out.line(s.endCommands) }
        return out.data
    }

    // MARK: - EPL2

    private func encodeEPL(_ pages: [MonoBitmap], sequence: LabelSequence,
                           settings s: PrintSettings) -> Data {
        var out = JobWriter(lineEnding: [0x0A])
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
            out.line("q\(page.width)")
            switch s.tracking {
            case .blackMark?: out.line("Q\(page.height),B\(gap)")
            case .continuous?: out.line("Q\(page.height),0")
            case .gap?, .autoDetect?, nil: out.line("Q\(page.height),\(gap)")
            }
            if let speed = s.speed { out.line("S\(min(max(speed, 1), 6))") }
            if let darkness = s.darkness { out.line("D\(min(max((darkness + 1) / 2, 0), 15))") }
            out.line(s.rotate180 ? "ZB" : "ZT")
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

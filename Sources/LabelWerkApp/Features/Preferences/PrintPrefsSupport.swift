import SwiftUI
import LabelWerkKit

// MARK: - Abschnitte

/// Abschnitte der Druckeinstellungen – entsprechen den Registerkarten „Optionen“, „Erweitertes Setup“,
/// „Dithering“ und „Benutzerdefinierte Befehle“ des Windows-Treibers, hier auf einer Seite vereint.
enum PrintPrefsSection: String, CaseIterable, Identifiable, Hashable {
    case quality
    case media
    case position
    case image
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: return tr("Qualität")
        case .media: return tr("Medien")
        case .position: return tr("Position")
        case .image: return tr("Bild")
        case .advanced: return tr("Erweitert")
        }
    }

    var systemImage: String {
        switch self {
        case .quality: return "circle.lefthalf.filled"
        case .media: return "square.stack.3d.up"
        case .position: return "arrow.up.and.down.and.arrow.left.and.right"
        case .image: return "photo"
        case .advanced: return "gearshape.2"
        }
    }
}

// MARK: - Druckerrelevante Felder

/// Felder, die `PrinterSession.applySettings` an den Drucker überträgt (Abgleich & Hervorhebung).
enum PrintPrefsField: String, CaseIterable, Hashable {
    case darkness
    case speed
    case mediaType
    case tracking
    case printMode
    case labelTop
    case labelLeft
    case tearOff
    case backfeed

    var title: String {
        switch self {
        case .darkness: return tr("Schwärzung")
        case .speed: return tr("Geschwindigkeit")
        case .mediaType: return tr("Druckverfahren")
        case .tracking: return tr("Medienerkennung")
        case .printMode: return tr("Druckmodus")
        case .labelTop: return tr("Oberer Versatz")
        case .labelLeft: return tr("Linker Versatz")
        case .tearOff: return tr("Abreißposition")
        case .backfeed: return tr("Rückzug")
        }
    }

    func matches(_ a: PrintSettings, _ b: PrintSettings) -> Bool {
        switch self {
        case .darkness: return a.darkness == b.darkness
        case .speed: return a.speed == b.speed
        case .mediaType: return a.mediaType == b.mediaType
        case .tracking: return a.tracking == b.tracking
        case .printMode: return a.printMode == b.printMode
        case .labelTop: return a.labelTop == b.labelTop
        case .labelLeft: return a.labelLeft == b.labelLeft
        case .tearOff: return a.tearOffAdjust == b.tearOffAdjust
        case .backfeed: return a.backfeed == b.backfeed
        }
    }

    /// Ist das Feld ausdrücklich gesetzt (nicht „Druckerwert“)?
    func isOverridden(in settings: PrintSettings) -> Bool {
        switch self {
        case .darkness: return settings.darkness != nil
        case .speed: return settings.speed != nil
        case .mediaType: return settings.mediaType != nil
        case .tracking: return settings.tracking != nil
        case .printMode: return settings.printMode != nil
        case .labelTop: return settings.labelTop != nil
        case .labelLeft: return settings.labelLeft != nil
        case .tearOff: return settings.tearOffAdjust != nil
        case .backfeed: return settings.backfeed != nil
        }
    }

    static func differences(_ a: PrintSettings, _ b: PrintSettings) -> [PrintPrefsField] {
        allCases.filter { !$0.matches(a, b) }
    }

    /// Übernimmt nur den Wert dieses Feldes aus `source` nach `target`.
    func copy(from source: PrintSettings, into target: inout PrintSettings) {
        switch self {
        case .darkness: target.darkness = source.darkness
        case .speed: target.speed = source.speed
        case .mediaType: target.mediaType = source.mediaType
        case .tracking: target.tracking = source.tracking
        case .printMode: target.printMode = source.printMode
        case .labelTop: target.labelTop = source.labelTop
        case .labelLeft: target.labelLeft = source.labelLeft
        case .tearOff: target.tearOffAdjust = source.tearOffAdjust
        case .backfeed: target.backfeed = source.backfeed
        }
    }
}

// MARK: - Abgleichstand (überdauert Neustarts)

/// Merkt sich je Drucker die zuletzt übertragenen bzw. vom Drucker gelesenen Werte, damit der
/// Abgleich-Hinweis auch nach einem Neustart der App stimmt. Ohne gespeicherten Stand gilt
/// `PrintSettings.default` – jedes eigene Feld zählt dann als „noch nicht gesendet“.
enum PrintPrefsSyncStore {
    private static let defaultsKey = "LabelWerk.PrintPrefs.SyncedSettings"

    static func baseline(for printerID: UUID) -> PrintSettings? {
        load()[printerID.uuidString]
    }

    /// Speichert den Stand von `printerID` und verwirft Einträge von Druckern, die es nicht mehr gibt.
    static func store(_ settings: PrintSettings, for printerID: UUID, knownPrinterIDs: Set<UUID>) {
        var entries = load()
        entries[printerID.uuidString] = settings
        var keep = Set(knownPrinterIDs.map { $0.uuidString })
        keep.insert(printerID.uuidString)
        entries = entries.filter { keep.contains($0.key) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func load() -> [String: PrintSettings] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([String: PrintSettings].self, from: data) else {
            return [:]
        }
        return entries
    }
}

// MARK: - Werte vom Drucker (SGD)

/// Liest SGD-Antworten robust in `PrintSettings` ein. Drucker melden je nach Firmware leicht
/// unterschiedliche Schreibweisen („thermal trans“, „Thermal Transfer“, „TT“ …).
enum PrintPrefsPrinterValues {
    /// Abgefragte SGD-Variablen. `zpl.label_top` gibt es nicht auf jedem Modell – fehlt die Antwort,
    /// bleibt der Wert unverändert.
    static let variables: [String] = [
        "print.tone", "media.speed", "ezpl.media_type", "ezpl.print_method",
        "media.printmode", "zpl.label_top", "ezpl.tear_off", "zpl.left_position",
    ]

    struct Outcome {
        var settings: PrintSettings
        /// Felder, deren Wert sich durch das Einlesen geändert hat.
        var changed: Set<PrintPrefsField>
        /// Felder, die der Drucker gemeldet hat (nur diese sind danach mit ihm abgeglichen).
        var read: Set<PrintPrefsField>
        /// Anzahl erfolgreich gelesener Felder.
        var readCount: Int { read.count }
    }

    static func merge(_ values: [String: String], into current: PrintSettings, maxSpeed: Int) -> Outcome {
        var result = current
        var read: Set<PrintPrefsField> = []
        func value(_ key: String) -> String? { cleaned(values[key]) }

        if let tone = number(value("print.tone")) {
            result.darkness = clamp(Int(tone.rounded()), 0, 30)
            read.insert(.darkness)
        }
        if let speed = number(value("media.speed")) {
            result.speed = clamp(Int(speed.rounded()), 1, max(1, min(14, maxSpeed)))
            read.insert(.speed)
        }
        if let type = mediaType(from: value("ezpl.print_method")) ?? mediaType(from: value("ezpl.media_type")) {
            result.mediaType = type
            read.insert(.mediaType)
        }
        if let tracking = tracking(from: value("ezpl.media_type")) ?? tracking(from: value("ezpl.print_method")) {
            result.tracking = tracking
            read.insert(.tracking)
        }
        if let mode = printMode(from: value("media.printmode")) {
            result.printMode = mode
            read.insert(.printMode)
        }
        if let top = number(value("zpl.label_top")) {
            result.labelTop = clamp(Int(top.rounded()), -120, 120)
            read.insert(.labelTop)
        }
        if let tear = number(value("ezpl.tear_off")) {
            result.tearOffAdjust = clamp(Int(tear.rounded()), -120, 120)
            read.insert(.tearOff)
        }
        if let left = number(value("zpl.left_position")) {
            result.labelLeft = clamp(Int(left.rounded()), -9999, 9999)
            read.insert(.labelLeft)
        }
        let changed = Set(read.filter { !$0.matches(result, current) })
        return Outcome(settings: result, changed: changed, read: read)
    }

    /// Entfernt Anführungszeichen/Leerraum und verwirft „?“, „null“ & Co.
    static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        let lower = trimmed.lowercased()
        if lower.isEmpty || ["?", "null", "nil", "unknown", "n/a", "none", "invalid"].contains(lower) { return nil }
        return trimmed
    }

    /// Liest eine (vorzeichenbehaftete) Zahl am Anfang des Textes: „+010“, „15.0“, „-12 dots“ …
    static func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        var text = ""
        var negative = false
        var seenSign = false
        var seenDigit = false
        var seenDot = false
        for character in raw.replacingOccurrences(of: ",", with: ".") {
            if !seenDigit && !seenSign && (character == "-" || character == "+") {
                seenSign = true
                negative = character == "-"
                continue
            }
            if character.isASCII && character.isNumber {
                text.append(character)
                seenDigit = true
                continue
            }
            if character == "." && seenDigit && !seenDot {
                text.append(character)
                seenDot = true
                continue
            }
            if character == " " && !seenDigit { continue }
            break
        }
        guard seenDigit else { return nil }
        if text.hasSuffix(".") { text.removeLast() }
        guard let magnitude = Double(text) else { return nil }
        return negative ? -magnitude : magnitude
    }

    static func mediaType(from raw: String?) -> MediaType? {
        guard let text = raw?.lowercased() else { return nil }
        let compact = text.replacingOccurrences(of: " ", with: "")
        if compact == "dt" || text.contains("direct") { return .directThermal }
        if compact == "tt" || text.contains("trans") { return .thermalTransfer }
        return nil
    }

    static func tracking(from raw: String?) -> MediaTracking? {
        guard let text = raw?.lowercased() else { return nil }
        if text.contains("non-continuous") || text.contains("noncontinuous") || text.contains("non continuous") {
            return .gap
        }
        if text.contains("continuous") || text.contains("journal") { return .continuous }
        if text.contains("mark") || text.contains("black") || text == "bar" { return .blackMark }
        if text.contains("gap") || text.contains("notch") || text.contains("web") || text == "label" { return .gap }
        if text.contains("auto") { return .autoDetect }
        return nil
    }

    static func printMode(from raw: String?) -> PrintMode? {
        guard let text = raw?.lowercased() else { return nil }
        let compact = text.filter { $0.isLetter }
        if compact.count == 1, let mode = PrintMode(zplCode: compact) { return mode }
        if compact.contains("delayed") { return .delayedCut }
        if compact.contains("peel") { return .peelOff }
        if compact.contains("tear") { return .tearOff }
        if compact.contains("rewind") { return .rewind }
        if compact.contains("applicator") { return .applicator }
        if compact.contains("kiosk") { return .kiosk }
        if compact.contains("cut") { return .cutter }
        return nil
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

// MARK: - Profil (Import/Export)

/// Einstellungsprofil als JSON – zum Sichern oder Übertragen auf andere Macs/Drucker.
struct PrintPrefsProfile: Codable {
    static let formatIdentifier = "de.labelwerk.print-settings"

    var format: String
    var version: Int
    var exportedAt: Date
    var printerName: String?
    var modelID: String?
    var language: PrinterLanguage?
    var stockID: String?
    var settings: PrintSettings

    init(settings: PrintSettings, printerName: String?, modelID: String?, language: PrinterLanguage?, stockID: String?) {
        self.format = Self.formatIdentifier
        self.version = 1
        self.exportedAt = Date()
        self.printerName = printerName
        self.modelID = modelID
        self.language = language
        self.stockID = stockID
        self.settings = settings
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Liest ein Profil; akzeptiert auch reine `PrintSettings`-JSON-Dateien.
    static func decode(_ data: Data) throws -> PrintPrefsProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PrintPrefsProfile.self, from: data)
        } catch {
            if let settings = try? decoder.decode(PrintSettings.self, from: data) {
                return PrintPrefsProfile(settings: settings, printerName: nil, modelID: nil, language: nil, stockID: nil)
            }
            throw error
        }
    }
}

// MARK: - Musterbild (Rasterung & Auftragsgröße)

/// Erzeugt ein Graustufen-Musterbild: Tonwertverlauf, schattierte Kugel, textähnliche Zeilen und
/// einen echten Code-128-Barcode. Reine Berechnung – läuft im Hintergrund.
enum PrintPrefsArtwork {
    static func sample(width: Int, height: Int) -> GrayImage {
        let w = max(16, width)
        let h = max(16, height)
        var pixels = [UInt8](repeating: 255, count: w * h)

        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8) {
            let xa = max(0, min(w, x0))
            let xb = max(0, min(w, x1))
            let ya = max(0, min(h, y0))
            let yb = max(0, min(h, y1))
            guard xa < xb, ya < yb else { return }
            for row in ya..<yb {
                let offset = row * w
                for column in xa..<xb { pixels[offset + column] = value }
            }
        }

        let margin = max(2, w / 32)

        // 1. Horizontaler Tonwertverlauf (schwarz → weiß)
        let rampTop = margin
        // Bei sehr flachen, breiten Etiketten kann der Rand höher sein als das Etikett.
        let rampBottom = max(rampTop, min(h, margin + max(4, h * 18 / 100)))
        let rampWidth = max(1, w - 2 * margin)
        for row in rampTop..<rampBottom {
            let offset = row * w
            for column in margin..<(w - margin) {
                let t = Double(column - margin) / Double(rampWidth)
                pixels[offset + column] = UInt8(max(0, min(255, Int(t * 255))))
            }
        }

        // 2. Schattierte Kugel mit Kantenglättung
        let radius = Double(min(w, h)) * 0.21
        let cx = Double(w) * 0.25
        let cy = Double(h) * 0.56
        let lightX = cx - radius * 0.38
        let lightY = cy - radius * 0.42
        let yStart = max(0, Int(cy - radius) - 1)
        let yEnd = min(h, Int(cy + radius) + 2)
        let xStart = max(0, Int(cx - radius) - 1)
        let xEnd = min(w, Int(cx + radius) + 2)
        if yStart < yEnd && xStart < xEnd {
            for row in yStart..<yEnd {
                for column in xStart..<xEnd {
                    let dx = Double(column) + 0.5 - cx
                    let dy = Double(row) + 0.5 - cy
                    let distance = (dx * dx + dy * dy).squareRoot()
                    let coverage = max(0, min(1, radius - distance + 0.5))
                    if coverage <= 0 { continue }
                    let lx = Double(column) - lightX
                    let ly = Double(row) - lightY
                    let shade = max(0, min(1, (lx * lx + ly * ly).squareRoot() / (radius * 1.55)))
                    let tone = 250 - shade * 235
                    let index = row * w + column
                    let base = Double(pixels[index])
                    let mixed = base * (1 - coverage) + tone * coverage
                    pixels[index] = UInt8(max(0, min(255, Int(mixed.rounded()))))
                }
            }
        }

        // 3. Textähnliche Zeilen (Überschrift + Fließtext)
        let textLeft = Int(Double(w) * 0.52)
        let textRight = w - margin * 2
        let lineHeight = max(2, h * 4 / 100)
        var cursorY = max(rampBottom + lineHeight * 2, Int(Double(h) * 0.30))
        var seed: UInt32 = 0x5EED
        func nextRandom() -> Int {
            seed = seed &* 1_103_515_245 &+ 12_345
            return Int((seed >> 16) & 0x7FFF)
        }
        if textRight > textLeft {
            fill(textLeft, cursorY, textLeft + (textRight - textLeft) * 7 / 10, cursorY + lineHeight * 2, 0)
            cursorY += lineHeight * 3
            let textBottom = Int(Double(h) * 0.78)
            for line in 0..<7 {
                if cursorY + lineHeight >= textBottom { break }
                let lineEnd = line == 6 ? textLeft + (textRight - textLeft) / 2 : textRight
                var x = textLeft
                while x < lineEnd {
                    let word = lineHeight * (2 + nextRandom() % 6)
                    let end = min(lineEnd, x + word)
                    fill(x, cursorY, end, cursorY + lineHeight, 35)
                    x = end + lineHeight
                }
                cursorY += lineHeight * 2
            }
        }

        // 4. Code 128 unten
        let modules = PrintPrefsSampleCodes.barcodeModules
        if !modules.isEmpty {
            let available = max(1, w - margin * 4)
            let moduleWidth = max(1, available / (modules.count + 20))
            let total = moduleWidth * modules.count
            let left = (w - total) / 2
            let top = Int(Double(h) * 0.82)
            let bottom = h - margin
            for (index, dark) in modules.enumerated() where dark {
                fill(left + index * moduleWidth, top, left + (index + 1) * moduleWidth, bottom, 0)
            }
        }

        return GrayImage(width: w, height: h, pixels: pixels)
    }
}

// MARK: - Beispielcodes für Vorschauen

/// Echte Codes (Code 128 und QR) für Vorschau-Etiketten – einmalig berechnet.
enum PrintPrefsSampleCodes {
    static let barcodeModules: [Bool] = (try? BarcodeEncoder.code128("LABELWERK"))?.modules ?? []
    static let qrMatrix: BitMatrix? = try? BarcodeEncoder.qr("LabelWerk")

    /// Balken des Code 128, über `rect` verteilt; `widen` simuliert Punktzuwachs (zu hohe Schwärzung).
    static func barcodePath(in rect: CGRect, widen: CGFloat = 0) -> Path {
        var path = Path()
        let modules = barcodeModules
        guard !modules.isEmpty, rect.width > 0, rect.height > 0 else { return path }
        let module = rect.width / CGFloat(modules.count)
        var index = 0
        while index < modules.count {
            if modules[index] {
                var end = index
                while end < modules.count && modules[end] { end += 1 }
                let x = rect.minX + CGFloat(index) * module - widen / 2
                let width = max(0.3, CGFloat(end - index) * module + widen)
                path.addRect(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
                index = end
            } else {
                index += 1
            }
        }
        return path
    }

    /// QR-Code, quadratisch in `rect` zentriert.
    static func qrPath(in rect: CGRect) -> Path {
        var path = Path()
        guard let matrix = qrMatrix, matrix.width > 0, matrix.height > 0, rect.width > 0, rect.height > 0 else {
            return path
        }
        let side = min(rect.width, rect.height)
        let module = side / CGFloat(max(matrix.width, matrix.height))
        let originX = rect.midX - module * CGFloat(matrix.width) / 2
        let originY = rect.midY - module * CGFloat(matrix.height) / 2
        for y in 0..<matrix.height {
            for x in 0..<matrix.width where matrix[x, y] {
                path.addRect(CGRect(x: originX + CGFloat(x) * module, y: originY + CGFloat(y) * module,
                                    width: module + 0.02, height: module + 0.02))
            }
        }
        return path
    }
}

/// Code-128-Balken als animierbare Form (Punktzuwachs über `widen`).
struct PrintPrefsBarcodeShape: Shape {
    var widen: CGFloat

    var animatableData: CGFloat {
        get { widen }
        set { widen = newValue }
    }

    func path(in rect: CGRect) -> Path {
        PrintPrefsSampleCodes.barcodePath(in: rect, widen: widen)
    }
}

/// QR-Code als Form.
struct PrintPrefsQRShape: Shape {
    func path(in rect: CGRect) -> Path {
        PrintPrefsSampleCodes.qrPath(in: rect)
    }
}

/// Fehlstellen bei zu hellem Druck (deterministisch, damit nichts flimmert).
struct PrintPrefsSpeckleShape: Shape {
    /// 0 = keine Fehlstellen, 1 = sehr viele.
    var amount: Double

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = Int(max(0, min(1, amount)) * 260)
        guard count > 0, rect.width > 0, rect.height > 0 else { return path }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0xFFFF) / 65_535
        }
        for _ in 0..<count {
            let x = rect.minX + CGFloat(next()) * rect.width
            let y = rect.minY + CGFloat(next()) * rect.height
            let r = CGFloat(0.5 + next() * 1.3)
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        return path
    }
}

// MARK: - Symbole

/// SF-Symbole für Medien-, Modus- und Kategoriewerte (eigener Namensraum, keine Erweiterungen der
/// Kerntypen, damit es keine Namenskonflikte mit anderen Bereichen gibt).
enum PrintPrefsSymbols {
    static func symbol(for tracking: MediaTracking?) -> String {
        guard let tracking else { return "printer" }
        switch tracking {
        case .gap: return "square.split.1x2"
        case .blackMark: return "square.bottomhalf.filled"
        case .continuous: return "scroll"
        case .autoDetect: return "wand.and.stars"
        }
    }

    static func symbol(for type: MediaType?) -> String {
        guard let type else { return "printer" }
        switch type {
        case .directThermal: return "flame"
        case .thermalTransfer: return "film"
        }
    }

    static func symbol(for mode: PrintMode?) -> String {
        guard let mode else { return "printer" }
        switch mode {
        case .tearOff: return "hand.raised"
        case .peelOff: return "square.stack"
        case .cutter: return "scissors"
        case .delayedCut: return "timer"
        case .rewind: return "arrow.triangle.2.circlepath"
        case .applicator: return "hand.point.up.left"
        case .kiosk: return "display"
        }
    }

    static func symbol(for backfeed: BackfeedMode?) -> String {
        guard let backfeed else { return "printer" }
        switch backfeed {
        case .afterPrinting: return "arrow.uturn.backward"
        case .beforePrinting: return "arrow.uturn.forward"
        case .normal: return "arrow.left.arrow.right"
        case .off: return "nosign"
        }
    }

    static func symbol(for category: LabelStock.Category) -> String {
        switch category {
        case .shipping: return "shippingbox"
        case .product: return "tag"
        case .barcode: return "barcode"
        case .address: return "envelope"
        case .receipt: return "doc.plaintext"
        case .jewelry: return "sparkles"
        case .wristband: return "cross.case"
        case .custom: return "square.and.pencil"
        }
    }

    static func symbol(for language: PrinterLanguage) -> String {
        switch language {
        case .zpl: return "chevron.left.forwardslash.chevron.right"
        case .epl: return "text.alignleft"
        case .cpcl: return "doc.text"
        }
    }
}

// MARK: - Formatierung

enum PrintPrefsFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Millimeter mit Vorzeichen, z. B. „+2,5“ bzw. „−1,3“.
    static func signed(_ value: Double, digits: Int = 1) -> String {
        let rounded = (value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        if rounded > 0 { return "+" + number(rounded, digits: digits) }
        if rounded < 0 { return "−" + number(-rounded, digits: digits) }
        return number(0, digits: digits)
    }

    static func signedInt(_ value: Int) -> String {
        if value > 0 { return "+\(value)" }
        if value < 0 { return "−\(-value)" }
        return "0"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Fließlayout

/// Ordnet Elemente zeilenweise an und bricht bei Platzmangel um (Chips, Filter).
struct PrintPrefsFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Auswahl-Chips

/// Auswahl als Chips mit gleitender Markierung (`matchedGeometryEffect`) und hüpfenden Symbolen.
struct PrintPrefsChoiceStrip<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let systemImage: (Value) -> String

    @Namespace private var namespace
    @State private var hovered: Value?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String,
         systemImage: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
        self.systemImage = systemImage
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(options, id: \.self) { option in
                chip(option)
            }
        }
    }

    private func chip(_ option: Value) -> some View {
        let isSelected = option == selection
        let isHovered = hovered == option
        return Button {
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                selection = option
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage(option))
                    .font(.system(size: 11.5, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                Text(title(option))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(isHovered ? 0.95 : 0.75))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else {
                    Capsule()
                        .fill(Theme.subtleFill.opacity(isHovered ? 2 : 1))
                        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                if inside {
                    hovered = option
                } else if hovered == option {
                    hovered = nil
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Hinweise & Effekte

/// Kurzer Erklärtext mit Symbol.
struct PrintPrefsHint: View {
    let text: String
    var systemImage: String = "info.circle"
    var tint: Color = Color.secondary

    init(_ text: String, systemImage: String = "info.circle", tint: Color = Color.secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .font(.system(size: 11.5))
    }
}

/// Lässt ein Steuerelement kurz aufleuchten, wenn sich `token` ändert (z. B. nach „Vom Drucker lesen“).
struct PrintPrefsPulse: ViewModifier {
    let token: Int
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: token) { view, glow in
                view
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Theme.teal.opacity(0.14 * glow))
                            .padding(-6)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.teal.opacity(0.9 * glow), lineWidth: 1.5)
                            .padding(-6)
                    }
            } keyframes: { _ in
                CubicKeyframe(1.0, duration: 0.25)
                CubicKeyframe(1.0, duration: 0.7)
                CubicKeyframe(0.0, duration: 0.9)
            }
    }
}

/// Gestaffeltes Einblenden von Karten.
struct PrintPrefsAppear: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 18)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985, anchor: .top)
            .animation(Motion.animation(Motion.spring.delay(Double(index) * 0.06), reduceMotion: reduceMotion),
                       value: appeared)
    }
}

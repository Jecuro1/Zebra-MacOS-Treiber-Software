import Foundation

// MARK: - Geometrie

/// Etikettengeometrie in Druckpunkten – Grundlage für Vorlagen und eingefügte Elemente.
///
/// Bewusst nur aus Ganzzahlen aufgebaut (keine App-Typen), damit Vorlagen deterministisch und
/// unabhängig von der Oberfläche erzeugt werden können.
struct DesignerLabelGeometry: Hashable, Sendable {
    var widthDots: Int
    var heightDots: Int
    var dotsPerMM: Int

    init(widthDots: Int, heightDots: Int, dotsPerMM: Int) {
        self.widthDots = max(32, widthDots)
        self.heightDots = max(32, heightDots)
        self.dotsPerMM = max(1, dotsPerMM)
    }

    /// Millimeter → Druckpunkte (gerundet).
    func dots(_ mm: Double) -> Int { Int((mm * Double(dotsPerMM)).rounded()) }

    /// Druckpunkte → Millimeter.
    func mm(_ dots: Int) -> Double { Double(dots) / Double(dotsPerMM) }

    var shortSide: Int { min(widthDots, heightDots) }
    var isLandscape: Bool { widthDots >= heightDots }
    var widthMM: Double { mm(widthDots) }
    var heightMM: Double { mm(heightDots) }

    /// Nominelle Auflösung in dpi.
    var dpi: Int {
        switch dotsPerMM {
        case 6: return 152
        case 8: return 203
        case 12: return 300
        case 24: return 600
        default: return Int((Double(dotsPerMM) * 25.4).rounded())
        }
    }

    /// Einheitlicher Sicherheitsrand für Vorlagen.
    var margin: Int { max(dots(1.5), shortSide / 28) }
}

// MARK: - ZPL-Schreiber

/// Erzeugt sauber formatierte ZPL-Befehle (ein Feld pro Zeile) für Vorlagen und Bausteine.
///
/// Alle Texte laufen über `fieldData(_:)`, das Steuerzeichen (`^`, `~`, `\`) per `^FH` maskiert.
/// Umlaute werden als UTF-8 übertragen (`^CI28` im Formatkopf).
struct DesignerZPLBuilder {
    let geometry: DesignerLabelGeometry
    private(set) var commands: [String] = []

    init(geometry: DesignerLabelGeometry) {
        self.geometry = geometry
    }

    // MARK: Maße & Hilfen

    static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), max(lower, upper))
    }

    /// Geschätzte Breite eines Textes in Schrift 0 (CG Triumvirate Bold Condensed) bei Höhe `height`.
    /// Bewusst großzügig, damit eingepasste Texte nie über den Rand laufen.
    static func estimatedWidth(_ text: String, height: Int) -> Int {
        var units = 0.0
        for character in text {
            if character == " " {
                units += 0.3
            } else if "iIl.,:;|!'·".contains(character) {
                units += 0.3
            } else if "mwMW@%€".contains(character) {
                units += 0.85
            } else if character.isUppercase || character.isNumber {
                units += 0.62
            } else {
                units += 0.54
            }
        }
        return Int((units * Double(max(1, height))).rounded(.up))
    }

    /// Größte Texthöhe ≤ `preferred`, bei der `text` in `maxWidth` passt (mindestens `minimum`).
    static func fittedHeight(_ text: String, maxWidth: Int, preferred: Int, minimum: Int = 10) -> Int {
        let preferred = max(minimum, preferred)
        let natural = estimatedWidth(text, height: preferred)
        guard natural > maxWidth, natural > 0 else { return preferred }
        let scaled = Int(Double(preferred) * Double(max(1, maxWidth)) / Double(natural))
        return max(minimum, scaled)
    }

    /// Höhe der Klarschriftzeile unter linearen Barcodes.
    static func interpretationHeight(module: Int) -> Int { max(14, module * 10) }

    /// Moduleinheiten eines Code 128 (Zeichensatz B): Start + Daten + Prüfzeichen + Stopp.
    static func code128Modules(_ data: String) -> Int { 11 * data.count + 35 }

    /// Moduleinheiten eines Code 39 (Verhältnis 3:1) inkl. Start/Stopp und Zwischenräumen.
    static func code39Modules(_ data: String) -> Int { 16 * (data.count + 2) - 1 }

    /// Moduleinheiten eines Interleaved 2 of 5 (Verhältnis 3:1).
    static func interleavedModules(_ digits: String) -> Int { 9 * digits.count + 9 }

    /// Kantenlänge (Module) eines QR-Codes im Bytemodus für die Fehlerkorrektur `ecc`.
    static func qrModules(_ data: String, ecc: String = "M") -> Int {
        let capacities: [Int]
        switch ecc {
        case "L": capacities = [17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458, 520]
        case "Q": capacities = [11, 20, 32, 46, 60, 74, 86, 108, 130, 151, 177, 203, 241, 258, 292]
        case "H": capacities = [7, 14, 24, 34, 44, 58, 64, 84, 98, 119, 137, 155, 177, 194, 220]
        default: capacities = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412]
        }
        let length = data.utf8.count
        let version = (capacities.firstIndex { $0 >= length } ?? capacities.count) + 1
        return 17 + 4 * version
    }

    /// Kantenlänge (Module) eines quadratischen DataMatrix-Symbols (ECC 200, ASCII-Kodierung).
    static func dataMatrixModules(_ data: String) -> Int {
        // Ziffernpaare belegen ein Codewort, alle anderen Zeichen eins (Erweiterte ASCII: zwei).
        var codewords = 0
        var pendingDigit = false
        for scalar in data.unicodeScalars {
            if scalar.value >= 48 && scalar.value <= 57 {
                if pendingDigit { pendingDigit = false } else { pendingDigit = true; codewords += 1 }
            } else {
                pendingDigit = false
                codewords += scalar.value > 127 ? 2 : 1
            }
        }
        let sizes: [(size: Int, capacity: Int)] = [
            (10, 3), (12, 5), (14, 8), (16, 12), (18, 18), (20, 22), (22, 30), (24, 36),
            (26, 44), (32, 62), (36, 86), (40, 114), (44, 144), (48, 174), (52, 204),
        ]
        return sizes.first { $0.capacity >= codewords }?.size ?? 64
    }

    /// Maskiert Felddaten für `^FD`. Enthält der Text Steuerzeichen, wird `^FH` vorangestellt.
    static func fieldData(_ text: String) -> String {
        let clean = singleLine(text)
        guard clean.contains(where: { $0 == "^" || $0 == "~" || $0 == "\\" }) else { return "^FD" + clean }
        return "^FH^FD" + escapeHex(clean)
    }

    /// Mehrzeilige Felddaten für `^FB` (Zeilenumbruch `\&`).
    static func blockData(_ lines: [String]) -> String {
        let clean = lines.map(singleLine)
        let needsHex = clean.contains { line in line.contains(where: { $0 == "^" || $0 == "~" || $0 == "\\" }) }
        if needsHex {
            return "^FH^FD" + clean.map(escapeHex).joined(separator: "\\&")
        }
        return "^FD" + clean.joined(separator: "\\&")
    }

    /// Ersetzt Zeilenumbrüche (auch das Graphem „\r\n“) durch Leerzeichen.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func escapeHex(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "_": escaped += "_5F"
            case "^": escaped += "_5E"
            case "~": escaped += "_7E"
            case "\\": escaped += "_5C"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Kommentartext ohne Steuerzeichen (ein `^FX` endet am nächsten `^`).
    static func sanitizedComment(_ text: String) -> String {
        singleLine(text)
            .replacingOccurrences(of: "^", with: " ")
            .replacingOccurrences(of: "~", with: " ")
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Y" : "N" }

    // MARK: Befehle

    mutating func raw(_ command: String) {
        commands.append(command)
    }

    mutating func comment(_ text: String) {
        commands.append("^FX " + Self.sanitizedComment(text))
    }

    /// Einzeiliger Text in Schrift 0 (linke obere Ecke).
    mutating func text(_ text: String, x: Int, y: Int, height: Int, width: Int? = nil, reverse: Bool = false) {
        let h = max(8, height)
        let w = max(8, width ?? h)
        commands.append("^FO\(max(0, x)),\(max(0, y))^A0N,\(h),\(w)" + (reverse ? "^FR" : "") + Self.fieldData(text) + "^FS")
    }

    /// Textblock (`^FB`) mit Ausrichtung `L`, `C`, `R` oder `J`.
    mutating func block(_ lines: [String], x: Int, y: Int, width: Int, height: Int, lineSpacing: Int = 0,
                        justification: String = "L", reverse: Bool = false) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^A0N,\(h),\(h)^FB\(max(1, width)),\(max(1, lines.count)),\(lineSpacing),\(justification),0"
                        + (reverse ? "^FR" : "") + Self.blockData(lines) + "^FS")
    }

    /// Rahmen (`^GB`); bei `thickness ≥ min(width, height)` gefüllt.
    mutating func box(x: Int, y: Int, width: Int, height: Int, thickness: Int, color: String = "B", rounding: Int = 0) {
        let t = max(1, thickness)
        let w = max(width, t), h = max(height, t)
        commands.append("^FO\(max(0, x)),\(max(0, y))^GB\(w),\(h),\(t),\(color),\(min(8, max(0, rounding)))^FS")
    }

    /// Gefüllte Fläche.
    mutating func fill(x: Int, y: Int, width: Int, height: Int, rounding: Int = 0) {
        box(x: x, y: y, width: max(1, width), height: max(1, height), thickness: max(1, min(width, height)), rounding: rounding)
    }

    mutating func horizontalLine(x: Int, y: Int, length: Int, thickness: Int) {
        box(x: x, y: y, width: max(1, length), height: max(1, thickness), thickness: max(1, thickness))
    }

    mutating func verticalLine(x: Int, y: Int, length: Int, thickness: Int) {
        box(x: x, y: y, width: max(1, thickness), height: max(1, length), thickness: max(1, thickness))
    }

    mutating func circle(x: Int, y: Int, diameter: Int, thickness: Int, color: String = "B") {
        let d = max(3, diameter)
        commands.append("^FO\(max(0, x)),\(max(0, y))^GC\(d),\(min(d, max(1, thickness))),\(color)^FS")
    }

    mutating func ellipse(x: Int, y: Int, width: Int, height: Int, thickness: Int) {
        commands.append("^FO\(max(0, x)),\(max(0, y))^GE\(max(3, width)),\(max(3, height)),\(max(1, thickness)),B^FS")
    }

    mutating func diagonal(x: Int, y: Int, width: Int, height: Int, thickness: Int, leansRight: Bool) {
        commands.append("^FO\(max(0, x)),\(max(0, y))^GD\(max(3, width)),\(max(3, height)),\(max(1, thickness)),B,\(leansRight ? "R" : "L")^FS")
    }

    /// Ausgefüllter Pfeil nach oben (Spitze aus gestaffelten Balken, Schaft als Fläche).
    mutating func arrowUp(x: Int, y: Int, width: Int, height: Int) {
        let headHeight = max(4, height * 46 / 100)
        let rows = Self.clamp(headHeight / max(2, geometry.dots(0.3)), 6, 40)
        let rowHeight = max(1, (headHeight + rows - 1) / rows)
        for row in 0..<rows {
            let rowWidth = max(2, width * (row + 1) / rows)
            fill(x: x + (width - rowWidth) / 2, y: y + row * rowHeight, width: rowWidth, height: rowHeight + 1)
        }
        let shaftWidth = max(2, width * 38 / 100)
        let shaftTop = y + rows * rowHeight
        fill(x: x + (width - shaftWidth) / 2, y: shaftTop, width: shaftWidth, height: max(2, y + height - shaftTop))
    }

    // MARK: Barcodes

    mutating func code128(_ data: String, x: Int, y: Int, height: Int, module: Int, interpretation: Bool = true) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module)),3,\(h)^BCN,\(h),\(Self.yesNo(interpretation)),N,N"
                        + Self.fieldData(data) + "^FS")
    }

    mutating func code39(_ data: String, x: Int, y: Int, height: Int, module: Int, interpretation: Bool = true) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module)),3,\(h)^B3N,N,\(h),\(Self.yesNo(interpretation)),N"
                        + Self.fieldData(data) + "^FS")
    }

    /// EAN-13 aus 12 Ziffern (die Prüfziffer berechnet der Drucker).
    mutating func ean13(_ digits: String, x: Int, y: Int, height: Int, module: Int) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module))^BEN,\(h),Y,N" + Self.fieldData(digits) + "^FS")
    }

    mutating func ean8(_ digits: String, x: Int, y: Int, height: Int, module: Int) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module))^B8N,\(h),Y,N" + Self.fieldData(digits) + "^FS")
    }

    mutating func upcA(_ digits: String, x: Int, y: Int, height: Int, module: Int) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module))^BUN,\(h),Y,N,Y" + Self.fieldData(digits) + "^FS")
    }

    mutating func interleaved2of5(_ digits: String, x: Int, y: Int, height: Int, module: Int) {
        let h = max(8, height)
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module)),3,\(h)^B2N,\(h),Y,N,N" + Self.fieldData(digits) + "^FS")
    }

    /// QR-Code (Modell 2) mit automatischer Kodierung.
    mutating func qr(_ data: String, x: Int, y: Int, magnification: Int, ecc: String = "M") {
        commands.append("^FO\(max(0, x)),\(max(0, y))^BQN,2,\(Self.clamp(magnification, 1, 10))"
                        + Self.fieldData("\(ecc)A," + data) + "^FS")
    }

    mutating func dataMatrix(_ data: String, x: Int, y: Int, module: Int) {
        commands.append("^FO\(max(0, x)),\(max(0, y))^BXN,\(Self.clamp(module, 1, 12)),200" + Self.fieldData(data) + "^FS")
    }

    mutating func pdf417(_ data: String, x: Int, y: Int, module: Int, rowHeight: Int, columns: Int = 3, security: Int = 2) {
        commands.append("^FO\(max(0, x)),\(max(0, y))^BY\(max(1, module))^B7N,\(max(2, rowHeight)),\(security),\(columns),,N"
                        + Self.fieldData(data) + "^FS")
    }

    // MARK: Textstapel

    /// Verteilt Textzeilen proportional zu ihrem Gewicht auf eine Fläche und passt jede Zeile in
    /// die Breite ein. Ausrichtung `L`, `C` oder `R`.
    mutating func textStack(_ items: [(text: String, weight: Double)], x: Int, y: Int, width: Int, height: Int,
                            justification: String = "L", spacing: Double = 0.24, reverse: Bool = false, minimum: Int = 10) {
        guard !items.isEmpty, height > 0, width > 0 else { return }
        let total = items.enumerated().reduce(0.0) { sum, entry in
            sum + entry.element.weight * (entry.offset == items.count - 1 ? 1 : 1 + spacing)
        }
        let unit = Double(height) / max(total, 0.001)
        var cursor = Double(y)
        for item in items {
            let slot = unit * item.weight
            let preferred = Int(slot.rounded(.down))
            let h = Self.fittedHeight(item.text, maxWidth: width, preferred: preferred, minimum: minimum)
            if !item.text.isEmpty {
                // Bei verkleinerter Schrift vertikal im Slot zentrieren.
                let top = Int(cursor) + max(0, (preferred - h) / 2)
                if justification == "L" {
                    text(item.text, x: x, y: top, height: h, reverse: reverse)
                } else {
                    block([item.text], x: x, y: top, width: width, height: h, justification: justification, reverse: reverse)
                }
            }
            cursor += slot * (1 + spacing)
        }
    }

    // MARK: Format

    /// Vollständiges Format `^XA … ^XZ` mit UTF-8, Etikettengröße und Ursprung.
    func document(title: String) -> String {
        var lines = [
            "^XA",
            "^CI28",
            "^FX " + Self.sanitizedComment(title),
            "^PW\(geometry.widthDots)",
            "^LL\(geometry.heightDots)",
            "^LH0,0",
        ]
        lines.append(contentsOf: commands)
        lines.append("^XZ")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Bausteine zum Einfügen

/// Elemente des Menüs „Einfügen“. Jedes erzeugt ein kommentiertes ZPL-Feld, das an einer freien
/// Position (gestaffelt nach Anzahl vorhandener Felder) innerhalb des Etiketts platziert wird.
enum DesignerSnippet: String, CaseIterable, Identifiable {
    case text, textBlock, reverseText, box, line, circle, ellipse, diagonal
    case code128, code39, ean13, qrCode, dataMatrix, pdf417

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return tr("Text")
        case .textBlock: return tr("Textblock (mehrzeilig)")
        case .reverseText: return tr("Weiß auf Schwarz")
        case .box: return tr("Rahmen")
        case .line: return tr("Linie")
        case .circle: return tr("Kreis")
        case .ellipse: return tr("Ellipse")
        case .diagonal: return tr("Diagonale")
        case .code128: return tr("Code 128")
        case .code39: return tr("Code 39")
        case .ean13: return tr("EAN-13")
        case .qrCode: return tr("QR-Code")
        case .dataMatrix: return tr("DataMatrix")
        case .pdf417: return tr("PDF417")
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .textBlock: return "text.alignleft"
        case .reverseText: return "character.textbox"
        case .box: return "rectangle"
        case .line: return "line.horizontal.3"
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .diagonal: return "line.diagonal"
        case .code128, .code39, .ean13: return "barcode"
        case .qrCode: return "qrcode"
        case .dataMatrix: return "square.grid.3x3"
        case .pdf417: return "rectangle.split.3x3"
        }
    }

    /// Gruppe im Menü.
    var isBarcode: Bool {
        switch self {
        case .code128, .code39, .ean13, .qrCode, .dataMatrix, .pdf417: return true
        default: return false
        }
    }

    /// ZPL des Bausteins. `slot` staffelt die Position (z. B. Anzahl vorhandener `^FO`).
    func zpl(geometry g: DesignerLabelGeometry, slot: Int) -> String {
        var b = DesignerZPLBuilder(geometry: g)
        let m = g.margin
        let available = g.widthDots - 2 * m
        let x = m + (slot % 4) * g.dots(2)
        let usableWidth = max(g.dots(10), g.widthDots - m - x)
        let step = max(g.dots(4), g.heightDots / 12)
        /// Oberkante so wählen, dass ein Element der Höhe `height` vollständig auf das Etikett passt.
        func top(_ height: Int) -> Int {
            let wanted = m + (slot % 9) * step
            return max(m, min(wanted, g.heightDots - m - height))
        }
        b.comment(title)
        switch self {
        case .text:
            let content = tr("Neuer Text")
            let h = DesignerZPLBuilder.fittedHeight(content, maxWidth: usableWidth,
                                                    preferred: DesignerZPLBuilder.clamp(g.dots(5), 16, g.shortSide / 5))
            b.text(content, x: x, y: top(h), height: h)
        case .textBlock:
            let h = DesignerZPLBuilder.clamp(g.dots(3.5), 14, g.shortSide / 8)
            let lines = [tr("Erste Zeile"), tr("Zweite Zeile"), tr("Dritte Zeile")]
            let spacing = h / 4
            b.block(lines, x: x, y: top(3 * h + 2 * spacing), width: usableWidth, height: h, lineSpacing: spacing,
                    justification: "C")
        case .reverseText:
            let content = tr("HINWEIS")
            let h = DesignerZPLBuilder.clamp(g.dots(4.5), 16, g.shortSide / 6)
            let pad = max(4, h / 3)
            let w = min(usableWidth, DesignerZPLBuilder.estimatedWidth(content, height: h) + 2 * pad)
            let y = top(h + 2 * pad)
            b.fill(x: x, y: y, width: w, height: h + 2 * pad, rounding: 2)
            b.block([content], x: x, y: y + pad, width: w, height: h, justification: "C", reverse: true)
        case .box:
            let w = min(usableWidth, g.dots(40))
            let h = min(g.heightDots - 2 * m, g.dots(20))
            b.box(x: x, y: top(h), width: w, height: h, thickness: max(2, g.dots(0.5)), rounding: 2)
        case .line:
            let t = max(2, g.dots(0.4))
            b.horizontalLine(x: x, y: top(t), length: usableWidth, thickness: t)
        case .circle:
            let d = min(g.dots(20), g.shortSide / 3)
            b.circle(x: x, y: top(d), diameter: d, thickness: max(2, g.dots(0.6)))
        case .ellipse:
            let w = min(usableWidth, g.dots(30))
            let h = min(g.heightDots - 2 * m, g.dots(15))
            b.ellipse(x: x, y: top(h), width: w, height: h, thickness: max(2, g.dots(0.6)))
        case .diagonal:
            let w = min(usableWidth, g.dots(30))
            let h = min(g.heightDots - 2 * m, g.dots(15))
            b.diagonal(x: x, y: top(h), width: w, height: h, thickness: max(2, g.dots(0.6)), leansRight: true)
        case .code128:
            let data = "LW-12345678"
            let module = DesignerZPLBuilder.clamp(usableWidth / DesignerZPLBuilder.code128Modules(data), 1, 3)
            let h = DesignerZPLBuilder.clamp(g.dots(12), 24, g.heightDots / 4)
            b.code128(data, x: x, y: top(h + DesignerZPLBuilder.interpretationHeight(module: module)), height: h, module: module)
        case .code39:
            let data = "LW39"
            let module = DesignerZPLBuilder.clamp(usableWidth / DesignerZPLBuilder.code39Modules(data), 1, 3)
            let h = DesignerZPLBuilder.clamp(g.dots(12), 24, g.heightDots / 4)
            b.code39(data, x: x, y: top(h + DesignerZPLBuilder.interpretationHeight(module: module)), height: h, module: module)
        case .ean13:
            let module = DesignerZPLBuilder.clamp(available / 110, 1, 3)
            let h = DesignerZPLBuilder.clamp(g.dots(15), 30, g.heightDots / 3)
            b.ean13("400638133393", x: x + 9 * module, y: top(h + DesignerZPLBuilder.interpretationHeight(module: module)),
                    height: h, module: module)
        case .qrCode:
            let data = "https://example.com"
            let modules = DesignerZPLBuilder.qrModules(data)
            let magnification = DesignerZPLBuilder.clamp(min(g.dots(20), g.shortSide / 2) / modules, 1, 10)
            b.qr(data, x: x, y: top((modules + 2) * magnification), magnification: magnification)
        case .dataMatrix:
            let data = "LabelWerk"
            let modules = DesignerZPLBuilder.dataMatrixModules(data)
            let module = DesignerZPLBuilder.clamp(min(g.dots(12), g.shortSide / 3) / modules, 1, 12)
            b.dataMatrix(data, x: x, y: top(modules * module), module: module)
        case .pdf417:
            let module = DesignerZPLBuilder.clamp(usableWidth / 160, 1, 3)
            let rowHeight = module * 3
            b.pdf417("LabelWerk PDF417", x: x, y: top(rowHeight * 10), module: module, rowHeight: rowHeight)
        }
        return b.commands.joined(separator: "\n")
    }
}

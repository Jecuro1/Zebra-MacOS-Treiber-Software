import Foundation

// MARK: - Symbologie

/// Alle Barcode-Symbologien, die LabelWerk selbst erzeugen kann.
///
/// Die Rohwerte sind stabil und werden in Dokumenten (JSON) gespeichert.
public enum BarcodeSymbology: String, Codable, CaseIterable, Sendable {
    case code128, code39, code93, ean13, ean8, upcA, upcE, interleaved2of5, codabar, qr, dataMatrix, pdf417

    /// Deutscher Anzeigename für die Oberfläche.
    public var displayName: String {
        switch self {
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .code93: return "Code 93"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upcA: return "UPC-A"
        case .upcE: return "UPC-E"
        case .interleaved2of5: return "Interleaved 2 of 5"
        case .codabar: return "Codabar"
        case .qr: return "QR-Code"
        case .dataMatrix: return "Data Matrix"
        case .pdf417: return "PDF417"
        }
    }

    /// `true` für zweidimensionale Symbologien (QR-Code, Data Matrix, PDF417).
    public var isTwoDimensional: Bool {
        switch self {
        case .qr, .dataMatrix, .pdf417: return true
        default: return false
        }
    }
}

// MARK: - Lineare Barcodes

/// Ein eindimensionaler Barcode als Folge von Balken und Lücken.
///
/// `elements` beginnt immer mit einem Balken und endet mit einem Balken; Ruhezonen sind
/// **nicht** enthalten. Bei Einbreiten-Codes (Code 128, Code 93, EAN/UPC) ist `width` die
/// Breite in Moduln (1…4), bei Zweibreiten-Codes (Code 39, Interleaved 2 of 5, Codabar)
/// bedeutet `width == 1` „schmal“ und `width == 2` „breit“.
public struct LinearBarcode: Hashable, Sendable {

    /// Ein einzelner Balken oder eine einzelne Lücke.
    public struct Element: Hashable, Sendable {
        /// `true` = Balken (schwarz), `false` = Lücke (weiß).
        public var isBar: Bool
        /// Breite in Moduleinheiten (bei Zweibreiten-Codes: 1 = schmal, 2 = breit).
        public var width: Int
        /// Gehört das Element zu einem Begrenzungszeichen (Rand-/Mittelzeichen bei EAN/UPC)?
        /// Solche Balken werden bei Klarschrift traditionell nach unten verlängert.
        public var isGuard: Bool

        public init(isBar: Bool, width: Int, isGuard: Bool = false) {
            self.isBar = isBar
            self.width = width
            self.isGuard = isGuard
        }
    }

    /// Balken und Lücken von links nach rechts, beginnt mit einem Balken, ohne Ruhezonen.
    public var elements: [Element]
    /// Klarschriftzeile (inklusive berechneter Prüfziffern, sofern die Symbologie sie anzeigt).
    public var humanReadable: String
    /// `true` für Zweibreiten-Codes (Code 39, Interleaved 2 of 5, Codabar).
    public var isTwoWidth: Bool

    public init(elements: [Element], humanReadable: String, isTwoWidth: Bool) {
        self.elements = elements
        self.humanReadable = humanReadable
        self.isTwoWidth = isTwoWidth
    }

    /// Kleinstes und größtes zulässiges Breitenverhältnis (wie ZPL `^BY`).
    public static let ratioRange: ClosedRange<Double> = 2.0...3.0

    /// Breite eines breiten Elements in Punkten bei Zweibreiten-Codes.
    ///
    /// Das Verhältnis wird auf 2,0…3,0 begrenzt (wie bei ZPL `^BY`) und kaufmännisch gerundet;
    /// ein breites Element ist stets mindestens einen Punkt breiter als ein schmales.
    public static func wideDots(moduleWidth: Int, ratio: Double) -> Int {
        let narrow = max(1, moduleWidth)
        let r = ratio.isFinite ? min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound) : 3.0
        let wide = Int((Double(narrow) * r).rounded(.toNearestOrAwayFromZero))
        return max(narrow + 1, wide)
    }

    /// Breiten aller Elemente in Druckerpunkten.
    ///
    /// - Parameters:
    ///   - moduleWidth: Modulbreite (schmales Element) in Punkten, mindestens 1.
    ///   - ratio: Verhältnis breit : schmal; nur für Zweibreiten-Codes relevant (2,0…3,0).
    public func widthsInDots(moduleWidth: Int, ratio: Double) -> [(isBar: Bool, dots: Int)] {
        let narrow = max(1, moduleWidth)
        if isTwoWidth {
            let wide = LinearBarcode.wideDots(moduleWidth: narrow, ratio: ratio)
            return elements.map { ($0.isBar, $0.width >= 2 ? wide : narrow) }
        }
        return elements.map { ($0.isBar, max(1, $0.width) * narrow) }
    }

    /// Gesamtbreite des Symbols (ohne Ruhezonen) in Druckerpunkten.
    public func totalWidth(moduleWidth: Int, ratio: Double) -> Int {
        widthsInDots(moduleWidth: moduleWidth, ratio: ratio).reduce(0) { $0 + $1.dots }
    }

    /// Das Symbol als Modulfolge (`true` = Balken).
    ///
    /// Nur für Einbreiten-Codes aussagekräftig; bei Zweibreiten-Codes wird jedes Element mit
    /// seinem gespeicherten Wert (1 bzw. 2 Module) expandiert, also ein Verhältnis von 2 : 1.
    public var modules: [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(elements.reduce(0) { $0 + $1.width })
        for element in elements {
            result.append(contentsOf: repeatElement(element.isBar, count: max(0, element.width)))
        }
        return result
    }

    /// Anzahl der Module (Summe aller Elementbreiten).
    public var moduleCount: Int { elements.reduce(0) { $0 + $1.width } }
}

// MARK: - 2D-Matrix

/// Eine rechteckige Matrix aus hellen und dunklen Modulen (QR-Code, Data Matrix, PDF417).
///
/// Die Bits liegen zeilenweise vor, `true` bedeutet dunkel. Ruhezonen sind nicht enthalten.
public struct BitMatrix: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Zeilenweise Moduldaten, `bits.count == width * height`, `true` = dunkel.
    public var bits: [Bool]

    /// Erzeugt eine vollständig helle Matrix.
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "BitMatrix: negative Abmessungen")
        self.width = width
        self.height = height
        self.bits = Array(repeating: false, count: width * height)
    }

    /// Erzeugt eine Matrix aus vorhandenen Bits (zeilenweise, `true` = dunkel).
    public init(width: Int, height: Int, bits: [Bool]) {
        precondition(width >= 0 && height >= 0, "BitMatrix: negative Abmessungen")
        precondition(bits.count == width * height, "BitMatrix: Bitanzahl passt nicht zu den Abmessungen")
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// Zugriff auf das Modul in Spalte `x`, Zeile `y` (0-basiert, Ursprung links oben).
    public subscript(x: Int, y: Int) -> Bool {
        get {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "BitMatrix: Index außerhalb")
            return bits[y * width + x]
        }
        set {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "BitMatrix: Index außerhalb")
            bits[y * width + x] = newValue
        }
    }

    /// Anzahl der dunklen Module.
    public var darkCount: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }
}

extension BitMatrix: CustomStringConvertible {
    /// Textdarstellung: eine Zeile je Matrixzeile, `#` = dunkel, `.` = hell, getrennt durch `\n`.
    public var description: String {
        var lines: [String] = []
        lines.reserveCapacity(height)
        for y in 0..<height {
            var line = ""
            line.reserveCapacity(width)
            for x in 0..<width { line.append(bits[y * width + x] ? "#" : ".") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Optionen

/// Fehlerkorrekturstufe eines QR-Codes (Anteil rekonstruierbarer Codewörter).
public enum QRErrorCorrection: String, Sendable, CaseIterable {
    /// ca. 7 %
    case low = "L"
    /// ca. 15 %
    case medium = "M"
    /// ca. 25 %
    case quartile = "Q"
    /// ca. 30 %
    case high = "H"
}

/// Zeichensatzwahl für Code 128.
public enum Code128Mode: Sendable {
    /// Automatische, codewortminimale Wahl und Umschaltung der Zeichensätze A/B/C.
    case auto
    /// Ausschließlich Zeichensatz A (Großbuchstaben, Ziffern, Steuerzeichen; Einzelzeichen aus B per SHIFT).
    case subsetA
    /// Ausschließlich Zeichensatz B (druckbares ASCII; Einzelzeichen aus A per SHIFT).
    case subsetB
    /// Ausschließlich Zeichensatz C (Ziffernpaare; gerade Ziffernanzahl erforderlich).
    case subsetC
    /// GS1-128 (früher UCC/EAN-128): FNC1 nach dem Startzeichen, Datenbezeichner in Klammern.
    case ucc
}

// MARK: - Fehler

/// Fehler beim Erzeugen eines Barcodes.
public enum BarcodeError: Error, Equatable {
    /// Das Zeichen ist in der Symbologie nicht darstellbar (bzw. eine Prüfziffer ist falsch).
    case invalidCharacter(Character)
    /// Die Datenlänge ist für die Symbologie unzulässig.
    case invalidLength(Int)
    /// Die Daten passen in kein Symbol der Symbologie.
    case dataTooLong
    /// Parameterkombination oder Funktion wird nicht unterstützt.
    case unsupported(String)
}

extension BarcodeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCharacter(let character):
            let scalars = character.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            return "Ungültiges Zeichen „\(character.isPrintableForMessage ? String(character) : "?")“ (\(scalars)) für diese Barcode-Art."
        case .invalidLength(let length):
            return "Ungültige Datenlänge (\(length) Zeichen) für diese Barcode-Art."
        case .dataTooLong:
            return "Die Daten sind zu lang für diese Barcode-Art."
        case .unsupported(let message):
            return "Nicht unterstützt: \(message)"
        }
    }
}

extension Character {
    /// Kann das Zeichen gefahrlos in einer Fehlermeldung angezeigt werden?
    fileprivate var isPrintableForMessage: Bool {
        !unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

// MARK: - Vereinheitlichter Barcode

/// Ergebnis von `BarcodeEncoder.encode(_:as:)`: entweder ein linearer Code oder eine 2D-Matrix.
public enum Barcode: Hashable, Sendable {
    case linear(LinearBarcode)
    case matrix(BitMatrix)

    /// Der lineare Barcode, falls vorhanden.
    public var linearBarcode: LinearBarcode? {
        if case .linear(let barcode) = self { return barcode }
        return nil
    }

    /// Die 2D-Matrix, falls vorhanden.
    public var bitMatrix: BitMatrix? {
        if case .matrix(let matrix) = self { return matrix }
        return nil
    }
}

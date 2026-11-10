import Foundation
import LabelWerkBarcode
import LabelWerkCore

/// Barcodefelder (`^BC`, `^B3`, `^BA`, `^BE`, `^B8`, `^BU`, `^B9`, `^B2`, `^BK`, `^BL`, `^BQ`, `^BX`, `^B7`).
extension InterpreterEngine {

    mutating func makeBarcode(_ spec: BarcodeSpec, field: FieldState, data: String,
                              placement: FieldPlacement, reverse: Bool) -> [LabelElement] {
        let command = spec.command
        let code = String(command.dropFirst())
        if let name = Self.unsupportedBarcodes[code] {
            warn(command, "Barcode-Typ \(name) wird in der Vorschau nicht dargestellt.")
            return []
        }
        switch code {
        case "BQ": return makeQRCode(spec.parameters, data: data, placement: placement, reverse: reverse)
        case "BX": return makeDataMatrix(spec.parameters, data: data, placement: placement, reverse: reverse)
        case "B7": return makePDF417(spec.parameters, data: data, placement: placement, reverse: reverse)
        default: return makeLinear(code, spec.parameters, data: data, placement: placement, reverse: reverse)
        }
    }

    // MARK: Lineare Codes

    private mutating func makeLinear(_ code: String, _ p: ZPLParameters, data: String,
                                     placement: FieldPlacement, reverse: Bool) -> [LabelElement] {
        let command = "^" + code
        let orientation = p.orientation(0) ?? printer.defaultOrientation
        var heightIndex = 1, interpretationIndex = 2, aboveIndex = 3
        switch code {
        case "B3": (heightIndex, interpretationIndex, aboveIndex) = (2, 3, 4)
        case "BK": (heightIndex, interpretationIndex, aboveIndex) = (2, 3, 4)
        case "BL": (heightIndex, interpretationIndex, aboveIndex) = (1, -1, 2)
        default: break
        }
        let height = p.int(heightIndex, in: 1...32_000) ?? printer.barcodeHeight
        let interpretation = interpretationIndex < 0 ? true : (p.bool(interpretationIndex) ?? true)
        let above = p.bool(aboveIndex) ?? false

        let symbology: BarcodeSymbology
        var barcode: LinearBarcode
        do {
            switch code {
            case "BC":
                symbology = .code128
                barcode = try Code128ZPL.encode(data, mode: p.character(5) ?? "N", uccCheckDigit: p.bool(4) ?? false)
            case "B3":
                symbology = .code39
                barcode = try Self.code39(data, checkDigit: p.bool(1) ?? false)
            case "BL":
                symbology = .code39
                barcode = try Self.code39(data, checkDigit: true)
            case "BA":
                symbology = .code93
                // Klarschrift = Daten (die Prüfzeichen C und K werden nicht gedruckt).
                barcode = try BarcodeEncoder.code93(data)
            case "BE":
                symbology = .ean13
                barcode = try BarcodeEncoder.ean13(Self.fixedDigits(data, count: 12))
            case "B8":
                symbology = .ean8
                barcode = try BarcodeEncoder.ean8(Self.fixedDigits(data, count: 7))
            case "BU":
                symbology = .upcA
                barcode = try BarcodeEncoder.upcA(Self.fixedDigits(data, count: 11))
                if p.bool(4) == false { barcode.humanReadable = String(barcode.humanReadable.dropLast()) }
            case "B9":
                symbology = .upcE
                barcode = try BarcodeEncoder.upcE(Self.upcEInput(data))
                if p.bool(4) == false { barcode.humanReadable = String(barcode.humanReadable.dropLast()) }
            case "B2":
                symbology = .interleaved2of5
                barcode = try BarcodeEncoder.interleaved2of5(data, checkDigit: p.bool(4) ?? false)
            case "BK":
                symbology = .codabar
                let start = p.character(5) ?? "A"
                let stop = p.character(6) ?? "A"
                barcode = try BarcodeEncoder.codabar(data, start: start, stop: stop)
            default:
                warn(command, "Unbekannter Barcode-Befehl – ignoriert.")
                return []
            }
        } catch {
            warn(command, "Barcode-Daten ungültig: \(Self.describe(error))")
            return []
        }

        var element = LinearBarcodeElement(origin: .zero, symbology: symbology, barcode: barcode,
                                           moduleWidth: printer.barcodeModuleWidth, ratio: printer.barcodeRatio,
                                           height: height, orientation: orientation,
                                           printInterpretation: interpretation, interpretationAbove: above,
                                           text: data, reverse: reverse)
        let layout = LinearBarcodeLayout(element)
        element.origin = placement.origin(width: layout.width, height: layout.height, orientation: orientation,
                                          anchorX: Double(layout.barsX),
                                          anchorRightX: Double(layout.barsX + layout.barsWidth),
                                          anchorY: Double(layout.barsY + layout.barHeight))
        return [.linearBarcode(element)]
    }

    /// Code 39 (Standard), bei Kleinbuchstaben/Sonderzeichen automatisch Full ASCII.
    private static func code39(_ data: String, checkDigit: Bool) throws -> LinearBarcode {
        do {
            return try BarcodeEncoder.code39(data, checkDigit: checkDigit)
        } catch BarcodeError.invalidCharacter {
            return try BarcodeEncoder.code39(data, checkDigit: checkDigit, fullASCII: true)
        }
    }

    /// Ziffern auf feste Länge bringen (ZPL: links mit Nullen auffüllen bzw. abschneiden).
    static func fixedDigits(_ data: String, count: Int) throws -> String {
        let digits = data.filter { $0.isASCII && $0.isNumber }
        if let invalid = data.first(where: { !($0.isASCII && $0.isNumber) && $0 != " " }) {
            throw BarcodeError.invalidCharacter(invalid)
        }
        if digits.count >= count { return String(digits.prefix(count)) }
        return String(repeating: "0", count: count - digits.count) + digits
    }

    /// `^B9`-Daten: 10 Ziffern (UPC-A ohne Nummernsystem und Prüfziffer) erhalten das
    /// Nummernsystem 0; andere Längen werden unverändert an den Encoder gegeben.
    static func upcEInput(_ data: String) -> String {
        let digits = data.filter { $0.isASCII && $0.isNumber }
        return digits.count == 10 ? "0" + digits : data
    }

    static func describe(_ error: Error) -> String {
        if let barcodeError = error as? BarcodeError, let text = barcodeError.errorDescription { return text }
        return error.localizedDescription
    }

    // MARK: QR-Code

    /// `^BQa,b,c,d,e` mit Felddaten `<Fehlerkorrektur><Eingabemodus>,<Daten>` (z. B. `QA,Text`).
    private mutating func makeQRCode(_ p: ZPLParameters, data: String, placement: FieldPlacement,
                                     reverse: Bool) -> [LabelElement] {
        if let model = p.int(1), model == 1 {
            warn("^BQ", "QR-Modell 1 wird als Modell 2 dargestellt.")
        }
        let magnification = p.int(2, in: 1...10) ?? Self.defaultQRMagnification(dotsPerMM: dotsPerMM)
        let defaultLevel = p.character(3).flatMap { QRErrorCorrection(rawValue: String($0)) } ?? .quartile
        let mask = p.int(4, in: 0...7)
        let parsed = QRFieldData.parse(data, defaultLevel: defaultLevel)
        if let message = parsed.warning { warn("^BQ", message) }
        let matrix: BitMatrix
        do {
            if let mask {
                matrix = try BarcodeEncoder.qr(parsed.payload, errorCorrection: parsed.level, minimumVersion: 1, mask: mask)
            } else {
                matrix = try BarcodeEncoder.qr(parsed.payload, errorCorrection: parsed.level)
            }
        } catch {
            warn("^BQ", "QR-Code kann nicht erzeugt werden: \(Self.describe(error))")
            return []
        }
        return [matrixElement(.qr, matrix: matrix, moduleSize: magnification, orientation: .normal,
                              text: parsed.payload, placement: placement, reverse: reverse)]
    }

    static func defaultQRMagnification(dotsPerMM: Int) -> Int {
        switch dotsPerMM {
        case ..<7: return 1
        case 7..<12: return 2
        case 12..<24: return 3
        default: return 6
        }
    }

    // MARK: Data Matrix

    /// `^BXo,h,s,c,r,f,g,a` – nur ECC 200.
    private mutating func makeDataMatrix(_ p: ZPLParameters, data: String, placement: FieldPlacement,
                                         reverse: Bool) -> [LabelElement] {
        let orientation = p.orientation(0) ?? printer.defaultOrientation
        if let quality = p.int(2), quality != 200 {
            warn("^BX", "Qualitätsstufe ECC \(quality) wird als ECC 200 dargestellt.")
        }
        let columns = p.int(3, in: 0...144) ?? 0
        let rows = p.int(4, in: 0...144) ?? 0
        let shape: DataMatrixShape = p.int(7) == 2 ? .rectangle : .square
        let escape = p.raw(6).flatMap { $0.first } ?? "~"
        let decoded = DataMatrixEscapes.decode(data, escape: escape)
        if let message = decoded.warning { warn("^BX", message) }
        var matrix: BitMatrix
        do {
            matrix = try BarcodeEncoder.dataMatrix(bytes: decoded.bytes,
                                                   options: DataMatrixOptions(shape: shape, rows: rows, columns: columns))
        } catch {
            if rows > 0 || columns > 0,
               let automatic = try? BarcodeEncoder.dataMatrix(bytes: decoded.bytes, options: DataMatrixOptions(shape: shape)) {
                warn("^BX", "Die Daten passen nicht in \(rows) × \(columns) Module – automatische Symbolgröße verwendet.")
                matrix = automatic
            } else {
                warn("^BX", "Data Matrix kann nicht erzeugt werden: \(Self.describe(error))")
                return []
            }
        }
        var module = p.int(1, in: 0...32_000) ?? 0
        if module <= 0 {
            // Ohne Modulgröße ergibt die ^BY-Höhe die ungefähre Symbolhöhe.
            module = max(1, printer.barcodeHeight / max(1, matrix.height))
        }
        return [matrixElement(.dataMatrix, matrix: matrix, moduleSize: module, orientation: orientation,
                              text: data, placement: placement, reverse: reverse)]
    }

    // MARK: PDF417

    /// `^B7o,h,s,c,r,t`: h = Zeilenhöhe in Punkten (Standard: ^BY-Höhe), Modulbreite aus ^BY.
    private mutating func makePDF417(_ p: ZPLParameters, data: String, placement: FieldPlacement,
                                     reverse: Bool) -> [LabelElement] {
        let orientation = p.orientation(0) ?? printer.defaultOrientation
        let module = printer.barcodeModuleWidth
        let rowHeightDots = p.int(1, in: 1...32_000) ?? printer.barcodeHeight
        let rowModules = max(1, Int((Double(rowHeightDots) / Double(module)).rounded()))
        if rowModules * module != rowHeightDots {
            warn("^B7", "Zeilenhöhe \(rowHeightDots) wird auf \(rowModules * module) Punkte (Vielfaches der Modulbreite) gerundet.")
        }
        let options = PDF417Options(columns: p.int(3, in: 0...30) ?? 0, rows: p.int(4, in: 0...90) ?? 0,
                                    securityLevel: p.int(2, in: 0...8) ?? 0, rowHeight: rowModules,
                                    compact: p.bool(5) ?? false)
        let matrix: BitMatrix
        do {
            matrix = try BarcodeEncoder.pdf417(data, options: options)
        } catch {
            warn("^B7", "PDF417 kann nicht erzeugt werden: \(Self.describe(error))")
            return []
        }
        return [matrixElement(.pdf417, matrix: matrix, moduleSize: module, orientation: orientation,
                              text: data, placement: placement, reverse: reverse)]
    }

    private func matrixElement(_ symbology: BarcodeSymbology, matrix: BitMatrix, moduleSize: Int,
                               orientation: FieldOrientation, text: String, placement: FieldPlacement,
                               reverse: Bool) -> LabelElement {
        let width = matrix.width * moduleSize
        let height = matrix.height * moduleSize
        let origin = placement.origin(width: width, height: height, orientation: orientation, anchorX: 0,
                                      anchorRightX: Double(width), anchorY: Double(height))
        return .matrixBarcode(MatrixBarcodeElement(origin: origin, symbology: symbology, matrix: matrix,
                                                   moduleSize: moduleSize, orientation: orientation, text: text,
                                                   reverse: reverse))
    }
}

// MARK: - QR-Felddaten

/// Zerlegt `^BQ`-Felddaten: `<Fehlerkorrektur H|Q|M|L><Eingabemodus A|M>,<Daten>`.
///
/// Im manuellen Modus (`M`) folgt dem Komma ein Zeichenmodus: `N` (numerisch), `A`
/// (alphanumerisch), `Bnnnn` (Bytes mit vierstelliger Länge) oder `K` (Kanji). Der Encoder wählt
/// die Segmentierung selbst – der Inhalt bleibt identisch. Strukturierte Anhänge (`D…`) werden
/// übersprungen.
enum QRFieldData {
    struct Parsed {
        var level: QRErrorCorrection
        var payload: String
        var warning: String?
    }

    static func parse(_ data: String, defaultLevel: QRErrorCorrection) -> Parsed {
        var text = Substring(data)
        // Strukturierter Anhang: "D" + Kennung + "," vor dem eigentlichen Präfix.
        if text.first == "D", let comma = text.firstIndex(of: ","), text[text.index(after: comma)...].contains(",") {
            text = text[text.index(after: comma)...]
        }
        let characters = Array(text.prefix(3))
        guard characters.count == 3, characters[2] == ",",
              let level = QRErrorCorrection(rawValue: String(characters[0]).uppercased()),
              ["A", "M"].contains(String(characters[1]).uppercased()) else {
            return Parsed(level: defaultLevel, payload: data,
                          warning: "QR-Daten ohne gültiges Präfix (z. B. „QA,“) – gesamte Daten werden kodiert.")
        }
        var payload = String(text.dropFirst(3))
        if String(characters[1]).uppercased() == "M", let mode = payload.first {
            switch mode.uppercased() {
            case "N", "A", "K":
                payload.removeFirst()
            case "B":
                payload.removeFirst()
                let digits = payload.prefix(4)
                if digits.count == 4, let length = Int(digits) {
                    payload.removeFirst(4)
                    payload = String(payload.prefix(length))
                }
            default:
                break
            }
        }
        return Parsed(level: level, payload: payload, warning: nil)
    }
}

// MARK: - Data-Matrix-Escapesequenzen

/// Escapesequenzen von `^BX` (Parameter g, Standard `~`): `~X` = Steuerzeichen (X − 64),
/// `~dNNN` = Byte NNN dezimal, `~~` = Escapezeichen selbst. Funktionszeichen (`~1`…`~7`) werden
/// nicht nachgebildet.
enum DataMatrixEscapes {
    static func decode(_ data: String, escape: Character) -> (bytes: [UInt8], warning: String?) {
        let characters = Array(data)
        var bytes: [UInt8] = []
        var warning: String?
        var index = 0
        func append(_ character: Character) { bytes.append(contentsOf: Array(String(character).utf8)) }
        while index < characters.count {
            let character = characters[index]
            guard character == escape, index + 1 < characters.count else {
                append(character)
                index += 1
                continue
            }
            let next = characters[index + 1]
            if next == escape {
                append(escape)
                index += 2
            } else if next == "d" || next == "D", index + 4 < characters.count,
                      let value = Int(String(characters[(index + 2)...(index + 4)])), value <= 255 {
                bytes.append(UInt8(value))
                index += 5
            } else if let ascii = next.asciiValue, (0x40...0x5F).contains(ascii) {
                bytes.append(ascii - 0x40)
                index += 2
            } else if let ascii = next.asciiValue, (0x31...0x37).contains(ascii) {
                warning = "Data-Matrix-Funktionszeichen (\(escape)\(next)) werden nicht nachgebildet."
                index += 2
            } else {
                append(character)
                index += 1
            }
        }
        return (bytes, warning)
    }
}

// MARK: - Code 128 nach ZPL-Regeln

/// Code 128 wie `^BC`: Modus N (Aufrufcodes `>…`), A (automatisch), U (UCC Case), D (GS1-128).
enum Code128ZPL {
    private static let startA = 103, startB = 104, startC = 105
    private enum Subset { case a, b, c }

    static func encode(_ data: String, mode: Character, uccCheckDigit: Bool) throws -> LinearBarcode {
        switch mode {
        case "A":
            return try BarcodeEncoder.code128(data, mode: .auto)
        case "D":
            let raw = data.replacingOccurrences(of: ">8", with: "\u{1D}")
            return try BarcodeEncoder.code128(raw, mode: .ucc)
        case "U":
            return try uccCase(data)
        default:
            return try modeN(data, uccCheckDigit: uccCheckDigit)
        }
    }

    /// GS1-Prüfziffer (Modulo 10, Gewichte 3/1 von rechts).
    static func gs1CheckDigit(_ digits: [Int]) -> Int {
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() { sum += digit * (offset % 2 == 0 ? 3 : 1) }
        return (10 - sum % 10) % 10
    }

    /// Modus U: genau 19 Ziffern (abschneiden bzw. rechts mit 0 auffüllen) + Prüfziffer, Zeichensatz C mit FNC1.
    private static func uccCase(_ data: String) throws -> LinearBarcode {
        var digits = data.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        if digits.count > 19 { digits = Array(digits.prefix(19)) }
        while digits.count < 19 { digits.append(0) }
        digits.append(gs1CheckDigit(digits))
        var values = [startC, 102]
        for pair in stride(from: 0, to: 20, by: 2) { values.append(digits[pair] * 10 + digits[pair + 1]) }
        let text = digits.map(String.init).joined()
        let readable = "(" + text.prefix(2) + ")" + text.dropFirst(2)
        return try BarcodeEncoder.code128(symbolValues: values, humanReadable: readable)
    }

    /// Modus N: Start in Zeichensatz B, sofern die Daten nicht mit `>9` (A), `>:` (B) oder `>;` (C) beginnen.
    private static func modeN(_ data: String, uccCheckDigit: Bool) throws -> LinearBarcode {
        var scalars = Array(data.unicodeScalars)
        var subset = Subset.b
        var values: [Int] = []
        if scalars.count >= 2, scalars[0] == ">", ["9", ":", ";"].contains(scalars[1]) {
            subset = scalars[1] == "9" ? .a : scalars[1] == ":" ? .b : .c
            scalars.removeFirst(2)
        }
        values.append(subset == .a ? startA : subset == .b ? startB : startC)
        if uccCheckDigit {
            let digits = scalars.compactMap { Character($0).isASCII ? Character($0).wholeNumberValue : nil }
            scalars.append(Unicode.Scalar(UInt8(48 + gs1CheckDigit(digits))))
        }

        var readable = String.UnicodeScalarView()
        var shiftNext = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ">" && index + 1 < scalars.count {
                let code = scalars[index + 1]
                index += 2
                switch code {
                case "<", "0":
                    try appendCharacter(">", subset: subset, shift: &shiftNext, values: &values)
                    readable.append(">")
                case "=":
                    values.append(94)
                    if subset == .b { readable.append("~") }
                case "1": values.append(95)
                case "2": values.append(96)
                case "3": values.append(97)
                case "4":
                    guard subset != .c else { throw BarcodeError.unsupported("SHIFT (>4) in Zeichensatz C") }
                    values.append(98)
                    shiftNext = true
                case "5":
                    if subset != .c { values.append(99) }
                    subset = .c
                case "6":
                    values.append(100)
                    if subset != .b { subset = .b }
                case "7":
                    values.append(101)
                    if subset != .a { subset = .a }
                case "8":
                    values.append(102)
                default:
                    throw BarcodeError.invalidCharacter(Character(code))
                }
                continue
            }
            if subset == .c && !shiftNext {
                if index + 1 < scalars.count,
                   let high = Self.digit(scalar), let low = Self.digit(scalars[index + 1]) {
                    values.append(high * 10 + low)
                    readable.append(scalar)
                    readable.append(scalars[index + 1])
                    index += 2
                    continue
                }
                // Einzelne Ziffer oder anderes Zeichen in Zeichensatz C: nach B wechseln (CODE B).
                values.append(100)
                subset = .b
            }
            try appendCharacter(scalar, subset: subset, shift: &shiftNext, values: &values)
            if scalar.value >= 0x20 && scalar.value != 0x7F { readable.append(scalar) }
            index += 1
        }
        guard values.count > 1 else { throw BarcodeError.invalidLength(0) }
        return try BarcodeEncoder.code128(symbolValues: values, humanReadable: String(readable))
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        (0x30...0x39).contains(scalar.value) ? Int(scalar.value - 0x30) : nil
    }

    private static func appendCharacter(_ scalar: Unicode.Scalar, subset: Subset, shift: inout Bool,
                                        values: inout [Int]) throws {
        let effective: Subset = shift ? (subset == .a ? .b : .a) : subset
        shift = false
        let ascii = Int(scalar.value)
        switch effective {
        case .a:
            if (32...95).contains(ascii) { values.append(ascii - 32) }
            else if (0...31).contains(ascii) { values.append(ascii + 64) }
            else { throw BarcodeError.invalidCharacter(Character(scalar)) }
        case .b:
            guard (32...127).contains(ascii) else { throw BarcodeError.invalidCharacter(Character(scalar)) }
            values.append(ascii - 32)
        case .c:
            throw BarcodeError.invalidCharacter(Character(scalar))
        }
    }
}

import Foundation

/// Code 39 (ISO/IEC 16388) mit optionaler Modulo-43-Prüfziffer und Full-ASCII-Erweiterung.
enum Code39 {

    /// Zeichenvorrat in Wertreihenfolge (Wert = Index, relevant für die Modulo-43-Prüfziffer).
    static let alphabet: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%")

    /// Muster je Zeichen: 9 Elemente (Balken, Lücke, …, Balken), höchstwertiges Bit zuerst,
    /// 1 = breit. Genau drei der neun Elemente sind breit.
    static let patterns: [UInt16] = [
        0x034, 0x121, 0x061, 0x160, 0x031, 0x130, 0x070, 0x025, 0x124, 0x064,  // 0–9
        0x109, 0x049, 0x148, 0x019, 0x118, 0x058, 0x00D, 0x10C, 0x04C, 0x01C,  // A–J
        0x103, 0x043, 0x142, 0x013, 0x112, 0x052, 0x007, 0x106, 0x046, 0x016,  // K–T
        0x181, 0x0C1, 0x1C0, 0x091, 0x190, 0x0D0, 0x085, 0x184, 0x0C4, 0x0A8,  // U–Z - . Leer $
        0x0A2, 0x08A, 0x02A,  // / + %
    ]

    /// Start-/Stoppzeichen `*`.
    static let startStop: UInt16 = 0x094

    static let valueOf: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = index }
        return map
    }()

    /// Full-ASCII-Darstellung (ein oder zwei Code-39-Zeichen) für ASCII 0…127.
    ///
    /// `$ % + /` werden als `/D /E /K /O` kodiert, da sie in Code 39 selbst Umschaltzeichen sind.
    static func fullASCII(_ code: UInt8) -> String {
        func letter(_ base: Character, _ offset: Int) -> String {
            String(Character(Unicode.Scalar(UInt8(base.asciiValue! + UInt8(offset)))))
        }
        switch code {
        case 0: return "%U"
        case 1...26: return "$" + letter("A", Int(code) - 1)
        case 27...31: return "%" + letter("A", Int(code) - 27)
        case 32: return " "
        case 33...44: return "/" + letter("A", Int(code) - 33)
        case 45: return "-"
        case 46: return "."
        case 47: return "/O"
        case 48...57: return String(Character(Unicode.Scalar(code)))
        case 58: return "/Z"
        case 59...63: return "%" + letter("F", Int(code) - 59)
        case 64: return "%V"
        case 65...90: return String(Character(Unicode.Scalar(code)))
        case 91...95: return "%" + letter("K", Int(code) - 91)
        case 96: return "%W"
        case 97...122: return "+" + letter("A", Int(code) - 97)
        default: return "%" + letter("P", Int(code) - 123)  // 123…127
        }
    }

    /// Wandelt ein Muster in 9 Elemente um.
    static func elements(for pattern: UInt16) -> [LinearBarcode.Element] {
        var widths: [Int] = []
        widths.reserveCapacity(9)
        for bit in stride(from: 8, through: 0, by: -1) {
            widths.append((pattern >> UInt16(bit)) & 1 == 1 ? 2 : 1)
        }
        return LinearSupport.elements(widths: widths)
    }

    static func encode(_ text: String, checkDigit: Bool, fullASCII: Bool) throws -> LinearBarcode {
        guard !text.isEmpty else { throw BarcodeError.invalidLength(0) }

        // 1) In Code-39-Zeichen übersetzen.
        var symbolCharacters: [Character] = []
        for scalar in text.unicodeScalars {
            let character = Character(scalar)
            if fullASCII {
                guard scalar.value < 128 else { throw BarcodeError.invalidCharacter(character) }
                symbolCharacters.append(contentsOf: Code39.fullASCII(UInt8(scalar.value)))
            } else {
                guard valueOf[character] != nil else { throw BarcodeError.invalidCharacter(character) }
                symbolCharacters.append(character)
            }
        }

        // 2) Optionale Prüfziffer (Modulo 43 über die Symbolzeichen).
        var check: Character?
        if checkDigit {
            let sum = symbolCharacters.reduce(0) { $0 + valueOf[$1]! }
            check = alphabet[sum % 43]
            symbolCharacters.append(check!)
        }

        // 3) Elemente: * Daten [Prüfziffer] *, getrennt durch schmale Lücken.
        var elements: [LinearBarcode.Element] = []
        let all = [startStop] + symbolCharacters.map { patterns[valueOf[$0]!] } + [startStop]
        for (index, pattern) in all.enumerated() {
            if index > 0 { elements.append(LinearBarcode.Element(isBar: false, width: 1)) }
            elements.append(contentsOf: Code39.elements(for: pattern))
        }

        let readableText = fullASCII ? Code128.readable(text) : text
        let readable = "*" + readableText + (check.map { String($0) } ?? "") + "*"
        return LinearBarcode(elements: elements, humanReadable: readable, isTwoWidth: true)
    }
}

/// Code 93 mit den Prüfzeichen „C“ und „K“; Zeichen außerhalb des Grundzeichensatzes werden
/// automatisch über die Code-93-Umschaltzeichen (Full ASCII) dargestellt.
enum Code93 {

    /// Zeichen 0…42 des Grundzeichensatzes; 43…46 sind die Umschaltzeichen ($) (%) (/) (+).
    static let alphabet: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%")

    /// Muster je Wert 0…47 als 9-Bit-Modulfolge (1 = Balkenmodul), Wert 47 = Start/Stopp.
    static let patterns: [UInt16] = [
        0x114, 0x148, 0x144, 0x142, 0x128, 0x124, 0x122, 0x150, 0x112, 0x10A,  // 0–9
        0x1A8, 0x1A4, 0x1A2, 0x194, 0x192, 0x18A, 0x168, 0x164, 0x162, 0x134,  // A–J
        0x11A, 0x158, 0x14C, 0x146, 0x12C, 0x116, 0x1B4, 0x1B2, 0x1AC, 0x1A6,  // K–T
        0x196, 0x19A, 0x16C, 0x166, 0x136, 0x13A,  // U–Z
        0x12E, 0x1D4, 0x1D2, 0x1CA, 0x16E, 0x176, 0x1AE,  // - . Leer $ / + %
        0x126, 0x1DA, 0x1D6, 0x132,  // ($) (%) (/) (+)
        0x15E,  // Start/Stopp
    ]

    static let startStopValue = 47

    static let valueOf: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = index }
        return map
    }()

    /// Wert des Umschaltzeichens für das Code-39-Full-ASCII-Präfix.
    static func shiftValue(for prefix: Character) -> Int? {
        switch prefix {
        case "$": return 43
        case "%": return 44
        case "/": return 45
        case "+": return 46
        default: return nil
        }
    }

    /// Wandelt einen Text in Code-93-Werte (ohne Prüfzeichen) um.
    static func values(for text: String) throws -> [Int] {
        var values: [Int] = []
        for scalar in text.unicodeScalars {
            guard scalar.value < 128 else { throw BarcodeError.invalidCharacter(Character(scalar)) }
            let character = Character(scalar)
            if let value = valueOf[character] {
                values.append(value)
                continue
            }
            // Zeichen des Grundzeichensatzes (auch $ % + /) sind oben bereits direkt kodiert.
            let pair = Array(Code39.fullASCII(UInt8(scalar.value)))
            guard pair.count == 2, let shift = shiftValue(for: pair[0]), let value = valueOf[pair[1]] else {
                throw BarcodeError.invalidCharacter(character)
            }
            values.append(shift)
            values.append(value)
        }
        return values
    }

    /// Gewichtete Prüfsumme (Gewichte von rechts 1…`maxWeight`, zyklisch), Modulo 47.
    static func checkValue(_ values: [Int], maxWeight: Int) -> Int {
        var sum = 0
        for (offset, value) in values.reversed().enumerated() {
            sum += value * (offset % maxWeight + 1)
        }
        return sum % 47
    }

    static func elements(for pattern: UInt16) -> [LinearBarcode.Element] {
        var modules: [Bool] = []
        for bit in stride(from: 8, through: 0, by: -1) { modules.append((pattern >> UInt16(bit)) & 1 == 1) }
        return LinearSupport.elements(modules: modules, guards: Array(repeating: false, count: modules.count))
    }

    static func encode(_ text: String) throws -> LinearBarcode {
        guard !text.isEmpty else { throw BarcodeError.invalidLength(0) }
        var values = try values(for: text)
        let c = checkValue(values, maxWeight: 20)
        values.append(c)
        let k = checkValue(values, maxWeight: 15)
        values.append(k)

        var elements: [LinearBarcode.Element] = []
        for value in [startStopValue] + values + [startStopValue] {
            LinearSupport.append(Code93.elements(for: patterns[value]), to: &elements)
        }
        // Abschlussbalken (1 Modul) nach dem Stoppzeichen.
        LinearSupport.append([LinearBarcode.Element(isBar: true, width: 1)], to: &elements)
        return LinearBarcode(elements: elements, humanReadable: Code128.readable(text), isTwoWidth: false)
    }
}

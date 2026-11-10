import Foundation

/// Interleaved 2 of 5 (ISO/IEC 16390).
enum Interleaved2of5 {

    /// Muster je Ziffer: 5 Elemente, höchstwertiges Bit zuerst, 1 = breit.
    static let patterns: [UInt8] = [
        0b00110, 0b10001, 0b01001, 0b11000, 0b00101, 0b10100, 0b01100, 0b00011, 0b10010, 0b01010,
    ]

    static func isWide(_ digit: Int, element: Int) -> Bool {
        patterns[digit] & (1 << UInt8(4 - element)) != 0
    }

    /// - Parameters:
    ///   - text: Nur Ziffern. Eine ungerade Gesamtzahl (inklusive Prüfziffer) wird mit einer
    ///     führenden 0 aufgefüllt.
    ///   - checkDigit: Modulo-10-Prüfziffer (Gewichte 3/1 von rechts) anhängen.
    static func encode(_ text: String, checkDigit: Bool) throws -> LinearBarcode {
        var digits = try LinearSupport.digits(text)
        guard !digits.isEmpty else { throw BarcodeError.invalidLength(0) }
        if checkDigit { digits.append(LinearSupport.mod10Weighted31(digits)) }
        if digits.count % 2 == 1 { digits.insert(0, at: 0) }

        var widths: [Int] = [1, 1, 1, 1]  // Startzeichen: schmal Balken/Lücke/Balken/Lücke
        var index = 0
        while index < digits.count {
            let barDigit = digits[index]
            let spaceDigit = digits[index + 1]
            for element in 0..<5 {
                widths.append(isWide(barDigit, element: element) ? 2 : 1)
                widths.append(isWide(spaceDigit, element: element) ? 2 : 1)
            }
            index += 2
        }
        widths.append(contentsOf: [2, 1, 1])  // Stoppzeichen: breit Balken, schmal Lücke, schmal Balken
        return LinearBarcode(elements: LinearSupport.elements(widths: widths),
                             humanReadable: EANUPC.string(digits), isTwoWidth: true)
    }
}

/// Codabar (NW-7) mit wählbaren Start-/Stoppzeichen A–D.
enum Codabar {

    /// Datenzeichen und Start-/Stoppzeichen in Tabellenreihenfolge.
    static let alphabet: [Character] = Array("0123456789-$:/.+ABCD")

    /// Muster: 7 Elemente (Balken zuerst), höchstwertiges Bit zuerst, 1 = breit.
    static let patterns: [UInt8] = [
        0x03, 0x06, 0x09, 0x60, 0x12, 0x42, 0x21, 0x24, 0x30, 0x48,  // 0–9
        0x0C, 0x18, 0x45, 0x51, 0x54, 0x15,  // - $ : / . +
        0x1A, 0x29, 0x0B, 0x0E,  // A B C D
    ]

    static let valueOf: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = index }
        return map
    }()

    /// Normalisiert ein Start-/Stoppzeichen (A–D, auch klein; Alternativen T/N/*/E wie bei ZPL `^BK`).
    static func normalizedGuard(_ character: Character) throws -> Character {
        switch character {
        case "A", "a", "T", "t": return "A"
        case "B", "b", "N", "n": return "B"
        case "C", "c", "*": return "C"
        case "D", "d", "E", "e": return "D"
        default: throw BarcodeError.invalidCharacter(character)
        }
    }

    static func encode(_ text: String, start: Character, stop: Character) throws -> LinearBarcode {
        let startGuard = try normalizedGuard(start)
        let stopGuard = try normalizedGuard(stop)
        guard !text.isEmpty else { throw BarcodeError.invalidLength(0) }
        var symbols: [Character] = [startGuard]
        for character in text {
            guard let value = valueOf[character], value < 16 else { throw BarcodeError.invalidCharacter(character) }
            symbols.append(character)
        }
        symbols.append(stopGuard)

        var elements: [LinearBarcode.Element] = []
        for (index, symbol) in symbols.enumerated() {
            if index > 0 { elements.append(LinearBarcode.Element(isBar: false, width: 1)) }
            let pattern = patterns[valueOf[symbol]!]
            var widths: [Int] = []
            for bit in stride(from: 6, through: 0, by: -1) { widths.append(pattern & (1 << UInt8(bit)) != 0 ? 2 : 1) }
            elements.append(contentsOf: LinearSupport.elements(widths: widths))
        }
        return LinearBarcode(elements: elements, humanReadable: String(startGuard) + text + String(stopGuard), isTwoWidth: true)
    }
}

import Foundation

/// Interne Hilfsfunktionen zum robusten Zerlegen von Druckerantworten.
///
/// Zebra-Drucker rahmen Antworten häufig mit `STX` (0x02) und `ETX` (0x03) ein, trennen Zeilen
/// mit `CR LF` und füllen Puffer gelegentlich mit `NUL` auf. Über Bluetooth oder bei
/// Zeitüberschreitungen kommen Antworten außerdem unvollständig an. Die Funktionen hier
/// normalisieren all das, bevor die eigentlichen Parser arbeiten.
enum StatusText {
    static let stx: Character = "\u{02}"
    static let etx: Character = "\u{03}"
    static let nul: Character = "\u{00}"

    /// Dekodiert Rohdaten als UTF-8, ersatzweise als ISO-8859-1 (gelingt immer).
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // ISO-8859-1 bildet jedes Byte 1:1 auf U+0000…U+00FF ab und kann nicht scheitern.
        var scalars = String.UnicodeScalarView()
        for byte in data { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }

    /// Ersetzt Rahmen- und Steuerzeichen (außer Tabulator) durch Zeilenumbrüche, zerlegt in
    /// Zeilen, entfernt Rand-Leerraum und verwirft leere Zeilen.
    static func lines(_ text: String) -> [String] {
        var current = ""
        var result: [String] = []
        current.reserveCapacity(64)
        for scalar in text.unicodeScalars {
            if isLineBreak(scalar) {
                let trimmed = trim(current)
                if !trimmed.isEmpty { result.append(trimmed) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        let trimmed = trim(current)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// Zeilen ohne Entfernen des führenden Leerraums (für spaltenorientierte Ausgaben).
    static func rawLines(_ text: String) -> [String] {
        var current = ""
        var result: [String] = []
        for scalar in text.unicodeScalars {
            if isLineBreak(scalar) {
                if !trim(current).isEmpty { result.append(trimTrailing(current)) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !trim(current).isEmpty { result.append(trimTrailing(current)) }
        return result
    }

    /// `true` für CR, LF und alle C0-Steuerzeichen außer Tabulator sowie DEL.
    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 { return false }
        return value < 0x20 || value == 0x7F || value == 0x85 || value == 0x2028 || value == 0x2029
    }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar.value == 0xA0 || isLineBreak(scalar)
    }

    /// Entfernt Leerraum und Steuerzeichen an beiden Enden.
    static func trim(_ text: some StringProtocol) -> String {
        let string = String(text)
        let scalars = string.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(Substring(scalars[first...last]))
    }

    /// Entfernt Leerraum und Steuerzeichen am Ende.
    static func trimTrailing(_ text: some StringProtocol) -> String {
        let string = String(text)
        let scalars = string.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(Substring(scalars[...last]))
    }

    /// Fasst Leerraumfolgen zu einem einzelnen Leerzeichen zusammen.
    static func collapseSpaces(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.unicodeScalars.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Zerlegt an Kommas und entfernt Leerraum je Feld.
    static func fields(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map { trim($0) }
    }

    /// Zerlegt an Leerraum.
    static func tokens(_ text: some StringProtocol) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Nicht negative Dezimalzahl ausschließlich aus ASCII-Ziffern (mit optionalem Vorzeichen).
    static func integer(_ text: String) -> Int? {
        var scalars = Substring(text).unicodeScalars[...]
        var negative = false
        if let first = scalars.first, first == "+" || first == "-" {
            negative = first == "-"
            scalars = scalars.dropFirst()
        }
        guard !scalars.isEmpty, scalars.count <= 18,
              scalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        var value = 0
        for scalar in scalars { value = value * 10 + Int(scalar.value - 0x30) }
        return negative ? -value : value
    }

    /// Hexadezimalzahl (1–16 Stellen, ohne Präfix).
    static func hex(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.unicodeScalars.count <= 16 else { return nil }
        var value: UInt64 = 0
        for scalar in text.unicodeScalars {
            let digit: UInt64
            switch scalar.value {
            case 0x30...0x39: digit = UInt64(scalar.value - 0x30)
            case 0x41...0x46: digit = UInt64(scalar.value - 0x41 + 10)
            case 0x61...0x66: digit = UInt64(scalar.value - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    /// Zahl mit Tausendertrennzeichen und/oder Dezimaltrennzeichen, wie sie Zebra-Drucker
    /// in SGD-Werten ausgeben („7,342“, „1.234,5“, „18649“, „4.0“).
    static func decimal(_ raw: String) -> Double? {
        var text = raw.filter { $0 != " " && $0 != "'" && $0 != "\u{A0}" }
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("-") || text.hasPrefix("+") {
            negative = text.hasPrefix("-")
            text.removeFirst()
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }),
              text.first?.isNumber == true else { return nil }
        let commas = text.filter { $0 == "," }.count
        let dots = text.filter { $0 == "." }.count
        var normalized: String
        if commas > 0 && dots > 0 {
            // Das zuletzt stehende Zeichen ist das Dezimaltrennzeichen.
            let lastComma = text.lastIndex(of: ",")!
            let lastDot = text.lastIndex(of: ".")!
            if lastComma > lastDot {
                normalized = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = text.replacingOccurrences(of: ",", with: "")
            }
        } else if commas > 0 {
            normalized = isThousandsGrouped(text, separator: ",")
                ? text.replacingOccurrences(of: ",", with: "")
                : (commas == 1 ? text.replacingOccurrences(of: ",", with: ".") : "")
        } else if dots > 1 {
            normalized = isThousandsGrouped(text, separator: ".") ? text.replacingOccurrences(of: ".", with: "") : ""
        } else {
            normalized = text
        }
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty, normalized.first != ".", let value = Double(normalized), value.isFinite else { return nil }
        return negative ? -value : value
    }

    /// `true`, wenn `text` dem Muster `d{1,3}(sep ddd)+` entspricht.
    static func isThousandsGrouped(_ text: String, separator: Character) -> Bool {
        let groups = text.split(separator: separator, omittingEmptySubsequences: false)
        guard groups.count >= 2, let first = groups.first, (1...3).contains(first.count) else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 }
    }

    /// Erste Zahl (mit Tausendertrennzeichen) in einem Text, z. B. „1,234 LABELS“ → 1234.
    ///
    /// Ein unmittelbar vor der ersten Ziffer stehendes `-` wird als Vorzeichen gewertet.
    /// Liefert außerdem den Rest hinter der Zahl.
    static func leadingNumber(_ text: String) -> (value: Double, rest: Substring)? {
        let string = Substring(text)
        guard let start = string.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        var negative = false
        if start > string.startIndex, string[string.index(before: start)] == "-" { negative = true }
        var end = start
        var index = start
        while index < string.endIndex {
            let char = string[index]
            guard char.isASCII, char.isNumber || char == "," || char == "." else { break }
            index = string.index(after: index)
            end = index
        }
        var numberText = String(string[start..<end])
        // Satzzeichen am Ende („1,234,“) gehören nicht zur Zahl.
        while let last = numberText.last, last == "," || last == "." {
            numberText.removeLast()
            end = string.index(before: end)
        }
        guard let value = decimal(numberText) else { return nil }
        return (negative ? -value : value, string[end...])
    }
}

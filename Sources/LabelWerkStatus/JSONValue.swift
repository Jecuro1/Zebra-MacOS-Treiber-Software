import Foundation

/// Minimaler, plattformunabhängiger JSON-Leser für SGD-Antworten.
///
/// Eigene Implementierung statt `JSONSerialization`, weil
/// * Zahlen exakt im Originaltext erhalten bleiben müssen („4.0“ statt „4“),
/// * `true`/`false` auf macOS und Linux unterschiedlich als `NSNumber` ankommen,
/// * Drucker gelegentlich rohe Steuerzeichen in Zeichenketten senden und
/// * eine Verschachtelungsgrenze Stapelüberläufe bei böswilligen Eingaben verhindert.
indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    /// Zahl im unveränderten Originaltext.
    case number(String)
    case bool(Bool)
    case null
    case array([JSONValue])
    /// Schlüssel-Wert-Paare in Originalreihenfolge.
    case object([(key: String, value: JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    /// Wert eines Schlüssels (erstes Vorkommen) in einem Objekt.
    subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// Textdarstellung für SGD-Werte (`nil` für `null`).
    var scalarText: String? {
        switch self {
        case .string(let text): return text
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return nil
        case .array(let items): return items.compactMap(\.scalarText).joined(separator: ",")
        case .object: return JSONWriter.write(self)
        }
    }

    /// Lesart als Wahrheitswert („true“, „yes“, „on“, „1“ …).
    var boolValue: Bool? {
        switch self {
        case .bool(let flag): return flag
        case .number(let text): return Double(text).map { $0 != 0 }
        case .string(let text):
            switch text.lowercased() {
            case "true", "yes", "on", "1", "y": return true
            case "false", "no", "off", "0", "n": return false
            default: return nil
            }
        default: return nil
        }
    }
}

/// Kompakte JSON-Ausgabe (nur für verschachtelte Werte in ``JSONValue/scalarText``).
enum JSONWriter {
    static func write(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return quote(text)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(write).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { quote($0.key) + ":" + write($0.value) }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// Rekursiver Abstiegsparser mit Tiefenbegrenzung.
struct JSONReader {
    static let maximumDepth = 64

    private let scalars: [Unicode.Scalar]
    private(set) var position = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool { position >= scalars.count }

    /// Überspringt Leerraum und Steuerzeichen (`STX`, `ETX`, `NUL` …).
    mutating func skipWhitespace() {
        while position < scalars.count, scalars[position].value <= 0x20 || scalars[position].value == 0x7F {
            position += 1
        }
    }

    /// `true`, wenn das aktuelle Zeichen eine öffnende geschweifte Klammer ist.
    var peekIsObjectStart: Bool { position < scalars.count && scalars[position] == "{" }

    /// Springt zur nächsten `{`; `false`, wenn keine mehr folgt.
    mutating func seekObjectStart() -> Bool {
        while position < scalars.count {
            if scalars[position] == "{" { return true }
            position += 1
        }
        return false
    }

    mutating func parseValue(depth: Int = 0) throws -> JSONValue {
        guard depth <= Self.maximumDepth else { throw fail("Verschachtelung zu tief") }
        skipWhitespace()
        guard position < scalars.count else { throw fail("Unerwartetes Ende") }
        switch scalars[position] {
        case "{": return try parseObject(depth: depth)
        case "[": return try parseArray(depth: depth)
        case "\"": return .string(try parseString())
        case "t": try expectLiteral("true"); return .bool(true)
        case "f": try expectLiteral("false"); return .bool(false)
        case "n": try expectLiteral("null"); return .null
        case "-", "0"..."9": return .number(try parseNumber())
        default: throw fail("Unerwartetes Zeichen „\(Character(scalars[position]))“")
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        position += 1 // {
        var pairs: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if position < scalars.count, scalars[position] == "}" {
            position += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard position < scalars.count else { throw fail("Unerwartetes Ende im Objekt") }
            guard scalars[position] == "\"" else { throw fail("Schlüssel erwartet") }
            let key = try parseString()
            skipWhitespace()
            guard position < scalars.count, scalars[position] == ":" else { throw fail("„:“ erwartet") }
            position += 1
            let value = try parseValue(depth: depth + 1)
            pairs.append((key, value))
            skipWhitespace()
            guard position < scalars.count else { throw fail("Unerwartetes Ende im Objekt") }
            if scalars[position] == "," {
                position += 1
                continue
            }
            if scalars[position] == "}" {
                position += 1
                return .object(pairs)
            }
            throw fail("„,“ oder „}“ erwartet")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        position += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if position < scalars.count, scalars[position] == "]" {
            position += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard position < scalars.count else { throw fail("Unerwartetes Ende im Array") }
            if scalars[position] == "," {
                position += 1
                continue
            }
            if scalars[position] == "]" {
                position += 1
                return .array(items)
            }
            throw fail("„,“ oder „]“ erwartet")
        }
    }

    private mutating func parseString() throws -> String {
        position += 1 // "
        var result = String.UnicodeScalarView()
        while position < scalars.count {
            let scalar = scalars[position]
            position += 1
            switch scalar {
            case "\"":
                return String(result)
            case "\\":
                guard position < scalars.count else { throw fail("Unvollständige Escape-Sequenz") }
                let escape = scalars[position]
                position += 1
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u": result.append(try parseUnicodeEscape())
                default: throw fail("Unbekannte Escape-Sequenz „\\\(Character(escape))“")
                }
            default:
                // Rohe Steuerzeichen sind laut JSON unzulässig, kommen bei Druckern aber vor.
                result.append(scalar)
            }
        }
        throw fail("Zeichenkette nicht abgeschlossen")
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let high = try readHex4()
        if (0xD800...0xDBFF).contains(high) {
            // Ersatzpaar (Surrogate Pair) erwartet.
            if position + 1 < scalars.count, scalars[position] == "\\", scalars[position + 1] == "u" {
                position += 2
                let low = try readHex4()
                if (0xDC00...0xDFFF).contains(low) {
                    let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    return Unicode.Scalar(value) ?? "\u{FFFD}"
                }
            }
            return "\u{FFFD}"
        }
        return Unicode.Scalar(high) ?? "\u{FFFD}"
    }

    private mutating func readHex4() throws -> UInt32 {
        guard position + 4 <= scalars.count else { throw fail("Unvollständige \\u-Sequenz") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let scalar = scalars[position]
            position += 1
            let digit: UInt32
            switch scalar.value {
            case 0x30...0x39: digit = scalar.value - 0x30
            case 0x41...0x46: digit = scalar.value - 0x41 + 10
            case 0x61...0x66: digit = scalar.value - 0x61 + 10
            default: throw fail("Ungültige \\u-Sequenz")
            }
            value = value << 4 | digit
        }
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = position
        if scalars[position] == "-" { position += 1 }
        func digits() -> Int {
            let begin = position
            while position < scalars.count, ("0"..."9").contains(scalars[position]) { position += 1 }
            return position - begin
        }
        guard digits() > 0 else { throw fail("Ziffer erwartet") }
        if position < scalars.count, scalars[position] == "." {
            position += 1
            guard digits() > 0 else { throw fail("Nachkommastellen erwartet") }
        }
        if position < scalars.count, scalars[position] == "e" || scalars[position] == "E" {
            position += 1
            if position < scalars.count, scalars[position] == "+" || scalars[position] == "-" { position += 1 }
            guard digits() > 0 else { throw fail("Exponent erwartet") }
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[start..<position])
        return String(text)
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard position < scalars.count, scalars[position] == expected else {
                throw fail("„\(literal)“ erwartet")
            }
            position += 1
        }
    }

    private func fail(_ message: String) -> StatusParseError {
        .invalidJSON("\(message) (Position \(position))")
    }
}

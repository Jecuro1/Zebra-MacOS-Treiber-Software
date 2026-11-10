import Foundation

/// Kleiner JSON-Leser/-Schreiber für den virtuellen Drucker.
///
/// Eigene Implementierung statt `JSONSerialization`, weil die Reihenfolge der Schlüssel einer
/// Anfrage in der Antwort erhalten bleiben soll (wie bei Link-OS) und Zahlen unverändert als Text
/// weitergegeben werden. Die Verschachtelungstiefe ist begrenzt.
indirect enum MiniJSON: Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case array([MiniJSON])
    case object([(key: String, value: MiniJSON)])

    struct ParseError: Error, Equatable {
        var message: String
    }

    static let maximumDepth = 64

    // MARK: Lesen

    static func parse(_ bytes: [UInt8]) throws -> MiniJSON {
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw ParseError(message: "Zusätzliche Daten nach dem JSON-Wert") }
        return value
    }

    /// Textdarstellung eines skalaren Werts (für SGD-Zuweisungen).
    var scalarText: String? {
        switch self {
        case .string(let text): return text
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return nil
        case .array, .object: return serialized
        }
    }

    // MARK: Schreiben

    /// Kompakte JSON-Darstellung.
    var serialized: String {
        switch self {
        case .string(let text): return Self.quote(text)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.serialized).joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { Self.quote($0.key) + ":" + $0.value.serialized }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func parseValue(depth: Int) throws -> MiniJSON {
            guard depth < MiniJSON.maximumDepth else { throw ParseError(message: "JSON zu tief verschachtelt") }
            skipWhitespace()
            guard index < bytes.count else { throw ParseError(message: "Unerwartetes Ende") }
            switch bytes[index] {
            case 0x7B: return try parseObject(depth: depth)
            case 0x5B: return try parseArray(depth: depth)
            case 0x22: return .string(try parseString())
            case 0x74: try expect("true"); return .bool(true)
            case 0x66: try expect("false"); return .bool(false)
            case 0x6E: try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func parseObject(depth: Int) throws -> MiniJSON {
            index += 1
            var pairs: [(key: String, value: MiniJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7D { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else { throw ParseError(message: "Schlüssel erwartet") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x3A else { throw ParseError(message: "„:“ erwartet") }
                index += 1
                let value = try parseValue(depth: depth + 1)
                pairs.append((key, value))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(message: "Unerwartetes Ende im Objekt") }
                if bytes[index] == 0x2C { index += 1; continue }
                if bytes[index] == 0x7D { index += 1; return .object(pairs) }
                throw ParseError(message: "„,“ oder „}“ erwartet")
            }
        }

        mutating func parseArray(depth: Int) throws -> MiniJSON {
            index += 1
            var items: [MiniJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x5D { index += 1; return .array(items) }
            while true {
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(message: "Unerwartetes Ende im Feld") }
                if bytes[index] == 0x2C { index += 1; continue }
                if bytes[index] == 0x5D { index += 1; return .array(items) }
                throw ParseError(message: "„,“ oder „]“ erwartet")
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars: [UInt8] = []
            var result = ""
            func flush() {
                if !scalars.isEmpty {
                    result += String(decoding: scalars, as: UTF8.self)
                    scalars.removeAll()
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case 0x22:
                    flush()
                    return result
                case 0x5C:
                    guard index < bytes.count else { throw ParseError(message: "Unvollständige Maskierung") }
                    let escape = bytes[index]
                    index += 1
                    flush()
                    switch escape {
                    case 0x22: result += "\""
                    case 0x5C: result += "\\"
                    case 0x2F: result += "/"
                    case 0x62: result += "\u{08}"
                    case 0x66: result += "\u{0C}"
                    case 0x6E: result += "\n"
                    case 0x72: result += "\r"
                    case 0x74: result += "\t"
                    case 0x75:
                        guard index + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                            throw ParseError(message: "Ungültige Unicode-Maskierung")
                        }
                        index += 4
                        result.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default:
                        throw ParseError(message: "Unbekannte Maskierung")
                    }
                default:
                    scalars.append(byte)
                }
            }
            throw ParseError(message: "Zeichenkette nicht abgeschlossen")
        }

        mutating func parseNumber() throws -> String {
            let start = index
            while index < bytes.count, let scalar = Optional(bytes[index]),
                  (scalar >= 0x30 && scalar <= 0x39) || scalar == 0x2D || scalar == 0x2B || scalar == 0x2E
                    || scalar == 0x65 || scalar == 0x45 {
                index += 1
            }
            guard index > start else { throw ParseError(message: "Wert erwartet") }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard Double(text) != nil else { throw ParseError(message: "Ungültige Zahl „\(text)“") }
            return text
        }

        mutating func expect(_ literal: String) throws {
            let pattern = Array(literal.utf8)
            guard index + pattern.count <= bytes.count, Array(bytes[index..<index + pattern.count]) == pattern else {
                throw ParseError(message: "„\(literal)“ erwartet")
            }
            index += pattern.count
        }
    }
}

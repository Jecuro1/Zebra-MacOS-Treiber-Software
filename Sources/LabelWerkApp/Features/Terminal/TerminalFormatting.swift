import Foundation

// Reine Logik des Terminals (nur Foundation): Eingabemodus, Aufbereitung von SGD-Kurzformen,
// Darstellung von Steuerzeichen, Hex-Dump und Eingabeverlauf.

// MARK: - Eingabemodus

/// Sprache der Terminal-Eingabe (Hervorhebung und Aufbereitung).
enum TerminalInputMode: String, CaseIterable, Identifiable, Codable {
    case zpl
    case sgd
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zpl: return "ZPL"
        case .sgd: return "SGD"
        case .text: return tr("Text")
        }
    }

    var systemImage: String {
        switch self {
        case .zpl: return "chevron.left.forwardslash.chevron.right"
        case .sgd: return "curlybraces"
        case .text: return "text.alignleft"
        }
    }

    var explanation: String {
        switch self {
        case .zpl:
            return tr("ZPL-Befehle werden unverändert gesendet. Zeilen mit „! U1“ erhalten automatisch ein Zeilenende.")
        case .sgd:
            return tr("SGD-Kurzformen: „device.languages“ liest, „name = wert“ setzt, „do name wert“ führt aus. JSON ({}{…}) wird unverändert gesendet.")
        case .text:
            return tr("Text wird Byte für Byte so gesendet, wie er eingegeben wurde.")
        }
    }

    /// Leitet den Modus aus dem Inhalt ab (für Verlauf und Bausteine). Der Verlauf speichert keinen
    /// Modus – SGD-Kurzformen („device.languages“, „name = wert“, „getvar …“, „do …“) gelten
    /// deshalb als SGD, sonst würden sie im ZPL-Modus als wirkungsloser Rohtext gesendet.
    static func infer(from text: String, fallback: TerminalInputMode) -> TerminalInputMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!") || trimmed.hasPrefix("{") { return .sgd }
        if trimmed.hasPrefix("^") || trimmed.hasPrefix("~") { return .zpl }
        if TerminalComposer.prepare(trimmed, mode: .sgd).wasExpanded { return .sgd }
        return fallback
    }
}

// MARK: - Aufbereitung

enum TerminalComposer {
    struct Prepared: Equatable {
        /// Tatsächlich gesendete Zeichen.
        let payload: String
        /// true, wenn Kurzformen in vollständige SGD-Befehle umgewandelt wurden.
        let wasExpanded: Bool
    }

    static func prepare(_ input: String, mode: TerminalInputMode) -> Prepared {
        switch mode {
        case .text:
            return Prepared(payload: input, wasExpanded: false)
        case .zpl:
            let lines = normalizedLines(input)
            // SGD-Zeilen benötigen ein Zeilenende, damit der Drucker sie ausführt.
            if lines.contains(where: { $0.hasPrefix("!") }) {
                return Prepared(payload: lines.joined(separator: "\r\n") + "\r\n", wasExpanded: false)
            }
            return Prepared(payload: input.trimmingCharacters(in: .whitespacesAndNewlines), wasExpanded: false)
        case .sgd:
            var expanded = false
            let converted = normalizedLines(input).map { line -> String in
                if let first = line.first, "!{}[\"^~".contains(first) { return line }
                if let command = keywordCommand(line) {
                    expanded = true
                    return command
                }
                if let pair = assignment(line) {
                    expanded = true
                    return "! U1 setvar \"\(pair.name)\" \"\(pair.value)\""
                }
                if isVariableName(line) {
                    expanded = true
                    return "! U1 getvar \"\(line)\""
                }
                return line
            }
            guard !converted.isEmpty else { return Prepared(payload: "", wasExpanded: false) }
            return Prepared(payload: converted.joined(separator: "\r\n") + "\r\n", wasExpanded: expanded)
        }
    }

    /// Zeilen ohne führenden/abschließenden Leerraum, leere Zeilen entfernt.
    static func normalizedLines(_ input: String) -> [String] {
        input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// SGD-Variablenname wie `device.languages` oder `ip.dhcp.enable`.
    static func isVariableName(_ text: String) -> Bool {
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
              let first = text.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `name = wert` bzw. `name = "wert"`.
    static func assignment(_ line: String) -> (name: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        guard isVariableName(name), !value.contains("\"") else { return nil }
        return (name, value)
    }

    /// `getvar name`, `setvar name wert`, `do name [wert]`.
    static func keywordCommand(_ line: String) -> String? {
        let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { return nil }
        let keyword = parts[0].lowercased()
        let name = unquote(parts[1])
        guard isVariableName(name) else { return nil }
        let value: String? = parts.count > 2 ? unquote(parts[2].trimmingCharacters(in: .whitespaces)) : nil
        if let value, value.contains("\"") { return nil }
        switch keyword {
        case "getvar":
            return value == nil ? "! U1 getvar \"\(name)\"" : nil
        case "setvar":
            guard let value else { return nil }
            return "! U1 setvar \"\(name)\" \"\(value)\""
        case "do":
            return "! U1 do \"\(name)\" \"\(value ?? "")\""
        default:
            return nil
        }
    }

    private static func unquote(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

// MARK: - Darstellung

enum TerminalFormatter {
    /// Ein Textabschnitt; Steuerzeichen werden als Unicode-Bildzeichen (␂ ␃ ␍ ␊ …) geliefert.
    struct Segment: Equatable {
        var text: String
        var isControl: Bool
    }

    struct SegmentedText: Equatable {
        var segments: [Segment]
        var isTruncated: Bool
        var lineCount: Int
    }

    /// Dekodiert Antwortbytes (UTF-8, sonst ISO-8859-1).
    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return String(decoding: data, as: UTF8.self)
    }

    /// Zerlegt Text in normale Abschnitte und sichtbar gemachte Steuerzeichen.
    /// Zeilenumbrüche bleiben zusätzlich als echte Umbrüche erhalten.
    static func segments(of text: String, limit: Int = Int.max) -> SegmentedText {
        var result: [Segment] = []
        var buffer = ""
        var count = 0
        var lines = 1
        var truncated = false

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(Segment(text: buffer, isControl: false))
            buffer = ""
        }

        func control(_ symbol: String) {
            flush()
            if let last = result.last, last.isControl {
                result[result.count - 1].text += symbol
            } else {
                result.append(Segment(text: symbol, isControl: true))
            }
        }

        for scalar in text.unicodeScalars {
            if count >= limit {
                truncated = true
                break
            }
            count += 1
            switch scalar.value {
            case 0x0A:
                control("␊")
                buffer.append("\n")
                lines += 1
            case 0x0D:
                control("␍")
            case 0x09:
                control("⇥")
                buffer.append("\t")
            case 0x00..<0x20:
                control(controlPicture(scalar.value))
            case 0x7F:
                control("␡")
            case 0x80..<0xA0:
                control(String(format: "‹%02X›", scalar.value))
            default:
                buffer.unicodeScalars.append(scalar)
            }
        }
        flush()
        return SegmentedText(segments: result, isTruncated: truncated, lineCount: lines)
    }

    /// Text mit sichtbaren Steuerzeichen als einfache Zeichenkette (für Export).
    static func visibleString(_ text: String) -> String {
        segments(of: text).segments.map(\.text).joined()
    }

    /// Unicode-Bildzeichen für C0-Steuerzeichen (STX → ␂, ETX → ␃ …).
    static func controlPicture(_ value: UInt32) -> String {
        guard value < 0x20, let scalar = Unicode.Scalar(0x2400 + value) else { return "�" }
        return String(Character(scalar))
    }

    /// Klassischer Hex-Dump: Offset, 16 Bytes (8 + 8) und ASCII-Spalte.
    static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "" }
        let digits = Array("0123456789ABCDEF".utf8)
        let bar = Array("│".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 5 + 32)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            out.append(contentsOf: Array(String(format: "%08X", offset).utf8))
            out.append(0x20)
            out.append(0x20)
            for index in offset..<(offset + 16) {
                if index < end {
                    let byte = bytes[index]
                    out.append(digits[Int(byte >> 4)])
                    out.append(digits[Int(byte & 0x0F)])
                    out.append(0x20)
                } else {
                    out.append(contentsOf: [0x20, 0x20, 0x20])
                }
                if index == offset + 7 { out.append(0x20) }
            }
            out.append(0x20)
            out.append(contentsOf: bar)
            for index in offset..<end {
                let byte = bytes[index]
                out.append(byte >= 0x20 && byte <= 0x7E ? byte : 0x2E)
            }
            out.append(contentsOf: bar)
            out.append(0x0A)
            offset += 16
        }
        if out.last == 0x0A { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    /// Lesbare Byte-Anzahl („82 Bytes“, „12,4 KB“).
    static func byteText(_ count: Int) -> String {
        if count < 10_000 { return tr("%d Bytes", count) }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Eingabeverlauf

enum TerminalHistory {
    static let storageKey = "LabelWerk.Terminal.History"
    static let limit = 80
    /// Größere Eingaben (z. B. eingefügtes ZPL mit Grafikdaten) werden nur für die Sitzung gemerkt,
    /// damit die Benutzereinstellungen klein bleiben.
    static let maxStoredLength = 4_000

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return items
    }

    static func encode(_ items: [String]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Fügt einen Eintrag vorne ein (ohne Dubletten, begrenzt).
    static func adding(_ item: String, to items: [String]) -> [String] {
        var result = items.filter { $0 != item }
        result.insert(item, at: 0)
        return Array(result.prefix(limit))
    }

    /// Darf dauerhaft gespeichert werden: nicht sensibel und nicht zu groß.
    static func isPersistable(_ item: String) -> Bool {
        item.utf8.count <= maxStoredLength && !isSensitive(item)
    }

    /// Einträge mit Passwörtern/Schlüsseln werden nicht dauerhaft gespeichert.
    static func isSensitive(_ item: String) -> Bool {
        let lower = item.lowercased()
        let markers = ["psk", "passphrase", "password", "passwort", "wep.key", "private_key", "secret", "community"]
        return markers.contains { lower.contains($0) }
    }

    /// Flüchtige (sensible) und gespeicherte Einträge zusammenführen, neueste zuerst.
    static func merged(volatile: [String], stored: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in volatile + stored where !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        return result
    }
}

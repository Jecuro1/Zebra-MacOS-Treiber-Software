import Foundation
import LabelWerkCore

/// Zugriff auf die Parameter eines ZPL-Befehls mit firmwareähnlich toleranter Auswertung.
///
/// * Fehlende oder leere Parameter liefern `nil` (der Aufrufer setzt den Standardwert ein).
/// * Zahlen werden wie von der Firmware gelesen: optionales Vorzeichen, dann Ziffern; alles
///   danach wird ignoriert (`"50 "` → 50, `"12abc"` → 12). Werte werden auf ±999 999 999 begrenzt,
///   damit keine Überläufe entstehen.
struct ZPLParameters {
    let values: [String]

    init(_ token: ZPLToken) {
        values = token.parameters
    }

    init(_ values: [String]) {
        self.values = values
    }

    var count: Int { values.count }

    /// Roher Parameter (ohne Trimmen).
    func raw(_ index: Int) -> String? {
        index < values.count ? values[index] : nil
    }

    /// Parameter ohne führende/abschließende Leerzeichen; leer → `nil`.
    func string(_ index: Int) -> String? {
        guard let value = raw(index)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// Erstes Zeichen in Großbuchstaben.
    func character(_ index: Int) -> Character? {
        guard let value = string(index), let first = value.first else { return nil }
        return Character(first.uppercased())
    }

    func int(_ index: Int) -> Int? {
        guard let value = string(index) else { return nil }
        return Self.parseInt(value)
    }

    func int(_ index: Int, in range: ClosedRange<Int>) -> Int? {
        int(index).map { min(max($0, range.lowerBound), range.upperBound) }
    }

    func double(_ index: Int) -> Double? {
        guard let value = string(index) else { return nil }
        var text = ""
        for (offset, character) in value.enumerated() {
            if character.isASCII && (character.isNumber || character == "." || (offset == 0 && (character == "-" || character == "+"))) {
                text.append(character)
            } else {
                break
            }
        }
        guard let number = Double(text), number.isFinite else { return nil }
        return number
    }

    /// Ja/Nein-Parameter (`Y`/`N`); andere Werte → `nil`.
    func bool(_ index: Int) -> Bool? {
        switch character(index) {
        case "Y": return true
        case "N": return false
        default: return nil
        }
    }

    /// Ausrichtung `N`/`R`/`I`/`B`; andere Werte → `nil`.
    func orientation(_ index: Int) -> FieldOrientation? {
        guard let character = character(index) else { return nil }
        return FieldOrientation(rawValue: String(character))
    }

    /// Alle Parameter ab `index`, wieder mit dem Trennzeichen verbunden (für Daten mit Kommas).
    func joined(from index: Int, separator: Character) -> String {
        guard index < values.count else { return "" }
        return values[index...].joined(separator: String(separator))
    }

    /// Liest eine ganze Zahl wie die Firmware (Vorzeichen + Ziffern, Rest ignoriert).
    static func parseInt(_ text: String) -> Int? {
        var negative = false
        var value = 0
        var digits = 0
        var started = false
        for scalar in text.unicodeScalars {
            if !started && (scalar == "-" || scalar == "+") {
                negative = scalar == "-"
                started = true
                continue
            }
            started = true
            guard scalar.value >= 0x30 && scalar.value <= 0x39 else { break }
            if value < 999_999_999 {
                value = min(999_999_999, value * 10 + Int(scalar.value - 0x30))
            }
            digits += 1
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }
}

/// Bezeichner gespeicherter Objekte (`d:NAME.EXT`).
enum ObjectName {
    /// Normalisiert einen Objektnamen: Großbuchstaben, Laufwerk (Standard `defaultDrive`) und
    /// Endung (Standard `defaultExtension`) ergänzt. `"logo"` → `"R:LOGO.GRF"`.
    static func normalize(_ raw: String, defaultDrive: String = "R:", defaultExtension: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if name.isEmpty { name = "UNKNOWN" }
        var drive = defaultDrive
        if let colon = name.firstIndex(of: ":") {
            let prefix = String(name[..<colon])
            drive = prefix.isEmpty ? defaultDrive : prefix + ":"
            name = String(name[name.index(after: colon)...])
            if name.isEmpty { name = "UNKNOWN" }
        }
        if !name.contains(".") { name += defaultExtension }
        return drive + name
    }

    /// Name ohne Laufwerk (für die laufwerksübergreifende Suche).
    static func withoutDrive(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// Einfacher Platzhaltervergleich (`*` beliebig viele, `?` genau ein Zeichen), ohne Groß/Klein.
    static func matches(_ name: String, pattern: String) -> Bool {
        let text = Array(name.uppercased())
        let mask = Array(pattern.uppercased())
        var t = 0, m = 0
        var starM = -1, starT = 0
        while t < text.count {
            if m < mask.count && (mask[m] == "?" || mask[m] == text[t]) {
                t += 1
                m += 1
            } else if m < mask.count && mask[m] == "*" {
                starM = m
                starT = t
                m += 1
            } else if starM >= 0 {
                m = starM + 1
                starT += 1
                t = starT
            } else {
                return false
            }
        }
        while m < mask.count && mask[m] == "*" { m += 1 }
        return m == mask.count
    }
}

/// Zeichenkodierung gemäß `^CI` (nur für `^FH`-Hexbytes relevant – der Eingabetext liegt
/// bereits als Unicode vor).
enum ZPLCharacterSet: Hashable, Sendable {
    case codePage850
    case windows1250
    case windows1251
    case windows1252
    case windows1253
    case windows1254
    case windows1255
    case utf8
    case utf16BigEndian
    case utf16LittleEndian

    /// Kodierung zu einem `^CI`-Wert; `nil` für nicht nachgebildete (asiatische) Kodierungen.
    init?(ciValue: Int) {
        switch ciValue {
        case 0...13: self = .codePage850
        case 27: self = .windows1252
        case 28: self = .utf8
        case 29: self = .utf16BigEndian
        case 30: self = .utf16LittleEndian
        case 31: self = .windows1250
        case 33: self = .windows1251
        case 34: self = .windows1253
        case 35: self = .windows1254
        case 36: self = .windows1255
        default: return nil
        }
    }

    /// Wandelt Bytes in Text um. UTF-8-Fehler fallen auf Windows-1252 zurück (wie viele
    /// Druckertreiber), damit einzelne Latin-1-Bytes lesbar bleiben.
    func decode(_ bytes: [UInt8]) -> String {
        switch self {
        case .utf8:
            if let text = String(strictUTF8: bytes) { return text }
            return Self.decodeSingleByte(bytes, table: CodePageTables.windows1252)
        case .utf16BigEndian, .utf16LittleEndian:
            var units: [UInt16] = []
            var index = 0
            while index + 1 < bytes.count {
                let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
                units.append(self == .utf16BigEndian ? (a << 8 | b) : (b << 8 | a))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        case .codePage850: return Self.decodeSingleByte(bytes, table: CodePageTables.ibm850)
        case .windows1250: return Self.decodeSingleByte(bytes, table: CodePageTables.windows1250)
        case .windows1251: return Self.decodeSingleByte(bytes, table: CodePageTables.windows1251)
        case .windows1252: return Self.decodeSingleByte(bytes, table: CodePageTables.windows1252)
        case .windows1253: return Self.decodeSingleByte(bytes, table: CodePageTables.windows1253)
        case .windows1254: return Self.decodeSingleByte(bytes, table: CodePageTables.windows1254)
        case .windows1255: return Self.decodeSingleByte(bytes, table: CodePageTables.windows1255)
        }
    }

    private static func decodeSingleByte(_ bytes: [UInt8], table: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value = byte < 0x80 ? UInt32(byte) : UInt32(table[Int(byte) - 0x80])
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }
}

extension String {
    /// Strikte UTF-8-Dekodierung (ohne Ersatzzeichen); `nil` bei ungültigen Folgen.
    init?(strictUTF8 bytes: [UInt8]) {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        self = String(scalars)
    }
}

/// Dekodiert `^FH`-Hexsequenzen (`_XX` mit wählbarem Kennzeichen) in Felddaten.
///
/// Aufeinanderfolgende Hexbytes werden gemeinsam gemäß `^CI` dekodiert (z. B. `_C3_A4` → „ä“ bei
/// `^CI28`). Ein Kennzeichen ohne zwei folgende Hexziffern bleibt als Zeichen erhalten.
enum FieldHexDecoder {
    static func decode(_ text: String, indicator: Character, characterSet: ZPLCharacterSet) -> String {
        guard text.contains(indicator) else { return text }
        let characters = Array(text)
        var result = ""
        var pending: [UInt8] = []
        func flush() {
            if !pending.isEmpty {
                result += characterSet.decode(pending)
                pending.removeAll()
            }
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == indicator, index + 2 < characters.count,
               let high = characters[index + 1].hexDigitValue, let low = characters[index + 2].hexDigitValue,
               characters[index + 1].isASCII, characters[index + 2].isASCII {
                pending.append(UInt8(high << 4 | low))
                index += 3
                continue
            }
            flush()
            result.append(character)
            index += 1
        }
        flush()
        return result
    }
}

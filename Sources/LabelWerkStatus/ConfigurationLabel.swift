import Foundation

/// Ein Eintrag der Druckerkonfiguration (`^HH`-Ausgabe bzw. Konfigurationsetikett).
public struct ConfigurationEntry: Hashable, Sendable, Codable {
    /// Bezeichnung, z. B. `DARKNESS` (Leerraum normalisiert).
    public var name: String
    /// Wert, z. B. `+10.0`.
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension Array where Element == ConfigurationEntry {
    /// Wert des ersten Eintrags mit diesem Namen (ohne Beachtung von Groß-/Kleinschreibung
    /// und mehrfachen Leerzeichen).
    public func value(named name: String) -> String? {
        let needle = StatusText.collapseSpaces(name).uppercased()
        return first { StatusText.collapseSpaces($0.name).uppercased() == needle }?.value
    }
}

/// Parser für die `^HH`-Antwort (Konfiguration als Text).
///
/// Jede Zeile enthält links den Wert und rechts die Bezeichnung, getrennt durch Punktführer
/// (`+10.0...............  DARKNESS`) oder – bei älterer Firmware – durch mindestens zwei
/// Leerzeichen (`+15.0               DARKNESS`). Kopfzeilen ohne Trenner (Modell, Hersteller,
/// „PRINTER CONFIGURATION“) werden übersprungen, `STX`/`ETX`-Rahmung wird entfernt.
/// Die Reihenfolge bleibt erhalten; doppelte Bezeichnungen sind möglich.
public enum ConfigurationLabelParser {
    public static func parse(_ text: String) -> [ConfigurationEntry] {
        StatusText.lines(text).compactMap(parseLine)
    }

    /// Variante für Rohdaten.
    public static func parse(data: Data) -> [ConfigurationEntry] {
        parse(StatusText.decode(data))
    }

    static func parseLine(_ line: String) -> ConfigurationEntry? {
        if let entry = parseDotLeaderLine(line) { return entry }
        return parseColumnLine(line)
    }

    /// `WERT.....  NAME` – die erste Folge von mindestens zwei Punkten trennt.
    static func parseDotLeaderLine(_ line: String) -> ConfigurationEntry? {
        let chars = Array(line)
        var index = 0
        while index + 1 < chars.count {
            if chars[index] == ".", chars[index + 1] == "." {
                var end = index
                while end < chars.count, chars[end] == "." { end += 1 }
                let name = StatusText.collapseSpaces(String(chars[end...]))
                guard !name.isEmpty, name.contains(where: { $0.isLetter }) else { return nil }
                let value = cleanValue(String(chars[..<index]))
                return ConfigurationEntry(name: name, value: value)
            }
            index += 1
        }
        return nil
    }

    /// `WERT    NAME` – der letzte Block aus mindestens zwei Leerzeichen (oder Tab) trennt.
    /// Bezeichnungen sind in `^HH` großgeschrieben; das schützt vor Fehldeutung von Fließtext.
    static func parseColumnLine(_ line: String) -> ConfigurationEntry? {
        let chars = Array(StatusText.trim(line))
        var separatorStart: Int?
        var separatorEnd = 0
        var index = 0
        while index < chars.count {
            if chars[index] == " " || chars[index] == "\t" {
                var end = index
                while end < chars.count, chars[end] == " " || chars[end] == "\t" { end += 1 }
                if end - index >= 2 || chars[index] == "\t" {
                    separatorStart = index
                    separatorEnd = end
                }
                index = end
            } else {
                index += 1
            }
        }
        guard let separatorStart, separatorStart > 0, separatorEnd < chars.count else { return nil }
        let name = StatusText.collapseSpaces(String(chars[separatorEnd...]))
        guard name.contains(where: { $0.isLetter }), name == name.uppercased() else { return nil }
        let value = cleanValue(String(chars[..<separatorStart]))
        return ConfigurationEntry(name: name, value: value)
    }

    /// Entfernt Rand-Leerraum und die Markierung `<-` (aktive Einstellung) am Wertende.
    static func cleanValue(_ raw: String) -> String {
        var value = StatusText.trim(raw)
        if value.hasSuffix("<-") {
            value = StatusText.trim(value.dropLast(2))
        }
        return value
    }
}

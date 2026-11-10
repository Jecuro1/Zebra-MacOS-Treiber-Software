import Foundation

/// Eine SGD-Einstellung (Set-Get-Do), z. B. aus `allconfig` oder `allcv`.
public struct SGDSetting: Hashable, Codable, Sendable {
    /// Vollständiger Name, z. B. `device.friendly_name`.
    public var name: String
    /// Aktueller Wert als Text.
    public var value: String
    /// Datentyp laut Drucker (`string`, `integer`, `enum`, `bool`, `ipv4-address` …).
    public var type: String?
    /// Zulässiger Bereich bzw. Auswahl, z. B. `0-17` oder `on,off`.
    public var range: String?
    /// Zugriff (`R`, `W`, `RW`).
    public var access: String?
    /// Wird der Wert bei einem Konfigurations-Backup archiviert?
    public var archive: Bool?
    /// Darf der Wert auf andere Drucker geklont werden? (Erweiterung, aus `allconfig`.)
    public var clone: Bool?

    public init(name: String, value: String, type: String? = nil, range: String? = nil,
                access: String? = nil, archive: Bool? = nil, clone: Bool? = nil) {
        self.name = name
        self.value = value
        self.type = type
        self.range = range
        self.access = access
        self.archive = archive
        self.clone = clone
    }

    /// Bereich vor dem ersten Punkt (`device`, `media`, `ip` …).
    public var group: String {
        name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }

    /// `true`, wenn der Drucker Schreibzugriff meldet (ohne Angabe: `true`).
    public var isWritable: Bool {
        guard let access, !access.isEmpty else { return true }
        return access.uppercased().contains("W")
    }

    /// Auswahlwerte aus ``range``, falls es eine kommagetrennte Liste ist (z. B. `on,off`).
    ///
    /// Numerische Bereiche wie `0-17` oder `1.0-8.0` liefern ein leeres Array.
    public var choices: [String] {
        guard let range, !range.isEmpty, range.contains(",") else { return [] }
        return range.split(separator: ",").map { StatusText.trim($0) }.filter { !$0.isEmpty }
    }

    /// Numerischer Bereich aus ``range`` (z. B. `0-17` → 0…17, `-30 - 30` → −30…30).
    public var numericRange: ClosedRange<Double>? {
        guard let range else { return nil }
        let text = StatusText.trim(range)
        // Trenner ist das erste „-“, das nicht am Anfang steht und nicht direkt auf einen
        // Trenner folgt (negative Untergrenzen bleiben so erhalten).
        var separator: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "-", index > text.startIndex {
                let previous = text[text.index(before: index)]
                if previous.isNumber || previous == " " && text[..<index].contains(where: \.isNumber) {
                    separator = index
                    break
                }
            }
            index = text.index(after: index)
        }
        guard let separator,
              let lower = Double(StatusText.trim(text[..<separator])),
              let upper = Double(StatusText.trim(text[text.index(after: separator)...])),
              lower <= upper else { return nil }
        return lower...upper
    }
}

/// Parser für SGD-Antworten (`getvar`, JSON, `allcv`).
public enum SGDResponseParser {

    // MARK: getvar

    /// Wert einer `! U1 getvar`-Antwort.
    ///
    /// `"203"` → `203`, `"?"`/`?`/leere Antwort → `nil`. Entfernt `NUL`, Rahmung sowie
    /// führende/abschließende Zeilenumbrüche; Zeilenumbrüche innerhalb des Werts
    /// (z. B. `file.dir`) bleiben erhalten. Eine fehlende schließende Anführung
    /// (abgeschnittene Antwort) wird toleriert.
    public static func parseValue(_ data: Data) -> String? {
        parseValue(text: StatusText.decode(data))
    }

    /// Variante für bereits dekodierten Text.
    public static func parseValue(text raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar.value != 0 && scalar.value != 0x02 && scalar.value != 0x03 {
            scalars.append(scalar)
        }
        let text = StatusText.trim(String(scalars))
        guard !text.isEmpty else { return nil }

        var value: String
        if text.first == "\"" {
            let body = text.dropFirst()
            if let closing = body.lastIndex(of: "\"") {
                value = String(body[..<closing])
            } else {
                value = String(body)
            }
        } else {
            value = text
        }
        if StatusText.trim(value) == "?" { return nil }
        // Zeilenenden innerhalb mehrzeiliger Werte vereinheitlichen.
        value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return value
    }

    // MARK: JSON

    /// Wertet JSON-Antworten aus.
    ///
    /// Unterstützt:
    /// * einfache Antworten `{"device.friendly_name":"ZD421"}` (auch mit vorangestelltem `{}`
    ///   aus dem Echo der Anfrage `{}{…}`),
    /// * `allconfig`-Antworten mit Deskriptoren
    ///   `{"name":{"value":"x","type":"string","range":"0-17","clone":true,"archive":true,"access":"RW"}}`,
    ///   auch eingebettet als `{"allconfig":{…}}`,
    /// * verschachtelte Zweige `{"device":{"friendly_name":"x"}}` → `device.friendly_name`.
    ///
    /// `null`-Werte und `"?"` (unbekannte Variablen) werden ausgelassen. Mehrere
    /// aufeinanderfolgende Objekte werden zusammengeführt.
    public static func parseJSON(_ data: Data) throws -> [String: SGDSetting] {
        try parseJSON(text: StatusText.decode(data))
    }

    /// Variante für bereits dekodierten Text.
    public static func parseJSON(text: String) throws -> [String: SGDSetting] {
        var reader = JSONReader(text)
        reader.skipWhitespace()
        guard !reader.isAtEnd else { throw StatusParseError.emptyResponse }
        guard reader.seekObjectStart() else {
            throw StatusParseError.invalidJSON("Kein JSON-Objekt gefunden")
        }
        var result: [String: SGDSetting] = [:]
        repeat {
            let value = try reader.parseValue()
            if case .object(let pairs) = value {
                flatten(pairs, prefix: "", into: &result)
            }
            reader.skipWhitespace()
            // Weitere Objekte (`{}{…}` oder mehrere Antworten) direkt dahinter werden
            // zusammengeführt; anderer nachfolgender Text (Fremddaten) wird ignoriert.
        } while reader.peekIsObjectStart
        return result
    }

    /// Schlüssel, deren Objekte keine Zweige, sondern Sammelcontainer sind.
    static let containerKeys: Set<String> = ["allconfig", "allcv", "getvar", "values"]

    static func flatten(_ pairs: [(key: String, value: JSONValue)], prefix: String,
                        into result: inout [String: SGDSetting]) {
        for (key, value) in pairs {
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            switch value {
            case .object(let inner):
                if value["value"] != nil {
                    result[name] = descriptor(name: name, object: value)
                } else if prefix.isEmpty, containerKeys.contains(key.lowercased()) {
                    flatten(inner, prefix: "", into: &result)
                } else {
                    flatten(inner, prefix: name, into: &result)
                }
            case .null:
                continue
            default:
                guard let text = value.scalarText, StatusText.trim(text) != "?" else { continue }
                result[name] = SGDSetting(name: name, value: text)
            }
        }
    }

    static func descriptor(name: String, object: JSONValue) -> SGDSetting {
        func text(_ key: String) -> String? {
            guard let value = object[key], let text = value.scalarText else { return nil }
            return text
        }
        return SGDSetting(
            name: name,
            value: object["value"]?.scalarText ?? "",
            type: text("type"),
            range: text("range"),
            access: text("access"),
            archive: object["archive"]?.boolValue,
            clone: object["clone"]?.boolValue
        )
    }

    // MARK: allcv

    /// Wertet die Textausgabe von `! U1 getvar "allcv"` aus.
    ///
    /// Zeilenformat: `device.friendly_name : ZD421 , Choices: A string of 0 - 17 characters`.
    /// Der Text hinter `Choices:` landet in ``SGDSetting/range``. Werte dürfen Kommas
    /// enthalten (`epl_zpl,zpl`), Anführungszeichen um Werte werden entfernt. Zeilen ohne
    /// erkennbaren SGD-Namen werden übersprungen.
    public static func parseAllCV(_ text: String) -> [String: SGDSetting] {
        var result: [String: SGDSetting] = [:]
        // Die gesamte Antwort kann selbst in Anführungszeichen stehen.
        var body = text
        if let unwrapped = parseValue(text: text), StatusText.trim(text).hasPrefix("\"") { body = unwrapped }
        for line in StatusText.lines(body) {
            guard let setting = parseAllCVLine(line) else { continue }
            result[setting.name] = setting
        }
        return result
    }

    static func parseAllCVLine(_ line: String) -> SGDSetting? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = StatusText.trim(line[..<colon])
        guard isSGDName(name) else { return nil }
        let remainder = line[line.index(after: colon)...]

        var valuePart = Substring(remainder)
        var choices: String?
        if let marker = remainder.range(of: "Choices:", options: .caseInsensitive) {
            choices = StatusText.trim(remainder[marker.upperBound...])
            valuePart = remainder[..<marker.lowerBound]
            // Trennendes Komma vor „Choices:“ entfernen.
            var trimmedValue = StatusText.trimTrailing(valuePart)
            if trimmedValue.hasSuffix(",") { trimmedValue.removeLast() }
            valuePart = Substring(trimmedValue)
        }
        var value = StatusText.trim(valuePart)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        if value == "?" { return nil }
        return SGDSetting(name: name, value: value, range: (choices?.isEmpty ?? true) ? nil : choices)
    }

    /// SGD-Namen bestehen aus Buchstaben, Ziffern, `.`, `_` und `-`, mit mindestens einem Punkt.
    static func isSGDName(_ name: String) -> Bool {
        guard !name.isEmpty, name.contains("."), name.first != ".", name.last != "." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "." || scalar == "_" || scalar == "-"
        }
    }
}

import Foundation

/// Eine eingerichtete CUPS-Warteschlange.
public struct CUPSQueueInfo: Hashable, Sendable, Codable {
    public var name: String
    public var deviceURI: String
    public var isDefault: Bool
    /// `printer-make-and-model` (Treiberbezeichnung), falls ermittelbar.
    public var makeAndModel: String?

    public init(name: String, deviceURI: String, isDefault: Bool, makeAndModel: String? = nil) {
        self.name = name
        self.deviceURI = deviceURI
        self.isDefault = isDefault
        self.makeAndModel = makeAndModel
    }

    /// Modellhinweis aus Treiberbezeichnung bzw. Geräte-URI.
    public var modelHint: String? {
        if let makeAndModel, !makeAndModel.isEmpty, ZebraIdentifiers.looksLikeZebra(makeAndModel) {
            return makeAndModel
        }
        return CUPSQueueLister.modelHint(fromDeviceURI: deviceURI) ?? makeAndModel
    }

    /// `true`, wenn Warteschlange, Treiber oder Geräte-URI auf einen Zebra-Drucker hindeuten.
    public var looksLikeZebra: Bool {
        if let makeAndModel, ZebraIdentifiers.looksLikeZebra(makeAndModel) || makeAndModel.localizedCaseInsensitiveContains("LabelWerk") {
            return true
        }
        let decodedURI = deviceURI.removingPercentEncoding ?? deviceURI
        if ZebraIdentifiers.looksLikeZebra(decodedURI) { return true }
        if let hint = CUPSQueueLister.modelHint(fromDeviceURI: deviceURI), ZebraIdentifiers.looksLikeZebra(hint) { return true }
        return ZebraIdentifiers.looksLikeZebra(name)
    }
}

/// Liest die eingerichteten CUPS-Warteschlangen über die Kommandozeilenwerkzeuge.
public enum CUPSQueueLister {
    /// Alle Warteschlangen (`lpstat -v`, Standardziel aus `lpstat -d`, Treiber aus `lpoptions -p`).
    ///
    /// Liefert ein leeres Feld, wenn `lpstat` fehlt oder der CUPS-Dienst nicht läuft.
    /// Blockiert den aufrufenden Thread (Prozessaufrufe) – nicht auf dem Main-Thread verwenden.
    public static func queues() -> [CUPSQueueInfo] {
        guard let lpstat = ProcessRunner.locate("lpstat", preferred: ["/usr/bin/lpstat"]) else { return [] }
        let environment = ProcessRunner.neutralEnvironment()
        guard let devices = try? ProcessRunner.run(lpstat, arguments: ["-v"], environment: environment, timeout: 15),
              !devices.timedOut
        else { return [] }
        let entries = parseLpstatV(devices.outputText)
        guard !entries.isEmpty else { return [] }

        var defaultName: String?
        if let output = try? ProcessRunner.run(lpstat, arguments: ["-d"], environment: environment, timeout: 10) {
            defaultName = parseLpstatD(output.outputText)
        }
        let lpoptions = ProcessRunner.locate("lpoptions", preferred: ["/usr/bin/lpoptions"])

        var result: [CUPSQueueInfo] = []
        for entry in entries where !result.contains(where: { $0.name == entry.name }) {
            var makeAndModel: String?
            if let lpoptions,
               let output = try? ProcessRunner.run(lpoptions, arguments: ["-p", entry.name], timeout: 10),
               output.succeeded {
                let options = parseLpoptions(output.outputText)
                makeAndModel = options["printer-make-and-model"].flatMap { $0.isEmpty ? nil : $0 }
            }
            result.append(CUPSQueueInfo(
                name: entry.name,
                deviceURI: entry.uri,
                isDefault: entry.name == defaultName,
                makeAndModel: makeAndModel
            ))
        }
        return result
    }

    /// Asynchrone Variante von `queues()` (läuft auf einer Hintergrund-Queue).
    public static func queuesAsync() async -> [CUPSQueueInfo] {
        (try? await BlockingIO.run { _ in queues() }) ?? []
    }

    /// Wertet die Ausgabe von `lpstat -v` aus (englisch oder deutsch).
    ///
    /// Erkannte Zeilen: `device for NAME: URI`, `Gerät für NAME: URI` (auch `Geraet fuer`),
    /// sowie weitere Sprachen nach dem Muster `<Text> NAME: URI`. Namen dürfen Leerzeichen und
    /// Doppelpunkte enthalten; als Trenner gilt das erste „: “, auf das eine URI folgt.
    public static func parseLpstatV(_ text: String) -> [(name: String, uri: String)] {
        let knownPrefixes = [
            "device for ", "gerät für ", "geraet fuer ", "geraet für ", "gerät fuer ",
            "périphérique pour ", "dispositivo para ", "dispositivo per ", "apparaat voor ",
        ]
        var result: [(name: String, uri: String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            var body = Substring(line)
            var hadPrefix = false
            for prefix in knownPrefixes where lower.hasPrefix(prefix) {
                body = line.dropFirst(prefix.count)
                hadPrefix = true
                break
            }
            guard let split = splitNameAndURI(body) else { continue }
            var name = split.name
            if !hadPrefix {
                // Unbekannte Sprache: Der Name ist das letzte Wort vor dem Trenner.
                name = name.split(separator: " ").last.map(String.init) ?? name
            }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !split.uri.isEmpty else { continue }
            result.append((name: name, uri: split.uri))
        }
        return result
    }

    /// Wertet `lpstat -d` aus: `system default destination: NAME` bzw.
    /// `Standardziel des Systems: NAME`. Liefert `nil`, wenn kein Standardziel gesetzt ist.
    public static func parseLpstatD(_ text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.lowercased().hasPrefix("lpstat:"), let range = line.range(of: ": ") else { continue }
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Wertet `lpoptions -p NAME` aus: `schlüssel=wert` getrennt durch Leerzeichen, Werte ggf. in
    /// einfachen/doppelten Anführungszeichen oder mit Backslash maskiert.
    public static func parseLpoptions(_ text: String) -> [String: String] {
        var options: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var quote: Character?
        var escaped = false

        func flush() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty { options[trimmedKey] = readingValue ? value : "" }
            key = ""
            value = ""
            readingValue = false
        }

        for character in text {
            if escaped {
                if readingValue { value.append(character) } else { key.append(character) }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { value.append(character) }
                continue
            }
            if readingValue, character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character == " " || character == "\t" || character.isNewline {
                flush()
                continue
            }
            if character == "=", !readingValue {
                readingValue = true
                continue
            }
            if readingValue { value.append(character) } else { key.append(character) }
        }
        flush()
        return options
    }

    /// Modellhinweis aus einer Geräte-URI.
    ///
    /// * `usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=…` → `"ZTC ZD421-203dpi ZPL"`
    /// * `dnssd://Zebra%20ZD421._pdl-datastream._tcp.local./?uuid=…` → `"Zebra ZD421"`
    /// * `socket://…`, `ipp://…`, `lpd://…` → `nil` (kein Modell in der URI)
    public static func modelHint(fromDeviceURI uri: String) -> String? {
        guard let schemeRange = uri.range(of: "://") else { return nil }
        let scheme = uri[..<schemeRange.lowerBound].lowercased()
        var rest = uri[schemeRange.upperBound...]
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = rest[..<cut]
        }
        let host: Substring
        let path: Substring
        if let slash = rest.firstIndex(of: "/") {
            host = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        } else {
            host = rest
            path = ""
        }

        func decoded(_ text: Substring) -> String? {
            let value = (String(text).removingPercentEncoding ?? String(text))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
            return value.isEmpty ? nil : value
        }

        switch scheme {
        case "usb":
            return decoded(path)
        case "dnssd", "mdns":
            guard let service = decoded(host) else { return nil }
            if let typeStart = service.range(of: "._") {
                let name = service[..<typeStart.lowerBound].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
            return service
        default:
            return nil
        }
    }

    // MARK: Intern

    /// Trennt „NAME: URI“ am ersten „: “, auf das eine URI (Schema oder absoluter Pfad) folgt.
    private static func splitNameAndURI(_ body: Substring) -> (name: String, uri: String)? {
        var searchStart = body.startIndex
        while let range = body.range(of: ": ", range: searchStart..<body.endIndex) {
            let name = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let uri = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, looksLikeURI(uri) { return (name, uri) }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func looksLikeURI(_ text: String) -> Bool {
        if text.hasPrefix("/") { return true }
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isLetter, first.isASCII else { return false }
        return scheme.allSatisfy { ($0.isLetter || $0.isNumber || "+-.".contains($0)) && $0.isASCII }
    }
}

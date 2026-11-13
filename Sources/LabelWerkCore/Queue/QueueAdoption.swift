import Foundation

/// Übernahme fremder macOS-Warteschlangen (ARCHITECTURE.md §9 „Übernahme von macOS-Warteschlangen“).
///
/// Wer einen Zebra-Drucker in „Systemeinstellungen › Drucker & Scanner“ per IP-Adresse hinzufügt,
/// erhält eine Warteschlange mit Apples AirPrint- bzw. einem allgemeinen Treiber (Name z. B.
/// „10.62.13.19“) – ohne Etikettengröße, Drehung und „An Etikett anpassen“. Führt ihre Geräte-URI zu
/// einem in LabelWerk eingerichteten Drucker, stellt die App sie automatisch auf den LabelWerk-Treiber
/// um. Diese reine Entscheidung (ohne CUPS-Aufrufe) ist unter Linux getestet.
///
/// Regel:
/// * Nur Netzwerk-URIs (`socket`, `labelwerk`, `ipp`, `ipps`, `lpd`, `http`, `https`); `usb://`, `dnssd://`,
///   `file:` und Hüllen wie `beh:/…` gehören zu keinem Host und bleiben unberührt.
/// * Nur URIs, die das Gerät selbst nennen (``deviceEndpoint(ofDeviceURI:)``): kein Loopback-Host
///   (`localhost`, `127.x.x.x`, `::1`), bei IPP/HTTP nur die Endpunkte eines Druckers (Pfad leer, `/`,
///   `/ipp`, `/ipp/…`), bei LPD nur die Standardwarteschlange (leer bzw. `/`). Warteschlangen eines
///   Druckservers (`/printers/…`, `/classes/…` von CUPS, macOS und Windows, benannte
///   LPD-Warteschlangen eines Druckservers mit mehreren Anschlüssen) gehören zu einem anderen Gerät.
/// * Host gleich (ohne Groß-/Kleinschreibung, ohne Port, Pfad, Benutzerangabe, eckige Klammern und
///   abschließenden Punkt) dem Host eines eingerichteten Druckers.
/// * `socket://` (und `labelwerk://`, das Backend von LabelWerk auf demselben Rohdatenport) nennt mit dem
///   Port das Gerät (Druckserver mit mehreren Anschlüssen): Der Port muss dem des Druckers entsprechen
///   (ohne Angabe 9100). Bei den übrigen Protokollen bezeichnet der Port nur den Dienst.
/// * Mit LabelWerk-Treiber (PPD mit `*lwModel`, sonst „LabelWerk“ in `printer-make-and-model`): nichts
///   umzustellen (``Decision/labelWerk(printerID:)``).
/// * Sonst umstellen: Geräte-URI `socket://<host>:<port>` des Druckers (Rohdatenport, den jeder
///   Zebra-Netzwerkdrucker bietet); eine `socket://`- bzw. `labelwerk://`-URI bleibt unverändert. Ob
///   daraus `labelwerk://` wird, entscheidet beim Umstellen ``QueueDeviceURI`` (Einstellung
///   „Bei Papier- oder Farbbandende anhalten und fortsetzen“).
public enum QueueAdoption {

    /// Rohdatenport der Zebra-Netzwerkdrucker.
    public static let rawPort = 9100

    /// Schemata, deren URI einen Host nennt.
    public static let networkSchemes: Set<String> = ["socket", QueueDeviceURI.backendScheme, "ipp", "ipps", "lpd",
                                                     "http", "https"]

    /// Schemata des Rohdatenports, deren Port das Gerät nennt (`socket://`, `labelwerk://`).
    public static let rawSchemes: Set<String> = ["socket", QueueDeviceURI.backendScheme]

    /// Ein in LabelWerk eingerichteter Netzwerkdrucker.
    public struct RegisteredPrinter: Equatable, Sendable {
        /// Kennung des Druckers (kommt in der Entscheidung zurück).
        public var id: String
        /// Hostname oder IP-Adresse, unter der LabelWerk den Drucker erreicht.
        public var host: String
        /// Rohdatenport (LabelWerk-Verbindung), Standard 9100.
        public var port: Int

        public init(id: String, host: String, port: Int = QueueAdoption.rawPort) {
            self.id = id
            self.host = host
            self.port = port
        }
    }

    /// Ergebnis für eine Warteschlange.
    public enum Decision: Equatable, Sendable {
        /// Fremder Treiber, Gerät eines eingerichteten Druckers: auf LabelWerk umstellen, Geräte-URI
        /// danach `deviceURI`.
        case adopt(printerID: String, deviceURI: String)
        /// Schon mit LabelWerk-Treiber, Gerät eines eingerichteten Druckers.
        case labelWerk(printerID: String)
        /// Gehört zu keinem eingerichteten Drucker (anderer Host, USB, Bonjour, Datei …): nie ändern.
        case ignore
    }

    /// Schema, Host und Port einer Geräte-URI.
    public struct Endpoint: Equatable, Sendable {
        /// Schema in Kleinbuchstaben (`socket`, `ipp` …).
        public var scheme: String
        /// Normalisierter Host (``normalizedHost(_:)``).
        public var host: String
        /// Port, falls angegeben.
        public var port: Int?

        public init(scheme: String, host: String, port: Int?) {
            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }

    // MARK: Entscheidung

    /// Entscheidet, ob LabelWerk eine Warteschlange übernimmt.
    ///
    /// - Parameters:
    ///   - queueName: Name der Warteschlange (leer → ``Decision/ignore``).
    ///   - deviceURI: Geräte-URI laut `lpstat -v`.
    ///   - makeAndModel: `printer-make-and-model` (enthält es „LabelWerk“, gilt die Warteschlange
    ///     als LabelWerk-Warteschlange, auch wenn `isLabelWerk` `false` ist).
    ///   - isLabelWerk: Die PPD der Warteschlange stammt von LabelWerk (`*lwModel`).
    ///   - printers: eingerichtete Netzwerkdrucker; bei mehreren passenden gilt der erste.
    public static func decide(queueName: String, deviceURI: String, makeAndModel: String?, isLabelWerk: Bool,
                              printers: [RegisteredPrinter]) -> Decision {
        guard !queueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = deviceEndpoint(ofDeviceURI: deviceURI),
              let printer = printers.first(where: { matches(endpoint, $0) })
        else { return .ignore }
        if isLabelWerk || makeAndModel?.range(of: "LabelWerk", options: .caseInsensitive) != nil {
            return .labelWerk(printerID: printer.id)
        }
        let uri = rawSchemes.contains(endpoint.scheme)
            ? deviceURI.trimmingCharacters(in: .whitespacesAndNewlines)
            : socketURI(host: printer.host, port: printer.port)
        return .adopt(printerID: printer.id, deviceURI: uri)
    }

    /// Führt die Geräte-URI zu diesem Drucker?
    static func matches(_ endpoint: Endpoint, _ printer: RegisteredPrinter) -> Bool {
        guard let host = normalizedHost(printer.host), host == endpoint.host else { return false }
        guard rawSchemes.contains(endpoint.scheme) else { return true }
        return (endpoint.port ?? rawPort) == printer.port
    }

    /// Eingerichteter Drucker, dessen LabelWerk-Verbindung selbst eine macOS-Warteschlange ist
    /// (`ConnectionDescriptor.cupsQueue`): Host und Port stammen aus deren Geräte-URI (`socket://` bzw.
    /// `labelwerk://` mit ihrem Port, sonst ``rawPort``). `nil`, wenn die URI nicht das Gerät selbst nennt
    /// (``deviceEndpoint(ofDeviceURI:)``: USB, Bonjour, Datei, Loopback, die Warteschlange eines
    /// Druckservers wie `ipp://server/printers/Zebra` – dessen Host ist nicht der Drucker).
    public static func registeredPrinter(id: String, queueDeviceURI uri: String) -> RegisteredPrinter? {
        guard let endpoint = deviceEndpoint(ofDeviceURI: uri) else { return nil }
        let port = rawSchemes.contains(endpoint.scheme) ? (endpoint.port ?? rawPort) : rawPort
        return RegisteredPrinter(id: id, host: endpoint.host, port: port)
    }

    // MARK: Gerät oder Druckserver

    /// Schema, Host und Port einer Geräte-URI, die das Gerät **selbst** nennt – sonst `nil`:
    /// * Schema aus ``networkSchemes``, Host kein Loopback (``isLoopbackHost(_:)``: über `localhost`
    ///   erreichte Ziele sind Tunnel, Proxys oder ein lokaler Druckserver, nie das Gerät selbst);
    /// * `socket`, `labelwerk`: jeder Pfad (der Port nennt das Gerät);
    /// * `ipp`, `ipps`, `http`, `https`: nur die IPP-Endpunkte eines Druckers – Pfad leer, `/`, `/ipp`
    ///   oder `/ipp/…` (`/ipp/print` von AirPrint/IPP Everywhere). Freigaben eines CUPS-, macOS- oder
    ///   Windows-Druckservers (`/printers/<name>`, `/classes/<name>`, `/printers/<name>/.printer`) und
    ///   alle anderen Pfade führen zu einem Druckserver bzw. einem unbekannten Gerät;
    /// * `lpd`: nur die Standardwarteschlange (Pfad leer bzw. `/`, so legt „Drucker & Scanner“ ohne
    ///   Angabe einer Warteschlange an) – eine benannte Warteschlange kann ein Druckserver bzw. ein
    ///   Anschluss eines Druckservers mit mehreren Anschlüssen sein (`lpd://host/PORT2`).
    public static func deviceEndpoint(ofDeviceURI uri: String) -> Endpoint? {
        guard let endpoint = endpoint(ofDeviceURI: uri), networkSchemes.contains(endpoint.scheme),
              !isLoopbackHost(endpoint.host)
        else { return nil }
        let path = self.path(ofDeviceURI: uri).lowercased()
        switch endpoint.scheme {
        case "socket", QueueDeviceURI.backendScheme:
            return endpoint
        case "lpd":
            return path.isEmpty || path == "/" ? endpoint : nil
        default:
            return path.isEmpty || path == "/" || path == "/ipp" || path.hasPrefix("/ipp/") ? endpoint : nil
        }
    }

    /// Pfad einer URI ohne Abfrage und Fragment (`ipp://h:631/ipp/print?x=1` → `/ipp/print`), leer ohne
    /// Pfad bzw. ohne `://`. Prozentkodierte Zeichen bleiben kodiert.
    public static func path(ofDeviceURI uri: String) -> String {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else { return "" }
        let rest = trimmed[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let beforeQuery = rest[..<end]
        guard let slash = beforeQuery.firstIndex(of: "/") else { return "" }
        return String(beforeQuery[slash...])
    }

    /// Loopback-Host (normalisiert, ``normalizedHost(_:)``): `localhost` und `*.localhost`,
    /// `127.0.0.0/8`, `::1` (auch ausgeschrieben) und `::ffff:127.x.x.x`.
    public static func isLoopbackHost(_ host: String) -> Bool {
        guard let value = normalizedHost(host) else { return false }
        if value == "localhost" || value.hasSuffix(".localhost") { return true }
        if isIPv4Literal(value) { return value.hasPrefix("127.") }
        let address = String(value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard isIPv6Literal(address) else { return false }
        if address.hasPrefix("::ffff:") {
            let mapped = String(address.dropFirst("::ffff:".count))
            return isIPv4Literal(mapped) && mapped.hasPrefix("127.")
        }
        // ::1 in jeder Schreibweise: alle Gruppen 0 bis auf die letzte = 1.
        let groups = address.components(separatedBy: ":")
        guard groups.count >= 3, groups.count <= 8, groups.allSatisfy({ $0.count <= 4 }),
              let last = groups.last, let lastValue = Int(last, radix: 16), lastValue == 1
        else { return false }
        return groups.dropLast().allSatisfy { $0.isEmpty || Int($0, radix: 16) == 0 }
    }

    // MARK: Namen

    /// Beschreibung (`printer-info`, `lpadmin -D`) einer übernommenen Warteschlange – so heißt sie im
    /// Druckdialog statt „10.62.13.19“; der Name der Warteschlange selbst bleibt.
    ///
    /// Grundlage ist der Name des Druckers in LabelWerk; ist der nur eine Adresse
    /// (``isAddressName(_:host:)``), der Modellname („Zebra ZD421t“). Hat der Drucker schon eine andere
    /// Warteschlange (seine LabelWerk-Warteschlange trägt im Druckdialog denselben Namen), folgt der
    /// Name der übernommenen in Klammern: „Zebra ZD421t (10.62.13.19)“.
    public static func queueDescription(printerName: String, modelName: String?, host: String?, queueName: String,
                                        printerHasOtherQueue: Bool) -> String {
        var name = printerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || isAddressName(name, host: host),
           let model = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            name = model
        }
        guard !name.isEmpty else { return queueName }
        if printerHasOtherQueue, name.caseInsensitiveCompare(queueName) != .orderedSame {
            return "\(name) (\(queueName))"
        }
        return name
    }

    /// Ist `name` nur eine Netzwerkadresse – eine IPv4- oder IPv6-Adresse (auch in eckigen Klammern
    /// oder mit Port) oder der Host `host` der Verbindung (ohne Groß-/Kleinschreibung, auch mit Port)?
    /// So benennen „Drucker & Scanner“ („10.62.13.19“) und die Netzwerksuche ohne Modell einen
    /// Drucker; LabelWerk schlägt dann den Modellnamen vor.
    public static func isAddressName(_ name: String, host: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
              let candidate = endpoint(ofDeviceURI: "x://" + trimmed)?.host
        else { return false }
        if let host, let other = normalizedHost(host), other == candidate { return true }
        return isIPv4Literal(candidate) || isIPv6Literal(candidate)
    }

    /// Vier Dezimalzahlen 0…255 mit Punkten (`10.62.13.19`).
    static func isIPv4Literal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && Int(part).map { $0 <= 255 } == true
        }
    }

    /// IPv6-Adresse, optional mit Zone (`fe80::1%en0`, `2001:db8::7`, `::ffff:10.0.0.1`).
    static func isIPv6Literal(_ text: String) -> Bool {
        let address = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard address.filter({ $0 == ":" }).count >= 2 else { return false }
        return address.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }
    }

    // MARK: URIs

    /// Vergleichbarer Host: ohne eckige Klammern (IPv6), Prozentkodierung (`%25` der Zone) und
    /// abschließende Punkte (`zd421.local.`), in Kleinbuchstaben. `nil` bei leerem Host.
    public static func normalizedHost(_ host: String) -> String? {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        value = (value.removingPercentEncoding ?? value).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    /// Schema, Host und Port einer Geräte-URI (`socket://10.62.13.19:9100`,
    /// `ipp://ZD421.local.:631/ipp/print`, `lpd://user@[fe80::1%25en0]/queue`). `nil`, wenn die URI
    /// keinen Host nennt (`file:/dev/null`, `usb://…` liefert den Hersteller als „Host“ – Aufrufer
    /// prüfen das Schema).
    public static func endpoint(ofDeviceURI uri: String) -> Endpoint? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<range.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        var authority = String(trimmed[range.upperBound...])
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(authority[..<end])
        }
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        var host = authority
        var port: Int?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.startIndex...close])
            let rest = authority[authority.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
        } else if authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") {
            host = String(authority[..<colon])
            port = Int(authority[authority.index(after: colon)...])
        }
        guard let normalized = normalizedHost(host) else { return nil }
        return Endpoint(scheme: scheme, host: normalized, port: port)
    }

    /// `socket://`-URI eines Netzwerkdruckers. IPv6-Adressen stehen in eckigen Klammern, eine
    /// Zonenangabe als `%25` (`socket://[fe80::1%25en0]:9100`).
    public static func socketURI(host: String, port: Int) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard bare.contains(":") else { return "socket://\(bare):\(port)" }
        let zoneEncoded = bare.replacingOccurrences(of: "%25", with: "%").replacingOccurrences(of: "%", with: "%25")
        return "socket://[\(zoneEncoded)]:\(port)"
    }
}

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
/// * Nur Netzwerk-URIs (`socket`, `ipp`, `ipps`, `lpd`, `http`, `https`); `usb://`, `dnssd://`,
///   `file:` und Hüllen wie `beh:/…` gehören zu keinem Host und bleiben unberührt.
/// * Host gleich (ohne Groß-/Kleinschreibung, ohne Port, Pfad, Benutzerangabe, eckige Klammern und
///   abschließenden Punkt) dem Host eines eingerichteten Druckers.
/// * `socket://` nennt mit dem Port das Gerät (Druckserver mit mehreren Anschlüssen): Der Port muss dem
///   des Druckers entsprechen (ohne Angabe 9100). Bei den übrigen Protokollen bezeichnet der Port nur
///   den Dienst.
/// * Mit LabelWerk-Treiber (PPD mit `*lwModel`, sonst „LabelWerk“ in `printer-make-and-model`): nichts
///   umzustellen (``Decision/labelWerk(printerID:)``).
/// * Sonst umstellen: Geräte-URI `socket://<host>:<port>` des Druckers (Rohdatenport, den jeder
///   Zebra-Netzwerkdrucker bietet); eine `socket://`-URI bleibt unverändert.
public enum QueueAdoption {

    /// Rohdatenport der Zebra-Netzwerkdrucker.
    public static let rawPort = 9100

    /// Schemata, deren URI einen Host nennt.
    public static let networkSchemes: Set<String> = ["socket", "ipp", "ipps", "lpd", "http", "https"]

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
              let endpoint = endpoint(ofDeviceURI: deviceURI),
              networkSchemes.contains(endpoint.scheme),
              let printer = printers.first(where: { matches(endpoint, $0) })
        else { return .ignore }
        if isLabelWerk || makeAndModel?.range(of: "LabelWerk", options: .caseInsensitive) != nil {
            return .labelWerk(printerID: printer.id)
        }
        let uri = endpoint.scheme == "socket"
            ? deviceURI.trimmingCharacters(in: .whitespacesAndNewlines)
            : socketURI(host: printer.host, port: printer.port)
        return .adopt(printerID: printer.id, deviceURI: uri)
    }

    /// Führt die Geräte-URI zu diesem Drucker?
    static func matches(_ endpoint: Endpoint, _ printer: RegisteredPrinter) -> Bool {
        guard let host = normalizedHost(printer.host), host == endpoint.host else { return false }
        guard endpoint.scheme == "socket" else { return true }
        return (endpoint.port ?? rawPort) == printer.port
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

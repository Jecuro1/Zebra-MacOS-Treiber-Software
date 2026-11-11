import Foundation
import LabelWerkCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - IPv4-Bereich

/// Zusammenhängender IPv4-Adressbereich (beide Enden eingeschlossen, Host-Byte-Reihenfolge).
public struct IPv4Range: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let first: UInt32
    public let last: UInt32

    public init?(first: UInt32, last: UInt32) {
        guard first <= last else { return nil }
        self.first = first
        self.last = last
    }

    /// CIDR-Block, der `address` enthält (Hostanteil wird abgeschnitten).
    public init(containing address: UInt32, prefix: Int) {
        let bits = min(max(prefix, 0), 32)
        let mask: UInt32 = bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
        first = address & mask
        last = first | ~mask
    }

    /// Einzelne Adresse.
    public init(single address: UInt32) {
        first = address
        last = address
    }

    /// Anzahl der Adressen im Bereich.
    public var count: UInt64 { UInt64(last) - UInt64(first) + 1 }

    /// Präfixlänge, wenn der Bereich genau ein CIDR-Block ist (z. B. 24), sonst `nil`.
    public var cidrPrefix: Int? {
        let size = count
        guard size.nonzeroBitCount == 1 else { return nil }
        let hostBits = size.trailingZeroBitCount
        guard UInt64(first) & (size - 1) == 0 else { return nil }
        return 32 - hostBits
    }

    /// Zu prüfende Hostadressen: Bei CIDR-Blöcken bis /30 ohne Netz- und Broadcastadresse,
    /// sonst der ganze Bereich (ausdrücklich angegebene Bereiche wie „…1-…254“ bleiben, wie sie sind).
    public var hostBounds: (first: UInt32, last: UInt32) {
        if let prefix = cidrPrefix, prefix <= 30 { return (first + 1, last - 1) }
        return (first, last)
    }

    /// Anzahl der zu prüfenden Hostadressen.
    public var hostCount: Int {
        let bounds = hostBounds
        return Int(UInt64(bounds.last) - UInt64(bounds.first) + 1)
    }

    /// Directed-Broadcast-Adresse („10.62.13.255“) bei CIDR-Blöcken bis /30, sonst `nil`.
    public var broadcastAddress: String? {
        guard let prefix = cidrPrefix, prefix <= 30 else { return nil }
        return SubnetScanner.formatIPv4(last)
    }

    public func contains(_ address: UInt32) -> Bool { address >= first && address <= last }

    public func contains(host: String) -> Bool {
        SubnetScanner.parseIPv4(host).map(contains) ?? false
    }

    /// `true`, wenn `other` vollständig in diesem Bereich liegt.
    public func covers(_ other: IPv4Range) -> Bool { other.first >= first && other.last <= last }

    /// Die ersten `limit` Hostadressen, aufsteigend.
    public func hosts(limit: Int = DiscoveryNetworks.maxHostsPerEntry) -> [String] {
        guard limit > 0 else { return [] }
        let bounds = hostBounds
        let count = min(UInt64(limit), UInt64(bounds.last) - UInt64(bounds.first) + 1)
        return (0..<count).map { SubnetScanner.formatIPv4(UInt32(UInt64(bounds.first) + $0)) }
    }

    /// „10.62.13.0/24“, „10.62.13.20–10.62.13.40“ bzw. „10.62.13.19“.
    public var description: String {
        if first == last { return SubnetScanner.formatIPv4(first) }
        if let prefix = cidrPrefix { return "\(SubnetScanner.formatIPv4(first))/\(prefix)" }
        return "\(SubnetScanner.formatIPv4(first))–\(SubnetScanner.formatIPv4(last))"
    }

    public static func < (lhs: IPv4Range, rhs: IPv4Range) -> Bool {
        (lhs.first, lhs.last) < (rhs.first, rhs.last)
    }
}

// MARK: - Netze der Suche

/// Ein Netz bzw. Adressbereich, der zusätzlich zu den lokalen Subnetzen durchsucht werden soll.
public struct DiscoveryNetworkEntry: Hashable, Sendable, Codable {
    /// Woher ein durchsuchtes Netz stammt.
    public enum Origin: String, Hashable, Sendable, Codable, CaseIterable {
        /// Subnetz einer lokalen Netzwerkschnittstelle (WLAN, Ethernet).
        case local
        /// /24 eines VPN-Tunnels mit privater Adresse (RFC 1918), z. B. FortiClient `utun`.
        case vpn
        /// /24 eines Druckers, den LabelWerk oder macOS bereits kennt.
        case knownPrinter
        /// Vom Benutzer eingetragen.
        case user
    }

    /// Angabe wie „10.62.13.0/24“, „10.62.13.1-10.62.13.254“, „10.62.13.*“ oder „10.62.13.19“.
    public var text: String
    public var origin: Origin
    /// Herkunft für die Anzeige (Druckername, Schnittstelle).
    public var label: String?

    public init(_ text: String, origin: Origin = .user, label: String? = nil) {
        self.text = text
        self.origin = origin
        self.label = label
    }
}

/// Ein Netz, das eine Suche tatsächlich durchsucht (Ergebnis von ``DiscoveryPlan/make(interfaces:entries:includePrivateVPNNetworks:localHostLimit:maxHostsPerEntry:)``).
public struct DiscoveryNetwork: Hashable, Sendable, Identifiable {
    public var id: String { "\(range.description)#\(SubnetScanner.formatIPv4(searchFirst))" }
    /// Das ganze Netz bzw. der angegebene Bereich.
    public var range: IPv4Range
    /// Tatsächlich geprüfte Adressen (zusammenhängend; bei großen Netzen begrenzt).
    public var searchFirst: UInt32
    public var searchLast: UInt32
    /// Herkünfte (die erste bestimmt die Einordnung, z. B. lokal vor bekanntem Drucker).
    public var origins: [DiscoveryNetworkEntry.Origin]
    /// Schnittstellen bzw. Drucker, auf die das Netz zurückgeht.
    public var labels: [String]
    /// Directed-Broadcast-Adresse des Netzes (nur Netze mit Broadcast).
    public var broadcastAddress: String?
    /// Der Bereich ist größer als die Höchstzahl der Adressen je Eintrag (nur ein Teil wird geprüft).
    public var isCapped: Bool

    public var origin: DiscoveryNetworkEntry.Origin { origins.first ?? .user }

    /// Anzahl der geprüften Adressen.
    public var searchedHostCount: Int { Int(UInt64(searchLast) - UInt64(searchFirst) + 1) }

    public var isLocal: Bool { origin == .local }

    /// Die geprüften Adressen, aufsteigend.
    public func hosts() -> [String] {
        (0..<UInt64(searchedHostCount)).map { SubnetScanner.formatIPv4(UInt32(UInt64(searchFirst) + $0)) }
    }

    func searchCovers(_ first: UInt32, _ last: UInt32) -> Bool {
        first >= searchFirst && last <= searchLast
    }
}

/// Was eine Suche durchsucht: lokale Subnetze, VPN-Netze, Netze bekannter Drucker und eigene Netze.
public struct DiscoveryPlan: Hashable, Sendable {
    public var networks: [DiscoveryNetwork]
    /// Eigene Angaben, die nicht verstanden wurden (Text und Grund).
    public var invalidEntries: [DiscoveryNetworkInvalidEntry]

    public init(networks: [DiscoveryNetwork] = [], invalidEntries: [DiscoveryNetworkInvalidEntry] = []) {
        self.networks = networks
        self.invalidEntries = invalidEntries
    }

    /// Alle zu prüfenden Adressen ohne Duplikate (lokale Netze zuerst).
    public var hosts: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for network in networks {
            for host in network.hosts() where seen.insert(host).inserted { result.append(host) }
        }
        return result
    }

    /// Adressen außerhalb der lokalen Subnetze (VPN, bekannte Drucker, eigene Netze): Diese erreicht
    /// kein Broadcast – die Zebra-Suche fragt sie einzeln (wie Link-OS `subnetSearch`).
    public var remoteHosts: [String] {
        let local = networks.filter(\.isLocal)
        var seen = Set<String>()
        var result: [String] = []
        for network in networks where !network.isLocal {
            for host in network.hosts() where seen.insert(host).inserted {
                guard let value = SubnetScanner.parseIPv4(host),
                      !local.contains(where: { value >= $0.searchFirst && value <= $0.searchLast })
                else { continue }
                result.append(host)
            }
        }
        return result
    }

    /// Ziele der Broadcast-Suche: 255.255.255.255 und die Directed-Broadcast-Adresse jedes Netzes.
    public var broadcastTargets: [String] {
        var result = ["255.255.255.255"]
        for network in networks {
            if let address = network.broadcastAddress, !result.contains(address) { result.append(address) }
        }
        return result
    }

    /// Gesamtzahl der zu prüfenden Adressen.
    public var totalHostCount: Int { hosts.count }

    /// Geschätzte Dauer des Netzwerk-Scans (Port 9100) im ungünstigen Fall – jede Adresse wartet
    /// die volle Verbindungsfrist ab –, mindestens `minimum`, höchstens `maximum`. Für Fortschritts-
    /// anzeigen und das Zeitlimit der Suche.
    public func estimatedScanDuration(
        maxConcurrent: Int = 64,
        localTimeout: Duration = .milliseconds(400),
        remoteTimeout: Duration = .milliseconds(900),
        minimum: Duration = .seconds(10),
        maximum: Duration = .seconds(90)
    ) -> Duration {
        let remote = remoteHosts.count
        let local = max(0, totalHostCount - remote)
        let lanes = Double(max(1, maxConcurrent))
        // 3 s für die Identifikation (SNMP/~HI) der zuletzt gefundenen Geräte.
        let seconds: Double = 3
            + (Double(local) / lanes).rounded(.up) * localTimeout.timeInterval
            + (Double(remote) / lanes).rounded(.up) * remoteTimeout.timeInterval
        return min(max(.milliseconds(Int64((seconds * 1000).rounded())), minimum), maximum)
    }

    /// `true`, wenn `host` in einem lokalen Subnetz liegt (kurze Verbindungsfrist genügt).
    public func isLocal(host: String) -> Bool {
        guard let value = SubnetScanner.parseIPv4(host) else { return false }
        return networks.contains { $0.isLocal && $0.range.contains(value) }
    }

    /// Plant die Suche.
    ///
    /// * Lokale Subnetze (ohne VPN-Tunnel): wie bisher bis `localHostLimit` Adressen rund um die eigene.
    /// * VPN-Tunnel (Punkt-zu-Punkt) mit privater Adresse (RFC 1918): deren /24 – öffentliche
    ///   Tunneladressen werden nie durchsucht.
    /// * `entries` (eigene Netze vor Netzen bekannter Drucker): je höchstens `maxHostsPerEntry`
    ///   Adressen; Ungültiges landet in `invalidEntries`.
    /// * Netze, deren Adressen schon ein früheres Netz prüft, werden zusammengefasst (Herkunft und
    ///   Bezeichnung kommen hinzu) statt doppelt durchsucht.
    public static func make(
        interfaces: [NetworkInterfaceInfo],
        entries: [DiscoveryNetworkEntry],
        includePrivateVPNNetworks: Bool = true,
        localHostLimit: Int = 1024,
        maxHostsPerEntry: Int = DiscoveryNetworks.maxHostsPerEntry
    ) -> DiscoveryPlan {
        var plan = DiscoveryPlan()

        func add(range: IPv4Range, searchFirst: UInt32, searchLast: UInt32, origin: DiscoveryNetworkEntry.Origin,
                 label: String?, broadcast: String?, capped: Bool) {
            if let index = plan.networks.firstIndex(where: { $0.searchCovers(searchFirst, searchLast) }) {
                if !plan.networks[index].origins.contains(origin) { plan.networks[index].origins.append(origin) }
                if let label, !label.isEmpty, !plan.networks[index].labels.contains(label) {
                    plan.networks[index].labels.append(label)
                }
                return
            }
            plan.networks.append(DiscoveryNetwork(
                range: range, searchFirst: searchFirst, searchLast: searchLast, origins: [origin],
                labels: label.map { [$0] } ?? [], broadcastAddress: broadcast, isCapped: capped
            ))
        }

        for iface in interfaces where !iface.isPointToPoint {
            guard let address = SubnetScanner.parseIPv4(iface.address),
                  let prefix = iface.prefixLength else { continue }
            let hosts = SubnetScanner.hosts(in: iface, limit: localHostLimit)
            guard let firstHost = hosts.first.flatMap(SubnetScanner.parseIPv4),
                  let lastHost = hosts.last.flatMap(SubnetScanner.parseIPv4) else { continue }
            let range = IPv4Range(containing: address, prefix: prefix)
            add(range: range, searchFirst: firstHost, searchLast: lastHost, origin: .local, label: iface.name,
                broadcast: iface.broadcastAddress, capped: range.hostCount > hosts.count)
        }

        if includePrivateVPNNetworks {
            for iface in interfaces where iface.isPointToPoint {
                guard let address = SubnetScanner.parseIPv4(iface.address),
                      DiscoveryNetworks.isPrivate(address) else { continue }
                let range = IPv4Range(containing: address, prefix: 24)
                let bounds = range.hostBounds
                add(range: range, searchFirst: bounds.first, searchLast: bounds.last, origin: .vpn,
                    label: iface.name, broadcast: nil, capped: false)
            }
        }

        let ordered = entries.filter { $0.origin == .user } + entries.filter { $0.origin != .user }
        for entry in ordered {
            switch DiscoveryNetworks.parse(entry.text) {
            case .failure(let error):
                if entry.origin == .user {
                    plan.invalidEntries.append(DiscoveryNetworkInvalidEntry(text: entry.text, error: error))
                }
            case .success(let range):
                let bounds = range.hostBounds
                let limit = UInt64(max(1, maxHostsPerEntry))
                let available = UInt64(bounds.last) - UInt64(bounds.first) + 1
                let searchLast = UInt32(UInt64(bounds.first) + min(available, limit) - 1)
                add(range: range, searchFirst: bounds.first, searchLast: searchLast, origin: entry.origin,
                    label: entry.label, broadcast: range.broadcastAddress, capped: available > limit)
            }
        }
        return plan
    }
}

/// Eine eigene Netzangabe, die nicht verstanden wurde.
public struct DiscoveryNetworkInvalidEntry: Hashable, Sendable {
    public var text: String
    public var error: DiscoveryNetworkError
}

/// Warum eine Netzangabe nicht verwendet werden kann.
public enum DiscoveryNetworkError: Error, Hashable, Sendable {
    /// Leere Angabe.
    case empty
    /// Weder Adresse, CIDR-Netz noch Bereich.
    case invalidSyntax
    /// Ungültige Präfixlänge bzw. Netzmaske.
    case invalidPrefix
    /// Bereichsende vor dem Anfang.
    case reversedRange
    /// Loopback, „0.x.x.x“, Multicast oder reservierte Adressen.
    case reservedAddress
}

// MARK: - Hilfen

/// Netzangaben lesen, Netze bekannter Drucker ableiten, private Adressen erkennen.
public enum DiscoveryNetworks {
    /// Höchstzahl der Adressen, die je eingetragenem Netz bzw. Bereich durchsucht werden (z. B. ein
    /// /20). Größere Angaben werden auf die ersten 4096 Adressen begrenzt.
    public static let maxHostsPerEntry = 4096

    /// Liest eine Netzangabe. Verstanden werden (Leerzeichen und Gedankenstriche sind erlaubt):
    /// * CIDR: „10.62.13.0/24“ (Hostanteil darf gesetzt sein: „10.62.13.19/24“), auch mit Maske
    ///   „10.62.13.0/255.255.255.0“;
    /// * Bereich: „10.62.13.1-10.62.13.254“, kurz „10.62.13.37-42“ oder „10.62.13.8-*“ (wie das
    ///   Link-OS-SDK, `*` = .254);
    /// * Platzhalter: „10.62.13.*“ (= .1–.254), „10.62.*“ (= 10.62.0.0/16);
    /// * drei Oktette „10.62.13“ bzw. „10.62.13.0“ (= 10.62.13.0/24) und einzelne Adressen „10.62.13.19“.
    public static func parse(_ text: String) -> Result<IPv4Range, DiscoveryNetworkError> {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for dash in ["–", "—", "‒", "−"] { value = value.replacingOccurrences(of: dash, with: "-") }
        value = value.replacingOccurrences(of: " ", with: "")
        guard !value.isEmpty else { return .failure(.empty) }
        guard value.allSatisfy({ $0.isASCII && ($0.isNumber || ".-/*".contains($0)) }) else {
            return .failure(.invalidSyntax)
        }

        let result: Result<IPv4Range, DiscoveryNetworkError>
        if let slash = value.firstIndex(of: "/") {
            result = parseCIDR(String(value[..<slash]), String(value[value.index(after: slash)...]))
        } else if let dash = value.firstIndex(of: "-") {
            result = parseRange(String(value[..<dash]), String(value[value.index(after: dash)...]))
        } else if value.contains("*") {
            result = parseWildcard(value)
        } else {
            let octets = value.split(separator: ".", omittingEmptySubsequences: false)
            if octets.count == 4, octets[3] == "0", let address = SubnetScanner.parseIPv4(value) {
                // „10.62.13.0“ meint das Netz, nicht die (nie vergebene) Netzadresse.
                result = .success(IPv4Range(containing: address, prefix: 24))
            } else if octets.count == 4, let address = SubnetScanner.parseIPv4(value) {
                result = .success(IPv4Range(single: address))
            } else if (octets.count == 3 || (octets.count == 4 && octets[3].isEmpty)),
                      let address = SubnetScanner.parseIPv4(octets.prefix(3).joined(separator: ".") + ".0") {
                result = .success(IPv4Range(containing: address, prefix: 24))
            } else {
                result = .failure(.invalidSyntax)
            }
        }
        guard case .success(let range) = result else { return result }
        return isUsable(range) ? .success(range) : .failure(.reservedAddress)
    }

    private static func parseCIDR(_ addressText: String, _ prefixText: String) -> Result<IPv4Range, DiscoveryNetworkError> {
        var octets = addressText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if octets.last == "" { octets.removeLast() }
        while octets.count < 4 && !octets.isEmpty { octets.append("0") }
        guard let address = SubnetScanner.parseIPv4(octets.joined(separator: ".")) else { return .failure(.invalidSyntax) }
        let prefix: Int
        if prefixText.contains(".") {
            guard let mask = SubnetScanner.parseIPv4(prefixText),
                  let length = SubnetScanner.prefixLength(ofMask: mask) else { return .failure(.invalidPrefix) }
            prefix = length
        } else {
            guard let length = Int(prefixText), (0...32).contains(length) else { return .failure(.invalidPrefix) }
            prefix = length
        }
        return .success(IPv4Range(containing: address, prefix: prefix))
    }

    private static func parseRange(_ startText: String, _ endText: String) -> Result<IPv4Range, DiscoveryNetworkError> {
        guard let start = SubnetScanner.parseIPv4(startText) else { return .failure(.invalidSyntax) }
        let end: UInt32
        if endText == "*" {
            end = (start & 0xFFFF_FF00) | 254
        } else if let full = SubnetScanner.parseIPv4(endText) {
            end = full
        } else if let lastOctet = UInt8(endText), !endText.isEmpty, endText.count <= 3 {
            end = (start & 0xFFFF_FF00) | UInt32(lastOctet)
        } else {
            return .failure(.invalidSyntax)
        }
        guard let range = IPv4Range(first: start, last: end) else { return .failure(.reversedRange) }
        return .success(range)
    }

    private static func parseWildcard(_ text: String) -> Result<IPv4Range, DiscoveryNetworkError> {
        var octets = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let firstWildcard = octets.firstIndex(of: "*"), firstWildcard > 0,
              octets[firstWildcard...].allSatisfy({ $0 == "*" }), octets.count <= 4 else {
            return .failure(.invalidSyntax)
        }
        let fixed = Array(octets[..<firstWildcard])
        octets = fixed + Array(repeating: "0", count: 4 - fixed.count)
        guard let address = SubnetScanner.parseIPv4(octets.joined(separator: ".")) else { return .failure(.invalidSyntax) }
        return .success(IPv4Range(containing: address, prefix: fixed.count * 8))
    }

    /// Keine Loopback-, „Dieses Netz“- (0/8), Multicast- oder reservierten Adressen (ab 224.0.0.0).
    static func isUsable(_ range: IPv4Range) -> Bool {
        let firstOctet = range.first >> 24
        let lastOctet = range.last >> 24
        if firstOctet == 0 || firstOctet == 127 || lastOctet >= 224 { return false }
        return !(firstOctet < 127 && lastOctet > 127)
    }

    /// Private Adresse nach RFC 1918 (10/8, 172.16/12, 192.168/16).
    public static func isPrivate(_ address: UInt32) -> Bool {
        address & 0xFF00_0000 == 0x0A00_0000
            || address & 0xFFF0_0000 == 0xAC10_0000
            || address & 0xFFFF_0000 == 0xC0A8_0000
    }

    public static func isPrivate(host: String) -> Bool {
        SubnetScanner.parseIPv4(host).map(isPrivate) ?? false
    }

    /// Host einer Geräte-URI (`socket://10.62.13.19:9100`, `ipp://10.62.13.19/ipp/print`,
    /// `lpd://10.62.13.19/PRT`, `ipp://10.62.13.19:631/printers/zebra` …), klein geschrieben und ohne
    /// eckige Klammern; `nil` für USB, Bonjour (`dnssd://`), Dateien und Loopback.
    ///
    /// Anders als `QueueAdoption.deviceEndpoint(ofDeviceURI:)` (das nur URIs akzeptiert, die das Gerät
    /// selbst nennen) zählt hier jeder Pfad: Für die Netze der Suche und das Auflösen von Hostnamen
    /// genügt der Host – auch eine benannte LPD-Warteschlange eines Zebra-Druckservers liegt im Netz des
    /// Druckers. Der Abgleich „schon eingerichtet“ (`DiscoveryFilter`) nimmt dagegen nur Adressen, die
    /// das Gerät selbst nennen.
    public static func host(ofDeviceURI uri: String) -> String? {
        guard let endpoint = QueueAdoption.endpoint(ofDeviceURI: uri),
              QueueAdoption.networkSchemes.contains(endpoint.scheme),
              !QueueAdoption.isLoopbackHost(endpoint.host)
        else { return nil }
        return hostKey(endpoint.host)
    }

    /// Vergleichsform eines Hosts: klein geschrieben, ohne eckige Klammern, Leerraum und
    /// abschließenden Punkt (leer, wenn nichts übrig bleibt).
    public static func hostKey(_ host: String) -> String {
        QueueAdoption.normalizedHost(host) ?? ""
    }

    /// Netze der bekannten Drucker (`hosts`: IPv4-Adressen oder Hostnamen, diese über `resolved`
    /// – ``hostKey(_:)`` → IPv4-Adresse, siehe ``resolveHostnames(_:resolver:)``), je Netz einmal mit
    /// allen Bezeichnungen, sortiert:
    /// * private Adressen (RFC 1918): das ganze /24;
    /// * öffentliche Adressen (z. B. ein Drucker hinter einer Portweiterleitung): nur die Adresse
    ///   selbst – ein fremdes öffentliches Netz wird nie von selbst durchsucht;
    /// * nicht auflösbare Hostnamen, Loopback, Link-Local und reservierte Adressen: übergangen.
    public static func knownPrinterNetworks(_ hosts: [(host: String, label: String?)],
                                            resolved: [String: String] = [:]) -> [DiscoveryNetworkEntry] {
        var order: [IPv4Range] = []
        var labels: [IPv4Range: [String]] = [:]
        for item in hosts {
            let key = hostKey(item.host)
            guard let address = SubnetScanner.parseIPv4(key) ?? resolved[key].flatMap(SubnetScanner.parseIPv4)
            else { continue }
            let range = isPrivate(address) ? IPv4Range(containing: address, prefix: 24) : IPv4Range(single: address)
            guard isUsable(range), address & 0xFFFF_0000 != 0xA9FE_0000 else { continue }
            if labels[range] == nil {
                order.append(range)
                labels[range] = []
            }
            if let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
               labels[range]?.contains(label) == false {
                labels[range]?.append(label)
            }
        }
        return order.sorted().map { range in
            let names = labels[range] ?? []
            return DiscoveryNetworkEntry(range.description, origin: .knownPrinter,
                                         label: names.isEmpty ? nil : names.joined(separator: ", "))
        }
    }

    // MARK: Hostnamen auflösen

    /// Löst einen Hostnamen in eine IPv4-Adresse auf (`nil` = nicht auflösbar).
    public typealias IPv4Resolver = @Sendable (String) async -> String?

    /// Höchstzahl der Hostnamen, die ``resolveHostnames(_:resolver:)`` auflöst.
    public static let maxResolvedHostnames = 32

    /// Löst die Hostnamen unter `hosts` (IP-Literale werden übergangen) gleichzeitig auf; Ergebnis:
    /// ``hostKey(_:)`` → IPv4-Adresse, nicht auflösbare Namen fehlen. Ohne `resolver`:
    /// ``systemIPv4Address(of:timeout:)`` (DNS bzw. mDNS, je Name höchstens 2 s).
    public static func resolveHostnames(_ hosts: [String], resolver: IPv4Resolver? = nil) async -> [String: String] {
        var names: [String] = []
        for host in hosts {
            let key = hostKey(host)
            guard !key.isEmpty, SubnetScanner.parseIPv4(key) == nil, !key.contains(":"), !names.contains(key)
            else { continue }
            names.append(key)
            if names.count >= maxResolvedHostnames { break }
        }
        guard !names.isEmpty else { return [:] }
        let resolve: IPv4Resolver = resolver ?? { await systemIPv4Address(of: $0) }
        return await withTaskGroup(of: (String, String?).self) { group in
            for name in names { group.addTask { (name, await resolve(name)) } }
            var result: [String: String] = [:]
            for await (name, address) in group {
                if let address, SubnetScanner.parseIPv4(address) != nil { result[name] = address }
            }
            return result
        }
    }

    /// IPv4-Adresse eines Hostnamens per `getaddrinfo` (`AF_INET`) – außerhalb des kooperativen
    /// Thread-Pools; wartet höchstens `timeout` (die Anfrage selbst läuft dann im Hintergrund aus).
    public static func systemIPv4Address(of host: String, timeout: Duration = .seconds(2)) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let pending = LockedValue<CheckedContinuation<String?, Never>?>(continuation)
            let finish: @Sendable (String?) -> Void = { value in
                pending.withLock { stored in
                    stored?.resume(returning: value)
                    stored = nil
                }
            }
            BlockingIO.makeQueue("de.labelwerk.transport.resolve").async { finish(lookupIPv4(host)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { finish(nil) }
        }
    }

    /// Blockierend: erste IPv4-Adresse von `host` oder `nil`.
    static func lookupIPv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET, let address = entry.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: 64)
                if getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let text = buffer.withUnsafeBufferPointer { pointer in
                        pointer.baseAddress.map { String(cString: $0) } ?? ""
                    }
                    if SubnetScanner.parseIPv4(text) != nil { return text }
                }
            }
            cursor = entry.pointee.ai_next
        }
        return nil
    }

    /// Bereinigte Liste eigener Netzangaben (ohne Leereinträge und Duplikate, Reihenfolge bleibt).
    public static func normalizedUserEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key: String
            if case .success(let range) = parse(trimmed) { key = range.description } else { key = trimmed.lowercased() }
            if seen.insert(key).inserted { result.append(trimmed) }
        }
        return result
    }

    /// Zerlegt eine Eingabe mit mehreren Angaben (Komma, Semikolon, Zeilenumbruch).
    public static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

import Foundation

/// Sucht Zebra-Drucker gleichzeitig über alle gewählten Quellen.
///
/// * **bonjour** – DNS-SD `_pdl-datastream._tcp`, `_printer._tcp`, `_ipp._tcp` (macOS:
///   Network.framework, Linux: `avahi-browse`), aufgelöst auf IP-Adresse; nur Zebra-Geräte.
/// * **zebra** – Zebras eigene Suche über UDP 4201 wie Zebra Setup Utilities und das Link-OS-SDK
///   (``ZebraUDPDiscovery``, Paketformat ``ZebraDiscoveryPacket``): Broadcast, Multicast 224.0.1.55
///   und – für Netze hinter Routern und VPN – einzeln an jede Adresse der entfernten Netze des
///   Suchplans (``DiscoveryPlan``). Es antworten nur Zebra-Druckserver, mit Modell, Seriennummer,
///   MAC-Adresse und Systemname; fremde Geräte erhalten nur das sechs Byte lange UDP-Paket.
/// * **usb** – IOKit, Hersteller-ID 0x0A5F (nur macOS).
/// * **network** – Portsuche (9100) in den Netzen des Suchplans (lokale Subnetze, private VPN-Netze,
///   Netze bekannter Drucker und eigene Netze: `Options.extraNetworks`), danach Identifikation per SNMP
///   (`sysDescr`/`sysName`, gefahrlos). Nur Geräte, die SNMP **eindeutig als Zebra** meldet,
///   erhalten zusätzlich `~HI` (Firmware, Auflösung, Speicher). Alle anderen Geräte bekommen
///   standardmäßig **keinerlei Daten**: Fremde Drucker (JetDirect, PCL/PJL …) würden Text an
///   Port 9100 als Seite ausdrucken – das gilt auch für Geräte, deren SNMP schweigt (abgeschaltet,
///   andere Community, nur SNMPv3) oder keine `sysDescr` liefert. Solche Geräte werden als „nicht
///   identifiziert“ aufgeführt (`includeUnidentifiedNetworkDevices`); per SNMP als Nicht-Zebra
///   erkannte Geräte werden standardmäßig ausgeblendet. Wer `~HI` auch an nicht identifizierte
///   Geräte senden will, schaltet `probeUnidentifiedDevicesWithHostIdentification` bewusst ein.
/// * **cups** – eingerichtete CUPS-Warteschlangen, deren Treiber/URI auf Zebra hindeutet.
/// * **bluetooth** – gekoppelte klassische Bluetooth-Geräte der Klasse „Drucker“ bzw. mit
///   Zebra-Namen (nur macOS).
/// * **ble** – BLE-Geräte mit Zebra-Dienstkennung (nur macOS).
///
/// Ergebnisse werden zusammengeführt (``DiscoveryRegistry``): gleiche `id`
/// (`ConnectionDescriptor.stableID`), gleiche Seriennummer oder gleiche Netzwerkadresse ergeben einen
/// Drucker. Der erste Fund wird geliefert; bringt ein späterer Fund desselben Geräts eine sicherere
/// Erkennung (Zebra-Suche vor SNMP/`~HI`/Bonjour vor unerkanntem offenem Port), wird der Eintrag
/// **mit derselben `id`** erneut geliefert – Verbraucher ersetzen ihn.
public final class PrinterDiscovery: Sendable {
    /// Feineinstellungen der Suche.
    public struct Options: Sendable, Hashable {
        /// Zu prüfende Hosts für Netzwerk-Scan und Zebra-Suche; `nil` = Suchplan (lokale Subnetze,
        /// private VPN-Netze, `extraNetworks`). Bei expliziten Hosts fragt die Zebra-Suche nur diese
        /// einzeln ab (kein Broadcast/Multicast).
        public var networkHosts: [String]?
        /// Zusätzlich zu durchsuchende Netze: Netze bekannter Drucker und eigene Angaben
        /// („10.62.13.0/24“, „10.62.13.1-10.62.13.254“ …, siehe ``DiscoveryNetworks/parse(_:)``).
        public var extraNetworks: [DiscoveryNetworkEntry] = []
        /// /24 von VPN-Tunneln mit privater Adresse (RFC 1918) mit durchsuchen.
        public var includePrivateVPNNetworks: Bool = true
        /// Höchstzahl der Adressen je zusätzlichem Netz.
        public var maxHostsPerNetwork: Int = DiscoveryNetworks.maxHostsPerEntry
        /// Verbindungsfrist für Adressen außerhalb der lokalen Subnetze (VPN, Router dazwischen).
        public var remoteConnectTimeout: Duration = .milliseconds(900)
        /// Zebra-Suche: Zielport (Standard 4201; abweichend nur für Tests).
        public var zebraDiscoveryPort: Int = ZebraDiscoveryPacket.port
        /// Zebra-Suche: Wartezeit auf Antworten nach der letzten Anfrage.
        public var zebraReplyWindow: Duration = .milliseconds(2500)
        /// Zebra-Suche: Broadcast (255.255.255.255 und Directed Broadcast je Netz).
        public var zebraUseBroadcast: Bool = true
        /// Zebra-Suche: Multicast an 224.0.1.55 über jede multicastfähige Schnittstelle.
        public var zebraUseMulticast: Bool = true
        /// Zebra-Suche: Reichweite des Multicasts in Routersprüngen (TTL).
        public var zebraMulticastHops: Int = ZebraDiscoveryPacket.defaultMulticastHops
        /// Zebra-Suche: auch jede Adresse der lokalen Subnetze einzeln abfragen (sonst genügt Broadcast).
        public var zebraUnicastToLocalSubnets: Bool = false
        /// Zu prüfende TCP-Ports (Standard: 9100).
        public var networkPorts: [Int] = [ZebraIdentifiers.rawPort]
        /// Höchstzahl der Hosts je Netzwerkschnittstelle (siehe `SubnetScanner.hosts(in:limit:)`).
        public var hostLimitPerInterface: Int = 1024
        /// Zeitlimit für den Verbindungsaufbau je Host.
        public var connectTimeout: Duration = .milliseconds(400)
        /// Gleichzeitige Verbindungsversuche.
        public var maxConcurrentProbes: Int = 64
        /// Gefundene Netzwerkgeräte per SNMP/`~HI` identifizieren.
        public var identifyNetworkPrinters: Bool = true
        /// SNMP-Abfrage (`sysDescr`, `sysName`) zur gefahrlosen Identifikation.
        public var useSNMP: Bool = true
        public var snmpPort: Int = 161
        /// SNMP-Community für die Leseabfrage (Zebra-Werkseinstellung: „public“).
        public var snmpCommunity: String = "public"
        public var snmpTimeout: Duration = .milliseconds(700)
        /// `~HI` an Geräte senden, die SNMP eindeutig als Zebra meldet (liefert Modell mit
        /// Auflösung, Firmware und Speicher).
        public var useHostIdentification: Bool = true
        public var hostIdentificationTimeout: Duration = .milliseconds(1500)
        /// `~HI` **auch** an Geräte senden, die sich per SNMP nicht identifizieren ließen
        /// (kein SNMP, andere Community, keine `sysDescr`). Wirkt nur zusammen mit
        /// `useHostIdentification`.
        ///
        /// Standard: `false`. **Vorsicht:** Fremde Drucker, die Rohdaten an Port 9100 annehmen
        /// (praktisch alle Bürodrucker), drucken den Text `~HI` als Seite aus. Nur einschalten,
        /// wenn die durchsuchten Hosts bekanntermaßen ausschließlich Zebra-Drucker sind.
        public var probeUnidentifiedDevicesWithHostIdentification: Bool = false
        /// Geräte liefern, die per SNMP eindeutig als Nicht-Zebra erkannt wurden.
        public var includeNonZebraNetworkDevices: Bool = false
        /// Geräte mit offenem Port liefern, die sich nicht identifizieren ließen.
        public var includeUnidentifiedNetworkDevices: Bool = true
        /// Bonjour-Diensttypen.
        public var bonjourServiceTypes: [String] = ZebraIdentifiers.bonjourServiceTypes
        /// Nur CUPS-Warteschlangen liefern, die nach Zebra aussehen.
        public var cupsOnlyZebra: Bool = true

        public init() {}
    }

    public let options: Options

    public init() {
        self.options = Options()
    }

    public init(options: Options) {
        self.options = options
    }

    /// Liefert gefundene Drucker (dedupliziert nach `id`) und endet nach `timeout`
    /// – oder früher, sobald alle Quellen fertig sind.
    public func discover(
        sources: Set<DiscoverySource> = Set(DiscoverySource.allCases),
        timeout: Duration = .seconds(6)
    ) -> AsyncStream<DiscoveredPrinter> {
        let (stream, continuation) = AsyncStream<DiscoveredPrinter>.makeStream(bufferingPolicy: .unbounded)
        let sink = DiscoverySink(continuation)
        let options = self.options
        let ordered = sources.sorted { $0.rawValue < $1.rawValue }
        let task = Task {
            await withTaskGroup(of: Bool.self) { group in
                for source in ordered {
                    group.addTask {
                        await Self.run(source, options: options, timeout: timeout, sink: sink)
                        return true
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                var remaining = ordered.count
                while remaining > 0, let sourceFinished = await group.next() {
                    if !sourceFinished { break }
                    remaining -= 1
                }
                // Strom sofort beenden; noch laufende Quellen werden abgebrochen.
                sink.finish()
                group.cancelAll()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Quellen

    static func run(_ source: DiscoverySource, options: Options, timeout: Duration, sink: DiscoverySink) async {
        switch source {
        case .network:
            await discoverNetwork(options: options, sink: sink)
        case .cups:
            await discoverCUPS(options: options, sink: sink)
        case .bonjour:
            await discoverBonjour(options: options, timeout: timeout, sink: sink)
        case .zebra:
            await discoverZebra(options: options, timeout: timeout, sink: sink)
        case .usb:
            #if os(macOS) && canImport(IOKit)
            await discoverUSB(sink: sink)
            #endif
        case .bluetooth:
            #if os(macOS) && canImport(IOBluetooth)
            await discoverBluetooth(sink: sink)
            #endif
        case .ble:
            #if os(macOS) && canImport(CoreBluetooth)
            await discoverBLE(timeout: timeout, sink: sink)
            #endif
        }
    }

    // MARK: Suchplan

    /// Was Netzwerk-Scan und Zebra-Suche mit diesen Optionen durchsuchen (für Anzeige und Tests).
    public static func plan(options: Options,
                            interfaces: [NetworkInterfaceInfo] = SubnetScanner.allIPv4Interfaces()) -> DiscoveryPlan {
        DiscoveryPlan.make(
            interfaces: interfaces,
            entries: options.extraNetworks,
            includePrivateVPNNetworks: options.includePrivateVPNNetworks,
            localHostLimit: options.hostLimitPerInterface,
            maxHostsPerEntry: options.maxHostsPerNetwork
        )
    }

    /// Suchplan dieser Suche (aktuelle Schnittstellen).
    public func plan() -> DiscoveryPlan {
        Self.plan(options: options)
    }

    /// Zu durchsuchende Hosts (explizit oder aus dem Suchplan), ohne Duplikate.
    static func networkHosts(options: Options, plan: DiscoveryPlan? = nil) -> [String] {
        let raw = options.networkHosts ?? (plan ?? Self.plan(options: options)).hosts
        var seen = Set<String>()
        return raw.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Ziele der Zebra-Suche: explizite Hosts einzeln, sonst Broadcast, Multicast und die Adressen
    /// der entfernten Netze des Suchplans.
    static func zebraTargets(options: Options, plan: DiscoveryPlan,
                             interfaces: [NetworkInterfaceInfo]) -> ZebraUDPDiscovery.Targets {
        var targets = ZebraUDPDiscovery.Targets()
        if let explicit = options.networkHosts {
            var seen = Set<String>()
            targets.unicast = explicit.filter { SubnetScanner.parseIPv4($0) != nil && seen.insert($0).inserted }
            return targets
        }
        if options.zebraUseBroadcast { targets.broadcast = plan.broadcastTargets }
        if options.zebraUseMulticast {
            targets.multicastInterfaces = interfaces.filter { !$0.isPointToPoint && $0.supportsMulticast }.map(\.address)
        }
        targets.unicast = options.zebraUnicastToLocalSubnets ? plan.hosts : plan.remoteHosts
        return targets
    }

    static func discoverNetwork(options: Options, sink: DiscoverySink) async {
        let plan = options.networkHosts == nil ? Self.plan(options: options) : nil
        let hosts = networkHosts(options: options, plan: plan)
        let ports = Array(Set(options.networkPorts.filter { (1...65535).contains($0) })).sorted()
        guard !hosts.isEmpty, !ports.isEmpty else { return }
        // Adressen hinter Routern bzw. VPN antworten langsamer: eigene, längere Verbindungsfrist.
        let local = plan.map { plan in hosts.filter { plan.isLocal(host: $0) } } ?? hosts
        let localSet = Set(local)
        let remote = hosts.filter { !localSet.contains($0) }
        let groups: [(hosts: [String], timeout: Duration)] = [
            (hosts: local, timeout: options.connectTimeout),
            (hosts: remote, timeout: max(options.connectTimeout, options.remoteConnectTimeout)),
        ].filter { !$0.hosts.isEmpty }
        await withTaskGroup(of: Void.self) { group in
            for port in ports {
                for scanGroup in groups {
                    group.addTask {
                        await withTaskGroup(of: Void.self) { identifications in
                            let found = SubnetScanner.scan(
                                hosts: scanGroup.hosts, port: port,
                                timeout: scanGroup.timeout,
                                maxConcurrent: options.maxConcurrentProbes
                            )
                            for await host in found {
                                identifications.addTask {
                                    if let printer = await identifyNetworkDevice(host: host, port: port, options: options) {
                                        sink.emit(printer)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Zebra-Suche (UDP 4201). Antworten mit lesbarem Produkt- oder Systemnamen werden sofort
    /// gemeldet; Antworten ohne (abweichender Paketaufbau älterer Druckserver) werden über SNMP und –
    /// da nur Zebra-Druckserver auf diese Anfrage antworten – `~HI` identifiziert.
    static func discoverZebra(options: Options, timeout: Duration, sink: DiscoverySink) async {
        let interfaces = SubnetScanner.allIPv4Interfaces()
        let plan = Self.plan(options: options, interfaces: interfaces)
        let targets = zebraTargets(options: options, plan: plan, interfaces: interfaces)
        guard !targets.isEmpty else { return }
        let rawPort = options.networkPorts.first { (1...65535).contains($0) } ?? ZebraIdentifiers.rawPort
        var incomplete: [(reply: ZebraDiscoveryPacket.Reply, host: String)] = []
        _ = await ZebraUDPDiscovery.run(
            targets: targets,
            port: options.zebraDiscoveryPort,
            multicastHops: options.zebraMulticastHops,
            replyWindow: min(options.zebraReplyWindow, timeout)
        ) { reply, host in
            if reply.productName != nil || reply.systemName != nil {
                sink.emit(ZebraDiscoveryPacket.makeDiscoveredPrinter(reply, host: host, port: rawPort))
            } else {
                incomplete.append((reply: reply, host: host))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for item in incomplete {
                group.addTask {
                    sink.emit(await identifyZebraResponder(reply: item.reply, host: item.host, port: rawPort,
                                                           options: options))
                }
            }
        }
    }

    /// Ergänzt eine unvollständige Antwort der Zebra-Suche per SNMP bzw. `~HI`.
    static func identifyZebraResponder(reply: ZebraDiscoveryPacket.Reply, host: String, port: Int,
                                       options: Options) async -> DiscoveredPrinter {
        var printer = ZebraDiscoveryPacket.makeDiscoveredPrinter(reply, host: host, port: port)
        var methods = ["zebra"]
        if options.useSNMP, let values = await querySNMPIdentity(host: host, options: options) {
            if let description = values[SNMPProbe.sysDescrOID], !description.isEmpty {
                printer.details["sysDescr"] = description
                if ZebraIdentifiers.looksLikeZebra(description) { printer.modelHint = cleanedSysDescr(description) }
                methods.append("snmp")
            }
            if let systemName = values[SNMPProbe.sysNameOID], !systemName.isEmpty {
                printer.details["sysName"] = systemName
                printer.name = systemName
            }
        }
        if printer.modelHint == nil, options.useHostIdentification,
           let identification = await HostIdentificationProbe.probe(
               host: host, port: port,
               connectTimeout: max(options.connectTimeout, options.remoteConnectTimeout),
               responseTimeout: options.hostIdentificationTimeout
           ) {
            printer.modelHint = identification.model
            methods.append("hi")
            if let firmware = identification.firmware { printer.details["firmware"] = firmware }
            if let dpmm = identification.dotsPerMM { printer.details["dotsPerMM"] = String(dpmm) }
            if let memory = identification.memory { printer.details["memory"] = memory }
            if printer.details["sysName"] == nil, let short = ZebraIdentifiers.shortModelName(from: identification.model) {
                printer.name = "Zebra \(short)"
            }
        }
        printer.details["identifiedBy"] = methods.joined(separator: "+")
        return printer
    }

    /// Identifiziert ein Gerät mit offenem Port. `nil` = ausblenden (gemäß Optionen).
    static func identifyNetworkDevice(host: String, port: Int, options: Options) async -> DiscoveredPrinter? {
        var details = ["host": host, "port": String(port)]
        var name: String?
        var modelHint: String?
        var isZebra: Bool?

        if options.identifyNetworkPrinters {
            if options.useSNMP, let values = await querySNMPIdentity(host: host, options: options) {
                if let description = values[SNMPProbe.sysDescrOID], !description.isEmpty {
                    details["sysDescr"] = description
                    let zebra = ZebraIdentifiers.looksLikeZebra(description)
                    isZebra = zebra
                    if zebra { modelHint = cleanedSysDescr(description) }
                    details["identifiedBy"] = "snmp"
                }
                if let systemName = values[SNMPProbe.sysNameOID], !systemName.isEmpty {
                    details["sysName"] = systemName
                    name = systemName
                }
            }
            if mayProbeWithHostIdentification(isZebra: isZebra, options: options),
               let identification = await HostIdentificationProbe.probe(
                   host: host, port: port,
                   connectTimeout: max(options.connectTimeout, .milliseconds(800)),
                   responseTimeout: options.hostIdentificationTimeout
               ) {
                isZebra = true
                modelHint = identification.model
                details["identifiedBy"] = details["identifiedBy"].map { "\($0)+hi" } ?? "hi"
                if let firmware = identification.firmware { details["firmware"] = firmware }
                if let dpmm = identification.dotsPerMM { details["dotsPerMM"] = String(dpmm) }
                if let memory = identification.memory { details["memory"] = memory }
            }
        }

        switch isZebra {
        case .some(false) where !options.includeNonZebraNetworkDevices:
            return nil
        case .none where options.identifyNetworkPrinters && !options.includeUnidentifiedNetworkDevices:
            return nil
        default:
            break
        }
        let shortModel = modelHint.flatMap(ZebraIdentifiers.shortModelName(from:))
        let displayName = name ?? shortModel.map { "Zebra \($0)" } ?? host
        return DiscoveredPrinter(
            name: displayName,
            modelHint: modelHint,
            descriptor: .tcp(host: host, port: port),
            source: .network,
            details: details
        )
    }

    /// Entscheidet, ob ein Gerät `~HI` erhalten darf.
    ///
    /// `~HI` ist druckbarer Text: Ein fremder Drucker an Port 9100 würde ihn als Seite ausgeben.
    /// Deshalb nur an Geräte, die SNMP positiv als Zebra gemeldet hat – nicht identifizierte Geräte
    /// nur nach ausdrücklicher Freigabe (`probeUnidentifiedDevicesWithHostIdentification`), per
    /// SNMP als Nicht-Zebra erkannte nie.
    static func mayProbeWithHostIdentification(isZebra: Bool?, options: Options) -> Bool {
        guard options.useHostIdentification else { return false }
        switch isZebra {
        case .some(true): return true
        case .some(false): return false
        case .none: return options.probeUnidentifiedDevicesWithHostIdentification
        }
    }

    /// Fragt `sysDescr` und `sysName` per SNMP ab.
    ///
    /// Bei SNMPv1 scheitert eine Anfrage mit mehreren OIDs vollständig (`noSuchName`, keine Werte),
    /// sobald der Agent auch nur eine davon nicht kennt. Liefert die gemeinsame Abfrage deshalb gar
    /// keine Werte, wird `sysDescr` – das für die Identifikation entscheidende Feld – einzeln erfragt.
    static func querySNMPIdentity(host: String, options: Options) async -> [String: String]? {
        guard let values = await SNMPProbe.query(
            host: host, port: options.snmpPort, community: options.snmpCommunity,
            oids: [SNMPProbe.sysDescrOID, SNMPProbe.sysNameOID], timeout: options.snmpTimeout
        ) else { return nil }
        guard values.isEmpty, !Task.isCancelled else { return values }
        return await SNMPProbe.query(
            host: host, port: options.snmpPort, community: options.snmpCommunity,
            oids: [SNMPProbe.sysDescrOID], timeout: options.snmpTimeout
        ) ?? values
    }

    /// „Zebra Technologies ZTC ZD421-203dpi ZPL“ → „ZTC ZD421-203dpi ZPL“.
    static func cleanedSysDescr(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Zebra Technologies ", "Zebra Technologies, "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result
    }

    static func discoverCUPS(options: Options, sink: DiscoverySink) async {
        let queues = await CUPSQueueLister.queuesAsync()
        for queue in queues where !options.cupsOnlyZebra || queue.looksLikeZebra {
            var details = ["deviceURI": queue.deviceURI, "isDefault": queue.isDefault ? "true" : "false"]
            if let makeAndModel = queue.makeAndModel { details["makeAndModel"] = makeAndModel }
            sink.emit(DiscoveredPrinter(
                name: queue.name,
                modelHint: queue.modelHint,
                descriptor: .cupsQueue(name: queue.name),
                source: .cups,
                details: details
            ))
        }
    }

    static func discoverBonjour(options: Options, timeout: Duration, sink: DiscoverySink) async {
        #if canImport(Network)
        await discoverBonjourWithNetworkFramework(types: options.bonjourServiceTypes, sink: sink)
        #else
        await discoverBonjourWithAvahi(types: options.bonjourServiceTypes, timeout: timeout, sink: sink)
        #endif
    }

    /// Linux: `avahi-browse` (falls installiert) je Diensttyp.
    static func discoverBonjourWithAvahi(types: [String], timeout: Duration, sink: DiscoverySink) async {
        guard let avahi = ProcessRunner.locate("avahi-browse") else { return }
        let seconds = min(max(timeout.timeInterval, 1), 10)
        await withTaskGroup(of: Void.self) { group in
            for type in types {
                group.addTask {
                    guard let output = try? await ProcessRunner.runAsync(
                        avahi, arguments: ["-p", "-r", "-t", "-k", type], timeout: seconds
                    ) else { return }
                    for service in AvahiBrowseParser.parse(output.outputText) where service.looksLikeZebra {
                        sink.emit(service.makeDiscoveredPrinter())
                    }
                }
            }
        }
    }
}

/// Sammelstelle für Funde aller Quellen: führt sie zusammen (``DiscoveryRegistry``) und reicht neue
/// bzw. ergänzte Einträge an den Strom weiter.
final class DiscoverySink: Sendable {
    private let continuation: AsyncStream<DiscoveredPrinter>.Continuation
    private let state = LockedValue<(registry: DiscoveryRegistry, finished: Bool)>((registry: DiscoveryRegistry(), finished: false))

    init(_ continuation: AsyncStream<DiscoveredPrinter>.Continuation) {
        self.continuation = continuation
    }

    /// Liefert `printer`, falls das Gerät neu ist, bzw. den ergänzten Eintrag (gleiche `id` wie zuvor),
    /// falls `printer` es sicherer erkennt; `true` bei Weitergabe.
    @discardableResult
    func emit(_ printer: DiscoveredPrinter) -> Bool {
        let output = state.withLock { state -> DiscoveredPrinter? in
            guard !state.finished else { return nil }
            return state.registry.insert(printer).printer
        }
        if let output { continuation.yield(output) }
        return output != nil
    }

    func finish() {
        state.withLock { $0.finished = true }
        continuation.finish()
    }
}

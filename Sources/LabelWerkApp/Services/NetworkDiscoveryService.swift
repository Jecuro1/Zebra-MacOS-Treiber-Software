import AppKit
import Foundation
import Observation
import LabelWerkKit

/// Vorbelegung des Installationsassistenten (z. B. „Hinzufügen“ eines gefundenen Netzwerkdruckers).
struct InstallWizardPrefill: Equatable {
    var host: String
    var port: Int
    var name: String?
    /// Der gefundene Drucker selbst: Der Assistent übernimmt ihn als Suchtreffer – mit allem, was die
    /// Suche schon weiß (Zebra-Suche: sicher ein Zebra-Drucker, Modell, Systemname). Ohne ihn gilt die
    /// Adresse als manuelle Eingabe.
    var printer: DiscoveredPrinter?
}

/// Findet Zebra-Drucker im Netzwerk automatisch – wie die Zebra-Programme unter Windows, die alle
/// Drucker des Netzes von selbst anzeigen.
///
/// * **Zebra-Suche** (UDP 4201, `ZebraUDPDiscovery`): Broadcast, Multicast und einzeln an jede
///   Adresse der Netze bekannter Drucker und der eigenen Netze – erreicht so auch Drucker hinter
///   Routern und VPN-Tunneln (FortiClient & Co.).
/// * **Vollständige Suche**: Zebra-Suche, Bonjour und Netzwerk-Scan (Port 9100 + SNMP/`~HI`) in den
///   lokalen Subnetzen, privaten VPN-Netzen, Netzen bekannter Drucker und eigenen Netzen
///   (`AppPreferences.extraDiscoveryNetworks`).
///
/// Zeitplan (`AppPreferences.automaticNetworkDiscovery`): vollständige Suche 5 s nach dem Start,
/// danach alle 10 Minuten die Zebra-Suche; beim Aktivieren der App erneut vollständig, wenn die letzte
/// vollständige Suche älter als 10 Minuten ist; „Erneut suchen“ jederzeit. Ergebnisse erscheinen in
/// „Drucker suchen“; die Seitenleiste zeigt die Zahl der neuen Zebra-Drucker („Neue Zebra-Drucker [N]“).
@Observable
@MainActor
final class NetworkDiscoveryService {
    /// Art eines Suchlaufs.
    enum Kind: Equatable {
        /// Nur Zebra-Suche (UDP) – für die Suche im Hintergrund.
        case quick
        /// Zebra-Suche, Bonjour und Netzwerk-Scan.
        case full
    }

    /// Wartezeit nach dem Start bis zur ersten (vollständigen) Suche.
    static let launchDelay: Duration = .seconds(5)
    /// Abstand der Zebra-Suchen im Hintergrund.
    static let backgroundInterval: TimeInterval = 10 * 60
    /// Ab diesem Alter sucht das Aktivieren der App wieder vollständig.
    static let fullSearchMaxAge: TimeInterval = 10 * 60
    /// So lange gilt ein Drucker nach seiner letzten Antwort als „im Netzwerk“.
    static let visibility: TimeInterval = 35 * 60
    /// Takt, in dem geprüft wird, ob eine Suche fällig ist.
    static let tickInterval: Duration = .seconds(30)
    /// Höchstzahl der Adressen, die eine Suche im Hintergrund zusätzlich einzeln prüft (Port 9100).
    static let maxRecheckHosts = 64

    // MARK: Zustand

    /// Alle bisher gefundenen Drucker (zusammengeführt über alle Läufe).
    private(set) var found: [DiscoveredPrinter] = []
    /// Letzte Antwort je Drucker (`DiscoveredPrinter.id`).
    private(set) var lastSeen: [String: Date] = [:]
    private(set) var isSearching = false
    private(set) var currentKind: Kind?
    private(set) var lastQuickSearch: Date?
    private(set) var lastFullSearch: Date?
    /// Netze der letzten (bzw. nächsten) Suche – für „Netze …“.
    private(set) var plan = DiscoveryPlan()
    /// Netze der Drucker, die LabelWerk bzw. macOS bereits kennt (je /24).
    private(set) var knownNetworkEntries: [DiscoveryNetworkEntry] = []
    /// Fehler der letzten Zebra-Suche, wenn keine Anfrage hinausging (z. B. kein Netzwerk).
    private(set) var lastProblem: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var registry = DiscoveryRegistry()
    /// macOS-Warteschlangen (`lpstat -v`) – für Netze und den Abgleich „schon eingerichtet“ (beobachtet,
    /// damit Suchergebnisse nach dem Lesen neu gefiltert werden).
    private(set) var macQueues: [CUPSQueueInfo] = []
    @ObservationIgnored private var macQueuesLoadedAt: Date?
    /// Aufgelöste Hostnamen bekannter Drucker (`DiscoveryNetworks.hostKey` → IPv4-Adresse).
    private var resolvedHosts: [String: String] = [:]
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFull = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Ergebnisse

    /// Drucker, die zuletzt (innerhalb von 35 Minuten) geantwortet haben.
    var recentPrinters: [DiscoveredPrinter] {
        let limit = Date().addingTimeInterval(-Self.visibility)
        return found.filter { (lastSeen[$0.id] ?? .distantPast) >= limit }
    }

    /// Seitenleiste „Neue Zebra-Drucker [N]“: noch nicht eingerichtete Zebra-Drucker der letzten
    /// 35 Minuten – je physischem Gerät einer (Zebra-Suche, Netzwerk-Scan, Bonjour, Bluetooth und USB
    /// desselben Druckers zusammengeführt, `DiscoveryFilter.overview`).
    var newDevices: [DiscoveredDevice] {
        overview(recentPrinters).devices
    }

    /// Identitäten der eingerichteten Drucker für den Abgleich „schon hinzugefügt“
    /// (`DiscoveryFilter`): Verbindung, eigene, übernommene und Etikettentyp-Warteschlangen samt
    /// deren Zielen (`lpstat -v`), Seriennummer, MAC- und IP-Adresse, die der Drucker gemeldet hat.
    var addedIdentities: [AddedPrinterIdentity] {
        (model?.sessions ?? []).map { session in
            let saved = session.saved
            var queueNames = saved.adoptedQueueNames
            if let name = saved.cupsQueueName { queueNames.append(name) }
            queueNames += saved.labelTypes.compactMap(\.queueName)
            return AddedPrinterIdentity(
                descriptor: saved.descriptor,
                queueNames: queueNames,
                serialNumber: session.identity?.serialNumber,
                macAddress: session.identity?.macAddress,
                ipAddress: session.identity?.ipAddress,
                queues: macQueues
            )
        }
    }

    /// Teilt Suchtreffer auf: neue Zebra-Drucker, schon eingerichtete, nicht als Zebra erkannte.
    /// Gemeinsame Regel für „Drucker suchen“, Radar, „Neue Zebra-Drucker“ und den Installationsassistenten.
    func partition(_ printers: [DiscoveredPrinter]) -> DiscoveryFilter.Partition {
        DiscoveryFilter.partition(printers, identities: addedIdentities, resolved: resolvedHosts)
    }

    /// Fasst Suchtreffer zu Geräten zusammen und teilt sie auf: neue Zebra-Drucker (ein Eintrag je
    /// Gerät), vorhandene macOS-Drucker ohne gefundenes Gerät, schon eingerichtete. Gemeinsame Regel für
    /// „Drucker suchen“, die Seitenleiste und den Installationsassistenten.
    func overview(_ printers: [DiscoveredPrinter]) -> DiscoveryOverview {
        DiscoveryFilter.overview(printers, identities: addedIdentities, resolved: resolvedHosts)
    }

    /// `true`, wenn der Drucker schon in LabelWerk eingerichtet ist – über dieselbe Verbindung, eine
    /// seiner macOS-Warteschlangen, Seriennummer, MAC-Adresse, Bonjour-Namen oder dieselbe Adresse
    /// (auch über den aufgelösten Hostnamen; `DiscoveryFilter.matchingIdentityIndex`).
    func isAdded(_ printer: DiscoveredPrinter) -> Bool {
        addedSession(for: printer) != nil
    }

    /// Der eingerichtete Drucker, der dasselbe Gerät ist wie `printer`.
    func addedSession(for printer: DiscoveredPrinter) -> PrinterSession? {
        guard let sessions = model?.sessions, !sessions.isEmpty else { return nil }
        let identities = addedIdentities
        guard let index = DiscoveryFilter.matchingIdentityIndex(for: printer, among: identities, resolved: resolvedHosts),
              sessions.indices.contains(index) else { return nil }
        return sessions[index]
    }

    // MARK: Start & Zeitplan

    /// Startet die automatische Suche (nur der erste Aufruf wirkt; `AppModel.start()`).
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.appDidBecomeActive() }
        }
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: NetworkDiscoveryService.launchDelay)
            self?.tick(initial: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: NetworkDiscoveryService.tickInterval)
                self?.tick(initial: false)
            }
        }
    }

    private var isAutomatic: Bool { model?.preferences.automaticNetworkDiscovery ?? false }

    private func tick(initial: Bool) {
        guard isAutomatic else { return }
        if initial || lastFullSearch == nil {
            search(.full)
            return
        }
        let last = [lastQuickSearch, lastFullSearch].compactMap { $0 }.max() ?? .distantPast
        if Date().timeIntervalSince(last) >= Self.backgroundInterval {
            search(.quick)
        }
    }

    private func appDidBecomeActive() {
        // Vor der ersten geplanten Suche nichts tun (die folgt ohnehin kurz nach dem Start).
        guard isAutomatic, let lastFullSearch else { return }
        if Date().timeIntervalSince(lastFullSearch) >= Self.fullSearchMaxAge { search(.full) }
    }

    /// Nach Änderungen an Netzen bzw. dem Schalter „Automatisch suchen“.
    func preferencesDidChange(old: AppPreferences, new: AppPreferences) {
        let networksChanged = old.extraDiscoveryNetworks != new.extraDiscoveryNetworks
        if networksChanged { updatePlan() }
        // Neue eigene Netze gleich durchsuchen (Zebra-Suche, schnell und gefahrlos).
        if networksChanged, new.automaticNetworkDiscovery, hasStarted,
           new.extraDiscoveryNetworks.contains(where: { !old.extraDiscoveryNetworks.contains($0) }) {
            search(.quick)
        }
        if new.automaticNetworkDiscovery, !old.automaticNetworkDiscovery, hasStarted, lastFullSearch == nil {
            search(.full)
        }
    }

    // MARK: Suchen

    /// Startet einen Suchlauf. Läuft schon einer, folgt eine angeforderte vollständige Suche danach.
    func search(_ kind: Kind) {
        guard runTask == nil else {
            if kind == .full && currentKind != .full { pendingFull = true }
            return
        }
        isSearching = true
        currentKind = kind
        runTask = Task { [weak self] in
            await self?.perform(kind)
        }
    }

    /// „Erneut suchen“: vollständige Suche, auch wenn die automatische Suche aus ist.
    func searchNow() {
        search(.full)
    }

    private func perform(_ kind: Kind) async {
        let runStart = Date()
        await refreshKnownNetworks()
        let options = discoveryOptions()
        let interfaces = SubnetScanner.allIPv4Interfaces()
        let plan = PrinterDiscovery.plan(options: options, interfaces: interfaces)
        self.plan = plan
        let sources: Set<DiscoverySource> = kind == .full ? [.zebra, .bonjour, .network] : [.zebra]
        let timeout: Duration = kind == .full ? plan.estimatedScanDuration() : .seconds(8)
        for await printer in PrinterDiscovery(options: options).discover(sources: sources, timeout: timeout) {
            absorb(printer)
        }
        // Im Hintergrund zusätzlich die Drucker einzeln prüfen (Port 9100, SNMP/`~HI`), die bisher
        // gefunden wurden, aber diesmal nicht auf die Zebra-Suche geantwortet haben – etwa weil VPN oder
        // Firewall UDP 4201 sperren. Nur eine Handvoll Verbindungen, kein Scan; so verschwinden sie nicht
        // nach 35 Minuten aus „Neue Zebra-Drucker“, solange sie erreichbar sind.
        if kind == .quick {
            let hosts = recheckHosts(notSeenSince: runStart)
            if !hosts.isEmpty {
                var recheck = options
                recheck.networkHosts = hosts
                for await printer in PrinterDiscovery(options: recheck).discover(sources: [.network], timeout: .seconds(10)) {
                    absorb(printer)
                }
            }
        }
        lastProblem = interfaces.isEmpty ? tr("Keine aktive Netzwerkverbindung.") : nil
        let now = Date()
        if kind == .full { lastFullSearch = now } else { lastQuickSearch = now }
        isSearching = false
        currentKind = nil
        runTask = nil
        if pendingFull {
            pendingFull = false
            search(.full)
        }
    }

    /// Netzwerkdrucker, die noch als „im Netzwerk“ gelten, aber seit `start` nicht geantwortet haben.
    private func recheckHosts(notSeenSince start: Date) -> [String] {
        var hosts: [String] = []
        for printer in recentPrinters where (lastSeen[printer.id] ?? .distantPast) < start {
            guard case .tcp(let host, _) = printer.descriptor, printer.source != .cups, !hosts.contains(host) else { continue }
            hosts.append(host)
            if hosts.count >= Self.maxRecheckHosts { break }
        }
        return hosts
    }

    /// Übernimmt einen Fund (auch aus „Drucker suchen“ und dem Installationsassistenten).
    func absorb(_ printer: DiscoveredPrinter) {
        let id = registry.matchingID(for: printer) ?? printer.id
        let outcome = registry.insert(printer)
        lastSeen[id] = Date()
        if outcome != .duplicate || found.count != registry.printers.count {
            animate { found = registry.printers }
        }
    }

    /// Übernimmt die Funde eines Suchlaufs aus „Drucker suchen“. `full`: Der Lauf umfasste Zebra-Suche
    /// und Netzwerk-Scan (zählt wie eine vollständige Suche).
    func absorb(_ printers: [DiscoveredPrinter], full: Bool) {
        for printer in printers where printer.source != .cups { absorb(printer) }
        if full { lastFullSearch = Date() }
    }

    // MARK: Netze

    /// Wie ``discoveryOptions()``, liest aber vorher die macOS-Warteschlangen neu, wenn sie noch nie bzw.
    /// vor über einer Minute gelesen wurden – damit auch Drucker, die nur als macOS-Warteschlange
    /// eingerichtet sind (z. B. „10.62.13.19“), ihr Netz in die erste Suche einbringen.
    func preparedDiscoveryOptions() async -> PrinterDiscovery.Options {
        await refreshKnownPrintersIfStale()
        return discoveryOptions()
    }

    /// Liest macOS-Warteschlangen und Hostnamen neu, wenn sie noch nie bzw. vor über einer Minute
    /// gelesen wurden (für Netze und den Abgleich „schon eingerichtet“).
    func refreshKnownPrintersIfStale() async {
        if macQueuesLoadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            await refreshKnownNetworks()
        }
    }

    /// Suchoptionen mit den Netzen bekannter Drucker und den eigenen Netzen (für jede Suche der App).
    func discoveryOptions() -> PrinterDiscovery.Options {
        var options = PrinterDiscovery.Options()
        options.extraNetworks = userNetworkEntries + currentKnownNetworkEntries()
        return options
    }

    /// Eigene Netze aus den Einstellungen.
    var userNetworkEntries: [DiscoveryNetworkEntry] {
        (model?.preferences.extraDiscoveryNetworks ?? []).map { DiscoveryNetworkEntry($0, origin: .user) }
    }

    /// Plant die Suche neu (z. B. nach dem Bearbeiten der Netze), ohne zu suchen.
    func updatePlan() {
        plan = PrinterDiscovery.plan(options: discoveryOptions())
    }

    /// Vorschläge für eigene Netze: Netze bekannter Drucker, die noch nicht eingetragen sind.
    var suggestedNetworks: [DiscoveryNetworkEntry] {
        let user = Set((model?.preferences.extraDiscoveryNetworks ?? []).compactMap { text -> String? in
            guard case .success(let range) = DiscoveryNetworks.parse(text) else { return nil }
            return range.description
        })
        return currentKnownNetworkEntries().filter { !user.contains($0.text) }
    }

    /// Netze der eingerichteten Drucker (sofort) und der zuletzt gelesenen macOS-Warteschlangen.
    private func currentKnownNetworkEntries() -> [DiscoveryNetworkEntry] {
        DiscoveryNetworks.knownPrinterNetworks(knownPrinterHosts(), resolved: resolvedHosts)
    }

    private func knownPrinterHosts() -> [(host: String, label: String?)] {
        var result: [(host: String, label: String?)] = []
        for session in model?.sessions ?? [] {
            if let host = Self.host(of: session.saved.descriptor) { result.append((host: host, label: session.displayName)) }
            if let address = session.identity?.ipAddress { result.append((host: address, label: session.displayName)) }
            for host in queueHosts(of: session.saved) { result.append((host: host, label: session.displayName)) }
        }
        // Zebra-Warteschlangen in macOS („Drucker & Scanner“), auch ohne Drucker in LabelWerk.
        for queue in macQueues where queue.looksLikeZebra {
            if let host = DiscoveryNetworks.host(ofDeviceURI: queue.deviceURI) { result.append((host: host, label: queue.name)) }
        }
        return result
    }

    /// Hosts der macOS-Warteschlangen eines Druckers (eigene, übernommene bzw. die Verbindung selbst).
    private func queueHosts(of saved: SavedPrinter) -> [String] {
        var names = saved.adoptedQueueNames
        if let name = saved.cupsQueueName { names.append(name) }
        if case .cupsQueue(let name) = saved.descriptor { names.append(name) }
        return names.compactMap { name in
            macQueues.first { $0.name == name }.flatMap { DiscoveryNetworks.host(ofDeviceURI: $0.deviceURI)?.lowercased() }
        }
    }

    /// Liest die macOS-Warteschlangen (`lpstat -v`) für Netze und den Abgleich „schon eingerichtet“ und
    /// löst die Hostnamen bekannter Drucker auf (z. B. `socket://zebra-lager.firma.local`; außerhalb des
    /// Main-Threads, je Name höchstens 2 s) – sonst trügen sie kein Netz bei.
    private func refreshKnownNetworks() async {
        macQueues = await CUPSService.queues()
        macQueuesLoadedAt = Date()
        resolvedHosts = await DiscoveryNetworks.resolveHostnames(knownPrinterHosts().map(\.host))
        knownNetworkEntries = currentKnownNetworkEntries()
    }

    // MARK: Hilfen

    private static func host(of descriptor: ConnectionDescriptor) -> String? {
        guard case .tcp(let host, _) = descriptor else { return nil }
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        return value.isEmpty ? nil : value
    }

    private func animate(_ changes: () -> Void) {
        if let model {
            model.animate(Motion.spring, changes)
        } else {
            changes()
        }
    }
}

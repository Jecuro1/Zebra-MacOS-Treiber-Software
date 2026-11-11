import Foundation
import LabelWerkCore

// MARK: - Physisches Gerät

/// Ein physischer Drucker, zusammengeführt aus den Funden aller Quellen (``DiscoveryFilter/groupDevices(_:resolved:)``).
///
/// Ein Zebra-Drucker meldet sich oft mehrfach: auf die Zebra-Suche (UDP 4201), beim Netzwerk-Scan, per
/// Bonjour, über Bluetooth LE (Name = Seriennummer), per USB und als eine oder mehrere
/// macOS-Warteschlangen. In der Oberfläche erscheint er genau einmal – mit allen Wegen, über die er
/// erreichbar ist (``paths``), und der besten Verbindung zum Hinzufügen (``preferred``).
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    /// Weg, über den das Gerät erreichbar ist.
    public enum Path: String, CaseIterable, Hashable, Sendable {
        case network, usb, bluetooth, macPrinter

        /// Deutscher Anzeigename.
        public var displayName: String {
            switch self {
            case .network: return "Netzwerk"
            case .usb: return "USB"
            case .bluetooth: return "Bluetooth"
            case .macPrinter: return "macOS-Drucker"
            }
        }

        /// SF Symbol (SF Symbols 5).
        public var systemImage: String {
            switch self {
            case .network: return "network"
            case .usb: return "cable.connector"
            case .bluetooth: return "antenna.radiowaves.left.and.right"
            case .macPrinter: return "printer"
            }
        }
    }

    /// Stabil, solange das Gerät dieselbe Seriennummer bzw. MAC-Adresse meldet (sonst die Kennung der
    /// besten Verbindung).
    public var id: String
    /// Alle Funde dieses Geräts (Reihenfolge der Eingabe).
    public var members: [DiscoveredPrinter]
    /// Beste Verbindung zum Hinzufügen (Netzwerk-Rohdatenport vor USB vor Bluetooth vor
    /// macOS-Warteschlange), ergänzt um Name (``title``), Modellhinweis und Seriennummer des Geräts.
    public var preferred: DiscoveredPrinter
    /// Kurzer Modellname („ZD421t“) oder `nil`, wenn unbekannt.
    public var modelName: String?
    /// Modell zum Anzeigen: „Zebra ZD421t“ bzw. „Zebra-Drucker“.
    public var displayModel: String
    /// Name des Geräts: eigener Name des Druckers (Systemname, Bonjour-Name …), wenn er etwas sagt –
    /// sonst ``displayModel``. Nie die Seriennummer oder die Adresse.
    public var title: String
    /// `true`, wenn ``title`` ein eigener Name des Druckers ist (nicht das Modell).
    public var hasCustomName: Bool
    /// Netzwerkadresse (bevorzugt IPv4) oder `nil`.
    public var address: String?
    /// Seriennummer des Druckers (Großbuchstaben) oder `nil`.
    public var serialNumber: String?
    /// MAC-Adresse („00:07:4D:12:34:56“) oder `nil`.
    public var macAddress: String?
    /// Erreichbar über (in fester Reihenfolge: Netzwerk, USB, Bluetooth, macOS-Drucker).
    public var paths: [Path]
    /// Namen der macOS-Warteschlangen, die zu diesem Gerät führen.
    public var queueNames: [String]

    /// `true`, wenn das Gerät nur als macOS-Warteschlange bekannt ist (kein Fund im Netzwerk, per USB
    /// oder Bluetooth).
    public var isMacQueueOnly: Bool { paths == [.macPrinter] }

    /// Funde, die über `path` führen.
    public func members(on path: Path) -> [DiscoveredPrinter] {
        members.filter { DiscoveryFilter.path(of: $0) == path }
    }
}

// MARK: - Übersicht

/// Suchergebnis nach Geräten: neue Drucker, vorhandene macOS-Drucker ohne passenden Fund, schon
/// eingerichtete (ausgeblendete) Drucker.
public struct DiscoveryOverview: Equatable, Sendable {
    /// Neue, noch nicht eingerichtete Zebra-Drucker – je physischem Gerät ein Eintrag.
    public var devices: [DiscoveredDevice] = []
    /// Zebra- bzw. LabelWerk-Warteschlangen in macOS, zu denen kein Gerät gefunden wurde und die noch
    /// nicht in LabelWerk eingerichtet sind („Vorhandene macOS-Drucker“).
    public var macQueues: [DiscoveredDevice] = []
    /// Geräte, die schon in LabelWerk eingerichtet sind (ausgeblendet).
    public var added: [DiscoveredDevice] = []
    /// Aufteilung der einzelnen Funde (``DiscoveryFilter/partition(_:identities:resolved:)``).
    public var partition = DiscoveryFilter.Partition()

    public init(devices: [DiscoveredDevice] = [], macQueues: [DiscoveredDevice] = [], added: [DiscoveredDevice] = [],
                partition: DiscoveryFilter.Partition = DiscoveryFilter.Partition()) {
        self.devices = devices
        self.macQueues = macQueues
        self.added = added
        self.partition = partition
    }

    /// Anzahl der ausgeblendeten, schon eingerichteten **Drucker** – für „N bereits hinzugefügt“.
    /// `excluding`: Fund, dessen Drucker nicht mitzählt (z. B. der im Assistenten gewählte).
    public func hiddenAddedPrinterCount(excluding printerID: String? = nil) -> Int {
        partition.hiddenAddedPrinterCount(excluding: printerID)
    }

    /// Das Gerät (neu, macOS-Drucker oder eingerichtet), zu dem der Fund `printerID` gehört.
    public func device(containing printerID: String) -> DiscoveredDevice? {
        (devices + macQueues + added).first { device in device.members.contains { $0.id == printerID } }
    }
}

// MARK: - Zusammenführen

extension DiscoveryFilter {
    /// Teilt Suchtreffer auf und fasst sie zu Geräten zusammen: nur sicher als Zebra erkannte Funde
    /// (``isIdentifiedZebra(_:)``); ein Gerät gilt als eingerichtet, sobald **einer** seiner Funde zu einem
    /// eingerichteten Drucker gehört (``matchingIdentityIndex(for:among:resolved:)``) – so verschwindet mit
    /// der Netzwerkverbindung auch sein Bluetooth-LE-Eintrag und seine macOS-Warteschlange.
    public static func overview(_ printers: [DiscoveredPrinter], identities: [AddedPrinterIdentity],
                                resolved: [String: String] = [:]) -> DiscoveryOverview {
        let partition = partition(printers, identities: identities, resolved: resolved)
        let unidentified = Set(partition.unidentified.map(\.id))
        let identified = printers.filter { !unidentified.contains($0.id) }
        var overview = DiscoveryOverview(partition: partition)
        for device in groupDevices(identified, resolved: resolved) {
            if device.members.contains(where: { partition.addedIdentityIndexByID[$0.id] != nil }) {
                overview.added.append(device)
            } else if device.isMacQueueOnly {
                overview.macQueues.append(device)
            } else {
                overview.devices.append(device)
            }
        }
        return overview
    }

    /// Fasst Funde desselben physischen Geräts zusammen. Dasselbe Gerät ist es bei
    ///
    /// 1. **sicheren Merkmalen** (immer): gleicher Verbindung (`stableID`), gleicher Seriennummer des
    ///    Druckers – auch wenn sie nur als Name auftritt (Bluetooth-/BLE-Name, Systemname der
    ///    Zebra-Suche, Bonjour-Name im Seriennummernformat, ``nameSerialNumbers(of:)``) –, gleicher
    ///    Seriennummer des Druckservers, gleicher MAC-Adresse, demselben Bonjour-Dienstnamen (auch aus
    ///    einer `dnssd://`-Warteschlange; auf dem Link eindeutig, darum auch Modellnamen wie
    ///    „ZTC ZD421t-203dpi ZPL“) bzw. demselben USB-Gerät;
    /// 2. **gleicher Netzwerkadresse** (Absender der Zebra-Suche, Netzwerk-Scan, Bonjour, Ziel einer
    ///    macOS-Warteschlange; Hostnamen über `resolved`; Ports wie ``portsMatch(_:_:)``) – außer die
    ///    beiden Gruppen nennen verschiedene Seriennummern bzw. MAC-Adressen (Adresse neu vergeben);
    /// 3. **gleichem eigenem Namen** (Systemname, `sysName`, Bonjour-Name, Bluetooth-Name; keine
    ///    allgemeinen Namen wie „Zebra ZD421“ oder Adressen) – nur wenn der Name eindeutig ist:
    ///    Widersprechen sich zwei der Gruppen, die ihn tragen, in Seriennummer, MAC-Adresse, (beide mit
    ///    Adresse) in der Netzwerkadresse oder sind es zwei verschiedene Bluetooth-Geräte derselben Art,
    ///    wird über diesen Namen gar nichts zusammengeführt.
    ///
    /// Reihenfolge: Netzwerkdrucker nach Adresse, dann USB, Bluetooth und reine macOS-Warteschlangen.
    public static func groupDevices(_ printers: [DiscoveredPrinter], resolved: [String: String] = [:]) -> [DiscoveredDevice] {
        guard !printers.isEmpty else { return [] }
        let keys = printers.map { GroupKeys(printer: $0) }
        var groups = UnionFind(keys: keys)

        // 1. Sichere Merkmale.
        for left in keys.indices {
            for right in keys.indices where right > left && keys[left].sharesHardKey(with: keys[right]) {
                groups.union(left, right)
            }
        }
        // 2. Netzwerkadresse.
        for left in keys.indices {
            for right in keys.indices where right > left && keys[left].sharesEndpoint(with: keys[right], resolved: resolved) {
                let a = groups.find(left), b = groups.find(right)
                if a != b, !groups.aggregate[a].conflictsInIdentity(with: groups.aggregate[b]) { groups.union(a, b) }
            }
        }
        // 3. Eigener Name – nur, wenn er eindeutig ist: Tragen ihn Gruppen, die sich widersprechen
        //    (z. B. zwei Drucker „Etiketten“ unter verschiedenen Adressen), gehört ein Bluetooth- oder
        //    Bonjour-Fund dieses Namens zu keinem von beiden – statt zufällig zum ersten.
        var indicesByName: [String: [Int]] = [:]
        for index in keys.indices {
            for name in keys[index].names { indicesByName[name, default: []].append(index) }
        }
        for name in indicesByName.keys.sorted() {
            var roots: [Int] = []
            for index in indicesByName[name] ?? [] {
                let root = groups.find(index)
                if !roots.contains(root) { roots.append(root) }
            }
            guard roots.count > 1 else { continue }
            let compatible = roots.indices.allSatisfy { left in
                roots.indices.allSatisfy { right in
                    right <= left || groups.aggregate[roots[left]].maySharePrinterName(with: groups.aggregate[roots[right]],
                                                                                        resolved: resolved)
                }
            }
            guard compatible else { continue }
            for root in roots.dropFirst() { groups.union(roots[0], root) }
        }

        var order: [Int] = []
        var membersByRoot: [Int: [DiscoveredPrinter]] = [:]
        for index in printers.indices {
            let root = groups.find(index)
            if membersByRoot[root] == nil { order.append(root) }
            membersByRoot[root, default: []].append(printers[index])
        }
        let devices = order.compactMap { membersByRoot[$0].map { makeDevice($0, resolved: resolved) } }
        return devices.enumerated().sorted { lhs, rhs in
            let left = sortKey(lhs.element), right = sortKey(rhs.element)
            if left.rank != right.rank { return left.rank < right.rank }
            if left.address != right.address { return left.address < right.address }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Weg eines einzelnen Funds.
    public static func path(of printer: DiscoveredPrinter) -> DiscoveredDevice.Path? {
        switch printer.descriptor {
        case .tcp: return printer.source == .cups ? .macPrinter : .network
        case .usb: return .usb
        case .bluetooth, .ble: return .bluetooth
        case .cupsQueue: return .macPrinter
        case .virtual: return nil
        }
    }

    /// `true` für Namen, die nichts über das einzelne Gerät sagen: leer, Adressen, Seriennummern,
    /// Platzhalter der Suche und reine Modellnamen („Zebra ZD421“, „ZTC ZD421-203dpi ZPL“).
    public static func isGenericPrinterName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isAddress(trimmed) || ZebraIdentifiers.looksLikeZebraSerialNumber(trimmed) { return true }
        let lower = trimmed.lowercased()
        if ["zebra", "zebra-drucker", "zebra-drucker (ble)", "zebra usb-drucker", "zebra printer"].contains(lower) { return true }
        guard let short = ZebraIdentifiers.shortModelName(from: trimmed) else { return true }
        if isAddress(short) { return true }
        let normalizedShort = normalized(short)
        if let model = ModelCatalog.shared.match(productName: short) {
            let full = normalized(model.name)
            if normalizedShort == full || normalizedShort == baseModelName(full) { return true }
        }
        return false
    }

    // MARK: Gerät bilden

    static func makeDevice(_ members: [DiscoveredPrinter], resolved: [String: String]) -> DiscoveredDevice {
        let ranked = members.enumerated().sorted { lhs, rhs in
            let left = connectionRank(lhs.element), right = connectionRank(rhs.element)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var preferred = ranked[0]

        // Seriennummer: ausdrücklich gemeldete zuerst, dann Namen im Seriennummernformat.
        var serials: [String] = []
        for member in members {
            for text in [member.details["serialNumber"], usbSerial(of: member)] {
                if let key = text.flatMap(serialKey), !serials.contains(key) { serials.append(key) }
            }
        }
        for member in members {
            for key in nameSerialNumbers(of: member) where !serials.contains(key) { serials.append(key) }
        }
        let macKey = members.lazy.compactMap { DiscoveryRegistry.macKey($0.details["macAddress"]) }.first

        let model = bestModel(members)
        let displayModel = model.name.map { "Zebra \($0)" } ?? "Zebra-Drucker"
        let customName = friendlyName(members, modelName: model.name)
        let title = customName ?? displayModel

        var queueNames: [String] = []
        for member in members {
            guard case .cupsQueue(let name) = member.descriptor,
                  !queueNames.contains(where: { sameQueueName($0, name) }) else { continue }
            queueNames.append(name)
        }
        var paths: [DiscoveredDevice.Path] = []
        for path in DiscoveredDevice.Path.allCases where members.contains(where: { self.path(of: $0) == path }) {
            paths.append(path)
        }

        // Die beste Verbindung bringt mit, was die anderen Funde über das Gerät wissen.
        preferred.name = title
        if let hint = model.hint, preferred.modelHint.map({ ZebraIdentifiers.looksLikeZebraSerialNumber($0) || model.isExact }) ?? true {
            preferred.modelHint = hint
        }
        if preferred.details["serialNumber"] == nil, let serial = serials.first { preferred.details["serialNumber"] = serial }
        if preferred.details["macAddress"] == nil, let macKey { preferred.details["macAddress"] = formattedMAC(macKey) }

        let id = serials.first.map { "device:serial:\($0)" }
            ?? macKey.map { "device:mac:\($0)" }
            ?? "device:\(preferred.id)"
        return DiscoveredDevice(
            id: id,
            members: members,
            preferred: preferred,
            modelName: model.name,
            displayModel: displayModel,
            title: title,
            hasCustomName: customName != nil,
            address: bestAddress(ranked, resolved: resolved),
            serialNumber: serials.first,
            macAddress: macKey.map(formattedMAC),
            paths: paths,
            queueNames: queueNames
        )
    }

    /// Rang einer Verbindung zum Hinzufügen: Netzwerk (Rohdatenport, sicher erkannt, IP-Adresse) vor USB
    /// vor Bluetooth vor Bluetooth LE vor macOS-Warteschlange.
    static func connectionRank(_ printer: DiscoveredPrinter) -> Int {
        switch printer.descriptor {
        case .tcp(let host, let port):
            if printer.source == .cups { return 90 }
            var rank = 0
            if port != ZebraIdentifiers.rawPort { rank += 4 }
            if !isAddress(host) { rank += 2 }
            if DiscoveryRegistry.identificationRank(printer) < 3 { rank += 1 }
            return rank
        case .usb: return 20
        case .bluetooth: return 30
        case .ble: return 40
        case .cupsQueue: return 50
        case .virtual: return 99
        }
    }

    /// Modell aus allen Modellhinweisen: eine eindeutige Katalogzuordnung („ZD421t“ im Hinweis) gewinnt;
    /// sonst der gekürzte Modellname des besten Hinweises („ZD421“ aus „ZTC ZD421-203dpi ZPL“).
    static func bestModel(_ members: [DiscoveredPrinter]) -> (name: String?, hint: String?, isExact: Bool) {
        var hints: [String] = []
        let ordered = members.sorted { modelHintRank($0) < modelHintRank($1) }
        for member in ordered {
            var texts = [member.modelHint, member.details["productName"]]
            if member.source == .cups || member.descriptor.kind == .cupsQueue {
                texts.append(member.details["makeAndModel"])
            }
            if case .usb(let device) = member.descriptor { texts.append(device.productName) }
            for text in texts {
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      !ZebraIdentifiers.looksLikeZebraSerialNumber(text), !hints.contains(text) else { continue }
                hints.append(text)
            }
        }
        for hint in hints {
            guard let model = ModelCatalog.shared.match(productName: hint),
                  normalized(hint).contains(normalized(model.name)) else { continue }
            return (model.name, hint, true)
        }
        for hint in hints {
            guard let model = ModelCatalog.shared.match(productName: hint) else { continue }
            let short = ZebraIdentifiers.shortModelName(from: hint).flatMap { text -> String? in
                let cleaned = text.replacingOccurrences(of: #"-\d{3}dpi.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                return cleaned.isEmpty || cleaned.contains(" ") ? nil : cleaned
            }
            return (short ?? baseDisplayName(model.name), hint, false)
        }
        return (nil, nil, false)
    }

    /// Wie verlässlich der Modellhinweis einer Quelle ist (kleiner = besser).
    static func modelHintRank(_ printer: DiscoveredPrinter) -> Int {
        switch printer.source {
        case .zebra: return 0
        case .network: return 1
        case .usb: return 2
        case .bonjour: return 3
        case .cups: return 4
        case .bluetooth, .ble: return 5
        }
    }

    /// Eigener Name des Druckers, wenn er etwas sagt: Systemname der Zebra-Suche, SNMP-`sysName`,
    /// Bonjour-Name, Bluetooth-Name (in dieser Reihenfolge). Warteschlangennamen zählen nicht.
    static func friendlyName(_ members: [DiscoveredPrinter], modelName: String?) -> String? {
        var candidates: [String?] = []
        for member in members where member.source == .zebra { candidates.append(member.details["name"]) }
        for member in members { candidates.append(member.details["sysName"]) }
        for member in members where member.source == .bonjour { candidates.append(member.details["serviceName"]) }
        for member in members {
            switch member.descriptor {
            case .bluetooth(_, let name), .ble(_, let name): candidates.append(name)
            default: break
            }
        }
        for candidate in candidates {
            guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !isGenericPrinterName(name) else { continue }
            if let modelName, normalized(name) == normalized(modelName) || normalized(name) == normalized("Zebra \(modelName)") { continue }
            return name
        }
        return nil
    }

    /// Adresse zum Anzeigen: IPv4 der besten Netzwerkverbindung, sonst eine andere IPv4-Adresse der
    /// Funde (auch das Ziel einer Warteschlange bzw. ein aufgelöster Hostname), sonst ein Hostname.
    static func bestAddress(_ ranked: [DiscoveredPrinter], resolved: [String: String]) -> String? {
        var hosts: [String] = []
        for member in ranked {
            if case .tcp(let host, _) = member.descriptor, member.source != .cups { hosts.append(host) }
        }
        for member in ranked {
            if let host = member.details["host"] { hosts.append(host) }
            if let uri = member.details["deviceURI"], let endpoint = QueueAdoption.deviceEndpoint(ofDeviceURI: uri) {
                hosts.append(endpoint.host)
            }
        }
        let cleaned = hosts.map { host -> String in
            var value = host.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
            return value
        }.filter { !$0.isEmpty }
        if let ipv4 = cleaned.first(where: { SubnetScanner.parseIPv4($0) != nil }) { return ipv4 }
        for host in cleaned {
            if let address = resolved[DiscoveryNetworks.hostKey(host)], SubnetScanner.parseIPv4(address) != nil { return address }
        }
        return cleaned.first
    }

    static func sortKey(_ device: DiscoveredDevice) -> (rank: Int, address: String) {
        let rank: Int
        switch device.paths.first {
        case .network: rank = 0
        case .usb: rank = 1
        case .bluetooth: rank = 2
        case .macPrinter, nil: rank = 3
        }
        // IPv4 numerisch sortierbar (10.62.13.9 vor 10.62.13.18), sonst Name.
        if let address = device.address, let value = SubnetScanner.parseIPv4(address) {
            return (rank, String(format: "0-%010u", value))
        }
        return (rank, "1-" + (device.address ?? device.title).lowercased())
    }

    // MARK: Hilfen

    static func usbSerial(of printer: DiscoveredPrinter) -> String? {
        if case .usb(let device) = printer.descriptor { return device.serialNumber }
        if let uri = printer.details["deviceURI"], uri.lowercased().hasPrefix("usb://") { return queryValue("serial", in: uri) }
        return nil
    }

    static func isAddress(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if SubnetScanner.parseIPv4(value) != nil { return true }
        return value.contains(":") && value.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }
    }

    /// Kleinbuchstaben, nur Buchstaben und Ziffern.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// „zd421t“ → „zd421“ (Ausstattungsbuchstabe d/t/c nach einer Ziffer entfernt).
    static func baseModelName(_ normalizedName: String) -> String {
        var base = normalizedName
        if let last = base.last, "dtc".contains(last), base.dropLast().last?.isNumber == true { base.removeLast() }
        return base
    }

    /// „ZD421t“ → „ZD421“ für die Anzeige, wenn nur die Baureihe sicher ist.
    static func baseDisplayName(_ name: String) -> String {
        guard let last = name.last, "dtcDTC".contains(last), name.dropLast().last?.isNumber == true else { return name }
        return String(name.dropLast())
    }

    /// „00074D123456“ → „00:07:4D:12:34:56“.
    static func formattedMAC(_ key: String) -> String {
        var pairs: [String] = []
        var index = key.startIndex
        while index < key.endIndex {
            let next = key.index(index, offsetBy: 2, limitedBy: key.endIndex) ?? key.endIndex
            pairs.append(String(key[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }
}

// MARK: - Merkmale & Gruppen (intern)

/// Vergleichsmerkmale eines Funds bzw. (vereinigt) einer Gruppe.
struct GroupKeys {
    var stableIDs: Set<String> = []
    var serials: Set<String> = []
    var printServerSerials: Set<String> = []
    var macs: Set<String> = []
    var endpoints: [AddedPrinterIdentity.Endpoint] = []
    /// Eigene Namen (klein geschrieben): Systemname, `sysName`, Bonjour-Name, Bluetooth-Name.
    var names: Set<String> = []
    /// Bonjour-Dienstnamen (klein geschrieben) – des Bonjour-Funds bzw. aus einer `dnssd://`- oder
    /// `mdns://`-Warteschlange. Auf dem Link eindeutig, darum ein sicheres Merkmal, auch wenn der Name
    /// allgemein klingt („ZTC ZD421t-203dpi ZPL“).
    var bonjourServices: Set<String> = []
    /// Arten der Funkverbindungen („ble“, „bluetooth“): Zwei Gruppen mit derselben Art sind (ohne
    /// gemeinsame Verbindung) zwei verschiedene Geräte – auch wenn sie gleich heißen.
    var radioKinds: Set<String> = []
    var usbDevices: [USBDeviceIdentifier] = []

    init() {}

    init(printer: DiscoveredPrinter) {
        let found = DiscoveryFilter.foundKeys(of: printer)
        // Gleiche Netzwerkverbindung zählt als Adresse (Stufe 2, mit Widerspruchsprüfung) – eine neu
        // vergebene IP-Adresse macht aus zwei Druckern nicht einen.
        if case .tcp = printer.descriptor {} else { stableIDs = [found.stableID] }
        serials = Set(found.serialNumbers)
        // Seriennummer des Druckservers (Zebra-Suche): eigener Namensraum wie in `DiscoveryRegistry`.
        if let serial = printer.details["printServerSerial"].flatMap(DiscoveryFilter.serialKey) {
            printServerSerials.insert(serial)
        }
        if let mac = found.macAddress { macs.insert(mac) }
        // Warteschlangen über Druckserver-Freigaben tragen keine Adresse bei (foundKeys); die Adresse des
        // Bonjour-Diensts zählt nur mit, wenn sie das Gerät nennt (wie bei jedem anderen Fund).
        endpoints = found.endpoints
        if let device = found.usbDevice { usbDevices.append(device) }
        bonjourServices = Set(found.serviceNames.map { $0.lowercased() })
        switch printer.descriptor {
        case .ble: radioKinds = ["ble"]
        case .bluetooth: radioKinds = ["bluetooth"]
        default: break
        }
        var texts: [String?] = [printer.details["sysName"]]
        if printer.source == .zebra { texts.append(printer.details["name"]) }
        if printer.source == .bonjour || printer.details["serviceType"] != nil { texts.append(printer.details["serviceName"]) }
        switch printer.descriptor {
        case .bluetooth(_, let name), .ble(_, let name): texts.append(name)
        default: break
        }
        texts += found.serviceNames
        for text in texts {
            guard let name = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !DiscoveryFilter.isGenericPrinterName(name) else { continue }
            names.insert(name.lowercased())
        }
    }

    func sharesHardKey(with other: GroupKeys) -> Bool {
        if !stableIDs.isDisjoint(with: other.stableIDs) { return true }
        if !serials.isDisjoint(with: other.serials) { return true }
        if !printServerSerials.isDisjoint(with: other.printServerSerials) { return true }
        if !macs.isDisjoint(with: other.macs) { return true }
        if !bonjourServices.isDisjoint(with: other.bonjourServices) { return true }
        for left in usbDevices {
            for right in other.usbDevices where DiscoveryFilter.sameUSBDevice(left, right) { return true }
        }
        return false
    }

    func sharesEndpoint(with other: GroupKeys, resolved: [String: String]) -> Bool {
        for left in endpoints {
            let leftHosts = DiscoveryFilter.expanded(left.host, resolved: resolved)
            for right in other.endpoints where DiscoveryFilter.portsMatch(left.port, right.port) {
                if !leftHosts.isDisjoint(with: DiscoveryFilter.expanded(right.host, resolved: resolved)) { return true }
            }
        }
        return false
    }

    /// `true`, wenn die Gruppe eine IP-Adresse kennt (direkt oder über einen aufgelösten Hostnamen).
    func hasAddress(resolved: [String: String]) -> Bool {
        endpoints.contains { endpoint in
            DiscoveryFilter.expanded(endpoint.host, resolved: resolved).contains { DiscoveryFilter.isAddress($0) }
        }
    }

    /// Widersprechen sich zwei Gruppen in Seriennummer oder MAC-Adresse (beide bekannt, keine gemeinsam)?
    func conflictsInIdentity(with other: GroupKeys) -> Bool {
        if !serials.isEmpty, !other.serials.isEmpty, serials.isDisjoint(with: other.serials) { return true }
        if !macs.isEmpty, !other.macs.isEmpty, macs.isDisjoint(with: other.macs) { return true }
        return false
    }

    /// Dürfen zwei Gruppen allein über einen gleichen eigenen Namen zusammengeführt werden? Nein, wenn
    /// sie sich in Seriennummer bzw. MAC-Adresse widersprechen, beide eine IP-Adresse kennen, aber keine
    /// gemeinsame (Hostnamen ohne aufgelöste Adresse widersprechen nichts), oder beide ein (verschiedenes)
    /// Bluetooth-Gerät derselben Art enthalten.
    func maySharePrinterName(with other: GroupKeys, resolved: [String: String]) -> Bool {
        if conflictsInIdentity(with: other) { return false }
        if hasAddress(resolved: resolved), other.hasAddress(resolved: resolved),
           !sharesEndpoint(with: other, resolved: resolved) { return false }
        if !radioKinds.isDisjoint(with: other.radioKinds) { return false }
        return true
    }

    mutating func formUnion(_ other: GroupKeys) {
        stableIDs.formUnion(other.stableIDs)
        serials.formUnion(other.serials)
        printServerSerials.formUnion(other.printServerSerials)
        macs.formUnion(other.macs)
        for endpoint in other.endpoints where !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        names.formUnion(other.names)
        bonjourServices.formUnion(other.bonjourServices)
        radioKinds.formUnion(other.radioKinds)
        usbDevices += other.usbDevices
    }
}

/// Union-Find mit vereinigten Merkmalen je Wurzel.
struct UnionFind {
    private var parent: [Int]
    private(set) var aggregate: [GroupKeys]

    init(keys: [GroupKeys]) {
        parent = Array(keys.indices)
        aggregate = keys
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var current = index
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let a = find(lhs), b = find(rhs)
        guard a != b else { return }
        let (root, child) = a < b ? (a, b) : (b, a)
        parent[child] = root
        aggregate[root].formUnion(aggregate[child])
    }
}

import Foundation
import LabelWerkCore

// MARK: - Identität eingerichteter Drucker

/// Was LabelWerk über einen bereits eingerichteten Drucker weiß – für den Abgleich mit Suchtreffern
/// (``DiscoveryFilter/isAlreadyAdded(_:among:resolved:)``).
///
/// Ein Drucker kann über viele Wege wieder auftauchen: über seine Adresse (auch unter einem Hostnamen
/// oder über seine macOS-Warteschlange „10.62.13.19“), über Bonjour, die Zebra-Suche (Seriennummer,
/// MAC-Adresse) oder per USB. Die Identität sammelt alle diese Merkmale.
public struct AddedPrinterIdentity: Hashable, Sendable {
    /// Netzwerkadresse des Druckers; `port == nil` gilt für jeden Port (z. B. IPP- oder LPD-Warteschlange,
    /// vom Drucker gemeldete eigene IP-Adresse).
    public struct Endpoint: Hashable, Sendable {
        /// Vergleichsform (``DiscoveryNetworks/hostKey(_:)``).
        public var host: String
        public var port: Int?

        public init(host: String, port: Int? = nil) {
            self.host = DiscoveryNetworks.hostKey(host)
            self.port = port
        }
    }

    /// Verbindungen des Druckers (in der Regel genau eine).
    public var descriptors: [ConnectionDescriptor] = []
    /// Netzwerkadressen: Verbindung, gemeldete IP-Adresse, Ziele seiner macOS-Warteschlangen.
    public var endpoints: [Endpoint] = []
    /// Namen seiner macOS-Warteschlangen: eigene, übernommene (`adoptedQueueNames`) und die der
    /// Etikettentypen.
    public var queueNames: [String] = []
    /// Bonjour-Dienstnamen (aus `dnssd://`-Warteschlangen).
    public var serviceNames: [String] = []
    /// Seriennummern des Druckers (`~HI`/SGD, USB, `usb://…?serial=`).
    public var serialNumbers: [String] = []
    /// MAC-Adressen (zwölf Hex-Ziffern).
    public var macAddresses: [String] = []
    /// Hosts seiner Warteschlangen, die nicht das Gerät selbst nennen (Freigabe eines Druckservers
    /// `ipp://server/printers/X`, benannte LPD-Warteschlange `lpd://ps/PORT2`): Sie tragen keine Adresse
    /// bei, und eine vom Drucker gemeldete IP-Adresse dieses Hosts gilt nicht für jeden Port.
    var printServerHosts: [String] = []
    /// Eine seiner Warteschlangen ist eine benannte LPD-Warteschlange (`lpd://ps/PORT2`) – möglicherweise
    /// ein Anschluss eines Druckservers mit mehreren Anschlüssen.
    var usesPrintServerPort = false

    public init() {}

    /// Identität aus der Verbindung, den Warteschlangennamen und dem, was der Drucker selbst gemeldet
    /// hat. `queues`: die macOS-Warteschlangen (`lpstat -v`) – die Ziele der eigenen Warteschlangen
    /// (`queueNames`) werden als weitere Adressen bzw. Bonjour-Namen übernommen.
    public init(descriptor: ConnectionDescriptor,
                queueNames: [String] = [],
                serialNumber: String? = nil,
                macAddress: String? = nil,
                ipAddress: String? = nil,
                queues: [CUPSQueueInfo] = []) {
        addDescriptor(descriptor)
        for name in queueNames { addQueueName(name) }
        if let serialNumber { addSerialNumber(serialNumber) }
        if let macAddress { addMACAddress(macAddress) }
        for queue in queues where self.queueNames.contains(where: { DiscoveryFilter.sameQueueName($0, queue.name) }) {
            addDeviceURI(queue.deviceURI)
        }
        if let ipAddress { addReportedAddress(ipAddress) }
    }

    /// Übernimmt die vom Drucker gemeldete eigene IP-Adresse (`~HI`/SGD). Nach Verbindung und
    /// Warteschlangen aufrufen:
    /// * Läuft die Verbindung über einen anderen als die Rohdatenports 9100/6101 (Anschluss eines
    ///   Druckservers, `tcp(…, 9101)` bzw. `socket://…:9101`), gilt die Adresse nur für diese Ports;
    /// * ist die Adresse der Host einer Druckserver-Warteschlange oder erreicht LabelWerk den Drucker nur
    ///   über eine benannte LPD-Warteschlange (`lpd://ps/PORT2`), wird sie nicht übernommen – sonst
    ///   gälte ein anderer Drucker am selben Druckserver als eingerichtet;
    /// * sonst gilt sie für jeden Port.
    public mutating func addReportedAddress(_ address: String) {
        let host = DiscoveryNetworks.hostKey(address)
        guard !host.isEmpty, !printServerHosts.contains(host) else { return }
        let serverPorts = Set(endpoints.compactMap(\.port)).subtracting([ZebraIdentifiers.rawPort, ZebraIdentifiers.alternateRawPort])
        if !serverPorts.isEmpty {
            for port in serverPorts.sorted() { addEndpoint(Endpoint(host: host, port: port)) }
            return
        }
        if usesPrintServerPort && endpoints.isEmpty { return }
        addEndpoint(Endpoint(host: host))
    }

    public mutating func addDescriptor(_ descriptor: ConnectionDescriptor) {
        if !descriptors.contains(where: { $0.stableID == descriptor.stableID }) { descriptors.append(descriptor) }
        switch descriptor {
        case .tcp(let host, let port):
            addEndpoint(Endpoint(host: host, port: port))
        case .cupsQueue(let name):
            addQueueName(name)
        case .usb(let device):
            if let serial = device.serialNumber { addSerialNumber(serial) }
        case .bluetooth, .ble, .virtual:
            break
        }
    }

    public mutating func addEndpoint(_ endpoint: Endpoint) {
        guard !endpoint.host.isEmpty, !endpoints.contains(endpoint) else { return }
        endpoints.append(endpoint)
    }

    public mutating func addQueueName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !queueNames.contains(where: { DiscoveryFilter.sameQueueName($0, trimmed) }) else { return }
        queueNames.append(trimmed)
    }

    public mutating func addSerialNumber(_ serial: String) {
        guard let key = DiscoveryFilter.serialKey(serial), !serialNumbers.contains(key) else { return }
        serialNumbers.append(key)
    }

    public mutating func addMACAddress(_ address: String) {
        guard let key = DiscoveryRegistry.macKey(address), !macAddresses.contains(key) else { return }
        macAddresses.append(key)
    }

    /// Übernimmt das Ziel einer Geräte-URI: Netzwerkadresse des Geräts selbst (`socket://` mit Port,
    /// IPP-Endpunkt bzw. LPD-Standardwarteschlange für jeden Port; `QueueAdoption.deviceEndpoint`),
    /// Bonjour-Name (`dnssd://`) bzw. USB-Seriennummer (`usb://…?serial=`). Druckserver-Ziele
    /// (`ipp://server/printers/X`, `lpd://ps/PORT2`) tragen keine Adresse bei.
    public mutating func addDeviceURI(_ uri: String) {
        let keys = DiscoveryFilter.keys(ofDeviceURI: uri)
        for endpoint in keys.endpoints { addEndpoint(endpoint) }
        if let server = DiscoveryFilter.printServerTarget(ofDeviceURI: uri) {
            if !printServerHosts.contains(server.host) { printServerHosts.append(server.host) }
            if server.isNamedLPDQueue { usesPrintServerPort = true }
        }
        if let serviceName = keys.serviceName,
           !serviceNames.contains(where: { $0.caseInsensitiveCompare(serviceName) == .orderedSame }) {
            serviceNames.append(serviceName)
        }
        if let serial = keys.serialNumber { addSerialNumber(serial) }
    }
}

// MARK: - Filter der Suchergebnisse

/// Gemeinsame Regeln, welche Suchtreffer LabelWerk anzeigt: **nur** sicher als Zebra erkannte Drucker
/// (``isIdentifiedZebra(_:)``) und **nie** Drucker, die schon eingerichtet sind
/// (``isAlreadyAdded(_:among:resolved:)``). Gilt für „Drucker suchen“, Radar, Seitenleiste
/// „Im Netzwerk“, den Installationsassistenten und `lwctl discover`.
public enum DiscoveryFilter {
    /// Aufteilung von Suchtreffern.
    public struct Partition: Equatable, Sendable {
        /// Als Zebra erkannte, noch nicht eingerichtete Drucker – das, was angezeigt wird.
        public var new: [DiscoveredPrinter] = []
        /// Als Zebra erkannte Drucker, die schon in LabelWerk eingerichtet sind (ausgeblendet).
        public var alreadyAdded: [DiscoveredPrinter] = []
        /// Geräte, die sich nicht als Zebra-Drucker zu erkennen gaben (ausgeblendet).
        public var unidentified: [DiscoveredPrinter] = []
        /// Je ausgeblendetem Treffer (`alreadyAdded`, nach `DiscoveredPrinter.id`) der Index des
        /// eingerichteten Druckers, der dasselbe Gerät ist.
        public var addedIdentityIndexByID: [String: Int] = [:]

        public init(new: [DiscoveredPrinter] = [], alreadyAdded: [DiscoveredPrinter] = [],
                    unidentified: [DiscoveredPrinter] = [], addedIdentityIndexByID: [String: Int] = [:]) {
            self.new = new
            self.alreadyAdded = alreadyAdded
            self.unidentified = unidentified
            self.addedIdentityIndexByID = addedIdentityIndexByID
        }

        /// Eingerichtete Drucker (Indizes der Identitäten), die in den Treffern wieder auftauchten.
        /// Ein Drucker erscheint oft mehrfach – LabelWerk-Warteschlange, Warteschlangen der
        /// Etikettentypen, übernommene Warteschlange, Netzwerk-Fund –, zählt hier aber einmal.
        public var addedIdentityIndices: Set<Int> { Set(addedIdentityIndexByID.values) }

        /// Anzahl der ausgeblendeten, schon eingerichteten **Drucker** (nicht Treffer) – für
        /// „N bereits hinzugefügt“. `excluding`: Treffer, deren Drucker nicht mitzählt (z. B. der im
        /// Assistenten gewählte, der sichtbar bleibt).
        public func hiddenAddedPrinterCount(excluding printerID: String? = nil) -> Int {
            var indices = addedIdentityIndices
            if let printerID, let index = addedIdentityIndexByID[printerID] { indices.remove(index) }
            return indices.count
        }
    }

    /// Teilt Suchtreffer auf (Reihenfolge bleibt erhalten).
    public static func partition(_ printers: [DiscoveredPrinter], identities: [AddedPrinterIdentity],
                                 resolved: [String: String] = [:]) -> Partition {
        var result = Partition()
        for printer in printers {
            if !isIdentifiedZebra(printer) {
                result.unidentified.append(printer)
            } else if let index = matchingIdentityIndex(for: printer, among: identities, resolved: resolved) {
                result.alreadyAdded.append(printer)
                result.addedIdentityIndexByID[printer.id] = index
            } else {
                result.new.append(printer)
            }
        }
        return result
    }

    // MARK: Zebra erkannt?

    /// `true`, wenn der Fund **positiv** als Zebra-Drucker erkannt ist:
    ///
    /// * Antwort auf die Zebra-Suche (UDP 4201) oder `~HI` (`identifiedBy` mit `zebra` bzw. `hi`);
    /// * Netzwerk-Scan: SNMP-`sysDescr` bzw. Modellhinweis nennt Zebra/ZTC oder ein Katalogmodell;
    /// * Bonjour und Bluetooth LE: Die Suche meldet ohnehin nur Dienste mit Zebra-Kennung (TXT-Einträge,
    ///   Name, Zebra-Dienst-UUID);
    /// * USB: Zebra-Hersteller-ID 0x0A5F;
    /// * macOS-Warteschlange: Treiber, Geräte-URI oder Name deuten auf Zebra (`CUPSQueueInfo.looksLikeZebra`);
    /// * Bluetooth: Zebra-Name, Zebra-Seriennummer als Name oder Adressblock mobiler Zebra-Drucker.
    ///
    /// Geräte mit nur offenem Port 9100 (kein SNMP, fremde Marke) gelten nicht als erkannt.
    public static func isIdentifiedZebra(_ printer: DiscoveredPrinter) -> Bool {
        let methods = Set((printer.details["identifiedBy"] ?? "").lowercased().split(separator: "+").map(String.init))
        if printer.source == .zebra || methods.contains("zebra") || methods.contains("hi") { return true }
        if case .usb(let device) = printer.descriptor { return device.vendorID == ZebraIdentifiers.usbVendorID }
        if case .virtual = printer.descriptor { return false }
        switch printer.source {
        case .zebra, .bonjour, .ble:
            return true
        case .usb:
            return hexValue(printer.details["vendorID"]) == ZebraIdentifiers.usbVendorID
        case .network:
            let texts = [printer.details["sysDescr"], printer.modelHint, printer.details["productName"]]
            return texts.contains { $0.map(ZebraIdentifiers.looksLikeZebra) ?? false }
        case .cups:
            return queueInfo(of: printer).looksLikeZebra
        case .bluetooth:
            let texts = [printer.name, printer.modelHint, printer.details["name"]]
            if texts.contains(where: { $0.map(ZebraIdentifiers.looksLikeZebra) ?? false }) { return true }
            if texts.contains(where: { $0.map(ZebraIdentifiers.looksLikeZebraSerialNumber) ?? false }) { return true }
            if case .bluetooth(let address, _) = printer.descriptor { return ZebraIdentifiers.isZebraBluetoothAddress(address) }
            return false
        }
    }

    // MARK: Schon eingerichtet?

    /// `true`, wenn der Fund dasselbe Gerät ist wie einer der eingerichteten Drucker.
    public static func isAlreadyAdded(_ printer: DiscoveredPrinter, among identities: [AddedPrinterIdentity],
                                      resolved: [String: String] = [:]) -> Bool {
        matchingIdentityIndex(for: printer, among: identities, resolved: resolved) != nil
    }

    /// Index des eingerichteten Druckers, der dasselbe Gerät ist wie `printer` (sonst `nil`).
    ///
    /// Dasselbe Gerät ist es bei (in dieser Reihenfolge):
    /// 1. derselben Verbindung (`ConnectionDescriptor.stableID`);
    /// 2. einer seiner macOS-Warteschlangen (eigene, übernommene, Etikettentypen; ohne Beachtung der
    ///    Groß-/Kleinschreibung);
    /// 3. derselben Seriennummer des Druckers bzw. 4. derselben MAC-Adresse;
    /// 5. demselben Bonjour-Dienstnamen (`dnssd://`-Warteschlange);
    /// 6. derselben Netzwerkadresse – auch über aufgelöste Hostnamen (`resolved`: ``DiscoveryNetworks/hostKey(_:)``
    ///    → IPv4-Adresse) und die Ziele seiner Warteschlangen, soweit sie das Gerät selbst nennen
    ///    (`QueueAdoption.deviceEndpoint`; nicht `ipp://server/printers/X` oder `lpd://ps/PORT2`). Ports
    ///    müssen passen: gleich, einer unbekannt (IPP-Endpunkt bzw. LPD-Standardwarteschlange des Geräts,
    ///    gemeldete IP-Adresse) oder 9100/6101 (beide Rohdatenports desselben Zebra-Druckers). 9100 und
    ///    9101 sind verschiedene Anschlüsse eines Druckservers;
    /// 7. USB: gleiches Produkt und gleicher Anschluss, wenn eine Seite keine Seriennummer kennt.
    public static func matchingIdentityIndex(for printer: DiscoveredPrinter, among identities: [AddedPrinterIdentity],
                                             resolved: [String: String] = [:]) -> Int? {
        guard !identities.isEmpty else { return nil }
        let keys = foundKeys(of: printer)
        for (index, identity) in identities.enumerated() where matches(keys, identity, resolved: resolved) {
            return index
        }
        return nil
    }

    // MARK: Hilfen (öffentlich)

    /// Suchtreffer einer macOS-Warteschlange (wie die Quelle „macOS-Warteschlangen“ ihn meldet).
    public static func discoveredPrinter(for queue: CUPSQueueInfo) -> DiscoveredPrinter {
        var details = ["deviceURI": queue.deviceURI, "isDefault": queue.isDefault ? "true" : "false"]
        if let makeAndModel = queue.makeAndModel { details["makeAndModel"] = makeAndModel }
        return DiscoveredPrinter(
            name: queue.name,
            modelHint: queue.modelHint,
            descriptor: .cupsQueue(name: queue.name),
            source: .cups,
            details: details
        )
    }

    /// CUPS-Warteschlangennamen sind unabhängig von Groß-/Kleinschreibung.
    public static func sameQueueName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// `true`, wenn zwei Ports zum selben Gerät passen (siehe ``matchingIdentityIndex(for:among:resolved:)``).
    public static func portsMatch(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return true }
        if lhs == rhs { return true }
        let zebraPorts: Set<Int> = [ZebraIdentifiers.rawPort, ZebraIdentifiers.alternateRawPort]
        return zebraPorts.contains(lhs) && zebraPorts.contains(rhs)
    }

    // MARK: Intern

    /// Merkmale eines Suchtreffers.
    struct FoundKeys {
        var stableID: String
        var queueName: String?
        var endpoints: [AddedPrinterIdentity.Endpoint] = []
        var serialNumbers: [String] = []
        var macAddress: String?
        var serviceNames: [String] = []
        var usbDevice: USBDeviceIdentifier?
    }

    static func foundKeys(of printer: DiscoveredPrinter) -> FoundKeys {
        var keys = FoundKeys(stableID: printer.descriptor.stableID)
        func addEndpoint(_ endpoint: AddedPrinterIdentity.Endpoint) {
            if !endpoint.host.isEmpty, !keys.endpoints.contains(endpoint) { keys.endpoints.append(endpoint) }
        }
        func addSerial(_ text: String?) {
            if let key = text.flatMap(serialKey), !keys.serialNumbers.contains(key) { keys.serialNumbers.append(key) }
        }
        func addServiceName(_ text: String?) {
            guard let name = text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !keys.serviceNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            keys.serviceNames.append(name)
        }
        switch printer.descriptor {
        case .tcp(let host, let port):
            addEndpoint(AddedPrinterIdentity.Endpoint(host: host, port: port))
        case .cupsQueue(let name):
            keys.queueName = name
        case .usb(let device):
            keys.usbDevice = device
            addSerial(device.serialNumber)
        case .bluetooth, .ble, .virtual:
            break
        }
        if let host = printer.details["host"], !host.isEmpty {
            addEndpoint(AddedPrinterIdentity.Endpoint(host: host, port: printer.details["port"].flatMap { Int($0) }))
        }
        if let uri = printer.details["deviceURI"] {
            let uriKeys = Self.keys(ofDeviceURI: uri)
            for endpoint in uriKeys.endpoints { addEndpoint(endpoint) }
            addServiceName(uriKeys.serviceName)
            addSerial(uriKeys.serialNumber)
        }
        addSerial(printer.details["serialNumber"])
        keys.macAddress = DiscoveryRegistry.macKey(printer.details["macAddress"])
        if printer.source == .bonjour || printer.details["serviceType"] != nil {
            addServiceName(printer.details["serviceName"])
        }
        return keys
    }

    static func matches(_ keys: FoundKeys, _ identity: AddedPrinterIdentity, resolved: [String: String]) -> Bool {
        if identity.descriptors.contains(where: { $0.stableID == keys.stableID }) { return true }
        if let queue = keys.queueName, identity.queueNames.contains(where: { sameQueueName($0, queue) }) { return true }
        if keys.serialNumbers.contains(where: identity.serialNumbers.contains) { return true }
        if let mac = keys.macAddress, identity.macAddresses.contains(mac) { return true }
        if keys.serviceNames.contains(where: { name in
            identity.serviceNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }) { return true }
        for found in keys.endpoints {
            let foundHosts = expanded(found.host, resolved: resolved)
            for known in identity.endpoints where portsMatch(found.port, known.port) {
                if !foundHosts.isDisjoint(with: expanded(known.host, resolved: resolved)) { return true }
            }
        }
        if let device = keys.usbDevice {
            for case .usb(let known) in identity.descriptors where sameUSBDevice(device, known) { return true }
        }
        return false
    }

    /// Ein Host und – bei Hostnamen – seine aufgelöste Adresse.
    static func expanded(_ host: String, resolved: [String: String]) -> Set<String> {
        let key = DiscoveryNetworks.hostKey(host)
        guard !key.isEmpty else { return [] }
        var result: Set<String> = [key]
        if let address = resolved[key] { result.insert(DiscoveryNetworks.hostKey(address)) }
        return result
    }

    /// USB ohne gemeinsame Seriennummer: gleiches Produkt am gleichen Anschluss.
    static func sameUSBDevice(_ lhs: USBDeviceIdentifier, _ rhs: USBDeviceIdentifier) -> Bool {
        guard lhs.vendorID == rhs.vendorID,
              lhs.productID == rhs.productID || lhs.productID == 0 || rhs.productID == 0 else { return false }
        let leftSerial = lhs.serialNumber.flatMap(serialKey)
        let rightSerial = rhs.serialNumber.flatMap(serialKey)
        if let leftSerial, let rightSerial { return leftSerial == rightSerial }
        guard let left = lhs.locationID, let right = rhs.locationID else { return false }
        return left == right
    }

    /// Merkmale einer Geräte-URI.
    static func keys(ofDeviceURI uri: String) -> (endpoints: [AddedPrinterIdentity.Endpoint], serviceName: String?,
                                                   serialNumber: String?) {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return ([], nil, nil) }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        switch scheme {
        case "dnssd", "mdns":
            return ([], CUPSQueueLister.modelHint(fromDeviceURI: trimmed), nil)
        case "usb":
            return ([], nil, queryValue("serial", in: trimmed))
        default:
            // Nur URIs, die das Gerät selbst nennen: Die Freigabe eines Druckservers
            // (`ipp://server/printers/X`) bzw. eine benannte LPD-Warteschlange (`lpd://ps/PORT2`, evtl.
            // ein Anschluss eines Druckservers mit mehreren Anschlüssen) hieße sonst „jeder Port dieses
            // Hosts“ – und ein anderer Drucker am selben Druckserver gälte als eingerichtet.
            guard let endpoint = QueueAdoption.deviceEndpoint(ofDeviceURI: trimmed) else { return ([], nil, nil) }
            // Nur `socket://` nennt den Rohdatenport; IPP/LPD erreichen dasselbe Gerät über andere Ports.
            let port = endpoint.scheme == "socket" ? (endpoint.port ?? ZebraIdentifiers.rawPort) : nil
            return ([AddedPrinterIdentity.Endpoint(host: endpoint.host, port: port)], nil, nil)
        }
    }

    /// Host einer Netzwerk-URI, die **nicht** das Gerät selbst nennt (Druckserver-Freigabe, benannte
    /// LPD-Warteschlange), sonst `nil`.
    static func printServerTarget(ofDeviceURI uri: String) -> (host: String, isNamedLPDQueue: Bool)? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QueueAdoption.deviceEndpoint(ofDeviceURI: trimmed) == nil,
              let endpoint = QueueAdoption.endpoint(ofDeviceURI: trimmed),
              QueueAdoption.networkSchemes.contains(endpoint.scheme),
              !QueueAdoption.isLoopbackHost(endpoint.host) else { return nil }
        let host = DiscoveryNetworks.hostKey(endpoint.host)
        guard !host.isEmpty else { return nil }
        return (host, endpoint.scheme == "lpd")
    }

    /// Wert eines Abfrageparameters (`?serial=…&…`), prozentdekodiert.
    static func queryValue(_ name: String, in uri: String) -> String? {
        guard let question = uri.firstIndex(of: "?") else { return nil }
        var query = uri[uri.index(after: question)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == name.lowercased() else { continue }
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Seriennummer in Vergleichsform (Großbuchstaben, ohne Leerraum) oder `nil`.
    static func serialKey(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value.isEmpty ? nil : value
    }

    static func hexValue(_ text: String?) -> Int? {
        guard var value = text?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        if value.hasPrefix("0x") { value.removeFirst(2) }
        return Int(value, radix: 16)
    }

    static func queueInfo(of printer: DiscoveredPrinter) -> CUPSQueueInfo {
        let name: String
        if case .cupsQueue(let queueName) = printer.descriptor { name = queueName } else { name = printer.name }
        return CUPSQueueInfo(
            name: name,
            deviceURI: printer.details["deviceURI"] ?? "",
            isDefault: printer.details["isDefault"] == "true",
            makeAndModel: printer.details["makeAndModel"]
        )
    }
}

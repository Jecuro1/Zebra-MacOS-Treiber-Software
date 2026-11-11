import Foundation
import Testing
@testable import LabelWerkTransport

// MARK: - Testdaten

private enum Found {
    static func zebra(_ host: String, port: Int = 9100, mac: String? = nil, serial: String? = nil) -> DiscoveredPrinter {
        var details = ["host": host, "port": String(port), "identifiedBy": "zebra"]
        if let mac { details["macAddress"] = mac }
        if let serial { details["serialNumber"] = serial }
        return DiscoveredPrinter(name: "Zebra ZD421", modelHint: "ZTC ZD421-203dpi ZPL",
                                 descriptor: .tcp(host: host, port: port), source: .zebra, details: details)
    }

    static func queue(_ name: String, uri: String, makeAndModel: String? = "Zebra ZD421-203dpi") -> DiscoveredPrinter {
        DiscoveryFilter.discoveredPrinter(for: CUPSQueueInfo(name: name, deviceURI: uri, isDefault: false,
                                                             makeAndModel: makeAndModel))
    }

    static func bonjour(_ serviceName: String, host: String, port: Int = 9100) -> DiscoveredPrinter {
        DiscoveredPrinter(name: serviceName, modelHint: "ZD421",
                          descriptor: .tcp(host: host, port: port), source: .bonjour,
                          details: ["serviceName": serviceName, "serviceType": "_pdl-datastream._tcp",
                                    "host": host, "port": String(port)])
    }

    static func network(_ host: String, port: Int = 9100, details extra: [String: String] = [:],
                        modelHint: String? = nil) -> DiscoveredPrinter {
        var details = ["host": host, "port": String(port)]
        details.merge(extra) { $1 }
        return DiscoveredPrinter(name: host, modelHint: modelHint, descriptor: .tcp(host: host, port: port),
                                 source: .network, details: details)
    }

    static func usb(productID: Int = 0x0081, serial: String? = nil, location: UInt32? = nil,
                    vendorID: Int = ZebraIdentifiers.usbVendorID) -> DiscoveredPrinter {
        let device = USBDeviceIdentifier(vendorID: vendorID, productID: productID, serialNumber: serial,
                                         locationID: location, productName: "ZTC ZD421-203dpi ZPL")
        var details = ["vendorID": String(format: "0x%04lX", vendorID)]
        if let serial { details["serialNumber"] = serial }
        return DiscoveredPrinter(name: "Zebra ZD421", modelHint: "ZTC ZD421-203dpi ZPL",
                                 descriptor: .usb(device), source: .usb, details: details)
    }

    static func bluetooth(_ address: String, name: String?) -> DiscoveredPrinter {
        DiscoveredPrinter(name: name ?? address, modelHint: name,
                          descriptor: .bluetooth(address: address, name: name), source: .bluetooth,
                          details: name.map { ["address": address, "name": $0] } ?? ["address": address])
    }
}

// MARK: - Schon eingerichtet?

@Suite("DiscoveryFilter – bereits hinzugefügte Drucker")
struct DiscoveryFilterAddedTests {
    @Test("Gleiche IP über eine andere Quelle: Zebra-Suche, Bonjour, Netzwerk-Scan, macOS-Warteschlange")
    func sameAddressDifferentSource() {
        let added = [AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.19", port: 9100))]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.62.13.19"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.bonjour("Zebra ZD421 Lager", host: "10.62.13.19"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(
            Found.network("10.62.13.19", details: ["identifiedBy": "snmp", "sysDescr": "Zebra Technologies ZTC ZD421"]),
            among: added))
        // Der Fall aus dem Bildschirmfoto: die macOS-Warteschlange „10.62.13.19“ desselben Druckers.
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("10.62.13.19", uri: "socket://10.62.13.19"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("Etiketten", uri: "ipp://10.62.13.19/ipp/print"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("Etiketten", uri: "lpd://10.62.13.19/"), among: added))
        // Eine benannte LPD-Warteschlange kann ein anderer Anschluss eines Druckservers sein.
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.queue("Etiketten", uri: "lpd://10.62.13.19/queue"), among: added))
        // Groß-/Kleinschreibung und eckige Klammern spielen keine Rolle.
        let ipv6 = [AddedPrinterIdentity(descriptor: .tcp(host: "[FE80::1]", port: 9100))]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("fe80::1"), among: ipv6))
    }

    @Test("Nur als macOS-Warteschlange eingerichtet: Zebra-Suche findet dieselbe Adresse")
    func addedAsQueueFoundByAddress() {
        let queues = [CUPSQueueInfo(name: "10.62.13.19", deviceURI: "socket://10.62.13.19:9100", isDefault: true,
                                    makeAndModel: "LabelWerk ZD421 203dpi")]
        let added = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "10.62.13.19"), queues: queues)]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.62.13.19"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("10.62.13.19", uri: "socket://10.62.13.19:9100"), among: added))
        // Ohne die Warteschlangenliste ist die Adresse unbekannt – der Name bleibt der Treffer.
        let nameOnly = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "10.62.13.19"))]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.62.13.19"), among: nameOnly))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("10.62.13.19", uri: "socket://10.62.13.19"), among: nameOnly))
    }

    @Test("Hostname und aufgelöste IP-Adresse")
    func hostnameVersusResolvedAddress() {
        let byName = [AddedPrinterIdentity(descriptor: .tcp(host: "Zebra-Lager.firma.local.", port: 9100))]
        let resolved = ["zebra-lager.firma.local": "10.62.13.19"]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.62.13.19"), among: byName, resolved: resolved))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.62.13.19"), among: byName))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("zebra-lager.firma.local"), among: byName))

        // Umgekehrt: eingerichtet per IP, gefunden als Warteschlange mit Hostnamen.
        let byAddress = [AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.19", port: 9100))]
        let found = Found.queue("Lager", uri: "socket://zebra-lager.firma.local:9100")
        #expect(DiscoveryFilter.isAlreadyAdded(found, among: byAddress, resolved: resolved))
        #expect(!DiscoveryFilter.isAlreadyAdded(found, among: byAddress))

        // Die vom Drucker gemeldete IP-Adresse (~HI/SGD) gilt für jeden Port.
        let reported = [AddedPrinterIdentity(descriptor: .tcp(host: "zebra-lager.firma.local", port: 9100),
                                             ipAddress: "10.62.13.19")]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.62.13.19"), among: reported))
    }

    @Test("Seriennummer und MAC-Adresse (z. B. neue IP-Adresse per DHCP)")
    func serialAndMAC() {
        let added = [AddedPrinterIdentity(descriptor: .tcp(host: "10.0.0.5", port: 9100),
                                          serialNumber: " d2j123456789 ", macAddress: "00:07:4d:12:34:56")]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.77", mac: "00074D123456"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.78", serial: "D2J123456789"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.usb(serial: "D2J123456789"), among: added))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.79", mac: "00:07:4D:99:99:99", serial: "OTHER"),
                                                among: added))
        // Ungültige MAC-Adressen (nur Nullen) verbinden nichts.
        let zeroMAC = [AddedPrinterIdentity(descriptor: .tcp(host: "10.0.0.5", port: 9100), macAddress: "00:00:00:00:00:00")]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.80", mac: "000000000000"), among: zeroMAC))
        // Die Seriennummer des Druckservers wird nicht mit der des Druckers verglichen.
        var printServer = Found.zebra("10.0.0.81")
        printServer.details["printServerSerial"] = "D2J123456789"
        #expect(!DiscoveryFilter.isAlreadyAdded(printServer, among: added))
    }

    @Test("Übernommene Warteschlangen und Warteschlangen der Etikettentypen sind nie „neu“")
    func adoptedAndLabelTypeQueues() {
        let queues = [
            CUPSQueueInfo(name: "ZD421_Lager", deviceURI: "socket://10.62.13.19:9100", isDefault: false,
                          makeAndModel: "LabelWerk ZD421 203dpi"),
            CUPSQueueInfo(name: "ZD421_Lager_Versand", deviceURI: "socket://10.62.13.19:9100", isDefault: false,
                          makeAndModel: "LabelWerk ZD421 203dpi"),
            CUPSQueueInfo(name: "Zebra_Alt", deviceURI: "dnssd://Zebra%20ZD421%20Lager._pdl-datastream._tcp.local./?uuid=1",
                          isDefault: false, makeAndModel: "LabelWerk ZD421 203dpi"),
        ]
        let added = [AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.19", port: 9100),
                                          queueNames: ["ZD421_Lager", "Zebra_Alt", "ZD421_Lager_Versand"],
                                          queues: queues)]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("ZD421_Lager", uri: "socket://10.62.13.19:9100"), among: added))
        // Name ohne Rücksicht auf Groß-/Kleinschreibung, auch wenn die URI keine Adresse nennt.
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("zd421_lager_versand", uri: "file:///dev/null"), among: added))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("Zebra_Alt", uri: "dnssd://x._ipp._tcp.local./"), among: added))
        // Bonjour-Name der übernommenen dnssd-Warteschlange: derselbe Drucker unter anderer Adresse.
        #expect(DiscoveryFilter.isAlreadyAdded(Found.bonjour("Zebra ZD421 Lager", host: "192.168.7.20"), among: added))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.bonjour("Zebra ZD421 Versand", host: "192.168.7.21"), among: added))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.queue("ZD421_Buero", uri: "socket://10.62.13.40"), among: added))
    }

    @Test("Ports: gleich, unbekannt oder 9100/6101 – aber nicht zwei Anschlüsse eines Druckservers")
    func ports() {
        let rawPort = [AddedPrinterIdentity(descriptor: .tcp(host: "10.0.0.5", port: 9100))]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.5", port: 6101), among: rawPort))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.network("10.0.0.5", port: 9101, details: ["identifiedBy": "hi"]),
                                                among: rawPort))
        let serverPort = [AddedPrinterIdentity(descriptor: .tcp(host: "10.0.0.6", port: 9101))]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.network("10.0.0.6", port: 9102, details: ["identifiedBy": "hi"]),
                                                among: serverPort))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.6", port: 9100), among: serverPort))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("Server2", uri: "socket://10.0.0.6:9101"), among: serverPort))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.queue("Server3", uri: "socket://10.0.0.6:9102"), among: serverPort))
        // IPP-/LPD-Warteschlangen nennen keinen Rohdatenport: jeder Port passt.
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("IPP", uri: "ipp://10.0.0.6:631/ipp/print"), among: serverPort))
        #expect(DiscoveryFilter.portsMatch(nil, 9100))
        #expect(DiscoveryFilter.portsMatch(9100, 6101))
        #expect(!DiscoveryFilter.portsMatch(9100, 9101))
    }

    @Test("Druckserver: benannte LPD-Warteschlange und Freigabe gelten nicht für jeden Port des Hosts")
    func printServerTargets() {
        // Eingerichtet über Anschluss 2 eines Druckservers (lpd://ps/PORT2): Der Drucker an Anschluss 1
        // (9100) ist ein anderer Drucker – auch wenn der Druckserver seine IP-Adresse meldet.
        let portQueue = [CUPSQueueInfo(name: "Lager", deviceURI: "lpd://10.0.0.6/PORT2", isDefault: false,
                                       makeAndModel: "LabelWerk ZD421 203dpi")]
        let viaPort2 = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "Lager"), ipAddress: "10.0.0.6",
                                             queues: portQueue)]
        #expect(viaPort2[0].endpoints.isEmpty)
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.6", port: 9100), among: viaPort2))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.queue("Lager2", uri: "lpd://10.0.0.6/PORT1"), among: viaPort2))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.queue("lager", uri: "lpd://10.0.0.6/PORT2"), among: viaPort2))

        // Freigabe eines CUPS-Servers: Der Server ist nicht der Drucker.
        let shareQueue = [CUPSQueueInfo(name: "Z", deviceURI: "ipp://cupsserver/printers/Z", isDefault: false,
                                        makeAndModel: "Zebra ZD421-203dpi")]
        let viaShare = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "Z"), queues: shareQueue)]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("cupsserver", port: 9100), among: viaShare))
        // Die vom Drucker gemeldete eigene IP-Adresse (nicht die des Servers) gilt weiter für jeden Port.
        let shareWithIP = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "Z"), ipAddress: "10.0.0.9",
                                                queues: shareQueue)]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.9"), among: shareWithIP))
        let serverReported = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "Z"), ipAddress: "CUPSServer",
                                                   queues: shareQueue)]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("cupsserver"), among: serverReported))

        // Verbindung über Anschluss 9101 eines Druckservers: Dessen gemeldete IP-Adresse gilt nur für 9101.
        let serverPort = [AddedPrinterIdentity(descriptor: .tcp(host: "ps.firma.local", port: 9101), ipAddress: "10.0.0.6")]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.6", port: 9100), among: serverPort))
        #expect(DiscoveryFilter.isAlreadyAdded(Found.network("10.0.0.6", port: 9101, details: ["identifiedBy": "hi"]),
                                               among: serverPort))
        // Am Rohdatenport 9100 bleibt die gemeldete Adresse ein Platzhalter für jeden Port.
        let rawPort = [AddedPrinterIdentity(descriptor: .tcp(host: "zebra.firma.local", port: 9100), ipAddress: "10.0.0.7")]
        #expect(rawPort[0].endpoints.contains(AddedPrinterIdentity.Endpoint(host: "10.0.0.7")))
    }

    @Test("Fremde Drucker bleiben neu; Index des passenden Druckers")
    func unrelatedPrinter() {
        let added = [
            AddedPrinterIdentity(descriptor: .tcp(host: "10.0.0.5", port: 9100), serialNumber: "AAA", macAddress: "00074D000001"),
            AddedPrinterIdentity(descriptor: .bluetooth(address: "AC:3F:A4:12:34:56", name: "ZQ520")),
            AddedPrinterIdentity(descriptor: .tcp(host: "10.0.0.7", port: 9100)),
        ]
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.50", mac: "00074D000002", serial: "BBB"), among: added))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.zebra("10.0.0.5"), among: []))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.queue("10.0.0.55", uri: "socket://10.0.0.55"), among: added))
        #expect(DiscoveryFilter.matchingIdentityIndex(for: Found.zebra("10.0.0.7"), among: added) == 2)
        #expect(DiscoveryFilter.matchingIdentityIndex(for: Found.bluetooth("ac-3f-a4-12-34-56", name: "XXQLJ120900310"),
                                                      among: added) == 1)
    }

    @Test("USB: Seriennummer, Anschluss ohne Seriennummer, Seriennummer der usb://-Warteschlange")
    func usb() {
        let byLocation = [AddedPrinterIdentity(descriptor: .usb(USBDeviceIdentifier(productID: 0x0081, locationID: 0x1410_0000)))]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.usb(location: 0x1410_0000), among: byLocation))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.usb(location: 0x1420_0000), among: byLocation))
        // Mit Seriennummer zählt die Seriennummer, nicht der Anschluss.
        let bySerial = [AddedPrinterIdentity(descriptor: .usb(USBDeviceIdentifier(productID: 0x0081, serialNumber: "D2J1",
                                                                                   locationID: 0x1410_0000)))]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.usb(serial: "D2J1", location: 0x1430_0000), among: bySerial))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.usb(serial: "D2J2", location: 0x1410_0000), among: bySerial))
        // Eingerichtet als macOS-Warteschlange mit USB-URI.
        let queues = [CUPSQueueInfo(name: "ZD421_USB", deviceURI: "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D2J9%201",
                                    isDefault: false)]
        let viaQueue = [AddedPrinterIdentity(descriptor: .cupsQueue(name: "ZD421_USB"), queues: queues)]
        #expect(DiscoveryFilter.isAlreadyAdded(Found.usb(serial: "D2J9 1"), among: viaQueue))
        #expect(!DiscoveryFilter.isAlreadyAdded(Found.usb(serial: "D2J9 2"), among: viaQueue))
    }

    @Test("Aufteilung: neu, schon eingerichtet, nicht erkannt")
    func partition() {
        let added = [AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.19", port: 9100))]
        let printers = [
            Found.zebra("10.62.13.20"),
            Found.queue("10.62.13.19", uri: "socket://10.62.13.19"),
            Found.network("10.62.13.30"),
            Found.zebra("10.62.13.21"),
        ]
        let partition = DiscoveryFilter.partition(printers, identities: added)
        #expect(partition.new.map(\.id) == [printers[0].id, printers[3].id])
        #expect(partition.alreadyAdded.map(\.id) == [printers[1].id])
        #expect(partition.unidentified.map(\.id) == [printers[2].id])
        #expect(partition.addedIdentityIndices == [0])
        #expect(partition.hiddenAddedPrinterCount() == 1)
    }

    @Test("„N bereits hinzugefügt“ zählt Drucker, nicht Treffer")
    func hiddenCountCountsPrinters() {
        let queues = [
            CUPSQueueInfo(name: "ZD421_Lager", deviceURI: "socket://10.62.13.19:9100", isDefault: false,
                          makeAndModel: "LabelWerk ZD421 203dpi"),
            CUPSQueueInfo(name: "ZD421_Lager_Versand", deviceURI: "socket://10.62.13.19:9100", isDefault: false,
                          makeAndModel: "LabelWerk ZD421 203dpi"),
        ]
        let added = [
            AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.19", port: 9100),
                                 queueNames: ["ZD421_Lager", "ZD421_Lager_Versand"], queues: queues),
            AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.40", port: 9100)),
        ]
        let printers = [
            Found.queue("ZD421_Lager", uri: "socket://10.62.13.19:9100", makeAndModel: "LabelWerk ZD421 203dpi"),
            Found.queue("ZD421_Lager_Versand", uri: "socket://10.62.13.19:9100", makeAndModel: "LabelWerk ZD421 203dpi"),
            Found.zebra("10.62.13.19"),
            Found.zebra("10.62.13.50"),
        ]
        let partition = DiscoveryFilter.partition(printers, identities: added)
        #expect(partition.alreadyAdded.count == 3)
        #expect(partition.addedIdentityIndices == [0])
        #expect(partition.hiddenAddedPrinterCount() == 1)
        #expect(partition.new.map(\.id) == [printers[3].id])
        // Der im Assistenten gewählte Drucker bleibt sichtbar und zählt nicht mit.
        #expect(partition.hiddenAddedPrinterCount(excluding: printers[2].id) == 0)
        #expect(partition.hiddenAddedPrinterCount(excluding: printers[3].id) == 1)

        // Zwei verschiedene eingerichtete Drucker: 2.
        let both = DiscoveryFilter.partition(printers + [Found.zebra("10.62.13.40")], identities: added)
        #expect(both.hiddenAddedPrinterCount() == 2)
    }
}

// MARK: - Zebra erkannt?

@Suite("DiscoveryFilter – nur Zebra-Drucker")
struct DiscoveryFilterZebraTests {
    @Test("Netzwerk-Scan: nur mit Zebra-Kennung (SNMP, ~HI, Zebra-Suche)")
    func network() {
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.network("10.0.0.9")))
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.network("10.0.0.9", details: [
            "identifiedBy": "snmp", "sysDescr": "HP ETHERNET MULTI-ENVIRONMENT", "sysName": "Zebra-Buero",
        ])))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.network("10.0.0.9", details: [
            "identifiedBy": "snmp", "sysDescr": "Zebra Technologies ZTC ZD421-203dpi ZPL",
        ], modelHint: "ZTC ZD421-203dpi ZPL")))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.network("10.0.0.9", details: ["identifiedBy": "hi"])))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.network("10.0.0.9", details: ["identifiedBy": "snmp+zebra"])))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.zebra("10.0.0.9")))
    }

    @Test("macOS-Warteschlangen: Treiber, URI oder Name nennen Zebra/LabelWerk")
    func queues() {
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.queue("Buero", uri: "socket://10.0.0.9", makeAndModel: "HP LaserJet 4250")))
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.queue("10.0.0.9", uri: "socket://10.0.0.9", makeAndModel: nil)))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.queue("Lager", uri: "socket://10.0.0.9", makeAndModel: "Zebra ZPL Label Printer")))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.queue("Lager", uri: "socket://10.0.0.9", makeAndModel: "LabelWerk ZD421 203dpi")))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.queue("Lager",
                                                              uri: "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=1",
                                                              makeAndModel: nil)))
    }

    @Test("USB, Bluetooth, Bonjour, BLE und virtuelle Geräte")
    func otherSources() {
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.usb(serial: "1")))
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.usb(serial: "1", vendorID: 0x03F0)))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.bluetooth("11:22:33:44:55:66", name: "Zebra ZQ520")))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.bluetooth("11:22:33:44:55:66", name: "XXQLJ120900310")))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.bluetooth("AC:3F:A4:01:02:03", name: "Lager mobil")))
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.bluetooth("11:22:33:44:55:66", name: "Fotodrucker")))
        #expect(!DiscoveryFilter.isIdentifiedZebra(Found.bluetooth("11:22:33:44:55:66", name: nil)))
        #expect(DiscoveryFilter.isIdentifiedZebra(Found.bonjour("Zebra ZD421", host: "10.0.0.9")))
        let ble = DiscoveredPrinter(name: "Zebra-Drucker (BLE)", descriptor: .ble(identifier: "ABC", name: nil), source: .ble)
        #expect(DiscoveryFilter.isIdentifiedZebra(ble))
        let virtual = DiscoveredPrinter(name: "Demo", descriptor: .virtual(id: "demo"), source: .network,
                                        details: ["identifiedBy": "snmp"])
        #expect(!DiscoveryFilter.isIdentifiedZebra(virtual))
    }

    @Test("Hilfen: Bluetooth-Adressblöcke und Seriennummern mobiler Zebra-Drucker")
    func identifiers() {
        #expect(ZebraIdentifiers.isZebraBluetoothAddress("ac-3f-a4-12-34-56"))
        #expect(ZebraIdentifiers.isZebraBluetoothAddress("00:07:4D:00:00:01"))
        #expect(!ZebraIdentifiers.isZebraBluetoothAddress("11:22:33:44:55:66"))
        #expect(!ZebraIdentifiers.isZebraBluetoothAddress("AC3FA4"))
        #expect(ZebraIdentifiers.looksLikeZebraSerialNumber("XXRBJ151200457"))
        #expect(!ZebraIdentifiers.looksLikeZebraSerialNumber("XX12"))
        #expect(!ZebraIdentifiers.looksLikeZebraSerialNumber("Bürodrucker"))
    }
}

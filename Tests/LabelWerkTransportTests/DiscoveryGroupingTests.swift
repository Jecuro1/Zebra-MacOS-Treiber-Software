import Foundation
import Testing
@testable import LabelWerkTransport

// MARK: - Testdaten: das Netz aus dem Bildschirmfoto (Build 71)

/// Vier ZD421 in 10.62.13.0/24; jeder meldet sich auf die Zebra-Suche (Systemname = Seriennummer, wie
/// ab Werk) und über Bluetooth LE (Name = Seriennummer). Dazu drei macOS-Warteschlangen.
private enum Lab {
    struct Printer {
        var host: String
        var serial: String
        var model: String
        var mac: String
    }

    static let printers = [
        Printer(host: "10.62.13.18", serial: "D6J250402293", model: "ZTC ZD421t-203dpi ZPL", mac: "00:07:4D:A1:00:18"),
        Printer(host: "10.62.13.19", serial: "D6J250301793", model: "ZTC ZD421t-203dpi ZPL", mac: "00:07:4D:A1:00:19"),
        Printer(host: "10.62.13.20", serial: "D6J244410828", model: "ZTC ZD421d-203dpi ZPL", mac: "00:07:4D:A1:00:20"),
        Printer(host: "10.62.13.21", serial: "D6J232205082", model: "ZTC ZD421t-203dpi ZPL", mac: "00:07:4D:A1:00:21"),
    ]

    static func udp(_ printer: Printer, systemName: String? = nil) -> DiscoveredPrinter {
        let reply = ZebraDiscoveryPacket.Reply(productName: printer.model, macAddress: printer.mac,
                                               serialNumber: printer.serial, ipAddress: printer.host,
                                               systemName: systemName ?? printer.serial)
        return ZebraDiscoveryPacket.makeDiscoveredPrinter(reply, host: printer.host)
    }

    static func ble(_ name: String, identifier: String? = nil) -> DiscoveredPrinter {
        let identifier = identifier ?? "BLE-\(name)"
        // Wie der BLE-Scanner: Name = Seriennummer, kein Modellhinweis.
        return DiscoveredPrinter(name: name, modelHint: nil, descriptor: .ble(identifier: identifier, name: name),
                          source: .ble, details: ["identifier": identifier, "rssi": "-61", "name": name])
    }

    static func queue(_ name: String, uri: String, makeAndModel: String? = "Zebra ZD421-203dpi") -> DiscoveredPrinter {
        DiscoveryFilter.discoveredPrinter(for: CUPSQueueInfo(name: name, deviceURI: uri, isDefault: false,
                                                             makeAndModel: makeAndModel))
    }

    /// Was „Drucker suchen“ in Build 71 sah: 4 × Zebra-Suche, 4 × Bluetooth LE, 3 Warteschlangen.
    static var screenshot: [DiscoveredPrinter] {
        printers.map { udp($0) } + printers.map { ble($0.serial) } + [
            queue("10.62.13.19", uri: "socket://10.62.13.19:9100"),
            queue("Zebra_ZD421t", uri: "dnssd://D6J250402293._pdl-datastream._tcp.local./?uuid=1d0e1f6a"),
            queue("Zebra_ZD421t_2", uri: "socket://10.62.13.21", makeAndModel: "LabelWerk ZD421t 203dpi"),
        ]
    }
}

// MARK: - Seriennummern

@Suite("Zebra-Seriennummern")
struct ZebraSerialNumberTests {
    @Test("Desktop- und mobile Seriennummern werden erkannt")
    func recognizesSerials() {
        for serial in ["D6J250402293", "D6J250301793", "D6J244410828", "D6J232205082", "28J154300589",
                       "52J162000000", "d6j250301793", " D6J250301793 ", "XXQLJ120900310", "XXRBJ151200457"] {
            #expect(ZebraIdentifiers.looksLikeZebraSerialNumber(serial), "\(serial)")
        }
    }

    @Test("Andere Namen sind keine Seriennummern")
    func rejectsOtherNames() {
        for text in ["XX12", "Bürodrucker", "Zebra ZD421t", "ZD421t", "10.62.13.19", "D6J259901793",
                     "D6J250001793", "D6J25030179", "D6J2503017933", "123250301793", "Lager links",
                     "ABC123451234", "MXG201012345"] {
            #expect(!ZebraIdentifiers.looksLikeZebraSerialNumber(text), "\(text)")
        }
    }

    @Test("Bluetooth-Name im Seriennummernformat gilt als Zebra und als Seriennummer")
    func bluetoothSerialName() {
        let printer = DiscoveredPrinter(name: "D6J250301793", descriptor: .bluetooth(address: "11-22-33-44-55-66", name: "D6J250301793"),
                                        source: .bluetooth, details: ["name": "D6J250301793"])
        #expect(DiscoveryFilter.isIdentifiedZebra(printer))
        #expect(DiscoveryFilter.nameSerialNumbers(of: printer) == ["D6J250301793"])
        // Ein anderes Gerät mit ähnlich gebautem Namen ist weder Zebra noch Seriennummer.
        let other = DiscoveredPrinter(name: "ABC123451234", descriptor: .bluetooth(address: "11-22-33-44-55-66", name: "ABC123451234"),
                                      source: .bluetooth, details: ["name": "ABC123451234"])
        #expect(!DiscoveryFilter.isIdentifiedZebra(other))
        #expect(DiscoveryFilter.nameSerialNumbers(of: other).isEmpty)
    }
}

// MARK: - Gruppieren

@Suite("DiscoveryFilter – ein Eintrag je Gerät")
struct DiscoveryGroupingTests {
    @Test("Bildschirmfoto: Zebra-Suche + Bluetooth LE + Warteschlangen → 4 Drucker")
    func screenshotScenario() throws {
        let overview = DiscoveryFilter.overview(Lab.screenshot, identities: [])
        #expect(overview.devices.count == 4)
        #expect(overview.macQueues.isEmpty)
        #expect(overview.added.isEmpty)
        #expect(overview.devices.map(\.address) == ["10.62.13.18", "10.62.13.19", "10.62.13.20", "10.62.13.21"])
        #expect(overview.devices.map(\.serialNumber) == Lab.printers.map(\.serial))
        #expect(overview.devices.map(\.title) == ["Zebra ZD421t", "Zebra ZD421t", "Zebra ZD421d", "Zebra ZD421t"])
        #expect(overview.devices.allSatisfy { !$0.hasCustomName })
        for device in overview.devices {
            // Hinzugefügt wird über das Netzwerk (Port 9100), nie über Bluetooth LE oder die Warteschlange.
            #expect(device.preferred.descriptor == .tcp(host: device.address ?? "", port: 9100))
            #expect(device.preferred.name == device.title)
            #expect(device.preferred.details["serialNumber"] == device.serialNumber)
            #expect(device.paths.first == .network)
            #expect(device.paths.contains(.bluetooth))
            #expect(device.members(on: .bluetooth).count == 1)
        }
        let byAddress = Dictionary(uniqueKeysWithValues: overview.devices.map { ($0.address ?? "", $0) })
        #expect(byAddress["10.62.13.18"]?.queueNames == ["Zebra_ZD421t"])      // Bonjour-Name = Seriennummer
        #expect(byAddress["10.62.13.19"]?.queueNames == ["10.62.13.19"])       // Ziel der Warteschlange
        #expect(byAddress["10.62.13.20"]?.queueNames == [])
        #expect(byAddress["10.62.13.21"]?.queueNames == ["Zebra_ZD421t_2"])
        #expect(byAddress["10.62.13.19"]?.paths == [.network, .bluetooth, .macPrinter])
        #expect(byAddress["10.62.13.20"]?.paths == [.network, .bluetooth])
        #expect(byAddress["10.62.13.19"]?.macAddress == "00:07:4D:A1:00:19")
        #expect(byAddress["10.62.13.19"]?.modelName == "ZD421t")
        // Kennung bleibt über Suchläufe gleich (Seriennummer).
        #expect(byAddress["10.62.13.19"]?.id == "device:serial:D6J250301793")
        let found = try #require(overview.device(containing: Lab.screenshot[5].id))
        #expect(found.serialNumber == "D6J250301793")
    }

    @Test("Reihenfolge der Funde spielt keine Rolle (BLE zuerst, Warteschlangen zuerst)")
    func orderIndependent() {
        let reversed = DiscoveryFilter.overview(Array(Lab.screenshot.reversed()), identities: [])
        #expect(reversed.devices.count == 4)
        #expect(reversed.devices.map(\.address) == ["10.62.13.18", "10.62.13.19", "10.62.13.20", "10.62.13.21"])
        let bleOnlyFirst = Lab.printers.map { Lab.ble($0.serial) } + Lab.printers.map { Lab.udp($0) }
        #expect(DiscoveryFilter.groupDevices(bleOnlyFirst).count == 4)
    }

    @Test("Schon eingerichteter Drucker verschwindet mit allen Wegen (auch Bluetooth LE)")
    func addedPrinterHidesAllPaths() {
        let added = [AddedPrinterIdentity(descriptor: .tcp(host: "10.62.13.19", port: 9100))]
        let overview = DiscoveryFilter.overview(Lab.screenshot, identities: added)
        #expect(overview.devices.count == 3)
        #expect(!overview.devices.contains { $0.serialNumber == "D6J250301793" })
        #expect(overview.added.count == 1)
        #expect(overview.added.first?.paths == [.network, .bluetooth, .macPrinter])
        #expect(overview.hiddenAddedPrinterCount() == 1)
    }

    @Test("Eingerichtet über die Seriennummer: Der BLE-Name genügt")
    func addedBySerialMatchesBLE() {
        let added = [AddedPrinterIdentity(descriptor: .usb(USBDeviceIdentifier(productID: 0x0185)),
                                          serialNumber: "D6J244410828")]
        #expect(DiscoveryFilter.isAlreadyAdded(Lab.ble("D6J244410828"), among: added))
        let overview = DiscoveryFilter.overview([Lab.ble("D6J244410828")], identities: added)
        #expect(overview.devices.isEmpty)
        #expect(overview.added.count == 1)
    }

    @Test("Warteschlange ohne gefundenes Gerät: eigene Gruppe „Vorhandene macOS-Drucker“")
    func unmatchedQueue() {
        let printers = Lab.screenshot + [
            Lab.queue("Zebra_GK420d", uri: "socket://192.168.7.40:9100", makeAndModel: "Zebra GK420d"),
            Lab.queue("Zebra_GK420d_Kopie", uri: "socket://192.168.7.40", makeAndModel: "Zebra GK420d"),
            Lab.queue("Buero", uri: "ipp://192.168.7.50/ipp/print", makeAndModel: "HP LaserJet"),
        ]
        let overview = DiscoveryFilter.overview(printers, identities: [])
        #expect(overview.devices.count == 4)
        #expect(overview.macQueues.count == 1)
        let queue = overview.macQueues.first
        #expect(queue?.queueNames == ["Zebra_GK420d", "Zebra_GK420d_Kopie"])
        #expect(queue?.isMacQueueOnly == true)
        #expect(queue?.title == "Zebra GK420d")
        #expect(queue?.address == "192.168.7.40")
        #expect(overview.partition.unidentified.map(\.name) == ["Buero"])
    }

    @Test("Hostname einer Warteschlange über die aufgelöste Adresse")
    func resolvedHostname() {
        let printers = [Lab.udp(Lab.printers[2]),
                        Lab.queue("Lager", uri: "socket://zebra-lager.firma.local:9100")]
        #expect(DiscoveryFilter.groupDevices(printers).count == 2)
        let devices = DiscoveryFilter.groupDevices(printers, resolved: ["zebra-lager.firma.local": "10.62.13.20"])
        #expect(devices.count == 1)
        #expect(devices.first?.queueNames == ["Lager"])
        #expect(devices.first?.address == "10.62.13.20")
    }

    @Test("Netzwerk-Scan, Bonjour und Zebra-Suche derselben Adresse; eigener Name als Titel")
    func customNameAndNetworkSources() {
        let udp = Lab.udp(Lab.printers[1], systemName: "Versand links")
        let sweep = DiscoveredPrinter(name: "Zebra ZD421", modelHint: "ZD421-203dpi", descriptor: .tcp(host: "10.62.13.19", port: 9100),
                                      source: .network, details: ["host": "10.62.13.19", "port": "9100", "identifiedBy": "hi"])
        let bonjour = DiscoveredPrinter(name: "Versand links", modelHint: "ZD421", descriptor: .tcp(host: "ZD421-versand.local", port: 9100),
                                        source: .bonjour, details: ["serviceName": "Versand links", "serviceType": "_pdl-datastream._tcp",
                                                                    "host": "ZD421-versand.local", "port": "9100"])
        let ble = Lab.ble("Versand links")
        let devices = DiscoveryFilter.groupDevices([sweep, bonjour, ble, udp])
        #expect(devices.count == 1)
        let device = devices.first
        #expect(device?.title == "Versand links")
        #expect(device?.hasCustomName == true)
        #expect(device?.displayModel == "Zebra ZD421t")
        #expect(device?.address == "10.62.13.19")
        #expect(device?.preferred.source == .zebra)
        #expect(device?.preferred.modelHint == "ZTC ZD421t-203dpi ZPL")
    }

    @Test("Gleicher Name, verschiedene Adressen: zwei Drucker")
    func sameNameDifferentAddresses() {
        let first = Lab.udp(Lab.printers[0], systemName: "Etiketten")
        let second = Lab.udp(Lab.printers[1], systemName: "Etiketten")
        #expect(DiscoveryFilter.groupDevices([first, second]).count == 2)
        // Ein BLE-Eintrag desselben Namens ist mehrdeutig: Er schließt sich keinem der beiden an –
        // in keiner Reihenfolge.
        for printers in [[first, second, Lab.ble("Etiketten")], [Lab.ble("Etiketten"), second, first]] {
            let devices = DiscoveryFilter.groupDevices(printers)
            #expect(devices.count == 3)
            #expect(devices.filter { $0.paths.contains(.network) }.allSatisfy { !$0.paths.contains(.bluetooth) })
            #expect(devices.filter { $0.paths == [.bluetooth] }.count == 1)
        }
        // Ist der Name eindeutig, gehört der BLE-Eintrag zum Drucker.
        let single = DiscoveryFilter.groupDevices([first, Lab.ble("Etiketten")])
        #expect(single.count == 1)
        #expect(single.first?.paths == [.network, .bluetooth])
    }

    @Test("Zwei Bluetooth-Geräte gleichen Namens bleiben getrennt und binden keinen Drucker")
    func sameNameTwoBLEDevices() {
        let printer = Lab.udp(Lab.printers[0], systemName: "Etiketten")
        let left = Lab.ble("Etiketten", identifier: "BLE-A"), right = Lab.ble("Etiketten", identifier: "BLE-B")
        #expect(DiscoveryFilter.groupDevices([left, right]).count == 2)
        let devices = DiscoveryFilter.groupDevices([printer, left, right])
        #expect(devices.count == 3)
        #expect(devices.first { $0.paths.contains(.network) }?.paths == [.network])
    }

    @Test("dnssd-Warteschlange mit Bonjour-Modellnamen gehört zu ihrem Bonjour-Fund")
    func dnssdQueueWithGenericBonjourName() {
        let udp = Lab.udp(Lab.printers[0])
        let bonjour = DiscoveredPrinter(name: "ZTC ZD421t-203dpi ZPL", modelHint: "ZTC ZD421t-203dpi ZPL",
                                        descriptor: .tcp(host: "10.62.13.18", port: 9100), source: .bonjour,
                                        details: ["serviceName": "ZTC ZD421t-203dpi ZPL", "serviceType": "_pdl-datastream._tcp",
                                                  "host": "10.62.13.18", "port": "9100"])
        let queue = Lab.queue("Zebra_ZD421t", uri: "dnssd://ZTC%20ZD421t-203dpi%20ZPL._pdl-datastream._tcp.local./?uuid=x")
        for printers in [[udp, bonjour, queue], [queue, bonjour, udp], [queue, udp, bonjour]] {
            let overview = DiscoveryFilter.overview(printers, identities: [])
            #expect(overview.devices.count == 1)
            #expect(overview.macQueues.isEmpty)
            #expect(overview.devices.first?.queueNames == ["Zebra_ZD421t"])
            #expect(overview.devices.first?.paths == [.network, .macPrinter])
            #expect(overview.devices.first?.serialNumber == "D6J250402293")
        }
        // Ohne Bonjour-Fund bleibt die Warteschlange eine vorhandene macOS-Warteschlange.
        let withoutBonjour = DiscoveryFilter.overview([udp, queue], identities: [])
        #expect(withoutBonjour.devices.count == 1)
        #expect(withoutBonjour.macQueues.map(\.queueNames) == [["Zebra_ZD421t"]])
    }

    @Test("Gleiche Adresse, verschiedene Seriennummern (Adresse neu vergeben): zwei Drucker")
    func reassignedAddress() {
        var old = Lab.udp(Lab.printers[0])
        old.details["macAddress"] = nil
        let new = Lab.udp(Lab.Printer(host: "10.62.13.18", serial: "D6J240101234", model: "ZTC ZD421d-203dpi ZPL",
                                      mac: "00:07:4D:B2:00:01"))
        #expect(DiscoveryFilter.groupDevices([old, new]).count == 2)
    }

    @Test("USB und Netzwerk mit derselben Seriennummer: ein Drucker, Netzwerk bevorzugt")
    func usbAndNetwork() {
        let device = USBDeviceIdentifier(productID: 0x0185, serialNumber: "D6J250301793", productName: "ZTC ZD421t-203dpi ZPL")
        let usb = DiscoveredPrinter(name: "Zebra ZD421t", modelHint: "ZTC ZD421t-203dpi ZPL", descriptor: .usb(device),
                                    source: .usb, details: ["vendorID": "0x0A5F", "serialNumber": "D6J250301793"])
        let devices = DiscoveryFilter.groupDevices([usb, Lab.udp(Lab.printers[1])])
        #expect(devices.count == 1)
        #expect(devices.first?.paths == [.network, .usb])
        #expect(devices.first?.preferred.descriptor.kind == .tcp)
        // Ohne Netzwerk: USB vor Bluetooth.
        let local = DiscoveryFilter.groupDevices([Lab.ble("D6J250301793"), usb])
        #expect(local.count == 1)
        #expect(local.first?.preferred.descriptor.kind == .usb)
        #expect(local.first?.paths == [.usb, .bluetooth])
    }

    @Test("Nur Bluetooth LE: Modell unbekannt, Titel nie die Seriennummer")
    func bleOnly() {
        let devices = DiscoveryFilter.groupDevices([Lab.ble("D6J250301793")])
        #expect(devices.count == 1)
        #expect(devices.first?.title == "Zebra-Drucker")
        #expect(devices.first?.modelName == nil)
        #expect(devices.first?.serialNumber == "D6J250301793")
        #expect(devices.first?.address == nil)
        #expect(devices.first?.preferred.descriptor.kind == .ble)
    }

    @Test("Druckserver mit mehreren Anschlüssen: 9100 und 9101 bleiben getrennt")
    func printServerPorts() {
        let left = DiscoveredPrinter(name: "Zebra ZT410", modelHint: "ZT410", descriptor: .tcp(host: "10.0.0.5", port: 9100),
                                     source: .network, details: ["host": "10.0.0.5", "port": "9100", "identifiedBy": "hi"])
        let right = DiscoveredPrinter(name: "Zebra ZT230", modelHint: "ZT230", descriptor: .tcp(host: "10.0.0.5", port: 9101),
                                      source: .network, details: ["host": "10.0.0.5", "port": "9101", "identifiedBy": "hi"])
        #expect(DiscoveryFilter.groupDevices([left, right]).count == 2)
    }

    @Test("Allgemeine Namen")
    func genericNames() {
        for name in ["", "Zebra ZD421", "ZTC ZD421-203dpi ZPL", "Zebra ZD421t", "ZD421t", "10.62.13.19",
                     "Zebra 10.62.13.19", "D6J250301793", "Zebra-Drucker (BLE)", "Zebra"] {
            #expect(DiscoveryFilter.isGenericPrinterName(name), "\(name)")
        }
        for name in ["Versand links", "Lager 2", "ZD421-Versand"] {
            #expect(!DiscoveryFilter.isGenericPrinterName(name), "\(name)")
        }
    }
}

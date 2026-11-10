import Foundation
import Testing
@testable import LabelWerkTransport

@Suite("ConnectionDescriptor")
struct ConnectionDescriptorTests {
    static let usbDevice = USBDeviceIdentifier(
        vendorID: 0x0A5F, productID: 0x0181, serialNumber: "D4J222602341",
        locationID: 0x1410_0000, productName: "ZTC ZD421-203dpi ZPL"
    )

    static let allCases: [ConnectionDescriptor] = [
        .tcp(host: "192.168.1.20", port: 9100),
        .tcp(host: "fe80::1", port: 6101),
        .usb(usbDevice),
        .usb(USBDeviceIdentifier(productID: 0x0120)),
        .bluetooth(address: "AC-3F-A4-12-34-56", name: "XXZBJ203"),
        .bluetooth(address: "AC:3F:A4:12:34:56", name: nil),
        .ble(identifier: "6B1C6F1E-8F0B-4D59-9C1F-5A1A2B3C4D5E", name: "ZQ520"),
        .ble(identifier: "6B1C6F1E-8F0B-4D59-9C1F-5A1A2B3C4D5E", name: nil),
        .cupsQueue(name: "Zebra_ZD421"),
        .virtual(id: "demo"),
    ]

    @Test("Codable-Rundreise für alle Fälle")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for descriptor in Self.allCases {
            let data = try encoder.encode(descriptor)
            let decoded = try JSONDecoder().decode(ConnectionDescriptor.self, from: data)
            #expect(decoded == descriptor)
        }
        let list = try JSONDecoder().decode([ConnectionDescriptor].self, from: try encoder.encode(Self.allCases))
        #expect(list == Self.allCases)
    }

    @Test("Stabiles JSON-Format")
    func stableJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ descriptor: ConnectionDescriptor) throws -> String {
            String(decoding: try encoder.encode(descriptor), as: UTF8.self)
        }
        #expect(try json(.tcp(host: "192.168.1.20", port: 9100)) == #"{"host":"192.168.1.20","kind":"tcp","port":9100}"#)
        #expect(try json(.cupsQueue(name: "ZD421")) == #"{"kind":"cupsQueue","name":"ZD421"}"#)
        #expect(try json(.virtual(id: "demo")) == #"{"id":"demo","kind":"virtual"}"#)
        #expect(try json(.bluetooth(address: "AC-3F-A4-12-34-56", name: nil)) == #"{"address":"AC-3F-A4-12-34-56","kind":"bluetooth"}"#)
        #expect(try json(.ble(identifier: "X", name: "ZQ520")) == #"{"identifier":"X","kind":"ble","name":"ZQ520"}"#)
        #expect(try json(.usb(USBDeviceIdentifier(vendorID: 2655, productID: 385, serialNumber: "S1"))) ==
            #"{"device":{"productID":385,"serialNumber":"S1","vendorID":2655},"kind":"usb"}"#)
    }

    @Test("Dekodieren fester JSON-Beispiele (Vorwärtskompatibilität)")
    func decodeFixtures() throws {
        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> ConnectionDescriptor {
            try decoder.decode(ConnectionDescriptor.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"kind":"tcp","host":"zd421.local"}"#) == .tcp(host: "zd421.local", port: 9100))
        #expect(try decode(#"{"kind":"usb","device":{"vendorID":2655,"productID":385,"locationID":336592896}}"#)
            == .usb(USBDeviceIdentifier(vendorID: 2655, productID: 385, locationID: 0x1410_0000)))
        #expect(try decode(#"{"kind":"ble","identifier":"ABC","extra":true}"#) == .ble(identifier: "ABC", name: nil))
        #expect(throws: DecodingError.self) { try decode(#"{"kind":"fax","number":"123"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"kind":"tcp"}"#) }
    }

    @Test("Art, Anzeige, Symbol, Bidirektionalität")
    func displayProperties() {
        #expect(ConnectionDescriptor.tcp(host: "192.168.1.20", port: 9100).displayString == "192.168.1.20:9100")
        #expect(ConnectionDescriptor.tcp(host: "fe80::1", port: 9100).displayString == "[fe80::1]:9100")
        #expect(ConnectionDescriptor.usb(Self.usbDevice).displayString == "USB · ZD421")
        #expect(ConnectionDescriptor.usb(USBDeviceIdentifier(productID: 0x0120, serialNumber: "XYZ")).displayString == "USB · Seriennr. XYZ")
        #expect(ConnectionDescriptor.usb(USBDeviceIdentifier(productID: 0x0120)).displayString == "USB · 0A5F:0120")
        #expect(ConnectionDescriptor.bluetooth(address: "AC-3F-A4-12-34-56", name: "XXZBJ203").displayString == "Bluetooth · XXZBJ203")
        #expect(ConnectionDescriptor.bluetooth(address: "AC-3F-A4-12-34-56", name: " ").displayString == "Bluetooth · AC-3F-A4-12-34-56")
        #expect(ConnectionDescriptor.ble(identifier: "6B1C6F1E-8F0B", name: nil).displayString == "Bluetooth LE · 6B1C6F1E")
        #expect(ConnectionDescriptor.cupsQueue(name: "ZD421").displayString == "CUPS-Warteschlange · ZD421")
        #expect(ConnectionDescriptor.virtual(id: "demo").displayString == "Virtueller Drucker · demo")

        let expectedKinds: [ConnectionKind] = [.tcp, .tcp, .usb, .usb, .bluetooth, .bluetooth, .ble, .ble, .cupsQueue, .virtual]
        #expect(Self.allCases.map(\.kind) == expectedKinds)
        for descriptor in Self.allCases {
            #expect(!descriptor.systemImage.isEmpty)
            #expect(descriptor.systemImage == descriptor.kind.systemImage)
            #expect(descriptor.supportsBidirectional == (descriptor.kind != .cupsQueue))
            #expect(!descriptor.displayString.isEmpty)
        }
        // Nur bekannte, gültige SF-Symbol-Namen.
        let validSymbols: Set<String> = ["network", "cable.connector", "antenna.radiowaves.left.and.right",
                                         "dot.radiowaves.left.and.right", "printer", "cube.transparent"]
        #expect(Set(ConnectionKind.allCases.map(\.systemImage)) == validSymbols)
        #expect(ConnectionKind.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("Stabile Kennung")
    func stableIDs() {
        #expect(ConnectionDescriptor.tcp(host: "ZD421.local", port: 9100).stableID == "tcp:zd421.local:9100")
        #expect(ConnectionDescriptor.tcp(host: "[FE80::1]", port: 9100).stableID == ConnectionDescriptor.tcp(host: "fe80::1", port: 9100).stableID)
        #expect(ConnectionDescriptor.usb(Self.usbDevice).stableID == "usb:0a5f:0181:D4J222602341")
        var moved = Self.usbDevice
        moved.locationID = 0x1420_0000
        moved.productName = nil
        #expect(ConnectionDescriptor.usb(moved).refersToSameDevice(as: .usb(Self.usbDevice)))
        #expect(ConnectionDescriptor.usb(USBDeviceIdentifier(productID: 1, locationID: 0x14100000)).stableID == "usb:0a5f:0001:@14100000")
        #expect(ConnectionDescriptor.bluetooth(address: "ac:3f:a4:12:34:56", name: "A").stableID
            == ConnectionDescriptor.bluetooth(address: "AC-3F-A4-12-34-56", name: nil).stableID)
        #expect(ConnectionDescriptor.ble(identifier: "abc", name: nil).stableID == "ble:ABC")
        let ids = Set(Self.allCases.map(\.stableID))
        // Bluetooth und BLE erscheinen je zweimal mit gleicher Kennung.
        #expect(ids.count == Self.allCases.count - 2)
    }

    @Test("URI-Darstellung (lwctl --printer)")
    func uriRoundTrip() {
        let samples: [(String, ConnectionDescriptor)] = [
            ("tcp://192.168.1.20", .tcp(host: "192.168.1.20", port: 9100)),
            ("tcp://192.168.1.20:6101", .tcp(host: "192.168.1.20", port: 6101)),
            ("socket://drucker.local:9100/", .tcp(host: "drucker.local", port: 9100)),
            ("tcp://[fe80::1]:9100", .tcp(host: "fe80::1", port: 9100)),
            ("192.168.1.30", .tcp(host: "192.168.1.30", port: 9100)),
            ("usb://0a5f:0181", .usb(USBDeviceIdentifier(vendorID: 0x0A5F, productID: 0x0181))),
            ("usb://0A5F:0181/D4J222602341", .usb(USBDeviceIdentifier(vendorID: 0x0A5F, productID: 0x0181, serialNumber: "D4J222602341"))),
            ("cups://Zebra_ZD421", .cupsQueue(name: "Zebra_ZD421")),
            ("cups://Lager%20Drucker", .cupsQueue(name: "Lager Drucker")),
            ("virtual://demo", .virtual(id: "demo")),
            ("bt://ac:3f:a4:12:34:56", .bluetooth(address: "AC-3F-A4-12-34-56", name: nil)),
            ("ble://6b1c6f1e-8f0b-4d59-9c1f-5a1a2b3c4d5e", .ble(identifier: "6B1C6F1E-8F0B-4D59-9C1F-5A1A2B3C4D5E", name: nil)),
        ]
        for (uri, expected) in samples {
            #expect(ConnectionDescriptor(uriString: uri) == expected, "URI \(uri)")
            #expect(ConnectionDescriptor(uriString: expected.uriString) == expected, "Rundreise \(expected.uriString)")
        }
        for invalid in ["", "tcp://", "tcp://host:0", "tcp://host:99999", "usb://zz:01", "ble://keine-uuid", "fax://123"] {
            #expect(ConnectionDescriptor(uriString: invalid) == nil, "\(invalid) sollte ungültig sein")
        }
    }

    @Test("Bluetooth-Adressen normalisieren")
    func bluetoothAddress() {
        #expect(ConnectionDescriptor.normalizedBluetoothAddress("ac:3f:a4:12:34:56") == "AC-3F-A4-12-34-56")
        #expect(ConnectionDescriptor.normalizedBluetoothAddress("AC3FA4123456") == "AC-3F-A4-12-34-56")
        #expect(ConnectionDescriptor.normalizedBluetoothAddress("kaputt") == "KAPUTT")
    }

    @Test("Kurze Modellnamen und Zebra-Erkennung")
    func modelNames() {
        #expect(ZebraIdentifiers.shortModelName(from: "ZTC ZD421-203dpi ZPL") == "ZD421")
        #expect(ZebraIdentifiers.shortModelName(from: "Zebra Technologies ZTC ZT410-300dpi ZPL") == "ZT410")
        #expect(ZebraIdentifiers.shortModelName(from: "ZDesigner GK420d") == "GK420d")
        #expect(ZebraIdentifiers.shortModelName(from: "(ZD621-203dpi)") == "ZD621")
        #expect(ZebraIdentifiers.shortModelName(from: "  ") == nil)
        #expect(ZebraIdentifiers.looksLikeZebra("ZTC ZD421-203dpi ZPL"))
        #expect(ZebraIdentifiers.looksLikeZebra("Zebra Technologies"))
        #expect(ZebraIdentifiers.looksLikeZebra("GK420d"))
        #expect(!ZebraIdentifiers.looksLikeZebra("HP LaserJet Pro M404dn"))
        #expect(!ZebraIdentifiers.looksLikeZebra("Brother HL-L2350DW series"))
        #expect(!ZebraIdentifiers.looksLikeZebra("Aztec Scanner"))
    }
}

@Suite("TransportError")
struct TransportErrorTests {
    @Test("Deutsche Beschreibungen und Gleichheit")
    func descriptions() {
        let errors: [TransportError] = [
            .notOpen, .timeout, .closedByPeer, .connectionFailed("Connection refused"), .ioError("EIO"),
            .unsupported("USB"), .deviceNotFound("ZD421"), .permissionDenied("CUPS"),
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty)
            #expect(error.recoverySuggestion?.isEmpty == false)
            #expect(error.localizedDescription == description)
        }
        #expect(TransportError.timeout.errorDescription == "Der Drucker hat nicht rechtzeitig reagiert (Zeitüberschreitung).")
        #expect(TransportError.connectionFailed("Connection refused").errorDescription == "Verbindung zum Drucker fehlgeschlagen: Connection refused")
        #expect(TransportError.deviceNotFound("").errorDescription == "Gerät nicht gefunden.")
        #expect(TransportError.connectionFailed("a") == .connectionFailed("a"))
        #expect(TransportError.connectionFailed("a") != .connectionFailed("b"))
        #expect(TransportError.ioError("x").failureReason == "x")
        #expect(TransportError.notOpen.failureReason == nil)
    }
}

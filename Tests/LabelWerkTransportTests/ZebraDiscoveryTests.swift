import Foundation
import Testing
@testable import LabelWerkTransport

/// Antwort eines ZebraNet-Druckservers, wie sie J. Runyon mitgeschnitten hat
/// (https://jfr.im/blog/2024/09/zebra-network-discovery-protocol/, 375 Byte).
let capturedPrintServerReply: [UInt8] = hexBytes("""
    3a 2c 2e 03 37 39 30 37 31 00 00 00 5a 65 62 72
    61 4e 65 74 20 57 69 72 65 64 20 50 53 00 00 00
    31 31 36 36 41 00 00 56 35 36 2e 31 37 2e 31 31
    5a 5a 42 52 00 61 00 07 4d 41 08 bd 34 32 36 32
    30 37 37 00 00 00 01 00 0a 01 00 9e ff ff ff 00
    0a 01 00 01 5a 42 52 34 32 36 32 30 37 37 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 7a 00 6d 14 7a 16 11 1c 2b 3a 35 30
    3f 4e 59 54 53 52 5d 68 67 66 61 6c 7b 8a 85 80
    8f 9e a9 a4 ee 18 e1 14 ee 0e 8d 0c 8f 0a 91 08
    93 06 95 04 97 02 99 00 9b 3e dd 7c 1f ba 21 b8
    23 b6 25 b4 4e 6f 6e 65 00 0e 8d 0c 8f 0a 91 08
    93 06 95 04 97 02 99 00 9b 3e dd 7c 1f ba 21 b8
    23 b6 25 b4 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 01 01 01 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00
    """)

func hexBytes(_ text: String) -> [UInt8] {
    text.split(whereSeparator: { $0 == " " || $0.isNewline }).compactMap { UInt8($0, radix: 16) }
}

/// ZD620 laut der an echten Druckern gemessenen Tabelle (monochrome-unicorn, docs/printer-notes.md),
/// mit der Adresse des Druckers aus dem Bildschirmfoto.
let zd620Reply = ZebraDiscoveryPacket.Reply(
    version: 3, productNumber: "V84", productName: "ZTC ZD620-300dpi ZPL", dateCode: "72221",
    firmware: "V84.20.23Z", company: "ZBR", macAddress: "00:07:4D:A3:CC:A7", serialNumber: "10734759",
    ipAddress: "10.62.13.19", subnetMask: "255.255.255.0", gateway: "10.62.13.1", systemName: "ZEBRA-ZD620"
)

@Suite("Zebra-Suche: Paketformat")
struct ZebraDiscoveryPacketTests {
    @Test("Anfrage: „.,:“ + 01 00 00, Port 4201, Multicast 224.0.1.55")
    func request() {
        #expect(ZebraDiscoveryPacket.request == [0x2E, 0x2C, 0x3A, 0x01, 0x00, 0x00])
        #expect(ZebraDiscoveryPacket.port == 4201)
        #expect(ZebraDiscoveryPacket.multicastGroup == "224.0.1.55")
        #expect(ZebraDiscoveryPacket.defaultMulticastHops == 3)
    }

    @Test("Mitgeschnittene Antwort eines ZebraNet-Druckservers")
    func capturedReply() throws {
        // Der Mitschnitt endet nach 375 Byte (ZD620/ZD500R senden 376).
        #expect(capturedPrintServerReply.count == 375)
        let reply = try #require(ZebraDiscoveryPacket.parse(capturedPrintServerReply))
        #expect(reply.version == 3)
        #expect(reply.productNumber == "79071")
        #expect(reply.productName == "ZebraNet Wired PS")
        #expect(reply.dateCode == "1166A")
        #expect(reply.firmware == "V56.17.11Z")
        #expect(reply.company == "ZBR")
        #expect(reply.macAddress == "00:07:4D:41:08:BD")
        #expect(reply.serialNumber == "4262077")
        #expect(reply.ipAddress == "10.1.0.158")
        #expect(reply.subnetMask == "255.255.255.0")
        #expect(reply.gateway == "10.1.0.1")
        #expect(reply.systemName == "ZBR4262077")
        // Externer Druckserver: sein Name sagt nichts über das Druckermodell.
        #expect(reply.isExternalPrintServer)
        #expect(reply.modelHint == nil)

        let printer = ZebraDiscoveryPacket.makeDiscoveredPrinter(reply, host: "10.1.0.158")
        #expect(printer.name == "ZBR4262077")
        #expect(printer.modelHint == nil)
        #expect(printer.descriptor == .tcp(host: "10.1.0.158", port: 9100))
        #expect(printer.source == .zebra)
        #expect(printer.details["printServer"] == "ZebraNet Wired PS")
        #expect(printer.details["productName"] == nil)
        #expect(printer.details["identifiedBy"] == "zebra")
        #expect(printer.details["printServerSerial"] == "4262077")
        #expect(printer.details["serialNumber"] == nil)
        #expect(printer.details["macAddress"] == "00:07:4D:41:08:BD")
        #expect(printer.details["reportedAddress"] == nil)
    }

    @Test("Erzeugte Antwort (ZD620): Aufbau, Rückweg und gefundener Drucker")
    func synthesizedReply() throws {
        let bytes = ZebraDiscoveryPacket.encode(zd620Reply)
        #expect(bytes.count == 376)
        #expect(Array(bytes[0..<4]) == [0x3A, 0x2C, 0x2E, 0x03])
        #expect(Array(bytes[54..<60]) == [0x00, 0x07, 0x4D, 0xA3, 0xCC, 0xA7])
        #expect(Array(bytes[72..<76]) == [10, 62, 13, 19])
        #expect(String(decoding: bytes[84..<95], as: UTF8.self) == "ZEBRA-ZD620")
        let parsed = try #require(ZebraDiscoveryPacket.parse(bytes))
        #expect(parsed == zd620Reply)
        #expect(parsed.shortModelName == "ZD620")

        let printer = ZebraDiscoveryPacket.makeDiscoveredPrinter(parsed, host: "10.62.13.19")
        #expect(printer.id == "tcp:10.62.13.19:9100")
        #expect(printer.name == "ZEBRA-ZD620")
        #expect(printer.modelHint == "ZTC ZD620-300dpi ZPL")
        #expect(ZebraIdentifiers.looksLikeZebra(printer.modelHint ?? ""))
        #expect(printer.details["productName"] == "ZTC ZD620-300dpi ZPL")
        #expect(printer.details["firmware"] == "V84.20.23Z")
        #expect(printer.details["name"] == "ZEBRA-ZD620")
        #expect(printer.details["gateway"] == "10.62.13.1")
    }

    @Test("Gekürzter Produktname, fehlender Systemname, Adresse hinter NAT/VPN")
    func truncatedAndTranslated() throws {
        var reply = zd620Reply
        reply.productName = "ZTC ZD500R-300dpi ZPL" // wird auf 20 Zeichen gekürzt
        reply.systemName = nil
        let parsed = try #require(ZebraDiscoveryPacket.parse(ZebraDiscoveryPacket.encode(reply)))
        #expect(parsed.productName == "ZTC ZD500R-300dpi ZP")
        #expect(parsed.systemName == nil)
        #expect(parsed.shortModelName == "ZD500R")
        let printer = ZebraDiscoveryPacket.makeDiscoveredPrinter(parsed, host: "172.20.1.7", port: 6101)
        #expect(printer.name == "Zebra ZD500R")
        #expect(printer.descriptor == .tcp(host: "172.20.1.7", port: 6101))
        #expect(printer.details["reportedAddress"] == "10.62.13.19")
        #expect(printer.details["port"] == "6101")
    }

    @Test("Fremde und kaputte Pakete")
    func invalidPackets() throws {
        #expect(ZebraDiscoveryPacket.parse([UInt8]()) == nil)
        #expect(ZebraDiscoveryPacket.parse([0x3A, 0x2C, 0x2E]) == nil)
        #expect(ZebraDiscoveryPacket.parse(ZebraDiscoveryPacket.request) == nil) // eigene Anfrage
        #expect(ZebraDiscoveryPacket.parse(Data("HTTP/1.1 200 OK".utf8)) == nil)

        // Nur Kennung und Version (älterer Druckserver mit anderem Aufbau): alle Felder leer.
        let minimal = try #require(ZebraDiscoveryPacket.parse([0x3A, 0x2C, 0x2E, 0x02]))
        #expect(minimal.version == 2)
        #expect(minimal.productName == nil && minimal.ipAddress == nil && minimal.macAddress == nil)

        // Nicht druckbare Bytes im Textfeld → Feld leer statt Zeichensalat; Nullen → keine Adresse.
        var bytes = ZebraDiscoveryPacket.encode(zd620Reply)
        bytes[13] = 0x07
        bytes.replaceSubrange(54..<60, with: [0, 0, 0, 0, 0, 0])
        bytes.replaceSubrange(80..<84, with: [0, 0, 0, 0])
        let damaged = try #require(ZebraDiscoveryPacket.parse(bytes))
        #expect(damaged.productName == nil)
        #expect(damaged.macAddress == nil)
        #expect(damaged.gateway == nil)
        #expect(damaged.systemName == "ZEBRA-ZD620")

        // Abgeschnittenes Paket: nur vollständige Felder.
        let cut = try #require(ZebraDiscoveryPacket.parse(Array(ZebraDiscoveryPacket.encode(zd620Reply).prefix(74))))
        #expect(cut.productName == "ZTC ZD620-300dpi ZPL")
        #expect(cut.serialNumber == "10734759")
        #expect(cut.ipAddress == nil)
        #expect(cut.systemName == nil)
    }
}

@Suite("Netze der Suche")
struct DiscoveryNetworksTests {
    func range(_ text: String) throws -> IPv4Range {
        try DiscoveryNetworks.parse(text).get()
    }

    @Test("CIDR, Maske, drei Oktette, .0")
    func cidr() throws {
        let net = try range("10.62.13.0/24")
        #expect(net.description == "10.62.13.0/24")
        #expect(net.cidrPrefix == 24)
        #expect(net.hostCount == 254)
        #expect(net.hosts().first == "10.62.13.1")
        #expect(net.hosts().last == "10.62.13.254")
        #expect(net.broadcastAddress == "10.62.13.255")
        #expect(try range("10.62.13.19/24") == net)
        #expect(try range("10.62.13.0/255.255.255.0") == net)
        #expect(try range("10.62.13") == net)
        #expect(try range("10.62.13.") == net)
        #expect(try range("10.62.13.0") == net)
        #expect(try range("10.62.13.0 / 24") == net)
        #expect(try range("10.62.12.0/23").hostCount == 510)
        #expect(try range("10.62.13.16/30").hosts() == ["10.62.13.17", "10.62.13.18"])
        #expect(try range("10.62.13.16/31").hosts() == ["10.62.13.16", "10.62.13.17"])
        #expect(try range("10.62.13.16/31").broadcastAddress == nil)
    }

    @Test("Bereiche und Platzhalter wie im Link-OS-SDK")
    func ranges() throws {
        let full = try range("10.62.13.1-10.62.13.254")
        #expect(full.hostCount == 254)
        #expect(full.description == "10.62.13.1–10.62.13.254")
        #expect(full.broadcastAddress == nil)
        #expect(try range(" 10.62.13.1 – 10.62.13.254 ") == full)
        #expect(try range("10.62.13.37-42").hosts() == (37...42).map { "10.62.13.\($0)" })
        let open = try range("10.62.13.8-*")
        #expect(open.hosts().first == "10.62.13.8")
        #expect(open.hosts().last == "10.62.13.254")
        #expect(open.hostCount == 247)
        let wildcard = try range("10.62.13.*")
        #expect(wildcard.description == "10.62.13.0/24")
        #expect(wildcard.hostCount == 254)
        #expect(try range("10.62.*").description == "10.62.0.0/16")
        #expect(try range("10.62.*.*").cidrPrefix == 16)
        let single = try range("10.62.13.19")
        #expect(single.hosts() == ["10.62.13.19"])
        #expect(single.description == "10.62.13.19")
        // Bereich über eine Oktettgrenze.
        #expect(try range("10.62.12.250-10.62.13.5").hostCount == 12)
    }

    @Test("Ungültige Angaben")
    func invalid() {
        #expect(DiscoveryNetworks.parse("") == .failure(.empty))
        #expect(DiscoveryNetworks.parse("   ") == .failure(.empty))
        #expect(DiscoveryNetworks.parse("lager") == .failure(.invalidSyntax))
        #expect(DiscoveryNetworks.parse("10.62.13.300") == .failure(.invalidSyntax))
        #expect(DiscoveryNetworks.parse("10.62.13.0/33") == .failure(.invalidPrefix))
        #expect(DiscoveryNetworks.parse("10.62.13.0/255.0.255.0") == .failure(.invalidPrefix))
        #expect(DiscoveryNetworks.parse("10.62.13.50-10") == .failure(.reversedRange))
        #expect(DiscoveryNetworks.parse("10.62.13.50-10.62.13.10") == .failure(.reversedRange))
        #expect(DiscoveryNetworks.parse("10.*.13.*") == .failure(.invalidSyntax))
        #expect(DiscoveryNetworks.parse("*") == .failure(.invalidSyntax))
        #expect(DiscoveryNetworks.parse("127.0.0.1") == .failure(.reservedAddress))
        #expect(DiscoveryNetworks.parse("224.0.1.55/24") == .failure(.reservedAddress))
        #expect(DiscoveryNetworks.parse("0.0.0.0/0") == .failure(.reservedAddress))
        #expect(DiscoveryNetworks.parse("100.0.0.0-200.0.0.0") == .failure(.reservedAddress))
    }

    @Test("Private Adressen (RFC 1918)")
    func privateAddresses() {
        for host in ["10.0.0.1", "10.62.13.19", "172.16.0.1", "172.31.255.254", "192.168.1.5"] {
            #expect(DiscoveryNetworks.isPrivate(host: host), "\(host)")
        }
        for host in ["172.15.0.1", "172.32.0.1", "100.64.1.2", "8.8.8.8", "192.169.0.1", "kein-host"] {
            #expect(!DiscoveryNetworks.isPrivate(host: host), "\(host)")
        }
    }

    @Test("Netze bekannter Drucker und Geräte-URIs")
    func knownPrinters() {
        #expect(DiscoveryNetworks.host(ofDeviceURI: "socket://10.62.13.19:9100") == "10.62.13.19")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "ipp://10.62.13.19/ipp/print") == "10.62.13.19")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "lpd://10.62.13.19/") == "10.62.13.19")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J") == nil)
        #expect(DiscoveryNetworks.host(ofDeviceURI: "dnssd://ZD421._pdl-datastream._tcp.local./") == nil)
        #expect(DiscoveryNetworks.host(ofDeviceURI: "socket://localhost:9100") == nil)
        // Benannte LPD-Warteschlange (Zebra-Druckserver) und Freigabe eines Druckservers: Nur der Host zählt.
        #expect(DiscoveryNetworks.host(ofDeviceURI: "lpd://10.62.13.19/PRT") == "10.62.13.19")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "ipp://10.62.13.19:631/printers/zebra") == "10.62.13.19")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "socket://Zebra-Lager.Firma.local.:9100") == "zebra-lager.firma.local")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "socket://[fe80::1%25en0]:9100") == "fe80::1%en0")
        #expect(DiscoveryNetworks.host(ofDeviceURI: "ipp://127.0.0.1:631/printers/zebra") == nil)
        #expect(DiscoveryNetworks.host(ofDeviceURI: "file:///dev/null") == nil)

        let entries = DiscoveryNetworks.knownPrinterNetworks([
            (host: "10.62.13.19", label: "ZD421t"),
            (host: "192.168.1.5", label: nil),
            (host: "10.62.13.20", label: "Lager"),
            (host: "10.62.13.21", label: "ZD421t"),
            (host: "zebra-lager.local", label: "Name"),
            (host: "127.0.0.1", label: "Tunnel"),
            (host: "169.254.3.4", label: "Link-Local"),
            (host: "[10.62.14.2]", label: nil),
        ])
        #expect(entries.map(\.text) == ["10.62.13.0/24", "10.62.14.0/24", "192.168.1.0/24"])
        #expect(entries.allSatisfy { $0.origin == .knownPrinter })
        #expect(entries.first?.label == "ZD421t, Lager")
        #expect(entries.last?.label == nil)
    }

    @Test("Netze bekannter Drucker: öffentliche Adressen nur einzeln")
    func knownPublicPrinters() {
        let entries = DiscoveryNetworks.knownPrinterNetworks([
            (host: "8.8.8.8", label: "Weiterleitung"),
            (host: "10.62.13.19", label: "ZD421t"),
            (host: "100.64.1.2", label: "CGNAT"),
        ])
        #expect(entries.map(\.text) == ["8.8.8.8", "10.62.13.0/24", "100.64.1.2"])
        #expect(!entries.contains { $0.text == "8.8.8.0/24" })
        let plan = DiscoveryPlan.make(interfaces: [], entries: [entries[0]])
        #expect(plan.hosts == ["8.8.8.8"])
        #expect(plan.remoteHosts == ["8.8.8.8"])
        #expect(plan.broadcastTargets == ["255.255.255.255"])
    }

    @Test("Netze bekannter Drucker: Hostnamen über einen Resolver")
    func knownPrinterHostnames() async {
        let hosts: [(host: String, label: String?)] = [
            (host: "Zebra-Lager.Firma.local.", label: "Lager"),
            (host: "unbekannt.firma.local", label: "Weg"),
            (host: "10.62.13.19", label: "ZD421t"),
            (host: "[fe80::1]", label: nil),
        ]
        #expect(DiscoveryNetworks.knownPrinterNetworks(hosts).map(\.text) == ["10.62.13.0/24"])
        let asked = LockedNames()
        let resolved = await DiscoveryNetworks.resolveHostnames(hosts.map(\.host)) { name in
            await asked.add(name)
            return name == "zebra-lager.firma.local" ? "10.62.20.7" : nil
        }
        #expect(resolved == ["zebra-lager.firma.local": "10.62.20.7"])
        // Nur Hostnamen werden aufgelöst, jeder einmal.
        #expect(await asked.names.sorted() == ["unbekannt.firma.local", "zebra-lager.firma.local"])
        let entries = DiscoveryNetworks.knownPrinterNetworks(hosts, resolved: resolved)
        #expect(entries.map(\.text) == ["10.62.13.0/24", "10.62.20.0/24"])
        #expect(entries.last?.label == "Lager")
        #expect(await DiscoveryNetworks.resolveHostnames(["10.62.13.19", " "]).isEmpty)
        // Systemauflösung: IP-Literal ohne DNS, Unsinn liefert nil.
        #expect(await DiscoveryNetworks.systemIPv4Address(of: "10.62.13.19") == "10.62.13.19")
        #expect(await DiscoveryNetworks.systemIPv4Address(of: "kein-host.invalid", timeout: .milliseconds(500)) == nil)
    }

    @Test("Eigene Angaben bereinigen und zerlegen")
    func userEntries() {
        #expect(DiscoveryNetworks.normalizedUserEntries(["10.62.13.0/24", " ", "10.62.13.*", "lager", "LAGER", "10.62.14.0/24"])
                == ["10.62.13.0/24", "lager", "10.62.14.0/24"])
        #expect(DiscoveryNetworks.splitList("10.62.13.0/24, 10.62.14.*;\n192.168.5.1-20") == ["10.62.13.0/24", "10.62.14.*", "192.168.5.1-20"])
    }

    static let interfaces = [
        NetworkInterfaceInfo(name: "en0", address: "192.168.1.37", netmask: "255.255.255.0"),
        // FortiClient-Tunnel mit privater Adresse und einer mit CGNAT-Adresse (nicht RFC 1918).
        NetworkInterfaceInfo(name: "utun4", address: "10.212.134.200", netmask: "255.255.255.255", isPointToPoint: true,
                             supportsMulticast: false),
        NetworkInterfaceInfo(name: "utun5", address: "100.64.1.2", netmask: "255.255.255.255", isPointToPoint: true),
    ]

    @Test("Suchplan: lokal, VPN, eigene und bekannte Netze, zusammengefasst")
    func plan() throws {
        let plan = DiscoveryPlan.make(interfaces: Self.interfaces, entries: [
            DiscoveryNetworkEntry("10.62.13.0/24", origin: .knownPrinter, label: "ZD421t"),
            DiscoveryNetworkEntry("192.168.1.0/24", origin: .knownPrinter, label: "Büro"),
            DiscoveryNetworkEntry("10.62.13.*", origin: .user),
            DiscoveryNetworkEntry("lager", origin: .user),
            DiscoveryNetworkEntry("kaputt", origin: .knownPrinter),
        ])
        #expect(plan.networks.map(\.range.description) == ["192.168.1.0/24", "10.212.134.0/24", "10.62.13.0/24"])
        let local = plan.networks[0]
        #expect(local.origins == [.local, .knownPrinter])
        #expect(local.labels == ["en0", "Büro"])
        #expect(local.broadcastAddress == "192.168.1.255")
        #expect(local.searchedHostCount == 254)
        let vpn = plan.networks[1]
        #expect(vpn.origin == .vpn)
        #expect(vpn.labels == ["utun4"])
        #expect(vpn.broadcastAddress == nil)
        let user = plan.networks[2]
        #expect(user.origins == [.user, .knownPrinter])
        #expect(user.labels == ["ZD421t"])
        #expect(!user.isCapped)
        #expect(plan.invalidEntries == [DiscoveryNetworkInvalidEntry(text: "lager", error: .invalidSyntax)])

        #expect(plan.hosts.count == 3 * 254)
        #expect(plan.remoteHosts.count == 2 * 254)
        #expect(!plan.remoteHosts.contains("192.168.1.20"))
        #expect(plan.remoteHosts.contains("10.62.13.19"))
        #expect(plan.broadcastTargets == ["255.255.255.255", "192.168.1.255", "10.62.13.255"])
        #expect(plan.isLocal(host: "192.168.1.200"))
        #expect(!plan.isLocal(host: "10.62.13.19"))
        #expect(Set(plan.networks.map(\.id)).count == plan.networks.count)

        let withoutVPN = DiscoveryPlan.make(interfaces: Self.interfaces, entries: [], includePrivateVPNNetworks: false)
        #expect(withoutVPN.networks.map(\.origin) == [.local])
    }

    @Test("Obergrenze 4096 Adressen je Eintrag")
    func cap() throws {
        let plan = DiscoveryPlan.make(interfaces: [], entries: [
            DiscoveryNetworkEntry("10.0.0.0/16", origin: .user),
            DiscoveryNetworkEntry("10.1.0.0/20", origin: .user),
        ])
        let big = plan.networks[0]
        #expect(big.isCapped)
        #expect(big.searchedHostCount == DiscoveryNetworks.maxHostsPerEntry)
        #expect(big.hosts().first == "10.0.0.1")
        #expect(big.hosts().last == "10.0.16.0")
        #expect(big.broadcastAddress == "10.0.255.255")
        let exact = plan.networks[1]
        #expect(!exact.isCapped)
        #expect(exact.searchedHostCount == 4094)
        #expect(plan.totalHostCount == 4096 + 4094)

        let small = DiscoveryPlan.make(interfaces: [], entries: [DiscoveryNetworkEntry("10.0.0.0/24")], maxHostsPerEntry: 10)
        #expect(small.networks[0].isCapped)
        #expect(small.hosts == (1...10).map { "10.0.0.\($0)" })
    }

    @Test("Geschätzte Dauer des Netzwerk-Scans")
    func estimatedDuration() {
        #expect(DiscoveryPlan().estimatedScanDuration() == .seconds(10))
        let lan = DiscoveryPlan.make(interfaces: [Self.interfaces[0]], entries: [])
        #expect(lan.estimatedScanDuration() == .seconds(10)) // 3 s + 4 × 0,4 s < Minimum
        let vpn = DiscoveryPlan.make(interfaces: [Self.interfaces[0]], entries: [DiscoveryNetworkEntry("10.62.0.0/20")])
        // 254 lokale (4 × 0,4 s) und 4094 entfernte Adressen (64 × 0,9 s) + 3 s.
        #expect(vpn.estimatedScanDuration() == .milliseconds(3000 + 1600 + 57600))
        #expect(vpn.estimatedScanDuration(maximum: .seconds(30)) == .seconds(30))
        let large = DiscoveryPlan.make(interfaces: [], entries: [DiscoveryNetworkEntry("10.62.0.0/20"),
                                                                 DiscoveryNetworkEntry("10.63.0.0/20")])
        #expect(large.estimatedScanDuration() == .seconds(90)) // Obergrenze
        #expect(large.estimatedScanDuration(maximum: .seconds(600)) == .milliseconds(3000 + 128 * 900))
    }

    @Test("Ziele der Zebra-Suche")
    func zebraTargets() {
        var options = PrinterDiscovery.Options()
        options.extraNetworks = [DiscoveryNetworkEntry("10.62.13.0/24", origin: .knownPrinter, label: "ZD421t")]
        let plan = PrinterDiscovery.plan(options: options, interfaces: Self.interfaces)
        let targets = PrinterDiscovery.zebraTargets(options: options, plan: plan, interfaces: Self.interfaces)
        #expect(targets.broadcast == ["255.255.255.255", "192.168.1.255", "10.62.13.255"])
        #expect(targets.multicastInterfaces == ["192.168.1.37"])
        #expect(targets.unicast.count == 2 * 254)
        #expect(targets.unicast.contains("10.62.13.19"))
        #expect(targets.unicast.contains("10.212.134.1"))

        options.zebraUseBroadcast = false
        options.zebraUseMulticast = false
        options.zebraUnicastToLocalSubnets = true
        let unicastOnly = PrinterDiscovery.zebraTargets(options: options, plan: plan, interfaces: Self.interfaces)
        #expect(unicastOnly.broadcast.isEmpty && unicastOnly.multicastInterfaces.isEmpty)
        #expect(unicastOnly.unicast.count == 3 * 254)

        options.networkHosts = ["10.62.13.19", "zebra.local", "10.62.13.19"]
        let explicit = PrinterDiscovery.zebraTargets(options: options, plan: plan, interfaces: Self.interfaces)
        #expect(explicit == ZebraUDPDiscovery.Targets(broadcast: [], multicastInterfaces: [], unicast: ["10.62.13.19"]))
        #expect(PrinterDiscovery.networkHosts(options: options) == ["10.62.13.19", "zebra.local"])
    }

    @Test("Schnittstellen: Broadcastadresse und VPN-Kennzeichnung")
    func interfaceInfo() {
        #expect(Self.interfaces[0].broadcastAddress == "192.168.1.255")
        #expect(Self.interfaces[1].broadcastAddress == nil)
        #expect(NetworkInterfaceInfo(name: "en0", address: "10.0.0.4", netmask: "255.255.255.254").broadcastAddress == nil)
        for iface in SubnetScanner.allIPv4Interfaces() {
            #expect(!iface.address.hasPrefix("127."))
        }
        #expect(SubnetScanner.localIPv4Interfaces().allSatisfy { !$0.isPointToPoint })
    }
}

@Suite("Funde zusammenführen")
struct DiscoveryRegistryTests {
    static func unidentified(_ host: String, port: Int = 9100) -> DiscoveredPrinter {
        DiscoveredPrinter(name: host, descriptor: .tcp(host: host, port: port), source: .network,
                          details: ["host": host, "port": String(port)])
    }

    @Test("Zebra-Suche ergänzt einen nicht identifizierten Netzwerkfund")
    func upgrade() throws {
        var registry = DiscoveryRegistry()
        let scan = Self.unidentified("10.62.13.19")
        #expect(registry.insert(scan) == .added(scan))
        let zebra = ZebraDiscoveryPacket.makeDiscoveredPrinter(zd620Reply, host: "10.62.13.19")
        guard case .updated(let merged) = registry.insert(zebra) else {
            Issue.record("kein Update")
            return
        }
        #expect(merged.id == scan.id)
        #expect(merged.descriptor == scan.descriptor)
        #expect(merged.source == .zebra)
        #expect(merged.name == "ZEBRA-ZD620")
        #expect(merged.modelHint == "ZTC ZD620-300dpi ZPL")
        #expect(merged.details["printServerSerial"] == "10734759")
        #expect(merged.details["serialNumber"] == nil)
        #expect(merged.details["identifiedBy"] == "zebra")
        #expect(registry.printers.count == 1)
        // Danach bringt der Scan nichts Neues mehr.
        #expect(registry.insert(scan) == .duplicate)
    }

    @Test("Seriennummer des Druckservers überschreibt nie die des Druckers")
    func printServerSerial() throws {
        var registry = DiscoveryRegistry()
        let snmp = DiscoveredPrinter(name: "Lager ZD620", modelHint: "ZTC ZD620-300dpi ZPL",
                                     descriptor: .tcp(host: "10.62.13.19", port: 9100), source: .network,
                                     details: ["host": "10.62.13.19", "identifiedBy": "snmp+hi", "serialNumber": "D4J123"])
        registry.insert(snmp)
        let zebra = ZebraDiscoveryPacket.makeDiscoveredPrinter(zd620Reply, host: "10.62.13.19")
        let merged = try #require(registry.insert(zebra).printer)
        #expect(merged.details["serialNumber"] == "D4J123")
        #expect(merged.details["printServerSerial"] == "10734759")
        // Gleiche Nummer, andere Art: kein Abgleich.
        var other = zd620Reply
        other.serialNumber = "D4J123"
        other.macAddress = "00:07:4D:00:00:01"
        let second = ZebraDiscoveryPacket.makeDiscoveredPrinter(other, host: "10.62.13.30")
        #expect(registry.insert(second) == .added(second))
        // Gleiche MAC-Adresse unter neuer Adresse (DHCP): derselbe Drucker.
        var moved = zd620Reply
        moved.serialNumber = nil
        let renumbered = ZebraDiscoveryPacket.makeDiscoveredPrinter(moved, host: "10.62.13.40")
        #expect(registry.matchingID(for: renumbered) == snmp.id)
        #expect(DiscoveryRegistry.macKey("00-07-4d-a3-cc-a7") == "00074DA3CCA7")
        #expect(DiscoveryRegistry.macKey("00:00:00:00:00:00") == nil)
        #expect(DiscoveryRegistry.macKey("FF:FF:FF:FF:FF:FF") == nil)
    }

    @Test("Erster Fund bleibt bei gleichwertiger oder schwächerer Erkennung")
    func duplicates() {
        var registry = DiscoveryRegistry()
        let zebra = ZebraDiscoveryPacket.makeDiscoveredPrinter(zd620Reply, host: "10.62.13.19")
        #expect(registry.insert(zebra) == .added(zebra))
        #expect(registry.insert(Self.unidentified("10.62.13.19")) == .duplicate)
        // Gleiche Adresse, anderer Port.
        #expect(registry.insert(Self.unidentified("10.62.13.19", port: 6101)) == .duplicate)
        // Gleicher Druckserver (Seriennummer, MAC) unter anderer Adresse.
        let wifi = ZebraDiscoveryPacket.makeDiscoveredPrinter(zd620Reply, host: "10.62.20.7")
        #expect(registry.insert(wifi) == .duplicate)
        // Anderer Drucker, macOS-Warteschlange: eigene Einträge.
        var other = zd620Reply
        other.serialNumber = "99999"
        other.macAddress = "00:07:4D:00:00:02"
        let second = ZebraDiscoveryPacket.makeDiscoveredPrinter(other, host: "10.62.13.20")
        #expect(registry.insert(second) == .added(second))
        let queue = DiscoveredPrinter(name: "10.62.13.19", descriptor: .cupsQueue(name: "10.62.13.19"), source: .cups)
        #expect(registry.insert(queue) == .added(queue))
        #expect(registry.printers.map(\.id) == ["tcp:10.62.13.19:9100", "tcp:10.62.13.20:9100", "cups:10.62.13.19"])
        #expect(registry.matchingID(for: wifi) == "tcp:10.62.13.19:9100")
    }

    @Test("Zusammenführen: Erkennungswege, Name und Rangfolge")
    func merging() {
        let snmp = DiscoveredPrinter(name: "Lager ZD421", modelHint: "ZTC ZD421-203dpi ZPL",
                                     descriptor: .tcp(host: "10.0.0.5", port: 9100), source: .network,
                                     details: ["host": "10.0.0.5", "identifiedBy": "snmp+hi", "dotsPerMM": "8"])
        var reply = zd620Reply
        reply.systemName = nil
        reply.productName = "ZTC ZD421-203dpi ZPL"
        let zebra = ZebraDiscoveryPacket.makeDiscoveredPrinter(reply, host: "10.0.0.5")
        #expect(zebra.name == "Zebra ZD421")
        let merged = DiscoveryRegistry.merged(existing: snmp, with: zebra)
        #expect(merged.details["identifiedBy"] == "zebra+snmp+hi")
        #expect(merged.details["dotsPerMM"] == "8")
        #expect(merged.details["host"] == "10.0.0.5")
        // Der eigene Name (SNMP) bleibt gegenüber dem allgemeinen „Zebra ZD421“.
        #expect(merged.name == "Lager ZD421")
        #expect(merged.source == .zebra)
        #expect(DiscoveryRegistry.merged(existing: Self.unidentified("10.0.0.5"), with: zebra).name == "Zebra ZD421")
        // Bloßer Adressname weicht nie einem schlechteren.
        let placeholder = Self.unidentified("10.0.0.6")
        var unnamed = zd620Reply
        unnamed.systemName = nil
        unnamed.productName = nil
        let bare = ZebraDiscoveryPacket.makeDiscoveredPrinter(unnamed, host: "10.0.0.6")
        #expect(bare.name == "Zebra 10.0.0.6")
        #expect(DiscoveryRegistry.merged(existing: placeholder, with: bare).name == "Zebra 10.0.0.6")
        let named = DiscoveredPrinter(name: "Versand", descriptor: .tcp(host: "10.0.0.6", port: 9100), source: .bonjour)
        #expect(DiscoveryRegistry.merged(existing: named, with: bare).name == "Versand")

        #expect(DiscoveryRegistry.identificationRank(zebra) == 3)
        #expect(DiscoveryRegistry.identificationRank(snmp) == 2)
        #expect(DiscoveryRegistry.identificationRank(named) == 2)
        #expect(DiscoveryRegistry.identificationRank(placeholder) == 1)
        #expect(DiscoveryRegistry.identificationRank(merged) == 3)
    }
}

@Suite("Zebra-Suche über UDP")
struct ZebraUDPDiscoveryTests {
    /// Antwortet wie ein Zebra-Druckserver – nur auf die echte Anfrage.
    static func makeResponder(_ reply: [UInt8], counter: LockedValue<Int>? = nil) throws -> TestUDPResponder {
        try TestUDPResponder { request in
            guard [UInt8](request) == ZebraDiscoveryPacket.request else { return nil }
            counter?.withLock { $0 += 1 }
            return Data(reply)
        }
    }

    @Test("Einzelabfrage findet den Druckserver; mehrere Runden, eine Meldung")
    func unicast() async throws {
        let requests = LockedValue(0)
        let responder = try Self.makeResponder(ZebraDiscoveryPacket.encode(zd620Reply), counter: requests)
        defer { responder.stop() }
        var replies: [(ZebraDiscoveryPacket.Reply, String)] = []
        let (report, elapsed) = await measure {
            await ZebraUDPDiscovery.run(
                targets: ZebraUDPDiscovery.Targets(unicast: ["127.0.0.1"]),
                port: responder.port, rounds: 2, roundInterval: .milliseconds(150), replyWindow: .milliseconds(400)
            ) { reply, host in replies.append((reply, host)) }
        }
        #expect(replies.count == 1)
        #expect(replies.first?.0 == zd620Reply)
        #expect(replies.first?.1 == "127.0.0.1")
        #expect(report.sent == 2)
        #expect(report.replies == 1)
        #expect(report.failed == 0)
        #expect(requests.value == 2)
        #expect(elapsed < .seconds(2))
    }

    @Test("Fremde Antworten und Fehler beim Senden")
    func foreignReplies() async throws {
        let responder = try TestUDPResponder { _ in Data("kein Zebra".utf8) }
        defer { responder.stop() }
        var count = 0
        let report = await ZebraUDPDiscovery.run(
            targets: ZebraUDPDiscovery.Targets(unicast: ["127.0.0.1", "kein-host"]),
            port: responder.port, rounds: 1, replyWindow: .milliseconds(300)
        ) { _, _ in count += 1 }
        #expect(count == 0)
        #expect(report.sent == 1)
        #expect(report.failed == 1)
        #expect(report.firstError?.hasPrefix("kein-host") == true)

        let empty = await ZebraUDPDiscovery.run(targets: ZebraUDPDiscovery.Targets(), replyWindow: .seconds(5)) { _, _ in }
        #expect(empty == ZebraUDPDiscovery.Report())
    }

    static func zebraOptions(port: Int, rawPort: Int = 9100) throws -> PrinterDiscovery.Options {
        var options = PrinterDiscovery.Options()
        options.networkHosts = ["127.0.0.1"]
        options.networkPorts = [rawPort]
        options.zebraDiscoveryPort = port
        options.zebraReplyWindow = .milliseconds(500)
        options.snmpPort = try TestTCPServer.unusedPort()
        options.snmpTimeout = .milliseconds(200)
        options.connectTimeout = .milliseconds(400)
        return options
    }

    @Test("PrinterDiscovery: Quelle „zebra“")
    func discoverySource() async throws {
        let responder = try Self.makeResponder(ZebraDiscoveryPacket.encode(zd620Reply))
        defer { responder.stop() }
        let discovery = PrinterDiscovery(options: try Self.zebraOptions(port: responder.port))
        var printers: [DiscoveredPrinter] = []
        for await printer in discovery.discover(sources: [.zebra], timeout: .seconds(5)) { printers.append(printer) }
        try #require(printers.count == 1)
        #expect(printers[0].source == .zebra)
        #expect(printers[0].descriptor == .tcp(host: "127.0.0.1", port: 9100))
        #expect(printers[0].name == "ZEBRA-ZD620")
        #expect(printers[0].details["reportedAddress"] == "10.62.13.19")
    }

    @Test("Unvollständige Antwort: Identifikation über ~HI (nur Zebra-Druckserver antworten)")
    func incompleteReply() async throws {
        let server = try TestTCPServer { client in
            let request = client.receive(until: Data("~HI".utf8), timeout: 3)
            if String(decoding: request, as: UTF8.self).contains("~HI") { client.send(sampleHostIdentification) }
        }
        defer { server.stop() }
        let responder = try Self.makeResponder([0x3A, 0x2C, 0x2E, 0x03])
        defer { responder.stop() }
        let discovery = PrinterDiscovery(options: try Self.zebraOptions(port: responder.port, rawPort: server.port))
        var printers: [DiscoveredPrinter] = []
        for await printer in discovery.discover(sources: [.zebra], timeout: .seconds(6)) { printers.append(printer) }
        try #require(printers.count == 1)
        #expect(printers[0].modelHint == "ZD421-203dpi")
        #expect(printers[0].name == "Zebra ZD421")
        #expect(printers[0].details["identifiedBy"] == "zebra+hi")
        #expect(printers[0].details["firmware"] == "V84.20.18Z")
    }

    @Test("Netzwerk-Scan und Zebra-Suche: ein Drucker, Zebra-Suche gewinnt")
    func combinedSources() async throws {
        // Offener Port ohne SNMP: der Scan meldet ein nicht identifiziertes Gerät …
        let server = try TestTCPServer { client in _ = client.receive(timeout: 1) }
        defer { server.stop() }
        // … die Zebra-Suche antwortet etwas später mit Modell und Seriennummer.
        let responder = try TestUDPResponder { request in
            guard [UInt8](request) == ZebraDiscoveryPacket.request else { return nil }
            Thread.sleep(forTimeInterval: 0.3)
            return Data(ZebraDiscoveryPacket.encode(zd620Reply))
        }
        defer { responder.stop() }
        let discovery = PrinterDiscovery(options: try Self.zebraOptions(port: responder.port, rawPort: server.port))
        var latest: [String: DiscoveredPrinter] = [:]
        var deliveries = 0
        for await printer in discovery.discover(sources: [.zebra, .network], timeout: .seconds(6)) {
            latest[printer.id] = printer
            deliveries += 1
        }
        #expect(latest.count == 1)
        #expect(deliveries <= 2)
        let printer = try #require(latest["tcp:127.0.0.1:\(server.port)"])
        #expect(printer.source == .zebra)
        #expect(printer.details["identifiedBy"]?.hasPrefix("zebra") == true)
        #expect(printer.details["printServerSerial"] == "10734759")
    }
}

/// Namen, die ein Test-Resolver gesehen hat.
private actor LockedNames {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

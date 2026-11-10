import Foundation
import Testing
@testable import LabelWerkTransport

@Suite("SubnetScanner")
struct SubnetScannerTests {
    @Test("Hostliste für /24, /23, /22")
    func hostsForSmallNetworks() {
        let c24 = SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "en0", address: "192.168.1.37", netmask: "255.255.255.0"))
        #expect(c24.count == 254)
        #expect(c24.first == "192.168.1.1")
        #expect(c24.last == "192.168.1.254")
        #expect(c24.contains("192.168.1.37"))
        #expect(!c24.contains("192.168.1.0"))
        #expect(!c24.contains("192.168.1.255"))

        let c23 = SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "en0", address: "10.1.3.200", netmask: "255.255.254.0"))
        #expect(c23.count == 510)
        #expect(c23.first == "10.1.2.1")
        #expect(c23.last == "10.1.3.254")

        let c22 = SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "en0", address: "172.16.5.9", netmask: "255.255.252.0"))
        #expect(c22.count == 1022)
        #expect(c22.first == "172.16.4.1")
        #expect(c22.last == "172.16.7.254")
    }

    @Test("Große Netze werden auf ein Fenster um die eigene Adresse begrenzt")
    func hostsForLargeNetworks() {
        let iface = NetworkInterfaceInfo(name: "en0", address: "10.20.30.40", netmask: "255.255.0.0")
        let hosts = SubnetScanner.hosts(in: iface)
        #expect(hosts.count == 1024)
        #expect(hosts.contains("10.20.30.40"))
        #expect(hosts == hosts.sorted { SubnetScanner.parseIPv4($0)! < SubnetScanner.parseIPv4($1)! })
        #expect(Set(hosts).count == hosts.count)

        let limited = SubnetScanner.hosts(in: iface, limit: 100)
        #expect(limited.count == 100)
        #expect(limited.contains("10.20.30.40"))

        // Eigene Adresse am Netzanfang: Fenster beginnt beim ersten Host.
        let edge = SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "en0", address: "10.20.0.1", netmask: "255.255.0.0"), limit: 10)
        #expect(edge.first == "10.20.0.1")
        #expect(edge.count == 10)
        // … und am Netzende.
        let top = SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "en0", address: "10.20.255.254", netmask: "255.255.0.0"), limit: 10)
        #expect(top.last == "10.20.255.254")
        #expect(top.count == 10)

        let tiny = SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "en0", address: "192.168.1.37", netmask: "255.255.255.0"), limit: 5)
        #expect(tiny == ["192.168.1.35", "192.168.1.36", "192.168.1.37", "192.168.1.38", "192.168.1.39"])
    }

    @Test("Sonderfälle: /31, /32, ungültige Angaben")
    func hostsEdgeCases() {
        #expect(SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "x", address: "10.0.0.4", netmask: "255.255.255.254")) == ["10.0.0.4", "10.0.0.5"])
        #expect(SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "x", address: "10.0.0.4", netmask: "255.255.255.255")) == ["10.0.0.4"])
        #expect(SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "x", address: "10.0.0.4", netmask: "255.255.255.0"), limit: 0).isEmpty)
        #expect(SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "x", address: "kaputt", netmask: "255.255.255.0")).isEmpty)
        #expect(SubnetScanner.hosts(in: NetworkInterfaceInfo(name: "x", address: "10.0.0.256", netmask: "255.255.255.0")).isEmpty)
    }

    @Test("Präfixlänge und CIDR")
    func prefix() {
        #expect(NetworkInterfaceInfo(name: "x", address: "192.168.1.37", netmask: "255.255.255.0").prefixLength == 24)
        #expect(NetworkInterfaceInfo(name: "x", address: "192.168.1.37", netmask: "255.255.255.0").networkCIDR == "192.168.1.0/24")
        #expect(NetworkInterfaceInfo(name: "x", address: "10.0.0.1", netmask: "255.255.252.0").prefixLength == 22)
        #expect(NetworkInterfaceInfo(name: "x", address: "10.0.0.1", netmask: "0.0.0.0").prefixLength == 0)
        #expect(NetworkInterfaceInfo(name: "x", address: "10.0.0.1", netmask: "255.255.255.255").prefixLength == 32)
        #expect(NetworkInterfaceInfo(name: "x", address: "10.0.0.1", netmask: "255.0.255.0").prefixLength == nil)
    }

    @Test("Lokale Schnittstellen enthalten kein Loopback")
    func localInterfaces() {
        let interfaces = SubnetScanner.localIPv4Interfaces()
        for iface in interfaces {
            #expect(!iface.address.hasPrefix("127."))
            #expect(SubnetScanner.parseIPv4(iface.address) != nil)
            #expect(SubnetScanner.parseIPv4(iface.netmask) != nil)
            #expect(!iface.name.isEmpty)
        }
    }

    @Test("Portsuche findet den lokalen Testserver")
    func scanFindsLocalServer() async throws {
        let server = try TestTCPServer { _ in }
        defer { server.stop() }
        let closedPort = try TestTCPServer.unusedPort()

        var found: [String] = []
        for await host in SubnetScanner.scan(hosts: ["127.0.0.1"], port: server.port, timeout: .milliseconds(500)) {
            found.append(host)
        }
        #expect(found == ["127.0.0.1"])

        var none: [String] = []
        for await host in SubnetScanner.scan(hosts: ["127.0.0.1"], port: closedPort, timeout: .milliseconds(300)) {
            none.append(host)
        }
        #expect(none.isEmpty)
        #expect(await SubnetScanner.isPortOpen(host: "127.0.0.1", port: server.port, timeout: .milliseconds(500)))
        #expect(await SubnetScanner.isPortOpen(host: "localhost", port: server.port, timeout: .milliseconds(500)))
        #expect(await !SubnetScanner.isPortOpen(host: "127.0.0.1", port: 0, timeout: .milliseconds(100)))
    }

    @Test("Viele Hosts mit begrenzter Parallelität")
    func scanManyHosts() async throws {
        let server = try TestTCPServer { _ in }
        defer { server.stop() }
        // 127.0.0.0/8 ist vollständig Loopback: nur 127.0.0.1 … 127.0.0.40 – alle lauschen auf
        // INADDR_LOOPBACK? Nein: der Server ist an 127.0.0.1 gebunden, die übrigen lehnen ab.
        let hosts = (1...40).map { "127.0.0.\($0)" }
        let (found, elapsed) = await measure { () async -> [String] in
            var result: [String] = []
            for await host in SubnetScanner.scan(hosts: hosts, port: server.port, timeout: .milliseconds(300), maxConcurrent: 8) {
                result.append(host)
            }
            return result
        }
        #expect(found == ["127.0.0.1"])
        #expect(elapsed < .seconds(5))
    }

    @Test("Abbruch beendet den Suchstrom")
    func scanCancellation() async throws {
        // Viele nicht antwortende Ziele (Dokumentationsnetz, wird verworfen oder abgelehnt).
        let hosts = (1...200).map { "192.0.2.\($0)" }
        let task = Task { () -> Int in
            var count = 0
            for await _ in SubnetScanner.scan(hosts: hosts, port: 9100, timeout: .seconds(3), maxConcurrent: 4) {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        _ = await task.value
        #expect(start.duration(to: .now) < .seconds(2))
    }
}

@Suite("PrinterDiscovery")
struct PrinterDiscoveryTests {
    /// Server, der wie ein Zebra-Drucker auf `~HI` antwortet.
    static func makeZebraServer() throws -> TestTCPServer {
        try TestTCPServer { client in
            let request = client.receive(until: Data("~HI".utf8), timeout: 3)
            if String(decoding: request, as: UTF8.self).contains("~HI") {
                client.send(sampleHostIdentification)
            }
        }
    }

    static func networkOptions(port: Int, hosts: [String]) throws -> PrinterDiscovery.Options {
        var options = PrinterDiscovery.Options()
        options.networkHosts = hosts
        options.networkPorts = [port]
        options.snmpPort = try TestTCPServer.unusedPort() // UDP-Port ohne Dienst
        options.connectTimeout = .milliseconds(400)
        return options
    }

    @Test("Netzwerksuche über vorgegebene Hosts endet vor dem Timeout")
    func networkOnly() async throws {
        let server = try Self.makeZebraServer()
        defer { server.stop() }
        let discovery = PrinterDiscovery(options: try Self.networkOptions(port: server.port, hosts: ["127.0.0.1", "127.0.0.1"]))

        let (printers, elapsed) = await measure { () async -> [DiscoveredPrinter] in
            var result: [DiscoveredPrinter] = []
            for await printer in discovery.discover(sources: [.network], timeout: .seconds(10)) {
                result.append(printer)
            }
            return result
        }
        #expect(elapsed < .seconds(6))
        try #require(printers.count == 1)
        let printer = printers[0]
        #expect(printer.descriptor == .tcp(host: "127.0.0.1", port: server.port))
        #expect(printer.id == "tcp:127.0.0.1:\(server.port)")
        #expect(printer.source == .network)
        #expect(printer.modelHint == "ZD421-203dpi")
        #expect(printer.name == "Zebra ZD421")
        #expect(printer.details["firmware"] == "V84.20.18Z")
        #expect(printer.details["dotsPerMM"] == "8")
        #expect(printer.details["identifiedBy"] == "hi")
    }

    @Test("SNMP identifiziert gefahrlos; Nicht-Zebra-Geräte erhalten kein ~HI")
    func snmpIdentification() async throws {
        let receivedHI = LockedValue(false)
        let server = try TestTCPServer { client in
            let request = client.receive(until: Data("~HI".utf8), timeout: 1)
            if String(decoding: request, as: UTF8.self).contains("~HI") {
                receivedHI.set(true)
                client.send(sampleHostIdentification)
            }
        }
        defer { server.stop() }

        // 1. Fremder Drucker laut SNMP → ausgeblendet, kein ~HI.
        let foreign = try TestUDPResponder { request in
            SNMPTests.response(to: request, values: [
                SNMPProbe.sysDescrOID: "HP ETHERNET MULTI-ENVIRONMENT,ROM none,JETDIRECT,JD153",
                SNMPProbe.sysNameOID: "NPI1A2B3C",
            ])
        }
        defer { foreign.stop() }
        var options = try Self.networkOptions(port: server.port, hosts: ["127.0.0.1"])
        options.snmpPort = foreign.port
        var results: [DiscoveredPrinter] = []
        for await printer in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .seconds(8)) {
            results.append(printer)
        }
        #expect(results.isEmpty)
        #expect(receivedHI.value == false)

        // Mit includeNonZebraNetworkDevices erscheint er – weiterhin ohne ~HI.
        options.includeNonZebraNetworkDevices = true
        results = []
        for await printer in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .seconds(8)) {
            results.append(printer)
        }
        #expect(results.count == 1)
        #expect(results.first?.name == "NPI1A2B3C")
        #expect(results.first?.modelHint == nil)
        #expect(receivedHI.value == false)

        // 2. Zebra laut SNMP → Name aus sysName, Modell aus sysDescr, Firmware per ~HI.
        let zebra = try TestUDPResponder { request in
            SNMPTests.response(to: request, values: [
                SNMPProbe.sysDescrOID: "Zebra Technologies ZTC ZD421-203dpi ZPL",
                SNMPProbe.sysNameOID: "Lager-Etiketten",
            ])
        }
        defer { zebra.stop() }
        options.snmpPort = zebra.port
        options.includeNonZebraNetworkDevices = false
        results = []
        for await printer in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .seconds(8)) {
            results.append(printer)
        }
        try #require(results.count == 1)
        #expect(results[0].name == "Lager-Etiketten")
        #expect(results[0].modelHint == "ZD421-203dpi")
        #expect(results[0].details["sysDescr"] == "Zebra Technologies ZTC ZD421-203dpi ZPL")
        #expect(results[0].details["identifiedBy"] == "snmp+hi")
        #expect(receivedHI.value == true)
    }

    @Test("Nicht identifizierbare Geräte: einstellbar")
    func unidentifiedDevices() async throws {
        let silent = try TestTCPServer { client in _ = client.receive(timeout: 1) }
        defer { silent.stop() }
        var options = try Self.networkOptions(port: silent.port, hosts: ["127.0.0.1"])
        options.hostIdentificationTimeout = .milliseconds(300)
        var results: [DiscoveredPrinter] = []
        for await printer in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .seconds(8)) {
            results.append(printer)
        }
        #expect(results.count == 1)
        #expect(results.first?.name == "127.0.0.1")
        #expect(results.first?.modelHint == nil)

        options.includeUnidentifiedNetworkDevices = false
        results = []
        for await printer in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .seconds(8)) {
            results.append(printer)
        }
        #expect(results.isEmpty)

        // Ohne Identifikation: kein SNMP, kein ~HI.
        options.identifyNetworkPrinters = false
        options.includeUnidentifiedNetworkDevices = false
        results = []
        for await printer in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .seconds(8)) {
            results.append(printer)
        }
        #expect(results.count == 1)
    }

    @Test("Timeout beendet die Suche")
    func timeoutEndsDiscovery() async throws {
        // Volle Annahme-Warteschlange: weitere Verbindungsversuche hängen bis zum connectTimeout.
        let server = try TestTCPServer(backlog: 0, accepts: false) { _ in }
        defer { server.stop() }
        let filler = TCPConnection(host: "127.0.0.1", port: server.port, connectTimeout: .milliseconds(500))
        try await filler.open()
        defer { Task { await filler.close() } }

        var options = PrinterDiscovery.Options()
        options.networkHosts = ["127.0.0.1"]
        options.networkPorts = [server.port]
        options.connectTimeout = .seconds(5)
        let (count, elapsed) = await measure { () async -> Int in
            var count = 0
            for await _ in PrinterDiscovery(options: options).discover(sources: [.network], timeout: .milliseconds(600)) {
                count += 1
            }
            return count
        }
        #expect(count == 0)
        #expect(elapsed >= .milliseconds(550))
        #expect(elapsed < .seconds(3))
    }

    @Test("Ohne Quellen endet der Strom sofort")
    func emptySources() async {
        let (count, elapsed) = await measure { () async -> Int in
            var count = 0
            for await _ in PrinterDiscovery().discover(sources: [], timeout: .seconds(5)) { count += 1 }
            return count
        }
        #expect(count == 0)
        #expect(elapsed < .seconds(1))
    }

    @Test("Quellen ohne Unterstützung auf dieser Plattform enden sofort")
    func platformSources() async {
        #if !os(macOS)
        let (count, elapsed) = await measure { () async -> Int in
            var count = 0
            for await _ in PrinterDiscovery().discover(sources: [.usb, .bluetooth, .ble], timeout: .seconds(5)) { count += 1 }
            return count
        }
        #expect(count == 0)
        #expect(elapsed < .seconds(1))
        #expect(!DiscoverySource.usb.isAvailableOnThisPlatform)
        #endif
        #expect(DiscoverySource.network.isAvailableOnThisPlatform)
        #expect(DiscoverySource.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.systemImage.isEmpty })
    }

    @Test("Deduplizierung nach id")
    func sinkDeduplicates() async {
        let (stream, continuation) = AsyncStream<DiscoveredPrinter>.makeStream()
        let sink = DiscoverySink(continuation)
        let first = DiscoveredPrinter(name: "A", descriptor: .tcp(host: "10.0.0.1", port: 9100), source: .bonjour)
        let second = DiscoveredPrinter(name: "B", descriptor: .tcp(host: "10.0.0.1", port: 9100), source: .network)
        let third = DiscoveredPrinter(name: "C", descriptor: .cupsQueue(name: "Q"), source: .cups)
        #expect(sink.emit(first))
        #expect(!sink.emit(second))
        #expect(sink.emit(third))
        sink.finish()
        #expect(!sink.emit(DiscoveredPrinter(name: "D", descriptor: .virtual(id: "x"), source: .cups)))
        var names: [String] = []
        for await printer in stream { names.append(printer.name) }
        #expect(names == ["A", "C"])
    }

    @Test("DiscoveredPrinter: Kennung und Codable")
    func discoveredPrinterCodable() throws {
        let printer = DiscoveredPrinter(
            name: "Zebra ZD421", modelHint: "ZD421-203dpi",
            descriptor: .usb(USBDeviceIdentifier(productID: 0x0181, serialNumber: "S1")),
            source: .usb, details: ["serialNumber": "S1"]
        )
        #expect(printer.id == "usb:0a5f:0181:S1")
        let decoded = try JSONDecoder().decode(DiscoveredPrinter.self, from: try JSONEncoder().encode(printer))
        #expect(decoded == printer)
    }

    @Test("~HI-Antworten auswerten")
    func hostIdentificationParsing() {
        let parsed = HostIdentificationProbe.parse(sampleHostIdentification)
        #expect(parsed?.model == "ZD421-203dpi")
        #expect(parsed?.firmware == "V84.20.18Z")
        #expect(parsed?.dotsPerMM == 8)
        #expect(parsed?.memory == "8192KB")
        #expect(parsed?.options == nil)
        let withOptions = HostIdentificationProbe.parse(Data("\u{2}ZT410-300dpi,V75.20.01Z,12,4104KB,D,X\u{3}".utf8))
        #expect(withOptions?.dotsPerMM == 12)
        #expect(withOptions?.options == "D,X")
        #expect(HostIdentificationProbe.parse(Data()) == nil)
        #expect(HostIdentificationProbe.parse(Data([0x02, 0x03])) == nil)
        #expect(HostIdentificationProbe.parse(Data("ZD620-203dpi,V1,8,1KB".utf8))?.model == "ZD620-203dpi")
        #expect(HostIdentificationProbe.isComplete(Data([0x02, 0x41, 0x03])))
        #expect(!HostIdentificationProbe.isComplete(Data([0x02, 0x41])))
    }

    @Test("Bonjour: avahi-browse-Ausgabe und Zuordnung")
    func avahiParsing() throws {
        let text = #"""
        +;eth0;IPv4;Zebra\032ZD421\032\091Lager\093;_pdl-datastream._tcp;local
        =;eth0;IPv6;Zebra\032ZD421\032\091Lager\093;_pdl-datastream._tcp;local;ZD421.local;fe80::1;9100;"ty=Zebra ZD421" "product=(ZTC ZD421-203dpi ZPL)"
        =;eth0;IPv4;Zebra\032ZD421\032\091Lager\093;_pdl-datastream._tcp;local;ZD421.local;192.168.1.20;9100;"ty=Zebra ZD421" "product=(ZTC ZD421-203dpi ZPL)" "note=Halle\0592" "usb_MFG=Zebra Technologies"
        =;eth0;IPv4;HP\032LaserJet;_ipp._tcp;local;hp.local;192.168.1.30;631;"ty=HP LaserJet Pro M404" "rp=ipp/print"
        =;eth0;IPv4;ZTC\032GK420d;_printer._tcp;local;gk.local;192.168.1.40;515;"rp=queue"
        """#
        let services = AvahiBrowseParser.parse(text)
        #expect(services.count == 3)
        let zd = try #require(services.first { $0.type == "_pdl-datastream._tcp" })
        #expect(zd.name == "Zebra ZD421 [Lager]")
        #expect(zd.host == "192.168.1.20")
        #expect(zd.port == 9100)
        #expect(zd.txt["product"] == "(ZTC ZD421-203dpi ZPL)")
        #expect(zd.txt["note"] == "Halle;2")
        #expect(zd.looksLikeZebra)
        #expect(zd.modelHint == "ZTC ZD421-203dpi ZPL")
        let printer = zd.makeDiscoveredPrinter()
        #expect(printer.descriptor == .tcp(host: "192.168.1.20", port: 9100))
        #expect(printer.source == .bonjour)
        #expect(printer.name == "Zebra ZD421 [Lager]")

        let hp = try #require(services.first { $0.type == "_ipp._tcp" })
        #expect(!hp.looksLikeZebra)

        let lpd = try #require(services.first { $0.type == "_printer._tcp" })
        #expect(lpd.looksLikeZebra)
        // LPD/IPP-Dienste werden auf den Rohdatenport 9100 abgebildet.
        #expect(lpd.makeDiscoveredPrinter().descriptor == .tcp(host: "192.168.1.40", port: 9100))
        #expect(lpd.makeDiscoveredPrinter().details["servicePort"] == "515")

        #expect(AvahiBrowseParser.unescape(#"A\032B\092C\.D"#) == "A B\\C.D")
        #expect(AvahiBrowseParser.parseTXT(#""a=1" "b=x \"y\"" "flag""#) == ["a": "1", "b": "x \"y\"", "flag": ""])
    }
}

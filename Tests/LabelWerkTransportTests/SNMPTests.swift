import Foundation
import Testing
@testable import LabelWerkTransport

@Suite("SNMPProbe")
struct SNMPTests {
    /// Baut eine SNMPv1-`GetResponse` passend zu `request` (gleiche Request-ID).
    static func response(to request: Data, values: [String: String], community: String = "public") -> Data? {
        guard let id = requestID(of: request) else { return nil }
        return makeResponse(requestID: id, values: values, community: community)
    }

    /// Request-ID eines SNMP-`GetRequest`.
    static func requestID(of request: Data) -> Int64? {
        let bytes = [UInt8](request)
        guard let message = SNMPProbe.readTLV(bytes, at: 0),
              let version = SNMPProbe.readTLV(bytes, at: message.valueStart),
              let communityTLV = SNMPProbe.readTLV(bytes, at: version.end),
              let pdu = SNMPProbe.readTLV(bytes, at: communityTLV.end),
              let requestID = SNMPProbe.readTLV(bytes, at: pdu.valueStart)
        else { return nil }
        return SNMPProbe.decodeInteger(Array(bytes[requestID.valueStart..<requestID.end]))
    }

    /// `true`, wenn das `GetRequest` die OID `oid` abfragt.
    static func request(_ request: Data, asksFor oid: String) -> Bool {
        guard let encoded = SNMPProbe.encodeOID(oid) else { return false }
        // OID-TLV (Tag 0x06, Länge, Inhalt) – eindeutig innerhalb der Varbind-Liste.
        let needle = Data([0x06] + SNMPProbe.encodeLength(encoded.count) + encoded)
        return request.range(of: needle) != nil
    }

    static func makeResponse(requestID: Int64, values: [String: String], community: String = "public", errorStatus: UInt8 = 0) -> Data {
        func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] { [tag] + SNMPProbe.encodeLength(value.count) + value }
        var varbinds: [UInt8] = []
        for (oid, value) in values.sorted(by: { $0.key < $1.key }) {
            varbinds += tlv(0x30, tlv(0x06, SNMPProbe.encodeOID(oid)!) + tlv(0x04, Array(value.utf8)))
        }
        let pdu = tlv(0x02, SNMPProbe.encodeInteger(requestID)) + tlv(0x02, [errorStatus]) + tlv(0x02, [0]) + tlv(0x30, varbinds)
        let message = tlv(0x02, [0]) + tlv(0x04, Array(community.utf8)) + tlv(0xA2, pdu)
        return Data(tlv(0x30, message))
    }

    @Test("GetRequest wird byte-genau kodiert")
    func encodeRequest() throws {
        let request = try #require(SNMPProbe.encodeGetRequest(community: "public", requestID: 0x1234, oids: [SNMPProbe.sysDescrOID]))
        let expected: [UInt8] = [
            0x30, 0x27,
            0x02, 0x01, 0x00,
            0x04, 0x06, 0x70, 0x75, 0x62, 0x6C, 0x69, 0x63,
            0xA0, 0x1A,
            0x02, 0x02, 0x12, 0x34,
            0x02, 0x01, 0x00,
            0x02, 0x01, 0x00,
            0x30, 0x0E,
            0x30, 0x0C,
            0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00,
            0x05, 0x00,
        ]
        #expect([UInt8](request) == expected)
    }

    @Test("BER-Grundbausteine")
    func berPrimitives() {
        #expect(SNMPProbe.encodeLength(5) == [5])
        #expect(SNMPProbe.encodeLength(200) == [0x81, 200])
        #expect(SNMPProbe.encodeLength(0x1234) == [0x82, 0x12, 0x34])
        #expect(SNMPProbe.encodeInteger(0) == [0])
        #expect(SNMPProbe.encodeInteger(127) == [0x7F])
        #expect(SNMPProbe.encodeInteger(128) == [0x00, 0x80])
        #expect(SNMPProbe.encodeInteger(-1) == [0xFF])
        #expect(SNMPProbe.encodeInteger(Int64(Int32.max)) == [0x7F, 0xFF, 0xFF, 0xFF])
        for value: Int64 in [0, 1, 127, 128, 255, 256, -1, -128, -129, 65_535, Int64(Int32.max), Int64(Int32.min)] {
            #expect(SNMPProbe.decodeInteger(SNMPProbe.encodeInteger(value)) == value)
        }
        #expect(SNMPProbe.encodeOID("1.3.6.1.4.1.10642.1.1.0") == [0x2B, 0x06, 0x01, 0x04, 0x01, 0xD3, 0x12, 0x01, 0x01, 0x00])
        #expect(SNMPProbe.decodeOID([0x2B, 0x06, 0x01, 0x04, 0x01, 0xD3, 0x12, 0x01, 0x01, 0x00]) == "1.3.6.1.4.1.10642.1.1.0")
        #expect(SNMPProbe.encodeOID("kaputt") == nil)
        #expect(SNMPProbe.encodeOID("1") == nil)
    }

    @Test("GetResponse auswerten")
    func decodeResponse() {
        let response = Self.makeResponse(requestID: 42, values: [
            SNMPProbe.sysDescrOID: "ZTC ZD421-203dpi ZPL",
            SNMPProbe.sysNameOID: "Lager",
        ])
        let values = SNMPProbe.decodeGetResponse(response, expectedRequestID: 42)
        #expect(values == [SNMPProbe.sysDescrOID: "ZTC ZD421-203dpi ZPL", SNMPProbe.sysNameOID: "Lager"])
        #expect(SNMPProbe.decodeGetResponse(response, expectedRequestID: 43) == nil)
        #expect(SNMPProbe.decodeGetResponse(Self.makeResponse(requestID: 1, values: [:], errorStatus: 2), expectedRequestID: 1) == [:])
        #expect(SNMPProbe.decodeGetResponse(Data([0x30, 0x05, 0x02])) == nil)
        #expect(SNMPProbe.decodeGetResponse(Data()) == nil)
        // Abgeschnittene Antworten führen nie zum Absturz.
        for length in 0..<response.count {
            _ = SNMPProbe.decodeGetResponse(response.prefix(length))
        }
    }

    @Test("Abfrage über UDP")
    func queryOverUDP() async throws {
        let responder = try TestUDPResponder { request in
            Self.response(to: request, values: [SNMPProbe.sysDescrOID: "ZTC ZT410-203dpi ZPL", SNMPProbe.sysNameOID: "ZT410"])
        }
        defer { responder.stop() }
        let values = await SNMPProbe.query(host: "127.0.0.1", port: responder.port, timeout: .seconds(2))
        #expect(values?[SNMPProbe.sysDescrOID] == "ZTC ZT410-203dpi ZPL")
        #expect(values?[SNMPProbe.sysNameOID] == "ZT410")
    }

    @Test("Keine Antwort → nil, rasch")
    func queryWithoutService() async throws {
        let silent = try TestUDPResponder { _ in nil }
        defer { silent.stop() }
        let (values, elapsed) = await measure { await SNMPProbe.query(host: "127.0.0.1", port: silent.port, timeout: .milliseconds(300)) }
        #expect(values == nil)
        #expect(elapsed < .seconds(1))

        let closedPort = try TestTCPServer.unusedPort()
        let (refused, refusedElapsed) = await measure { await SNMPProbe.query(host: "127.0.0.1", port: closedPort, timeout: .seconds(2)) }
        #expect(refused == nil)
        #expect(refusedElapsed < .seconds(2.5))
        #expect(await SNMPProbe.query(host: "kein-numerischer-host", timeout: .milliseconds(100)) == nil)
    }
}

@Suite("IncomingDataBuffer")
struct IncomingDataBufferTests {
    @Test("Vorhandene Daten werden sofort geliefert")
    func immediate() async throws {
        let buffer = IncomingDataBuffer()
        buffer.append(Data("AB".utf8))
        buffer.append(Data("CD".utf8))
        #expect(buffer.bufferedByteCount == 4)
        #expect(try await buffer.read(timeout: .zero) == Data("ABCD".utf8))
        #expect(try await buffer.read(timeout: .zero).isEmpty)
    }

    @Test("Wartet auf eintreffende Daten")
    func waitsForData() async throws {
        let buffer = IncomingDataBuffer()
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            buffer.append(Data("XYZ".utf8))
        }
        let (data, elapsed) = try await measure { try await buffer.read(timeout: .seconds(3)) }
        #expect(data == Data("XYZ".utf8))
        #expect(elapsed < .seconds(1))
    }

    @Test("Zeitablauf liefert leere Daten")
    func timeout() async throws {
        let buffer = IncomingDataBuffer()
        let (data, elapsed) = try await measure { try await buffer.read(timeout: .milliseconds(150)) }
        #expect(data.isEmpty)
        #expect(elapsed >= .milliseconds(140))
        #expect(elapsed < .seconds(1))
    }

    @Test("Nach fail() erst Restdaten, dann Fehler; reset() setzt zurück")
    func failure() async throws {
        let buffer = IncomingDataBuffer()
        buffer.append(Data("REST".utf8))
        buffer.fail(.closedByPeer)
        #expect(try await buffer.read(timeout: .seconds(1)) == Data("REST".utf8))
        await #expect(throws: TransportError.closedByPeer) { try await buffer.read(timeout: .seconds(1)) }
        buffer.reset()
        #expect(try await buffer.read(timeout: .milliseconds(10)).isEmpty)
    }

    @Test("fail() weckt wartende Leser")
    func failWakesReaders() async throws {
        let buffer = IncomingDataBuffer()
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            buffer.fail(.closedByPeer)
        }
        let start = ContinuousClock.now
        await #expect(throws: TransportError.closedByPeer) { try await buffer.read(timeout: .seconds(3)) }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("Abbruch beendet das Warten")
    func cancellation() async throws {
        let buffer = IncomingDataBuffer()
        let reader = Task { try await buffer.read(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        reader.cancel()
        let result = await reader.result
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("Kapazitätsgrenze verwirft älteste Bytes")
    func capacity() async throws {
        let buffer = IncomingDataBuffer(capacity: 4)
        buffer.append(Data("123456".utf8))
        #expect(try await buffer.read(timeout: .zero) == Data("3456".utf8))
    }

    @Test("Viele parallele Leser und Schreiber")
    func concurrency() async throws {
        let buffer = IncomingDataBuffer()
        let total = await withTaskGroup(of: Int.self) { group in
            for index in 0..<50 {
                group.addTask {
                    buffer.append(Data(repeating: UInt8(index), count: 10))
                    return 0
                }
                group.addTask {
                    (try? await buffer.read(timeout: .milliseconds(200)).count) ?? 0
                }
            }
            var sum = 0
            for await count in group { sum += count }
            return sum
        }
        let rest = try await buffer.read(timeout: .zero).count
        #expect(total + rest == 500)
    }
}

@Suite("ConnectionFactory", .serialized)
struct ConnectionFactoryTests {
    /// Minimale Testverbindung.
    final class StubConnection: PrinterConnection {
        let descriptor: ConnectionDescriptor
        init(id: String) { descriptor = .virtual(id: id) }
        var isOpen: Bool { get async { true } }
        func open() async throws {}
        func close() async {}
        func write(_ data: Data) async throws {}
        func read(timeout: Duration) async throws -> Data { Data("pong".utf8) }
    }

    @Test("Erzeugt passende Verbindungen")
    func makesConnections() throws {
        let tcp = try ConnectionFactory.make(.tcp(host: "192.168.1.20", port: 6101))
        #expect(tcp is TCPConnection)
        #expect(tcp.descriptor == .tcp(host: "192.168.1.20", port: 6101))
        let cups = try ConnectionFactory.make(.cupsQueue(name: "ZD421"))
        #expect(cups is CUPSQueueConnection)
        #expect(cups.descriptor == .cupsQueue(name: "ZD421"))
        #expect(throws: TransportError.self) { try ConnectionFactory.make(.tcp(host: "", port: 9100)) }
        #expect(throws: TransportError.self) { try ConnectionFactory.make(.tcp(host: "h", port: 70000)) }
        #if !os(macOS)
        #expect(throws: TransportError.self) { try ConnectionFactory.make(.usb(USBDeviceIdentifier(productID: 1))) }
        #expect(throws: TransportError.self) { try ConnectionFactory.make(.bluetooth(address: "AA-BB-CC-DD-EE-FF", name: nil)) }
        #expect(throws: TransportError.self) { try ConnectionFactory.make(.ble(identifier: UUID().uuidString, name: nil)) }
        #expect(ConnectionFactory.supportedKinds == [.tcp, .cupsQueue, .virtual])
        #else
        #expect(ConnectionFactory.supportedKinds.isSuperset(of: [.tcp, .cupsQueue, .virtual, .usb, .bluetooth, .ble]))
        #endif
    }

    @Test("Registrierung virtueller Drucker (threadsicher)")
    func virtualRegistry() async throws {
        ConnectionFactory.unregisterVirtualFactory()
        #expect(!ConnectionFactory.hasVirtualFactory)
        #expect(throws: TransportError.self) { try ConnectionFactory.make(.virtual(id: "demo")) }

        ConnectionFactory.registerVirtualFactory { id in StubConnection(id: id) }
        #expect(ConnectionFactory.hasVirtualFactory)
        let connection = try ConnectionFactory.make(.virtual(id: "demo"))
        #expect(connection.descriptor == .virtual(id: "demo"))
        #expect(try await connection.request(Data("ping".utf8), timeout: .seconds(1), isComplete: { $0.count >= 4 }) == Data("pong".utf8))

        // Gleichzeitiges Registrieren und Erzeugen aus vielen Tasks.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    if index % 10 == 0 {
                        ConnectionFactory.registerVirtualFactory { id in StubConnection(id: id) }
                    }
                    let made = try? ConnectionFactory.make(.virtual(id: "v\(index)"))
                    #expect(made?.descriptor == .virtual(id: "v\(index)"))
                }
            }
        }
        ConnectionFactory.unregisterVirtualFactory()
        #expect(!ConnectionFactory.hasVirtualFactory)
    }
}

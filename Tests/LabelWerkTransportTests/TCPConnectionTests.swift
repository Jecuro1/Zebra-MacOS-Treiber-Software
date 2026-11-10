import Foundation
import Testing
@testable import LabelWerkTransport

@Suite("TCPConnection")
struct TCPConnectionTests {
    @Test("Öffnen, Schreiben und Lesen (Echo)")
    func openWriteRead() async throws {
        let server = try TestTCPServer { client in
            while let data = client.receive(timeout: 2) {
                if !data.isEmpty { client.send(data) }
            }
        }
        defer { server.stop() }

        let connection = TCPConnection(host: "127.0.0.1", port: server.port, connectTimeout: .seconds(2))
        #expect(await connection.isOpen == false)
        try await connection.open()
        #expect(await connection.isOpen)
        #expect(connection.descriptor == .tcp(host: "127.0.0.1", port: server.port))

        try await connection.write("^XA^FDHallo^FS^XZ")
        var received = Data()
        let deadline = ContinuousClock.now + .seconds(2)
        while received.count < 17, ContinuousClock.now < deadline {
            received.append(try await connection.read(timeout: .milliseconds(500)))
        }
        #expect(String(decoding: received, as: UTF8.self) == "^XA^FDHallo^FS^XZ")

        // open() ist idempotent.
        try await connection.open()
        #expect(await connection.isOpen)

        await connection.close()
        #expect(await connection.isOpen == false)
        await connection.close() // idempotent
    }

    @Test("read() liefert leere Daten nach Ablauf der Frist")
    func readTimeoutReturnsEmpty() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("ENDE".utf8), timeout: 3)
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let (data, elapsed) = try await measure { try await connection.read(timeout: .milliseconds(200)) }
        #expect(data.isEmpty)
        #expect(elapsed >= .milliseconds(180))
        #expect(elapsed < .seconds(1.5))
        try await connection.write("ENDE")
        await connection.close()
    }

    @Test("request() endet, sobald isComplete erfüllt ist")
    func requestIsComplete() async throws {
        let server = try TestTCPServer { client in
            let request = client.receive(until: Data("~HI".utf8), timeout: 3)
            guard String(decoding: request, as: UTF8.self).contains("~HI") else { return }
            // Antwort in zwei Teilen, danach würde noch mehr kommen.
            client.send("\u{2}ZD421-203dpi,")
            Thread.sleep(forTimeInterval: 0.1)
            client.send("V84.20.18Z,8,8192KB\u{3}")
            Thread.sleep(forTimeInterval: 1.5)
            client.send("SPÄTER")
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let (response, elapsed) = try await measure {
            try await connection.request(
                Data("~HI\r\n".utf8), timeout: .seconds(3), idleTimeout: .seconds(1),
                isComplete: { $0.contains(0x03) }
            )
        }
        #expect(String(decoding: response, as: UTF8.self) == "\u{2}ZD421-203dpi,V84.20.18Z,8,8192KB\u{3}")
        #expect(elapsed < .seconds(1))
        await connection.close()
    }

    @Test("request() endet nach idleTimeout ohne weitere Daten")
    func requestIdleTimeout() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("~HS".utf8), timeout: 3)
            client.send("TEIL1")
            Thread.sleep(forTimeInterval: 0.05)
            client.send("TEIL2")
            // Danach Funkstille, Verbindung bleibt offen.
            _ = client.receive(until: Data("ENDE".utf8), timeout: 5)
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let (response, elapsed) = try await measure {
            try await connection.request(Data("~HS".utf8), timeout: .seconds(4), idleTimeout: .milliseconds(300))
        }
        #expect(String(decoding: response, as: UTF8.self) == "TEIL1TEIL2")
        #expect(elapsed >= .milliseconds(300))
        #expect(elapsed < .seconds(2))
        try await connection.write("ENDE")
        await connection.close()
    }

    @Test("request() liefert leere Daten nach Gesamt-Timeout ohne Antwort")
    func requestTimeoutWithoutResponse() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("ENDE".utf8), timeout: 5)
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let (response, elapsed) = try await measure {
            try await connection.request(Data("~HQES".utf8), timeout: .milliseconds(400), idleTimeout: .milliseconds(100))
        }
        #expect(response.isEmpty)
        #expect(elapsed >= .milliseconds(380))
        #expect(elapsed < .seconds(2))
        try await connection.write("ENDE")
        await connection.close()
    }

    @Test("request() begrenzt fortlaufende Antworten auf timeout")
    func requestTimeoutWithContinuousData() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("GO".utf8), timeout: 3)
            for _ in 0..<40 {
                guard client.send(Data("x".utf8)) else { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let (response, elapsed) = try await measure {
            try await connection.request(Data("GO".utf8), timeout: .milliseconds(500), idleTimeout: .milliseconds(300))
        }
        #expect(!response.isEmpty)
        #expect(response.count < 40)
        #expect(elapsed < .seconds(1.2))
        await connection.close()
    }

    @Test("Verbindungsende durch den Drucker → closedByPeer")
    func peerClose() async throws {
        let server = try TestTCPServer { client in
            client.send("BYE")
            // Handler endet → Server schließt die Verbindung.
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()

        var received = Data()
        var caught: TransportError?
        for _ in 0..<20 {
            do {
                received.append(try await connection.read(timeout: .milliseconds(300)))
            } catch let error as TransportError {
                caught = error
                break
            }
        }
        #expect(String(decoding: received, as: UTF8.self) == "BYE")
        #expect(caught == .closedByPeer)
        #expect(await connection.isOpen == false)
        await #expect(throws: TransportError.closedByPeer) {
            try await connection.write("^XA^XZ")
        }
        // Erneutes Öffnen baut eine neue Verbindung auf.
        try await connection.open()
        #expect(await connection.isOpen)
        await connection.close()
    }

    @Test("request() liefert bereits empfangene Daten, wenn der Drucker danach trennt")
    func requestReturnsDataBeforePeerClose() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("?".utf8), timeout: 3)
            client.send("ANTWORT")
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let response = try await connection.request(Data("?".utf8), timeout: .seconds(3), idleTimeout: .seconds(2))
        #expect(String(decoding: response, as: UTF8.self) == "ANTWORT")
        await connection.close()
    }

    @Test("Verbindung abgelehnt → connectionFailed")
    func connectionRefused() async throws {
        let port = try TestTCPServer.unusedPort()
        let connection = TCPConnection(host: "127.0.0.1", port: port, connectTimeout: .seconds(2))
        do {
            try await connection.open()
            Issue.record("open() hätte fehlschlagen müssen")
        } catch let error as TransportError {
            guard case .connectionFailed(let detail) = error else {
                Issue.record("Unerwarteter Fehler: \(error)")
                return
            }
            #expect(!detail.isEmpty)
            #expect(error.errorDescription?.hasPrefix("Verbindung zum Drucker fehlgeschlagen") == true)
        }
        #expect(await connection.isOpen == false)
    }

    @Test("Zeitüberschreitung beim Verbindungsaufbau (volle Annahme-Warteschlange)",
          .enabled(if: TestPlatform.hasLinuxListenBacklogSemantics, "Benötigt das Linux-Verhalten von listen(…, 0)"))
    func connectTimeoutDeterministic() async throws {
        // Ein Server mit Backlog 0, der nie annimmt: Nach der ersten Verbindung verwirft der
        // Kernel weitere SYNs, der Verbindungsaufbau bleibt hängen.
        let server = try TestTCPServer(backlog: 0, accepts: false) { _ in }
        defer { server.stop() }
        var fillers: [TCPConnection] = []
        var timedOut = false
        for _ in 0..<4 {
            let connection = TCPConnection(host: "127.0.0.1", port: server.port, connectTimeout: .milliseconds(300))
            let start = ContinuousClock.now
            do {
                try await connection.open()
                fillers.append(connection)
            } catch let error as TransportError {
                let elapsed = start.duration(to: .now)
                #expect(error == .timeout)
                #expect(elapsed >= .milliseconds(250))
                #expect(elapsed < .seconds(2))
                timedOut = true
                break
            }
        }
        #expect(timedOut)
        for filler in fillers { await filler.close() }
    }

    @Test("Nicht routbare Adresse: Zeitüberschreitung oder Fehler, jedenfalls rasch")
    func connectTimeoutNonRoutable() async throws {
        let connection = TCPConnection(host: "10.255.255.1", port: 9100, connectTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        do {
            try await connection.open()
            await connection.close()
            Issue.record("Verbindung zu 10.255.255.1 sollte nicht gelingen")
        } catch let error as TransportError {
            switch error {
            case .timeout, .connectionFailed: break
            default: Issue.record("Unerwarteter Fehler: \(error)")
            }
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test("Ungültige Angaben werden abgewiesen")
    func invalidTargets() async throws {
        let badPort = TCPConnection(host: "127.0.0.1", port: 0)
        await #expect(throws: TransportError.self) { try await badPort.open() }
        let badHost = TCPConnection(host: "", port: 9100)
        await #expect(throws: TransportError.self) { try await badHost.open() }
        let unknown = TCPConnection(host: "nicht-vorhanden.invalid", port: 9100, connectTimeout: .seconds(2))
        await #expect(throws: TransportError.self) { try await unknown.open() }
    }

    @Test("Operationen ohne offene Verbindung → notOpen")
    func notOpen() async throws {
        let connection = TCPConnection(host: "127.0.0.1", port: 9100)
        await #expect(throws: TransportError.notOpen) { try await connection.write(Data([1])) }
        await #expect(throws: TransportError.notOpen) { _ = try await connection.read(timeout: .zero) }
        await #expect(throws: TransportError.notOpen) {
            _ = try await connection.request(Data([1]))
        }
    }

    @Test("Große Datenmengen werden vollständig übertragen (Teil-Schreibvorgänge)")
    func largeWrite() async throws {
        let size = 6 * 1024 * 1024
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let received = LockedValue(Data())
        let server = try TestTCPServer { client in
            // Langsam lesen, damit der Sendepuffer volläuft.
            Thread.sleep(forTimeInterval: 0.3)
            let data = client.receive(count: size, timeout: 20)
            received.set(data)
            client.send("OK")
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        try await connection.write(payload)
        let ack = try await connection.request(Data(), timeout: .seconds(20), isComplete: { $0 == Data("OK".utf8) })
        #expect(ack == Data("OK".utf8))
        #expect(received.value.count == size)
        #expect(received.value == payload)
        await connection.close()
    }

    @Test("close() während eines laufenden read() bricht diesen sofort ab")
    func closeDuringRead() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("ENDE".utf8), timeout: 5)
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let reader = Task { () -> Result<Data, Error> in
            do { return .success(try await connection.read(timeout: .seconds(5))) } catch { return .failure(error) }
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        await connection.close()
        let result = await reader.value
        #expect(start.duration(to: .now) < .seconds(1))
        switch result {
        case .success(let data):
            Issue.record("read() sollte nach close() fehlschlagen, lieferte \(data.count) Bytes")
        case .failure(let error):
            #expect(error as? TransportError == .notOpen)
        }
    }

    @Test("Abbruch des Tasks beendet ein wartendes read()")
    func cancellationDuringRead() async throws {
        let server = try TestTCPServer { client in
            _ = client.receive(until: Data("ENDE".utf8), timeout: 5)
        }
        defer { server.stop() }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let reader = Task { try await connection.read(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        reader.cancel()
        let result = await reader.result
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(throws: CancellationError.self) { try result.get() }
        // Verbindung bleibt nutzbar.
        #expect(await connection.isOpen)
        await connection.close()
    }
}

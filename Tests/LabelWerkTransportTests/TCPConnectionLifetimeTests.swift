import Foundation
import Testing
@testable import LabelWerkTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Regressionstests: `close()` parallel zu `read()`/`write()` darf nie dazu führen, dass eine
/// bereits freigegebene (und vom Kernel neu vergebene) Deskriptornummer benutzt wird.
@Suite("TCPConnection – Lebensdauer des Deskriptors")
struct TCPConnectionLifetimeTests {
    /// Server, der alles Empfangene bis „ENDE“ (oder Verbindungsende) sammelt.
    final class RecordingServer: @unchecked Sendable {
        let received = LockedValue(Data())
        let finishedHandlers = LockedValue(0)
        private(set) var server: TestTCPServer!

        init(greeting: Data? = nil) throws {
            let received = self.received
            let finished = self.finishedHandlers
            server = try TestTCPServer { client in
                if let greeting { client.send(greeting) }
                let data = client.receive(until: Data("ENDE".utf8), timeout: 5)
                received.withLock { $0.append(data) }
                finished.withLock { $0 += 1 }
            }
        }

        var port: Int { server.port }
        var receivedText: String { String(decoding: received.value, as: UTF8.self) }

        /// Wartet, bis `count` Verbindungen angenommen und ausgewertet sind.
        func waitForHandlers(count: Int) async -> Bool {
            await eventually(timeout: .seconds(8)) { finishedHandlers.value >= count }
        }

        func stop() { server.stop() }
    }

    /// Verbundenes Socket-Paar (Unix-Domain) für Tests ohne Netzwerk.
    static func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, POSIXSocket.streamType, 0, &fds) == 0 else {
            throw TestServerError(description: "socketpair() fehlgeschlagen")
        }
        return (fds[0], fds[1])
    }

    /// Wartet bis `timeout` auf Daten bzw. Verbindungsende an `fd`; `0` = Ende, `nil` = Zeitablauf.
    static func receiveCount(_ fd: Int32, timeout: Int32 = 2000) -> Int? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeout) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64)
        return buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
    }

    @Test("SocketHandle: nach close() wird der Deskriptor nicht mehr herausgegeben")
    func handleRejectsUseAfterClose() throws {
        let (local, peer) = try Self.socketPair()
        defer { POSIXSocket.closeDescriptor(peer) }
        let handle = SocketHandle(fd: local)
        #expect(try handle.withDescriptor { $0 } == local)
        #expect(!handle.isClosed)
        #expect(!handle.isReleased)

        handle.close()
        #expect(handle.isClosed)
        #expect(handle.isReleased) // niemand benutzt ihn → sofort freigegeben
        var bodyRan = false
        #expect(throws: TransportError.notOpen) {
            try handle.withDescriptor { _ in bodyRan = true }
        }
        #expect(!bodyRan)
        handle.close() // idempotent
        // Die Gegenstelle sieht das Verbindungsende.
        #expect(Self.receiveCount(peer) == 0)
    }

    @Test("SocketHandle: close() während laufender Benutzung weckt, gibt aber erst nach dem letzten Benutzer frei")
    func handleDefersReleaseUntilLastUser() throws {
        let (local, peer) = try Self.socketPair()
        defer { POSIXSocket.closeDescriptor(peer) }
        let handle = SocketHandle(fd: local)

        struct Observation: Sendable {
            var wokeByShutdown = false
            var waited: Duration = .zero
            var descriptorStillOurs = false
        }
        let observations = LockedValue<[Observation]>([])
        let entered = DispatchSemaphore(value: 0)
        let proceed = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let finished = DispatchSemaphore(value: 0)

        for index in 0..<2 {
            Thread.detachNewThread {
                _ = try? handle.withDescriptor { fd in
                    entered.signal()
                    var observation = Observation()
                    // Blockierendes Warten auf Daten – nur shutdown() durch close() kann es beenden.
                    let start = ContinuousClock.now
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    observation.wokeByShutdown = poll(&descriptor, 1, 5000) > 0
                    observation.waited = start.duration(to: .now)
                    proceed[index].wait()
                    // Die Nummer ist weiterhin unser Socket (nicht freigegeben, nicht neu vergeben).
                    var type: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    observation.descriptorStillOurs = getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == 0
                        && type == POSIXSocket.streamType
                    observations.withLock { $0.append(observation) }
                }
                finished.signal()
            }
        }
        entered.wait()
        entered.wait()

        handle.close()
        #expect(handle.isClosed)
        #expect(!handle.isReleased)
        #expect(throws: TransportError.notOpen) { try handle.withDescriptor { _ in } }

        proceed[0].signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(!handle.isReleased) // ein Benutzer ist noch aktiv

        proceed[1].signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(handle.isReleased)

        let results = observations.value
        #expect(results.count == 2)
        for observation in results {
            #expect(observation.wokeByShutdown)
            #expect(observation.waited < .seconds(2))
            #expect(observation.descriptorStillOurs)
        }
        #expect(Self.receiveCount(peer) == 0)
    }

    @Test("close() während eines blockierten write() (voller Sendepuffer) beendet es zügig")
    func closeDuringBlockedWrite() async throws {
        let release = DispatchSemaphore(value: 0)
        let server = try TestTCPServer { _ in
            // Nie lesen: Der Sendepuffer des Clients läuft voll.
            _ = release.wait(timeout: .now() + 5)
        }
        defer {
            release.signal()
            server.stop()
        }
        let connection = TCPConnection(host: "127.0.0.1", port: server.port, connectTimeout: .seconds(2))
        try await connection.open()
        let payload = Data(count: 64 * 1024 * 1024)
        let writer = Task { try await connection.write(payload) }
        try await Task.sleep(for: .milliseconds(300))

        let (_, closeDuration) = await measure { await connection.close() }
        #expect(closeDuration < .seconds(1))
        let (result, writeDuration) = await measure { await writer.result }
        #expect(writeDuration < .seconds(1))
        #expect(throws: TransportError.notOpen) { try result.get() }
        #expect(await connection.isOpen == false)

        // Danach lässt sich die Verbindung wieder öffnen.
        try await connection.open()
        #expect(await connection.isOpen)
        await connection.close()
    }

    @Test("close() vor dem Einreihen eines write(): keine Bytes an eine neu geöffnete Verbindung")
    func closeBeforeQueuedWriteNeverLeaks() async throws {
        let serverA = try RecordingServer()
        let serverB = try RecordingServer()
        defer { serverA.stop(); serverB.stop() }

        let iterations = 12
        for iteration in 0..<iterations {
            let connectionA = TCPConnection(host: "127.0.0.1", port: serverA.port, connectTimeout: .seconds(2))
            try await connectionA.open()
            let checkpoint = TestCheckpoint()
            await connectionA.setBeforeBlockingIOHook { await checkpoint.pass() }

            // write() hat den Socket bereits abgeholt, die blockierende Arbeit ist noch nicht eingereiht.
            let writer = Task { try await connectionA.write("LEAK-\(iteration)\n") }
            await checkpoint.waitForArrival()

            // In genau dieser Lücke: schließen und eine fremde Verbindung öffnen (erhält in der
            // Regel dieselbe, gerade freigewordene Deskriptornummer).
            await connectionA.close()
            let connectionB = TCPConnection(host: "127.0.0.1", port: serverB.port, connectTimeout: .seconds(2))
            try await connectionB.open()

            checkpoint.release()
            let result = await writer.result
            #expect(throws: TransportError.notOpen) { try result.get() }

            try await connectionB.write("B-\(iteration)ENDE")
            await connectionB.close()
        }

        #expect(await serverB.waitForHandlers(count: iterations))
        let textB = serverB.receivedText
        #expect(!textB.contains("LEAK"), "Daten von A sind bei Server B angekommen: \(textB.debugDescription)")
        #expect(textB.components(separatedBy: "ENDE").count - 1 == iterations)
        // Die Daten von A wurden nie gesendet – auch nicht an Server A.
        #expect(await serverA.waitForHandlers(count: iterations))
        #expect(!serverA.receivedText.contains("LEAK"))
    }

    @Test("close() vor dem Einreihen eines read(): fremde Antworten werden nicht verschluckt")
    func closeBeforeQueuedReadNeverSteals() async throws {
        let serverA = try RecordingServer()
        let serverB = try RecordingServer(greeting: Data("FUER-B".utf8))
        defer { serverA.stop(); serverB.stop() }

        let iterations = 12
        for _ in 0..<iterations {
            let connectionA = TCPConnection(host: "127.0.0.1", port: serverA.port, connectTimeout: .seconds(2))
            try await connectionA.open()
            let checkpoint = TestCheckpoint()
            await connectionA.setBeforeBlockingIOHook { await checkpoint.pass() }

            let reader = Task { try await connectionA.read(timeout: .seconds(2)) }
            await checkpoint.waitForArrival()

            await connectionA.close()
            let connectionB = TCPConnection(host: "127.0.0.1", port: serverB.port, connectTimeout: .seconds(2))
            try await connectionB.open()

            checkpoint.release()
            let (result, elapsed) = await measure { await reader.result }
            #expect(throws: TransportError.notOpen) { try result.get() }
            // Ein geschlossener Socket wird gar nicht erst abgefragt – kein Warten auf die Frist.
            #expect(elapsed < .seconds(1))

            // Die Begrüßung von Server B gehört allein Verbindung B.
            var received = Data()
            let deadline = ContinuousClock.now + .seconds(2)
            while received.count < 6, ContinuousClock.now < deadline {
                received.append(try await connectionB.read(timeout: .milliseconds(200)))
            }
            #expect(String(decoding: received, as: UTF8.self) == "FUER-B")

            try await connectionB.write("ENDE")
            await connectionB.close()
        }
        #expect(await serverB.waitForHandlers(count: iterations))
    }

    @Test("Paralleles close() und neues open(): unter Last nie Daten an fremde Verbindungen")
    func concurrentCloseStress() async throws {
        let serverA = try RecordingServer()
        let serverB = try RecordingServer()
        defer { serverA.stop(); serverB.stop() }

        let iterations = 150
        for iteration in 0..<iterations {
            let connectionA = TCPConnection(host: "127.0.0.1", port: serverA.port, connectTimeout: .seconds(2))
            try await connectionA.open()
            let reader = Task.detached { _ = try? await connectionA.read(timeout: .milliseconds(20)) }
            let writer = Task.detached { try? await connectionA.write("LEAK-\(iteration)\n") }
            for _ in 0..<(iteration % 4) { await Task.yield() }
            let closer = Task.detached { await connectionA.close() }
            let connectionB = TCPConnection(host: "127.0.0.1", port: serverB.port, connectTimeout: .seconds(2))
            try await connectionB.open()
            _ = await (reader.value, writer.value, closer.value)
            try await connectionB.write("ENDE")
            await connectionB.close()
            #expect(await connectionA.isOpen == false)
        }

        #expect(await serverB.waitForHandlers(count: iterations))
        let textB = serverB.receivedText
        #expect(!textB.contains("LEAK"), "Daten von A sind bei Server B angekommen: \(textB.debugDescription)")
        #expect(textB.components(separatedBy: "ENDE").count - 1 == iterations)
    }
}

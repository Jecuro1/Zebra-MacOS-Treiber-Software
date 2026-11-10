import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fehler der Test-Hilfsserver.
struct TestServerError: Error, CustomStringConvertible {
    var description: String
}

/// Blockierender Socket einer angenommenen Testverbindung.
final class TestClientSocket: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Sendet alle Bytes (blockierend).
    @discardableResult
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let sent = Darwin.send(fd, base + offset, raw.count - offset, 0)
                #else
                let sent = Glibc.send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if sent > 0 { offset += sent } else if sent < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    func send(_ text: String) {
        send(Data(text.utf8))
    }

    /// Liest bis `timeout` die verfügbaren Daten; `nil` bei Verbindungsende, leer bei Zeitablauf.
    func receive(timeout: TimeInterval) -> Data? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&descriptor, 1, Int32(timeout * 1000))
        if rc <= 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count <= 0 { return nil }
        return Data(buffer[0..<count])
    }

    /// Liest, bis `marker` enthalten ist, die Verbindung endet oder `timeout` abläuft.
    func receive(until marker: Data, timeout: TimeInterval) -> Data {
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, collected.range(of: marker) == nil {
            guard let chunk = receive(timeout: min(0.05, max(0.001, deadline.timeIntervalSinceNow))) else { break }
            collected.append(chunk)
        }
        return collected
    }

    /// Liest bis zum Verbindungsende oder bis `count` Bytes empfangen wurden.
    func receive(count: Int, timeout: TimeInterval) -> Data {
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, collected.count < count {
            guard let chunk = receive(timeout: min(0.05, max(0.001, deadline.timeIntervalSinceNow))) else { break }
            collected.append(chunk)
        }
        return collected
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    deinit { close() }
}

/// Einfacher POSIX-TCP-Server auf 127.0.0.1 mit zufälligem Port für Tests.
///
/// Jede angenommene Verbindung wird auf einer eigenen Hintergrund-Queue an `handler` übergeben
/// und danach geschlossen.
final class TestTCPServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private let handler: @Sendable (TestClientSocket) -> Void
    private let acceptLoopDone = DispatchSemaphore(value: 0)
    private(set) var acceptedCount = 0
    private let accepts: Bool

    /// - Parameters:
    ///   - backlog: Länge der Warteschlange für Verbindungen.
    ///   - accepts: `false` = Verbindungen nie annehmen (für Zeitüberschreitungstests).
    init(backlog: Int32 = 32, accepts: Bool = true, handler: @escaping @Sendable (TestClientSocket) -> Void) throws {
        self.handler = handler
        self.accepts = accepts
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw TestServerError(description: "socket() fehlgeschlagen") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, backlog) == 0 else {
            _ = TestTCPServer.closeFD(fd)
            throw TestServerError(description: "bind/listen fehlgeschlagen")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = Int(UInt16(bigEndian: address.sin_port))
        self.listenFD = fd
        if accepts {
            // Eigene Threads statt globaler Queues: Handler blockieren bewusst (Thread.sleep, poll).
            Thread.detachNewThread { [self] in acceptLoop() }
        } else {
            acceptLoopDone.signal()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        defer { acceptLoopDone.signal() }
        while !isStopped {
            var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let rc = poll(&descriptor, 1, 50)
            guard rc > 0 else { continue }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            lock.lock()
            acceptedCount += 1
            lock.unlock()
            let socket = TestClientSocket(fd: client)
            let handler = self.handler
            Thread.detachNewThread {
                handler(socket)
                socket.close()
            }
        }
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        acceptLoopDone.wait()
        _ = TestTCPServer.closeFD(listenFD)
    }

    deinit { stop() }

    static func closeFD(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }

    /// Liefert einen Port auf 127.0.0.1, auf dem garantiert niemand lauscht.
    static func unusedPort() throws -> Int {
        let server = try TestTCPServer(accepts: false) { _ in }
        let port = server.port
        server.stop()
        return port
    }
}

/// UDP-Responder auf 127.0.0.1 für SNMP-Tests: beantwortet jede Anfrage mit `respond(request)`.
final class TestUDPResponder: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    init(respond: @escaping @Sendable (Data) -> Data?) throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw TestServerError(description: "socket() fehlgeschlagen") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            _ = TestTCPServer.closeFD(fd)
            throw TestServerError(description: "bind fehlgeschlagen")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = Int(UInt16(bigEndian: address.sin_port))
        self.fd = fd
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !isStopped {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 50) > 0 else { continue }
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &peerLength)
                        }
                    }
                }
                guard count > 0, let reply = respond(Data(buffer[0..<count])) else { continue }
                _ = reply.withUnsafeBytes { raw in
                    withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, peerLength)
                        }
                    }
                }
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        done.wait()
        _ = TestTCPServer.closeFD(fd)
    }

    deinit { stop() }
}

/// Misst die Dauer eines asynchronen Vorgangs.
func measure<T>(_ body: () async throws -> T) async rethrows -> (value: T, elapsed: Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    return (value, start.duration(to: clock.now))
}

/// Typische `~HI`-Antwort eines ZD421.
let sampleHostIdentification = Data("\u{2}ZD421-203dpi,V84.20.18Z,8,8192KB\u{3}\r\n".utf8)

/// Haltepunkt für Nebenläufigkeitstests: Ein Task meldet mit `pass()` seine Ankunft und wartet,
/// bis der Test ihn mit `release()` weiterlaufen lässt. Der Test kann mit `waitForArrival()`
/// abwarten, bis der Task den Haltepunkt erreicht hat.
final class TestCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var passWaiters: [CheckedContinuation<Void, Never>] = []

    private func synchronized<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Meldet die Ankunft und wartet auf `release()`.
    func pass() async {
        let woken: [CheckedContinuation<Void, Never>] = synchronized {
            arrived = true
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            return waiters
        }
        for waiter in woken { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = synchronized {
                if released { return true }
                passWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Wartet, bis ein Task `pass()` erreicht hat.
    func waitForArrival() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = synchronized {
                if arrived { return true }
                arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lässt alle wartenden (und künftigen) `pass()`-Aufrufe weiterlaufen.
    func release() {
        let woken: [CheckedContinuation<Void, Never>] = synchronized {
            released = true
            let waiters = passWaiters
            passWaiters.removeAll()
            return waiters
        }
        for waiter in woken { waiter.resume() }
    }
}

/// Wartet (höchstens `timeout`), bis `condition` erfüllt ist; liefert, ob sie erfüllt wurde.
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

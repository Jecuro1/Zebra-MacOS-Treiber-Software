import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX-Hilfen für den TCP-Server des virtuellen Druckers (macOS & Linux).
///
/// Alle Sockets sind nicht blockierend; gewartet wird mit `poll()` in kurzen Zeitscheiben, damit
/// ein Abbruch zügig wirkt. Die Funktionen sind synchron und laufen über ``ServerIO`` auf
/// eigenen Threads – nie auf dem kooperativen Thread-Pool.
enum ServerSocket {
    #if canImport(Darwin)
    static let streamType: Int32 = SOCK_STREAM
    static let sendFlags: Int32 = 0
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    /// Länge einer Wartescheibe in Millisekunden.
    static let sliceMilliseconds: Int32 = 50

    enum ReceiveResult: Sendable {
        case data(Data)
        case timeout
        case closed
    }

    struct SocketError: Error, LocalizedError, Sendable {
        var message: String
        var errorDescription: String? { message }
    }

    static func errorText(_ code: Int32) -> String {
        guard let text = strerror(code) else { return "Fehler \(code)" }
        return String(cString: text)
    }

    /// Öffnet einen lauschenden Socket.
    ///
    /// - Parameters:
    ///   - host: numerische Adresse (`127.0.0.1`, `::1`, `0.0.0.0`) oder `nil` für alle IPv4-Adressen.
    ///   - port: Port; `0` wählt einen freien Port.
    /// - Returns: Deskriptor und tatsächlich gebundener Port.
    static func listen(host: String?, port: Int, backlog: Int32 = 8) throws -> (fd: Int32, port: Int) {
        guard (0...65535).contains(port) else { throw SocketError(message: "Ungültiger Port \(port).") }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST | AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        let bindHost = host.map { $0 == "localhost" ? "127.0.0.1" : $0 } ?? "0.0.0.0"
        let rc = getaddrinfo(bindHost, String(port), &hints, &list)
        guard rc == 0, let first = list else {
            let reason = rc == 0 ? "keine Adresse" : String(cString: gai_strerror(rc))
            throw SocketError(message: "Adresse „\(bindHost)“ ist ungültig (\(reason)).")
        }
        defer { freeaddrinfo(list) }

        let fd = socket(first.pointee.ai_family, streamType, 0)
        guard fd >= 0 else { throw SocketError(message: "Socket konnte nicht erzeugt werden: \(errorText(errno)).") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            let code = errno
            _ = closeDescriptor(fd)
            throw SocketError(message: "Port \(port) ist nicht verfügbar: \(errorText(code)).")
        }
        guard POSIXCalls.listen(fd, backlog) == 0 else {
            let code = errno
            _ = closeDescriptor(fd)
            throw SocketError(message: "Lauschen auf Port \(port) fehlgeschlagen: \(errorText(code)).")
        }
        setNonBlocking(fd)

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        var boundPort = port
        if named == 0 {
            if Int32(storage.ss_family) == AF_INET {
                boundPort = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
                }
            } else if Int32(storage.ss_family) == AF_INET6 {
                boundPort = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
                }
            }
        }
        return (fd, boundPort)
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Wartet bis zu `timeoutMilliseconds` auf eine neue Verbindung; `nil` bei Zeitablauf.
    static func accept(_ fd: Int32, timeoutMilliseconds: Int32) throws -> Int32? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&descriptor, 1, timeoutMilliseconds)
        if rc < 0 {
            if errno == EINTR { return nil }
            throw SocketError(message: "Warten auf Verbindungen fehlgeschlagen: \(errorText(errno)).")
        }
        guard rc > 0 else { return nil }
        let client = POSIXCalls.accept(fd)
        guard client >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED { return nil }
            throw SocketError(message: "Verbindung konnte nicht angenommen werden: \(errorText(errno)).")
        }
        setNonBlocking(client)
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var noDelay: Int32 = 1
        setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        return client
    }

    /// Liest verfügbare Daten (höchstens `timeoutMilliseconds` warten).
    static func receive(_ fd: Int32, timeoutMilliseconds: Int32) throws -> ReceiveResult {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&descriptor, 1, timeoutMilliseconds)
        if rc < 0 {
            if errno == EINTR { return .timeout }
            throw SocketError(message: "Lesefehler: \(errorText(errno)).")
        }
        guard rc > 0 else { return .timeout }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count > 0 { return .data(Data(buffer[0..<count])) }
        if count == 0 { return .closed }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .timeout }
        if errno == ECONNRESET { return .closed }
        throw SocketError(message: "Lesefehler: \(errorText(errno)).")
    }

    /// Sendet alle Bytes; `isCancelled` wird zwischen den Wartescheiben geprüft.
    static func sendAll(_ fd: Int32, _ data: Data, isCancelled: () -> Bool) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            var stalledSlices = 0
            while offset < raw.count {
                if isCancelled() { throw CancellationError() }
                let sent = send(fd, base + offset, raw.count - offset, sendFlags)
                if sent > 0 {
                    offset += sent
                    stalledSlices = 0
                    continue
                }
                if sent < 0, errno == EINTR { continue }
                if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, sliceMilliseconds)
                    stalledSlices += 1
                    // 30 s ohne Fortschritt: Client nimmt nichts mehr an.
                    if stalledSlices > 600 { throw SocketError(message: "Der Client nimmt keine Daten mehr an.") }
                    continue
                }
                throw SocketError(message: "Sendefehler: \(errorText(errno)).")
            }
        }
    }

    @discardableResult
    static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }
}

/// Plattformneutrale Namen für `listen`/`accept` (vermeidet Verwechslung mit eigenen Methoden).
enum POSIXCalls {
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(fd, backlog)
        #else
        return Glibc.listen(fd, backlog)
        #endif
    }

    static func accept(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.accept(fd, nil, nil)
        #else
        return Glibc.accept(fd, nil, nil)
        #endif
    }
}

/// Threadsichere Abbruchmarke für blockierende Aufrufe.
final class ServerCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Führt blockierende Socket-Aufrufe auf eigenen seriellen Queues aus.
enum ServerIO {
    static func run<T: Sendable>(on queue: DispatchQueue,
                                 _ body: @escaping @Sendable (ServerCancellationFlag) throws -> T) async throws -> T {
        let flag = ServerCancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    continuation.resume(with: Result { try body(flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

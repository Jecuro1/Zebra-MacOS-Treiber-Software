import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Plattformunabhängige Hilfsfunktionen für POSIX-Sockets (macOS & Linux).
///
/// Alle Sockets sind nicht-blockierend; Wartezeiten laufen über `poll()` in kurzen Zeitscheiben,
/// damit Abbruch (`CancellationFlag`) und lokales Schließen zügig wirken. Die Funktionen sind
/// synchron und werden von `TCPConnection` auf eigenen `DispatchQueue`s ausgeführt.
enum POSIXSocket {
    #if canImport(Darwin)
    static let streamType: Int32 = SOCK_STREAM
    static let datagramType: Int32 = SOCK_DGRAM
    /// Darwin unterdrückt SIGPIPE per `SO_NOSIGPIPE` am Socket.
    static let sendFlags: Int32 = 0
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let datagramType = Int32(SOCK_DGRAM.rawValue)
    /// Linux unterdrückt SIGPIPE pro Aufruf mit `MSG_NOSIGNAL`.
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    static let pollIn = Int16(POLLIN)
    static let pollOut = Int16(POLLOUT)
    static let pollFailure = Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)

    /// Maximale Länge einer einzelnen Wartescheibe in `poll()` (Reaktionszeit auf Abbruch).
    static let pollSliceMilliseconds: Int32 = 50

    /// Ergebnis eines Lesevorgangs.
    enum ReceiveOutcome: Sendable, Equatable {
        /// Daten empfangen; `peerClosed` = direkt danach wurde das Verbindungsende erkannt.
        case data(Data, peerClosed: Bool)
        /// Innerhalb der Frist nichts empfangen.
        case timeout
        /// Verbindung von der Gegenstelle beendet, keine weiteren Daten.
        case closed
    }

    // MARK: Fehlertexte

    static func errorText(_ code: Int32) -> String {
        guard let text = strerror(code) else { return "Fehler \(code)" }
        return String(cString: text)
    }

    /// Wandelt einen nullterminierten C-Puffer in einen String (UTF-8, Ersatzzeichen bei Fehlern).
    static func string(fromCString buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Namensauflösung

    /// Aufgelöste Socket-Adresse (Kopie, unabhängig von `freeaddrinfo`).
    struct ResolvedAddress: Sendable {
        var family: Int32
        var socketType: Int32
        var proto: Int32
        var storage: [UInt8]

        /// Ruft `body` mit einem `sockaddr`-Zeiger und der Länge auf.
        func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
            try storage.withUnsafeBytes { raw in
                let pointer = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                return try body(pointer, socklen_t(raw.count))
            }
        }

        /// Numerische Darstellung der Adresse.
        var numericHost: String? {
            withSockAddr { pointer, length in
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(pointer, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                guard rc == 0 else { return nil }
                return POSIXSocket.string(fromCString: buffer)
            }
        }
    }

    /// Entfernt eckige Klammern um IPv6-Adressen.
    static func bareHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Löst `host` per `getaddrinfo` auf (blockierend!).
    ///
    /// - Parameter numericOnly: nur numerische Adressen akzeptieren (kein DNS, blockiert nie lange).
    static func resolve(host: String, port: Int, socketType: Int32 = streamType, numericOnly: Bool = false) throws -> [ResolvedAddress] {
        let bare = bareHost(host)
        guard !bare.isEmpty else { throw TransportError.connectionFailed("Es wurde keine Adresse angegeben.") }
        guard (1...65535).contains(port) else {
            throw TransportError.connectionFailed("Ungültiger Port \(port) (erlaubt: 1–65535).")
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = socketType
        hints.ai_flags = numericOnly ? (AI_NUMERICHOST | AI_NUMERICSERV) : AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(bare, String(port), &hints, &list)
        guard rc == 0, let first = list else {
            let reason = rc == 0 ? "keine Adresse" : String(cString: gai_strerror(rc))
            throw TransportError.connectionFailed("Adresse „\(bare)“ konnte nicht aufgelöst werden (\(reason)).")
        }
        defer { freeaddrinfo(list) }
        var result: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            let info = entry.pointee
            if let address = info.ai_addr, info.ai_addrlen > 0,
               info.ai_family == AF_INET || info.ai_family == AF_INET6 {
                let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(address), count: Int(info.ai_addrlen))
                let candidate = ResolvedAddress(
                    family: info.ai_family,
                    socketType: info.ai_socktype,
                    proto: info.ai_protocol,
                    storage: Array(bytes)
                )
                if !result.contains(where: { $0.storage == candidate.storage }) {
                    result.append(candidate)
                }
            }
            cursor = info.ai_next
        }
        guard !result.isEmpty else {
            throw TransportError.connectionFailed("Für „\(bare)“ wurde keine IPv4/IPv6-Adresse gefunden.")
        }
        return result
    }

    /// `true`, wenn `host` eine numerische IPv4/IPv6-Adresse ist.
    static func isNumericHost(_ host: String) -> Bool {
        let bare = bareHost(host)
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 { return true }
        let withoutScope = bare.split(separator: "%", maxSplits: 1).first.map(String.init) ?? bare
        return inet_pton(AF_INET6, withoutScope, &v6) == 1
    }

    // MARK: Socket anlegen

    /// Erzeugt einen nicht-blockierenden Socket mit den üblichen Optionen.
    static func makeSocket(family: Int32, type: Int32, proto: Int32) throws -> Int32 {
        let fd = socket(family, type, proto)
        guard fd >= 0 else {
            throw TransportError.connectionFailed("Socket konnte nicht angelegt werden (\(errorText(errno))).")
        }
        do {
            try configure(fd, isStream: type == streamType)
        } catch {
            _ = closeDescriptor(fd)
            throw error
        }
        return fd
    }

    private static func configure(_ fd: Int32, isStream: Bool) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw TransportError.connectionFailed("Socket konnte nicht konfiguriert werden (\(errorText(errno))).")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        #if canImport(Darwin)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        #endif
        if isStream {
            _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, size)
            _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, size)
        }
    }

    /// Schließt einen Deskriptor (EINTR wird nicht wiederholt – POSIX-konform).
    @discardableResult
    static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }

    /// Liest `SO_ERROR` (ausstehender Socket-Fehler).
    static func pendingError(_ fd: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &value, &length) == 0 else { return errno }
        return value
    }

    // MARK: Warten

    /// Ein einzelner `poll()`-Aufruf; liefert `revents` (0 = Zeitablauf).
    static func pollOnce(_ fd: Int32, events: Int16, milliseconds: Int32) throws -> Int16 {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            #if canImport(Darwin)
            let rc = Darwin.poll(&descriptor, 1, milliseconds)
            #else
            let rc = Glibc.poll(&descriptor, 1, milliseconds)
            #endif
            if rc > 0 { return descriptor.revents }
            if rc == 0 { return 0 }
            let code = errno
            if code == EINTR || code == EAGAIN { continue }
            throw TransportError.ioError("poll() fehlgeschlagen (\(errorText(code))).")
        }
    }

    /// Wartet (blockierend, in kurzen Zeitscheiben) auf `events`; liefert `revents` oder 0 bei Zeitablauf.
    static func wait(_ fd: Int32, events: Int16, timeout: Duration, cancellation: CancellationFlag?) throws -> Int16 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        repeat {
            try cancellation?.check()
            let remaining = clock.now.duration(to: deadline).clampedMilliseconds
            let slice = min(remaining, pollSliceMilliseconds)
            let revents = try pollOnce(fd, events: events, milliseconds: slice)
            if revents != 0 { return revents }
        } while clock.now < deadline
        return 0
    }

    /// Wartet kooperativ (ohne Threads zu blockieren) auf `events`: `poll()` ohne Wartezeit,
    /// dazwischen `Task.sleep` mit wachsendem Abstand (2 ms … 25 ms). Für viele parallele Sonden.
    static func waitCooperatively(_ fd: Int32, events: Int16, timeout: Duration) async throws -> Int16 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        var pause = Duration.milliseconds(2)
        while true {
            let revents = try pollOnce(fd, events: events, milliseconds: 0)
            if revents != 0 { return revents }
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { return 0 }
            try await Task.sleep(for: min(pause, remaining))
            pause = min(pause * 2, .milliseconds(25))
        }
    }

    // MARK: Verbinden

    /// Baut eine TCP-Verbindung auf (blockierend; nicht-blockierendes `connect` + `poll`).
    ///
    /// Mehrere aufgelöste Adressen werden nacheinander versucht; die Gesamtfrist wird fair auf die
    /// verbleibenden Adressen verteilt. Wirft `.timeout`, wenn keine Adresse rechtzeitig antwortet,
    /// sonst `.connectionFailed` mit dem letzten Fehler (z. B. „Connection refused“).
    static func connect(host: String, port: Int, timeout: Duration, cancellation: CancellationFlag?) throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        let addresses = try resolve(host: host, port: port)
        var lastError: TransportError?
        var sawTimeout = false
        for (index, address) in addresses.enumerated() {
            try cancellation?.check()
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { sawTimeout = true; break }
            let share = remaining / (addresses.count - index)
            do {
                return try connect(address, timeout: share, cancellation: cancellation)
            } catch TransportError.timeout {
                sawTimeout = true
            } catch let error as TransportError {
                lastError = error
            }
        }
        if let lastError, !sawTimeout { throw lastError }
        if sawTimeout { throw TransportError.timeout }
        throw lastError ?? TransportError.connectionFailed("\(host):\(port) ist nicht erreichbar.")
    }

    /// Verbindet zu einer einzelnen Adresse.
    static func connect(_ address: ResolvedAddress, timeout: Duration, cancellation: CancellationFlag?) throws -> Int32 {
        let fd = try makeSocket(family: address.family, type: streamType, proto: address.proto)
        do {
            let rc = address.withSockAddr { pointer, length in
                #if canImport(Darwin)
                return Darwin.connect(fd, pointer, length)
                #else
                return Glibc.connect(fd, pointer, length)
                #endif
            }
            if rc == 0 { return fd }
            let code = errno
            guard code == EINPROGRESS || code == EINTR || code == EAGAIN else {
                throw TransportError.connectionFailed(connectFailureText(address, code))
            }
            let revents = try wait(fd, events: pollOut, timeout: timeout, cancellation: cancellation)
            if revents == 0 { throw TransportError.timeout }
            let pending = pendingError(fd)
            if pending != 0 { throw TransportError.connectionFailed(connectFailureText(address, pending)) }
            return fd
        } catch {
            closeDescriptor(fd)
            throw error
        }
    }

    private static func connectFailureText(_ address: ResolvedAddress, _ code: Int32) -> String {
        let target = address.numericHost ?? "Gegenstelle"
        return "\(target): \(errorText(code))"
    }

    // MARK: Senden

    /// Sendet alle Bytes (Teil-Schreibvorgänge, EINTR, EAGAIN werden behandelt).
    ///
    /// - Parameter stallTimeout: maximale Zeit ohne jeden Sendefortschritt, danach `.timeout`.
    static func sendAll(_ fd: Int32, _ data: Data, stallTimeout: Duration, cancellation: CancellationFlag?) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                try cancellation?.check()
                #if canImport(Darwin)
                let sent = Darwin.send(fd, base + offset, raw.count - offset, sendFlags)
                #else
                let sent = Glibc.send(fd, base + offset, raw.count - offset, sendFlags)
                #endif
                if sent > 0 {
                    offset += sent
                    continue
                }
                let code = sent < 0 ? errno : EAGAIN
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    let revents = try wait(fd, events: pollOut, timeout: stallTimeout, cancellation: cancellation)
                    if revents == 0 { throw TransportError.timeout }
                    if revents & pollOut == 0, revents & pollFailure != 0 {
                        throw mapSocketError(pendingError(fd), fallback: "Senden nicht möglich")
                    }
                    continue
                }
                throw mapSocketError(code, fallback: "Senden fehlgeschlagen")
            }
        }
    }

    // MARK: Empfangen

    /// Wartet bis `timeout` auf Daten und liest dann alles sofort Verfügbare (bis `maxBytes`).
    static func receive(_ fd: Int32, timeout: Duration, cancellation: CancellationFlag?, maxBytes: Int = 1 << 20) throws -> ReceiveOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = max(clock.now.duration(to: deadline), .zero)
            let revents = try wait(fd, events: pollIn, timeout: remaining, cancellation: cancellation)
            if revents == 0 { return .timeout }
            // Alles sofort Verfügbare lesen.
            while collected.count < maxBytes {
                let count = buffer.withUnsafeMutableBytes { pointer in
                    recv(fd, pointer.baseAddress, min(pointer.count, maxBytes - collected.count), 0)
                }
                if count > 0 {
                    collected.append(contentsOf: buffer[0..<count])
                    continue
                }
                if count == 0 {
                    return collected.isEmpty ? .closed : .data(collected, peerClosed: true)
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { break }
                if isDisconnect(code) {
                    return collected.isEmpty ? .closed : .data(collected, peerClosed: true)
                }
                throw TransportError.ioError("Empfang fehlgeschlagen (\(errorText(code))).")
            }
            if !collected.isEmpty { return .data(collected, peerClosed: false) }
            // Fehlalarm von poll() ohne Daten: weiter warten, solange Zeit bleibt.
            if clock.now >= deadline { return .timeout }
        }
    }

    // MARK: Fehlerabbildung

    static func isDisconnect(_ code: Int32) -> Bool {
        code == EPIPE || code == ECONNRESET || code == ENOTCONN || code == ECONNABORTED || code == ESHUTDOWN
    }

    static func mapSocketError(_ code: Int32, fallback: String) -> TransportError {
        if isDisconnect(code) { return .closedByPeer }
        if code == ETIMEDOUT { return .timeout }
        if code == 0 { return .ioError(fallback) }
        return .ioError("\(fallback) (\(errorText(code))).")
    }
}

/// Besitzt einen Socket-Deskriptor und gibt ihn genau einmal frei – erst, wenn ihn kein
/// Systemaufruf mehr benutzt.
///
/// Hintergrund: Deskriptoren sind bloße Nummern, die der Kernel nach `close()` sofort neu vergibt
/// (meist an den nächsten `socket()`-Aufruf im selben Prozess). Würde ein Lese- oder Schreibvorgang
/// die Nummer noch nach der Freigabe benutzen, landeten Daten in einer fremden Verbindung bzw. würden
/// deren Antworten verschluckt. Deshalb gilt:
///
/// * Der Deskriptor ist ausschließlich innerhalb von `withDescriptor(_:)` zugänglich. Prüfung auf
///   „geschlossen“ und Anmeldung als Benutzer geschehen atomar unter derselben Sperre.
/// * `close()` weist neue Benutzer ab (`TransportError.notOpen`) und weckt laufende `poll()`-,
///   `send()`- und `recv()`-Aufrufe per `shutdown(SHUT_RDWR)` – die Nummer bleibt dabei gültig.
/// * Freigegeben (`close(2)`) wird der Deskriptor von demjenigen, der die Benutzerzahl auf null
///   bringt: sofort von `close()`, wenn niemand ihn benutzt, sonst vom letzten Benutzer.
final class SocketHandle: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    /// `close()` wurde aufgerufen; neue Benutzer werden abgewiesen.
    private var closeRequested = false
    /// Der Deskriptor wurde an das System zurückgegeben.
    private var released = false
    /// Zahl der gerade laufenden `withDescriptor(_:)`-Aufrufe.
    private var activeUsers = 0

    /// Übernimmt den Besitz von `fd`.
    init(fd: Int32) {
        self.fd = fd
    }

    /// `true`, sobald `close()` aufgerufen wurde.
    var isClosed: Bool {
        lock.locked { closeRequested }
    }

    /// `true`, sobald der Deskriptor tatsächlich freigegeben ist (nach `close()` und dem Ende
    /// aller laufenden Benutzungen).
    var isReleased: Bool {
        lock.locked { released }
    }

    /// Führt `body` mit dem Deskriptor aus. Während `body` läuft, wird der Deskriptor garantiert
    /// nicht freigegeben – auch nicht durch ein paralleles `close()`.
    ///
    /// - Throws: `TransportError.notOpen`, wenn `close()` bereits aufgerufen wurde (`body` läuft
    ///   dann nicht), sowie alle Fehler von `body`.
    func withDescriptor<R>(_ body: (Int32) throws -> R) throws -> R {
        try lock.locked {
            guard !closeRequested else { throw TransportError.notOpen }
            activeUsers += 1
        }
        defer { endUse() }
        return try body(fd)
    }

    /// Schließt den Socket: keine neuen Benutzer mehr, laufende werden geweckt; die Freigabe
    /// erfolgt sofort oder durch den letzten Benutzer (idempotent).
    func close() {
        let releaseNow: Bool = lock.locked {
            guard !closeRequested else { return false }
            closeRequested = true
            // Unter der Sperre und vor der Freigabe: Die Nummer gehört garantiert noch uns.
            // Weckt wartende poll()-Aufrufe beider Richtungen und sendet FIN.
            _ = shutdown(fd, Int32(SHUT_RDWR))
            guard activeUsers == 0 else { return false }
            released = true
            return true
        }
        if releaseNow { POSIXSocket.closeDescriptor(fd) }
    }

    private func endUse() {
        let releaseNow: Bool = lock.locked {
            activeUsers -= 1
            guard activeUsers == 0, closeRequested, !released else { return false }
            released = true
            return true
        }
        if releaseNow { POSIXSocket.closeDescriptor(fd) }
    }

    deinit {
        // Ohne Referenzen kann es keine Benutzer mehr geben.
        if !released { POSIXSocket.closeDescriptor(fd) }
    }
}

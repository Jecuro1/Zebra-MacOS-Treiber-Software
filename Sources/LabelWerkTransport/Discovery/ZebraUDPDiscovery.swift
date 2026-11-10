import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Zebra-Suche über UDP 4201 (Paketformat und Quellen: ``ZebraDiscoveryPacket``).
///
/// Ein einziger, nicht blockierender UDP-Socket (beliebiger lokaler Port) sendet die Anfrage
/// * als Broadcast an 255.255.255.255 und an die Directed-Broadcast-Adresse jedes Netzes
///   (macOS schickt 255.255.255.255 nur über die Schnittstelle der Standardroute – deshalb zusätzlich
///   je Netz, wie Apple es in TN3179 für eigene Suchprotokolle empfiehlt),
/// * an die Multicast-Gruppe 224.0.1.55 über jede multicastfähige Schnittstelle (TTL = Sprünge, 3),
/// * einzeln an jede Adresse entfernter Netze (VPN, Netze bekannter Drucker, eigene Netze) – das
///   erreicht Drucker hinter Routern und VPN-Tunneln, wo Broadcast und Multicast enden
///   (Link-OS `subnetSearch`).
///
/// Jeder Zebra-Druckserver antwortet von Port 4201 direkt an den Absender. Die Anfrage geht in
/// `rounds` Runden hinaus (UDP kann verloren gehen; Zebras Programme senden sie ebenfalls mehrfach),
/// Antworten werden je Absenderadresse einmal gemeldet. Wird `local network privacy` (macOS 15+)
/// verweigert, scheitern nur die Sendungen ins lokale Netz – Ziele hinter VPN-Tunneln gelten laut
/// TN3179 nicht als lokales Netz.
enum ZebraUDPDiscovery {
    /// Ziele einer Suche.
    struct Targets: Sendable, Equatable {
        /// Broadcast-Adressen (255.255.255.255, Directed Broadcasts).
        var broadcast: [String] = []
        /// Eigene IPv4-Adressen der Schnittstellen, über die an die Multicast-Gruppe gesendet wird.
        var multicastInterfaces: [String] = []
        /// Einzeln abzufragende Adressen.
        var unicast: [String] = []

        var isEmpty: Bool { broadcast.isEmpty && multicastInterfaces.isEmpty && unicast.isEmpty }
    }

    /// Ergebnis einer Suche (für Diagnose und Hinweise).
    struct Report: Sendable, Equatable {
        /// Erfolgreich gesendete Anfragen.
        var sent = 0
        /// Fehlgeschlagene Sendungen (z. B. kein Weg zum Ziel, Broadcast nicht erlaubt).
        var failed = 0
        /// Antwortende Druckserver (verschiedene Absenderadressen).
        var replies = 0
        /// Erster Sendefehler (Text).
        var firstError: String?
    }

    /// Sendet die Suchanfrage an `targets` und meldet jede Antwort (ausgewertet, Absenderadresse).
    /// Endet `replyWindow` nach der letzten Sendung oder beim Abbruch des Tasks.
    static func run(
        targets: Targets,
        port: Int = ZebraDiscoveryPacket.port,
        multicastGroup: String = ZebraDiscoveryPacket.multicastGroup,
        multicastHops: Int = ZebraDiscoveryPacket.defaultMulticastHops,
        rounds: Int = 2,
        roundInterval: Duration = .milliseconds(800),
        replyWindow: Duration = .milliseconds(2500),
        batchSize: Int = 64,
        batchPause: Duration = .milliseconds(15),
        onReply: (ZebraDiscoveryPacket.Reply, String) -> Void
    ) async -> Report {
        var report = Report()
        guard !targets.isEmpty, (1...65535).contains(port) else { return report }
        let fd: Int32
        do {
            fd = try POSIXSocket.makeSocket(family: AF_INET, type: POSIXSocket.datagramType, proto: 0)
        } catch {
            report.failed = 1
            report.firstError = "\(error)"
            return report
        }
        defer { POSIXSocket.closeDescriptor(fd) }
        configure(fd, multicastHops: multicastHops)

        var state = ReceiveState()
        let clock = ContinuousClock()
        for round in 0..<max(1, rounds) {
            if Task.isCancelled { break }
            let roundStart = clock.now
            for target in targets.broadcast {
                await send(fd, to: target, port: port, report: &report)
            }
            for interface in targets.multicastInterfaces {
                guard selectMulticastInterface(fd, address: interface) else { continue }
                await send(fd, to: multicastGroup, port: port, report: &report)
            }
            receiveAvailable(fd, state: &state, report: &report, onReply: onReply)
            for (index, host) in targets.unicast.enumerated() {
                if Task.isCancelled { break }
                await send(fd, to: host, port: port, report: &report)
                if (index + 1) % max(1, batchSize) == 0 {
                    receiveAvailable(fd, state: &state, report: &report, onReply: onReply)
                    try? await Task.sleep(for: batchPause)
                }
            }
            receiveAvailable(fd, state: &state, report: &report, onReply: onReply)
            if round < max(1, rounds) - 1 {
                await receive(fd, until: roundStart.advanced(by: roundInterval), state: &state, report: &report,
                              onReply: onReply)
            }
        }
        await receive(fd, until: clock.now.advanced(by: replyWindow), state: &state, report: &report, onReply: onReply)
        return report
    }

    // MARK: Socket

    private static func configure(_ fd: Int32, multicastHops: Int) {
        var one: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, intSize)
        // Viele Drucker antworten fast gleichzeitig (je Runde und Weg einmal): großzügiger Puffer.
        var receiveBuffer: Int32 = 1 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, intSize)
        // Ein Byte (u_char) versteht sowohl Darwin als auch Linux.
        var hops = UInt8(clamping: max(1, multicastHops))
        _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &hops, socklen_t(MemoryLayout<UInt8>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = 0 // INADDR_ANY
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Wählt die Schnittstelle (über ihre eigene Adresse), über die Multicast gesendet wird.
    private static func selectMulticastInterface(_ fd: Int32, address: String) -> Bool {
        var interfaceAddress = in_addr()
        guard inet_pton(AF_INET, address, &interfaceAddress) == 1 else { return false }
        return setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_IF, &interfaceAddress,
                          socklen_t(MemoryLayout<in_addr>.size)) == 0
    }

    /// Sendet die Anfrage an `host`; ein voller Sendepuffer wird kurz abgewartet.
    private static func send(_ fd: Int32, to host: String, port: Int, report: inout Report) async {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            note(EINVAL, host: host, report: &report)
            return
        }
        for attempt in 0..<2 {
            let sent = ZebraDiscoveryPacket.request.withUnsafeBytes { raw in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, POSIXSocket.sendFlags, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == ZebraDiscoveryPacket.request.count {
                report.sent += 1
                return
            }
            let code = errno
            if attempt == 0, code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS || code == EINTR {
                _ = try? await POSIXSocket.waitCooperatively(fd, events: POSIXSocket.pollOut, timeout: .milliseconds(50))
                continue
            }
            note(code, host: host, report: &report)
            return
        }
    }

    private static func note(_ code: Int32, host: String, report: inout Report) {
        report.failed += 1
        if report.firstError == nil { report.firstError = "\(host): \(POSIXSocket.errorText(code))" }
    }

    // MARK: Empfang

    private struct ReceiveState {
        var seenHosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)
    }

    /// Wartet bis `deadline` auf Antworten.
    private static func receive(_ fd: Int32, until deadline: ContinuousClock.Instant, state: inout ReceiveState,
                                report: inout Report, onReply: (ZebraDiscoveryPacket.Reply, String) -> Void) async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            guard let revents = try? await POSIXSocket.waitCooperatively(fd, events: POSIXSocket.pollIn, timeout: remaining)
            else { return }
            if revents == 0 { return }
            receiveAvailable(fd, state: &state, report: &report, onReply: onReply)
        }
    }

    /// Liest alle bereits eingetroffenen Pakete (ohne zu warten).
    private static func receiveAvailable(_ fd: Int32, state: inout ReceiveState, report: inout Report,
                                         onReply: (ZebraDiscoveryPacket.Reply, String) -> Void) {
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = state.buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: nichts mehr da (bzw. ICMP-Fehler einer früheren Sendung)
            }
            guard count > 0, Int32(from.sin_family) == AF_INET,
                  let reply = ZebraDiscoveryPacket.parse(Array(state.buffer[0..<count]))
            else { continue }
            let host = SubnetScanner.formatIPv4(UInt32(bigEndian: from.sin_addr.s_addr))
            guard state.seenHosts.insert(host).inserted else { continue }
            report.replies += 1
            onReply(reply, host)
        }
    }
}

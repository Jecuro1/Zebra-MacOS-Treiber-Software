import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// IPv4-Adresse und Netzmaske einer lokalen Netzwerkschnittstelle.
public struct NetworkInterfaceInfo: Hashable, Sendable {
    public var name: String
    public var address: String
    public var netmask: String

    public init(name: String, address: String, netmask: String) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    /// Präfixlänge der Netzmaske (z. B. 24), `nil` bei ungültiger Maske.
    public var prefixLength: Int? {
        guard let mask = SubnetScanner.parseIPv4(netmask) else { return nil }
        return SubnetScanner.prefixLength(ofMask: mask)
    }

    /// CIDR-Schreibweise des Netzes, z. B. „192.168.1.0/24“.
    public var networkCIDR: String? {
        guard let address = SubnetScanner.parseIPv4(address),
              let mask = SubnetScanner.parseIPv4(netmask),
              let prefix = prefixLength else { return nil }
        return "\(SubnetScanner.formatIPv4(address & mask))/\(prefix)"
    }
}

/// Sucht in lokalen IPv4-Netzen nach Geräten mit offenem Druckerport (Standard 9100).
public enum SubnetScanner {
    /// Aktive IPv4-Schnittstellen (`getifaddrs`), ohne Loopback und Punkt-zu-Punkt-Verbindungen (VPN).
    public static func localIPv4Interfaces() -> [NetworkInterfaceInfo] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [NetworkInterfaceInfo] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let info = entry.pointee
            let flags = Int(info.ifa_flags)
            guard flags & Int(IFF_UP) != 0,
                  flags & Int(IFF_RUNNING) != 0,
                  flags & Int(IFF_LOOPBACK) == 0,
                  flags & Int(IFF_POINTOPOINT) == 0,
                  let address = info.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  let netmask = info.ifa_netmask
            else { continue }
            let addressValue = ipv4Value(address)
            let maskValue = ipv4Value(netmask)
            // Link-Local (169.254/16) und unspezifizierte Adressen überspringen.
            guard addressValue != 0, addressValue & 0xFFFF_0000 != 0xA9FE_0000 else { continue }
            let name = String(cString: info.ifa_name)
            let item = NetworkInterfaceInfo(name: name, address: formatIPv4(addressValue), netmask: formatIPv4(maskValue))
            if !result.contains(item) { result.append(item) }
        }
        return result
    }

    /// Zu durchsuchende Hostadressen des Netzes von `iface`, aufsteigend sortiert.
    ///
    /// * Netz- und Broadcastadresse werden ausgelassen (außer bei /31 und /32).
    /// * Ist das Netz größer als `limit` (z. B. /16), wird ein zusammenhängendes Fenster von
    ///   `limit` Adressen rund um die eigene Adresse gewählt – bei `limit = 1024` also etwa das
    ///   eigene /22-Netz. /24 … /22 werden mit dem Standardlimit vollständig abgedeckt.
    /// * Die eigene Adresse ist enthalten (lokal laufender Drucker-Simulator).
    public static func hosts(in iface: NetworkInterfaceInfo, limit: Int = 1024) -> [String] {
        guard limit > 0,
              let address = parseIPv4(iface.address),
              let mask = parseIPv4(iface.netmask)
        else { return [] }
        let network = address & mask
        let broadcast = network | ~mask
        var first = UInt64(network)
        var last = UInt64(broadcast)
        if last - first >= 2 {
            first += 1
            last -= 1
        }
        let total = last - first + 1
        let count = min(UInt64(limit), total)
        // Fenster um die eigene Adresse, in den Netzbereich verschoben.
        var start = UInt64(address) >= first + count / 2 ? UInt64(address) - count / 2 : first
        if start + count - 1 > last { start = last - count + 1 }
        if start < first { start = first }
        return (0..<count).map { formatIPv4(UInt32(start + $0)) }
    }

    /// Prüft `hosts` parallel (höchstens `maxConcurrent` gleichzeitig) per nicht-blockierendem
    /// TCP-Verbindungsaufbau auf `port` und liefert jeden Host mit offenem Port, sobald er gefunden ist.
    ///
    /// Der Strom endet, wenn alle Hosts geprüft sind oder der Verbraucher ihn verwirft
    /// (dann werden die laufenden Prüfungen abgebrochen).
    public static func scan(
        hosts: [String],
        port: Int = 9100,
        timeout: Duration = .milliseconds(400),
        maxConcurrent: Int = 64
    ) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let task = Task {
            await withTaskGroup(of: String?.self) { group in
                var pending = hosts.makeIterator()
                var started = 0
                while started < max(1, maxConcurrent), let host = pending.next() {
                    group.addTask { await isPortOpen(host: host, port: port, timeout: timeout) ? host : nil }
                    started += 1
                }
                while let result = await group.next() {
                    if let host = result { continuation.yield(host) }
                    if Task.isCancelled { group.cancelAll(); break }
                    if let host = pending.next() {
                        group.addTask { await isPortOpen(host: host, port: port, timeout: timeout) ? host : nil }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Prüft, ob auf `host:port` eine TCP-Verbindung angenommen wird (Verbindung wird sofort geschlossen).
    ///
    /// Numerische Adressen werden ohne DNS geprüft; Hostnamen werden auf einer Hintergrund-Queue aufgelöst.
    public static func isPortOpen(host: String, port: Int, timeout: Duration) async -> Bool {
        guard (1...65535).contains(port) else { return false }
        let addresses: [POSIXSocket.ResolvedAddress]
        if POSIXSocket.isNumericHost(host) {
            guard let resolved = try? POSIXSocket.resolve(host: host, port: port, numericOnly: true) else { return false }
            addresses = resolved
        } else {
            guard let resolved = try? await BlockingIO.run({ _ in try POSIXSocket.resolve(host: host, port: port) }) else {
                return false
            }
            addresses = resolved
        }
        for address in addresses {
            if Task.isCancelled { return false }
            if await probe(address, timeout: timeout) { return true }
        }
        return false
    }

    private static func probe(_ address: POSIXSocket.ResolvedAddress, timeout: Duration) async -> Bool {
        guard let fd = try? POSIXSocket.makeSocket(family: address.family, type: POSIXSocket.streamType, proto: address.proto) else {
            return false
        }
        defer { POSIXSocket.closeDescriptor(fd) }
        let rc = address.withSockAddr { pointer, length in
            #if canImport(Darwin)
            return Darwin.connect(fd, pointer, length)
            #else
            return Glibc.connect(fd, pointer, length)
            #endif
        }
        if rc == 0 { return true }
        let code = errno
        guard code == EINPROGRESS || code == EINTR || code == EAGAIN else { return false }
        guard let revents = try? await POSIXSocket.waitCooperatively(fd, events: POSIXSocket.pollOut, timeout: timeout),
              revents != 0
        else { return false }
        return POSIXSocket.pendingError(fd) == 0
    }

    // MARK: IPv4-Hilfen

    /// „192.168.1.20“ → 0xC0A80114 (Host-Byte-Reihenfolge).
    static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    /// Präfixlänge einer zusammenhängenden Netzmaske, sonst `nil`.
    static func prefixLength(ofMask mask: UInt32) -> Int? {
        let ones = (~mask).leadingZeroBitCount
        let expected: UInt32 = ones == 0 ? 0 : (ones == 32 ? .max : UInt32.max << UInt32(32 - ones))
        return mask == expected ? ones : nil
    }

    static func formatIPv4(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// Liest eine IPv4-Adresse aus einer `sockaddr` (Host-Byte-Reihenfolge).
    private static func ipv4Value(_ address: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
        }
    }
}

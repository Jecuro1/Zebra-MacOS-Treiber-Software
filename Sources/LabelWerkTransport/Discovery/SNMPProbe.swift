import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimaler SNMPv1-Client (nur `GetRequest` für Zeichenkettenwerte).
///
/// Dient der **gefahrlosen** Identifikation von Netzwerkgeräten bei der Suche: Eine SNMP-Abfrage
/// von `sysDescr`/`sysName` löst auf keinem Drucker einen Ausdruck aus – anders als Text, der an
/// Port 9100 eines fremden Druckers gesendet wird. Zebra-Drucker melden z. B.
/// `sysDescr = "ZTC ZD421-203dpi ZPL"`.
enum SNMPProbe {
    static let sysDescrOID = "1.3.6.1.2.1.1.1.0"
    static let sysNameOID = "1.3.6.1.2.1.1.5.0"

    // MARK: Kodierung (BER)

    /// Erzeugt ein SNMPv1-`GetRequest` mit `NULL`-Werten für alle OIDs.
    static func encodeGetRequest(community: String, requestID: Int32, oids: [String]) -> Data? {
        var varbinds: [UInt8] = []
        for oid in oids {
            guard let encodedOID = encodeOID(oid) else { return nil }
            let varbind = tlv(0x06, encodedOID) + [0x05, 0x00]
            varbinds += tlv(0x30, varbind)
        }
        var pdu: [UInt8] = []
        pdu += tlv(0x02, encodeInteger(Int64(requestID)))
        pdu += tlv(0x02, [0x00])          // error-status
        pdu += tlv(0x02, [0x00])          // error-index
        pdu += tlv(0x30, varbinds)
        var message: [UInt8] = []
        message += tlv(0x02, [0x00])      // version: SNMPv1
        message += tlv(0x04, Array(community.utf8))
        message += tlv(0xA0, pdu)         // GetRequest-PDU
        return Data(tlv(0x30, message))
    }

    /// Wertet ein `GetResponse` aus; liefert OID → Zeichenkette (nur OCTET-STRING-Werte).
    ///
    /// - Parameter expectedRequestID: wenn gesetzt, werden Antworten mit anderer ID verworfen.
    static func decodeGetResponse(_ data: Data, expectedRequestID: Int32? = nil) -> [String: String]? {
        let bytes = [UInt8](data)
        guard let message = readTLV(bytes, at: 0), message.tag == 0x30 else { return nil }
        var cursor = message.valueStart
        guard let version = readTLV(bytes, at: cursor), version.tag == 0x02 else { return nil }
        cursor = version.end
        guard let community = readTLV(bytes, at: cursor), community.tag == 0x04 else { return nil }
        cursor = community.end
        guard let pdu = readTLV(bytes, at: cursor), pdu.tag == 0xA2, pdu.end <= message.end else { return nil }
        cursor = pdu.valueStart
        guard let requestID = readTLV(bytes, at: cursor), requestID.tag == 0x02 else { return nil }
        if let expectedRequestID, decodeInteger(Array(bytes[requestID.valueStart..<requestID.end])) != Int64(expectedRequestID) {
            return nil
        }
        cursor = requestID.end
        guard let errorStatus = readTLV(bytes, at: cursor), errorStatus.tag == 0x02 else { return nil }
        if decodeInteger(Array(bytes[errorStatus.valueStart..<errorStatus.end])) != 0 { return [:] }
        cursor = errorStatus.end
        guard let errorIndex = readTLV(bytes, at: cursor), errorIndex.tag == 0x02 else { return nil }
        cursor = errorIndex.end
        guard let list = readTLV(bytes, at: cursor), list.tag == 0x30 else { return nil }

        var values: [String: String] = [:]
        var position = list.valueStart
        while position < list.end, let varbind = readTLV(bytes, at: position), varbind.tag == 0x30 {
            position = varbind.end
            guard let name = readTLV(bytes, at: varbind.valueStart), name.tag == 0x06,
                  let value = readTLV(bytes, at: name.end)
            else { continue }
            guard value.tag == 0x04, let oid = decodeOID(Array(bytes[name.valueStart..<name.end])) else { continue }
            let raw = Array(bytes[value.valueStart..<value.end])
            let text = String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
            values[oid] = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        }
        return values
    }

    // MARK: Abfrage

    /// Fragt `oids` per UDP ab. Liefert `nil`, wenn keine (gültige) Antwort innerhalb von `timeout`
    /// eintrifft oder das Ziel die Anfrage ablehnt (ICMP „Port unreachable“).
    ///
    /// Wartet kooperativ (kurzes `poll()` + `Task.sleep`) und blockiert keine Threads.
    static func query(
        host: String,
        port: Int = 161,
        community: String = "public",
        oids: [String] = [sysDescrOID, sysNameOID],
        timeout: Duration = .milliseconds(700)
    ) async -> [String: String]? {
        guard POSIXSocket.isNumericHost(host),
              let address = try? POSIXSocket.resolve(host: host, port: port, socketType: POSIXSocket.datagramType, numericOnly: true).first,
              let fd = try? POSIXSocket.makeSocket(family: address.family, type: POSIXSocket.datagramType, proto: 0)
        else { return nil }
        defer { POSIXSocket.closeDescriptor(fd) }

        // Verbundener UDP-Socket: ICMP-Fehler werden als ECONNREFUSED gemeldet.
        let connected = address.withSockAddr { pointer, length -> Int32 in
            #if canImport(Darwin)
            return Darwin.connect(fd, pointer, length)
            #else
            return Glibc.connect(fd, pointer, length)
            #endif
        }
        guard connected == 0 else { return nil }

        let requestID = Int32.random(in: 1...Int32.max)
        guard let request = encodeGetRequest(community: community, requestID: requestID, oids: oids) else { return nil }

        // Zwei Sendeversuche innerhalb der Frist (UDP kann verloren gehen).
        let attempts = 2
        let slice = timeout / attempts
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<attempts {
            if Task.isCancelled { return nil }
            let sent = request.withUnsafeBytes { raw in
                send(fd, raw.baseAddress, raw.count, POSIXSocket.sendFlags)
            }
            guard sent == request.count else { return nil }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: slice)
            while clock.now < deadline {
                guard let revents = try? await POSIXSocket.waitCooperatively(
                    fd, events: POSIXSocket.pollIn, timeout: clock.now.duration(to: deadline)
                ) else { return nil }
                if revents == 0 { break }
                let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if count < 0 {
                    let code = errno
                    if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                    return nil // z. B. ECONNREFUSED: kein SNMP-Dienst
                }
                if let values = decodeGetResponse(Data(buffer[0..<count]), expectedRequestID: requestID) {
                    return values
                }
            }
        }
        return nil
    }

    // MARK: BER-Hilfen

    private static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(value.count) + value
    }

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func encodeInteger(_ value: Int64) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        // Überflüssige führende Bytes entfernen (Zweierkomplement-Minimalform).
        while bytes.count > 1,
              (bytes[0] == 0x00 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return bytes
    }

    static func decodeInteger(_ bytes: [UInt8]) -> Int64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var value: Int64 = bytes[0] & 0x80 != 0 ? -1 : 0
        for byte in bytes {
            value = (value << 8) | Int64(byte)
        }
        return value
    }

    static func encodeOID(_ text: String) -> [UInt8]? {
        let arcs = text.split(separator: ".").compactMap { UInt64($0) }
        guard arcs.count >= 2, arcs.count == text.split(separator: ".").count, arcs[0] <= 2, arcs[1] < 40 || arcs[0] == 2 else {
            return nil
        }
        var bytes = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) {
            bytes += base128(arc)
        }
        return bytes
    }

    static func decodeOID(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return nil }
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                arcs.append(value)
                value = 0
            }
        }
        guard let first = arcs.first else { return nil }
        let head: [UInt64] = first < 80 ? [first / 40, first % 40] : [2, first - 80]
        return (head + arcs.dropFirst()).map(String.init).joined(separator: ".")
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return bytes
    }

    /// Gelesenes TLV-Element: Tag sowie Beginn des Werts und Ende des Elements.
    struct Element {
        var tag: UInt8
        var valueStart: Int
        var end: Int
    }

    static func readTLV(_ bytes: [UInt8], at offset: Int) -> Element? {
        guard offset + 1 < bytes.count else { return nil }
        let tag = bytes[offset]
        var cursor = offset + 1
        let first = bytes[cursor]
        cursor += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count >= 1, count <= 4, cursor + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return Element(tag: tag, valueStart: cursor, end: cursor + length)
    }
}

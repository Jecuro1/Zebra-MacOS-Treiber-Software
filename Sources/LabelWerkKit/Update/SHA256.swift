import Foundation

/// SHA-256 (FIPS 180-4) in reinem Swift – für die Prüfung geladener Update-Pakete auf macOS und
/// Linux ohne CryptoKit/CommonCrypto.
///
/// Der Typ heißt bewusst nicht `SHA256`, damit er in der App nicht mit `CryptoKit.SHA256`
/// kollidiert. Daten können in beliebig großen Stücken nachgereicht werden (``update(_:)``);
/// ``hexDigest(ofFileAt:chunkSize:)`` liest Dateien stückweise und hält nie die ganze Datei im
/// Speicher.
///
/// ```swift
/// var hasher = SHA256Hasher()
/// hasher.update(Data("ab".utf8))
/// hasher.update(Data("c".utf8))
/// hasher.hexDigest()   // "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
/// ```
public struct SHA256Hasher: Sendable {

    /// Länge des Hashwerts in Bytes.
    public static let byteCount = 32

    private var state: [UInt32] = SHA256Hasher.initialState
    /// Noch nicht verarbeitete Bytes (weniger als ein Block).
    private var buffer: [UInt8] = []
    /// Bisher eingespeiste Bytes insgesamt.
    private var length: UInt64 = 0

    public init() {
        buffer.reserveCapacity(64)
    }

    // MARK: - Einspeisen

    /// Speist weitere Daten ein.
    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(bytes: $0) }
    }

    /// Speist weitere Bytes ein.
    public mutating func update(bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        length &+= UInt64(bytes.count)
        var offset = 0
        // Angefangenen Block auffüllen.
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            offset = take
            if buffer.count == 64 {
                buffer.withUnsafeBytes { SHA256Hasher.compress(&state, $0.baseAddress!) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        // Ganze Blöcke direkt aus dem Eingabepuffer verarbeiten.
        if let base = bytes.baseAddress {
            while bytes.count - offset >= 64 {
                SHA256Hasher.compress(&state, base + offset)
                offset += 64
            }
        }
        if offset < bytes.count {
            buffer.append(contentsOf: bytes[offset..<bytes.count])
        }
    }

    // MARK: - Ergebnis

    /// Hashwert der bisher eingespeisten Daten (32 Bytes). Der Hasher selbst bleibt unverändert,
    /// es können also weitere Daten folgen.
    public func finalize() -> [UInt8] {
        var copy = self
        var padding: [UInt8] = [0x80]
        let used = (buffer.count + 1) % 64
        let zeros = used <= 56 ? 56 - used : 120 - used
        padding.append(contentsOf: repeatElement(0, count: zeros))
        let bitLength = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        copy.appendWithoutCounting(padding)
        precondition(copy.buffer.isEmpty, "SHA-256: Auffüllung fehlerhaft")
        var digest: [UInt8] = []
        digest.reserveCapacity(SHA256Hasher.byteCount)
        for word in copy.state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    /// Hashwert als 64 Kleinbuchstaben-Hexziffern.
    public func hexDigest() -> String {
        SHA256Hasher.hex(finalize())
    }

    // MARK: - Bequeme Varianten

    /// Hashwert von `data`.
    public static func digest(_ data: Data) -> [UInt8] {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize()
    }

    /// Hashwert von `data` als Hexziffern (klein).
    public static func hexDigest(_ data: Data) -> String {
        hex(digest(data))
    }

    /// Hashwert einer Datei als Hexziffern (klein); liest die Datei stückweise.
    /// - Throws: Fehler beim Öffnen oder Lesen der Datei.
    public static func hexDigest(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        let size = max(4096, chunkSize)
        while true {
            let chunk = try handle.read(upToCount: size) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.hexDigest()
    }

    /// Bytes als Hexziffern (klein).
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Intern

    /// Wie `update`, zählt die Bytes aber nicht zur Nachrichtenlänge (für die Auffüllung).
    private mutating func appendWithoutCounting(_ bytes: [UInt8]) {
        let saved = length
        bytes.withUnsafeBytes { update(bytes: $0) }
        length = saved
    }

    private static let initialState: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    /// Verarbeitet einen 64-Byte-Block ab `block`.
    private static func compress(_ state: inout [UInt32], _ block: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            for i in 0..<16 {
                let p = block + i * 4
                w[i] = UInt32(p.load(fromByteOffset: 0, as: UInt8.self)) << 24
                    | UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) << 16
                    | UInt32(p.load(fromByteOffset: 2, as: UInt8.self)) << 8
                    | UInt32(p.load(fromByteOffset: 3, as: UInt8.self))
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            k.withUnsafeBufferPointer { k in
                for i in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    h = g; g = f; f = e
                    e = d &+ t1
                    d = c; c = b; b = a
                    a = t1 &+ t2
                }
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
    }
}

import Foundation

/// Zebra-`:Z64:`-Kodierung: zlib-komprimierte Daten als Base64 mit CRC-16-Prüfsumme.
///
/// Format: `":Z64:" + base64(zlib(data)) + ":" + %04X(CRC16.xmodem(base64-ASCII))`.
/// Base64 verwendet das Standardalphabet mit Padding und ohne Zeilenumbrüche.
public enum Z64 {
    /// Kodiert Rohdaten (komprimiert mit `Z_DEFAULT_COMPRESSION`).
    public static func encode(_ data: Data) throws -> String {
        try encode(bytes: [UInt8](data))
    }

    /// Dekodiert `:Z64:`-Daten.
    ///
    /// Akzeptiert die Daten mit oder ohne `:Z64:`-Präfix und mit oder ohne angehängte CRC
    /// (`:XXXX`). Ist eine CRC vorhanden, wird sie geprüft. Leerraum und Zeilenumbrüche in den
    /// Base64-Daten werden ignoriert, fehlendes Padding wird ergänzt.
    ///
    /// - Throws: `ImagingError.invalidBase64`, `.checksumMismatch`, `.decompressionFailed`.
    public static func decode(_ string: String) throws -> Data {
        Data(try decodeBytes(string))
    }

    // MARK: - Intern

    static func encode(bytes: [UInt8]) throws -> String {
        let compressed = try Deflate.compress(bytes: bytes)
        let base64 = Base64.encode(compressed)
        let crc = CRC16.xmodem(base64)
        var result = ":Z64:"
        result.reserveCapacity(base64.count + 10)
        result += String(decoding: base64, as: UTF8.self)
        result += ":"
        result += CRC16.hex4(crc)
        return result
    }

    /// Dekodiert `:Z64:`-Daten; mit `limit` werden höchstens so viele Bytes entpackt.
    static func decodeBytes(_ string: String, limit: Int? = nil) throws -> [UInt8] {
        let payload = try ZebraBase64Payload(string, prefix: ":Z64:")
        return try Deflate.decompress(bytes: payload.decoded, expectedSize: limit, limit: limit)
    }
}

/// `:B64:`-Kodierung (unkomprimiertes Base64 mit CRC-16), wie sie ZPL für `^GF`/`~DY` kennt.
enum B64 {
    static func encode(bytes: [UInt8]) -> String {
        let base64 = Base64.encode(bytes)
        return ":B64:" + String(decoding: base64, as: UTF8.self) + ":" + CRC16.hex4(CRC16.xmodem(base64))
    }

    static func decodeBytes(_ string: String) throws -> [UInt8] {
        try ZebraBase64Payload(string, prefix: ":B64:").decoded
    }
}

/// Zerlegt `[:Z64:|:B64:]<base64>[:CRC]` und prüft die CRC.
struct ZebraBase64Payload {
    /// Dekodierte Base64-Daten.
    let decoded: [UInt8]

    init(_ string: String, prefix: String) throws {
        var text = Substring(string)
        // Führenden/abschließenden Leerraum entfernen.
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        if text.count >= prefix.count, text.prefix(prefix.count).uppercased() == prefix {
            text = text.dropFirst(prefix.count)
        }
        var body = text
        var crcText: Substring?
        if let colon = text.lastIndex(of: ":") {
            body = text[..<colon]
            crcText = text[text.index(after: colon)...]
        }
        // Base64-Zeichen ohne Leerraum sammeln.
        let raw = Array(body.utf8)
        let compact = raw.filter { !Base64.isWhitespace($0) }
        if let crcText {
            let crcString = crcText.filter { !$0.isWhitespace }
            if !crcString.isEmpty {
                guard crcString.count == 4, let expected = UInt16(crcString, radix: 16) else {
                    throw ImagingError.invalidGraphicData("Ungültige Prüfsumme „\(crcString)“.")
                }
                let actual = CRC16.xmodem(compact)
                if actual != expected {
                    // Manche Erzeuger rechnen die CRC über den Text inklusive Zeilenumbrüchen.
                    let alternative = CRC16.xmodem(raw)
                    if alternative != expected {
                        throw ImagingError.checksumMismatch(expected: expected, actual: actual)
                    }
                }
            }
        }
        guard let decoded = Base64.decode(compact) else { throw ImagingError.invalidBase64 }
        self.decoded = decoded
    }
}

/// Schnelle Base64-Kodierung (Standardalphabet, mit Padding) ohne Foundation-Umwege.
enum Base64 {
    private static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// Dekodiertabelle: 0…63 gültig, 0xFF ungültig.
    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (i, c) in alphabet.enumerated() { table[Int(c)] = UInt8(i) }
        // URL-sicheres Alphabet ebenfalls akzeptieren.
        table[Int(UInt8(ascii: "-"))] = 62
        table[Int(UInt8(ascii: "_"))] = 63
        return table
    }()

    static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    static func encode(_ input: [UInt8]) -> [UInt8] {
        let outCount = (input.count + 2) / 3 * 4
        var out = [UInt8](repeating: 0, count: outCount)
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                alphabet.withUnsafeBufferPointer { abc in
                    let n = src.count
                    var i = 0, o = 0
                    while i + 3 <= n {
                        let v = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2])
                        dst[o] = abc[Int(v >> 18)]
                        dst[o + 1] = abc[Int((v >> 12) & 63)]
                        dst[o + 2] = abc[Int((v >> 6) & 63)]
                        dst[o + 3] = abc[Int(v & 63)]
                        i += 3
                        o += 4
                    }
                    let rest = n - i
                    if rest == 1 {
                        let v = UInt32(src[i]) << 16
                        dst[o] = abc[Int(v >> 18)]
                        dst[o + 1] = abc[Int((v >> 12) & 63)]
                        dst[o + 2] = UInt8(ascii: "=")
                        dst[o + 3] = UInt8(ascii: "=")
                    } else if rest == 2 {
                        let v = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8
                        dst[o] = abc[Int(v >> 18)]
                        dst[o + 1] = abc[Int((v >> 12) & 63)]
                        dst[o + 2] = abc[Int((v >> 6) & 63)]
                        dst[o + 3] = UInt8(ascii: "=")
                    }
                }
            }
        }
        return out
    }

    /// Dekodiert Base64 (Leerraum muss bereits entfernt sein); Padding ist optional.
    /// Liefert `nil` bei ungültigen Zeichen oder unmöglicher Länge.
    static func decode(_ input: [UInt8]) -> [UInt8]? {
        var end = input.count
        var padding = 0
        while end > 0 && input[end - 1] == UInt8(ascii: "=") && padding < 2 {
            end -= 1
            padding += 1
        }
        let remainder = end % 4
        if remainder == 1 { return nil }
        if padding > 0 && (end + padding) % 4 != 0 { return nil }
        var out = [UInt8]()
        out.reserveCapacity(end / 4 * 3 + 3)
        var valid = true
        input.withUnsafeBufferPointer { src in
            decodeTable.withUnsafeBufferPointer { table in
                var acc: UInt32 = 0
                var bits = 0
                for i in 0..<end {
                    let v = table[Int(src[i])]
                    if v == 0xFF { valid = false; return }
                    acc = (acc << 6) | UInt32(v)
                    bits += 6
                    if bits >= 8 {
                        bits -= 8
                        out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits)))
                        acc &= (1 << UInt32(bits)) - 1
                    }
                }
            }
        }
        return valid ? out : nil
    }
}

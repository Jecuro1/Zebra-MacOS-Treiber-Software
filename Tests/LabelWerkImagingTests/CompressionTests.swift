import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("CRC16, Deflate, Z64")
struct CompressionTests {

    // MARK: CRC

    @Test("CRC-16/XMODEM Prüfwert und Eigenschaften")
    func crc16() {
        #expect(CRC16.xmodem(Array("123456789".utf8)) == 0x31C3)
        #expect(CRC16.xmodem("123456789".utf8) == 0x31C3)
        #expect(CRC16.xmodem(Data("123456789".utf8)) == 0x31C3)
        // Nicht zusammenhängende Sequenz (langsamer Pfad)
        #expect(CRC16.xmodem("123456789".utf8.lazy.map { $0 }) == 0x31C3)
        #expect(CRC16.xmodem([UInt8]()) == 0x0000)
        #expect(CRC16.xmodem([0x00]) == 0x0000)
        #expect(CRC16.xmodem(Array("A".utf8)) == 0x58E5)
        // Base64 der Bytes C0 00 00 40 FF C0 ("wAAAQP/A"), mit Python berechnet
        #expect(CRC16.xmodem(Array("wAAAQP/A".utf8)) == 0x956C)
        #expect(CRC16.hex4(0x31C3) == "31C3")
        #expect(CRC16.hex4(0x000A) == "000A")
    }

    @Test("CRC-32 (zlib) Prüfwert")
    func crc32() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(Adler32.checksum(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }

    // MARK: Deflate

    @Test("Deflate: Rundlauf verschiedener Daten")
    func deflateRoundTrip() throws {
        var rng = SplitMix64(seed: 1)
        let samples: [[UInt8]] = [
            [],
            [0x42],
            Array("LabelWerk LabelWerk LabelWerk".utf8),
            [UInt8](repeating: 0, count: 100_000),
            (0..<70_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) },
        ]
        for sample in samples {
            let compressed = try Deflate.compress(Data(sample))
            #expect(compressed.first == 0x78, "zlib-Header (CMF) erwartet")
            #expect((Int(compressed[0]) << 8 | Int(compressed[1])) % 31 == 0, "FCHECK")
            let restored = try Deflate.decompress(compressed)
            #expect([UInt8](restored) == sample)
        }
        // Hohe Kompression für Nullen
        let zeros = try Deflate.compress(Data(count: 100_000))
        #expect(zeros.count < 200)
    }

    @Test("Deflate: große Ausgabe ohne bekannte Größe (Streaming)")
    func deflateLarge() throws {
        let big = [UInt8](repeating: 0xAB, count: 5_000_000)
        let compressed = try Deflate.compress(bytes: big)
        // Absichtlich zu kleiner Größenhinweis → Puffer muss wachsen
        let restored = try Deflate.decompress(bytes: compressed, expectedSize: 10)
        #expect(restored.count == big.count)
        #expect(restored == big)
    }

    @Test("Deflate: Ausgabegrenze schützt vor Dekompressionsbomben")
    func deflateLimit() throws {
        let bomb = try Deflate.compress(bytes: [UInt8](repeating: 0, count: 20_000_000))
        #expect(bomb.count < 30_000)
        let limited = try Deflate.decompress(bytes: bomb, limit: 1_000)
        #expect(limited.count == 1_000)
        #expect(try Deflate.decompress(bytes: bomb, limit: 0).isEmpty)
        // Grenze größer als die Daten → vollständige Daten, kein Fehler
        let small = try Deflate.compress(bytes: [1, 2, 3])
        #expect(try Deflate.decompress(bytes: small, limit: 100) == [1, 2, 3])
        // ^GF mit Z64, das mehr Daten enthält als angegeben → nur totalBytes werden entpackt
        let z64 = try Z64.encode(bytes: [UInt8](repeating: 0xFF, count: 5_000_000))
        let bitmap = try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 4, bytesPerRow: 2, data: z64)
        #expect(bitmap.data == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("Deflate: Fehlerfälle")
    func deflateErrors() throws {
        #expect(throws: ImagingError.self) { try Deflate.decompress(Data()) }
        #expect(throws: ImagingError.self) { try Deflate.decompress(Data([1, 2, 3, 4, 5])) }
        let compressed = try Deflate.compress(Data(Array("abcdefghijklmnopqrstuvwxyz".utf8)))
        // Abgeschnitten
        #expect(throws: ImagingError.self) { try Deflate.decompress(compressed.prefix(compressed.count - 6)) }
        // Prüfsumme verfälscht
        var corrupted = compressed
        corrupted[corrupted.count - 1] ^= 0xFF
        #expect(throws: ImagingError.self) { try Deflate.decompress(corrupted) }
        // Daten nach dem Ende des Datenstroms werden ignoriert
        var trailing = compressed
        trailing.append(contentsOf: [0xDE, 0xAD])
        #expect(String(decoding: try Deflate.decompress(trailing), as: UTF8.self) == "abcdefghijklmnopqrstuvwxyz")
    }

    @Test("Stored-Rückfallebene ergibt gültigen zlib-Datenstrom")
    func storedStream() throws {
        var rng = SplitMix64(seed: 5)
        for count in [0, 1, 65_535, 65_536, 140_000] {
            let input = (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let stream = Deflate.storedZlibStream(input)
            #expect(try Deflate.decompress(bytes: stream) == input)
        }
    }

    // MARK: Z64

    @Test("Z64: Format und Rundlauf")
    func z64RoundTrip() throws {
        let payload = Data(Array("LabelWerk LabelWerk ".utf8) + [UInt8](repeating: 0xFF, count: 300))
        let encoded = try Z64.encode(payload)
        #expect(encoded.hasPrefix(":Z64:"))
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: true)
        #expect(parts.count == 3)
        let base64 = String(parts[1])
        let crc = String(parts[2])
        #expect(crc.count == 4)
        #expect(crc == crc.uppercased())
        #expect(UInt16(crc, radix: 16) == CRC16.xmodem(base64.utf8))
        #expect(Data(base64Encoded: base64) != nil, "Standard-Base64 mit Padding")
        #expect(!base64.contains("\n"))
        #expect(try Deflate.decompress(Data(base64Encoded: base64)!) == payload)
        #expect(try Z64.decode(encoded) == payload)
    }

    @Test("Z64: Dekodierung eines extern (Python/zlib) erzeugten Vektors")
    func z64KnownVector() throws {
        let vector = ":Z64:eJzzSUxKzQlPLcpW8CGSBQDNkBH+:9E8C"
        let expected = Data(String(repeating: "LabelWerk ", count: 5).utf8)
        #expect(try Z64.decode(vector) == expected)
        // Ohne CRC, ohne Präfix, mit Leerraum/Zeilenumbrüchen, Kleinbuchstaben-Präfix
        #expect(try Z64.decode(":Z64:eJzzSUxKzQlPLcpW8CGSBQDNkBH+") == expected)
        #expect(try Z64.decode("eJzzSUxKzQlPLcpW8CGSBQDNkBH+") == expected)
        #expect(try Z64.decode(" :z64:eJzzSUxKzQlP\r\nLcpW8CGSBQDNkBH+:9e8c\n") == expected)
        #expect(try Z64.decode(":Z64:eJzzSUxKzQlPLcpW8CGSBQDNkBH+:") == expected)
    }

    @Test("Z64: Fehlerfälle")
    func z64Errors() {
        #expect(throws: ImagingError.checksumMismatch(expected: 0x0000, actual: 0x9E8C)) {
            try Z64.decode(":Z64:eJzzSUxKzQlPLcpW8CGSBQDNkBH+:0000")
        }
        #expect(throws: ImagingError.self) { try Z64.decode(":Z64:eJzzSUxKzQlPLcpW8CGSBQDNkBH+:XYZ") }
        #expect(throws: ImagingError.invalidBase64) { try Z64.decode(":Z64:e$Jz") }
        #expect(throws: ImagingError.self) { try Z64.decode(":Z64:QUJD") }   // "ABC" ist kein zlib
    }

    @Test("Z64: Rundlauf zufälliger Bitmaps")
    func z64Bitmaps() throws {
        var rng = SplitMix64(seed: 64)
        for width in [1, 7, 8, 9, 63, 64, 65, 203] {
            let bitmap = TestSupport.randomBitmap(width: width, height: 13, rng: &rng)
            let encoded = try Z64.encode(Data(bitmap.data))
            #expect(try [UInt8](Z64.decode(encoded)) == bitmap.data)
        }
    }

    // MARK: Base64

    @Test("Base64: Kodierung entspricht Foundation, Dekodierung tolerant")
    func base64() {
        var rng = SplitMix64(seed: 3)
        for count in 0..<40 {
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let ours = String(decoding: Base64.encode(bytes), as: UTF8.self)
            #expect(ours == Data(bytes).base64EncodedString())
            #expect(Base64.decode(Array(ours.utf8)) == bytes)
            // ohne Padding
            let unpadded = ours.replacingOccurrences(of: "=", with: "")
            #expect(Base64.decode(Array(unpadded.utf8)) == bytes)
        }
        #expect(Base64.decode(Array("A".utf8)) == nil)
        #expect(Base64.decode(Array("AB*D".utf8)) == nil)
        #expect(Base64.decode(Array("-_8=".utf8)) == [0xFB, 0xFF])   // URL-sicheres Alphabet
    }
}

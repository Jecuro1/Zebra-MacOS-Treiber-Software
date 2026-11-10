import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("PNGCodec")
struct PNGCodecTests {

    // MARK: Fixtures (mit Pillow erzeugt bzw. dekodiert)

    @Test("Dekodierung aller Farbtypen, Bittiefen, Filter, Adam7 und tRNS", arguments: PNGFixtures.all)
    func fixture(_ fixture: PNGFixture) throws {
        let data = try #require(Data(base64Encoded: fixture.base64))
        let image = try PNGCodec.decode(data)
        #expect(image.width == fixture.width)
        #expect(image.height == fixture.height)
        let expected = TestSupport.bytes(hex: fixture.expectedHex)
        #expect(image.pixels == expected, "\(fixture.name)")
    }

    @Test("Fixture-Abdeckung: alle Farbtypen/Bittiefen und Interlace vorhanden")
    func fixtureCoverage() throws {
        var seen = Set<String>()
        for fixture in PNGFixtures.all {
            let bytes = [UInt8](Data(base64Encoded: fixture.base64)!)
            // IHDR liegt direkt nach der Signatur
            let depth = bytes[24], colorType = bytes[25], interlace = bytes[28]
            seen.insert("\(colorType)/\(depth)")
            if interlace == 1 { seen.insert("adam7/\(colorType)") }
        }
        for combo in ["0/1", "0/2", "0/4", "0/8", "0/16", "2/8", "2/16", "3/1", "3/2", "3/4", "3/8",
                      "4/8", "4/16", "6/8", "6/16"] {
            #expect(seen.contains(combo), "\(combo)")
        }
        for type in [0, 2, 3, 4, 6] { #expect(seen.contains("adam7/\(type)")) }
    }

    // MARK: Kodierung

    @Test("Rundlauf GrayImage (8 Bit, adaptive Filter)")
    func roundTripGray() throws {
        var rng = SplitMix64(seed: 0x9E9)
        let images = [
            TestSupport.randomGray(width: 17, height: 9, rng: &rng),
            GrayImage(width: 1, height: 1, fill: 0),
            GrayImage(width: 64, height: 3, pixels: (0..<192).map { UInt8($0 % 256) }),
            PerformanceTests.makePage(width: 120, height: 900).cropped(x: 0, y: 250, width: 120, height: 500),
        ]
        for image in images {
            let png = PNGCodec.encode(image)
            #expect(Array(png.prefix(8)) == PNGCodec.signature)
            #expect(try PNGCodec.decode(png) == image)
        }
        // Glatter Verlauf komprimiert dank Filter gut
        let gradient = GrayImage(width: 256, height: 256, pixels: (0..<65536).map { UInt8(($0 % 256 + $0 / 256) / 2) })
        #expect(PNGCodec.encode(gradient).count < 4_000)
    }

    @Test("Rundlauf MonoBitmap (1 Bit)")
    func roundTripBitmap() throws {
        var rng = SplitMix64(seed: 0xB17)
        for width in [1, 7, 8, 9, 30, 65] {
            let bitmap = TestSupport.randomBitmap(width: width, height: 5, rng: &rng)
            let png = PNGCodec.encode(bitmap)
            // IHDR: Bittiefe 1, Farbtyp 0
            #expect(png[24] == 1 && png[25] == 0)
            #expect(try PNGCodec.decode(png) == bitmap.toGrayImage())
        }
    }

    @Test("Struktur der kodierten Datei: IHDR, IDAT, IEND mit gültigen CRCs")
    func structure() throws {
        let png = [UInt8](PNGCodec.encode(GrayImage(width: 3, height: 2, pixels: [0, 128, 255, 10, 20, 30])))
        var offset = 8
        var types: [String] = []
        while offset < png.count {
            let length = Int(png.readBE32(at: offset))
            let type = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let crc = png.readBE32(at: offset + 8 + length)
            #expect(crc == CRC32.checksum(Array(png[(offset + 4)..<(offset + 8 + length)])), "\(type)")
            types.append(type)
            offset += 12 + length
        }
        #expect(types == ["IHDR", "IDAT", "IEND"])
        // IHDR: 3 × 2, 8 Bit, Graustufen, kein Interlace
        #expect(Array(png[16..<29]) == [0, 0, 0, 3, 0, 0, 0, 2, 8, 0, 0, 0, 0])
    }

    @Test("Leeres Bild wird als 1 × 1 Weiß kodiert")
    func emptyImage() throws {
        let decoded = try PNGCodec.decode(PNGCodec.encode(GrayImage(width: 0, height: 0)))
        #expect(decoded == GrayImage(width: 1, height: 1, fill: 255))
        let decodedBitmap = try PNGCodec.decode(PNGCodec.encode(MonoBitmap(width: 0, height: 4)))
        #expect(decodedBitmap == GrayImage(width: 1, height: 1, fill: 255))
    }

    // MARK: Fehlerfälle

    @Test("Ungültige Dateien werden abgelehnt")
    func errors() throws {
        let valid = [UInt8](PNGCodec.encode(GrayImage(width: 4, height: 4, fill: 100)))
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data()) }
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data("GIF89a".utf8)) }
        // CRC-Fehler im IHDR
        var badCRC = valid
        badCRC[29] ^= 0xFF
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data(badCRC)) }
        // Abgeschnittene Datei
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data(valid.prefix(40))) }
        // Ungültige Bittiefe (IHDR neu berechnen)
        var badDepth = valid
        badDepth[24] = 3
        let crc = CRC32.checksum(Array(badDepth[12..<29]))
        badDepth.replaceSubrange(29..<33, with: [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data(badDepth)) }
        // Interlace-Methode 2 ist unbekannt
        var badInterlace = valid
        badInterlace[28] = 2
        let crc2 = CRC32.checksum(Array(badInterlace[12..<29]))
        badInterlace.replaceSubrange(29..<33, with: [UInt8(crc2 >> 24), UInt8((crc2 >> 16) & 0xFF), UInt8((crc2 >> 8) & 0xFF), UInt8(crc2 & 0xFF)])
        #expect(throws: ImagingError.unsupportedPNG("Interlace-Methode 2.")) { try PNGCodec.decode(Data(badInterlace)) }
    }

    @Test("Fehlende Palette und unvollständige Bilddaten werden erkannt")
    func structuralErrors() throws {
        // Palettenbild ohne PLTE
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.appendBE32(UInt32(payload.count))
            let body = Array(type.utf8) + payload
            out += body
            out.appendBE32(CRC32.checksum(body))
            return out
        }
        var ihdr: [UInt8] = []
        ihdr.appendBE32(2)
        ihdr.appendBE32(2)
        ihdr += [8, 3, 0, 0, 0]
        let idat = try Deflate.compress(bytes: [0, 0, 0, 0, 0, 0])
        let noPalette = PNGCodec.signature + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", [])
        #expect(throws: ImagingError.invalidPNG("Palette (PLTE) fehlt.")) { try PNGCodec.decode(Data(noPalette)) }

        // Zu wenige Bilddaten (2 × 2 Grau braucht 6 Bytes)
        var grayIHDR: [UInt8] = []
        grayIHDR.appendBE32(2)
        grayIHDR.appendBE32(2)
        grayIHDR += [8, 0, 0, 0, 0]
        let shortIDAT = try Deflate.compress(bytes: [0, 1, 2])
        let short = PNGCodec.signature + chunk("IHDR", grayIHDR) + chunk("IDAT", shortIDAT) + chunk("IEND", [])
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data(short)) }

        // Ungültiger Zeilenfilter 7
        let badFilter = PNGCodec.signature + chunk("IHDR", grayIHDR) + chunk("IDAT", try Deflate.compress(bytes: [7, 1, 2, 0, 3, 4])) + chunk("IEND", [])
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data(badFilter)) }

        // Palettenindex außerhalb der Palette → schwarz; fehlendes IEND wird toleriert
        let palette = chunk("PLTE", [255, 255, 255])
        let outOfRange = PNGCodec.signature + chunk("IHDR", ihdr) + palette + chunk("IDAT", try Deflate.compress(bytes: [0, 0, 5, 0, 0, 0]))
        #expect(try PNGCodec.decode(Data(outOfRange)).pixels == [255, 0, 255, 255])

        // Unbekannter kritischer Chunk
        let unknownCritical = PNGCodec.signature + chunk("IHDR", grayIHDR) + chunk("ABCD", [1]) + chunk("IDAT", try Deflate.compress(bytes: [0, 1, 2, 0, 3, 4])) + chunk("IEND", [])
        #expect(throws: ImagingError.self) { try PNGCodec.decode(Data(unknownCritical)) }
        // Unbekannter optionaler Chunk wird übersprungen
        let unknownAncillary = PNGCodec.signature + chunk("IHDR", grayIHDR) + chunk("abCD", [1]) + chunk("IDAT", try Deflate.compress(bytes: [0, 1, 2, 0, 3, 4])) + chunk("IEND", [])
        #expect(try PNGCodec.decode(Data(unknownAncillary)).pixels == [1, 2, 3, 4])
    }
}

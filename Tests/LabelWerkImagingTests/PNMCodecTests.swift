import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("PNMCodec")
struct PNMCodecTests {

    @Test("P1 (PBM ASCII) mit Kommentaren und ohne Trennzeichen")
    func p1() throws {
        let text = "P1\n# Kommentar\n4 2\n1 0 1 0\n0111\n"
        let image = try PNMCodec.decode(Data(text.utf8))
        #expect(image.width == 4 && image.height == 2)
        #expect(image.pixels == [0, 255, 0, 255, 255, 0, 0, 0])
    }

    @Test("P2 (PGM ASCII) mit Skalierung")
    func p2() throws {
        let image = try PNMCodec.decode(Data("P2 3 1 15\n0 7 15".utf8))
        // (v·255 + 7) / 15: 0 → 0, 7 → 119, 15 → 255
        #expect(image.pixels == [0, 119, 255])
        let full = try PNMCodec.decode(Data("P2\n2 2\n255\n# mitten drin\n0 64\n128 255\n".utf8))
        #expect(full.pixels == [0, 64, 128, 255])
    }

    @Test("P3 (PPM ASCII) → Luminanz")
    func p3() throws {
        let image = try PNMCodec.decode(Data("P3 3 1 255  255 0 0  0 255 0  10 20 30".utf8))
        // (299·255)/1000 = 76; (587·255)/1000 = 149; (2990 + 11740 + 3420)/1000 = 18
        #expect(image.pixels == [76, 149, 18])
    }

    @Test("P4 (PBM binär) mit Zeilenauffüllung")
    func p4() throws {
        let data = TestSupport.data(.text("P4\n10 2\n"), .bytes([0xC0, 0x3F, 0x00, 0x40]))
        let image = try PNMCodec.decode(data)
        #expect(image.width == 10 && image.height == 2)
        // Zeile 0: ##........ (Füllbits 0x3F ignoriert), Zeile 1: .........#
        #expect(image.pixels == [0, 0, 255, 255, 255, 255, 255, 255, 255, 255,
                                 255, 255, 255, 255, 255, 255, 255, 255, 255, 0])
        // Rundlauf mit dem Encoder
        let bitmap = TestSupport.bitmap(["#.#.#.#.#", ".#.#.#.#."])
        #expect(try PNMCodec.decode(PNMCodec.encode(bitmap)) == bitmap.toGrayImage())
    }

    @Test("P5 (PGM binär) 8 und 16 Bit")
    func p5() throws {
        let eight = TestSupport.data(.text("P5 2 2 255\n"), .bytes([0, 10, 200, 255]))
        #expect(try PNMCodec.decode(eight).pixels == [0, 10, 200, 255])
        // 16 Bit, Maximalwert 65535: (v·255 + 32767) / 65535
        let sixteen = TestSupport.data(.text("P5\n3 1\n65535\n"), .bytes([0x00, 0x00, 0x80, 0x00, 0xFF, 0xFF]))
        #expect(try PNMCodec.decode(sixteen).pixels == [0, 128, 255])
        // Maximalwert 1000 (zweibytig)
        let thousand = TestSupport.data(.text("P5 1 1 1000 "), .bytes([0x01, 0xF4]))
        #expect(try PNMCodec.decode(thousand).pixels == [128])   // (500·255 + 500)/1000 = 128
        // Rundlauf mit dem Encoder
        let image = GrayImage(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 250])
        #expect(try PNMCodec.decode(PNMCodec.encode(image)) == image)
    }

    @Test("P6 (PPM binär) → Luminanz")
    func p6() throws {
        let data = TestSupport.data(.text("P6 2 1 255\n"), .bytes([255, 255, 255, 0, 0, 255]))
        // Weiß → 255, Blau → (114·255)/1000 = 29
        #expect(try PNMCodec.decode(data).pixels == [255, 29])
        let sixteen = TestSupport.data(.text("P6 1 1 65535\n"), .bytes([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]))
        #expect(try PNMCodec.decode(sixteen).pixels == [76])
    }

    @Test("Fehlerfälle")
    func errors() {
        let cases: [Data] = [
            Data(),
            Data("P7 1 1 255\n".utf8),
            Data("Q5 1 1 255\n".utf8),
            Data("P5 2 2 255\n".utf8) + Data([0, 1]),     // zu wenige Daten
            Data("P1 2 1 1 2".utf8),                        // ungültiges Bit
            Data("P2 2 1 255 7".utf8),                      // Wert fehlt
            Data("P2 0 1 255".utf8),                        // Breite 0
            Data("P2 1 1 0 0".utf8),                        // Maximalwert 0
            Data("P5 1 1 70000 \u{0}\u{0}".utf8),           // Maximalwert zu groß
            Data("P5 x 1 255".utf8),                        // keine Zahl
            Data("P5 1 1 255".utf8),                        // Binärdaten fehlen
        ]
        for data in cases {
            #expect(throws: ImagingError.self, "\(String(decoding: data, as: UTF8.self))") { try PNMCodec.decode(data) }
        }
        #expect(throws: ImagingError.imageTooLarge(width: 100_000, height: 1)) {
            try PNMCodec.decode(Data("P5 100000 1 255\n".utf8))
        }
    }
}

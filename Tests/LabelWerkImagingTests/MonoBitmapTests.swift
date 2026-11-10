import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("MonoBitmap")
struct MonoBitmapTests {

    @Test("Aufbau: MSB zuerst, 1 = schwarz, Füllbits = 0")
    func layout() {
        var bitmap = MonoBitmap(width: 10, height: 2)
        #expect(bitmap.bytesPerRow == 2)
        #expect(bitmap.data == [0, 0, 0, 0])
        bitmap[0, 0] = true
        bitmap[9, 1] = true
        #expect(bitmap.data == [0x80, 0x00, 0x00, 0x40])
        #expect(bitmap[0, 0] && bitmap[9, 1] && !bitmap[1, 0])
        bitmap[0, 0] = false
        #expect(bitmap.data == [0x00, 0x00, 0x00, 0x40])
        #expect(MonoBitmap(width: 8, height: 1).bytesPerRow == 1)
        #expect(MonoBitmap(width: 9, height: 1).bytesPerRow == 2)
        #expect(MonoBitmap(width: 0, height: 3).bytesPerRow == 0)
    }

    @Test("init(data:) löscht gesetzte Füllbits")
    func paddingMasked() {
        let bitmap = MonoBitmap(width: 3, height: 2, data: [0xFF, 0x5F])
        #expect(bitmap.data == [0xE0, 0x40])
        #expect(bitmap.blackPixelCount == 4)
        let exact = MonoBitmap(width: 16, height: 1, data: [0xFF, 0xFF])
        #expect(exact.data == [0xFF, 0xFF])
    }

    @Test("Leer-Erkennung und Zählung")
    func blankAndCount() {
        var bitmap = MonoBitmap(width: 12, height: 3)
        #expect(bitmap.isBlank)
        #expect(bitmap.blackPixelCount == 0)
        bitmap[11, 1] = true
        bitmap[3, 1] = true
        #expect(!bitmap.isBlank)
        #expect(bitmap.isRowBlank(0) && !bitmap.isRowBlank(1) && bitmap.isRowBlank(2))
        #expect(bitmap.blackPixelCount == 2)
        #expect(Array(bitmap.row(1)) == [0x10, 0x10])
    }

    @Test("Drehen und Spiegeln an einem Handbeispiel")
    func geometryExample() {
        let bitmap = TestSupport.bitmap([
            "##.",
            "...",
        ])
        #expect(TestSupport.rows(bitmap.rotated(.r90)) == [".#", ".#", ".."])
        #expect(TestSupport.rows(bitmap.rotated(.r270)) == ["..", "#.", "#."])
        #expect(TestSupport.rows(bitmap.rotated180()) == ["...", ".##"])
        #expect(bitmap.rotated(.r180) == bitmap.rotated180())
        #expect(bitmap.rotated(.r0) == bitmap)
        #expect(TestSupport.rows(bitmap.mirrored()) == [".##", "..."])
        #expect(TestSupport.rows(bitmap.flippedVertically()) == ["...", "##."])
    }

    @Test("Geometrie gegen Pixel-Referenz (Breiten 1…40)")
    func geometryRandom() {
        var rng = SplitMix64(seed: 42)
        for width in 1...40 {
            let height = Int(rng.next() % 6) + 1
            let bitmap = TestSupport.randomBitmap(width: width, height: height, rng: &rng)
            let mirrored = bitmap.mirrored()
            let rot180 = bitmap.rotated180()
            let rot90 = bitmap.rotated(.r90)
            let rot270 = bitmap.rotated(.r270)
            #expect(rot90.width == height && rot90.height == width)
            var ok = true
            for y in 0..<height {
                for x in 0..<width {
                    let v = bitmap[x, y]
                    if mirrored[width - 1 - x, y] != v { ok = false }
                    if rot180[width - 1 - x, height - 1 - y] != v { ok = false }
                    if rot90[height - 1 - y, x] != v { ok = false }
                    if rot270[y, width - 1 - x] != v { ok = false }
                }
            }
            #expect(ok, "Breite \(width)")
            // Füllbits bleiben 0 (Invariante): Neuaufbau aus Daten ändert nichts
            for result in [mirrored, rot180, rot90, rot270] {
                #expect(MonoBitmap(width: result.width, height: result.height, data: result.data) == result)
            }
            #expect(mirrored.mirrored() == bitmap)
            #expect(rot180.rotated180() == bitmap)
            #expect(rot90.rotated(.r270) == bitmap)
        }
    }

    @Test("Invertieren lässt Füllbits bei 0")
    func invert() {
        let bitmap = TestSupport.bitmap(["#.#.#", "....."])
        let inverted = bitmap.inverted()
        #expect(TestSupport.rows(inverted) == [".#.#.", "#####"])
        #expect(inverted.data == [0x50, 0xF8])
        #expect(inverted.inverted() == bitmap)
        #expect(inverted.blackPixelCount == 7)
    }

    @Test("Ausschneiden gegen Pixel-Referenz (inkl. Bereiche außerhalb)")
    func cropRandom() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let width = Int(rng.next() % 30) + 1
            let height = Int(rng.next() % 5) + 1
            let bitmap = TestSupport.randomBitmap(width: width, height: height, rng: &rng)
            let cx = Int(rng.next() % 40) - 10
            let cy = Int(rng.next() % 8) - 2
            let cw = Int(rng.next() % 35)
            let ch = Int(rng.next() % 7)
            let crop = bitmap.cropped(x: cx, y: cy, width: cw, height: ch)
            #expect(crop.width == cw && crop.height == ch)
            var ok = true
            for y in 0..<ch {
                for x in 0..<cw {
                    let sx = x + cx, sy = y + cy
                    let expected = sx >= 0 && sx < width && sy >= 0 && sy < height && bitmap[sx, sy]
                    if crop[x, y] != expected { ok = false }
                }
            }
            #expect(ok, "crop \(cx),\(cy) \(cw)×\(ch) aus \(width)×\(height)")
            #expect(MonoBitmap(width: cw, height: ch, data: crop.data) == crop)
        }
    }

    @Test("Rechts abschneiden (wie JobEncoder)")
    func cropRight() {
        let bitmap = TestSupport.bitmap(["##########", "#........#"])
        let cut = bitmap.cropped(x: 0, y: 0, width: 8, height: 2)
        #expect(cut.data == [0xFF, 0x80])
        #expect(bitmap.cropped(x: 0, y: 0, width: 10, height: 2) == bitmap)
    }

    @Test("Umwandlung in Graustufen")
    func toGray() {
        let bitmap = TestSupport.bitmap(["#.", ".#"])
        #expect(bitmap.toGrayImage().pixels == [0, 255, 255, 0])
        // Hin und zurück über die Schwelle
        var rng = SplitMix64(seed: 99)
        let random = TestSupport.randomBitmap(width: 21, height: 9, rng: &rng)
        #expect(Ditherer.dither(random.toGrayImage(), algorithm: .threshold, threshold: 128) == random)
    }

    @Test("Prädikat-Initialisierer")
    func predicateInit() {
        let checker = MonoBitmap(width: 4, height: 2) { x, y in (x + y) % 2 == 0 }
        #expect(checker.data == [0xA0, 0x50])
    }
}

import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// Bitgenaue Prüfung der Rasterung nach ARCHITECTURE.md §4.1. Die erwarteten Werte der
/// kleinen Beispiele sind von Hand berechnet (Rechenweg in den Kommentaren).
@Suite("Ditherer")
struct DithererTests {

    // MARK: Matrizen

    @Test("Bayer- und Halbtonmatrix sind Permutationen von 0…63 und entsprechen §4.1")
    func matrices() {
        #expect(Ditherer.bayerMatrix.count == 64)
        #expect(Ditherer.halftoneMatrix.count == 64)
        #expect(Ditherer.bayerMatrix.sorted() == Array(0..<64))
        #expect(Ditherer.halftoneMatrix.sorted() == Array(0..<64))
        // Stichproben aus §4.1
        #expect(Array(Ditherer.bayerMatrix[0..<8]) == [0, 32, 8, 40, 2, 34, 10, 42])
        #expect(Array(Ditherer.bayerMatrix[56..<64]) == [63, 31, 55, 23, 61, 29, 53, 21])
        #expect(Array(Ditherer.halftoneMatrix[0..<8]) == [24, 10, 12, 26, 35, 47, 49, 37])
        #expect(Array(Ditherer.halftoneMatrix[56..<64]) == [32, 40, 54, 38, 31, 21, 19, 29])
        #expect(Ditherer.bayerMatrix[4 * 8 + 4] == 1)
        #expect(Ditherer.halftoneMatrix[1 * 8 + 1] == 0)
    }

    // MARK: Schwelle

    @Test("Schwelle: schwarz ⇔ L < T")
    func threshold() {
        let image = GrayImage(width: 9, height: 1, pixels: [0, 127, 128, 255, 100, 200, 127, 128, 50])
        // T = 128 → 1 1 0 0 1 0 1 0 | 1 → 0xCA 0x80
        #expect(Ditherer.dither(image, algorithm: .threshold, threshold: 128).data == [0xCA, 0x80])
        // T = 1 → nur L = 0 ist schwarz
        #expect(Ditherer.dither(image, algorithm: .threshold, threshold: 1).data == [0x80, 0x00])
        // T = 201 → alles außer 255 schwarz: 1 1 1 0 1 1 1 1 | 1
        #expect(Ditherer.dither(image, algorithm: .threshold, threshold: 201).data == [0xEF, 0x80])
    }

    @Test("Schwelle wird auf 1…254 begrenzt")
    func thresholdClamping() {
        let image = GrayImage(width: 4, height: 1, pixels: [0, 1, 253, 254])
        // 0 → T = 1: nur 0 schwarz
        #expect(Ditherer.dither(image, algorithm: .threshold, threshold: 0).data == [0x80])
        #expect(Ditherer.dither(image, algorithm: .threshold, threshold: -50).data == [0x80])
        // 999 → T = 254: 0, 1, 253 schwarz, 254 nicht
        #expect(Ditherer.dither(image, algorithm: .threshold, threshold: 999).data == [0xE0])
        // Weiß (255) wird bei Schwelle und Fehlerdiffusion nie schwarz, auch nicht bei T = 254
        let white = GrayImage(width: 8, height: 2, fill: 255)
        for algorithm in [DitherAlgorithm.threshold, .floydSteinberg, .atkinson, .stucki] {
            #expect(Ditherer.dither(white, algorithm: algorithm, threshold: 254).isBlank, "\(algorithm)")
        }
    }

    // MARK: Geordnet

    @Test("Ordered (Bayer): t = B·4 + 2 + (T − 128)")
    func ordered() {
        // Zeile 0: B = 0 32 8 40 2 34 10 42 → t = 2 130 34 162 10 138 42 170
        // Zeile 1: B = 48 16 56 24 50 18 58 26 → t = 194 66 226 98 202 74 234 106
        let image = GrayImage(width: 8, height: 2, pixels: [
            2, 129, 34, 161, 10, 137, 42, 170,
            193, 66, 0, 255, 202, 73, 234, 105,
        ])
        // Zeile 0: n j n j n j n n → 0x54; Zeile 1: j n j n n j n j → 0xA5
        #expect(Ditherer.dither(image, algorithm: .ordered, threshold: 128).data == [0x54, 0xA5])

        // T = 100 verschiebt um −28: Zeile 0 t = −26 102 6 134 −18 110 14 142
        let shifted = GrayImage(width: 8, height: 1, pixels: [0, 101, 6, 133, 0, 110, 13, 141])
        // n j n j n n j j → 0x53
        #expect(Ditherer.dither(shifted, algorithm: .ordered, threshold: 100).data == [0x53])
    }

    @Test("Ordered: Matrix wiederholt sich alle 8 Pixel (x % 8, y % 8)")
    func orderedTiling() {
        // L = 2: schwarz ⇔ B·4 + 2 > 2 ⇔ B > 0 → nur Zellen mit B = 0 bleiben weiß.
        let image = GrayImage(width: 17, height: 9, fill: 2)
        let bitmap = Ditherer.dither(image, algorithm: .ordered, threshold: 128)
        var white: [String] = []
        for y in 0..<9 { for x in 0..<17 where !bitmap[x, y] { white.append("\(x),\(y)") } }
        #expect(white == ["0,0", "8,0", "16,0", "0,8", "8,8", "16,8"])
    }

    // MARK: Halbton

    @Test("Halftone (Clustered Dot): t = H·4 + 2 + (T − 128)")
    func halftone() {
        // Zeile 0: H = 24 10 12 26 35 47 49 37 → t = 98 42 50 106 142 190 198 150
        let image = GrayImage(width: 8, height: 1, pixels: [97, 42, 49, 106, 141, 191, 197, 150])
        // j n j n j n j n → 0xAA
        #expect(Ditherer.dither(image, algorithm: .halftone, threshold: 128).data == [0xAA])

        // L = 3: schwarz ⇔ H ≥ 1 → nur (1,1) (H = 0) bleibt weiß
        let flat = Ditherer.dither(GrayImage(width: 8, height: 8, fill: 3), algorithm: .halftone, threshold: 128)
        #expect(flat.blackPixelCount == 63)
        #expect(flat[1, 1] == false)
    }

    // MARK: Fehlerdiffusion

    @Test("Floyd–Steinberg: Hand-Rechnung 3 × 2")
    func floydSteinberg() {
        // (0,0) v=100 → schwarz, e=100: (1,0)+=43 (0,1)+=31 (1,1)+=6
        // (1,0) v=193 → weiß, e=−62: (2,0)+=−27 (0,1)+=−11 (1,1)+=−19 (2,1)+=−3
        // (2,0) v=155−27=128 → weiß (Abschneiden Richtung 0!), e=−127: (1,1)+=−23 (2,1)+=−39
        // (0,1) v=50+20=70 → schwarz, e=70: (1,1)+=30
        // (1,1) v=128−36+30=122 → schwarz, e=122: (2,1)+=53
        // (2,1) v=255−42+53=266 → weiß
        let image = GrayImage(width: 3, height: 2, pixels: [100, 150, 155, 50, 128, 255])
        let bitmap = Ditherer.dither(image, algorithm: .floydSteinberg, threshold: 128)
        #expect(TestSupport.rows(bitmap) == ["#..", "##."])
        #expect(bitmap.data == [0x80, 0xC0])
    }

    @Test("Atkinson: Hand-Rechnung 3 × 3")
    func atkinson() {
        // (0,0) v=100 → schwarz, Anteil 12 → (1,0) (2,0) (0,1) (1,1) (0,2)
        // (1,0) v=212 → weiß, e=−43, Anteil −5
        // (2,0) v=60+7=67 → schwarz, Anteil 8
        // (0,1) v=180+7=187 → weiß, e=−68, Anteil −8
        // (1,1) v=90+7=97 → schwarz, Anteil 12
        // (2,1) v=140+7=147 → weiß, e=−108, Anteil −13
        // (0,2) v=30+16=46 → schwarz, Anteil 5
        // (1,2) v=220−9=211 → weiß, e=−44, Anteil −5
        // (2,2) v=128+7=135 → weiß
        let image = GrayImage(width: 3, height: 3, pixels: [100, 200, 60, 180, 90, 140, 30, 220, 128])
        let bitmap = Ditherer.dither(image, algorithm: .atkinson, threshold: 128)
        #expect(TestSupport.rows(bitmap) == ["#.#", ".#.", "#.."])
    }

    @Test("Stucki: Hand-Rechnung 3 × 3")
    func stucki() {
        // (0,0) v=100 → schwarz, e=100: Anteile 8→19, 4→9, 2→4, 1→2
        // (1,0) v=219 → weiß, e=−36: 8→−6, 4→−3, 2→−1, 1→0
        // (2,0) v=63 → schwarz, e=63: 8→12, 4→6, 2→3, 1→1
        // (0,1) v=199 → weiß, e=−56: 8→−10, 4→−5, 2→−2
        // (1,1) v=89 → schwarz, e=89: 8→16, 4→8
        // (2,1) v=164 → weiß, e=−91: 8→−17, 4→−8, 2→−4
        // (0,2) v=33 → schwarz, e=33: 8→6, 4→3
        // (1,2) v=233 → weiß, e=−22: 8→−4
        // (2,2) v=128−5=123 → schwarz
        let image = GrayImage(width: 3, height: 3, pixels: [100, 200, 60, 180, 90, 140, 30, 220, 128])
        let bitmap = Ditherer.dither(image, algorithm: .stucki, threshold: 128)
        #expect(TestSupport.rows(bitmap) == ["#.#", ".#.", "#.#"])
    }

    @Test("Fehlerdiffusion verwendet T als Entscheidungsschwelle")
    func diffusionThreshold() {
        // Einzelpixel: schwarz ⇔ L < T
        for algorithm in [DitherAlgorithm.floydSteinberg, .atkinson, .stucki] {
            let pixel = GrayImage(width: 1, height: 1, pixels: [150])
            #expect(Ditherer.dither(pixel, algorithm: algorithm, threshold: 151).data == [0x80])
            #expect(Ditherer.dither(pixel, algorithm: algorithm, threshold: 150).data == [0x00])
        }
    }

    @Test("Mittelgrau ergibt bei Fehlerdiffusion ca. 50 % Deckung")
    func diffusionCoverage() {
        let gray = GrayImage(width: 64, height: 64, fill: 128)
        for algorithm in [DitherAlgorithm.floydSteinberg, .stucki, .ordered, .halftone] {
            let ratio = Double(Ditherer.dither(gray, algorithm: algorithm, threshold: 128).blackPixelCount) / 4096
            #expect(abs(ratio - 0.5) < 0.05, "\(algorithm): \(ratio)")
        }
        // Atkinson verteilt nur 6/8 des Fehlers → bewusst kontrastreicher, aber plausibel
        let atkinson = Double(Ditherer.dither(gray, algorithm: .atkinson, threshold: 128).blackPixelCount) / 4096
        #expect(atkinson > 0.3 && atkinson < 0.7)
    }

    // MARK: Abgleich mit der Referenzimplementierung

    @Test("Optimierte Implementierung == Referenz (zufällige Bilder, alle Verfahren, Schwellen)",
          arguments: DitherAlgorithm.allCases)
    func matchesReference(algorithm: DitherAlgorithm) {
        var rng = SplitMix64(seed: 0xD17E + UInt64(algorithm.rawValue.count))
        let sizes = [(1, 1), (1, 9), (9, 1), (2, 2), (7, 3), (8, 8), (13, 11), (33, 17), (64, 5)]
        for (w, h) in sizes {
            let image = TestSupport.randomGray(width: w, height: h, rng: &rng)
            for t in [1, 64, 127, 128, 129, 200, 254] {
                let fast = Ditherer.dither(image, algorithm: algorithm, threshold: t)
                let reference = ReferenceDitherer.bitmap(image, algorithm: algorithm, threshold: t)
                #expect(fast == reference, "\(algorithm) \(w)×\(h) T=\(t)")
            }
        }
    }

    @Test("Extremwerte: Schwarz bleibt schwarz, Weiß bleibt weiß", arguments: DitherAlgorithm.allCases)
    func extremes(algorithm: DitherAlgorithm) {
        let black = Ditherer.dither(GrayImage(width: 37, height: 5, fill: 0), algorithm: algorithm, threshold: 128)
        #expect(black.blackPixelCount == 37 * 5)
        // Füllbits bleiben 0
        #expect(black.data[4] == 0xF8)
        let white = Ditherer.dither(GrayImage(width: 37, height: 5, fill: 255), algorithm: algorithm, threshold: 128)
        #expect(white.isBlank)
    }

    @Test("Leeres Bild ergibt leere Bitmap")
    func empty() {
        for algorithm in DitherAlgorithm.allCases {
            let result = Ditherer.dither(GrayImage(width: 0, height: 4), algorithm: algorithm)
            #expect(result.width == 0 && result.height == 4 && result.data.isEmpty)
        }
    }
}

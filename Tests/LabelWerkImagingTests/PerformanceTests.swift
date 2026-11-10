import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// Laufzeitanforderung: Rastern + Z64-Kodierung einer 4-Zoll-Seite (832 × 1218 Punkte bei
/// 203 dpi) in < 150 ms – auch im Debug-Build.
@Suite("Leistung", .serialized)
struct PerformanceTests {

    /// Realistische Testseite: Verläufe, Rauschen, Text-ähnliche Blöcke, weiße Ränder.
    static func makePage(width: Int = 832, height: Int = 1218) -> GrayImage {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if y < 300 {
                    // horizontaler Verlauf
                    pixels[i] = UInt8(x * 255 / max(1, width - 1))
                } else if y < 600 {
                    // Foto-ähnliches Rauschen um einen Verlauf
                    let base = (y - 300) * 255 / 300
                    let noise = Int(rng.next() % 41) - 20
                    pixels[i] = UInt8(clamping: base + noise)
                } else if y < 900 {
                    // Balken (Barcode-ähnlich) und Textblöcke
                    pixels[i] = ((x / 6) % 3 == 0 || (y / 20) % 2 == 0 && (x / 4) % 5 == 0) ? 0 : 255
                }
                // Rest bleibt weiß.
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    static func bestOf(_ runs: Int, _ body: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock()
        var best = Duration.seconds(1000)
        for _ in 0..<runs {
            let elapsed = try clock.measure(body)
            best = min(best, elapsed)
        }
        return best
    }

    @Test("Rastern + Z64 einer 832 × 1218-Seite < 150 ms", arguments: DitherAlgorithm.allCases)
    func ditherAndZ64(algorithm: DitherAlgorithm) throws {
        let page = Self.makePage()
        var result = ""
        var bitmap = MonoBitmap(width: 0, height: 0)
        let elapsed = Self.bestOf(5) {
            bitmap = Ditherer.dither(page, algorithm: algorithm, threshold: 128)
            result = ZPLGraphicEncoder.graphicField(bitmap, compression: .z64)
        }
        print("Leistung \(algorithm.rawValue): \(elapsed)")
        #expect(elapsed < .milliseconds(150), "\(algorithm.rawValue): \(elapsed)")
        // Ergebnis prüfen (außerhalb der Zeitmessung).
        #expect(String(result.prefix(28)) == "^GFA,126672,126672,104,:Z64:")
        let payload = String(result.split(separator: ",", maxSplits: 4).last!)
        let decoded = try Z64.decode(payload)
        #expect([UInt8](decoded) == bitmap.data)
    }
}

/// Deterministischer Zufallsgenerator für reproduzierbare Tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

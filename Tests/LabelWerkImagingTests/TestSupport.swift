import Foundation
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// Hilfsfunktionen für die Imaging-Tests.
enum TestSupport {

    /// Hex-String (Groß-/Kleinbuchstaben, ohne Trenner) → Bytes.
    static func bytes(hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        precondition(chars.count % 2 == 0, "ungerade Hexlänge")
        func value(_ c: UInt8) -> UInt8 {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            default: preconditionFailure("kein Hexzeichen")
            }
        }
        return stride(from: 0, to: chars.count, by: 2).map { value(chars[$0]) << 4 | value(chars[$0 + 1]) }
    }

    /// Bitmap aus Zeilenstrings, `#` = schwarz, `.` = weiß.
    static func bitmap(_ rows: [String]) -> MonoBitmap {
        let width = rows.first?.count ?? 0
        let chars = rows.map { Array($0) }
        precondition(chars.allSatisfy { $0.count == width })
        return MonoBitmap(width: width, height: rows.count) { x, y in chars[y][x] == "#" }
    }

    /// Bitmap als Zeilenstrings (`#`/`.`).
    static func rows(_ bitmap: MonoBitmap) -> [String] {
        (0..<bitmap.height).map { y in String((0..<bitmap.width).map { bitmap[$0, y] ? "#" : "." }) }
    }

    /// Zufällige Bitmap mit wählbarer Schwarzdichte und Neigung zu Läufen/Wiederholungen.
    static func randomBitmap(width: Int, height: Int, rng: inout SplitMix64, density: Double = 0.5) -> MonoBitmap {
        var bitmap = MonoBitmap(width: width, height: height)
        let style = rng.next() % 4
        for y in 0..<height {
            // Gelegentlich Zeile der Vorzeile gleich lassen (testet ':')
            if y > 0 && style >= 2 && rng.next() % 3 == 0 {
                for x in 0..<width { bitmap[x, y] = bitmap[x, y - 1] }
                continue
            }
            var current = Double(rng.next() % 1000) / 1000 < density
            for x in 0..<width {
                switch style {
                case 0:
                    bitmap[x, y] = Double(rng.next() % 1000) / 1000 < density
                default:
                    // Lauflängen-lastig
                    if rng.next() % 9 == 0 { current.toggle() }
                    bitmap[x, y] = current
                }
            }
        }
        return bitmap
    }

    /// Zufälliges Graustufenbild.
    static func randomGray(width: Int, height: Int, rng: inout SplitMix64) -> GrayImage {
        GrayImage(width: width, height: height, pixels: (0..<(width * height)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }

    /// Daten aus ASCII-Teilen und Rohbytes zusammensetzen.
    static func data(_ parts: DataPart...) -> Data {
        var out = Data()
        for part in parts {
            switch part {
            case .text(let s): out.append(contentsOf: Array(s.utf8))
            case .bytes(let b): out.append(contentsOf: b)
            }
        }
        return out
    }

    enum DataPart {
        case text(String)
        case bytes([UInt8])
    }

    /// Lesbare Darstellung (Steuerzeichen und Nicht-ASCII als \xHH) für Fehlermeldungen.
    static func printable(_ data: Data) -> String {
        var s = ""
        for b in data {
            switch b {
            case 0x0A: s += "\\n"
            case 0x0D: s += "\\r"
            case 0x20...0x7E: s += String(UnicodeScalar(b))
            default: s += String(format: "\\x%02X", b)
            }
        }
        return s
    }
}

// MARK: - Referenzimplementierung der Rasterung (direkt nach ARCHITECTURE.md §4.1)

/// Bewusst einfache, langsame Umsetzung der Spezifikation (2D-Felder, keine Optimierungen),
/// gegen die die optimierte Implementierung geprüft wird.
enum ReferenceDitherer {
    static func dither(_ image: GrayImage, algorithm: DitherAlgorithm, threshold: Int) -> [[Bool]] {
        let T = min(max(threshold, 1), 254)
        let w = image.width, h = image.height
        var black = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        func L(_ x: Int, _ y: Int) -> Int { Int(image.pixels[y * w + x]) }
        switch algorithm {
        case .threshold:
            for y in 0..<h { for x in 0..<w { black[y][x] = L(x, y) < T } }
        case .ordered, .halftone:
            let m = algorithm == .ordered ? Ditherer.bayerMatrix : Ditherer.halftoneMatrix
            for y in 0..<h {
                for x in 0..<w {
                    let t = Int(m[(y % 8) * 8 + x % 8]) * 4 + 2 + (T - 128)
                    black[y][x] = L(x, y) < t
                }
            }
        case .floydSteinberg, .atkinson, .stucki:
            let kernel: [(dx: Int, dy: Int, w: Int32)]
            let D: Int32
            switch algorithm {
            case .floydSteinberg:
                kernel = [(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)]
                D = 16
            case .atkinson:
                kernel = [(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1), (1, 1, 1), (0, 2, 1)]
                D = 8
            default:
                kernel = [(1, 0, 8), (2, 0, 4),
                          (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
                          (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1)]
                D = 42
            }
            var err = [[Int32]](repeating: [Int32](repeating: 0, count: w), count: h)
            for y in 0..<h {
                for x in 0..<w {
                    let v = Int32(L(x, y)) + err[y][x]
                    let out: Int32 = v < Int32(T) ? 0 : 255
                    black[y][x] = out == 0
                    let e = v - out
                    for k in kernel {
                        let nx = x + k.dx, ny = y + k.dy
                        if nx >= 0 && nx < w && ny >= 0 && ny < h {
                            err[ny][nx] += e * k.w / D
                        }
                    }
                }
            }
        }
        return black
    }

    static func bitmap(_ image: GrayImage, algorithm: DitherAlgorithm, threshold: Int) -> MonoBitmap {
        let black = dither(image, algorithm: algorithm, threshold: threshold)
        return MonoBitmap(width: image.width, height: image.height) { x, y in black[y][x] }
    }
}

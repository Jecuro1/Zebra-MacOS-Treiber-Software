import Foundation
import LabelWerkCore

/// Rasterung von Graustufen in 1-Bit-Bitmaps – bitgenau nach ARCHITECTURE.md §4.1
/// (identisch zum C-Filter `rastertolabelwerk`).
///
/// Eingabe ist die Luminanz `L(x, y)` ∈ 0…255 (0 = schwarz), Schwelle `T` ∈ 1…254
/// (Werte außerhalb werden begrenzt). Ein schwarzes Ausgabepixel bedeutet „Punkt brennt“.
/// Alle Divisionen sind Ganzzahldivisionen mit Abschneiden Richtung 0.
public enum Ditherer {

    /// Bayer-Matrix 8 × 8 für `ordered` (zeilenweise, Index `y % 8 * 8 + x % 8`).
    public static let bayerMatrix: [Int32] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// Clustered-Dot-Matrix 8 × 8 für `halftone` (zeilenweise, Index `y % 8 * 8 + x % 8`).
    public static let halftoneMatrix: [Int32] = [
        24, 10, 12, 26, 35, 47, 49, 37,
         8,  0,  2, 14, 45, 59, 61, 51,
        22,  6,  4, 16, 43, 57, 63, 53,
        30, 20, 18, 28, 33, 41, 55, 39,
        34, 46, 48, 36, 25, 11, 13, 27,
        44, 58, 60, 50,  9,  1,  3, 15,
        42, 56, 62, 52, 23,  7,  5, 17,
        32, 40, 54, 38, 31, 21, 19, 29,
    ]

    /// Rastert ein Graustufenbild.
    ///
    /// - Parameters:
    ///   - image: Luminanzbild (0 = schwarz, 255 = weiß).
    ///   - algorithm: Rasterverfahren.
    ///   - threshold: Schwelle `T` (1…254, wird begrenzt). Bei `ordered`/`halftone` verschiebt
    ///     `T − 128` die Matrix, bei Fehlerdiffusion ist `T` die Entscheidungsschwelle.
    /// - Returns: Bitmap mit 1 = schwarz.
    public static func dither(_ image: GrayImage, algorithm: DitherAlgorithm, threshold: Int = 128) -> MonoBitmap {
        let t = Int32(min(max(threshold, 1), 254))
        guard image.width > 0, image.height > 0 else {
            return MonoBitmap(width: image.width, height: image.height)
        }
        switch algorithm {
        case .threshold:
            return thresholdDither(image, t)
        case .ordered:
            return matrixDither(image, matrix: bayerMatrix, t)
        case .halftone:
            return matrixDither(image, matrix: halftoneMatrix, t)
        case .floydSteinberg:
            return floydSteinberg(image, t)
        case .atkinson:
            return atkinson(image, t)
        case .stucki:
            return stucki(image, t)
        }
    }

    // MARK: - Schwelle

    private static func thresholdDither(_ image: GrayImage, _ t: Int32) -> MonoBitmap {
        let w = image.width, h = image.height
        let bpr = (w + 7) / 8
        var out = [UInt8](repeating: 0, count: bpr * h)
        // Nachschlagetabelle: schwarz ⇔ L < T.
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let s = src.baseAddress!, d = dst.baseAddress!
                for y in 0..<h {
                    let row = s + y * w
                    let outRow = d + y * bpr
                    var acc: UInt8 = 0
                    var bit: UInt8 = 0x80
                    var byteIndex = 0
                    for x in 0..<w {
                        if Int32(row[x]) < t { acc |= bit }
                        bit >>= 1
                        if bit == 0 {
                            outRow[byteIndex] = acc
                            byteIndex += 1
                            acc = 0
                            bit = 0x80
                        }
                    }
                    if bit != 0x80 { outRow[byteIndex] = acc }
                }
            }
        }
        return MonoBitmap(trustedWidth: w, height: h, data: out)
    }

    // MARK: - Geordnete Rasterung (Bayer / Clustered Dot)

    private static func matrixDither(_ image: GrayImage, matrix: [Int32], _ t: Int32) -> MonoBitmap {
        let w = image.width, h = image.height
        let bpr = (w + 7) / 8
        var out = [UInt8](repeating: 0, count: bpr * h)
        // Schwellen je Matrixzelle: t = M·4 + 2 + (T − 128).
        let shift = t - 128
        let thresholds: [Int32] = matrix.map { $0 * 4 + 2 + shift }
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                thresholds.withUnsafeBufferPointer { thr in
                    let s = src.baseAddress!, d = dst.baseAddress!, m = thr.baseAddress!
                    for y in 0..<h {
                        let row = s + y * w
                        let outRow = d + y * bpr
                        let mrow = m + (y & 7) * 8
                        var acc: UInt8 = 0
                        var bit: UInt8 = 0x80
                        var byteIndex = 0
                        for x in 0..<w {
                            if Int32(row[x]) < mrow[x & 7] { acc |= bit }
                            bit >>= 1
                            if bit == 0 {
                                outRow[byteIndex] = acc
                                byteIndex += 1
                                acc = 0
                                bit = 0x80
                            }
                        }
                        if bit != 0x80 { outRow[byteIndex] = acc }
                    }
                }
            }
        }
        return MonoBitmap(trustedWidth: w, height: h, data: out)
    }

    // MARK: - Fehlerdiffusion

    /// Randzugabe links/rechts in den Fehlerzeilen. Anteile, die außerhalb des Bildes landen,
    /// werden in diese Ränder geschrieben und nie gelesen – sie „entfallen“ also wie gefordert.
    private static let margin = 2

    /// Floyd–Steinberg (D = 16): (x+1,y)=7, (x−1,y+1)=3, (x,y+1)=5, (x+1,y+1)=1.
    private static func floydSteinberg(_ image: GrayImage, _ t: Int32) -> MonoBitmap {
        let w = image.width, h = image.height
        let bpr = (w + 7) / 8
        let stride = w + 2 * margin
        var out = [UInt8](repeating: 0, count: bpr * h)
        var errors = [Int32](repeating: 0, count: stride * 2)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                errors.withUnsafeMutableBufferPointer { errBuf in
                    let s = src.baseAddress!, d = dst.baseAddress!
                    var cur = errBuf.baseAddress! + margin
                    var nxt = cur + stride
                    for y in 0..<h {
                        let row = s + y * w
                        let outRow = d + y * bpr
                        var acc: UInt8 = 0
                        var bit: UInt8 = 0x80
                        var byteIndex = 0
                        for x in 0..<w {
                            let v = Int32(row[x]) + cur[x]
                            let e: Int32
                            if v < t {
                                acc |= bit
                                e = v
                            } else {
                                e = v - 255
                            }
                            if e != 0 {
                                cur[x + 1] += e * 7 / 16
                                nxt[x - 1] += e * 3 / 16
                                nxt[x] += e * 5 / 16
                                nxt[x + 1] += e / 16
                            }
                            bit >>= 1
                            if bit == 0 {
                                outRow[byteIndex] = acc
                                byteIndex += 1
                                acc = 0
                                bit = 0x80
                            }
                        }
                        if bit != 0x80 { outRow[byteIndex] = acc }
                        // Zeilen rotieren; die neue „nächste“ Zeile (inkl. Ränder) leeren.
                        swap(&cur, &nxt)
                        (nxt - margin).update(repeating: 0, count: stride)
                    }
                }
            }
        }
        return MonoBitmap(trustedWidth: w, height: h, data: out)
    }

    /// Atkinson (D = 8): (x+1,y), (x+2,y), (x−1,y+1), (x,y+1), (x+1,y+1), (x,y+2) je 1/8.
    private static func atkinson(_ image: GrayImage, _ t: Int32) -> MonoBitmap {
        let w = image.width, h = image.height
        let bpr = (w + 7) / 8
        let stride = w + 2 * margin
        var out = [UInt8](repeating: 0, count: bpr * h)
        var errors = [Int32](repeating: 0, count: stride * 3)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                errors.withUnsafeMutableBufferPointer { errBuf in
                    let s = src.baseAddress!, d = dst.baseAddress!
                    var r0 = errBuf.baseAddress! + margin
                    var r1 = r0 + stride
                    var r2 = r1 + stride
                    for y in 0..<h {
                        let row = s + y * w
                        let outRow = d + y * bpr
                        var acc: UInt8 = 0
                        var bit: UInt8 = 0x80
                        var byteIndex = 0
                        for x in 0..<w {
                            let v = Int32(row[x]) + r0[x]
                            let e: Int32
                            if v < t {
                                acc |= bit
                                e = v
                            } else {
                                e = v - 255
                            }
                            if e != 0 {
                                let part = e / 8   // alle Gewichte = 1 → identischer Anteil
                                r0[x + 1] += part
                                r0[x + 2] += part
                                r1[x - 1] += part
                                r1[x] += part
                                r1[x + 1] += part
                                r2[x] += part
                            }
                            bit >>= 1
                            if bit == 0 {
                                outRow[byteIndex] = acc
                                byteIndex += 1
                                acc = 0
                                bit = 0x80
                            }
                        }
                        if bit != 0x80 { outRow[byteIndex] = acc }
                        let old = r0
                        r0 = r1
                        r1 = r2
                        r2 = old
                        (r2 - margin).update(repeating: 0, count: stride)
                    }
                }
            }
        }
        return MonoBitmap(trustedWidth: w, height: h, data: out)
    }

    /// Stucki (D = 42):
    /// (x+1,y)=8, (x+2,y)=4;
    /// (x−2,y+1)=2, (x−1,y+1)=4, (x,y+1)=8, (x+1,y+1)=4, (x+2,y+1)=2;
    /// (x−2,y+2)=1, (x−1,y+2)=2, (x,y+2)=4, (x+1,y+2)=2, (x+2,y+2)=1.
    private static func stucki(_ image: GrayImage, _ t: Int32) -> MonoBitmap {
        let w = image.width, h = image.height
        let bpr = (w + 7) / 8
        let stride = w + 2 * margin
        var out = [UInt8](repeating: 0, count: bpr * h)
        var errors = [Int32](repeating: 0, count: stride * 3)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                errors.withUnsafeMutableBufferPointer { errBuf in
                    let s = src.baseAddress!, d = dst.baseAddress!
                    var r0 = errBuf.baseAddress! + margin
                    var r1 = r0 + stride
                    var r2 = r1 + stride
                    for y in 0..<h {
                        let row = s + y * w
                        let outRow = d + y * bpr
                        var acc: UInt8 = 0
                        var bit: UInt8 = 0x80
                        var byteIndex = 0
                        for x in 0..<w {
                            let v = Int32(row[x]) + r0[x]
                            let e: Int32
                            if v < t {
                                acc |= bit
                                e = v
                            } else {
                                e = v - 255
                            }
                            if e != 0 {
                                // Jeder Anteil einzeln: e · w / 42 (abgeschnitten).
                                let e8 = e * 8 / 42, e4 = e * 4 / 42, e2 = e * 2 / 42, e1 = e / 42
                                r0[x + 1] += e8
                                r0[x + 2] += e4
                                r1[x - 2] += e2
                                r1[x - 1] += e4
                                r1[x] += e8
                                r1[x + 1] += e4
                                r1[x + 2] += e2
                                r2[x - 2] += e1
                                r2[x - 1] += e2
                                r2[x] += e4
                                r2[x + 1] += e2
                                r2[x + 2] += e1
                            }
                            bit >>= 1
                            if bit == 0 {
                                outRow[byteIndex] = acc
                                byteIndex += 1
                                acc = 0
                                bit = 0x80
                            }
                        }
                        if bit != 0x80 { outRow[byteIndex] = acc }
                        let old = r0
                        r0 = r1
                        r1 = r2
                        r2 = old
                        (r2 - margin).update(repeating: 0, count: stride)
                    }
                }
            }
        }
        return MonoBitmap(trustedWidth: w, height: h, data: out)
    }
}

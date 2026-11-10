import Foundation

/// 1-Bit-Bitmap im Druckerformat: zeilenweise, höchstwertiges Bit zuerst, **1 = schwarz**
/// (der Heizpunkt brennt).
///
/// Jede Zeile belegt `bytesPerRow = (width + 7) / 8` Bytes. Ungenutzte Füllbits am Zeilenende
/// sind immer 0 (weiß) – diese Invariante wird von allen Initialisierern und Operationen
/// gewahrt, sodass `data` direkt als ZPL-`^GF`- bzw. CPCL-`CG`-Nutzlast verwendet werden kann.
public struct MonoBitmap: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Zeilenweise Bitdaten, `count == bytesPerRow * height`, Füllbits = 0.
    public var data: [UInt8]

    /// Bytes je Zeile (aufgerundet auf ganze Bytes).
    public var bytesPerRow: Int { (width + 7) / 8 }

    /// Erzeugt eine leere (weiße) Bitmap.
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "MonoBitmap: negative Abmessungen \(width) × \(height)")
        self.width = width
        self.height = height
        self.data = [UInt8](repeating: 0, count: ((width + 7) / 8) * height)
    }

    /// Erzeugt eine Bitmap aus vorhandenen Bitdaten. Gesetzte Füllbits werden gelöscht.
    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(width >= 0 && height >= 0, "MonoBitmap: negative Abmessungen \(width) × \(height)")
        let bpr = (width + 7) / 8
        precondition(data.count == bpr * height,
                     "MonoBitmap: \(data.count) Bytes passen nicht zu \(width) × \(height) (\(bpr) Bytes/Zeile)")
        self.width = width
        self.height = height
        self.data = data
        clearPaddingBits()
    }

    /// Erzeugt eine Bitmap aus einem Prädikat (`true` = schwarz).
    public init(width: Int, height: Int, isBlack: (_ x: Int, _ y: Int) -> Bool) {
        self.init(width: width, height: height)
        let bpr = bytesPerRow
        for y in 0..<height {
            for x in 0..<width where isBlack(x, y) {
                data[y * bpr + (x >> 3)] |= UInt8(0x80) >> UInt8(x & 7)
            }
        }
    }

    /// Maske der gültigen Bits im letzten Byte einer Zeile.
    var lastByteMask: UInt8 {
        let rem = width & 7
        return rem == 0 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - rem))
    }

    /// Setzt alle Füllbits auf 0.
    mutating func clearPaddingBits() {
        let mask = lastByteMask
        guard mask != 0xFF, height > 0 else { return }
        let bpr = bytesPerRow
        data.withUnsafeMutableBufferPointer { buf in
            var i = bpr - 1
            for _ in 0..<height {
                buf[i] &= mask
                i += bpr
            }
        }
    }

    /// Zugriff auf ein einzelnes Pixel (`true` = schwarz); Koordinaten müssen im Bild liegen.
    public subscript(x: Int, y: Int) -> Bool {
        get {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "MonoBitmap: (\(x), \(y)) außerhalb der Bitmap")
            return data[y * bytesPerRow + (x >> 3)] & (UInt8(0x80) >> UInt8(x & 7)) != 0
        }
        set {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "MonoBitmap: (\(x), \(y)) außerhalb der Bitmap")
            let index = y * bytesPerRow + (x >> 3)
            let bit = UInt8(0x80) >> UInt8(x & 7)
            if newValue { data[index] |= bit } else { data[index] &= ~bit }
        }
    }

    /// `true`, wenn kein einziger Punkt schwarz ist.
    public var isBlank: Bool {
        data.withUnsafeBufferPointer { buf in
            var acc: UInt8 = 0
            for b in buf { acc |= b }
            return acc == 0
        }
    }

    /// `true`, wenn Zeile `y` keinen schwarzen Punkt enthält.
    public func isRowBlank(_ y: Int) -> Bool {
        precondition(y >= 0 && y < height, "MonoBitmap: Zeile \(y) außerhalb der Bitmap")
        let bpr = bytesPerRow
        return data.withUnsafeBufferPointer { buf in
            var acc: UInt8 = 0
            for i in (y * bpr)..<(y * bpr + bpr) { acc |= buf[i] }
            return acc == 0
        }
    }

    /// Anzahl schwarzer Punkte.
    public var blackPixelCount: Int {
        data.withUnsafeBufferPointer { buf in
            var count = 0
            for b in buf { count += b.nonzeroBitCount }
            return count
        }
    }

    /// Bytes einer Zeile.
    public func row(_ y: Int) -> ArraySlice<UInt8> {
        precondition(y >= 0 && y < height, "MonoBitmap: Zeile \(y) außerhalb der Bitmap")
        return data[(y * bytesPerRow)..<(y * bytesPerRow + bytesPerRow)]
    }

    // MARK: Geometrie

    /// Dreht die Bitmap um 180°.
    public func rotated180() -> MonoBitmap {
        let mirroredRows = mirrored()
        let bpr = bytesPerRow
        var out = [UInt8](repeating: 0, count: data.count)
        mirroredRows.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let s = y * bpr
                    let d = (height - 1 - y) * bpr
                    for i in 0..<bpr { dst[d + i] = src[s + i] }
                }
            }
        }
        return MonoBitmap(trustedWidth: width, height: height, data: out)
    }

    /// Dreht die Bitmap im Uhrzeigersinn um die angegebene Vierteldrehung.
    public func rotated(_ turn: QuarterTurn) -> MonoBitmap {
        switch turn {
        case .r0: return self
        case .r180: return rotated180()
        case .r90, .r270:
            let w = width, h = height
            var out = MonoBitmap(width: h, height: w)
            let srcBPR = bytesPerRow
            let dstBPR = out.bytesPerRow
            data.withUnsafeBufferPointer { src in
                out.data.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = y * srcBPR
                        for x in 0..<w where src[row + (x >> 3)] & (UInt8(0x80) >> UInt8(x & 7)) != 0 {
                            // r90: (x, y) → (h−1−y, x); r270: (x, y) → (y, w−1−x)
                            let nx = turn == .r90 ? h - 1 - y : y
                            let ny = turn == .r90 ? x : w - 1 - x
                            dst[ny * dstBPR + (nx >> 3)] |= UInt8(0x80) >> UInt8(nx & 7)
                        }
                    }
                }
            }
            return out
        }
    }

    /// Spiegelt die Bitmap horizontal (links ↔ rechts).
    public func mirrored() -> MonoBitmap {
        let bpr = bytesPerRow
        guard bpr > 0, height > 0 else { return self }
        let pad = bpr * 8 - width   // 0…7 Füllbits am Zeilenende
        var out = [UInt8](repeating: 0, count: data.count)
        let table = BitReversal.table
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                table.withUnsafeBufferPointer { rev in
                    for y in 0..<height {
                        let base = y * bpr
                        // Bytes in umgekehrter Reihenfolge, Bits je Byte umgekehrt …
                        for i in 0..<bpr {
                            dst[base + i] = rev[Int(src[base + bpr - 1 - i])]
                        }
                        // … danach stehen die Füllbits vorne: Zeile um `pad` Bits nach links schieben.
                        if pad > 0 {
                            let left = UInt8(pad), right = UInt8(8 - pad)
                            for i in 0..<bpr {
                                let next: UInt8 = i + 1 < bpr ? dst[base + i + 1] : 0
                                dst[base + i] = (dst[base + i] << left) | (next >> right)
                            }
                        }
                    }
                }
            }
        }
        return MonoBitmap(trustedWidth: width, height: height, data: out)
    }

    /// Spiegelt die Bitmap vertikal (oben ↔ unten).
    public func flippedVertically() -> MonoBitmap {
        let bpr = bytesPerRow
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for y in stride(from: height - 1, through: 0, by: -1) {
            out.append(contentsOf: data[(y * bpr)..<(y * bpr + bpr)])
        }
        return MonoBitmap(trustedWidth: width, height: height, data: out)
    }

    /// Negativ: schwarz ↔ weiß. Füllbits bleiben 0.
    public func inverted() -> MonoBitmap {
        var copy = MonoBitmap(trustedWidth: width, height: height, data: data.map { ~$0 })
        copy.clearPaddingBits()
        return copy
    }

    /// Schneidet einen Ausschnitt aus. Das Ergebnis hat immer genau `width × height` Punkte;
    /// Bereiche außerhalb der Quelle sind weiß (0).
    public func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> MonoBitmap {
        precondition(cropWidth >= 0 && cropHeight >= 0, "MonoBitmap.cropped: negative Größe")
        if x == 0 && y == 0 && cropWidth == width && cropHeight == height { return self }
        var out = MonoBitmap(width: cropWidth, height: cropHeight)
        let dstBPR = out.bytesPerRow
        let srcBPR = bytesPerRow
        guard dstBPR > 0 else { return out }
        let srcBits = width
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                for ny in 0..<cropHeight {
                    let sy = ny + y
                    guard sy >= 0 && sy < height else { continue }
                    let srcRow = sy * srcBPR
                    let dstRow = ny * dstBPR
                    for j in 0..<dstBPR {
                        // 8 Bits ab Quell-Bitposition x + 8j lesen (außerhalb = 0).
                        let bitPos = x + j * 8
                        var byte: UInt8 = 0
                        if bitPos >= 0 && bitPos + 8 <= srcBits {
                            let bi = bitPos >> 3, sh = bitPos & 7
                            if sh == 0 {
                                byte = src[srcRow + bi]
                            } else {
                                let hi = src[srcRow + bi] << UInt8(sh)
                                let lo: UInt8 = bi + 1 < srcBPR ? src[srcRow + bi + 1] >> UInt8(8 - sh) : 0
                                byte = hi | lo
                            }
                        } else {
                            for k in 0..<8 {
                                let sx = bitPos + k
                                if sx >= 0 && sx < srcBits,
                                   src[srcRow + (sx >> 3)] & (UInt8(0x80) >> UInt8(sx & 7)) != 0 {
                                    byte |= UInt8(0x80) >> UInt8(k)
                                }
                            }
                        }
                        dst[dstRow + j] = byte
                    }
                }
            }
        }
        out.clearPaddingBits()
        return out
    }

    /// Wandelt in ein Graustufenbild um (schwarz → 0, weiß → 255).
    public func toGrayImage() -> GrayImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        let bpr = bytesPerRow
        let w = width
        data.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * bpr
                    let out = y * w
                    for x in 0..<w where src[row + (x >> 3)] & (UInt8(0x80) >> UInt8(x & 7)) != 0 {
                        dst[out + x] = 0
                    }
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Interner Initialisierer ohne Prüfungen (Aufrufer garantiert Größe und Füllbits).
    init(trustedWidth width: Int, height: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
    }
}

/// Tabelle zur Bitumkehr eines Bytes (Bit 7 ↔ Bit 0 usw.).
enum BitReversal {
    static let table: [UInt8] = (0..<256).map { value -> UInt8 in
        var v = UInt8(value), r: UInt8 = 0
        for _ in 0..<8 {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }
}

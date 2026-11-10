import Foundation
import LabelWerkCore
import LabelWerkImaging

/// Ganzzahliges Rechteck `[x, x + width) × [y, y + height)`.
struct IntRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func intersection(_ other: IntRect) -> IntRect {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        return IntRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

/// Art, wie eine Feldmaske in das Etikett übernommen wird.
enum CompositeMode {
    /// Schwarz drucken (ODER).
    case black
    /// Weiß drucken (löschen, `^GB…,W`).
    case white
    /// Untergrund umkehren (XOR, `^FR`/`^LR`).
    case reverse
}

/// 1-Bit-Zeichenfläche im `MonoBitmap`-Format (MSB zuerst, 1 = schwarz, Füllbits stets 0).
struct BitCanvas {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var data: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.bytesPerRow = (self.width + 7) / 8
        self.data = [UInt8](repeating: 0, count: bytesPerRow * self.height)
    }

    init(bitmap: MonoBitmap) {
        width = bitmap.width
        height = bitmap.height
        bytesPerRow = bitmap.bytesPerRow
        data = bitmap.data
    }

    var bounds: IntRect { IntRect(x: 0, y: 0, width: width, height: height) }

    var monoBitmap: MonoBitmap { MonoBitmap(width: width, height: height, data: data) }

    func get(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return data[y * bytesPerRow + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0
    }

    mutating func set(_ x: Int, _ y: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        data[y * bytesPerRow + (x >> 3)] |= 0x80 >> UInt8(x & 7)
    }

    /// Setzt die Punkte `[x0, x1)` in Zeile `y` (außerhalb wird abgeschnitten).
    mutating func fillSpan(y: Int, from x0: Int, to x1: Int) {
        guard y >= 0, y < height else { return }
        let start = max(0, x0), end = min(width, x1)
        guard start < end else { return }
        let row = y * bytesPerRow
        var x = start
        // Teilbyte am Anfang.
        while x < end && x & 7 != 0 {
            data[row + (x >> 3)] |= 0x80 >> UInt8(x & 7)
            x += 1
        }
        // Ganze Bytes.
        while x + 8 <= end {
            data[row + (x >> 3)] = 0xFF
            x += 8
        }
        // Teilbyte am Ende.
        while x < end {
            data[row + (x >> 3)] |= 0x80 >> UInt8(x & 7)
            x += 1
        }
    }

    mutating func fillRect(_ rect: IntRect) {
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        for y in clipped.y..<clipped.maxY { fillSpan(y: y, from: clipped.x, to: clipped.maxX) }
    }

    /// Dreht die Fläche im Uhrzeigersinn gemäß Feldausrichtung.
    func rotated(_ orientation: FieldOrientation) -> BitCanvas {
        let turn: QuarterTurn
        switch orientation {
        case .normal: return self
        case .rotated90: turn = .r90
        case .inverted180: turn = .r180
        case .rotated270: turn = .r270
        }
        return BitCanvas(bitmap: monoBitmap.rotated(turn))
    }

    /// Überträgt `mask` an Position (`x`, `y`). Die Maske muss vollständig innerhalb liegen.
    mutating func composite(_ mask: BitCanvas, x: Int, y: Int, mode: CompositeMode) {
        guard mask.width > 0, mask.height > 0, x >= 0, y >= 0,
              x + mask.width <= width, y + mask.height <= height else { return }
        let shift = UInt8(x & 7)
        let byteOffset = x >> 3
        let maskBPR = mask.bytesPerRow
        let bpr = bytesPerRow
        mask.data.withUnsafeBufferPointer { source in
            data.withUnsafeMutableBufferPointer { target in
                for row in 0..<mask.height {
                    let sourceRow = row * maskBPR
                    let targetRow = (y + row) * bpr
                    let rowEnd = targetRow + bpr
                    for column in 0..<maskBPR {
                        let byte = source[sourceRow + column]
                        if byte == 0 { continue }
                        let index = targetRow + byteOffset + column
                        let first = byte >> shift
                        let second: UInt8 = shift == 0 ? 0 : byte << (8 - shift)
                        Self.apply(first, at: index, in: target, mode: mode)
                        if second != 0 && index + 1 < rowEnd {
                            Self.apply(second, at: index + 1, in: target, mode: mode)
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func apply(_ bits: UInt8, at index: Int, in target: UnsafeMutableBufferPointer<UInt8>,
                              mode: CompositeMode) {
        switch mode {
        case .black: target[index] |= bits
        case .white: target[index] &= ~bits
        case .reverse: target[index] ^= bits
        }
    }
}

/// Zeichenfläche für ein Feld in **ungedrehten Feldkoordinaten**, beschränkt auf den sichtbaren
/// Ausschnitt `clip` (Feldkoordinaten). Zeichenoperationen außerhalb werden abgeschnitten.
struct FieldMask {
    let clip: IntRect
    var canvas: BitCanvas

    init(clip: IntRect) {
        self.clip = clip
        canvas = BitCanvas(width: clip.width, height: clip.height)
    }

    /// Zeile `y` (Feldkoordinaten) im Bereich `[x0, x1)` füllen.
    mutating func span(y: Int, from x0: Int, to x1: Int) {
        canvas.fillSpan(y: y - clip.y, from: x0 - clip.x, to: x1 - clip.x)
    }

    mutating func rect(x: Int, y: Int, width: Int, height: Int) {
        let target = IntRect(x: x, y: y, width: width, height: height).intersection(clip)
        guard !target.isEmpty else { return }
        for row in target.y..<target.maxY { span(y: row, from: target.x, to: target.maxX) }
    }

    /// Zeilen des Ausschnitts, die `[y0, y1)` überlappen.
    func rows(_ y0: Int, _ y1: Int) -> Range<Int> {
        let start = max(y0, clip.y), end = min(y1, clip.maxY)
        return start < end ? start..<end : 0..<0
    }

    mutating func setPixel(_ x: Int, _ y: Int) {
        canvas.set(x - clip.x, y - clip.y)
    }
}

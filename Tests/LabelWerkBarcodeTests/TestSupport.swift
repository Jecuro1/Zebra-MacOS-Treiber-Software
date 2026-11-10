import Foundation
@testable import LabelWerkBarcode

/// Hilfsfunktionen für die Barcode-Tests (unabhängige Rückleser, Prüfsummen, Zufallsdaten).
enum TestSupport {

    /// Modulfolge als "1"/"0"-Text.
    static func moduleString(_ barcode: LinearBarcode) -> String {
        String(barcode.modules.map { $0 ? "1" : "0" })
    }

    /// FNV-1a-64 über Abmessungen und Bits – kompakte Goldwerte für große Matrizen.
    static func fingerprint(_ matrix: BitMatrix) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(UInt64(matrix.width))
        mix(UInt64(matrix.height))
        for bit in matrix.bits { mix(bit ? 1 : 0) }
        return String(format: "0x%016llX", hash)
    }

    /// Deterministischer Zufallsgenerator (SplitMix64), damit Tests reproduzierbar sind.
    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func string(from alphabet: [Unicode.Scalar], length: Int) -> String {
            var result = ""
            for _ in 0..<length { result.unicodeScalars.append(alphabet[int(0...(alphabet.count - 1))]) }
            return result
        }
    }

    static func scalars(_ range: ClosedRange<UInt32>) -> [Unicode.Scalar] {
        range.compactMap(Unicode.Scalar.init)
    }

    // MARK: Code 128 – unabhängiger Rückleser

    /// Liest die Symbolwerte (inkl. Start, Prüf- und Stoppzeichen) aus den Elementen.
    static func code128Values(_ barcode: LinearBarcode) -> [Int]? {
        let widths = barcode.elements.map(\.width)
        guard widths.count >= 13, (widths.count - 7) % 6 == 0 else { return nil }
        var values: [Int] = []
        var index = 0
        while index + 7 < widths.count {
            let chunk = Array(widths[index..<(index + 6)])
            guard let value = Code128.patterns.firstIndex(of: chunk) else { return nil }
            values.append(value)
            index += 6
        }
        guard Array(widths[index...]) == Code128.patterns[106] else { return nil }
        values.append(106)
        return values
    }

    /// Interpretiert Code-128-Symbolwerte (ohne Prüf-/Stoppzeichen) als Text (ISO 8859-1).
    /// FNC1 wird als GS (ASCII 29) wiedergegeben – außer direkt nach dem Startzeichen.
    static func interpretCode128(_ values: [Int]) -> String? {
        guard let start = values.first, (103...105).contains(start) else { return nil }
        var set = start - 103  // 0 = A, 1 = B, 2 = C
        var shiftNext = false
        var fnc4Next = false
        var result = ""
        for (offset, value) in values.dropFirst().enumerated() {
            let activeSet = shiftNext ? (set == 0 ? 1 : 0) : set
            shiftNext = false
            if activeSet == 2 {
                switch value {
                case 0...99: result += String(format: "%02d", value)
                case 100: set = 1
                case 101: set = 0
                case 102: if offset > 0 { result.unicodeScalars.append(Unicode.Scalar(29)) }
                default: return nil
                }
                continue
            }
            switch value {
            case 0...95:
                var code: Int
                if activeSet == 0 { code = value < 64 ? value + 32 : value - 64 } else { code = value + 32 }
                if fnc4Next { code += 128; fnc4Next = false }
                result.unicodeScalars.append(Unicode.Scalar(UInt8(code)))
            case 96, 97: break  // FNC3 / FNC2
            case 98: shiftNext = true
            case 99: set = 2
            case 100: if activeSet == 1 { fnc4Next = true } else { set = 1 }
            case 101: if activeSet == 0 { fnc4Next = true } else { set = 0 }
            case 102: if offset > 0 { result.unicodeScalars.append(Unicode.Scalar(29)) }
            default: return nil
            }
        }
        return result
    }

    // MARK: Reed-Solomon-Prüfung (Syndrome)

    /// Prüft, ob `codeword` (höchste Potenz zuerst) an den Nullstellen α^first … α^(first+count−1)
    /// verschwindet, d. h. ein gültiges Reed-Solomon-Codewort ist.
    static func hasZeroSyndromes(_ codeword: [UInt8], field: GaloisField256, firstRoot: Int, count: Int) -> Bool {
        for i in 0..<count {
            let root = field.exp[(firstRoot + i) % 255]
            var value: UInt8 = 0
            for c in codeword { value = field.multiply(value, root) ^ c }
            if value != 0 { return false }
        }
        return true
    }

    // MARK: QR – unabhängiger Rückleser

    /// Liest Format-Information (Kopie um das linke obere Positionsmuster).
    static func qrFormatBits(_ m: BitMatrix) -> Int {
        var bits = 0
        // Bits 0…7 senkrecht in Spalte 8 (Zeilen 0–5, 7, 8), Bits 8…14 waagrecht in Zeile 8.
        let positions: [(Int, Int)] = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
                                       (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
        for (i, p) in positions.enumerated() where m[p.0, p.1] { bits |= 1 << i }
        return bits
    }

    /// Entfernt die Maske und liest alle Codewörter im Zickzack aus (eigene, vom Encoder
    /// unabhängige Bestimmung der Funktionsmodule).
    static func qrReadCodewords(_ m: BitMatrix, version: Int, mask: Int) -> [UInt8] {
        let n = m.width
        var function = [Bool](repeating: false, count: n * n)
        func mark(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) {
            for y in max(0, y0)..<min(n, y0 + h) {
                for x in max(0, x0)..<min(n, x0 + w) { function[y * n + x] = true }
            }
        }
        mark(0, 0, 9, 9)
        mark(n - 8, 0, 8, 9)
        mark(0, n - 8, 9, 8)
        mark(6, 0, 1, n)
        mark(0, 6, n, 1)
        let centers = QRCode.alignmentPatternPositions[version]
        for cy in centers {
            for cx in centers {
                let overlapsFinder = (cx < 9 && cy < 9) || (cx > n - 9 && cy < 9) || (cx < 9 && cy > n - 9)
                if !overlapsFinder { mark(cx - 2, cy - 2, 5, 5) }
            }
        }
        if version >= 7 {
            mark(n - 11, 0, 3, 6)
            mark(0, n - 11, 6, 3)
        }
        var bits: [Bool] = []
        var right = n - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<n {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? n - 1 - vertical : vertical
                    if function[y * n + x] { continue }
                    var bit = m[x, y]
                    if QRCode.maskCondition(mask, x: x, y: y) { bit.toggle() }
                    bits.append(bit)
                }
            }
            right -= 2
        }
        var bytes: [UInt8] = []
        var i = 0
        while i + 8 <= bits.count {
            var byte: UInt8 = 0
            for k in 0..<8 where bits[i + k] { byte |= 0x80 >> UInt8(k) }
            bytes.append(byte)
            i += 8
        }
        return bytes
    }
}

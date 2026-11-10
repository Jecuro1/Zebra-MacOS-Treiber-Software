import Foundation
import LabelWerkImaging

/// Eine eingebettete 1-Bit-Masterschrift (siehe `Sources/LabelWerkRender/.fontgen/generate_font.py`).
///
/// Die Glyphen liegen in Masterpixeln vor (Geviert `emSize` ≈ 44 px, Versalhöhe ≈ 32 px) und
/// werden beim Rastern auf die Zielgröße skaliert. Die Daten werden beim ersten Zugriff einmalig
/// dekodiert (`static let` ist threadsicher und träge).
struct BitmapFont: Sendable {

    /// Eine Glyphe in Masterpixeln.
    struct Glyph: Sendable {
        /// Vorschub in Masterpixeln.
        let advance: Double
        let width: Int
        let height: Int
        /// Abstand der linken Tintenkante vom Stiftpunkt.
        let left: Int
        /// Abstand der oberen Tintenkante über der Grundlinie (negativ = unterhalb).
        let top: Int
        /// Zeilenweise Pixel, 1 = schwarz, `count == width * height`.
        let pixels: [UInt8]

        var isEmpty: Bool { width == 0 || height == 0 }

        /// Pixelwert (0/1); außerhalb der Glyphe 0.
        @inline(__always)
        func pixel(_ x: Int, _ y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return pixels[y * width + x]
        }
    }

    let emSize: Int
    let ascent: Int
    let descent: Int
    let capHeight: Int
    let xHeight: Int
    let glyphs: [UInt32: Glyph]
    /// Ersatzglyphe („Tofu“, umrandetes Rechteck) für fehlende Zeichen.
    let missingGlyph: Glyph

    /// DejaVu Sans Bold – Schrift 0.
    static let sansBold = BitmapFont(lines: BitmapFontData.sansBold)
    /// DejaVu Sans – übrige skalierbare Schriften.
    static let sans = BitmapFont(lines: BitmapFontData.sans)
    /// DejaVu Sans Mono – Bitmap-Schriften A–H und Klarschriftzeilen.
    static let mono = BitmapFont(lines: BitmapFontData.mono)

    /// Dekodiert die Base64-Zeilen; bei beschädigten Daten entsteht eine leere Schrift (nur Tofu).
    init(lines: [String]) {
        var parsed: (Int, Int, Int, Int, Int, [UInt32: Glyph])?
        if let compressed = Data(base64Encoded: lines.joined()),
           let raw = try? Deflate.decompress(compressed) {
            parsed = Self.parse([UInt8](raw))
        }
        let (em, ascent, descent, cap, xHeight, glyphs) = parsed ?? (44, 41, 11, 32, 24, [:])
        self.emSize = em
        self.ascent = ascent
        self.descent = descent
        self.capHeight = cap
        self.xHeight = xHeight
        self.glyphs = glyphs
        self.missingGlyph = Self.makeMissingGlyph(emSize: em, capHeight: cap)
    }

    func glyph(_ scalar: Unicode.Scalar) -> Glyph? {
        glyphs[scalar.value]
    }

    /// Glyphe für ein Zeichen mit Ersatzstrategie:
    /// 1. exaktes (NFC-)Zeichen, 2. Grundbuchstabe der kanonischen Zerlegung (ő → o),
    /// 3. typografische Entsprechung (‐ → -), 4. Tofu.
    func resolve(_ character: Character) -> Glyph {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first, let glyph = glyphs[scalar.value] {
            return glyph
        }
        let composed = String(character).precomposedStringWithCanonicalMapping.unicodeScalars
        if composed.count == 1, let scalar = composed.first, let glyph = glyphs[scalar.value] {
            return glyph
        }
        let decomposed = String(character).decomposedStringWithCanonicalMapping.unicodeScalars
        if let base = decomposed.first, let glyph = glyphs[base.value] {
            return glyph
        }
        if let base = scalars.first, let substitute = Self.substitutes[base.value], let glyph = glyphs[substitute] {
            return glyph
        }
        return missingGlyph
    }

    /// Typografische Ersatzzeichen ohne eigene Glyphe.
    private static let substitutes: [UInt32: UInt32] = [
        0x2010: 0x2D, 0x2011: 0x2D, 0x2012: 0x2013, 0x2015: 0x2014, 0x2212: 0x2D, 0x00AD: 0x2D,
        0x2032: 0x27, 0x2033: 0x22, 0x2044: 0x2F, 0x2215: 0x2F, 0x2024: 0x2E, 0x2027: 0xB7,
        0x202F: 0x20, 0x2007: 0x20, 0x2009: 0x20, 0x200A: 0x20, 0x2002: 0x20, 0x2003: 0x20,
        0x2219: 0xB7, 0x22C5: 0xB7, 0x02BC: 0x2019,
    ]

    // MARK: Dekodierung

    private static func parse(_ bytes: [UInt8]) -> (Int, Int, Int, Int, Int, [UInt32: Glyph])? {
        guard bytes.count >= 11, bytes[0] == 0x4C, bytes[1] == 0x57, bytes[2] == 0x46, bytes[3] == 0x31 else {
            return nil
        }
        let em = Int(bytes[4]), ascent = Int(bytes[5]), descent = Int(bytes[6])
        let cap = Int(bytes[7]), xHeight = Int(bytes[8])
        let count = Int(bytes[9]) | Int(bytes[10]) << 8
        var offset = 11
        var glyphs: [UInt32: Glyph] = [:]
        glyphs.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 8 <= bytes.count else { return nil }
            let codepoint = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            let advance16 = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
            let width = Int(bytes[offset + 4])
            let height = Int(bytes[offset + 5])
            let left = Int(Int8(bitPattern: bytes[offset + 6]))
            let top = Int(Int8(bitPattern: bytes[offset + 7]))
            offset += 8
            let bitCount = width * height
            let byteCount = (bitCount + 7) / 8
            guard offset + byteCount <= bytes.count else { return nil }
            var pixels = [UInt8](repeating: 0, count: bitCount)
            for index in 0..<bitCount where bytes[offset + (index >> 3)] & (0x80 >> UInt8(index & 7)) != 0 {
                pixels[index] = 1
            }
            offset += byteCount
            glyphs[codepoint] = Glyph(advance: Double(advance16) / 16, width: width, height: height,
                                      left: left, top: top, pixels: pixels)
        }
        return (em, ascent, descent, cap, xHeight, glyphs)
    }

    /// Umrandetes Rechteck in Versalhöhe als Ersatzglyphe.
    private static func makeMissingGlyph(emSize: Int, capHeight: Int) -> Glyph {
        let width = max(4, emSize * 45 / 100)
        let height = max(4, capHeight)
        let stroke = max(1, emSize / 16)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where x < stroke || x >= width - stroke || y < stroke || y >= height - stroke {
                pixels[y * width + x] = 1
            }
        }
        let left = max(1, emSize / 16)
        return Glyph(advance: Double(width + 2 * left), width: width, height: height, left: left, top: height,
                     pixels: pixels)
    }
}

import Foundation

/// Netpbm-Formate (PBM/PGM/PPM) für Tests, CLI und Filter-Prüfstände.
///
/// Dekodierung: `P1` (PBM ASCII), `P2` (PGM ASCII), `P3` (PPM ASCII), `P4` (PBM binär),
/// `P5` (PGM binär, 8 oder 16 Bit), `P6` (PPM binär, 8 oder 16 Bit). Kommentare (`#` bis
/// Zeilenende) sind im Kopf und in ASCII-Daten erlaubt. Bei mehreren Bildern in einer Datei
/// wird nur das erste gelesen.
///
/// Umrechnung: PBM 1 → 0 (schwarz), 0 → 255. Grauwerte werden mit
/// `(v · 255 + maxval / 2) / maxval` auf 0…255 skaliert, Farbwerte erst skaliert und dann mit
/// `(299·R + 587·G + 114·B) / 1000` in Luminanz umgerechnet.
public enum PNMCodec {

    /// Dekodiert eine PNM-Datei in ein Luminanzbild.
    ///
    /// - Throws: `ImagingError.invalidPNM` bei unbekanntem Format oder beschädigten Daten,
    ///   `.imageTooLarge` bei übergroßen Bildern.
    public static func decode(_ data: Data) throws -> GrayImage {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.bytes.count >= 2, reader.bytes[0] == UInt8(ascii: "P") else {
            throw ImagingError.invalidPNM("Kennung „P1“…„P6“ fehlt.")
        }
        let kind = reader.bytes[1]
        reader.position = 2
        guard (UInt8(ascii: "1")...UInt8(ascii: "6")).contains(kind) else {
            throw ImagingError.invalidPNM("Unbekanntes Format „P\(Character(Unicode.Scalar(kind)))“.")
        }
        let width = try reader.readInteger(field: "Breite")
        let height = try reader.readInteger(field: "Höhe")
        try ImagingLimits.check(width: width, height: height)
        let isBitmap = kind == UInt8(ascii: "1") || kind == UInt8(ascii: "4")
        var maxValue = 1
        if !isBitmap { maxValue = try reader.readInteger(field: "Maximalwert") }
        guard maxValue >= 1 && maxValue <= 65_535 else {
            throw ImagingError.invalidPNM("Maximalwert \(maxValue) außerhalb von 1…65535.")
        }
        let isBinary = kind >= UInt8(ascii: "4")
        if isBinary {
            // Genau ein Leerraumzeichen trennt Kopf und Binärdaten.
            guard reader.position < reader.bytes.count, Reader.isWhitespace(reader.bytes[reader.position]) else {
                throw ImagingError.invalidPNM("Binärdaten fehlen.")
            }
            reader.position += 1
        }

        var pixels = [UInt8](repeating: 255, count: width * height)
        let scale: (Int) -> UInt8 = { v in UInt8(min(255, (min(v, maxValue) * 255 + maxValue / 2) / maxValue)) }

        switch kind {
        case UInt8(ascii: "1"):
            for i in 0..<(width * height) {
                let bit = try reader.readBit()
                pixels[i] = bit ? 0 : 255
            }
        case UInt8(ascii: "2"):
            for i in 0..<(width * height) {
                pixels[i] = scale(try reader.readInteger(field: "Grauwert"))
            }
        case UInt8(ascii: "3"):
            for i in 0..<(width * height) {
                let r = scale(try reader.readInteger(field: "Rotwert"))
                let g = scale(try reader.readInteger(field: "Grünwert"))
                let b = scale(try reader.readInteger(field: "Blauwert"))
                pixels[i] = PNGCodec.PixelConverter.luminance(r, g, b)
            }
        case UInt8(ascii: "4"):
            let bpr = (width + 7) / 8
            let needed = bpr * height
            guard reader.bytes.count - reader.position >= needed else {
                throw ImagingError.invalidPNM("Bilddaten unvollständig.")
            }
            let base = reader.position
            for y in 0..<height {
                for x in 0..<width {
                    let byte = reader.bytes[base + y * bpr + (x >> 3)]
                    if byte & (UInt8(0x80) >> UInt8(x & 7)) != 0 { pixels[y * width + x] = 0 }
                }
            }
        default: // P5, P6
            let channels = kind == UInt8(ascii: "5") ? 1 : 3
            let sampleBytes = maxValue > 255 ? 2 : 1
            let needed = width * height * channels * sampleBytes
            guard reader.bytes.count - reader.position >= needed else {
                throw ImagingError.invalidPNM("Bilddaten unvollständig.")
            }
            var p = reader.position
            let bytes = reader.bytes
            func sample() -> UInt8 {
                let v: Int
                if sampleBytes == 2 {
                    v = Int(bytes[p]) << 8 | Int(bytes[p + 1])
                } else {
                    v = Int(bytes[p])
                }
                p += sampleBytes
                return scale(v)
            }
            for i in 0..<(width * height) {
                if channels == 1 {
                    pixels[i] = sample()
                } else {
                    let r = sample(), g = sample(), b = sample()
                    pixels[i] = PNGCodec.PixelConverter.luminance(r, g, b)
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Kodiert ein Graustufenbild als binäres PGM (`P5`, Maximalwert 255).
    public static func encode(_ image: GrayImage) -> Data {
        var out = Data("P5\n\(image.width) \(image.height)\n255\n".utf8)
        out.append(contentsOf: image.pixels)
        return out
    }

    /// Kodiert eine Bitmap als binäres PBM (`P4`, 1 = schwarz – wie `MonoBitmap`).
    public static func encode(_ bitmap: MonoBitmap) -> Data {
        var out = Data("P4\n\(bitmap.width) \(bitmap.height)\n".utf8)
        out.append(contentsOf: bitmap.data)
        return out
    }

    // MARK: - Leser

    struct Reader {
        let bytes: [UInt8]
        var position = 0

        static func isWhitespace(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
        }

        /// Überspringt Leerraum und Kommentare.
        mutating func skipSeparators() {
            while position < bytes.count {
                let c = bytes[position]
                if Self.isWhitespace(c) {
                    position += 1
                } else if c == UInt8(ascii: "#") {
                    while position < bytes.count && bytes[position] != 0x0A && bytes[position] != 0x0D {
                        position += 1
                    }
                } else {
                    return
                }
            }
        }

        mutating func readInteger(field: String) throws -> Int {
            skipSeparators()
            var value = 0
            var digits = 0
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
                value = value * 10 + Int(bytes[position] - UInt8(ascii: "0"))
                digits += 1
                position += 1
                if value > 1 << 31 { throw ImagingError.invalidPNM("\(field): Zahl zu groß.") }
            }
            guard digits > 0 else {
                throw ImagingError.invalidPNM(position >= bytes.count ? "\(field) fehlt (Dateiende)." : "\(field): Zahl erwartet.")
            }
            return value
        }

        /// Liest ein PBM-ASCII-Bit (`0`/`1`, Trennzeichen optional).
        mutating func readBit() throws -> Bool {
            skipSeparators()
            guard position < bytes.count else { throw ImagingError.invalidPNM("Bilddaten unvollständig.") }
            let c = bytes[position]
            position += 1
            switch c {
            case UInt8(ascii: "0"): return false
            case UInt8(ascii: "1"): return true
            default: throw ImagingError.invalidPNM("Ungültiges PBM-Zeichen „\(Character(Unicode.Scalar(c)))“.")
            }
        }
    }
}

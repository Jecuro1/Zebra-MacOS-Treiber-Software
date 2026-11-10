import Foundation

/// PNG-Kodierung und -Dekodierung ohne Fremdbibliotheken (nur zlib).
///
/// * Kodierung: 8-Bit-Graustufen (`GrayImage`) bzw. 1-Bit-Graustufen (`MonoBitmap`).
/// * Dekodierung: alle Farbtypen (0 Grau, 2 RGB, 3 Palette, 4 Grau + Alpha, 6 RGBA), alle
///   Bittiefen (1/2/4/8/16), alle fünf Zeilenfilter, Adam7-Interlacing und `tRNS`.
///
/// Umrechnung in Luminanz (identisch zum C-Filter, ARCHITECTURE.md §4.1):
/// 1. Jede Komponente wird auf 8 Bit gebracht: 16 Bit → höherwertiges Byte,
///    1/2/4 Bit → `v · 255 / (2^Tiefe − 1)`.
/// 2. Farbe → `L = (299·R + 587·G + 114·B) / 1000` (Ganzzahldivision).
/// 3. Alpha `a` (8 Bit) wird auf Weiß verrechnet: `L' = (L·a + 255·(255 − a) + 127) / 255`.
///
/// `tRNS` bei Grau/RGB vergleicht die **ungekürzten** Abtastwerte und ergibt Alpha 0 oder 255.
public enum PNGCodec {

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    // MARK: - Kodierung

    /// Kodiert ein Graustufenbild als 8-Bit-Graustufen-PNG (adaptive Zeilenfilter).
    ///
    /// Ein leeres Bild (Breite oder Höhe 0) wird als 1 × 1 Pixel Weiß kodiert, da PNG keine
    /// leeren Bilder kennt.
    public static func encode(_ image: GrayImage) -> Data {
        let source = image.isEmpty ? GrayImage(width: 1, height: 1) : image
        let w = source.width, h = source.height
        var raw = [UInt8](repeating: 0, count: (w + 1) * h)
        var candidate = [UInt8](repeating: 0, count: w)
        source.pixels.withUnsafeBufferPointer { px in
            raw.withUnsafeMutableBufferPointer { out in
                candidate.withUnsafeMutableBufferPointer { cand in
                    for y in 0..<h {
                        let cur = px.baseAddress! + y * w
                        let prev: UnsafePointer<UInt8>? = y > 0 ? px.baseAddress! + (y - 1) * w : nil
                        let dst = out.baseAddress! + y * (w + 1)
                        // Filter mit kleinster Summe der Beträge (als vorzeichenbehaftete Bytes) wählen.
                        var bestScore = Int.max
                        for filter in UInt8(0)...4 {
                            if prev == nil && (filter == 2 || filter == 4) { continue }
                            var score = 0
                            for x in 0..<w {
                                let a: UInt8 = x > 0 ? cur[x - 1] : 0
                                let b: UInt8 = prev?[x] ?? 0
                                let c: UInt8 = (x > 0 ? prev?[x - 1] : nil) ?? 0
                                let v = cur[x] &- predictor(filter, a, b, c)
                                cand[x] = v
                                score += v < 128 ? Int(v) : 256 - Int(v)
                                if score >= bestScore { break }
                            }
                            if score < bestScore {
                                bestScore = score
                                dst[0] = filter
                                (dst + 1).update(from: cand.baseAddress!, count: w)
                            }
                        }
                    }
                }
            }
        }
        return assemble(width: w, height: h, bitDepth: 8, colorType: 0, filtered: raw)
    }

    /// Kodiert eine 1-Bit-Bitmap als 1-Bit-Graustufen-PNG (schwarz = 0, weiß = 1).
    ///
    /// Eine leere Bitmap wird als 1 × 1 Pixel Weiß kodiert.
    public static func encode(_ bitmap: MonoBitmap) -> Data {
        let source = (bitmap.width == 0 || bitmap.height == 0) ? MonoBitmap(width: 1, height: 1) : bitmap
        let bpr = source.bytesPerRow
        var raw = [UInt8](repeating: 0, count: (bpr + 1) * source.height)
        source.data.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                for y in 0..<source.height {
                    let s = y * bpr, d = y * (bpr + 1)
                    dst[d] = 0   // Filter „None“ (für Bittiefen < 8 empfohlen)
                    for i in 0..<bpr { dst[d + 1 + i] = ~src[s + i] }
                }
            }
        }
        return assemble(width: source.width, height: source.height, bitDepth: 1, colorType: 0, filtered: raw)
    }

    /// Setzt Signatur, IHDR, IDAT und IEND zusammen.
    private static func assemble(width: Int, height: Int, bitDepth: UInt8, colorType: UInt8, filtered: [UInt8]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(filtered.count / 4 + 128)
        out.append(contentsOf: signature)
        var ihdr = [UInt8]()
        ihdr.appendBE32(UInt32(width))
        ihdr.appendBE32(UInt32(height))
        ihdr.append(contentsOf: [bitDepth, colorType, 0, 0, 0])
        appendChunk("IHDR", ihdr, to: &out)
        let compressed = (try? Deflate.compress(bytes: filtered)) ?? Deflate.storedZlibStream(filtered)
        appendChunk("IDAT", compressed, to: &out)
        appendChunk("IEND", [], to: &out)
        return Data(out)
    }

    private static func appendChunk(_ type: String, _ payload: [UInt8], to out: inout [UInt8]) {
        out.appendBE32(UInt32(payload.count))
        let typeBytes = Array(type.utf8)
        let start = out.count
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: payload)
        let crc = out.withUnsafeBufferPointer { buf in
            CRC32.checksum(UnsafeBufferPointer(rebasing: buf[start..<buf.count]))
        }
        out.appendBE32(crc)
    }

    /// PNG-Prädiktor (a = links, b = oben, c = oben links).
    @inline(__always)
    static func predictor(_ filter: UInt8, _ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        switch filter {
        case 1: return a
        case 2: return b
        case 3: return UInt8((Int(a) + Int(b)) >> 1)
        case 4: return paeth(a, b, c)
        default: return 0
        }
    }

    @inline(__always)
    static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    // MARK: - Dekodierung

    /// Kopfdaten (IHDR) einer PNG-Datei.
    struct Header {
        var width: Int
        var height: Int
        var bitDepth: Int
        var colorType: Int
        var interlaced: Bool

        var channels: Int {
            switch colorType {
            case 0, 3: return 1
            case 2: return 3
            case 4: return 2
            default: return 4
            }
        }
        var bitsPerPixel: Int { channels * bitDepth }
        /// Abstand für die Filter (mindestens 1 Byte).
        var filterStride: Int { max(1, bitsPerPixel / 8) }
        func rowBytes(_ w: Int) -> Int { (w * bitsPerPixel + 7) / 8 }
    }

    /// Dekodiert eine PNG-Datei in ein Luminanzbild (Alpha auf Weiß verrechnet).
    ///
    /// - Throws: `ImagingError.invalidPNG` bei beschädigten Daten (Signatur, CRC, Struktur,
    ///   unvollständige Bilddaten), `.unsupportedPNG` bei unbekannten Kompressions-/Filter-/
    ///   Interlace-Methoden, `.imageTooLarge` bei übergroßen Bildern.
    public static func decode(_ data: Data) throws -> GrayImage {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else {
            throw ImagingError.invalidPNG("PNG-Signatur fehlt.")
        }
        var offset = 8
        var header: Header?
        var palette: [UInt8] = []          // RGB-Tripel
        var paletteAlpha: [UInt8] = []     // tRNS für Farbtyp 3
        var transparentKey: [Int]?         // tRNS für Farbtyp 0 (1 Wert) bzw. 2 (3 Werte)
        var idat = [UInt8]()
        var sawIEND = false

        while offset + 8 <= bytes.count {
            let length = Int(bytes.readBE32(at: offset))
            guard length <= Int(Int32.max), offset + 12 + length <= bytes.count else {
                throw ImagingError.invalidPNG("Chunk überschreitet das Dateiende.")
            }
            let typeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
            let type = String(decoding: typeBytes, as: UTF8.self)
            let payloadRange = (offset + 8)..<(offset + 8 + length)
            let isCritical = typeBytes[0] & 0x20 == 0
            let isUsed = isCritical || type == "tRNS"
            if isUsed {
                let storedCRC = bytes.readBE32(at: offset + 8 + length)
                let actualCRC = bytes.withUnsafeBufferPointer { buf in
                    CRC32.checksum(UnsafeBufferPointer(rebasing: buf[(offset + 4)..<(offset + 8 + length)]))
                }
                guard storedCRC == actualCRC else {
                    throw ImagingError.invalidPNG("CRC-Fehler im Chunk \(type).")
                }
            }
            switch type {
            case "IHDR":
                guard header == nil, length == 13 else { throw ImagingError.invalidPNG("Ungültiger IHDR-Chunk.") }
                let p = payloadRange.lowerBound
                let width = Int(bytes.readBE32(at: p))
                let height = Int(bytes.readBE32(at: p + 4))
                let depth = Int(bytes[p + 8]), colorType = Int(bytes[p + 9])
                guard bytes[p + 10] == 0 else { throw ImagingError.unsupportedPNG("Kompressionsmethode \(bytes[p + 10]).") }
                guard bytes[p + 11] == 0 else { throw ImagingError.unsupportedPNG("Filtermethode \(bytes[p + 11]).") }
                guard bytes[p + 12] <= 1 else { throw ImagingError.unsupportedPNG("Interlace-Methode \(bytes[p + 12]).") }
                guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else {
                    throw ImagingError.invalidPNG("Ungültige Bildmaße \(width) × \(height).")
                }
                let allowed: [Int]
                switch colorType {
                case 0: allowed = [1, 2, 4, 8, 16]
                case 3: allowed = [1, 2, 4, 8]
                case 2, 4, 6: allowed = [8, 16]
                default: throw ImagingError.invalidPNG("Unbekannter Farbtyp \(colorType).")
                }
                guard allowed.contains(depth) else {
                    throw ImagingError.invalidPNG("Bittiefe \(depth) ist für Farbtyp \(colorType) unzulässig.")
                }
                try ImagingLimits.check(width: width, height: height)
                header = Header(width: width, height: height, bitDepth: depth, colorType: colorType,
                                interlaced: bytes[p + 12] == 1)
            case "PLTE":
                guard header != nil else { throw ImagingError.invalidPNG("PLTE vor IHDR.") }
                guard length % 3 == 0, length >= 3, length <= 768 else {
                    throw ImagingError.invalidPNG("Ungültige Palettengröße \(length).")
                }
                palette = Array(bytes[payloadRange])
            case "tRNS":
                guard let h = header else { throw ImagingError.invalidPNG("tRNS vor IHDR.") }
                switch h.colorType {
                case 0:
                    guard length >= 2 else { throw ImagingError.invalidPNG("Ungültiger tRNS-Chunk.") }
                    transparentKey = [Int(bytes.readBE16(at: payloadRange.lowerBound))]
                case 2:
                    guard length >= 6 else { throw ImagingError.invalidPNG("Ungültiger tRNS-Chunk.") }
                    let p = payloadRange.lowerBound
                    transparentKey = [Int(bytes.readBE16(at: p)), Int(bytes.readBE16(at: p + 2)), Int(bytes.readBE16(at: p + 4))]
                case 3:
                    paletteAlpha = Array(bytes[payloadRange].prefix(256))
                default:
                    break   // Bei Farbtypen mit Alphakanal unzulässig – wird ignoriert.
                }
            case "IDAT":
                guard header != nil else { throw ImagingError.invalidPNG("IDAT vor IHDR.") }
                idat.append(contentsOf: bytes[payloadRange])
            case "IEND":
                sawIEND = true
            default:
                if isCritical { throw ImagingError.unsupportedPNG("Unbekannter kritischer Chunk \(type).") }
            }
            offset += 12 + length
            if sawIEND { break }
        }

        guard let h = header else { throw ImagingError.invalidPNG("IHDR-Chunk fehlt.") }
        guard !idat.isEmpty else { throw ImagingError.invalidPNG("Keine Bilddaten (IDAT).") }
        if h.colorType == 3 && palette.isEmpty { throw ImagingError.invalidPNG("Palette (PLTE) fehlt.") }

        // Erwartete Rohdatengröße (alle Durchgänge, je Zeile + 1 Filterbyte).
        let passes = h.interlaced ? adam7Passes : [Pass(x0: 0, y0: 0, dx: 1, dy: 1)]
        var expected = 0
        for pass in passes {
            let (pw, ph) = pass.size(width: h.width, height: h.height)
            if pw > 0 && ph > 0 { expected += (h.rowBytes(pw) + 1) * ph }
        }
        var raw = try Deflate.decompress(bytes: idat, expectedSize: expected, limit: expected)
        guard raw.count >= expected else {
            throw ImagingError.invalidPNG("Bilddaten unvollständig (\(raw.count) von \(expected) Bytes).")
        }

        var out = [UInt8](repeating: 255, count: h.width * h.height)
        let converter = PixelConverter(header: h, palette: palette, paletteAlpha: paletteAlpha, transparentKey: transparentKey)
        var passOffset = 0
        try raw.withUnsafeMutableBufferPointer { rawBuf in
            try out.withUnsafeMutableBufferPointer { outBuf in
                for pass in passes {
                    let (pw, ph) = pass.size(width: h.width, height: h.height)
                    guard pw > 0 && ph > 0 else { continue }
                    let rowBytes = h.rowBytes(pw)
                    try unfilter(rawBuf.baseAddress! + passOffset, rowBytes: rowBytes, rows: ph, stride: h.filterStride)
                    for py in 0..<ph {
                        let row = rawBuf.baseAddress! + passOffset + py * (rowBytes + 1) + 1
                        let y = pass.y0 + py * pass.dy
                        converter.convertRow(row, count: pw) { px, value in
                            outBuf[y * h.width + pass.x0 + px * pass.dx] = value
                        }
                    }
                    passOffset += (rowBytes + 1) * ph
                }
            }
        }
        return GrayImage(width: h.width, height: h.height, pixels: out)
    }

    /// Kehrt die Zeilenfilter in-place um. Jede Zeile beginnt mit ihrem Filterbyte.
    static func unfilter(_ base: UnsafeMutablePointer<UInt8>, rowBytes: Int, rows: Int, stride bpp: Int) throws {
        var prev: UnsafeMutablePointer<UInt8>?
        for r in 0..<rows {
            let line = base + r * (rowBytes + 1)
            let filter = line[0]
            let cur = line + 1
            switch filter {
            case 0:
                break
            case 1:
                if rowBytes > bpp {
                    for i in bpp..<rowBytes { cur[i] = cur[i] &+ cur[i - bpp] }
                }
            case 2:
                if let p = prev {
                    for i in 0..<rowBytes { cur[i] = cur[i] &+ p[i] }
                }
            case 3:
                for i in 0..<rowBytes {
                    let a = i >= bpp ? Int(cur[i - bpp]) : 0
                    let b = prev.map { Int($0[i]) } ?? 0
                    cur[i] = cur[i] &+ UInt8((a + b) >> 1)
                }
            case 4:
                for i in 0..<rowBytes {
                    let a: UInt8 = i >= bpp ? cur[i - bpp] : 0
                    let b: UInt8 = prev?[i] ?? 0
                    let c: UInt8 = (i >= bpp ? prev?[i - bpp] : nil) ?? 0
                    cur[i] = cur[i] &+ paeth(a, b, c)
                }
            default:
                throw ImagingError.invalidPNG("Unbekannter Zeilenfilter \(filter).")
            }
            prev = cur
        }
    }

    // MARK: Adam7

    struct Pass {
        var x0: Int, y0: Int, dx: Int, dy: Int
        func size(width: Int, height: Int) -> (Int, Int) {
            let w = width > x0 ? (width - x0 + dx - 1) / dx : 0
            let h = height > y0 ? (height - y0 + dy - 1) / dy : 0
            return (w, h)
        }
    }

    static let adam7Passes: [Pass] = [
        Pass(x0: 0, y0: 0, dx: 8, dy: 8),
        Pass(x0: 4, y0: 0, dx: 8, dy: 8),
        Pass(x0: 0, y0: 4, dx: 4, dy: 8),
        Pass(x0: 2, y0: 0, dx: 4, dy: 4),
        Pass(x0: 0, y0: 2, dx: 2, dy: 4),
        Pass(x0: 1, y0: 0, dx: 2, dy: 2),
        Pass(x0: 0, y0: 1, dx: 1, dy: 2),
    ]

    // MARK: Pixelumrechnung

    /// Wandelt eine entfilterte Zeile in Luminanzwerte um.
    struct PixelConverter {
        let header: Header
        /// Luminanz und Alpha je Palettenindex (256 Einträge, fehlende = schwarz/deckend).
        let paletteLuma: [UInt8]
        let paletteAlpha: [UInt8]
        let transparentKey: [Int]?

        init(header: Header, palette: [UInt8], paletteAlpha: [UInt8], transparentKey: [Int]?) {
            self.header = header
            var luma = [UInt8](repeating: 0, count: 256)
            var alpha = [UInt8](repeating: 255, count: 256)
            for i in 0..<(palette.count / 3) {
                luma[i] = PixelConverter.luminance(palette[3 * i], palette[3 * i + 1], palette[3 * i + 2])
            }
            for (i, a) in paletteAlpha.enumerated() where i < 256 { alpha[i] = a }
            self.paletteLuma = luma
            self.paletteAlpha = alpha
            self.transparentKey = transparentKey
        }

        @inline(__always)
        static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000)
        }

        @inline(__always)
        static func composite(_ l: UInt8, alpha a: UInt8) -> UInt8 {
            if a == 255 { return l }
            return UInt8((Int(l) * Int(a) + 255 * (255 - Int(a)) + 127) / 255)
        }

        func convertRow(_ row: UnsafePointer<UInt8>, count: Int, _ store: (Int, UInt8) -> Void) {
            let depth = header.bitDepth
            switch header.colorType {
            case 0:
                let key = transparentKey?.first
                if depth == 16 {
                    for x in 0..<count {
                        let hi = row[2 * x], lo = row[2 * x + 1]
                        let sample = Int(hi) << 8 | Int(lo)
                        store(x, sample == key ? 255 : hi)
                    }
                } else if depth == 8 {
                    for x in 0..<count {
                        let v = row[x]
                        store(x, Int(v) == key ? 255 : v)
                    }
                } else {
                    let maxValue = (1 << depth) - 1
                    let perByte = 8 / depth
                    for x in 0..<count {
                        let byte = row[x / perByte]
                        let shift = 8 - depth * (x % perByte + 1)
                        let sample = (Int(byte) >> shift) & maxValue
                        store(x, sample == key ? 255 : UInt8(sample * 255 / maxValue))
                    }
                }
            case 2:
                let key = transparentKey
                let step = depth == 16 ? 6 : 3
                for x in 0..<count {
                    let p = row + x * step
                    let r, g, b: UInt8
                    let transparent: Bool
                    if depth == 16 {
                        r = p[0]; g = p[2]; b = p[4]
                        if let key {
                            transparent = (Int(p[0]) << 8 | Int(p[1])) == key[0]
                                && (Int(p[2]) << 8 | Int(p[3])) == key[1]
                                && (Int(p[4]) << 8 | Int(p[5])) == key[2]
                        } else {
                            transparent = false
                        }
                    } else {
                        r = p[0]; g = p[1]; b = p[2]
                        transparent = key.map { Int(r) == $0[0] && Int(g) == $0[1] && Int(b) == $0[2] } ?? false
                    }
                    store(x, transparent ? 255 : PixelConverter.luminance(r, g, b))
                }
            case 3:
                let perByte = 8 / depth
                let mask = (1 << depth) - 1
                for x in 0..<count {
                    let index: Int
                    if depth == 8 {
                        index = Int(row[x])
                    } else {
                        let shift = 8 - depth * (x % perByte + 1)
                        index = (Int(row[x / perByte]) >> shift) & mask
                    }
                    store(x, PixelConverter.composite(paletteLuma[index], alpha: paletteAlpha[index]))
                }
            case 4:
                let step = depth == 16 ? 4 : 2
                let alphaOffset = depth == 16 ? 2 : 1
                for x in 0..<count {
                    let p = row + x * step
                    store(x, PixelConverter.composite(p[0], alpha: p[alphaOffset]))
                }
            default: // 6
                let step = depth == 16 ? 8 : 4
                let unit = depth == 16 ? 2 : 1
                for x in 0..<count {
                    let p = row + x * step
                    let l = PixelConverter.luminance(p[0], p[unit], p[2 * unit])
                    store(x, PixelConverter.composite(l, alpha: p[3 * unit]))
                }
            }
        }
    }
}

// MARK: - Hilfen

extension Array where Element == UInt8 {
    mutating func appendBE32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readBE32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }

    func readBE16(at index: Int) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[index + 1])
    }
}

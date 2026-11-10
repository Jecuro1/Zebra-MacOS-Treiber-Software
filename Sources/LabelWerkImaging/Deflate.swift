import CZlib
import Foundation

/// zlib-Kompression (RFC 1950: zlib-Header + Deflate + Adler-32) über die System-zlib.
///
/// Wird für `:Z64:`-Grafikdaten und PNG-Bilddaten verwendet. Komprimiert wird immer mit
/// `compress2(…, Z_DEFAULT_COMPRESSION)` – identisch zum C-Filter, damit beide Implementierungen
/// byte-gleiche Druckaufträge erzeugen.
public enum Deflate {

    /// Komprimiert Daten im zlib-Format.
    public static func compress(_ data: Data) throws -> Data {
        try Data(compress(bytes: [UInt8](data)))
    }

    /// Dekomprimiert zlib-Daten. Die Ausgabegröße muss nicht bekannt sein (Streaming über
    /// `inflate`). Daten nach dem Ende des zlib-Datenstroms werden ignoriert.
    ///
    /// - Throws: `ImagingError.decompressionFailed`, wenn die Daten beschädigt oder
    ///   unvollständig sind.
    public static func decompress(_ data: Data) throws -> Data {
        try Data(decompress(bytes: [UInt8](data)))
    }

    // MARK: - Byte-Arrays (intern, ohne Data-Umwege)

    static func compress(bytes input: [UInt8], level: Int32 = Z_DEFAULT_COMPRESSION) throws -> [UInt8] {
        guard input.count <= Int(UInt32.max / 2) else {
            throw ImagingError.invalidArgument("Daten zu groß für die Komprimierung (\(input.count) Bytes).")
        }
        let bound = Int(compressBound(uLong(input.count)))
        var output = [UInt8](repeating: 0, count: bound)
        var destLength = uLongf(bound)
        let status = input.withUnsafeBufferPointer { src -> Int32 in
            output.withUnsafeMutableBufferPointer { dst -> Int32 in
                // zlib erwartet auch bei leerer Eingabe einen gültigen Zeiger.
                withUnsafePointer(to: UInt8(0)) { dummy in
                    compress2(dst.baseAddress!, &destLength, src.baseAddress ?? dummy, uLong(src.count), level)
                }
            }
        }
        guard status == Z_OK else { throw ImagingError.compressionFailed(code: status) }
        output.removeSubrange(Int(destLength)...)
        return output
    }

    /// Dekomprimiert einen zlib-Datenstrom.
    ///
    /// - Parameters:
    ///   - expectedSize: Hinweis für die Anfangsgröße des Ausgabepuffers (optional).
    ///   - limit: Höchstzahl benötigter Ausgabebytes. Ist sie erreicht, wird ohne Fehler
    ///     abgebrochen (Schutz vor „Dekompressionsbomben“ bei bekannter Zielgröße).
    static func decompress(bytes input: [UInt8], expectedSize: Int? = nil, limit: Int? = nil) throws -> [UInt8] {
        guard !input.isEmpty else {
            throw ImagingError.decompressionFailed("Keine Daten.")
        }
        var stream = z_stream()
        var status = inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw ImagingError.decompressionFailed("inflateInit fehlgeschlagen (Code \(status)).")
        }
        defer { inflateEnd(&stream) }

        let cap = limit.map { max(0, $0) }
        var initial = max(64, min(expectedSize ?? input.count * 4, 1 << 26))
        if let cap { initial = min(initial, max(cap, 1)) }
        var output = [UInt8](repeating: 0, count: initial)
        var produced = 0
        var consumed = 0
        let maxChunk = Int(UInt32.max >> 1)

        try input.withUnsafeBufferPointer { src in
            let srcBase = UnsafeMutablePointer(mutating: src.baseAddress!)
            while true {
                if let cap, produced >= cap { return }   // genug Daten
                if produced == output.count {
                    // Ausgabepuffer verdoppeln (bzw. um höchstens 64 MiB wachsen).
                    var grow = max(64, min(output.count, 1 << 26))
                    if let cap { grow = min(grow, cap - output.count) }
                    output.append(contentsOf: repeatElement(0, count: grow))
                }
                let inChunk = min(input.count - consumed, maxChunk)
                stream.next_in = srcBase + consumed
                stream.avail_in = uInt(inChunk)
                let outChunk = min(output.count - produced, maxChunk)
                status = output.withUnsafeMutableBufferPointer { dst -> Int32 in
                    stream.next_out = dst.baseAddress! + produced
                    stream.avail_out = uInt(outChunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                consumed += inChunk - Int(stream.avail_in)
                produced += outChunk - Int(stream.avail_out)
                stream.next_in = nil
                stream.next_out = nil

                switch status {
                case Z_STREAM_END:
                    return
                case Z_OK:
                    continue
                case Z_BUF_ERROR:
                    // Kein Fortschritt möglich: Eingabe erschöpft, aber Datenstrom nicht beendet.
                    if consumed >= input.count && stream.avail_out > 0 {
                        throw ImagingError.decompressionFailed("Datenstrom unvollständig.")
                    }
                    continue
                case Z_NEED_DICT:
                    throw ImagingError.decompressionFailed("Voreingestelltes Wörterbuch wird nicht unterstützt.")
                case Z_DATA_ERROR:
                    throw ImagingError.decompressionFailed(Self.message(stream) ?? "Daten beschädigt.")
                case Z_MEM_ERROR:
                    throw ImagingError.decompressionFailed("Nicht genügend Speicher.")
                default:
                    throw ImagingError.decompressionFailed(Self.message(stream) ?? "zlib-Fehler \(status).")
                }
            }
        }
        output.removeSubrange(produced...)
        return output
    }

    private static func message(_ stream: z_stream) -> String? {
        guard let msg = stream.msg else { return nil }
        return String(cString: msg)
    }

    /// Erzeugt einen gültigen zlib-Datenstrom aus unkomprimierten „stored“-Blöcken.
    /// Rückfallebene, falls zlib (theoretisch) die Komprimierung verweigert.
    static func storedZlibStream(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        out.reserveCapacity(input.count + input.count / 65_535 * 5 + 16)
        var offset = 0
        repeat {
            let length = min(65_535, input.count - offset)
            let isFinal = offset + length >= input.count
            out.append(isFinal ? 1 : 0)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out.append(contentsOf: input[offset..<(offset + length)])
            offset += length
        } while offset < input.count
        let adler = Adler32.checksum(input)
        out.append(UInt8(adler >> 24))
        out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF))
        out.append(UInt8(adler & 0xFF))
        return out
    }
}

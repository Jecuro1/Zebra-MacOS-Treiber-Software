import CZlib
import Foundation

/// Entpacken von gzip-Dateien (RFC 1952) über die System-zlib – z. B. der installierten PPDs
/// `/Library/Printers/PPDs/Contents/Resources/LabelWerk-*.ppd.gz`.
public enum Gzip {

    /// `true`, wenn die Daten mit der gzip-Kennung `1F 8B` beginnen.
    public static func isCompressed(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Entpackt gzip-Daten (auch mehrere aneinandergehängte Teile, wie `gzip -dc`). Daten ohne
    /// gzip-Kennung werden unverändert zurückgegeben.
    ///
    /// - Parameter limit: Höchstgröße des Ergebnisses in Bytes (Schutz vor beschädigten Dateien).
    /// - Throws: `ImagingError.decompressionFailed` bei beschädigten oder zu großen Daten.
    public static func decompress(_ data: Data, limit: Int = 64 << 20) throws -> Data {
        guard isCompressed(data) else { return data }
        let input = [UInt8](data)
        var output = [UInt8]()
        var offset = 0
        while offset < input.count {
            // Füllbytes nach dem letzten Teil (z. B. aus Bandlaufwerken) sind erlaubt.
            if input[offset...].allSatisfy({ $0 == 0 }) { break }
            let (part, consumed) = try inflateMember(input, from: offset, limit: limit - output.count)
            output += part
            offset += consumed
            if consumed == 0 { break }
        }
        return Data(output)
    }

    /// Entpackt einen gzip-Teil ab `start`; liefert die Daten und die Zahl der gelesenen Bytes.
    private static func inflateMember(_ input: [UInt8], from start: Int, limit: Int) throws -> ([UInt8], Int) {
        var stream = z_stream()
        // 16 + MAX_WBITS: nur gzip-Kopf und -Prüfsumme (CRC-32, Länge) akzeptieren.
        var status = inflateInit2_(&stream, 16 + MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw ImagingError.decompressionFailed("inflateInit2 fehlgeschlagen (Code \(status)).")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let available = input.count - start
        try input.withUnsafeBufferPointer { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress! + start)
            stream.avail_in = uInt(min(available, Int(UInt32.max >> 1)))
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { target -> Int32 in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                output += buffer[0..<produced]
                guard output.count <= max(0, limit) else {
                    throw ImagingError.decompressionFailed("Entpackte Daten sind zu groß.")
                }
                switch status {
                case Z_OK, Z_STREAM_END:
                    break
                case Z_BUF_ERROR where stream.avail_in == 0:
                    throw ImagingError.decompressionFailed("gzip-Daten unvollständig.")
                case Z_BUF_ERROR:
                    break
                default:
                    let message = stream.msg.map { String(cString: $0) } ?? "zlib-Fehler \(status)."
                    throw ImagingError.decompressionFailed(message)
                }
            } while status != Z_STREAM_END
        }
        return (output, available - Int(stream.avail_in))
    }
}

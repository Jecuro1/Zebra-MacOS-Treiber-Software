import Foundation
import LabelWerkCore

// MARK: - ZPL

/// Erzeugt und dekodiert ZPL-Grafikbefehle (`^GF`, `~DG`).
public enum ZPLGraphicEncoder {

    /// Erzeugt ein `^GF`-Grafikfeld: `^GFA,{total},{total},{bpr},{daten}`.
    ///
    /// `{daten}` je nach Kompression: Hex (Großbuchstaben, ohne Trenner), ACS oder
    /// `:Z64:…:CRC`. Sollte zlib wider Erwarten scheitern, wird auf ACS ausgewichen
    /// (verlustfrei und von jedem ZPL-Drucker verstanden).
    public static func graphicField(_ bitmap: MonoBitmap, compression: GraphicCompression) -> String {
        let total = bitmap.data.count
        return "^GFA,\(total),\(total),\(bitmap.bytesPerRow)," + graphicData(bitmap, compression: compression)
    }

    /// Wie `graphicField`, meldet zlib-Fehler aber als Fehler statt auf ACS auszuweichen.
    static func strictGraphicField(_ bitmap: MonoBitmap, compression: GraphicCompression) throws -> String {
        let total = bitmap.data.count
        let payload: String
        switch compression {
        case .hex: payload = Hex.encode(bitmap.data)
        case .acs: payload = ACS.encode(bitmap)
        case .z64: payload = try Z64.encode(bytes: bitmap.data)
        }
        return "^GFA,\(total),\(total),\(bitmap.bytesPerRow)," + payload
    }

    /// Nur die Datenkomponente eines `^GFA`-Feldes.
    public static func graphicData(_ bitmap: MonoBitmap, compression: GraphicCompression) -> String {
        switch compression {
        case .hex:
            return Hex.encode(bitmap.data)
        case .acs:
            return ACS.encode(bitmap)
        case .z64:
            if let z64 = try? Z64.encode(bytes: bitmap.data) { return z64 }
            return ACS.encode(bitmap)
        }
    }

    /// Erzeugt einen `~DG`-Befehl zum Speichern einer Grafik im Drucker:
    /// `~DG{drive}{NAME}.GRF,{total},{bpr},{hex}`.
    ///
    /// Der Name wird in Großbuchstaben umgewandelt; eine vorhandene Endung `.GRF` wird nicht
    /// verdoppelt. Ein Laufwerk ohne Doppelpunkt (z. B. `"E"`) wird ergänzt.
    public static func downloadGraphic(name: String, drive: String = "R:", bitmap: MonoBitmap) -> String {
        var objectName = name.uppercased()
        if objectName.hasSuffix(".GRF") { objectName.removeLast(4) }
        var driveName = drive.uppercased()
        if driveName.isEmpty { driveName = "R:" }
        if !driveName.hasSuffix(":") { driveName += ":" }
        let total = bitmap.data.count
        return "~DG\(driveName)\(objectName).GRF,\(total),\(bitmap.bytesPerRow)," + Hex.encode(bitmap.data)
    }

    /// Dekodiert die Daten eines `^GF`-Feldes (bzw. `~DG`) in eine Bitmap.
    ///
    /// - Parameters:
    ///   - format: `A` = ASCII (Hex, ACS, `:Z64:`, `:B64:`), `B` = binär (Bytes als
    ///     ISO-Latin-1-Zeichen im String). `C` (proprietär komprimiert) wird nicht unterstützt.
    ///   - totalBytes: Gesamtzahl der Bitmap-Bytes.
    ///   - bytesPerRow: Bytes je Zeile; die Bitmap ist `bytesPerRow × 8` Punkte breit.
    ///   - data: Grafikdaten.
    /// - Returns: Bitmap mit `ceil(totalBytes / bytesPerRow)` Zeilen; fehlende Daten sind weiß.
    public static func decodeGraphicField(format: String, totalBytes: Int, bytesPerRow: Int,
                                          data: String) throws -> MonoBitmap {
        guard bytesPerRow > 0 else {
            throw ImagingError.invalidArgument("Bytes je Zeile müssen größer als 0 sein (\(bytesPerRow)).")
        }
        guard totalBytes >= 0 else {
            throw ImagingError.invalidArgument("Gesamtbytes dürfen nicht negativ sein (\(totalBytes)).")
        }
        let height = (totalBytes + bytesPerRow - 1) / bytesPerRow
        try ImagingLimits.check(width: max(1, bytesPerRow * 8), height: max(1, height))
        let paddedCount = height * bytesPerRow

        var bytes: [UInt8]
        switch format.trimmingCharacters(in: .whitespaces).uppercased() {
        case "A", "":
            let trimmed = data.drop { $0.isWhitespace }
            let marker = trimmed.prefix(5).uppercased()
            if marker == ":Z64:" {
                bytes = try Z64.decodeBytes(String(trimmed), limit: totalBytes)
            } else if marker == ":B64:" {
                bytes = try B64.decodeBytes(String(trimmed))
            } else {
                bytes = try ACS.decode(String(trimmed), bytesPerRow: bytesPerRow, totalBytes: totalBytes)
            }
        case "B":
            bytes = []
            bytes.reserveCapacity(min(totalBytes, data.unicodeScalars.count))
            for scalar in data.unicodeScalars {
                if bytes.count >= totalBytes { break }
                guard scalar.value <= 0xFF else {
                    throw ImagingError.invalidGraphicData("Binärdaten enthalten ein Zeichen außerhalb von ISO-Latin-1 (U+\(String(scalar.value, radix: 16, uppercase: true))).")
                }
                bytes.append(UInt8(scalar.value))
            }
        case "C":
            throw ImagingError.unsupportedGraphicFormat("^GF Format C (komprimiertes Binärformat)")
        default:
            throw ImagingError.unsupportedGraphicFormat("^GF Format „\(format)“")
        }
        // Auf exakte Größe bringen: fehlende Bytes weiß, überzählige verwerfen.
        if bytes.count > totalBytes { bytes.removeSubrange(totalBytes...) }
        if bytes.count < paddedCount { bytes.append(contentsOf: repeatElement(0, count: paddedCount - bytes.count)) }
        return MonoBitmap(trustedWidth: bytesPerRow * 8, height: height, data: bytes)
    }
}

// MARK: - EPL2

/// EPL2-Grafikbefehle.
public enum EPLGraphicEncoder {
    /// `GW{x},{y},{bpr},{h},` + Binärdaten + `\n`.
    ///
    /// Achtung: In EPL bedeutet ein **0-Bit schwarz**. Die Bitmap (1 = schwarz) wird daher
    /// invertiert übertragen; Füllbits werden dadurch zu 1 (weiß).
    public static func gw(x: Int, y: Int, bitmap: MonoBitmap) -> Data {
        var out = Data("GW\(x),\(y),\(bitmap.bytesPerRow),\(bitmap.height),".utf8)
        out.reserveCapacity(out.count + bitmap.data.count + 1)
        out.append(contentsOf: bitmap.data.map { ~$0 })
        out.append(0x0A)
        return out
    }
}

// MARK: - CPCL

/// CPCL-Grafikbefehle.
public enum CPCLGraphicEncoder {
    /// `CG {bpr} {h} {x} {y} ` + Binärdaten (1 = schwarz) + `\r\n`.
    public static func cg(x: Int, y: Int, bitmap: MonoBitmap) -> Data {
        var out = Data("CG \(bitmap.bytesPerRow) \(bitmap.height) \(x) \(y) ".utf8)
        out.reserveCapacity(out.count + bitmap.data.count + 2)
        out.append(contentsOf: bitmap.data)
        out.append(contentsOf: [0x0D, 0x0A])
        return out
    }

    /// `EG {bpr} {h} {x} {y} ` + Hexdaten (Großbuchstaben, 1 = schwarz) + `\r\n`.
    public static func eg(x: Int, y: Int, bitmap: MonoBitmap) -> String {
        "EG \(bitmap.bytesPerRow) \(bitmap.height) \(x) \(y) " + Hex.encode(bitmap.data) + "\r\n"
    }
}

// MARK: - Hex

/// ASCII-Hex-Kodierung in Großbuchstaben.
enum Hex {
    private static let digits: [UInt8] = Array("0123456789ABCDEF".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8](repeating: 0, count: bytes.count * 2)
        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                digits.withUnsafeBufferPointer { hex in
                    for i in 0..<src.count {
                        let b = src[i]
                        dst[2 * i] = hex[Int(b >> 4)]
                        dst[2 * i + 1] = hex[Int(b & 0x0F)]
                    }
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

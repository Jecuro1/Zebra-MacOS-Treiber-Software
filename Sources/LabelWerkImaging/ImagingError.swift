import Foundation

/// Fehler des Moduls `LabelWerkImaging`.
///
/// Alle Codecs (Deflate, Z64, ACS, PNG, PNM) und der `JobEncoder` melden Fehler über diesen Typ.
/// Die Fehlermeldungen (`errorDescription`) sind deutschsprachig und für die Anzeige in der App
/// bzw. im Kommandozeilenwerkzeug gedacht.
public enum ImagingError: Error, Equatable, Hashable, Sendable, LocalizedError {
    /// Ein Argument liegt außerhalb des gültigen Bereichs (z. B. Bitmap mit Breite 0).
    case invalidArgument(String)
    /// zlib konnte die Daten nicht komprimieren (zlib-Rückgabewert).
    case compressionFailed(code: Int32)
    /// zlib konnte die Daten nicht dekomprimieren (beschädigt oder unvollständig).
    case decompressionFailed(String)
    /// Base64-Daten sind ungültig.
    case invalidBase64
    /// Die mitgesendete CRC-16-Prüfsumme stimmt nicht mit den Daten überein.
    case checksumMismatch(expected: UInt16, actual: UInt16)
    /// Grafikdaten (Hex/ACS/Binär) sind ungültig.
    case invalidGraphicData(String)
    /// Das Grafikformat wird nicht unterstützt (z. B. `^GF` Format C).
    case unsupportedGraphicFormat(String)
    /// Die PNG-Datei ist beschädigt oder entspricht nicht der Spezifikation.
    case invalidPNG(String)
    /// Die PNG-Datei verwendet eine nicht unterstützte Variante.
    case unsupportedPNG(String)
    /// Die PNM-Datei (PBM/PGM/PPM) ist beschädigt oder nicht unterstützt.
    case invalidPNM(String)
    /// Das Bild überschreitet die zulässige Größe (Schutz vor Speichererschöpfung).
    case imageTooLarge(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let detail):
            return "Ungültiges Argument: \(detail)"
        case .compressionFailed(let code):
            return "Komprimierung fehlgeschlagen (zlib-Code \(code))."
        case .decompressionFailed(let detail):
            return "Dekomprimierung fehlgeschlagen: \(detail)"
        case .invalidBase64:
            return "Die Base64-Daten sind ungültig."
        case .checksumMismatch(let expected, let actual):
            return "Prüfsummenfehler: erwartet \(Self.hex4(expected)), berechnet \(Self.hex4(actual))."
        case .invalidGraphicData(let detail):
            return "Ungültige Grafikdaten: \(detail)"
        case .unsupportedGraphicFormat(let format):
            return "Nicht unterstütztes Grafikformat: \(format)"
        case .invalidPNG(let detail):
            return "Ungültige PNG-Datei: \(detail)"
        case .unsupportedPNG(let detail):
            return "Nicht unterstützte PNG-Variante: \(detail)"
        case .invalidPNM(let detail):
            return "Ungültige PNM-Datei: \(detail)"
        case .imageTooLarge(let width, let height):
            return "Das Bild ist zu groß (\(width) × \(height) Pixel)."
        }
    }

    private static func hex4(_ value: UInt16) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// Obergrenzen zum Schutz vor übergroßen oder böswilligen Eingaben.
enum ImagingLimits {
    /// Maximale Kantenlänge eines dekodierten Bildes in Pixeln.
    static let maxDimension = 1 << 16
    /// Maximale Pixelanzahl eines dekodierten Bildes (≈ 268 Megapixel).
    static let maxPixelCount = 1 << 28
    /// Maximale Größe einer 1-Bit-Grafik in Bytes (`maxPixelCount / 8` = 32 MiB). Jede Grafik,
    /// die `check` besteht, passt hinein; größere Angaben (z. B. `^GF`-Gesamtbytes) werden
    /// abgewiesen, bevor Speicher reserviert wird.
    static let maxGraphicBytes = maxPixelCount / 8

    /// Prüft Bildmaße gegen die Obergrenzen.
    static func check(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw ImagingError.invalidArgument("Bildmaße \(width) × \(height) sind ungültig.")
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width <= maxDimension, height <= maxDimension,
              !pixels.overflow, pixels.partialValue <= maxPixelCount
        else {
            throw ImagingError.imageTooLarge(width: width, height: height)
        }
    }

    /// Maße einer 1-Bit-Grafik aus ZPL-Größenangaben (`^GF`, `~DG`), ohne Ganzzahlüberlauf.
    ///
    /// Breite = `bytesPerRow × 8` Punkte (läuft das über, wird `Int.max` geliefert, was jede
    /// Prüfung abweist), Höhe = `⌈totalBytes / bytesPerRow⌉` – bewusst nicht als
    /// `(totalBytes + bytesPerRow − 1) / bytesPerRow`, weil die Summe bei fremden Eingaben
    /// überlaufen kann.
    ///
    /// - Precondition: `bytesPerRow > 0` und `totalBytes ≥ 0` (vom Aufrufer bereits geprüft).
    static func graphicSize(totalBytes: Int, bytesPerRow: Int) -> (width: Int, height: Int) {
        let width = bytesPerRow.multipliedReportingOverflow(by: 8)
        let height = totalBytes / bytesPerRow + (totalBytes % bytesPerRow == 0 ? 0 : 1)
        return (width.overflow ? Int.max : width.partialValue, height)
    }
}

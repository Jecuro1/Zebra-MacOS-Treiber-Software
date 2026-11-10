import Foundation

/// Zentrale Fassade aller Barcode-Encoder.
///
/// Alle Funktionen sind rein (keine Seiteneffekte) und threadsicher.
public enum BarcodeEncoder {

    // MARK: Lineare Codes

    /// Code 128.
    ///
    /// * `.auto`: codewortminimale Kombination der Zeichensätze A/B/C (inkl. SHIFT, FNC4 für
    ///   ISO-8859-1-Zeichen 128…255).
    /// * `.subsetA/.subsetB`: nur der gewählte Zeichensatz (Einzelzeichen des jeweils anderen per SHIFT).
    /// * `.subsetC`: nur Ziffernpaare.
    /// * `.ucc`: GS1-128, Eingabe als `(01)09501101530003(10)ABC` oder roh mit GS (ASCII 29) als
    ///   Feldtrenner; FNC1 wird automatisch gesetzt, Prüfziffern für AI 00/01/02 ergänzt.
    public static func code128(_ text: String, mode: Code128Mode = .auto) throws -> LinearBarcode {
        try Code128.encode(text, mode: mode)
    }

    /// Code 128 aus vorgegebenen Symbolwerten (Startzeichen 103…105, danach Werte 0…102).
    /// Prüf- und Stoppzeichen werden ergänzt. Für exakte Nachbildung von ZPL-Aufrufcodes.
    public static func code128(symbolValues: [Int], humanReadable: String) throws -> LinearBarcode {
        try Code128.encode(symbolValues: symbolValues, humanReadable: humanReadable)
    }

    /// Code 39 mit optionaler Modulo-43-Prüfziffer und Full-ASCII-Erweiterung.
    /// Die Klarschrift enthält die Start-/Stoppzeichen `*` (wie ZPL `^B3`).
    public static func code39(_ text: String, checkDigit: Bool = false, fullASCII: Bool = false) throws -> LinearBarcode {
        try Code39.encode(text, checkDigit: checkDigit, fullASCII: fullASCII)
    }

    /// Code 93 inklusive der Prüfzeichen C und K; Full ASCII wird automatisch verwendet.
    public static func code93(_ text: String) throws -> LinearBarcode {
        try Code93.encode(text)
    }

    /// EAN-13 aus 12 Ziffern (Prüfziffer wird berechnet) oder 13 Ziffern (Prüfziffer wird validiert).
    public static func ean13(_ digits: String) throws -> LinearBarcode {
        try EANUPC.ean13(digits)
    }

    /// EAN-8 aus 7 oder 8 Ziffern.
    public static func ean8(_ digits: String) throws -> LinearBarcode {
        try EANUPC.ean8(digits)
    }

    /// UPC-A aus 11 oder 12 Ziffern.
    public static func upcA(_ digits: String) throws -> LinearBarcode {
        try EANUPC.upcA(digits)
    }

    /// UPC-E aus 6 Ziffern (Nummernsystem 0), 7 Ziffern (Nummernsystem 0/1 + 6) oder 8 Ziffern
    /// (zusätzlich Prüfziffer); 11/12-stellige UPC-A-Nummern werden komprimiert, sofern möglich.
    public static func upcE(_ digits: String) throws -> LinearBarcode {
        try EANUPC.upcE(digits)
    }

    /// Interleaved 2 of 5; ungerade Längen erhalten eine führende 0.
    public static func interleaved2of5(_ digits: String, checkDigit: Bool = false) throws -> LinearBarcode {
        try Interleaved2of5.encode(digits, checkDigit: checkDigit)
    }

    /// Codabar mit Start-/Stoppzeichen A–D (Alternativen T/N/*/E werden akzeptiert).
    public static func codabar(_ text: String, start: Character = "A", stop: Character = "A") throws -> LinearBarcode {
        try Codabar.encode(text, start: start, stop: stop)
    }

    // MARK: 2D-Codes

    /// QR-Code (Modell 2) mit automatischer Version und Maske. Text wird als UTF-8 kodiert.
    public static func qr(_ text: String, errorCorrection: QRErrorCorrection = .medium) throws -> BitMatrix {
        try QRCode.encode(text, level: errorCorrection)
    }

    /// QR-Code mit Mindestversion (1…40) und optional fester Maske (0…7, `nil` = automatisch).
    public static func qr(_ text: String, errorCorrection: QRErrorCorrection, minimumVersion: Int, mask: Int?) throws -> BitMatrix {
        try QRCode.encode(text, level: errorCorrection, minimumVersion: minimumVersion, mask: mask)
    }

    /// Data Matrix ECC200 (quadratisch, kleinstes passendes Symbol). Text wird als UTF-8 kodiert;
    /// die Kodierung (ASCII/C40/Text/X12/EDIFACT/Base 256) wird codewortminimal gewählt.
    public static func dataMatrix(_ text: String) throws -> BitMatrix {
        try DataMatrix.encode(text, options: DataMatrixOptions())
    }

    /// Data Matrix ECC200 mit wählbarer Symbolform.
    public static func dataMatrix(_ text: String, shape: DataMatrixShape) throws -> BitMatrix {
        try DataMatrix.encode(text, options: DataMatrixOptions(shape: shape))
    }

    /// Data Matrix ECC200 mit allen Einstellungen (Form oder feste Symbolgröße).
    public static func dataMatrix(_ text: String, options: DataMatrixOptions) throws -> BitMatrix {
        try DataMatrix.encode(text, options: options)
    }

    /// Data Matrix ECC200 aus Binärdaten.
    public static func dataMatrix(bytes: [UInt8], options: DataMatrixOptions = DataMatrixOptions()) throws -> BitMatrix {
        try DataMatrix.encode(bytes: bytes, options: options)
    }

    /// PDF417. Jede Symbolzeile ist 3 Matrixzeilen hoch (Empfehlung der Norm: Zeilenhöhe ≥ 3 Module).
    ///
    /// - Parameters:
    ///   - columns: Datenspalten 1…30, 0 = automatisch.
    ///   - securityLevel: Fehlerkorrekturstufe 0…8.
    public static func pdf417(_ text: String, columns: Int = 0, securityLevel: Int = 2) throws -> BitMatrix {
        try PDF417.encode(bytes: Array(text.utf8), options: PDF417Options(columns: columns, securityLevel: securityLevel))
    }

    /// PDF417 mit allen Einstellungen (Zeilen, Zeilenhöhe, Kompakt-PDF417).
    public static func pdf417(_ text: String, options: PDF417Options) throws -> BitMatrix {
        try PDF417.encode(bytes: Array(text.utf8), options: options)
    }

    /// PDF417 aus Binärdaten.
    public static func pdf417(bytes: [UInt8], options: PDF417Options = PDF417Options()) throws -> BitMatrix {
        try PDF417.encode(bytes: bytes, options: options)
    }

    // MARK: Vereinheitlicht

    /// Kodiert `text` mit den Standardeinstellungen der Symbologie.
    public static func encode(_ text: String, as symbology: BarcodeSymbology) throws -> Barcode {
        switch symbology {
        case .code128: return .linear(try code128(text))
        case .code39: return .linear(try code39(text))
        case .code93: return .linear(try code93(text))
        case .ean13: return .linear(try ean13(text))
        case .ean8: return .linear(try ean8(text))
        case .upcA: return .linear(try upcA(text))
        case .upcE: return .linear(try upcE(text))
        case .interleaved2of5: return .linear(try interleaved2of5(text))
        case .codabar: return .linear(try codabar(text))
        case .qr: return .matrix(try qr(text))
        case .dataMatrix: return .matrix(try dataMatrix(text))
        case .pdf417: return .matrix(try pdf417(text))
        }
    }
}

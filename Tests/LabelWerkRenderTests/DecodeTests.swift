import Foundation
import Testing
import LabelWerkImaging
@testable import LabelWerkRender

/// Unabhängige Prüfung: Gerasterte Etiketten werden mit zxing-cpp gelesen. Läuft nur, wenn ein
/// Python-Interpreter mit zxing-cpp und Pillow gefunden wird (`LABELWERK_ZXING_PYTHON` oder
/// `python3` im `PATH`, siehe `TestSupport.pythonPath`); sonst wird die Suite mit Begründung
/// übersprungen.
@Suite("Rückleser (zxing-cpp)", .enabled(if: TestSupport.hasZXing, TestSupport.zxingSkipReason))
struct DecodeTests {

    private func decode(_ zpl: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: String] {
        let label = TestSupport.label(zpl, sourceLocation: sourceLocation)
        #expect(label.warnings.isEmpty, "\(label.warnings)", sourceLocation: sourceLocation)
        let results = try TestSupport.decode(SoftwareRasterizer.rasterize(label))
        return Dictionary(results.map { ($0.format, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("QR-Code aus dem Rasterizer ist lesbar (verschiedene Präfixe, Größen, Umlaute)")
    func qrCodes() throws {
        let cases: [(String, String)] = [
            ("^BQN,2,4^FDQA,https://labelwerk.example/track?id=0034567890", "https://labelwerk.example/track?id=0034567890"),
            ("^BQN,2,3^FDHM,AHELLO WORLD 123", "HELLO WORLD 123"),
            ("^BQN,2,2^FDLA,0123456789012345678901234567890123456789", "0123456789012345678901234567890123456789"),
            ("^BQN,2,5^FDMA,Grüße aus München – 25 €", "Grüße aus München – 25 €"),
            // Manuelle Eingabe mit mehreren Segmenten (Beispiel des ZPL II Programming Guide).
            ("^BQN,2,5^FDLM,N0123456789,A12AABB,B0006qrcode", "012345678912AABBqrcode"),
            ("^BQN,2,5^FDHM,B0013Grüße, Welt,N42", "Grüße, Welt42"),
        ]
        for (command, expected) in cases {
            let decoded = try decode("^XA^CI28^PW600^LL600^FO60,60" + command + "^FS^XZ")
            #expect(decoded["QRCode"] == expected, "\(command): \(decoded)")
        }
    }

    @Test("Versandetikett: Code 128 und QR-Code sind lesbar")
    func parcelLabel() throws {
        let decoded = try decode(ShippingLabelTests.parcelLabel)
        #expect(decoded["Code128"] == "00340434161234567890")
        #expect(decoded["QRCode"] == "https://labelwerk.example/t/00340434161234567890")
    }

    @Test("Lineare Codes und 2D-Codes sind lesbar", arguments: [
        ("^BY2^BCN,80,Y,N,N^FDLabelWerk-128", "Code128", "LabelWerk-128"),
        ("^BY2^BCN,80,Y,N,N,A^FDABC1234567890", "Code128", "ABC1234567890"),
        ("^BY2^B3N,N,80,Y,N^FDCODE-39 TEST", "Code39", "CODE-39 TEST"),
        ("^BY2^BAN,80,Y,N^FDCODE93", "Code93", "CODE93"),
        ("^BY2^BEN,80,Y,N^FD400638133393", "EAN13", "4006381333931"),
        ("^BY2^B8N,80,Y,N^FD5512345", "EAN8", "55123457"),
        ("^BY2^BUN,80,Y,N^FD03600029145", "UPCA", "036000291452"),
        ("^BY2^B2N,80,Y,N^FD1234567890", "ITF", "1234567890"),
        ("^BY2^BKN,N,80,Y,N,A,B^FD40156", "Codabar", "A40156B"),
        ("^BXN,6,200^FDLabelWerk Data Matrix", "DataMatrix", "LabelWerk Data Matrix"),
        ("^BY2^B7N,6,3,4^FDLabelWerk PDF417 1234567890", "PDF417", "LabelWerk PDF417 1234567890"),
    ])
    func symbologies(command: String, format: String, expected: String) throws {
        let decoded = try decode("^XA^PW700^LL400^FO60,60" + command + "^FS^XZ")
        // zxing-cpp liefert UPC-A je nach Version als UPCA oder EAN13 (mit führender 0).
        let value = decoded[format] ?? (format == "UPCA" ? decoded["EAN13"].map { String($0.dropFirst()) } : nil)
        #expect(value == expected, "\(command): \(decoded)")
    }

    @Test("Gedrehte und invertierte Barcodes sind lesbar")
    func rotatedAndReversed() throws {
        for orientation in ["R", "I", "B"] {
            let decoded = try decode("^XA^PW600^LL600^BY2^FO100,100^BC\(orientation),100,N^FDDREH\(orientation)^FS^XZ")
            #expect(decoded["Code128"] == "DREH\(orientation)", "\(orientation): \(decoded)")
        }
        let reversed = try decode("^XA^PW600^LL400^FO20,20^GB560,300,300^FS^BY2^FO80,80^FR^BCN,120,N^FDINVERS^FS^XZ")
        // Weiße Balken auf Schwarz: zxing-cpp liest invertierte Codes nur mit try_invert – daher
        // prüfen wir das invertierte Bild.
        if reversed["Code128"] == nil {
            let label = TestSupport.label("^XA^PW600^LL400^FO20,20^GB560,300,300^FS^BY2^FO80,80^FR^BCN,120,N^FDINVERS^FS^XZ")
            let inverted = SoftwareRasterizer.rasterize(label).inverted()
            let results = try TestSupport.decode(inverted)
            #expect(results.contains { $0.format == "Code128" && $0.text == "INVERS" })
        }
    }
}

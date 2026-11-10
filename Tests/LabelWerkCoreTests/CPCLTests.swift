import Foundation
import Testing
@testable import LabelWerkCore

private let cpclCases: [CommandCase] = [
    CommandCase(CPCL.header(height: 400), "! 0 200 200 400 1"),
    CommandCase(CPCL.header(resolution: .dpi203, height: 400), "! 0 200 200 400 1"),
    CommandCase(CPCL.header(offset: 10, resolution: .dpi300, height: 600, quantity: 3), "! 10 300 300 600 3"),
    CommandCase(CPCL.header(resolution: .dpi600, height: 0, quantity: 0), "! 0 600 600 1 1"),
    CommandCase(CPCL.pageWidth(576), "PAGE-WIDTH 576"),
    CommandCase(CPCL.contrast(2), "CONTRAST 2"),
    CommandCase(CPCL.contrast(9), "CONTRAST 3"),
    CommandCase(CPCL.speed(3), "SPEED 3"),
    CommandCase(CPCL.speed(9), "SPEED 5"),
    CommandCase(CPCL.tone(50), "TONE 50"),
    CommandCase(CPCL.tone(-150), "TONE -99"),
    CommandCase(CPCL.tone(500), "TONE 200"),
    CommandCase(CPCL.form(), "FORM"),
    CommandCase(CPCL.print(), "PRINT"),
    CommandCase(CPCL.journal(), "JOURNAL"),
    CommandCase(CPCL.prefeed(20), "PREFEED 20"),
    CommandCase(CPCL.postfeed(30), "POSTFEED 30"),
    CommandCase(CPCL.country("germany"), "COUNTRY GERMANY"),
    CommandCase(CPCL.text("Hallo", x: 10, y: 20), "TEXT 7 0 10 20 Hallo"),
    CommandCase(CPCL.text("A\nB", font: "4", size: 1, x: 0, y: 5, rotation: .rotated90), "TEXT90 4 1 0 5 A B"),
    CommandCase(CPCL.text("X", x: 1, y: 2, rotation: .rotated180), "TEXT180 7 0 1 2 X"),
    CommandCase(CPCL.text("X", x: 1, y: 2, rotation: .rotated270), "TEXT270 7 0 1 2 X"),
    CommandCase(CPCL.setMagnification(width: 2, height: 2), "SETMAG 2 2"),
    CommandCase(CPCL.setMagnification(width: 0, height: 0), "SETMAG 0 0"),
    CommandCase(CPCL.setMagnification(width: 40, height: 3), "SETMAG 16 3"),
    CommandCase(CPCL.setBold(2), "SETBOLD 2"),
    CommandCase(CPCL.setSpacing(3), "SETSP 3"),
    CommandCase(CPCL.center(), "CENTER"),
    CommandCase(CPCL.center(400), "CENTER 400"),
    CommandCase(CPCL.left(), "LEFT"),
    CommandCase(CPCL.right(576), "RIGHT 576"),
    CommandCase(CPCL.barcode("123456", type: .code128, x: 10, y: 20, height: 50), "BARCODE 128 1 1 50 10 20 123456"),
    CommandCase(CPCL.barcode("4006381333931", type: .ean13, x: 0, y: 0, height: 80, narrowBar: 2, ratio: 0, vertical: true),
                "VBARCODE EAN13 2 0 80 0 0 4006381333931"),
    CommandCase(CPCL.barcode("CODE39", type: .code39, x: 5, y: 6, height: 40, narrowBar: 1, ratio: 20),
                "BARCODE 39 1 20 40 5 6 CODE39"),
    CommandCase(CPCL.barcode("1234", type: .interleaved2of5, x: 5, y: 6, height: 40), "BARCODE I2OF5 1 1 40 5 6 1234"),
    CommandCase(CPCL.barcodeText(), "BARCODE-TEXT 7 0 5"),
    CommandCase(CPCL.barcodeText(font: "0", size: 2, offset: 3), "BARCODE-TEXT 0 2 3"),
    CommandCase(CPCL.barcodeTextOff(), "BARCODE-TEXT OFF"),
    CommandCase(CPCL.qrCode("ABC123", x: 10, y: 100), "BARCODE QR 10 100 M 2 U 6\r\nMA,ABC123\r\nENDQR"),
    CommandCase(CPCL.qrCode("x", x: 0, y: 0, model: 1, unitSize: 40, errorCorrection: "q", vertical: true),
                "VBARCODE QR 0 0 M 1 U 32\r\nQA,x\r\nENDQR"),
    CommandCase(CPCL.qrCode("a\r\nb", x: 0, y: 0, errorCorrection: "Z"), "BARCODE QR 0 0 M 2 U 6\r\nMA,a  b\r\nENDQR"),
    CommandCase(CPCL.box(x0: 0, y0: 0, x1: 100, y1: 50, thickness: 2), "BOX 0 0 100 50 2"),
    CommandCase(CPCL.box(x0: 0, y0: 0, x1: 100, y1: 50), "BOX 0 0 100 50 1"),
    CommandCase(CPCL.line(x0: 0, y0: 10, x1: 200, y1: 10, thickness: 3), "LINE 0 10 200 10 3"),
    CommandCase(CPCL.inverseLine(x0: 0, y0: 0, x1: 200, y1: 0, thickness: 40), "INVERSE-LINE 0 0 200 0 40"),
    CommandCase(CPCL.gapSense(), "GAP-SENSE"),
    CommandCase(CPCL.barSense(), "BAR-SENSE"),
]

@Suite("CPCL-Bausteine")
struct CPCLTests {
    @Test("Exakte Befehlszeilen", arguments: cpclCases)
    func commands(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("Auflösungswert der Kopfzeile")
    func resolutionValue() {
        #expect(CPCL.resolutionValue(.dpi203) == 200)
        #expect(CPCL.resolutionValue(.dpi300) == 300)
        #expect(CPCL.resolutionValue(.dpi600) == 600)
        #expect(CPCL.resolutionValue(.dpi152) == 152)
    }

    @Test("Zeilenende CR LF")
    func render() {
        #expect(CPCL.lineEnding == "\r\n")
        #expect(CPCL.render(["A", "B"]) == "A\r\nB\r\n")
    }

    @Test("Etikett mit Result Builder")
    func label() {
        let bold = true
        let cpcl = CPCL.label(height: 200) {
            CPCL.pageWidth(400)
            if bold { CPCL.setBold(1) }
            for i in 0..<2 { CPCL.text("Z\(i)", x: 0, y: i * 30) }
            CPCL.qrCode("Q", x: 200, y: 0, unitSize: 4)
        }
        #expect(cpcl == "! 0 200 200 200 1\r\nPAGE-WIDTH 400\r\nSETBOLD 1\r\nTEXT 7 0 0 0 Z0\r\nTEXT 7 0 0 30 Z1\r\n"
            + "BARCODE QR 200 0 M 2 U 4\r\nMA,Q\r\nENDQR\r\nFORM\r\nPRINT\r\n")
        #expect(CPCL.label(height: 100, resolution: .dpi300, quantity: 2, form: false) {}
            == "! 0 300 300 100 2\r\nPRINT\r\n")
    }

    @Test("Utilities-Block")
    func utilities() {
        #expect(CPCL.utilities { CPCL.gapSense() } == "! UTILITIES\r\nGAP-SENSE\r\nPRINT\r\n")
        #expect(CPCL.utilities { CPCL.barSense() } == "! UTILITIES\r\nBAR-SENSE\r\nPRINT\r\n")
    }

    @Test("Bereinigung und Umschrift")
    func sanitizing() {
        #expect(CPCL.sanitized("a\r\nb\tc\u{1}d") == "a  b cd")
        #expect(CPCL.transliterated("Prüfung · 3 × 4") == "Pruefung - 3 x 4")
    }

    @Test("Alle Barcode-Typen haben eindeutige Codes")
    func barcodeTypes() {
        let codes = CPCL.BarcodeType.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
    }
}

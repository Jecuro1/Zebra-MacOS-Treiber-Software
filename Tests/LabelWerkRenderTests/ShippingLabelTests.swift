import Foundation
import Testing
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging
@testable import LabelWerkRender

@Suite("Realistische Etiketten")
struct ShippingLabelTests {

    /// Versandetikett im Stil eines Paketdienstes (4 × 6 Zoll, 203 dpi).
    static let parcelLabel = """
    ^XA
    ^CI28
    ^PW812
    ^LL1218
    ^LH0,0
    ^FX ===== Absender =====^FS
    ^CF0,28
    ^FO40,40^FDLabelWerk Versand GmbH^FS
    ^FO40,75^FDMusterstraße 12^FS
    ^FO40,110^FD80331 München^FS
    ^FO600,40^GB170,110,4^FS
    ^FO615,55^A0N,90,70^FDP1^FS
    ^FO30,170^GB752,3,3^FS
    ^FX ===== Empfänger =====^FS
    ^FO40,190^ADN,36,20^FDAN:^FS
    ^FO120,190^A0N,44,44^FB640,4,6,L,0^FDJürgen Müller\\&c/o Bäckerei Groß\\&Hauptstraße 5\\&10115 Berlin^FS
    ^FO30,420^GB752,3,3^FS
    ^FX ===== Routing =====^FS
    ^FO40,440^A0N,120,100^FDDE-101^FS
    ^FO560,440^GB200,130,130^FS
    ^FO585,470^A0N,80,80^FR^FDEXP^FS
    ^FO30,590^GB752,3,3^FS
    ^FX ===== Sendungsnummer =====^FS
    ^BY3,3,200
    ^FO90,620^BCN,200,Y,N,N^FD>;00340434161234567890^FS
    ^FO30,880^GB752,3,3^FS
    ^FX ===== QR und Details =====^FS
    ^FO40,900^BQN,2,5^FDQA,https://labelwerk.example/t/00340434161234567890^FS
    ^FO330,910^A0N,30,30^FDGewicht: 2,4 kg^FS
    ^FO330,950^A0N,30,30^FDPaket 1 von 1^FS
    ^FO330,990^A0N,30,30^FDReferenz: A-2026-0042^FS
    ^FT330,1150^A0N,26,26^FDSendungsdatum: 10.11.2026^FS
    ^FO740,900^A0R,30,30^FDLabelWerk^FS
    ^PQ2
    ^XZ
    """

    @Test("Versandetikett: Elemente, Inhalte und Positionen")
    func parcelElements() throws {
        let label = TestSupport.label(Self.parcelLabel)
        #expect(label.warnings.isEmpty, "\(label.warnings)")
        #expect(label.widthDots == 812 && label.heightDots == 1218)
        #expect(label.quantity == 2)
        #expect(!label.inverted && !label.mirrored)

        let texts = TestSupport.texts(label)
        #expect(texts.map(\.text) == [
            "LabelWerk Versand GmbH", "Musterstraße 12", "80331 München", "P1", "AN:",
            "Jürgen Müller\\&c/o Bäckerei Groß\\&Hauptstraße 5\\&10115 Berlin",
            "DE-101", "EXP", "Gewicht: 2,4 kg", "Paket 1 von 1", "Referenz: A-2026-0042",
            "Sendungsdatum: 10.11.2026", "LabelWerk",
        ])
        // ^CF0,28 gilt für Felder ohne ^A
        #expect(texts[0].fontName == "0" && texts[0].height == 28 && texts[0].width == 28)
        #expect(texts[4].fontName == "D" && texts[4].height == 36 && texts[4].width == 20)
        let recipient = texts[5]
        #expect(recipient.block == FieldBlock(width: 640, maxLines: 4, lineSpacing: 6, justification: .left))
        #expect(TextLayout(element: recipient, dotsPerMM: 8).lineCount == 4)
        #expect(texts[7].reverse)
        #expect(texts[11].origin == LabelPoint(x: 330, y: 1150 - 20))   // ^FT: Grundlinie 3/4 × 26 ≈ 20
        #expect(texts[12].orientation == .rotated90)

        let boxes = TestSupport.boxes(label)
        #expect(boxes.count == 6)
        #expect(boxes.filter { $0.width == 752 && $0.height == 3 }.count == 4)

        let code128 = try #require(TestSupport.linearBarcodes(label).first)
        #expect(code128.text == ">;00340434161234567890")
        #expect(code128.barcode.humanReadable == "00340434161234567890")
        #expect(code128.barcode.elements == (try BarcodeEncoder.code128("00340434161234567890", mode: .subsetC)).elements)
        #expect(code128.moduleWidth == 3 && code128.height == 200)
        #expect(code128.origin == LabelPoint(x: 90, y: 620))

        let qr = try #require(TestSupport.matrixBarcodes(label).first)
        #expect(qr.text == "https://labelwerk.example/t/00340434161234567890")
        #expect(qr.moduleSize == 5)
        #expect(label.elements.count == texts.count + boxes.count + 2)
    }

    @Test("Versandetikett: Rasterung bleibt im Etikett, Barcodes sitzen an ihren Positionen")
    func parcelRaster() throws {
        let label = TestSupport.label(Self.parcelLabel)
        let raster = SoftwareRasterizer.rasterize(label)
        #expect(raster.width == 812 && raster.height == 1218)
        // Code-128-Balken: Zeile in der Mitte der Balken entspricht dem Referenzraster.
        let code128 = try #require(TestSupport.linearBarcodes(label).first)
        let reference = BarcodeRasterizer.render(code128.barcode, moduleWidth: 3, ratio: 3, height: 1, quietZone: 0)
        let row = 620 + 100
        for x in 0..<reference.width where raster[90 + x, row] != reference.pixels[x] {
            Issue.record("Code-128-Balken weicht bei x = \(x) ab")
            break
        }
        // QR-Code: Modulmittelpunkte entsprechen der Matrix.
        let qr = try #require(TestSupport.matrixBarcodes(label).first)
        for my in 0..<qr.matrix.height {
            for mx in 0..<qr.matrix.width where raster[40 + mx * 5 + 2, 900 + my * 5 + 2] != qr.matrix[mx, my] {
                Issue.record("QR-Modul (\(mx), \(my)) weicht ab")
                return
            }
        }
        // Umgekehrtes Feld: „EXP“ erscheint weiß im schwarzen Kasten.
        let inside = TestSupport.blackCount(raster, x: 560, y: 440, width: 200, height: 130)
        #expect(inside < 200 * 130 && inside > 200 * 130 / 2)
    }

    @Test("Testetikett von LabelWerkCore wird ohne Hinweise interpretiert", arguments: [
        (812, 1218, Resolution.dpi203), (1200, 1800, .dpi300), (406, 203, .dpi203), (2400, 1200, .dpi600),
    ])
    func coreTestLabel(width: Int, height: Int, resolution: Resolution) throws {
        let zpl = TestLabel.zpl(widthDots: width, heightDots: height, resolution: resolution, title: "LabelWerk",
                                subtitle: "Prüfdruck", date: Date(timeIntervalSince1970: 1_794_319_509),
                                timeZone: TimeZone(identifier: "UTC")!)
        let document = ZPLInterpreter(dotsPerMM: resolution.dotsPerMM, defaultWidthDots: width,
                                      defaultHeightDots: height).render(zpl)
        #expect(document.allWarnings.isEmpty, "\(document.allWarnings)")
        let label = try #require(document.labels.first)
        #expect(label.widthDots == width && label.heightDots == height)
        #expect(!TestSupport.texts(label).isEmpty)
        let raster = SoftwareRasterizer.rasterize(label)
        #expect(raster.blackPixelCount > 0)
    }
}

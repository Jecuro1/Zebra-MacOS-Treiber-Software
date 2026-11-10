import Foundation
import Testing
import LabelWerkBarcode
import LabelWerkCore
@testable import LabelWerkRender

@Suite("ZPLInterpreter – Barcodes")
struct InterpreterBarcodeTests {

    private func linear(_ zpl: String, sourceLocation: SourceLocation = #_sourceLocation) -> LinearBarcodeElement? {
        let label = TestSupport.label("^XA" + zpl + "^XZ", sourceLocation: sourceLocation)
        #expect(label.warnings.isEmpty, "\(label.warnings)", sourceLocation: sourceLocation)
        return TestSupport.linearBarcodes(label).first
    }

    private func matrix(_ zpl: String, sourceLocation: SourceLocation = #_sourceLocation) -> MatrixBarcodeElement? {
        let label = TestSupport.label("^XA" + zpl + "^XZ", sourceLocation: sourceLocation)
        return TestSupport.matrixBarcodes(label).first
    }

    private static func ascii(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) - 32 } }

    // MARK: Code 128

    @Test("^BC Modus N: Zeichensatz B ohne Aufrufcode, Zeichensatz C mit >;")
    func code128ModeN() throws {
        let plain = try #require(linear("^FO10,10^BY2^BCN,80,Y,N,N^FD12345678^FS"))
        let expected = try BarcodeEncoder.code128(symbolValues: [104] + Self.ascii("12345678"), humanReadable: "12345678")
        #expect(plain.barcode == expected)
        #expect(plain.symbology == .code128)
        #expect(plain.moduleWidth == 2 && plain.height == 80)
        #expect(plain.printInterpretation && !plain.interpretationAbove)
        #expect(plain.text == "12345678")

        let subsetC = try #require(linear("^FO10,10^BCN,80^FD>;12345678^FS"))
        #expect(subsetC.barcode.elements == (try BarcodeEncoder.code128("12345678", mode: .subsetC)).elements)
        #expect(subsetC.barcode.humanReadable == "12345678")
    }

    @Test("^BC Modus N: Aufrufcodes >5, >6, >7, >8, >< und Zeichensatzwechsel")
    func code128Invocation() throws {
        let mixed = try #require(linear("^FO0,0^BCN,50^FD>:AB>5123456^FS"))
        let values = [104, 33, 34, 99, 12, 34, 56]
        #expect(mixed.barcode == (try BarcodeEncoder.code128(symbolValues: values, humanReadable: "AB123456")))

        let fnc1 = try #require(linear("^FO0,0^BCN,50^FD>;>80112345678901234^FS"))
        let fnc1Values = [105, 102, 1, 12, 34, 56, 78, 90, 12, 34]
        #expect(fnc1.barcode.elements == (try BarcodeEncoder.code128(symbolValues: fnc1Values, humanReadable: "")).elements)

        let escaped = try #require(linear("^FO0,0^BCN,50^FDA><B>6c>7D^FS"))
        #expect(escaped.barcode.elements == (try BarcodeEncoder.code128(
            symbolValues: [104, 33, 30, 34, 100, 67, 101, 36], humanReadable: "")).elements)
        #expect(escaped.barcode.humanReadable == "A>BcD")

        // Ungerade Ziffernzahl in Zeichensatz C: letzte Ziffer über CODE B
        let odd = try #require(linear("^FO0,0^BCN,50^FD>;123^FS"))
        #expect(odd.barcode.elements == (try BarcodeEncoder.code128(
            symbolValues: [105, 12, 100, 19], humanReadable: "")).elements)
    }

    @Test("^BC Modi A (automatisch), D (GS1-128) und U (UCC Case)")
    func code128Modes() throws {
        let auto = try #require(linear("^FO0,0^BCN,50,Y,N,N,A^FDABC12345678^FS"))
        #expect(auto.barcode == (try BarcodeEncoder.code128("ABC12345678", mode: .auto)))

        let gs1Data = "(01)09501101530003(17)140704(10)AB-123"
        let gs1 = try #require(linear("^FO0,0^BCN,50,Y,N,N,D^FD\(gs1Data)^FS"))
        #expect(gs1.barcode == (try BarcodeEncoder.code128(gs1Data, mode: .ucc)))

        let ucc = try #require(linear("^FO0,0^BCN,50,Y,N,N,U^FD1234^FS"))
        var digits = Array("1234000000000000000").map { Int(String($0))! }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() { sum += digit * (offset % 2 == 0 ? 3 : 1) }
        digits.append((10 - sum % 10) % 10)
        var values = [105, 102]
        for index in stride(from: 0, to: 20, by: 2) { values.append(digits[index] * 10 + digits[index + 1]) }
        #expect(ucc.barcode.elements == (try BarcodeEncoder.code128(symbolValues: values, humanReadable: "")).elements)
        #expect(ucc.barcode.humanReadable.hasPrefix("(12)34"))
    }

    @Test("^BC Parameter: ohne Klarschrift, Klarschrift oben, Standardhöhe aus ^BY")
    func code128Parameters() throws {
        let noText = try #require(linear("^FO0,0^BCN,50,N^FDX^FS"))
        #expect(!noText.printInterpretation)
        let above = try #require(linear("^FO0,0^BCN,50,Y,Y^FDX^FS"))
        #expect(above.interpretationAbove)
        let defaultHeight = try #require(linear("^BY3,2.5,77^FO0,0^BCR^FDX^FS"))
        #expect(defaultHeight.height == 77 && defaultHeight.moduleWidth == 3)
        #expect(defaultHeight.ratio == 2.5 && defaultHeight.orientation == .rotated90)
    }

    // MARK: Weitere lineare Codes

    @Test("Lineare Codes entsprechen LabelWerkBarcode")
    func linearSymbologies() throws {
        let cases: [(String, BarcodeSymbology, LinearBarcode)] = [
            ("^B3N,N,60^FDLABEL-39", .code39, try BarcodeEncoder.code39("LABEL-39")),
            ("^B3N,Y,60^FDLABEL39", .code39, try BarcodeEncoder.code39("LABEL39", checkDigit: true)),
            ("^B3N,N,60^FDabc", .code39, try BarcodeEncoder.code39("abc", fullASCII: true)),
            ("^BLN,60^FDLOG123", .code39, try BarcodeEncoder.code39("LOG123", checkDigit: true)),
            ("^BAN,60^FDCODE93", .code93, try BarcodeEncoder.code93("CODE93")),
            ("^BEN,60^FD400638133393", .ean13, try BarcodeEncoder.ean13("400638133393")),
            ("^BEN,60^FD4006381333931", .ean13, try BarcodeEncoder.ean13("400638133393")),
            ("^BEN,60^FD123", .ean13, try BarcodeEncoder.ean13("000000000123")),
            ("^B8N,60^FD5512345", .ean8, try BarcodeEncoder.ean8("5512345")),
            ("^BUN,60^FD03600029145", .upcA, try BarcodeEncoder.upcA("03600029145")),
            ("^B9N,60^FD1230000045", .upcE, try BarcodeEncoder.upcE("01230000045")),
            ("^B2N,60^FD1234567890", .interleaved2of5, try BarcodeEncoder.interleaved2of5("1234567890")),
            ("^B2N,60,Y,N,Y^FD123456", .interleaved2of5, try BarcodeEncoder.interleaved2of5("123456", checkDigit: true)),
            ("^BKN,N,60,Y,N,B,D^FD123456", .codabar, try BarcodeEncoder.codabar("123456", start: "B", stop: "D")),
        ]
        for (command, symbology, expected) in cases {
            let element = try #require(linear("^FO10,10^BY2" + command + "^FS"))
            #expect(element.symbology == symbology, "\(command)")
            #expect(element.barcode.elements == expected.elements, "\(command)")
            #expect(element.barcode.humanReadable == expected.humanReadable, "\(command)")
        }
    }

    @Test("UPC-A/UPC-E ohne gedruckte Prüfziffer")
    func upcWithoutCheckDigit() throws {
        let upcA = try #require(linear("^FO0,0^BUN,60,Y,N,N^FD03600029145^FS"))
        #expect(upcA.barcode.humanReadable == "03600029145")
        let upcE = try #require(linear("^FO0,0^B9N,60,Y,N,N^FD1230000045^FS"))
        #expect(upcE.barcode.humanReadable.count == 7)
    }

    // MARK: 2D-Codes

    @Test("^BQ: Präfix aus Fehlerkorrektur und Eingabemodus, Vergrößerung")
    func qrCode() throws {
        let element = try #require(matrix("^FO20,30^BQN,2,5^FDQA,Hallo Welt^FS"))
        #expect(element.matrix == (try BarcodeEncoder.qr("Hallo Welt", errorCorrection: .quartile)))
        #expect(element.moduleSize == 5)
        #expect(element.text == "Hallo Welt")
        #expect(element.symbology == .qr)
        #expect(element.origin == LabelPoint(x: 20, y: 30))

        let high = try #require(matrix("^FO0,0^BQN,2,3^FDHM,AHELLO 123^FS"))
        #expect(high.matrix == (try BarcodeEncoder.qr("HELLO 123", errorCorrection: .high)))
        let bytes = try #require(matrix("^FO0,0^BQN,2,3^FDLM,B0005hello world^FS"))
        #expect(bytes.text == "hello")
        let numeric = try #require(matrix("^FO0,0^BQN,2,3^FDMM,N0123456789^FS"))
        #expect(numeric.matrix == (try BarcodeEncoder.qr("0123456789", errorCorrection: .medium)))
        // Kommas in den Nutzdaten bleiben erhalten
        let commas = try #require(matrix("^FO0,0^BQN,2,3^FDLA,a,b,c^FS"))
        #expect(commas.text == "a,b,c")
    }

    @Test("^BQ: Standardvergrößerung je Auflösung, feste Maske, fehlendes Präfix")
    func qrDefaults() throws {
        #expect(matrix("^FO0,0^BQN^FDQA,X^FS")?.moduleSize == 2)
        let label300 = ZPLInterpreter(dotsPerMM: 12).render("^XA^FO0,0^BQN^FDQA,X^FS^XZ").labels.first
        #expect(label300.flatMap { TestSupport.matrixBarcodes($0).first?.moduleSize } == 3)
        let masked = try #require(matrix("^FO0,0^BQN,2,4,M,3^FDMA,Mask^FS"))
        #expect(masked.matrix == (try BarcodeEncoder.qr("Mask", errorCorrection: .medium, minimumVersion: 1, mask: 3)))
        let document = TestSupport.render("^XA^FO0,0^BQN,2,4^FDhttps://example.com^FS^XZ")
        let plain = document.labels.first.flatMap { TestSupport.matrixBarcodes($0).first }
        #expect(plain?.text == "https://example.com")
        #expect(document.allWarnings.contains { $0.command == "^BQ" })
    }

    @Test("^BX: Data Matrix ECC 200, Modulgröße, feste Symbolgröße, Escapes")
    func dataMatrix() throws {
        let element = try #require(matrix("^FO0,0^BXN,5,200^FDLabelWerk^FS"))
        #expect(element.matrix == (try BarcodeEncoder.dataMatrix("LabelWerk")))
        #expect(element.moduleSize == 5 && element.symbology == .dataMatrix)
        let fixed = try #require(matrix("^FO0,0^BXN,4,200,24,24^FDABC^FS"))
        #expect(fixed.matrix.width == 24 && fixed.matrix.height == 24)
        let rectangular = try #require(matrix("^FO0,0^BXN,4,200,,,,,2^FDABC^FS"))
        #expect(rectangular.matrix.width != rectangular.matrix.height)
        // Eigenes Escapezeichen # (das Standardzeichen ~ ist im Datenstrom das Steuerpräfix)
        let escaped = try #require(matrix("^FO0,0^BXN,4,200,,,,#^FD#d065#M##^FS"))
        #expect(escaped.matrix == (try BarcodeEncoder.dataMatrix(bytes: [65, 13, 35])))
        // Standard-Escapezeichen ~ über ^FH
        let defaultEscape = try #require(matrix("^FO0,0^BXN,4,200^FH^FD_7Ed066x^FS"))
        #expect(defaultEscape.matrix == (try BarcodeEncoder.dataMatrix(bytes: [66, 120])))
        // Ohne Modulgröße ergibt die ^BY-Höhe die ungefähre Symbolhöhe
        let auto = try #require(matrix("^BY2,3,100^FO0,0^BXN,,200^FDABC^FS"))
        #expect(auto.moduleSize == 100 / auto.matrix.height)
        let rotated = try #require(matrix("^FO0,0^BXR,5,200^FDABC^FS"))
        #expect(rotated.orientation == .rotated90)
        let lowQuality = TestSupport.render("^XA^FO0,0^BXN,5,140^FDABC^FS^XZ")
        #expect(lowQuality.allWarnings.contains { $0.command == "^BX" })
    }

    @Test("^B7: PDF417 mit Zeilenhöhe, Sicherheitsstufe und Spalten")
    func pdf417() throws {
        let element = try #require(matrix("^BY2^FO0,0^B7N,6,3,4^FDLabelWerk PDF417^FS"))
        let options = PDF417Options(columns: 4, securityLevel: 3, rowHeight: 3)
        #expect(element.matrix == (try BarcodeEncoder.pdf417("LabelWerk PDF417", options: options)))
        #expect(element.moduleSize == 2 && element.symbology == .pdf417)
        let compact = try #require(matrix("^BY3^FO0,0^B7N,9,2,3,,Y^FDABC^FS"))
        let compactOptions = PDF417Options(columns: 3, securityLevel: 2, rowHeight: 3, compact: true)
        #expect(compact.matrix == (try BarcodeEncoder.pdf417("ABC", options: compactOptions)))
    }

    // MARK: Geometrie

    @Test("^FT bei Barcodes: linke untere Ecke der Balken; gedrehte Felder")
    func barcodeGeometry() throws {
        let typeset = try #require(linear("^BY2^FT100,300^BCN,100,Y,N^FD12^FS"))
        #expect(typeset.origin == LabelPoint(x: 100, y: 200))
        let layout = LinearBarcodeLayout(typeset)
        #expect(layout.barsY == 0 && layout.height == 100 + 2 + 18)

        let qr = try #require(matrix("^FT50,400^BQN,2,4^FDQA,X^FS"))
        #expect(qr.origin == LabelPoint(x: 50, y: 400 - qr.matrix.height * 4))

        let rotated = try #require(linear("^BY2^FO100,100^BCR,80,N^FD1234^FS"))
        let box = LabelElement.linearBarcode(rotated).boundingBox
        #expect(box.x == 100 && box.y == 100 && box.width == 80)
        #expect(box.height == rotated.barcode.totalWidth(moduleWidth: 2, ratio: 3))
    }

    @Test("EAN-13-Klarschrift: Randziffer links, verlängerte Begrenzungsbalken")
    func eanLayout() throws {
        let element = try #require(linear("^BY2^FO50,50^BEN,80,Y,N^FD400638133393^FS"))
        let layout = LinearBarcodeLayout(element)
        #expect(layout.barsX == 14)
        #expect(layout.width == 14 + 95 * 2)
        #expect(layout.guardExtension > 0)
        #expect(layout.texts.map(\.text) == ["4", "006381", "333931"])
        #expect(layout.texts[1].x > layout.barsX && layout.texts[2].x > layout.texts[1].x)
    }

    @Test("Ungültige Daten und nicht unterstützte Symbologien: Hinweis, kein Element, kein Text")
    func invalidBarcodes() {
        let invalid = TestSupport.render("^XA^FO0,0^BEN,60^FDABC^FS^XZ")
        #expect(invalid.labels.first?.elements.isEmpty == true)
        #expect(invalid.allWarnings.contains { $0.command == "^BE" })
        let unsupported = TestSupport.render("^XA^FO0,0^BZN,40^FD12345^FS^FO0,100^BDN^FDtest^FS^XZ")
        #expect(unsupported.labels.first?.elements.isEmpty == true)
        #expect(unsupported.allWarnings.contains { $0.command == "^BZ" })
        #expect(unsupported.allWarnings.contains { $0.command == "^BD" })
    }

    @Test("^BY bleibt über Felder und Formate erhalten; ^FR kehrt Barcodes um")
    func barcodeDefaultsPersist() {
        let document = TestSupport.render("""
        ^XA^BY4,2.0,120^FO0,0^BCN^FDA^FS^FO0,200^FR^B3N^FDB^FS^XZ
        ^XA^FO0,0^B2N^FD12^FS^XZ
        """)
        let first = document.labels.first.map(TestSupport.linearBarcodes) ?? []
        let second = document.labels.last.map(TestSupport.linearBarcodes) ?? []
        #expect(first.map(\.moduleWidth) == [4, 4])
        #expect(first.map(\.height) == [120, 120])
        #expect(first.map(\.reverse) == [false, true])
        #expect(second.first?.moduleWidth == 4 && second.first?.ratio == 2.0)
    }
}

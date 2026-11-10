import Foundation
import Testing
@testable import LabelWerkCore

private let formatAndFieldCases: [CommandCase] = [
    CommandCase(ZPL.startFormat(), "^XA"),
    CommandCase(ZPL.endFormat(), "^XZ"),
    CommandCase(ZPL.changeEncoding(), "^CI28"),
    CommandCase(ZPL.changeEncoding(utf8: true), "^CI28"),
    CommandCase(ZPL.changeEncoding(utf8: false), "^CI0"),
    CommandCase(ZPL.changeInternationalFont(27), "^CI27"),
    CommandCase(ZPL.changeInternationalFont(99), "^CI36"),
    CommandCase(ZPL.comment("Versandetikett"), "^FXVersandetikett"),
    CommandCase(ZPL.comment("Hallo ^Welt~\nZeile 2"), "^FXHallo Welt Zeile 2"),
    CommandCase(ZPL.fieldOrigin(x: 50, y: 60), "^FO50,60"),
    CommandCase(ZPL.fieldOrigin(x: -5, y: -1), "^FO0,0"),
    CommandCase(ZPL.fieldTypeset(x: 10, y: 20), "^FT10,20"),
    CommandCase(ZPL.font(height: 30), "^A0N,30"),
    CommandCase(ZPL.font(height: 30, width: 20), "^A0N,30,20"),
    CommandCase(ZPL.font("D", orientation: .rotated90, height: 36, width: 20), "^ADR,36,20"),
    CommandCase(ZPL.font("0", orientation: .inverted180, height: 40), "^A0I,40"),
    CommandCase(ZPL.font("E:ARIAL.TTF", height: 40), "^A@N,40,,E:ARIAL.TTF"),
    CommandCase(ZPL.font("E:ARIAL.TTF", orientation: .rotated270, height: 40, width: 30), "^A@B,40,30,E:ARIAL.TTF"),
    CommandCase(ZPL.defaultFont(height: 30), "^CF0,30"),
    CommandCase(ZPL.defaultFont("a", height: 20, width: 10), "^CFA,20,10"),
    CommandCase(ZPL.fieldOrientationDefault(.inverted180), "^FWI"),
    CommandCase(ZPL.fieldBlock(width: 400), "^FB400,1,0,L,0"),
    CommandCase(ZPL.fieldBlock(width: 300, maxLines: 3, lineSpacing: 5, justification: "c", hangingIndent: 10), "^FB300,3,5,C,10"),
    CommandCase(ZPL.fieldBlock(width: 300, justification: "J"), "^FB300,1,0,J,0"),
    CommandCase(ZPL.fieldBlock(width: 300, justification: "X"), "^FB300,1,0,L,0"),
    CommandCase(ZPL.fieldSeparator(), "^FS"),
    CommandCase(ZPL.fieldReverse(), "^FR"),
    CommandCase(ZPL.fieldHexIndicator(), "^FH"),
    CommandCase(ZPL.fieldNumber(3), "^FN3"),
    CommandCase(ZPL.fieldData("Hallo Welt"), "^FH^FDHallo Welt"),
    CommandCase(ZPL.fieldData("A^B~C_D\\E\n"), "^FH^FDA_5EB_7EC_5FD_5CE_0A"),
    CommandCase(ZPL.fieldData("Tab\tCR\rDEL\u{7F}NUL\u{0}"), "^FH^FDTab_09CR_0DDEL_7FNUL_00"),
    CommandCase(ZPL.fieldData("Grüße aus Köln – 10 € · 😀"), "^FH^FDGrüße aus Köln – 10 € · 😀"),
    CommandCase(ZPL.fieldData("a,b;c\"d'e"), "^FH^FDa,b;c\"d'e"),
    CommandCase(ZPL.blockFieldData("Zeile 1\nZeile_2\r\nZeile 3"), "^FH^FDZeile 1\\&Zeile_5F2\\&Zeile 3"),
    CommandCase(ZPL.text("Hallo", x: 10, y: 20, height: 30), "^FO10,20^A0N,30^FH^FDHallo^FS"),
    CommandCase(ZPL.text("x^y", x: 1, y: 2, height: 3, width: 4, font: "B", orientation: .rotated90), "^FO1,2^ABR,3,4^FH^FDx_5Ey^FS"),
    CommandCase(ZPL.blockText("Hi", x: 10, y: 20, width: 200, height: 30, justification: "C", reversed: true),
                "^FO10,20^A0N,30,30^FB200,1,0,C,0^FR^FH^FDHi^FS"),
    CommandCase(ZPL.blockText("A\nB", x: 0, y: 0, width: 100, height: 20, maxLines: 2),
                "^FO0,0^A0N,20,20^FB100,2,0,L,0^FH^FDA\\&B^FS"),
]

private let graphicCases: [CommandCase] = [
    CommandCase(ZPL.graphicBox(width: 100, height: 50), "^GB100,50,1,B,0"),
    CommandCase(ZPL.graphicBox(width: 200, height: 100, thickness: 4, color: "w", rounding: 3), "^GB200,100,4,W,3"),
    CommandCase(ZPL.graphicBox(width: 200, height: 100, thickness: 4, rounding: 12), "^GB200,100,4,B,8"),
    CommandCase(ZPL.graphicBox(width: 2, height: 50, thickness: 5), "^GB5,50,5,B,0"),
    CommandCase(ZPL.graphicBox(width: 300, height: 0, thickness: 3), "^GB300,3,3,B,0"),
    CommandCase(ZPL.graphicCircle(diameter: 50, thickness: 3), "^GC50,3,B"),
    CommandCase(ZPL.graphicCircle(diameter: 1), "^GC3,1,B"),
    CommandCase(ZPL.graphicEllipse(width: 100, height: 50, thickness: 2), "^GE100,50,2,B"),
    CommandCase(ZPL.graphicEllipse(width: 100, height: 50, color: "W"), "^GE100,50,1,W"),
    CommandCase(ZPL.graphicDiagonal(width: 100, height: 50, thickness: 3, orientation: "L"), "^GD100,50,3,B,L"),
    CommandCase(ZPL.graphicDiagonal(width: 100, height: 50), "^GD100,50,1,B,R"),
    CommandCase(ZPL.recallGraphic("R:LOGO.GRF", magnificationX: 2, magnificationY: 2), "^XGR:LOGO.GRF,2,2"),
    CommandCase(ZPL.recallGraphic("E:LOGO.GRF"), "^XGE:LOGO.GRF,1,1"),
    CommandCase(ZPL.imageMove("R:LOGO.GRF"), "^IMR:LOGO.GRF"),
]

private let barcodeCases: [CommandCase] = [
    CommandCase(ZPL.barcodeDefaults(moduleWidth: 2), "^BY2,3.0,10"),
    CommandCase(ZPL.barcodeDefaults(moduleWidth: 3, ratio: 2.5, height: 80), "^BY3,2.5,80"),
    CommandCase(ZPL.barcodeDefaults(moduleWidth: 20, ratio: 5, height: 80), "^BY10,3.0,80"),
    CommandCase(ZPL.barcodeDefaults(moduleWidth: 0, ratio: 1, height: 0), "^BY1,2.0,1"),
    CommandCase(ZPL.barcodeDefaults(moduleWidth: 2, ratio: .nan), "^BY2,3.0,10"),
    CommandCase(ZPL.code128(height: 100), "^BCN,100,Y,N,N"),
    CommandCase(ZPL.code128(orientation: .rotated90, height: 50, printInterpretation: false, above: true), "^BCR,50,N,Y,N"),
    CommandCase(ZPL.code128(height: 80, mode: .automatic), "^BCN,80,Y,N,N,A"),
    CommandCase(ZPL.code128(height: 80, checkDigit: true, mode: .uccEAN), "^BCN,80,Y,N,Y,D"),
    CommandCase(ZPL.code128(height: 80, mode: .none), "^BCN,80,Y,N,N,N"),
    CommandCase(ZPL.code128(height: 80, mode: .ucc), "^BCN,80,Y,N,N,U"),
    CommandCase(ZPL.code39(height: 100), "^B3N,N,100,Y,N"),
    CommandCase(ZPL.code39(checkDigit: true, height: 60, printInterpretation: false), "^B3N,Y,60,N,N"),
    CommandCase(ZPL.code93(height: 70), "^BAN,70,Y,N,N"),
    CommandCase(ZPL.code93(orientation: .inverted180, height: 70, printCheckDigit: true), "^BAI,70,Y,N,Y"),
    CommandCase(ZPL.ean13(height: 90), "^BEN,90,Y,N"),
    CommandCase(ZPL.ean13(orientation: .rotated270, height: 90, above: true), "^BEB,90,Y,Y"),
    CommandCase(ZPL.ean8(height: 90), "^B8N,90,Y,N"),
    CommandCase(ZPL.upcA(height: 90), "^BUN,90,Y,N,Y"),
    CommandCase(ZPL.upcA(height: 90, printCheckDigit: false), "^BUN,90,Y,N,N"),
    CommandCase(ZPL.upcE(height: 90), "^B9N,90,Y,N,Y"),
    CommandCase(ZPL.interleaved2of5(height: 90), "^B2N,90,Y,N,N"),
    CommandCase(ZPL.interleaved2of5(height: 90, checkDigit: true), "^B2N,90,Y,N,Y"),
    CommandCase(ZPL.codabar(height: 60), "^BKN,N,60,Y,N,A,A"),
    CommandCase(ZPL.codabar(height: 60, start: "b", stop: "D"), "^BKN,N,60,Y,N,B,D"),
    CommandCase(ZPL.codabar(height: 60, start: "X", stop: "Z"), "^BKN,N,60,Y,N,A,A"),
    CommandCase(ZPL.qrCode(magnification: 5), "^BQN,2,5,M"),
    CommandCase(ZPL.qrCode(magnification: 20, errorCorrection: "h"), "^BQN,2,10,H"),
    CommandCase(ZPL.qrCode(magnification: 0, errorCorrection: "X"), "^BQN,2,1,M"),
    CommandCase(ZPL.qrFieldData("https://x.de/a_b"), "^FH^FDMA,https://x.de/a_5Fb"),
    CommandCase(ZPL.qrFieldData("Q", errorCorrection: "L"), "^FH^FDLA,Q"),
    CommandCase(ZPL.dataMatrix(moduleSize: 6), "^BXN,6,200"),
    CommandCase(ZPL.dataMatrix(moduleSize: 4, orientation: .rotated90), "^BXR,4,200"),
    CommandCase(ZPL.pdf417(rowHeight: 8), "^B7N,8,0,,,N"),
    CommandCase(ZPL.pdf417(orientation: .rotated90, rowHeight: 10, securityLevel: 5, columns: 4, rows: 20, truncated: true), "^B7R,10,5,4,20,Y"),
    CommandCase(ZPL.pdf417(rowHeight: 8, securityLevel: 12, columns: 50, rows: 1), "^B7N,8,8,30,3,N"),
]

private let setupCases: [CommandCase] = [
    CommandCase(ZPL.printWidth(812), "^PW812"),
    CommandCase(ZPL.labelLength(1218), "^LL1218"),
    CommandCase(ZPL.labelHome(x: 0, y: 0), "^LH0,0"),
    CommandCase(ZPL.labelHome(x: 20, y: 30), "^LH20,30"),
    CommandCase(ZPL.labelTop(30), "^LT30"),
    CommandCase(ZPL.labelTop(-200), "^LT-120"),
    CommandCase(ZPL.labelShift(-20), "^LS-20"),
    CommandCase(ZPL.labelShift(20_000), "^LS9999"),
    CommandCase(ZPL.labelReverse(true), "^LRY"),
    CommandCase(ZPL.labelReverse(false), "^LRN"),
    CommandCase(ZPL.printQuantity(5), "^PQ5"),
    CommandCase(ZPL.printQuantity(0), "^PQ1"),
    CommandCase(ZPL.printQuantity(10, pauseCount: 2, replicates: 0, overridePause: true), "^PQ10,2,0,Y"),
    CommandCase(ZPL.printQuantity(3, replicates: 2), "^PQ3,0,2,N"),
    CommandCase(ZPL.printRate(4), "^PR4,4,4"),
    CommandCase(ZPL.printRate(20), "^PR14,14,14"),
    CommandCase(ZPL.printRate(print: 6, slew: 8, backfeed: 2), "^PR6,8,2"),
    CommandCase(ZPL.setDarkness(8), "~SD08"),
    CommandCase(ZPL.setDarkness(0), "~SD00"),
    CommandCase(ZPL.setDarkness(25), "~SD25"),
    CommandCase(ZPL.setDarkness(40), "~SD30"),
    CommandCase(ZPL.setDarkness(-1), "~SD00"),
    CommandCase(ZPL.mediaDarkness(relative: -5), "^MD-5"),
    CommandCase(ZPL.mediaDarkness(relative: 50), "^MD30"),
    CommandCase(ZPL.mediaType(.directThermal), "^MTD"),
    CommandCase(ZPL.mediaType(.thermalTransfer), "^MTT"),
    CommandCase(ZPL.mediaTracking(.gap), "^MNY"),
    CommandCase(ZPL.mediaTracking(.blackMark), "^MNM"),
    CommandCase(ZPL.mediaTracking(.continuous), "^MNN"),
    CommandCase(ZPL.mediaTracking(.autoDetect), "^MNA"),
    CommandCase(ZPL.printMode(.tearOff), "^MMT"),
    CommandCase(ZPL.printMode(.peelOff), "^MMP"),
    CommandCase(ZPL.printMode(.cutter), "^MMC"),
    CommandCase(ZPL.printMode(.delayedCut), "^MMD"),
    CommandCase(ZPL.printMode(.rewind), "^MMR"),
    CommandCase(ZPL.printMode(.applicator), "^MMA"),
    CommandCase(ZPL.printMode(.kiosk), "^MMK"),
    CommandCase(ZPL.backfeed(.afterPrinting), "~JSA"),
    CommandCase(ZPL.backfeed(.beforePrinting), "~JSB"),
    CommandCase(ZPL.backfeed(.normal), "~JSN"),
    CommandCase(ZPL.backfeed(.off), "~JSO"),
    CommandCase(ZPL.printOrientation(inverted: true), "^POI"),
    CommandCase(ZPL.printOrientation(inverted: false), "^PON"),
    CommandCase(ZPL.mirror(true), "^PMY"),
    CommandCase(ZPL.mirror(false), "^PMN"),
    CommandCase(ZPL.tearOffAdjust(10), "~TA010"),
    CommandCase(ZPL.tearOffAdjust(5), "~TA005"),
    CommandCase(ZPL.tearOffAdjust(0), "~TA000"),
    CommandCase(ZPL.tearOffAdjust(-10), "~TA-10"),
    CommandCase(ZPL.tearOffAdjust(-5), "~TA-05"),
    CommandCase(ZPL.tearOffAdjust(120), "~TA120"),
    CommandCase(ZPL.tearOffAdjust(-200), "~TA-120"),
    CommandCase(ZPL.mediaFeed(powerUp: .calibrate, headClose: .feed), "^MFC,F"),
    CommandCase(ZPL.mediaFeed(powerUp: .noMotion, headClose: .shortCalibration), "^MFN,S"),
    CommandCase(ZPL.mediaFeed(powerUp: .length, headClose: .length), "^MFL,L"),
    CommandCase(ZPL.saveSettings(), "^JUS"),
    CommandCase(ZPL.restoreFactoryDefaults(), "^JUF"),
    CommandCase(ZPL.restoreNetworkDefaults(), "^JUN"),
    CommandCase(ZPL.recallSavedSettings(), "^JUR"),
]

private let deviceCases: [CommandCase] = [
    CommandCase(ZPL.calibrate(), "~JC"),
    CommandCase(ZPL.measureLabelLength(), "~JL"),
    CommandCase(ZPL.sensorProfile(), "~JG"),
    CommandCase(ZPL.hostStatus(), "~HS"),
    CommandCase(ZPL.hostIdentification(), "~HI"),
    CommandCase(ZPL.hostQueryErrors(), "~HQES"),
    CommandCase(ZPL.hostMemoryStatus(), "~HM"),
    CommandCase(ZPL.hostConfiguration(), "^HH"),
    CommandCase(ZPL.hostConfigurationFormat(), "^XA^HH^XZ"),
    CommandCase(ZPL.printConfiguration(), "~WC"),
    CommandCase(ZPL.printNetworkConfiguration(), "~WL"),
    CommandCase(ZPL.feed(), "~PH"),
    CommandCase(ZPL.pause(), "~PP"),
    CommandCase(ZPL.resume(), "~PS"),
    CommandCase(ZPL.cancelAll(), "~JA"),
    CommandCase(ZPL.cancelCurrent(), "~JX"),
    CommandCase(ZPL.reset(), "~JR"),
    CommandCase(ZPL.deleteObject("E:LOGO.GRF"), "^IDE:LOGO.GRF"),
    CommandCase(ZPL.deleteObject("E:*.TTF"), "^IDE:*.TTF"),
    CommandCase(ZPL.hostDirectory(), "^XA^HWE:*.*^XZ"),
    CommandCase(ZPL.hostDirectory("R:*.GRF"), "^XA^HWR:*.GRF^XZ"),
    CommandCase(ZPL.printDirectory(), "^XA^WDE:*.*^XZ"),
    CommandCase(ZPL.printDirectory("B:*.*"), "^XA^WDB:*.*^XZ"),
    CommandCase(ZPL.downloadFormat("E:FORM.ZPL"), "^DFE:FORM.ZPL"),
    CommandCase(ZPL.recallFormat("E:FORM.ZPL"), "^XFE:FORM.ZPL"),
]

@Suite("ZPL-Bausteine")
struct ZPLBuilderTests {
    @Test("Format- und Feldbefehle", arguments: formatAndFieldCases)
    func formatAndFields(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("Grafikbefehle", arguments: graphicCases)
    func graphics(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("Barcodes", arguments: barcodeCases)
    func barcodes(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("Etikett- und Drucker-Setup", arguments: setupCases)
    func setup(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("Geräte- und Dateibefehle", arguments: deviceCases)
    func device(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("^FD enthält genau einen (maskierten) Parameter")
    func fieldDataStructure() throws {
        let commands = ZPL.fieldData("a,b^c")
        #expect(commands.count == 2)
        #expect(commands[0] == ZPLCommand(.caret, "FH"))
        let fd = try #require(commands.last)
        #expect(fd.code == "FD")
        #expect(fd.parameters == ["a,b_5Ec"])
    }

    @Test("Maskierung lässt keine Steuerzeichen und Präfixe durch")
    func escapingIsComplete() {
        var all = ""
        for value in 0..<0x80 { all.unicodeScalars.append(Unicode.Scalar(UInt8(value))) }
        let escaped = ZPL.escapeFieldData(all)
        #expect(!escaped.contains("^"))
        #expect(!escaped.contains("~"))
        #expect(!escaped.contains("\\"))
        #expect(escaped.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        // Jeder Unterstrich leitet eine zweistellige Hex-Sequenz ein.
        let scalars = Array(escaped.unicodeScalars)
        for (i, s) in scalars.enumerated() where s == "_" {
            #expect(i + 2 < scalars.count)
            let hex = String(String.UnicodeScalarView(scalars[(i + 1)...(i + 2)]))
            #expect(UInt8(hex, radix: 16) != nil)
        }
    }

    @Test("Maskierung ist umkehrbar (wie ^FH im Drucker)")
    func escapingRoundTrip() {
        let original = "Preis_^~\\\n\t: 12,50 € – Größe XL"
        let escaped = ZPL.escapeFieldData(original)
        // ^FH-Dekodierung nachbilden: _XX → Byte.
        var bytes: [UInt8] = []
        let utf8 = Array(escaped.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "_"), i + 2 < utf8.count,
               let byte = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                i += 3
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        #expect(String(decoding: bytes, as: UTF8.self) == original)
    }

    @Test("TrueType-Download: Kopf und Binärdaten")
    func trueTypeDownload() {
        let font = Data([0x00, 0x01, 0x02, 0xFF, 0x5E])
        let data = ZPL.downloadTrueTypeFont(name: "Arial.ttf", drive: "e", data: font)
        var expected = Data("~DYE:ARIAL,B,T,5,,".utf8)
        expected.append(font)
        #expect(data == expected)

        let defaultDrive = ZPL.downloadTrueTypeFont(name: "E:Corp Sans!.TTF", data: Data([1]))
        #expect(String(decoding: defaultDrive.dropLast(), as: UTF8.self) == "~DYE:CORP_SANS_,B,T,1,,")
    }

    @Test("Objektnamen und Laufwerke werden normalisiert")
    func objectNames() {
        #expect(ZPL.objectName("logo.png") == "LOGO")
        #expect(ZPL.objectName("R:Mein Logo.GRF") == "MEIN_LOGO")
        #expect(ZPL.objectName("ABCDEFGHIJKLMNOPQRSTUVWXYZ") == "ABCDEFGHIJKLMNOP")
        #expect(ZPL.objectName("") == "FONT")
        #expect(ZPL.objectName(".hidden") == "_HIDDEN")
        #expect(ZPL.normalizedDrive("e") == "E:")
        #expect(ZPL.normalizedDrive("R:") == "R:")
        #expect(ZPL.normalizedDrive(" b: ") == "B:")
        #expect(ZPL.normalizedDrive("") == "E:")
    }
}

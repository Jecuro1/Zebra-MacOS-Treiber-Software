import Foundation
import Testing
@testable import LabelWerkCore

private let eplCases: [CommandCase] = [
    CommandCase(EPL.clearImageBuffer(), "N"),
    CommandCase(EPL.labelWidth(812), "q812"),
    CommandCase(EPL.formLength(1218, gap: 24), "Q1218,24"),
    CommandCase(EPL.formLength(1218, gap: 5), "Q1218,16"),
    CommandCase(EPL.formLength(1218, sensing: .gap(30)), "Q1218,30"),
    CommandCase(EPL.formLength(1218, sensing: .blackMark(height: 24, offset: 0)), "Q1218,B24"),
    CommandCase(EPL.formLength(1218, sensing: .blackMark(height: 24, offset: 16)), "Q1218,B24,16"),
    CommandCase(EPL.formLength(1218, sensing: .blackMark(height: 24, offset: -8)), "Q1218,B24,-8"),
    CommandCase(EPL.formLength(600, sensing: .continuous), "Q600,0"),
    CommandCase(EPL.speed(4), "S4"),
    CommandCase(EPL.speed(9), "S6"),
    CommandCase(EPL.speed(0), "S1"),
    CommandCase(EPL.density(10), "D10"),
    CommandCase(EPL.density(20), "D15"),
    CommandCase(EPL.density(-2), "D0"),
    CommandCase(EPL.printDirection(topFirst: true), "ZT"),
    CommandCase(EPL.printDirection(topFirst: false), "ZB"),
    CommandCase(EPL.options([]), "O"),
    CommandCase(EPL.options([.directThermal]), "OD"),
    CommandCase(EPL.options([.directThermal, .peel]), "OD,P"),
    CommandCase(EPL.options([.cutter, .directThermal]), "OC,D"),
    CommandCase(EPL.options([.cutterEvery(5), .directThermal]), "OC5,D"),
    CommandCase(EPL.options([.cutterEvery(999)]), "OC255"),
    CommandCase(EPL.options([.cutterBatch]), "OCb"),
    CommandCase(EPL.options([.tapToPrint, .reverseGapSensor]), "OL,S"),
    CommandCase(EPL.referencePoint(x: 10, y: 20), "R10,20"),
    CommandCase(EPL.characterSet(), "I8,A,049"),
    CommandCase(EPL.characterSet(bits: 7, codePage: "0", country: "001"), "I7,0,001"),
    CommandCase(EPL.topOfFormBackup(true), "JF"),
    CommandCase(EPL.topOfFormBackup(false), "JB"),
    CommandCase(EPL.text("Hallo", x: 10, y: 20), "A10,20,0,3,1,1,N,\"Hallo\""),
    CommandCase(EPL.text("Say \"hi\" C:\\", x: 0, y: 0, font: "4", rotation: .rotated90,
                         horizontalMultiplier: 7, verticalMultiplier: 12, reverse: true),
                "A0,0,1,4,6,9,R,\"Say \\\"hi\\\" C:\\\\\""),
    CommandCase(EPL.text("Zeile\r\nzwei", x: 5, y: 5, font: "1", rotation: .rotated270, horizontalMultiplier: 8),
                "A5,5,3,1,8,1,N,\"Zeile  zwei\""),
    CommandCase(EPL.text("x", x: -3, y: 2, rotation: .rotated180), "A0,2,2,3,1,1,N,\"x\""),
    CommandCase(EPL.barcode("12345", x: 10, y: 20, type: .code128, height: 80), "B10,20,0,1,2,4,80,B,\"12345\""),
    CommandCase(EPL.barcode("4006381333931", x: 0, y: 0, type: .ean13, narrowBar: 3, wideBar: 6, height: 100,
                            rotation: .rotated180, humanReadable: false),
                "B0,0,2,E30,3,6,100,N,\"4006381333931\""),
    CommandCase(EPL.barcode("CODE39", x: 1, y: 2, type: .code39CheckDigit, height: 50), "B1,2,0,3C,2,4,50,B,\"CODE39\""),
    CommandCase(EPL.barcode("12345670", x: 1, y: 2, type: .ean8, height: 50), "B1,2,0,E80,2,4,50,B,\"12345670\""),
    CommandCase(EPL.barcode("03600029145", x: 1, y: 2, type: .upcA, height: 50), "B1,2,0,UA0,2,4,50,B,\"03600029145\""),
    CommandCase(EPL.barcode("A12345B", x: 1, y: 2, type: .codabar, height: 50), "B1,2,0,K,2,4,50,B,\"A12345B\""),
    CommandCase(EPL.barcode("1234", x: 1, y: 2, type: .interleaved2of5, height: 50), "B1,2,0,2,2,4,50,B,\"1234\""),
    CommandCase(EPL.lineBlack(x: 10, y: 20, width: 300, height: 4), "LO10,20,300,4"),
    CommandCase(EPL.lineXOR(x: 10, y: 20, width: 300, height: 40), "LE10,20,300,40"),
    CommandCase(EPL.lineWhite(x: 10, y: 20, width: 300, height: 4), "LW10,20,300,4"),
    CommandCase(EPL.lineBlack(x: 0, y: 0, width: 0, height: 0), "LO0,0,1,1"),
    CommandCase(EPL.diagonalLine(x1: 10, y1: 20, thickness: 3, x2: 200, y2: 100), "LS10,20,3,200,100"),
    CommandCase(EPL.box(x1: 10, y1: 10, thickness: 3, x2: 200, y2: 100), "X10,10,3,200,100"),
    CommandCase(EPL.print(), "P1"),
    CommandCase(EPL.print(3), "P3"),
    CommandCase(EPL.print(2, copies: 5), "P2,5"),
    CommandCase(EPL.print(0), "P1"),
    CommandCase(EPL.printConfiguration(), "U"),
    CommandCase(EPL.queryConfiguration(), "UQ"),
    CommandCase(EPL.autoSense(), "xa"),
    CommandCase(EPL.reset(), "^@"),
    CommandCase(EPL.factoryDefaults(), "^default"),
    CommandCase(EPL.printStoredGraphic("LOGO", x: 5, y: 6), "GG5,6,\"LOGO\""),
    CommandCase(EPL.deleteGraphic("*"), "GK\"*\""),
    CommandCase(EPL.listGraphics(), "GI"),
]

@Suite("EPL2-Bausteine")
struct EPLTests {
    @Test("Exakte Befehlszeilen", arguments: eplCases)
    func commands(_ c: CommandCase) { #expect(c.actual == c.expected) }

    @Test("Zeilenende LF")
    func render() {
        #expect(EPL.lineEnding == "\n")
        #expect(EPL.render(["N", "P1"]) == "N\nP1\n")
        #expect(EPL.render([]) == "")
    }

    @Test("Programm mit Result Builder (if, for, Optionale)")
    func program() {
        let withBarcode = false
        let optional: String? = nil
        let program = EPL.program {
            EPL.labelWidth(400)
            for i in 0..<2 {
                EPL.text("L\(i)", x: 0, y: i * 20)
            }
            if withBarcode {
                EPL.barcode("1", x: 0, y: 0, type: .code128, height: 10)
            } else {
                EPL.lineBlack(x: 0, y: 50, width: 100, height: 2)
            }
            optional
            [EPL.density(8), EPL.speed(3)]
        }
        #expect(program == "q400\nA0,0,0,3,1,1,N,\"L0\"\nA0,20,0,3,1,1,N,\"L1\"\nLO0,50,100,2\nD8\nS3\n")
    }

    @Test("Etikett: führendes LF, N, Inhalt, P")
    func label() {
        #expect(EPL.label { EPL.labelWidth(400) } == "\nN\nq400\nP1\n")
        #expect(EPL.label(quantity: 2, copies: 3) {} == "\nN\nP2,3\n")
    }

    @Test("Windows-1252-Kodierung")
    func encoding() {
        #expect(Array(EPL.encode("Grüße €")) == [0x47, 0x72, 0xFC, 0xDF, 0x65, 0x20, 0x80])
        #expect(Array(EPL.encode("„Test“ – ok…")) == [0x84, 0x54, 0x65, 0x73, 0x74, 0x93, 0x20, 0x96, 0x20, 0x6F, 0x6B, 0x85])
        #expect(Array(EPL.encode("日本")) == [0x3F, 0x3F])
        #expect(EPL.encode("N\nP1\n") == Data("N\nP1\n".utf8))
    }

    @Test("ASCII-Umschrift")
    func transliteration() {
        #expect(EPL.transliterated("Größe × Maß – „ok“") == "Groesse x Mass - \"ok\"")
        #expect(EPL.transliterated("ÄÖÜ äöü ß · …") == "AeOeUe aeoeue ss - ...")
        #expect(EPL.transliterated("Café Ñandú") == "Cafe Nandu")
        #expect(EPL.transliterated("日本") == "??")
        #expect(EPL.transliterated("plain ASCII 123") == "plain ASCII 123")
    }

    @Test("Alle Barcode-Typen haben eindeutige Codes")
    func barcodeTypes() {
        let codes = EPL.BarcodeType.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
        #expect(EPL.BarcodeType.code128.rawValue == "1")
        #expect(EPL.BarcodeType.ean13.rawValue == "E30")
    }
}

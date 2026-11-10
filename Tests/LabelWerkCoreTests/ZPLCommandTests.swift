import Foundation
import Testing
@testable import LabelWerkCore

/// Ein erwartetes Befehlsergebnis (für parametrisierte Tests).
struct CommandCase: Sendable, CustomTestStringConvertible {
    let actual: String
    let expected: String
    var testDescription: String { expected.debugDescription }

    init(_ command: ZPLCommand, _ expected: String) {
        self.actual = command.description
        self.expected = expected
    }

    init(_ actual: String, _ expected: String) {
        self.actual = actual
        self.expected = expected
    }

    init(_ commands: [ZPLCommand], _ expected: String) {
        self.actual = commands.map(\.description).joined()
        self.expected = expected
    }
}

@Suite("ZPLCommand & Result Builder")
struct ZPLCommandTests {
    @Test("Gerenderte Form = Präfix + Code + Parameter mit Komma")
    func description() {
        #expect(ZPLCommand(.caret, "FO", ["50", "60"]).description == "^FO50,60")
        #expect(ZPLCommand(.tilde, "JC").description == "~JC")
        #expect(ZPLCommand(.caret, "A0", ["N", "30", "20"]).description == "^A0N,30,20")
        #expect(ZPLCommand(.caret, "GF", ["A", "8", "8", "1", "FF00FF00FF00FF00"]).description == "^GFA,8,8,1,FF00FF00FF00FF00")
        #expect(ZPLCommand(.caret, "FD", ["a,b,c"]).description == "^FDa,b,c")
        #expect(ZPLCommand(.caret, "XA").parameters.isEmpty)
        #expect(ZPLCommand(.caret, "XA").prefix == .caret)
        #expect(ZPLCommand("FS") == ZPLCommand(.caret, "FS"))
        #expect(ZPLCommand("FO", ["1", "2"]).description == "^FO1,2")
        #expect(ZPLCommand(.tilde, "SD", ["08"]).description == "~SD08")
    }

    @Test("Präfix-Rohwerte")
    func prefixes() {
        #expect(ZPLCommand.Prefix.caret.rawValue == "^")
        #expect(ZPLCommand.Prefix.tilde.rawValue == "~")
        #expect(ZPLCommand.Prefix(rawValue: "~") == .tilde)
    }

    @Test("Gleichheit und Hash")
    func hashable() {
        let a = ZPLCommand(.caret, "FO", ["1", "2"])
        let b = ZPL.fieldOrigin(x: 1, y: 2)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a != ZPL.fieldTypeset(x: 1, y: 2))
    }

    @Test("Kurzname (Mnemonic)")
    func mnemonic() {
        #expect(ZPL.font("0", height: 30).mnemonic == "^A")
        #expect(ZPL.font("E:ARIAL.TTF", height: 30).mnemonic == "^A")
        #expect(ZPL.hostQueryErrors().mnemonic == "~HQ")
        #expect(ZPL.fieldOrigin(x: 0, y: 0).mnemonic == "^FO")
        #expect(ZPL.setDarkness(5).mnemonic == "~SD")
    }

    @Test("Leeres Format")
    func emptyFormat() {
        #expect(ZPL.format {} == "^XA\n^XZ\n")
    }

    @Test("Result Builder: if/else, Optionale, for-Schleifen, Arrays")
    func builderControlFlow() {
        let include = true
        let missing: ZPLCommand? = nil
        let present: ZPLCommand? = ZPL.mirror(false)
        let lines = ["L0", "L1"]
        let zpl = ZPL.format {
            ZPL.changeEncoding()
            if include {
                ZPL.printWidth(400)
            } else {
                ZPL.printWidth(800)
            }
            missing
            present
            for (index, line) in lines.enumerated() {
                ZPL.text(line, x: 0, y: index * 10, height: 10)
            }
            if !include {
                ZPL.printOrientation(inverted: true)
            }
            ZPL.printQuantity(1)
        }
        #expect(zpl == """
            ^XA
            ^CI28
            ^PW400
            ^PMN
            ^FO0,0^A0N,10^FH^FDL0^FS
            ^FO0,10^A0N,10^FH^FDL1^FS
            ^PQ1
            ^XZ

            """)
    }

    @Test("Result Builder: else-Zweig, switch und Optional-Arrays")
    func builderElseAndSwitch() {
        let mode = PrintMode.cutter
        let flag = false
        let extra: [ZPLCommand]? = [ZPL.labelTop(5), ZPL.labelShift(-5)]
        let commands = ZPL.commands {
            if flag {
                ZPL.mirror(true)
            } else {
                ZPL.mirror(false)
            }
            switch mode {
            case .cutter:
                ZPL.printMode(.cutter)
            default:
                ZPL.printMode(.tearOff)
            }
            extra
            if #available(macOS 14, *) {
                ZPL.saveSettings()
            }
        }
        #expect(commands.map(\.description) == ["^PMN", "^MMC", "^LT5", "^LS-5", "^JUS"])
    }

    @Test("Zeilenaufbau: Felder in einer Zeile, Setup-Befehle einzeln")
    func renderLayout() {
        let text = ZPL.render([
            ZPL.barcodeDefaults(moduleWidth: 2),
            ZPL.fieldOrigin(x: 10, y: 10),
            ZPL.code128(height: 50),
            ZPL.fieldSeparator(),
            ZPL.comment("Ende"),
        ] + ZPL.fieldData("ohne Feld"))
        #expect(text == "^BY2,3.0,10\n^FO10,10^BCN,50,Y,N,N^FS\n^FXEnde\n^FH\n^FDohne Feld\n")
    }

    @Test("Zeilenaufbau: fehlendes ^FS")
    func renderMissingSeparator() {
        let text = ZPL.render([ZPL.fieldOrigin(x: 1, y: 1), ZPL.fieldOrigin(x: 2, y: 2), ZPL.graphicBox(width: 5, height: 5)])
        #expect(text == "^FO1,1\n^FO2,2^GB5,5,1,B,0\n")
    }

    @Test("Format mit Text erzeugt ^XA…^XZ mit genau einem Feld je Zeile")
    func formatLines() {
        let zpl = ZPL.format {
            ZPL.text("A", x: 1, y: 2, height: 3)
            ZPL.text("B", x: 4, y: 5, height: 6, width: 7, font: "D", orientation: .rotated270)
        }
        let lines = zpl.split(separator: "\n").map(String.init)
        #expect(lines == ["^XA", "^FO1,2^A0N,3^FH^FDA^FS", "^FO4,5^ADB,6,7^FH^FDB^FS", "^XZ"])
    }
}

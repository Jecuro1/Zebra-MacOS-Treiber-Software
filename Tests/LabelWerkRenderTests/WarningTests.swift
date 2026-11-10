import Foundation
import Testing
@testable import LabelWerkRender

@Suite("ZPLInterpreter – Hinweise statt Fehler")
struct WarningTests {

    private func warnings(_ zpl: String) -> [RenderWarning] {
        TestSupport.render(zpl).allWarnings
    }

    @Test("Unbekannte Format- und Steuerbefehle werden gemeldet, die Verarbeitung läuft weiter")
    func unknownCommands() throws {
        let document = TestSupport.render("^XA^ZQ12^FO10,10^A0N,30^FDok^FS~ZQ^QQ^XZ")
        let label = try #require(document.labels.first)
        #expect(TestSupport.texts(label).map(\.text) == ["ok"])
        let commands = Set(document.allWarnings.map(\.command))
        #expect(commands.isSuperset(of: ["^ZQ", "~ZQ", "^QQ"]))
        #expect(document.allWarnings.allSatisfy { !$0.message.isEmpty })
        #expect(document.allWarnings.first?.description.hasPrefix("^ZQ: ") == true)
    }

    @Test("Druckerbefehle ohne Wirkung auf das Bild erzeugen keine Hinweise")
    func silentCommands() {
        let zpl = """
        ~SD15~TA010~JC^XA^MMT^MNY^MTD^PR4,4,4^JSA^JUS^LT10^MD5^PON^PMN^CI28^LH0,0^LS0^MUD
        ^FO10,10^A0N,30^FDx^FS^HH^XZ~HS~HI~HQES~WC^XA^JUS^XZ
        """
        #expect(warnings(zpl).isEmpty)
    }

    @Test("Gleiche Hinweise werden je Etikett nur einmal aufgeführt")
    func deduplication() {
        let document = TestSupport.render("^XA^ZQ^ZQ^ZQ^FO0,0^A0N,20^FDx^FS^XZ")
        #expect(document.allWarnings.filter { $0.command == "^ZQ" }.count == 1)
    }

    @Test("Strukturfehler: fehlendes ^XZ, ^XZ ohne ^XA, Feld außerhalb eines Formats, fehlendes ^FS")
    func structure() {
        let missingEnd = TestSupport.render("^XA^FO0,0^A0N,20^FDoffen")
        #expect(missingEnd.labels.count == 1)
        #expect(missingEnd.allWarnings.contains { $0.command == "^XA" })
        #expect(missingEnd.allWarnings.contains { $0.command == "^FS" })

        let stray = TestSupport.render("^XZ")
        #expect(stray.labels.isEmpty)
        #expect(stray.warnings.contains { $0.command == "^XZ" })

        let outside = TestSupport.render("^FO10,10^A0N,20^FDohne Format^FS")
        #expect(outside.labels.count == 1)
        #expect(outside.labels.first?.warnings.first?.command == "^XA")

        let twoStarts = TestSupport.render("^XA^FO0,0^A0N,20^FDa^FS^XA^FO0,0^A0N,20^FDb^FS^XZ")
        #expect(twoStarts.labels.count == 2)
        #expect(twoStarts.allWarnings.contains { $0.command == "^XA" })
    }

    @Test("Nicht nachgebildete Einstellungen werden gemeldet")
    func unsupportedSettings() {
        #expect(warnings("^XA^MUM^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^MU" })
        #expect(warnings("^XA^MUD,200,300^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^MU" })
        #expect(warnings("^XA^CI15^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^CI" })
        #expect(warnings("^XA^CI6^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^CI" })
        #expect(warnings("^XA^CI0,21,36^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^CI" })
        #expect(warnings("^XA^POX^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^PO" })
        #expect(warnings("^XA^FM10,10^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^FM" })
        #expect(warnings("^XA^JMB^FO0,0^A0N,20^FDx^FS^XZ").contains { $0.command == "^JM" })
        #expect(warnings("^XA^FO0,0^BQN,1,3^FDQA,x^FS^XZ").contains { $0.command == "^BQ" })
    }

    @Test("Ungültige Schriftbezeichner und Daten")
    func invalidInput() {
        #expect(warnings("^XA^FO0,0^A!N,20^FDx^FS^XZ").contains { $0.command == "^A" })
        #expect(warnings("^XA^FO0,0^A@N,20,20^FDx^FS^XZ").contains { $0.command == "^A@" })
        #expect(warnings("^XA^CWZ^XZ").contains { $0.command == "^CW" })
        #expect(warnings("~DGR:BAD.GRF,abc,0,FF").contains { $0.command == "~DG" })
        #expect(warnings("~DYR:BAD,A,P,4,0,00112233").contains { $0.command == "~DY" })
        #expect(warnings("~DYR:BAD,C,G,4,1,ABCD").contains { $0.command == "~DY" })
    }
}

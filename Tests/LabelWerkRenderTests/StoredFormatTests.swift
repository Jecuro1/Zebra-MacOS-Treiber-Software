import Foundation
import Testing
@testable import LabelWerkRender

@Suite("ZPLInterpreter – gespeicherte Formate, Serialisierung, Uhrzeit")
struct StoredFormatTests {

    private static let template = """
    ^XA^DFR:SHIP.ZPL^FS
    ^FO50,50^A0N,30,30^FN1^FS
    ^FO50,100^A0N,30,30^FN2^FDStandard^FS
    ^FO50,150^GB100,10,10^FS
    ^FO50,200^BY2^BCN,50,Y,N^FN3^FS
    ^XZ
    """

    @Test("^DF speichert ohne Druck, ^XF füllt ^FN-Felder")
    func recallWithFieldNumbers() throws {
        let document = TestSupport.render(Self.template + """
        ^XA^XFR:SHIP.ZPL^FN1^FDAlice^FS^FN3^FD12345^FS^XZ
        ^XA^XFSHIP.ZPL^FN1^FDBob^FS^FN2^FDÜberschrieben^FS^FO300,300^A0N,20^FDZusatz^FS^XZ
        """)
        #expect(document.labels.count == 2)
        let first = try #require(document.labels.first)
        #expect(TestSupport.texts(first).map(\.text) == ["Alice", "Standard"])
        #expect(TestSupport.texts(first).map(\.origin) == [LabelPoint(x: 50, y: 50), LabelPoint(x: 50, y: 100)])
        #expect(TestSupport.boxes(first).count == 1)
        #expect(TestSupport.linearBarcodes(first).first?.text == "12345")
        let second = try #require(document.labels.last)
        #expect(TestSupport.texts(second).map(\.text) == ["Bob", "Überschrieben", "Zusatz"])
        #expect(TestSupport.linearBarcodes(second).isEmpty)
        #expect(document.allWarnings.isEmpty)
    }

    @Test("^XF-Werte mit ^FH, verschachtelte Formate, fehlendes Format")
    func recallDetails() throws {
        let nested = TestSupport.render("""
        ^XA^DFR:INNER.ZPL^FS^FO10,10^A0N,20^FN5^FS^XZ
        ^XA^DFR:OUTER.ZPL^FS^XFR:INNER.ZPL^FO10,40^A0N,20^FN6^FS^XZ
        ^XA^XFR:OUTER.ZPL^FN5^FH^FDA_42C^FS^FN6^FDzwei^FS^XZ
        """)
        let label = try #require(nested.labels.first)
        #expect(TestSupport.texts(label).map(\.text) == ["ABC", "zwei"])

        let missing = TestSupport.render("^XA^XFR:NONE.ZPL^FN1^FDx^FS^XZ")
        #expect(missing.labels.isEmpty)
        #expect(missing.allWarnings.contains { $0.command == "^XF" && $0.message.contains("R:NONE.ZPL") })
    }

    @Test("Selbstbezügliche gespeicherte Formate werden begrenzt")
    func recursiveRecall() {
        var definition = "^XA^DFR:LOOP.ZPL^FS"
        for _ in 0..<12 { definition += "^XFR:LOOP.ZPL" }
        definition += "^FO0,0^GB5,5,5^FS^XZ"
        let document = TestSupport.render(definition + "^XA^XFR:LOOP.ZPL^XZ")
        #expect(document.labels.count == 1)
        #expect(document.allWarnings.contains { $0.command == "^XF" })
    }

    @Test("^FN ohne ^XF ist ein gewöhnliches Feld")
    func fieldNumberWithoutRecall() {
        let label = TestSupport.label("^XA^FO0,0^A0N,20^FN1^FDsichtbar^FS^XZ")
        #expect(TestSupport.texts(label).map(\.text) == ["sichtbar"])
    }

    // MARK: Serialisierung

    @Test("^SN mit führenden Nullen und ^PQ: ein Etikett je Seriennummer")
    func serialNumbers() {
        let document = TestSupport.render("^XA^FO10,10^A0N,30^SN001,1,Y^FS^FO10,50^A0N,30^FDfest^FS^PQ3^XZ")
        #expect(document.labels.count == 3)
        #expect(document.labels.map { TestSupport.texts($0).first?.text } == ["001", "002", "003"])
        #expect(document.labels.allSatisfy { TestSupport.texts($0).last?.text == "fest" })
        #expect(document.labels.map(\.quantity) == [1, 1, 1])
    }

    @Test("^SN: Wiederholungen je Nummer, negative Schritte, ohne Nullen, Präfixe")
    func serialVariants() {
        let replicated = TestSupport.render("^XA^FO0,0^A0N,20^SNA-0007,5,Y^FS^PQ5,0,1^XZ")
        #expect(replicated.labels.map { TestSupport.texts($0).first?.text } == ["A-0007", "A-0012", "A-0017"])
        #expect(replicated.labels.map(\.quantity) == [2, 2, 1])
        let down = TestSupport.render("^XA^FO0,0^A0N,20^SN10,-3,N^FS^PQ3^XZ")
        #expect(down.labels.map { TestSupport.texts($0).first?.text } == ["10", "7", "4"])
        let growing = TestSupport.render("^XA^FO0,0^A0N,20^SN9,1,N^FS^PQ3^XZ")
        #expect(growing.labels.map { TestSupport.texts($0).first?.text } == ["9", "10", "11"])
        let wrap = TestSupport.render("^XA^FO0,0^A0N,20^SN98,1,Y^FS^PQ3^XZ")
        #expect(wrap.labels.map { TestSupport.texts($0).first?.text } == ["98", "99", "00"])
        // Ohne Menge > 1 nur ein Etikett mit dem Startwert
        #expect(TestSupport.render("^XA^FO0,0^A0N,20^SN5^FS^XZ").labels.map { TestSupport.texts($0).first?.text } == ["5"])
    }

    @Test("^SF: Maskenserialisierung (dezimal, hexadezimal, alphabetisch, Übertrag)")
    func serialMask() {
        func values(_ zpl: String) -> [String?] {
            TestSupport.render(zpl).labels.map { TestSupport.texts($0).first?.text }
        }
        #expect(values("^XA^FO0,0^A0N,20^FD0009^SFdddd,3^FS^PQ3^XZ") == ["0009", "0012", "0015"])
        #expect(values("^XA^FO0,0^A0N,20^FDAB0F^SF%%HH,1^FS^PQ2^XZ") == ["AB0F", "AB10"])
        #expect(values("^XA^FO0,0^A0N,20^FDAZ9^SFAAd,1^FS^PQ2^XZ") == ["AZ9", "BA0"])
        #expect(values("^XA^FO0,0^A0N,20^FDX-99^SF%%dd,1^FS^PQ2^XZ") == ["X-99", "X-00"])
    }

    @Test("Seriennummern in Barcodes und Begrenzung der Etikettenanzahl")
    func serialBarcodesAndLimit() {
        let barcodes = TestSupport.render("^XA^BY2^FO0,0^BCN,50^SN1000,1,Y^FS^PQ2^XZ")
        #expect(barcodes.labels.map { TestSupport.linearBarcodes($0).first?.text } == ["1000", "1001"])
        let many = TestSupport.render("^XA^FO0,0^A0N,20^SN1^FS^PQ500^XZ")
        #expect(many.labels.count == InterpreterEngine.maxSerializedLabels)
        #expect(many.allWarnings.contains { $0.command == "^PQ" })
    }

    @Test("Druckmenge ohne Serialisierung")
    func quantity() {
        #expect(TestSupport.label("^XA^FO0,0^A0N,20^FDx^FS^PQ25^XZ").quantity == 25)
        #expect(TestSupport.label("^XA^FO0,0^A0N,20^FDx^FS^PQ0^XZ").quantity == 1)
        #expect(TestSupport.label("^XA^FO0,0^A0N,20^FDx^FS^XZ").quantity == 1)
    }

    // MARK: Uhrzeit

    @Test("^FC ersetzt Datums- und Uhrzeitcodes")
    func clock() throws {
        var interpreter = ZPLInterpreter()
        interpreter.timeZone = try #require(TimeZone(identifier: "UTC"))
        // 10.11.2026 14:05:09 UTC (Dienstag, Tag 314)
        interpreter.currentDate = Date(timeIntervalSince1970: 1_794_319_509)
        let document = interpreter.render("""
        ^XA^FO0,0^A0N,20^FC%^FD%d.%m.%Y %H:%M:%S^FS
        ^FO0,30^A0N,20^FC{^FD{a {A {b {B {y {j {I{p {w {%^FS
        ^FO0,60^A0N,20^FDohne Uhr: %d^FS^XZ
        """)
        let texts = try #require(document.labels.first.map(TestSupport.texts))
        #expect(texts.map(\.text) == [
            "10.11.2026 14:05:09",
            "Tue Tuesday Nov November 26 314 02PM 2 {%",
            "ohne Uhr: %d",
        ])
    }
}

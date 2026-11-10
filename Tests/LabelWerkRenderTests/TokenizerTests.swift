import Foundation
import Testing
@testable import LabelWerkRender

@Suite("ZPLTokenizer")
struct TokenizerTests {

    private func names(_ zpl: String) -> [String] {
        ZPLTokenizer.tokenize(zpl).map(\.name)
    }

    @Test("Grundlegende Zerlegung mit Kommas in Felddaten")
    func basic() {
        let tokens = ZPLTokenizer.tokenize("^XA^FO50,60^A0N,30,40^FDHello, World^FS^XZ")
        #expect(tokens.map(\.name) == ["^XA", "^FO", "^A", "^FD", "^FS", "^XZ"])
        #expect(tokens[1].arguments == "50,60")
        #expect(tokens[1].parameters == ["50", "60"])
        #expect(tokens[2].arguments == "0N,30,40")
        #expect(tokens[3].arguments == "Hello, World")
    }

    @Test("Leerraum und CR/LF zwischen Befehlen und in Daten werden ignoriert")
    func whitespaceAndLineBreaks() {
        let tokens = ZPLTokenizer.tokenize("^XA\r\n  ^FO10,\r\n20\r\n^FDab\r\ncd^FS\n^XZ\n")
        #expect(tokens.map(\.name) == ["^XA", "^FO", "^FD", "^FS", "^XZ"])
        #expect(tokens[1].parameters == ["10", "20"])
        #expect(tokens[2].arguments == "abcd")
        // Befehlskennung über einen Zeilenumbruch hinweg
        #expect(names("^X\r\nA^F\nS") == ["^XA", "^FS"])
    }

    @Test("Text vor dem ersten Befehl wird übersprungen, leere Eingabe ergibt nichts")
    func junk() {
        #expect(names("garbage 123\n^XA^XZ trailing") == ["^XA", "^XZ"])
        #expect(ZPLTokenizer.tokenize("").isEmpty)
        #expect(ZPLTokenizer.tokenize("no commands at all").isEmpty)
    }

    @Test("Kleinbuchstaben werden normalisiert; ^A trennt den Schriftbezeichner ab")
    func lowercaseAndFont() {
        let tokens = ZPLTokenizer.tokenize("^xa^fo1,2^a0n,5^A@N,30,30,E:ARIAL.TTF^AD^xz")
        #expect(tokens.map(\.name) == ["^XA", "^FO", "^A", "^A", "^A", "^XZ"])
        #expect(tokens[2].arguments == "0n,5")
        #expect(tokens[3].arguments == "@N,30,30,E:ARIAL.TTF")
        #expect(tokens[4].arguments == "D")
    }

    @Test("^CC ändert das Formatpräfix")
    func caretChange() {
        let tokens = ZPLTokenizer.tokenize("^XA^CC#\n#FO10,10#FDx^y#FS#XZ")
        #expect(tokens.map(\.name) == ["^XA", "^CC", "^FO", "^FD", "^FS", "^XZ"])
        #expect(tokens[1].arguments == "#")
        #expect(tokens[3].arguments == "x^y")
        // ~CC wirkt genauso
        #expect(names("~CC%%XA%FDa^b%FS%XZ") == ["~CC", "^XA", "^FD", "^FS", "^XZ"])
    }

    @Test("^CT/~CT ändert das Steuerpräfix")
    func tildeChange() {
        let tokens = ZPLTokenizer.tokenize("^CT+^XA^FDa~b^FS^XZ+DGR:A.GRF,1,1,FF")
        #expect(tokens.map(\.name) == ["^CT", "^XA", "^FD", "^FS", "^XZ", "~DG"])
        #expect(tokens[2].arguments == "a~b")
        #expect(tokens[5].arguments == "R:A.GRF,1,1,FF")
        #expect(names("~CT!!HS") == ["~CT", "~HS"])
    }

    @Test("^CD/~CD ändert das Trennzeichen")
    func delimiterChange() {
        let tokens = ZPLTokenizer.tokenize("^XA^CD;^FO10;20^FDa,b;c^FS~CD|^FO1|2^XZ")
        let origin = tokens[2]
        #expect(origin.delimiter == ";")
        #expect(origin.parameters == ["10", "20"])
        #expect(tokens[3].arguments == "a,b;c")
        #expect(tokens[6].delimiter == "|")
        #expect(tokens[6].parameters == ["1", "2"])
        // Interpreter übernimmt das neue Trennzeichen
        let label = TestSupport.label("^XA^CD;^FO10;20^A0N;30;30^FDx^FS^XZ")
        #expect(TestSupport.texts(label).first?.origin == LabelPoint(x: 10, y: 20))
        #expect(TestSupport.texts(label).first?.height == 30)
    }

    @Test("Ungeeignete Präfixwechsel (Steuerzeichen, Kollisionen) werden ignoriert")
    func invalidPrefixChange() {
        #expect(names("^CC\u{1}^XA^XZ") == ["^CC", "^XA", "^XZ"])
        #expect(names("^CC~^XA^XZ") == ["^CC", "^XA", "^XZ"])
        #expect(names("^CT^^XA~HS") == ["^CT", "^XA", "~HS"])
    }

    @Test("^FX-Kommentare laufen bis zum nächsten Befehl")
    func comments() {
        let tokens = ZPLTokenizer.tokenize("^XA^FX Kommentar, mit Komma ^FO1,2^FX~HS^XZ")
        #expect(tokens.map(\.name) == ["^XA", "^FX", "^FO", "^FX", "~HS", "^XZ"])
        #expect(tokens[1].arguments == " Kommentar, mit Komma ")
    }

    @Test("Felddaten enden wie in der Firmware an jedem Präfix")
    func fieldDataEndsAtPrefix() {
        #expect(names("^FDabc^FO1,1^FS") == ["^FD", "^FO", "^FS"])
        #expect(ZPLTokenizer.tokenize("^FDa~JA").map(\.name) == ["^FD", "~JA"])
    }

    @Test("Binäres ^GF übernimmt genau die angekündigten Bytes, auch ^ und ~")
    func binaryGraphicField() {
        let payload = String(String.UnicodeScalarView([0x5E, 0x7E, 0x0A, 0xFF].map { Unicode.Scalar($0) }))
        let tokens = ZPLTokenizer.tokenize("^XA^FO0,0^GFB,4,4,1," + payload + "^FS^XZ")
        #expect(tokens.map(\.name) == ["^XA", "^FO", "^GF", "^FS", "^XZ"])
        #expect(tokens[2].arguments == "B,4,4,1," + payload)
        // ASCII-Format läuft wie gewohnt bis zum nächsten Präfix (CR/LF entfernt)
        let ascii = ZPLTokenizer.tokenize("^GFA,2,2,1,FF\r\n00^FS")
        #expect(ascii[0].arguments == "A,2,2,1,FF00")
    }

    @Test("Binäres ~DY übernimmt genau die angekündigten Bytes")
    func binaryDownloadObject() {
        let payload = String(String.UnicodeScalarView([0x5E, 0x58, 0x5A, 0x7E].map { Unicode.Scalar($0) }))
        let tokens = ZPLTokenizer.tokenize("~DYR:X,B,G,4,1," + payload + "^XA^XZ")
        #expect(tokens.map(\.name) == ["~DY", "^XA", "^XZ"])
        #expect(tokens[0].arguments == "R:X,B,G,4,1," + payload)
    }

    @Test("Bereiche verweisen auf den Quelltext")
    func ranges() throws {
        let source = "^XA\n^FO50,60^FDHi^FS\n^XZ"
        let tokens = ZPLTokenizer.tokenize(source)
        let origin = try #require(tokens.first { $0.command == "FO" })
        let range = try #require(origin.range)
        #expect(String(source[range]) == "^FO50,60")
        let last = try #require(tokens.last?.range)
        #expect(source[last.lowerBound...].hasPrefix("^XZ"))
    }

    @Test("Leere Parameter bleiben erhalten; einzelnes Präfix am Ende")
    func emptyParameters() {
        let token = ZPLTokenizer.tokenize("^BCN,,Y,N")[0]
        #expect(token.parameters == ["N", "", "Y", "N"])
        let trailing = ZPLTokenizer.tokenize("^XA^")
        #expect(trailing.map(\.name) == ["^XA", "^"])
        #expect(ZPLTokenizer.tokenize("^X").map(\.command) == ["X"])
        #expect(ZPLToken(prefix: "^", command: "XA").parameters.isEmpty)
    }
}

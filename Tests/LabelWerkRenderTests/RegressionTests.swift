import Foundation
import Testing
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging
@testable import LabelWerkRender

/// Regressionstests zu den Befunden der Render-Prüfung (Abstürze, falsche Inhalte, Abweichungen
/// zwischen Vorschau und Druck). Jeder Fall hat früher den Prozess beendet oder ein falsches
/// Ergebnis ohne Hinweis geliefert.
@Suite("Regressionen: Nicht-ASCII-Parameter")
struct NonASCIIParameterRegressionTests {

    /// Zeichen, deren Großschreibung aus mehreren Zeichen besteht (ß → SS, ﬁ → FI, ŉ → ʼN) oder
    /// die außerhalb von ASCII liegen.
    static let awkward = ["ß", "ﬁ", "ŉ", "İ", "ǰ", "Ä", "€", "😀"]

    @Test("^A mit ß/ﬁ als Schriftbezeichner: Hinweis und Standardschrift statt Absturz")
    func fontIdentifier() throws {
        for character in Self.awkward {
            let document = TestSupport.render("^XA^FO0,0^A\(character)N,30^FDx^FS^XZ")
            let label = try #require(document.labels.first, "\(character)")
            #expect(TestSupport.texts(label).map(\.text) == ["x"])
            #expect(TestSupport.texts(label).first?.fontName == "A", "\(character)")
            #expect(document.allWarnings.contains { $0.command == "^A" && $0.message.contains(character) })
        }
    }

    @Test("^CF mit Nicht-ASCII-Bezeichner: Hinweis, Standardschrift bleibt (früher Schrift „SS“)")
    func defaultFontIdentifier() throws {
        let document = TestSupport.render("^XA^CF0,40^CFß^FO0,0^FDx^FS^XZ")
        let text = try #require(document.labels.first.flatMap { TestSupport.texts($0).first })
        #expect(text.fontName == "0")
        #expect(text.height == 40)
        #expect(document.allWarnings.contains { $0.command == "^CF" && $0.message.contains("ß") })
    }

    @Test("Ja/Nein-, Ausrichtungs- und Buchstabenparameter mit ß", arguments: [
        "^XA^POß^FO0,0^A0N,20^FDx^FS^XZ",
        "^XA^FO0,0^A0N,30^FB300,2,0,ß^FDx^FS^XZ",
        "^XA^FWß^FO0,0^A0ß,30^FDx^FS^XZ",
        "^XA^FPß^FO0,0^A0N,30^FDx^FS^XZ",
        "^XA^FO0,0^BCß,50,ß,ß,ß,ß^FDABC^FS^XZ",
        "^XA^FO0,0^BKN,N,50,Y,N,ß,ŉ^FD123^FS^XZ",
        "^XA^FO0,0^GB100,100,3,ß^FS^XZ",
        "^XA^MUß^LRß^PMß^MCß^FO0,0^A0N,20^FDx^FS^XZ",
        "^XA^CWß,E:FONT.TTF^FO0,0^Aß,20^FDx^FS^XZ",
        "^XA^FO0,0^BQN,2,4^FDßA,text^FS^XZ",
        "^XA^FO0,0^BQN,2,4^FDQß,text^FS^XZ",
        "^XA^FO0,0^BQN,2,4^FDQM,ßtext^FS^XZ",
    ])
    func letterParameters(zpl: String) {
        let document = TestSupport.render(zpl)
        #expect(document.labels.count == 1)
        for label in document.labels {
            _ = label.elements.map(\.boundingBox)
            _ = SoftwareRasterizer.rasterize(label)
        }
    }

    @Test("^PO mit ß: Hinweis, Etikett bleibt aufrecht")
    func printOrientation() throws {
        let document = TestSupport.render("^XA^POß^FO0,0^A0N,20^FDx^FS^XZ")
        let label = try #require(document.labels.first)
        #expect(label.inverted == false)
        #expect(document.allWarnings.contains { $0.command == "^PO" })
    }

    @Test("^FB mit ß als Ausrichtung: linksbündig")
    func fieldBlockJustification() throws {
        let label = TestSupport.label("^XA^FO0,0^A0N,30^FB300,2,0,ß^FDx^FS^XZ")
        let text = try #require(TestSupport.texts(label).first)
        #expect(text.block?.justification == .left)
        #expect(text.block?.width == 300)
    }

    @Test("^SF mit ß in Daten und Schrittweite: kein Absturz, ASCII-Stellen zählen weiter")
    func serializationMask() {
        let document = TestSupport.render("^XA^FO0,0^A0N,20^FDß^SFA,ß^FS^PQ2^XZ")
        #expect(document.labels.count == 2)
        let mixed = TestSupport.render("^XA^FO0,0^A0N,20^FDßA^SF%A,B^FS^PQ3^XZ")
        let texts = mixed.labels.compactMap { TestSupport.texts($0).first?.text }
        #expect(texts == ["ßA", "ßB", "ßC"])
    }

    @Test("Serializer.alphabetIndex: andere ASCII-Schreibweise ja, Nicht-ASCII nie")
    func alphabetIndex() {
        let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let lower = Array("abcdefghijklmnopqrstuvwxyz")
        #expect(Serializer.alphabetIndex("C", in: upper) == 2)
        #expect(Serializer.alphabetIndex("c", in: upper) == 2)
        #expect(Serializer.alphabetIndex("Z", in: lower) == 25)
        #expect(Serializer.alphabetIndex("1", in: upper) == nil)
        for character in Self.awkward {
            #expect(Serializer.alphabetIndex(Character(character), in: upper) == nil)
            #expect(Serializer.alphabetIndex(Character(character), in: lower) == nil)
        }
        // Zeichen außerhalb des Alphabets zählen als dessen erstes Zeichen (wie Ziffern bei „A“).
        #expect(Serializer.masked("Aß", mask: "AA", increment: "ß", copy: 1) == "AA")
        #expect(Serializer.masked("AZ", mask: "AA", increment: "1", copy: 1) == "AZ")
        #expect(Serializer.masked("AZ", mask: "AA", increment: "B", copy: 1) == "BA")
    }

    @Test("Character.asciiUppercased/asciiLowercased: nur ASCII-Buchstaben werden umgewandelt")
    func asciiCaseMapping() {
        #expect(Character("a").asciiUppercased == "A")
        #expect(Character("z").asciiUppercased == "Z")
        #expect(Character("A").asciiLowercased == "a")
        #expect(Character("1").asciiUppercased == "1")
        #expect(Character("@").asciiLowercased == "@")
        #expect(Character("\r\n").asciiUppercased == "\r\n")
        for character in Self.awkward {
            #expect(Character(character).asciiUppercased == Character(character))
            #expect(Character(character).asciiLowercased == Character(character))
        }
        #expect(ZPLParameters(["ß"]).character(0) == "ß")
        #expect(ZPLParameters(["  y "]).bool(0) == true)
        #expect(ZPLParameters(["ß"]).bool(0) == nil)
        #expect(ZPLParameters(["ﬁ"]).orientation(0) == nil)
    }
}

@Suite("Regressionen: Vorzeichen in Barcodedaten")
struct SignedBarcodeDataRegressionTests {

    @Test("QR-Byte-Segment mit negativer Länge: Hinweis statt Absturz")
    func qrNegativeByteCount() throws {
        let document = TestSupport.render("^XA^FO0,0^BQN,2,4^FDMM,B-001hello^FS^XZ")
        let matrix = try #require(document.labels.first.flatMap { TestSupport.matrixBarcodes($0).first })
        #expect(matrix.text == "-001hello")
        #expect(document.allWarnings.contains { $0.command == "^BQ" && $0.message.contains("Bytezahl") })
        for count in ["+001", " 001", "00 1", "１２３４", "12"] {
            let parsed = QRFieldData.parse("MM,B\(count)hello", defaultLevel: .quartile)
            #expect(!parsed.warnings.isEmpty, "\(count)")
            #expect(parsed.payload == "\(count)hello", "\(count)")
        }
    }

    @Test("Data-Matrix-Escape mit Vorzeichen: Hinweis, Zeichen bleiben erhalten")
    func dataMatrixSignedEscape() throws {
        let document = TestSupport.render("^XA^FO0,0^BXN,5,200,,,,_^FDab_d-12^FS^XZ")
        let matrix = try #require(document.labels.first.flatMap { TestSupport.matrixBarcodes($0).first })
        #expect(matrix.text == "ab_d-12")
        #expect(document.allWarnings.contains { $0.command == "^BX" && $0.message.contains("_d-12") })

        let decoded = DataMatrixEscapes.decode("_d065_d-12_d+12_d１２３_d256_d0", escape: "_")
        #expect(decoded.bytes == [65] + Array("_d-12_d+12_d１２３_d256_d0".utf8))
        #expect(decoded.warnings.count == 5)
        #expect(DataMatrixEscapes.decode("~d255~d000~~~M", escape: "~").bytes == [255, 0, 0x7E, 0x0D])
        #expect(DataMatrixEscapes.decode("~d255", escape: "~").warnings.isEmpty)
    }

    @Test("ZPLParameters.unsignedDecimal akzeptiert nur ASCII-Ziffern")
    func unsignedDecimal() {
        #expect(ZPLParameters.unsignedDecimal("0006") == 6)
        #expect(ZPLParameters.unsignedDecimal("255") == 255)
        #expect(ZPLParameters.unsignedDecimal("-12") == nil)
        #expect(ZPLParameters.unsignedDecimal("+12") == nil)
        #expect(ZPLParameters.unsignedDecimal(" 12") == nil)
        #expect(ZPLParameters.unsignedDecimal("１２") == nil)
        #expect(ZPLParameters.unsignedDecimal("٣") == nil)
        #expect(ZPLParameters.unsignedDecimal("") == nil)
        #expect(ZPLParameters.unsignedDecimal(String(repeating: "9", count: 19)) == nil)
    }
}

@Suite("Regressionen: QR-Code mit manueller Eingabe")
struct QRManualInputRegressionTests {

    /// Beispiel des ZPL II Programming Guide (^BQ, Mixed Mode mit manueller Eingabe).
    static let guideSegments = "LM,N0123456789,A12AABB,B0006qrcode"
    static let guideContent = "012345678912AABBqrcode"

    @Test("Mehrere Segmente werden ohne Kommas und Moduskennungen aneinandergehängt")
    func segments() throws {
        let parsed = QRFieldData.parse(Self.guideSegments, defaultLevel: .quartile)
        #expect(parsed.payload == Self.guideContent)
        #expect(parsed.level == .low)
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.structuredAppend == nil)

        let label = TestSupport.label("^XA^FO0,0^BQN,2,5^FD\(Self.guideSegments)^FS^XZ")
        #expect(label.warnings.isEmpty)
        let matrix = try #require(TestSupport.matrixBarcodes(label).first)
        #expect(matrix.text == Self.guideContent)
        #expect(matrix.matrix == (try BarcodeEncoder.qr(Self.guideContent, errorCorrection: .low)))
    }

    @Test("Strukturierter Anhang (D…): Kopf wird erkannt, Hinweis, Inhalt wie ohne Kopf")
    func structuredAppend() throws {
        for mode in ["M,N0123456789,A12AABB,B0006qrcode", "A,012345678912AABBqrcode"] {
            let parsed = QRFieldData.parse("D03048F,L" + mode, defaultLevel: .quartile)
            #expect(parsed.payload == Self.guideContent)
            #expect(parsed.structuredAppend == QRFieldData.StructuredAppend(position: 3, total: 4, parity: 0x8F))
            #expect(parsed.warnings.count == 1)
            #expect(parsed.warnings.first?.contains("Symbol 3 von 4") == true)
            #expect(parsed.warnings.first?.contains("8F") == true)
        }
        let document = TestSupport.render("^XA^FO0,0^BQN,2,5^FDD03048F,\(Self.guideSegments)^FS^XZ")
        #expect(document.labels.first.flatMap { TestSupport.matrixBarcodes($0).first?.text } == Self.guideContent)
        #expect(document.allWarnings.contains { $0.command == "^BQ" && $0.message.contains("Strukturierter Anhang") })

        for header in ["D0304", "D17048F", "D05048F", "D0301ZZ", "Dab048F"] {
            let invalid = QRFieldData.parse(header + ",QA,text", defaultLevel: .medium)
            #expect(invalid.payload == "text", "\(header)")
            #expect(invalid.structuredAppend == nil, "\(header)")
            #expect(invalid.warnings.contains { $0.contains("Ungültiger Kopf") }, "\(header)")
        }
    }

    @Test("Byte-Segmente zählen Bytes gemäß ^CI und dürfen Kommas enthalten")
    func byteSegments() {
        let commas = QRFieldData.parse("HM,B0005a,b,c,N123", defaultLevel: .medium)
        #expect(commas.payload == "a,b,c123")
        #expect(commas.level == .high)
        #expect(commas.warnings.isEmpty)

        let utf8 = QRFieldData.parse("MM,B0004äö,N12", defaultLevel: .medium, characterSet: .utf8)
        #expect(utf8.payload == "äö12")
        #expect(utf8.warnings.isEmpty)
        let latin = QRFieldData.parse("MM,B0004äö,N12", defaultLevel: .medium, characterSet: .codePage850)
        #expect(latin.payload == "äö,N")
        #expect(latin.warnings.contains { $0.contains("Komma") && $0.contains("„12“") })
        // Die angekündigte Bytezahl ist maßgeblich, überzählige Zeichen werden nicht kodiert.
        let surplus = QRFieldData.parse("LM,B0005hello world", defaultLevel: .medium)
        #expect(surplus.payload == "hello")
        #expect(surplus.warnings.contains { $0.contains("„ world“") })
        let utf16 = QRFieldData.parse("MM,B0004ab,N1", defaultLevel: .medium, characterSet: .utf16BigEndian)
        #expect(utf16.payload == "ab1")

        let short = QRFieldData.parse("MM,B0010abc", defaultLevel: .medium)
        #expect(short.payload == "abc")
        #expect(short.warnings.contains { $0.contains("10 Bytes") })
        let split = QRFieldData.parse("MM,B0001ä", defaultLevel: .medium)
        #expect(split.payload == "ä")
        #expect(split.warnings.contains { $0.contains("Mehrbytezeichen") })
        #expect(QRFieldData.parse("MM,B0000,N1", defaultLevel: .medium).payload == "1")
    }

    @Test("^CI28 im Format: Bytezahl von Byte-Segmenten in UTF-8")
    func byteSegmentsFollowCharacterSet() throws {
        let utf8 = TestSupport.label("^XA^CI28^FO0,0^BQN,2,4^FDMM,B0007Grüße^FS^XZ")
        #expect(utf8.warnings.isEmpty)
        #expect(TestSupport.matrixBarcodes(utf8).first?.text == "Grüße")
        let latin = TestSupport.label("^XA^CI27^FO0,0^BQN,2,4^FDMM,B0005Grüße^FS^XZ")
        #expect(latin.warnings.isEmpty)
        #expect(TestSupport.matrixBarcodes(latin).first?.text == "Grüße")
    }

    @Test("Ungültige Segmente erzeugen Hinweise, der Inhalt bleibt erhalten")
    func invalidSegments() {
        let numeric = QRFieldData.parse("MM,N12a4", defaultLevel: .medium)
        #expect(numeric.payload == "12a4")
        #expect(numeric.warnings.contains { $0.contains("(N)") })
        let alphanumeric = QRFieldData.parse("MM,Aabc", defaultLevel: .medium)
        #expect(alphanumeric.payload == "abc")
        #expect(alphanumeric.warnings.contains { $0.contains("(A)") })
        let unknown = QRFieldData.parse("MM,N12,X34,N56", defaultLevel: .medium)
        #expect(unknown.payload == "12X34,N56")
        #expect(unknown.warnings.contains { $0.contains("Zeichenmodus") })
        let lowercase = QRFieldData.parse("qm,n123,b0002xy", defaultLevel: .medium)
        #expect(lowercase.payload == "123xy")
        #expect(lowercase.level == .quartile)
        let kanji = QRFieldData.parse("MM,K漢字,N1", defaultLevel: .medium)
        #expect(kanji.payload == "漢字1")
        #expect(QRFieldData.parse("MM,N12,", defaultLevel: .medium).payload == "12")
    }

    @Test("Automatischer Modus und fehlendes Präfix unverändert")
    func automaticAndMissingPrefix() {
        let automatic = QRFieldData.parse("QA,a,b,c", defaultLevel: .medium)
        #expect(automatic.payload == "a,b,c")
        #expect(automatic.level == .quartile)
        #expect(automatic.warnings.isEmpty)
        let missing = QRFieldData.parse("https://example.com", defaultLevel: .medium)
        #expect(missing.payload == "https://example.com")
        #expect(missing.level == .medium)
        #expect(missing.warnings.count == 1)
        let startsWithD = QRFieldData.parse("DATA,1,2", defaultLevel: .high)
        #expect(startsWithD.payload == "DATA,1,2")
        #expect(startsWithD.structuredAppend == nil)
    }
}

@Suite("Regressionen: Auflösungsabhängige Textvermessung")
struct ResolutionBoundingBoxRegressionTests {

    @Test("boundingBox umschließt die gerasterte Tinte bei 6, 8, 12 und 24 Punkten/mm",
          arguments: ["A", "B", "D", "E", "F", "H", "0"], [6, 8, 12, 24])
    func boxContainsInk(font: String, dotsPerMM: Int) throws {
        let zpl = "^XA^PW1600^LL400^FO20,20^A\(font)N^FDABCDEFGH^FS^XZ"
        let label = TestSupport.label(zpl, dotsPerMM: dotsPerMM)
        let element = try #require(label.elements.first)
        guard case .text(let text) = element else {
            Issue.record("kein Textelement")
            return
        }
        #expect(text.dotsPerMM == dotsPerMM)
        let box = element.boundingBox
        #expect(label.boundingBox(of: element) == box)
        let ink = try #require(TestSupport.inkBounds(SoftwareRasterizer.rasterize(label)))
        // Die Tinte liegt innerhalb des Feldrechtecks (Zeichenabstand rechts darf leer sein).
        #expect(ink.x >= box.x && ink.x + ink.width <= box.x + box.width,
                "\(font) @\(dotsPerMM): box \(box), ink \(ink)")
        #expect(box.width - ink.width < text.width, "\(font) @\(dotsPerMM): box \(box), ink \(ink)")
    }

    @Test("Schriften E und H bei 12 Punkten/mm: Zellen 20 + 10 bzw. 22 + 8 Punkte")
    func highResolutionCells() throws {
        for (font, height) in [("E", 42), ("H", 34)] {
            let label = TestSupport.label("^XA^FO0,0^A\(font)N^FDABCDEFGH^FS^XZ", dotsPerMM: 12)
            let box = try #require(label.elements.first?.boundingBox)
            #expect(box.width == 240, "\(font)")
            #expect(box.height == height, "\(font)")
        }
    }

    @Test("Elemente ohne eigene Auflösung: RenderedLabel.boundingBox(of:) nutzt die des Etiketts")
    func elementWithoutResolution() {
        let text = TextElement(origin: LabelPoint(x: 5, y: 7), fontName: "E", height: 42, width: 20, text: "ABCD")
        let element = LabelElement.text(text)
        let label = RenderedLabel(widthDots: 400, heightDots: 100, dotsPerMM: 12, elements: [element])
        #expect(label.boundingBox(of: element) == (5, 7, 120, 42))
        #expect(element.boundingBox(dotsPerMM: 12) == (5, 7, 120, 42))
        // Ohne Etikett gilt 8 Punkte/mm (Zelle 15 + 5, Vergrößerung 1).
        #expect(element.boundingBox == (5, 7, 80, 42))
        // Die Rasterung verwendet dieselbe Auflösung wie boundingBox(of:).
        let ink = TestSupport.inkBounds(SoftwareRasterizer.rasterize(label))
        #expect(ink.map { $0.x + $0.width <= 5 + 120 && $0.x + $0.width > 5 + 90 } == true)

        var tagged = text
        tagged.dotsPerMM = 8
        #expect(label.boundingBox(of: .text(tagged)) == (5, 7, 80, 42))
    }
}

@Suite("Regressionen: ^LT (Etikettenanfang)")
struct LabelTopRegressionTests {

    @Test("^LT verschiebt alle Felder nach unten bzw. oben, ohne Hinweis")
    func shiftsFields() throws {
        let label = TestSupport.label("^XA^LT20^FO10,10^GB10,10,10^FS^XZ")
        #expect(label.warnings.isEmpty)
        #expect(label.elements.first?.origin == LabelPoint(x: 10, y: 30))
        let ink = try #require(TestSupport.inkBounds(SoftwareRasterizer.rasterize(label)))
        #expect(ink.y == 30 && ink.x == 10)

        let up = TestSupport.label("^XA^LT-20^FO10,30^GB10,10,10^FS^XZ")
        #expect(up.elements.first?.origin == LabelPoint(x: 10, y: 10))
    }

    @Test("^LT gilt für das ganze Format, unabhängig von seiner Stellung")
    func appliesToWholeFormat() {
        let label = TestSupport.label("^XA^FO0,0^GB10,10,10^FS^FO50,40^A0N,20^FDx^FS^LT15^XZ")
        #expect(label.elements.map(\.origin) == [LabelPoint(x: 0, y: 15), LabelPoint(x: 50, y: 55)])
    }

    @Test("^LT ist eine dauerhafte Einstellung: gilt in Folgeformaten, ^LT0 setzt zurück")
    func persists() {
        let document = TestSupport.render("""
        ^XA^LT12^FO0,0^GB5,5,5^FS^XZ
        ^XA^FO0,0^GB5,5,5^FS^XZ
        ^XA^LT0^FO0,0^GB5,5,5^FS^XZ
        """)
        #expect(document.labels.map { $0.elements.first?.origin.y } == [12, 12, 0])
    }

    @Test("Werte außerhalb von ±120 werden begrenzt, ungültige ignoriert")
    func limits() {
        let high = TestSupport.render("^XA^LT500^FO0,0^GB5,5,5^FS^XZ")
        #expect(high.labels.first?.elements.first?.origin.y == 120)
        #expect(high.allWarnings.contains { $0.command == "^LT" && $0.message.contains("120") })
        let low = TestSupport.render("^XA^LT-500^FO0,200^GB5,5,5^FS^XZ")
        #expect(low.labels.first?.elements.first?.origin.y == 80)
        let invalid = TestSupport.render("^XA^LT30^LTabc^FO0,0^GB5,5,5^FS^XZ")
        #expect(invalid.labels.first?.elements.first?.origin.y == 30)
        #expect(invalid.allWarnings.contains { $0.command == "^LT" })
        let empty = TestSupport.render("^XA^LT30^LT^FO0,0^GB5,5,5^FS^XZ")
        #expect(empty.labels.first?.elements.first?.origin.y == 30)
        #expect(empty.allWarnings.isEmpty)
    }

    @Test("^FT-Folgepositionen, ^IS/^IL und Serialisierung: Verschiebung genau einmal")
    func appliedOnce() throws {
        let plain = TestSupport.label("^XA^FT10,50^A0N,20^FDab^FS^FT^A0N,20^FDcd^FS^XZ")
        let shifted = TestSupport.label("^XA^LT20^FT10,50^A0N,20^FDab^FS^FT^A0N,20^FDcd^FS^XZ")
        #expect(shifted.elements.map(\.origin) == plain.elements.map { LabelPoint(x: $0.origin.x, y: $0.origin.y + 20) })

        let stored = TestSupport.render("""
        ^XA^LT10^FO0,0^GB20,20,20^FS^ISR:LT.GRF,N^XZ
        ^XA^ILR:LT.GRF^FO100,100^GB5,5,5^FS^XZ
        """)
        let recalled = try #require(stored.labels.first)
        #expect(recalled.elements.map(\.origin) == [LabelPoint(x: 0, y: 10), LabelPoint(x: 100, y: 110)])

        let serial = TestSupport.render("^XA^LT8^FO0,0^A0N,20^SN001,1,Y^FS^PQ2^XZ")
        #expect(serial.labels.map { $0.elements.first?.origin.y } == [8, 8])
        #expect(serial.labels.compactMap { TestSupport.texts($0).first?.text } == ["001", "002"])

        let retained = TestSupport.render("^XA^MCN^LT6^FO0,0^GB5,5,5^FS^XZ^XA^FO20,0^GB5,5,5^FS^XZ")
        #expect(retained.labels.last?.elements.map(\.origin.y) == [6, 6])
    }
}

@Suite("Regressionen: ^BX ohne Qualitätsstufe")
struct DataMatrixQualityRegressionTests {

    @Test("Fehlendes s: Hinweis auf ECC 000, Darstellung als ECC 200")
    func missingQuality() throws {
        let document = TestSupport.render("^XA^FO0,0^BXN,5^FDhello^FS^XZ")
        let matrix = try #require(document.labels.first.flatMap { TestSupport.matrixBarcodes($0).first })
        #expect(matrix.matrix.width == 12 && matrix.matrix.height == 12)
        #expect(document.allWarnings.contains { $0.command == "^BX" && $0.message.contains("ECC 000") })
        #expect(TestSupport.render("^XA^FO0,0^BXN,5,,^FDhello^FS^XZ").allWarnings.contains { $0.command == "^BX" })
    }

    @Test("s = 200 ohne Hinweis, andere Stufen mit Hinweis")
    func explicitQuality() {
        #expect(TestSupport.render("^XA^FO0,0^BXN,5,200^FDhello^FS^XZ").allWarnings.isEmpty)
        for quality in ["0", "50", "80", "100", "140"] {
            let warnings = TestSupport.render("^XA^FO0,0^BXN,5,\(quality)^FDhello^FS^XZ").allWarnings
            #expect(warnings.contains { $0.command == "^BX" && $0.message.contains("ECC \(quality)") })
        }
    }
}

@Suite("Regressionen: Balkengeometrie linearer Barcodes")
struct LinearBarcodeGeometryRegressionTests {

    @Test("EAN-13 mit Klarschrift unten: Balken beginnen 7 Module rechts vom Ursprung")
    func eanBarsOrigin() throws {
        let label = TestSupport.label("^XA^BY2^FO100,100^BEN,100,Y,N^FD590123412345^FS^XZ")
        let barcode = try #require(TestSupport.linearBarcodes(label).first)
        #expect(barcode.origin == LabelPoint(x: 100, y: 100))
        #expect(barcode.layout.barsX == 14)
        #expect(barcode.barsOrigin == LabelPoint(x: 114, y: 100))
        let bitmap = SoftwareRasterizer.rasterize(label)
        let firstBar = (0..<bitmap.width).first { bitmap[$0, 150] }
        #expect(firstBar == barcode.barsOrigin.x)
        #expect(barcode.barsFrame.width == barcode.layout.barsWidth)
        #expect(barcode.barsFrame.height == 100)
        // Die außen stehende Ziffer liegt links der Balken.
        let digit = try #require(barcode.layout.texts.first)
        #expect(digit.text == "5")
        #expect(digit.x + barcode.layout.textAdvance <= barcode.layout.barsX)
    }

    @Test("Klarschrift oben: Balken beginnen unter der Schriftzeile")
    func interpretationAbove() throws {
        let label = TestSupport.label("^XA^BY2^FO50,40^BCN,60,Y,Y^FDABC^FS^XZ")
        let barcode = try #require(TestSupport.linearBarcodes(label).first)
        let layout = barcode.layout
        #expect(layout.barsY == layout.textHeight + layout.module)
        #expect(barcode.barsOrigin == LabelPoint(x: 50, y: 40 + layout.barsY))
    }

    @Test("barsFrame enthält in jeder Drehung genau die Balkenpunkte",
          arguments: ["N", "R", "I", "B"], ["^BEo,80,Y,N^FD590123412345", "^BUo,80,Y,N^FD03600029145", "^BCo,60,Y,Y^FDABC123"])
    func barsFrameMatchesRaster(orientation: String, command: String) throws {
        let field = command.replacingOccurrences(of: "o,", with: orientation + ",")
        let label = TestSupport.label("^XA^PW700^LL700^BY2^FO120,120\(field)^FS^XZ")
        let barcode = try #require(TestSupport.linearBarcodes(label).first)
        let layout = barcode.layout
        let frame = barcode.barsFrame
        let bitmap = SoftwareRasterizer.rasterize(label)
        let expected = layout.bars.reduce(0) { $0 + $1.width } * layout.barHeight
        let inside = TestSupport.blackCount(bitmap, x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        #expect(inside == expected, "\(field): frame \(frame)")
    }
}

@Suite("Regressionen: Paket- und Testinfrastruktur")
struct InfrastructureRegressionTests {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Das Ziel LabelWerkRender enthält außer Swift-Dateien nur versteckte Verzeichnisse")
    func noUnhandledFiles() throws {
        let target = Self.packageRoot.appendingPathComponent("Sources/LabelWerkRender", isDirectory: true)
        let files = try #require(FileManager.default.subpaths(atPath: target.path))
        #expect(files.contains("Interpreter/ZPLInterpreter.swift"))
        // SwiftPM überspringt versteckte Dateien und Verzeichnisse (Pfadteil beginnt mit „.“).
        let unhandled = files.filter { path in
            let components = path.split(separator: "/")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target.appendingPathComponent(path).path,
                                                        isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue && !path.hasSuffix(".swift")
                && !components.contains { $0.hasPrefix(".") }
        }
        #expect(unhandled.isEmpty, "SwiftPM würde warnen: \(unhandled)")
        let generator = target.appendingPathComponent(".fontgen/generate_font.py")
        #expect(FileManager.default.fileExists(atPath: generator.path))
    }

    @Test("Rückleser-Interpreter stammt aus LABELWERK_ZXING_PYTHON oder dem PATH")
    func zxingInterpreterLookup() {
        guard let path = TestSupport.pythonPath else { return }
        let environment = ProcessInfo.processInfo.environment
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fromEnvironment = environment["LABELWERK_ZXING_PYTHON"] == path
        let fromPath = directories.contains { URL(fileURLWithPath: $0).appendingPathComponent("python3").path == path
            || URL(fileURLWithPath: $0).appendingPathComponent("python").path == path }
        #expect(fromEnvironment || fromPath, "\(path)")
    }
}

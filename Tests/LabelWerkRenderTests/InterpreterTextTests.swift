import Foundation
import Testing
import LabelWerkCore
import LabelWerkImaging
@testable import LabelWerkRender

@Suite("ZPLInterpreter – Text, Schriften und Geometrie")
struct InterpreterTextTests {

    private func text(_ zpl: String, sourceLocation: SourceLocation = #_sourceLocation) -> TextElement {
        let label = TestSupport.label("^XA" + zpl + "^XZ", sourceLocation: sourceLocation)
        return TestSupport.texts(label).first
            ?? TextElement(origin: .zero, fontName: "?", height: 0, width: 0, text: "")
    }

    // MARK: Etikettengröße

    @Test("Etikettengröße aus Vorgaben, ^PW und ^LL (dauerhaft über Formate)")
    func labelSize() {
        let document = TestSupport.render("""
        ^XA^FO0,0^A0N,30^FDa^FS^XZ
        ^XA^PW400^LL600^FO0,0^A0N,30^FDb^FS^XZ
        ^XA^FO0,0^A0N,30^FDc^FS^XZ
        """)
        #expect(document.labels.count == 3)
        #expect(document.labels.map(\.widthDots) == [812, 400, 400])
        #expect(document.labels.map(\.heightDots) == [1218, 600, 600])
        #expect(document.labels.allSatisfy { $0.dotsPerMM == 8 })
        let custom = ZPLInterpreter(dotsPerMM: 12, defaultWidthDots: 1200, defaultHeightDots: 900)
            .render("^XA^FO0,0^A0N,30^FDx^FS^XZ")
        #expect(custom.labels.first?.widthDots == 1200)
        #expect(custom.labels.first?.heightDots == 900)
        #expect(custom.labels.first?.dotsPerMM == 12)
    }

    // MARK: Schriften

    @Test("Skalierbare Schrift 0: Höhe/Breite, proportionale Breite")
    func scalableFont() {
        let a = text("^FO10,20^A0N,30,40^FDHallo^FS")
        #expect(a.fontName == "0")
        #expect(a.height == 30 && a.width == 40)
        #expect(a.origin == LabelPoint(x: 10, y: 20))
        #expect(a.orientation == .normal)
        #expect(a.text == "Hallo")
        let b = text("^FO0,0^A0N,50^FDx^FS")
        #expect(b.height == 50 && b.width == 50)
        let c = text("^FO0,0^A0N,,60^FDx^FS")
        #expect(c.height == 60 && c.width == 60)
    }

    @Test("Bitmap-Schriften A–H: Zellgrößen und ganzzahlige Vergrößerung")
    func bitmapFonts() {
        let cases: [(String, Int, Int)] = [
            ("^AAN", 9, 5),            // ^CF-Standard 9 × 5
            ("^ABN,11,7", 11, 7),
            ("^ADN,36,20", 36, 20),
            ("^ADN,40,25", 36, 20),    // abgerundet auf Vielfache
            ("^ADN,36", 36, 20),       // Breite proportional
            ("^ADN,,30", 54, 30),      // Höhe proportional
            ("^AEN,28,15", 28, 15),
            ("^AFN,52,26", 52, 26),
            ("^AGN,200,200", 180, 200),
            ("^AHN,21,13", 21, 13),
            ("^ADN,1000,1000", 180, 100), // höchstens 10-fach
            ("^ADN,5,5", 18, 10),          // mindestens 1-fach
        ]
        for (font, height, width) in cases {
            let element = text("^FO0,0" + font + "^FDx^FS")
            #expect(element.height == height && element.width == width, "\(font): \(element.height)×\(element.width)")
        }
        // Schriften fester Größe P–V ohne Angabe: eigene Zellgröße, mit Angabe skalierbar.
        let p = text("^FO0,0^APN^FDx^FS")
        #expect(p.fontName == "P" && p.height == 20 && p.width == 18)
        let v = text("^FO0,0^AVN^FDx^FS")
        #expect(v.height == 80 && v.width == 71)
        let scaledP = text("^FO0,0^APN,40^FDx^FS")
        #expect(scaledP.height == 40 && scaledP.width == 40)
        // Bei 12 Punkten/mm haben E und H eigene Matrizen.
        let label = ZPLInterpreter(dotsPerMM: 12).render("^XA^FO0,0^AEN,42,20^FDx^FS^XZ").labels.first
        let e12 = label.flatMap { TestSupport.texts($0).first }
        #expect(e12?.height == 42 && e12?.width == 20)
    }

    @Test("^CF setzt die Standardschrift")
    func changeDefaultFont() {
        let a = text("^CF0,40^FO10,10^FDx^FS")
        #expect(a.fontName == "0" && a.height == 40 && a.width == 40)
        let b = text("^CFD^FO10,10^FDx^FS")
        #expect(b.fontName == "D" && b.height == 18 && b.width == 10)
        let c = text("^CFA,30^FO10,10^FDx^FS")
        #expect(c.fontName == "A" && c.height == 27 && c.width == 15)
        let d = text("^CF0,40,20^FO10,10^FDx^FS")
        #expect(d.height == 40 && d.width == 20)
        // ^A ohne Größe übernimmt die ^CF-Größe
        let e = text("^CF0,44^FO10,10^A0R^FDx^FS")
        #expect(e.height == 44 && e.orientation == .rotated90)
    }

    @Test("^FW setzt die Standardausrichtung, ^A überschreibt sie")
    func fieldOrientationDefault() {
        #expect(text("^FWR^FO10,10^A0,30,30^FDx^FS").orientation == .rotated90)
        #expect(text("^FWR^FO10,10^A0B,30,30^FDx^FS").orientation == .rotated270)
        #expect(text("^FWI^CF0,30^FO10,10^FDx^FS").orientation == .inverted180)
    }

    @Test("^A@ mit Schriftdatei, ^CW-Zuordnung, ^GS-Symbolschrift")
    func namedFonts() {
        #expect(text("^FO0,0^A@N,40,40,E:ARIAL.TTF^FDx^FS").fontName == "E:ARIAL.TTF")
        #expect(text("^FO0,0^A@N,40,40,arial.ttf^FDx^FS").fontName == "R:ARIAL.TTF")
        #expect(text("^FO0,0^A@N,40,40,E:SWISS^FDx^FS").fontName == "E:SWISS.FNT")
        let aliased = TestSupport.render("^XA^CWZ,E:MYFONT.TTF^FO0,0^AZN,30,30^FDx^FS^XZ")
        #expect(aliased.labels.first.map { TestSupport.texts($0).first?.fontName } == "E:MYFONT.TTF")
        #expect(aliased.allWarnings.isEmpty)
        let symbol = text("^FO0,0^GSN,40,40^FDABC^FS")
        #expect(symbol.fontName == "GS" && symbol.height == 40)
        // Nicht residente Schrift → Hinweis, Darstellung trotzdem
        let missing = TestSupport.render("^XA^FO0,0^AJN,30,30^FDx^FS^XZ")
        #expect(missing.labels.first.map { TestSupport.texts($0).count } == 1)
        #expect(missing.allWarnings.contains { $0.command == "^A" })
    }

    // MARK: Feldposition

    @Test("^FT setzt die Grundlinie: Ursprung = Grundlinie − 3/4 Höhe (Schrift 0)")
    func typesetVersusOrigin() {
        let origin = text("^FO100,200^A0N,40,40^FDHello^FS")
        let typeset = text("^FT100,200^A0N,40,40^FDHello^FS")
        #expect(origin.origin == LabelPoint(x: 100, y: 200))
        #expect(typeset.origin == LabelPoint(x: 100, y: 170))
        // Bitmap-Schrift D (Grundlinie 14 je Vergrößerungsstufe)
        let bitmap = text("^FT100,200^ADN,36,20^FDHello^FS")
        #expect(bitmap.origin == LabelPoint(x: 100, y: 172))
        // Gerastert: Großbuchstaben enden direkt über der Grundlinie
        let label = TestSupport.label("^XA^PW400^LL300^FT100,200^A0N,40,40^FDHEH^FS^XZ")
        let bounds = TestSupport.inkBounds(SoftwareRasterizer.rasterize(label))
        #expect(bounds.map { abs(($0.y + $0.height) - 200) <= 1 } == true)
        // linke Tintenkante = Stiftpunkt + Vorbreite des „H“ (wenige Punkte)
        #expect(bounds.map { $0.x >= 100 && $0.x <= 104 } == true)
    }

    @Test("^LH und ^LS verschieben Felder; ^FO-Ausrichtung rechts")
    func homeShiftAndJustification() {
        #expect(text("^LH30,40^FO10,20^A0N,30^FDx^FS").origin == LabelPoint(x: 40, y: 60))
        #expect(text("^LS10^FO50,20^A0N,30^FDx^FS").origin == LabelPoint(x: 40, y: 20))
        let right = text("^FO400,10,1^A0N,30,30^FDABC^FS")
        let width = TextLayout.fieldSize(of: right).0
        #expect(right.origin.x + width == 400)
        // ^LH bleibt über Formate hinweg erhalten
        let document = TestSupport.render("^XA^LH5,5^XZ^XA^FO0,0^A0N,20^FDx^FS^XZ")
        #expect(document.labels.first.map { TestSupport.texts($0).first?.origin } == LabelPoint(x: 5, y: 5))
    }

    @Test("^FT ohne Koordinaten setzt hinter dem vorigen Feld fort")
    func typesetContinuation() {
        let label = TestSupport.label("^XA^FT10,100^A0N,30,30^FDAB^FS^FT^A0N,30,30^FDCD^FS^XZ")
        let texts = TestSupport.texts(label)
        #expect(texts.count == 2)
        let firstWidth = TextLayout(element: texts[0], dotsPerMM: 8).endX
        #expect(texts[1].origin.y == texts[0].origin.y)
        #expect(abs(Double(texts[1].origin.x) - (10 + firstWidth)) <= 1)
    }

    // MARK: Drehung

    @Test("Drehgeometrie: Feldrechteck bleibt rechts unterhalb von ^FO")
    func rotationOrigin() {
        let normal = text("^FO100,100^A0N,40,40^FDHEH^FS")
        let size = TextLayout.fieldSize(of: normal)
        for orientation in ["R", "I", "B"] {
            let rotated = text("^FO100,100^A0\(orientation),40,40^FDHEH^FS")
            #expect(rotated.origin == LabelPoint(x: 100, y: 100))
            let box = LabelElement.text(rotated).boundingBox
            if orientation == "I" {
                #expect(box.width == size.0 && box.height == size.1)
            } else {
                #expect(box.width == size.1 && box.height == size.0)
            }
        }
    }

    @Test("Gerasterte Drehungen entsprechen der um 90°/180°/270° gedrehten Normalform")
    func rotationRaster() throws {
        let base = "^XA^PW600^LL600^FO100,100^A0%@,40,40^FDHEH^FS^XZ"
        let normalLabel = TestSupport.label(base.replacingOccurrences(of: "%@", with: "N"))
        let element = try #require(TestSupport.texts(normalLabel).first)
        let (w, h) = TextLayout.fieldSize(of: element)
        let normal = SoftwareRasterizer.rasterize(normalLabel).cropped(x: 100, y: 100, width: w, height: h)
        #expect(normal.blackPixelCount > 100)
        let turns: [(String, QuarterTurn)] = [("R", .r90), ("I", .r180), ("B", .r270)]
        for (code, turn) in turns {
            let label = TestSupport.label(base.replacingOccurrences(of: "%@", with: code))
            let swaps = turn != .r180
            let raster = SoftwareRasterizer.rasterize(label)
                .cropped(x: 100, y: 100, width: swaps ? h : w, height: swaps ? w : h)
            #expect(raster == normal.rotated(turn), "Ausrichtung \(code)")
            // Außerhalb des Feldrechtecks keine Tinte
            #expect(SoftwareRasterizer.rasterize(label).blackPixelCount == raster.blackPixelCount)
        }
    }

    @Test("^FT mit Drehung: Grundlinienanfang im gedrehten Koordinatensystem")
    func rotatedTypeset() {
        let normal = text("^FO0,0^A0N,40,40^FDHEH^FS")
        let width = TextLayout.fieldSize(of: normal).0
        // Grundlinie 30, Höhe 40
        #expect(text("^FT100,300^A0R,40,40^FDHEH^FS").origin == LabelPoint(x: 90, y: 300))
        #expect(text("^FT100,300^A0I,40,40^FDHEH^FS").origin == LabelPoint(x: 100 - width, y: 290))
        #expect(text("^FT100,300^A0B,40,40^FDHEH^FS").origin == LabelPoint(x: 70, y: 300 - width))
    }

    // MARK: Feldblock

    @Test("^FB: Wortumbruch, Zeilenabstand und Feldgröße (Schrift A, Vorschub 6)")
    func fieldBlockWrapping() throws {
        let element = text("^FO0,0^AAN,9,5^FB60,5,3,L,0^FDAAAA BBBB CCCC DDDD^FS")
        let block = try #require(element.block)
        #expect(block.width == 60 && block.maxLines == 5 && block.lineSpacing == 3)
        let layout = TextLayout(element: element, dotsPerMM: 8)
        #expect(layout.lineCount == 2)
        #expect(layout.width == 60)
        #expect(layout.height == 5 * 9 + 4 * 3)
        let firstC = try #require(layout.characters.first { $0.character == "C" })
        #expect(firstC.x == 0 && firstC.baseline == 19)   // Zeile 2: 9 + 3 + Grundlinie 7
        let firstB = try #require(layout.characters.first { $0.character == "B" })
        #expect(firstB.x == 30 && firstB.baseline == 7)
    }

    @Test("^FB: Ausrichtung L/C/R/J und hängender Einzug")
    func fieldBlockJustification() throws {
        func xs(_ fb: String, _ data: String) -> [Double] {
            let element = text("^FO0,0^AAN,9,5" + fb + "^FD" + data + "^FS")
            return TextLayout(element: element, dotsPerMM: 8).characters.map(\.x)
        }
        #expect(xs("^FB60,1,0,L", "AB") == [0, 6])
        #expect(xs("^FB60,1,0,C", "AB") == [24, 30])
        #expect(xs("^FB60,1,0,R", "AB") == [48, 54])
        // Blocksatz: erste Zeile gedehnt (60 − 42 = 18 Punkte im Wortabstand), letzte linksbündig
        let justified = xs("^FB60,2,0,J", "AAAA BB CCCC DD")
        #expect(Array(justified.prefix(6)) == [0, 6, 12, 18, 48, 54])
        #expect(Array(justified.suffix(6)) == [0, 6, 12, 18, 30, 36])
        // Hängender Einzug: ab der zweiten Zeile 12 Punkte, verfügbare Breite 48
        let element = text("^FO0,0^AAN,9,5^FB60,3,0,L,12^FDAAAAAAAA BBBBBBBB^FS")
        let layout = TextLayout(element: element, dotsPerMM: 8)
        #expect(layout.lineCount == 2)
        #expect(layout.characters.first { $0.character == "B" }?.x == 12)
    }

    @Test("^FB: \\& erzwingt Zeilenumbruch, \\\\ ist ein Backslash, lange Wörter werden geteilt")
    func fieldBlockSpecials() {
        let element = text("^FO0,0^AAN,9,5^FB60,4^FDAB\\&CD\\\\E^FS")
        let layout = TextLayout(element: element, dotsPerMM: 8)
        #expect(layout.lineCount == 2)
        #expect(layout.characters.map(\.character) == ["A", "B", "C", "D", "\\", "E"])
        #expect(layout.characters.map(\.baseline) == [7, 7, 16, 16, 16, 16])
        // Ohne ^FB bleibt \& Text
        let plain = text("^FO0,0^AAN,9,5^FDAB\\&CD^FS")
        #expect(TextLayout(element: plain, dotsPerMM: 8).characters.count == 6)
        // Wort länger als die Zeile
        let long = text("^FO0,0^AAN,9,5^FB60,3^FDABCDEFGHIJKLMNOP^FS")
        let longLayout = TextLayout(element: long, dotsPerMM: 8)
        #expect(longLayout.lineCount == 2)
        #expect(longLayout.characters.filter { $0.baseline == 7 }.count == 10)
    }

    @Test("^FB: Überlauf überdruckt die letzte Zeile (mit Hinweis), ^TB schneidet ab")
    func fieldBlockOverflow() {
        let document = TestSupport.render("^XA^FO0,0^AAN,9,5^FB30,2^FDAAAA BBBB CCCC^FS^XZ")
        let element = document.labels.first.flatMap { TestSupport.texts($0).first }
        let layout = element.map { TextLayout(element: $0, dotsPerMM: 8) }
        #expect(layout?.lineCount == 3)
        #expect(layout?.overflowLines == 1)
        #expect(layout?.characters.filter { $0.character == "C" }.allSatisfy { $0.baseline == 16 } == true)
        #expect(document.allWarnings.contains { $0.command == "^FB" })

        let truncated = text("^FO0,0^AAN,9,5^TBN,30,20^FDAAAA BBBB CCCC^FS")
        #expect(truncated.block?.truncatesOverflow == true)
        #expect(truncated.block?.maxLines == 2)
        let truncatedLayout = TextLayout(element: truncated, dotsPerMM: 8)
        #expect(!truncatedLayout.characters.contains { $0.character == "C" })
    }

    @Test("^FT mit ^FB: Grundlinie der letzten gedruckten Zeile")
    func fieldBlockTypeset() {
        let element = text("^FT0,100^AAN,9,5^FB60,4,0^FDAAAA BBBB CCCC DDDD^FS")
        // zwei Zeilen: letzte Grundlinie bei 9 + 7 = 16 → Ursprung 100 − 16
        #expect(element.origin == LabelPoint(x: 0, y: 84))
    }

    @Test("^FB mit Breite 0 druckt nicht (Hinweis)")
    func fieldBlockZeroWidth() {
        let document = TestSupport.render("^XA^FO0,0^A0N,30^FB0,2^FDText^FS^XZ")
        #expect(document.labels.first?.elements.isEmpty == true)
        #expect(document.allWarnings.contains { $0.command == "^FB" })
    }

    // MARK: Feldparameter

    @Test("^FP: senkrechte und rückwärtige Schreibrichtung, Zeichenabstand")
    func fieldParameter() {
        let vertical = text("^FO10,10^AAN,9,5^FPV,2^FDABC^FS")
        #expect(vertical.direction == .vertical && vertical.characterGap == 2)
        let size = TextLayout.fieldSize(of: vertical)
        #expect(size.1 == 3 * 9 + 2 * 2)
        let reverse = text("^FO10,10^AAN,9,5^FPR^FDABC^FS")
        let positions = TextLayout(element: reverse, dotsPerMM: 8).characters.map { ($0.character, $0.x) }
        #expect(positions.map(\.0) == ["A", "B", "C"])
        #expect(positions.map(\.1) == [12, 6, 0])
        let gap = text("^FO10,10^AAN,9,5^FPH,4^FDABC^FS")
        #expect(TextLayout.fieldSize(of: gap).0 == 3 * (6 + 4))
    }

    // MARK: Felddaten

    @Test("^FH dekodiert Hexbytes gemäß ^CI")
    func hexadecimalFieldData() {
        #expect(text("^FO0,0^A0N,30^FH^FDA_5E_7EB^FS").text == "A^~B")
        #expect(text("^FO0,0^A0N,30^FH#^FD#41#42_5E^FS").text == "AB_5E")
        #expect(text("^CI28^FO0,0^A0N,30^FH^FD_C3_A4_E2_82_AC^FS").text == "ä€")
        #expect(text("^CI27^FO0,0^A0N,30^FH^FD_80_E4^FS").text == "€ä")
        #expect(text("^CI0^FO0,0^A0N,30^FH^FD_84_E1^FS").text == "äß")
        // Ungültiges UTF-8 fällt auf Windows-1252 zurück; unvollständige Escapes bleiben stehen
        #expect(text("^CI28^FO0,0^A0N,30^FH^FD_E4_G1_4^FS").text == "ä_G1_4")
    }

    @Test("UTF-8-Text bleibt erhalten; leere Felder erzeugen kein Element")
    func unicodeAndEmpty() {
        #expect(text("^CI28^FO0,0^A0N,30^FDGrüße aus München – 25 €^FS").text == "Grüße aus München – 25 €")
        let empty = TestSupport.render("^XA^FO10,10^A0N,30^FD^FS^XZ")
        #expect(empty.labels.count == 1)
        #expect(empty.labels.first?.elements.isEmpty == true)
        // Format ohne Felder druckt nichts
        #expect(TestSupport.render("^XA^MMT^PW600^JUS^XZ").labels.isEmpty)
    }

    @Test("^FR und ^LR setzen den Umkehrmodus")
    func reverse() {
        #expect(text("^FO0,0^A0N,30^FR^FDx^FS").reverse)
        let document = TestSupport.render("^XA^LRY^FO0,0^A0N,30^FDa^FS^LRN^FO0,40^A0N,30^FDb^FS^XZ")
        let texts = document.labels.first.map(TestSupport.texts) ?? []
        #expect(texts.map(\.reverse) == [true, false])
    }
}

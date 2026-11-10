import Foundation
import Testing
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging
@testable import LabelWerkRender

@Suite("SoftwareRasterizer")
struct RasterizerTests {

    private func raster(_ body: String, width: Int = 60, height: Int = 50) -> MonoBitmap {
        let label = TestSupport.label("^XA^PW\(width)^LL\(height)" + body + "^XZ")
        return SoftwareRasterizer.rasterize(label)
    }

    private func expected(width: Int, height: Int, _ isBlack: (Int, Int) -> Bool) -> MonoBitmap {
        MonoBitmap(width: width, height: height, isBlack: isBlack)
    }

    // MARK: Rechtecke

    @Test("Rahmen ^GB: pixelgenau")
    func boxFrame() {
        let bitmap = raster("^FO10,20^GB30,20,3^FS")
        let reference = expected(width: 60, height: 50) { x, y in
            guard (10..<40).contains(x), (20..<40).contains(y) else { return false }
            return x < 13 || x >= 37 || y < 23 || y >= 37
        }
        #expect(bitmap == reference)
        #expect(bitmap.blackPixelCount == 30 * 20 - 24 * 14)
    }

    @Test("Volle Fläche, waagerechte und senkrechte Linien")
    func filledAndLines() {
        #expect(raster("^FO5,5^GB30,4,3^FS") == expected(width: 60, height: 50) { x, y in
            (5..<35).contains(x) && (5..<9).contains(y)
        })
        #expect(raster("^FO0,10^GB60,0,2^FS") == expected(width: 60, height: 50) { _, y in (10..<12).contains(y) })
        #expect(raster("^FO7,0^GB0,50,3^FS") == expected(width: 60, height: 50) { x, _ in (7..<10).contains(x) })
    }

    @Test("Weiße Linienfarbe löscht, ^FR invertiert (XOR), Überlappung im Feld hebt sich nicht auf")
    func colorAndReverse() {
        let hole = raster("^FO0,0^GB40,40,40^FS^FO10,10^GB20,20,20,W^FS")
        #expect(hole == expected(width: 60, height: 50) { x, y in
            (0..<40).contains(x) && (0..<40).contains(y) && !((10..<30).contains(x) && (10..<30).contains(y))
        })
        let xor = raster("^FO0,0^GB20,10,10^FS^FO10,0^FR^GB20,10,10^FS")
        #expect(xor == expected(width: 60, height: 50) { x, y in
            y < 10 && ((0..<10).contains(x) || (20..<30).contains(x))
        })
        // Ein invertierter Rahmen mit Ecküberlappungen ergibt denselben Rahmen wie ein normaler.
        #expect(raster("^FO10,20^FR^GB30,20,3^FS") == raster("^FO10,20^GB30,20,3^FS"))
        // ^LR kehrt alle Felder um: auf Weiß wirkt das erste Feld schwarz, das zweite überlappend XOR.
        #expect(raster("^LRY^FO0,0^GB20,10,10^FS^FO10,0^GB20,10,10^FS^LRN") == xor)
    }

    @Test("Abgerundete Rahmen: symmetrisch, Ecken frei")
    func roundedBox() {
        let bitmap = raster("^FO10,10^GB40,30,4,B,8^FS")
        #expect(!bitmap[10, 10] && !bitmap[49, 10] && !bitmap[10, 39] && !bitmap[49, 39])
        #expect(bitmap[30, 10] && bitmap[10, 25] && bitmap[49, 25] && bitmap[30, 39])
        #expect(!bitmap[30, 25])
        let cropped = bitmap.cropped(x: 10, y: 10, width: 40, height: 30)
        #expect(cropped == cropped.mirrored())
        #expect(cropped == cropped.rotated180())
        // Rundung 0 bleibt eckig
        #expect(raster("^FO10,10^GB40,30,4,B,0^FS")[10, 10])
    }

    // MARK: Ellipsen und Diagonalen

    @Test("Kreis und Ellipse: Fläche, Symmetrie, Ring")
    func ellipses() {
        let disc = raster("^FO0,0^GC100,60^FS", width: 120, height: 120)
        let area = Double(disc.blackPixelCount)
        #expect(abs(area - Double.pi * 50 * 50) / (Double.pi * 50 * 50) < 0.02)
        let crop = disc.cropped(x: 0, y: 0, width: 100, height: 100)
        #expect(crop == crop.mirrored())
        #expect(crop == crop.rotated180())
        #expect(crop == crop.rotated(.r90))

        let ring = raster("^FO0,0^GC100,5^FS", width: 120, height: 120)
        #expect(!ring[50, 50])
        #expect(ring[50, 1] && ring[1, 50] && ring[98, 50] && ring[50, 98])
        let ringArea = Double(ring.blackPixelCount)
        let expectedRing = Double.pi * (50 * 50 - 45 * 45)
        #expect(abs(ringArea - expectedRing) / expectedRing < 0.05)

        let ellipse = raster("^FO10,20^GE80,40,40^FS", width: 120, height: 120)
        let bounds = TestSupport.inkBounds(ellipse)
        #expect(bounds.map { $0 == (10, 20, 80, 40) } == true)
    }

    @Test("Diagonalen: Neigung, Endpunkte und Spiegelsymmetrie")
    func diagonals() {
        let right = raster("^FO0,0^GD50,50,5,B,R^FS")
        #expect(right[47, 0] && right[2, 49])
        #expect(!right[2, 0] && !right[47, 49])
        let left = raster("^FO0,0^GD50,50,5,B,L^FS")
        #expect(left[2, 0] && left[47, 49])
        let difference = zip(left.cropped(x: 0, y: 0, width: 50, height: 50).data,
                             right.cropped(x: 0, y: 0, width: 50, height: 50).mirrored().data)
            .reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        #expect(difference <= 50)
        // Jede Zeile enthält Tinte (keine Lücken), auch bei flachen Linien
        let flat = raster("^FO0,0^GD60,10,2^FS")
        for y in 0..<10 { #expect(!flat.isRowBlank(y)) }
        for x in 0..<60 { #expect((0..<10).contains { flat[x, $0] }, "Spalte \(x) ohne Tinte") }
    }

    // MARK: Grafiken

    @Test("Grafik mit Vergrößerung und Umkehrung")
    func graphics() {
        let source = TestSupport.bitmap(["#.", ".#"])
        let encoded = ZPLGraphicEncoder.graphicField(source, compression: .hex)
        let bitmap = raster("^FO4,6" + encoded + "^FS")
        #expect(bitmap[4, 6] && !bitmap[5, 6] && !bitmap[4, 7] && bitmap[5, 7])
        let magnified = raster(ZPLGraphicEncoder.downloadGraphic(name: "P", bitmap: source) + "^FO10,10^XGR:P.GRF,3,2^FS")
        #expect(TestSupport.rows(magnified, x: 10, y: 10, width: 6, height: 4) == ["###...", "###...", "...###", "...###"])
        let reversed = raster("^FO0,0^GB20,20,20^FS^FO0,0^FR" + encoded + "^FS")
        #expect(!reversed[0, 0] && reversed[1, 0] && reversed[0, 1] && !reversed[1, 1])
    }

    // MARK: Text

    @Test("Text aller Schriften rendert sichtbar und bleibt in seinem Feld", arguments: [
        "^A0N,40,40", "^A0N,12,12", "^AAN,9,5", "^ABN,22,14", "^ACN,18,10", "^ADN,36,20", "^AEN,28,15",
        "^AFN,26,13", "^AGN,60,40", "^AHN,21,13", "^APN", "^AVN", "^A@N,30,30,E:ARIAL.TTF", "^AJN,30,30",
    ])
    func textWithinBounds(font: String) throws {
        let label = TestSupport.label("^XA^PW800^LL300^FO40,60" + font + "^FDHello 123^FS^XZ")
        let element = try #require(TestSupport.texts(label).first)
        let box = LabelElement.text(element).boundingBox
        let bitmap = SoftwareRasterizer.rasterize(label)
        let ink = try #require(TestSupport.inkBounds(bitmap))
        #expect(bitmap.blackPixelCount > 20)
        let tolerance = max(2, element.height / 4)
        #expect(ink.x >= box.x - tolerance && ink.y >= box.y - tolerance)
        #expect(ink.x + ink.width <= box.x + box.width + tolerance)
        #expect(ink.y + ink.height <= box.y + box.height + tolerance)
        // Text füllt sein Feld weitgehend aus
        #expect(ink.width >= box.width / 2 && ink.height >= box.height / 3)
    }

    @Test("Umlaute, ß, €, fehlende Zeichen (Ersatzrechteck) und Zerlegung (ǒ → o)")
    func specialCharacters() {
        for text in ["ÄÖÜäöüß€", "漢", "ǒ", "ő"] {
            let bitmap = raster("^CI28^FO5,5^A0N,40,40^FD\(text)^FS", width: 400, height: 80)
            #expect(bitmap.blackPixelCount > 30, "\(text)")
        }
        // ǒ (nicht im Glyphenvorrat) wird über die kanonische Zerlegung als o gezeichnet
        let decomposed = raster("^CI28^FO5,5^A0N,40,40^FDǒ^FS", width: 100, height: 80)
        let plain = raster("^FO5,5^A0N,40,40^FDo^FS", width: 100, height: 80)
        #expect(decomposed == plain)
        // ő hat eine eigene Glyphe (Latin Extended-A)
        #expect(raster("^CI28^FO5,5^A0N,40,40^FDő^FS", width: 100, height: 80) != plain)
    }

    @Test("Schrift B druckt Kleinbuchstaben als Großbuchstaben")
    func uppercaseOnlyFont() {
        #expect(raster("^FO5,5^ABN,22,14^FDabc^FS", width: 200) == raster("^FO5,5^ABN,22,14^FDABC^FS", width: 200))
    }

    @Test("Größere Schrift ergibt proportional größere Glyphen")
    func textScaling() throws {
        let small = try #require(TestSupport.inkBounds(raster("^FO0,0^A0N,40,40^FDH^FS", width: 300, height: 300)))
        let large = try #require(TestSupport.inkBounds(raster("^FO0,0^A0N,160,160^FDH^FS", width: 300, height: 300)))
        #expect(abs(Double(large.height) / Double(small.height) - 4) < 0.25)
        let wide = try #require(TestSupport.inkBounds(raster("^FO0,0^A0N,40,80^FDH^FS", width: 300, height: 300)))
        #expect(abs(Double(wide.width) / Double(small.width) - 2) < 0.3)
        #expect(abs(wide.height - small.height) <= 1)
    }

    @Test("Sehr große Schrift wird nur im sichtbaren Bereich gerastert")
    func hugeText() {
        let start = Date()
        let bitmap = raster("^FO0,0^A0N,32000,32000^FDW^FS", width: 300, height: 300)
        #expect(Date().timeIntervalSince(start) < 20)
        #expect(bitmap.width == 300)
    }

    // MARK: Barcodes

    @Test("Linearer Barcode: Balken entsprechen BarcodeRasterizer, Klarschrift unter den Balken")
    func linearBarcodeRaster() throws {
        let label = TestSupport.label("^XA^PW600^LL300^BY2^FO20,30^BCN,100,Y,N^FDLabelWerk^FS^XZ")
        let element = try #require(TestSupport.linearBarcodes(label).first)
        let bitmap = SoftwareRasterizer.rasterize(label)
        let reference = BarcodeRasterizer.render(element.barcode, moduleWidth: 2, ratio: 3, height: 1, quietZone: 0)
        for row in [30, 80, 129] {
            for x in 0..<reference.width where bitmap[20 + x, row] != reference.pixels[x] {
                Issue.record("Zeile \(row), x \(x) weicht ab")
                return
            }
        }
        #expect(bitmap.isRowBlank(29) && bitmap.isRowBlank(130))
        // Klarschrift im Bereich 132…150
        #expect(TestSupport.blackCount(bitmap, x: 0, y: 132, width: 600, height: 18) > 50)
        #expect(TestSupport.inkBounds(bitmap).map { $0.y + $0.height <= 150 } == true)
    }

    @Test("2D-Code: Modulmittelpunkte entsprechen der Matrix, gedreht wie die Matrix")
    func matrixRaster() throws {
        let label = TestSupport.label("^XA^PW400^LL400^FO30,40^BXN,6,200^FDDrehtest^FS^FO200,40^BXR,6,200^FDDrehtest^FS^XZ")
        let elements = TestSupport.matrixBarcodes(label)
        let matrix = try #require(elements.first?.matrix)
        let bitmap = SoftwareRasterizer.rasterize(label)
        let size = matrix.width * 6
        let normal = bitmap.cropped(x: 30, y: 40, width: size, height: size)
        for my in 0..<matrix.height {
            for mx in 0..<matrix.width where normal[mx * 6 + 3, my * 6 + 3] != matrix[mx, my] {
                Issue.record("Modul (\(mx), \(my)) weicht ab")
                return
            }
        }
        #expect(normal.blackPixelCount == matrix.darkCount * 36)
        #expect(bitmap.cropped(x: 200, y: 40, width: size, height: size) == normal.rotated(.r90))
    }

    // MARK: Etikett

    @Test("^POI dreht, ^PMY spiegelt das fertige Bild; Formatkoordinaten optional")
    func printTransforms() throws {
        let body = "^FO10,5^GB20,10,10^FS^FO40,30^A0N,20^FDAB^FS"
        let plain = raster(body)
        let inverted = TestSupport.label("^XA^PW60^LL50^POI" + body + "^XZ")
        #expect(inverted.inverted)
        #expect(SoftwareRasterizer.rasterize(inverted) == plain.rotated180())
        #expect(SoftwareRasterizer.rasterize(inverted, applyingPrintTransforms: false) == plain)
        let mirrored = TestSupport.label("^XA^PW60^LL50^PON^PMY" + body + "^XZ")
        #expect(mirrored.mirrored)
        #expect(SoftwareRasterizer.rasterize(mirrored) == plain.mirrored())
    }

    @Test("Elemente außerhalb des Etiketts werden abgeschnitten; Größe = ^PW × ^LL")
    func clipping() {
        let bitmap = raster("^FO50,40^GB100,100,100^FS^FT0,5^A0N,60,60^FDClip^FS^FO55,0^BCR,100^FD123^FS")
        #expect(bitmap.width == 60 && bitmap.height == 50)
        #expect(bitmap[59, 49] && bitmap[50, 40])
        let empty = SoftwareRasterizer.rasterize(RenderedLabel(widthDots: 0, heightDots: 0))
        #expect(empty.width == 0 && empty.height == 0)
    }

    @Test("Einzelelement rastern und Determinismus")
    func singleElementAndDeterminism() {
        let element = LabelElement.box(BoxElement(origin: LabelPoint(x: 1, y: 1), width: 3, height: 2, thickness: 2))
        let bitmap = SoftwareRasterizer.rasterize(element, widthDots: 5, heightDots: 4)
        #expect(TestSupport.rows(bitmap) == [".....", ".###.", ".###.", "....."])
        let label = TestSupport.label(Samples.graphics)
        #expect(SoftwareRasterizer.rasterize(label) == SoftwareRasterizer.rasterize(label))
    }
}

import Foundation
import Testing
import LabelWerkCore
import LabelWerkImaging
@testable import LabelWerkRender

@Suite("ZPLInterpreter – Grafiken und gespeicherte Objekte")
struct InterpreterGraphicsTests {

    /// Deterministische Testbitmap mit unregelmäßigem Muster.
    private func pattern(width: Int, height: Int, seed: UInt64) -> MonoBitmap {
        var random = TestSupport.Random(seed: seed)
        var bitmap = MonoBitmap(width: width, height: height)
        for y in 0..<height {
            // Leerzeilen und wiederholte Zeilen testen die ACS-Sonderzeichen.
            if y % 7 == 3 { continue }
            if y % 5 == 4 && y > 0 {
                for x in 0..<width { bitmap[x, y] = bitmap[x, y - 1] }
                continue
            }
            for x in 0..<width where random.next() % 3 == 0 { bitmap[x, y] = true }
        }
        return bitmap
    }

    // MARK: Formen

    @Test("^GB, ^GC, ^GE, ^GD werden mit Standardwerten übernommen")
    func shapes() {
        let label = TestSupport.label("""
        ^XA
        ^FO10,20^GB100,50,3^FS
        ^FO10,80^GB0,60,4,W^FS
        ^FO10,150^GB^FS
        ^FO200,20^GC80,5,B^FS
        ^FO200,120^GE120,60,2^FS
        ^FO400,20^GD100,50,4,B,L^FS
        ^FO400,100^GD100,50^FS
        ^FO500,20^GB60,60,2,B,5^FS
        ^XZ
        """)
        #expect(label.elements == [
            .box(BoxElement(origin: LabelPoint(x: 10, y: 20), width: 100, height: 50, thickness: 3)),
            .box(BoxElement(origin: LabelPoint(x: 10, y: 80), width: 4, height: 60, thickness: 4, color: .white)),
            .box(BoxElement(origin: LabelPoint(x: 10, y: 150), width: 1, height: 1, thickness: 1)),
            .ellipse(EllipseElement(origin: LabelPoint(x: 200, y: 20), width: 80, height: 80, thickness: 5)),
            .ellipse(EllipseElement(origin: LabelPoint(x: 200, y: 120), width: 120, height: 60, thickness: 2)),
            .diagonal(DiagonalElement(origin: LabelPoint(x: 400, y: 20), width: 100, height: 50, thickness: 4,
                                      leansRight: false)),
            .diagonal(DiagonalElement(origin: LabelPoint(x: 400, y: 100), width: 100, height: 50, thickness: 1)),
            .box(BoxElement(origin: LabelPoint(x: 500, y: 20), width: 60, height: 60, thickness: 2, rounding: 5)),
        ])
        #expect(label.warnings.isEmpty)
    }

    @Test("^FT setzt bei Grafiken die linke untere Ecke; ^FR kehrt um")
    func typesetGraphics() {
        let label = TestSupport.label("^XA^FT10,120^GB100,50,3^FS^FO0,0^FR^GB10,10,10^FS^XZ")
        #expect(TestSupport.boxes(label).map(\.origin) == [LabelPoint(x: 10, y: 70), LabelPoint(x: 0, y: 0)])
        #expect(TestSupport.boxes(label).map(\.reverse) == [false, true])
    }

    @Test("Mehrere Grafiken ohne ^FS: das Feld wird beim nächsten ^FO abgeschlossen")
    func implicitCompletion() {
        let document = TestSupport.render("^XA^FO10,10^GB20,20,2^FO50,50^GB30,30,3^FS^XZ")
        let boxes = document.labels.first.map(TestSupport.boxes) ?? []
        #expect(boxes.map(\.origin) == [LabelPoint(x: 10, y: 10), LabelPoint(x: 50, y: 50)])
        #expect(document.allWarnings.contains { $0.command == "^FS" })
    }

    // MARK: ^GF

    @Test("^GF-Rundreise: Hex, ACS und Z64 (Encoder → Interpreter → Rasterizer)", arguments: GraphicCompression.allCases)
    func graphicFieldRoundTrip(compression: GraphicCompression) throws {
        let original = pattern(width: 45, height: 37, seed: 0x5EED + UInt64(compression.rawValue.count))
        let zpl = "^XA^PW200^LL120^FO15,25" + ZPLGraphicEncoder.graphicField(original, compression: compression) + "^FS^XZ"
        let label = TestSupport.label(zpl)
        let graphic = try #require(TestSupport.graphics(label).first)
        #expect(graphic.origin == LabelPoint(x: 15, y: 25))
        #expect(graphic.bitmap.width == original.bytesPerRow * 8)
        #expect(graphic.bitmap.height == original.height)
        #expect(graphic.bitmap.cropped(x: 0, y: 0, width: original.width, height: original.height) == original)
        let raster = SoftwareRasterizer.rasterize(label)
        #expect(raster.cropped(x: 15, y: 25, width: original.width, height: original.height) == original)
        #expect(raster.blackPixelCount == original.blackPixelCount)
        #expect(label.warnings.isEmpty)
    }

    @Test("^GF im Binärformat B (Bytes dürfen ^ und ~ enthalten)")
    func binaryGraphicField() throws {
        let bytes: [UInt8] = [0x5E, 0x7E, 0x0D, 0x0A, 0xFF, 0x00, 0x81, 0x18]
        let original = MonoBitmap(width: 16, height: 4, data: bytes)
        let payload = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        let label = TestSupport.label("^XA^FO5,6^GFB,8,8,2,\(payload)^FS^FO0,50^A0N,20^FDdanach^FS^XZ")
        let graphic = try #require(TestSupport.graphics(label).first)
        #expect(graphic.bitmap == original)
        #expect(TestSupport.texts(label).first?.text == "danach")
    }

    @Test("Ungültige ^GF-Angaben erzeugen Hinweise statt Abbruch")
    func invalidGraphicField() {
        let document = TestSupport.render("^XA^FO0,0^GFA,10^FS^FO0,0^GFC,4,4,1,ABCD^FS^FO0,0^GFA,4,4,1,ZZ!!^FS^XZ")
        #expect(document.allWarnings.filter { $0.command == "^GF" }.count >= 2)
    }

    // MARK: ~DG / ^XG / ^IM

    @Test("~DG speichert, ^XG ruft mit Vergrößerung ab (Rasterung blockweise)")
    func downloadAndRecall() throws {
        let original = pattern(width: 24, height: 10, seed: 42)
        let zpl = ZPLGraphicEncoder.downloadGraphic(name: "logo", drive: "R:", bitmap: original)
            + "\n^XA^PW300^LL200^FO50,60^XGR:LOGO.GRF,2,3^FS^XZ"
        let document = TestSupport.render(zpl)
        #expect(document.storedGraphics["R:LOGO.GRF"] == original)
        let label = try #require(document.labels.first)
        let graphic = try #require(TestSupport.graphics(label).first)
        #expect(graphic.magnificationX == 2 && graphic.magnificationY == 3)
        #expect(LabelElement.graphic(graphic).boundingBox == (50, 60, 48, 30))
        let raster = SoftwareRasterizer.rasterize(label)
        for y in 0..<original.height {
            for x in 0..<original.width {
                for dy in 0..<3 {
                    for dx in 0..<2 where raster[50 + 2 * x + dx, 60 + 3 * y + dy] != original[x, y] {
                        Issue.record("Abweichung bei Quellpunkt (\(x), \(y))")
                        return
                    }
                }
            }
        }
        #expect(raster.blackPixelCount == original.blackPixelCount * 6)
    }

    @Test("^XG/^IM: Standardlaufwerk R:, Suche auf anderen Laufwerken, fehlende Grafik")
    func recallLookup() {
        let bitmap = pattern(width: 8, height: 4, seed: 7)
        let download = ZPLGraphicEncoder.downloadGraphic(name: "BOX", drive: "E:", bitmap: bitmap)
        let document = TestSupport.render(download + """
        ^XA^FO0,0^XGBOX.GRF^FS^FO20,0^IME:BOX.GRF^FS^FO40,0^XGR:NOPE.GRF,1,1^FS^XZ
        """)
        let graphics = document.labels.first.map(TestSupport.graphics) ?? []
        #expect(graphics.count == 2)
        #expect(graphics.allSatisfy { $0.bitmap == bitmap && $0.magnificationX == 1 })
        #expect(document.allWarnings.contains { $0.command == "^XG" && $0.message.contains("R:NOPE.GRF") })
    }

    @Test("~DG mit ACS-Daten (Kommas in den Daten)")
    func downloadACS() {
        var bitmap = MonoBitmap(width: 32, height: 6)
        for x in 0..<12 { bitmap[x, 0] = true; bitmap[x, 1] = true }
        for x in 0..<32 { bitmap[x, 4] = true }
        let acs = ACS.encode(bitmap)
        #expect(acs.contains(",") || acs.contains(":") || acs.contains("!"))
        let document = TestSupport.render("~DGR:ACS.GRF,\(bitmap.data.count),\(bitmap.bytesPerRow),\(acs)")
        #expect(document.storedGraphics["R:ACS.GRF"] == bitmap)
    }

    @Test("~DY lädt GRF (hex und binär) und PNG")
    func downloadObject() throws {
        let bitmap = pattern(width: 16, height: 8, seed: 99)
        let hex = bitmap.data.map { String(format: "%02X", $0) }.joined()
        let binary = String(String.UnicodeScalarView(bitmap.data.map { Unicode.Scalar($0) }))
        let png = PNGCodec.encode(bitmap)
        let pngHex = png.map { String(format: "%02X", $0) }.joined()
        let document = TestSupport.render("""
        ~DYE:HEXLOGO,A,G,\(bitmap.data.count),\(bitmap.bytesPerRow),\(hex)
        ~DYE:BINLOGO,B,G,\(bitmap.data.count),\(bitmap.bytesPerRow),\(binary)
        ~DYE:PICTURE,A,P,\(png.count),0,\(pngHex)
        ~DYE:PICB64,P,P,\(png.count),0,:B64:\(png.base64EncodedString()):0000
        ~DYE:FONT,B,T,4,0,ABCD
        ^XA^FO0,0^XGE:PICTURE.PNG,1,1^FS^XZ
        """)
        #expect(document.storedGraphics["E:HEXLOGO.GRF"] == bitmap)
        #expect(document.storedGraphics["E:BINLOGO.GRF"] == bitmap)
        #expect(document.storedGraphics["E:PICTURE.PNG"] == bitmap)
        #expect(document.storedGraphics["E:PICB64.PNG"] == bitmap)
        #expect(document.storedGraphics.count == 4)
        let graphic = try #require(document.labels.first.flatMap { TestSupport.graphics($0).first })
        #expect(graphic.bitmap == bitmap)
        #expect(document.allWarnings.isEmpty)
    }

    @Test("^ID und ~EG löschen gespeicherte Grafiken (mit Platzhaltern)")
    func deleteObjects() {
        let a = ZPLGraphicEncoder.downloadGraphic(name: "A", drive: "R:", bitmap: MonoBitmap(width: 8, height: 1))
        let b = ZPLGraphicEncoder.downloadGraphic(name: "B", drive: "R:", bitmap: MonoBitmap(width: 8, height: 1))
        let c = ZPLGraphicEncoder.downloadGraphic(name: "C", drive: "E:", bitmap: MonoBitmap(width: 8, height: 1))
        #expect(Set(TestSupport.render(a + b + c + "^XA^IDR:A.GRF^XZ").storedGraphics.keys) == ["R:B.GRF", "E:C.GRF"])
        #expect(Set(TestSupport.render(a + b + c + "^XA^IDR:*.*^XZ").storedGraphics.keys) == ["E:C.GRF"])
        #expect(TestSupport.render(a + b + c + "~EG").storedGraphics.isEmpty)
    }

    @Test("^IS speichert das Etikettenbild, ^IL lädt es in ein späteres Format")
    func saveAndLoadImage() throws {
        let document = TestSupport.render("""
        ^XA^FO10,10^GB50,50,50^FS^ISR:BG.GRF,N^XZ
        ^XA^ILR:BG.GRF^FO100,100^A0N,30^FDText^FS^XZ
        ^XA^FO200,0^XGR:BG.GRF,1,1^FS^XZ
        """)
        #expect(document.labels.count == 2)
        let first = try #require(document.labels.first)
        #expect(first.elements.count == 2)
        #expect(TestSupport.boxes(first).first?.origin == LabelPoint(x: 10, y: 10))
        let second = try #require(document.labels.last)
        #expect(TestSupport.boxes(second).first?.origin == LabelPoint(x: 210, y: 10))
    }

    @Test("^MCN: Feste Felder bleiben für das nächste Etikett erhalten, ^FV-Felder nicht")
    func mapClear() throws {
        let document = TestSupport.render("""
        ^XA^MCN^FO0,0^GB10,10,10^FS^FO0,20^A0N,20^FVvariabel^FS^XZ
        ^XA^FO50,50^GB5,5,5^FS^XZ
        ^XA^MCY^FO70,70^GB5,5,5^FS^XZ
        ^XA^FO90,90^GB5,5,5^FS^XZ
        """)
        #expect(document.labels.count == 4)
        let second = try #require(document.labels.dropFirst().first)
        #expect(TestSupport.boxes(second).count == 2)
        #expect(TestSupport.texts(second).isEmpty)
        // ^MCY im dritten Format: das vierte beginnt leer.
        #expect(document.labels.last?.elements.count == 1)
    }
}

import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// „An Etikett anpassen“ (ARCHITECTURE.md §8 „F“): Entscheidung, Inhaltsrahmen, Zielgröße,
/// Flächenmittel gegen die Definition, Einsetzen und der Weg durch den `JobEncoder`. Die
/// byte-genaue Übereinstimmung mit C-Filter und Python-Referenz prüft
/// Scripts/tests/test_encoder_conformance.py.
@Suite("An Etikett anpassen (LabelFit)")
struct LabelFitTests {

    /// 104 × 76,2 mm wie der ZD421 mit ZDesigner.
    static var label: PrintSettings {
        var s = PrintSettings()
        s.setLabelSize(widthMM: 104, heightMM: 76.2)
        return s
    }

    @Test("Punkte → 1/100 mm wie C/Python (double, dann abrunden)")
    func pointsConversion() {
        #expect(LabelFit.hundredthsMM(fromPoints: 595) == 20990)
        #expect(LabelFit.hundredthsMM(fromPoints: 842) == 29704)
        #expect(LabelFit.hundredthsMM(fromPoints: 295) == 10407)
        #expect(LabelFit.hundredthsMM(fromPoints: 216) == 7620)
        #expect(LabelFit.hundredthsMM(fromPoints: 0) == nil)
        #expect(LabelFit.hundredthsMM(fromPoints: -3) == nil)
        #expect(LabelFit.hundredthsMM(fromPoints: .nan) == nil)
        #expect(LabelFit.hundredthsMM(fromPoints: 100_001) == nil)
        #expect(LabelFit.hundredthsMM(fromPoints: PageSizePoints.a4.width) == 21000)
        #expect(LabelFit.hundredthsMM(fromPoints: PageSizePoints.a4.height) == 29700)
    }

    @Test("Entscheidung: A4/Letter → Etikett, passende Größe (± 2 mm), Off, unbekannt, Drehung, Endlos")
    func plan() {
        let s = Self.label
        func plan(_ settings: PrintSettings, _ page: PageSizePoints?, dpi: Int = 203) -> LabelFit.Plan? {
            LabelFit.plan(settings: settings, pageSize: page, xDPI: dpi, yDPI: dpi, imageWidth: 10, imageHeight: 10)
        }
        #expect(plan(s, .a4) == LabelFit.Plan(width: 831, height: 609))
        #expect(plan(s, .letter) == LabelFit.Plan(width: 831, height: 609))
        #expect(plan(s, .a4, dpi: 300) == LabelFit.Plan(width: 1228, height: 900))
        #expect(plan(s, PageSizePoints(width: 295, height: 216)) == nil, "w295h216 = Etikett")
        #expect(plan(s, PageSizePoints(width: 299, height: 220)) == nil, "≤ 2 mm Abweichung")
        #expect(plan(s, PageSizePoints(width: 295, height: 222)) != nil, "2,1 mm zu lang")
        #expect(plan(s, nil) == nil)
        #expect(plan(PrintSettings(), .a4) == nil, "ohne Etikettengröße wie bisher")
        var off = s
        off.fitToLabel = .off
        #expect(plan(off, .a4) == nil)
        var rotated = s
        rotated.rotation = .r90
        #expect(plan(rotated, PageSizePoints(width: 216, height: 295)) == nil, "quer liegende Seite passt")
        #expect(plan(rotated, .a4) == LabelFit.Plan(width: 609, height: 831))
        var continuous = s
        continuous.tracking = .continuous
        #expect(plan(continuous, PageSizePoints(width: 295, height: 842)) == nil, "Länge frei, Breite passt")
        #expect(plan(continuous, .a4) == LabelFit.Plan(width: 831, height: nil))
        #expect(LabelFit.plan(settings: s, pageSize: .a4, xDPI: 0, yDPI: 203, imageWidth: 10, imageHeight: 10) == nil)
        #expect(LabelFit.plan(settings: s, pageSize: .a4, xDPI: 203, yDPI: 203, imageWidth: 0, imageHeight: 10) == nil)
        var huge = PrintSettings()
        huge.setLabelSize(widthMM: 1000, heightMM: 1000)
        #expect(plan(huge, .a4, dpi: 1200) == nil, "mehr als 32000 Punkte")
    }

    @Test("Inhaltsrahmen: L < 250, leere Seite → nil")
    func bounds() {
        var image = GrayImage(width: 10, height: 10)
        #expect(LabelFit.contentBounds(image) == nil)
        image[9, 8] = 250
        #expect(LabelFit.contentBounds(image) == nil, "250 ist kein Inhalt")
        image[1, 5] = 0
        image[4, 5] = 100
        image[2, 7] = 249
        let b = LabelFit.contentBounds(image)
        #expect(b?.x == 1 && b?.y == 5 && b?.width == 4 && b?.height == 3)
    }

    @Test("Zielgröße: nie vergrößern, Seitenverhältnis, freie Seite")
    func targetSize() {
        func size(_ w: Int, _ h: Int, _ plan: LabelFit.Plan) -> [Int] {
            let s = LabelFit.targetSize(contentWidth: w, contentHeight: h, plan: plan)
            return [s.width, s.height]
        }
        let both = LabelFit.Plan(width: 200, height: 200)
        #expect(size(100, 50, both) == [100, 50])
        #expect(size(400, 100, both) == [200, 50])
        #expect(size(100, 400, both) == [50, 200])
        #expect(size(401, 3, both) == [200, 1])
        let widthOnly = LabelFit.Plan(width: 200, height: nil)
        #expect(size(3, 1000, widthOnly) == [3, 1000])
        #expect(size(1000, 3, widthOnly) == [200, 1])
        #expect(size(1000, 300, LabelFit.Plan(width: nil, height: 200)) == [667, 200])
    }

    /// Definition aus §8 Schritt 4, ohne Zerlegung.
    static func naive(_ image: GrayImage, _ x0: Int, _ y0: Int, _ bw: Int, _ bh: Int, _ tw: Int, _ th: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ty in 0..<th {
            for tx in 0..<tw {
                var sum = 0
                for y in 0..<bh {
                    let ay = max(0, min((y + 1) * th, (ty + 1) * bh) - max(y * th, ty * bh))
                    guard ay > 0 else { continue }
                    for x in 0..<bw {
                        let ax = max(0, min((x + 1) * tw, (tx + 1) * bw) - max(x * tw, tx * bw))
                        sum += ax * ay * Int(image[x0 + x, y0 + y])
                    }
                }
                out.append(UInt8((sum + bw * bh / 2) / (bw * bh)))
            }
        }
        return out
    }

    @Test("Flächenmittel = Definition (zufällige Ausschnitte), Faktor 1 = Kopie, Rundung")
    func areaAverage() {
        var rng = SplitMix64(seed: 20_261_110)
        for _ in 0..<200 {
            let w = Int(rng.next() % 29) + 1, h = Int(rng.next() % 23) + 1
            let image = GrayImage(width: w, height: h, pixels: (0..<w * h).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            let x0 = Int(rng.next() % UInt64(w)), y0 = Int(rng.next() % UInt64(h))
            let bw = Int(rng.next() % UInt64(w - x0)) + 1, bh = Int(rng.next() % UInt64(h - y0)) + 1
            let tw = Int(rng.next() % UInt64(bw)) + 1, th = Int(rng.next() % UInt64(bh)) + 1
            let result = LabelFit.areaAverage(image, x: x0, y: y0, width: bw, height: bh, toWidth: tw, toHeight: th)
            #expect(result.width == tw && result.height == th)
            #expect(result.pixels == Self.naive(image, x0, y0, bw, bh, tw, th))
        }
        let half = GrayImage(width: 2, height: 1, pixels: [0, 255])
        #expect(LabelFit.areaAverage(half, x: 0, y: 0, width: 2, height: 1, toWidth: 1, toHeight: 1).pixels == [128])
        let copy = GrayImage(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])
        #expect(LabelFit.areaAverage(copy, x: 1, y: 0, width: 2, height: 2, toWidth: 2, toHeight: 2).pixels == [2, 3, 5, 6])
    }

    @Test("Einsetzen: mittig auf weißem Etikett, leere Seite → leeres Etikett, freie Länge")
    func apply() {
        var page = GrayImage(width: 10, height: 10)
        page[1, 5] = 0
        page[4, 5] = 100
        page[2, 7] = 249
        let fitted = LabelFit.apply(page, plan: LabelFit.Plan(width: 10, height: 10))
        #expect(fitted.width == 10 && fitted.height == 10)
        #expect(Array(fitted.pixels[30..<40]) == [255, 255, 255, 0, 255, 255, 100, 255, 255, 255], "Inhalt 4 × 3 an (3, 3)")
        #expect(fitted[4, 5] == 249)
        let blank = LabelFit.apply(GrayImage(width: 3, height: 2), plan: LabelFit.Plan(width: 10, height: 10))
        #expect(blank == GrayImage(width: 10, height: 10))
        let free = LabelFit.apply(page, plan: LabelFit.Plan(width: 2, height: nil))
        #expect(free.width == 2 && free.height == 2)
        #expect(LabelFit.apply(GrayImage(width: 3, height: 2), plan: LabelFit.Plan(width: 2, height: nil))
            == GrayImage(width: 2, height: 1))
    }

    @Test("JobEncoder: A4 mit kleinem Etikett in der Ecke → ein Etikett ^PW831 ^LL609, sonst unverändert")
    func jobEncoder() throws {
        // A4 bei 203 dpi mit einem 600 × 420 Punkte großen „Etikett“ oben links.
        var a4 = GrayImage(width: 1678, height: 2374)
        for y in 50..<470 where y % 3 == 0 {
            for x in 40..<640 { a4[x, y] = 0 }
        }
        let encoder = JobEncoder(language: .zpl, resolution: .dpi203, settings: Self.label, maxPrintWidthDots: 832)
        let fitted = String(decoding: try encoder.encode(images: [a4], pageSizes: [.a4]), as: UTF8.self)
        #expect(fitted.contains("^PW831\n^LL609\n"))
        let plain = String(decoding: try encoder.encode(images: [a4]), as: UTF8.self)
        #expect(plain.contains("^PW832\n^LL2374\n"), "ohne Seitengröße wie bisher")
        #expect(try encoder.encode(images: [a4], pageSizes: [nil]) == encoder.encode(images: [a4]))
        let off = JobEncoder(language: .zpl, resolution: .dpi203,
                             settings: { var s = Self.label; s.fitToLabel = .off; return s }(), maxPrintWidthDots: 832)
        #expect(try off.encode(images: [a4], pageSizes: [.a4]) == off.encode(images: [a4]))
        // Passende Seite (w295h216): byte-gleich zur Ausgabe ohne Seitengröße
        let labelPage = GrayImage(width: 831, height: 609, fill: 128)
        #expect(try encoder.encode(images: [labelPage], pageSizes: [PageSizePoints(width: 295, height: 216)])
            == encoder.encode(images: [labelPage]))
        #expect(throws: ImagingError.self) { try encoder.encode(images: [a4], pageSizes: []) }
        // Inhalt bleibt in Originalgröße und liegt mittig: Zeilen 0 und 608 weiß
        let image = encoder.fitted(a4, pageSize: .a4)
        #expect(image.width == 831 && image.height == 609)
        let bounds = LabelFit.contentBounds(image)
        #expect(bounds?.width == 600 && bounds?.height == 418, "Originalgröße")
        #expect(bounds?.x == 115 && bounds?.y == 95, "mittig: (831 − 600) / 2, (609 − 418) / 2")
    }
}

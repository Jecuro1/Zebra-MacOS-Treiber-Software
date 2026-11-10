import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// „An Etikett anpassen“ (ARCHITECTURE.md §8 „F“): Entscheidung, Rand, Inhaltsrahmen, Drehung,
/// Zielgröße, Flächenmittel (verkleinern und vergrößern) gegen die Definition, Einsetzen und der Weg
/// durch den `JobEncoder`. Die
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
        #expect(plan(s, .a4) == LabelFit.Plan(width: 831, height: 609, marginX: 12, marginY: 12))
        #expect(plan(s, .letter) == LabelFit.Plan(width: 831, height: 609, marginX: 12, marginY: 12))
        #expect(plan(s, .a4, dpi: 300) == LabelFit.Plan(width: 1228, height: 900, marginX: 18, marginY: 18))
        #expect(LabelFit.plan(settings: s, pageSize: .a4, xDPI: 300, yDPI: 600, imageWidth: 10, imageHeight: 10)
            == LabelFit.Plan(width: 1228, height: 1800, marginX: 18, marginY: 35))
        #expect([152, 203, 254, 300, 600].map(LabelFit.margin(dpi:)) == [9, 12, 15, 18, 35])
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
        #expect(plan(rotated, .a4) == LabelFit.Plan(width: 609, height: 831, marginX: 12, marginY: 12))
        var continuous = s
        continuous.tracking = .continuous
        #expect(plan(continuous, PageSizePoints(width: 295, height: 842)) == nil, "Länge frei, Breite passt")
        #expect(plan(continuous, .a4) == LabelFit.Plan(width: 831, height: nil, marginX: 12, marginY: 12))
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

    @Test("Zielrahmen und Zielgröße: vergrößern und verkleinern, Rand, freie Seite = Inhalt (nie größer)")
    func targetSize() {
        func size(_ w: Int, _ h: Int, _ plan: LabelFit.Plan) -> [Int] {
            let s = LabelFit.targetSize(contentWidth: w, contentHeight: h, plan: plan)
            return [s.width, s.height]
        }
        func box(_ w: Int, _ h: Int, _ plan: LabelFit.Plan) -> [Int] {
            let b = LabelFit.box(contentWidth: w, contentHeight: h, plan: plan)
            return [b.width, b.height]
        }
        let label = LabelFit.Plan(width: 831, height: 609, marginX: 12, marginY: 12)
        #expect(box(5, 5, label) == [807, 585])
        #expect(box(5, 5, LabelFit.Plan(width: 20, height: 30, marginX: 10, marginY: 14)) == [20, 2], "Rand zu groß")
        #expect(box(5, 40_000, LabelFit.Plan(width: 831, height: nil, marginX: 12, marginY: 12)) == [807, 40_000])
        #expect(box(5, 7, LabelFit.Plan(width: 831, height: nil, marginX: 12, marginY: 12)) == [807, 7])
        #expect(box(7, 5, LabelFit.Plan(width: nil, height: 200)) == [7, 200])
        let both = LabelFit.Plan(width: 200, height: 200)
        #expect(size(100, 50, both) == [200, 100], "vergrößern")
        #expect(size(400, 100, both) == [200, 50])
        #expect(size(100, 400, both) == [50, 200])
        #expect(size(401, 3, both) == [200, 1])
        let widthOnly = LabelFit.Plan(width: 200, height: nil)
        #expect(size(3, 1000, widthOnly) == [3, 1000], "freie Länge: nie vergrößern")
        #expect(size(1000, 3, widthOnly) == [200, 1])
        #expect(size(1000, 300, LabelFit.Plan(width: nil, height: 200)) == [667, 200])
        #expect(size(300, 100, LabelFit.Plan(width: nil, height: 200)) == [300, 100])
        #expect(size(416, 305, label) == [798, 585])
        // Meldung der Prüfung: Seitenzahl bzw. dünner Strich auf Endlosmaterial 80 mm → unverändert
        let roll = LabelFit.Plan(width: 639, height: nil, marginX: 12, marginY: 12)
        #expect(size(12, 30, roll) == [12, 30])
        #expect(size(2, 900, roll) == [2, 900])
        #expect(size(1000, 300, roll) == [615, 185])
        // Maßstab als Bruch
        #expect(LabelFit.scale(contentWidth: 100, contentHeight: 50, plan: both) == LabelFit.Scale(numerator: 200, denominator: 100))
        #expect(LabelFit.scale(contentWidth: 100, contentHeight: 400, plan: both) == LabelFit.Scale(numerator: 200, denominator: 400))
        let scaled = LabelFit.scaledSize(contentWidth: 151, contentHeight: 205, scale: LabelFit.Scale(numerator: 807, denominator: 350))
        #expect(scaled.width == 348 && scaled.height == 473)
        let tiny = LabelFit.scaledSize(contentWidth: 1, contentHeight: 1, scale: LabelFit.Scale(numerator: 1, denominator: 9))
        #expect(tiny.width == 1 && tiny.height == 1, "mindestens 1")
    }

    @Test("Referenz: einheitliche Drehung und Maßstab für Seiten gleicher Größe (wie C und Python)")
    func reference() {
        // Etikett-PDF halb so groß, gegen den Uhrzeigersinn gedreht auf A4 (20 dpi: Seite 165 × 234,
        // Etikett 82 × 60, Rahmen 80 × 58). Nur Seite 1 ist deutlich hoch; Seiten 2 und 3 (kurze Zeilen)
        // werden wie sie gedreht und gleich groß, Seite 4 passt nur kleiner, Letter entscheidet selbst.
        func sheet(_ w: Int, _ h: Int, _ box: (Int, Int, Int, Int)) -> GrayImage {
            var image = GrayImage(width: w, height: h)
            for y in box.1..<(box.1 + box.3) {
                for x in box.0..<(box.0 + box.2) { image[x, y] = 0 }
            }
            return image
        }
        let pages = [(70, 100, 20, 34), (70, 100, 20, 15), (60, 110, 24, 10), (60, 90, 40, 30)]
            .map { sheet(165, 234, $0) } + [sheet(170, 220, (60, 90, 20, 15))]
        let plan = LabelFit.Plan(width: 82, height: 60, marginX: 1, marginY: 1)
        let sizes = [(21000, 29700), (21000, 29700), (21000, 29700), (21000, 29700), (21590, 27940)]
        let expected = [(80, 47), (35, 47), (24, 56), (44, 58), (77, 58)]
        var reference: LabelFit.Reference?
        for (index, page) in pages.enumerated() {
            #expect((reference?.applies(to: plan, pageWidth: sizes[index].0, pageHeight: sizes[index].1) ?? false)
                    == (1...3).contains(index))
            let fitted = LabelFit.apply(page, plan: plan, pageWidth: sizes[index].0, pageHeight: sizes[index].1,
                                        reference: &reference)
            #expect(fitted.width == 82 && fitted.height == 60)
            let bounds = LabelFit.contentBounds(fitted)
            #expect(bounds?.width == expected[index].0 && bounds?.height == expected[index].1, "Seite \(index + 1)")
            #expect(bounds?.x == (82 - expected[index].0) / 2 && bounds?.y == (60 - expected[index].1) / 2)
        }
        #expect(reference == LabelFit.Reference(plan: plan, pageWidth: 21590, pageHeight: 27940, turn: .r0,
                                                scale: LabelFit.Scale(numerator: 58, denominator: 15)))
        // Allein entschiede Seite 2 anders (nicht gedreht: 15 hoch → 58)
        #expect(LabelFit.contentBounds(LabelFit.apply(pages[1], plan: plan))?.height == 58)
        // Leere Seite ändert die Referenz nicht; ± 2 mm, anderer Rand
        let before = reference
        _ = LabelFit.apply(GrayImage(width: 9, height: 9), plan: plan, pageWidth: 21590, pageHeight: 27940,
                           reference: &reference)
        #expect(reference == before)
        #expect(reference?.applies(to: plan, pageWidth: 21790, pageHeight: 27740) == true)
        #expect(reference?.applies(to: plan, pageWidth: 21791, pageHeight: 27940) == false)
        #expect(reference?.applies(to: LabelFit.Plan(width: 82, height: 60), pageWidth: 21590, pageHeight: 27940) == false)
    }

    @Test("Drehung: nur festes Etikett, > 10 % Gewinn (= s90 > 1,1 · s0), Richtung nach dem Inhalt")
    func rotation() {
        let label = LabelFit.Plan(width: 831, height: 609, marginX: 12, marginY: 12)
        #expect(LabelFit.rotation(contentWidth: 305, contentHeight: 416, plan: label) == .r90, "Fall aus der Meldung")
        #expect(LabelFit.rotation(contentWidth: 416, contentHeight: 305, plan: label) == .r0)
        #expect(LabelFit.rotation(contentWidth: 100, contentHeight: 110, plan: label) == .r0, "genau 10 % genügen nicht")
        #expect(LabelFit.rotation(contentWidth: 100, contentHeight: 111, plan: label) == .r90)
        let fourBySix = LabelFit.Plan(width: 812, height: 1218, marginX: 12, marginY: 12)
        #expect(LabelFit.rotation(contentWidth: 416, contentHeight: 305, plan: fourBySix) == .r270)
        #expect(LabelFit.rotation(contentWidth: 305, contentHeight: 416, plan: fourBySix) == .r0)
        #expect(LabelFit.rotation(contentWidth: 305, contentHeight: 416,
                                  plan: LabelFit.Plan(width: 831, height: nil, marginX: 12, marginY: 12)) == .r0)
        // Kurzform = Definition s90 > 1,1 · s0 (Brüche über Kreuz multipliziert)
        var rng = SplitMix64(seed: 0x0F17)
        for _ in 0..<5000 {
            let bw = Int(rng.next() % 60) + 1, bh = Int(rng.next() % 60) + 1
            let plan = LabelFit.Plan(width: Int(rng.next() % 80) + 1, height: Int(rng.next() % 80) + 1,
                                     marginX: Int(rng.next() % 10), marginY: Int(rng.next() % 10))
            let inner = LabelFit.box(contentWidth: bw, contentHeight: bh, plan: plan)
            let (iw, ih) = (inner.width, inner.height)
            let (n0, d0) = iw * bh <= ih * bw ? (iw, bw) : (ih, bh)          // min(iw/bw, ih/bh)
            let (n90, d90) = iw * bw <= ih * bh ? (iw, bh) : (ih, bw)        // min(iw/bh, ih/bw)
            let rotate = 10 * n90 * d0 > 11 * n0 * d90
            let turn = LabelFit.rotation(contentWidth: bw, contentHeight: bh, plan: plan)
            #expect((turn != .r0) == rotate)
            if rotate { #expect(turn == (bh > bw ? .r90 : .r270)) }
        }
    }

    /// Definition aus §8 Schritt 5, ohne Zerlegung.
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

    @Test("Flächenmittel = Definition (zufällige Ausschnitte, verkleinern und vergrößern), Kopie, Rundung")
    func areaAverage() {
        var rng = SplitMix64(seed: 20_261_110)
        for _ in 0..<300 {
            let w = Int(rng.next() % 29) + 1, h = Int(rng.next() % 23) + 1
            let image = GrayImage(width: w, height: h, pixels: (0..<w * h).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            let x0 = Int(rng.next() % UInt64(w)), y0 = Int(rng.next() % UInt64(h))
            let bw = Int(rng.next() % UInt64(w - x0)) + 1, bh = Int(rng.next() % UInt64(h - y0)) + 1
            let tw = Int(rng.next() % UInt64(2 * bw + 3)) + 1, th = Int(rng.next() % UInt64(2 * bh + 3)) + 1
            let result = LabelFit.areaAverage(image, x: x0, y: y0, width: bw, height: bh, toWidth: tw, toHeight: th)
            #expect(result.width == tw && result.height == th)
            #expect(result.pixels == Self.naive(image, x0, y0, bw, bh, tw, th))
        }
        let half = GrayImage(width: 2, height: 1, pixels: [0, 255])
        #expect(LabelFit.areaAverage(half, x: 0, y: 0, width: 2, height: 1, toWidth: 1, toHeight: 1).pixels == [128])
        #expect(LabelFit.areaAverage(half, x: 0, y: 0, width: 2, height: 1, toWidth: 4, toHeight: 1).pixels
            == [0, 0, 255, 255], "ganzzahlig vergrößern = Kopien")
        #expect(LabelFit.areaAverage(half, x: 0, y: 0, width: 2, height: 1, toWidth: 3, toHeight: 1).pixels == [0, 128, 255])
        let copy = GrayImage(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])
        #expect(LabelFit.areaAverage(copy, x: 1, y: 0, width: 2, height: 2, toWidth: 2, toHeight: 2).pixels == [2, 3, 5, 6])
    }

    @Test("Einsetzen: formatfüllend mittig, Rand, leere Seite → leeres Etikett, freie Länge")
    func apply() {
        var page = GrayImage(width: 10, height: 10)
        page[1, 5] = 0
        page[4, 5] = 100
        page[2, 7] = 249
        // Rand 15 ist größer als das Etikett → ganze Seite; Inhalt 4 × 3 → 10 × 8 an (0, 1)
        let fitted = LabelFit.apply(page, plan: LabelFit.Plan(width: 10, height: 10, marginX: 15, marginY: 15))
        #expect(fitted.width == 10 && fitted.height == 10)
        let scaled = LabelFit.areaAverage(page, x: 1, y: 5, width: 4, height: 3, toWidth: 10, toHeight: 8)
        #expect(Array(fitted.pixels[10..<90]) == scaled.pixels)
        #expect(fitted.pixels[0..<10].allSatisfy { $0 == 255 } && fitted.pixels[90..<100].allSatisfy { $0 == 255 })
        let blank = LabelFit.apply(GrayImage(width: 3, height: 2), plan: LabelFit.Plan(width: 10, height: 10))
        #expect(blank == GrayImage(width: 10, height: 10))
        let free = LabelFit.apply(page, plan: LabelFit.Plan(width: 2, height: nil))
        #expect(free.width == 2 && free.height == 2)
        #expect(LabelFit.apply(GrayImage(width: 3, height: 2), plan: LabelFit.Plan(width: 2, height: nil))
            == GrayImage(width: 2, height: 1))
    }

    /// Etikett mit schwarzem Rahmen (Inhaltsrahmen = ganzes Bild) und Marke oben links.
    static func labelImage(width: Int, height: Int) -> GrayImage {
        var image = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let frame = x == 0 || y == 0 || x == width - 1 || y == height - 1 || (x < 6 && y < 5)
                image[x, y] = frame ? 0 : UInt8((x * 37 + y * 11) % 256)
            }
        }
        return image
    }

    /// `image` mittig auf einer weißen Seite `width` × `height`.
    static func onPage(_ image: GrayImage, width: Int, height: Int) -> GrayImage {
        image.padded(toWidth: width, height: height, alignment: .center)
    }

    @Test("Meldung: halb so großes, gegen den Uhrzeigersinn gedrehtes Etikett auf A4 → aufrecht, formatfüllend")
    func rotatedHalfSizeLabel() {
        // 254 dpi (10 Punkte/mm): Etikett 43 × 33 mm = 430 × 330, Rand 15 → Rahmen 400 × 300 = 10 × Inhalt.
        let upright = Self.labelImage(width: 40, height: 30)
        let page = Self.onPage(upright.rotated(.r270), width: 120, height: 160)
        var settings = PrintSettings()
        settings.setLabelSize(widthMM: 43, heightMM: 33)
        let plan = LabelFit.plan(settings: settings, pageSize: .a4, xDPI: 254, yDPI: 254,
                                 imageWidth: page.width, imageHeight: page.height)
        #expect(plan == LabelFit.Plan(width: 430, height: 330, marginX: 15, marginY: 15))
        guard let plan else { return }
        let fitted = LabelFit.apply(page, plan: plan)
        #expect(fitted.width == 430 && fitted.height == 330)
        var wrong = 0
        for y in 0..<300 {
            for x in 0..<400 where fitted[15 + x, 15 + y] != upright[x / 10, y / 10] { wrong += 1 }
        }
        #expect(wrong == 0, "aufrecht (Marke oben links) und exakt 10-fach")
        let bounds = LabelFit.contentBounds(fitted)
        #expect(bounds?.x == 15 && bounds?.y == 15 && bounds?.width == 400 && bounds?.height == 300)
        // Umgekehrt: Hochformat-Etikett im Uhrzeigersinn quer auf die Seite gelegt → zurück gegen den Uhrzeigersinn
        let tall = Self.labelImage(width: 30, height: 40)
        let landscape = Self.onPage(tall.rotated(.r90), width: 160, height: 120)
        let portraitPlan = LabelFit.Plan(width: 330, height: 430, marginX: 15, marginY: 15)
        let back = LabelFit.apply(landscape, plan: portraitPlan)
        wrong = 0
        for y in 0..<400 {
            for x in 0..<300 where back[15 + x, 15 + y] != tall[x / 10, y / 10] { wrong += 1 }
        }
        #expect(wrong == 0)
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
        // Inhalt füllt das Etikett abzüglich 1,5 mm (12 Punkte) Rand und liegt mittig
        let image = encoder.fitted(a4, pageSize: .a4)
        #expect(image.width == 831 && image.height == 609)
        let bounds = LabelFit.contentBounds(image)
        #expect(bounds?.width == 807 && bounds?.height == 562, "600 × 418 → 807 × 562 (vergrößert)")
        #expect(bounds?.x == 12 && bounds?.y == 23, "mittig: (831 − 807) / 2, (609 − 562) / 2")
    }

    @Test("JobEncoder: Fall aus der Meldung – A4 hoch, Etikett halb so groß und gedreht in der Mitte")
    func jobEncoderReportedCase() throws {
        // 104 × 76,2 mm halb so groß (52 × 38,1 mm = 416 × 305 Punkte), gegen den Uhrzeigersinn gedreht
        let label = Self.labelImage(width: 416, height: 305)
        let a4 = Self.onPage(label.rotated(.r270), width: 1678, height: 2374)
        let encoder = JobEncoder(language: .zpl, resolution: .dpi203, settings: Self.label, maxPrintWidthDots: 832)
        let image = encoder.fitted(a4, pageSize: .a4)
        #expect(image.width == 831 && image.height == 609)
        let bounds = LabelFit.contentBounds(image)
        #expect(bounds?.width == 798 && bounds?.height == 585, "aufrecht, 1,92-fach bis an den Rand (12 Punkte)")
        #expect(bounds?.x == 16 && bounds?.y == 12)
        // Marke oben links (6 × 5 → etwa 11,5 × 9,6 Punkte) liegt oben links: Punkt (20, 16) schwarz
        #expect(image[20, 16] == 0 && image[16 + 797 - 4, 12 + 584 - 4] > 0)
        let job = String(decoding: try encoder.encode(images: [a4], pageSizes: [.a4]), as: UTF8.self)
        #expect(job.contains("^PW831\n^LL609\n"))
    }
}

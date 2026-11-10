import Foundation
import Testing
@testable import LabelWerkCore

@Suite("Etikettengrößen: Erkennung, Eingabe, Zuordnung")
struct LabelSizingTests {

    // MARK: Druckerpunkte → mm

    @Test("Druckerpunkte werden auf runde Maße gerastet (203 dpi)", arguments: [
        (832, 104.0), (609, 76.2), (610, 76.2), (608, 76.0), (812, 101.6), (813, 101.6), (1218, 152.4),
        (1219, 152.4), (820, 102.5), (800, 100.0), (406, 50.8), (200, 25.0),
    ])
    func dotsToMillimeters(dots: Int, expected: Double) {
        #expect(LabelSizing.millimeters(fromDots: dots, resolution: .dpi203) == expected)
    }

    @Test("Andere Auflösungen")
    func otherResolutions() {
        #expect(LabelSizing.millimeters(fromDots: 1248, resolution: .dpi300) == 104)
        #expect(LabelSizing.millimeters(fromDots: 914, resolution: .dpi300) == 76.2)
        // Mehrdeutig: 900 Punkte sind 75 mm (12 Punkte/mm) oder 3 Zoll (300 dpi) – ganze mm gewinnen.
        #expect(LabelSizing.millimeters(fromDots: 900, resolution: .dpi300) == 75)
        #expect(LabelSizing.millimeters(fromDots: 2496, resolution: .dpi600) == 104)
        #expect(LabelSizing.millimeters(fromDots: 0, resolution: .dpi203) == 0)
    }

    @Test("Ohne passenden Kandidaten: auf 0,1 mm gerundet")
    func fallbackRounding() {
        // 1002 Punkte = 125,25 mm: weder ganze/halbe mm noch das Zollraster liegen höchstens einen
        // Punkt entfernt → 125,3 (0,1 mm, kaufmännisch). 1003 Punkte treffen 125,5 mm bei 203 dpi.
        #expect(LabelSizing.millimeters(fromDots: 1002, resolution: .dpi203) == 125.3)
        #expect(LabelSizing.millimeters(fromDots: 1003, resolution: .dpi203) == 125.5)
    }

    // MARK: Formatieren & Lesen

    @Test("Formatierung")
    func formatting() {
        #expect(LabelSizing.format(104) == "104")
        #expect(LabelSizing.format(76.2) == "76,2")
        #expect(LabelSizing.format(57.15) == "57,15")
        #expect(LabelSizing.format(76.2, decimalSeparator: ".") == "76.2")
        #expect(LabelSizing.format(0.004) == "0")
        #expect(LabelSizing.sizeText(widthMM: 104, heightMM: 76.2) == "104 × 76,2 mm")
        #expect(LabelSizing.sizeText(widthMM: 104, heightMM: 76.2, ascii: true) == "104 x 76.2 mm")
        #expect(LabelSizing.hundredthsOfMillimeter(104) == 10400)
        #expect(LabelSizing.hundredthsOfMillimeter(76.2) == 7620)
        #expect(LabelSizing.hundredthsOfMillimeter(-3) == 0)
        #expect(LabelSizing.hundredthsOfMillimeter(.nan) == 0)
    }

    @Test("Millimeter lesen (deutsches Komma)")
    func parseMillimeters() {
        #expect(LabelSizing.parseMillimeters("76,2") == 76.2)
        #expect(LabelSizing.parseMillimeters(" 76.2 mm ") == 76.2)
        #expect(LabelSizing.parseMillimeters("104") == 104)
        #expect(LabelSizing.parseMillimeters("") == nil)
        #expect(LabelSizing.parseMillimeters("1.000,5") == nil)
        #expect(LabelSizing.parseMillimeters("abc") == nil)
        #expect(LabelSizing.parseMillimeters("0") == nil)
        #expect(LabelSizing.parseMillimeters("-5") == nil)
    }

    @Test("Größe lesen (lwctl --size)")
    func parseSize() throws {
        let mm = try #require(LabelSizing.parseSize("104x76.2mm"))
        #expect(mm.widthMM == 104 && mm.heightMM == 76.2)
        let spaced = try #require(LabelSizing.parseSize("104 × 76,2 mm"))
        #expect(spaced.widthMM == 104 && spaced.heightMM == 76.2)
        let inches = try #require(LabelSizing.parseSize("4x3in"))
        #expect(inches.widthMM == 101.6 && inches.heightMM == 76.2)
        let plain = try #require(LabelSizing.parseSize("100X150"))
        #expect(plain.widthMM == 100 && plain.heightMM == 150)
        #expect(LabelSizing.parseSize("104") == nil)
        #expect(LabelSizing.parseSize("104x") == nil)
        #expect(LabelSizing.parseSize("104x76x2") == nil)
        #expect(LabelSizing.parseSize("axb") == nil)
    }

    // MARK: Grenzen

    @Test("Grenzen eines Modells")
    func limits() throws {
        let model = try #require(ModelCatalog.shared.model(id: "zd421t"))
        let limits = LabelSizing.Limits(model: model)
        #expect(limits.widthMM.lowerBound == 10)
        #expect(limits.widthMM.upperBound == model.printWidthMM + 2)
        #expect(limits.heightMM.lowerBound == 5)
        #expect(limits.heightMM.upperBound == model.maxLabelLengthMM)
        #expect(limits.contains(widthMM: 104, heightMM: 76.2))
        #expect(limits.issues(widthMM: 9, heightMM: 76.2) == [.widthTooSmall(minimum: 10)])
        #expect(limits.issues(widthMM: 200, heightMM: 3) == [.widthTooLarge(maximum: model.printWidthMM + 2),
                                                            .heightTooSmall(minimum: 5)])
        #expect(limits.issues(widthMM: nil, heightMM: nil) == [.widthMissing, .heightMissing])
        #expect(LabelSizing.Issue.widthTooLarge(maximum: 106).message == "Breite höchstens 106 mm")
        let generic = LabelSizing.Limits(model: nil)
        #expect(generic.widthMM.upperBound >= limits.widthMM.upperBound)
    }

    // MARK: Zuordnung

    private func stock(_ id: String, _ w: Double, _ h: Double, _ tracking: MediaTracking = .gap,
                       custom: Bool = false) -> LabelStock {
        LabelStock(id: id, name: id, widthMM: w, heightMM: h, tracking: tracking, isCustom: custom)
    }

    @Test("Medientypen")
    func trackingCompatibility() {
        #expect(LabelSizing.isCompatible(nil, with: .continuous))
        #expect(LabelSizing.isCompatible(.gap, with: .notch))
        #expect(LabelSizing.isCompatible(.notch, with: .gap))
        #expect(LabelSizing.isCompatible(.autoDetect, with: .blackMark))
        #expect(LabelSizing.isCompatible(.gap, with: .autoDetect))
        #expect(!LabelSizing.isCompatible(.autoDetect, with: .continuous))
        #expect(!LabelSizing.isCompatible(.gap, with: .blackMark))
        #expect(!LabelSizing.isCompatible(.continuous, with: .gap))
        #expect(LabelSizing.isCompatible(.continuous, with: .continuous))
    }

    @Test("Toleranz ± 0,6 mm, nächstliegendes Format gewinnt")
    func bestMatch() {
        let stocks = [stock("a", 104, 76), stock("b", 104, 76.2), stock("c", 101.6, 76.2), stock("d", 104, 76.2, .continuous)]
        #expect(LabelSizing.bestMatch(widthMM: 104, heightMM: 76.25, tracking: .gap, in: stocks)?.id == "b")
        #expect(LabelSizing.bestMatch(widthMM: 104, heightMM: 75.9, tracking: .gap, in: stocks)?.id == "a")
        #expect(LabelSizing.bestMatch(widthMM: 104.6, heightMM: 76.2, tracking: .gap, in: stocks)?.id == "b")
        #expect(LabelSizing.bestMatch(widthMM: 104.7, heightMM: 76.2, tracking: .gap, in: stocks) == nil)
        #expect(LabelSizing.bestMatch(widthMM: 104, heightMM: 76.2, tracking: .continuous, in: stocks)?.id == "d")
        #expect(LabelSizing.bestMatch(widthMM: 104, heightMM: 76.2, tracking: nil, in: stocks)?.id == "b")
    }

    @Test("Eigene Formate vor dem Katalog")
    func customFirst() {
        let custom = [stock("mine", 101.7, 152.4, custom: true)]
        let catalog = ModelCatalog.shared.stocks
        #expect(LabelSizing.matchingStock(widthMM: 101.6, heightMM: 152.4, tracking: .gap, custom: custom,
                                          catalog: catalog)?.id == "mine")
        #expect(LabelSizing.matchingStock(widthMM: 101.6, heightMM: 152.4, tracking: .gap, custom: [],
                                          catalog: catalog)?.id == "w4h6in")
        // 104 × 76,2 mm (ZD421 mit ZDesigner-Etiketten) steht nicht im Katalog: 4 × 3 Zoll ist 2,4 mm schmaler.
        #expect(LabelSizing.matchingStock(widthMM: 104, heightMM: 76.2, tracking: .gap, custom: [],
                                          catalog: catalog) == nil)
    }

    @Test("Gleiche Größe wie im Dialog (± 0,05 mm, gleicher Medientyp)")
    func sameSize() {
        let stocks = [stock("x", 104, 76.2, .gap, custom: true), stock("y", 104, 76.2, .blackMark, custom: true)]
        #expect(LabelSizing.sameSizeStock(widthMM: 104.04, heightMM: 76.2, tracking: .gap, in: stocks)?.id == "x")
        #expect(LabelSizing.sameSizeStock(widthMM: 104, heightMM: 76.2, tracking: .blackMark, in: stocks)?.id == "y")
        #expect(LabelSizing.sameSizeStock(widthMM: 104.06, heightMM: 76.2, tracking: .gap, in: stocks) == nil)
        #expect(LabelSizing.sameSizeStock(widthMM: 104, heightMM: 76.2, tracking: .notch, in: stocks) == nil)
    }
}

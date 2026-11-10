import Foundation
import Testing
@testable import LabelWerkCore

/// Ausschnitt einer LabelWerk-PPD im Aufbau von `generate_ppds.py` (`_emit_page_sizes`).
enum SamplePPD {
    static let text = """
    *PPD-Adobe: "4.3"
    *% LabelWerk - PPD fuer Zebra ZD421t (203 dpi)
    *ModelName: "Zebra ZD421t 203 dpi - LabelWerk"
    *cupsLanguages: "de"

    *% LabelWerk-Attribute fuer den Filter (ARCHITECTURE.md Abschnitt 9)
    *lwModel: "zd421t"
    *lwMaxPrintWidthDots: "831"
    *lwDefaultGapDots: "24"

    *OpenGroup: PageSetup/Page Setup

    *OpenUI *PageSize/Media Size: PickOne
    *OrderDependency: 10 AnySetup *PageSize
    *DefaultPageSize: w288h432
    *PageSize w288h432/4 x 6 in (Shipping): "<</PageSize[288 432]/ImagingBBox null>>setpagedevice"
    *PageSize w288h216/4 x 3 in: "<</PageSize[288 216]/ImagingBBox null>>setpagedevice"
    *CloseUI: *PageSize
    *de.Translation PageSize/Etikettenformat: ""
    *de.PageSize w288h432/4 × 6 Zoll (Versand): ""
    *de.PageSize w288h216/4 × 3 Zoll: ""

    *OpenUI *PageRegion/Media Size: PickOne
    *OrderDependency: 10 AnySetup *PageRegion
    *DefaultPageRegion: w288h432
    *PageRegion w288h432/4 x 6 in (Shipping): "<</PageSize[288 432]/ImagingBBox null>>setpagedevice"
    *PageRegion w288h216/4 x 3 in: "<</PageSize[288 216]/ImagingBBox null>>setpagedevice"
    *CloseUI: *PageRegion
    *de.Translation PageRegion/Etikettenformat: ""
    *de.PageRegion w288h432/4 × 6 Zoll (Versand): ""
    *de.PageRegion w288h216/4 × 3 Zoll: ""

    *DefaultImageableArea: w288h432
    *ImageableArea w288h432/4 x 6 in (Shipping): "0 0 288 432"
    *ImageableArea w288h216/4 x 3 in: "0 0 288 216"
    *DefaultPaperDimension: w288h432
    *PaperDimension w288h432/4 x 6 in (Shipping): "288 432"
    *PaperDimension w288h216/4 x 3 in: "288 216"

    *CloseGroup: PageSetup
    *OpenUI *Resolution/Resolution: PickOne
    *DefaultResolution: 203dpi
    *Resolution 203dpi/203 dpi (8 dots/mm): "<</HWResolution[203 203]>>setpagedevice"
    *CloseUI: *Resolution

    """
}

@Suite("Etikettengröße der Warteschlange: PPD ergänzen")
struct QueuePPDTests {
    let size = QueueLabelSize(widthMM: 104, heightMM: 76.2)

    @Test("Schlüsselwort, Texte und 1/100 mm")
    func labelSize() {
        #expect(size.keyword == "w295h216")
        #expect(size.englishName == "Label 104 x 76.2 mm")
        #expect(size.germanName == "Etikett 104 × 76,2 mm")
        #expect(size.widthHundredths == 10400)
        #expect(size.heightHundredths == 7620)
        #expect(QueuePPD.formatNumber(size.widthPoints) == "294.803")
        #expect(QueuePPD.formatNumber(size.heightPoints) == "216")
        // Gleiches Schlüsselwort wie LabelStock.ppdKeyword.
        let stock = LabelStock(id: "x", name: "x", widthMM: 104, heightMM: 76.2)
        #expect(QueueLabelSize(stock: stock).keyword == stock.ppdKeyword)
    }

    @Test("Ergänzte Zeilen in der Syntax des Generators")
    func patchedLines() throws {
        let patched = try QueuePPD.patched(SamplePPD.text, adding: size)
        let lines = patched.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func after(_ anchor: String) -> String? {
            guard let index = lines.firstIndex(of: anchor), index + 1 < lines.count else { return nil }
            return lines[index + 1]
        }
        let code = "\"<</PageSize[294.803 216]/ImagingBBox null>>setpagedevice\""
        #expect(after("*DefaultPageSize: w295h216") == "*PageSize w295h216/Label 104 x 76.2 mm: \(code)")
        #expect(after("*DefaultPageRegion: w295h216") == "*PageRegion w295h216/Label 104 x 76.2 mm: \(code)")
        #expect(after("*DefaultImageableArea: w295h216") == "*ImageableArea w295h216/Label 104 x 76.2 mm: \"0 0 294.803 216\"")
        #expect(after("*DefaultPaperDimension: w295h216") == "*PaperDimension w295h216/Label 104 x 76.2 mm: \"294.803 216\"")
        #expect(after("*de.Translation PageSize/Etikettenformat: \"\"") == "*de.PageSize w295h216/Etikett 104 × 76,2 mm: \"\"")
        #expect(after("*de.Translation PageRegion/Etikettenformat: \"\"") == "*de.PageRegion w295h216/Etikett 104 × 76,2 mm: \"\"")
        #expect(after("*lwModel: \"zd421t\"") == QueuePPD.markerComment)
        #expect(lines.contains("*lwLabelPageSize: \"w295h216\""))
        #expect(!lines.contains { $0.hasPrefix("*Default") && $0.contains("w288h432") })
        #expect(patched.hasSuffix("\n") && !patched.hasSuffix("\n\n"))
        // Lesen der ergänzten PPD.
        #expect(QueuePPD.pageSizeKeywords(in: patched) == ["w295h216", "w288h432", "w288h216"])
        #expect(QueuePPD.defaultPageSize(in: patched) == "w295h216")
        #expect(QueuePPD.addedPageSize(in: patched) == "w295h216")
        let dimension = try #require(QueuePPD.paperDimension(of: "w295h216", in: patched))
        #expect(abs(dimension.width - 294.803) < 0.001 && dimension.height == 216)
        #expect(QueuePPD.baseStem(of: patched) == "LabelWerk-zd421t-203dpi")
        // Nur ASCII außerhalb der Übersetzungszeilen (PPD-Regel).
        for line in lines where line.unicodeScalars.contains(where: { $0.value > 0x7E }) {
            #expect(line.hasPrefix("*de."), "Nicht-ASCII außerhalb einer Übersetzung: \(line)")
        }
    }

    @Test("Erneutes Ergänzen ersetzt die frühere Größe, gleiche Größe ändert nichts")
    func repatch() throws {
        let first = try QueuePPD.patched(SamplePPD.text, adding: size)
        #expect(try QueuePPD.patched(first, adding: size) == first)
        let other = QueueLabelSize(widthMM: 100, heightMM: 60)
        let second = try QueuePPD.patched(first, adding: other)
        #expect(!second.contains("w295h216"))
        #expect(QueuePPD.addedPageSize(in: second) == other.keyword)
        #expect(second == (try QueuePPD.patched(SamplePPD.text, adding: other)))
        // Entfernen stellt die Einträge der Modell-PPD wieder her (Standardwerte zeigen dann ins Leere,
        // werden aber beim nächsten Ergänzen bzw. von lpadmin gesetzt).
        let removed = QueuePPD.removingAddedPageSize(first)
        #expect(QueuePPD.pageSizeKeywords(in: removed) == ["w288h432", "w288h216"])
        #expect(QueuePPD.addedPageSize(in: removed) == nil)
        #expect(!removed.contains(QueuePPD.markerComment))
    }

    @Test("Größe aus der Modell-PPD: nur die Standardwerte")
    func existingSize() throws {
        let catalog = QueueLabelSize(widthMM: 101.6, heightMM: 76.2)
        #expect(catalog.keyword == "w288h216")
        let patched = try QueuePPD.patched(SamplePPD.text, adding: catalog)
        #expect(QueuePPD.addedPageSize(in: patched) == nil)
        #expect(QueuePPD.pageSizeKeywords(in: patched) == ["w288h432", "w288h216"])
        for keyword in ["PageSize", "PageRegion", "ImageableArea", "PaperDimension"] {
            #expect(QueuePPD.value(of: "Default\(keyword)", in: patched) == "w288h216")
        }
    }

    @Test("Fremde oder unvollständige PPDs werden abgelehnt")
    func rejects() {
        #expect(throws: QueuePPD.PatchError.notLabelWerkPPD) {
            try QueuePPD.patched("*PPD-Adobe: \"4.3\"\n*DefaultPageSize: A4\n", adding: size)
        }
        let withoutRegion = SamplePPD.text.replacingOccurrences(of: "*DefaultPageRegion: w288h432\n", with: "")
        #expect(throws: QueuePPD.PatchError.missingAnchor("*DefaultPageRegion:")) {
            try QueuePPD.patched(withoutRegion, adding: size)
        }
    }

    @Test("CRLF-Zeilenenden werden gelesen")
    func crlf() throws {
        let crlf = SamplePPD.text.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(QueuePPD.defaultPageSize(in: crlf) == "w288h432")
        let patched = try QueuePPD.patched(crlf, adding: size)
        #expect(QueuePPD.defaultPageSize(in: patched) == "w295h216")
        #expect(!patched.contains("\r"))
    }

    @Test("lpoptions -l auswerten")
    func lpoptionsList() {
        let output = """
        PageSize/Media Size: *w295h216 w288h432 w288h216 Custom.WIDTHxHEIGHT
        lwDarkness/Darkness: Default 1 2 *15 16
        lwCancelBefore/Cancel Jobs: Before: *False True
        Resolution/Resolution: *203dpi
        """
        let parsed = LPOptionsList.parse(output)
        #expect(parsed["PageSize"]?.selected == "w295h216")
        #expect(parsed["PageSize"]?.choices == ["w295h216", "w288h432", "w288h216", "Custom.WIDTHxHEIGHT"])
        #expect(parsed["lwDarkness"]?.selected == "15")
        #expect(parsed["lwCancelBefore"]?.selected == "False")
        #expect(parsed["Resolution"]?.choices == ["203dpi"])
        let current = QueueDefaults.currentOptions(list: parsed, plain: ["lwLabelWidth": "10400", "printer-info": "x",
                                                                         "lwDarkness": "17"])
        #expect(current["PageSize"] == "w295h216")
        #expect(current["lwLabelWidth"] == "10400")
        #expect(current["lwDarkness"] == "17")
        #expect(current["printer-info"] == nil)
    }
}

@Suite("Standardwerte der Warteschlange: Plan und Abgleich")
struct QueueDefaultsTests {
    let size = QueueLabelSize(widthMM: 104, heightMM: 76.2)

    @Test("Plan mit Etikettengröße")
    func planWithSize() {
        let plan = QueueDefaults.plan(settings: .default, language: .zpl, removingStale: true, resolution: .dpi203,
                                      labelSize: size)
        let pairs = stride(from: 0, to: plan.arguments.count - 1, by: 1).map { (plan.arguments[$0], plan.arguments[$0 + 1]) }
        #expect(pairs.contains { $0 == ("-o", "PageSize=w295h216") })
        #expect(pairs.contains { $0 == ("-o", "lwLabelWidth-default=10400") })
        #expect(pairs.contains { $0 == ("-o", "lwLabelHeight-default=7620") })
        #expect(!pairs.contains { $0 == ("-R", "lwLabelWidth-default") })
        #expect(plan.expected["PageSize"] == "w295h216")
        #expect(plan.expected["lwLabelWidth"] == "10400")
        #expect(plan.queueDefaults.isSuperset(of: ["lwLabelWidth", "lwLabelHeight"]))
        #expect(plan.expected[CUPSOptionName.language] == "ZPL")
    }

    @Test("Plan ohne Etikettengröße entfernt lwLabelWidth/lwLabelHeight")
    func planWithoutSize() {
        let plan = QueueDefaults.plan(settings: .default, language: nil, removingStale: true)
        let pairs = stride(from: 0, to: plan.arguments.count - 1, by: 1).map { (plan.arguments[$0], plan.arguments[$0 + 1]) }
        #expect(pairs.contains { $0 == ("-R", "lwLabelWidth-default") })
        #expect(pairs.contains { $0 == ("-R", "lwLabelHeight-default") })
        #expect(plan.cleared.isSuperset(of: ["lwLabelWidth", "lwLabelHeight"]))
        #expect(plan.expected["PageSize"] == nil)
        // Neue Warteschlange: kein -R (wirkt nur auf vorhandene).
        let fresh = QueueDefaults.plan(settings: .default, language: nil, removingStale: false)
        #expect(!fresh.arguments.contains("-R"))
    }

    @Test("Werte außerhalb der PPD-Auswahl: nächstliegende Wahl plus exakter Warteschlangen-Standard")
    func approximated() {
        var settings = PrintSettings.default
        settings.labelTop = 37
        let plan = QueueDefaults.plan(settings: settings, language: nil, removingStale: true, resolution: .dpi203)
        #expect(plan.arguments.contains("lwLabelTop=40"))
        #expect(plan.arguments.contains("lwLabelTop-default=37"))
        #expect(plan.approximated == [CUPSOptionName.labelTop])
    }

    @Test("Abgleich: alles gleich")
    func differenceNone() {
        let plan = QueueDefaults.plan(settings: .default, language: .zpl, removingStale: true, resolution: .dpi203,
                                      labelSize: size)
        var current = plan.expected
        current["lwStartCmd"] = nil
        let difference = QueueDefaults.difference(plan, current: current,
                                                  pageSizeChoices: ["w295h216", "w288h432"], basePageSizes: ["w288h432"])
        #expect(difference.isEmpty)
        #expect(!difference.needsPPD)
    }

    @Test("Abgleich: alte Warteschlange ohne ergänzte Größe und ohne lwLabelWidth")
    func differenceOldQueue() {
        let plan = QueueDefaults.plan(settings: .default, language: .zpl, removingStale: true, resolution: .dpi203,
                                      labelSize: size)
        var current = plan.expected
        current["PageSize"] = "w288h432"
        current["lwLabelWidth"] = nil
        current["lwLabelHeight"] = nil
        let difference = QueueDefaults.difference(plan, current: current, pageSizeChoices: ["w288h432", "w288h216"],
                                                  basePageSizes: ["w288h432", "w288h216"])
        #expect(difference.missingPageSize)
        #expect(difference.needsPPD)
        #expect(difference.mismatchedOptions == ["PageSize", "lwLabelHeight", "lwLabelWidth"])
    }

    @Test("Abgleich: veraltete ergänzte Größe")
    func differenceStale() {
        let catalog = QueueLabelSize(widthMM: 101.6, heightMM: 152.4)
        let plan = QueueDefaults.plan(settings: .default, language: nil, removingStale: true, labelSize: catalog)
        var current = plan.expected
        current["PageSize"] = "w288h432"
        let difference = QueueDefaults.difference(plan, current: current,
                                                  pageSizeChoices: ["w295h216", "w288h432", "Custom.WIDTHxHEIGHT"],
                                                  basePageSizes: ["w288h432"])
        #expect(!difference.missingPageSize)
        #expect(difference.stalePageSizes == ["w295h216"])
        #expect(difference.needsPPD)
        #expect(difference.mismatchedOptions.isEmpty)
    }

    @Test("Abgleich: abweichende Option und gesetzter, nicht gewünschter Startbefehl")
    func differenceOptions() {
        let plan = QueueDefaults.plan(settings: .default, language: nil, removingStale: true, labelSize: size)
        var current = plan.expected
        current[CUPSOptionName.darkness] = "20"
        current[CUPSOptionName.startCommands] = "XlhB"
        let difference = QueueDefaults.difference(plan, current: current, pageSizeChoices: ["w295h216"])
        #expect(difference.mismatchedOptions == [CUPSOptionName.darkness, CUPSOptionName.startCommands])
        #expect(!difference.needsPPD)
    }

    @Test("Abgleich: Option, die die PPD nicht kennt, zählt nicht")
    func differenceUnknownPPDOption() {
        let plan = QueueDefaults.plan(settings: .default, language: nil, removingStale: true, labelSize: size)
        var current = plan.expected
        current[CUPSOptionName.cutEvery] = nil
        let difference = QueueDefaults.difference(plan, current: current, pageSizeChoices: ["w295h216"])
        #expect(difference.isEmpty)
    }
}

@Suite("Seitengrößen der LabelWerk-PPDs (wie generate_ppds.py)")
struct PPDPageSizesTests {

    @Test("Dateinamen")
    func names() throws {
        let model = try #require(PPDPageSizes.target(forPPDNamed: "/Library/x/LabelWerk-zd421t-203dpi.ppd.gz"))
        #expect(model.target == .model("zd421t") && model.dpi == 203)
        let generic = try #require(PPDPageSizes.target(forPPDNamed: "LabelWerk-generic-epl-203dpi.ppd"))
        #expect(generic.target == .generic(.epl))
        #expect(PPDPageSizes.target(forPPDNamed: "Other-zd421t-203dpi.ppd") == nil)
        #expect(PPDPageSizes.target(forPPDNamed: "LabelWerk-generic-xyz-203dpi") == nil)
        #expect(PPDPageSizes.Target.model("zd421t").stem(resolution: .dpi300) == "LabelWerk-zd421t-300dpi")
        #expect(PPDPageSizes.Target(lwModel: "generic-zpl") == .generic(.zpl))
    }

    @Test("ZD421t: Katalogformate, 104 × 76,2 mm fehlt")
    func zd421t() throws {
        let entries = try #require(PPDPageSizes.entries(for: .model("zd421t")))
        let keywords = entries.map(\.keyword)
        #expect(keywords.first == "w288h432")
        #expect(keywords.contains("w288h216"))
        #expect(!keywords.contains("w295h216"))
        #expect(Set(keywords).count == keywords.count)
        #expect(PPDPageSizes.defaultKeyword(for: .model("zd421t")) == "w288h432")
        #expect(PPDPageSizes.keywords(forPPDNamed: "LabelWerk-zd421t-203dpi") == keywords)
        let catalogStock = try #require(ModelCatalog.shared.stock(id: "w4h6in"))
        #expect(PPDPageSizes.contains(catalogStock, target: .model("zd421t")))
        #expect(PPDPageSizes.entries(for: .model("gibt-es-nicht")) == nil)
    }

    @Test("Generische PPDs nutzen die größten Werte der Sprache")
    func generic() throws {
        let zpl = try #require(PPDPageSizes.entries(for: .generic(.zpl)))
        let zd421 = try #require(PPDPageSizes.entries(for: .model("zd421t")))
        #expect(zpl.count >= zd421.count)
    }

    @Test("Zusammenführen gleicher Schlüsselwörter: das Standardformat gewinnt")
    func merging() {
        let a = LabelStock(id: "a", name: "A", widthMM: 100, heightMM: 50)
        let b = LabelStock(id: "b", name: "B", widthMM: 99.9, heightMM: 50)    // gleiches w283h142
        let c = LabelStock(id: "c", name: "C", widthMM: 300, heightMM: 50)     // zu breit
        let catalog = ModelCatalog(models: [], stocks: [a, b, c])
        let byDefault = PPDPageSizes.entries(printWidthMM: 104, maxLabelLengthMM: 991, defaultStock: b, catalog: catalog)
        #expect(byDefault.map(\.keyword) == [a.ppdKeyword])
        #expect(byDefault.first?.stock.id == "b")
        #expect(byDefault.first?.mergedStockIDs == ["a"])
        let withWide = PPDPageSizes.entries(printWidthMM: 104, maxLabelLengthMM: 991, defaultStock: c, catalog: catalog)
        #expect(withWide.map(\.stock.id) == ["a", "c"])
    }
}

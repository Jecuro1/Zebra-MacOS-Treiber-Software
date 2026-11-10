import Foundation
import Testing
@testable import LabelWerkCore

/// „An Etikett anpassen“ (`lwFitToLabel`, `lwLabelWidth`, `lwLabelHeight`): Werte, CUPS-Optionen
/// (§9, gelesen wie C-Filter und Python-Referenz), Etikettengröße aus dem Format, Dekodieren.
@Suite("An Etikett anpassen (Optionen)")
struct LabelFitOptionsTests {

    @Test("LabelFitMode: CUPS-Werte und deutsche Bezeichnungen")
    func mode() {
        #expect(LabelFitMode.allCases.map(\.cupsValue) == ["Auto", "Off"])
        #expect(LabelFitMode.auto.displayName == "Automatisch" && LabelFitMode.off.displayName == "Aus")
        #expect(LabelFitMode(cupsValue: " off\t") == .off)
        #expect(LabelFitMode(cupsValue: "AUTO") == .auto)
        #expect(LabelFitMode(cupsValue: "Default") == nil && LabelFitMode(cupsValue: "True") == nil)
        #expect(PrintSettings().fitToLabel == .auto, "Standard: automatisch anpassen")
    }

    @Test("CUPS-Optionen schreiben: Auto/Off immer, Größe nur > 0")
    func writeOptions() {
        let plain = PrintSettings().cupsOptions()
        #expect(plain[CUPSOptionName.fitToLabel] == "Auto")
        #expect(plain[CUPSOptionName.labelWidth] == nil && plain[CUPSOptionName.labelHeight] == nil)
        var s = PrintSettings(fitToLabel: .off)
        s.setLabelSize(widthMM: 104, heightMM: 76.2)
        let o = s.cupsOptions()
        #expect(o[CUPSOptionName.fitToLabel] == "Off")
        #expect(o[CUPSOptionName.labelWidth] == "10400" && o[CUPSOptionName.labelHeight] == "7620")
        #expect(PrintSettings(cupsOptions: o) == s)
        let widthOnly = PrintSettings(labelWidthHundredthsMM: 8000).cupsOptions()
        #expect(widthOnly[CUPSOptionName.labelWidth] == "8000" && widthOnly[CUPSOptionName.labelHeight] == nil)
        #expect(PrintSettings(cupsOptions: widthOnly) == PrintSettings(labelWidthHundredthsMM: 8000))
    }

    @Test("CUPS-Optionen lesen wie lw_parse_int/lw_parse_fit_mode: Custom., Vorzeichen, Leerraum, Begrenzung")
    func readOptions() {
        let s = PrintSettings(cupsOptions: ["lwFitToLabel": " OFF ", "lwLabelWidth": "Custom.10400",
                                            "lwLabelHeight": " +7620\n"])
        #expect(s.fitToLabel == .off && s.labelWidthHundredthsMM == 10400 && s.labelHeightHundredthsMM == 7620)
        let clamped = PrintSettings(cupsOptions: ["lwLabelWidth": "999999", "lwLabelHeight": "-5"])
        #expect(clamped.labelWidthHundredthsMM == PrintSettings.maxLabelSizeHundredthsMM)
        #expect(clamped.labelHeightHundredthsMM == 0)
        let invalid = PrintSettings(cupsOptions: ["lwFitToLabel": "Yes", "lwLabelWidth": "104 mm",
                                                  "lwLabelHeight": "76.2"])
        #expect(invalid.fitToLabel == .auto && invalid.labelWidthHundredthsMM == 0 && invalid.labelHeightHundredthsMM == 0)
        #expect(PrintSettings(cupsOptions: ["lwFitToLabel": "Default", "lwLabelWidth": "Default"])
            == PrintSettings())
    }

    @Test("Etikettengröße aus dem Format: gerundet, Endlosmaterial ohne Länge, nil → unbekannt")
    func labelSizeFromStock() {
        let stock = LabelStock(id: "eigen", name: "Benutzerdefiniert 104 × 76,2 mm", widthMM: 104, heightMM: 76.2)
        let s = PrintSettings(darkness: 20).withLabelSize(of: stock)
        #expect(s.labelWidthHundredthsMM == 10400 && s.labelHeightHundredthsMM == 7620)
        #expect(s.darkness == 20, "übrige Einstellungen bleiben")
        #expect(s.labelSizeMM?.width == 104 && s.labelSizeMM?.height == 76.2)
        let receipt = LabelStock(id: "c80", name: "Beleg 80 mm", widthMM: 80, heightMM: 200, tracking: .continuous)
        let r = PrintSettings().withLabelSize(of: receipt)
        #expect(r.labelWidthHundredthsMM == 8000 && r.labelHeightHundredthsMM == 0)
        let none = s.withLabelSize(of: nil)
        #expect(none.labelWidthHundredthsMM == 0 && none.labelHeightHundredthsMM == 0 && none.labelSizeMM == nil)
        var odd = PrintSettings()
        odd.setLabelSize(widthMM: 101.6049, heightMM: .nan)
        #expect(odd.labelWidthHundredthsMM == 10160 && odd.labelHeightHundredthsMM == 0)
        odd.setLabelSize(widthMM: 5000, heightMM: -1)
        #expect(odd.labelWidthHundredthsMM == 100_000 && odd.labelHeightHundredthsMM == 0)
        if let catalog = ModelCatalog.shared.stock(id: "w4h6in") {
            let fromCatalog = PrintSettings().withLabelSize(of: catalog)
            #expect(fromCatalog.labelWidthHundredthsMM == 10160 && fromCatalog.labelHeightHundredthsMM == 15240)
        }
    }

    @Test("JSON: ältere Einstellungen ohne neue Felder → Auto, Größe unbekannt; ungültige Werte tolerant")
    func decoding() throws {
        let old = Data(#"{"darkness":20,"mirror":false,"negative":false,"rotate180":false,"dither":"threshold","threshold":128,"compression":"z64","cutEvery":0,"calibrateBeforeJob":false,"saveToPrinter":false,"skipBlankLabels":false,"startCommands":"","endCommands":""}"#.utf8)
        let s = try JSONDecoder().decode(PrintSettings.self, from: old)
        #expect(s.fitToLabel == .auto && s.labelWidthHundredthsMM == 0 && s.labelHeightHundredthsMM == 0)
        let odd = Data(#"{"fitToLabel":"sometimes","labelWidthHundredthsMM":-3,"labelHeightHundredthsMM":250000}"#.utf8)
        let t = try JSONDecoder().decode(PrintSettings.self, from: odd)
        #expect(t.fitToLabel == .auto && t.labelWidthHundredthsMM == 0 && t.labelHeightHundredthsMM == 100_000)
        var full = PrintSettings(fitToLabel: .off)
        full.setLabelSize(widthMM: 104, heightMM: 76.2)
        #expect(try JSONDecoder().decode(PrintSettings.self, from: JSONEncoder().encode(full)) == full)
    }
}

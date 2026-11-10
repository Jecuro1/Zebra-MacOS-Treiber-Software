import Foundation
import Testing
@testable import LabelWerkCore

@Suite("Etikettentypen")
struct LabelTypeTests {
    /// Format des Druckers: 104 × 76,2 mm, Einzeletiketten.
    let printerStock = LabelStock(id: "w104h76", name: "104 × 76,2 mm", widthMM: 104, heightMM: 76.2,
                                  tracking: .gap, isCustom: false)
    /// Brillenetikett (Schmucketikett mit Steg): 22 × 13 mm Druckfläche, Thermotransfer.
    let opticianStock = LabelStock(id: "custom-optic", name: "Brillenetikett", widthMM: 22, heightMM: 13,
                                   gapMM: 2, tracking: .gap, mediaType: .thermalTransfer, category: .jewelry)

    // MARK: Kodierung

    @Test("Round Trip mit allen Abweichungen")
    func roundTrip() throws {
        let type = LabelType(name: "Brillenetikett", stockID: "custom-optic",
                             overrides: LabelTypeOverrides(rotation: .r90, darkness: 22, speed: 3,
                                                           mediaTracking: .blackMark, mediaType: .thermalTransfer,
                                                           printMode: .peelOff, labelTop: -12, labelLeft: 8,
                                                           tearOffAdjust: 4, mirror: true, negative: false,
                                                           fitToLabel: .off),
                             queueName: "Zebra_ZD421t_Brillenetikett")
        let decoded = try JSONDecoder().decode(LabelType.self, from: JSONEncoder().encode(type))
        #expect(decoded == type)
        #expect(decoded.overrides.count == 12)
    }

    @Test("Tolerant: fehlende und unbekannte Werte, Pflicht nur Kennung und Format")
    func tolerantDecoding() throws {
        let id = UUID()
        let json = #"{"id": "\#(id.uuidString)", "stockID": "w2h1in", "overrides": {"darkness": 18, "printMode": "zukunftsmodus", "rotation": 45}, "queueName": "  ", "neu": true}"#
        let type = try JSONDecoder().decode(LabelType.self, from: Data(json.utf8))
        #expect(type.id == id)
        #expect(type.name == "")
        #expect(type.stockID == "w2h1in")
        #expect(type.overrides == LabelTypeOverrides(darkness: 18))
        #expect(type.queueName == nil)

        let brokenOverrides = #"{"id": "\#(id.uuidString)", "stockID": "x", "name": "A", "overrides": 5}"#
        let fallback = try JSONDecoder().decode(LabelType.self, from: Data(brokenOverrides.utf8))
        #expect(fallback.overrides.isEmpty)

        let missingStock = #"{"id": "\#(id.uuidString)", "name": "A"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LabelType.self, from: Data(missingStock.utf8)) }
        let missingID = #"{"stockID": "x", "name": "A"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LabelType.self, from: Data(missingID.utf8)) }
    }

    @Test("Ohne Abweichungen werden keine Schlüssel geschrieben")
    func emptyOverridesEncoding() throws {
        let data = try JSONEncoder().encode(LabelTypeOverrides())
        #expect(String(decoding: data, as: UTF8.self) == "{}")
        #expect(LabelTypeOverrides().isEmpty)
        #expect(LabelTypeOverrides().count == 0)
    }

    // MARK: Abweichungen

    @Test("Abweichungen ersetzen nur ihre Werte, begrenzt auf gültige Bereiche")
    func overridesApplied() {
        let base = PrintSettings(darkness: 10, speed: 4, mediaType: .directThermal, tracking: .gap, printMode: .tearOff,
                                 labelTop: 5, labelLeft: 0, tearOffAdjust: 0, mirror: false, negative: true,
                                 rotate180: true, dither: .atkinson, threshold: 100, cutEvery: 3)
        let overrides = LabelTypeOverrides(rotation: .r90, darkness: 45, labelLeft: 20, negative: false)
        let s = overrides.applied(to: base)
        #expect(s.rotation == .r90)
        #expect(!s.rotate180)
        #expect(s.effectiveRotation == .r90)
        #expect(s.darkness == 30)            // begrenzt
        #expect(s.labelLeft == 20)
        #expect(!s.negative)
        // Unverändert („wie Drucker“):
        #expect(s.speed == 4)
        #expect(s.mediaType == .directThermal)
        #expect(s.tracking == .gap)
        #expect(s.printMode == .tearOff)
        #expect(s.labelTop == 5)
        #expect(s.dither == .atkinson)
        #expect(s.threshold == 100)
        #expect(s.cutEvery == 3)
        #expect(LabelTypeOverrides().applied(to: base) == base.clamped())
    }

    @Test("Drehung 0° hebt das ältere „um 180° drehen“ des Druckers auf")
    func rotationZeroClearsLegacyFlag() {
        var base = PrintSettings.default
        base.rotate180 = true
        #expect(base.effectiveRotation == .r180)
        let s = LabelTypeOverrides(rotation: .r0).applied(to: base)
        #expect(s.effectiveRotation == .r0)
    }

    // MARK: Wirksame Einstellungen

    @Test("Anderes Format: Medientyp und Druckmodus folgen dem Format, Größe aus dem Format")
    func settingsFollowTypeStock() {
        let printer = PrintSettings(darkness: 12, mediaType: .directThermal, tracking: .gap)
        let type = LabelType(name: "Brillenetikett", stockID: opticianStock.id)
        let s = type.settings(printerSettings: printer, printerStock: printerStock, stock: opticianStock)
        #expect(s.tracking == .gap)
        #expect(s.mediaType == .thermalTransfer)
        #expect(s.darkness == 12)
        #expect(s.labelWidthHundredthsMM == 2200)
        #expect(s.labelHeightHundredthsMM == 1300)

        // Endlosmaterial: Medientyp folgt, Länge 0 (der Treiber passt nur die Breite an).
        let receipt = LabelStock(id: "r80", name: "Beleg", widthMM: 80, heightMM: 200, tracking: .continuous)
        let r = LabelType(name: "Beleg", stockID: receipt.id)
            .settings(printerSettings: PrintSettings(), printerStock: printerStock, stock: receipt)
        #expect(r.tracking == .continuous)
        #expect(r.labelWidthHundredthsMM == 8000)
        #expect(r.labelHeightHundredthsMM == 0)
    }

    @Test("„Druckerwert“ bleibt, wenn das Format nichts anderes verlangt")
    func printerValueKept() {
        let other = LabelStock(id: "w50h25", name: "50 × 25", widthMM: 50, heightMM: 25, tracking: .gap)
        let printer = PrintSettings()  // tracking/mediaType = Druckerwert
        let s = LabelType(name: "Klein", stockID: other.id)
            .settings(printerSettings: printer, printerStock: printerStock, stock: other)
        #expect(s.tracking == nil)
        #expect(s.mediaType == nil)
    }

    @Test("Gleiches Format: Einstellungen des Druckers bleiben, Abweichungen haben Vorrang")
    func sameStock() {
        let printer = PrintSettings(tracking: .blackMark, markOffset: 16)
        let plain = LabelType(name: "Standard", stockID: printerStock.id)
        let s = plain.settings(printerSettings: printer, printerStock: printerStock, stock: printerStock)
        #expect(s.tracking == .blackMark)
        #expect(s.markOffset == 16)
        #expect(s.labelWidthHundredthsMM == 10400)
        #expect(s.labelHeightHundredthsMM == 7620)

        let overridden = LabelType(name: "Endlos", stockID: opticianStock.id,
                                   overrides: LabelTypeOverrides(mediaTracking: .notch, mediaType: .directThermal))
        let o = overridden.settings(printerSettings: printer, printerStock: printerStock, stock: opticianStock)
        #expect(o.tracking == .notch)
        #expect(o.mediaType == .directThermal)
    }

    @Test("Unbekanntes Format: Größe unbekannt, nur Abweichungen")
    func unknownStock() {
        var printer = PrintSettings(darkness: 8)
        printer.setLabelSize(widthMM: 104, heightMM: 76.2)
        let s = LabelType(name: "X", stockID: "fehlt", overrides: LabelTypeOverrides(speed: 2))
            .settings(printerSettings: printer, printerStock: printerStock, stock: nil)
        #expect(s.labelSizeMM == nil)
        #expect(s.speed == 2)
        #expect(s.darkness == 8)
    }

    // MARK: Warteschlange

    @Test("Plan der Warteschlange eines Typs: Größe, lwLabelWidth/Height und Abweichungen")
    func queuePlan() {
        let printer = PrintSettings(darkness: 15, speed: 4, tracking: .gap)
        let type = LabelType(name: "Brillenetikett", stockID: opticianStock.id,
                             overrides: LabelTypeOverrides(rotation: .r180, darkness: 25, labelTop: 37))
        let settings = type.settings(printerSettings: printer, printerStock: printerStock, stock: opticianStock)
        let size = QueueLabelSize(stock: opticianStock)
        let plan = QueueDefaults.plan(settings: settings, language: .zpl, removingStale: true, resolution: .dpi203,
                                      labelSize: size, maxSpeed: 6)
        let pairs = stride(from: 0, to: plan.arguments.count - 1, by: 1).map { (plan.arguments[$0], plan.arguments[$0 + 1]) }
        #expect(size.keyword == "w62h37")
        #expect(pairs.contains { $0 == ("-o", "PageSize=w62h37") })
        #expect(pairs.contains { $0 == ("-o", "lwLabelWidth-default=2200") })
        #expect(pairs.contains { $0 == ("-o", "lwLabelHeight-default=1300") })
        #expect(pairs.contains { $0 == ("-o", "lwDarkness=25") })
        #expect(pairs.contains { $0 == ("-o", "lwRotation=180") })
        #expect(pairs.contains { $0 == ("-o", "lwMediaType=ThermalTransfer") })
        #expect(pairs.contains { $0 == ("-o", "lwSpeed=4") })
        // 37 liegt nicht in der Auswahl (Schritte von 10): nächstliegende Wahl plus exakter Standard.
        #expect(pairs.contains { $0 == ("-o", "lwLabelTop=40") })
        #expect(pairs.contains { $0 == ("-o", "lwLabelTop-default=37") })
        #expect(plan.expected["PageSize"] == "w62h37")
        #expect(plan.expected["lwFitToLabel"] == "Auto")
    }

    @Test("Name der Warteschlange: Drucker + Kürzel, Umlaute umschrieben")
    func queueName() {
        #expect(LabelTypeQueueNaming.queueName(baseQueue: "Zebra_ZD421t", typeName: "Brillenetikett", existing: [])
            == "Zebra_ZD421t_Brillenetikett")
        #expect(LabelTypeQueueNaming.queueName(baseQueue: "Zebra_ZD421t", typeName: "Größe Ölkännchen / Café #1",
                                               existing: []) == "Zebra_ZD421t_Groesse_Oelkaennchen_Cafe_1")
        #expect(LabelTypeQueueNaming.slug("  ") == LabelTypeQueueNaming.fallbackSlug)
        #expect(LabelTypeQueueNaming.slug("日本") == LabelTypeQueueNaming.fallbackSlug)
        #expect(LabelTypeQueueNaming.slug("Schmuck-Etikett 22.5") == "Schmuck-Etikett_22.5")
    }

    @Test("Name der Warteschlange: eindeutig ohne Groß-/Kleinschreibung")
    func queueNameUnique() {
        let existing = ["zebra_zd421t_brillenetikett", "Zebra_ZD421t_Brillenetikett_2", "Andere"]
        #expect(LabelTypeQueueNaming.queueName(baseQueue: "Zebra_ZD421t", typeName: "Brillenetikett",
                                               existing: existing) == "Zebra_ZD421t_Brillenetikett_3")
    }

    @Test("Name der Warteschlange: höchstens 127 Bytes, nur erlaubte Zeichen")
    func queueNameLength() {
        let longBase = String(repeating: "B", count: 140)
        let longType = String(repeating: "Typ", count: 50)
        let name = LabelTypeQueueNaming.queueName(baseQueue: longBase, typeName: longType, existing: [])
        #expect(name.utf8.count <= 127)
        #expect(LabelTypeQueueNaming.isValidQueueName(name))
        #expect(name.contains("_TypTypTy"))

        let taken = LabelTypeQueueNaming.queueName(baseQueue: longBase, typeName: longType, existing: [name])
        #expect(taken != name)
        #expect(taken.utf8.count <= 127)
        #expect(taken.hasSuffix("_2"))

        // Verbotene Zeichen im Druckerteil fallen weg.
        let odd = LabelTypeQueueNaming.queueName(baseQueue: "Büro Zebra#1", typeName: "A", existing: [])
        #expect(LabelTypeQueueNaming.isValidQueueName(odd))
        #expect(odd == "BüroZebra1_A")
        #expect(!LabelTypeQueueNaming.isValidQueueName("a b"))
        #expect(!LabelTypeQueueNaming.isValidQueueName("a/b"))
        #expect(!LabelTypeQueueNaming.isValidQueueName(""))
    }

    @Test("Beschreibung im Druckdialog: Drucker – Typ, Adressname → Modell")
    func queueDescription() {
        #expect(LabelTypeQueueNaming.description(printerName: "Zebra ZD421t", modelName: "Zebra ZD421t",
                                                 typeName: "Brillenetikett") == "Zebra ZD421t – Brillenetikett")
        #expect(LabelTypeQueueNaming.description(printerName: "10.62.13.19", modelName: "Zebra ZD421t",
                                                 host: "10.62.13.19", typeName: " Schmuck ") == "Zebra ZD421t – Schmuck")
        #expect(LabelTypeQueueNaming.description(printerName: "Laden", modelName: nil, typeName: "")
            == "Laden")
        #expect(LabelTypeQueueNaming.description(printerName: "", modelName: nil, typeName: "Typ") == "Typ")
    }
}

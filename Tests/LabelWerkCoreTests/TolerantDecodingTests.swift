import Foundation
import Testing
@testable import LabelWerkCore

@Suite("Tolerantes Dekodieren")
struct TolerantDecodingTests {
    @Test("Druckeinstellungen: fehlende und unbekannte Werte erhalten Standardwerte")
    func printSettings() throws {
        let json = #"{"darkness": 40, "dither": "kuenftigesVerfahren", "mirror": true, "neuesFeld": 1}"#
        let s = try JSONDecoder().decode(PrintSettings.self, from: Data(json.utf8))
        #expect(s.darkness == 30)          // begrenzt
        #expect(s.dither == .threshold)    // unbekannt → Standard
        #expect(s.mirror)
        #expect(s.compression == .z64)
        #expect(s.threshold == 128)
    }

    @Test("Druckeinstellungen: Round Trip bleibt verlustfrei")
    func roundTrip() throws {
        let original = PrintSettings(darkness: 12, speed: 4, mediaType: .thermalTransfer, tracking: .blackMark,
                                     printMode: .cutter, labelTop: -10, labelLeft: 20, tearOffAdjust: 5,
                                     backfeed: .off, mirror: true, negative: true, rotate180: true,
                                     dither: .atkinson, threshold: 100, compression: .acs, cutEvery: 3,
                                     calibrateBeforeJob: true, saveToPrinter: true, skipBlankLabels: true,
                                     startCommands: "^XA^XZ", endCommands: "~JR")
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test("Etikettenformat: nur Kennung, Name und Maße sind Pflicht")
    func labelStock() throws {
        let json = #"{"id": "x", "name": "Test", "widthMM": 50, "heightMM": 30, "tracking": "zukunft"}"#
        let stock = try JSONDecoder().decode(LabelStock.self, from: Data(json.utf8))
        #expect(stock.tracking == .gap)
        #expect(stock.gapMM == 3)
        #expect(stock.category == .custom)
        let missing = #"{"id": "x", "name": "Test"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LabelStock.self, from: Data(missing.utf8)) }
    }
}

import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// Byte-genaue Druckaufträge nach ARCHITECTURE.md §8. Alle erwarteten Ausgaben sind von Hand
/// aus der Spezifikation abgeleitet (nicht mit dem Encoder erzeugt).
@Suite("JobEncoder")
struct JobEncoderTests {

    /// 10 × 3: C0 00 / 00 40 / FF C0 — Hex „C0000040FFC0“, ACS „C,0040FFC0“
    static let pageA = TestSupport.bitmap([
        "##........",
        ".........#",
        "##########",
    ])
    /// 8 × 2: FF / 81 — Hex „FF81“, ACS „!81“
    static let pageB = TestSupport.bitmap([
        "########",
        "#......#",
    ])
    static let blank = MonoBitmap(width: 10, height: 3)

    static func zpl(_ settings: PrintSettings, maxWidth: Int? = nil) -> JobEncoder {
        JobEncoder(language: .zpl, resolution: .dpi203, settings: settings, maxPrintWidthDots: maxWidth)
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    static func expectEqual(_ actual: Data, _ expected: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(TestSupport.printable(actual) == TestSupport.printable(expected), sourceLocation: sourceLocation)
        #expect(actual == expected, sourceLocation: sourceLocation)
    }

    // MARK: - ZPL

    @Test("ZPL: Minimalauftrag (Hex, Standardwerte)")
    func zplMinimal() throws {
        let data = try Self.zpl(PrintSettings(compression: .hex)).encode(pages: [Self.pageA])
        #expect(Self.text(data) == """
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
        ^PQ1
        ^XZ

        """)
    }

    @Test("ZPL: alle Einstellungen gesetzt (ACS)")
    func zplAllSettings() throws {
        let settings = PrintSettings(
            darkness: 8, speed: 4, mediaType: .thermalTransfer, tracking: .blackMark, printMode: .cutter,
            labelTop: -12, labelLeft: 20, tearOffAdjust: -10, backfeed: .beforePrinting,
            mirror: true, negative: false, rotate180: true,
            dither: .stucki, threshold: 100, compression: .acs, cutEvery: 5,
            calibrateBeforeJob: true, saveToPrinter: true, skipBlankLabels: false,
            startCommands: "^XA^CI28^XZ", endCommands: "^XA^FXende^XZ")
        let data = try Self.zpl(settings).encode(pages: [Self.pageA], copies: 3)
        // ZPL spiegelt/dreht per ^PM/^PO – die Bitmap bleibt unverändert.
        #expect(Self.text(data) == """
        ^XA^CI28^XZ
        ~SD08
        ~TA-10
        ~JSB
        ~JC
        ^XA
        ^MMC
        ^MNM
        ^MTT
        ^PR4,4,4
        ^PW10
        ^LL3
        ^LH0,0
        ^LT-12
        ^LS20
        ^POI
        ^PMY
        ^FO0,0^GFA,6,6,2,C,0040FFC0^FS
        ^PQ3,5,0,Y
        ^JUS
        ^XZ
        ^XA^FXende^XZ

        """)
    }

    @Test("ZPL: Sortieren wiederholt die Seitenfolge, ^JUS nur beim ersten Etikett")
    func zplCollate() throws {
        let encoder = Self.zpl(PrintSettings(compression: .hex, saveToPrinter: true))
        let collated = try encoder.encode(pages: [Self.pageA, Self.pageB], copies: 2, collate: true)
        #expect(Self.text(collated) == """
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
        ^PQ1
        ^JUS
        ^XZ
        ^XA
        ^PW8
        ^LL2
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,2,2,1,FF81^FS
        ^PQ1
        ^XZ
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
        ^PQ1
        ^XZ
        ^XA
        ^PW8
        ^LL2
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,2,2,1,FF81^FS
        ^PQ1
        ^XZ

        """)
        let uncollated = try encoder.encode(pages: [Self.pageA, Self.pageB], copies: 2, collate: false)
        #expect(Self.text(uncollated) == """
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
        ^PQ2
        ^JUS
        ^XZ
        ^XA
        ^PW8
        ^LL2
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,2,2,1,FF81^FS
        ^PQ2
        ^XZ

        """)
        // Eine Seite + Sortieren → ^PQ{copies}
        let single = try Self.zpl(PrintSettings(compression: .acs, cutEvery: 2)).encode(pages: [Self.pageB], copies: 7, collate: true)
        #expect(Self.text(single) == """
        ^XA
        ^PW8
        ^LL2
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,2,2,1,!81^FS
        ^PQ7,2,0,Y
        ^XZ

        """)
    }

    @Test("Viele sortierte Kopien: Seitenfolge wird vollständig wiederholt")
    func manyCollatedCopies() throws {
        let encoder = Self.zpl(PrintSettings(compression: .acs))
        let text = Self.text(try encoder.encode(pages: [Self.pageA, Self.pageB], copies: 1_000, collate: true))
        #expect(text.components(separatedBy: "^XA\n").count - 1 == 2_000)
        #expect(text.components(separatedBy: "^PQ1\n").count - 1 == 2_000)
        #expect(text.components(separatedBy: "^GFA,6,6,2,C,0040FFC0^FS").count - 1 == 1_000)
        // Ohne Seiten: keine Etiketten, unabhängig von der Kopienzahl
        #expect(try encoder.encode(pages: [], copies: 5, collate: true).isEmpty)
        // LabelSequence direkt
        let order = Array(LabelSequence(pageCount: 3, repetitions: 2, quantity: 1)).map { "\($0.page)×\($0.quantity)" }
        #expect(order == ["0×1", "1×1", "2×1", "0×1", "1×1", "2×1"])
        #expect(Array(LabelSequence(pageCount: 2, repetitions: 1, quantity: 9)).map(\.quantity) == [9, 9])
        #expect(Array(LabelSequence(pageCount: 0, repetitions: 4, quantity: 1)).isEmpty)
    }

    @Test("ZPL: leere Etiketten überspringen (vor dem Zählen der Seiten)")
    func zplSkipBlank() throws {
        let skip = try Self.zpl(PrintSettings(compression: .hex, skipBlankLabels: true))
            .encode(pages: [Self.blank, Self.pageA, Self.blank], copies: 2, collate: true)
        // Nur eine Seite übrig → keine Wiederholung, ^PQ2
        #expect(Self.text(skip) == """
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
        ^PQ2
        ^XZ

        """)
        // Ohne skipBlank wird das leere Etikett gedruckt
        let keep = try Self.zpl(PrintSettings(compression: .hex)).encode(pages: [Self.blank])
        #expect(Self.text(keep) == """
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,000000000000^FS
        ^PQ1
        ^XZ

        """)
        // Alles übersprungen → nur Start-/Endbefehle
        let none = try Self.zpl(PrintSettings(compression: .hex, skipBlankLabels: true, startCommands: "~JA", endCommands: "~PS"))
            .encode(pages: [Self.blank, Self.blank])
        #expect(Self.text(none) == "~JA\n~PS\n")
    }

    @Test("ZPL: Negativ vor dem Überspringen; Füllbits bleiben 0")
    func zplNegative() throws {
        let encoder = Self.zpl(PrintSettings(negative: true, compression: .hex, skipBlankLabels: true))
        // Invertiertes Leeretikett ist schwarz → wird gedruckt
        let data = try encoder.encode(pages: [Self.blank, Self.pageA])
        #expect(Self.text(data) == """
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,FFC0FFC0FFC0^FS
        ^PQ1
        ^XZ
        ^XA
        ^PW10
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,3FC0FF800000^FS
        ^PQ1
        ^XZ

        """)
        // Ganz schwarzes Etikett wird durch Negativ leer → übersprungen
        let black = Self.blank.inverted()
        #expect(Self.text(try encoder.encode(pages: [black])) == "")
    }

    @Test("ZPL: rechts auf maxPrintWidthDots abschneiden")
    func zplCrop() throws {
        let data = try Self.zpl(PrintSettings(compression: .hex), maxWidth: 8).encode(pages: [Self.pageA])
        #expect(Self.text(data) == """
        ^XA
        ^PW8
        ^LL3
        ^LH0,0
        ^PON
        ^PMN
        ^FO0,0^GFA,3,3,1,C000FF^FS
        ^PQ1
        ^XZ

        """)
        // Breitere Grenze bzw. 0/nil → unverändert
        let unchanged = try Self.zpl(PrintSettings(compression: .hex)).encode(pages: [Self.pageA])
        #expect(try Self.zpl(PrintSettings(compression: .hex), maxWidth: 832).encode(pages: [Self.pageA]) == unchanged)
        #expect(try Self.zpl(PrintSettings(compression: .hex), maxWidth: 0).encode(pages: [Self.pageA]) == unchanged)
        // Abschneiden vor dem Leer-Test: rechts liegende Punkte verschwinden → leer → übersprungen
        let rightOnly = TestSupport.bitmap(["........##"])
        #expect(try Self.zpl(PrintSettings(compression: .hex, skipBlankLabels: true), maxWidth: 8).encode(pages: [rightOnly]).isEmpty)
    }

    @Test("ZPL: Zahlenformate ~SD, ~TA, Begrenzungen", arguments: [
        (PrintSettings(darkness: 0, tearOffAdjust: 0), "~SD00\n~TA000\n"),
        (PrintSettings(darkness: 8, tearOffAdjust: 10), "~SD08\n~TA010\n"),
        (PrintSettings(darkness: 30, tearOffAdjust: -5), "~SD30\n~TA-05\n"),
        (PrintSettings(darkness: 15, tearOffAdjust: -10), "~SD15\n~TA-10\n"),
        (PrintSettings(darkness: 29, tearOffAdjust: 120), "~SD29\n~TA120\n"),
        (PrintSettings(darkness: 99, tearOffAdjust: -500), "~SD30\n~TA-120\n"),   // begrenzt auf 0…30 bzw. −120…120
        (PrintSettings(darkness: -4, tearOffAdjust: 7), "~SD00\n~TA007\n"),
        (PrintSettings(tearOffAdjust: -1), "~TA-01\n"),
        (PrintSettings(darkness: 3), "~SD03\n"),
    ])
    func zplNumberFormats(settings: PrintSettings, expectedPrefix: String) throws {
        let data = try Self.zpl(settings).encode(pages: [])
        #expect(Self.text(data) == expectedPrefix)
    }

    @Test("ZPL: Begrenzung von Geschwindigkeit und Versätzen")
    func zplClamping() throws {
        let settings = PrintSettings(speed: 20, labelTop: -500, labelLeft: 12_000, compression: .hex, cutEvery: 20_000)
        let text = Self.text(try Self.zpl(settings).encode(pages: [Self.pageB], copies: 0))
        #expect(text == """
        ^XA
        ^PR14,14,14
        ^PW8
        ^LL2
        ^LH0,0
        ^LT-120
        ^LS9999
        ^PON
        ^PMN
        ^FO0,0^GFA,2,2,1,FF81^FS
        ^PQ1,9999,0,Y
        ^XZ

        """)
    }

    @Test("ZPL: Medien-/Modusbefehle einzeln", arguments: [
        (PrintSettings(compression: .hex, cutEvery: 0), ""),
        (PrintSettings(printMode: .peelOff, compression: .hex), "^MMP\n"),
        (PrintSettings(printMode: .kiosk, compression: .hex), "^MMK\n"),
        (PrintSettings(tracking: .continuous, compression: .hex), "^MNN\n"),
        (PrintSettings(tracking: .autoDetect, compression: .hex), "^MNA\n"),
        (PrintSettings(tracking: .gap, compression: .hex), "^MNY\n"),
        (PrintSettings(mediaType: .directThermal, compression: .hex), "^MTD\n"),
        (PrintSettings(speed: 1, compression: .hex), "^PR1,1,1\n"),
    ])
    func zplMediaCommands(settings: PrintSettings, expectedBlock: String) throws {
        let text = Self.text(try Self.zpl(settings).encode(pages: [Self.pageB]))
        #expect(text == "^XA\n" + expectedBlock + "^PW8\n^LL2\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,2,2,1,FF81^FS\n^PQ1\n^XZ\n")
    }

    @Test("ZPL: Rückzug als Steuerbefehl ~JS im Auftragskopf (nicht ^JS = Sensorwahl)", arguments: [
        (BackfeedMode.off, "~JSO\n"),
        (BackfeedMode.normal, "~JSN\n"),
        (BackfeedMode.afterPrinting, "~JSA\n"),
        (BackfeedMode.beforePrinting, "~JSB\n"),
    ])
    func zplBackfeedIsTildeCommand(mode: BackfeedMode, header: String) throws {
        let text = Self.text(try Self.zpl(PrintSettings(backfeed: mode, compression: .hex)).encode(pages: [Self.pageB]))
        #expect(text == header + "^XA\n^PW8\n^LL2\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,2,2,1,FF81^FS\n^PQ1\n^XZ\n")
        #expect(!text.contains("^JS"))
    }

    @Test("ZPL: Z64-Auftrag (Struktur + Dekodierung)")
    func zplZ64() throws {
        let data = try Self.zpl(PrintSettings()).encode(pages: [Self.pageA])
        let text = Self.text(data)
        let head = "^XA\n^PW10\n^LL3\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,6,6,2,:Z64:"
        let tail = "^FS\n^PQ1\n^XZ\n"
        #expect(text.hasPrefix(head))
        #expect(text.hasSuffix(tail))
        let z64 = ":Z64:" + text.dropFirst(head.count).dropLast(tail.count)
        #expect(try [UInt8](Z64.decode(z64)) == Self.pageA.data)
        #expect(z64.split(separator: ":").last?.count == 4)
    }

    @Test("ZPL: Graustufenbilder werden gemäß Einstellungen gerastert")
    func zplImages() throws {
        // Schwelle 128: 0 → schwarz, 255 → weiß
        let gray = Self.pageA.toGrayImage()
        let fromImages = try Self.zpl(PrintSettings(compression: .hex)).encode(images: [gray])
        let fromPages = try Self.zpl(PrintSettings(compression: .hex)).encode(pages: [Self.pageA])
        #expect(fromImages == fromPages)
        // Verfahren aus den Einstellungen (Halbton) wird verwendet
        let flat = GrayImage(width: 16, height: 8, fill: 128)
        let settings = PrintSettings(dither: .halftone, threshold: 128, compression: .hex)
        let expected = try Self.zpl(settings).encode(pages: [Ditherer.dither(flat, algorithm: .halftone, threshold: 128)])
        #expect(try Self.zpl(settings).encode(images: [flat]) == expected)
        // Schwelle wird aus den Einstellungen übernommen (und begrenzt)
        let mid = GrayImage(width: 8, height: 1, pixels: [0, 50, 100, 150, 200, 250, 254, 255])
        let t200 = Self.text(try Self.zpl(PrintSettings(threshold: 200, compression: .hex)).encode(images: [mid]))
        #expect(t200.contains("^GFA,1,1,1,F0^FS"))     // 0, 50, 100, 150 < 200
        let t999 = Self.text(try Self.zpl(PrintSettings(threshold: 999, compression: .hex)).encode(images: [mid]))
        #expect(t999.contains("^GFA,1,1,1,FC^FS"))     // T = 254: alles außer 254, 255
    }

    /// Regression: Seiten ohne Fläche ließen früher den ganzen Auftrag scheitern, während der
    /// C-Filter (`lw_job_add_page`) sie mit einer Warnung überspringt. Alle erwarteten Bytes
    /// stammen aus `rastertolabelwerk` (lw_job.c) mit denselben Eingaben.
    @Test("Seiten ohne Fläche werden wie im C-Filter übersprungen und nicht gezählt")
    func zeroSizedPagesAreSkipped() throws {
        let page = MonoBitmap(width: 8, height: 1, data: [0xFF])
        let label = "^XA\n^PW8\n^LL1\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,1,1,1,FF^FS\n"
        // [8×1 FF, 0×0], ZPL, Hex, 1 Kopie, Sortieren → vollständiger Auftrag statt Fehler
        let single = try Self.zpl(PrintSettings(compression: .hex))
            .encode(pages: [page, MonoBitmap(width: 0, height: 0)], copies: 1, collate: true)
        #expect(Self.text(single) == label + "^PQ1\n^XZ\n")
        // Übersprungene Seiten zählen nicht: eine verbleibende Seite → Menge = Kopien
        for zero in [MonoBitmap(width: 0, height: 5), MonoBitmap(width: 7, height: 0), MonoBitmap(width: 0, height: 0)] {
            let three = try Self.zpl(PrintSettings(compression: .hex)).encode(pages: [page, zero], copies: 3, collate: true)
            #expect(Self.text(three) == label + "^PQ3\n^XZ\n", "\(zero.width) × \(zero.height)")
        }
        // Zwei verbleibende Seiten → Seitenfolge wiederholen, je ^PQ1
        let pageB = MonoBitmap(width: 8, height: 2, data: [0xFF, 0x81])
        let labelB = "^XA\n^PW8\n^LL2\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,2,2,1,FF81^FS\n^PQ1\n^XZ\n"
        let collated = try Self.zpl(PrintSettings(compression: .hex))
            .encode(pages: [page, MonoBitmap(width: 0, height: 0), pageB], copies: 2, collate: true)
        #expect(Self.text(collated) == (label + "^PQ1\n^XZ\n" + labelB) + (label + "^PQ1\n^XZ\n" + labelB))
        // EPL und CPCL
        let epl = JobEncoder(language: .epl, resolution: .dpi203, settings: PrintSettings())
        Self.expectEqual(try epl.encode(pages: [page, MonoBitmap(width: 0, height: 3)], copies: 2, collate: true),
                         TestSupport.data(.text("\nN\nq8\nQ1,24\nZT\nGW0,0,1,1,"), .bytes([0x00]), .text("\nP2\n")))
        let cpcl = JobEncoder(language: .cpcl, resolution: .dpi203, settings: PrintSettings(negative: true))
        Self.expectEqual(try cpcl.encode(pages: [MonoBitmap(width: 9, height: 0), MonoBitmap(width: 8, height: 1, data: [0x0F])],
                                         copies: 2, collate: true),
                         TestSupport.data(.text("! 0 200 200 1 2\r\nPAGE-WIDTH 8\r\nCG 1 1 0 0 "), .bytes([0xF0]),
                                          .text("\r\nFORM\r\nPRINT\r\n")))
        // Nur Seiten ohne Fläche → nur Auftragskopf und Endbefehle (wie bei lauter leeren Seiten)
        let none = try Self.zpl(PrintSettings(darkness: 8, compression: .hex, startCommands: "~JA", endCommands: "~PS"))
            .encode(pages: [MonoBitmap(width: 0, height: 0), MonoBitmap(width: 0, height: 4)])
        #expect(Self.text(none) == "~JA\n~SD08\n~PS\n")
        // Auch ohne skipBlankLabels liefert die Vorschau-Vorverarbeitung nil
        let preview = JobEncoder(language: .epl, resolution: .dpi203, settings: PrintSettings(mirror: true, negative: true))
        #expect(preview.preprocess(MonoBitmap(width: 0, height: 2)) == nil)
        #expect(preview.preprocess(MonoBitmap(width: 5, height: 0)) == nil)
        #expect(preview.preprocess(page) == MonoBitmap(width: 8, height: 1))
    }

    // MARK: - EPL2

    @Test("EPL: Minimalauftrag")
    func eplMinimal() throws {
        let encoder = JobEncoder(language: .epl, resolution: .dpi203, settings: PrintSettings())
        let expected = TestSupport.data(
            .text("\nN\nq10\nQ3,24\nZT\nGW0,0,2,3,"),
            .bytes([0x3F, 0xFF, 0xFF, 0xBF, 0x00, 0x3F]),
            .text("\nP1\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageA]), expected)
    }

    @Test("EPL: alle Einstellungen (Spiegeln in der Bitmap, Drehen per ZB)")
    func eplAllSettings() throws {
        let settings = PrintSettings(
            darkness: 15, speed: 9, mediaType: .directThermal, tracking: .blackMark, printMode: .peelOff,
            labelTop: 30, labelLeft: 40, tearOffAdjust: 50, backfeed: .afterPrinting,
            mirror: true, rotate180: true, cutEvery: 3, calibrateBeforeJob: true, saveToPrinter: true,
            startCommands: "I8,B", endCommands: "OEPL1")
        // Lücke aus dem Etikettenformat: 2 mm bei 203 dpi = 15,98 → 16 Punkte
        let stock = LabelStock(id: "t", name: "Test", widthMM: 50, heightMM: 30, gapMM: 2)
        let encoder = JobEncoder(language: .epl, resolution: .dpi203, settings: settings, stock: stock)
        // Gespiegelte Seite A: 00 C0 / 80 00 / FF C0 → EPL invertiert: FF 3F / 7F FF / 00 3F
        let expected = TestSupport.data(
            .text("I8,B\n"),
            .text("\nN\nq10\nQ3,B16\nS6\nD8\nZB\nODP\nGW0,0,2,3,"),
            .bytes([0xFF, 0x3F, 0x7F, 0xFF, 0x00, 0x3F]),
            .text("\nP2\n"),
            .text("OEPL1\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageA], copies: 2), expected)
    }

    @Test("EPL: Q-Befehl je Medienerkennung", arguments: [
        (MediaTracking?.none, "Q2,24"),
        (MediaTracking.gap, "Q2,24"),
        (MediaTracking.autoDetect, "Q2,24"),
        (MediaTracking.blackMark, "Q2,B24"),
        (MediaTracking.continuous, "Q2,0"),
    ])
    func eplTracking(tracking: MediaTracking?, line: String) throws {
        let encoder = JobEncoder(language: .epl, resolution: .dpi203, settings: PrintSettings(tracking: tracking))
        let expected = TestSupport.data(.text("\nN\nq8\n\(line)\nZT\nGW0,0,1,2,"), .bytes([0x00, 0x7E]), .text("\nP1\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageB]), expected)
    }

    @Test("EPL: Lücke aus Etikettenformat bei 300 dpi")
    func eplStockGap300() throws {
        // 3 mm bei 300 dpi = 35,43 → 35
        let stock = LabelStock(id: "s", name: "S", widthMM: 50, heightMM: 25, gapMM: 3)
        let encoder = JobEncoder(language: .epl, resolution: .dpi300, settings: PrintSettings(), stock: stock)
        let expected = TestSupport.data(.text("\nN\nq8\nQ2,35\nZT\nGW0,0,1,2,"), .bytes([0x00, 0x7E]), .text("\nP1\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageB]), expected)
    }

    @Test("EPL: S/D/O-Zeilen", arguments: [
        (PrintSettings(darkness: 0), "D0\nZT\n"),
        (PrintSettings(darkness: 1), "D1\nZT\n"),
        (PrintSettings(darkness: 2), "D1\nZT\n"),
        (PrintSettings(darkness: 3), "D2\nZT\n"),
        (PrintSettings(darkness: 30), "D15\nZT\n"),
        (PrintSettings(speed: 1), "S1\nZT\n"),
        (PrintSettings(speed: 0), "S1\nZT\n"),
        (PrintSettings(speed: 6), "S6\nZT\n"),
        (PrintSettings(speed: 14), "S6\nZT\n"),
        (PrintSettings(mediaType: .thermalTransfer), "ZT\nO\n"),
        (PrintSettings(mediaType: .directThermal), "ZT\nOD\n"),
        (PrintSettings(printMode: .cutter), "ZT\nOC\n"),
        (PrintSettings(printMode: .delayedCut), "ZT\nO\n"),
        (PrintSettings(mediaType: .directThermal, printMode: .tearOff), "ZT\nOD\n"),
        (PrintSettings(mediaType: .thermalTransfer, printMode: .cutter), "ZT\nOC\n"),
        (PrintSettings(darkness: 20, speed: 3, rotate180: true), "S3\nD10\nZB\n"),
    ])
    func eplOptionLines(settings: PrintSettings, block: String) throws {
        let encoder = JobEncoder(language: .epl, resolution: .dpi203, settings: settings)
        let expected = TestSupport.data(.text("\nN\nq8\nQ2,24\n" + block + "GW0,0,1,2,"), .bytes([0x00, 0x7E]), .text("\nP1\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageB]), expected)
    }

    @Test("EPL: Sortieren wie bei ZPL")
    func eplCollate() throws {
        let encoder = JobEncoder(language: .epl, resolution: .dpi203, settings: PrintSettings())
        let a = TestSupport.data(.text("\nN\nq10\nQ3,24\nZT\nGW0,0,2,3,"), .bytes([0x3F, 0xFF, 0xFF, 0xBF, 0x00, 0x3F]), .text("\nP1\n"))
        let b = TestSupport.data(.text("\nN\nq8\nQ2,24\nZT\nGW0,0,1,2,"), .bytes([0x00, 0x7E]), .text("\nP1\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageA, Self.pageB], copies: 2, collate: true), a + b + a + b)
        let a3 = TestSupport.data(.text("\nN\nq10\nQ3,24\nZT\nGW0,0,2,3,"), .bytes([0x3F, 0xFF, 0xFF, 0xBF, 0x00, 0x3F]), .text("\nP3\n"))
        let b3 = TestSupport.data(.text("\nN\nq8\nQ2,24\nZT\nGW0,0,1,2,"), .bytes([0x00, 0x7E]), .text("\nP3\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageA, Self.pageB], copies: 3, collate: false), a3 + b3)
    }

    // MARK: - CPCL

    @Test("CPCL: Minimalauftrag bei 203 dpi (Auflösung 200)")
    func cpclMinimal() throws {
        let encoder = JobEncoder(language: .cpcl, resolution: .dpi203, settings: PrintSettings())
        let expected = TestSupport.data(
            .text("! 0 200 200 3 1\r\nPAGE-WIDTH 10\r\nCG 2 3 0 0 "),
            .bytes([0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0]),
            .text("\r\nFORM\r\nPRINT\r\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageA]), expected)
    }

    @Test("CPCL: alle Einstellungen bei 300 dpi (Spiegeln + Drehen in der Bitmap)")
    func cpclAllSettings() throws {
        let settings = PrintSettings(
            darkness: 15, speed: 9, mediaType: .directThermal, tracking: .continuous, printMode: .peelOff,
            labelTop: 10, mirror: true, negative: false, rotate180: true, cutEvery: 2,
            calibrateBeforeJob: true, saveToPrinter: true, startCommands: "! U1 setvar \"a\" \"b\"", endCommands: "END")
        let encoder = JobEncoder(language: .cpcl, resolution: .dpi300, settings: settings)
        // Spiegeln, dann 180° drehen = vertikal spiegeln: FF C0 / 00 40 / C0 00
        // Start-/Endbefehle sind für CPCL in §8 nicht vorgesehen.
        let expected = TestSupport.data(
            .text("! 0 300 300 3 4\r\nPAGE-WIDTH 10\r\nCONTRAST 2\r\nSPEED 5\r\nCG 2 3 0 0 "),
            .bytes([0xFF, 0xC0, 0x00, 0x40, 0xC0, 0x00]),
            .text("\r\nPRINT\r\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageA], copies: 4), expected)
    }

    @Test("CPCL: nur Drehen bzw. nur Spiegeln")
    func cpclRotateMirror() throws {
        let rotate = JobEncoder(language: .cpcl, resolution: .dpi203, settings: PrintSettings(rotate180: true))
        Self.expectEqual(try rotate.encode(pages: [Self.pageA]), TestSupport.data(
            .text("! 0 200 200 3 1\r\nPAGE-WIDTH 10\r\nCG 2 3 0 0 "),
            .bytes([0xFF, 0xC0, 0x80, 0x00, 0x00, 0xC0]),
            .text("\r\nFORM\r\nPRINT\r\n")))
        let mirror = JobEncoder(language: .cpcl, resolution: .dpi203, settings: PrintSettings(mirror: true))
        Self.expectEqual(try mirror.encode(pages: [Self.pageA]), TestSupport.data(
            .text("! 0 200 200 3 1\r\nPAGE-WIDTH 10\r\nCG 2 3 0 0 "),
            .bytes([0x00, 0xC0, 0x80, 0x00, 0xFF, 0xC0]),
            .text("\r\nFORM\r\nPRINT\r\n")))
    }

    static func cpcl(_ settings: PrintSettings, _ resolution: Resolution = .dpi203) -> JobEncoder {
        JobEncoder(language: .cpcl, resolution: resolution, settings: settings)
    }

    @Test("CPCL: CONTRAST, SPEED und Auflösungen", arguments: [
        (cpcl(PrintSettings(darkness: 0)), "! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 0\r\n"),
        (cpcl(PrintSettings(darkness: 4)), "! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 0\r\n"),
        (cpcl(PrintSettings(darkness: 5)), "! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 1\r\n"),
        (cpcl(PrintSettings(darkness: 14)), "! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 1\r\n"),
        (cpcl(PrintSettings(darkness: 25)), "! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 3\r\n"),
        (cpcl(PrintSettings(darkness: 30)), "! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 3\r\n"),
        (cpcl(PrintSettings(speed: 3), .dpi300), "! 0 300 300 2 1\r\nPAGE-WIDTH 8\r\nSPEED 3\r\n"),
        (cpcl(PrintSettings(speed: 5), .dpi600), "! 0 600 600 2 1\r\nPAGE-WIDTH 8\r\nSPEED 5\r\n"),
        (cpcl(PrintSettings(darkness: 20, speed: 2), .dpi300), "! 0 300 300 2 1\r\nPAGE-WIDTH 8\r\nCONTRAST 2\r\nSPEED 2\r\n"),
        (cpcl(PrintSettings(), .dpi152), "! 0 152 152 2 1\r\nPAGE-WIDTH 8\r\n"),
    ])
    func cpclOptionLines(encoder: JobEncoder, head: String) throws {
        let expected = TestSupport.data(.text(head + "CG 1 2 0 0 "), .bytes([0xFF, 0x81]), .text("\r\nFORM\r\nPRINT\r\n"))
        Self.expectEqual(try encoder.encode(pages: [Self.pageB]), expected)
    }

    @Test("CPCL: Sortieren, Negativ, Leer überspringen, Abschneiden")
    func cpclJobSemantics() throws {
        let settings = PrintSettings(negative: true, skipBlankLabels: true)
        let encoder = JobEncoder(language: .cpcl, resolution: .dpi203, settings: settings, maxPrintWidthDots: 8)
        // Seite A abgeschnitten (C0 / 00 / FF) und invertiert (3F / FF / 00); schwarze Seite → leer → übersprungen
        let page = TestSupport.data(
            .text("! 0 200 200 3 1\r\nPAGE-WIDTH 8\r\nCG 1 3 0 0 "),
            .bytes([0x3F, 0xFF, 0x00]),
            .text("\r\nFORM\r\nPRINT\r\n"))
        let b = TestSupport.data(
            .text("! 0 200 200 2 1\r\nPAGE-WIDTH 8\r\nCG 1 2 0 0 "),
            .bytes([0x00, 0x7E]),
            .text("\r\nFORM\r\nPRINT\r\n"))
        let black = MonoBitmap(width: 8, height: 4).inverted()
        Self.expectEqual(try encoder.encode(pages: [Self.pageA, black, Self.pageB], copies: 2, collate: true), page + b + page + b)
    }

    // MARK: - Vorverarbeitung

    @Test("preprocess() entspricht §8 je Sprache")
    func preprocess() {
        let settings = PrintSettings(mirror: true, rotate180: true, skipBlankLabels: true)
        let zpl = JobEncoder(language: .zpl, resolution: .dpi203, settings: settings)
        let epl = JobEncoder(language: .epl, resolution: .dpi203, settings: settings)
        let cpcl = JobEncoder(language: .cpcl, resolution: .dpi203, settings: settings)
        #expect(zpl.preprocess(Self.pageA) == Self.pageA)
        #expect(epl.preprocess(Self.pageA) == Self.pageA.mirrored())
        #expect(cpcl.preprocess(Self.pageA) == Self.pageA.mirrored().rotated180())
        #expect(zpl.preprocess(Self.blank) == nil)
        #expect(zpl.settings == settings)
    }
}

import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

/// Neue Optionen des Druckauftrags (ARCHITECTURE.md §8): Drehung 90°/270°, „Bei letztem Element
/// stoppen“, Echtzeituhr, Steuerzeichen, Linerless, `^MF`, `^MNM,n`, Pause, `~JA`, Befehle je
/// Etikett. Alle erwarteten Ausgaben sind von Hand aus der Spezifikation abgeleitet.
@Suite("JobEncoder – Treiberoptionen")
struct JobEncoderDriverOptionsTests {

    /// 10 × 3: Hex „C0000040FFC0“, ACS „C,0040FFC0“
    static let pageA = JobEncoderTests.pageA
    /// 8 × 2: Hex „FF81“
    static let pageB = JobEncoderTests.pageB
    static let utc = TimeZone(identifier: "UTC")!
    /// 2023-11-14 22:13:20 UTC
    static let t0: TimeInterval = 1_700_000_000

    static func encoder(_ settings: PrintSettings, maxWidth: Int? = nil, time: TimeInterval = t0,
                        step: Int64 = 0) -> JobEncoder {
        encoder(.zpl, settings, maxWidth: maxWidth, time: time, step: step)
    }

    static func encoder(_ language: PrinterLanguage, _ settings: PrintSettings, maxWidth: Int? = nil,
                        time: TimeInterval = t0, step: Int64 = 0) -> JobEncoder {
        var encoder = JobEncoder(language: language, resolution: .dpi203, settings: settings,
                                 maxPrintWidthDots: maxWidth, timeZone: utc,
                                 now: { Date(timeIntervalSince1970: time) })
        encoder.timeStepSeconds = step
        return encoder
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    static func expectText(_ data: Data, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(TestSupport.printable(data) == TestSupport.printable(Data(expected.utf8)), sourceLocation: sourceLocation)
    }

    /// Etikettenrumpf ohne Einstellungen für `pageA` (Hex).
    static let bodyA = """
    ^XA
    ^PW10
    ^LL3
    ^LH0,0
    ^PON
    ^PMN
    ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
    ^PQ1
    ^XZ

    """

    // MARK: - Auftragskopf

    @Test("ZPL: Auftragskopf in fester Reihenfolge (~JA, Start, ~SD, ~TA, ~JS, ~JC, SGD, ^MF, ^ST)")
    func prologueOrder() throws {
        let settings = PrintSettings(darkness: 8, printMode: .linerlessPeel, tearOffAdjust: -10, backfeed: .afterPrinting,
                                     compression: .hex, calibrateBeforeJob: true, startCommands: "~JR", endCommands: "~PS",
                                     rtcUpdate: .jobStart, cancelJobsBeforePrint: true,
                                     powerUpAction: .feed, headCloseAction: .calibrate)
        let data = try Self.encoder(settings, time: 0).encode(pages: [Self.pageA])
        Self.expectText(data, "~JA\n~JR\n~SD08\n~TA-10\n~JSA\n~JC\n"
            + "! U1 setvar \"media.printmode\" \"L\"\r\n"
            + "^XA^MFF,C^XZ\n^XA^ST01,01,1970,00,00,00,M^XZ\n" + Self.bodyA + "~PS\n")
    }

    @Test("^MF nur, wenn beide Aktionen gesetzt sind")
    func mediaFeedNeedsBoth() throws {
        for settings in [PrintSettings(compression: .hex, powerUpAction: .feed),
                         PrintSettings(compression: .hex, headCloseAction: .noMotion)] {
            Self.expectText(try Self.encoder(settings).encode(pages: [Self.pageA]), Self.bodyA)
        }
        for action in MediaFeedAction.allCases {
            let data = try Self.encoder(PrintSettings(compression: .hex, powerUpAction: action, headCloseAction: .shortCalibration))
                .encode(pages: [Self.pageA])
            Self.expectText(data, "^XA^MF\(action.zplCode),S^XZ\n" + Self.bodyA)
        }
    }

    // MARK: - Etikett

    @Test("ZPL: Etikett mit Befehlen je Etikett, ^MM, ^MNM-Versatz, Pause vor Schnitt, ^JUS nur beim ersten")
    func labelBody() throws {
        let settings = PrintSettings(speed: 3, mediaType: .directThermal, tracking: .blackMark, printMode: .cutter,
                                     labelTop: 5, labelLeft: -7, compression: .hex, cutEvery: 2, saveToPrinter: true,
                                     markOffset: -12, pauseEvery: 4, labelStartCommands: "^FXa",
                                     labelEndCommands: "^FXb\n^FXc")
        let data = try Self.encoder(settings).encode(pages: [Self.pageA, Self.pageB])
        Self.expectText(data, """
        ^XA
        ^FXa
        ^MMC
        ^MNM,-12
        ^MTD
        ^PR3,3,3
        ^PW10
        ^LL3
        ^LH0,0
        ^LT5
        ^LS-7
        ^PON
        ^PMN
        ^FO0,0^GFA,6,6,2,C0000040FFC0^FS
        ^PQ1,4,0,N
        ^JUS
        ^FXb
        ^FXc
        ^XZ
        ^XA
        ^FXa
        ^MMC
        ^MNM,-12
        ^MTD
        ^PR3,3,3
        ^PW8
        ^LL2
        ^LH0,0
        ^LT5
        ^LS-7
        ^PON
        ^PMN
        ^FO0,0^GFA,2,2,1,FF81^FS
        ^PQ1,4,0,N
        ^FXb
        ^FXc
        ^XZ

        """)
    }

    @Test("^PQ: Pause hat Vorrang vor Schneiden", arguments: [
        (0, 0, "^PQ3"), (0, 5, "^PQ3,5,0,Y"), (7, 0, "^PQ3,7,0,N"), (7, 5, "^PQ3,7,0,N"), (9999, 9999, "^PQ3,9999,0,N"),
    ])
    func pauseQuantity(pause: Int, cut: Int, expected: String) throws {
        let data = try Self.encoder(PrintSettings(compression: .hex, cutEvery: cut, pauseEvery: pause))
            .encode(pages: [Self.pageA], copies: 3)
        #expect(Self.text(data).contains("^FS\n" + expected + "\n^XZ\n"))
    }

    @Test("Medienerkennung: ^MNW, Versatz nur bei schwarzer Markierung")
    func trackingAndOffset() throws {
        func line(_ settings: PrintSettings) throws -> String? {
            let lines = Self.text(try Self.encoder(settings).encode(pages: [Self.pageA])).split(separator: "\n")
            return lines.first { $0.hasPrefix("^MN") }.map(String.init)
        }
        #expect(try line(PrintSettings(tracking: .notch)) == "^MNW")
        #expect(try line(PrintSettings(tracking: .blackMark, markOffset: 283)) == "^MNM,283")
        #expect(try line(PrintSettings(tracking: .blackMark, markOffset: 0)) == "^MNM,0")
        #expect(try line(PrintSettings(tracking: .blackMark, markOffset: -500)) == "^MNM,-80")
        #expect(try line(PrintSettings(tracking: .gap, markOffset: 20)) == "^MNY")
        #expect(try line(PrintSettings(tracking: .continuous, markOffset: 20)) == "^MNN")
        #expect(try line(PrintSettings(markOffset: 20)) == nil)
    }

    @Test("Linerless: SGD media.printmode im Kopf, kein ^MM", arguments: PrintMode.allCases.filter(\.isLinerless))
    func linerless(mode: PrintMode) throws {
        let data = try Self.encoder(PrintSettings(printMode: mode, compression: .hex)).encode(pages: [Self.pageA])
        Self.expectText(data, "! U1 setvar \"media.printmode\" \"\(mode.sgdSetValue)\"\r\n" + Self.bodyA)
    }

    @Test("Klassische Modi: ^MM im Etikett, keine SGD-Zeile", arguments: PrintMode.allCases.filter { !$0.isLinerless })
    func classicModes(mode: PrintMode) throws {
        let text = Self.text(try Self.encoder(PrintSettings(printMode: mode, compression: .hex)).encode(pages: [Self.pageA]))
        #expect(text.hasPrefix("^XA\n^MM\(mode.zplCode)\n^PW10\n"))
        #expect(!text.contains("setvar"))
    }

    // MARK: - Aufträge abbrechen

    @Test("~JA: am Auftragsanfang vor den Startbefehlen, Länge der Zeile für die Wartezeit")
    func cancelBeforePrint() throws {
        let plain = Self.encoder(PrintSettings(compression: .hex, cancelJobsBeforePrint: true))
        let data = try plain.encode(pages: [Self.pageA])
        Self.expectText(data, "~JA\n" + Self.bodyA)
        #expect(plain.cancelPrefixLength() == 4)

        let withStart = Self.encoder(PrintSettings(compression: .hex, startCommands: "~JR\n~PS",
                                                   cancelJobsBeforePrint: true, cancelDelayMs: 0))
        let started = try withStart.encode(pages: [Self.pageA])
        let split = try #require(withStart.cancelPrefixLength())
        #expect(split == 4)
        #expect(Self.text(started.prefix(split)) == "~JA\n")
        // ~JA löscht die Daten vor sich im Eingangspuffer: Die Startbefehle müssen danach kommen.
        #expect(Self.text(started.dropFirst(split)).hasPrefix("~JR\n~PS\n^XA\n"))

        let custom = Self.encoder(PrintSettings(compression: .hex,
                                                controlCharacters: ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23,
                                                                                     delimiter: 0x3B),
                                                cancelJobsBeforePrint: true))
        #expect(Self.text(try custom.encode(pages: [Self.pageA]).prefix(4)) == "#JA\n")
        #expect(custom.cancelPrefixLength() == 4)

        #expect(Self.encoder(PrintSettings()).cancelPrefixLength() == nil)
        let epl = Self.encoder(.epl, PrintSettings(startCommands: "S", cancelJobsBeforePrint: true))
        #expect(epl.cancelPrefixLength() == 4)
        #expect(Self.text(try epl.encode(pages: [Self.pageB]).prefix(6)) == "~JA\nS\n")
        #expect(Self.encoder(.cpcl, PrintSettings(cancelJobsBeforePrint: true)).cancelPrefixLength() == nil)
    }

    // MARK: - Echtzeituhr

    static func stLines(_ data: Data) -> [String] {
        text(data).split(separator: "\n").filter { $0.contains("ST") && $0.hasPrefix("^XA^ST") }.map(String.init)
    }

    @Test("RTC jobStart: genau ein ^ST zu Auftragsbeginn")
    func rtcJobStart() throws {
        let data = try Self.encoder(PrintSettings(compression: .hex, rtcUpdate: .jobStart), step: 3600)
            .encode(pages: [Self.pageA, Self.pageB], copies: 3)
        #expect(Self.stLines(data) == ["^XA^ST11,14,2023,22,13,20,M^XZ"])
        #expect(Self.text(data).hasPrefix("^XA^ST11,14,2023,22,13,20,M^XZ\n^XA\n^PW10\n"))
    }

    @Test("RTC everyLabel: vor jedem Etikett außer dem ersten, Zeit je Etikett")
    func rtcEveryLabel() throws {
        let data = try Self.encoder(PrintSettings(compression: .hex, rtcUpdate: .everyLabel), step: 10)
            .encode(pages: [Self.pageA, Self.pageB], copies: 2)
        let text = Self.text(data)
        // Kopf, dann Etikett 1 (ohne), Etikett 2 (+10 s), Etikett 3 (+20 s), Etikett 4 (+30 s)
        #expect(Self.stLines(data) == [
            "^XA^ST11,14,2023,22,13,20,M^XZ", "^XA^ST11,14,2023,22,13,30,M^XZ",
            "^XA^ST11,14,2023,22,13,40,M^XZ", "^XA^ST11,14,2023,22,13,50,M^XZ",
        ])
        #expect(text.contains("^XZ\n^XA^ST11,14,2023,22,13,30,M^XZ\n^XA\n^PW8\n"))
        #expect(text.contains("^XZ\n^XA^ST11,14,2023,22,13,50,M^XZ\n^XA\n^PW8\n"))
        #expect(text.components(separatedBy: "^XA\n^PW").count - 1 == 4)

        let single = try Self.encoder(PrintSettings(compression: .hex, rtcUpdate: .everyLabel))
            .encode(pages: [Self.pageA], copies: 5)
        #expect(Self.stLines(single).count == 1, "Ein Etikett mit ^PQ5: nur der Kopf")
    }

    @Test("RTC everyMinute: erst nach ≥ 60 s seit dem letzten ^ST", arguments: [
        (Int64(0), ["22,13,20"]),
        (Int64(30), ["22,13,20", "22,14,20"]),               // Etiketten 0/30/60/90 s: nur bei 60 s
        (Int64(59), ["22,13,20", "22,15,18"]),               // 0/59/118/177: bei 118 s (Abstand 118), 177−118 < 60
        (Int64(60), ["22,13,20", "22,14,20", "22,15,20", "22,16,20"]),
    ])
    func rtcEveryMinute(step: Int64, times: [String]) throws {
        let data = try Self.encoder(PrintSettings(compression: .hex, rtcUpdate: .everyMinute), step: step)
            .encode(pages: [Self.pageA, Self.pageB], copies: 2)
        #expect(Self.stLines(data) == times.map { "^XA^ST11,14,2023,\($0),M^XZ" })
    }

    @Test("RTC everyMinute mit laufender Uhr: auch vor dem ersten Etikett möglich")
    func rtcEveryMinuteRunningClock() throws {
        let clock = SteppingClock(start: Self.t0, step: 61)
        var encoder = JobEncoder(language: .zpl, resolution: .dpi203,
                                 settings: PrintSettings(compression: .hex, rtcUpdate: .everyMinute),
                                 timeZone: Self.utc, now: { clock.next() })
        encoder.timeStepSeconds = 0
        let data = try encoder.encode(pages: [Self.pageA], copies: 1)
        #expect(Self.stLines(data) == ["^XA^ST11,14,2023,22,13,20,M^XZ", "^XA^ST11,14,2023,22,14,21,M^XZ"])
        #expect(Self.text(data).hasPrefix("^XA^ST11,14,2023,22,13,20,M^XZ\n^XA^ST11,14,2023,22,14,21,M^XZ\n^XA\n"))
    }

    @Test("RTC: Ortszeit der eingestellten Zeitzone")
    func rtcTimeZone() throws {
        var encoder = Self.encoder(PrintSettings(compression: .hex, rtcUpdate: .jobStart))
        encoder.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(Self.stLines(try encoder.encode(pages: [Self.pageA])) == ["^XA^ST11,15,2023,07,13,20,M^XZ"])
    }

    @Test("EPL und CPCL ignorieren ZPL-Optionen (RTC, Steuerzeichen, ^MF, Versatz, Pause, Linerless)")
    func zplOnlyOptionsIgnored() throws {
        let zplOnly = PrintSettings(tracking: .blackMark, compression: .hex, markOffset: 30, pauseEvery: 2,
                                    controlCharacters: ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B),
                                    rtcUpdate: .everyLabel, powerUpAction: .feed, headCloseAction: .feed)
        let base = PrintSettings(tracking: .blackMark, compression: .hex)
        for language in [PrinterLanguage.epl, .cpcl] {
            #expect(try Self.encoder(language, zplOnly).encode(pages: [Self.pageA, Self.pageB], copies: 2)
                == Self.encoder(language, base).encode(pages: [Self.pageA, Self.pageB], copies: 2))
        }
        // CPCL kennt weder Start-/Endbefehle noch ~JA oder Befehle je Etikett.
        let cpclExtras = PrintSettings(startCommands: "A", endCommands: "B", cancelJobsBeforePrint: true,
                                       labelStartCommands: "C", labelEndCommands: "D")
        #expect(try Self.encoder(.cpcl, cpclExtras).encode(pages: [Self.pageA])
            == Self.encoder(.cpcl, PrintSettings()).encode(pages: [Self.pageA]))
    }

    // MARK: - Steuerzeichen

    @Test("Steuerzeichen „Intern“: alle eigenen Befehle mit $ # ; – Rohbefehle, SGD und Grafikdaten unverändert")
    func controlCharacters() throws {
        let settings = PrintSettings(
            darkness: 8, speed: 4, mediaType: .thermalTransfer, tracking: .blackMark, printMode: .linerlessCut,
            labelTop: 1, labelLeft: 2, tearOffAdjust: -10, backfeed: .afterPrinting, mirror: true, rotate180: true,
            compression: .acs, cutEvery: 3, calibrateBeforeJob: true, saveToPrinter: true,
            startCommands: "^XA^FX,~^XZ", endCommands: "~PS,x",
            markOffset: 7, controlCharacters: ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B),
            rtcUpdate: .everyLabel, cancelJobsBeforePrint: true, labelStartCommands: "^FX,~", labelEndCommands: "^FX,~ Ende",
            powerUpAction: .noMotion, headCloseAction: .shortCalibration)
        let data = try Self.encoder(settings, time: 0, step: 1).encode(pages: [Self.pageA], copies: 1)
        Self.expectText(data, """
        #JA
        ^XA^FX,~^XZ
        #SD08
        #TA-10
        #JSA
        #JC
        ! U1 setvar "media.printmode" "linerless cut"\r
        $XA$MFN;S$XZ
        $XA$ST01;01;1970;00;00;00;M$XZ
        $XA
        ^FX,~
        $MNM;7
        $MTT
        $PR4;4;4
        $PW10
        $LL3
        $LH0;0
        $LT1
        $LS2
        $POI
        $PMY
        $FO0;0$GFA;6;6;2;C,0040FFC0$FS
        $PQ1;3;0;Y
        $JUS
        ^FX,~ Ende
        $XZ
        ~PS,x

        """)
    }

    @Test("Standard-Steuerzeichen als „Intern“ ergeben denselben Auftrag wie „Standard“")
    func standardCharactersAsPrinter() throws {
        let base = PrintSettings(darkness: 3, tracking: .blackMark, compression: .acs, cutEvery: 2, markOffset: 4,
                                 rtcUpdate: .jobStart, cancelJobsBeforePrint: true)
        var printer = base
        printer.controlCharacters = .standard
        #expect(try Self.encoder(printer).encode(pages: [Self.pageA, Self.pageB])
            == Self.encoder(base).encode(pages: [Self.pageA, Self.pageB]))
    }

    // MARK: - Drehung

    /// 3 × 2: „##.“ / „..#“
    static let asymmetric = TestSupport.bitmap(["##.", "..#"])

    @Test("Drehung 90°/270° in Software (im Uhrzeigersinn), 180° per ^POI/ZB bzw. Software bei CPCL")
    func rotationBitmaps() throws {
        func rows(_ language: PrinterLanguage, _ settings: PrintSettings) throws -> [String] {
            TestSupport.rows(try #require(Self.encoder(language, settings).preprocess(Self.asymmetric)))
        }
        for language in PrinterLanguage.allCases {
            #expect(try rows(language, PrintSettings(rotation: .r90)) == [".#", ".#", "#."])
            #expect(try rows(language, PrintSettings(rotation: .r270)) == [".#", "#.", "#."])
            #expect(try rows(language, PrintSettings(rotate180: true, rotation: .r90)) == [".#", ".#", "#."],
                    "rotation hat Vorrang vor rotate180")
        }
        #expect(try rows(.zpl, PrintSettings(rotation: .r180)) == ["##.", "..#"])
        #expect(try rows(.epl, PrintSettings(rotation: .r180)) == ["##.", "..#"])
        #expect(try rows(.cpcl, PrintSettings(rotation: .r180)) == ["#..", ".##"])
        #expect(try rows(.cpcl, PrintSettings(rotate180: true)) == ["#..", ".##"])
        // Spiegeln (EPL/CPCL) erst nach dem Drehen
        #expect(try rows(.epl, PrintSettings(mirror: true, rotation: .r90)) == ["#.", "#.", ".#"])
    }

    @Test("Drehung im Auftrag: ^PW/^LL vertauscht, ^PO nur bei 180°")
    func rotationInJob() throws {
        let r90 = Self.text(try Self.encoder(PrintSettings(compression: .hex, rotation: .r90)).encode(pages: [Self.asymmetric]))
        // 2 × 3: 40 / 40 / 80
        #expect(r90 == "^XA\n^PW2\n^LL3\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,3,3,1,404080^FS\n^PQ1\n^XZ\n")
        let r180 = Self.text(try Self.encoder(PrintSettings(compression: .hex, rotation: .r180)).encode(pages: [Self.asymmetric]))
        #expect(r180 == "^XA\n^PW3\n^LL2\n^LH0,0\n^POI\n^PMN\n^FO0,0^GFA,2,2,1,C020^FS\n^PQ1\n^XZ\n")
        let legacy90 = Self.text(try Self.encoder(PrintSettings(rotate180: true, compression: .hex, rotation: .r270))
            .encode(pages: [Self.asymmetric]))
        #expect(legacy90.contains("^PON\n") && legacy90.contains("^GFA,3,3,1,408080^FS"))
        let epl = Self.text(try Self.encoder(.epl, PrintSettings(rotation: .r270)).encode(pages: [Self.asymmetric]))
        #expect(epl.contains("q2\nQ3,24\nZT\n"))
        let epl180 = Self.text(try Self.encoder(.epl, PrintSettings(rotation: .r180)).encode(pages: [Self.asymmetric]))
        #expect(epl180.contains("q3\nQ2,24\nZB\n"))
    }

    @Test("Drehung vor dem Abschneiden auf die Druckbreite")
    func rotationBeforeCrop() throws {
        let page = TestSupport.bitmap(["#...", ".#.#"])
        let rotated = try #require(Self.encoder(PrintSettings(rotation: .r90), maxWidth: 1).preprocess(page))
        #expect(TestSupport.rows(rotated) == [".", "#", ".", "#"])
        let rotated270 = try #require(Self.encoder(PrintSettings(rotation: .r270), maxWidth: 1).preprocess(page))
        #expect(TestSupport.rows(rotated270) == [".", ".", ".", "#"])
        #expect(Self.encoder(PrintSettings(rotation: .r90)).preprocess(MonoBitmap(width: 0, height: 5)) == nil)
        #expect(Self.encoder(PrintSettings(rotation: .r270)).preprocess(MonoBitmap(width: 4, height: 0)) == nil)
    }

    // MARK: - Bei letztem Element stoppen

    /// 4 × 6, letzte schwarze Zeile 3.
    static let tall = TestSupport.bitmap(["....", "#...", "....", ".#..", "....", "...."])

    @Test("Bei letztem Element stoppen: Höhe = letzte schwarze Zeile + 1 + Versatz (nur Endlosmaterial)",
          arguments: [(0, 4), (1, 5), (2, 6), (5, 9), (32_000, 32_004)])
    func stopAtLast(offset: Int, height: Int) throws {
        let settings = PrintSettings(tracking: .continuous, stopAtLastElement: true, stopOffset: offset)
        let page = try #require(Self.encoder(settings).preprocess(Self.tall))
        #expect(page.width == 4 && page.height == height)
        #expect(Array(TestSupport.rows(page).prefix(4)) == ["....", "#...", "....", ".#.."])
        #expect(TestSupport.rows(page).dropFirst(4).allSatisfy { $0 == "...." }, "Ergänzte Zeilen sind weiß")
        #expect(page.data.count == height)
    }

    @Test("Bei letztem Element stoppen: Sonderfälle")
    func stopAtLastSpecialCases() throws {
        let stop = PrintSettings(tracking: .continuous, stopAtLastElement: true)
        for tracking in [MediaTracking.gap, .blackMark, .notch, .autoDetect] {
            var settings = stop
            settings.tracking = tracking
            #expect(Self.encoder(settings).preprocess(Self.tall)?.height == 6, "nur bei Endlosmaterial")
        }
        var noTracking = stop
        noTracking.tracking = nil
        #expect(Self.encoder(noTracking).preprocess(Self.tall)?.height == 6)
        // Leere Seite: mindestens 1 Zeile bzw. der Versatz
        #expect(Self.encoder(stop).preprocess(MonoBitmap(width: 5, height: 9))?.height == 1)
        var offset = stop
        offset.stopOffset = 3
        #expect(Self.encoder(offset).preprocess(MonoBitmap(width: 5, height: 9))?.height == 3)
        // Erst kürzen, dann invertieren
        var negative = stop
        negative.negative = true
        let inverted = try #require(Self.encoder(negative).preprocess(Self.tall))
        #expect(TestSupport.rows(inverted) == ["####", ".###", "####", "#.##"])
        // Leere Seite wird mit skipBlankLabels trotzdem übersprungen
        var skip = stop
        skip.skipBlankLabels = true
        #expect(Self.encoder(skip).preprocess(MonoBitmap(width: 5, height: 9)) == nil)
        // Drehung zuerst, dann kürzen: 4 × 6 → 6 × 4 (90°), letzte schwarze Zeile 1
        var rotated = stop
        rotated.rotation = .r90
        let turned = try #require(Self.encoder(rotated).preprocess(Self.tall))
        #expect(TestSupport.rows(turned) == ["....#.", "..#..."])
        // Im Auftrag: ^LL ist die gekürzte Höhe
        var job = stop
        job.compression = .hex
        #expect(Self.text(try Self.encoder(job).encode(pages: [Self.tall])).contains("^PW4\n^LL4\n"))
    }

    // MARK: - EPL

    @Test("EPL: ~JA vor den Startbefehlen, Befehle je Etikett nach N bzw. vor P")
    func eplLabelCommands() throws {
        let settings = PrintSettings(startCommands: "S", endCommands: "E", cancelJobsBeforePrint: true,
                                     labelStartCommands: "X", labelEndCommands: "Y\nZ")
        let data = try Self.encoder(.epl, settings).encode(pages: [Self.pageB], copies: 2)
        var expected = Data("~JA\nS\n\nN\nX\nq8\nQ2,24\nZT\nGW0,0,1,2,".utf8)
        expected.append(contentsOf: [0x00, 0x7E])
        expected.append(Data("\nY\nZ\nP2\nE\n".utf8))
        #expect(TestSupport.printable(data) == TestSupport.printable(expected))
        #expect(data == expected)
    }

    @Test("EPL: Seitenkerben wie Lücke, Linerless ohne C/P")
    func eplTrackingAndModes() throws {
        let notch = Self.text(try Self.encoder(.epl, PrintSettings(tracking: .notch)).encode(pages: [Self.pageB]))
        #expect(notch.contains("q8\nQ2,24\nZT\n"))
        let linerless = Self.text(try Self.encoder(.epl, PrintSettings(printMode: .linerlessCut)).encode(pages: [Self.pageB]))
        #expect(linerless.contains("ZT\nO\nGW"))
        let linerlessDT = Self.text(try Self.encoder(.epl, PrintSettings(mediaType: .directThermal, printMode: .linerlessPeel))
            .encode(pages: [Self.pageB]))
        #expect(linerlessDT.contains("ZT\nOD\nGW"))
        #expect(!linerlessDT.contains("setvar"))
    }
}

/// Uhr, die bei jedem Aufruf `step` Sekunden weiterläuft (für `@Sendable`-Zeitquellen).
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval
    private let step: TimeInterval

    init(start: TimeInterval, step: TimeInterval) {
        current = start
        self.step = step
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current += step
        return Date(timeIntervalSince1970: value)
    }
}

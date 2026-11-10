import Foundation
import Testing
@testable import LabelWerkKit

/// Treiberoptionen im `PrinterClient`: dauerhafte Einstellungen (`^MF`, `^MNM,n`, Linerless per
/// SGD, Steuerzeichen), Uhr stellen (`^ST`), Einstellungen vom Drucker lesen und Wartezeit nach `~JA`.
@Suite("PrinterClient – Treiberoptionen")
struct DriverOptionsKitTests {

    static let custom = ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B)

    static func payload(_ settings: PrintSettings, permanently: Bool = false, _ language: PrinterLanguage = .zpl) -> String {
        String(decoding: PrinterClient.settingsPayload(settings, permanently: permanently, language: language), as: UTF8.self)
    }

    static var zq630: PrinterModel {
        guard let model = ModelCatalog.shared.model(id: "zq630") else { preconditionFailure("ZQ630 fehlt im Katalog") }
        return model
    }

    // MARK: - applySettings

    @Test("ZPL: Linerless per SGD, ^MNM-Versatz, ^MF, Reihenfolge")
    func zplPayload() {
        let settings = PrintSettings(darkness: 22, speed: 5, mediaType: .directThermal, tracking: .blackMark,
                                     printMode: .linerlessPeel, labelTop: 12, labelLeft: -16, tearOffAdjust: 10,
                                     backfeed: .beforePrinting, markOffset: 15,
                                     powerUpAction: .calibrate, headCloseAction: .feed)
        #expect(Self.payload(settings, permanently: true) == """
        ~SD22
        ~TA010
        ~JSB
        ! U1 setvar "media.printmode" "linerless peel"\r
        ^XA
        ^MTD
        ^MNM,15
        ^PR5,5,5
        ^LT12
        ^LS-16
        ^MFC,F
        ^JUS
        ^XZ

        """)
        var classic = settings
        classic.printMode = .cutter
        classic.markOffset = nil
        classic.headCloseAction = nil
        #expect(Self.payload(classic) == "~SD22\n~TA010\n~JSB\n^XA\n^MTD\n^MNM\n^MMC\n^PR5,5,5\n^LT12\n^LS-16\n^XZ\n",
                "Ohne beide Aktionen kein ^MF, ohne Versatz ^MNM")
        #expect(Self.payload(PrintSettings(printMode: .linerlessTear))
            == "! U1 setvar \"media.printmode\" \"linerless tear\"\r\n", "Nur SGD: kein leeres ^XA…^XZ")
        #expect(Self.payload(PrintSettings(tracking: .notch, markOffset: 9)) == "^XA\n^MNW\n^XZ\n")
        #expect(Self.payload(PrintSettings(powerUpAction: .noMotion, headCloseAction: .shortCalibration))
            == "^XA\n^MFN,S\n^XZ\n")
    }

    @Test("ZPL: Einstellungen mit den Steuerzeichen des Druckers („Intern“)")
    func zplPayloadControlCharacters() {
        let settings = PrintSettings(darkness: 8, speed: 3, tracking: .blackMark, printMode: .linerlessCut,
                                     tearOffAdjust: -5, backfeed: .off, markOffset: -3, controlCharacters: Self.custom,
                                     powerUpAction: .length, headCloseAction: .noMotion)
        #expect(Self.payload(settings, permanently: true) == """
        #SD08
        #TA-05
        #JSO
        ! U1 setvar "media.printmode" "linerless cut"\r
        $XA
        $MNM;-3
        $PR3;3;3
        $MFL;N
        $JUS
        $XZ

        """)
    }

    @Test("EPL ignoriert Linerless-SGD; CPCL setzt Aktionen und Linerless per SGD")
    func otherLanguages() {
        #expect(Self.payload(PrintSettings(printMode: .linerlessPeel), .epl) == "\nO\n")
        #expect(Self.payload(PrintSettings(mediaType: .directThermal, printMode: .linerlessCut, powerUpAction: .feed,
                                           headCloseAction: .feed), .epl) == "\nOD\n")
        let cpcl = Self.payload(PrintSettings(printMode: .linerlessRewind, labelTop: 7, powerUpAction: .shortCalibration,
                                              headCloseAction: .noMotion), .cpcl)
        #expect(cpcl == "! U1 setvar \"media.printmode\" \"linerless rewind\"\r\n"
                + "! U1 setvar \"zpl.label_top\" \"7\"\r\n"
                + "! U1 setvar \"ezpl.power_up_action\" \"short cal\"\r\n"
                + "! U1 setvar \"ezpl.head_close_action\" \"no motion\"\r\n")
        #expect(Self.payload(PrintSettings(tracking: .notch), .cpcl) == "! U1 setvar \"ezpl.media_type\" \"gap/notch\"\r\n")
    }

    @Test("applySettings am virtuellen Drucker: ^MF, ^MNM, Linerless (nur bei Linerless-Modellen)")
    func applyOnVirtualPrinter() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.applySettings(PrintSettings(tracking: .blackMark, printMode: .linerlessPeel, markOffset: 20,
                                                     powerUpAction: .calibrate, headCloseAction: .noMotion),
                                       permanently: true)
        #expect(await printer.sgdValue("ezpl.power_up_action") == "calibrate")
        #expect(await printer.sgdValue("ezpl.head_close_action") == "no motion")
        #expect(await printer.sgdValue("ezpl.media_type") == "mark")
        #expect(await printer.sgdValue("media.printmode") == "tear off", "ZD421t kennt keine Linerless-Modi")

        let mobile = try await KitTestSupport.makePrinter(model: Self.zq630)
        let mobileClient = await KitTestSupport.makeClient(mobile)
        for mode in PrintMode.allCases.filter(\.isLinerless) + [.peelOff] {
            try await mobileClient.applySettings(PrintSettings(printMode: mode), permanently: false)
            #expect(await mobile.sgdValue("media.printmode") == mode.sgdValue)
            #expect(try await mobileClient.readPrintSettings().printMode == mode)
        }
    }

    // MARK: - Uhr

    @Test("syncClock: ^ST (ZPL) bzw. rtc.date/rtc.time (EPL, CPCL)")
    func clockPayloads() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_767_582_245)   // 2026-01-05 03:04:05 UTC
        #expect(String(decoding: PrinterClient.clockPayload(now: date, timeZone: utc, language: .zpl), as: UTF8.self)
            == "^XA^ST01,05,2026,03,04,05,M^XZ\n")
        for language in [PrinterLanguage.epl, .cpcl] {
            #expect(String(decoding: PrinterClient.clockPayload(now: date, timeZone: utc, language: language), as: UTF8.self)
                == "! U1 setvar \"rtc.date\" \"01-05-2026\"\r\n! U1 setvar \"rtc.time\" \"03:04:05\"\r\n")
        }
    }

    @Test("syncClock stellt die Uhr des virtuellen Druckers", arguments: [PrinterLanguage.zpl, .cpcl])
    func syncClockVirtual(language: PrinterLanguage) async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer, language: language)
        // 2031-03-04 05:06:07 in der Zeitzone des virtuellen Druckers
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let target = try #require(calendar.date(from: DateComponents(year: 2031, month: 3, day: 4, hour: 5, minute: 6, second: 7)))
        try await client.syncClock(now: target, timeZone: .current)
        #expect(try await client.getvar("rtc.date") == "03-04-2031")
        let time = try #require(try await client.getvar("rtc.time"))
        #expect(time.hasPrefix("05:06:"), "\(time)")
        let drift = await printer.clockDate.timeIntervalSince(target)
        #expect(drift >= 0 && drift < 5)
    }

    // MARK: - Einstellungen lesen

    @Test("readPrintSettings: Werkswerte des virtuellen ZD421t und Rundreise nach applySettings")
    func readSettings() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let initial = try await client.readPrintSettings()
        #expect(initial.darkness == 15 && initial.speed == 4)
        #expect(initial.tracking == .gap && initial.mediaType == .thermalTransfer && initial.printMode == .tearOff)
        #expect(initial.labelTop == 0 && initial.labelLeft == 0 && initial.tearOffAdjust == 0)
        #expect(initial.powerUpAction == .feed && initial.headCloseAction == .feed)
        #expect(initial.controlCharacters == nil)

        let applied = PrintSettings(darkness: 23, speed: 5, mediaType: .directThermal, tracking: .continuous,
                                    printMode: .cutter, labelTop: -40, labelLeft: 120, tearOffAdjust: -7,
                                    powerUpAction: .length, headCloseAction: .shortCalibration)
        try await client.applySettings(applied, permanently: true)
        let base = PrintSettings(dither: .stucki, compression: .acs, startCommands: "~JR", rotation: .r90)
        let read = try await client.readPrintSettings(into: base)
        var expected = applied
        expected.dither = .stucki
        expected.compression = .acs
        expected.startCommands = "~JR"
        expected.rotation = .r90
        #expect(read == expected, "Werte aus dem Drucker, übrige Felder aus base")

        try await client.setvar("zpl.caret", "$")
        try await client.setvar("zpl.delimiter", ";")
        #expect(try await client.readPrintSettings().controlCharacters
            == ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x7E, delimiter: 0x3B))
    }

    @Test("Zuordnung der SGD-Werte: tolerant gegenüber fehlenden und unbekannten Werten")
    func sgdMapping() {
        let base = PrintSettings(darkness: 3, tracking: .notch)
        #expect(SGDValueMapping.settings(from: [:], base: base) == base)
        let garbage: [String: String] = [
            "print.tone": "?", "media.speed": "schnell", "ezpl.media_type": "", "ezpl.print_method": "laser",
            "media.printmode": "teleport", "zpl.label_top": "", "ezpl.power_up_action": "jump", "zpl.caret": "^^",
        ]
        #expect(SGDValueMapping.settings(from: garbage, base: base) == base)

        let values: [String: String] = [
            "print.tone": "17.6", "media.speed": "3.0", "ezpl.media_type": "continuous variable",
            "ezpl.print_method": "direct thermal", "media.printmode": "Linerless Delayed Cut",
            "zpl.label_top": "-200", "zpl.left_position": "15", "ezpl.tear_off": "12.0",
            "ezpl.power_up_action": "no motion", "ezpl.head_close_action": "short cal",
            "zpl.caret": "^", "zpl.control_character": "#", "zpl.delimiter": ",",
        ]
        let s = SGDValueMapping.settings(from: values, base: PrintSettings())
        #expect(s.darkness == 18 && s.speed == 3)
        #expect(s.tracking == .continuous && s.mediaType == .directThermal && s.printMode == .linerlessDelayedCut)
        #expect(s.labelTop == -120, "auf −120 begrenzt")
        #expect(s.labelLeft == 15 && s.tearOffAdjust == 12)
        #expect(s.powerUpAction == .noMotion && s.headCloseAction == .shortCalibration)
        #expect(s.controlCharacters == ControlCharacters(formatPrefix: 0x5E, controlPrefix: 0x23, delimiter: 0x2C))

        // Standardzeichen → nil (Standard); Ersatzquellen der Medienerkennung
        #expect(SGDValueMapping.settings(from: ["zpl.caret": "^", "zpl.control_character": "~", "zpl.delimiter": ","],
                                         base: PrintSettings(controlCharacters: Self.custom)).controlCharacters == nil)
        #expect(SGDValueMapping.settings(from: ["media.type": "journal", "media.sense_mode": "bar"], base: base).tracking
            == .continuous)
        #expect(SGDValueMapping.settings(from: ["media.type": "label", "media.sense_mode": "bar"], base: base).tracking
            == .blackMark)
        #expect(SGDValueMapping.settings(from: ["media.sense_mode": "gap"], base: base).tracking == .gap)
        #expect(SGDValueMapping.settings(from: ["ezpl.media_type": "mark", "media.sense_mode": "gap"], base: base).tracking
            == .blackMark, "ezpl.media_type hat Vorrang")
        #expect(SGDValueMapping.mediaTracking(sgd: "notch") == .notch)
        #expect(SGDValueMapping.mediaTracking(sgd: "gap/notch") == .gap)
        #expect(SGDValueMapping.mediaTracking(.notch) == "gap/notch")
        #expect(SGDValueMapping.printMode(sgd: "LINERLESS PEEL") == .linerlessPeel)
        #expect(SGDValueMapping.printMode(sgd: "linerless_tear") == .linerlessTear)
        #expect(SGDValueMapping.printMode(sgd: "linerless something") == nil)
        #expect(SGDValueMapping.printMode(sgd: "peel-off") == .peelOff)
        #expect(SGDValueMapping.integer("1e12") == nil && SGDValueMapping.integer("-2.5") == -3)
    }

    @Test("readPrintSettings ohne Rückkanal bzw. ohne Antwort")
    func readSettingsErrors() async throws {
        let queue = PrinterClient(connection: TimedConnection(), language: .zpl)
        await #expect(throws: PrinterClientError.self) { try await queue.readPrintSettings() }
        let silent = await KitTestSupport.makeClient(SilentConnection())
        await #expect(throws: PrinterClientError.self) { try await silent.readPrintSettings() }
    }

    // MARK: - Aufträge vor dem Drucken abbrechen

    @Test("printImages wartet nach ~JA cancelDelayMs und sendet dann den Rest")
    func cancelDelay() async throws {
        let connection = TimedConnection()
        let client = PrinterClient(connection: connection, language: .zpl)
        let image = GrayImage(width: 16, height: 4, fill: 0)
        let settings = PrintSettings(compression: .hex, startCommands: "~JR", cancelJobsBeforePrint: true, cancelDelayMs: 300)
        try await client.printImages([image], settings: settings, resolution: .dpi203, stock: nil)
        let writes = await connection.writes
        #expect(writes.count == 2)
        #expect(String(decoding: writes[0].data, as: UTF8.self) == "~JR\n~JA\n")
        let expected = try JobEncoder(language: .zpl, resolution: .dpi203, settings: settings).encode(images: [image])
        #expect(writes.reduce(Data()) { $0 + $1.data } == expected)
        #expect(writes[1].time.timeIntervalSince(writes[0].time) >= 0.29)

        // Ohne ~JA: ein einziger Schreibvorgang
        let single = TimedConnection()
        try await PrinterClient(connection: single).printImages([image], settings: PrintSettings(), resolution: .dpi203,
                                                                  stock: nil)
        #expect(await single.writes.count == 1)
        // CPCL kennt kein ~JA
        let cpcl = TimedConnection()
        try await PrinterClient(connection: cpcl, language: .cpcl).printImages(
            [image], settings: PrintSettings(cancelJobsBeforePrint: true), resolution: .dpi203, stock: nil)
        #expect(await cpcl.writes.count == 1)
    }

    @Test("Wartezeit 0: zwei Schreibvorgänge ohne Pause, Daten unverändert")
    func cancelWithoutDelay() async throws {
        let connection = TimedConnection()
        let client = PrinterClient(connection: connection, language: .epl)
        let settings = PrintSettings(cancelJobsBeforePrint: true, cancelDelayMs: 0)
        let image = GrayImage(width: 8, height: 2, fill: 0)
        try await client.printImages([image], settings: settings, resolution: .dpi203, stock: nil)
        let writes = await connection.writes
        #expect(writes.map { String(decoding: $0.data, as: UTF8.self) }.first == "~JA\n")
        #expect(writes.count == 2)
    }
}

/// Verbindung ohne Rückkanal (wie eine CUPS-Warteschlange), die Schreibvorgänge mit Zeitstempel aufzeichnet.
actor TimedConnection: PrinterConnection {
    nonisolated let descriptor = ConnectionDescriptor.cupsQueue(name: "Test_Zeit")
    private var opened = false
    private(set) var writes: [(time: Date, data: Data)] = []
    var isOpen: Bool { opened }
    func open() async throws { opened = true }
    func close() async { opened = false }
    func write(_ data: Data) async throws { writes.append((Date(), data)) }
    func read(timeout: Duration) async throws -> Data { Data() }
}

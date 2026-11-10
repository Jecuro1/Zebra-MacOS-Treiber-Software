import Foundation
import Testing
@testable import LabelWerkCore

/// Optionen des Windows-Treiberdialogs („Druckeinstellungen für ZD421 …“): neue Aufzählungen,
/// `PrintSettings`-Felder, CUPS-Optionen (§9) und tolerantes Dekodieren.
@Suite("Treiberoptionen (Core)")
struct DriverOptionsTests {

    // MARK: - Aufzählungen

    @Test("Medientyp: Seitenkerben (^MNW) und deutsche Bezeichnungen wie unter Windows")
    func mediaTracking() {
        #expect(MediaTracking.notch.zplCode == "W")
        #expect(MediaTracking.notch.cupsValue == "Notch")
        #expect(MediaTracking(cupsValue: "Notch") == .notch)
        #expect(MediaTracking(cupsValue: "notch") == .notch, "wie der C-Filter ohne Groß-/Kleinschreibung")
        #expect(MediaTracking.continuous.displayName == "Endlosmaterial")
        #expect(MediaTracking.gap.displayName == "Einzeletiketten")
        #expect(MediaTracking.blackMark.displayName == "Etiketten mit schwarzen Markierungen")
        #expect(MediaTracking.notch.displayName == "Etiketten mit Seitenkerben")
        #expect(MediaTracking.autoDetect.displayName == "Automatisch erkennen")
        #expect(MediaTracking.allCases.map(\.zplCode) == ["Y", "M", "N", "A", "W"])
    }

    @Test("Druckverfahren und Rückzug: deutsche Bezeichnungen wie unter Windows")
    func germanNames() {
        #expect(MediaType.thermalTransfer.displayName == "Thermotransfer")
        #expect(MediaType.directThermal.displayName == "Thermo-Direkt")
        #expect(BackfeedMode.off.displayName == "Kein Rückzug")
        #expect(BackfeedMode.beforePrinting.displayName == "Vor dem Drucken")
        #expect(BackfeedMode.afterPrinting.displayName == "Nach dem Drucken")
        #expect(BackfeedMode.normal.displayName == "Standard")
    }

    static let printModeTable: [(PrintMode, cups: String, sgd: String, name: String, mm: String?)] = [
        (.tearOff, "TearOff", "tear off", "Abreißen", "T"),
        (.peelOff, "PeelOff", "peel off", "Spendemodus", "P"),
        (.cutter, "Cutter", "cutter", "Abschneider", "C"),
        (.delayedCut, "DelayedCut", "delayed cut", "Verzögerter Abschneider", "D"),
        (.rewind, "Rewind", "rewind", "Aufwickeln", "R"),
        (.applicator, "Applicator", "applicator", "Applikator", "A"),
        (.kiosk, "Kiosk", "kiosk", "Kiosk", "K"),
        (.linerlessPeel, "LinerlessPeel", "linerless peel", "Linerless ablösen", nil),
        (.linerlessCut, "LinerlessCut", "linerless cut", "Linerless schneiden", nil),
        (.linerlessDelayedCut, "LinerlessDelayedCut", "linerless delayed cut", "Linerless verzögert schneiden", nil),
        (.linerlessRewind, "LinerlessRewind", "linerless rewind", "Linerless aufwickeln", nil),
        (.linerlessTear, "LinerlessTear", "linerless tear", "Linerless-Abriss", nil),
    ]

    @Test("Bedienermodus: CUPS-, SGD-, ^MM-Werte und Bezeichnungen aller Modi")
    func printModes() {
        #expect(Self.printModeTable.count == PrintMode.allCases.count)
        for (mode, cups, sgd, name, mm) in Self.printModeTable {
            #expect(mode.cupsValue == cups)
            #expect(PrintMode(cupsValue: cups) == mode)
            #expect(mode.sgdValue == sgd)
            #expect(PrintMode(sgdValue: sgd) == mode)
            #expect(PrintMode(sgdValue: " " + sgd.uppercased().replacingOccurrences(of: " ", with: "_") + " ") == mode)
            #expect(mode.displayName == name)
            #expect(mode.mmCode == mm)
            #expect(mode.isLinerless == (mm == nil))
            #expect(mode.usesSGD == mode.isLinerless)
            if let mm {
                #expect(mode.zplCode == mm)
                #expect(PrintMode(zplCode: mm.lowercased()) == mode)
                #expect(mode.classicEquivalent == mode)
            }
        }
        #expect(PrintMode.linerlessPeel.classicEquivalent == .peelOff)
        #expect(PrintMode.linerlessCut.classicEquivalent == .cutter)
        #expect(PrintMode.linerlessDelayedCut.classicEquivalent == .delayedCut)
        #expect(PrintMode.linerlessRewind.classicEquivalent == .rewind)
        #expect(PrintMode.linerlessTear.classicEquivalent == .tearOff)
        #expect(PrintMode.linerlessCut.zplCode == "C", "Rückfall auf den Code des klassischen Modus")
        #expect(PrintMode(zplCode: "X") == nil)
        #expect(PrintMode(sgdValue: "linerless") == nil)
        // Setzwerte laut Zebra-SGD-Referenz: Kennbuchstaben, Linerless schneiden ohne Buchstaben (Wort).
        #expect(PrintMode.allCases.map(\.sgdSetValue)
            == ["T", "P", "C", "D", "R", "A", "K", "L", "linerless cut", "linerless delayed cut", "U", "V"])
        for mode in PrintMode.allCases {
            #expect(PrintMode(sgdValue: mode.sgdSetValue) == mode, "Rücklesen nimmt auch den Setzwert an")
            #expect(PrintMode(sgdValue: mode.sgdSetValue.lowercased()) == mode)
        }
        #expect(PrintMode(sgdValue: "F") == nil, "RFID ist kein eigener Modus")
        #expect(PrintMode.allCases.filter(\.usesCutter) == [.cutter, .delayedCut, .kiosk, .linerlessCut, .linerlessDelayedCut])
    }

    @Test("Drehung: Gradzahlen, CUPS-Werte, Bezeichnungen")
    func rotation() {
        #expect(PrintRotation.allCases.map(\.degrees) == [0, 90, 180, 270])
        #expect(PrintRotation.allCases.map(\.cupsValue) == ["0", "90", "180", "270"])
        #expect(PrintRotation.allCases.map(\.displayName)
            == ["0° – Hochformat", "90° – Querformat", "180° – Hochformat", "270° – Querformat"])
        #expect(PrintRotation(cupsValue: " 270 ") == .r270)
        #expect(PrintRotation(cupsValue: "45") == nil)
        #expect(PrintRotation(cupsValue: "+90") == nil && PrintRotation(cupsValue: "090") == nil, "nur exakte Werte wie im Filter")
        #expect(PrintRotation(cupsValue: "Default") == nil)
        #expect(PrintRotation.r90.isQuarterTurn && PrintRotation.r270.isQuarterTurn)
        #expect(!PrintRotation.r0.isQuarterTurn && !PrintRotation.r180.isQuarterTurn)
    }

    @Test("RTC aktualisieren und Medienvorschub-Aktionen")
    func rtcAndFeedActions() {
        #expect(RTCUpdate.allCases.map(\.cupsValue) == ["JobStart", "EveryLabel", "EveryMinute"])
        #expect(RTCUpdate.allCases.map(\.displayName) == ["Druckzeit starten", "Jedes Etikett", "Jede Minute"])
        #expect(RTCUpdate(cupsValue: "EveryMinute") == .everyMinute)
        #expect(RTCUpdate(cupsValue: "Default") == nil)

        #expect(MediaFeedAction.allCases.map(\.zplCode) == ["F", "C", "L", "N", "S"])
        #expect(MediaFeedAction.allCases.map(\.cupsValue) == ["Feed", "Calibrate", "Length", "NoMotion", "ShortCal"])
        #expect(MediaFeedAction.allCases.map(\.sgdValue) == ["feed", "calibrate", "length", "no motion", "short cal"])
        for action in MediaFeedAction.allCases {
            #expect(MediaFeedAction(cupsValue: action.cupsValue) == action)
            #expect(MediaFeedAction(sgdValue: action.sgdValue.uppercased()) == action)
            #expect(MediaFeedAction(zplCode: action.zplCode.lowercased()) == action)
        }
        #expect(MediaFeedAction(sgdValue: "no_motion") == .noMotion)
        #expect(MediaFeedAction(sgdValue: "short calibration") == .shortCalibration)
        #expect(MediaFeedAction(sgdValue: "springen") == nil)
        #expect(MediaFeedAction(cupsValue: "ShortCalibration") == nil)
    }

    @Test("Steuerzeichen: Standard, Begrenzung, Zeichen aus SGD-Werten, tolerantes Dekodieren")
    func controlCharacters() throws {
        let standard = ControlCharacters.standard
        #expect(standard == ControlCharacters(formatPrefix: 0x5E, controlPrefix: 0x7E, delimiter: 0x2C))
        #expect(standard.isStandard)
        #expect(standard.formatPrefixString == "^" && standard.controlPrefixString == "~" && standard.delimiterString == ",")
        let custom = ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B)
        #expect(!custom.isStandard)
        #expect(custom.clamped() == custom)
        #expect(ControlCharacters(formatPrefix: 32, controlPrefix: 127, delimiter: 0).clamped() == .standard)
        #expect(ControlCharacters(formatPrefix: 33, controlPrefix: 126, delimiter: 200).clamped()
            == ControlCharacters(formatPrefix: 33, controlPrefix: 126, delimiter: 0x2C))
        #expect(ControlCharacters.character(from: "$") == 0x24)
        #expect(ControlCharacters.character(from: "") == nil)
        #expect(ControlCharacters.character(from: "^^") == nil)
        #expect(ControlCharacters.character(from: " ") == nil)
        #expect(ControlCharacters.character(from: "ä") == nil)

        let encoded = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(ControlCharacters.self, from: encoded) == custom)
        let partial = Data(#"{"formatPrefix":36,"delimiter":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(ControlCharacters.self, from: partial)
            == ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x7E, delimiter: 0x2C))
    }

    // MARK: - PrintSettings

    @Test("Neue Felder: Standardwerte und wirksame Drehung")
    func defaultsAndEffectiveRotation() {
        let s = PrintSettings()
        #expect(s.rotation == .r0 && s.markOffset == nil && !s.stopAtLastElement && s.stopOffset == 0)
        #expect(s.pauseEvery == 0 && s.controlCharacters == nil && s.rtcUpdate == nil)
        #expect(!s.cancelJobsBeforePrint && s.cancelDelayMs == 1000)
        #expect(s.labelStartCommands.isEmpty && s.labelEndCommands.isEmpty)
        #expect(s.powerUpAction == nil && s.headCloseAction == nil && !s.hasMediaFeedActions)
        #expect(s.effectiveControlCharacters == .standard)

        for rotation in PrintRotation.allCases {
            for legacy in [false, true] {
                let expected: PrintRotation = rotation != .r0 ? rotation : (legacy ? .r180 : .r0)
                #expect(PrintSettings(rotate180: legacy, rotation: rotation).effectiveRotation == expected)
            }
        }
        #expect(PrintSettings(powerUpAction: .feed, headCloseAction: .calibrate).hasMediaFeedActions)
        #expect(!PrintSettings(powerUpAction: .feed).hasMediaFeedActions)
    }

    @Test("clamped() begrenzt die neuen Werte")
    func clamping() {
        let low = PrintSettings(markOffset: -81, stopOffset: -1, pauseEvery: -5,
                                controlCharacters: ControlCharacters(formatPrefix: 10, controlPrefix: 0x7E, delimiter: 0x3B),
                                cancelDelayMs: -1).clamped()
        #expect(low.markOffset == -80 && low.stopOffset == 0 && low.pauseEvery == 0 && low.cancelDelayMs == 0)
        #expect(low.controlCharacters == ControlCharacters(formatPrefix: 0x5E, controlPrefix: 0x7E, delimiter: 0x3B))
        let high = PrintSettings(markOffset: 284, stopOffset: 32_001, pauseEvery: 10_000, cancelDelayMs: 10_001).clamped()
        #expect(high.markOffset == 283 && high.stopOffset == 32_000 && high.pauseEvery == 9999 && high.cancelDelayMs == 10_000)
        let inside = PrintSettings(markOffset: 0, stopOffset: 32_000, pauseEvery: 9999, cancelDelayMs: 10_000)
        #expect(inside.clamped() == inside)
    }

    @Test("CUPS-Optionen der Standardwerte (§9)")
    func defaultCUPSOptions() {
        let o = PrintSettings().cupsOptions()
        #expect(o[CUPSOptionName.rotation] == "0")
        #expect(o[CUPSOptionName.markOffset] == "Default")
        #expect(o[CUPSOptionName.stopAtLast] == "False")
        #expect(o[CUPSOptionName.stopOffset] == "0")
        #expect(o[CUPSOptionName.pauseEvery] == "0")
        #expect(o[CUPSOptionName.controlChars] == "Standard")
        #expect(o[CUPSOptionName.formatPrefix] == nil && o[CUPSOptionName.controlPrefix] == nil && o[CUPSOptionName.delimiter] == nil)
        #expect(o[CUPSOptionName.rtc] == "Default")
        #expect(o[CUPSOptionName.cancelBefore] == "False")
        #expect(o[CUPSOptionName.cancelDelay] == "1000")
        #expect(o[CUPSOptionName.labelStartCommands] == nil && o[CUPSOptionName.labelEndCommands] == nil)
        #expect(o[CUPSOptionName.powerUpAction] == "Default" && o[CUPSOptionName.headCloseAction] == "Default")
        #expect(PrintSettings(cupsOptions: o) == PrintSettings())
        #expect(PrintSettings(cupsOptions: [:]) == PrintSettings())
    }

    static let everything = PrintSettings(
        darkness: 12, speed: 5, mediaType: .directThermal, tracking: .blackMark, printMode: .linerlessDelayedCut,
        labelTop: 4, labelLeft: -8, tearOffAdjust: 6, backfeed: .off, mirror: true, negative: true, rotate180: true,
        dither: .atkinson, threshold: 90, compression: .hex, cutEvery: 3, calibrateBeforeJob: true, saveToPrinter: true,
        skipBlankLabels: true, startCommands: "~JR", endCommands: "^XA^XZ",
        rotation: .r270, markOffset: -37, stopAtLastElement: true, stopOffset: 120, pauseEvery: 25,
        controlCharacters: ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B),
        rtcUpdate: .everyMinute, cancelJobsBeforePrint: true, cancelDelayMs: 2500,
        labelStartCommands: "^FXStart äöü", labelEndCommands: "^FX Ende\n^PQ1",
        powerUpAction: .shortCalibration, headCloseAction: .noMotion)

    @Test("CUPS-Optionen: alle neuen Werte und Rundreise")
    func fullCUPSRoundTrip() {
        let o = Self.everything.cupsOptions()
        #expect(o[CUPSOptionName.printMode] == "LinerlessDelayedCut")
        #expect(o[CUPSOptionName.rotation] == "270")
        #expect(o[CUPSOptionName.rotate180] == "True", "Altoption bleibt unverändert erhalten")
        #expect(o[CUPSOptionName.markOffset] == "-37")
        #expect(o[CUPSOptionName.stopAtLast] == "True")
        #expect(o[CUPSOptionName.stopOffset] == "120")
        #expect(o[CUPSOptionName.pauseEvery] == "25")
        #expect(o[CUPSOptionName.controlChars] == "Printer")
        #expect(o[CUPSOptionName.formatPrefix] == "36")
        #expect(o[CUPSOptionName.controlPrefix] == "35")
        #expect(o[CUPSOptionName.delimiter] == "59")
        #expect(o[CUPSOptionName.rtc] == "EveryMinute")
        #expect(o[CUPSOptionName.cancelBefore] == "True")
        #expect(o[CUPSOptionName.cancelDelay] == "2500")
        #expect(o[CUPSOptionName.labelStartCommands] == CUPSCommandEncoding.encode("^FXStart äöü"))
        #expect(o[CUPSOptionName.labelEndCommands] == "XkZYIEVuZGUKXlBRMQ")
        #expect(o[CUPSOptionName.powerUpAction] == "ShortCal")
        #expect(o[CUPSOptionName.headCloseAction] == "NoMotion")
        #expect(PrintSettings(cupsOptions: o) == Self.everything)

        for tracking in MediaTracking.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(tracking: tracking).cupsOptions()).tracking == tracking)
        }
        for rotation in PrintRotation.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(rotation: rotation).cupsOptions()).rotation == rotation)
        }
        for rtc in RTCUpdate.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(rtcUpdate: rtc).cupsOptions()).rtcUpdate == rtc)
        }
        for action in MediaFeedAction.allCases {
            let s = PrintSettings(powerUpAction: action, headCloseAction: action)
            #expect(PrintSettings(cupsOptions: s.cupsOptions()) == s)
        }
    }

    @Test("CUPS-Optionen lesen: Steuerzeichen nur mit „Printer“, ungültige Zeichen → Standardzeichen")
    func cupsControlCharacters() {
        #expect(PrintSettings(cupsOptions: ["lwFormatPrefix": "36"]).controlCharacters == nil)
        #expect(PrintSettings(cupsOptions: ["lwControlChars": "Standard", "lwFormatPrefix": "36"]).controlCharacters == nil)
        #expect(PrintSettings(cupsOptions: ["lwControlChars": "Printer"]).controlCharacters == .standard,
                "„Intern“ ohne Zeichen: Standardzeichen, aber nicht nil")
        #expect(PrintSettings(cupsOptions: ["lwControlChars": "printer", "lwFormatPrefix": "36", "lwControlPrefix": "200",
                                            "lwDelimiter": "x"]).controlCharacters
            == ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x7E, delimiter: 0x2C))
        #expect(PrintSettings(cupsOptions: ["lwControlChars": "Printer", "lwFormatPrefix": "32", "lwControlPrefix": "33",
                                            "lwDelimiter": "126"]).controlCharacters
            == ControlCharacters(formatPrefix: 0x5E, controlPrefix: 33, delimiter: 126))
        #expect(PrintSettings(cupsOptions: ["lwControlChars": "Printer", "lwDelimiter": "Default"]).controlCharacters == .standard)
    }

    @Test("CUPS-Optionen lesen: ungültige Werte werden ignoriert bzw. begrenzt")
    func cupsInvalidValues() {
        let s = PrintSettings(cupsOptions: [
            "lwRotation": "45", "lwMarkOffset": "-500", "lwStopAtLast": "yes", "lwStopOffset": "99999",
            "lwPauseEvery": "abc", "lwRTC": "Hourly", "lwCancelBefore": "on", "lwCancelDelay": "-3",
            "lwLabelStartCmd": "!!", "lwLabelEndCmd": CUPSCommandEncoding.encode("~PS"),
            "lwPowerUpAction": "Jump", "lwHeadCloseAction": "Calibrate", "lwMediaTracking": "Notch",
            "lwPrintMode": "LinerlessTear",
        ])
        #expect(s.rotation == .r0)
        #expect(s.markOffset == -80)
        #expect(s.stopAtLastElement)
        #expect(s.stopOffset == 32_000)
        #expect(s.pauseEvery == 0)
        #expect(s.rtcUpdate == nil)
        #expect(s.cancelJobsBeforePrint)
        #expect(s.cancelDelayMs == 0)
        #expect(s.labelStartCommands.isEmpty)
        #expect(s.labelEndCommands == "~PS")
        #expect(s.powerUpAction == nil && s.headCloseAction == .calibrate)
        #expect(s.tracking == .notch && s.printMode == .linerlessTear)
        #expect(PrintSettings(cupsOptions: ["lwRotation": "90", "lwRotate180": "True"]).effectiveRotation == .r90)
        #expect(PrintSettings(cupsOptions: ["lwRotation": "0", "lwRotate180": "True"]).effectiveRotation == .r180)
        #expect(PrintSettings(cupsOptions: ["lwMarkOffset": "Default"]).markOffset == nil)
    }

    @Test("CUPS-Optionen lesen wie C-Filter und Python-Referenz: Leerraum, Schreibweise, Custom.-Präfix")
    func cupsParsingMatchesFilter() {
        // Aufzählungen ohne Beachtung der Groß-/Kleinschreibung (ASCII), Leerraum am Rand egal.
        let s = PrintSettings(cupsOptions: [
            "lwRTC": "everylabel", "lwPowerUpAction": "feed", "lwHeadCloseAction": " SHORTCAL\t",
            "lwMediaTracking": "notch", "lwPrintMode": "linerlesscut", "lwMediaType": "directthermal",
            "lwBackfeed": "BEFORE", "lwDither": "floydsteinberg", "lwCompression": " hex ",
            "lwRotation": " 90\n", "lwMarkOffset": "Custom.12", "lwStopAtLast": " True", "lwCancelBefore": "on ",
            "lwMirror": "\tYES", "lwDarkness": " +12 ", "lwSpeed": "custom.4", "lwControlChars": " PRINTER ",
            "lwFormatPrefix": " 36 ", "lwStartCmd": " \(CUPSCommandEncoding.encode("~JR")) ",
        ])
        #expect(s.rtcUpdate == .everyLabel)
        #expect(s.powerUpAction == .feed && s.headCloseAction == .shortCalibration)
        #expect(s.tracking == .notch && s.printMode == .linerlessCut && s.mediaType == .directThermal)
        #expect(s.backfeed == .beforePrinting && s.dither == .floydSteinberg && s.compression == .hex)
        #expect(s.rotation == .r90)
        #expect(s.markOffset == 12 && s.darkness == 12 && s.speed == 4)
        #expect(s.stopAtLastElement && s.cancelJobsBeforePrint && s.mirror)
        #expect(s.controlCharacters == ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x7E, delimiter: 0x2C))
        #expect(s.startCommands == "~JR")

        // Ungültig wie im Filter: Drehung nur exakt, Zahlen nur mit Ziffern, Unicode-Schreibweisen nicht.
        let invalid = PrintSettings(cupsOptions: [
            "lwRotation": "+90", "lwMarkOffset": "12 mm", "lwDarkness": "1.5", "lwSpeed": "Custom.",
            "lwRTC": "Every Label", "lwPrintMode": "Lınerlesscut", "lwStartCmd": "Default", "lwEndCmd": " none ",
            "lwStopAtLast": "ja",
        ])
        #expect(invalid.rotation == .r0 && PrintSettings(cupsOptions: ["lwRotation": "090"]).rotation == .r0)
        #expect(invalid.markOffset == nil && invalid.darkness == nil && invalid.speed == nil)
        #expect(invalid.rtcUpdate == nil && invalid.printMode == nil)
        #expect(invalid.startCommands.isEmpty && invalid.endCommands.isEmpty)
        #expect(!invalid.stopAtLastElement)
        #expect(PrintSettings(cupsOptions: ["lwMarkOffset": "default", "lwThreshold": "DEFAULT"]).markOffset == nil)
        #expect(PrintSettings(cupsOptions: ["lwThreshold": " Default "]).threshold == 128)
        #expect(PrintSettings(cupsOptions: ["lwPauseEvery": "  "]).pauseEvery == 0, "leer = nicht gesetzt")
    }

    @Test("Optionsnamen: vollständig, eindeutig, Nicht-PPD-Optionen")
    func optionNames() {
        let new = ["lwRotation", "lwMarkOffset", "lwStopAtLast", "lwStopOffset", "lwPauseEvery", "lwControlChars",
                   "lwFormatPrefix", "lwControlPrefix", "lwDelimiter", "lwRTC", "lwCancelBefore", "lwCancelDelay",
                   "lwLabelStartCmd", "lwLabelEndCmd", "lwPowerUpAction", "lwHeadCloseAction"]
        for name in new { #expect(CUPSOptionName.all.contains(name), "\(name)") }
        #expect(Set(CUPSOptionName.all).count == CUPSOptionName.all.count)
        #expect(Set(CUPSOptionName.nonPPD) == ["lwStartCmd", "lwEndCmd", "lwLabelStartCmd", "lwLabelEndCmd",
                                                "lwFormatPrefix", "lwControlPrefix", "lwDelimiter", "lwRotate180"])
        // Jede erzeugte Option ist bekannt.
        for key in Self.everything.cupsOptions().keys { #expect(CUPSOptionName.all.contains(key), "\(key)") }
    }

    // MARK: - Tolerantes Dekodieren

    @Test("JSON-Rundreise mit allen neuen Feldern")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.everything)
        #expect(try JSONDecoder().decode(PrintSettings.self, from: data) == Self.everything)
    }

    @Test("Einstellungen einer älteren App-Version (ohne neue Felder) werden gelesen")
    func decodesOldVersion() throws {
        let old = Data(#"{"darkness":20,"mirror":true,"negative":false,"rotate180":true,"dither":"stucki","threshold":100,"compression":"acs","cutEvery":2,"calibrateBeforeJob":false,"saveToPrinter":false,"skipBlankLabels":true,"startCommands":"~JR","endCommands":""}"#.utf8)
        let s = try JSONDecoder().decode(PrintSettings.self, from: old)
        #expect(s.darkness == 20 && s.rotate180 && s.dither == .stucki && s.cutEvery == 2)
        #expect(s.rotation == .r0 && s.effectiveRotation == .r180)
        #expect(s.cancelDelayMs == 1000 && s.controlCharacters == nil && s.rtcUpdate == nil)
    }

    @Test("Ungültige neue Werte: Standardwerte bzw. Begrenzung statt Fehler")
    func decodesInvalidNewValues() throws {
        let json = Data(#"{"rotation":45,"markOffset":999,"stopAtLastElement":"ja","stopOffset":-4,"pauseEvery":3,"controlCharacters":{"formatPrefix":36,"controlPrefix":5},"rtcUpdate":"stündlich","cancelJobsBeforePrint":true,"cancelDelayMs":"lang","labelStartCommands":42,"labelEndCommands":"^FX","powerUpAction":"calibrate","headCloseAction":"teleport","tracking":"notch","printMode":"linerlessRewind"}"#.utf8)
        let s = try JSONDecoder().decode(PrintSettings.self, from: json)
        #expect(s.rotation == .r0)
        #expect(s.markOffset == 283)
        #expect(!s.stopAtLastElement)
        #expect(s.stopOffset == 0)
        #expect(s.pauseEvery == 3)
        #expect(s.controlCharacters == ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x7E, delimiter: 0x2C),
                "Steuerpräfix 5 ist ungültig und wird zum Standardzeichen")
        #expect(s.rtcUpdate == nil)
        #expect(s.cancelJobsBeforePrint)
        #expect(s.cancelDelayMs == 1000)
        #expect(s.labelStartCommands.isEmpty && s.labelEndCommands == "^FX")
        #expect(s.powerUpAction == .calibrate && s.headCloseAction == nil)
        #expect(s.tracking == .notch && s.printMode == .linerlessRewind)
    }

    // MARK: - Befehlsbausteine

    @Test("ZPL-Bausteine: ^MNM mit Versatz, ^MM nur klassisch, ^MF, SGD media.printmode")
    func commandBuilders() {
        #expect(ZPL.mediaTracking(.blackMark, markOffset: -12).description == "^MNM,-12")
        #expect(ZPL.mediaTracking(.blackMark, markOffset: 300).description == "^MNM,283")
        #expect(ZPL.mediaTracking(.blackMark, markOffset: -100).description == "^MNM,-80")
        #expect(ZPL.mediaTracking(.blackMark, markOffset: nil).description == "^MNM")
        #expect(ZPL.mediaTracking(.gap, markOffset: 40).description == "^MNY", "Versatz nur bei schwarzer Markierung")
        #expect(ZPL.mediaTracking(.notch).description == "^MNW")
        #expect(ZPL.printModeCommand(.cutter)?.description == "^MMC")
        #expect(ZPL.printModeCommand(.linerlessPeel) == nil)
        #expect(ZPL.printMode(.linerlessTear).description == "^MMT")
        #expect(ZPL.mediaFeed(powerUpAction: .shortCalibration, headCloseAction: .length).description == "^MFS,L")
        #expect(ZPL.mediaFeed(powerUp: .calibrate, headClose: .feed).description == "^MFC,F")
        #expect(SGD.setPrintMode(.linerlessDelayedCut) == "! U1 setvar \"media.printmode\" \"linerless delayed cut\"\r\n")
        #expect(SGD.setPrintMode(.linerlessPeel) == "! U1 setvar \"media.printmode\" \"L\"\r\n")
        #expect(SGD.setPrintMode(.peelOff) == "! U1 setvar \"media.printmode\" \"P\"\r\n")
        for name in ["print.tone", "media.speed", "ezpl.media_type", "ezpl.print_method", "media.printmode",
                     "zpl.label_top", "zpl.left_position", "ezpl.tear_off", "ezpl.power_up_action",
                     "ezpl.head_close_action", "zpl.caret", "zpl.control_character", "zpl.delimiter",
                     "media.sense_mode", "media.type"] {
            #expect(SGD.printSettingsVariables.contains(name), "\(name)")
        }
    }

    @Test("^ST: Ortszeit, 24 Stunden, mit Nullen aufgefüllt")
    func setClock() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        // 2026-01-05 03:04:05 UTC
        let date = Date(timeIntervalSince1970: 1_767_582_245)
        #expect(ZPL.setRealTimeClock(date, timeZone: utc).description == "^ST01,05,2026,03,04,05,M")
        #expect(ZPL.setRealTimeClock(date, timeZone: berlin).description == "^ST01,05,2026,04,04,05,M")
        #expect(ZPL.realTimeClockFormat(Date(timeIntervalSince1970: 0), timeZone: utc) == "^XA^ST01,01,1970,00,00,00,M^XZ")
        // Sommerzeit: 2026-07-31 23:59:59 UTC = 01:59:59 am 1. August in Berlin
        let summer = Date(timeIntervalSince1970: 1_785_542_399)
        #expect(ZPL.setRealTimeClock(summer, timeZone: utc).description == "^ST07,31,2026,23,59,59,M")
        #expect(ZPL.setRealTimeClock(summer, timeZone: berlin).description == "^ST08,01,2026,01,59,59,M")
        #expect(ZPL.pad(5, 4) == "0005" && ZPL.pad(-5, 3) == "-05" && ZPL.pad(12345, 2) == "12345")
    }

    @Test("Steuerzeichen beim Rendern: Präfixe und Trennzeichen, Parameter unverändert")
    func renderingWithControlCharacters() {
        let chars = ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B)
        #expect(ZPL.labelHome(x: 0, y: 0).rendered(with: chars) == "$LH0;0")
        #expect(ZPL.setDarkness(8).rendered(with: chars) == "#SD08")
        #expect(ZPL.mediaTracking(.blackMark, markOffset: 5).rendered(with: chars) == "$MNM;5")
        #expect(ZPLCommand(.caret, "FD", ["a,b^c~d"]).rendered(with: chars) == "$FDa,b^c~d", "Daten bleiben unverändert")
        #expect(ZPL.labelHome(x: 1, y: 2).rendered(with: .standard) == ZPL.labelHome(x: 1, y: 2).description)
        let commands = [ZPL.startFormat(), ZPL.fieldOrigin(x: 1, y: 2), ZPL.fieldSeparator(), ZPL.printQuantity(2, pauseCount: 3),
                        ZPL.endFormat()]
        #expect(ZPL.render(commands, characters: chars) == "$XA\n$FO1;2$FS\n$PQ2;3;0;N\n$XZ\n")
        #expect(ZPL.render(commands) == "^XA\n^FO1,2^FS\n^PQ2,3,0,N\n^XZ\n")
    }
}

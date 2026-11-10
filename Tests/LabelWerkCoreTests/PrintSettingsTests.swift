import Foundation
import Testing
@testable import LabelWerkCore

@Suite("Druckeinstellungen & CUPS-Optionen")
struct PrintSettingsTests {
    @Test("Standardwerte → CUPS-Optionen")
    func defaults() {
        let options = PrintSettings.default.cupsOptions()
        #expect(options[CUPSOptionName.darkness] == "Default")
        #expect(options[CUPSOptionName.speed] == "Default")
        #expect(options[CUPSOptionName.mediaType] == "Default")
        #expect(options[CUPSOptionName.tracking] == "Default")
        #expect(options[CUPSOptionName.printMode] == "Default")
        #expect(options[CUPSOptionName.labelTop] == "Default")
        #expect(options[CUPSOptionName.labelLeft] == "Default")
        #expect(options[CUPSOptionName.tearOff] == "Default")
        #expect(options[CUPSOptionName.backfeed] == "Default")
        #expect(options[CUPSOptionName.mirror] == "False")
        #expect(options[CUPSOptionName.dither] == "Threshold")
        #expect(options[CUPSOptionName.threshold] == "128")
        #expect(options[CUPSOptionName.compression] == "Z64")
        #expect(options[CUPSOptionName.cutEvery] == "0")
        #expect(options[CUPSOptionName.startCommands] == nil)
        #expect(options[CUPSOptionName.endCommands] == nil)
        #expect(Set(options.keys).isSubset(of: Set(CUPSOptionName.all)))
        #expect(PrintSettings(cupsOptions: options) == .default)
    }

    @Test("Vollständige Rundreise")
    func roundTrip() {
        let settings = PrintSettings(
            darkness: 22, speed: 6, mediaType: .thermalTransfer, tracking: .blackMark, printMode: .cutter,
            labelTop: -15, labelLeft: 37, tearOffAdjust: 10, backfeed: .beforePrinting,
            mirror: true, negative: true, rotate180: true, dither: .stucki, threshold: 160, compression: .acs,
            cutEvery: 25, calibrateBeforeJob: true, saveToPrinter: true, skipBlankLabels: true,
            startCommands: "^XA^MMT^XZ\n! U1 setvar \"print.tone\" \"20\"\r\n",
            endCommands: "~JA ünïcødé 😀 + / = _ -")
        let options = settings.cupsOptions()
        #expect(options[CUPSOptionName.darkness] == "22")
        #expect(options[CUPSOptionName.mediaType] == "ThermalTransfer")
        #expect(options[CUPSOptionName.tracking] == "BlackMark")
        #expect(options[CUPSOptionName.printMode] == "Cutter")
        #expect(options[CUPSOptionName.labelTop] == "-15")
        #expect(options[CUPSOptionName.backfeed] == "Before")
        #expect(options[CUPSOptionName.dither] == "Stucki")
        #expect(options[CUPSOptionName.compression] == "ACS")
        #expect(options[CUPSOptionName.skipBlank] == "True")
        #expect(PrintSettings(cupsOptions: options) == settings)
    }

    @Test("Rundreise aller Aufzählungswerte")
    func enumRoundTrips() {
        for mode in PrintMode.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(printMode: mode).cupsOptions()).printMode == mode)
            #expect(PrintMode(zplCode: mode.zplCode) == mode)
        }
        for tracking in MediaTracking.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(tracking: tracking).cupsOptions()).tracking == tracking)
        }
        for backfeed in BackfeedMode.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(backfeed: backfeed).cupsOptions()).backfeed == backfeed)
        }
        for dither in DitherAlgorithm.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(dither: dither).cupsOptions()).dither == dither)
        }
        for compression in GraphicCompression.allCases {
            #expect(PrintSettings(cupsOptions: PrintSettings(compression: compression).cupsOptions()).compression == compression)
        }
        for language in PrinterLanguage.allCases {
            #expect(PrinterLanguage(cupsValue: language.cupsValue) == language)
        }
    }

    @Test("Werte werden begrenzt")
    func clamping() {
        let settings = PrintSettings(darkness: 99, speed: 0, labelTop: -500, labelLeft: 20_000, tearOffAdjust: 300,
                                     threshold: 0, cutEvery: -3)
        let options = settings.cupsOptions()
        #expect(options[CUPSOptionName.darkness] == "30")
        #expect(options[CUPSOptionName.speed] == "1")
        #expect(options[CUPSOptionName.labelTop] == "-120")
        #expect(options[CUPSOptionName.labelLeft] == "9999")
        #expect(options[CUPSOptionName.tearOff] == "120")
        #expect(options[CUPSOptionName.threshold] == "1")
        #expect(options[CUPSOptionName.cutEvery] == "0")
        let parsed = PrintSettings(cupsOptions: [CUPSOptionName.darkness: "45", CUPSOptionName.threshold: "300"])
        #expect(parsed.darkness == 30)
        #expect(parsed.threshold == 254)
    }

    @Test("Toleranter Import (lpadmin-Werte)")
    func lenientParsing() {
        let parsed = PrintSettings(cupsOptions: [
            CUPSOptionName.labelTop: " 37 ",
            CUPSOptionName.speed: "fast",
            CUPSOptionName.mirror: "yes",
            CUPSOptionName.negative: "On",
            CUPSOptionName.rotate180: "1",
            CUPSOptionName.calibrate: "no",
            CUPSOptionName.mediaType: "Unbekannt",
            CUPSOptionName.dither: "Ordered",
            CUPSOptionName.startCommands: "!!!",
        ])
        #expect(parsed.labelTop == 37)
        #expect(parsed.speed == nil)
        #expect(parsed.mirror)
        #expect(parsed.negative)
        #expect(parsed.rotate180)
        #expect(!parsed.calibrateBeforeJob)
        #expect(parsed.mediaType == nil)
        #expect(parsed.dither == .ordered)
        #expect(parsed.startCommands == "")
    }

    @Test("Codable-Rundreise")
    func codable() throws {
        let settings = PrintSettings(darkness: 12, tracking: .gap, mirror: true, startCommands: "~SD10")
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

private let commandSamples: [String] = [
    "",
    "a",
    "ab",
    "abc",
    "^XA^FDHällo Wörld 😀^FS^XZ",
    "a+b/c=d?e",
    "\r\n\t\u{0}",
    "~JA\n! U1 setvar \"device.friendly_name\" \"Lager 1\"\r\n",
    String(repeating: "^XA^PQ1^XZ\n", count: 200),
    "日本語のテキスト",
]

@Suite("CUPSCommandEncoding")
struct CUPSCommandEncodingTests {
    @Test("Rundreise mit Unicode und Sonderzeichen", arguments: commandSamples)
    func roundTrip(_ sample: String) {
        let encoded = CUPSCommandEncoding.encode(sample)
        #expect(encoded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(!encoded.contains("="))
        #expect(CUPSCommandEncoding.decode(encoded) == sample)
    }

    @Test("Bekannte Werte (Base64url ohne Padding)")
    func knownValues() {
        #expect(CUPSCommandEncoding.encode("~JC") == "fkpD")
        #expect(CUPSCommandEncoding.encode("??>") == "Pz8-")
        #expect(CUPSCommandEncoding.encode("???") == "Pz8_")
        #expect(CUPSCommandEncoding.encode("a") == "YQ")
        #expect(CUPSCommandEncoding.decode("YQ") == "a")
    }

    @Test("Ungültige Eingaben")
    func invalid() {
        #expect(CUPSCommandEncoding.decode("!!!") == nil)
        #expect(CUPSCommandEncoding.decode("_w") == nil)   // 0xFF ist kein gültiges UTF-8
    }
}

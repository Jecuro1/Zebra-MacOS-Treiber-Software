import Foundation

/// Druckeinstellungen eines Auftrags bzw. Standardwerte einer Warteschlange.
///
/// Optionale Werte (`nil`) bedeuten „Druckereinstellung beibehalten“ – es wird dann kein
/// entsprechender Befehl gesendet. Das entspricht dem Verhalten „Druckereinstellungen verwenden“
/// des Windows-Treibers.
///
/// Die Abbildung auf CUPS-Optionen (`lw*`) ist der Vertrag zwischen App, PPD-Dateien und dem
/// CUPS-Filter `rastertolabelwerk` (siehe ARCHITECTURE.md, Abschnitt „CUPS-Optionen“).
public struct PrintSettings: Codable, Hashable, Sendable {
    /// Schwärzung 0…30 (`~SD`).
    public var darkness: Int?
    /// Druckgeschwindigkeit in Zoll pro Sekunde 1…14 (`^PR`).
    public var speed: Int?
    public var mediaType: MediaType?
    public var tracking: MediaTracking?
    public var printMode: PrintMode?
    /// Vertikaler Versatz in Punkten −120…120 (`^LT`).
    public var labelTop: Int?
    /// Horizontaler Versatz in Punkten −9999…9999 (`^LS`).
    public var labelLeft: Int?
    /// Abreißposition in Punkten −120…120 (`~TA`).
    public var tearOffAdjust: Int?
    public var backfeed: BackfeedMode?

    /// Spiegeln (`^PMY`).
    public var mirror: Bool
    /// Negativdruck (Bitmap invertieren).
    public var negative: Bool
    /// Um 180° drehen (`^POI`).
    public var rotate180: Bool

    public var dither: DitherAlgorithm
    /// Schwelle 1…254 für `threshold` sowie Helligkeitsbezug der anderen Verfahren.
    public var threshold: Int
    public var compression: GraphicCompression

    /// Nach jeweils N Etiketten schneiden (0 = nur am Auftragsende).
    public var cutEvery: Int
    /// Vor dem Auftrag kalibrieren (`~JC`).
    public var calibrateBeforeJob: Bool
    /// Einstellungen dauerhaft im Drucker speichern (`^JUS`).
    public var saveToPrinter: Bool
    /// Leere Etiketten nicht drucken.
    public var skipBlankLabels: Bool

    /// Rohbefehle, die vor dem ersten Etikett gesendet werden.
    public var startCommands: String
    /// Rohbefehle, die nach dem letzten Etikett gesendet werden.
    public var endCommands: String

    // MARK: Erweiterungen (Windows-Treiberdialog)

    /// Drehung der Seite im Uhrzeigersinn („Drehung“). Zusammen mit ``rotate180`` ergibt sich
    /// ``effectiveRotation``.
    public var rotation: PrintRotation
    /// Versatz der schwarzen Markierung in Punkten −80…283 (`^MNM,{offset}`, nur bei
    /// ``MediaTracking/blackMark``; `nil` = Druckerwert).
    public var markOffset: Int?
    /// „Bei letztem Element stoppen“ (nur Endlosmaterial): Seitenhöhe = letzte Zeile mit
    /// schwarzen Punkten + 1 + ``stopOffset``.
    public var stopAtLastElement: Bool
    /// Stoppversatz in Punkten 0…32000 (nur mit ``stopAtLastElement``).
    public var stopOffset: Int
    /// Nach jeweils N Etiketten pausieren (`^PQ{n},{N},0,N`), 0…9999; 0 = keine Pause.
    /// Hat Vorrang vor ``cutEvery``.
    public var pauseEvery: Int
    /// Steuerzeichen: `nil` = Standard (`^ ~ ,`), sonst die im Drucker eingestellten Zeichen („Intern“).
    public var controlCharacters: ControlCharacters?
    /// Echtzeituhr stellen (`^ST`); `nil` = nie.
    public var rtcUpdate: RTCUpdate?
    /// „Aufträge vor dem Drucken abbrechen“: `~JA` vor dem Auftrag.
    public var cancelJobsBeforePrint: Bool
    /// Wartezeit nach `~JA` in Millisekunden 0…10000 (der CUPS-Filter wartet selbst; beim
    /// `JobEncoder` wartet der Aufrufer).
    public var cancelDelayMs: Int
    /// Rohbefehle am Anfang jedes Etiketts (nach `^XA`).
    public var labelStartCommands: String
    /// Rohbefehle am Ende jedes Etiketts (vor `^XZ`).
    public var labelEndCommands: String
    /// Aktion beim Einschalten (`^MF`, nur zusammen mit ``headCloseAction``).
    public var powerUpAction: MediaFeedAction?
    /// Aktion nach dem Schließen des Druckkopfs (`^MF`, nur zusammen mit ``powerUpAction``).
    public var headCloseAction: MediaFeedAction?

    public init(
        darkness: Int? = nil,
        speed: Int? = nil,
        mediaType: MediaType? = nil,
        tracking: MediaTracking? = nil,
        printMode: PrintMode? = nil,
        labelTop: Int? = nil,
        labelLeft: Int? = nil,
        tearOffAdjust: Int? = nil,
        backfeed: BackfeedMode? = nil,
        mirror: Bool = false,
        negative: Bool = false,
        rotate180: Bool = false,
        dither: DitherAlgorithm = .threshold,
        threshold: Int = 128,
        compression: GraphicCompression = .z64,
        cutEvery: Int = 0,
        calibrateBeforeJob: Bool = false,
        saveToPrinter: Bool = false,
        skipBlankLabels: Bool = false,
        startCommands: String = "",
        endCommands: String = "",
        rotation: PrintRotation = .r0,
        markOffset: Int? = nil,
        stopAtLastElement: Bool = false,
        stopOffset: Int = 0,
        pauseEvery: Int = 0,
        controlCharacters: ControlCharacters? = nil,
        rtcUpdate: RTCUpdate? = nil,
        cancelJobsBeforePrint: Bool = false,
        cancelDelayMs: Int = 1000,
        labelStartCommands: String = "",
        labelEndCommands: String = "",
        powerUpAction: MediaFeedAction? = nil,
        headCloseAction: MediaFeedAction? = nil
    ) {
        self.darkness = darkness
        self.speed = speed
        self.mediaType = mediaType
        self.tracking = tracking
        self.printMode = printMode
        self.labelTop = labelTop
        self.labelLeft = labelLeft
        self.tearOffAdjust = tearOffAdjust
        self.backfeed = backfeed
        self.mirror = mirror
        self.negative = negative
        self.rotate180 = rotate180
        self.dither = dither
        self.threshold = threshold
        self.compression = compression
        self.cutEvery = cutEvery
        self.calibrateBeforeJob = calibrateBeforeJob
        self.saveToPrinter = saveToPrinter
        self.skipBlankLabels = skipBlankLabels
        self.startCommands = startCommands
        self.endCommands = endCommands
        self.rotation = rotation
        self.markOffset = markOffset
        self.stopAtLastElement = stopAtLastElement
        self.stopOffset = stopOffset
        self.pauseEvery = pauseEvery
        self.controlCharacters = controlCharacters
        self.rtcUpdate = rtcUpdate
        self.cancelJobsBeforePrint = cancelJobsBeforePrint
        self.cancelDelayMs = cancelDelayMs
        self.labelStartCommands = labelStartCommands
        self.labelEndCommands = labelEndCommands
        self.powerUpAction = powerUpAction
        self.headCloseAction = headCloseAction
    }

    /// Standard: Alle Druckerwerte beibehalten, Schwellenwert-Rasterung, Z64.
    public static let `default` = PrintSettings()

    /// Begrenzt alle Werte auf gültige Bereiche.
    public func clamped() -> PrintSettings {
        var s = self
        s.darkness = darkness.map { min(max($0, 0), 30) }
        s.speed = speed.map { min(max($0, 1), 14) }
        s.labelTop = labelTop.map { min(max($0, -120), 120) }
        s.labelLeft = labelLeft.map { min(max($0, -9999), 9999) }
        s.tearOffAdjust = tearOffAdjust.map { min(max($0, -120), 120) }
        s.threshold = min(max(threshold, 1), 254)
        s.cutEvery = min(max(cutEvery, 0), 9999)
        s.markOffset = markOffset.map { min(max($0, -80), 283) }
        s.stopOffset = min(max(stopOffset, 0), 32_000)
        s.pauseEvery = min(max(pauseEvery, 0), 9999)
        s.controlCharacters = controlCharacters?.clamped()
        s.cancelDelayMs = min(max(cancelDelayMs, 0), 10_000)
        return s
    }

    /// Wirksame Drehung: ``rotation``, falls nicht 0°, sonst 180° bei ``rotate180`` (ältere
    /// Einstellung `lwRotate180`), sonst 0°.
    public var effectiveRotation: PrintRotation {
        rotation != .r0 ? rotation : (rotate180 ? .r180 : .r0)
    }

    /// Wirksame Steuerzeichen (``ControlCharacters/standard`` bei „Standard“).
    public var effectiveControlCharacters: ControlCharacters {
        controlCharacters?.clamped() ?? .standard
    }

    /// `true`, wenn ``powerUpAction`` und ``headCloseAction`` gesetzt sind (nur dann wird `^MF` gesendet).
    public var hasMediaFeedActions: Bool { powerUpAction != nil && headCloseAction != nil }
}

// MARK: - CUPS-Optionen

/// Namen der CUPS-Optionen. Identisch in PPD-Generator und C-Filter.
public enum CUPSOptionName {
    public static let language = "lwLanguage"
    public static let darkness = "lwDarkness"
    public static let speed = "lwSpeed"
    public static let mediaType = "lwMediaType"
    public static let tracking = "lwMediaTracking"
    public static let printMode = "lwPrintMode"
    public static let labelTop = "lwLabelTop"
    public static let labelLeft = "lwLabelLeft"
    public static let tearOff = "lwTearOff"
    public static let backfeed = "lwBackfeed"
    public static let mirror = "lwMirror"
    public static let negative = "lwNegative"
    public static let rotate180 = "lwRotate180"
    public static let dither = "lwDither"
    public static let threshold = "lwThreshold"
    public static let compression = "lwCompression"
    public static let cutEvery = "lwCutEvery"
    public static let calibrate = "lwCalibrate"
    public static let saveSettings = "lwSaveSettings"
    public static let skipBlank = "lwSkipBlank"
    public static let startCommands = "lwStartCmd"
    public static let endCommands = "lwEndCmd"
    public static let rotation = "lwRotation"
    public static let markOffset = "lwMarkOffset"
    public static let stopAtLast = "lwStopAtLast"
    public static let stopOffset = "lwStopOffset"
    public static let pauseEvery = "lwPauseEvery"
    public static let controlChars = "lwControlChars"
    public static let formatPrefix = "lwFormatPrefix"
    public static let controlPrefix = "lwControlPrefix"
    public static let delimiter = "lwDelimiter"
    public static let rtc = "lwRTC"
    public static let cancelBefore = "lwCancelBefore"
    public static let cancelDelay = "lwCancelDelay"
    public static let labelStartCommands = "lwLabelStartCmd"
    public static let labelEndCommands = "lwLabelEndCmd"
    public static let powerUpAction = "lwPowerUpAction"
    public static let headCloseAction = "lwHeadCloseAction"

    /// `lwControlChars`: Standardzeichen (`^ ~ ,`).
    public static let controlCharsStandard = "Standard"
    /// `lwControlChars`: im Drucker eingestellte Zeichen („Intern“, mit `lwFormatPrefix` …).
    public static let controlCharsPrinter = "Printer"

    /// Wert für „Druckereinstellung beibehalten“.
    public static let defaultValue = "Default"

    public static let all: [String] = [
        language, darkness, speed, mediaType, tracking, printMode, labelTop, labelLeft, tearOff,
        backfeed, mirror, negative, rotate180, dither, threshold, compression, cutEvery, calibrate,
        saveSettings, skipBlank, startCommands, endCommands,
        rotation, markOffset, stopAtLast, stopOffset, pauseEvery, controlChars, formatPrefix, controlPrefix,
        delimiter, rtc, cancelBefore, cancelDelay, labelStartCommands, labelEndCommands, powerUpAction,
        headCloseAction,
    ]

    /// Optionen ohne PPD-Eintrag (Base64url-Rohbefehle, Steuerzeichen und die veraltete
    /// `lwRotate180`): nur als Warteschlangen-Standard (`-o name-default=…`) bzw. Auftragsoption möglich.
    public static let nonPPD: [String] = [
        startCommands, endCommands, labelStartCommands, labelEndCommands, formatPrefix, controlPrefix, delimiter,
        rotate180,
    ]
}

extension PrintSettings {
    /// Wandelt die Einstellungen in CUPS-Optionen um (`lpoptions`/`lpadmin -o name=value`).
    ///
    /// Leere Start-/Endbefehle (auch je Etikett) werden weggelassen, ebenso `lwFormatPrefix`,
    /// `lwControlPrefix` und `lwDelimiter` bei Standard-Steuerzeichen.
    public func cupsOptions() -> [String: String] {
        let s = clamped()
        var o: [String: String] = [:]
        let d = CUPSOptionName.defaultValue
        o[CUPSOptionName.darkness] = s.darkness.map(String.init) ?? d
        o[CUPSOptionName.speed] = s.speed.map(String.init) ?? d
        o[CUPSOptionName.mediaType] = s.mediaType?.cupsValue ?? d
        o[CUPSOptionName.tracking] = s.tracking?.cupsValue ?? d
        o[CUPSOptionName.printMode] = s.printMode?.cupsValue ?? d
        o[CUPSOptionName.labelTop] = s.labelTop.map(String.init) ?? d
        o[CUPSOptionName.labelLeft] = s.labelLeft.map(String.init) ?? d
        o[CUPSOptionName.tearOff] = s.tearOffAdjust.map(String.init) ?? d
        o[CUPSOptionName.backfeed] = s.backfeed?.cupsValue ?? d
        o[CUPSOptionName.mirror] = s.mirror ? "True" : "False"
        o[CUPSOptionName.negative] = s.negative ? "True" : "False"
        o[CUPSOptionName.rotate180] = s.rotate180 ? "True" : "False"
        o[CUPSOptionName.dither] = s.dither.cupsValue
        o[CUPSOptionName.threshold] = String(s.threshold)
        o[CUPSOptionName.compression] = s.compression.cupsValue
        o[CUPSOptionName.cutEvery] = String(s.cutEvery)
        o[CUPSOptionName.calibrate] = s.calibrateBeforeJob ? "True" : "False"
        o[CUPSOptionName.saveSettings] = s.saveToPrinter ? "True" : "False"
        o[CUPSOptionName.skipBlank] = s.skipBlankLabels ? "True" : "False"
        if !s.startCommands.isEmpty {
            o[CUPSOptionName.startCommands] = CUPSCommandEncoding.encode(s.startCommands)
        }
        if !s.endCommands.isEmpty {
            o[CUPSOptionName.endCommands] = CUPSCommandEncoding.encode(s.endCommands)
        }
        o[CUPSOptionName.rotation] = s.rotation.cupsValue
        o[CUPSOptionName.markOffset] = s.markOffset.map(String.init) ?? d
        o[CUPSOptionName.stopAtLast] = s.stopAtLastElement ? "True" : "False"
        o[CUPSOptionName.stopOffset] = String(s.stopOffset)
        o[CUPSOptionName.pauseEvery] = String(s.pauseEvery)
        if let chars = s.controlCharacters {
            o[CUPSOptionName.controlChars] = CUPSOptionName.controlCharsPrinter
            o[CUPSOptionName.formatPrefix] = String(chars.formatPrefix)
            o[CUPSOptionName.controlPrefix] = String(chars.controlPrefix)
            o[CUPSOptionName.delimiter] = String(chars.delimiter)
        } else {
            o[CUPSOptionName.controlChars] = CUPSOptionName.controlCharsStandard
        }
        o[CUPSOptionName.rtc] = s.rtcUpdate?.cupsValue ?? d
        o[CUPSOptionName.cancelBefore] = s.cancelJobsBeforePrint ? "True" : "False"
        o[CUPSOptionName.cancelDelay] = String(s.cancelDelayMs)
        if !s.labelStartCommands.isEmpty {
            o[CUPSOptionName.labelStartCommands] = CUPSCommandEncoding.encode(s.labelStartCommands)
        }
        if !s.labelEndCommands.isEmpty {
            o[CUPSOptionName.labelEndCommands] = CUPSCommandEncoding.encode(s.labelEndCommands)
        }
        o[CUPSOptionName.powerUpAction] = s.powerUpAction?.cupsValue ?? d
        o[CUPSOptionName.headCloseAction] = s.headCloseAction?.cupsValue ?? d
        return o
    }

    /// Liest Einstellungen aus CUPS-Optionen. Unbekannte oder ungültige Werte werden ignoriert.
    public init(cupsOptions o: [String: String]) {
        self.init()
        func int(_ key: String) -> Int? {
            guard let v = o[key], v != CUPSOptionName.defaultValue else { return nil }
            return Int(v.trimmingCharacters(in: .whitespaces))
        }
        func bool(_ key: String) -> Bool {
            guard let v = o[key]?.lowercased() else { return false }
            return ["true", "yes", "on", "1"].contains(v)
        }
        darkness = int(CUPSOptionName.darkness)
        speed = int(CUPSOptionName.speed)
        mediaType = o[CUPSOptionName.mediaType].flatMap(MediaType.init(cupsValue:))
        tracking = o[CUPSOptionName.tracking].flatMap(MediaTracking.init(cupsValue:))
        printMode = o[CUPSOptionName.printMode].flatMap(PrintMode.init(cupsValue:))
        labelTop = int(CUPSOptionName.labelTop)
        labelLeft = int(CUPSOptionName.labelLeft)
        tearOffAdjust = int(CUPSOptionName.tearOff)
        backfeed = o[CUPSOptionName.backfeed].flatMap(BackfeedMode.init(cupsValue:))
        mirror = bool(CUPSOptionName.mirror)
        negative = bool(CUPSOptionName.negative)
        rotate180 = bool(CUPSOptionName.rotate180)
        dither = o[CUPSOptionName.dither].flatMap(DitherAlgorithm.init(cupsValue:)) ?? .threshold
        threshold = int(CUPSOptionName.threshold) ?? 128
        compression = o[CUPSOptionName.compression].flatMap(GraphicCompression.init(cupsValue:)) ?? .z64
        cutEvery = int(CUPSOptionName.cutEvery) ?? 0
        calibrateBeforeJob = bool(CUPSOptionName.calibrate)
        saveToPrinter = bool(CUPSOptionName.saveSettings)
        skipBlankLabels = bool(CUPSOptionName.skipBlank)
        startCommands = o[CUPSOptionName.startCommands].flatMap(CUPSCommandEncoding.decode) ?? ""
        endCommands = o[CUPSOptionName.endCommands].flatMap(CUPSCommandEncoding.decode) ?? ""
        rotation = o[CUPSOptionName.rotation].flatMap(PrintRotation.init(cupsValue:)) ?? .r0
        markOffset = int(CUPSOptionName.markOffset)
        stopAtLastElement = bool(CUPSOptionName.stopAtLast)
        stopOffset = int(CUPSOptionName.stopOffset) ?? 0
        pauseEvery = int(CUPSOptionName.pauseEvery) ?? 0
        if o[CUPSOptionName.controlChars]?.trimmingCharacters(in: .whitespaces).lowercased()
            == CUPSOptionName.controlCharsPrinter.lowercased() {
            // Dezimaler ASCII-Code 33…126; fehlend oder ungültig → Standardzeichen.
            func character(_ key: String, _ fallback: UInt8) -> UInt8 {
                guard let value = int(key), let byte = UInt8(exactly: value),
                      ControlCharacters.validRange.contains(byte) else { return fallback }
                return byte
            }
            controlCharacters = ControlCharacters(formatPrefix: character(CUPSOptionName.formatPrefix, 0x5E),
                                                  controlPrefix: character(CUPSOptionName.controlPrefix, 0x7E),
                                                  delimiter: character(CUPSOptionName.delimiter, 0x2C))
        }
        rtcUpdate = o[CUPSOptionName.rtc].flatMap(RTCUpdate.init(cupsValue:))
        cancelJobsBeforePrint = bool(CUPSOptionName.cancelBefore)
        cancelDelayMs = int(CUPSOptionName.cancelDelay) ?? 1000
        labelStartCommands = o[CUPSOptionName.labelStartCommands].flatMap(CUPSCommandEncoding.decode) ?? ""
        labelEndCommands = o[CUPSOptionName.labelEndCommands].flatMap(CUPSCommandEncoding.decode) ?? ""
        powerUpAction = o[CUPSOptionName.powerUpAction].flatMap(MediaFeedAction.init(cupsValue:))
        headCloseAction = o[CUPSOptionName.headCloseAction].flatMap(MediaFeedAction.init(cupsValue:))
        self = clamped()
    }
}

/// Kodiert beliebige Rohbefehle (mit Leer- und Sonderzeichen) sicher als CUPS-Optionswert:
/// UTF-8 → Base64url ohne Padding (`A–Z a–z 0–9 - _`).
public enum CUPSCommandEncoding {
    public static func encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) -> String? {
        var b64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Tolerantes Dekodieren

extension PrintSettings {
    /// Dekodiert fehlende oder unbekannte Werte (z. B. aus einer neueren App-Version) mit
    /// Standardwerten, statt die gesamten Einstellungen zu verwerfen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        self.init(
            darkness: value(Int.self, .darkness),
            speed: value(Int.self, .speed),
            mediaType: value(MediaType.self, .mediaType),
            tracking: value(MediaTracking.self, .tracking),
            printMode: value(PrintMode.self, .printMode),
            labelTop: value(Int.self, .labelTop),
            labelLeft: value(Int.self, .labelLeft),
            tearOffAdjust: value(Int.self, .tearOffAdjust),
            backfeed: value(BackfeedMode.self, .backfeed),
            mirror: value(Bool.self, .mirror) ?? false,
            negative: value(Bool.self, .negative) ?? false,
            rotate180: value(Bool.self, .rotate180) ?? false,
            dither: value(DitherAlgorithm.self, .dither) ?? .threshold,
            threshold: value(Int.self, .threshold) ?? 128,
            compression: value(GraphicCompression.self, .compression) ?? .z64,
            cutEvery: value(Int.self, .cutEvery) ?? 0,
            calibrateBeforeJob: value(Bool.self, .calibrateBeforeJob) ?? false,
            saveToPrinter: value(Bool.self, .saveToPrinter) ?? false,
            skipBlankLabels: value(Bool.self, .skipBlankLabels) ?? false,
            startCommands: value(String.self, .startCommands) ?? "",
            endCommands: value(String.self, .endCommands) ?? "",
            rotation: value(PrintRotation.self, .rotation) ?? .r0,
            markOffset: value(Int.self, .markOffset),
            stopAtLastElement: value(Bool.self, .stopAtLastElement) ?? false,
            stopOffset: value(Int.self, .stopOffset) ?? 0,
            pauseEvery: value(Int.self, .pauseEvery) ?? 0,
            controlCharacters: value(ControlCharacters.self, .controlCharacters),
            rtcUpdate: value(RTCUpdate.self, .rtcUpdate),
            cancelJobsBeforePrint: value(Bool.self, .cancelJobsBeforePrint) ?? false,
            cancelDelayMs: value(Int.self, .cancelDelayMs) ?? 1000,
            labelStartCommands: value(String.self, .labelStartCommands) ?? "",
            labelEndCommands: value(String.self, .labelEndCommands) ?? "",
            powerUpAction: value(MediaFeedAction.self, .powerUpAction),
            headCloseAction: value(MediaFeedAction.self, .headCloseAction)
        )
        self = clamped()
    }
}

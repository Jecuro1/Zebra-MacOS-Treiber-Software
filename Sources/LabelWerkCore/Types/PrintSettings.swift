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

    // MARK: An Etikett anpassen (macOS-Druckdialog)

    /// „An Etikett anpassen“ (`lwFitToLabel`): Seiten, deren Größe um mehr als 2 mm vom Etikett
    /// abweicht (z. B. A4 aus Vorschau), legt der Treiber automatisch auf das Etikett (§8).
    public var fitToLabel: LabelFitMode
    /// Etikettenbreite der Warteschlange in 1/100 mm (`lwLabelWidth`, 0…100 000; 0 = unbekannt).
    /// Kommt aus dem Etikettenformat, nicht aus einer Benutzereingabe: vor `cupsOptions()` mit
    /// ``withLabelSize(of:)`` bzw. ``setLabelSize(widthMM:heightMM:)`` setzen.
    public var labelWidthHundredthsMM: Int
    /// Etikettenlänge in 1/100 mm (`lwLabelHeight`, 0…100 000; 0 = unbekannt bzw. Endlosmaterial:
    /// dann passt der Treiber nur die Breite an).
    public var labelHeightHundredthsMM: Int

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
        headCloseAction: MediaFeedAction? = nil,
        fitToLabel: LabelFitMode = .auto,
        labelWidthHundredthsMM: Int = 0,
        labelHeightHundredthsMM: Int = 0
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
        self.fitToLabel = fitToLabel
        self.labelWidthHundredthsMM = labelWidthHundredthsMM
        self.labelHeightHundredthsMM = labelHeightHundredthsMM
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
        s.labelWidthHundredthsMM = min(max(labelWidthHundredthsMM, 0), Self.maxLabelSizeHundredthsMM)
        s.labelHeightHundredthsMM = min(max(labelHeightHundredthsMM, 0), Self.maxLabelSizeHundredthsMM)
        return s
    }

    /// Obergrenze von `lwLabelWidth`/`lwLabelHeight` in 1/100 mm (1 m).
    public static let maxLabelSizeHundredthsMM = 100_000

    /// Etikettengröße in Millimetern (`nil`, solange die Breite unbekannt ist; Höhe 0 = Endlosmaterial
    /// bzw. unbekannt).
    public var labelSizeMM: (width: Double, height: Double)? {
        guard labelWidthHundredthsMM > 0 else { return nil }
        return (Double(labelWidthHundredthsMM) / 100, Double(labelHeightHundredthsMM) / 100)
    }

    /// Setzt die Etikettengröße der Warteschlange (auf 1/100 mm gerundet, begrenzt auf 0…1 m;
    /// ungültige oder negative Werte → 0 = unbekannt).
    public mutating func setLabelSize(widthMM: Double, heightMM: Double) {
        func hundredths(_ mm: Double) -> Int {
            guard mm.isFinite, mm > 0 else { return 0 }
            return min(Int((mm * 100).rounded()), Self.maxLabelSizeHundredthsMM)
        }
        labelWidthHundredthsMM = hundredths(widthMM)
        labelHeightHundredthsMM = hundredths(heightMM)
    }

    /// Kopie mit der Etikettengröße des Formats (`lwLabelWidth`/`lwLabelHeight` für die Warteschlange).
    /// Endlosmaterial erhält die Länge 0: Der Treiber passt dort nur die Breite an (§8), lange Belege
    /// bleiben lang. `nil` = Größe unbekannt (beide 0).
    public func withLabelSize(of stock: LabelStock?) -> PrintSettings {
        var s = self
        guard let stock else {
            s.labelWidthHundredthsMM = 0
            s.labelHeightHundredthsMM = 0
            return s
        }
        s.setLabelSize(widthMM: stock.widthMM, heightMM: stock.isContinuous ? 0 : stock.heightMM)
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
    /// „An Etikett anpassen“: `Auto` (Standard) | `Off` (PPD-Option, Gruppe „Seite einrichten“).
    public static let fitToLabel = "lwFitToLabel"
    /// Etikettenbreite der Warteschlange in 1/100 mm (nur Warteschlangen-Standard, nicht in der PPD).
    public static let labelWidth = "lwLabelWidth"
    /// Etikettenlänge der Warteschlange in 1/100 mm (nur Warteschlangen-Standard, nicht in der PPD).
    public static let labelHeight = "lwLabelHeight"

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
        headCloseAction, fitToLabel, labelWidth, labelHeight,
    ]

    /// Optionen ohne PPD-Eintrag (Base64url-Rohbefehle, Steuerzeichen, die veraltete `lwRotate180`
    /// und die Etikettengröße `lwLabelWidth`/`lwLabelHeight`): nur als Warteschlangen-Standard
    /// (`-o name-default=…`) bzw. Auftragsoption möglich.
    public static let nonPPD: [String] = [
        startCommands, endCommands, labelStartCommands, labelEndCommands, formatPrefix, controlPrefix, delimiter,
        rotate180, labelWidth, labelHeight,
    ]
}

extension PrintSettings {
    /// Wandelt die Einstellungen in CUPS-Optionen um (`lpoptions`/`lpadmin -o name=value`).
    ///
    /// Leere Start-/Endbefehle (auch je Etikett) werden weggelassen, ebenso `lwFormatPrefix`,
    /// `lwControlPrefix` und `lwDelimiter` bei Standard-Steuerzeichen und `lwLabelWidth`/`lwLabelHeight`
    /// mit dem Wert 0 (unbekannt).
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
        o[CUPSOptionName.fitToLabel] = s.fitToLabel.cupsValue
        if s.labelWidthHundredthsMM > 0 {
            o[CUPSOptionName.labelWidth] = String(s.labelWidthHundredthsMM)
        }
        if s.labelHeightHundredthsMM > 0 {
            o[CUPSOptionName.labelHeight] = String(s.labelHeightHundredthsMM)
        }
        return o
    }

    /// Liest Einstellungen aus CUPS-Optionen. Unbekannte oder ungültige Werte werden ignoriert.
    ///
    /// Gelesen wird wie im C-Filter und in der Python-Referenz (ARCHITECTURE.md §9): Leerraum am
    /// Rand zählt nicht, Aufzählungswerte und Wahrheitswerte ohne Beachtung der Groß-/Kleinschreibung,
    /// Ganzzahlen optional mit `Custom.`-Präfix (PPD-Eigenwerte) und Vorzeichen, nur Ziffern.
    public init(cupsOptions o: [String: String]) {
        self.init()
        /// Wert ohne Leerraum am Rand; leer → nicht gesetzt.
        func text(_ key: String) -> String? {
            guard let raw = o[key] else { return nil }
            let value = CUPSValueMatching.trimmed(raw)
            return value.isEmpty ? nil : value
        }
        func int(_ key: String) -> Int? {
            guard var v = text(key), !CUPSValueMatching.equals(v, CUPSOptionName.defaultValue) else { return nil }
            if CUPSValueMatching.asciiLowercased(String(v.prefix(7))) == "custom." { v = String(v.dropFirst(7)) }
            // Wie lw_parse_int: optionales Vorzeichen, dann nur ASCII-Ziffern – genau das nimmt Int() an.
            return Int(v)
        }
        func bool(_ key: String) -> Bool {
            guard let v = text(key) else { return false }
            return ["true", "yes", "on", "1"].contains(CUPSValueMatching.asciiLowercased(v))
        }
        func commands(_ key: String) -> String {
            guard let v = text(key), !["default", "none"].contains(CUPSValueMatching.asciiLowercased(v)) else { return "" }
            return CUPSCommandEncoding.decode(v) ?? ""
        }
        darkness = int(CUPSOptionName.darkness)
        speed = int(CUPSOptionName.speed)
        mediaType = text(CUPSOptionName.mediaType).flatMap(MediaType.init(cupsValue:))
        tracking = text(CUPSOptionName.tracking).flatMap(MediaTracking.init(cupsValue:))
        printMode = text(CUPSOptionName.printMode).flatMap(PrintMode.init(cupsValue:))
        labelTop = int(CUPSOptionName.labelTop)
        labelLeft = int(CUPSOptionName.labelLeft)
        tearOffAdjust = int(CUPSOptionName.tearOff)
        backfeed = text(CUPSOptionName.backfeed).flatMap(BackfeedMode.init(cupsValue:))
        mirror = bool(CUPSOptionName.mirror)
        negative = bool(CUPSOptionName.negative)
        rotate180 = bool(CUPSOptionName.rotate180)
        dither = text(CUPSOptionName.dither).flatMap(DitherAlgorithm.init(cupsValue:)) ?? .threshold
        threshold = int(CUPSOptionName.threshold) ?? 128
        compression = text(CUPSOptionName.compression).flatMap(GraphicCompression.init(cupsValue:)) ?? .z64
        cutEvery = int(CUPSOptionName.cutEvery) ?? 0
        calibrateBeforeJob = bool(CUPSOptionName.calibrate)
        saveToPrinter = bool(CUPSOptionName.saveSettings)
        skipBlankLabels = bool(CUPSOptionName.skipBlank)
        startCommands = commands(CUPSOptionName.startCommands)
        endCommands = commands(CUPSOptionName.endCommands)
        rotation = text(CUPSOptionName.rotation).flatMap(PrintRotation.init(cupsValue:)) ?? .r0
        markOffset = int(CUPSOptionName.markOffset)
        stopAtLastElement = bool(CUPSOptionName.stopAtLast)
        stopOffset = int(CUPSOptionName.stopOffset) ?? 0
        pauseEvery = int(CUPSOptionName.pauseEvery) ?? 0
        if let chars = text(CUPSOptionName.controlChars),
           CUPSValueMatching.equals(chars, CUPSOptionName.controlCharsPrinter) {
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
        rtcUpdate = text(CUPSOptionName.rtc).flatMap(RTCUpdate.init(cupsValue:))
        cancelJobsBeforePrint = bool(CUPSOptionName.cancelBefore)
        cancelDelayMs = int(CUPSOptionName.cancelDelay) ?? 1000
        labelStartCommands = commands(CUPSOptionName.labelStartCommands)
        labelEndCommands = commands(CUPSOptionName.labelEndCommands)
        powerUpAction = text(CUPSOptionName.powerUpAction).flatMap(MediaFeedAction.init(cupsValue:))
        headCloseAction = text(CUPSOptionName.headCloseAction).flatMap(MediaFeedAction.init(cupsValue:))
        fitToLabel = text(CUPSOptionName.fitToLabel).flatMap(LabelFitMode.init(cupsValue:)) ?? .auto
        labelWidthHundredthsMM = int(CUPSOptionName.labelWidth) ?? 0
        labelHeightHundredthsMM = int(CUPSOptionName.labelHeight) ?? 0
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
            headCloseAction: value(MediaFeedAction.self, .headCloseAction),
            fitToLabel: value(LabelFitMode.self, .fitToLabel) ?? .auto,
            labelWidthHundredthsMM: value(Int.self, .labelWidthHundredthsMM) ?? 0,
            labelHeightHundredthsMM: value(Int.self, .labelHeightHundredthsMM) ?? 0
        )
        self = clamped()
    }
}

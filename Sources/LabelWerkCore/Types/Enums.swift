import Foundation

// MARK: - Druckersprache

/// Befehlssprache des Druckers.
public enum PrinterLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case zpl
    case epl
    case cpcl

    public var id: String { rawValue }

    /// Wert für die CUPS-Option `lwLanguage`.
    public var cupsValue: String {
        switch self {
        case .zpl: return "ZPL"
        case .epl: return "EPL"
        case .cpcl: return "CPCL"
        }
    }

    public init?(cupsValue: String) {
        switch cupsValue.uppercased() {
        case "ZPL", "ZPL2", "ZPLII": self = .zpl
        case "EPL", "EPL2": self = .epl
        case "CPCL": self = .cpcl
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .zpl: return "ZPL II"
        case .epl: return "EPL2"
        case .cpcl: return "CPCL"
        }
    }
}

// MARK: - Medientyp

/// Thermodirekt (ohne Farbband) oder Thermotransfer (mit Farbband).
public enum MediaType: String, Codable, CaseIterable, Sendable, Identifiable {
    case directThermal
    case thermalTransfer

    public var id: String { rawValue }

    /// ZPL `^MT`-Parameter.
    public var zplCode: String { self == .directThermal ? "D" : "T" }

    public var cupsValue: String { self == .directThermal ? "DirectThermal" : "ThermalTransfer" }

    public init?(cupsValue: String) {
        switch cupsValue {
        case "DirectThermal": self = .directThermal
        case "ThermalTransfer": self = .thermalTransfer
        default: return nil
        }
    }

    /// Deutsche Bezeichnung wie im Windows-Treiber („Druckmodus“).
    public var displayName: String {
        self == .directThermal ? "Thermo-Direkt" : "Thermotransfer"
    }
}

// MARK: - Medienerkennung

/// Art der Etikettenerkennung (Sensor).
public enum MediaTracking: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Etiketten mit Lücke (Gap/Web-Sensing).
    case gap
    /// Etiketten mit schwarzer Markierung auf der Rückseite.
    case blackMark
    /// Endlosmaterial.
    case continuous
    /// Automatische Erkennung beim Kalibrieren.
    case autoDetect
    /// Etiketten mit Seitenkerben (Web-Sensing, `^MNW`).
    case notch

    public var id: String { rawValue }

    /// ZPL `^MN`-Parameter.
    public var zplCode: String {
        switch self {
        case .gap: return "Y"
        case .blackMark: return "M"
        case .continuous: return "N"
        case .autoDetect: return "A"
        case .notch: return "W"
        }
    }

    public var cupsValue: String {
        switch self {
        case .gap: return "Gap"
        case .blackMark: return "BlackMark"
        case .continuous: return "Continuous"
        case .autoDetect: return "Auto"
        case .notch: return "Notch"
        }
    }

    public init?(cupsValue: String) {
        switch cupsValue {
        case "Gap": self = .gap
        case "BlackMark": self = .blackMark
        case "Continuous": self = .continuous
        case "Auto": self = .autoDetect
        case "Notch": self = .notch
        default: return nil
        }
    }

    /// Deutsche Bezeichnung wie im Windows-Treiber („Medientyp“).
    public var displayName: String {
        switch self {
        case .gap: return "Einzeletiketten"
        case .blackMark: return "Etiketten mit schwarzen Markierungen"
        case .continuous: return "Endlosmaterial"
        case .autoDetect: return "Automatisch erkennen"
        case .notch: return "Etiketten mit Seitenkerben"
        }
    }
}

// MARK: - Druckmodus

/// Verhalten des Druckers nach dem Druck eines Etiketts („Bedienermodus“ im Windows-Treiber).
///
/// Die klassischen Modi werden per ZPL `^MM` gesetzt. Die Linerless-Modi (Etiketten ohne
/// Trägermaterial) haben keinen `^MM`-Code; sie werden über die SGD-Variable `media.printmode`
/// gesetzt (``usesSGD``, ``sgdValue``).
public enum PrintMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case tearOff
    case peelOff
    case cutter
    case delayedCut
    case rewind
    case applicator
    case kiosk
    /// Linerless: ablösen (`media.printmode` = `linerless peel`).
    case linerlessPeel
    /// Linerless: schneiden (`linerless cut`).
    case linerlessCut
    /// Linerless: verzögert schneiden (`linerless delayed cut`).
    case linerlessDelayedCut
    /// Linerless: aufwickeln (`linerless rewind`).
    case linerlessRewind
    /// Linerless: abreißen (`linerless tear`).
    case linerlessTear

    public var id: String { rawValue }

    /// `true` für die Linerless-Modi (ohne Trägermaterial).
    public var isLinerless: Bool {
        switch self {
        case .linerlessPeel, .linerlessCut, .linerlessDelayedCut, .linerlessRewind, .linerlessTear: return true
        case .tearOff, .peelOff, .cutter, .delayedCut, .rewind, .applicator, .kiosk: return false
        }
    }

    /// `true`, wenn der Modus nur per SGD (`media.printmode`) gesetzt werden kann – kein `^MM`.
    /// Gilt genau für die Linerless-Modi.
    public var usesSGD: Bool { isLinerless }

    /// Der gleichwertige klassische Modus (Linerless ablösen → Spenden usw.); klassische Modi
    /// liefern sich selbst.
    public var classicEquivalent: PrintMode {
        switch self {
        case .linerlessPeel: return .peelOff
        case .linerlessCut: return .cutter
        case .linerlessDelayedCut: return .delayedCut
        case .linerlessRewind: return .rewind
        case .linerlessTear: return .tearOff
        case .tearOff, .peelOff, .cutter, .delayedCut, .rewind, .applicator, .kiosk: return self
        }
    }

    /// ZPL `^MM`-Parameter (`T P C D R A K`).
    ///
    /// Linerless-Modi haben keinen eigenen Code; geliefert wird der Code des gleichwertigen
    /// klassischen Modus (``classicEquivalent``). Druckaufträge und ``usesSGD``-bewusste Aufrufer
    /// senden für Linerless-Modi **kein** `^MM`, sondern `media.printmode` per SGD.
    public var zplCode: String {
        switch self {
        case .tearOff: return "T"
        case .peelOff: return "P"
        case .cutter: return "C"
        case .delayedCut: return "D"
        case .rewind: return "R"
        case .applicator: return "A"
        case .kiosk: return "K"
        case .linerlessPeel, .linerlessCut, .linerlessDelayedCut, .linerlessRewind, .linerlessTear:
            return classicEquivalent.zplCode
        }
    }

    /// `^MM`-Code nur für klassische Modi; `nil` für Linerless-Modi.
    public var mmCode: String? { isLinerless ? nil : zplCode }

    /// Umkehrung von `zplCode` (z. B. für `~HS`-Auswertung) – liefert nur klassische Modi.
    public init?(zplCode: String) {
        let code = zplCode.uppercased()
        guard let match = PrintMode.allCases.first(where: { !$0.isLinerless && $0.zplCode == code }) else { return nil }
        self = match
    }

    /// Wert der SGD-Variablen `media.printmode`.
    public var sgdValue: String {
        switch self {
        case .tearOff: return "tear off"
        case .peelOff: return "peel off"
        case .cutter: return "cutter"
        case .delayedCut: return "delayed cut"
        case .rewind: return "rewind"
        case .applicator: return "applicator"
        case .kiosk: return "kiosk"
        case .linerlessPeel: return "linerless peel"
        case .linerlessCut: return "linerless cut"
        case .linerlessDelayedCut: return "linerless delayed cut"
        case .linerlessRewind: return "linerless rewind"
        case .linerlessTear: return "linerless tear"
        }
    }

    /// Umkehrung von ``sgdValue`` (ohne Beachtung von Groß-/Kleinschreibung, Leerzeichen am
    /// Rand, `_`/`-` statt Leerzeichen).
    public init?(sgdValue: String) {
        let key = sgdValue.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let match = PrintMode.allCases.first(where: { $0.sgdValue == key }) else { return nil }
        self = match
    }

    public var cupsValue: String {
        switch self {
        case .tearOff: return "TearOff"
        case .peelOff: return "PeelOff"
        case .cutter: return "Cutter"
        case .delayedCut: return "DelayedCut"
        case .rewind: return "Rewind"
        case .applicator: return "Applicator"
        case .kiosk: return "Kiosk"
        case .linerlessPeel: return "LinerlessPeel"
        case .linerlessCut: return "LinerlessCut"
        case .linerlessDelayedCut: return "LinerlessDelayedCut"
        case .linerlessRewind: return "LinerlessRewind"
        case .linerlessTear: return "LinerlessTear"
        }
    }

    public init?(cupsValue: String) {
        guard let match = PrintMode.allCases.first(where: { $0.cupsValue == cupsValue }) else { return nil }
        self = match
    }

    /// Deutsche Bezeichnung wie im Windows-Treiber („Bedienermodus“).
    public var displayName: String {
        switch self {
        case .tearOff: return "Abreißen"
        case .peelOff: return "Spendemodus"
        case .cutter: return "Abschneider"
        case .delayedCut: return "Verzögerter Abschneider"
        case .rewind: return "Aufwickeln"
        case .applicator: return "Applikator"
        case .kiosk: return "Kiosk"
        case .linerlessPeel: return "Linerless ablösen"
        case .linerlessCut: return "Linerless schneiden"
        case .linerlessDelayedCut: return "Linerless verzögert schneiden"
        case .linerlessRewind: return "Linerless aufwickeln"
        case .linerlessTear: return "Linerless-Abriss"
        }
    }

    /// `true` für Modi mit Schneider (Abschneider, verzögerter Abschneider, Kiosk, Linerless
    /// schneiden/verzögert schneiden) – dort ist „Schneiden alle N Etiketten“ sinnvoll.
    public var usesCutter: Bool {
        switch self {
        case .cutter, .delayedCut, .kiosk, .linerlessCut, .linerlessDelayedCut: return true
        case .tearOff, .peelOff, .rewind, .applicator, .linerlessPeel, .linerlessRewind, .linerlessTear: return false
        }
    }
}

// MARK: - Rasterung

/// Verfahren zur Umwandlung von Graustufen in reines Schwarz/Weiß.
public enum DitherAlgorithm: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Harte Schwelle – ideal für Text und Barcodes.
    case threshold
    /// Geordnete Rasterung (Bayer 8×8).
    case ordered
    /// Klassisches Halbton-Punktraster (Clustered Dot).
    case halftone
    /// Fehlerdiffusion nach Floyd–Steinberg.
    case floydSteinberg
    /// Fehlerdiffusion nach Atkinson (kontrastreich).
    case atkinson
    /// Fehlerdiffusion nach Stucki (sehr fein).
    case stucki

    public var id: String { rawValue }

    public var cupsValue: String {
        switch self {
        case .threshold: return "Threshold"
        case .ordered: return "Ordered"
        case .halftone: return "Halftone"
        case .floydSteinberg: return "FloydSteinberg"
        case .atkinson: return "Atkinson"
        case .stucki: return "Stucki"
        }
    }

    public init?(cupsValue: String) {
        guard let match = DitherAlgorithm.allCases.first(where: { $0.cupsValue == cupsValue }) else { return nil }
        self = match
    }

    public var displayName: String {
        switch self {
        case .threshold: return "Schwellenwert (Text & Barcodes)"
        case .ordered: return "Geordnet (Bayer)"
        case .halftone: return "Halbton-Raster"
        case .floydSteinberg: return "Floyd–Steinberg"
        case .atkinson: return "Atkinson"
        case .stucki: return "Stucki"
        }
    }
}

// MARK: - Grafikkompression

/// Kodierung von Bitmaps in `^GF`-Befehlen.
public enum GraphicCompression: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Unkomprimiertes ASCII-Hex.
    case hex
    /// Zebra "Alternative Compression Scheme" (Lauflängen in ASCII).
    case acs
    /// zlib-Deflate + Base64 mit CRC (`:Z64:`).
    case z64

    public var id: String { rawValue }

    public var cupsValue: String {
        switch self {
        case .hex: return "Hex"
        case .acs: return "ACS"
        case .z64: return "Z64"
        }
    }

    public init?(cupsValue: String) {
        switch cupsValue.uppercased() {
        case "HEX": self = .hex
        case "ACS": self = .acs
        case "Z64": self = .z64
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .hex: return "Hex (unkomprimiert)"
        case .acs: return "ACS (Lauflänge)"
        case .z64: return "Z64 (Deflate, empfohlen)"
        }
    }
}

// MARK: - Rückzug (Backfeed)

/// ZPL `~JS` – Reihenfolge des Rückzugs bei Abreiß-/Spendemodus (`^JS` ist die Sensorwahl).
public enum BackfeedMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Rückzug nach dem Druck (`~JSA`).
    case afterPrinting
    /// Rückzug vor dem Druck (`~JSB`).
    case beforePrinting
    /// Normal: 90 % vor, 10 % nach dem Druck (`~JSN`).
    case normal
    /// Kein Rückzug (`~JSO`).
    case off

    public var id: String { rawValue }

    public var zplCode: String {
        switch self {
        case .afterPrinting: return "A"
        case .beforePrinting: return "B"
        case .normal: return "N"
        case .off: return "O"
        }
    }

    public var cupsValue: String {
        switch self {
        case .afterPrinting: return "After"
        case .beforePrinting: return "Before"
        case .normal: return "Normal"
        case .off: return "Off"
        }
    }

    public init?(cupsValue: String) {
        guard let match = BackfeedMode.allCases.first(where: { $0.cupsValue == cupsValue }) else { return nil }
        self = match
    }

    /// Deutsche Bezeichnung wie im Windows-Treiber („Rückzug“).
    public var displayName: String {
        switch self {
        case .afterPrinting: return "Nach dem Drucken"
        case .beforePrinting: return "Vor dem Drucken"
        case .normal: return "Standard"
        case .off: return "Kein Rückzug"
        }
    }
}

// MARK: - Drehung

/// Drehung der Druckseite im Uhrzeigersinn („Drehung“ im Windows-Treiber).
///
/// 90° und 270° dreht der Treiber die Bitmap selbst (alle Sprachen), 180° übernimmt bei ZPL
/// `^POI`, bei EPL `ZB`, bei CPCL die Software (ARCHITECTURE.md §8).
public enum PrintRotation: Int, Codable, CaseIterable, Sendable, Identifiable {
    case r0 = 0
    case r90 = 90
    case r180 = 180
    case r270 = 270

    public var id: Int { rawValue }

    /// Drehung im Uhrzeigersinn in Grad.
    public var degrees: Int { rawValue }

    /// Wert der CUPS-Option `lwRotation`.
    public var cupsValue: String { String(rawValue) }

    public init?(cupsValue: String) {
        guard let degrees = Int(cupsValue.trimmingCharacters(in: .whitespaces)),
              let match = PrintRotation(rawValue: degrees) else { return nil }
        self = match
    }

    /// `true` bei 90° und 270° (Hoch- und Querformat tauschen).
    public var isQuarterTurn: Bool { self == .r90 || self == .r270 }

    /// Deutsche Bezeichnung wie im Windows-Treiber.
    public var displayName: String {
        switch self {
        case .r0: return "0° – Hochformat"
        case .r90: return "90° – Querformat"
        case .r180: return "180° – Hochformat"
        case .r270: return "270° – Querformat"
        }
    }
}

// MARK: - Echtzeituhr

/// Wann der Treiber die Echtzeituhr des Druckers stellt (`^ST`, „RTC aktualisieren“).
public enum RTCUpdate: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Einmal zu Beginn des Auftrags („Druckzeit starten“).
    case jobStart
    /// Vor jedem Etikett.
    case everyLabel
    /// Höchstens einmal je Minute (vor einem Etikett, sobald seit dem letzten `^ST` 60 s vergangen sind).
    case everyMinute

    public var id: String { rawValue }

    /// Wert der CUPS-Option `lwRTC`.
    public var cupsValue: String {
        switch self {
        case .jobStart: return "JobStart"
        case .everyLabel: return "EveryLabel"
        case .everyMinute: return "EveryMinute"
        }
    }

    public init?(cupsValue: String) {
        guard let match = RTCUpdate.allCases.first(where: { $0.cupsValue == cupsValue }) else { return nil }
        self = match
    }

    /// Deutsche Bezeichnung wie im Windows-Treiber.
    public var displayName: String {
        switch self {
        case .jobStart: return "Druckzeit starten"
        case .everyLabel: return "Jedes Etikett"
        case .everyMinute: return "Jede Minute"
        }
    }
}

// MARK: - Medienvorschub beim Einschalten / Kopf schließen

/// Aktion beim Einschalten bzw. nach dem Schließen des Druckkopfs (`^MF`, SGD
/// `ezpl.power_up_action` / `ezpl.head_close_action`).
public enum MediaFeedAction: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Ein Etikett vorschieben.
    case feed
    /// Vollständig kalibrieren.
    case calibrate
    /// Etikettenlänge messen.
    case length
    /// Keine Bewegung.
    case noMotion
    /// Kurzkalibrierung.
    case shortCalibration

    public var id: String { rawValue }

    /// ZPL `^MF`-Parameter.
    public var zplCode: String {
        switch self {
        case .feed: return "F"
        case .calibrate: return "C"
        case .length: return "L"
        case .noMotion: return "N"
        case .shortCalibration: return "S"
        }
    }

    public init?(zplCode: String) {
        let code = zplCode.uppercased()
        guard let match = MediaFeedAction.allCases.first(where: { $0.zplCode == code }) else { return nil }
        self = match
    }

    /// Wert der CUPS-Optionen `lwPowerUpAction` / `lwHeadCloseAction`.
    public var cupsValue: String {
        switch self {
        case .feed: return "Feed"
        case .calibrate: return "Calibrate"
        case .length: return "Length"
        case .noMotion: return "NoMotion"
        case .shortCalibration: return "ShortCal"
        }
    }

    public init?(cupsValue: String) {
        guard let match = MediaFeedAction.allCases.first(where: { $0.cupsValue == cupsValue }) else { return nil }
        self = match
    }

    /// Wert der SGD-Variablen `ezpl.power_up_action` / `ezpl.head_close_action`.
    public var sgdValue: String {
        switch self {
        case .feed: return "feed"
        case .calibrate: return "calibrate"
        case .length: return "length"
        case .noMotion: return "no motion"
        case .shortCalibration: return "short cal"
        }
    }

    /// Umkehrung von ``sgdValue`` (tolerant gegenüber Groß-/Kleinschreibung und `_`).
    public init?(sgdValue: String) {
        let key = sgdValue.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: " ")
        switch key {
        case "feed": self = .feed
        case "calibrate", "calibration": self = .calibrate
        case "length": self = .length
        case "no motion", "nomotion", "none": self = .noMotion
        case "short cal", "short calibration", "shortcal": self = .shortCalibration
        default: return nil
        }
    }

    /// Deutsche Bezeichnung.
    public var displayName: String {
        switch self {
        case .feed: return "Vorschub"
        case .calibrate: return "Kalibrieren"
        case .length: return "Länge messen"
        case .noMotion: return "Keine Bewegung"
        case .shortCalibration: return "Kurzkalibrierung"
        }
    }
}

// MARK: - Steuerzeichen

/// Die drei ZPL-Steuerzeichen: Formatpräfix (`^`, `^CC`), Steuerpräfix (`~`, `^CT`) und
/// Trennzeichen (`,`, `^CD`).
///
/// In ``PrintSettings/controlCharacters`` bedeutet `nil` „Standard“ (`^ ~ ,`); ein Wert
/// („Intern“) sind die im Drucker eingestellten Zeichen (SGD `zpl.caret`,
/// `zpl.control_character`, `zpl.delimiter`). Der Treiber erzeugt dann alle selbst erzeugten
/// Befehle mit diesen Zeichen (ARCHITECTURE.md §8).
public struct ControlCharacters: Codable, Hashable, Sendable {
    /// Formatpräfix (Standard `^` = 0x5E).
    public var formatPrefix: UInt8
    /// Steuerpräfix (Standard `~` = 0x7E).
    public var controlPrefix: UInt8
    /// Trennzeichen (Standard `,` = 0x2C).
    public var delimiter: UInt8

    public init(formatPrefix: UInt8 = 0x5E, controlPrefix: UInt8 = 0x7E, delimiter: UInt8 = 0x2C) {
        self.formatPrefix = formatPrefix
        self.controlPrefix = controlPrefix
        self.delimiter = delimiter
    }

    /// `^ ~ ,`
    public static let standard = ControlCharacters()

    /// Zulässige Zeichen: druckbares ASCII ohne Leerzeichen (33…126).
    public static let validRange: ClosedRange<UInt8> = 33...126

    /// `true`, wenn alle drei Zeichen den Standardzeichen entsprechen.
    public var isStandard: Bool { self == .standard }

    /// Ersetzt Zeichen außerhalb von ``validRange`` durch das jeweilige Standardzeichen.
    public func clamped() -> ControlCharacters {
        func valid(_ value: UInt8, _ fallback: UInt8) -> UInt8 { Self.validRange.contains(value) ? value : fallback }
        return ControlCharacters(formatPrefix: valid(formatPrefix, 0x5E),
                                 controlPrefix: valid(controlPrefix, 0x7E),
                                 delimiter: valid(delimiter, 0x2C))
    }

    /// Formatpräfix als Text.
    public var formatPrefixString: String { Self.string(formatPrefix) }
    /// Steuerpräfix als Text.
    public var controlPrefixString: String { Self.string(controlPrefix) }
    /// Trennzeichen als Text.
    public var delimiterString: String { Self.string(delimiter) }

    /// Zeichen aus einem Ein-Zeichen-Text (z. B. SGD `zpl.caret` = `"^"`); `nil` bei leerem,
    /// längerem oder nicht druckbarem Text.
    public static func character(from text: String) -> UInt8? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 1, scalars[0].isASCII else { return nil }
        let value = UInt8(scalars[0].value)
        return validRange.contains(value) ? value : nil
    }

    static func string(_ byte: UInt8) -> String { String(Character(Unicode.Scalar(byte))) }

    /// Tolerantes Dekodieren: fehlende oder ungültige Felder werden zum Standardzeichen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: UInt8) -> UInt8 {
            ((try? c.decodeIfPresent(UInt8.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(formatPrefix: value(.formatPrefix, 0x5E), controlPrefix: value(.controlPrefix, 0x7E),
                  delimiter: value(.delimiter, 0x2C))
    }
}

// MARK: - Feldausrichtung

/// Rotation eines ZPL-Feldes (`^A`, `^B*`, `^FW`).
public enum FieldOrientation: String, Codable, CaseIterable, Sendable {
    case normal = "N"
    case rotated90 = "R"
    case inverted180 = "I"
    case rotated270 = "B"

    /// Drehung im Uhrzeigersinn in Grad.
    public var degrees: Int {
        switch self {
        case .normal: return 0
        case .rotated90: return 90
        case .inverted180: return 180
        case .rotated270: return 270
        }
    }
}

// MARK: - Modellkategorien & Schnittstellen

public enum PrinterCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case desktop
    case industrial
    case mobile
    case healthcare
    case printEngine

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .desktop: return "Desktop"
        case .industrial: return "Industrie"
        case .mobile: return "Mobil"
        case .healthcare: return "Gesundheitswesen"
        case .printEngine: return "Druckmodul"
        }
    }
}

public enum Connectivity: String, Codable, CaseIterable, Sendable, Identifiable {
    case usb
    case ethernet
    case wifi
    case bluetooth
    case ble
    case serial
    case parallel

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .usb: return "USB"
        case .ethernet: return "Ethernet"
        case .wifi: return "WLAN"
        case .bluetooth: return "Bluetooth"
        case .ble: return "Bluetooth LE"
        case .serial: return "Seriell"
        case .parallel: return "Parallel"
        }
    }
}

/// Besondere Fähigkeiten eines Modells.
public enum PrinterFeature: String, Codable, CaseIterable, Sendable {
    /// Link-OS (SGD, JSON-Konfiguration, `allconfig`).
    case linkOS
    /// Set-Get-Do-Befehle (`! U1 getvar`).
    case sgd
    /// RFID-Kodierer verfügbar.
    case rfid
    /// Farbdisplay / LCD.
    case display
    /// Linerless-Medien.
    case linerless
    /// Batteriebetrieb.
    case battery
}

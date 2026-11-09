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

    public var displayName: String {
        self == .directThermal ? "Thermodirekt" : "Thermotransfer"
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

    public var id: String { rawValue }

    /// ZPL `^MN`-Parameter.
    public var zplCode: String {
        switch self {
        case .gap: return "Y"
        case .blackMark: return "M"
        case .continuous: return "N"
        case .autoDetect: return "A"
        }
    }

    public var cupsValue: String {
        switch self {
        case .gap: return "Gap"
        case .blackMark: return "BlackMark"
        case .continuous: return "Continuous"
        case .autoDetect: return "Auto"
        }
    }

    public init?(cupsValue: String) {
        switch cupsValue {
        case "Gap": self = .gap
        case "BlackMark": self = .blackMark
        case "Continuous": self = .continuous
        case "Auto": self = .autoDetect
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .gap: return "Etiketten mit Lücke"
        case .blackMark: return "Schwarze Markierung"
        case .continuous: return "Endlosmaterial"
        case .autoDetect: return "Automatisch"
        }
    }
}

// MARK: - Druckmodus

/// Verhalten des Druckers nach dem Druck eines Etiketts.
public enum PrintMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case tearOff
    case peelOff
    case cutter
    case delayedCut
    case rewind
    case applicator
    case kiosk

    public var id: String { rawValue }

    /// ZPL `^MM`-Parameter.
    public var zplCode: String {
        switch self {
        case .tearOff: return "T"
        case .peelOff: return "P"
        case .cutter: return "C"
        case .delayedCut: return "D"
        case .rewind: return "R"
        case .applicator: return "A"
        case .kiosk: return "K"
        }
    }

    /// Umkehrung von `zplCode` (z. B. für `~HS`-Auswertung).
    public init?(zplCode: String) {
        guard let match = PrintMode.allCases.first(where: { $0.zplCode == zplCode.uppercased() }) else { return nil }
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
        }
    }

    public init?(cupsValue: String) {
        guard let match = PrintMode.allCases.first(where: { $0.cupsValue == cupsValue }) else { return nil }
        self = match
    }

    public var displayName: String {
        switch self {
        case .tearOff: return "Abreißen"
        case .peelOff: return "Spenden (Peel-Off)"
        case .cutter: return "Schneiden"
        case .delayedCut: return "Verzögert schneiden"
        case .rewind: return "Aufwickeln"
        case .applicator: return "Applikator"
        case .kiosk: return "Kiosk"
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

/// ZPL `^JS` – Reihenfolge des Rückzugs bei Abreiß-/Spendemodus.
public enum BackfeedMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Rückzug nach dem Druck (`^JSA`).
    case afterPrinting
    /// Rückzug vor dem Druck (`^JSB`).
    case beforePrinting
    /// Normal: 90 % vor, 10 % nach dem Druck (`^JSN`).
    case normal
    /// Kein Rückzug (`^JSO`).
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

    public var displayName: String {
        switch self {
        case .afterPrinting: return "Nach dem Druck"
        case .beforePrinting: return "Vor dem Druck"
        case .normal: return "Normal (90/10)"
        case .off: return "Aus"
        }
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

import Foundation

/// Beschreibung eines Druckermodells aus dem Modellkatalog (`Catalog/models.json`).
public struct PrinterModel: Codable, Identifiable, Hashable, Sendable {
    /// Stabile Kennung in Kleinbuchstaben, z. B. `zd421t`.
    public var id: String
    /// Anzeigename ohne Herstellerpräfix, z. B. `ZD421t`.
    public var name: String
    /// Baureihe, z. B. `ZD400`.
    public var family: String
    public var category: PrinterCategory
    public var languages: [PrinterLanguage]
    public var defaultLanguage: PrinterLanguage
    /// Verfügbare Auflösungen in dpi.
    public var resolutions: [Int]
    /// Maximale Druckbreite in mm.
    public var printWidthMM: Double
    /// Maximale Etikettenlänge in mm.
    public var maxLabelLengthMM: Double
    /// Höchstgeschwindigkeit (Zoll/s) je Auflösung, Schlüssel = dpi als String.
    public var maxSpeedIPS: [String: Int]
    public var mediaTypes: [MediaType]
    public var printModes: [PrintMode]
    public var connectivity: [Connectivity]
    public var features: [PrinterFeature]
    /// IEEE-1284-Modellnamen (`MDL:`), mit denen macOS den Treiber automatisch zuordnet.
    public var ieee1284: [String]
    /// Kennung des Standard-Etikettenformats.
    public var defaultStock: String

    public init(
        id: String,
        name: String,
        family: String,
        category: PrinterCategory,
        languages: [PrinterLanguage],
        defaultLanguage: PrinterLanguage,
        resolutions: [Int],
        printWidthMM: Double,
        maxLabelLengthMM: Double,
        maxSpeedIPS: [String: Int],
        mediaTypes: [MediaType],
        printModes: [PrintMode],
        connectivity: [Connectivity],
        features: [PrinterFeature],
        ieee1284: [String],
        defaultStock: String
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.category = category
        self.languages = languages
        self.defaultLanguage = defaultLanguage
        self.resolutions = resolutions
        self.printWidthMM = printWidthMM
        self.maxLabelLengthMM = maxLabelLengthMM
        self.maxSpeedIPS = maxSpeedIPS
        self.mediaTypes = mediaTypes
        self.printModes = printModes
        self.connectivity = connectivity
        self.features = features
        self.ieee1284 = ieee1284
        self.defaultStock = defaultStock
    }

    /// Unterstützte Auflösungen als Enum (unbekannte Werte werden verworfen).
    public var supportedResolutions: [Resolution] { resolutions.compactMap(Resolution.init(dpi:)) }

    /// Maximale Druckbreite in Punkten für eine Auflösung.
    public func printWidthDots(_ resolution: Resolution) -> Int { resolution.dots(fromMM: printWidthMM) }

    /// Maximale Etikettenlänge in Punkten für eine Auflösung.
    public func maxLabelLengthDots(_ resolution: Resolution) -> Int { resolution.dots(fromMM: maxLabelLengthMM) }

    /// Höchstgeschwindigkeit für eine Auflösung (Fallback: kleinster bekannter Wert, sonst 4).
    public func maxSpeed(_ resolution: Resolution) -> Int {
        maxSpeedIPS[String(resolution.dpi)] ?? maxSpeedIPS.values.min() ?? 4
    }

    public var supportsThermalTransfer: Bool { mediaTypes.contains(.thermalTransfer) }
    public func supports(_ feature: PrinterFeature) -> Bool { features.contains(feature) }
    public func supports(_ language: PrinterLanguage) -> Bool { languages.contains(language) }

    /// Anzeigename mit Hersteller, z. B. `Zebra ZD421t`.
    public var displayName: String { "Zebra \(name)" }

    /// Name des SF-Symbols, das die Bauform am besten wiedergibt.
    public var systemImage: String {
        switch category {
        case .desktop, .healthcare: return "printer"
        case .industrial, .printEngine: return "printer.filled.and.paper"
        case .mobile: return "printer.dotmatrix"
        }
    }
}

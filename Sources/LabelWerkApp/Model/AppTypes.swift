import Foundation
import LabelWerkKit

// MARK: - Gespeicherter Drucker

/// Ein vom Benutzer eingerichteter Drucker (persistiert).
struct SavedPrinter: Codable, Identifiable, Hashable {
    var id: UUID
    /// Anzeigename (frei wählbar).
    var name: String
    var descriptor: ConnectionDescriptor
    /// ID im `ModelCatalog` (nil = unbekanntes Modell → generische Werte).
    var modelID: String?
    var resolution: Resolution
    var language: PrinterLanguage
    /// ID des aktuellen Etikettenformats (Katalog oder benutzerdefiniert).
    var stockID: String
    /// Treiber-Standardeinstellungen dieses Druckers.
    var settings: PrintSettings
    /// Name der zugehörigen macOS-Druckerwarteschlange (CUPS), falls eingerichtet.
    var cupsQueueName: String?
    /// Persönliche Akzentfarbe (Farbton 0…1).
    var accentHue: Double
    var isFavorite: Bool
    var addedAt: Date
    /// Notizen / Standort.
    var location: String

    init(
        id: UUID = UUID(),
        name: String,
        descriptor: ConnectionDescriptor,
        modelID: String?,
        resolution: Resolution = .dpi203,
        language: PrinterLanguage = .zpl,
        stockID: String = "w4h6in",
        settings: PrintSettings = .default,
        cupsQueueName: String? = nil,
        accentHue: Double = 0.72,
        isFavorite: Bool = false,
        addedAt: Date = Date(),
        location: String = ""
    ) {
        self.id = id
        self.name = name
        self.descriptor = descriptor
        self.modelID = modelID
        self.resolution = resolution
        self.language = language
        self.stockID = stockID
        self.settings = settings
        self.cupsQueueName = cupsQueueName
        self.accentHue = accentHue
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.location = location
    }
}

// MARK: - Auftragsverlauf

/// Eintrag im Auftragsverlauf.
struct JobRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case zpl, image, testLabel, action, raw, firmware, font, graphic, settings

        var displayName: String {
            switch self {
            case .zpl: return tr("ZPL-Etikett")
            case .image: return tr("Bilddruck")
            case .testLabel: return tr("Testetikett")
            case .action: return tr("Gerätebefehl")
            case .raw: return tr("Rohdaten")
            case .firmware: return tr("Firmware")
            case .font: return tr("Schriftart")
            case .graphic: return tr("Grafik")
            case .settings: return tr("Einstellungen")
            }
        }

        var systemImage: String {
            switch self {
            case .zpl: return "doc.text"
            case .image: return "photo"
            case .testLabel: return "checkmark.seal"
            case .action: return "wand.and.stars"
            case .raw: return "terminal"
            case .firmware: return "cpu"
            case .font: return "textformat"
            case .graphic: return "photo.on.rectangle"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date = Date()
    var printerID: UUID
    var printerName: String
    var title: String
    var kind: Kind
    var labels: Int
    var bytes: Int
    var success: Bool
    var message: String?
    /// Kleine PNG-Vorschau (optional, max. ~40 KB).
    var previewPNG: Data?
    /// Gesendete Druckdaten für „Erneut drucken“ (nur bis 512 KB gespeichert).
    var payload: Data?

    /// Höchstgröße gespeicherter Druckdaten.
    static let maxStoredPayload = 512 * 1024
}

// MARK: - App-Einstellungen

enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return tr("System")
        case .light: return tr("Hell")
        case .dark: return tr("Dunkel")
        }
    }
}

struct AppPreferences: Codable, Equatable {
    /// Abfrageintervall des Live-Status in Sekunden.
    var pollInterval: Double = 3
    var notificationsEnabled: Bool = true
    var showMenuBarExtra: Bool = true
    var playSounds: Bool = true
    /// Zusätzlich zur Systemeinstellung Animationen reduzieren.
    var reduceMotion: Bool = false
    var appearance: AppearancePreference = .system
    /// Beim Start automatisch mit allen Druckern verbinden.
    var autoConnect: Bool = true
    /// Standard-Rasterung für Fotos/Bilder im Designer.
    var imageDither: DitherAlgorithm = .floydSteinberg
    /// Vor zerstörerischen Aktionen (Werkseinstellungen …) nachfragen.
    var confirmDestructiveActions: Bool = true
    /// Zeigt Rohdaten, SGD-Explorer und Hex-Ansichten.
    var developerMode: Bool = false
    /// Demo-Drucker anzeigen, wenn kein echter Drucker eingerichtet ist.
    var showDemoPrinter: Bool = true
}

// MARK: - Persistenter Gesamtzustand

struct PersistedState: Codable {
    var printers: [SavedPrinter] = []
    var customStocks: [LabelStock] = []
    var preferences: AppPreferences = AppPreferences()
    var history: [JobRecord] = []
    var hasCompletedOnboarding: Bool = false
    var designerDocument: String?
    var lastSelectedPrinterID: UUID?
}

// MARK: - Hinweise (Toasts)

struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case info, success, warning, error }
    let id = UUID()
    var style: Style
    var title: String
    var message: String?
    var systemImage: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Verbindungszustand

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }

    var displayName: String {
        switch self {
        case .disconnected: return tr("Getrennt")
        case .connecting: return tr("Verbinde …")
        case .connected: return tr("Verbunden")
        case .failed: return tr("Verbindung fehlgeschlagen")
        }
    }
}

/// Ein Statuswert im zeitlichen Verlauf (für Sparklines & Zeitleisten).
struct StatusSample: Identifiable, Hashable {
    let id = UUID()
    var date: Date
    var state: PrinterState
    var labelsPrinted: Int?
}

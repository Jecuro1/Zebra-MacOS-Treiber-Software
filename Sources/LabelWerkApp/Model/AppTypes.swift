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
    /// Weitere macOS-Warteschlangen desselben Geräts, die LabelWerk automatisch auf den LabelWerk-Treiber
    /// umgestellt hat (z. B. „10.62.13.19“ aus „Drucker & Scanner“, `QueueSyncService`). Sie werden wie
    /// `cupsQueueName` auf dem Stand der Einstellungen gehalten.
    var adoptedQueueNames: [String] = []
    /// Etikettentypen dieses Druckers (Druckeinstellungen › Etikettentypen): je eigenes Format, eigene
    /// Abweichungen und – sobald der Drucker eine macOS-Warteschlange haben kann – ein eigener
    /// macOS-Drucker „<Drucker> – <Typ>“ (`QueueSyncService`, ARCHITECTURE.md §9 „Etikettentypen“).
    var labelTypes: [LabelType] = []

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

        /// Druckaufträge, deren gespeicherte Daten erneut gesendet werden dürfen. Rohdaten und
        /// Gerätebefehle (z. B. ein Neustart) gehören ausdrücklich nicht dazu.
        var isReprintable: Bool { self == .zpl || self == .image }
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
    /// Gesendete Druckdaten für „Erneut drucken“ (nur bis 512 KB gespeichert). Nach dem Laden
    /// `nil`: Die Daten liegen dann in einer eigenen Datei (`payloadFile`).
    var payload: Data?
    /// Name der Datei mit den Druckdaten im Ordner `PersistenceStore.payloadDirectory`.
    var payloadFile: String?

    /// Höchstgröße gespeicherter Druckdaten.
    static let maxStoredPayload = 512 * 1024

    /// „Erneut drucken“ möglich: druckbare Auftragsart mit gespeicherten Druckdaten.
    var isReprintable: Bool { kind.isReprintable && (payload != nil || payloadFile != nil) }
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

/// Standard-Maßeinheit für Längen in den Druckeinstellungen („Einheiten“ im Windows-Treiber).
/// Gespeichert wird immer in Millimetern (Etikettengröße) bzw. Druckpunkten (Versätze).
enum MeasurementUnit: String, Codable, CaseIterable, Identifiable {
    case millimeters
    case inches
    case dots

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .millimeters: return tr("Millimeter")
        case .inches: return tr("Zoll")
        case .dots: return tr("Punkte")
        }
    }

    /// Kurzzeichen hinter Zahlen („mm“, „Zoll“, „Punkte“).
    var symbol: String {
        switch self {
        case .millimeters: return tr("mm")
        case .inches: return tr("Zoll")
        case .dots: return tr("Punkte")
        }
    }

    /// Nachkommastellen der Anzeige: mm eine, Zoll zwei, Punkte keine.
    var fractionDigits: Int {
        switch self {
        case .millimeters: return 1
        case .inches: return 2
        case .dots: return 0
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
    /// Maßeinheit für Längen in den Druckeinstellungen.
    var measurementUnit: MeasurementUnit = .millimeters
    /// Automatisch nach Updates suchen (kurz nach dem Start, danach alle 6 Stunden).
    var autoCheckUpdates: Bool = true
    /// Gefundene Updates sofort im Hintergrund laden – „Jetzt installieren“ beginnt dann ohne Wartezeit.
    var autoDownloadUpdates: Bool = true
    /// Mit „Diese Version überspringen“ ausgeblendetes Update (Release-Tag, z. B. „v1.1.0-b58“).
    var skippedUpdateTag: String? = nil
}

// MARK: - Persistenter Gesamtzustand

struct PersistedState: Codable {
    var printers: [SavedPrinter] = []
    var customStocks: [LabelStock] = []
    var preferences: AppPreferences = AppPreferences()
    var history: [JobRecord] = []
    var hasCompletedOnboarding: Bool = false
    /// Nur noch zum Lesen älterer Dateien – der Designer-Inhalt liegt in einer eigenen Datei.
    var designerDocument: String?
    var lastSelectedPrinterID: UUID?
}

// MARK: - Tolerantes Laden
//
// Die synthetisierte `Decodable`-Implementierung verlangt jeden Schlüssel und jeden bekannten
// Aufzählungswert. Ein neues Feld in einer späteren Version oder ein unbekannter Wert nach einem
// Downgrade machte sonst die ganze `state.json` unlesbar – mit allen Druckern, Formaten und dem
// Verlauf. Darum: fehlende Werte → Standardwert, ungültige Einträge in Listen werden übersprungen.
// Ungültige Werte (nicht bloß fehlende) meldet `PersistenceDecodeReport`, damit die Originaldatei
// vor dem nächsten Speichern gesichert wird.

extension AppPreferences {
    init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder, keyedBy: CodingKeys.self)
        let d = AppPreferences()
        self.init()
        pollInterval = c.value(.pollInterval, default: d.pollInterval)
        notificationsEnabled = c.value(.notificationsEnabled, default: d.notificationsEnabled)
        showMenuBarExtra = c.value(.showMenuBarExtra, default: d.showMenuBarExtra)
        playSounds = c.value(.playSounds, default: d.playSounds)
        reduceMotion = c.value(.reduceMotion, default: d.reduceMotion)
        appearance = c.value(.appearance, default: d.appearance)
        autoConnect = c.value(.autoConnect, default: d.autoConnect)
        imageDither = c.value(.imageDither, default: d.imageDither)
        confirmDestructiveActions = c.value(.confirmDestructiveActions, default: d.confirmDestructiveActions)
        developerMode = c.value(.developerMode, default: d.developerMode)
        showDemoPrinter = c.value(.showDemoPrinter, default: d.showDemoPrinter)
        measurementUnit = c.value(.measurementUnit, default: d.measurementUnit)
        autoCheckUpdates = c.value(.autoCheckUpdates, default: d.autoCheckUpdates)
        autoDownloadUpdates = c.value(.autoDownloadUpdates, default: d.autoDownloadUpdates)
        skippedUpdateTag = c.optional(String.self, .skippedUpdateTag)
    }
}

extension SavedPrinter {
    init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder, keyedBy: CodingKeys.self)
        // Ohne Kennung und Verbindung ist der Eintrag unbrauchbar (wird in der Liste übersprungen).
        self.init(
            id: try c.required(UUID.self, .id),
            name: c.value(.name, default: tr("Drucker")),
            descriptor: try c.required(ConnectionDescriptor.self, .descriptor),
            modelID: c.optional(String.self, .modelID),
            resolution: c.value(.resolution, default: .dpi203),
            language: c.value(.language, default: .zpl),
            stockID: c.value(.stockID, default: "w4h6in"),
            settings: c.value(.settings, default: .default),
            cupsQueueName: c.optional(String.self, .cupsQueueName),
            accentHue: c.value(.accentHue, default: 0.72),
            isFavorite: c.value(.isFavorite, default: false),
            addedAt: c.value(.addedAt, default: Date()),
            location: c.value(.location, default: "")
        )
        adoptedQueueNames = c.value(.adoptedQueueNames, default: [])
        labelTypes = c.array(LabelType.self, .labelTypes)
    }
}

extension JobRecord {
    init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder, keyedBy: CodingKeys.self)
        self.init(
            id: c.value(.id, default: UUID()),
            date: c.value(.date, default: Date.distantPast),
            printerID: try c.required(UUID.self, .printerID),
            printerName: c.value(.printerName, default: ""),
            title: c.value(.title, default: ""),
            kind: try c.required(Kind.self, .kind),
            labels: c.value(.labels, default: 0),
            bytes: c.value(.bytes, default: 0),
            success: c.value(.success, default: true),
            message: c.optional(String.self, .message),
            previewPNG: c.optional(Data.self, .previewPNG),
            payload: c.optional(Data.self, .payload),
            payloadFile: c.optional(String.self, .payloadFile)
        )
    }
}

extension PersistedState {
    init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder, keyedBy: CodingKeys.self)
        self.init()
        printers = c.array(SavedPrinter.self, .printers)
        customStocks = c.array(LabelStock.self, .customStocks)
        preferences = c.value(.preferences, default: AppPreferences())
        history = c.array(JobRecord.self, .history)
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, default: false)
        designerDocument = c.optional(String.self, .designerDocument)
        lastSelectedPrinterID = c.optional(UUID.self, .lastSelectedPrinterID)
    }
}

/// Sammelt beim Laden Werte, die ungültig waren und deshalb verworfen wurden (nur während eines
/// einzelnen, synchronen Dekodiervorgangs benutzt).
final class PersistenceDecodeReport: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "LabelWerk.PersistenceDecodeReport")!

    private(set) var problems: [String] = []

    func note(_ path: [CodingKey], _ error: Error) {
        problems.append(path.map(\.stringValue).joined(separator: ".") + ": \(error)")
    }
}

/// Liest Werte nachsichtig: Fehlt ein Schlüssel oder ist der Wert ungültig, gilt der Standardwert.
struct LenientContainer<Key: CodingKey> {
    private let container: KeyedDecodingContainer<Key>
    private let report: PersistenceDecodeReport?

    init(_ decoder: Decoder, keyedBy type: Key.Type) throws {
        container = try decoder.container(keyedBy: type)
        report = decoder.userInfo[PersistenceDecodeReport.key] as? PersistenceDecodeReport
    }

    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        optional(T.self, key) ?? fallback()
    }

    func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        do {
            return try container.decodeIfPresent(type, forKey: key)
        } catch {
            report?.note(container.codingPath + [key], error)
            return nil
        }
    }

    func required<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
        try container.decode(type, forKey: key)
    }

    /// Liest eine Liste und überspringt ungültige Einträge.
    func array<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let elements = optional([LossyElement<T>].self, key) else { return [] }
        for element in elements {
            if let error = element.error { report?.note(container.codingPath + [key], error) }
        }
        return elements.compactMap(\.value)
    }
}

/// Listeneintrag, dessen Dekodierfehler abgefangen wird (der Listenzeiger rückt trotzdem vor).
private struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    let error: Error?

    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
            error = nil
        } catch {
            value = nil
            self.error = error
        }
    }
}

// MARK: - Hinweise (Toasts)

/// Schaltfläche in einem Hinweis, z. B. „Erneut versuchen“ (die Übersicht `ToastOverlay` zeigt sie
/// als Knopf; ein Klick führt `perform` aus und schließt den Hinweis).
struct ToastAction {
    var title: String
    var perform: @MainActor () -> Void
}

struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case info, success, warning, error }
    let id = UUID()
    var style: Style
    var title: String
    var message: String?
    /// Optionale Aktion (`nil` = nur Text).
    var action: ToastAction?

    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id && lhs.style == rhs.style && lhs.title == rhs.title && lhs.message == rhs.message
            && lhs.action?.title == rhs.action?.title
    }
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

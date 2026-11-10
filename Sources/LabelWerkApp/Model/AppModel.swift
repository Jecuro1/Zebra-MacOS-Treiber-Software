import AppKit
import Foundation
import Observation
import SwiftUI
import LabelWerkKit

/// Globaler Zustand der App (eine Instanz, per `.environment(model)` verteilt).
@Observable
@MainActor
final class AppModel {
    // MARK: Daten

    let catalog = ModelCatalog.shared
    private(set) var sessions: [PrinterSession] = []
    var selection: SidebarItem?
    var customStocks: [LabelStock] = [] {
        didSet {
            scheduleSave()
            // Geänderte Maße eines eigenen Formats erreichen die macOS-Warteschlangen automatisch.
            if !isRestoring, customStocks != oldValue { queueSync?.noteStocksChanged() }
        }
    }
    private(set) var history: [JobRecord] = []
    var preferences = AppPreferences() {
        didSet {
            guard preferences != oldValue else { return }
            scheduleSave()
            if preferences.pollInterval != oldValue.pollInterval {
                sessions.forEach { $0.restartMonitoringIfNeeded() }
            }
        }
    }
    var hasCompletedOnboarding = false { didSet { scheduleSave() } }
    /// Aktueller Inhalt des Designers (ZPL), bleibt zwischen Starts erhalten (eigene Datei).
    var designerDocument: String = "" { didSet { scheduleDesignerSave() } }

    // MARK: UI-Zustand

    var toasts: [Toast] = []
    var isOnboardingPresented = false
    var isAddPrinterPresented = false
    /// Installationsassistent „Drucker installieren“ (macOS-Drucker mit LabelWerk-Treiber einrichten).
    var isInstallWizardPresented = false
    /// Vom Installationspaket angefordert (`--setup`), während noch der Willkommensassistent läuft:
    /// Der Installationsassistent folgt nach dessen Ende.
    var pendingInstallWizard = false
    /// Gesetzt, wenn ein Bereich programmgesteuert angesprungen werden soll (z. B. aus der Menüleiste).
    var pendingSection: PrinterSection?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var designerSaveTask: Task<Void, Never>?
    @ObservationIgnored private let writer = PersistenceWriter()
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var hasStarted = false
    /// Hält die macOS-Warteschlangen der Drucker auf dem Stand der gespeicherten Einstellungen
    /// (Etikettengröße, Treiberoptionen) – nach Änderungen und einmal nach dem Start.
    @ObservationIgnored private(set) var queueSync: QueueSyncService!

    // MARK: Init

    init() {
        VirtualPrinter.registerWithConnectionFactory()
        restore()
        queueSync = QueueSyncService(model: self)
    }

    private func restore() {
        isRestoring = true
        defer { isRestoring = false }
        let state = PersistenceStore.load()
        preferences = state.preferences
        customStocks = state.customStocks
        history = state.history
        hasCompletedOnboarding = state.hasCompletedOnboarding
        designerDocument = state.designerDocument ?? ""
        // Ältere Zustände enthielten den Designer-Inhalt in `state.json`: in die eigene Datei
        // übernehmen, bevor das nächste Speichern ihn dort weglässt (die Warteschlange ist seriell).
        if !designerDocument.isEmpty, !FileManager.default.fileExists(atPath: PersistenceStore.designerURL.path) {
            writer.saveDesigner(designerDocument)
        }
        sessions = state.printers.map { PrinterSession(saved: $0, app: self) }
        if let last = state.lastSelectedPrinterID, sessions.contains(where: { $0.id == last }) {
            selection = .printer(last)
        } else if let first = sessions.first {
            selection = .printer(first.id)
        } else {
            selection = .discover
        }
        isOnboardingPresented = !hasCompletedOnboarding
    }

    /// Wird von der App nach dem Start aufgerufen (Verbindungen aufbauen, Überwachung starten).
    /// Nur der erste Aufruf wirkt – ein neu geöffnetes Hauptfenster verbindet bewusst getrennte
    /// Drucker nicht erneut.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        // Warteschlangen älterer Versionen (ohne benannte Etikettengröße, lwLabelWidth …) einmalig
        // abgleichen – still, ohne Passwortabfrage, nur bei Abweichungen.
        queueSync.syncAtLaunch()
        guard preferences.autoConnect else { return }
        for session in sessions {
            Task { await session.connect() }
        }
    }

    // MARK: Persistenz

    /// Speichert verzögert (Änderungen werden zusammengefasst). Kodiert und geschrieben wird im
    /// Hintergrund – hier wird nur der aktuelle Stand übernommen.
    func scheduleSave() {
        guard !isRestoring else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.writer.save(self.persistedState())
        }
    }

    private func scheduleDesignerSave() {
        guard !isRestoring else { return }
        designerSaveTask?.cancel()
        designerSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.writer.saveDesigner(self.designerDocument)
        }
    }

    /// Speichert sofort und wartet, bis alles geschrieben ist (beim Beenden).
    func saveNow() {
        saveTask?.cancel()
        designerSaveTask?.cancel()
        writer.save(persistedState())
        writer.saveDesigner(designerDocument)
        writer.waitUntilIdle()
    }

    private func persistedState() -> PersistedState {
        var lastSelected: UUID?
        if case .printer(let id) = selection { lastSelected = id }
        return PersistedState(
            printers: sessions.map(\.saved),
            customStocks: customStocks,
            preferences: preferences,
            history: Array(history.prefix(500)),
            hasCompletedOnboarding: hasCompletedOnboarding,
            designerDocument: nil,
            lastSelectedPrinterID: lastSelected
        )
    }

    // MARK: Drucker verwalten

    var selectedSession: PrinterSession? {
        guard case .printer(let id) = selection else { return nil }
        return session(for: id)
    }

    func session(for id: UUID) -> PrinterSession? {
        sessions.first { $0.id == id }
    }

    /// Fügt einen gefundenen Drucker hinzu (oder liefert die bestehende Sitzung mit gleicher Verbindung).
    @discardableResult
    func addPrinter(from discovered: DiscoveredPrinter) -> PrinterSession {
        if let existing = sessions.first(where: { $0.saved.descriptor.refersToSameDevice(as: discovered.descriptor) }) {
            return existing
        }
        let model = discovered.modelHint.flatMap { catalog.match(productName: $0) }
        let resolution = Self.resolution(fromHint: discovered.modelHint) ?? model?.supportedResolutions.first ?? .dpi203
        let saved = SavedPrinter(
            name: discovered.name,
            descriptor: discovered.descriptor,
            modelID: model?.id,
            resolution: resolution,
            language: model?.defaultLanguage ?? .zpl,
            stockID: model?.defaultStock ?? "w4h6in",
            accentHue: Self.nextAccentHue(after: sessions.count)
        )
        return addPrinter(saved)
    }

    @discardableResult
    func addPrinter(_ saved: SavedPrinter, connect: Bool = true) -> PrinterSession {
        let session = PrinterSession(saved: saved, app: self)
        animate(.spring(response: 0.45, dampingFraction: 0.82)) {
            sessions.append(session)
            selection = .printer(session.id)
        }
        scheduleSave()
        if connect {
            Task { await session.connect() }
        }
        return session
    }

    /// Legt den virtuellen Demo-Drucker an (simuliert einen ZD421t vollständig).
    @discardableResult
    func addDemoPrinter() -> PrinterSession {
        if let existing = sessions.first(where: { $0.saved.descriptor.kind == .virtual }) {
            selection = .printer(existing.id)
            return existing
        }
        let saved = SavedPrinter(
            name: tr("Demo-Drucker"),
            descriptor: .virtual(id: "demo"),
            modelID: "zd421t",
            resolution: .dpi203,
            language: .zpl,
            stockID: "w4h6in",
            accentHue: 0.78,
            location: tr("Virtuell")
        )
        return addPrinter(saved)
    }

    func removePrinter(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        session.stopMonitoring()
        Task { await session.disconnect() }
        animate(.spring(response: 0.4, dampingFraction: 0.85)) {
            sessions.remove(at: index)
            if selection == .printer(id) {
                selection = sessions.first.map { .printer($0.id) } ?? .discover
            }
        }
        scheduleSave()
    }

    func movePrinters(fromOffsets source: IndexSet, toOffset destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    /// Wird von `PrinterSession` aufgerufen, wenn sich gespeicherte Daten geändert haben. Betrifft die
    /// Änderung die macOS-Warteschlange (Format, Einstellungen, Sprache, Warteschlange), gleicht
    /// `queueSync` sie verzögert ab – egal, welcher Bereich der App sie vorgenommen hat.
    func printerDidChange(_ session: PrinterSession) {
        scheduleSave()
        queueSync?.noteChange(session)
    }

    // MARK: Etiketten

    /// Alle Etikettenformate: eigene zuerst, dann Katalog.
    var allStocks: [LabelStock] { customStocks + catalog.stocks }

    func stock(id: String) -> LabelStock? {
        customStocks.first { $0.id == id } ?? catalog.stock(id: id)
    }

    func addCustomStock(_ stock: LabelStock) {
        var s = stock
        s.isCustom = true
        s.category = .custom
        if let index = customStocks.firstIndex(where: { $0.id == s.id }) {
            customStocks[index] = s
        } else {
            customStocks.append(s)
        }
    }

    func removeCustomStock(id: String) {
        customStocks.removeAll { $0.id == id }
    }

    // MARK: Verlauf

    func record(_ job: JobRecord) {
        animate(.snappy) {
            history.insert(job, at: 0)
            if history.count > 500 { history.removeLast(history.count - 500) }
        }
        scheduleSave()
    }

    func clearHistory(printerID: UUID? = nil) {
        animate(.snappy) {
            if let printerID {
                history.removeAll { $0.printerID == printerID }
            } else {
                history.removeAll()
            }
        }
        scheduleSave()
    }

    // MARK: Hinweise

    func toast(_ title: String, message: String? = nil, style: Toast.Style = .info, action: ToastAction? = nil) {
        let toast = Toast(style: style, title: title, message: message, action: action)
        animate(.spring(response: 0.4, dampingFraction: 0.8)) {
            toasts.append(toast)
            if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        }
        // Hinweise mit Aktion bleiben länger stehen, damit sie erreichbar sind.
        let duration: Double = action != nil ? 15 : (style == .error ? 7 : 4)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.dismissToast(toast.id)
        }
    }

    func dismissToast(_ id: UUID) {
        animate(.spring(response: 0.35, dampingFraction: 0.9)) {
            toasts.removeAll { $0.id == id }
        }
    }

    // MARK: Gesamtstatus (Menüleiste)

    /// Schlechtester Zustand aller Drucker – steuert das Menüleistensymbol. Berücksichtigt auch
    /// Drucker ohne Status (nicht erreichbar, verbindet gerade, reine Druckwarteschlange).
    var aggregateState: PrinterState {
        let states = sessions.map(\.state)
        if states.contains(.error) { return .error }
        if states.contains(.warning) { return .warning }
        if states.contains(.paused) { return .paused }
        if states.contains(.printing) { return .printing }
        if states.contains(.ready) { return .ready }
        if states.contains(.unknown) { return .unknown }
        return sessions.isEmpty ? .unknown : .offline
    }

    /// Anzahl der Meldungen (Warnungen und Fehler); ein nicht erreichbarer Drucker zählt mindestens als eine.
    var activeAlertCount: Int {
        sessions.reduce(0) { count, session in
            let alerts = session.alerts.filter { $0.severity >= .warning }.count
            if case .failed = session.connectionState { return count + max(1, alerts) }
            return count + alerts
        }
    }

    // MARK: Bewegung

    /// „Bewegung reduzieren“ aus Systemeinstellung oder App-Einstellung.
    var reducesMotion: Bool {
        preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Animiert eine vom Modell ausgelöste Änderung – ohne Animation bei reduzierter Bewegung.
    func animate(_ animation: Animation, _ changes: () -> Void) {
        withAnimation(Motion.animation(animation, reduceMotion: reducesMotion), changes)
    }

    // MARK: Hilfen

    /// Liest die Auflösung aus Hinweisen wie „ZD421-300dpi“.
    static func resolution(fromHint hint: String?) -> Resolution? {
        guard let hint = hint?.lowercased() else { return nil }
        for r in Resolution.allCases.reversed() where hint.contains("\(r.dpi)dpi") || hint.contains("\(r.dpi) dpi") {
            return r
        }
        return nil
    }

    static func nextAccentHue(after count: Int) -> Double {
        let hues: [Double] = [0.72, 0.55, 0.92, 0.08, 0.36, 0.62, 0.82, 0.14]
        return hues[count % hues.count]
    }
}

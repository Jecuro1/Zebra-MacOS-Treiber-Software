import Foundation
import Observation
import SwiftUI
import LabelWerkKit

/// Laufzeitzustand eines eingerichteten Druckers: Verbindung, Live-Status, Identität und alle
/// Geräteoperationen. Views rufen ausschließlich diese Methoden auf – Fehler werden hier
/// abgefangen, als Hinweis angezeigt und im Verlauf protokolliert.
@Observable
@MainActor
final class PrinterSession: Identifiable {
    let id: UUID

    /// Persistente Konfiguration. Änderungen werden automatisch gespeichert; Änderungen an
    /// Verbindung oder Sprache bauen die Verbindung neu auf.
    var saved: SavedPrinter {
        didSet {
            guard saved != oldValue else { return }
            app?.printerDidChange(self)
            if saved.descriptor != oldValue.descriptor || saved.language != oldValue.language {
                Task { await reconnect() }
            }
        }
    }

    /// Aktuell angezeigter Bereich in der Detailansicht.
    var section: PrinterSection = .overview

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var status: PrinterStatusSnapshot?
    private(set) var identity: PrinterIdentity?
    private(set) var statusHistory: [StatusSample] = []
    /// Beschreibung der laufenden Operation (z. B. „Firmware wird übertragen …“).
    private(set) var activity: String?
    /// Fortschritt der laufenden Operation 0…1 (nil = unbestimmt).
    private(set) var progress: Double?
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    /// In dieser Sitzung gedruckte Etiketten.
    private(set) var labelsPrintedThisSession = 0

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var client: PrinterClient?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var alertsMutedUntil: Date?
    @ObservationIgnored private var previousAlertKinds: Set<AlertKind> = []
    @ObservationIgnored private var consecutiveFailures = 0
    /// Automatische Wiederverbindungsversuche seit der letzten erfolgreichen Verbindung.
    @ObservationIgnored private var reconnectAttempts = 0
    /// Laufender Verbindungsaufbau; weitere `connect()`-Aufrufe warten auf ihn statt einen zweiten zu starten.
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// Zählt Verbindungsaufbauten und Trennungen. Ein Aufbau, der beim Abschluss nicht mehr der
    /// aktuelle ist (inzwischen getrennt oder mit neuer Adresse/Sprache neu verbunden), wird verworfen.
    @ObservationIgnored private var connectGeneration = 0

    init(saved: SavedPrinter, app: AppModel) {
        self.id = saved.id
        self.saved = saved
        self.app = app
    }

    // MARK: - Abgeleitete Werte

    var displayName: String { saved.name }
    var model: PrinterModel? { saved.modelID.flatMap { ModelCatalog.shared.model(id: $0) } }
    var resolution: Resolution { saved.resolution }
    var isVirtual: Bool { saved.descriptor.kind == .virtual }
    var supportsStatus: Bool { saved.descriptor.supportsBidirectional }
    var accentColor: Color { Color(hue: saved.accentHue, saturation: 0.72, brightness: 0.95) }

    var stock: LabelStock {
        app?.stock(id: saved.stockID)
            ?? ModelCatalog.shared.stock(id: saved.stockID)
            ?? LabelStock(id: "w4h6in", name: "4 × 6 Zoll", widthMM: 101.6, heightMM: 152.4,
                          category: .shipping, isCustom: false)
    }

    /// Druckbreite in Punkten (Etikett, begrenzt auf die Kopfbreite).
    var labelWidthDots: Int {
        let width = stock.widthDots(resolution)
        guard let model else { return width }
        return min(width, model.printWidthDots(resolution))
    }

    var labelHeightDots: Int { stock.heightDots(resolution) }

    /// Zusammengefasster Zustand für Anzeige & Farben.
    var state: PrinterState {
        switch connectionState {
        case .connected: return supportsStatus ? (status?.state ?? .unknown) : .ready
        case .connecting: return .unknown
        case .disconnected, .failed: return .offline
        }
    }

    var alerts: [PrinterAlert] { status?.alerts ?? [] }
    var isBusy: Bool { activity != nil }
    /// Der Drucker ist pausiert – auch wenn ein Fehler (z. B. Druckkopf offen) als Zustand Vorrang hat.
    var isPaused: Bool { status?.hasAlert(.paused) == true || status?.hostStatus?.paused == true }

    var availableSections: [PrinterSection] {
        PrinterSection.available(for: model, descriptor: saved.descriptor,
                                 developerMode: app?.preferences.developerMode ?? false)
    }

    /// Zugriff auf den simulierten Drucker (nur Demo-Verbindung), z. B. um Fehler zu simulieren.
    /// Auch ohne aktive Verbindung verfügbar: Je Kennung gibt es prozessweit genau einen.
    var virtualPrinter: VirtualPrinter? {
        if case .virtual(let id) = saved.descriptor { return VirtualPrinter.shared(id: id) }
        return nil
    }

    // MARK: - Verbindung

    func connect() async {
        if connectionState == .connected { return }
        // Läuft bereits ein Verbindungsaufbau, auf dessen Ergebnis warten.
        if let pending = connectTask {
            await pending.value
            return
        }
        connectGeneration &+= 1
        let generation = connectGeneration
        animate(.smooth) { connectionState = .connecting }
        let attempt = Task<Void, Never> { [weak self] in
            await self?.establishConnection(generation: generation)
        }
        connectTask = attempt
        await attempt.value
        if connectGeneration == generation { connectTask = nil }
    }

    private func establishConnection(generation: Int) async {
        // Nach wiederholten Statusfehlern ist die alte Verbindung noch offen: zuerst schließen
        // (USB-Geräte erlauben oft nur einen Zugriff).
        if let stale = client {
            client = nil
            await stale.disconnect()
            guard generation == connectGeneration else { return }
        }
        do {
            let connection = try ConnectionFactory.make(saved.descriptor)
            let client = PrinterClient(connection: connection, language: saved.language)
            try await client.connect()
            // Inzwischen getrennt oder neu verbunden: Diese Verbindung wird nicht mehr gebraucht.
            guard generation == connectGeneration else {
                await client.disconnect()
                return
            }
            self.client = client
            consecutiveFailures = 0
            reconnectAttempts = 0
            animate(.spring(response: 0.5, dampingFraction: 0.8)) { connectionState = .connected }
            lastError = nil
            await refreshIdentity()
            await refreshStatus()
            guard generation == connectGeneration else { return }
            startMonitoring()
        } catch {
            guard generation == connectGeneration else { return }
            client = nil
            let message = Self.describe(error)
            animate(.smooth) { connectionState = .failed(message) }
            lastError = message
            // Die Überwachung verbindet im Hintergrund erneut – auch wenn der Drucker beim Start
            // noch ausgeschaltet oder nicht erreichbar war.
            if monitorTask == nil { startMonitoring() }
        }
    }

    func disconnect() async {
        // Laufende Verbindungsaufbauten verwerfen: Ihr Ergebnis darf diese Trennung nicht überschreiben.
        connectGeneration &+= 1
        connectTask = nil
        stopMonitoring()
        reconnectAttempts = 0
        let previous = client
        client = nil
        animate(.smooth) {
            connectionState = .disconnected
            status = nil
        }
        await previous?.disconnect()
    }

    func reconnect() async {
        await disconnect()
        await connect()
    }

    // MARK: - Überwachung

    func startMonitoring() {
        monitorTask?.cancel()
        guard supportsStatus else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.app?.preferences.pollInterval ?? 3
                try? await Task.sleep(for: .seconds(max(1, interval)))
                guard !Task.isCancelled, let self else { return }
                if self.connectionState == .connected {
                    await self.refreshStatus()
                } else if case .failed = self.connectionState {
                    // Automatischer Wiederverbindungsversuch mit wachsendem Abstand: nach 5, 10, 20 …
                    // Abfragen, höchstens etwa einmal pro Minute.
                    self.consecutiveFailures += 1
                    let limit = max(5, Int(60 / max(1, interval)))
                    if self.consecutiveFailures >= min(5 << min(self.reconnectAttempts, 4), limit) {
                        self.consecutiveFailures = 0
                        self.reconnectAttempts += 1
                        await self.connect()
                    }
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func restartMonitoringIfNeeded() {
        guard monitorTask != nil else { return }
        startMonitoring()
    }

    /// Status und Identität neu laden.
    func refresh() async {
        if connectionState != .connected { await connect(); return }
        await refreshIdentity()
        await refreshStatus()
    }

    func refreshStatus() async {
        guard let client, supportsStatus else { return }
        do {
            let snapshot = try await client.status()
            // Inzwischen getrennt oder neu verbunden: veraltete Antwort verwerfen.
            guard client === self.client else { return }
            consecutiveFailures = 0
            apply(snapshot)
        } catch {
            guard client === self.client else { return }
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                let message = Self.describe(error)
                animate(.smooth) {
                    connectionState = .failed(message)
                    status = .offline
                }
                lastError = message
                notifyIfNeeded(newAlerts: [PrinterAlert.make(.offline)])
            }
        }
    }

    func refreshIdentity() async {
        guard let client, supportsStatus else { return }
        if let identity = try? await client.identify(), client === self.client {
            animate(.smooth) { self.identity = identity }
            // Modell & Auflösung automatisch übernehmen, falls noch unbekannt.
            if saved.modelID == nil, let matched = identity.matchedModelID {
                saved.modelID = matched
            }
            if let res = identity.resolution, res != saved.resolution,
               model?.supportedResolutions.contains(res) ?? true {
                saved.resolution = res
            }
        }
    }

    private func apply(_ snapshot: PrinterStatusSnapshot) {
        let newKinds = Set(snapshot.alerts.map(\.kind))
        let appeared = snapshot.alerts.filter { !previousAlertKinds.contains($0.kind) }
        previousAlertKinds = newKinds
        animate(.spring(response: 0.45, dampingFraction: 0.85)) {
            status = snapshot
            lastUpdated = snapshot.timestamp
            statusHistory.append(StatusSample(date: snapshot.timestamp, state: snapshot.state,
                                              labelsPrinted: snapshot.labelsPrinted))
            if statusHistory.count > 240 { statusHistory.removeFirst(statusHistory.count - 240) }
        }
        notifyIfNeeded(newAlerts: appeared)
    }

    /// Unterdrückt Hinweise, Mitteilungen und Töne für neu auftretende Meldungen für `seconds`
    /// Sekunden – z. B. während einer Kalibrierung, bei der der Drucker kurzzeitig „Etiketten leer“
    /// melden kann. Die Meldungen bleiben in der Übersicht sichtbar.
    func muteAlertNotifications(for seconds: TimeInterval) {
        alertsMutedUntil = Date().addingTimeInterval(max(0, seconds))
    }

    func unmuteAlertNotifications() {
        alertsMutedUntil = nil
    }

    private func notifyIfNeeded(newAlerts: [PrinterAlert]) {
        if let until = alertsMutedUntil {
            if Date() < until { return }
            alertsMutedUntil = nil
        }
        let relevant = newAlerts.filter { $0.severity >= .warning }
        guard !relevant.isEmpty, let app else { return }
        for alert in relevant {
            app.toast(tr("%@: %@", displayName, tr(alert.title)), message: tr(alert.recovery),
                      style: alert.severity == .error ? .error : .warning)
            if app.preferences.notificationsEnabled {
                NotificationService.shared.notify(printerName: displayName, alert: alert, printerID: id)
            }
        }
        if app.preferences.playSounds, relevant.contains(where: { $0.severity == .error }) {
            SoundService.play(.alert)
        }
    }

    // MARK: - Operationen

    /// Führt eine Operation mit Fehlerbehandlung, Aktivitätsanzeige und optionalem Verlaufseintrag aus.
    private func run<T>(
        _ activityText: String,
        quiet: Bool = false,
        _ operation: (PrinterClient) async throws -> T
    ) async -> T? {
        if connectionState != .connected { await connect() }
        guard let client else {
            if !quiet {
                app?.toast(tr("Drucker nicht verbunden"), message: lastError, style: .error)
            }
            return nil
        }
        animate(.smooth) { activity = activityText }
        defer {
            animate(.smooth) {
                activity = nil
                progress = nil
            }
        }
        do {
            let result = try await operation(client)
            lastError = nil
            return result
        } catch is CancellationError {
            return nil
        } catch {
            let message = Self.describe(error)
            lastError = message
            if !quiet {
                app?.toast(tr("Fehler bei „%@“", activityText), message: message, style: .error)
            }
            return nil
        }
    }

    /// Wie `run`, für Erweiterungen in anderen Dateien (z. B. `PrinterSession+Preferences.swift`).
    func withClient<T>(
        _ activityText: String,
        quiet: Bool = false,
        _ operation: (PrinterClient) async throws -> T
    ) async -> T? {
        await run(activityText, quiet: quiet, operation)
    }

    private func recordJob(_ kind: JobRecord.Kind, title: String, labels: Int, bytes: Int,
                           success: Bool, message: String? = nil, preview: Data? = nil, payload: Data? = nil) {
        let stored = payload.flatMap { $0.count <= JobRecord.maxStoredPayload ? $0 : nil }
        app?.record(JobRecord(printerID: id, printerName: displayName, title: title, kind: kind,
                              labels: labels, bytes: bytes, success: success, message: message,
                              previewPNG: preview, payload: stored))
        if success && labels > 0 {
            labelsPrintedThisSession += labels
            if app?.preferences.playSounds == true { SoundService.play(.printed) }
        }
    }

    @discardableResult
    func perform(_ action: PrinterAction) async -> Bool {
        let title = tr(action.displayName)
        let ok = await run(title) { client in
            try await client.perform(action, resolution: resolution,
                                     widthDots: labelWidthDots, heightDots: labelHeightDots)
        } != nil
        recordJob(action == .printTestLabel ? .testLabel : .action, title: title,
                  labels: action == .printTestLabel ? 1 : 0, bytes: 0, success: ok,
                  message: ok ? nil : lastError)
        if ok {
            app?.toast(title, message: tr("Befehl wurde gesendet."), style: .success)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                await self?.refreshStatus()
            }
        }
        return ok
    }

    @discardableResult
    func printTestLabel() async -> Bool { await perform(.printTestLabel) }

    @discardableResult
    func printZPL(_ zpl: String, title: String, copies: Int = 1) async -> Bool {
        var payload = zpl
        if copies > 1 {
            // ^PQ in jedes Format einfügen, sofern nicht vorhanden.
            payload = Self.applyingQuantity(copies, to: zpl)
        }
        let data = Data(payload.utf8)
        let labelCount = max(1, payload.components(separatedBy: "^XZ").count - 1) * max(1, copies)
        let ok = await run(tr("Etikett wird gedruckt …")) { client in
            try await client.send(data)
        } != nil
        let preview = ok ? await Self.previewPNG(zpl: zpl, dotsPerMM: resolution.dotsPerMM) : nil
        recordJob(.zpl, title: title, labels: labelCount, bytes: data.count, success: ok,
                  message: ok ? nil : lastError, preview: preview, payload: data)
        if ok { app?.toast(tr("Gedruckt"), message: title, style: .success) }
        return ok
    }

    /// Druckt Bilder (bereits auf Etikettengröße gebracht) mit den Treibereinstellungen.
    @discardableResult
    func printImages(_ images: [GrayImage], title: String, copies: Int = 1,
                     settings: PrintSettings? = nil) async -> Bool {
        guard !images.isEmpty else { return false }
        let effective = settings ?? saved.settings
        let encoder = JobEncoder(language: saved.language, resolution: resolution, settings: effective,
                                 stock: stock, maxPrintWidthDots: model?.printWidthDots(resolution))
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try encoder.encode(images: images, copies: copies, collate: true)
            }.value
        } catch {
            app?.toast(tr("Druckauftrag konnte nicht erzeugt werden"), message: Self.describe(error), style: .error)
            return false
        }
        // „Aufträge vor dem Drucken abbrechen“: ~JA allein senden, die eingestellte Verzögerung
        // warten, dann den Rest – wie der CUPS-Filter (ARCHITECTURE.md §8).
        let cancelPrefix = encoder.cancelPrefixLength()
        let delay = effective.clamped().cancelDelayMs
        let ok = await run(tr("Bild wird gedruckt …")) { client in
            try await client.sendJob(data, cancelPrefixLength: cancelPrefix, delayMilliseconds: delay)
        } != nil
        let preview = ok ? await Self.previewPNG(image: images[0]) : nil
        recordJob(.image, title: title, labels: images.count * max(1, copies), bytes: data.count,
                  success: ok, message: ok ? nil : lastError, preview: preview, payload: data)
        if ok { app?.toast(tr("Gedruckt"), message: title, style: .success) }
        return ok
    }

    /// Sendet Rohdaten (z. B. Gerätebefehle). Die Daten werden nur mit `storePayload` für
    /// „Erneut drucken“ gespeichert – Befehle wie ein Neustart dürfen nicht erneut auslösbar sein.
    @discardableResult
    func sendRaw(_ text: String, title: String = tr("Rohdaten"), storePayload: Bool = false) async -> Bool {
        let data = Data(text.utf8)
        let ok = await run(tr("Daten werden gesendet …")) { client in try await client.send(data) } != nil
        recordJob(.raw, title: title, labels: 0, bytes: data.count, success: ok, message: ok ? nil : lastError,
                  payload: storePayload ? data : nil)
        return ok
    }

    /// Sendet gespeicherte Druckdaten aus dem Verlauf erneut.
    @discardableResult
    func reprint(_ job: JobRecord) async -> Bool {
        // Nach einem Neustart liegen die Druckdaten in einer eigenen Datei (siehe `PersistenceStore`).
        if let payload = PersistenceStore.payload(for: job), Self.containsRFIDWrite(payload) {
            // RFID-Kodieraufträge nie erneut senden: Das würde dieselbe EPC ein zweites Mal schreiben.
            app?.toast(tr("Erneut drucken nicht möglich"),
                       message: tr("RFID-Kodieraufträge werden nicht wiederholt – jede EPC darf nur einmal geschrieben werden."),
                       style: .warning)
            return false
        }
        guard job.isReprintable, let payload = PersistenceStore.payload(for: job) else {
            app?.toast(tr("Erneut drucken nicht möglich"), message: tr("Für diesen Auftrag wurden keine Druckdaten gespeichert."), style: .warning)
            return false
        }
        // Bildaufträge mit „Aufträge vor dem Drucken abbrechen“ beginnen mit der ~JA-Zeile: wie beim
        // ersten Druck nach ihr warten (Verzögerung aus den aktuellen Treibereinstellungen).
        let cancelPrefix = job.kind == .image ? PrinterClient.cancelPrefixLength(of: payload) : nil
        let delay = saved.settings.clamped().cancelDelayMs
        let ok = await run(tr("Auftrag wird erneut gesendet …")) { client in
            try await client.sendJob(payload, cancelPrefixLength: cancelPrefix, delayMilliseconds: delay)
        } != nil
        recordJob(job.kind, title: job.title, labels: job.labels, bytes: payload.count, success: ok,
                  message: ok ? nil : lastError, preview: job.previewPNG, payload: payload)
        if ok { app?.toast(tr("Erneut gedruckt"), message: job.title, style: .success) }
        return ok
    }

    @discardableResult
    func sendData(_ data: Data, title: String, kind: JobRecord.Kind = .raw) async -> Bool {
        let ok = await run(tr("Daten werden gesendet …")) { client in try await client.send(data) } != nil
        recordJob(kind, title: title, labels: 0, bytes: data.count, success: ok, message: ok ? nil : lastError)
        return ok
    }

    /// Sendet Terminal-Eingaben und liefert die Antwort des Druckers als Text (nil bei Fehler).
    func terminal(_ input: String, timeout: Duration = .seconds(2)) async -> Data? {
        await run(tr("Terminal"), quiet: true) { client in
            try await client.terminal(input, timeout: timeout)
        }
    }

    @discardableResult
    func applySettings(_ settings: PrintSettings, permanently: Bool) async -> Bool {
        let ok = await run(tr("Einstellungen werden übertragen …")) { client in
            try await client.applySettings(settings, permanently: permanently)
        } != nil
        recordJob(.settings, title: permanently ? tr("Einstellungen dauerhaft gespeichert") : tr("Einstellungen übertragen"),
                  labels: 0, bytes: 0, success: ok, message: ok ? nil : lastError)
        if ok {
            app?.toast(tr("Einstellungen übertragen"),
                       message: permanently ? tr("Dauerhaft im Drucker gespeichert.") : nil, style: .success)
        }
        return ok
    }

    func allSettings() async -> [String: SGDSetting] {
        await run(tr("Druckereinstellungen werden gelesen …")) { client in try await client.allSettings() } ?? [:]
    }

    func getvar(_ name: String) async -> String? {
        await run(tr("Wert wird gelesen …"), quiet: true) { client in try await client.getvar(name) } ?? nil
    }

    func getvars(_ names: [String]) async -> [String: String] {
        await run(tr("Werte werden gelesen …"), quiet: true) { client in try await client.getvars(names) } ?? [:]
    }

    @discardableResult
    func setvar(_ name: String, _ value: String) async -> Bool {
        await run(tr("Wert wird gesetzt …")) { client in try await client.setvar(name, value) } != nil
    }

    func configuration() async -> [ConfigurationEntry] {
        await run(tr("Konfiguration wird gelesen …")) { client in try await client.configuration() } ?? []
    }

    func listFiles(drive: String = "E:") async -> [PrinterFile] {
        await run(tr("Dateien werden gelesen …"), quiet: true) { client in try await client.listFiles(drive: drive) } ?? []
    }

    @discardableResult
    func uploadFont(name: String, data: Data, drive: String = "E:") async -> Bool {
        let ok = await run(tr("Schriftart wird übertragen …")) { client in
            try await client.uploadFont(name: name, data: data, drive: drive)
        } != nil
        recordJob(.font, title: name, labels: 0, bytes: data.count, success: ok, message: ok ? nil : lastError)
        if ok { app?.toast(tr("Schriftart übertragen"), message: name, style: .success) }
        return ok
    }

    @discardableResult
    func uploadGraphic(name: String, bitmap: MonoBitmap, drive: String = "E:") async -> Bool {
        let ok = await run(tr("Grafik wird übertragen …")) { client in
            try await client.uploadGraphic(name: name, bitmap: bitmap, drive: drive)
        } != nil
        recordJob(.graphic, title: name, labels: 0, bytes: bitmap.data.count, success: ok, message: ok ? nil : lastError)
        if ok { app?.toast(tr("Grafik übertragen"), message: name, style: .success) }
        return ok
    }

    @discardableResult
    func deleteFile(_ path: String) async -> Bool {
        await run(tr("Datei wird gelöscht …")) { client in try await client.deleteFile(path) } != nil
    }

    /// Überträgt eine Firmware-Datei; `progress` wird laufend aktualisiert.
    @discardableResult
    func sendFirmware(_ data: Data, fileName: String) async -> Bool {
        let ok = await run(tr("Firmware wird übertragen …")) { client in
            try await client.sendFirmware(data, chunkSize: 16_384) { value in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.animate(.linear(duration: 0.2)) { self.progress = value }
                }
            }
        } != nil
        recordJob(.firmware, title: fileName, labels: 0, bytes: data.count, success: ok, message: ok ? nil : lastError)
        if ok {
            app?.toast(tr("Firmware übertragen"),
                       message: tr("Der Drucker startet nach der Installation automatisch neu."), style: .success)
        }
        return ok
    }

    func networkSettings() async -> NetworkSettings? {
        await run(tr("Netzwerkeinstellungen werden gelesen …")) { client in try await client.networkSettings() }
    }

    @discardableResult
    func applyNetworkSettings(_ settings: NetworkSettings) async -> Bool {
        let ok = await run(tr("Netzwerkeinstellungen werden übertragen …")) { client in
            try await client.applyNetworkSettings(settings)
        } != nil
        recordJob(.settings, title: tr("Netzwerkeinstellungen"), labels: 0, bytes: 0, success: ok,
                  message: ok ? nil : lastError)
        if ok {
            app?.toast(tr("Netzwerkeinstellungen übertragen"),
                       message: tr("Der Drucker übernimmt die Werte nach dem Neustart."), style: .success)
        }
        return ok
    }

    // MARK: - Hilfen

    /// Animiert eine Zustandsänderung – ohne Animation, wenn Bewegung reduziert werden soll.
    private func animate(_ animation: Animation, _ changes: () -> Void) {
        withAnimation(Motion.animation(animation, reduceMotion: app?.reducesMotion ?? false), changes)
    }

    /// Enthält der Auftrag einen RFID-Schreibbefehl (`^RFW`)?
    nonisolated static func containsRFIDWrite(_ data: Data) -> Bool {
        let upper = String(decoding: data, as: UTF8.self).uppercased()
        return upper.contains("^RFW")
    }

    /// Lesbare Fehlermeldung (LocalizedError bevorzugt).
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    /// Fügt `^PQn` vor jedem `^XZ` ein, falls das Format keine eigene Menge setzt.
    static func applyingQuantity(_ copies: Int, to zpl: String) -> String {
        let formats = zpl.components(separatedBy: "^XZ")
        guard formats.count > 1 else { return zpl }
        var result = ""
        for (index, part) in formats.enumerated() {
            if index == formats.count - 1 {
                result += part
            } else if part.uppercased().contains("^PQ") {
                result += part + "^XZ"
            } else {
                result += part + "^PQ\(copies)^XZ"
            }
        }
        return result
    }

    /// Kleine PNG-Vorschau eines ZPL-Etiketts für den Verlauf.
    nonisolated static func previewPNG(zpl: String, dotsPerMM: Int) async -> Data? {
        await Task.detached(priority: .utility) {
            let document = ZPLInterpreter(dotsPerMM: dotsPerMM).render(zpl)
            guard let label = document.labels.first else { return nil }
            let bitmap = SoftwareRasterizer.rasterize(label)
            return thumbnail(bitmap.toGrayImage())
        }.value
    }

    nonisolated static func previewPNG(image: GrayImage) async -> Data? {
        await Task.detached(priority: .utility) { thumbnail(image) }.value
    }

    nonisolated private static func thumbnail(_ image: GrayImage) -> Data? {
        guard image.width > 0, image.height > 0 else { return nil }
        let maxSide = 240.0
        let scale = min(1, maxSide / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        return PNGCodec.encode(image.scaled(width: w, height: h))
    }
}

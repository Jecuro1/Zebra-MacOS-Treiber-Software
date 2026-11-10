import AppKit
import Foundation
import Observation
import LabelWerkKit

/// Update-Dienst der App: Jede Änderung, die die macOS-CI besteht, erscheint als GitHub-Release mit
/// `labelwerk-update.json` und Installationspaket (docs/DEVELOPMENT.md „Release und Updates“). Dieser
/// Dienst findet es, lädt es, installiert es und startet LabelWerk neu – Drucker, Einstellungen,
/// Etikettenformate, Verlauf und macOS-Warteschlangen bleiben erhalten (sie liegen außerhalb des
/// App-Bundles; das Paket stellt Warteschlangen mit ihren Optionen auf den neuen Treiber um).
///
/// * **Suchen**: automatisch 10 s nach dem Start und danach alle 6 Stunden
///   (`AppPreferences.autoCheckUpdates`, `UpdateSchedule`), jederzeit über „Nach Updates suchen …“.
///   Automatische Suchen sind still; nur gefundene Updates zeigen den Hinweis im Hauptfenster.
/// * **Laden**: bei `AppPreferences.autoDownloadUpdates` sofort im Hintergrund nach
///   `~/Library/Caches/com.labelwerk.app/Updates` (Größe und SHA-256 prüft `UpdateClient`), damit
///   „Jetzt installieren“ ohne Wartezeit beginnt.
/// * **Installieren**: `installer -pkg … -target /` mit Administratorrechten (macOS fragt nach dem
///   Passwort; Abbrechen ist kein Fehler). Der Befehl kopiert das Paket zuvor in ein nur für root
///   beschreibbares Verzeichnis und prüft dort die Prüfsumme erneut. Protokoll:
///   `~/Library/Logs/LabelWerk/Update.log`. Danach startet ein losgelöster Prozess die neue App,
///   sobald diese beendet ist.
/// * **Private Repositorys**: Zugriffstoken aus dem Schlüsselbund (`UpdateTokenStore`), gelesen
///   höchstens einmal je Programmstart und nie auf dem Main-Thread.
@Observable
@MainActor
final class UpdateController {

    /// Zustand des Update-Dienstes.
    enum State: Equatable {
        /// Noch nicht gesucht (oder Update-Dienst abgeschaltet).
        case idle
        /// Erste Suche läuft (ohne bekanntes Update).
        case checking
        /// Keine neuere Version vorhanden.
        case upToDate(checkedAt: Date)
        /// Neuere Version gefunden, noch nicht geladen.
        case available(AvailableUpdate)
        /// Paket wird geladen (0…1).
        case downloading(AvailableUpdate, fraction: Double)
        /// Paket geladen und geprüft – „Jetzt installieren“ beginnt sofort.
        case readyToInstall(AvailableUpdate, URL)
        /// `installer` läuft (bzw. macOS fragt nach dem Passwort).
        case installing(AvailableUpdate)
        /// Suche, Laden oder Installation fehlgeschlagen (Text für die Oberfläche).
        case failed(String)
    }

    /// Wie das Ergebnis einer Suche gemeldet wird.
    enum Feedback: Int, Comparable {
        /// Automatische Suche: nur ein gefundenes Update zeigt den Hinweis im Hauptfenster.
        case silent = 0
        /// Die auslösende Ansicht zeigt den Zustand selbst (Einstellungen, Menüleiste).
        case inline = 1
        /// Menü „Nach Updates suchen …“: Details-Fenster bzw. Hinweis im Hauptfenster.
        case window = 2

        static func < (lhs: Feedback, rhs: Feedback) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: Konfiguration

    /// Repository „Besitzer/Name“ aus der Info.plist (`LWUpdateRepository`); `nil` = abgeschaltet.
    let repository: String?
    /// Installierte Version (`nil` ohne App-Bundle, z. B. bei `swift run`).
    let currentVersion: AppVersion?

    /// Wartezeit nach dem Start bis zur ersten automatischen Suche.
    static let launchDelay: Duration = .seconds(10)
    /// Takt, in dem geprüft wird, ob eine automatische Suche fällig ist.
    static let tickInterval: Duration = .seconds(60)

    /// Ordner für geladene Pakete: `~/Library/Caches/<Bundle-ID>/Updates` (entfernt auch
    /// `uninstall.sh --purge-user-data`).
    static var downloadDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.labelwerk.app"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    /// Protokoll des letzten Installationsversuchs.
    static var logFile: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return base.appendingPathComponent("Logs/LabelWerk/Update.log", isDirectory: false)
    }

    /// Ziel der Installation: Das Paket legt die App immer unter `/Applications/<Name>.app` ab
    /// (nicht verschiebbare Paketkomponente, siehe `Scripts/make_pkg.sh`).
    static var installedAppURL: URL {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "LabelWerk"
        return URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(name + ".app", isDirectory: true)
    }

    // MARK: Zustand

    private(set) var state: State = .idle
    /// Neuestes gefundenes Update – bleibt erhalten, wenn Laden oder Installieren fehlschlagen
    /// (dann ist „Jetzt installieren“ der erneute Versuch).
    private(set) var update: AvailableUpdate?
    /// Eine Suche läuft (auch im Hintergrund, während ein Update schon bekannt ist).
    private(set) var isChecking = false
    /// Zeitpunkt der letzten erfolgreichen Suche.
    private(set) var lastCheck: Date?
    /// Fehler der letzten Suche (`nil` nach einer erfolgreichen Suche).
    private(set) var lastCheckError: String?
    /// Ein Zugriffstoken für das Repository liegt im Schlüsselbund.
    private(set) var hasToken = false
    /// „Jetzt installieren“ während des Ladens: nach dem Laden sofort installieren.
    private(set) var installWhenReady = false
    /// Mit „Später“ ausgeblendeter Hinweis (Release-Tag; gilt bis zum nächsten Start oder einem neueren Update).
    private(set) var bannerDismissedTag: String?
    /// Details-Fenster (Sheet im Hauptfenster).
    var isDetailsPresented = false

    @ObservationIgnored private weak var model: AppModel?
    private let session: URLSession
    @ObservationIgnored private let schedule = UpdateSchedule()
    /// Nach Netzwerkfehlern früher erneut versuchen.
    @ObservationIgnored private let retrySchedule = UpdateSchedule(checkInterval: 30 * 60)
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var retrySoon = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFeedback: Feedback = .silent
    @ObservationIgnored private var pendingUserInitiated = false
    @ObservationIgnored private var recheckRequested = false
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadID: UUID?
    /// Token aus dem Schlüsselbund, nur im Speicher (`nil` = noch nicht gelesen).
    @ObservationIgnored private var cachedToken: String?

    convenience init(model: AppModel) {
        self.init(model: model, repository: UpdateSource.configuredRepository(), currentVersion: AppVersion.current())
    }

    /// - Parameters:
    ///   - repository: „Besitzer/Name“ (`nil` = abgeschaltet).
    ///   - currentVersion: installierte Version (`nil` = abgeschaltet).
    ///   - session: liefert die Netzwerkkonfiguration (Tests: Protokollklassen mit Attrappen).
    init(model: AppModel, repository: String?, currentVersion: AppVersion?, session: URLSession = .shared) {
        self.model = model
        self.repository = repository
        self.currentVersion = currentVersion
        self.session = session
    }

    // MARK: Abgeleitete Werte

    /// Updates sind möglich (Repository hinterlegt, Version bekannt).
    var isEnabled: Bool { repository != nil && currentVersion != nil }

    /// Warum Updates abgeschaltet sind (`nil`, wenn sie möglich sind).
    var disabledReason: String? {
        if currentVersion == nil {
            return tr("Updates gibt es nur für die installierte App – ohne App-Bundle ist keine Version bekannt.")
        }
        if repository == nil {
            return tr("In dieser App ist kein Update-Repository hinterlegt (Info.plist: LWUpdateRepository). Der Update-Dienst ist abgeschaltet.")
        }
        return nil
    }

    /// Die laufende App liegt dort, wo das Update sie ersetzt (`/Applications/LabelWerk.app`).
    var runsFromInstalledLocation: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            == Self.installedAppURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Releases im Browser (für „Alle Versionen auf GitHub“).
    var releasesPageURL: URL? {
        guard let repository else { return nil }
        return URL(string: "https://github.com/\(repository)/releases")
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    var isReadyToInstall: Bool {
        if case .readyToInstall = state { return true }
        return false
    }

    /// Ladefortschritt 0…1 (`nil`, wenn nicht geladen wird).
    var downloadFraction: Double? {
        if case .downloading(_, let fraction) = state { return fraction }
        return nil
    }

    /// Fehlertext des aktuellen Zustands.
    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func isSkipped(_ update: AvailableUpdate) -> Bool {
        model?.preferences.skippedUpdateTag == update.id
    }

    /// Hinweis „Update verfügbar“ im Hauptfenster zeigen?
    var showsBanner: Bool {
        guard let update, bannerDismissedTag != update.id, !isSkipped(update), !isDetailsPresented else {
            return false
        }
        switch state {
        case .available, .downloading, .readyToInstall, .installing, .failed: return true
        case .idle, .checking, .upToDate: return false
        }
    }

    /// Einzeiliger Status für Einstellungen, Menüleiste und „Hilfe und Über“.
    var statusText: String {
        if let reason = disabledReason { return reason }
        switch state {
        case .idle:
            return isChecking ? tr("Suche nach Updates …") : tr("Noch nicht nach Updates gesucht.")
        case .checking:
            return tr("Suche nach Updates …")
        case .upToDate:
            return tr("LabelWerk ist auf dem neuesten Stand.")
        case .available(let update):
            return tr("Update verfügbar: LabelWerk %@", update.manifest.appVersion.description)
        case .downloading(let update, let fraction):
            return tr("LabelWerk %@ wird geladen … %d %%", update.manifest.appVersion.description,
                      Int((fraction * 100).rounded(.down)))
        case .readyToInstall(let update, _):
            return tr("LabelWerk %@ ist geladen und bereit zur Installation.", update.manifest.appVersion.description)
        case .installing(let update):
            return tr("LabelWerk %@ wird installiert …", update.manifest.appVersion.description)
        case .failed(let message):
            return message
        }
    }

    // MARK: Start & Zeitplan

    /// Startet die automatische Suche (nur der erste Aufruf wirkt; `AppModel.start()`).
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard isEnabled, let repository else { return }
        hasToken = UpdateTokenStore.hasToken(repository: repository)
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: UpdateController.launchDelay)
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: UpdateController.tickInterval)
            }
        }
    }

    /// Einmal je Takt: fällige automatische Suche starten bzw. ein gefundenes Update laden.
    private func tick() {
        guard isEnabled, let model, model.preferences.autoCheckUpdates else { return }
        let now = Date()
        let due = schedule.isDue(lastCheck: lastAttempt, now: now)
            || (retrySoon && retrySchedule.isDue(lastCheck: lastAttempt, now: now))
        if due {
            checkNow(userInitiated: false)
        } else {
            startAutomaticDownloadIfNeeded()
        }
    }

    /// Nach Änderungen an den Update-Einstellungen (Schalter in Einstellungen › Updates).
    func preferencesDidChange() {
        guard let model else { return }
        if model.preferences.autoDownloadUpdates {
            startAutomaticDownloadIfNeeded()
        } else if downloadTask != nil, !installWhenReady {
            // Nur automatisch begonnenes Laden abbrechen – ein ausdrückliches „Jetzt installieren“ läuft weiter.
            cancelDownload()
        }
        // Automatische Suche eingeschaltet: Fälligkeit beim nächsten Takt.
    }

    // MARK: Suchen

    /// Sucht jetzt nach Updates. `userInitiated`: vom Benutzer ausgelöst (zeigt auch eine
    /// übersprungene Version). `feedback` (Standard: `.window` bzw. `.silent`) bestimmt, wie das
    /// Ergebnis gemeldet wird.
    func checkNow(userInitiated: Bool, feedback: Feedback? = nil) {
        let feedback = feedback ?? (userInitiated ? .window : .silent)
        guard isEnabled else {
            if feedback == .window {
                model?.toast(tr("Updates sind nicht verfügbar"), message: disabledReason, style: .warning)
            }
            return
        }
        if isInstalling { return }
        if userInitiated {
            bannerDismissedTag = nil
        }
        // Läuft schon eine Suche, übernimmt sie Auslöser und stärkere Rückmeldung.
        pendingFeedback = max(pendingFeedback, feedback)
        pendingUserInitiated = pendingUserInitiated || userInitiated
        guard checkTask == nil else { return }
        // Sofort als „sucht“ markieren (Schaltflächen sperren, bevor die Aufgabe startet).
        isChecking = true
        checkTask = Task { [weak self] in
            await self?.performCheck()
        }
    }

    private func performCheck() async {
        defer {
            isChecking = false
            checkTask = nil
            pendingFeedback = .silent
            pendingUserInitiated = false
            if recheckRequested {
                // Während der Suche wurde z. B. ein Token gespeichert: mit dem neuen Stand erneut suchen.
                recheckRequested = false
                checkNow(userInitiated: true, feedback: .inline)
            }
        }
        guard let repository, let current = currentVersion else { return }
        lastAttempt = Date()
        switch state {
        case .idle, .upToDate:
            state = .checking
        case .failed where update == nil:
            state = .checking
        default:
            break
        }
        do {
            let token = await token(for: repository)
            let client = UpdateClient(source: UpdateSource(repository: repository, token: token), session: session)
            let found = try await client.checkForUpdate(current: current)
            lastCheck = Date()
            lastCheckError = nil
            retrySoon = false
            if let found {
                handleFound(found, userInitiated: pendingUserInitiated)
            } else {
                handleUpToDate(current)
            }
        } catch {
            let message = Self.message(for: error)
            lastCheckError = message
            retrySoon = Self.isTransient(error)
            // Ein schon bekanntes Update bleibt bestehen; nur ohne Update zeigt der Zustand den Fehler.
            if update == nil {
                state = .failed(message)
            } else if case .checking = state, let update {
                state = .available(update)
            }
            if pendingFeedback == .window {
                model?.toast(tr("Suche nach Updates fehlgeschlagen"), message: message, style: .error,
                             action: ToastAction(title: tr("Erneut versuchen")) { [weak self] in
                                 self?.checkNow(userInitiated: true)
                             })
            }
        }
    }

    private func handleFound(_ found: AvailableUpdate, userInitiated: Bool) {
        // Eine Installation läuft schon (die Suche begann vorher): nichts mehr ändern.
        if isInstalling { return }
        if update?.id != found.id {
            // Neueres Release (oder das erste): ein laufendes Laden des alten endet hier.
            cancelDownload()
            update = found
            installWhenReady = false
            state = .available(found)
        } else {
            update = found
            switch state {
            case .checking, .failed, .idle, .upToDate:
                state = .available(found)
            default:
                break
            }
        }
        cleanDownloads(keeping: found.manifest.pkg.name)
        if userInitiated, isSkipped(found) {
            // Ausdrücklich gesucht: übersprungene Version wieder anbieten.
            model?.preferences.skippedUpdateTag = nil
        }
        if pendingFeedback == .window {
            if canPresentDetails {
                isDetailsPresented = true
            } else {
                model?.toast(tr("Update verfügbar"), message: tr("LabelWerk %@", found.manifest.appVersion.description),
                             style: .info)
            }
        }
        startAutomaticDownloadIfNeeded()
    }

    private func handleUpToDate(_ current: AppVersion) {
        if isInstalling { return }
        cancelDownload()
        update = nil
        installWhenReady = false
        state = .upToDate(checkedAt: Date())
        isDetailsPresented = false
        cleanDownloads(keeping: nil)
        if pendingFeedback == .window {
            model?.toast(tr("LabelWerk ist auf dem neuesten Stand"),
                         message: tr("Installiert ist Version %@.", current.description), style: .success)
        }
    }

    /// Kein anderes Sheet im Hauptfenster offen (es kann immer nur eins geben).
    private var canPresentDetails: Bool {
        guard let model else { return false }
        return !(model.isOnboardingPresented || model.isAddPrinterPresented || model.isInstallWizardPresented)
    }

    // MARK: Benutzeraktionen

    /// Details (Änderungen, Fortschritt) im Hauptfenster zeigen.
    func showDetails() {
        guard update != nil else { return }
        isDetailsPresented = true
    }

    /// „Später“: Hinweis bis zum nächsten Start bzw. einem neueren Update ausblenden.
    func dismissBanner() {
        bannerDismissedTag = update?.id
        isDetailsPresented = false
    }

    /// „Diese Version überspringen“: kein Hinweis und kein automatisches Laden mehr für dieses Release.
    func skipCurrentUpdate() {
        guard let update, let model else { return }
        model.preferences.skippedUpdateTag = update.id
        if case .downloading = state { cancelDownload() }
        isDetailsPresented = false
    }

    /// Übersprungene Version wieder anbieten.
    func unskip() {
        model?.preferences.skippedUpdateTag = nil
        startAutomaticDownloadIfNeeded()
    }

    /// „Jetzt installieren“: laden (falls nötig) und danach installieren.
    func downloadAndInstall() {
        guard let update else { return }
        if isSkipped(update) { model?.preferences.skippedUpdateTag = nil }
        switch state {
        case .readyToInstall:
            installAndRelaunch()
        case .downloading:
            installWhenReady = true
        case .installing:
            return
        default:
            installWhenReady = true
            startDownload(update)
        }
    }

    /// Bricht das Laden ab (das Update bleibt verfügbar).
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadID = nil
        installWhenReady = false
        if case .downloading(let update, _) = state {
            state = .available(update)
        }
    }

    // MARK: Laden

    private func startAutomaticDownloadIfNeeded() {
        guard let model, model.preferences.autoDownloadUpdates, let update, !isSkipped(update) else { return }
        switch state {
        case .available:
            startDownload(update)
        default:
            break
        }
    }

    private func startDownload(_ update: AvailableUpdate) {
        guard downloadTask == nil, let repository else { return }
        let id = UUID()
        downloadID = id
        state = .downloading(update, fraction: 0)
        downloadTask = Task { [weak self] in
            await self?.download(update, id: id, repository: repository)
        }
    }

    private func download(_ update: AvailableUpdate, id: UUID, repository: String) async {
        do {
            let token = await token(for: repository)
            let client = UpdateClient(source: UpdateSource(repository: repository, token: token), session: session)
            let file = try await client.download(update, to: Self.downloadDirectory) { [weak self] fraction in
                Task { @MainActor in self?.downloadProgressed(fraction, id: id) }
            }
            guard downloadID == id else { return }
            downloadTask = nil
            downloadID = nil
            state = .readyToInstall(update, file)
            if installWhenReady {
                installWhenReady = false
                installAndRelaunch()
            }
        } catch {
            guard downloadID == id else { return }
            downloadTask = nil
            downloadID = nil
            installWhenReady = false
            if (error as? UpdateError) == .cancelled || error is CancellationError {
                state = .available(update)
            } else {
                state = .failed(Self.message(for: error))
            }
        }
    }

    private func downloadProgressed(_ fraction: Double, id: UUID) {
        guard downloadID == id, case .downloading(let update, _) = state else { return }
        state = .downloading(update, fraction: max(0, min(1, fraction)))
    }

    /// Entfernt geladene Pakete außer `name` (nach jeder erfolgreichen Suche).
    private func cleanDownloads(keeping name: String?) {
        guard downloadTask == nil else { return }
        let directory = Self.downloadDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent != name {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Installieren

    /// Installiert das geladene Paket (macOS fragt nach dem Administratorpasswort) und startet
    /// LabelWerk neu. Ist das Paket noch nicht geladen, wird es zuerst geladen.
    func installAndRelaunch() {
        guard case .readyToInstall(let update, let package) = state else {
            downloadAndInstall()
            return
        }
        if let model, model.sessions.contains(where: \.isBusy) {
            model.toast(tr("Update wartet auf einen Drucker"),
                        message: tr("Ein Drucker ist gerade beschäftigt (Druck, Übertragung oder Firmware). Bitte nach dem Ende erneut „Jetzt installieren“ wählen."),
                        style: .warning)
            return
        }
        guard FileManager.default.fileExists(atPath: package.path) else {
            // Datei inzwischen entfernt (z. B. Cache geleert): neu laden und dann installieren.
            state = .available(update)
            downloadAndInstall()
            return
        }
        state = .installing(update)
        Task { [weak self] in
            await self?.install(update, package: package)
        }
    }

    private func install(_ update: AvailableUpdate, package: URL) async {
        let log = Self.prepareLogFile()
        let command = UpdateInstaller.shellCommand(pkg: package, logFile: log,
                                                   expectedSHA256: update.manifest.pkg.sha256)
        let script = UpdateInstaller.appleScript(
            shellCommand: command,
            prompt: tr("LabelWerk möchte das Update %@ installieren.", update.manifest.appVersion.description))
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(UpdateInstaller.osascriptPath, ["-e", script])
        } catch {
            state = .failed(tr("Das Update konnte nicht installiert werden: %@", error.localizedDescription))
            return
        }
        guard result.succeeded else {
            let output = result.stderr + "\n" + result.stdout
            if UpdateInstaller.isUserCancellation(output) {
                // Passwortdialog abgebrochen: kein Fehler, das Update bleibt bereit.
                state = .readyToInstall(update, package)
                return
            }
            let code = Self.exitCode(fromAppleScriptError: result.stderr)
            if code == 3 {
                // Prüfsumme der Kopie stimmt nicht: Datei verwerfen, „Jetzt installieren“ lädt neu.
                try? FileManager.default.removeItem(at: package)
            }
            state = .failed(Self.installFailureMessage(code: code, output: output))
            return
        }

        // Liegt die neue Version wirklich in /Applications? Sonst nicht neu starten (Endlosschleife).
        let appURL = Self.installedAppURL
        guard let installed = Self.version(ofAppAt: appURL) else {
            state = .failed(tr("Das Paket wurde installiert, aber die App wurde nicht unter „%@“ gefunden.", appURL.path))
            return
        }
        guard installed >= update.manifest.appVersion else {
            state = .failed(tr("Das Paket wurde installiert, aber „%@“ hat weiterhin Version %@. Details stehen im Protokoll %@.",
                               appURL.path, installed.description, log.path))
            return
        }
        relaunch(appURL)
    }

    /// Startet die neue App, sobald diese beendet ist, und beendet LabelWerk.
    private func relaunch(_ appURL: URL) {
        let arguments = UpdateInstaller.relaunchCommand(waitingFor: ProcessInfo.processInfo.processIdentifier,
                                                        appPath: appURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Installiert ist das Update – nur der automatische Neustart klappt nicht.
            update = nil
            state = .idle
            isDetailsPresented = false
            model?.toast(tr("Update installiert"), message: tr("Bitte LabelWerk beenden und erneut öffnen."),
                         style: .success,
                         action: ToastAction(title: tr("LabelWerk beenden")) { NSApp.terminate(nil) })
            return
        }
        isDetailsPresented = false
        // Speichert über `applicationWillTerminate` (AppDelegate) und beendet die App.
        NSApp.terminate(nil)
    }

    // MARK: Zugriffstoken (private Repositorys)

    /// Token aus dem Schlüsselbund – höchstens einmal je Start gelesen, nie auf dem Main-Thread.
    private func token(for repository: String) async -> String? {
        if let cachedToken { return cachedToken }
        guard hasToken else { return nil }
        let token = await Task.detached(priority: .utility) {
            UpdateTokenStore.read(repository: repository)
        }.value
        // Nicht gelesen (z. B. Zugriff verweigert): nächstes Mal erneut fragen.
        if let token { cachedToken = token }
        return token
    }

    /// Speichert einen Zugriffstoken im Schlüsselbund und sucht anschließend nach Updates.
    func saveToken(_ rawToken: String) throws {
        guard let repository else { return }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw TokenError.invalid
        }
        try UpdateTokenStore.save(token, repository: repository)
        cachedToken = token
        hasToken = true
        if checkTask != nil {
            recheckRequested = true
        } else {
            checkNow(userInitiated: true, feedback: .inline)
        }
    }

    /// Entfernt den Zugriffstoken aus dem Schlüsselbund.
    func removeToken() throws {
        guard let repository else { return }
        try UpdateTokenStore.delete(repository: repository)
        cachedToken = nil
        hasToken = false
    }

    enum TokenError: LocalizedError {
        case invalid
        var errorDescription: String? {
            tr("Der Token ist ungültig. Bitte den vollständigen Token von GitHub einfügen (ohne Leerzeichen).")
        }
    }

    // MARK: Hilfen

    /// Text für die Oberfläche zu einem Fehler des Update-Dienstes.
    static func message(for error: Error) -> String {
        guard let error = error as? UpdateError else { return error.localizedDescription }
        switch error {
        case .notPublished:
            return tr("Kein veröffentlichtes Update gefunden. Entweder gibt es noch keine Update-Version, oder das Repository ist privat – dann ist unter „Einstellungen › Updates“ ein gültiger Zugriffstoken nötig.")
        case .unauthorized:
            return tr("Der Zugriff auf die Updates wurde verweigert. Bitte den Zugriffstoken unter „Einstellungen › Updates“ prüfen (Lesezugriff auf die Inhalte des Repositorys).")
        case .rateLimited:
            return tr("GitHub hat vorübergehend zu viele Anfragen gezählt. Bitte später erneut nach Updates suchen.")
        case .network(let detail):
            return tr("Der Update-Server ist nicht erreichbar: %@", detail)
        case .invalidManifest(let detail):
            return tr("Die Update-Informationen sind ungültig: %@", detail)
        case .checksumMismatch:
            return tr("Die geladene Update-Datei ist beschädigt (die Prüfsumme stimmt nicht). Bitte erneut laden.")
        case .sizeMismatch:
            return tr("Die geladene Update-Datei ist unvollständig (die Größe stimmt nicht). Bitte erneut laden.")
        case .systemTooOld(let required):
            return tr("Das neueste Update benötigt macOS %@ oder neuer.", required)
        case .installFailed(let detail):
            return tr("Das Update konnte nicht installiert werden: %@", detail)
        case .cancelled:
            return tr("Das Update wurde abgebrochen.")
        }
    }

    /// Fehler, nach denen sich ein früherer erneuter Versuch lohnt (Netz, Kontingent).
    private static func isTransient(_ error: Error) -> Bool {
        switch error as? UpdateError {
        case .network?, .rateLimited?: return true
        default: return false
        }
    }

    /// Leeres Protokoll als Benutzer anlegen: Der Installationsbefehl läuft als root und schreibt
    /// hinein – so bleibt die Datei für die App lesbar.
    private static func prepareLogFile() -> URL {
        let url = logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// Exit-Code aus einer Fehlermeldung von `osascript` („… (3)“ am Ende).
    static func exitCode(fromAppleScriptError output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        let digits = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return Int(digits)
    }

    private static func installFailureMessage(code: Int?, output: String) -> String {
        switch code {
        case 3:
            return message(for: UpdateError.checksumMismatch)
        case 2:
            return tr("Das Update konnte nicht installiert werden: Die Update-Datei ließ sich nicht kopieren.")
        default:
            let detail = logTail() ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
            return tr("Das Update konnte nicht installiert werden: %@",
                      detail.isEmpty ? tr("unbekannter Fehler (Protokoll: %@)", logFile.path) : detail)
        }
    }

    /// Letzte Zeilen des Installationsprotokolls (für die Fehlermeldung).
    private static func logTail(lines: Int = 3) -> String? {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return nil }
        let tail = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
        guard !tail.isEmpty else { return nil }
        let joined = tail.joined(separator: " · ")
        return joined.count > 400 ? String(joined.suffix(400)) : joined
    }

    /// Version einer App laut ihrer Info.plist (direkt gelesen – `Bundle` würde die Werte der
    /// laufenden App aus dem Zwischenspeicher liefern).
    static func version(ofAppAt appURL: URL) -> AppVersion? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces),
              !version.isEmpty,
              let buildText = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces),
              let build = Int(buildText)
        else { return nil }
        return AppVersion(version: version, build: build)
    }
}

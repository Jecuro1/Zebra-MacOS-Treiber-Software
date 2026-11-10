import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Versionen

enum DriverVersion {
    /// Vergleicht Versionsnummern numerisch („1.10.0“ > „1.9.3“, fehlende Stellen = 0).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

// MARK: - Bestandsaufnahme

/// Momentaufnahme von installiertem Treiber und Treiberpaket im App-Bundle.
struct DriverSnapshot: Sendable, Equatable {
    var isInstalled: Bool
    var installedVersion: String?
    var installedPPDCount: Int
    var installedFilters: [String]
    var payloadURL: URL?
    var bundledVersion: String?
    var bundledPPDCount: Int
}

/// Ergebnis einer Diagnoseprüfung.
struct DriverCheck: Identifiable, Equatable {
    enum Outcome: Equatable { case passed, failed, unknown }
    let id: String
    let title: String
    let detail: String
    let outcome: Outcome
}

// MARK: - Installer

/// Installiert, aktualisiert und entfernt den CUPS-Treiber (Filter + PPDs) aus dem App-Bundle.
///
/// Das Treiberpaket liegt unter `Contents/Resources/Driver` im Aufbau von ARCHITECTURE.md §10
/// (`Library/Printers/LabelWerk/…`, `Library/Printers/PPDs/Contents/Resources/*.ppd.gz`,
/// `Library/Printers/LabelWerk/VERSION`). Installation und Entfernen laufen mit
/// Administratorrechten (macOS fragt nach dem Passwort); danach wird `cupsd` neu gestartet.
@Observable
@MainActor
final class DriverInstaller {
    static let shared = DriverInstaller()

    enum Operation: Equatable {
        case install, update, uninstall

        var title: String {
            switch self {
            case .install: return tr("Installation")
            case .update: return tr("Aktualisierung")
            case .uninstall: return tr("Entfernen")
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case running(Operation, String)
        case succeeded(Operation)
        case cancelled(Operation)
        case failed(Operation, String)
    }

    enum Status: Equatable {
        case notInstalled
        case current(String?)
        case outdated(installed: String?, bundled: String)
        case newerInstalled(installed: String, bundled: String)
    }

    private(set) var snapshot: DriverSnapshot?
    private(set) var schedulerRunning: Bool?
    private(set) var phase: Phase = .idle
    private(set) var checks: [DriverCheck] = []
    private(set) var lastRefresh: Date?
    /// Zählt erfolgreiche Installationen (z. B. für Erfolgsanimationen).
    private(set) var successCount = 0
    private(set) var isRefreshing = false

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    private init() {}

    // MARK: Abgeleitete Werte

    var isInstalled: Bool { snapshot?.isInstalled ?? CUPSService.isDriverInstalled }
    var installedVersion: String? { snapshot?.installedVersion }
    var bundledVersion: String? { snapshot?.bundledVersion }
    var payloadURL: URL? { snapshot?.payloadURL }
    var hasPayload: Bool { snapshot?.payloadURL != nil }
    var installedPPDCount: Int { snapshot?.installedPPDCount ?? 0 }
    var bundledPPDCount: Int { snapshot?.bundledPPDCount ?? 0 }
    var installedFilters: [String] { snapshot?.installedFilters ?? [] }

    var isBusy: Bool {
        if case .running = phase { return true }
        return false
    }

    var status: Status {
        guard isInstalled else { return .notInstalled }
        guard let bundled = bundledVersion else { return .current(installedVersion) }
        guard let installed = installedVersion else { return .outdated(installed: nil, bundled: bundled) }
        let comparison = DriverVersion.compare(installed, bundled)
        if comparison == .orderedAscending { return .outdated(installed: installed, bundled: bundled) }
        if comparison == .orderedDescending { return .newerInstalled(installed: installed, bundled: bundled) }
        return .current(installed)
    }

    /// Installation bzw. Update ist sinnvoll und möglich.
    var canInstallOrUpdate: Bool {
        guard hasPayload, !isBusy else { return false }
        switch status {
        case .notInstalled, .outdated: return true
        case .current, .newerInstalled: return false
        }
    }

    // MARK: Prüfen

    /// Liest Installationszustand, Paketinhalt und CUPS-Dienst neu ein.
    ///
    /// Läuft bereits eine Prüfung, wird ihr Ergebnis abgewartet. Mit `force` folgt danach eine
    /// eigene, frische Prüfung – nötig nach Installation/Entfernen, weil eine zuvor (z. B. während
    /// des Passwortdialogs) gestartete Prüfung noch den alten Zustand gelesen haben kann.
    func refresh(force: Bool = false) async {
        if let running = refreshTask {
            await running.value
            guard force else { return }
            // Eine inzwischen von einem anderen Aufruf gestartete Prüfung begann erst nach dieser
            // Anforderung und ist damit aktuell genug.
            if let newer = refreshTask {
                await newer.value
                return
            }
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            let snapshot = await Task.detached(priority: .utility) { DriverInstaller.inspect() }.value
            let scheduler = await DriverInstaller.isSchedulerRunning()
            withAnimation(.smooth) {
                self.snapshot = snapshot
                self.schedulerRunning = scheduler
                self.checks = DriverInstaller.makeChecks(snapshot: snapshot, scheduler: scheduler)
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
            // Vor dem Ende der Aufgabe freigeben: Wer danach `refresh` aufruft, startet neu.
            if self.refreshGeneration == generation {
                self.refreshTask = nil
            }
        }
        refreshTask = task
        await task.value
    }

    // MARK: Installieren / Aktualisieren

    /// Installiert bzw. aktualisiert den Treiber aus dem App-Paket. Ist bereits eine neuere Version
    /// installiert, wäre das ein Downgrade – nur mit `allowDowngrade` (nach ausdrücklicher Rückfrage).
    @discardableResult
    func install(allowDowngrade: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        if snapshot == nil { await refresh() }
        if case .newerInstalled = status, !allowDowngrade { return false }
        let operation: Operation = isInstalled ? .update : .install
        guard let payload = payloadURL else {
            setPhase(.failed(operation, tr("Diese App enthält kein Treiberpaket. Bitte das App-Bundle mit „Scripts/build_app.sh“ erstellen.")))
            return false
        }
        setPhase(.running(operation, tr("Treiber wird installiert – macOS fragt nach einem Administratorpasswort …")))
        let prompt = operation == .update
            ? tr("LabelWerk möchte den Druckertreiber aktualisieren.")
            : tr("LabelWerk möchte den Druckertreiber installieren.")
        do {
            try await ProcessRunner.runAsAdministrator(Self.installScript(payload: payload), prompt: prompt)
        } catch {
            return handle(error, operation: operation)
        }
        setPhase(.running(operation, tr("Installation wird überprüft …")))
        await refresh(force: true)
        guard isInstalled else {
            setPhase(.failed(operation, tr("Der CUPS-Filter wurde nach der Installation nicht gefunden.")))
            return false
        }
        successCount += 1
        setPhase(.succeeded(operation))
        return true
    }

    // MARK: Entfernen

    /// Entfernt Filter und PPDs; optional werden die genannten Warteschlangen mit entfernt.
    @discardableResult
    func uninstall(removingQueues queues: [String]) async -> Bool {
        guard !isBusy else { return false }
        setPhase(.running(.uninstall, tr("Treiber wird entfernt – macOS fragt nach einem Administratorpasswort …")))
        do {
            try await ProcessRunner.runAsAdministrator(
                Self.uninstallScript(removingQueues: queues),
                prompt: tr("LabelWerk möchte den Druckertreiber entfernen.")
            )
        } catch {
            return handle(error, operation: .uninstall)
        }
        setPhase(.running(.uninstall, tr("Entfernen wird überprüft …")))
        await refresh(force: true)
        guard !isInstalled else {
            setPhase(.failed(.uninstall, tr("Der Treiber ist weiterhin vorhanden.")))
            return false
        }
        setPhase(.succeeded(.uninstall))
        return true
    }

    /// Blendet das Ergebnis der letzten Operation aus.
    func dismissResult() {
        guard !isBusy else { return }
        setPhase(.idle)
    }

    // MARK: Intern

    private func setPhase(_ newPhase: Phase) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            phase = newPhase
        }
    }

    private func handle(_ error: Error, operation: Operation) -> Bool {
        let message: String
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            message = text
        } else {
            message = error.localizedDescription
        }
        if Self.isUserCancellation(message) {
            setPhase(.cancelled(operation))
        } else {
            setPhase(.failed(operation, message))
        }
        return false
    }

    /// osascript meldet einen abgebrochenen Passwortdialog mit Fehler −128.
    nonisolated static func isUserCancellation(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("-128") || lower.contains("user canceled") || lower.contains("user cancelled")
            || lower.contains("abgebrochen")
    }

    // MARK: Dateisystem

    /// Ort des Treiberpakets im App-Bundle (nil, wenn es fehlt – z. B. bei `swift run`).
    nonisolated static func bundledPayloadURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let payload = resources.appendingPathComponent("Driver", isDirectory: true)
        let filter = payload.appendingPathComponent("Library/Printers/LabelWerk/Filter/rastertolabelwerk")
        return FileManager.default.fileExists(atPath: filter.path) ? payload : nil
    }

    nonisolated static func inspect() -> DriverSnapshot {
        let fm = FileManager.default
        let installedPPDs = (try? fm.contentsOfDirectory(atPath: CUPSService.ppdDirectory.path)) ?? []
        let filterDirectory = CUPSService.driverRoot.appendingPathComponent("Filter").path
        let filters = ((try? fm.contentsOfDirectory(atPath: filterDirectory)) ?? []).filter { !$0.hasPrefix(".") }.sorted()

        let payload = bundledPayloadURL()
        var bundledVersion: String?
        var bundledPPDs: [String] = []
        if let payload {
            let candidates = [
                payload.appendingPathComponent("Library/Printers/LabelWerk/VERSION"),
                payload.appendingPathComponent("VERSION"),
            ]
            for url in candidates {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        bundledVersion = trimmed
                        break
                    }
                }
            }
            let ppdPath = payload.appendingPathComponent("Library/Printers/PPDs/Contents/Resources").path
            bundledPPDs = (try? fm.contentsOfDirectory(atPath: ppdPath)) ?? []
        }

        return DriverSnapshot(
            isInstalled: CUPSService.isDriverInstalled,
            installedVersion: CUPSService.installedDriverVersion,
            installedPPDCount: installedPPDs.filter(isLabelWerkPPD).count,
            installedFilters: filters,
            payloadURL: payload,
            bundledVersion: bundledVersion,
            bundledPPDCount: bundledPPDs.filter(isLabelWerkPPD).count
        )
    }

    nonisolated static func isLabelWerkPPD(_ fileName: String) -> Bool {
        fileName.hasPrefix("LabelWerk-") && (fileName.hasSuffix(".ppd.gz") || fileName.hasSuffix(".ppd"))
    }

    /// `lpstat -r` meldet, ob der CUPS-Dienst läuft (nil = unbekannt).
    nonisolated static func isSchedulerRunning() async -> Bool? {
        guard let result = try? await ProcessRunner.run(CUPSService.lpstat, ["-r"],
                                                         environment: ["LANG": "C", "LC_ALL": "C"]) else {
            return nil
        }
        let text = result.stdout.lowercased()
        if text.contains("not running") { return false }
        if text.contains("is running") { return true }
        return result.succeeded ? true : nil
    }

    @MainActor
    static func makeChecks(snapshot: DriverSnapshot, scheduler: Bool?) -> [DriverCheck] {
        var checks: [DriverCheck] = []
        let hasRaster = snapshot.installedFilters.contains("rastertolabelwerk")
        checks.append(DriverCheck(
            id: "raster",
            title: tr("Rasterfilter"),
            detail: hasRaster ? "rastertolabelwerk" : tr("rastertolabelwerk fehlt"),
            outcome: hasRaster && snapshot.isInstalled ? .passed : .failed
        ))
        let hasCommand = snapshot.installedFilters.contains("commandtolabelwerk")
        checks.append(DriverCheck(
            id: "command",
            title: tr("Befehlsfilter"),
            detail: hasCommand ? "commandtolabelwerk" : tr("commandtolabelwerk fehlt (Reinigen, Kalibrieren, Selbsttest)"),
            outcome: hasCommand ? .passed : .failed
        ))
        checks.append(DriverCheck(
            id: "ppd",
            title: tr("PPD-Dateien"),
            detail: snapshot.installedPPDCount > 0
                ? tr("%d Modell-/Auflösungsvarianten installiert", snapshot.installedPPDCount)
                : tr("Keine LabelWerk-PPDs gefunden"),
            outcome: snapshot.installedPPDCount > 0 ? .passed : .failed
        ))
        let versionOutcome: DriverCheck.Outcome
        let versionDetail: String
        switch (snapshot.installedVersion, snapshot.bundledVersion) {
        case let (installed?, bundled?):
            let comparison = DriverVersion.compare(installed, bundled)
            versionOutcome = comparison == .orderedAscending ? .failed : .passed
            versionDetail = comparison == .orderedAscending
                ? tr("Installiert %@, verfügbar %@", installed, bundled)
                : tr("Version %@", installed)
        case let (installed?, nil):
            versionOutcome = .passed
            versionDetail = tr("Version %@", installed)
        case (nil, _):
            versionOutcome = snapshot.isInstalled ? .unknown : .failed
            versionDetail = tr("Keine Versionsdatei gefunden")
        }
        checks.append(DriverCheck(id: "version", title: tr("Treiberversion"), detail: versionDetail, outcome: versionOutcome))
        checks.append(DriverCheck(
            id: "cups",
            title: tr("CUPS-Druckdienst"),
            detail: scheduler == true ? tr("Läuft") : (scheduler == false ? tr("Läuft nicht – wird beim nächsten Druckauftrag gestartet") : tr("Zustand unbekannt")),
            outcome: scheduler == true ? .passed : (scheduler == false ? .failed : .unknown)
        ))
        return checks
    }

    // MARK: Skripte (laufen mit Administratorrechten über /bin/sh)

    /// Kopiert das Paket nach /Library, setzt Besitzer & Rechte (CUPS verlangt root:wheel und keine
    /// Schreibrechte für Gruppe/Andere) und startet `cupsd` neu.
    ///
    /// Bewusst werden nur unsere eigenen Pfade ersetzt (Treiberordner und `LabelWerk-*.ppd*`),
    /// damit Besitzer/Rechte von `/Library/Printers` unangetastet bleiben und bei einem Update
    /// entfallene Modelle verschwinden.
    nonisolated static func installScript(payload: URL) -> String {
        let q = ProcessRunner.shellQuote
        let sourceRoot = payload.appendingPathComponent("Library/Printers/LabelWerk", isDirectory: true).path
        let sourcePPDs = payload.appendingPathComponent("Library/Printers/PPDs/Contents/Resources", isDirectory: true).path
        let root = CUPSService.driverRoot.path
        let ppdDirectory = CUPSService.ppdDirectory.path
        let commands = [
            "set -e",
            "/bin/mkdir -p \(q(ppdDirectory))",
            "/bin/rm -rf \(q(root))",
            // --noqtn: Quarantäne einer heruntergeladenen App nicht auf die Filter übertragen
            // (cupsd würde sie sonst ggf. nicht ausführen); zusätzlich explizit entfernen.
            "/usr/bin/ditto --noqtn \(q(sourceRoot)) \(q(root))",
            "/usr/bin/xattr -dr com.apple.quarantine \(q(root)) 2>/dev/null || true",
            "/usr/sbin/chown -R root:wheel \(q(root))",
            "/usr/bin/find \(q(root)) -type d -exec /bin/chmod 755 {} +",
            "/usr/bin/find \(q(root)) -type f -exec /bin/chmod 644 {} +",
            "/bin/chmod 755 \(q(root))/Filter/*",
            // Mitgelieferte Skripte (z. B. uninstall.sh) bleiben ausführbar.
            "/usr/bin/find \(q(root)) -type f -name '*.sh' -exec /bin/chmod 755 {} +",
            "/bin/rm -f \(q(ppdDirectory))/LabelWerk-*.ppd.gz \(q(ppdDirectory))/LabelWerk-*.ppd",
            "for f in \(q(sourcePPDs))/LabelWerk-*.ppd*; do if [ -e \"$f\" ]; then /bin/cp -f \"$f\" \(q(ppdDirectory))/; fi; done",
            "for f in \(q(ppdDirectory))/LabelWerk-*.ppd*; do if [ -e \"$f\" ]; then /usr/sbin/chown root:wheel \"$f\"; /bin/chmod 644 \"$f\"; /usr/bin/xattr -d com.apple.quarantine \"$f\" 2>/dev/null || true; fi; done",
            restartCUPSCommand,
        ]
        return commands.joined(separator: "; ")
    }

    /// Entfernt Warteschlangen (optional), den Treiberordner und unsere PPDs, dann Neustart von `cupsd`.
    nonisolated static func uninstallScript(removingQueues queues: [String]) -> String {
        let q = ProcessRunner.shellQuote
        let root = CUPSService.driverRoot.path
        let ppdDirectory = CUPSService.ppdDirectory.path
        var commands: [String] = []
        for queue in queues {
            commands.append("\(q(CUPSService.lpadmin)) -x \(q(queue)) || true")
        }
        commands.append("/bin/rm -rf \(q(root))")
        commands.append("/bin/rm -f \(q(ppdDirectory))/LabelWerk-*.ppd.gz \(q(ppdDirectory))/LabelWerk-*.ppd")
        commands.append(restartCUPSCommand)
        return commands.joined(separator: "; ")
    }

    nonisolated static let restartCUPSCommand =
        "/bin/launchctl kickstart -k system/org.cups.cupsd || /usr/bin/killall -HUP cupsd || true"
}

// MARK: - Warteschlangenzustand

enum DriverQueueState: Equatable {
    case idle, printing, disabled, unknown

    var displayName: String {
        switch self {
        case .idle: return tr("Bereit")
        case .printing: return tr("Druckt")
        case .disabled: return tr("Angehalten")
        case .unknown: return tr("Unbekannt")
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "checkmark.circle.fill"
        case .printing: return "printer.fill"
        case .disabled: return "pause.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .idle: return Theme.ready
        case .printing: return Theme.printing
        case .disabled: return Theme.warning
        case .unknown: return Theme.offline
        }
    }
}

/// Liest den Zustand aller Warteschlangen aus `lpstat -p` (englische Ausgabe erzwungen).
enum DriverQueueStatusReader {
    static func states() async -> [String: DriverQueueState] {
        guard let result = try? await ProcessRunner.run(CUPSService.lpstat, ["-p"],
                                                         environment: ["LANG": "C", "LC_ALL": "C"]) else {
            return [:]
        }
        return parse(result.stdout)
    }

    /// Zeilen wie „printer Zebra is idle.  enabled since …“, „printer Zebra now printing Zebra-12.“,
    /// „printer Zebra disabled since …“.
    static func parse(_ text: String) -> [String: DriverQueueState] {
        var states: [String: DriverQueueState] = [:]
        for line in text.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 3, tokens[0] == "printer" else { continue }
            let name = String(tokens[1])
            let rest = line.lowercased()
            if rest.contains("disabled") {
                states[name] = .disabled
            } else if rest.contains("now printing") {
                states[name] = .printing
            } else if rest.contains("is idle") {
                states[name] = .idle
            } else {
                states[name] = .unknown
            }
        }
        return states
    }
}

/// Erkennt Warteschlangen, die den LabelWerk-Treiber verwenden – ohne die Warteschlangen erneut
/// über `lpstat`/`lpoptions` abzufragen (gleiche Kriterien wie `CUPSService.labelWerkQueues()`).
enum DriverQueueClassifier {
    static func labelWerkQueueNames(in queues: [CUPSQueueInfo]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            var names = Set<String>()
            for queue in queues {
                if queue.makeAndModel?.contains("LabelWerk") == true {
                    names.insert(queue.name)
                    continue
                }
                let ppd = URL(fileURLWithPath: "/etc/cups/ppd/\(queue.name).ppd")
                if let text = try? String(contentsOf: ppd, encoding: .isoLatin1), text.contains("*lwModel:") {
                    names.insert(queue.name)
                }
            }
            return names
        }.value
    }
}

/// Zusätzliche Warteschlangen-Befehle, die `CUPSService` nicht anbietet.
enum DriverQueueControl {
    /// Setzt eine angehaltene Warteschlange fort (`cupsenable` + `cupsaccept`), bei Bedarf als Administrator.
    static func resume(_ queue: String) async throws {
        let enable = try await ProcessRunner.run(CUPSService.cupsenable, [queue])
        let accept = try await ProcessRunner.run(CUPSService.cupsaccept, [queue])
        if enable.succeeded && accept.succeeded { return }
        let script = [
            [CUPSService.cupsenable, queue].map(ProcessRunner.shellQuote).joined(separator: " "),
            [CUPSService.cupsaccept, queue].map(ProcessRunner.shellQuote).joined(separator: " "),
        ].joined(separator: "; ")
        try await ProcessRunner.runAsAdministrator(script, prompt: tr("LabelWerk möchte die Druckerwarteschlange fortsetzen."))
    }
}

import Foundation
import LabelWerkKit

/// Hält die macOS-Warteschlange jedes LabelWerk-Druckers automatisch auf dem Stand der App: Was in
/// LabelWerk eingestellt ist (Etikettenformat als benannte Standard-Papiergröße, `lwLabelWidth`/
/// `lwLabelHeight`, „An Etikett anpassen“ und alle übrigen Treiberoptionen), gilt ohne weiteres Zutun
/// für alle Programme – wie der Windows-Treiber ZDesigner (ARCHITECTURE.md §9 „Etikettengröße der
/// Warteschlange“).
///
/// * **Nach Änderungen** (``noteChange(_:)``): `AppModel.printerDidChange` meldet jede Änderung an
///   `PrinterSession.saved` – egal ob aus „Druckeinstellungen“, „Etiketten“, dem Designer, einer
///   Wiederherstellung oder dem Verknüpfen einer Warteschlange; `AppModel.customStocks` meldet
///   geänderte eigene Formate (``noteStocksChanged()``). Betrifft sie die Warteschlange (Fingerabdruck
///   aus Warteschlange, Format, Einstellungen, Sprache, Auflösung, Modell), folgt nach
///   ``debounce`` ein Abgleich.
/// * **Einmal nach dem Start** (``syncAtLaunch()``): auch Warteschlangen älterer Versionen erhalten
///   die benannte Größe und `lwLabelWidth`/`lwLabelHeight`.
/// * **Sofort** (``syncNow(_:force:allowAdminPrompt:)``): „OK“/„Übernehmen“ in „Druckeinstellungen“,
///   „Erneut übertragen“, „Erneut versuchen“.
///
/// Abgeglichen wird mit ``CUPSService/apply(_:to:force:allowAdminPrompt:)``: `lpadmin` läuft nur bei
/// Abweichungen laut `lpoptions`. Automatische Abgleiche fragen nie nach einem Passwort (Administratoren
/// gehören auf macOS zur Gruppe `_lpadmin`), sind bei Erfolg still und melden Fehler mit einem Hinweis
/// „Erneut versuchen“. Eine in macOS entfernte Warteschlange wird nicht neu angelegt. Alle
/// `lpadmin`-Aufrufe laufen nacheinander.
@MainActor
final class QueueSyncService {

    /// Was abgeglichen wird – ändert sich nichts davon, entfällt der Abgleich.
    struct Fingerprint: Equatable {
        var queue: String
        var configuration: CUPSService.QueueConfiguration
    }

    /// Wartezeit nach der letzten Änderung (mehrere Änderungen kurz hintereinander → ein Abgleich).
    static let debounce: Duration = .milliseconds(1500)
    /// Verzögerung des Abgleichs nach dem Start (Fenster und Verbindungen zuerst).
    static let launchDelay: Duration = .seconds(2)

    private weak var model: AppModel?
    /// Zuletzt erfolgreich abgeglichener (bzw. als aktuell geprüfter) Stand je Drucker.
    private var synced: [UUID: Fingerprint] = [:]
    /// Geplante Abgleiche nach Änderungen.
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// Letzter laufender Abgleich: Abgleiche laufen nacheinander.
    private var tail: Task<Void, Never>?
    private var launchStarted = false

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Soll-Zustand

    /// Soll-Zustand der Warteschlange eines Druckers (`nil`: keine Warteschlange bzw. Demo-Drucker).
    func fingerprint(for session: PrinterSession) -> Fingerprint? {
        guard !session.isVirtual, let queue = session.saved.cupsQueueName?.trimmingCharacters(in: .whitespaces),
              !queue.isEmpty else { return nil }
        return Fingerprint(queue: queue, configuration: CUPSService.QueueConfiguration(printer: session.saved,
                                                                                      stock: session.stock))
    }

    /// Ist die Warteschlange des Druckers laut letztem Abgleich auf dem Stand der App?
    func isInSync(_ session: PrinterSession) -> Bool {
        guard let fingerprint = fingerprint(for: session) else { return true }
        return synced[session.id] == fingerprint
    }

    // MARK: Auslöser

    /// Nach einer Änderung an den gespeicherten Daten eines Druckers (verzögert, zusammengefasst).
    func noteChange(_ session: PrinterSession) {
        guard let fingerprint = fingerprint(for: session) else {
            pending.removeValue(forKey: session.id)?.cancel()
            return
        }
        guard synced[session.id] != fingerprint else {
            pending.removeValue(forKey: session.id)?.cancel()
            return
        }
        let id = session.id
        pending[id]?.cancel()
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.pending[id] = nil
            guard let session = self.model?.session(for: id) else { return }
            await self.syncInBackground([session], reason: .change)
        }
    }

    /// Eigene Formate wurden geändert: alle Drucker prüfen (nur die betroffenen weichen ab).
    func noteStocksChanged() {
        model?.sessions.forEach(noteChange)
    }

    /// Einmal nach dem Start: alle Warteschlangen der Drucker prüfen und bei Abweichungen anpassen.
    func syncAtLaunch() {
        guard !launchStarted else { return }
        launchStarted = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            guard let self, let model = self.model else { return }
            await self.syncInBackground(model.sessions, reason: .launch)
        }
    }

    /// Gleicht sofort ab (Aktion des Benutzers): verwirft einen geplanten Abgleich, wartet auf laufende.
    ///
    /// - Parameters:
    ///   - force: `lpadmin` auch ohne erkannte Abweichung ausführen („Erneut übertragen“).
    ///   - allowAdminPrompt: bei fehlenden Rechten nach dem Administratorpasswort fragen.
    /// - Returns: Ergebnis des Abgleichs, `nil` ohne Warteschlange (bzw. beim Demo-Drucker).
    @discardableResult
    func syncNow(_ session: PrinterSession, force: Bool = true,
                 allowAdminPrompt: Bool = true) async throws -> CUPSService.QueueApplyOutcome? {
        pending.removeValue(forKey: session.id)?.cancel()
        guard let fingerprint = fingerprint(for: session) else { return nil }
        let outcome = try await serialized {
            try await CUPSService.apply(fingerprint.configuration, to: fingerprint.queue, force: force,
                                        allowAdminPrompt: allowAdminPrompt)
        }
        synced[session.id] = fingerprint
        return outcome
    }

    // MARK: Ablauf

    private enum Reason { case launch, change }

    /// Automatischer Abgleich: still bei Erfolg, ein Hinweis mit „Erneut versuchen“ bei Fehlern.
    private func syncInBackground(_ sessions: [PrinterSession], reason: Reason) async {
        guard CUPSService.isDriverInstalled else { return }
        let candidates = sessions.compactMap { session in fingerprint(for: session).map { (session, $0) } }
            .filter { reason == .launch || synced[$0.0.id] != $0.1 }
        guard !candidates.isEmpty else { return }
        let existing = Set(await CUPSService.queues().map(\.name))
        var failures: [(session: PrinterSession, error: Error)] = []
        for (session, fingerprint) in candidates {
            // In macOS entfernte Warteschlangen nicht neu anlegen (DriverView zeigt die Verknüpfung).
            guard existing.contains(fingerprint.queue) else { continue }
            // Inzwischen erneut geändert: der nächste geplante Abgleich übernimmt.
            guard self.fingerprint(for: session) == fingerprint else { continue }
            do {
                _ = try await serialized {
                    try await CUPSService.apply(fingerprint.configuration, to: fingerprint.queue, force: false,
                                                allowAdminPrompt: false)
                }
                synced[session.id] = fingerprint
            } catch CUPSService.CUPSError.queueMissing {
                continue
            } catch {
                failures.append((session, error))
            }
        }
        reportFailures(failures)
    }

    /// Ein Hinweis für alle fehlgeschlagenen Abgleiche, mit „Erneut versuchen“ (dann mit
    /// Passwortabfrage, denn der Benutzer hat ihn ausgelöst).
    private func reportFailures(_ failures: [(session: PrinterSession, error: Error)]) {
        guard let model, !failures.isEmpty else { return }
        let ids = failures.map(\.session.id)
        let names = failures.map { $0.session.saved.cupsQueueName ?? $0.session.displayName }
        let detail = PrinterSession.describe(failures[0].error)
        let message = failures.count == 1
            ? tr("„%@“ übernimmt die Einstellungen aus LabelWerk nicht: %@", names[0], detail)
            : tr("%@ übernehmen die Einstellungen aus LabelWerk nicht: %@", names.joined(separator: ", "), detail)
        model.toast(tr("macOS-Drucker nicht aktualisiert"), message: message, style: .warning,
                    action: ToastAction(title: tr("Erneut versuchen")) { [weak self] in
                        self?.retry(ids)
                    })
    }

    /// „Erneut versuchen“: die betroffenen Drucker sofort abgleichen.
    func retry(_ ids: [UUID]) {
        Task { [weak self] in
            guard let self, let model = self.model else { return }
            var failures: [(session: PrinterSession, error: Error)] = []
            var updated: [String] = []
            for id in ids {
                guard let session = model.session(for: id) else { continue }
                do {
                    if try await self.syncNow(session, force: true, allowAdminPrompt: true) != nil {
                        updated.append(session.saved.cupsQueueName ?? session.displayName)
                    }
                } catch {
                    failures.append((session, error))
                }
            }
            if !updated.isEmpty {
                model.toast(tr("macOS-Drucker aktualisiert"),
                            message: tr("Alle Programme drucken auf „%@“ mit den Einstellungen aus LabelWerk.",
                                        updated.joined(separator: ", ")),
                            style: .success)
            }
            self.reportFailures(failures)
        }
    }

    /// Führt `operation` nach allen zuvor gestarteten Abgleichen aus.
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

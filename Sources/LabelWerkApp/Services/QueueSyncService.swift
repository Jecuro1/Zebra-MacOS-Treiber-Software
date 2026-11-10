import AppKit
import Foundation
import Observation
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
///   geänderte eigene Formate (``noteStocksChanged()``). Betrifft sie die Warteschlangen (Fingerabdruck
///   aus Warteschlangen, Format, Einstellungen, Sprache, Auflösung, Modell), folgt nach
///   ``debounce`` ein Abgleich.
/// * **Einmal nach dem Start** (``syncAtLaunch()``): auch Warteschlangen älterer Versionen erhalten
///   die benannte Größe und `lwLabelWidth`/`lwLabelHeight`.
/// * **Sofort** (``syncNow(_:force:allowAdminPrompt:)``): „OK“/„Übernehmen“ in „Druckeinstellungen“,
///   „Erneut übertragen“, „Erneut versuchen“.
///
/// Abgeglichen werden die verknüpfte Warteschlange (`SavedPrinter.cupsQueueName`) und die übernommenen
/// (`SavedPrinter.adoptedQueueNames`) mit ``CUPSService/apply(_:to:force:allowAdminPrompt:)``: `lpadmin`
/// läuft nur bei Abweichungen laut `lpoptions`. Automatische Abgleiche fragen nie nach einem Passwort
/// (Administratoren gehören auf macOS zur Gruppe `_lpadmin`), sind bei Erfolg still und melden Fehler
/// mit einem Hinweis „Erneut versuchen“. Eine in macOS entfernte Warteschlange wird nicht neu angelegt.
/// Alle `lpadmin`-Aufrufe laufen nacheinander.
///
/// **Übernahme fremder Warteschlangen** (ARCHITECTURE.md §9 „Übernahme von macOS-Warteschlangen“):
/// Eine Warteschlange mit fremdem Treiber, deren Geräte-URI zu einem in LabelWerk eingerichteten
/// Netzwerkdrucker führt (z. B. „10.62.13.19“ aus „Drucker & Scanner“ mit AirPrint), stellt der Dienst
/// still auf den LabelWerk-Treiber um (`QueueAdoption.decide`, ``CUPSService/adoptQueue(_:deviceURI:description:configuration:allowAdminPrompt:)``)
/// und meldet das mit einem Hinweis – nach dem Start, bei jedem Aktivieren der App (``adoptionDebounce``)
/// und wenn ein Drucker hinzukommt oder seine Verbindung ändert. Warteschlangen anderer Hosts und
/// Freigaben eines Druckservers (`…/printers/…`) bleiben unberührt (`QueueAdoption.deviceEndpoint`).
///
/// **Etikettentypen** (ARCHITECTURE.md §9 „Etikettentypen“): Jeder Typ eines Druckers (`SavedPrinter.labelTypes`)
/// erhält eine eigene Warteschlange „<Drucker> – <Typ>“ mit derselben Geräte-URI wie die Warteschlange des
/// Druckers (ohne sie `socket://host:port` bzw. die USB-URI), dem Format des Typs als benannter Standardgröße
/// und den Einstellungen des Druckers mit den Abweichungen des Typs. Sie folgt denselben Auslösern (Änderung,
/// Start, „OK“/„Übernehmen“) und wird – anders als die Warteschlange des Druckers – neu angelegt, wenn sie
/// fehlt: Ein Etikettentyp *ist* ein macOS-Drucker. Den Namen vergibt der erste Abgleich
/// (`LabelTypeQueueNaming`) und merkt ihn im Typ; nur diese Warteschlangen entfernt LabelWerk wieder
/// (Typ bzw. Drucker gelöscht, ``removeLabelTypeQueues(_:of:)``). Den Zustand je Typ zeigt
/// ``labelTypeStatus``.
@MainActor
final class QueueSyncService {

    /// Was abgeglichen wird – ändert sich nichts davon, entfällt der Abgleich.
    struct Fingerprint: Equatable {
        /// Verknüpfte Warteschlange zuerst, danach die übernommenen (``queueNames(of:)``).
        var queues: [String]
        var configuration: CUPSService.QueueConfiguration
        /// Soll-Zustand der Warteschlangen der Etikettentypen (ohne deren Namen – die vergibt der Abgleich).
        var labelTypes: [LabelTypeTarget] = []
        /// Verbindung des Druckers (Geräte-URI der Typ-Warteschlangen); nur mit Etikettentypen gesetzt.
        var descriptor: ConnectionDescriptor?
    }

    /// Soll-Zustand der Warteschlange eines Etikettentyps.
    struct LabelTypeTarget: Equatable {
        var typeID: UUID
        /// Beschreibung im Druckdialog („Zebra ZD421t – Brillenetikett“).
        var description: String
        var configuration: CUPSService.QueueConfiguration
    }

    /// Stand einer fehlgeschlagenen automatischen Übernahme: Erst wenn sich daran etwas ändert, wird
    /// sie erneut versucht (sonst bei jedem Aktivieren der App ein Hinweis).
    private struct AdoptionAttempt: Equatable {
        var printerID: UUID
        var deviceURI: String
        var makeAndModel: String?
        var configuration: CUPSService.QueueConfiguration
    }

    /// Wartezeit nach der letzten Änderung (mehrere Änderungen kurz hintereinander → ein Abgleich).
    static let debounce: Duration = .milliseconds(1500)
    /// Verzögerung des Abgleichs nach dem Start (Fenster und Verbindungen zuerst).
    static let launchDelay: Duration = .seconds(2)
    /// Wartezeit nach dem Aktivieren der App bzw. einer neuen Druckerverbindung bis zur Prüfung auf
    /// fremde Warteschlangen (schnelles Hin- und Herwechseln → eine Prüfung).
    static let adoptionDebounce: Duration = .seconds(1)

    private weak var model: AppModel?
    /// Zuletzt erfolgreich abgeglichener (bzw. als aktuell geprüfter) Stand je Drucker.
    private var synced: [UUID: Fingerprint] = [:]
    /// Zuletzt automatisch versuchter Stand je Drucker (auch fehlgeschlagen): Andere Änderungen am
    /// Drucker (Favorit, Farbe …) lösen so keinen weiteren Versuch samt Hinweis aus.
    private var attempted: [UUID: Fingerprint] = [:]
    /// Geplante Abgleiche nach Änderungen.
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// Letzter laufender Abgleich: Abgleiche laufen nacheinander.
    private var tail: Task<Void, Never>?
    private var launchStarted = false

    /// Geplante Prüfung auf fremde Warteschlangen.
    private var adoptionPending: Task<Void, Never>?
    /// Die erste Prüfung (nach dem Start) ist gelaufen – vorher wartet jede weitere auf sie.
    private var launchAdoptionDone = false
    private var isAdopting = false
    private var adoptionRequested = false
    /// Verbindungen der Drucker bei der letzten Prüfung (``adoptionSignature(_:)``).
    private var lastAdoptionSignature: [String]?
    /// Fehlgeschlagene automatische Übernahmen je Warteschlange.
    private var failedAdoptions: [String: AdoptionAttempt] = [:]
    private var activationObserver: NSObjectProtocol?

    /// Zustand der Warteschlange je Etikettentyp (für „Druckeinstellungen › Etikettentypen“).
    let labelTypeStatus = LabelTypeQueueStatusStore()

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Soll-Zustand

    /// Soll-Zustand der Warteschlangen eines Druckers (`nil`: weder Warteschlange noch Etikettentypen bzw.
    /// Demo-Drucker).
    func fingerprint(for session: PrinterSession) -> Fingerprint? {
        guard !session.isVirtual else { return nil }
        let queues = Self.queueNames(of: session.saved)
        let types = Self.labelTypeTargets(of: session)
        guard !queues.isEmpty || !types.isEmpty else { return nil }
        return Fingerprint(queues: queues,
                           configuration: CUPSService.QueueConfiguration(printer: session.saved, stock: session.stock),
                           labelTypes: types, descriptor: types.isEmpty ? nil : session.saved.descriptor)
    }

    /// Soll-Zustand der Warteschlangen aller Etikettentypen eines Druckers.
    static func labelTypeTargets(of session: PrinterSession) -> [LabelTypeTarget] {
        session.saved.labelTypes.map { type in
            LabelTypeTarget(typeID: type.id, description: labelTypeQueueDescription(type, of: session),
                            configuration: labelTypeConfiguration(type, of: session))
        }
    }

    /// Soll-Zustand der Warteschlange eines Etikettentyps: Format des Typs, Einstellungen des Druckers mit
    /// den Abweichungen des Typs (`PrinterSession.effectiveSettings(for:)`), Sprache, Auflösung und Modell
    /// des Druckers.
    static func labelTypeConfiguration(_ type: LabelType, of session: PrinterSession) -> CUPSService.QueueConfiguration {
        CUPSService.QueueConfiguration(settings: session.effectiveSettings(for: type), stock: session.stock(for: type),
                                       language: session.saved.language, resolution: session.saved.resolution,
                                       modelID: session.saved.modelID)
    }

    /// „Zebra ZD421t – Brillenetikett“ (`LabelTypeQueueNaming.description`).
    static func labelTypeQueueDescription(_ type: LabelType, of session: PrinterSession) -> String {
        LabelTypeQueueNaming.description(printerName: session.saved.name, modelName: session.model?.displayName,
                                         host: host(of: session.saved.descriptor), typeName: type.name)
    }

    /// Host einer Netzwerkverbindung (für die Erkennung von Adressnamen).
    static func host(of descriptor: ConnectionDescriptor) -> String? {
        if case .tcp(let host, _) = descriptor { return host }
        return nil
    }

    /// Warteschlangen eines Druckers: die verknüpfte (`cupsQueueName`), danach die übernommenen – ohne
    /// leere und doppelte Namen (CUPS unterscheidet nicht zwischen Groß- und Kleinschreibung).
    static func queueNames(of saved: SavedPrinter) -> [String] {
        var result: [String] = []
        for name in [saved.cupsQueueName ?? ""] + saved.adoptedQueueNames {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            result.append(trimmed)
        }
        return result
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
        guard synced[session.id] != fingerprint, attempted[session.id] != fingerprint else {
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

    /// Einmal nach dem Start: fremde Warteschlangen der Drucker übernehmen, dann alle Warteschlangen
    /// prüfen und bei Abweichungen anpassen. Danach prüft der Dienst bei jedem Aktivieren der App und
    /// bei neuen Druckerverbindungen erneut auf fremde Warteschlangen.
    func syncAtLaunch() {
        guard !launchStarted else { return }
        launchStarted = true
        startObserving()
        Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            guard let self, let model = self.model else { return }
            await self.runAdoption()
            self.launchAdoptionDone = true
            await self.syncInBackground(model.sessions, reason: .launch)
        }
    }

    /// Gleicht sofort ab (Aktion des Benutzers): verwirft einen geplanten Abgleich, wartet auf laufende.
    /// Übernommene Warteschlangen folgen der verknüpften; ihre Fehler meldet der automatische Abgleich.
    ///
    /// - Parameters:
    ///   - force: `lpadmin` auch ohne erkannte Abweichung ausführen („Erneut übertragen“; nur für die
    ///     verknüpfte Warteschlange).
    ///   - allowAdminPrompt: bei fehlenden Rechten nach dem Administratorpasswort fragen.
    /// - Returns: Ergebnis für die verknüpfte Warteschlange, `nil` ohne sie (bzw. beim Demo-Drucker).
    @discardableResult
    func syncNow(_ session: PrinterSession, force: Bool = true,
                 allowAdminPrompt: Bool = true) async throws -> CUPSService.QueueApplyOutcome? {
        pending.removeValue(forKey: session.id)?.cancel()
        guard let fingerprint = fingerprint(for: session) else { return nil }
        let linked = session.saved.cupsQueueName?.trimmingCharacters(in: .whitespaces)
        var outcome: CUPSService.QueueApplyOutcome?
        var linkedError: Error?
        for queue in fingerprint.queues {
            let isLinked = queue == linked
            do {
                let result = try await applyAdopting(fingerprint.configuration, to: queue, force: force && isLinked,
                                                     allowAdminPrompt: allowAdminPrompt)
                if isLinked { outcome = result }
            } catch {
                if isLinked { linkedError = error }
            }
        }
        // Etikettentypen folgen den Einstellungen des Druckers; ihre Fehler meldet ein eigener Hinweis.
        let types = await syncLabelTypeQueues(session, allowAdminPrompt: allowAdminPrompt)
        reportLabelTypeResults([types])
        if let linkedError { throw linkedError }
        if types.failures.isEmpty { synced[session.id] = fingerprint }
        return outcome
    }

    /// Gleicht nur die Warteschlangen der Etikettentypen eines Druckers sofort ab (Aktion des Benutzers,
    /// z. B. „Sichern“ im Etikettentyp oder „Erneut versuchen“; mit Passwortabfrage). Ein Hinweis meldet
    /// neu eingerichtete macOS-Drucker bzw. Fehler.
    func syncLabelTypesNow(_ session: PrinterSession, allowAdminPrompt: Bool = true) async {
        let result = await syncLabelTypeQueues(session, allowAdminPrompt: allowAdminPrompt)
        reportLabelTypeResults([result])
    }

    /// Gleicht eine Warteschlange ab. Hat sie (noch) einen fremden Treiber, wird sie zuerst übernommen,
    /// sofern sie zu einem LabelWerk-Drucker führt (``adoptForeignQueues(allowAdminPrompt:only:)``) –
    /// sonst bleibt es bei `CUPSError.notLabelWerkQueue`.
    private func applyAdopting(_ configuration: CUPSService.QueueConfiguration, to queue: String, force: Bool,
                               allowAdminPrompt: Bool) async throws -> CUPSService.QueueApplyOutcome {
        do {
            return try await serialized {
                try await CUPSService.apply(configuration, to: queue, force: force, allowAdminPrompt: allowAdminPrompt)
            }
        } catch CUPSService.CUPSError.notLabelWerkQueue {
            await adoptForeignQueues(allowAdminPrompt: allowAdminPrompt, only: [queue])
            return try await serialized {
                try await CUPSService.apply(configuration, to: queue, force: force, allowAdminPrompt: allowAdminPrompt)
            }
        }
    }

    // MARK: Ablauf

    private enum Reason { case launch, change }

    /// Automatischer Abgleich: still bei Erfolg, ein Hinweis mit „Erneut versuchen“ bei Fehlern.
    private func syncInBackground(_ sessions: [PrinterSession], reason: Reason) async {
        guard CUPSService.isDriverInstalled else {
            for session in sessions {
                for type in session.saved.labelTypes {
                    labelTypeStatus.set(.unavailable(tr("Der LabelWerk-Treiber ist nicht installiert.")), for: type.id)
                }
            }
            return
        }
        let candidates = sessions.compactMap { session in fingerprint(for: session).map { (session, $0) } }
            .filter { reason == .launch || (synced[$0.0.id] != $0.1 && attempted[$0.0.id] != $0.1) }
        guard !candidates.isEmpty else { return }
        let queues = await CUPSService.queues()
        let existing = Set(queues.map(\.name))
        // Nur Warteschlangen mit LabelWerk-Treiber: Eine fremde stellt die Übernahme
        // (`runAdoption`) um, sofern sie zum Gerät des Druckers führt – sonst bleibt sie unverändert.
        let labelWerk = await DriverQueueClassifier.labelWerkQueueNames(in: queues)
        var failures: [(session: PrinterSession, queue: String, error: Error)] = []
        var typeResults: [LabelTypeSyncResult] = []
        for (session, fingerprint) in candidates {
            // Inzwischen erneut geändert: der nächste geplante Abgleich übernimmt.
            guard self.fingerprint(for: session) == fingerprint else { continue }
            attempted[session.id] = fingerprint
            var failed = false
            var vanished: [String] = []
            for queue in fingerprint.queues {
                // In macOS entfernte Warteschlangen nicht neu anlegen (DriverView zeigt die Verknüpfung);
                // eine entfernte übernommene vergisst der Drucker.
                guard existing.contains(queue) else {
                    if !queues.isEmpty, session.saved.adoptedQueueNames.contains(queue) { vanished.append(queue) }
                    continue
                }
                guard labelWerk.contains(queue) else { continue }
                do {
                    _ = try await serialized {
                        try await CUPSService.apply(fingerprint.configuration, to: queue, force: false,
                                                    allowAdminPrompt: false)
                    }
                } catch CUPSService.CUPSError.queueMissing {
                    continue
                } catch CUPSService.CUPSError.notLabelWerkQueue {
                    continue
                } catch {
                    failed = true
                    failures.append((session, queue, error))
                }
            }
            if !fingerprint.labelTypes.isEmpty {
                let result = await syncLabelTypeQueues(session, allowAdminPrompt: false)
                if !result.failures.isEmpty { failed = true }
                typeResults.append(result)
            }
            if !failed { synced[session.id] = fingerprint }
            if !vanished.isEmpty {
                session.saved.adoptedQueueNames.removeAll { vanished.contains($0) }
            }
        }
        reportFailures(failures)
        reportLabelTypeResults(typeResults)
    }

    /// Ein Hinweis für alle fehlgeschlagenen Abgleiche, mit „Erneut versuchen“ (dann mit
    /// Passwortabfrage, denn der Benutzer hat ihn ausgelöst).
    private func reportFailures(_ failures: [(session: PrinterSession, queue: String, error: Error)]) {
        guard let model, !failures.isEmpty else { return }
        var ids: [UUID] = []
        for failure in failures where !ids.contains(failure.session.id) { ids.append(failure.session.id) }
        let names = failures.map(\.queue)
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
            var failures: [(session: PrinterSession, queue: String, error: Error)] = []
            var updated: [String] = []
            for id in ids {
                guard let session = model.session(for: id) else { continue }
                do {
                    if try await self.syncNow(session, force: true, allowAdminPrompt: true) != nil {
                        updated.append(session.saved.cupsQueueName ?? session.displayName)
                    }
                } catch {
                    failures.append((session, session.saved.cupsQueueName ?? session.displayName, error))
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

    // MARK: Etikettentypen

    /// Grund, warum die Etikettentypen des Demo-Druckers keinen macOS-Drucker erhalten (Zustand
    /// „Nicht verfügbar“ – auch ohne Abgleich, den es für ihn nie gibt).
    static var virtualPrinterReason: String { tr("Der Demo-Drucker hat keinen macOS-Drucker.") }

    /// Ergebnis eines Abgleichs der Typ-Warteschlangen eines Druckers.
    struct LabelTypeSyncResult: Sendable {
        var printerID: UUID
        /// Neu angelegte macOS-Drucker (Beschreibung).
        var created: [String] = []
        /// Fehlgeschlagene Typen: Beschreibung und Fehlermeldung.
        var failures: [LabelTypeFailure] = []
    }

    struct LabelTypeFailure: Sendable {
        var description: String
        var message: String
    }

    /// Legt die Warteschlangen der Etikettentypen eines Druckers an bzw. gleicht sie ab
    /// (``CUPSService/ensureLabelTypeQueue(_:deviceURI:description:location:configuration:allowAdminPrompt:)``).
    /// Läuft als Ganzes in der Reihe der `lpadmin`-Aufrufe: Namensvergabe, Anlegen und Merken des Namens
    /// überschneiden sich nie mit einem gleichzeitigen Abgleich (sonst entstünde eine zweite Warteschlange).
    private func syncLabelTypeQueues(_ session: PrinterSession, allowAdminPrompt: Bool) async -> LabelTypeSyncResult {
        let id = session.id
        let empty = LabelTypeSyncResult(printerID: id)
        guard !session.saved.labelTypes.isEmpty else { return empty }
        guard !session.isVirtual else {
            for type in session.saved.labelTypes {
                labelTypeStatus.set(.unavailable(Self.virtualPrinterReason), for: type.id)
            }
            return empty
        }
        guard CUPSService.isDriverInstalled else {
            for type in session.saved.labelTypes {
                labelTypeStatus.set(.unavailable(tr("Der LabelWerk-Treiber ist nicht installiert.")), for: type.id)
            }
            return empty
        }
        for type in session.saved.labelTypes where !labelTypeStatus.status(for: type.id).isReady {
            labelTypeStatus.set(.syncing, for: type.id)
        }
        return (try? await serialized { [weak self] () async -> LabelTypeSyncResult in
            guard let self, let session = self.model?.session(for: id) else { return empty }
            return await self.performLabelTypeSync(session, allowAdminPrompt: allowAdminPrompt)
        }) ?? empty
    }

    /// Eigentlicher Abgleich (nur aus ``syncLabelTypeQueues(_:allowAdminPrompt:)`` – innerhalb von
    /// ``serialized(_:)``, ruft `CUPSService` deshalb direkt auf).
    private func performLabelTypeSync(_ session: PrinterSession, allowAdminPrompt: Bool) async -> LabelTypeSyncResult {
        var result = LabelTypeSyncResult(printerID: session.id)
        let queues = await CUPSService.queues()
        guard let deviceURI = await Self.labelTypeDeviceURI(for: session, queues: queues) else {
            let reason = tr("Für diese Verbindung kann kein macOS-Drucker eingerichtet werden (nur Netzwerk, USB oder eine macOS-Warteschlange).")
            for type in session.saved.labelTypes { labelTypeStatus.set(.unavailable(reason), for: type.id) }
            return result
        }
        var known = Set(queues.map { $0.name.lowercased() })
        let base = Self.baseQueueName(for: session)
        for type in session.saved.labelTypes {
            // Drucker inzwischen entfernt: nichts mehr anlegen (seine Typ-Warteschlangen entfernt
            // `removeLabelTypeQueues` nach diesem Abgleich).
            guard model?.session(for: session.id) === session else { break }
            // Inzwischen gelöscht: nichts anlegen.
            guard let current = session.labelType(id: type.id) else { continue }
            let target = LabelTypeTarget(typeID: current.id, description: Self.labelTypeQueueDescription(current, of: session),
                                         configuration: Self.labelTypeConfiguration(current, of: session))
            let name = current.queueName ?? LabelTypeQueueNaming.queueName(
                baseQueue: base, typeName: current.name, existing: Array(known) + otherLabelTypeQueueNames(excluding: current.id))
            do {
                let outcome = try await CUPSService.ensureLabelTypeQueue(
                    name, deviceURI: deviceURI, description: target.description, location: session.saved.location,
                    configuration: target.configuration, allowAdminPrompt: allowAdminPrompt)
                known.insert(name.lowercased())
                if current.queueName != name, !recordLabelTypeQueue(name, typeID: current.id, in: session) {
                    // Typ bzw. Drucker wurde während des Anlegens gelöscht: die neue Warteschlange gleich
                    // wieder entfernen (sonst bliebe sie für immer in macOS).
                    _ = try? await CUPSService.removeLabelTypeQueue(name, allowAdminPrompt: false)
                    labelTypeStatus.remove(current.id)
                    continue
                }
                if outcome == .created { result.created.append(target.description) }
                labelTypeStatus.set(.ready(name), for: current.id)
            } catch {
                // Drucker inzwischen entfernt: kein Hinweis über einen Fehler, den niemand mehr beheben kann.
                guard model?.session(for: session.id) === session else {
                    labelTypeStatus.remove(current.id)
                    break
                }
                let message = PrinterSession.describe(error)
                labelTypeStatus.set(.failed(message), for: current.id)
                result.failures.append(LabelTypeFailure(description: target.description, message: message))
            }
        }
        return result
    }

    /// Namen der Warteschlangen aller anderen Etikettentypen (aller Drucker) – auch solcher, die gerade
    /// fehlen: Ein neuer Typ bekommt nie den Namen eines anderen.
    private func otherLabelTypeQueueNames(excluding typeID: UUID) -> [String] {
        (model?.sessions ?? []).flatMap { session in
            session.saved.labelTypes.compactMap { $0.id == typeID ? nil : $0.queueName }
        }
    }

    /// Merkt den Namen der Warteschlange im Typ. `false`, wenn es den Typ oder seinen Drucker nicht mehr
    /// gibt – ein entfernter Drucker hält sein `PrinterSession`-Objekt hier noch, doch was darin gemerkt
    /// würde, entfernte niemand mehr.
    private func recordLabelTypeQueue(_ name: String, typeID: UUID, in session: PrinterSession) -> Bool {
        guard model?.session(for: session.id) === session else { return false }
        var saved = session.saved
        guard let index = saved.labelTypes.firstIndex(where: { $0.id == typeID }) else { return false }
        saved.labelTypes[index].queueName = name
        session.saved = saved
        return true
    }

    /// Geräte-URI der Typ-Warteschlangen: die der Warteschlange des Druckers (verknüpfte, Verbindung über
    /// eine Warteschlange, übernommene – so erreicht macOS den Drucker bereits), sonst die der Verbindung
    /// (`socket://host:port`, USB-URI). `nil` für Bluetooth und den Demo-Drucker.
    static func labelTypeDeviceURI(for session: PrinterSession, queues: [CUPSQueueInfo]) async -> String? {
        var names = queueNames(of: session.saved)
        if case .cupsQueue(let name) = session.saved.descriptor { names.insert(name, at: min(1, names.count)) }
        for name in names {
            if let queue = queues.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let uri = queue.deviceURI.trimmingCharacters(in: .whitespacesAndNewlines)
                if !uri.isEmpty { return uri }
            }
        }
        return (try? await CUPSService.deviceURI(for: session.saved.descriptor)) ?? nil
    }

    /// Grundlage des Namens neuer Typ-Warteschlangen: die verknüpfte Warteschlange des Druckers, sonst
    /// sein bereinigter Name – nie eine bloße Adresse („10.62.13.19“ → „Zebra_ZD421t“).
    static func baseQueueName(for session: PrinterSession) -> String {
        let host = host(of: session.saved.descriptor)
        if let linked = session.saved.cupsQueueName?.trimmingCharacters(in: .whitespaces), !linked.isEmpty,
           !QueueAdoption.isAddressName(linked, host: host) {
            return linked
        }
        let name = LabelTypeQueueNaming.description(printerName: session.saved.name, modelName: session.model?.displayName,
                                                    host: host, typeName: "")
        return CUPSService.sanitizedQueueName(name)
    }

    /// Entfernt die Warteschlangen gelöschter Etikettentypen (bzw. aller Typen eines gelöschten Druckers) –
    /// nur die, die LabelWerk angelegt hat (`LabelType.queueName`, mit LabelWerk-Treiber). Fehler meldet ein
    /// Hinweis.
    func removeLabelTypeQueues(_ types: [LabelType], of printerName: String) {
        for type in types { labelTypeStatus.remove(type.id) }
        let names = types.compactMap(\.queueName)
        guard !names.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var failures: [(name: String, message: String)] = []
            for name in names {
                do {
                    _ = try await self.serialized {
                        try await CUPSService.removeLabelTypeQueue(name, allowAdminPrompt: true)
                    }
                } catch {
                    failures.append((name, PrinterSession.describe(error)))
                }
            }
            guard let model = self.model, let first = failures.first else { return }
            model.toast(tr("macOS-Drucker nicht entfernt"),
                        message: tr("„%@“ konnte nicht entfernt werden: %@", failures.map(\.name).joined(separator: ", "),
                                    first.message),
                        style: .warning)
        }
    }

    /// Ein Hinweis für neu eingerichtete macOS-Drucker, einer (mit „Erneut versuchen“) für Fehler.
    private func reportLabelTypeResults(_ results: [LabelTypeSyncResult]) {
        guard let model else { return }
        let created = results.flatMap(\.created)
        if created.count == 1 {
            model.toast(tr("macOS-Drucker „%@“ ist eingerichtet.", created[0]),
                        message: tr("Im Druckdialog jedes Programms einfach diesen Drucker wählen."), style: .success)
        } else if created.count > 1 {
            model.toast(tr("%d macOS-Drucker für Etikettentypen eingerichtet.", created.count),
                        message: created.map { "„\($0)“" }.joined(separator: ", "), style: .success)
        }
        let failures = results.flatMap(\.failures)
        guard let first = failures.first else { return }
        let ids = results.filter { !$0.failures.isEmpty }.map(\.printerID)
        let message = failures.count == 1
            ? tr("„%@“ konnte nicht eingerichtet werden: %@", first.description, first.message)
            : tr("%@ konnten nicht eingerichtet werden: %@", failures.map(\.description).joined(separator: ", "),
                 first.message)
        model.toast(tr("macOS-Drucker für Etikettentypen nicht eingerichtet"), message: message, style: .warning,
                    action: ToastAction(title: tr("Erneut versuchen")) { [weak self] in
                        guard let self else { return }
                        Task {
                            for id in ids {
                                guard let session = self.model?.session(for: id) else { continue }
                                await self.syncLabelTypesNow(session, allowAdminPrompt: true)
                            }
                        }
                    })
    }

    // MARK: Übernahme fremder Warteschlangen

    /// Beobachtet das Aktivieren der App und neue bzw. geänderte Druckerverbindungen.
    private func startObserving() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleAdoption() }
            }
        }
        observeSessions()
    }

    /// Meldet hinzugefügte Drucker (`AppModel.addPrinter`) und geänderte Verbindungen; geprüft wird
    /// nur, wenn sich die Verbindungen wirklich geändert haben (``adoptionSignature(_:)``).
    private func observeSessions() {
        guard let model else { return }
        withObservationTracking {
            _ = model.sessions.map(\.saved.descriptor)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSessions()
                self.noteDevicesChanged()
            }
        }
    }

    private func noteDevicesChanged() {
        guard let model, let previous = lastAdoptionSignature else { return }
        guard Self.adoptionSignature(model.sessions) != previous else { return }
        scheduleAdoption()
    }

    /// Verbindungen, über die eine Warteschlange einem Drucker zugeordnet werden kann (Netzwerk, macOS-
    /// Warteschlange).
    static func adoptionSignature(_ sessions: [PrinterSession]) -> [String] {
        sessions.compactMap { session in
            switch session.saved.descriptor {
            case .tcp, .cupsQueue:
                return "\(session.id.uuidString) \(session.saved.descriptor.stableID)"
            case .usb, .bluetooth, .ble, .virtual:
                return nil
            }
        }
    }

    /// Plant eine Prüfung auf fremde Warteschlangen (zusammengefasst nach ``adoptionDebounce``). Vor der
    /// ersten Prüfung nach dem Start geschieht nichts – sie folgt ohnehin.
    func scheduleAdoption() {
        guard launchAdoptionDone else { return }
        adoptionPending?.cancel()
        adoptionPending = Task { [weak self] in
            try? await Task.sleep(for: Self.adoptionDebounce)
            guard !Task.isCancelled, let self else { return }
            self.adoptionPending = nil
            await self.runAdoption()
        }
    }

    /// Eine Prüfung zur Zeit; eine während der Prüfung angeforderte folgt danach.
    private func runAdoption() async {
        guard !isAdopting else {
            adoptionRequested = true
            return
        }
        isAdopting = true
        repeat {
            adoptionRequested = false
            await adoptForeignQueues(allowAdminPrompt: false, only: nil)
        } while adoptionRequested
        isAdopting = false
        if launchAdoptionDone { await restoreMissingLabelTypeQueues() }
    }

    /// Beim Aktivieren der App: Fehlt die Warteschlange eines eingerichteten Etikettentyps (in macOS
    /// entfernt, CUPS zurückgesetzt), legt der Abgleich sie neu an – ein Etikettentyp ist ein macOS-Drucker.
    /// Nur für Typen, deren Warteschlange schon bestand: Fehlgeschlagene versucht erst eine Änderung, ein
    /// Neustart oder „Erneut versuchen“ wieder (sonst bei jedem Aktivieren ein Hinweis).
    private func restoreMissingLabelTypeQueues() async {
        guard let model, CUPSService.isDriverInstalled else { return }
        let candidates = model.sessions.filter { session in
            !session.isVirtual && session.saved.labelTypes.contains { labelTypeStatus.status(for: $0.id).isReady }
        }
        guard !candidates.isEmpty else { return }
        let existing = Set(await CUPSService.queues().map { $0.name.lowercased() })
        guard !existing.isEmpty else { return }
        var results: [LabelTypeSyncResult] = []
        for session in candidates {
            let missing = session.saved.labelTypes.contains { type in
                guard labelTypeStatus.status(for: type.id).isReady, let name = type.queueName else { return false }
                return !existing.contains(name.lowercased())
            }
            if missing { results.append(await syncLabelTypeQueues(session, allowAdminPrompt: false)) }
        }
        reportLabelTypeResults(results)
    }

    /// Stellt fremde Warteschlangen, die zu einem LabelWerk-Drucker führen, auf den LabelWerk-Treiber um
    /// (`QueueAdoption.decide`): Geräte-URI zum Rohdatenport, Modell-PPD mit der Etikettengröße, alle
    /// gespeicherten Einstellungen, Beschreibung = Name des Druckers. Ein Hinweis nennt die
    /// umgestellten, einer (mit „Erneut versuchen“) die fehlgeschlagenen.
    ///
    /// - Parameters:
    ///   - allowAdminPrompt: nur bei „Erneut versuchen“ nach dem Administratorpasswort fragen.
    ///   - only: nur diese Warteschlangen (und auch nach einem Fehlschlag mit unverändertem Stand).
    private func adoptForeignQueues(allowAdminPrompt: Bool, only: Set<String>?) async {
        guard let model else { return }
        let signature = Self.adoptionSignature(model.sessions)
        lastAdoptionSignature = signature
        let sessions = model.sessions.filter { !$0.isVirtual }
        guard !signature.isEmpty, CUPSService.isDriverInstalled else { return }
        let queues = await CUPSService.queues()
        guard !queues.isEmpty else { return }
        let printers = Self.registeredPrinters(sessions, queues: queues)
        guard !printers.isEmpty else { return }
        let labelWerk = await DriverQueueClassifier.labelWerkQueueNames(in: queues)
        let existing = Set(queues.map { $0.name.lowercased() })
        var adopted: [(queue: String, description: String)] = []
        var failures: [(queue: String, error: Error)] = []
        for info in queues {
            if let only, !only.contains(info.name) { continue }
            let decision = QueueAdoption.decide(queueName: info.name, deviceURI: info.deviceURI,
                                                makeAndModel: info.makeAndModel,
                                                isLabelWerk: labelWerk.contains(info.name), printers: printers)
            guard case .adopt(let printerID, let deviceURI) = decision,
                  let id = UUID(uuidString: printerID), let session = model.session(for: id) else { continue }
            let configuration = CUPSService.QueueConfiguration(printer: session.saved, stock: session.stock)
            let attempt = AdoptionAttempt(printerID: id, deviceURI: info.deviceURI, makeAndModel: info.makeAndModel,
                                          configuration: configuration)
            if only == nil, failedAdoptions[info.name] == attempt { continue }
            let hasOtherQueue = Self.queueNames(of: session.saved).contains { name in
                name.caseInsensitiveCompare(info.name) != .orderedSame && existing.contains(name.lowercased())
            }
            let description = QueueAdoption.queueDescription(
                printerName: session.saved.name, modelName: session.model?.displayName,
                host: printers.first { $0.id == printerID }?.host, queueName: info.name,
                printerHasOtherQueue: hasOtherQueue)
            do {
                // `adoptQueue` liest die Warteschlange in der Reihe der `lpadmin`-Aufrufe erneut: Hat eine
                // gleichzeitige Prüfung (Aktivieren der App, „OK“/„Übernehmen“, „Erneut versuchen“) sie
                // nach demselben `lpstat`-Stand schon umgestellt, folgt weder ein zweites `lpadmin` noch
                // ein zweiter Hinweis.
                let changed = try await serialized {
                    try await CUPSService.adoptQueue(info.name, deviceURI: deviceURI, description: description,
                                                     configuration: configuration, allowAdminPrompt: allowAdminPrompt)
                }
                failedAdoptions[info.name] = nil
                guard changed else { continue }
                record(info.name, for: session, existing: existing)
                adopted.append((info.name, description))
            } catch {
                failedAdoptions[info.name] = attempt
                failures.append((info.name, error))
            }
        }
        reportAdoptions(adopted)
        reportAdoptionFailures(failures)
    }

    /// Netzwerkdrucker aus LabelWerk: Host und Port der TCP-Verbindung bzw. der Geräte-URI der
    /// Warteschlange, über die LabelWerk druckt (`ConnectionDescriptor.cupsQueue`).
    static func registeredPrinters(_ sessions: [PrinterSession], queues: [CUPSQueueInfo]) -> [QueueAdoption.RegisteredPrinter] {
        sessions.compactMap { session in
            let id = session.id.uuidString
            switch session.saved.descriptor {
            case .tcp(let host, let port):
                return QueueAdoption.RegisteredPrinter(id: id, host: host, port: port)
            case .cupsQueue(let name):
                guard let queue = queues.first(where: { $0.name == name }) else { return nil }
                return QueueAdoption.registeredPrinter(id: id, queueDeviceURI: queue.deviceURI)
            case .usb, .bluetooth, .ble, .virtual:
                return nil
            }
        }
    }

    /// Merkt sich die übernommene Warteschlange beim Drucker, damit sie wie die verknüpfte auf dem Stand
    /// der Einstellungen bleibt: Ohne (noch vorhandene) verknüpfte Warteschlange wird sie die verknüpfte,
    /// sonst kommt sie zu `adoptedQueueNames`.
    private func record(_ queue: String, for session: PrinterSession, existing: Set<String>) {
        var saved = session.saved
        let linked = saved.cupsQueueName?.trimmingCharacters(in: .whitespaces) ?? ""
        if linked.caseInsensitiveCompare(queue) == .orderedSame { return }
        if linked.isEmpty || !existing.contains(linked.lowercased()) {
            saved.cupsQueueName = queue
            saved.adoptedQueueNames.removeAll { $0.caseInsensitiveCompare(queue) == .orderedSame }
        } else if !saved.adoptedQueueNames.contains(where: { $0.caseInsensitiveCompare(queue) == .orderedSame }) {
            saved.adoptedQueueNames.append(queue)
        }
        session.saved = saved
    }

    /// Ein Hinweis für alle umgestellten Warteschlangen.
    private func reportAdoptions(_ adopted: [(queue: String, description: String)]) {
        guard let model, !adopted.isEmpty else { return }
        if adopted.count == 1 {
            let item = adopted[0]
            let message = item.description == item.queue
                ? nil : tr("Im Druckdialog heißt er jetzt „%@“.", item.description)
            model.toast(tr("macOS-Drucker „%@“ nutzt jetzt den LabelWerk-Treiber.", item.queue), message: message,
                        style: .success)
        } else {
            let names = adopted.map { "„\($0.queue)“" }.joined(separator: ", ")
            model.toast(tr("Die macOS-Drucker %@ nutzen jetzt den LabelWerk-Treiber.", names), style: .success)
        }
    }

    /// Ein Hinweis für alle fehlgeschlagenen Übernahmen, mit „Erneut versuchen“ (dann mit
    /// Passwortabfrage).
    private func reportAdoptionFailures(_ failures: [(queue: String, error: Error)]) {
        guard let model, !failures.isEmpty else { return }
        let names = failures.map(\.queue)
        let detail = PrinterSession.describe(failures[0].error)
        let message = failures.count == 1
            ? tr("„%@“ verwendet weiterhin nicht den LabelWerk-Treiber: %@", names[0], detail)
            : tr("%@ verwenden weiterhin nicht den LabelWerk-Treiber: %@", names.joined(separator: ", "), detail)
        model.toast(tr("macOS-Drucker nicht umgestellt"), message: message, style: .warning,
                    action: ToastAction(title: tr("Erneut versuchen")) { [weak self] in
                        self?.retryAdoption(Set(names))
                    })
    }

    /// „Erneut versuchen“ nach einer fehlgeschlagenen Übernahme (mit Passwortabfrage).
    func retryAdoption(_ queues: Set<String>) {
        Task { [weak self] in
            await self?.adoptForeignQueues(allowAdminPrompt: true, only: queues)
        }
    }
}

// MARK: - Zustand der Typ-Warteschlangen

/// Zustand der macOS-Warteschlange je Etikettentyp (beobachtbar für die Oberfläche).
@Observable
@MainActor
final class LabelTypeQueueStatusStore {
    enum Status: Equatable {
        /// Noch nicht geprüft (kurz nach dem Start bzw. dem Anlegen).
        case pending
        /// Wird angelegt bzw. abgeglichen.
        case syncing
        /// Warteschlange vorhanden und auf dem Stand.
        case ready(String)
        /// Anlegen bzw. Abgleich fehlgeschlagen (Meldung).
        case failed(String)
        /// Für diesen Drucker nicht möglich (Grund).
        case unavailable(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private(set) var statuses: [UUID: Status] = [:]

    func status(for typeID: UUID) -> Status { statuses[typeID] ?? .pending }

    func set(_ status: Status, for typeID: UUID) {
        guard statuses[typeID] != status else { return }
        statuses[typeID] = status
    }

    func remove(_ typeID: UUID) {
        statuses[typeID] = nil
    }
}

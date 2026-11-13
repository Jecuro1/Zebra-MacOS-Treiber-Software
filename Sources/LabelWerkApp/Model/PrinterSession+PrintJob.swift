import AppKit
import Foundation
import SwiftUI
import LabelWerkKit

/// Fortschritt eines Auftrags, der Etikett für Etikett gedruckt wird (`PacedJobSender`): „Etikett 37
/// von 50“, bei Papier leer, Farbband leer oder offenem Druckkopf der Wartegrund. Angezeigt von
/// `PrintJobBanner` im Hauptfenster und im Etikettendruck-Fenster.
struct PrintJobProgress: Identifiable, Equatable {
    let id = UUID()
    var title: String
    /// Fertig gedruckte Etiketten.
    var printed: Int
    /// Etiketten des Auftrags (0 = unbekannt).
    var total: Int
    /// Etikett für Etikett überwacht (sonst in einem Stück gesendet).
    var paced = true
    /// Der Drucker hält an (`nil` = druckt).
    var waiting: PacedJobWaitReason?
    /// Verbindung unterbrochen, LabelWerk verbindet neu.
    var reconnecting = false
    /// „Abbrechen“ gedrückt, `~JA` wird gesendet.
    var isCancelling = false

    /// Gerade gedrucktes Etikett (1-basiert).
    var currentLabel: Int { total > 0 ? min(total, printed + 1) : printed + 1 }

    /// Anteil 0…1 (`nil` bei unbekannter Gesamtzahl).
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(printed) / Double(total))
    }

    /// Statusmeldungen, die während eines Auftrags der Hinweis des Auftrags übernimmt.
    static let coveredAlertKinds: Set<AlertKind> = [.mediaOut, .ribbonOut, .headOpen, .paused, .labelWaitingToBePeeled]

    /// „Etikett 37 von 50“.
    var counterText: String {
        total > 0 ? tr("Etikett %d von %d", currentLabel, total) : tr("Etikett %d", currentLabel)
    }

    /// Kurzbezeichnung eines Wartegrunds.
    static func title(for reason: PacedJobWaitReason) -> String {
        switch reason {
        case .mediaOut: return tr("Papier leer")
        case .ribbonOut: return tr("Farbband leer")
        case .headOpen: return tr("Druckkopf offen")
        case .paused: return tr("Drucker pausiert")
        case .labelWaitingToBePeeled: return tr("Etikett entnehmen")
        case .headTemperature: return tr("Druckkopf zu heiß")
        }
    }

    /// Meldung mit Handlungsanweisung, z. B. „Papier leer – neue Etikettenrolle einlegen. Der Druck geht
    /// danach automatisch weiter.“
    static func message(for reason: PacedJobWaitReason) -> String {
        switch reason {
        case .mediaOut:
            return tr("Papier leer – neue Etikettenrolle einlegen. Der Druck geht danach automatisch weiter.")
        case .ribbonOut:
            return tr("Farbband leer – neues Farbband einlegen. Der Druck geht danach automatisch weiter.")
        case .headOpen:
            return tr("Druckkopf offen – Druckkopf schließen. Der Druck geht danach automatisch weiter.")
        case .paused:
            return tr("Drucker pausiert – zum Fortsetzen die Pause-Taste am Drucker drücken.")
        case .labelWaitingToBePeeled:
            return tr("Etikett entnehmen – der Druck geht danach automatisch weiter.")
        case .headTemperature:
            return tr("Druckkopf zu heiß – der Drucker kühlt ab und druckt danach automatisch weiter.")
        }
    }

    static func systemImage(for reason: PacedJobWaitReason) -> String {
        switch reason {
        case .mediaOut: return "doc.badge.ellipsis"
        case .ribbonOut: return "film"
        case .headOpen: return "printer.dotmatrix"
        case .paused: return "pause.circle.fill"
        case .labelWaitingToBePeeled: return "hand.raised.fill"
        case .headTemperature: return "thermometer.high"
        }
    }
}

/// Ergebnis eines gesendeten Druckauftrags.
enum PrintJobOutcome: Equatable {
    /// Alle Etiketten gedruckt (bzw. bei Versand in einem Stück: übergeben). `uncertain`: davon
    /// möglicherweise fehlende nach einem nicht prüfbaren Verbindungsabbruch (`PacedJobResult.uncertain`).
    case printed(labels: Int, uncertain: Int = 0)
    /// Mit „Abbrechen“ beendet; `~JA` wurde gesendet.
    case cancelled(printed: Int, total: Int)
    /// Fehlgeschlagen (Meldung), bis dahin gedruckte Etiketten.
    case failed(message: String, printed: Int, total: Int)

    var succeeded: Bool {
        if case .printed = self { return true }
        return false
    }

    /// Gedruckte Etiketten (für den Verlauf).
    var printedLabels: Int {
        switch self {
        case .printed(let labels, _): return labels
        case .cancelled(let printed, _), .failed(_, let printed, _): return printed
        }
    }

    /// Meldung für den Verlauf (`nil` bei Erfolg).
    var historyMessage: String? {
        switch self {
        case .printed(_, let uncertain):
            guard uncertain > 0 else { return nil }
            return tr("Nach einem Verbindungsabbruch nicht prüfbar: bis zu %d Etiketten fehlen möglicherweise – bitte nachzählen.", uncertain)
        case .cancelled(let printed, let total):
            return tr("Abgebrochen – %d von %d Etiketten gedruckt.", printed, total)
        case .failed(let message, let printed, let total):
            guard printed > 0 else { return message }
            return tr("%@ (%d von %d Etiketten gedruckt)", message, printed, total)
        }
    }
}

extension PrinterSession {

    /// „Bei Papier- oder Farbbandende anhalten und fortsetzen“ (Druckeinstellungen,
    /// `PrintSettings.resumeAfterError` – dieselbe Einstellung wählt für die macOS-Warteschlangen
    /// `labelwerk://` statt `socket://`) gilt für diesen Drucker: eingeschaltet, ZPL und Verbindung mit
    /// Rückkanal (nicht über eine macOS-Warteschlange).
    var pacesPrintJobs: Bool {
        saved.settings.resumeAfterError && saved.language == .zpl && supportsStatus
    }

    /// Sendet einen fertig kodierten Auftrag und kehrt erst zurück, wenn er gedruckt ist.
    ///
    /// Mit „Bei Papier- oder Farbbandende anhalten und fortsetzen“ (``pacesPrintJobs``) geht er Etikett
    /// für Etikett an den Drucker (`PacedJobSender`): ``printJob`` zeigt „Etikett 37 von 50“, bei Papier
    /// leer, Farbband leer oder offenem Druckkopf wartet der Auftrag und geht nach dem Beheben genau dort
    /// weiter (das unterbrochene Etikett druckt der Drucker selbst erneut, `^JZY`). Läuft die App im
    /// Hintergrund, kommt eine Mitteilung. „Abbrechen“ (``cancelPrintJob()``) leert den Drucker (`~JA`).
    /// Sonst wie bisher in einem Stück (`PrinterClient.sendJob`).
    ///
    /// Aufträge desselben Druckers laufen nacheinander (wie in einer Druckwarteschlange).
    ///
    /// - Parameters:
    ///   - labels: erwartete Etikettenzahl (Anzeige, falls der Auftrag sie nicht selbst liefert).
    ///   - characters: Steuerzeichen des Auftrags (`nil` = erkennen).
    ///   - quiet: Fehler nicht als Hinweis anzeigen (der Aufrufer meldet sie selbst).
    func transmitPrintJob(_ data: Data, title: String, labels: Int, characters: ControlCharacters?,
                          cancelPrefix: Int?, delay: Int, activity: String, quiet: Bool = false) async -> PrintJobOutcome {
        await runPrintJobsInOrder(labels: labels) {
            await self.performPrintJob(data, title: title, labels: labels, characters: characters,
                                       cancelPrefix: cancelPrefix, delay: delay, activity: activity, quiet: quiet)
        }
    }

    /// Bricht den laufenden Auftrag ab (`~JA`); wartende Aufträge folgen danach. Wirkt auch, solange
    /// noch verbunden wird (``performPrintJob`` prüft ``PrintJobProgress/isCancelling`` vor dem Senden).
    func cancelPrintJob() {
        guard var job = printJob, !job.isCancelling else { return }
        job.isCancelling = true
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: app?.reducesMotion ?? false)) { printJob = job }
        printJobTask?.cancel()
    }

    /// Verwirft alle Aufträge, die noch auf das Ende des laufenden warten (sie senden nichts).
    func cancelWaitingPrintJobs() {
        cancelledPrintJobIDs.formUnion(waitingPrintJobIDs)
    }

    // MARK: - Ablauf

    /// Führt Druckaufträge nacheinander aus (der nächste beginnt erst nach dem Ende des vorigen). Ein
    /// wartender Auftrag, den ``cancelWaitingPrintJobs()`` verworfen hat, sendet nichts.
    private func runPrintJobsInOrder(labels: Int,
                                     _ body: @escaping @MainActor () async -> PrintJobOutcome) async -> PrintJobOutcome {
        let previous = printJobTail
        let jobID = UUID()
        if previous != nil {
            queuedPrintJobs += 1
            waitingPrintJobIDs.insert(jobID)
        }
        let job = Task { @MainActor [weak self] () -> PrintJobOutcome in
            await previous?.value
            if previous != nil, let self {
                self.queuedPrintJobs = max(0, self.queuedPrintJobs - 1)
                self.waitingPrintJobIDs.remove(jobID)
                if self.cancelledPrintJobIDs.remove(jobID) != nil {
                    return .cancelled(printed: 0, total: labels)
                }
            }
            return await body()
        }
        let tail = Task<Void, Never> { _ = await job.value }
        printJobTail = tail
        let outcome = await job.value
        if printJobTail == tail { printJobTail = nil }
        return outcome
    }

    private func performPrintJob(_ data: Data, title: String, labels: Int, characters: ControlCharacters?,
                                 cancelPrefix: Int?, delay: Int, activity: String, quiet: Bool) async -> PrintJobOutcome {
        guard pacesPrintJobs else {
            let ok = await withClient(activity, quiet: quiet) { client in
                try await client.sendJob(data, cancelPrefixLength: cancelPrefix, delayMilliseconds: delay)
            } != nil
            return ok ? .printed(labels: labels)
                : .failed(message: lastError ?? tr("Der Drucker hat den Auftrag nicht angenommen."), printed: 0, total: labels)
        }

        let start = PrintJobProgress(title: title, printed: 0, total: labels)
        withAnimation(Motion.animation(Motion.spring, reduceMotion: app?.reducesMotion ?? false)) { printJob = start }
        // Ein Auftrag kann minutenlang auf eine neue Rolle warten: währenddessen weder Ruhezustand noch
        // App Nap, sonst endet die Statusabfrage und die Verbindung bricht ab (cupsd tut dasselbe für
        // Aufträge über die macOS-Warteschlange).
        let keepAwake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: tr("Druckauftrag läuft"))
        defer {
            ProcessInfo.processInfo.endActivity(keepAwake)
            printJobTask = nil
            withAnimation(Motion.animation(Motion.spring, reduceMotion: app?.reducesMotion ?? false)) { printJob = nil }
        }

        let (events, continuation) = AsyncStream<PacedJobEvent>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await event in events { self?.handlePrintJobEvent(event) }
        }
        var failure: String?
        var reachedPrinter = false
        let result: PacedJobResult? = await withClient(activity, quiet: true) { client in
            reachedPrinter = true
            // „Abbrechen“ während des Verbindens: nichts senden.
            if self.printJob?.isCancelling == true { throw CancellationError() }
            let sender = PacedJobSender(client: client)
            let task = Task.detached(priority: .userInitiated) {
                try await sender.send(data, characters: characters, cancelPrefixLength: cancelPrefix,
                                      delayMilliseconds: delay, onEvent: { _ = continuation.yield($0) })
            }
            self.printJobTask = task
            do {
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = Self.describe(error)
                throw error
            }
        }
        continuation.finish()
        await consumer.value

        let job = printJob ?? start
        if let result {
            if result.uncertain > 0, !quiet {
                app?.toast(tr("Bitte nachzählen"),
                           message: tr("Nach einem Verbindungsabbruch nicht prüfbar: bis zu %d Etiketten fehlen möglicherweise – bitte nachzählen.", result.uncertain),
                           style: .warning)
            }
            return .printed(labels: result.total > 0 ? result.total : labels, uncertain: result.uncertain)
        }
        guard reachedPrinter else {
            // Keine Verbindung zustande gekommen (`withClient` ruft die Operation dann nicht auf).
            let message = lastError ?? tr("Der Drucker ist nicht erreichbar.")
            if !quiet { app?.toast(tr("Drucker nicht verbunden"), message: message, style: .error) }
            return .failed(message: message, printed: 0, total: labels)
        }
        if job.isCancelling || failure == nil {
            app?.toast(tr("Druck abgebrochen"),
                       message: tr("Abgebrochen – %d von %d Etiketten gedruckt.", job.printed, job.total), style: .info)
            return .cancelled(printed: job.printed, total: job.total)
        }
        let message = failure ?? lastError ?? tr("Der Drucker hat den Auftrag nicht angenommen.")
        if !quiet {
            app?.toast(tr("Fehler bei „%@“", activity), message: message, style: .error)
        }
        return .failed(message: message, printed: job.printed, total: job.total)
    }

    private func handlePrintJobEvent(_ event: PacedJobEvent) {
        guard var job = printJob else { return }
        let previousReason = job.waiting
        switch event {
        case .started(let total, let paced):
            if total > 0 { job.total = total }
            job.paced = paced
        case .progress(let printed, let total):
            job.printed = printed
            if total > 0 { job.total = total }
        case .waiting(let reason, let printed, _):
            job.printed = printed
            job.waiting = reason
        case .resumed(let printed, _):
            job.printed = printed
            job.waiting = nil
        case .unpaced:
            job.paced = false
        case .connectionLost:
            job.reconnecting = true
        case .reconnected:
            job.reconnecting = false
        case .cancelled(let printed, _):
            job.printed = printed
        case .finished(let printed, let total):
            job.printed = printed
            if total > 0 { job.total = total }
            job.waiting = nil
        case .resumeSent, .resending, .uncertain:
            break
        }
        guard job != printJob else { return }
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: app?.reducesMotion ?? false)) { printJob = job }
        setActivityProgress(job.fraction)
        if let reason = job.waiting, reason != previousReason {
            announceWaiting(reason, job: job)
        }
    }

    /// Ton und – wenn LabelWerk nicht im Vordergrund ist – Mitteilung, sobald ein Auftrag anhält.
    private func announceWaiting(_ reason: PacedJobWaitReason, job: PrintJobProgress) {
        guard let app, reason != .labelWaitingToBePeeled else { return }
        if app.preferences.playSounds, reason.isFault { SoundService.play(.alert) }
        guard app.preferences.notificationsEnabled, !NSApplication.shared.isActive else { return }
        NotificationService.shared.notifyPrintJob(
            title: tr("%@: Druck angehalten", displayName),
            body: PrintJobProgress.message(for: reason) + "\n" + tr("%@ · %@", job.title, job.counterText),
            printerID: id, key: "job-\(reason.rawValue)")
    }
}

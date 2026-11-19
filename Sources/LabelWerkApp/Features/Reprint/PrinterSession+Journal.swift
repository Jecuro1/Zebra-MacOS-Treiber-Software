import AppKit
import Foundation
import LabelWerkKit

/// Druckjournal („Nachdrucken“): eigene Aufträge aufnehmen, Aufträge einem Drucker zuordnen und
/// ausgewählte Etiketten erneut drucken. Layout und Aufbewahrung wie beim CUPS-Backend `labelwerk`
/// (`PrintJournal` in LabelWerkKit, ARCHITECTURE.md §7b „Druckjournal“).
extension PrinterSession {

    /// Nimmt einen ZPL-Auftrag ins Journal der App auf (`~/Library/Application Support/LabelWerk/
    /// Journal/<Drucker>/…`). Schreibfehler stören den Druck nie (der Auftrag fehlt dann nur in
    /// „Nachdrucken“). Aufträge ohne gedrucktes Etikett, die nicht fertig wurden, entfallen.
    func recordInJournal(_ data: Data, characters: ControlCharacters?, title: String, printed: Int,
                         reprinted: Int = 0, status: PrintJournalEntry.Status) {
        guard saved.language == .zpl, printed > 0 || status == .completed else { return }
        let queue = displayName
        let printerID = id
        let uri = saved.descriptor.displayString
        let user = NSUserName()
        let jobID = String(UUID().uuidString.prefix(8)).lowercased()
        let root = PrintJournalStore.shared.appRoot
        Task.detached(priority: .utility) {
            // Fehler (voller Datenträger, fehlende Rechte) bewusst nur übergehen: das Journal ist eine
            // Hilfe, kein Teil des Drucks.
            _ = try? PrintJournal.record(data, characters: characters, queue: queue, jobID: jobID, title: title,
                                         user: user, printerURI: uri, printerID: printerID, printed: printed,
                                         reprinted: reprinted, status: status, in: root)
            await PrintJournalStore.shared.reload()
        }
    }

    /// Namen der macOS-Warteschlangen dieses Druckers (verknüpfte, übernommene, je Etikettentyp) – so
    /// findet „Nachdrucken“ die Aufträge, die andere Programme über sie gedruckt haben.
    var journalQueueNames: Set<String> {
        var names = Set<String>()
        for candidate in [saved.cupsQueueName] + saved.adoptedQueueNames.map(Optional.some)
            + saved.labelTypes.map(\.queueName) {
            guard let name = candidate?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            names.insert(name)
        }
        return names
    }

    /// Gehört der Auftrag zu diesem Drucker? Aufträge der App über die Drucker-ID, Aufträge der
    /// macOS-Warteschlange über deren Namen.
    func journalMatches(_ entry: PrintJournalEntry) -> Bool {
        switch entry.source {
        case .app:
            return entry.printerID == id
        case .system:
            return journalQueueNames.contains(entry.queue)
        }
    }

    /// Druckt die Etiketten `labels` (1-basiert) eines Auftrags aus dem Journal erneut – Etikett für
    /// Etikett mit Warten bei Papier leer usw., wenn „anhalten und fortsetzen“ gilt. Serialisierte Felder
    /// (`^SN`/`^SF`) beginnen wieder beim Startwert ihres Formats. Nachdrucke landen im Verlauf, nicht
    /// noch einmal im Journal.
    @discardableResult
    func reprintFromJournal(_ job: PrintJournalJob, labels: [Int]) async -> Bool {
        guard saved.language == .zpl else {
            app?.toast(tr("Nachdrucken nicht möglich"),
                       message: tr("„%@“ druckt nicht mit ZPL – Aufträge aus dem Druckjournal sind ZPL.", displayName),
                       style: .warning)
            return false
        }
        guard let data = job.reprintData(labels: labels) else {
            app?.toast(tr("Nachdrucken nicht möglich"), message: tr("Keine Etiketten gewählt."), style: .warning)
            return false
        }
        if Self.containsRFIDWrite(data) {
            // Wie „Erneut drucken“ im Verlauf: eine EPC darf nur einmal geschrieben werden.
            app?.toast(tr("Nachdrucken nicht möglich"),
                       message: tr("RFID-Kodieraufträge werden nicht wiederholt – jede EPC darf nur einmal geschrieben werden."),
                       style: .warning)
            return false
        }
        let count = Set(labels).filter { (1...max(1, job.totalLabels)).contains($0) }.count
        let title = tr("Nachdruck: %@", job.entry.displayTitle)
        let outcome = await transmitPrintJob(data, title: title, labels: count, characters: job.plan.characters,
                                             cancelPrefix: nil, delay: 0,
                                             activity: tr("Etiketten werden nachgedruckt …"), journal: false)
        let ok = outcome.succeeded
        let preview: Data?
        if let first = labels.min(), let label = job.labelData(first) {
            preview = await Self.previewPNG(zpl: LabelThumbnail.text(of: label), dotsPerMM: resolution.dotsPerMM)
        } else {
            preview = nil
        }
        recordJob(.zpl, title: title, labels: outcome.printedLabels, bytes: data.count, success: ok,
                  message: outcome.historyMessage, preview: preview, payload: data)
        if ok {
            let message = count == 1 ? tr("1 Etikett auf „%@“ nachgedruckt.", displayName)
                : tr("%d Etiketten auf „%@“ nachgedruckt.", count, displayName)
            app?.toast(tr("Nachgedruckt"), message: message, style: .success)
            if app?.preferences.notificationsEnabled == true, !NSApplication.shared.isActive {
                NotificationService.shared.notifyPrintJob(title: tr("Nachgedruckt"), body: message, printerID: id,
                                                          key: "reprint-\(UUID().uuidString)")
            }
        }
        return ok
    }
}

extension PrintJournalEntry {
    /// Titel zum Anzeigen („Ohne Titel“, wenn das Programm keinen übergeben hat).
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? tr("Ohne Titel") : trimmed
    }
}

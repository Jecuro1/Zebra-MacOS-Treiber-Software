import AppKit
import Foundation
import LabelWerkKit

/// „Nachdrucken“ (Fenster) und „Letztes Etikett nochmal“ (Drucker-Menü, Menüleiste, ⌘⇧L).
extension AppModel {

    /// Zeigt das Fenster „Nachdrucken“ (zuletzt gedruckte Aufträge mit Vorschaubildern).
    func showReprintWindow(printer: PrinterSession? = nil) {
        ReprintWindowController.shared.show(model: self, printerID: printer?.id)
    }

    /// Drucker, dem ein Auftrag aus dem Journal gehört (`nil`, wenn keiner passt).
    func session(forJournal entry: PrintJournalEntry) -> PrinterSession? {
        sessions.first { $0.journalMatches(entry) }
    }

    /// „Letztes Etikett nochmal“: druckt das letzte gedruckte Etikett des neuesten Auftrags im
    /// Druckjournal erneut – für `printer` bzw. ohne Angabe für den gewählten Drucker; ist keiner gewählt,
    /// den Drucker des neuesten Auftrags überhaupt.
    func reprintLastLabel(on printer: PrinterSession? = nil) {
        Task { await performReprintLastLabel(on: printer ?? selectedSession) }
    }

    private func performReprintLastLabel(on printer: PrinterSession?) async {
        let entries = await PrintJournalStore.shared.freshEntries()
        let candidates = entries.filter { $0.printed > 0 || $0.status == .completed }
        var match: (entry: PrintJournalEntry, session: PrinterSession)?
        for entry in candidates {
            if let printer {
                if printer.journalMatches(entry) { match = (entry, printer) }
            } else if let owner = session(forJournal: entry) {
                match = (entry, owner)
            }
            if match != nil { break }
        }
        guard let match else {
            toast(tr("Kein Auftrag zum Nachdrucken"),
                  message: printer.map { tr("Für „%@“ ist noch kein Auftrag im Druckjournal.", $0.displayName) }
                      ?? tr("Im Druckjournal ist noch kein Auftrag eines eingerichteten Druckers."),
                  style: .warning)
            return
        }
        guard let job = await PrintJournalStore.shared.job(for: match.entry), job.totalLabels > 0 else {
            toast(tr("Nachdrucken nicht möglich"), message: tr("Die Druckdaten dieses Auftrags fehlen."), style: .warning)
            return
        }
        // Letztes tatsächlich gedrucktes Etikett (bei einem abgebrochenen Auftrag nicht das letzte des
        // Auftrags).
        let printed = match.entry.printed > 0 ? match.entry.printed : job.totalLabels
        let last = min(job.totalLabels, max(1, printed))
        toast(tr("Letztes Etikett nochmal"),
              message: tr("„%@“, Etikett %d – auf „%@“", match.entry.displayTitle, last, match.session.displayName),
              style: .info)
        await match.session.reprintFromJournal(job, labels: [last])
    }
}

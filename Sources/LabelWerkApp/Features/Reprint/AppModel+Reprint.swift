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
    /// Druckjournal erneut – für `printer` bzw. ohne Angabe (mit `useSelection`) für den im Hauptfenster
    /// gewählten Drucker; ist keiner gewählt oder `useSelection == false` (Menüleiste, deren Menü den
    /// gewählten Drucker nicht zeigt), auf dem Drucker des neuesten Auftrags überhaupt.
    func reprintLastLabel(on printer: PrinterSession? = nil, useSelection: Bool = true) {
        let scope = printer ?? (useSelection ? selectedSession : nil)
        Task { await performReprintLastLabel(on: scope) }
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
        guard let job = await PrintJournalStore.shared.job(for: match.entry), let last = job.lastPrintedLabel else {
            toast(tr("Nachdrucken nicht möglich"), message: tr("Die Druckdaten dieses Auftrags fehlen."), style: .warning)
            return
        }
        // Letztes tatsächlich gedrucktes Etikett (bei einem abgebrochenen Auftrag nicht das letzte des
        // Auftrags; bei mehreren Kopien in der letzten begonnenen Kopie).
        toast(tr("Letztes Etikett nochmal"),
              message: tr("Etikett %d aus „%@“ wird auf „%@“ gedruckt.", last, match.entry.displayTitle,
                          match.session.displayName),
              style: .info)
        await match.session.reprintFromJournal(job, labels: [last])
    }
}

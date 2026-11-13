import AppKit
import Foundation
import Observation
import SwiftUI
import LabelWerkKit

/// Eine Seite im Etikettendruck (über alle geöffneten Dokumente fortlaufend nummeriert).
struct LabelPrintPageRef: Hashable, Sendable {
    var documentID: UUID
    /// Seite im Dokument (0-basiert).
    var page: Int
}

/// Alle Eingaben der Aufbereitung – ändert sich eine, rechnet der Etikettendruck neu.
struct LabelPrintJobKey: Hashable, Sendable {
    /// Fortlaufende Seitennummern (0-basiert) in Druckreihenfolge.
    var pages: [Int]
    var target: LabelPrintTarget
    /// Wechselt, wenn andere Dokumente geöffnet werden.
    var generation: Int
}

/// Zustand des Fensters „Etikettendruck“: geöffnete Dokumente, Seitenauswahl, Drucker und
/// Etikettentyp, aufbereitete Seiten (= Druckdaten) und der Druckvorgang.
@Observable
@MainActor
final class LabelPrintStore {
    enum PageMode: String, CaseIterable, Identifiable {
        case all, selection
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return tr("Alle")
            case .selection: return tr("Auswahl")
            }
        }
    }

    enum PrintPhase: Equatable {
        case idle
        case sending
        case success(PrinterSession.LabelPrintRoute)
        case failure(String)
    }

    @ObservationIgnored weak var model: AppModel?

    private(set) var documents: [LabelPrintDocument] = []
    private(set) var pages: [LabelPrintPageRef] = []
    private(set) var isLoading = false
    private(set) var generation = 0

    /// In der Seitenleiste markierte Seiten (Druck bei „Auswahl“).
    var selection: Set<Int> = []
    /// In der Mitte angezeigte Seite.
    var focusedPage: Int?
    var pageMode: PageMode = .all
    var printerID: UUID? { didSet { if printerID != oldValue { validateLabelType() } } }
    var labelTypeID: UUID?
    var copies = 1
    /// Vergrößerung der Vorschau (1 = ins Fenster eingepasst).
    var zoom: Double = 1
    /// Originalseite statt des Etiketts zeigen (Vergleich).
    var showsOriginal = false

    /// Aufbereitete Seiten des aktuellen Auftrags (Schlüssel: fortlaufende Seitennummer).
    private(set) var rendered: [Int: LabelPrintRenderedPage] = [:]
    /// Schlüssel, für den `rendered` gilt (bzw. gerade berechnet wird).
    private(set) var renderedKey: LabelPrintJobKey?
    private(set) var renderedCount = 0
    private(set) var isRendering = false
    private(set) var printPhase: PrintPhase = .idle
    /// Zählt erfolgreiche Drucke (Animationen).
    private(set) var printSuccessCount = 0

    @ObservationIgnored private var renderToken = 0
    /// Referenz des Auftrags nach jeder aufbereiteten Seite (Position wie `renderedKey.pages`).
    @ObservationIgnored private var referenceTrail: [LabelFit.Reference?] = []
    /// Zuletzt angefragte Dateien (bei mehreren Meldungen desselben Öffnens zusammengefasst) und der
    /// Zeitpunkt der letzten Anfrage.
    @ObservationIgnored private var lastOpened: (urls: [URL], date: Date)?
    /// Zählt Anfragen zum Öffnen (und das Schließen des Fensters): Nur das Laden der letzten Anfrage
    /// zeigt seine Dokumente an.
    @ObservationIgnored private var openGeneration = 0

    /// Innerhalb dieser Zeit gelten bereits angefragte Dateien als dasselbe Öffnen.
    private static let duplicateWindow: TimeInterval = 3
    /// Innerhalb dieser Zeit gehören auch ganz andere Dateien zum selben Öffnen (`onOpenURL` meldet
    /// mehrere Dateien einzeln und unmittelbar nacheinander).
    private static let splitWindow: TimeInterval = 1

    // MARK: Dokumente

    /// Öffnet Dateien (ersetzt die bisherigen). Dasselbe Öffnen kann mehrfach ankommen – vom App-Delegate
    /// alle Dateien auf einmal, über `onOpenURL` je Datei einzeln, in beliebiger Reihenfolge: Bereits
    /// angefragte Dateien werden kurz darauf übergangen, weitere Dateien desselben Öffnens ergänzen die
    /// Anfrage, statt sie zu ersetzen. Nur das Laden der letzten Anfrage kommt an – ein langsames früheres
    /// (großes PDF) überschreibt nie ein späteres oder ein inzwischen geschlossenes Fenster.
    func open(_ urls: [URL]) {
        var requested: [URL] = []
        for url in urls.map(\.standardizedFileURL) where !requested.contains(url) {
            requested.append(url)
        }
        guard !requested.isEmpty else { return }
        let now = Date()
        if let last = lastOpened, now.timeIntervalSince(last.date) < Self.duplicateWindow {
            let new = requested.filter { !last.urls.contains($0) }
            // Alles schon angefragt: dasselbe Öffnen noch einmal gemeldet.
            guard !new.isEmpty else { return }
            // Teil derselben Meldung (überschneidet sich mit der letzten Anfrage oder folgt unmittelbar):
            // ergänzen statt die übrigen Dateien zu verwerfen.
            if new.count < requested.count || now.timeIntervalSince(last.date) < Self.splitWindow {
                requested = last.urls + new
            }
        }
        lastOpened = (requested, now)
        openGeneration += 1
        let generation = openGeneration
        let files = requested
        isLoading = true
        Task {
            var loaded: [LabelPrintDocument] = []
            var failures: [String] = []
            for url in files {
                do {
                    let document = try await Task.detached(priority: .userInitiated) { try LabelPrintDocument.load(url) }.value
                    loaded.append(document)
                } catch {
                    failures.append(PrinterSession.describe(error))
                }
            }
            // Inzwischen andere Dateien angefragt oder Fenster geschlossen: Ergebnis verwerfen.
            guard generation == openGeneration else {
                discardStaleLoad(loaded)
                return
            }
            isLoading = false
            if !failures.isEmpty {
                model?.toast(tr("Datei konnte nicht geöffnet werden"), message: failures.joined(separator: "\n"), style: .error)
            }
            guard !loaded.isEmpty else { return }
            replaceDocuments(with: loaded)
        }
    }

    /// Verworfenes Laden: Kopien aus „Mit LabelWerk drucken“ löschen, die weder angezeigt noch erneut
    /// angefragt sind (eine ergänzte Anfrage lädt dieselbe Datei gerade noch einmal).
    private func discardStaleLoad(_ loaded: [LabelPrintDocument]) {
        let needed = Set(documents.map(\.url)).union(lastOpened?.urls ?? [])
        for document in loaded where !needed.contains(document.url) {
            PDFServiceInstaller.removeIncomingCopy(document.url)
        }
    }

    private func replaceDocuments(with loaded: [LabelPrintDocument]) {
        let previous = documents
        renderToken += 1
        referenceTrail = []
        isRendering = false
        animate {
            documents = loaded
            pages = loaded.flatMap { document in
                (0..<document.pageCount).map { LabelPrintPageRef(documentID: document.id, page: $0) }
            }
            generation += 1
            selection = pages.isEmpty ? [] : [0]
            focusedPage = pages.isEmpty ? nil : 0
            pageMode = .all
            copies = 1
            showsOriginal = false
            printPhase = .idle
            rendered = [:]
            renderedKey = nil
            renderedCount = 0
        }
        chooseInitialTarget()
        // Vorübergehende Kopien aus „Mit LabelWerk drucken“ der vorigen Dokumente entfernen.
        let current = Set(loaded.map(\.url))
        for document in previous where !current.contains(document.url) {
            PDFServiceInstaller.removeIncomingCopy(document.url)
        }
    }

    /// Fenster geschlossen: Dokumente freigeben (Speicher), Kopien aus dem Eingangsordner löschen.
    func closeDocuments() {
        // Laufendes Laden verwerfen (es löscht dann seine Kopien selbst).
        openGeneration += 1
        isLoading = false
        renderToken += 1
        referenceTrail = []
        for document in documents { PDFServiceInstaller.removeIncomingCopy(document.url) }
        documents = []
        pages = []
        selection = []
        focusedPage = nil
        rendered = [:]
        renderedKey = nil
        renderedCount = 0
        isRendering = false
        printPhase = .idle
        lastOpened = nil
    }

    func document(for ref: LabelPrintPageRef) -> LabelPrintDocument? {
        documents.first { $0.id == ref.documentID }
    }

    /// Titel des Auftrags (Verlauf, Fenstertitel).
    var title: String {
        guard let first = documents.first else { return tr("Etikettendruck") }
        if documents.count == 1 { return first.title }
        return tr("%@ und %d weitere", first.title, documents.count - 1)
    }

    // MARK: Ziel

    var sessions: [PrinterSession] { model?.sessions ?? [] }

    var session: PrinterSession? {
        guard let printerID else { return nil }
        return model?.session(for: printerID)
    }

    var labelType: LabelType? {
        guard let labelTypeID, let session else { return nil }
        return session.labelTypes.first { $0.id == labelTypeID }
    }

    /// Aktuelles Ziel (liest Einstellungen und Format live aus der Sitzung).
    var target: LabelPrintTarget? {
        session?.labelPrintTarget(for: labelType)
    }

    /// Seiten, die gedruckt werden (fortlaufende Nummern in Druckreihenfolge).
    var jobPages: [Int] {
        switch pageMode {
        case .all: return Array(pages.indices)
        case .selection: return selection.filter { $0 < pages.count }.sorted()
        }
    }

    var jobKey: LabelPrintJobKey? {
        guard let target, !pages.isEmpty else { return nil }
        let pages = jobPages
        guard !pages.isEmpty else { return nil }
        return LabelPrintJobKey(pages: pages, target: target, generation: generation)
    }

    /// Alle Seiten des Auftrags sind aufbereitet (Drucken möglich).
    var isReady: Bool {
        guard let key = jobKey, renderedKey == key, !isRendering else { return false }
        return key.pages.allSatisfy { rendered[$0] != nil }
    }

    /// Angezeigte Seite: die fokussierte, falls sie gedruckt wird, sonst die erste des Auftrags.
    var displayedPage: Int? {
        let job = jobPages
        if let focusedPage, job.contains(focusedPage) { return focusedPage }
        return job.first
    }

    func select(_ type: LabelType?, of session: PrinterSession) {
        printerID = session.id
        labelTypeID = type?.id
    }

    private func validateLabelType() {
        if let labelTypeID, session?.labelTypes.contains(where: { $0.id == labelTypeID }) != true {
            self.labelTypeID = nil
        }
    }

    /// Wählt Drucker und Etikettentyp beim Öffnen: (1) ein Etikettentyp, dessen Format genau der
    /// Seitengröße entspricht (± 2 mm, auch gedreht), (2) die letzte Wahl für das erzeugende Programm,
    /// (3) die letzte Wahl überhaupt, (4) der ausgewählte bzw. erste Drucker.
    private func chooseInitialTarget() {
        guard let model else { return }
        if let match = sizeMatch() {
            select(match.type, of: match.session)
            return
        }
        let memory = LabelPrintMemory.load()
        let creator = documents.first?.creator
        for choice in [creator.flatMap { memory.byCreator[$0] }, memory.last].compactMap({ $0 }) {
            if let session = model.session(for: choice.printerID),
               choice.labelTypeID == nil || session.labelTypes.contains(where: { $0.id == choice.labelTypeID }) {
                printerID = session.id
                labelTypeID = choice.labelTypeID
                return
            }
        }
        if printerID.flatMap({ model.session(for: $0) }) == nil {
            printerID = (model.selectedSession ?? model.sessions.first)?.id
            labelTypeID = nil
        }
    }

    private func sizeMatch() -> (session: PrinterSession, type: LabelType?)? {
        guard let model, let first = pages.first, let document = document(for: first), document.kind == .pdf,
              let size = document.pageSize(at: first.page, dpi: 203) else { return nil }
        let widthMM = size.width / 72 * 25.4
        let heightMM = size.height / 72 * 25.4
        func matches(_ stock: LabelStock) -> Bool {
            let tolerance = 2.0
            let straight = abs(stock.widthMM - widthMM) <= tolerance && abs(stock.heightMM - heightMM) <= tolerance
            let turned = abs(stock.widthMM - heightMM) <= tolerance && abs(stock.heightMM - widthMM) <= tolerance
            return !stock.isContinuous && (straight || turned)
        }
        // Zuerst der zuletzt benutzte bzw. gewählte Drucker, dann alle übrigen; je Drucker zuerst seine
        // Etikettentypen, dann sein eigenes Format.
        let ordered = model.sessions.filter { $0.id == printerID } + model.sessions.filter { $0.id != printerID }
        for session in ordered {
            if let type = session.labelTypes.first(where: { matches(session.stock(for: $0)) }) {
                return (session, type)
            }
            if matches(session.stock) {
                return (session, nil)
            }
        }
        return nil
    }

    // MARK: Aufbereitung

    /// Bereitet die Seiten von `key` nacheinander auf (Druckreihenfolge, Referenz von Seite zu Seite).
    /// Ergebnisse erscheinen nach und nach; ein neuer Schlüssel verwirft die laufende Berechnung.
    func render(_ key: LabelPrintJobKey) async {
        if renderedKey == key, key.pages.allSatisfy({ rendered[$0] != nil }) { return }
        renderToken += 1
        let token = renderToken
        // Kurz warten: Mehrere Änderungen hintereinander (Auswahl mit ⇧) lösen nur eine Berechnung aus.
        if renderedKey != nil {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard token == renderToken else { return }
        }
        // Gleiches Ziel und gleicher Anfang der Seitenfolge: bereits aufbereitete Seiten bleiben gültig,
        // denn Schritt F einer Seite hängt nur von den Seiten davor ab (Referenz des Auftrags). Die
        // Referenz nach jeder Seite liegt in `referenceTrail`.
        var keep = 0
        if let old = renderedKey, old.target == key.target, old.generation == key.generation {
            while keep < min(old.pages.count, key.pages.count, referenceTrail.count),
                  old.pages[keep] == key.pages[keep], rendered[key.pages[keep]] != nil {
                keep += 1
            }
        }
        var results: [Int: LabelPrintRenderedPage] = [:]
        for index in key.pages.prefix(keep) { results[index] = rendered[index] }
        var reference: LabelFit.Reference? = keep > 0 ? referenceTrail[keep - 1] : nil
        referenceTrail = Array(referenceTrail.prefix(keep))
        let target = key.target
        let encoder = target.encoder
        let dpi = target.resolution.dpi
        let refs = key.pages.map { pages[$0] }
        let documents = Dictionary(uniqueKeysWithValues: self.documents.map { ($0.id, $0) })
        renderedKey = key
        rendered = results
        renderedCount = keep
        isRendering = keep < key.pages.count
        for position in keep..<key.pages.count {
            let index = key.pages[position]
            let ref = refs[position]
            let document = documents[ref.documentID]
            let start = reference
            let output = await Task.detached(priority: .userInitiated) { () -> (LabelPrintRenderedPage, LabelFit.Reference?) in
                var reference = start
                // Nicht darstellbare Seite: leeres Etikett (wie eine leere Seite im Treiber).
                let blank = (image: GrayImage(width: target.labelWidthDots, height: target.labelHeightDots ?? 1),
                             pageSize: PageSizePoints?.none)
                let source = document?.grayPage(at: ref.page, dpi: dpi) ?? blank
                let page = LabelPrintPipeline.render(source.image, pageSize: source.pageSize, target: target,
                                                     encoder: encoder, reference: &reference)
                return (page, reference)
            }.value
            guard token == renderToken else { return }
            reference = output.1
            referenceTrail.append(output.1)
            rendered[index] = output.0
            renderedCount = position + 1
        }
        isRendering = false
    }

    // MARK: Drucken

    /// Etiketten des Auftrags (ohne übersprungene Seiten) mal Exemplare.
    var labelCount: Int {
        guard let key = jobKey, renderedKey == key else { return jobPages.count * max(1, copies) }
        let pages = key.pages.compactMap { rendered[$0] }
        guard pages.count == key.pages.count else { return jobPages.count * max(1, copies) }
        return LabelPrintPipeline.labelCount(pages, copies: copies)
    }

    func printLabels() {
        guard printPhase != .sending, isReady, let key = jobKey, let session else { return }
        let pages = key.pages.compactMap { rendered[$0] }
        let copies = max(1, self.copies)
        let type = labelType
        let target = key.target
        let labels = LabelPrintPipeline.labelCount(pages, copies: copies)
        let title = self.title
        let typeName = type?.name
        let creator = documents.first?.creator
        let preview = pages.first(where: { $0.label != nil })?.label?.toGrayImage()
        animate { printPhase = .sending }
        Task {
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try LabelPrintPipeline.encode(pages, target: target, copies: copies)
                }.value
            } catch {
                let message = PrinterSession.describe(error)
                animate { printPhase = .failure(message) }
                model?.toast(tr("Druckauftrag konnte nicht erzeugt werden"), message: message, style: .error)
                return
            }
            let outcome = await session.printLabelJob(data, target: target, type: type, title: title,
                                                      labels: labels, preview: preview)
            let summary = typeName.map { tr("%d Etiketten · %@", labels, $0) } ?? tr("%d Etiketten", labels)
            switch outcome {
            case .printed(let route):
                animate { printPhase = .success(route) }
                printSuccessCount += 1
                LabelPrintMemory.remember(printerID: session.id, labelTypeID: type?.id, creator: creator)
                switch route {
                case .direct:
                    model?.toast(tr("Gedruckt"), message: summary + " · " + session.displayName, style: .success)
                case .queue(let queue):
                    model?.toast(tr("An macOS-Warteschlange übergeben"),
                                 message: tr("„%@“ war nicht direkt erreichbar. Der Auftrag liegt in der macOS-Warteschlange „%@“ und wird gedruckt, sobald der Drucker erreichbar ist – genau wie in der Vorschau.",
                                             session.displayName, queue),
                                 style: .warning)
                }
            case .failed(let message):
                animate { printPhase = .failure(message) }
                model?.toast(tr("Drucken fehlgeschlagen"), message: message, style: .error)
            case .cancelled(let printed, let total):
                // Den Hinweis „Druck abgebrochen“ zeigt die Druckersitzung.
                animate { printPhase = .failure(tr("Abgebrochen – %d von %d Etiketten gedruckt.", printed, total)) }
            }
            try? await Task.sleep(for: .seconds(2.4))
            if case .sending = printPhase { return }
            animate { printPhase = .idle }
        }
    }

    // MARK: Hilfen

    private func animate(_ changes: () -> Void) {
        if let model {
            model.animate(Motion.spring, changes)
        } else {
            changes()
        }
    }
}

/// Zuletzt gewählter Drucker und Etikettentyp – insgesamt und je erzeugendem Programm (PDF „Creator“,
/// z. B. „Safari“). Eine reine Bequemlichkeit je Benutzer, deshalb in `UserDefaults`.
struct LabelPrintMemory {
    struct Choice: Codable, Hashable {
        var printerID: UUID
        var labelTypeID: UUID?
    }

    var last: Choice?
    var byCreator: [String: Choice] = [:]

    private static let key = "LabelPrint.LastTargets"

    private struct Stored: Codable {
        var last: Choice?
        var byCreator: [String: Choice]?
    }

    static func load() -> LabelPrintMemory {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return LabelPrintMemory() }
        return LabelPrintMemory(last: stored.last, byCreator: stored.byCreator ?? [:])
    }

    static func remember(printerID: UUID, labelTypeID: UUID?, creator: String?) {
        var memory = load()
        let choice = Choice(printerID: printerID, labelTypeID: labelTypeID)
        memory.last = choice
        if let creator, !creator.isEmpty {
            memory.byCreator[creator] = choice
            // Begrenzen: höchstens 50 Programme merken.
            if memory.byCreator.count > 50, let drop = memory.byCreator.keys.first(where: { $0 != creator }) {
                memory.byCreator.removeValue(forKey: drop)
            }
        }
        if let data = try? JSONEncoder().encode(Stored(last: memory.last, byCreator: memory.byCreator)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

import AppKit
import Observation
import SwiftUI
import LabelWerkKit

/// Beide Druckjournale zusammen: das des CUPS-Backends (Aufträge über die macOS-Warteschlangen, auch aus
/// anderen Programmen, `/Users/Shared/LabelWerk/Journal`) und das der App (`~/Library/Application
/// Support/LabelWerk/Journal`). Gelesen wird abseits des Main Threads; „Nachdrucken“ und „Letztes
/// Etikett nochmal“ verwenden diese Liste.
@Observable
@MainActor
final class PrintJournalStore {
    static let shared = PrintJournalStore()

    /// Alle Aufträge, neueste zuerst.
    private(set) var entries: [PrintJournalEntry] = []
    private(set) var isLoading = false
    /// Mindestens einmal gelesen.
    private(set) var hasLoaded = false

    @ObservationIgnored let systemRoot = PrintJournal.systemDirectory()
    @ObservationIgnored let appRoot = PrintJournal.appDirectory()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Zuletzt geladene Aufträge (Formate für Vorschau und Nachdruck), nach Ordner.
    @ObservationIgnored private var loadedJobs: [String: PrintJournalJob] = [:]
    @ObservationIgnored private var loadedOrder: [String] = []

    private init() {}

    /// Liest beide Journale neu (eine laufende Leseoperation wird ersetzt).
    func reload() {
        loadTask?.cancel()
        isLoading = true
        let roots = self.roots
        loadTask = Task { [weak self] in
            let entries = await Task.detached(priority: .utility) { PrintJournal.entries(in: roots) }.value
            guard !Task.isCancelled, let self else { return }
            self.entries = entries
            self.isLoading = false
            self.hasLoaded = true
            // Gelöschte (aufgeräumte) Aufträge aus dem Zwischenspeicher nehmen.
            let ids = Set(entries.map(\.id))
            self.loadedJobs = self.loadedJobs.filter { ids.contains($0.key) }
            self.loadedOrder.removeAll { !ids.contains($0) }
        }
    }

    /// Liest die Journale frisch (ohne die Liste zu ändern) – für „Letztes Etikett nochmal“, das den
    /// wirklich neuesten Auftrag braucht.
    func freshEntries() async -> [PrintJournalEntry] {
        let roots = self.roots
        let entries = await Task.detached(priority: .userInitiated) { PrintJournal.entries(in: roots) }.value
        self.entries = entries
        hasLoaded = true
        return entries
    }

    private var roots: [(url: URL, source: PrintJournalEntry.Source)] {
        [(url: systemRoot, source: .system), (url: appRoot, source: .app)]
    }

    /// Lädt `job.zpl` eines Auftrags (zwischengespeichert, die letzten 12). `nil`, wenn die Datei
    /// inzwischen fehlt.
    func job(for entry: PrintJournalEntry) async -> PrintJournalJob? {
        if let cached = loadedJobs[entry.id] { return cached }
        let loaded = await Task.detached(priority: .userInitiated) { try? entry.load() }.value
        guard let loaded else { return nil }
        loadedJobs[entry.id] = loaded
        loadedOrder.removeAll { $0 == entry.id }
        loadedOrder.append(entry.id)
        while loadedOrder.count > 12 {
            loadedJobs[loadedOrder.removeFirst()] = nil
        }
        return loaded
    }
}

// MARK: - Vorschaubilder

/// Gerenderte Vorschaubilder einzelner Etiketten (Hinweis bei Papier-/Farbbandende, „Nachdrucken“).
/// Gerendert wird abseits des Main Threads, höchstens drei gleichzeitig; gleiche Schlüssel werden nur
/// einmal gerendert.
@MainActor
final class LabelThumbnailCache {
    static let shared = LabelThumbnailCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()
    private var running: [String: Task<CGImage?, Never>] = [:]
    private let gate = RenderGate(limit: 3)

    func cached(_ key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    /// Vorschaubild für `key`; `render` liefert das Graustufenbild (läuft im Hintergrund).
    func image(key: String, render: @escaping @Sendable () -> GrayImage?) async -> CGImage? {
        if let hit = cached(key) { return hit }
        if let task = running[key] { return await task.value }
        let gate = self.gate
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            await gate.enter()
            defer { Task { await gate.leave() } }
            guard !Task.isCancelled, let gray = render() else { return nil }
            return ImageImport.cgImage(from: gray)
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { cache.setObject(Box(image), forKey: key as NSString) }
        return image
    }

    /// Begrenzt gleichzeitige Rendervorgänge.
    private actor RenderGate {
        let limit: Int
        private var active = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func enter() async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func leave() {
            if waiting.isEmpty {
                active = max(0, active - 1)
            } else {
                waiting.removeFirst().resume()
            }
        }
    }
}

/// Ein Etikett als kleines Vorschaubild (Papierweiß mit feinem Rand); lädt beim Erscheinen.
struct LabelThumbnailView: View {
    /// Eindeutiger Schlüssel des Bildes (Auftrag + Etikett bzw. Format).
    let key: String
    /// Seitenverhältnis bis zum Laden (Breite / Höhe).
    var placeholderAspect: CGFloat = 0.66
    let render: @Sendable () -> GrayImage?

    @State private var image: CGImage?
    @State private var failed = false

    init(key: String, placeholderAspect: CGFloat = 0.66, render: @escaping @Sendable () -> GrayImage?) {
        self.key = key
        self.placeholderAspect = placeholderAspect
        self.render = render
        _image = State(initialValue: LabelThumbnailCache.shared.cached(key))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Theme.labelPaper
                    .aspectRatio(placeholderAspect, contentMode: .fit)
                    .overlay {
                        if failed {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .background(Theme.labelPaper)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.cardStroke)
        }
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        .task(id: key) {
            guard image == nil else { return }
            let loaded = await LabelThumbnailCache.shared.image(key: key, render: render)
            image = loaded
            failed = loaded == nil
        }
    }
}

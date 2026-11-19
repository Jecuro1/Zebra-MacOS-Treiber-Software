import AppKit
import Observation
import SwiftUI
import LabelWerkKit

/// Das Fenster „Nachdrucken“ – genau eins, wie „Etikettendruck“ ein AppKit-Fenster mit SwiftUI-Inhalt
/// (erscheint auch, wenn LabelWerk nur in der Menüleiste läuft).
@MainActor
final class ReprintWindowController: NSObject, NSWindowDelegate {
    static let shared = ReprintWindowController()

    let state = ReprintWindowState()
    private var window: NSWindow?

    /// Zeigt das Fenster; mit `printerID` nur die Aufträge dieses Druckers.
    func show(model: AppModel, printerID: UUID?) {
        if let printerID { state.printerFilter = printerID }
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        PrintJournalStore.shared.reload()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let root = ReprintWindowRoot(state: state).environment(model)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = tr("Nachdrucken")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 500)
        window.setContentSize(NSSize(width: 980, height: 660))
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private static let frameName = "LabelWerk.ReprintWindow"
}

/// Auswahl im Fenster „Nachdrucken“.
@Observable
@MainActor
final class ReprintWindowState {
    /// Nur Aufträge dieses Druckers (`nil` = alle).
    var printerFilter: UUID?
    /// Gewählter Auftrag (Ordner, `PrintJournalEntry.id`).
    var selectedEntryID: String?
}

private struct ReprintWindowRoot: View {
    let state: ReprintWindowState
    @Environment(AppModel.self) private var model

    var body: some View {
        ReprintView(state: state, store: PrintJournalStore.shared)
            .frame(minWidth: 760, minHeight: 480)
            .preferredColorScheme(colorScheme)
            .tint(Theme.accent)
            .environment(\.appReduceMotion, model.preferences.reduceMotion)
    }

    private var colorScheme: ColorScheme? {
        switch model.preferences.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Inhalt

/// Links die zuletzt gedruckten Aufträge (nach Tag), rechts die Etiketten des gewählten Auftrags als
/// Vorschaubilder zum Anhaken, darunter Drucker und „Nachdrucken“.
struct ReprintView: View {
    @Bindable var state: ReprintWindowState
    let store: PrintJournalStore

    @Environment(AppModel.self) private var model

    private var filteredEntries: [PrintJournalEntry] {
        guard let printerID = state.printerFilter, let session = model.session(for: printerID) else {
            return store.entries
        }
        return store.entries.filter { session.journalMatches($0) }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        var entries: [PrintJournalEntry]
        var id: Date { day }
    }

    /// Aufträge nach Tag (neueste zuerst).
    private var days: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: entry.date)
            if let last = result.last, last.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(DayGroup(day: day, entries: [entry]))
            }
        }
        return result
    }

    private var selectedEntry: PrintJournalEntry? {
        guard let id = state.selectedEntryID else { return nil }
        return filteredEntries.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider().opacity(0.5)
            Group {
                if let entry = selectedEntry {
                    ReprintDetailView(entry: entry, store: store)
                        .id(entry.id)
                } else if store.hasLoaded, filteredEntries.isEmpty {
                    EmptyStateView(
                        title: tr("Noch nichts gedruckt"),
                        message: tr("Hier erscheinen die zuletzt gedruckten Aufträge – aus LabelWerk und aus anderen Programmen über die macOS-Warteschlange (Geräte-URI labelwerk://). Je Warteschlange bleiben die letzten 30 Aufträge."),
                        systemImage: "arrow.counterclockwise")
                } else {
                    Text(tr("Auftrag wählen"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AnimatedBackground(style: .subtle).ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            ToastOverlay().padding(Theme.Metrics.paddingLarge)
        }
        .overlay(alignment: .top) {
            PrintJobBannerStack()
                .padding(.top, 12)
                .padding(.horizontal, Theme.Metrics.paddingLarge)
        }
        .onAppear { if !store.hasLoaded { store.reload() } }
        .onChange(of: store.entries.map(\.id)) { _, ids in
            // Neuester Auftrag vorgewählt; ein aufgeräumter Auftrag verschwindet aus der Auswahl.
            if let id = state.selectedEntryID, ids.contains(id) { return }
            state.selectedEntryID = filteredEntries.first?.id
        }
        .onChange(of: state.printerFilter) { _, _ in
            if let id = state.selectedEntryID, filteredEntries.contains(where: { $0.id == id }) { return }
            state.selectedEntryID = filteredEntries.first?.id
        }
    }

    // MARK: Liste

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker(tr("Drucker"), selection: $state.printerFilter) {
                    Text(tr("Alle Drucker")).tag(UUID?.none)
                    if !model.sessions.isEmpty { Divider() }
                    ForEach(model.sessions) { session in
                        Text(session.displayName).tag(UUID?.some(session.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer(minLength: 0)
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkPlain)
                .disabled(store.isLoading)
                .help(tr("Liste aktualisieren"))
                .accessibilityLabel(tr("Liste aktualisieren"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 34)

            List(selection: $state.selectedEntryID) {
                ForEach(days) { group in
                    Section(Self.dayTitle(group.day)) {
                        ForEach(group.entries) { entry in
                            ReprintEntryRow(entry: entry, printerName: model.session(forJournal: entry)?.displayName)
                                .tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return tr("Heute") }
        if calendar.isDateInYesterday(day) { return tr("Gestern") }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// Ein Auftrag in der Liste: Vorschau des ersten Etiketts, Titel, Uhrzeit, Drucker, Etiketten.
private struct ReprintEntryRow: View {
    let entry: PrintJournalEntry
    let printerName: String?

    private var detail: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        let where_ = printerName ?? entry.queue
        let labels = entry.totalLabels == 1 ? tr("1 Etikett") : tr("%d Etiketten", entry.totalLabels)
        return [time, where_, labels].joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            LabelThumbnailView(key: entry.id + "#0") {
                guard let job = try? entry.load(), let data = job.labelData(1) else { return nil }
                return LabelThumbnail.render(data, maxSide: 90)
            }
            .frame(width: 34, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.status != .completed {
                Image(systemName: entry.status == .cancelled ? "xmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.status == .cancelled ? Color.secondary : Theme.warning)
                    .help(entry.status == .cancelled ? tr("Abgebrochen") : tr("Fehlgeschlagen"))
            }
        }
        .padding(.vertical, 2)
        .help(entry.source == .system ? tr("Über die macOS-Warteschlange „%@“ gedruckt", entry.queue)
                                      : tr("Aus LabelWerk gedruckt"))
    }
}

// MARK: - Auftrag

/// Etiketten eines Auftrags zum Anhaken, Drucker und „Nachdrucken“.
private struct ReprintDetailView: View {
    let entry: PrintJournalEntry
    let store: PrintJournalStore

    @Environment(AppModel.self) private var model
    @State private var job: PrintJournalJob?
    @State private var missing = false
    @State private var selection: Set<Int> = []
    @State private var targetID: UUID?
    @State private var isSending = false

    /// Höchstens so viele Etiketten werden als Vorschau angeboten (die letzten).
    private static let maxShown = 300

    private var owner: PrinterSession? { model.session(forJournal: entry) }

    private var target: PrinterSession? {
        targetID.flatMap { model.session(for: $0) } ?? owner
    }

    private var shownLabels: [Int] {
        guard let job else { return [] }
        let total = job.totalLabels
        return Array(max(1, total - Self.maxShown + 1)...max(1, total)).filter { $0 <= total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.Metrics.paddingLarge)
                .padding(.top, 34)
                .padding(.bottom, 12)
            Divider().opacity(0.5)
            Group {
                if let job {
                    grid(job)
                } else if missing {
                    Text(tr("Die Druckdaten dieses Auftrags fehlen."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider().opacity(0.5)
            footer
                .padding(.horizontal, Theme.Metrics.paddingLarge)
                .padding(.vertical, 12)
        }
        .task(id: entry.id) {
            job = await store.job(for: entry)
            missing = job == nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayTitle)
                .font(Theme.Typography.headline)
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let status = statusText {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.status == .failed ? Theme.warning : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let date = entry.date.formatted(date: .abbreviated, time: .shortened)
        let origin = entry.source == .system ? tr("macOS-Warteschlange „%@“", entry.queue)
                                             : (owner?.displayName ?? entry.queue)
        var parts = [date, origin]
        if !entry.user.isEmpty { parts.append(entry.user) }
        return parts.joined(separator: " · ")
    }

    private var statusText: String? {
        switch entry.status {
        case .completed:
            return entry.reprinted > 0 ? tr("Nach Papier- oder Farbbandende %d nachgedruckt.", entry.reprinted) : nil
        case .cancelled:
            return tr("Abgebrochen – %d von %d Etiketten gedruckt.", entry.printed, entry.totalLabels)
        case .failed:
            return tr("Fehlgeschlagen – %d von %d Etiketten gedruckt.", entry.printed, entry.totalLabels)
        }
    }

    private func grid(_ job: PrintJournalJob) -> some View {
        let dotsPerMM = (target ?? owner)?.resolution.dotsPerMM ?? 8
        let width = (target ?? owner)?.labelWidthDots ?? 812
        let height = (target ?? owner)?.labelHeightDots ?? 1218
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)], spacing: 14) {
                ForEach(shownLabels, id: \.self) { number in
                    ReprintLabelCell(
                        number: number,
                        // Exemplare desselben Formats (^PQ) teilen sich ein Vorschaubild.
                        key: entry.id + "#\(job.plan.location(ofLabel: number)?.segment ?? number)",
                        selected: selection.contains(number),
                        aspect: CGFloat(max(1, width)) / CGFloat(max(1, height)),
                        render: {
                            job.labelData(number).flatMap {
                                LabelThumbnail.render($0, dotsPerMM: dotsPerMM, widthDots: width, heightDots: height)
                            }
                        },
                        toggle: {
                            if selection.contains(number) { selection.remove(number) } else { selection.insert(number) }
                        })
                }
            }
            .padding(Theme.Metrics.paddingLarge)
            if job.totalLabels > Self.maxShown {
                Text(tr("Gezeigt werden die letzten %d von %d Etiketten.", Self.maxShown, job.totalLabels))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(tr("Letztes")) {
                if let job { selection = [min(job.totalLabels, max(1, entry.printed > 0 ? entry.printed : job.totalLabels))] }
            }
            .buttonStyle(.link)
            .help(tr("Nur das zuletzt gedruckte Etikett wählen"))
            Button(tr("Alle")) { selection = Set(shownLabels) }
                .buttonStyle(.link)
            Button(tr("Keins")) { selection = [] }
                .buttonStyle(.link)
                .disabled(selection.isEmpty)
            Spacer(minLength: 8)
            Picker(tr("Drucker"), selection: Binding(get: { target?.id }, set: { targetID = $0 })) {
                ForEach(model.sessions.filter { $0.saved.language == .zpl }) { session in
                    Text(session.displayName).tag(UUID?.some(session.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            Button {
                send()
            } label: {
                Text(selection.count <= 1 ? tr("Nachdrucken") : tr("%d nachdrucken", selection.count))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty || target == nil || job == nil || isSending)
        }
        .font(.system(size: 12))
    }

    private func send() {
        guard let job, let target, !selection.isEmpty else { return }
        let labels = selection.sorted()
        isSending = true
        Task {
            await target.reprintFromJournal(job, labels: labels)
            isSending = false
        }
    }
}

/// Ein Etikett mit Nummer und Häkchen.
private struct ReprintLabelCell: View {
    let number: Int
    let key: String
    let selected: Bool
    let aspect: CGFloat
    let render: @Sendable () -> GrayImage?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 6) {
                LabelThumbnailView(key: key, placeholderAspect: aspect, render: render)
                    .frame(height: 120)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Theme.accent.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accent)
                                .offset(x: 6, y: -6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(tr("Nr. %d", number))
                    .font(.system(size: 11, weight: selected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: selected)
        .accessibilityLabel(tr("Etikett %d", number))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

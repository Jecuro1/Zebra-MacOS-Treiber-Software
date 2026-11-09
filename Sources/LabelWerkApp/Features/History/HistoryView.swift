import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// Auftragsverlauf: Kennzahlen, Filter, Suche, Vorschau und „Erneut drucken“.
struct HistoryView: View {
    let printerID: UUID?

    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var kindFilter: JobRecord.Kind?
    @State private var printerFilter: UUID?
    @State private var onlyFailures = false
    @State private var selectedJob: JobRecord.ID?
    @State private var confirmClear = false

    init(printerID: UUID?) {
        self.printerID = printerID
    }

    private var effectivePrinter: UUID? { printerID ?? printerFilter }

    private var filtered: [JobRecord] {
        model.history.filter { job in
            if let effectivePrinter, job.printerID != effectivePrinter { return false }
            if let kindFilter, job.kind != kindFilter { return false }
            if onlyFailures && job.success { return false }
            if !search.isEmpty {
                let needle = search.lowercased()
                return job.title.lowercased().contains(needle)
                    || job.printerName.lowercased().contains(needle)
                    || (job.message?.lowercased().contains(needle) ?? false)
            }
            return true
        }
    }

    private var groupedByDay: [(day: Date, jobs: [JobRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                    header
                    statistics
                    filterBar
                    if filtered.isEmpty {
                        EmptyStateView(
                            title: model.history.isEmpty ? tr("Noch keine Aufträge") : tr("Keine Treffer"),
                            message: model.history.isEmpty
                                ? tr("Gedruckte Etiketten, Gerätebefehle und Übertragungen erscheinen hier – mit Vorschau und der Möglichkeit, sie erneut zu drucken.")
                                : tr("Passe Suche oder Filter an."),
                            systemImage: "clock.arrow.circlepath"
                        )
                        .frame(minHeight: 320)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                            ForEach(groupedByDay, id: \.day) { group in
                                Section {
                                    VStack(spacing: 8) {
                                        ForEach(group.jobs) { job in
                                            JobRow(job: job, isSelected: selectedJob == job.id,
                                                   reprint: { reprint(job) },
                                                   select: { withAnimation(Motion.snappy) { selectedJob = selectedJob == job.id ? nil : job.id } })
                                                .transition(.opacity.combined(with: .move(edge: .top)))
                                        }
                                    }
                                } header: {
                                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                            }
                        }
                        .animation(Motion.spring, value: filtered.map(\.id))
                    }
                }
                .padding(Theme.Metrics.paddingLarge)
                .frame(maxWidth: Theme.Metrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .background { if printerID == nil { AnimatedBackground(style: .subtle).ignoresSafeArea() } }
        .navigationTitle(tr("Auftragsverlauf"))
        .searchable(text: $search, placement: .toolbar, prompt: Text(tr("Aufträge durchsuchen")))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportCSV()
                } label: {
                    Label(tr("Als CSV exportieren"), systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label(tr("Verlauf leeren"), systemImage: "trash")
                }
                .disabled(model.history.isEmpty)
            }
        }
        .confirmationDialog(tr("Verlauf leeren?"), isPresented: $confirmClear) {
            Button(tr("Leeren"), role: .destructive) { model.clearHistory(printerID: printerID) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Alle Einträge und gespeicherten Druckdaten werden gelöscht."))
        }
    }

    // MARK: Abschnitte

    private var header: some View {
        SectionHeader(tr("Auftragsverlauf"),
                      subtitle: tr("Alle Druckaufträge und Gerätebefehle der letzten Zeit"),
                      systemImage: "clock.arrow.circlepath")
    }

    private var statistics: some View {
        let jobs = filtered
        let labels = jobs.filter(\.success).reduce(0) { $0 + $1.labels }
        let bytes = jobs.reduce(0) { $0 + $1.bytes }
        let successRate = jobs.isEmpty ? 1 : Double(jobs.filter(\.success).count) / Double(jobs.count)
        let perDay = labelsPerDay(jobs)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Metrics.cardSpacing)],
                         spacing: Theme.Metrics.cardSpacing) {
            MetricTile(title: tr("Gedruckte Etiketten"), value: labels.formatted(), systemImage: "square.stack.3d.up.fill",
                       tint: Theme.violet, trend: perDay.count > 1 ? perDay : nil)
            MetricTile(title: tr("Aufträge"), value: jobs.count.formatted(), systemImage: "list.bullet.rectangle",
                       tint: Theme.teal)
            MetricTile(title: tr("Übertragene Daten"),
                       value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                       systemImage: "arrow.up.arrow.down", tint: Theme.printing)
            MetricTile(title: tr("Erfolgsquote"), value: successRate.formatted(.percent.precision(.fractionLength(0))),
                       systemImage: "checkmark.seal.fill", tint: successRate > 0.95 ? Theme.ready : Theme.warning)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker(selection: $kindFilter) {
                Text(tr("Alle Arten")).tag(JobRecord.Kind?.none)
                Divider()
                ForEach(JobRecord.Kind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(JobRecord.Kind?.some(kind))
                }
            } label: {
                Label(tr("Art"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .frame(maxWidth: 220)

            if printerID == nil {
                Picker(selection: $printerFilter) {
                    Text(tr("Alle Drucker")).tag(UUID?.none)
                    Divider()
                    ForEach(model.sessions) { session in
                        Text(session.displayName).tag(UUID?.some(session.id))
                    }
                } label: {
                    Label(tr("Drucker"), systemImage: "printer")
                }
                .frame(maxWidth: 240)
            }

            Toggle(isOn: $onlyFailures.animation(Motion.spring)) {
                Label(tr("Nur Fehler"), systemImage: "exclamationmark.triangle")
            }
            .toggleStyle(.button)

            Spacer()
            Text(tr("%d Einträge", filtered.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    // MARK: Aktionen

    private func labelsPerDay(_ jobs: [JobRecord]) -> [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<14).reversed().map { offset -> Double in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return 0 }
            return Double(jobs.filter { $0.success && calendar.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.labels })
        }
    }

    private func reprint(_ job: JobRecord) {
        guard let session = model.session(for: job.printerID) ?? model.selectedSession else {
            model.toast(tr("Drucker nicht gefunden"), message: tr("Der ursprüngliche Drucker ist nicht mehr eingerichtet."), style: .warning)
            return
        }
        Task { await session.reprint(job) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "LabelWerk-Verlauf.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Datum;Drucker;Titel;Art;Etiketten;Bytes;Erfolg;Meldung\n"
        for job in filtered {
            csv += [formatter.string(from: job.date), esc(job.printerName), esc(job.title), esc(job.kind.displayName),
                    String(job.labels), String(job.bytes), job.success ? "ja" : "nein", esc(job.message ?? "")]
                .joined(separator: ";") + "\n"
        }
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            model.toast(tr("Verlauf exportiert"), message: url.lastPathComponent, style: .success)
        } catch {
            model.toast(tr("Export fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }
}

/// Eine Zeile im Verlauf, aufklappbar mit Vorschau und Details.
private struct JobRow: View {
    let job: JobRecord
    let isSelected: Bool
    let reprint: () -> Void
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        GlassCard(padding: 12, cornerRadius: 14, tint: job.success ? nil : Theme.error) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(systemImage: job.kind.systemImage, tint: job.success ? Theme.violet : Theme.error, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("\(job.printerName) · \(job.kind.displayName) · \(job.date.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if job.labels > 0 {
                        Text(tr("%d Etiketten", job.labels))
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.subtleFill, in: Capsule())
                    }
                    Image(systemName: job.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(job.success ? Theme.ready : Theme.error)
                    if job.payload != nil {
                        Button(action: reprint) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 18))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .opacity(hovering || isSelected ? 1 : 0.35)
                        .help(tr("Erneut drucken"))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isSelected ? 180 : 0))
                }
                if isSelected {
                    HStack(alignment: .top, spacing: 16) {
                        if let data = job.previewPNG, let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 160, maxHeight: 200)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            KeyValueRow(tr("Zeitpunkt"), job.date.formatted(date: .abbreviated, time: .standard))
                            KeyValueRow(tr("Datenmenge"), ByteCountFormatter.string(fromByteCount: Int64(job.bytes), countStyle: .file))
                            KeyValueRow(tr("Status"), job.success ? tr("Erfolgreich") : tr("Fehlgeschlagen"))
                            if let message = job.message, !message.isEmpty {
                                KeyValueRow(tr("Meldung"), message)
                            }
                            if job.payload != nil {
                                Button(action: reprint) {
                                    Label(tr("Erneut drucken"), systemImage: "printer")
                                }
                                .buttonStyle(.labelWerkSecondary)
                                .padding(.top, 6)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(Motion.spring, value: isSelected)
        .contextMenu {
            if job.payload != nil {
                Button(tr("Erneut drucken"), action: reprint)
            }
            Button(tr("Titel kopieren")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.title, forType: .string)
            }
        }
    }
}

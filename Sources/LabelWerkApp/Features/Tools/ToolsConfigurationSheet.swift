import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

private struct ConfigurationRow: Identifiable, Hashable {
    let id: Int
    let name: String
    let value: String
}

/// Druckerkonfiguration (`^HH`) als durchsuchbare Liste mit Kopieren und Textexport –
/// der Inhalt des Konfigurationsetiketts, ohne Etiketten zu verbrauchen.
struct ToolsConfigurationSheet: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var rows: [ConfigurationRow] = []
    @State private var isLoading = true
    @State private var readAt: Date?
    @State private var query = ""
    @State private var copiedAll = false
    @State private var revealed = false

    init(session: PrinterSession) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var filtered: [ConfigurationRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle)
        }
    }

    private var subtitle: String {
        if let readAt {
            return tr("%@ · gelesen um %@", session.displayName, readAt.formatted(date: .omitted, time: .standard))
        }
        return session.displayName
    }

    private var countText: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tr("%d Einträge", rows.count)
        }
        return tr("%d von %d Einträgen", filtered.count, rows.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolsSheetHeader(title: tr("Druckerkonfiguration"), subtitle: subtitle,
                             systemImage: "list.bullet.rectangle.portrait", tint: Theme.printing) {
                HStack(spacing: 8) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label(tr("Neu lesen"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(isLoading)

                    Button {
                        copyAll()
                    } label: {
                        Label(copiedAll ? tr("Kopiert") : tr("Alles kopieren"),
                              systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(rows.isEmpty)

                    Button {
                        exportText()
                    } label: {
                        Label(tr("Exportieren …"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .disabled(rows.isEmpty)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.labelWerkPlain)
                    .keyboardShortcut(.cancelAction)
                    .help(tr("Schließen"))
                }
            }

            HStack(spacing: 12) {
                ToolsSearchField(text: $query, prompt: tr("Name oder Wert suchen"), reduceMotion: reduceMotion)
                Text(countText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: filtered.count)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(22)
        .frame(minWidth: 700, idealWidth: 800, minHeight: 540, idealHeight: 680)
        .task { await load() }
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        if isLoading && rows.isEmpty {
            loadingSkeleton
                .transition(.opacity)
        } else if rows.isEmpty {
            EmptyStateView(
                title: tr("Keine Konfiguration erhalten"),
                message: tr("Der Drucker hat auf die Konfigurationsabfrage nicht geantwortet. Prüfe Verbindung und Druckersprache und versuche es erneut."),
                systemImage: "list.bullet.rectangle.portrait",
                actionTitle: tr("Erneut lesen"),
                action: { Task { await load() } }
            )
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                Text(tr("Keine Treffer für „%@“", query))
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, row in
                        ConfigurationRowView(row: row, query: query, striped: index.isMultiple(of: 2),
                                             reduceMotion: reduceMotion)
                            .opacity(revealed ? 1 : 0)
                            .offset(y: revealed || reduceMotion ? 0 : 6)
                            .animation(reduceMotion ? nil : Motion.spring.delay(Double(min(index, 24)) * 0.012),
                                       value: revealed)
                    }
                }
                .padding(6)
            }
            .labelWerkGlass(cornerRadius: 12)
            .overlay(alignment: .topTrailing) {
                if isLoading {
                    ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                        .padding(10)
                        .transition(.opacity)
                }
            }
        }
    }

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.subtleFill.opacity(2.2))
                        .frame(width: CGFloat(110 + (index * 37) % 120), height: 11)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.subtleFill.opacity(2.2))
                        .frame(width: CGFloat(50 + (index * 53) % 110), height: 11)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Spacer(minLength: 0)
        }
        .shimmering(active: !reduceMotion)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .labelWerkGlass(cornerRadius: 12)
        .overlay {
            VStack(spacing: 10) {
                ProgressRing(progress: nil, size: 30)
                Text(tr("Konfiguration wird gelesen …"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .labelWerkGlass(cornerRadius: 14)
        }
    }

    // MARK: Aktionen

    private func load() async {
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { isLoading = true }
        let entries = await session.configuration()
        let newRows = entries.enumerated().map { offset, entry in
            ConfigurationRow(id: offset, name: entry.name, value: entry.value)
        }
        revealed = false
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            rows = newRows
            isLoading = false
            if !newRows.isEmpty { readAt = Date() }
        }
        // Erst nach dem Einfügen aufdecken, damit die Zeilen gestaffelt erscheinen.
        try? await Task.sleep(for: .milliseconds(40))
        revealed = true
    }

    private var exportedText: String {
        let width = min(44, rows.map { $0.name.count }.max() ?? 0)
        var lines: [String] = []
        lines.append(tr("Druckerkonfiguration – %@", session.displayName))
        if let printerModel = session.model {
            lines.append(printerModel.displayName)
        }
        lines.append(tr("Gelesen: %@", (readAt ?? Date()).formatted(date: .abbreviated, time: .standard)))
        lines.append("")
        for row in rows {
            let padded = row.name.padding(toLength: max(width, row.name.count), withPad: " ", startingAt: 0)
            lines.append(padded + "  " + row.value)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func copyAll() {
        ToolsFileExport.copy(exportedText)
        let animation = Motion.animation(Motion.snappy, reduceMotion: reduceMotion)
        withAnimation(animation) { copiedAll = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(animation) { copiedAll = false }
        }
    }

    private func exportText() {
        let fileName = ToolsFileExport.safeFileName(tr("Konfiguration %@", session.displayName)) + ".txt"
        do {
            if let url = try ToolsFileExport.save(Data(exportedText.utf8), suggestedName: fileName,
                                                  contentType: .plainText) {
                model.toast(tr("Konfiguration exportiert"), message: url.lastPathComponent, style: .success)
            }
        } catch {
            model.toast(tr("Export fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Zeile

private struct ConfigurationRowView: View {
    let row: ConfigurationRow
    let query: String
    let striped: Bool
    let reduceMotion: Bool

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(ToolsHighlight.attributed(row.name, query: query))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 260, alignment: .leading)
            Text(ToolsHighlight.attributed(row.value.isEmpty ? "–" : row.value, query: query))
                .font(Theme.Typography.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(row.value)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Theme.ready : Color.secondary)
            .opacity(hovering || copied ? 1 : 0)
            .help(tr("Wert kopieren"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.accent.opacity(0.1) : (striped ? Theme.subtleFill : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .contextMenu {
            Button(tr("Wert kopieren")) { copy(row.value) }
            Button(tr("Name kopieren")) { copy(row.name) }
            Button(tr("Zeile kopieren")) { copy(row.name + ": " + row.value) }
        }
    }

    private func copy(_ text: String) {
        ToolsFileExport.copy(text)
        let animation = Motion.animation(Motion.snappy, reduceMotion: reduceMotion)
        withAnimation(animation) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(animation) { copied = false }
        }
    }
}

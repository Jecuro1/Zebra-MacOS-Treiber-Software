import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Texte und Zustände für die Oberfläche

extension UpdateController {
    /// Grober Zustand ohne Fortschrittswert – für Animationen (ändert sich nicht bei jedem Prozent).
    var phaseKey: String {
        switch state {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .available: return "available"
        case .downloading: return installWhenReady ? "downloadingThenInstall" : "downloading"
        case .readyToInstall: return "ready"
        case .installing: return "installing"
        case .failed: return "failed"
        }
    }

    /// Beschriftung der Hauptschaltfläche („Jetzt installieren“ …).
    var installButtonTitle: String {
        switch state {
        case .downloading: return installWhenReady ? tr("Wird geladen …") : tr("Jetzt installieren")
        case .installing: return tr("Wird installiert …")
        case .failed: return tr("Erneut versuchen")
        default: return tr("Jetzt installieren")
        }
    }

    /// Hauptschaltfläche bedienbar?
    var canInstall: Bool {
        guard update != nil else { return false }
        switch state {
        case .installing: return false
        case .downloading: return !installWhenReady
        default: return true
        }
    }

    /// Fortschritt bzw. Eckdaten des gefundenen Updates in einer Zeile.
    var progressText: String {
        switch state {
        case .downloading(_, let fraction):
            return tr("Wird geladen … %d %%", Int((fraction * 100).rounded(.down)))
        case .readyToInstall:
            return tr("Geladen und geprüft – die Installation dauert nur einen Moment.")
        case .installing:
            return tr("Wird installiert … macOS fragt nach dem Administratorpasswort.")
        case .failed(let message):
            return message
        default:
            guard let update else { return statusText }
            return Self.facts(of: update)
        }
    }

    /// „Veröffentlicht am 10.11.2026 · 46,2 MB“.
    static func facts(of update: AvailableUpdate) -> String {
        let date = update.manifest.publishedAt.formatted(date: .abbreviated, time: .omitted)
        let size = ByteCountFormatter.string(fromByteCount: Int64(update.manifest.pkg.size), countStyle: .file)
        return tr("Veröffentlicht am %@ · %@", date, size)
    }
}

/// Symbol bzw. Fortschrittsring zum aktuellen Zustand des Update-Dienstes.
struct UpdateStatusSymbol: View {
    let updates: UpdateController
    var size: CGFloat = 26

    var body: some View {
        Group {
            switch updates.state {
            case .checking:
                ProgressRing(progress: nil, size: size, lineWidth: max(2.5, size / 9))
            case .downloading(_, let fraction):
                ProgressRing(progress: fraction, size: size, lineWidth: max(2.5, size / 9))
            case .installing:
                ProgressRing(progress: nil, size: size, lineWidth: max(2.5, size / 9))
            case .readyToInstall:
                symbol("checkmark.seal.fill", Theme.ready)
            case .available:
                symbol("arrow.down.circle.fill", Theme.violet)
            case .upToDate:
                symbol("checkmark.circle.fill", Theme.ready)
            case .failed:
                symbol("exclamationmark.triangle.fill", Theme.warning)
            case .idle:
                if updates.isChecking {
                    ProgressRing(progress: nil, size: size, lineWidth: max(2.5, size / 9))
                } else {
                    symbol("arrow.triangle.2.circlepath", .secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .transition(.scale.combined(with: .opacity))
    }

    private func symbol(_ name: String, _ style: some ShapeStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.8, weight: .semibold))
            .foregroundStyle(style)
    }
}

// MARK: - Hinweis im Hauptfenster

/// Hinweis „Update verfügbar“ unten rechts im Hauptfenster (über den Toasts): Jetzt installieren,
/// Details, Später. Zeigt beim Laden den Fortschritt und nach Fehlern den Grund.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var hovering = false

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        let updates: UpdateController = model.updates
        if let update = updates.update {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if updates.isDownloading || updates.isInstalling {
                        UpdateStatusSymbol(updates: updates, size: 30)
                    } else {
                        IconBadge(systemImage: "arrow.down.circle", tint: Theme.violet, size: 30)
                            .symbolEffect(.bounce, value: reduceMotion ? "" : update.id)
                    }
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Update verfügbar: LabelWerk %@", update.manifest.appVersion.description))
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(updates.progressText)
                        .font(.system(size: 12))
                        .foregroundStyle(updates.failureMessage != nil ? Theme.error : Color.secondary)
                        .lineLimit(4)
                        .contentTransition(.numericText())
                    HStack(spacing: 6) {
                        Button(updates.installButtonTitle) { updates.downloadAndInstall() }
                            .buttonStyle(.labelWerkPrimary)
                            .disabled(!updates.canInstall)
                        Button(tr("Details")) { updates.showDetails() }
                            .buttonStyle(.labelWerkSecondary)
                        Button(tr("Später")) { updates.dismissBanner() }
                            .buttonStyle(.labelWerkPlain)
                            .disabled(updates.isInstalling)
                    }
                    .controlSize(.small)
                    .padding(.top, 5)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 380, alignment: .leading)
            .labelWerkGlass(cornerRadius: 16, tint: Theme.violet)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.brandGradient).frame(width: 3).padding(.vertical, 12).padding(.leading, 4)
            }
            .scaleEffect(hovering && !reduceMotion ? 1.01 : 1)
            .onHover { hovering = $0 }
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: updates.phaseKey)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tr("Update verfügbar: LabelWerk %@", update.manifest.appVersion.description))
        }
    }
}

// MARK: - Details

/// Details eines Updates (Sheet im Hauptfenster): Version, Änderungen, Fortschritt sowie
/// „Jetzt installieren“, „Später“ und „Diese Version überspringen“.
struct UpdateDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var appeared = false

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        let updates: UpdateController = model.updates
        VStack(spacing: 0) {
            if let update = updates.update {
                header(update, updates: updates)
                Divider().opacity(0.5)
                ScrollView {
                    ReleaseNotesView(markdown: update.manifest.notes)
                        .padding(.horizontal, Theme.Metrics.paddingLarge)
                        .padding(.vertical, Theme.Metrics.padding)
                }
                .frame(height: 230)
                Divider().opacity(0.5)
                status(updates)
                footer(updates)
            } else {
                upToDate(updates)
            }
        }
        .frame(width: 580)
        .background(AnimatedBackground(style: .subtle))
        .interactiveDismissDisabled(updates.isInstalling)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: updates.phaseKey)
        .onAppear {
            withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) { appeared = true }
        }
    }

    private func header(_ update: AvailableUpdate, updates: UpdateController) -> some View {
        HStack(alignment: .center, spacing: 16) {
            IconBadge(systemImage: "arrow.down.circle", tint: Theme.violet, size: 58)
                .scaleEffect(appeared ? 1 : 0.7)
                .rotationEffect(.degrees(appeared ? 0 : -10))
                .symbolEffect(.bounce, value: reduceMotion ? "" : updates.phaseKey)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Neue Version verfügbar"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Text(tr("LabelWerk %@", update.manifest.appVersion.description))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.brandGradient)
                Text(tr("Installiert: %@", update.current.description))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(UpdateController.facts(of: update))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : 8)
            Spacer(minLength: 0)
        }
        .padding(Theme.Metrics.paddingLarge)
    }

    private func status(_ updates: UpdateController) -> some View {
        HStack(alignment: .top, spacing: 12) {
            UpdateStatusSymbol(updates: updates, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(updates.progressText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(updates.failureMessage != nil ? Theme.error : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                Text(tr("Drucker, Einstellungen, Etikettenformate, Verlauf und macOS-Warteschlangen bleiben erhalten. LabelWerk startet nach der Installation von selbst neu."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !updates.runsFromInstalledLocation {
                    Label(tr("Diese App läuft nicht aus dem Ordner „Programme“. Das Update wird als „%@“ installiert und von dort gestartet.",
                             UpdateController.installedAppURL.path),
                          systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if updates.isDownloading {
                Button(tr("Laden abbrechen")) { updates.cancelDownload() }
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func footer(_ updates: UpdateController) -> some View {
        HStack(spacing: 10) {
            Button(tr("Diese Version überspringen")) {
                updates.skipCurrentUpdate()
                dismiss()
            }
            .buttonStyle(.labelWerkPlain)
            .disabled(updates.isInstalling)
            Spacer()
            Button(tr("Später")) {
                updates.dismissBanner()
                dismiss()
            }
            .buttonStyle(.labelWerkSecondary)
            .keyboardShortcut(.cancelAction)
            .disabled(updates.isInstalling)
            Button {
                updates.downloadAndInstall()
            } label: {
                Label(updates.installButtonTitle, systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!updates.canInstall)
        }
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.vertical, Theme.Metrics.padding)
    }

    private func upToDate(_ updates: UpdateController) -> some View {
        VStack(spacing: 14) {
            IconBadge(systemImage: "checkmark.seal", tint: Theme.ready, size: 58)
                .scaleEffect(appeared ? 1 : 0.7)
            Text(updates.statusText)
                .font(Theme.Typography.headline)
                .multilineTextAlignment(.center)
            if let current = updates.currentVersion {
                Text(tr("Installiert ist Version %@.", current.description))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button(tr("Schließen")) { dismiss() }
                .buttonStyle(.labelWerkPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Änderungsnotizen

/// Zeigt die Änderungsnotizen eines Releases (Markdown): Überschriften, Aufzählungen und Absätze;
/// Hervorhebungen, Code und Links innerhalb einer Zeile über `AttributedString(markdown:)`.
struct ReleaseNotesView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String, level: Int)
        case bullet(String)
        case paragraph(String)
    }

    var body: some View {
        let blocks = Self.blocks(of: markdown)
        VStack(alignment: .leading, spacing: 7) {
            if blocks.isEmpty {
                Text(tr("Für diese Version liegen keine Änderungsnotizen vor."))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, let level):
                    Text(Self.inline(text))
                        .font(level <= 2 ? Theme.Typography.headline : .system(size: 13, weight: .semibold))
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•")
                            .foregroundStyle(Theme.violet)
                        Text(Self.inline(text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Zerlegt Markdown zeilenweise in Blöcke (Überschrift, Aufzählung, Absatz).
    private static func blocks(of markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph.removeAll()
        }
        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(text, level: level)) }
            } else if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

// MARK: - Menüleiste

/// Update-Zeile im Menüleisten-Fenster: gefundenes Update mit „Jetzt installieren“, sonst (nach
/// „Nach Updates suchen …“) kurz das Ergebnis der Suche.
struct UpdateMenuBarSection: View {
    @Environment(AppModel.self) private var model
    /// Hauptfenster nach vorn holen (für „Details“).
    let openMain: () -> Void

    var body: some View {
        let updates: UpdateController = model.updates
        HStack(spacing: 10) {
            UpdateStatusSymbol(updates: updates, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                if let update = updates.update {
                    Text(tr("Update verfügbar: LabelWerk %@", update.manifest.appVersion.description))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    Text(updates.progressText)
                        .font(.system(size: 11))
                        .foregroundStyle(updates.failureMessage != nil ? Theme.error : Color.secondary)
                        .lineLimit(3)
                        .contentTransition(.numericText())
                } else {
                    Text(updates.statusText)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if updates.update != nil {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(updates.installButtonTitle) { updates.downloadAndInstall() }
                        .buttonStyle(.labelWerkPrimary)
                        .disabled(!updates.canInstall)
                    Button(tr("Details")) {
                        openMain()
                        updates.showDetails()
                    }
                    .buttonStyle(.labelWerkPlain)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .labelWerkGlass(cornerRadius: 12, tint: updates.update != nil ? Theme.violet : nil)
    }
}

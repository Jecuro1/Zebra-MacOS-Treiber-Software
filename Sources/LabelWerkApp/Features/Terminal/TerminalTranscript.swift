import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Protokolleintrag

/// Ein Eintrag im Terminalprotokoll: gesendete Eingabe, Zeitstempel und Antwort – als Text mit
/// sichtbaren Steuerzeichen (␂ ␃ ␍ ␊) oder als Hex-Dump mit Offsets und ASCII-Spalte.
struct TerminalEntryView: View {
    let entry: TerminalEntry
    /// Hex-Ansicht verfügbar (Entwicklermodus).
    let hexAvailable: Bool
    let hexByDefault: Bool
    let reduceMotion: Bool
    let onReuse: () -> Void
    let onResend: () -> Void

    @State private var hexOverride: Bool?
    @State private var expanded = false
    @State private var inputExpanded = false
    @State private var copied = false
    @State private var hovering = false
    @State private var shakeCount = 0

    init(entry: TerminalEntry, hexAvailable: Bool, hexByDefault: Bool, reduceMotion: Bool,
         onReuse: @escaping () -> Void, onResend: @escaping () -> Void) {
        self.entry = entry
        self.hexAvailable = hexAvailable
        self.hexByDefault = hexByDefault
        self.reduceMotion = reduceMotion
        self.onReuse = onReuse
        self.onResend = onResend
    }

    private var showsHex: Bool { hexAvailable && (hexOverride ?? hexByDefault) }

    private var accent: Color {
        switch entry.outcome {
        case .pending: return Theme.accent
        case .response: return Theme.teal
        case .silent, .sent: return Theme.ready
        case .sendOnly: return Theme.printing
        case .failed: return Theme.error
        }
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .command(let mode): return mode.systemImage
        case .file: return "arrow.up.doc.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(accent.gradient)
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 8) {
                header
                if let expandedPayload = entry.expandedPayload {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(TerminalFormatter.visibleString(expandedPayload))
                            .font(Theme.Typography.codeSmall)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.secondary)
                    .help(tr("Kurzform wurde in vollständige SGD-Befehle umgewandelt"))
                }
                responseSection
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.subtleFill.opacity(hovering ? 1.8 : 1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(entry.isPending ? Theme.accent.opacity(0.35) : Theme.cardStroke, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(ToolsShakeEffect(trigger: shakeCount, travel: 5))
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: entry.outcome)
        .onChange(of: entry.outcome) { _, newValue in
            guard !reduceMotion, case .failed = newValue else { return }
            withAnimation(.linear(duration: 0.45)) { shakeCount += 1 }
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kindSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if case .file = entry.kind {
                    Text(tr("Datei „%@“ gesendet", entry.input))
                        .font(.system(size: 12.5, weight: .semibold))
                } else {
                    Text(verbatim: entry.input)
                        .font(Theme.Typography.code)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                        .lineLimit(inputExpanded ? nil : 4)
                    if entry.input.split(separator: "\n").count > 4 {
                        Button(inputExpanded ? tr("Eingabe einklappen") : tr("Ganze Eingabe zeigen")) {
                            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                                inputExpanded.toggle()
                            }
                        }
                        .buttonStyle(.labelWerkPlain)
                        .controlSize(.mini)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .command = entry.kind {
                HStack(spacing: 2) {
                    iconButton("arrow.uturn.up", help: tr("In die Eingabe übernehmen"), action: onReuse)
                    iconButton("arrow.clockwise", help: tr("Erneut senden"), action: onResend)
                }
                .opacity(hovering ? 1 : 0)
            }

            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.labelWerkPlain)
        .help(help)
    }

    // MARK: Antwort

    @ViewBuilder
    private var responseSection: some View {
        switch entry.outcome {
        case .pending:
            HStack(spacing: 8) {
                TerminalWaitingDots(reduceMotion: reduceMotion)
                Text(pendingText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        case .response(let data, let rendering):
            responseBody(data: data, rendering: rendering)
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .silent:
            statusLine(tr("Keine Antwort innerhalb von %d s – bei Befehlen ohne Rückmeldung ist das normal.",
                          entry.timeoutSeconds),
                       systemImage: "checkmark.circle", tint: Theme.ready)
        case .sendOnly:
            statusLine(tr("Gesendet. Über diese Verbindung kommen keine Antworten zurück."),
                       systemImage: "paperplane.fill", tint: Theme.printing)
        case .sent:
            statusLine(tr("%@ übertragen", TerminalFormatter.byteText(entry.bytesSent)) + durationSuffix,
                       systemImage: "checkmark.circle.fill", tint: Theme.ready)
        case .failed(let message):
            statusLine(message, systemImage: "xmark.octagon.fill", tint: Theme.error)
        }
    }

    private var pendingText: String {
        if case .file = entry.kind {
            return tr("%@ werden übertragen …", TerminalFormatter.byteText(entry.bytesSent))
        }
        return tr("Warte auf Antwort … (bis %d s)", entry.timeoutSeconds)
    }

    private var durationSuffix: String {
        guard let duration = entry.duration else { return "" }
        return " · " + tr("%.0f ms", duration * 1000)
    }

    private func statusLine(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : (entry.duration ?? 0))
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5, weight: .medium))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func isLong(_ rendering: TerminalRendering) -> Bool {
        showsHex ? rendering.byteCount > 16 * 12 : (rendering.lineCount > 14 || rendering.byteCount > 1_600)
    }

    private func responseBody(data: Data, rendering: TerminalRendering) -> some View {
        let long = isLong(rendering)
        let collapsed = long && !expanded
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                Group {
                    if showsHex {
                        Text(verbatim: rendering.hex)
                            .font(Theme.Typography.codeSmall)
                    } else {
                        Text(rendering.visual)
                            .font(Theme.Typography.code)
                    }
                }
                .id(showsHex)
                .transition(.opacity)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .frame(maxHeight: collapsed ? 240 : nil, alignment: .top)
                .clipped()

                if collapsed {
                    LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor).opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 12) {
                Label(tr("%@ empfangen", TerminalFormatter.byteText(rendering.byteCount)), systemImage: "arrow.down.circle")
                Label(tr("%@ gesendet", TerminalFormatter.byteText(entry.bytesSent)), systemImage: "arrow.up.circle")
                if let duration = entry.duration {
                    Label(tr("%.0f ms", duration * 1000), systemImage: "timer")
                }
                if (showsHex && rendering.isHexTruncated) || (!showsHex && rendering.isTextTruncated) {
                    Label(tr("Anzeige gekürzt – vollständig über Kopieren oder Sichern"), systemImage: "scissors")
                        .foregroundStyle(Theme.warning)
                }
                Spacer(minLength: 6)
                if long {
                    Button(expanded ? tr("Weniger") : tr("Alles anzeigen")) {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            expanded.toggle()
                        }
                    }
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.mini)
                }
                if hexAvailable {
                    displayToggle
                }
                Button {
                    copy(data: data, rendering: rendering)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copied ? Theme.ready : Color.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(showsHex ? tr("Hex-Dump kopieren") : tr("Antwort als Text kopieren"))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    private var displayToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(title: tr("Text"), active: !showsHex) { hexOverride = false }
            toggleSegment(title: "Hex", active: showsHex) { hexOverride = true }
        }
        .padding(2)
        .background {
            Capsule().fill(Theme.subtleFill)
        }
    }

    private func toggleSegment(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { action() }
        } label: {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background {
                    if active {
                        Capsule().fill(Theme.brandGradient)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copy(data: Data, rendering: TerminalRendering) {
        let text = showsHex
            ? (rendering.isHexTruncated ? TerminalFormatter.hexDump(data) : rendering.hex)
            : rendering.plain
        ToolsFileExport.copy(text)
        let animation = Motion.animation(Motion.snappy, reduceMotion: reduceMotion)
        withAnimation(animation) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(animation) { copied = false }
        }
    }
}

// MARK: - Wartepunkte

struct TerminalWaitingDots: View {
    let reduceMotion: Bool

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                if reduceMotion {
                    Circle()
                        .fill(Theme.accent.opacity(0.7))
                        .frame(width: 5, height: 5)
                } else {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .phaseAnimator([0.35, 1.0]) { dot, phase in
                            dot
                                .opacity(phase)
                                .scaleEffect(0.7 + 0.3 * phase)
                        } animation: { _ in
                            .easeInOut(duration: 0.42).delay(Double(index) * 0.14)
                        }
                }
            }
        }
        .accessibilityLabel(tr("Warte auf Antwort"))
    }
}

// MARK: - Willkommen

/// Leerer Zustand des Terminals mit Einstieg und Schnellstart-Befehlen.
struct TerminalWelcome: View {
    let supportsStatus: Bool
    let hexAvailable: Bool
    let reduceMotion: Bool
    let onPick: (TerminalSnippet) -> Void

    @State private var appeared = false

    init(supportsStatus: Bool, hexAvailable: Bool, reduceMotion: Bool,
         onPick: @escaping (TerminalSnippet) -> Void) {
        self.supportsStatus = supportsStatus
        self.hexAvailable = hexAvailable
        self.reduceMotion = reduceMotion
        self.onPick = onPick
    }

    var body: some View {
        VStack(spacing: 14) {
            IconBadge(systemImage: "terminal.fill", tint: Theme.violet, size: 56)
                .symbolEffect(.bounce, value: reduceMotion ? false : appeared)
            VStack(spacing: 6) {
                Text(tr("Direkt mit dem Drucker sprechen"))
                    .font(Theme.Typography.title)
                Text(introText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 18) {
                hint(symbol: "command", text: tr("⌘↩ sendet"))
                hint(symbol: "square.grid.2x2", text: tr("Bausteine unten"))
                hint(symbol: "text.book.closed", text: tr("Referenz rechts"))
            }
            if supportsStatus {
                HStack(spacing: 8) {
                    ForEach(Array(TerminalSnippet.all.prefix(3))) { snippet in
                        Button {
                            onPick(snippet)
                        } label: {
                            VStack(spacing: 1) {
                                Text(verbatim: snippet.code)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                Text(snippet.title)
                                    .font(.system(size: 10))
                                    .opacity(0.8)
                            }
                        }
                        .buttonStyle(.labelWerkSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .onAppear {
            withAnimation(reduceMotion ? nil : Motion.spring.delay(0.05)) { appeared = true }
        }
    }

    private var introText: String {
        if !supportsStatus {
            return tr("Diese Verbindung kann nur senden: Befehle und Dateien werden übertragen, Antworten des Druckers sind nicht verfügbar.")
        }
        return hexAvailable
            ? tr("Sende ZPL-, SGD- oder JSON-Befehle mit ⌘↩. Antworten erscheinen hier – als Text mit sichtbaren Steuerzeichen oder als Hex-Dump.")
            : tr("Sende ZPL-, SGD- oder JSON-Befehle mit ⌘↩. Antworten erscheinen hier als Text mit sichtbaren Steuerzeichen.")
    }

    private func hint(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

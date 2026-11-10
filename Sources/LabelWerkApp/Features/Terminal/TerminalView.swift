import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

extension TerminalInputMode {
    /// Hervorhebung im Code-Editor.
    var codeLanguage: CodeLanguage {
        switch self {
        case .zpl: return .zpl
        case .sgd: return .sgd
        case .text: return .plain
        }
    }
}

/// ZPL/SGD-Konsole – ersetzt „Open Communication With Printer“ der Zebra Setup Utilities:
/// Protokoll mit Antworten (Text mit sichtbaren Steuerzeichen oder Hex-Dump), Editor mit
/// Hervorhebung und ⌘↩, Bausteine, Eingabeverlauf, Befehlsreferenz, Dateiversand und Export.
struct TerminalView: View {
    let session: PrinterSession
    private let console: TerminalConsole

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @AppStorage("LabelWerk.Terminal.Timeout") private var timeoutSeconds = 2
    @AppStorage("LabelWerk.Terminal.HexByDefault") private var hexByDefault = false
    @AppStorage("LabelWerk.Terminal.ClearAfterSend") private var clearAfterSend = true
    @AppStorage("LabelWerk.Terminal.ShowReference") private var showReference = true

    @State private var inputHeight: CGFloat = 200
    @State private var dragStartHeight: CGFloat?
    @State private var showHistory = false
    @State private var sendPulse = 0
    @State private var handleHovered = false
    @State private var resizeCursorPushed = false

    private static let bottomAnchor = "terminal.bottom"
    private static let inputHeightRange: ClosedRange<CGFloat> = 150...460

    init(session: PrinterSession) {
        self.session = session
        self.console = TerminalConsole.console(for: session.id)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    /// Hex-Ansichten gehören laut App-Einstellungen zum Entwicklermodus.
    private var hexAvailable: Bool { model.preferences.developerMode }

    private var history: TerminalHistoryStore { TerminalHistoryStore.shared }

    /// Nur im Popover gebraucht – kein Dekodieren pro Tastendruck.
    private var historyItems: [String] {
        TerminalHistory.merged(volatile: console.volatileHistory, stored: history.items)
    }

    private var hasHistory: Bool {
        !console.volatileHistory.isEmpty || !history.items.isEmpty
    }

    /// Bricht beim ersten sichtbaren Zeichen ab – kein Kopieren großer Eingaben pro Tastendruck.
    private var canSend: Bool {
        !console.isSending && console.input.contains { !$0.isWhitespace }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
            VStack(spacing: 10) {
                toolbar

                if !session.supportsStatus {
                    ToolsNotice(
                        title: tr("Nur Senden"),
                        message: tr("Diese Verbindung (macOS-Warteschlange) überträgt nur Daten zum Drucker. Antworten wie Status, Konfiguration oder SGD-Werte sind nicht verfügbar."),
                        systemImage: "paperplane",
                        tint: Theme.warning
                    )
                }

                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                splitHandle

                inputPanel
                    .frame(height: inputHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showReference {
                TerminalReferencePanel(reduceMotion: reduceMotion) { text, mode in
                    insert(text, mode: mode)
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.bottom, Theme.Metrics.padding)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: showReference)
        .onAppear {
            // Konsolen entfernter Drucker samt Protokoll freigeben.
            TerminalConsole.discardAll(except: Set(model.sessions.map(\.id)))
        }
    }

    // MARK: Symbolleiste

    private var connectionSummary: String {
        "\(session.saved.descriptor.displayString) · \(session.connectionState.displayName)"
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(compact: false)
            toolbarRow(compact: true)
        }
        .padding(10)
        .labelWerkGlass(cornerRadius: 14)
    }

    private func toolbarRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: "terminal.fill", tint: session.accentColor, size: 32)
                .symbolEffect(.bounce, value: sendPulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Terminal"))
                    .font(Theme.Typography.headline)
                HStack(spacing: 5) {
                    StatusOrb(state: session.state, size: 7)
                    Text(compact ? session.connectionState.displayName : connectionSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 8)

            if !console.entries.isEmpty && !compact {
                Text(tr("%d Einträge", console.entries.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: console.entries.count)
            }

            if hexAvailable {
                Toggle(isOn: $hexByDefault.animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion))) {
                    Label(tr("Hex"), systemImage: "number")
                        .labelStyle(TerminalAdaptiveLabelStyle(compact: compact))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(tr("Antworten standardmäßig als Hex-Dump anzeigen"))
            }

            Button {
                pickFile()
            } label: {
                Label(tr("Datei senden …"), systemImage: "arrow.up.doc")
                    .labelStyle(TerminalAdaptiveLabelStyle(compact: compact))
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .disabled(console.isSending)
            .help(tr("Datei unverändert an den Drucker senden"))

            Menu {
                Button(tr("Protokoll sichern …")) { saveTranscript() }
                    .disabled(console.entries.isEmpty)
                Button(tr("Protokoll kopieren")) {
                    ToolsFileExport.copy(console.transcriptText(printerName: session.displayName))
                }
                .disabled(console.entries.isEmpty)
                Divider()
                Toggle(tr("Eingabe nach dem Senden leeren"), isOn: $clearAfterSend)
                Divider()
                Button(tr("Protokoll leeren"), role: .destructive) {
                    console.clear(reduceMotion: reduceMotion)
                }
                .disabled(console.entries.isEmpty)
            } label: {
                Label(tr("Protokoll"), systemImage: "doc.plaintext")
                    .labelStyle(TerminalAdaptiveLabelStyle(compact: compact))
            }
            .menuStyle(.button)
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .fixedSize()
            .help(tr("Protokoll sichern, kopieren oder leeren"))

            Button {
                showReference.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .symbolEffect(.bounce, value: reduceMotion ? false : showReference)
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .help(showReference ? tr("Befehlsreferenz ausblenden") : tr("Befehlsreferenz einblenden"))
        }
    }

    // MARK: Protokoll

    private var entryTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .bottom)),
            removal: .opacity
        )
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if console.entries.isEmpty {
                        TerminalWelcome(supportsStatus: session.supportsStatus, hexAvailable: hexAvailable,
                                        reduceMotion: reduceMotion) { snippet in
                            submitDirect(snippet.code, mode: snippet.mode)
                        }
                        .transition(.opacity)
                    }
                    ForEach(console.entries) { entry in
                        TerminalEntryView(
                            entry: entry,
                            hexAvailable: hexAvailable,
                            hexByDefault: hexByDefault,
                            reduceMotion: reduceMotion,
                            onReuse: { reuse(entry) },
                            onResend: { resend(entry) }
                        )
                        .id(entry.id)
                        .transition(entryTransition)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(12)
            }
            .labelWerkGlass(cornerRadius: 14)
            .onChange(of: console.revision) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let animated = !reduceMotion
        Task { @MainActor in
            // Einen Layoutdurchlauf abwarten, damit neue Einträge bereits vermessen sind.
            try? await Task.sleep(for: .milliseconds(30))
            if animated {
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: Teiler

    private var splitHandle: some View {
        ZStack {
            Color.clear
                .frame(height: 12)
            Capsule()
                .fill(handleHovered || dragStartHeight != nil ? Theme.accent.opacity(0.7) : Theme.separator)
                .frame(width: handleHovered || dragStartHeight != nil ? 64 : 44, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            handleHovered = inside
            // Während des Ziehens verlässt der Zeiger den schmalen Griff sofort – der
            // Größenänderungs-Cursor bleibt dann bis zum Loslassen bestehen.
            if dragStartHeight == nil { setResizeCursor(inside) }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? inputHeight
                    if dragStartHeight == nil {
                        dragStartHeight = inputHeight
                        setResizeCursor(true)
                    }
                    inputHeight = (start - value.translation.height).clamped(to: Self.inputHeightRange)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    setResizeCursor(handleHovered)
                }
        )
        .onDisappear {
            setResizeCursor(false)
            handleHovered = false
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: handleHovered)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: dragStartHeight == nil)
        .help(tr("Ziehen, um die Eingabe zu vergrößern oder zu verkleinern"))
        .accessibilityHidden(true)
    }

    /// Hält Push/Pop des Cursors ausgeglichen, egal in welcher Reihenfolge Hover und Ziehen enden.
    private func setResizeCursor(_ active: Bool) {
        if active && !resizeCursorPushed {
            NSCursor.resizeUpDown.push()
            resizeCursorPushed = true
        } else if !active && resizeCursorPushed {
            NSCursor.pop()
            resizeCursorPushed = false
        }
    }

    // MARK: Eingabe

    private var inputBinding: Binding<String> {
        Binding(get: { console.input }, set: { console.input = $0 })
    }

    private var modeBinding: Binding<TerminalInputMode> {
        Binding(get: { console.mode }, set: { console.mode = $0 })
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TerminalSnippet.all) { snippet in
                        TerminalSnippetChip(
                            snippet: snippet,
                            isDisabled: console.isSending,
                            reduceMotion: reduceMotion,
                            onInsert: { insert(snippet.code, mode: snippet.mode) },
                            onSend: { submitDirect(snippet.code, mode: snippet.mode) }
                        )
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
            .scrollBounceBehavior(.basedOnSize)

            ZStack(alignment: .topLeading) {
                CodeEditor(text: inputBinding, language: console.mode.codeLanguage, fontSize: 13,
                           onSubmit: { send() })
                    // CodeEditor hebt nur bei Text- oder Schriftänderungen neu hervor; beim Moduswechsel
                    // wird er deshalb neu aufgebaut (Text kommt aus der Bindung zurück).
                    .id(console.mode)
                if console.input.isEmpty {
                    Text(tr("Befehl eingeben, z. B. ~HS oder device.languages – ⌘↩ sendet"))
                        .font(Theme.Typography.code)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 50)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(console.isSending ? Theme.accent.opacity(0.5) : Theme.cardStroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: console.input.isEmpty)

            ViewThatFits(in: .horizontal) {
                controlsRow(compact: false)
                controlsRow(compact: true)
            }
            // Außerhalb von ViewThatFits, damit nur eine Variante das Popover besitzt.
            .popover(isPresented: $showHistory, attachmentAnchor: .point(.top), arrowEdge: .top) {
                historyPopover
            }
        }
        .padding(12)
        .labelWerkGlass(cornerRadius: 14)
    }

    private func controlsRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            TerminalModePicker(selection: modeBinding, compact: compact, reduceMotion: reduceMotion)
                .help(console.mode.explanation)
            timeoutPicker(compact: compact)
            historyButton(compact: compact)
            Spacer(minLength: 6)
            if !compact {
                Text(TerminalFormatter.byteText(console.input.utf8.count))
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
            sendButton(compact: compact)
        }
    }

    @ViewBuilder
    private func timeoutPicker(compact: Bool) -> some View {
        let picker = Picker(selection: $timeoutSeconds) {
            ForEach(1...10, id: \.self) { seconds in
                Text(tr("%d s", seconds)).tag(seconds)
            }
        } label: {
            Label(tr("Zeitlimit"), systemImage: "timer")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(tr("So lange wird auf eine Antwort des Druckers gewartet"))
        if compact {
            picker.labelsHidden()
        } else {
            picker
        }
    }

    private func historyButton(compact: Bool) -> some View {
        Button {
            showHistory.toggle()
        } label: {
            Label(tr("Verlauf"), systemImage: "clock.arrow.circlepath")
                .labelStyle(TerminalAdaptiveLabelStyle(compact: compact))
        }
        .buttonStyle(.labelWerkPlain)
        .controlSize(.small)
        .disabled(!hasHistory)
        .help(tr("Eingabeverlauf"))
    }

    private var historyPopover: some View {
        TerminalHistoryPopover(
            items: historyItems,
            reduceMotion: reduceMotion,
            onInsert: { item in
                showHistory = false
                replaceInput(with: item)
            },
            onSend: { item in
                showHistory = false
                submitDirect(item, mode: TerminalInputMode.infer(from: item, fallback: console.mode))
            },
            onClear: {
                showHistory = false
                history.clear()
                console.clearVolatileHistory()
            }
        )
    }

    private func sendButton(compact: Bool) -> some View {
        Button {
            send()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    if console.isSending {
                        ProgressRing(progress: nil, size: 13, lineWidth: 2)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "paperplane.fill")
                            .symbolEffect(.bounce, value: sendPulse)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 14, height: 14)
                Text(console.isSending ? tr("Wartet …") : tr("Senden"))
                    .contentTransition(.opacity)
                if !compact {
                    Text(verbatim: "⌘↩")
                        .font(.system(size: 10.5, weight: .semibold))
                        .opacity(0.7)
                }
            }
        }
        .buttonStyle(.labelWerkPrimary)
        .disabled(!canSend)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: console.isSending)
        .help(tr("Senden (⌘↩)"))
    }

    // MARK: Aktionen

    private func send() {
        let text = console.input
        guard console.submit(text, mode: console.mode, timeoutSeconds: timeoutSeconds,
                             session: session, reduceMotion: reduceMotion) else {
            if console.isSending { NSSound.beep() }
            return
        }
        console.remember(text)
        if !reduceMotion { sendPulse += 1 }
        if clearAfterSend { console.input = "" }
    }

    private func submitDirect(_ text: String, mode: TerminalInputMode) {
        guard console.submit(text, mode: mode, timeoutSeconds: timeoutSeconds,
                             session: session, reduceMotion: reduceMotion) else {
            if console.isSending { NSSound.beep() }
            return
        }
        console.remember(text)
        if !reduceMotion { sendPulse += 1 }
    }

    /// Fügt Text ans Ende der Eingabe an (bzw. ersetzt eine leere Eingabe).
    private func insert(_ text: String, mode: TerminalInputMode) {
        let current = console.input
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            console.input = text
            console.mode = mode
        } else {
            console.input = current + (current.hasSuffix("\n") ? "" : "\n") + text
        }
    }

    private func replaceInput(with text: String) {
        console.input = text
        console.mode = TerminalInputMode.infer(from: text, fallback: console.mode)
    }

    private func reuse(_ entry: TerminalEntry) {
        console.input = entry.input
        if let mode = entry.mode { console.mode = mode }
    }

    private func resend(_ entry: TerminalEntry) {
        submitDirect(entry.input, mode: entry.mode ?? console.mode)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = tr("Datei an Drucker senden")
        panel.message = tr("Die Datei wird unverändert übertragen (ZPL, EPL, CPCL, SGD, Grafiken, Schriften …).")
        panel.prompt = tr("Senden")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        console.sendFile(at: url, session: session, model: model, reduceMotion: reduceMotion)
    }

    private func saveTranscript() {
        let text = console.transcriptText(printerName: session.displayName)
        let fileName = ToolsFileExport.safeFileName(tr("Terminal %@", session.displayName)) + ".txt"
        do {
            if let url = try ToolsFileExport.save(Data(text.utf8), suggestedName: fileName, contentType: .plainText) {
                model.toast(tr("Protokoll gesichert"), message: url.lastPathComponent, style: .success)
            }
        } catch {
            model.toast(tr("Sichern fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Beschriftung

/// Symbol mit Titel – in schmalen Fenstern nur das Symbol.
private struct TerminalAdaptiveLabelStyle: LabelStyle {
    let compact: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        }
    }
}

// MARK: - Moduswahl

private struct TerminalModePicker: View {
    @Binding var selection: TerminalInputMode
    let compact: Bool
    let reduceMotion: Bool

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TerminalInputMode.allCases) { mode in
                let isSelected = selection == mode
                Button {
                    withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                        selection = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 10, weight: .bold))
                        if !compact || isSelected {
                            Text(mode.title)
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.brandGradient)
                                .shadow(color: Theme.violet.opacity(0.35), radius: 5, y: 2)
                                .matchedGeometryEffect(id: "mode", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(mode.explanation)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            Capsule().fill(Theme.subtleFill)
        }
    }
}

// MARK: - Verlauf

private struct TerminalHistoryPopover: View {
    let items: [String]
    let reduceMotion: Bool
    let onInsert: (String) -> Void
    let onSend: (String) -> Void
    let onClear: () -> Void

    @State private var query = ""

    private var filtered: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Eingabeverlauf"))
                    .font(Theme.Typography.headline)
                Spacer()
                Button(tr("Leeren"), role: .destructive, action: onClear)
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.small)
            }
            ToolsSearchField(text: $query, prompt: tr("Verlauf durchsuchen"), reduceMotion: reduceMotion)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.self) { item in
                        TerminalHistoryRow(item: item, query: query, reduceMotion: reduceMotion,
                                           onInsert: { onInsert(item) },
                                           onSend: { onSend(item) })
                    }
                    if filtered.isEmpty {
                        Text(tr("Keine Treffer"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
            }
            .frame(height: 260)
            Text(tr("Klick übernimmt den Befehl in die Eingabe. Einträge mit Passwörtern werden nicht dauerhaft gespeichert."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 420)
    }
}

private struct TerminalHistoryRow: View {
    let item: String
    let query: String
    let reduceMotion: Bool
    let onInsert: () -> Void
    let onSend: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onInsert) {
                // Anzeige begrenzen: Sitzungseinträge können sehr groß sein (eingefügtes ZPL mit Grafiken).
                Text(ToolsHighlight.attributed(String(item.prefix(400)).replacingOccurrences(of: "\n", with: " ⏎ "),
                                               query: query))
                    .font(Theme.Typography.codeSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(item.prefix(1_000)))
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help(tr("Direkt senden"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.accent.opacity(0.1) : Color.clear)
        }
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
    }
}

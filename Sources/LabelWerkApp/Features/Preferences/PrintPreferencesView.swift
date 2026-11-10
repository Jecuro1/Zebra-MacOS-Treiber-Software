import AppKit
import SwiftUI
import LabelWerkKit

/// „Druckeinstellungen für …“ – die macOS-Fassung des Dialogs des Windows-Treibers ZDesigner:
/// links die Bereiche (Seite einrichten, Druckoptionen, Bedienermodus, Grafik Optionen,
/// Kundenspezifische Befehle, Wartung, Einheiten, Hilfe und Über) mit „Testseite drucken“, in der
/// Mitte die Einstellungen mit Stift-Menü je Wert, rechts die „Druckvorschau“ und unten
/// „OK“, „Abbrechen“, „Übernehmen“ und „Hilfe“.
///
/// Bearbeitet wird ein Entwurf (`PrintPrefsEditor`, je Drucker). Gespeichert werden die Werte erst
/// mit „OK“ bzw. „Übernehmen“: als Treiber-Standard des Druckers (`session.saved.settings`) und –
/// falls eingerichtet – als Standard der macOS-Warteschlange.
@MainActor
struct PrintPreferencesView: View {
    let session: PrinterSession
    /// Je Drucker geteilt: Eingaben überstehen einen Bereichswechsel.
    let editor: PrintPrefsEditor

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var showHelp = false
    @State private var helpPane: PrintPrefsPane = .page
    @State private var isPrintingTest = false
    @State private var printTrigger = 0
    @State private var saveTrigger = 0
    @State private var appeared = false
    @State private var hoveredPane: PrintPrefsPane?
    @Namespace private var sidebarNamespace

    init(session: PrinterSession) {
        self.session = session
        self.editor = PrintPrefsEditor.shared(for: session)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var spring: Animation? { reduceMotion ? nil : Motion.spring }

    private var context: PrintPrefsContext {
        PrintPrefsContext(editor: editor, session: session,
                          length: PrintPrefsLength(unit: model.preferences.measurementUnit, resolution: session.resolution),
                          reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
                .modifier(PrintPrefsAppear(index: 0, appeared: appeared, reduceMotion: reduceMotion))
            GeometryReader { geo in
                let wide = geo.size.width >= 1000
                HStack(alignment: .top, spacing: 14) {
                    sidebar
                        .frame(width: 214)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .modifier(PrintPrefsAppear(index: 1, appeared: appeared, reduceMotion: reduceMotion))
                    // ZStack: Beim Bereichswechsel überlagern sich alter und neuer Inhalt kurz.
                    ZStack(alignment: .topLeading) {
                        paneScroll(inlinePreview: !wide)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .modifier(PrintPrefsAppear(index: 2, appeared: appeared, reduceMotion: reduceMotion))
                    if wide {
                        ScrollView {
                            previewPanel
                        }
                        .scrollIndicators(.never)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .modifier(PrintPrefsAppear(index: 3, appeared: appeared, reduceMotion: reduceMotion))
                    }
                }
                .animation(spring, value: wide)
            }
            footer
                .modifier(PrintPrefsAppear(index: 4, appeared: appeared, reduceMotion: reduceMotion))
        }
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .sheet(isPresented: $showHelp) {
            PrintPrefsHelpSheet(initialPane: helpPane)
                .environment(model)
        }
        .sensoryFeedback(.success, trigger: saveTrigger)
        .onAppear {
            editor.reloadIfClean(from: session)
            appeared = true
        }
        .onChange(of: session.saved) { _, _ in
            editor.reloadIfClean(from: session)
        }
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Druckeinstellungen für %@", session.displayName))
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                Text(tr("Treiber-Standardwerte – gelten für Aufträge aus LabelWerk und für die macOS-Warteschlange."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
                chip(symbol: session.model?.systemImage ?? "printer",
                     text: session.model?.displayName ?? tr("Unbekanntes Modell"))
                chip(symbol: "circle.grid.3x3", text: session.resolution.displayName)
                chip(symbol: PrintPrefsSymbols.symbol(for: editor.draft.language), text: editor.draft.language.displayName)
                if let queue = session.saved.cupsQueueName {
                    chip(symbol: "macwindow", text: tr("macOS: %@", queue))
                }
            }
            .fixedSize()
        }
    }

    private func chip(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.brandGradient)
            Text(text)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.subtleFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    // MARK: - Seitenleiste

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(PrintPrefsPane.allCases) { pane in
                        sidebarRow(pane)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            Divider()
                .opacity(0.6)
            Button {
                printTestPage()
            } label: {
                HStack(spacing: 7) {
                    if isPrintingTest {
                        ProgressRing(progress: nil, size: 14, lineWidth: 2)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "printer.dotmatrix.filled.and.paper")
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(tr("Testseite drucken"))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(isPrintingTest || session.isBusy)
            .help(tr("Druckt eine Testseite mit den Werten dieses Dialogs (auch mit noch nicht gespeicherten Änderungen)."))
            .padding(10)
            .animation(spring, value: isPrintingTest)
        }
        .labelWerkGlass(cornerRadius: 16)
    }

    private func sidebarRow(_ pane: PrintPrefsPane) -> some View {
        let isSelected = editor.pane == pane
        let hasChanges = editor.hasChanges(in: pane)
        return Button {
            withAnimation(spring) { editor.pane = pane }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.22))
                                         : AnyShapeStyle(pane.tint.opacity(0.16)))
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : pane.tint)
                        .symbolEffect(.bounce, value: isSelected)
                }
                .frame(width: 24, height: 24)
                Text(pane.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if hasChanges {
                    Circle()
                        .fill(isSelected ? Color.white : Theme.warning)
                        .frame(width: 7, height: 7)
                        .transition(.scale.combined(with: .opacity))
                        .help(tr("Enthält nicht gespeicherte Änderungen"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "pane", in: sidebarNamespace)
                } else if hoveredPane == pane {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.subtleFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                hoveredPane = inside ? pane : (hoveredPane == pane ? nil : hoveredPane)
            }
        }
        .animation(spring, value: hasChanges)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Bereich

    private func paneScroll(inlinePreview: Bool) -> some View {
        let pane = editor.pane
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                paneHeader(pane)
                if inlinePreview {
                    previewPanel
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity)
                }
                paneContent(pane)
            }
            .padding(.bottom, 8)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .id(pane)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 12)),
                                                          removal: .opacity))
    }

    private func paneHeader(_ pane: PrintPrefsPane) -> some View {
        let changes = editor.changedSettings.filter { $0.pane == pane }.count
        return HStack(spacing: 12) {
            IconBadge(systemImage: pane.systemImage, tint: pane.tint, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(Theme.Typography.title)
                Text(pane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if changes > 0 {
                Text(changes == 1 ? tr("1 Änderung") : tr("%d Änderungen", changes))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.warning.opacity(0.12), in: Capsule())
                    .contentTransition(.numericText(value: Double(changes)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.top, 4)
        .animation(spring, value: changes)
    }

    @ViewBuilder
    private func paneContent(_ pane: PrintPrefsPane) -> some View {
        let context = self.context
        switch pane {
        case .page: PrintPrefsPagePane(context: context)
        case .options: PrintPrefsOptionsPane(context: context)
        case .operation: PrintPrefsOperationPane(context: context)
        case .graphics: PrintPrefsGraphicsPane(context: context)
        case .commands: PrintPrefsCommandsPane(context: context)
        case .maintenance: PrintPrefsMaintenancePane(context: context)
        case .units: PrintPrefsUnitsPane(context: context)
        case .about:
            PrintPrefsAboutPane(context: context) {
                helpPane = .page
                showHelp = true
            }
        }
    }

    // MARK: - Druckvorschau

    private var previewPanel: some View {
        let draft = editor.draft
        let input = PrintPrefsPreviewInput(draft: draft, resolution: session.resolution)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                Text(tr("Druckvorschau"))
                    .font(Theme.Typography.headline)
                Spacer(minLength: 0)
            }
            PrintPrefsPrinterPreview(input: input, state: session.state, accent: session.accentColor,
                                     printTrigger: printTrigger, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
                fact(symbol: "ruler", text: context.length.size(widthMM: draft.widthMM, heightMM: draft.heightMM))
                fact(symbol: PrintPrefsSymbols.symbol(for: draft.settings.tracking),
                     text: draft.settings.tracking.map { tr($0.displayName) } ?? tr("Medientyp: Druckerwert"))
                fact(symbol: "rotate.right", text: tr(draft.settings.effectiveRotation.displayName))
                fact(symbol: PrintPrefsSymbols.symbol(for: draft.settings.printMode),
                     text: draft.settings.printMode.map { tr($0.displayName) } ?? tr("Modus: Druckerwert"))
                if draft.settings.mirror {
                    fact(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", text: tr("Spiegeln"))
                }
                if draft.settings.negative {
                    fact(symbol: "circle.righthalf.filled", text: tr("Invers"))
                }
                if let speed = draft.settings.speed {
                    fact(symbol: "speedometer", text: PrintPrefsChoices.speedText(speed))
                }
                if let darkness = draft.settings.darkness {
                    fact(symbol: "thermometer.medium", text: tr("Temperatur %d", darkness))
                }
            }
            .animation(spring, value: draft)
        }
        .padding(14)
        .labelWerkGlass(cornerRadius: 16)
    }

    private func fact(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.subtleFill, in: Capsule())
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Fußleiste

    private var footer: some View {
        let changes = editor.changedSettings
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: changes.isEmpty ? "checkmark.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(changes.isEmpty ? Theme.ready : Theme.warning)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(changes.isEmpty ? tr("Alle Änderungen gespeichert")
                                         : (changes.count == 1 ? tr("1 nicht gespeicherte Änderung")
                                                               : tr("%d nicht gespeicherte Änderungen", changes.count)))
                        .font(.system(size: 12.5, weight: .semibold))
                        .contentTransition(.numericText(value: Double(changes.count)))
                    Text(changes.isEmpty ? tr("Die Treiberwerte gelten für neue Aufträge.")
                                         : changes.map(\.summaryTitle).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .animation(spring, value: changes)
            Spacer(minLength: 12)
            Button(tr("OK")) {
                save(closing: true)
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(tr("Speichern und schließen (⌘↩)"))
            .overlay {
                CelebrationBurst(trigger: saveTrigger, colors: [Theme.violet, Theme.teal, Theme.ready])
                    .frame(width: 200, height: 140)
                    .allowsHitTesting(false)
            }
            Button(tr("Abbrechen")) {
                withAnimation(spring) { editor.revert() }
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(!editor.isDirty)
            .help(tr("Nicht gespeicherte Änderungen verwerfen"))
            Button(tr("Übernehmen")) {
                save(closing: false)
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(!editor.isDirty)
            .keyboardShortcut("s", modifiers: [.command])
            .help(tr("Speichern, ohne den Dialog zu verlassen (⌘S)"))
            Button(tr("Hilfe")) {
                helpPane = editor.pane
                showHelp = true
            }
            .buttonStyle(.labelWerkSecondary)
            .help(tr("Erklärungen zu allen Optionen"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .labelWerkGlass(cornerRadius: 16)
    }

    // MARK: - Aktionen

    /// „OK“ (mit `closing`) bzw. „Übernehmen“: Entwurf als Treiber-Standard speichern und – falls
    /// eingerichtet – als Standard der macOS-Warteschlange übertragen.
    private func save(closing: Bool) {
        afterCommittingTextEditing {
            let changed = editor.commit(session: session, model: model)
            if changed {
                saveTrigger += 1
                if let queue = session.saved.cupsQueueName, !queue.isEmpty, !session.isVirtual {
                    model.toast(tr("Druckeinstellungen gespeichert"),
                                message: tr("Die macOS-Warteschlange „%@“ wird aktualisiert …", queue), style: .success)
                    let session = self.session
                    let model = self.model
                    Task { await PrintPrefsQueueDefaults.apply(queue: queue, session: session, model: model) }
                } else {
                    model.toast(tr("Druckeinstellungen gespeichert"),
                                message: tr("Gilt für alle neuen Aufträge aus LabelWerk."), style: .success)
                }
            }
            if closing {
                // Wie „OK“ im Windows-Dialog: Einstellungen schließen (zurück zur Übersicht).
                withAnimation(spring) { session.section = .overview }
            }
        }
    }

    private func printTestPage() {
        guard !isPrintingTest else { return }
        afterCommittingTextEditing {
            isPrintingTest = true
            let draft = editor.draft
            Task {
                let ok = await session.printTestPage(settings: draft.settings.clamped(), widthMM: draft.widthMM,
                                                     heightMM: draft.heightMM)
                isPrintingTest = false
                if ok { printTrigger += 1 }
            }
        }
    }
}

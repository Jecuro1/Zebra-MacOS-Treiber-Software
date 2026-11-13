import AppKit
import SwiftUI
import LabelWerkKit

/// Rechte Spalte des Etikettendrucks: Drucker, Etikettentyp (Standard des Druckers oder einer seiner
/// Etikettentypen), Exemplare, Seiten, die wirksamen Einstellungen und „Drucken“.
struct LabelPrintOptionsPanel: View {
    @Bindable var store: LabelPrintStore
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Namespace private var typeNamespace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.sessions.isEmpty {
                        noPrinter
                    } else {
                        printerSection
                        if let session = store.session {
                            typeSection(session)
                        }
                        jobSection
                        if let target = store.target {
                            settingsSection(target)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            Divider().opacity(0.5)
            footer
        }
        .background(.ultraThinMaterial.opacity(0.6))
    }

    // MARK: Drucker

    private var noPrinter: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(tr("Kein Drucker eingerichtet"), systemImage: "printer.badge.plus")
                    .font(Theme.Typography.headline)
                Text(tr("Richte zuerst einen Zebra-Drucker in LabelWerk ein – danach erscheint er hier."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("Drucker hinzufügen …")) {
                    showMainWindow()
                    model.isAddPrinterPresented = true
                }
                .buttonStyle(.labelWerkPrimary)
            }
        }
    }

    private var printerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(tr("Drucker"), systemImage: "printer")
            Picker(selection: Binding(get: { store.printerID }, set: { id in
                withAnimation(reduceMotion ? nil : Motion.snappy) {
                    store.printerID = id
                    store.labelTypeID = nil
                }
            })) {
                ForEach(store.sessions) { session in
                    Text(session.displayName).tag(Optional(session.id))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if let session = store.session {
                HStack(spacing: 6) {
                    StatusOrb(state: session.state, size: 9)
                    Text(statusText(session))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
    }

    private func statusText(_ session: PrinterSession) -> String {
        switch session.connectionState {
        case .connected:
            return session.supportsStatus ? session.state.displayName : tr("Verbunden")
        case .connecting:
            return tr("Verbinde …")
        case .disconnected, .failed:
            if let queue = session.labelPrintFallbackQueues(for: store.labelType).first {
                return tr("Nicht direkt erreichbar – gedruckt wird dann über den macOS-Drucker „%@“.", queue)
            }
            return tr("Nicht verbunden – beim Drucken wird erneut verbunden.")
        }
    }

    // MARK: Etikettentyp

    private func typeSection(_ session: PrinterSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(tr("Etikettentyp"), systemImage: "square.stack.3d.up")
            typeRow(session: session, type: nil)
            ForEach(session.labelTypes) { type in
                typeRow(session: session, type: type)
            }
            Button {
                openPreferences(of: session)
            } label: {
                Label(session.labelTypes.isEmpty ? tr("Etikettentyp anlegen …") : tr("Etikettentypen verwalten …"),
                      systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.labelWerkPlain)
            .controlSize(.small)
            .help(tr("Druckeinstellungen › Etikettentypen: eigene Formate und Einstellungen, je als eigener macOS-Drucker"))
        }
    }

    private func typeRow(session: PrinterSession, type: LabelType?) -> some View {
        let isSelected = store.printerID == session.id && store.labelTypeID == type?.id
        let stock = session.stock(for: type)
        let settings = session.effectiveSettings(for: type)
        let tracking = settings.tracking ?? stock.tracking
        let subtitle = [LabelSizing.sizeText(widthMM: stock.widthMM, heightMM: stock.heightMM), tr(tracking.displayName)]
            .joined(separator: " · ")
        let queue = session.queueName(for: type)
        return Button {
            withAnimation(reduceMotion ? nil : Motion.spring) {
                store.select(type, of: session)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(type?.name ?? tr("Standard des Druckers"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let queue {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(tr("macOS-Drucker „%@“", queue))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
                        .matchedGeometryEffect(id: "selectedType", in: typeNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.subtleFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Auftrag

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(tr("Auftrag"), systemImage: "doc.on.doc")
            NumberStepperField(title: tr("Exemplare"), value: $store.copies, range: 1...9999)
            HStack(spacing: 8) {
                Text(tr("Seiten"))
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Picker(selection: $store.pageMode.animation(reduceMotion ? nil : Motion.snappy)) {
                    ForEach(LabelPrintStore.PageMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            Text(pagesCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(store.jobPages.isEmpty ? Theme.warning : .secondary)
                .contentTransition(.opacity)
        }
    }

    private var pagesCaption: String {
        switch store.pageMode {
        case .all:
            return store.pages.count == 1 ? tr("Die Seite des Dokuments") : tr("Alle %d Seiten", store.pages.count)
        case .selection:
            let pages = store.jobPages
            if pages.isEmpty { return tr("Keine Seite markiert – links Seiten markieren.") }
            return tr("Seiten %@ (links markiert)", LabelPrintPageRanges.describe(pages))
        }
    }

    // MARK: Einstellungen

    private func settingsSection(_ target: LabelPrintTarget) -> some View {
        let s = target.settings.clamped()
        let printerValue = tr("Druckerwert")
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(tr("Einstellungen"), systemImage: "slider.horizontal.3")
            VStack(spacing: 0) {
                KeyValueRow(tr("Drehung"), tr(s.effectiveRotation.displayName))
                KeyValueRow(tr("An Etikett anpassen"), tr(s.fitToLabel.displayName))
                KeyValueRow(tr("Temperatur"), s.darkness.map { String($0) } ?? printerValue)
                KeyValueRow(tr("Geschwindigkeit"), s.speed.map { tr("%d Zoll/s", $0) } ?? printerValue)
                KeyValueRow(tr("Druckmodus"), s.mediaType.map { tr($0.displayName) } ?? printerValue)
                if s.labelTop != nil || s.labelLeft != nil {
                    KeyValueRow(tr("Versatz oben/links"),
                                tr("%d / %d Punkte", s.labelTop ?? 0, s.labelLeft ?? 0))
                }
                if s.mirror || s.negative {
                    KeyValueRow(tr("Spiegeln/Invertieren"),
                                [s.mirror ? tr("Spiegeln") : nil, s.negative ? tr("Invertieren") : nil]
                                    .compactMap { $0 }.joined(separator: ", "))
                }
                KeyValueRow(tr("Rasterung"), tr(s.dither.displayName))
            }
            if let session = store.session {
                Button {
                    openPreferences(of: session)
                } label: {
                    Label(tr("Druckeinstellungen öffnen …"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.labelWerkPlain)
                .controlSize(.small)
            }
        }
    }

    // MARK: Fußzeile

    private var summary: String {
        guard let target = store.target else { return "" }
        let count = store.labelCount
        let labels = count == 1 ? tr("1 Etikett") : tr("%d Etiketten", count)
        let size = target.labelHeightDots == nil
            ? tr("%@ mm breit · Endlos", LabelSizing.format(target.stock.widthMM))
            : LabelSizing.sizeText(widthMM: target.stock.widthMM, heightMM: target.stock.heightMM)
        return [labels, size, store.labelType?.name ?? tr("Standard")].joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.target != nil {
                Text(summary)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.snappy, value: summary)
            }
            Button {
                // „Exemplare“ ist ein Zahlenfeld: Ein getippter Wert kommt erst beim Beenden der
                // Bearbeitung im Zustand an – Klick bzw. ⏎ beenden sie nicht von selbst.
                afterCommittingTextEditing {
                    guard canPrint else { return }
                    store.printLabels()
                }
            } label: {
                HStack(spacing: 8) {
                    printButtonIcon
                    Text(printButtonTitle)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.labelWerkPrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canPrint)
            .help(tr("Druckt genau die Etiketten der Vorschau (⏎)"))
        }
        .padding(16)
        .animation(reduceMotion ? nil : Motion.snappy, value: store.printPhase)
    }

    private var canPrint: Bool {
        store.session != nil && store.isReady && store.printPhase != .sending && store.labelCount > 0
    }

    @ViewBuilder
    private var printButtonIcon: some View {
        switch store.printPhase {
        case .sending:
            ProgressView().controlSize(.small).tint(.white)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .symbolEffect(.bounce, value: store.printSuccessCount)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        case .idle:
            if store.isRendering {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "printer.fill")
            }
        }
    }

    private var printButtonTitle: String {
        switch store.printPhase {
        case .sending:
            // Etikett für Etikett: „Etikett 37 von 50“ bzw. der Wartegrund („Papier leer“).
            if let job = store.session?.printJob {
                if let reason = job.waiting { return PrintJobProgress.title(for: reason) }
                if job.paced { return job.counterText }
            }
            return tr("Wird gedruckt …")
        case .success(.direct): return tr("Gedruckt")
        case .success(.queue): return tr("An macOS übergeben")
        case .failure: return tr("Erneut drucken")
        case .idle:
            if store.isRendering, let key = store.renderedKey {
                return tr("Wird vorbereitet … %d/%d", store.renderedCount, key.pages.count)
            }
            return tr("Drucken")
        }
    }

    // MARK: Hauptfenster

    private func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !MainWindow.bringToFront() {
            openWindow(id: "main")
        }
    }

    /// Öffnet „Druckeinstellungen“ des Druckers im Hauptfenster (dort auch die Etikettentypen).
    private func openPreferences(of session: PrinterSession) {
        model.selection = .printer(session.id)
        model.pendingSection = .preferences
        if session.availableSections.contains(.preferences) { session.section = .preferences }
        showMainWindow()
    }
}

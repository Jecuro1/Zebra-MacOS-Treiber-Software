import AppKit
import SwiftUI
import LabelWerkKit

/// Etiketten-Designer: ZPL-Editor mit Live-Vorschau, Vorlagen und Bausteinen sowie
/// Bild-/PDF-Druck mit Rasterungsvergleich – eine Funktion, die der Windows-Treiber nicht bietet.
struct DesignerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @AppStorage("designer.targetPrinterID") private var storedTargetID = ""
    @AppStorage("designer.stockOverrideID") private var stockOverrideID = ""
    @AppStorage("designer.fallbackResolution") private var fallbackResolution: Resolution = .dpi203

    @State private var isTargetPickerPresented = false
    @State private var didSetUp = false

    init() {}

    /// Vorschau, Bild, Arbeitsbereich und Titel überdauern das Verlassen des Designers.
    @MainActor private var store: DesignerStore { .shared }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    /// Zieldrucker: gespeicherte Wahl, sonst ausgewählter bzw. erster Drucker.
    private var targetSession: PrinterSession? {
        if let id = UUID(uuidString: storedTargetID), let session = model.session(for: id) {
            return session
        }
        return model.selectedSession ?? model.sessions.first
    }

    private var stockOverride: LabelStock? {
        stockOverrideID.isEmpty ? nil : model.stock(id: stockOverrideID)
    }

    var body: some View {
        @Bindable var store = store
        let session = targetSession
        let target = DesignerTarget.make(session: session, stockOverride: stockOverride,
                                         fallbackResolution: fallbackResolution)
        let pending = store.pendingReplacement
        VStack(spacing: 0) {
            header(target: target, session: session)
                .padding(.horizontal, Theme.Metrics.paddingLarge)
                .padding(.top, Theme.Metrics.padding)

            AnimatedTabBar(items: DesignerMode.allCases, selection: $store.mode,
                           title: { $0.title }, systemImage: { $0.systemImage })
                .padding(.horizontal, Theme.Metrics.paddingLarge)
                .padding(.vertical, 12)

            ZStack {
                switch store.mode {
                case .zpl:
                    DesignerZPLWorkspace(target: target, session: session, store: store, reduceMotion: reduceMotion)
                        .transition(transition(from: .leading))
                case .image:
                    DesignerImageWorkspace(target: target, session: session, state: store.image,
                                           reduceMotion: reduceMotion,
                                           onAdopt: { zpl, title in adopt(zpl, title: title) })
                        .transition(transition(from: .trailing))
                }
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: store.mode)
        }
        .background {
            AnimatedBackground(style: .subtle)
                .ignoresSafeArea()
        }
        .navigationTitle(tr("Etiketten-Designer"))
        .navigationSubtitle(target.summary)
        .confirmationDialog(pending?.origin == .template ? tr("Vorlage übernehmen?") : tr("Dokument ersetzen?"),
                            isPresented: Binding(get: { store.pendingReplacement != nil },
                                                 set: { if !$0 { store.pendingReplacement = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { replacement in
            Button(tr("Dokument ersetzen")) { perform(replacement, append: false) }
            Button(tr("Als weiteres Etikett anhängen")) { perform(replacement, append: true) }
            Button(tr("Abbrechen"), role: .cancel) { store.pendingReplacement = nil }
        } message: { replacement in
            Text(tr("Der Editor enthält Änderungen. „%@“ ersetzt den Inhalt – oder wird als zusätzliches Etikett angehängt.",
                    replacement.title))
        }
        .onAppear { setUp(target: target) }
    }

    private func transition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: edge).combined(with: .opacity),
                                              removal: .opacity)
    }

    // MARK: Kopf

    private func header(target: DesignerTarget, session: PrinterSession?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(systemImage: "pencil.and.ruler", tint: Theme.violet, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Etiketten-Designer"))
                    .font(Theme.Typography.title)
                Text(tr("ZPL live gestalten, Bilder und PDFs gestochen scharf rastern – und direkt drucken."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            DesignerTargetButton(target: target, session: session, reduceMotion: reduceMotion) {
                isTargetPickerPresented.toggle()
            }
            .popover(isPresented: $isTargetPickerPresented, arrowEdge: .bottom) {
                DesignerTargetPicker(currentSessionID: session?.id, target: target,
                                     fallbackResolution: $fallbackResolution, stockOverrideID: $stockOverrideID,
                                     reduceMotion: reduceMotion,
                                     onSelectSession: { id in storedTargetID = id.uuidString },
                                     onAddDemo: { addDemoPrinter() })
                    .environment(model)
            }
        }
    }

    // MARK: Aktionen

    private func setUp(target: DesignerTarget) {
        guard !didSetUp else { return }
        didSetUp = true
        let image = store.image
        if !image.didApplyPreferences {
            image.dither = model.preferences.imageDither
            image.didApplyPreferences = true
        }
        if model.designerDocument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let template = DesignerTemplate.suggested(for: target.stock)
            model.designerDocument = template.zpl(geometry: target.geometry)
            store.documentTitle = template.title
            // Die Startvorlage gilt als unverändert: Eine andere Vorlage ersetzt sie ohne Rückfrage.
            store.markGenerated(model.designerDocument)
        }
    }

    /// Übernimmt ZPL aus „Bild & PDF“ (bei geändertem Dokument erst nach Rückfrage).
    private func adopt(_ zpl: String, title: String) {
        let replacement = DesignerReplacement(zpl: zpl, title: title, systemImage: "photo.on.rectangle.angled",
                                              origin: .image, notice: tr("Übernommen: %@", title))
        if store.request(replacement, in: model) {
            didAdopt(title)
        }
    }

    /// Antwort aus dem Rückfrage-Dialog.
    private func perform(_ replacement: DesignerReplacement, append: Bool) {
        store.apply(replacement, append: append, in: model)
        if replacement.origin == .image {
            didAdopt(replacement.title)
        }
    }

    /// Nach der Übernahme animiert in den Editor wechseln.
    private func didAdopt(_ title: String) {
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            store.mode = .zpl
        }
        model.toast(tr("In den Designer übernommen"), message: title, style: .success)
    }

    private func addDemoPrinter() {
        let session = model.addDemoPrinter()
        // Im Designer bleiben (addDemoPrinter wählt den neuen Drucker in der Seitenleiste aus).
        model.selection = .designer
        storedTargetID = session.id.uuidString
    }
}

// MARK: - Zielwahl

/// Kapsel oben rechts: Zieldrucker mit Status, Auflösung und Etikettengröße.
private struct DesignerTargetButton: View {
    let target: DesignerTarget
    let session: PrinterSession?
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let session {
                    StatusOrb(state: session.state, size: 9)
                } else {
                    Image(systemName: "printer.dotmatrix")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.printerName ?? tr("Kein Drucker"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(target.detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .labelWerkGlass(cornerRadius: 12, tint: session?.accentColor)
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { hovering = inside }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: target)
        .help(tr("Zieldrucker und Etikettenformat wählen"))
    }
}

/// Auswahl von Zieldrucker, Etikettenformat und (ohne Drucker) Vorschau-Auflösung.
private struct DesignerTargetPicker: View {
    @Environment(AppModel.self) private var model
    let currentSessionID: UUID?
    let target: DesignerTarget
    @Binding var fallbackResolution: Resolution
    @Binding var stockOverrideID: String
    let reduceMotion: Bool
    let onSelectSession: (UUID) -> Void
    let onAddDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(tr("Zieldrucker"),
                          subtitle: tr("Bestimmt Auflösung, Etikettengröße und wohin gedruckt wird."),
                          systemImage: "printer")
            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Noch kein Drucker eingerichtet. Der Designer funktioniert trotzdem – wähle die Auflösung für die Vorschau."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DesignerChoiceBar(items: Resolution.allCases, selection: $fallbackResolution,
                                      reduceMotion: reduceMotion, title: { $0.displayName })
                    if model.preferences.showDemoPrinter {
                        Button(action: onAddDemo) {
                            Label(tr("Demo-Drucker hinzufügen"), systemImage: "sparkles")
                        }
                        .buttonStyle(.labelWerkSecondary)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(model.sessions) { session in
                        DesignerTargetRow(session: session, isSelected: session.id == currentSessionID,
                                          reduceMotion: reduceMotion) {
                            onSelectSession(session.id)
                        }
                    }
                }
            }

            Divider()

            SectionHeader(tr("Etikettenformat"),
                          subtitle: tr("Standard ist das am Drucker eingestellte Format."),
                          systemImage: "square.stack.3d.up")
            Picker(selection: $stockOverrideID) {
                Text(tr("Wie am Drucker eingestellt")).tag("")
                Divider()
                ForEach(LabelStock.Category.allCases, id: \.self) { category in
                    let stocks = model.allStocks.filter { $0.category == category }
                    if !stocks.isEmpty {
                        Section(tr(category.displayName)) {
                            ForEach(stocks) { stock in
                                Text(stock.name).tag(stock.id)
                            }
                        }
                    }
                }
            } label: {
                Text(tr("Format"))
            }
            .pickerStyle(.menu)

            VStack(spacing: 2) {
                KeyValueRow(tr("Etikett"), target.stock.name)
                KeyValueRow(tr("Druckfläche"), target.sizeText)
                KeyValueRow(tr("Druckpunkte"), tr("%d × %d", target.widthDots, target.heightDots))
                KeyValueRow(tr("Auflösung"), tr("%d dpi (%d Punkte/mm)", target.resolution.dpi, target.resolution.dotsPerMM))
            }
            if let maxWidth = target.maxPrintWidthDots, target.stock.widthDots(target.resolution) > maxWidth {
                Label(tr("Das Etikett ist breiter als der Druckkopf – die Druckfläche wird auf die Kopfbreite begrenzt."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}

private struct DesignerTargetRow: View {
    let session: PrinterSession
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(systemImage: session.model?.systemImage ?? "printer", tint: session.accentColor, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text([session.model?.displayName ?? tr("Unbekanntes Modell"), session.resolution.displayName,
                          session.stock.name].joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                StatusOrb(state: session.state, size: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : (hovering ? Theme.subtleFill : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isSelected)
    }
}

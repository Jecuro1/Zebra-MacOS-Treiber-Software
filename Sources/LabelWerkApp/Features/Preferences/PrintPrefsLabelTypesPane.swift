import SwiftUI
import LabelWerkKit

// MARK: - Etikettentypen

/// „Etikettentypen“: eigene macOS-Drucker je Etikett (ARCHITECTURE.md §9 „Etikettentypen“). Jeder Typ hat
/// ein Format und optionale Abweichungen von den Einstellungen des Druckers („wie Drucker“); LabelWerk
/// richtet dafür automatisch eine macOS-Warteschlange „<Drucker> – <Typ>“ ein (`QueueSyncService`).
///
/// Anders als die übrigen Bereiche gelten Änderungen hier sofort (Sichern im Bearbeitungsfenster) – „OK“
/// und „Übernehmen“ betreffen nur die Einstellungen des Druckers.
@MainActor
struct PrintPrefsLabelTypesPane: View {
    let context: PrintPrefsContext
    @Environment(AppModel.self) private var model

    @State private var editing: LabelTypeEditorDraft?
    @State private var pendingDeletion: LabelType?

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var session: PrinterSession { context.session }

    var body: some View {
        let types = session.labelTypes
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            introduction
            PrintPrefsGroup(tr("Etikettentypen"), systemImage: "tag") {
                if types.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        ForEach(types) { type in
                            LabelTypeCard(type: type, context: context,
                                          onEdit: { edit(type) },
                                          onDelete: { pendingDeletion = type })
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    }
                }
                addRow
                    .padding(.top, 6)
            }
            if let note = availabilityNote {
                PrintPrefsHint(note, systemImage: "exclamationmark.triangle", tint: Theme.warning)
                    .padding(.horizontal, 4)
            }
        }
        .animation(context.animation, value: types)
        .sheet(item: $editing) { draft in
            LabelTypeEditorSheet(draft: draft, session: session, length: context.length)
                .environment(model)
        }
        .confirmationDialog(
            pendingDeletion.map { tr("Etikettentyp „%@“ löschen?", $0.name) } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { type in
            Button(tr("Löschen"), role: .destructive) { delete(type) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { type in
            Text(tr("Der macOS-Drucker „%@“ wird ebenfalls entfernt. Das Etikettenformat bleibt erhalten.",
                    QueueSyncService.labelTypeQueueDescription(type, of: session)))
        }
    }

    // MARK: Teile

    /// Kurze Erklärung mit dem Namen, unter dem ein Typ im Druckdialog erscheint.
    private var introduction: some View {
        let example = LabelTypeQueueNaming.description(printerName: session.saved.name,
                                                       modelName: session.model?.displayName,
                                                       host: QueueSyncService.host(of: session.saved.descriptor),
                                                       typeName: tr("Brillenetikett"))
        return HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: "printer.filled.and.paper", tint: Theme.teal, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Ein macOS-Drucker je Etikett"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("Jeder Etikettentyp erscheint in macOS als eigener Drucker, z. B. „%@“. Im Druckdialog einfach diesen Drucker wählen – Format und Einstellungen kommen von hier.", example))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.teal.opacity(0.25), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tag.square")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.brandGradient)
                .symbolEffect(.pulse, options: .nonRepeating, isActive: !context.reduceMotion)
            Text(tr("Noch keine Etikettentypen"))
                .font(.system(size: 13, weight: .semibold))
            Text(tr("Legen Sie für jedes Etikett, das Sie regelmäßig drucken – z. B. Brillen- oder Schmucketiketten –, einen Typ mit Format und Einstellungen an."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Button {
                addNew()
            } label: {
                Label(tr("Etikettentyp hinzufügen"), systemImage: "plus")
            }
            .buttonStyle(.labelWerkPrimary)
            Spacer(minLength: 8)
            if !session.labelTypes.isEmpty {
                Text(tr("Änderungen gelten sofort – „OK“ ist dafür nicht nötig."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// Hinweis, wenn für diesen Drucker keine macOS-Drucker angelegt werden können.
    private var availabilityNote: String? {
        if session.isVirtual {
            return tr("Der Demo-Drucker hat keinen macOS-Drucker – Etikettentypen gelten hier nur für Drucke aus LabelWerk.")
        }
        if !CUPSService.isDriverInstalled {
            return tr("Der LabelWerk-Treiber ist nicht installiert. Etikettentypen erscheinen in macOS, sobald er unter „Treiber“ installiert ist.")
        }
        switch session.saved.descriptor {
        case .bluetooth, .ble:
            if session.saved.cupsQueueName == nil {
                return tr("Über Bluetooth verbundene Drucker können keine macOS-Drucker erhalten. Richten Sie den Drucker per Netzwerk oder USB ein.")
            }
            return nil
        case .tcp, .usb, .cupsQueue, .virtual:
            return nil
        }
    }

    // MARK: Aktionen

    private func addNew() {
        editing = LabelTypeEditorDraft(type: nil, session: session)
    }

    private func edit(_ type: LabelType) {
        editing = LabelTypeEditorDraft(type: type, session: session)
    }

    private func delete(_ type: LabelType) {
        let name = type.name
        model.removeLabelType(id: type.id, from: session)
        pendingDeletion = nil
        model.toast(tr("Etikettentyp gelöscht"), message: name, style: .info)
    }
}

// MARK: - Karte

/// Ein Etikettentyp in der Liste: Format, Medientyp, macOS-Drucker mit Zustand, Abweichungen.
@MainActor
private struct LabelTypeCard: View {
    let type: LabelType
    let context: PrintPrefsContext
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    private var session: PrinterSession { context.session }

    var body: some View {
        let stock = session.stock(for: type)
        let status = model.queueSync.labelTypeStatus.status(for: type.id)
        HStack(alignment: .center, spacing: 12) {
            LabelTypeThumbnail(widthMM: stock.widthMM, heightMM: stock.heightMM, isContinuous: stock.isContinuous)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: type.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    overridesBadge
                }
                Text(details(stock: stock))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.brandGradient)
                    Text(verbatim: QueueSyncService.labelTypeQueueDescription(type, of: session))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LabelTypeStatusChip(status: status)
                    if case .failed = status {
                        Button(tr("Erneut versuchen")) { retry() }
                            .buttonStyle(.labelWerkPlain)
                            .controlSize(.small)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Bearbeiten"))
                .accessibilityLabel(tr("„%@“ bearbeiten", type.name))
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.error)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Löschen"))
                .accessibilityLabel(tr("„%@“ löschen", type.name))
            }
            .opacity(isHovered ? 1 : 0.7)
        }
        .padding(10)
        .background(Theme.subtleFill.opacity(isHovered ? 1.8 : 1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2, perform: onEdit)
        .onHover { inside in
            withAnimation(context.reduceMotion ? nil : Motion.snappy) { isHovered = inside }
        }
        .contextMenu {
            Button(tr("Bearbeiten …"), action: onEdit)
            Button(tr("Löschen …"), role: .destructive, action: onDelete)
        }
        .animation(context.animation, value: status)
    }

    @ViewBuilder
    private var overridesBadge: some View {
        let count = type.overrides.count
        Text(count == 0 ? tr("wie Drucker") : (count == 1 ? tr("1 Abweichung") : tr("%d Abweichungen", count)))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(count == 0 ? Color.secondary : Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((count == 0 ? Theme.subtleFill : Theme.accent.opacity(0.12)), in: Capsule())
            .contentTransition(.numericText(value: Double(count)))
    }

    /// „22,0 × 13,0 mm · Einzeletiketten · Thermotransfer“.
    private func details(stock: LabelStock) -> String {
        let settings = session.effectiveSettings(for: type)
        var parts = [context.length.size(widthMM: stock.widthMM, heightMM: stock.heightMM)]
        parts.append(settings.tracking.map { tr($0.displayName) } ?? tr("Medientyp: Druckerwert"))
        if let mediaType = settings.mediaType { parts.append(tr(mediaType.displayName)) }
        return parts.joined(separator: " · ")
    }

    private func retry() {
        let printer = session
        let app = model
        Task { await app.queueSync.syncLabelTypesNow(printer) }
    }
}

/// Etikett im Seitenverhältnis des Formats (Miniatur).
private struct LabelTypeThumbnail: View {
    let widthMM: Double
    let heightMM: Double
    let isContinuous: Bool

    var body: some View {
        GeometryReader { geo in
            let aspect = max(0.05, widthMM) / max(0.05, isContinuous ? widthMM * 1.4 : heightMM)
            let side = min(geo.size.width, geo.size.height)
            let width = aspect >= 1 ? side : side * aspect
            let height = aspect >= 1 ? side / aspect : side
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.labelPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: max(1.5, height * 0.08)) {
                        ForEach(0..<3, id: \.self) { line in
                            Capsule()
                                .fill(Theme.labelInk.opacity(line == 0 ? 0.75 : 0.35))
                                .frame(width: max(3, width * (line == 0 ? 0.6 : 0.42)), height: max(1.2, height * 0.1))
                        }
                    }
                    .padding(.leading, max(2, width * 0.12))
                }
                .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
                .frame(width: max(6, width), height: max(6, height))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// Zustand des macOS-Druckers eines Typs.
private struct LabelTypeStatusChip: View {
    let status: LabelTypeQueueStatusStore.Status

    var body: some View {
        HStack(spacing: 4) {
            if case .syncing = status {
                ProgressRing(progress: nil, size: 10, lineWidth: 1.6)
            } else {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.13), in: Capsule())
        .help(helpText)
        .fixedSize()
    }

    private var title: String {
        switch status {
        case .pending: return tr("Wird geprüft …")
        case .syncing: return tr("Wird eingerichtet …")
        case .ready: return tr("Bereit")
        case .failed: return tr("Fehler")
        case .unavailable: return tr("Nicht verfügbar")
        }
    }

    private var symbol: String {
        switch status {
        case .pending, .syncing: return "clock"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .unavailable: return "slash.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .pending: return Theme.offline
        case .syncing: return Theme.printing
        case .ready: return Theme.ready
        case .failed: return Theme.error
        case .unavailable: return Theme.offline
        }
    }

    private var helpText: String {
        switch status {
        case .pending: return tr("LabelWerk prüft den macOS-Drucker gleich.")
        case .syncing: return tr("Der macOS-Drucker wird eingerichtet bzw. abgeglichen.")
        case .ready(let queue): return tr("macOS-Warteschlange „%@“ ist eingerichtet und auf dem Stand.", queue)
        case .failed(let message): return message
        case .unavailable(let reason): return reason
        }
    }
}

// MARK: - Entwurf

/// Werte des Bearbeitungsfensters eines Etikettentyps.
struct LabelTypeEditorDraft: Identifiable, Equatable {
    var id: UUID
    var isNew: Bool
    var name: String
    var stockChoice: LabelStockChoice
    var entry: LabelSizeEntry
    var overrides: LabelTypeOverrides

    /// Neuer Typ (`type == nil`, mit dem Format des Druckers) bzw. Bearbeiten eines vorhandenen.
    @MainActor
    init(type: LabelType?, session: PrinterSession) {
        id = type?.id ?? UUID()
        isNew = type == nil
        name = type?.name ?? ""
        let stock = session.stock(for: type)
        stockChoice = .stock(stock.id)
        entry = LabelSizeEntry(widthMM: stock.widthMM, heightMM: stock.heightMM, tracking: stock.tracking)
        overrides = type?.overrides ?? LabelTypeOverrides()
    }
}

// MARK: - Bearbeiten

/// Bearbeitungsfenster: Name, Etikett (gemeinsame Auswahl mit dem Installationsassistenten:
/// Formate, „Vom Drucker“, „Benutzerdefiniert …“) und die Abweichungen von den Druckereinstellungen –
/// jede mit „Wie Drucker“ als Standard.
@MainActor
struct LabelTypeEditorSheet: View {
    let session: PrinterSession
    let length: PrintPrefsLength

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var draft: LabelTypeEditorDraft
    @State private var detected: DetectedMedia?
    @State private var isReadingMedia = false
    @FocusState private var nameFocused: Bool

    init(draft: LabelTypeEditorDraft, session: PrinterSession, length: PrintPrefsLength) {
        self.session = session
        self.length = length
        _draft = State(initialValue: draft)
        _nameFocused = FocusState()
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var animation: Animation? { reduceMotion ? nil : Motion.spring }
    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var limits: LabelSizing.Limits { LabelSizing.Limits(model: session.model) }

    // MARK: Format

    private var detectedMatch: LabelStock? {
        detected.flatMap { LabelStockLibrary.matchingStock(for: $0, model: model) }
    }

    /// Formate der Auswahl: passend zur Druckbreite des Modells, dazu das gewählte.
    private var stockOptions: [LabelStock] {
        let printer = session.model
        var list = model.allStocks.filter { stock in
            guard let printer else { return true }
            return stock.widthMM <= printer.printWidthMM + 2 && stock.heightMM <= printer.maxLabelLengthMM
        }
        if let id = draft.stockChoice.stockID, !list.contains(where: { $0.id == id }), let stock = model.stock(id: id) {
            list.append(stock)
        }
        return list
    }

    /// Gewähltes Format – bei „Vom Drucker“ und „Benutzerdefiniert …“ eine Vorschau, die erst beim Sichern
    /// ein echtes Format wird (`nil` = Eingabe ungültig).
    private var selectedStock: LabelStock? {
        switch draft.stockChoice {
        case .stock(let id):
            return model.stock(id: id)
        case .printer:
            guard let media = detected else { return nil }
            return detectedMatch ?? LabelStock(id: "detected", name: tr("Vom Drucker: %@", media.sizeText),
                                               widthMM: media.widthMM, heightMM: media.heightMM,
                                               tracking: media.tracking ?? .gap, mediaType: media.mediaType)
        case .custom:
            guard let size = draft.entry.size(in: limits) else { return nil }
            return LabelStock(id: "custom-entry",
                              name: LabelStockLibrary.customStockName(widthMM: size.widthMM, heightMM: size.heightMM),
                              widthMM: size.widthMM, heightMM: size.heightMM, tracking: draft.entry.tracking)
        }
    }

    /// Einstellungen ohne Abweichungen: was „Wie Drucker“ für dieses Format bedeutet.
    private var inherited: PrintSettings {
        let stock = selectedStock ?? session.stock
        return LabelType(id: draft.id, name: trimmedName, stockID: stock.id)
            .settings(printerSettings: session.saved.settings, printerStock: session.stock, stock: stock)
    }

    /// Wirksame Einstellungen des Entwurfs.
    private var effective: PrintSettings {
        draft.overrides.applied(to: inherited)
    }

    private var errors: [String] {
        var list: [String] = []
        if trimmedName.isEmpty { list.append(tr("Bitte einen Namen eingeben.")) }
        if session.labelTypes.contains(where: {
            $0.id != draft.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            list.append(tr("Dieser Drucker hat bereits einen Etikettentyp mit diesem Namen."))
        }
        if selectedStock == nil {
            list.append(draft.stockChoice == .custom ? tr("Bitte Breite und Höhe des Etiketts prüfen.")
                                                     : tr("Bitte ein Etikett wählen."))
        }
        return list
    }

    private var printerDescription: String {
        LabelTypeQueueNaming.description(printerName: session.saved.name, modelName: session.model?.displayName,
                                         host: QueueSyncService.host(of: session.saved.descriptor),
                                         typeName: trimmedName.isEmpty ? tr("Etikettentyp") : trimmedName)
    }

    // MARK: Ansicht

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    form
                        .padding(.trailing, 6)
                }
                .scrollIndicators(.automatic)
                .frame(width: 470)
                preview
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
            Divider()
            footer
        }
        .frame(width: 820, height: 640)
        .background {
            AnimatedBackground(style: .subtle)
                .ignoresSafeArea()
        }
        .onAppear {
            if draft.isNew { nameFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: draft.isNew ? "tag.fill" : "square.and.pencil", tint: Theme.teal, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isNew ? tr("Neuer Etikettentyp") : tr("Etikettentyp bearbeiten"))
                    .font(Theme.Typography.title)
                Text(tr("Format und Einstellungen für einen eigenen macOS-Drucker von %@", session.displayName))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                caption(tr("Name"))
                TextField(tr("z. B. Brillenetikett"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                caption(tr("Etikett"))
                LabelStockChooser(choice: stockChoiceBinding, entry: $draft.entry, stocks: stockOptions,
                                  detected: detected, detectedMatch: detectedMatch, limits: limits,
                                  isReadingMedia: isReadingMedia, note: mediaNote,
                                  onReadFromPrinter: readFromPrinterAction,
                                  reduceMotion: reduceMotion)
            }

            VStack(alignment: .leading, spacing: 8) {
                caption(tr("Abweichungen vom Drucker"))
                VStack(alignment: .leading, spacing: 8) {
                    overrides
                }
                .padding(12)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !draft.overrides.isEmpty {
                    Button {
                        withAnimation(animation) { draft.overrides = LabelTypeOverrides() }
                    } label: {
                        Label(tr("Alle wie Drucker"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    .transition(.opacity)
                }
            }
        }
        .animation(animation, value: draft.overrides)
    }

    // MARK: Abweichungen

    @ViewBuilder
    private var overrides: some View {
        let base = inherited
        overridePicker(tr("Drehung"), selection: $draft.overrides.rotation, options: PrintRotation.allCases,
                       inherited: tr(base.effectiveRotation.displayName)) { tr($0.displayName) }
        overridePicker(tr("Temperatur"), selection: $draft.overrides.darkness,
                       options: PrintPrefsChoices.temperatures(current: draft.overrides.darkness),
                       inherited: base.darkness.map { String($0) } ?? tr("Druckerwert")) { String($0) }
        overridePicker(tr("Geschwindigkeit"), selection: $draft.overrides.speed,
                       options: PrintPrefsChoices.speeds(session, current: draft.overrides.speed),
                       inherited: base.speed.map { PrintPrefsChoices.speedText($0) } ?? tr("Druckerwert")) {
            PrintPrefsChoices.speedText($0)
        }
        offsetRow(tr("Versatz oben"), value: $draft.overrides.labelTop, range: -120...120,
                  inherited: base.labelTop)
        offsetRow(tr("Versatz links"), value: $draft.overrides.labelLeft, range: -9999...9999,
                  inherited: base.labelLeft)
        overridePicker(tr("Medientyp"), selection: $draft.overrides.mediaTracking,
                       options: PrintPrefsChoices.trackingOrder,
                       inherited: base.tracking.map { tr($0.displayName) } ?? tr("Druckerwert")) { tr($0.displayName) }
        overridePicker(tr("Druckmodus"), selection: $draft.overrides.mediaType,
                       options: PrintPrefsChoices.mediaTypes(session, current: draft.overrides.mediaType),
                       inherited: base.mediaType.map { tr($0.displayName) } ?? tr("Druckerwert")) { tr($0.displayName) }
        overridePicker(tr("Bedienermodus"), selection: $draft.overrides.printMode,
                       options: PrintPrefsChoices.printModes(session, language: session.saved.language,
                                                             current: draft.overrides.printMode),
                       inherited: base.printMode.map { tr($0.displayName) } ?? tr("Druckerwert")) { tr($0.displayName) }
    }

    private func overrideRow<Content: View>(_ title: String, isSet: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .scaleEffect(isSet ? 1 : 0.2)
                .opacity(isSet ? 1 : 0)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 128, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Auswahl mit „Wie Drucker · <Wert>“ als erstem Eintrag (`nil`).
    private func overridePicker<Value: Hashable>(_ title: String, selection: Binding<Value?>, options: [Value],
                                                 inherited: String,
                                                 label: @escaping (Value) -> String) -> some View {
        overrideRow(title, isSet: selection.wrappedValue != nil) {
            Picker(title, selection: selection) {
                Text(tr("Wie Drucker · %@", inherited)).tag(Value?.none)
                Divider()
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(Value?.some(option))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
        }
    }

    /// Versatz in Druckpunkten: „Eigener Wert“ schaltet das Feld ein, sonst gilt der Wert des Druckers.
    private func offsetRow(_ title: String, value: Binding<Int?>, range: ClosedRange<Int>, inherited: Int?) -> some View {
        let isSet = value.wrappedValue != nil
        let animation = self.animation
        return overrideRow(title, isSet: isSet) {
            HStack(spacing: 10) {
                Toggle(tr("Eigener Wert"), isOn: Binding(
                    get: { value.wrappedValue != nil },
                    set: { on in
                        withAnimation(animation) {
                            value.wrappedValue = on ? (value.wrappedValue ?? inherited ?? 0).clamped(to: range) : nil
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                if isSet {
                    PrintPrefsMeasureField(dots: Binding(get: { value.wrappedValue ?? 0 },
                                                         set: { value.wrappedValue = $0 }),
                                           range: range, length: length, width: 70)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                } else {
                    Text(tr("Wie Drucker · %@", inherited.map { length.text(dots: $0) } ?? tr("Druckerwert")))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Vorschau

    private var preview: some View {
        let stock = selectedStock
        let settings = effective
        return VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.subtleFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                if let stock {
                    StockLibraryLabelArt(widthMM: stock.widthMM, heightMM: stock.heightMM, gapMM: stock.gapMM,
                                         tracking: settings.tracking ?? stock.tracking,
                                         maxSize: CGSize(width: 220, height: 190),
                                         printableWidthMM: session.model?.printWidthMM)
                        .rotationEffect(.degrees(settings.effectiveRotation == .r180 ? 180 : 0))
                        .padding(18)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(tr("Etikett wählen"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 270)
            .animation(reduceMotion ? nil : Motion.bouncy, value: stock?.widthMM)
            .animation(reduceMotion ? nil : Motion.bouncy, value: stock?.heightMM)
            .animation(reduceMotion ? nil : Motion.spring, value: settings.effectiveRotation)

            VStack(alignment: .leading, spacing: 6) {
                caption(tr("Im Druckdialog"))
                HStack(spacing: 8) {
                    Image(systemName: "printer.fill")
                        .foregroundStyle(Theme.brandGradient)
                    Text(verbatim: printerDescription)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
                    if let stock {
                        fact(symbol: "ruler", text: length.size(widthMM: stock.widthMM, heightMM: stock.heightMM))
                    }
                    fact(symbol: PrintPrefsSymbols.symbol(for: settings.tracking),
                         text: settings.tracking.map { tr($0.displayName) } ?? tr("Medientyp: Druckerwert"))
                    if let mediaType = settings.mediaType {
                        fact(symbol: PrintPrefsSymbols.symbol(for: mediaType), text: tr(mediaType.displayName))
                    }
                    fact(symbol: "rotate.right", text: tr(settings.effectiveRotation.displayName))
                    if let darkness = settings.darkness {
                        fact(symbol: "thermometer.medium", text: tr("Temperatur %d", darkness))
                    }
                    if let speed = settings.speed {
                        fact(symbol: "speedometer", text: PrintPrefsChoices.speedText(speed))
                    }
                    if let mode = settings.printMode {
                        fact(symbol: PrintPrefsSymbols.symbol(for: mode), text: tr(mode.displayName))
                    }
                }
                .animation(animation, value: settings)
                PrintPrefsHint(tr("Alle übrigen Einstellungen (Rasterung, Befehle, …) folgen dem Drucker."))
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(errors, id: \.self) { message in
                    PrintPrefsHint(message, systemImage: "xmark.octagon.fill", tint: Theme.error)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(animation, value: errors)
        }
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

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(Theme.teal)
            Text(tr("Beim Sichern richtet LabelWerk den macOS-Drucker automatisch ein bzw. aktualisiert ihn."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button(tr("Abbrechen")) { dismiss() }
                .buttonStyle(.labelWerkSecondary)
                .keyboardShortcut(.cancelAction)
            Button(draft.isNew ? tr("Hinzufügen") : tr("Sichern")) { save() }
                .buttonStyle(.labelWerkPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Etikett vom Drucker

    private var stockChoiceBinding: Binding<LabelStockChoice> {
        Binding(
            get: { draft.stockChoice },
            set: { choice in selectStockChoice(choice) }
        )
    }

    private func selectStockChoice(_ choice: LabelStockChoice) {
        guard choice != draft.stockChoice else { return }
        if choice == .custom, let stock = selectedStock {
            // Mit der bisherigen Größe vorbelegen – meist ist nur noch anzupassen.
            draft.entry = LabelSizeEntry(widthMM: stock.widthMM, heightMM: stock.heightMM, tracking: stock.tracking)
        }
        withAnimation(reduceMotion ? nil : Motion.snappy) { draft.stockChoice = choice }
    }

    /// „Vom Drucker übernehmen“ (`nil` = Schaltfläche ausblenden).
    private var readFromPrinterAction: (() -> Void)? {
        guard canReadMedia else { return nil }
        return { readFromPrinter() }
    }

    /// „Vom Drucker übernehmen“ nur bei verbundenen ZPL-Druckern mit Rückkanal.
    private var canReadMedia: Bool {
        session.supportsStatus && session.saved.language == .zpl && !session.isVirtual
            && session.connectionState == .connected
    }

    private var mediaNote: String? {
        guard detected == nil, !canReadMedia, !session.isVirtual else { return nil }
        return tr("Mit verbundenem Drucker lässt sich die eingelegte Etikettengröße übernehmen.")
    }

    private func readFromPrinter() {
        guard !isReadingMedia else { return }
        isReadingMedia = true
        Task {
            let media = await PrinterInstallService.readMediaSize(of: session)
            isReadingMedia = false
            guard let media else {
                model.toast(tr("Keine Etikettengröße gemeldet"),
                            message: tr("Der Drucker hat keine Etikettengröße gemeldet – bitte von Hand eingeben."),
                            style: .warning)
                return
            }
            let match = LabelStockLibrary.matchingStock(for: media, model: model)
            withAnimation(reduceMotion ? nil : Motion.snappy) {
                detected = media
                draft.stockChoice = match.map { LabelStockChoice.stock($0.id) } ?? .printer
            }
        }
    }

    // MARK: Sichern

    /// Format des Typs: vorhandenes bzw. aus „Vom Drucker“/„Benutzerdefiniert …“ ein passendes vorhandenes
    /// oder neues eigenes Format (`LabelStockLibrary.resolveStock`, wie im Installationsassistenten).
    private func resolvedStockID() -> String? {
        switch draft.stockChoice {
        case .stock(let id):
            return model.stock(id: id)?.id
        case .printer:
            guard let media = detected else { return nil }
            return LabelStockLibrary.resolveStock(for: media, model: model).id
        case .custom:
            guard let size = draft.entry.size(in: limits) else { return nil }
            return LabelStockLibrary.resolveStock(widthMM: size.widthMM, heightMM: size.heightMM,
                                                  tracking: draft.entry.tracking,
                                                  mediaType: draft.overrides.mediaType, model: model).id
        }
    }

    private func save() {
        afterCommittingTextEditing {
            guard errors.isEmpty, let stockID = resolvedStockID() else { return }
            let type = LabelType(id: draft.id, name: trimmedName, stockID: stockID, overrides: draft.overrides)
            if draft.isNew {
                model.addLabelType(type, to: session)
            } else {
                model.updateLabelType(type, in: session)
            }
            // Gleich einrichten (Aktion des Benutzers – bei fehlenden Rechten mit Passwortabfrage).
            let printer = session
            let app = model
            Task { await app.queueSync.syncLabelTypesNow(printer) }
            dismiss()
        }
    }
}

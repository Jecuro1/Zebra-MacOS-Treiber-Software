import SwiftUI
import LabelWerkKit

/// Etikettenformate – entspricht der Registerkarte „Etiketten/Stocks“ des Windows-Treibers:
/// eingelegtes Format, durchsuchbarer Katalog plus eigene Formate, Anlegen/Bearbeiten,
/// Übernahme der vom Drucker gemessenen Maße und Kalibrieren.
struct StocksView: View {
    @Bindable var session: PrinterSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var search = ""
    @State private var category: LabelStock.Category?
    @State private var onlyFitting = false
    @State private var editor: StockLibraryDraft?
    @State private var pendingDeletion: LabelStock?
    @State private var appeared = false
    @State private var isFetchingFromPrinter = false
    @Namespace private var selectionNamespace
    @Namespace private var filterNamespace

    init(session: PrinterSession) {
        self._session = Bindable(session)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    // MARK: Filter

    private func fits(_ stock: LabelStock) -> Bool {
        guard let printer = session.model else { return true }
        return stock.widthMM <= printer.printWidthMM + 2 && stock.heightMM <= printer.maxLabelLengthMM
    }

    /// Vereinheitlicht Suchtexte: „4 x 6“, „4×6“ und „4,0 × 6“ finden dasselbe.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Nach Suche und „Nur passende“ gefiltert (ohne Kategorie – für die Zähler der Filter-Chips).
    private var searchFiltered: [LabelStock] {
        let needle = Self.normalized(search.trimmingCharacters(in: .whitespacesAndNewlines))
        return model.allStocks.filter { stock in
            if onlyFitting && !fits(stock) { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [stock.name, stock.sizeDescription, tr(stock.category.displayName),
                            tr(stock.tracking.displayName), stock.id]
            return haystack.contains { Self.normalized($0).contains(needle) }
        }
    }

    private var filtered: [LabelStock] {
        guard let category else { return searchFiltered }
        return searchFiltered.filter { $0.category == category }
    }

    private var availableCategories: [LabelStock.Category] {
        let all = model.allStocks
        return LabelStock.Category.allCases.filter { candidate in all.contains { $0.category == candidate } }
    }

    // MARK: Ansicht

    var body: some View {
        let visible = filtered
        let custom = visible.filter(\.isCustom)
        let catalog = visible.filter { !$0.isCustom }
        let showsAddTile = search.isEmpty && (category == nil || category == .custom)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                StocksCurrentStockCard(
                    session: session,
                    reduceMotion: reduceMotion,
                    isFetching: isFetchingFromPrinter,
                    onCalibrate: { calibrate() },
                    onAdopt: { adoptFromPrinter() },
                    onCreate: { createNew() },
                    onEdit: session.stock.isCustom ? { edit(session.stock) } : nil
                )
                .modifier(PrintPrefsAppear(index: 0, appeared: appeared, reduceMotion: reduceMotion))

                filterBar
                    .modifier(PrintPrefsAppear(index: 1, appeared: appeared, reduceMotion: reduceMotion))

                if visible.isEmpty {
                    EmptyStateView(
                        title: tr("Keine passenden Formate"),
                        message: tr("Passe Suche oder Filter an – oder lege ein eigenes Format an."),
                        systemImage: "square.stack.3d.up.slash",
                        actionTitle: tr("Eigenes Format anlegen"),
                        action: { createNew() }
                    )
                    .frame(minHeight: 320)
                    .transition(.opacity)
                } else {
                    if !custom.isEmpty || showsAddTile {
                        gridSection(title: tr("Eigene Formate"),
                                    subtitle: custom.isEmpty
                                        ? tr("Noch keine eigenen Formate – lege eines an oder dupliziere ein Standardformat.")
                                        : tr("Rechtsklick zum Bearbeiten, Duplizieren oder Löschen"),
                                    systemImage: "square.and.pencil",
                                    stocks: custom, showsAddTile: showsAddTile, indexOffset: 2)
                    }
                    if !catalog.isEmpty {
                        gridSection(title: tr("Standardformate"),
                                    subtitle: tr("Gängige Größen für Versand, Produkte, Barcodes und Belege"),
                                    systemImage: "square.grid.2x2",
                                    stocks: catalog, showsAddTile: false, indexOffset: 3 + custom.count)
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.top, 6)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Motion.spring, value: visible.map(\.id))
        }
        .sensoryFeedback(.selection, trigger: session.saved.stockID)
        .onAppear { appeared = true }
        .sheet(item: $editor) { draft in
            StockLibraryEditor(draft: draft, session: session)
                .environment(model)
        }
        .confirmationDialog(
            tr("Etikettenformat löschen?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { stock in
            Button(tr("Löschen"), role: .destructive) { delete(stock) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { stock in
            Text(deletionMessage(for: stock))
        }
    }

    /// Etikettentypen (aller Drucker), die `stock` verwenden – „„Brillenetikett“ (Zebra ZD421t)“.
    private func labelTypeNames(using stock: LabelStock) -> [String] {
        model.sessions.flatMap { printer in
            printer.labelTypes.filter { $0.stockID == stock.id }.map { "„\($0.name)“ (\(printer.displayName))" }
        }
    }

    /// Text der Rückfrage: Nennt die Etikettentypen, deren Format (und damit deren macOS-Drucker) sich
    /// mit dem Löschen ändert – sonst geschähe das unbemerkt.
    private func deletionMessage(for stock: LabelStock) -> String {
        let base = tr("„%@“ wird aus deinen eigenen Formaten entfernt. Drucker, die es verwenden, wechseln auf ihr Standardformat.", stock.name)
        let types = labelTypeNames(using: stock)
        guard !types.isEmpty else { return base }
        let note = types.count == 1
            ? tr("Auch der Etikettentyp %@ verwendet es: Er übernimmt dann das Etikett seines Druckers, und sein macOS-Drucker druckt danach in diesem Format.", types[0])
            : tr("Auch die Etikettentypen %@ verwenden es: Sie übernehmen dann das Etikett ihres Druckers, und ihre macOS-Drucker drucken danach in diesem Format.", types.joined(separator: ", "))
        return base + "\n\n" + note
    }

    // MARK: Filterleiste

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(tr("Formate durchsuchen – z. B. 100 × 150 oder Versand"), text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            withAnimation(reduceMotion ? nil : Motion.snappy) { search = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Suche leeren"))
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .labelWerkGlass(cornerRadius: 10)
                .frame(maxWidth: 380)
                .animation(reduceMotion ? nil : Motion.snappy, value: search.isEmpty)

                Toggle(isOn: $onlyFitting.animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion))) {
                    Label(tr("Nur passende"), systemImage: "checkmark.rectangle.stack")
                }
                .toggleStyle(.button)
                .disabled(session.model == nil)
                .help(session.model.map { tr("Nur Formate, die auf den %@ passen (Druckbreite %@ mm)", $0.displayName,
                                             PrintPrefsFormat.number($0.printWidthMM, digits: 0)) }
                      ?? tr("Modell unbekannt – alle Formate werden angezeigt"))

                Spacer(minLength: 8)

                Text(tr("%d Formate", filtered.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(filtered.count)))
                    .animation(reduceMotion ? nil : Motion.snappy, value: filtered.count)
            }

            PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
                filterChip(nil, title: tr("Alle"), symbol: "square.grid.2x2", count: searchFiltered.count)
                ForEach(availableCategories, id: \.self) { candidate in
                    filterChip(candidate, title: tr(candidate.displayName),
                               symbol: PrintPrefsSymbols.symbol(for: candidate),
                               count: searchFiltered.filter { $0.category == candidate }.count)
                }
            }
        }
    }

    private func filterChip(_ value: LabelStock.Category?, title: String, symbol: String, count: Int) -> some View {
        let isSelected = category == value
        return Button {
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { category = value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Text(verbatim: "\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background((isSelected ? Color.white.opacity(0.22) : Theme.subtleFill), in: Capsule())
                    .contentTransition(.numericText(value: Double(count)))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "filter", in: filterNamespace)
                } else {
                    Capsule()
                        .fill(Theme.subtleFill)
                        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
                }
            }
            .contentShape(Capsule())
            .opacity(count == 0 && !isSelected ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Motion.snappy, value: count)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Raster

    private func gridSection(title: String, subtitle: String, systemImage: String, stocks: [LabelStock],
                             showsAddTile: Bool, indexOffset: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title, subtitle: subtitle, systemImage: systemImage) {
                Text(tr("%d Formate", stocks.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(value: Double(stocks.count)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 14)], spacing: 14) {
                if showsAddTile {
                    StockLibraryAddTile(action: { createNew() })
                        .modifier(StocksCardAppear(index: indexOffset, appeared: appeared, reduceMotion: reduceMotion))
                }
                ForEach(Array(stocks.enumerated()), id: \.element.id) { index, stock in
                    StockLibraryCard(
                        stock: stock,
                        isSelected: stock.id == session.saved.stockID,
                        fits: fits(stock),
                        namespace: selectionNamespace,
                        reduceMotion: reduceMotion,
                        onSelect: { select(stock) },
                        onEdit: { edit(stock) },
                        onDuplicate: { duplicate(stock) },
                        onDelete: { pendingDeletion = stock }
                    )
                    .modifier(StocksCardAppear(index: indexOffset + index + (showsAddTile ? 1 : 0),
                                               appeared: appeared, reduceMotion: reduceMotion))
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
        }
    }

    // MARK: Aktionen

    private func select(_ stock: LabelStock) {
        guard stock.id != session.saved.stockID else { return }
        withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
            session.saved.stockID = stock.id
        }
    }

    private func createNew() {
        let base = session.stock
        let width = min(base.widthMM, session.model?.printWidthMM ?? base.widthMM)
        let stock = LabelStock(
            id: StockLibraryDraft.newID(),
            name: tr("Eigenes Format"),
            widthMM: width,
            heightMM: base.heightMM,
            gapMM: base.isContinuous ? 3 : base.gapMM,
            tracking: base.isContinuous ? .gap : base.tracking,
            mediaType: base.mediaType,
            category: .custom,
            isCustom: true
        )
        editor = StockLibraryDraft(stock: stock, mode: .create)
    }

    private func edit(_ stock: LabelStock) {
        editor = StockLibraryDraft(stock: stock, mode: .edit)
    }

    private func duplicate(_ stock: LabelStock) {
        var copy = stock
        copy.id = StockLibraryDraft.newID()
        copy.name = tr("%@ (Kopie)", stock.name)
        copy.category = .custom
        copy.isCustom = true
        editor = StockLibraryDraft(stock: copy, mode: .duplicate)
    }

    private func delete(_ stock: LabelStock) {
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            for other in model.sessions where other.saved.stockID == stock.id {
                other.saved.stockID = other.model?.defaultStock ?? "w4h6in"
            }
            model.removeCustomStock(id: stock.id)
        }
        pendingDeletion = nil
        model.toast(tr("Format gelöscht"), message: stock.name, style: .info)
    }

    private func calibrate() {
        Task { await session.perform(.calibrate) }
    }

    /// Legt ein Format aus der gemeldeten Druckbreite (`~HI`/SGD) und der gemessenen Etikettenlänge
    /// (`~HS`) an und öffnet es zur Prüfung im Editor.
    private func adoptFromPrinter() {
        guard !isFetchingFromPrinter else { return }
        isFetchingFromPrinter = true
        Task {
            // Immer frisch abfragen: Nach Kalibrieren oder Rollenwechsel wäre der zuletzt
            // gepollte Status (bis zu ein Abfrageintervall alt) noch die alte Etikettenlänge.
            await session.refresh()
            isFetchingFromPrinter = false
            let resolution = session.resolution
            guard let widthDots = session.identity?.printWidthDots, widthDots > 0,
                  let lengthDots = session.status?.hostStatus?.labelLengthDots, lengthDots > 0 else {
                model.toast(tr("Keine Maße vom Drucker"),
                            message: tr("Der Drucker hat Druckbreite oder Etikettenlänge nicht gemeldet. Kalibriere ihn und versuche es erneut."),
                            style: .warning)
                return
            }
            let widthMM = (resolution.mm(fromDots: widthDots) * 10).rounded() / 10
            let heightMM = (resolution.mm(fromDots: lengthDots) * 10).rounded() / 10
            var tracking = session.saved.settings.tracking ?? session.stock.tracking
            if tracking == .autoDetect { tracking = .gap }
            let mediaType: MediaType? = session.status?.hostStatus.map {
                $0.thermalTransferMode ? MediaType.thermalTransfer : MediaType.directThermal
            }
            let stock = LabelStock(
                id: StockLibraryDraft.newID(),
                name: tr("Vom Drucker %@ × %@ mm", PrintPrefsFormat.number(widthMM), PrintPrefsFormat.number(heightMM)),
                widthMM: widthMM,
                heightMM: heightMM,
                gapMM: tracking == .continuous ? 0 : max(session.stock.gapMM, 2),
                tracking: tracking,
                mediaType: mediaType,
                category: .custom,
                isCustom: true
            )
            editor = StockLibraryDraft(stock: stock, mode: .fromPrinter)
        }
    }
}

// MARK: - Eingelegtes Etikett

/// Großes, maßstäbliches Etikett mit Kenndaten, Abgleich mit den Messwerten des Druckers und
/// Schnellaktionen (Kalibrieren, Übernehmen, Anlegen).
private struct StocksCurrentStockCard: View {
    @Bindable var session: PrinterSession
    let reduceMotion: Bool
    let isFetching: Bool
    let onCalibrate: () -> Void
    let onAdopt: () -> Void
    let onCreate: () -> Void
    let onEdit: (() -> Void)?

    var body: some View {
        let stock = session.stock
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: session.accentColor) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) {
                    art(stock)
                    details(stock)
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 18) {
                    art(stock)
                    details(stock)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.bouncy, value: stock)
    }

    private func art(_ stock: LabelStock) -> some View {
        StockLibraryLabelArt(stock: stock, maxSize: CGSize(width: 190, height: 170))
            .frame(width: 250, height: 240)
    }

    private func details(_ stock: LabelStock) -> some View {
        let resolution = session.resolution
        return VStack(alignment: .leading, spacing: 10) {
            Text(tr("Eingelegtes Etikett"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(stock.name)
                .font(Theme.Typography.title)
                .lineLimit(2)
                .contentTransition(.opacity)
            Text(stock.sizeDescription)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
                infoChip(PrintPrefsSymbols.symbol(for: stock.category), tr(stock.category.displayName))
                infoChip(PrintPrefsSymbols.symbol(for: stock.tracking), tr(stock.tracking.displayName))
                if !stock.isContinuous {
                    infoChip("arrow.up.and.down",
                             stock.tracking == .blackMark
                                 ? tr("Marke %@ mm", PrintPrefsFormat.number(stock.gapMM))
                                 : tr("Lücke %@ mm", PrintPrefsFormat.number(stock.gapMM)))
                }
                if let type = stock.mediaType {
                    infoChip(PrintPrefsSymbols.symbol(for: type), tr(type.displayName))
                }
                infoChip("circle.grid.3x3", tr("%d × %d Punkte", stock.widthDots(resolution), stock.heightDots(resolution)))
                if stock.isCustom {
                    infoChip("square.and.pencil", tr("Eigenes Format"))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fitRow(stock)
                measuredRow(stock)
                trackingRow(stock)
            }

            PrintPrefsFlowLayout(spacing: 8, lineSpacing: 8) {
                Button(action: onCalibrate) {
                    Label(tr("Kalibrieren"), systemImage: "ruler")
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(session.isBusy)
                .help(tr("Etikettenlänge und Sensor neu einmessen (~JC)"))

                Button(action: onAdopt) {
                    HStack(spacing: 6) {
                        if isFetching {
                            ProgressRing(progress: nil, size: 13, lineWidth: 2)
                        } else {
                            Image(systemName: "arrow.down.doc")
                        }
                        Text(tr("Vom Drucker übernehmen"))
                    }
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(isFetching || !session.supportsStatus)
                .help(session.supportsStatus
                      ? tr("Format aus gemeldeter Druckbreite und gemessener Etikettenlänge anlegen")
                      : tr("Diese Verbindung kann keine Messwerte lesen (nur Senden)."))

                Button(action: onCreate) {
                    Label(tr("Neues Format …"), systemImage: "plus")
                }
                .buttonStyle(.labelWerkSecondary)

                if let onEdit {
                    Button(action: onEdit) {
                        Label(tr("Bearbeiten …"), systemImage: "pencil")
                    }
                    .buttonStyle(.labelWerkPlain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.brandGradient)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.subtleFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    private func statusRow(_ symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    @ViewBuilder
    private func fitRow(_ stock: LabelStock) -> some View {
        if let printer = session.model {
            if stock.widthMM > printer.printWidthMM + 2 {
                statusRow("exclamationmark.triangle.fill", tint: Theme.warning,
                          text: tr("Breiter als die Druckbreite des %@ (%@ mm) – Ränder bleiben unbedruckt.",
                                   printer.displayName, PrintPrefsFormat.number(printer.printWidthMM, digits: 0)))
            } else if stock.heightMM > printer.maxLabelLengthMM {
                statusRow("exclamationmark.triangle.fill", tint: Theme.warning,
                          text: tr("Länger als die maximale Etikettenlänge des %@ (%@ mm).",
                                   printer.displayName, PrintPrefsFormat.number(printer.maxLabelLengthMM, digits: 0)))
            } else {
                statusRow("checkmark.seal.fill", tint: Theme.ready,
                          text: tr("Passt auf den %@ (Druckbreite %@ mm).",
                                   printer.displayName, PrintPrefsFormat.number(printer.printWidthMM, digits: 0)))
            }
        }
    }

    @ViewBuilder
    private func measuredRow(_ stock: LabelStock) -> some View {
        if !stock.isContinuous, let lengthDots = session.status?.hostStatus?.labelLengthDots, lengthDots > 0 {
            let measured = session.resolution.mm(fromDots: lengthDots)
            let delta = abs(measured - stock.heightMM)
            if delta <= 2 {
                statusRow("ruler.fill", tint: Theme.ready,
                          text: tr("Drucker misst %@ mm Länge – stimmt mit dem Format überein.",
                                   PrintPrefsFormat.number(measured)))
            } else {
                statusRow("ruler.fill", tint: Theme.warning,
                          text: tr("Drucker misst %@ mm Länge (Format: %@ mm) – bitte kalibrieren oder Format prüfen.",
                                   PrintPrefsFormat.number(measured), PrintPrefsFormat.number(stock.heightMM)))
            }
        }
    }

    @ViewBuilder
    private func trackingRow(_ stock: LabelStock) -> some View {
        if let tracking = session.saved.settings.tracking, tracking != .autoDetect, tracking != stock.tracking {
            HStack(spacing: 8) {
                statusRow("exclamationmark.triangle.fill", tint: Theme.warning,
                          text: tr("Druckeinstellung „%@“ passt nicht zu diesem Format („%@“).",
                                   tr(tracking.displayName), tr(stock.tracking.displayName)))
                Button(tr("Angleichen")) {
                    withAnimation(reduceMotion ? nil : Motion.spring) {
                        session.saved.settings.tracking = stock.tracking
                    }
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
            }
        }
    }
}

/// Gestaffeltes Einblenden der Karten (kurze Verzögerung, gedeckelt).
private struct StocksCardAppear: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .animation(Motion.animation(Motion.spring.delay(Double(min(index, 16)) * 0.03),
                                        reduceMotion: reduceMotion),
                       value: appeared)
    }
}

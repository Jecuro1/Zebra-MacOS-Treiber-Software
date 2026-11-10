import SwiftUI
import LabelWerkKit

/// Editor für eigene Etikettenformate: Maße in mm oder Zoll, Lücke, Erkennung, optionales
/// Druckverfahren, maßstäbliche Live-Vorschau und Prüfung gegen die Druckbreite des Druckers.
struct StockLibraryEditor: View {
    let draft: StockLibraryDraft
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var name: String
    @State private var widthMM: Double
    @State private var heightMM: Double
    @State private var gapMM: Double
    @State private var tracking: MediaTracking
    @State private var mediaType: MediaType?
    @State private var unit: StockLibraryUnit
    @State private var selectAfterSave: Bool
    @FocusState private var nameFocused: Bool

    init(draft: StockLibraryDraft, session: PrinterSession) {
        self.draft = draft
        self.session = session
        let stock = draft.stock
        _name = State(initialValue: stock.name)
        _widthMM = State(initialValue: stock.widthMM)
        _heightMM = State(initialValue: stock.heightMM)
        _gapMM = State(initialValue: stock.gapMM)
        _tracking = State(initialValue: stock.tracking)
        _mediaType = State(initialValue: stock.mediaType)
        let imperial = Self.isQuarterInch(stock.widthMM) && Self.isQuarterInch(stock.heightMM)
        _unit = State(initialValue: imperial ? .inch : .mm)
        // Beim Bearbeiten eines anderen Formats die aktuelle Auswahl nicht ungefragt ändern.
        _selectAfterSave = State(initialValue: draft.mode != .edit || session.saved.stockID == stock.id)
        // Ausdrücklich initialisieren – nicht auf die implizite Standardinitialisierung verlassen.
        _nameFocused = FocusState()
    }

    /// Liegt der Wert auf einem Viertelzoll-Raster (typisch für US-Formate)?
    static func isQuarterInch(_ millimetres: Double) -> Bool {
        let quarters = millimetres / 25.4 * 4
        return abs(quarters - quarters.rounded()) < 0.01
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Prüfung

    private var errors: [String] {
        var list: [String] = []
        if trimmedName.isEmpty { list.append(tr("Bitte einen Namen eingeben.")) }
        if widthMM < 5 { list.append(tr("Die Breite muss mindestens 5 mm betragen.")) }
        if heightMM < 3 { list.append(tr("Die Länge muss mindestens 3 mm betragen.")) }
        return list
    }

    private var warnings: [String] {
        var list: [String] = []
        if let printer = session.model {
            if widthMM > printer.printWidthMM + 2 {
                list.append(tr("Breiter als die Druckbreite des %@ (%@) – die Ränder bleiben unbedruckt.",
                               printer.displayName, unit.format(printer.printWidthMM)))
            }
            if heightMM > printer.maxLabelLengthMM {
                list.append(tr("Länger als die maximale Etikettenlänge des %@ (%@).",
                               printer.displayName, unit.format(printer.maxLabelLengthMM)))
            }
        }
        if tracking != .continuous && gapMM < 1 {
            list.append(tr("Sehr kleine Lücke – der Sensor erkennt sie eventuell nicht zuverlässig."))
        }
        if !trimmedName.isEmpty, model.allStocks.contains(where: { $0.id != draft.stock.id && $0.name == trimmedName }) {
            list.append(tr("Es gibt bereits ein Format mit diesem Namen."))
        }
        return list
    }

    /// Vorhandenes Format mit gleichen Maßen – nur für vom Drucker übernommene oder vom Benutzer
    /// geänderte neue Formate (Duplikate und unveränderte Vorlagen sind absichtlich gleich).
    private var equivalentStock: LabelStock? {
        let changed = abs(widthMM - draft.stock.widthMM) > 0.01 || abs(heightMM - draft.stock.heightMM) > 0.01
        guard draft.mode == .fromPrinter || (draft.mode == .create && changed) else { return nil }
        return model.allStocks.first {
            $0.id != draft.stock.id && abs($0.widthMM - widthMM) < 0.6 && abs($0.heightMM - heightMM) < 0.6
                && $0.tracking == tracking
        }
    }

    private var title: String {
        switch draft.mode {
        case .create: return tr("Neues Etikettenformat")
        case .edit: return tr("Format bearbeiten")
        case .duplicate: return tr("Format duplizieren")
        case .fromPrinter: return tr("Format vom Drucker")
        }
    }

    private var subtitle: String {
        switch draft.mode {
        case .fromPrinter:
            return tr("Maße aus Druckbreite und gemessener Etikettenlänge – bitte prüfen und benennen.")
        default:
            return tr("Eigene Formate stehen allen Druckern in LabelWerk zur Verfügung.")
        }
    }

    // MARK: Ansicht

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 24) {
                form
                    .frame(width: 340)
                preview
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
            Divider()
            footer
        }
        .frame(width: 790)
        .background {
            AnimatedBackground(style: .subtle)
                .ignoresSafeArea()
        }
        .onAppear {
            if draft.mode != .edit { nameFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: draft.mode == .fromPrinter ? "printer.dotmatrix" : "square.and.pencil",
                      tint: Theme.violet, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.title)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                caption(tr("Name"))
                TextField(tr("z. B. Versandetikett 100 × 150"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                caption(tr("Einheit"))
                Picker(tr("Einheit"), selection: $unit.animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion))) {
                    ForEach(StockLibraryUnit.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(spacing: 10) {
                measurementField(tr("Breite"), value: $widthMM, range: 5...250)
                measurementField(tr("Länge"), value: $heightMM, range: 3...4000)
                measurementField(tracking == .blackMark ? tr("Markenhöhe") : tr("Lücke"), value: $gapMM, range: 0...30)
                    .disabled(tracking == .continuous)
                    .opacity(tracking == .continuous ? 0.45 : 1)
            }
            .padding(12)
            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                caption(tr("Medienerkennung"))
                PrintPrefsChoiceStrip(
                    options: MediaTracking.allCases,
                    selection: $tracking,
                    title: { tr($0.displayName) },
                    systemImage: { PrintPrefsSymbols.symbol(for: $0) }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                caption(tr("Druckverfahren"))
                Picker(tr("Druckverfahren"), selection: $mediaType) {
                    Text(tr("Keine Vorgabe")).tag(MediaType?.none)
                    Divider()
                    ForEach(MediaType.allCases) { type in
                        Label(tr(type.displayName), systemImage: PrintPrefsSymbols.symbol(for: type))
                            .tag(MediaType?.some(type))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func measurementField(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let factor = unit.millimetres
        let display = Binding<Double>(
            get: { value.wrappedValue / factor },
            set: { newValue in
                let millimetres = (newValue * factor * 100).rounded() / 100
                value.wrappedValue = min(max(millimetres, range.lowerBound), range.upperBound)
            }
        )
        let step = unit == .mm ? 0.5 : 0.05
        let digits = unit == .mm ? 1 : 3
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            TextField(title, value: display, format: .number.precision(.fractionLength(0...digits)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 86)
            Text(unit.symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Stepper(title, value: display, in: (range.lowerBound / factor)...(range.upperBound / factor), step: step)
                .labelsHidden()
        }
    }

    private var preview: some View {
        let resolution = session.resolution
        return VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.subtleFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                StockLibraryLabelArt(widthMM: widthMM, heightMM: heightMM, gapMM: gapMM, tracking: tracking,
                                     maxSize: CGSize(width: 250, height: 210),
                                     printableWidthMM: session.model?.printWidthMM, unit: unit)
                    .padding(20)
            }
            .frame(height: 320)
            .animation(reduceMotion ? nil : Motion.bouncy, value: widthMM)
            .animation(reduceMotion ? nil : Motion.bouncy, value: heightMM)
            .animation(reduceMotion ? nil : Motion.spring, value: gapMM)
            .animation(reduceMotion ? nil : Motion.spring, value: tracking)
            .animation(reduceMotion ? nil : Motion.snappy, value: unit)

            HStack(spacing: 8) {
                Image(systemName: "circle.grid.3x3")
                    .foregroundStyle(Theme.brandGradient)
                Text(tr("%d × %d Punkte bei %d dpi", resolution.dots(fromMM: widthMM),
                        resolution.dots(fromMM: heightMM), resolution.dpi))
                    .contentTransition(.numericText())
                if let printer = session.model {
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    Text(tr("Druckbreite %@", unit.format(printer.printWidthMM)))
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .animation(reduceMotion ? nil : Motion.snappy, value: widthMM)
            .animation(reduceMotion ? nil : Motion.snappy, value: heightMM)

            messages
        }
    }

    @ViewBuilder
    private var messages: some View {
        let errorList = errors
        let warningList = warnings
        VStack(alignment: .leading, spacing: 6) {
            ForEach(errorList, id: \.self) { message in
                PrintPrefsHint(message, systemImage: "xmark.octagon.fill", tint: Theme.error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ForEach(warningList, id: \.self) { message in
                PrintPrefsHint(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if errorList.isEmpty && warningList.isEmpty, let printer = session.model {
                PrintPrefsHint(tr("Passt auf den %@.", printer.displayName),
                               systemImage: "checkmark.seal.fill", tint: Theme.ready)
                    .transition(.opacity)
            }
            if let match = equivalentStock {
                HStack(spacing: 10) {
                    Image(systemName: "equal.circle.fill")
                        .foregroundStyle(Theme.teal)
                    Text(tr("Entspricht dem vorhandenen Format „%@“.", match.name))
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(tr("Stattdessen verwenden")) {
                        withAnimation(reduceMotion ? nil : Motion.bouncy) { session.saved.stockID = match.id }
                        model.toast(tr("Etikett ausgewählt"), message: match.name, style: .success)
                        dismiss()
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Theme.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.spring, value: errorList)
        .animation(reduceMotion ? nil : Motion.spring, value: warningList)
        .animation(reduceMotion ? nil : Motion.spring, value: equivalentStock?.id)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(tr("Nach dem Speichern auswählen"), isOn: $selectAfterSave)
                .toggleStyle(.checkbox)
            Spacer()
            Button(tr("Abbrechen")) { dismiss() }
                .buttonStyle(.labelWerkSecondary)
                .keyboardShortcut(.cancelAction)
            Button {
                save()
            } label: {
                Label(draft.mode == .edit ? tr("Änderungen sichern") : tr("Format anlegen"), systemImage: "checkmark")
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!errors.isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Speichern

    private func save() {
        guard errors.isEmpty else { return }
        let stock = LabelStock(
            id: draft.stock.id,
            name: trimmedName,
            widthMM: (widthMM * 100).rounded() / 100,
            heightMM: (heightMM * 100).rounded() / 100,
            gapMM: tracking == .continuous ? 0 : (gapMM * 100).rounded() / 100,
            tracking: tracking,
            mediaType: mediaType,
            category: .custom,
            isCustom: true
        )
        withAnimation(reduceMotion ? nil : Motion.bouncy) {
            model.addCustomStock(stock)
            if selectAfterSave { session.saved.stockID = stock.id }
        }
        model.toast(draft.mode == .edit ? tr("Format aktualisiert") : tr("Format angelegt"),
                    message: stock.name, style: .success)
        dismiss()
    }
}

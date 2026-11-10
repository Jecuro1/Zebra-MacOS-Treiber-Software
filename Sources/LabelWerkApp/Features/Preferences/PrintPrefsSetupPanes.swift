import SwiftUI
import LabelWerkKit

// MARK: - Seite einrichten

/// „Seite einrichten“: Vorlage, Breite/Höhe, Medientyp, Drehung, Markierung Versatz, Spiegeln,
/// Invers, Bei letztem Element stoppen und Stoppversatz.
@MainActor
struct PrintPrefsPagePane: View {
    let context: PrintPrefsContext
    @Environment(AppModel.self) private var model

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var editor: PrintPrefsEditor { context.editor }
    private var session: PrinterSession { context.session }
    private var settings: PrintSettings { editor.draft.settings }

    private func fits(_ stock: LabelStock) -> Bool {
        guard let printer = session.model else { return true }
        return stock.widthMM <= printer.printWidthMM + 2 && stock.heightMM <= printer.maxLabelLengthMM
    }

    private var maxWidthMM: Double {
        max(5, max((session.model?.printWidthMM).map { ($0 + 2).rounded(.up) } ?? 250, editor.draft.widthMM))
    }

    private var maxHeightMM: Double {
        max(5, max(session.model?.maxLabelLengthMM ?? 1000, editor.draft.heightMM))
    }

    private var templateBinding: Binding<String?> {
        let editor = self.editor
        let model = self.model
        let animation = context.animation
        return Binding(
            get: { editor.draft.stockID },
            set: { id in
                withAnimation(animation) { editor.selectTemplate(id.flatMap { model.stock(id: $0) }) }
            }
        )
    }

    private var rotationBinding: Binding<PrintRotation> {
        let editor = self.editor
        let animation = context.animation
        return Binding(
            get: { editor.draft.settings.effectiveRotation },
            set: { rotation in
                withAnimation(animation) {
                    editor.draft.settings.rotation = rotation
                    // Die ältere Einstellung „Um 180° drehen“ geht in der Drehung auf.
                    editor.draft.settings.rotate180 = false
                }
            }
        )
    }

    private func sizeBinding(width: Bool) -> Binding<Double> {
        let editor = self.editor
        let animation = context.animation
        return Binding(
            get: { width ? editor.draft.widthMM : editor.draft.heightMM },
            set: { value in
                withAnimation(animation) {
                    if width { editor.setSize(widthMM: value) } else { editor.setSize(heightMM: value) }
                }
            }
        )
    }

    var body: some View {
        let stocks = model.allStocks.filter { fits($0) || $0.id == editor.draft.stockID }
        let custom = stocks.filter(\.isCustom)
        let catalog = stocks.filter { !$0.isCustom }
        let isBlackMark = settings.tracking == .blackMark
        let isContinuous = settings.tracking == .continuous
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Vorlage"), systemImage: "square.stack.3d.up") {
                PrintPrefsRow(.template, context: context) {
                    Picker("", selection: templateBinding) {
                        Text(tr("Benutzerdefiniert")).tag(String?.none)
                        if !custom.isEmpty {
                            Section(tr("Eigene Formate")) {
                                ForEach(custom) { stock in
                                    Text(verbatim: templateTitle(stock)).tag(String?.some(stock.id))
                                }
                            }
                        }
                        Section(tr("Etikettenformate")) {
                            ForEach(catalog) { stock in
                                Text(verbatim: templateTitle(stock)).tag(String?.some(stock.id))
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 340, alignment: .leading)
                }
                PrintPrefsRow(.size, context: context, title: tr("Breite")) {
                    PrintPrefsMeasureField(millimetres: sizeBinding(width: true), range: 5...maxWidthMM,
                                           length: context.length)
                }
                PrintPrefsRow(.size, context: context, title: tr("Höhe"),
                              note: widthWarning) {
                    PrintPrefsMeasureField(millimetres: sizeBinding(width: false), range: 5...maxHeightMM,
                                           length: context.length)
                }

                Divider().opacity(0.5).padding(.vertical, 4)

                PrintPrefsRow(.tracking, context: context, note: trackingNote) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.tracking, fallback: .gap),
                                         options: PrintPrefsChoices.trackingOrder, width: 320) { tr($0.displayName) }
                }
                PrintPrefsRow(.markOffset, context: context, isEnabled: isBlackMark,
                              note: isBlackMark ? (context.isZPL ? nil : tr("Wirkt nur bei ZPL."))
                                                : tr("Nur bei „Etiketten mit schwarzen Markierungen“.")) {
                    PrintPrefsMeasureField(dots: context.binding(\.settings.markOffset, fallback: 0), range: -80...283,
                                           length: context.length)
                }
                PrintPrefsRow(.rotation, context: context) {
                    HStack(spacing: 10) {
                        PrintPrefsMenuPicker(selection: rotationBinding, options: PrintRotation.allCases, width: 240) {
                            tr($0.displayName)
                        }
                        Image(systemName: settings.effectiveRotation.isQuarterTurn ? "rectangle" : "rectangle.portrait")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.brandGradient)
                            .rotationEffect(.degrees(settings.effectiveRotation == .r180 ? 180 : 0))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                PrintPrefsRow(.mirror, context: context) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.mirror),
                                     caption: settings.mirror ? tr("Horizontal gespiegelt") : nil)
                }
                PrintPrefsRow(.negative, context: context) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.negative),
                                     caption: settings.negative ? tr("Weiß auf Schwarz") : nil)
                }

                Divider().opacity(0.5).padding(.vertical, 4)

                PrintPrefsRow(.stopAtLast, context: context, isEnabled: isContinuous,
                              note: isContinuous ? nil : tr("Nur bei „Endlosmaterial“.")) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.stopAtLastElement),
                                     caption: settings.stopAtLastElement ? tr("Etikett endet nach dem letzten Element") : nil)
                }
                PrintPrefsRow(.stopOffset, context: context, isEnabled: isContinuous && settings.stopAtLastElement) {
                    PrintPrefsMeasureField(dots: context.binding(\.settings.stopOffset), range: 0...32_000,
                                           length: context.length)
                }

                Divider().opacity(0.5).padding(.vertical, 4)

                // Nur Treiber: wirkt im Filter, wenn ein Programm eine andere Papiergröße schickt.
                PrintPrefsRow(.fitToLabel, context: context, note: fitToLabelNote) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.fitToLabel),
                                         options: LabelFitMode.allCases, width: 240) { tr($0.displayName) }
                }
            }
        }
    }

    private var fitToLabelNote: String {
        let size = context.length.size(widthMM: editor.draft.widthMM, heightMM: editor.draft.heightMM)
        switch settings.fitToLabel {
        case .auto:
            return tr("A4, Letter & Co. aus Vorschau, Safari usw. landen automatisch auf dem Etikett %@ – im Druckdialog muss nichts eingestellt werden.", size)
        case .off:
            return tr("Andere Papiergrößen werden nicht angepasst – im Druckdialog muss dann „%@“ gewählt werden.", size)
        }
    }

    private func templateTitle(_ stock: LabelStock) -> String {
        stock.name + "  ·  " + context.length.size(widthMM: stock.widthMM, heightMM: stock.heightMM)
    }

    private var widthWarning: String? {
        guard let printer = session.model, editor.draft.widthMM > printer.printWidthMM + 0.05 else { return nil }
        return tr("Breiter als die Druckbreite von %@ (%@) – rechts wird abgeschnitten.",
                  printer.displayName, context.length.text(mm: printer.printWidthMM))
    }

    private var trackingNote: String? {
        guard let id = editor.draft.stockID, let stock = model.stock(id: id),
              let tracking = settings.tracking, tracking != .autoDetect, tracking != stock.tracking else { return nil }
        return tr("Die Vorlage „%@“ ist als „%@“ hinterlegt.", stock.name, tr(stock.tracking.displayName))
    }
}

// MARK: - Druckoptionen

/// „Druckoptionen“: Druckeinstellungen, Versatz, Erweiterte Einstellungen und „Aufträge vor dem
/// Drucken abbrechen“.
@MainActor
struct PrintPrefsOptionsPane: View {
    let context: PrintPrefsContext
    @State private var lastPauseCount = 10

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var editor: PrintPrefsEditor { context.editor }
    private var session: PrinterSession { context.session }
    private var settings: PrintSettings { editor.draft.settings }

    private var languages: [PrinterLanguage] {
        var list = session.model?.languages ?? PrinterLanguage.allCases
        if list.isEmpty { list = PrinterLanguage.allCases }
        if !list.contains(editor.draft.language) { list.append(editor.draft.language) }
        return list
    }

    private enum PauseChoice: Hashable { case none, every }

    private var pauseBinding: Binding<PauseChoice> {
        let editor = self.editor
        let animation = context.animation
        let last = lastPauseCount
        return Binding(
            get: { editor.draft.settings.pauseEvery > 0 ? .every : .none },
            set: { choice in
                withAnimation(animation) { editor.draft.settings.pauseEvery = choice == .every ? max(1, last) : 0 }
            }
        )
    }

    private var pauseCountBinding: Binding<Int> {
        let editor = self.editor
        return Binding(
            get: { max(1, editor.draft.settings.pauseEvery) },
            set: { value in
                editor.draft.settings.pauseEvery = value.clamped(to: 1...9999)
                lastPauseCount = value.clamped(to: 1...9999)
            }
        )
    }

    private var internalCharactersBinding: Binding<Bool> {
        let editor = self.editor
        let animation = context.animation
        return Binding(
            get: { editor.draft.settings.controlCharacters != nil },
            set: { isInternal in
                withAnimation(animation) {
                    editor.draft.settings.controlCharacters = isInternal
                        ? (editor.printerValues?.controlCharacters ?? .standard)
                        : nil
                }
            }
        )
    }

    var body: some View {
        let zplNote: String? = context.isZPL ? nil : tr("Wirkt nur bei ZPL.")
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Druckeinstellungen"), systemImage: "speedometer") {
                PrintPrefsRow(.speed, context: context) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.speed,
                                                                    fallback: min(4, PrintPrefsChoices.maxSpeed(session))),
                                         options: PrintPrefsChoices.speeds(session, current: settings.speed),
                                         width: 180) { PrintPrefsChoices.speedText($0) }
                }
                PrintPrefsRow(.darkness, context: context, note: darknessNote) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.darkness, fallback: 15),
                                         options: PrintPrefsChoices.temperatures(current: settings.darkness),
                                         width: 120) { String($0) }
                }
                PrintPrefsRow(.mediaType, context: context) {
                    Picker("", selection: context.binding(\.settings.mediaType, fallback: .directThermal)) {
                        ForEach(PrintPrefsChoices.mediaTypes(session, current: settings.mediaType)) { type in
                            Text(tr(type.displayName)).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
            }

            PrintPrefsGroup(tr("Versatz"), systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                PrintPrefsRow(.labelTop, context: context, note: offsetNote(settings.labelTop,
                                                                             positive: tr("Druckbild nach unten"),
                                                                             negative: tr("Druckbild nach oben"))) {
                    PrintPrefsMeasureField(dots: context.binding(\.settings.labelTop, fallback: 0), range: -120...120,
                                           length: context.length)
                }
                PrintPrefsRow(.labelLeft, context: context, note: offsetNote(settings.labelLeft,
                                                                              positive: tr("Druckbild nach links"),
                                                                              negative: tr("Druckbild nach rechts"))) {
                    PrintPrefsMeasureField(dots: context.binding(\.settings.labelLeft, fallback: 0),
                                           range: -9999...9999, length: context.length)
                }
            }

            PrintPrefsGroup(tr("Erweiterte Einstellungen"), systemImage: "gearshape.2") {
                PrintPrefsRow(.backfeed, context: context) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.backfeed, fallback: .normal),
                                         options: PrintPrefsChoices.backfeedOrder, width: 220) { tr($0.displayName) }
                }
                PrintPrefsRow(.pauseEvery, context: context, note: pauseNote ?? zplNote) {
                    HStack(spacing: 10) {
                        Picker("", selection: pauseBinding) {
                            Text(tr("Keine Pause")).tag(PauseChoice.none)
                            Text(tr("Nach Etiketten")).tag(PauseChoice.every)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 170)
                        if settings.pauseEvery > 0 {
                            PrintPrefsIntegerField(value: pauseCountBinding, range: 1...9999, unit: tr("Etiketten"))
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                }
                PrintPrefsRow(.controlCharacters, context: context, note: zplNote) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: internalCharactersBinding) {
                            Text(tr("Standard")).tag(false)
                            Text(tr("Intern")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        if settings.controlCharacters != nil {
                            controlCharacterFields
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                PrintPrefsRow(.rtcUpdate, context: context, note: zplNote) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.rtcUpdate, fallback: .jobStart),
                                         options: RTCUpdate.allCases, width: 220) { tr($0.displayName) }
                }
                Divider().opacity(0.5).padding(.vertical, 4)
                PrintPrefsRow(.language, context: context,
                              note: editor.draft.language != session.saved.language
                                  ? tr("Beim Speichern wird die Verbindung in der neuen Sprache aufgebaut.") : nil) {
                    Picker("", selection: context.binding(\.language)) {
                        ForEach(languages) { language in
                            Text(verbatim: language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                PrintPrefsRow(.calibrateBeforeJob, context: context) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.calibrateBeforeJob),
                                     caption: settings.calibrateBeforeJob ? tr("~JC vor jedem Auftrag") : nil)
                }
                PrintPrefsRow(.saveToPrinter, context: context) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.saveToPrinter),
                                     caption: settings.saveToPrinter ? tr("^JUS mit dem ersten Etikett") : nil)
                }
            }

            PrintPrefsGroup(tr("Aufträge vor dem Drucken abbrechen"), systemImage: "xmark.bin") {
                PrintPrefsRow(.cancelJobs, context: context,
                              note: editor.draft.language == .cpcl ? tr("Wirkt nur bei ZPL und EPL.") : nil) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.cancelJobsBeforePrint),
                                     caption: settings.cancelJobsBeforePrint ? tr("~JA vor jedem Auftrag") : nil)
                }
                PrintPrefsRow(.cancelDelay, context: context, isEnabled: settings.cancelJobsBeforePrint) {
                    PrintPrefsIntegerField(value: context.binding(\.settings.cancelDelayMs), range: 0...10_000,
                                           step: 250, unit: tr("ms"), width: 80)
                }
            }
        }
        .animation(context.animation, value: settings.pauseEvery > 0)
        .animation(context.animation, value: settings.controlCharacters != nil)
    }

    // MARK: Steuerzeichen

    private var controlCharacterFields: some View {
        HStack(spacing: 14) {
            characterField(tr("Formatpräfix"), \.formatPrefix, fallback: 0x5E)
            characterField(tr("Steuerpräfix"), \.controlPrefix, fallback: 0x7E)
            characterField(tr("Trennzeichen"), \.delimiter, fallback: 0x2C)
        }
    }

    private func characterField(_ title: String, _ keyPath: WritableKeyPath<ControlCharacters, UInt8>,
                                fallback: UInt8) -> some View {
        let editor = self.editor
        let binding = Binding<String>(
            get: {
                let byte = editor.draft.settings.controlCharacters?[keyPath: keyPath] ?? fallback
                return String(Character(Unicode.Scalar(byte)))
            },
            set: { text in
                guard let last = text.last, let byte = ControlCharacters.character(from: String(last)) else { return }
                var characters = editor.draft.settings.controlCharacters ?? .standard
                characters[keyPath: keyPath] = byte
                editor.draft.settings.controlCharacters = characters
            }
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.code)
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .labelsHidden()
        }
    }

    // MARK: Hinweise

    private var darknessNote: String? {
        guard let darkness = settings.darkness else { return nil }
        switch darkness {
        case ..<10: return tr("Sehr hell – Barcodes können unlesbar werden.")
        case 26...: return tr("Sehr dunkel – Balken können verlaufen, der Druckkopf altert schneller.")
        default: return nil
        }
    }

    private var pauseNote: String? {
        guard settings.pauseEvery > 0, settings.cutEvery > 0 else { return nil }
        return tr("Pausieren hat Vorrang vor „Schneiden alle N Etiketten“.")
    }

    private func offsetNote(_ dots: Int?, positive: String, negative: String) -> String? {
        guard let dots, dots != 0 else { return nil }
        return tr("%@: %@", dots > 0 ? positive : negative, context.length.text(dots: abs(dots)))
    }
}

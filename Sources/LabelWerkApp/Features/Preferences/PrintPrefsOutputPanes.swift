import SwiftUI
import LabelWerkKit

// MARK: - Bedienermodus

/// „Bedienermodus“: Modus, Versatz (Abreiß-/Spendeposition) und Abschneider.
@MainActor
struct PrintPrefsOperationPane: View {
    let context: PrintPrefsContext
    @State private var lastCutCount = 1

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var editor: PrintPrefsEditor { context.editor }
    private var settings: PrintSettings { editor.draft.settings }
    private var cutterActive: Bool { settings.printMode?.usesCutter == true }

    private enum CutType: Hashable { case endOfJob, everyN }

    private var cutTypeBinding: Binding<CutType> {
        let editor = self.editor
        let animation = context.animation
        let last = lastCutCount
        return Binding(
            get: { editor.draft.settings.cutEvery > 0 ? .everyN : .endOfJob },
            set: { type in
                withAnimation(animation) { editor.draft.settings.cutEvery = type == .everyN ? max(1, last) : 0 }
            }
        )
    }

    private var cutCountBinding: Binding<Int> {
        let editor = self.editor
        return Binding(
            get: { max(1, editor.draft.settings.cutEvery) },
            set: { value in
                editor.draft.settings.cutEvery = value.clamped(to: 1...9999)
                lastCutCount = value.clamped(to: 1...9999)
            }
        )
    }

    var body: some View {
        let modes = PrintPrefsChoices.printModes(context.session, language: editor.draft.language,
                                                 current: settings.printMode)
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Bedienermodus"), systemImage: "gearshape.2") {
                PrintPrefsRow(.printMode, context: context, note: modeNote) {
                    HStack(spacing: 10) {
                        PrintPrefsMenuPicker(selection: context.binding(\.settings.printMode, fallback: .tearOff),
                                             options: modes, width: 280) { tr($0.displayName) }
                        Image(systemName: PrintPrefsSymbols.symbol(for: settings.printMode))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.brandGradient)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                PrintPrefsRow(.tearOff, context: context, note: tearOffNote) {
                    PrintPrefsMeasureField(dots: context.binding(\.settings.tearOffAdjust, fallback: 0),
                                           range: -120...120, length: context.length)
                }
            }

            PrintPrefsGroup(tr("Abschneider"), systemImage: "scissors") {
                PrintPrefsRow(.cutEvery, context: context, title: tr("Typ"), isEnabled: cutterActive,
                              note: cutterActive ? nil : tr("Nur in einem Modus mit Abschneider (Abschneider, Verzögerter Abschneider, Kiosk, Linerless schneiden).")) {
                    Picker("", selection: cutTypeBinding) {
                        Text(tr("Nur am Auftragsende")).tag(CutType.endOfJob)
                        Text(tr("Nach Etikettenanzahl")).tag(CutType.everyN)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                PrintPrefsRow(.cutEvery, context: context, title: tr("Schneiden alle N Etiketten"),
                              isEnabled: cutterActive && settings.cutEvery > 0,
                              note: cutterActive && settings.pauseEvery > 0
                                  ? tr("„Pausieren“ (Druckoptionen) hat Vorrang vor dem Schneiden.") : nil) {
                    PrintPrefsIntegerField(value: cutCountBinding, range: 1...9999, unit: tr("Etiketten"))
                }
            }
        }
    }

    private var modeNote: String? {
        switch settings.printMode {
        case .none: return nil
        case .some(.tearOff): return tr("Etiketten werden an der Abreißkante abgetrennt.")
        case .some(.peelOff): return tr("Das Etikett wird vom Träger gelöst – Spender erforderlich.")
        case .some(.cutter): return tr("Der Abschneider trennt die Etiketten automatisch.")
        case .some(.delayedCut): return tr("Der Schnitt erfolgt erst beim nächsten Etikett oder per Befehl.")
        case .some(.rewind): return tr("Bedruckte Etiketten werden aufgewickelt.")
        case .some(.applicator): return tr("Betrieb mit einem Etiketten-Applikator.")
        case .some(.kiosk): return tr("Kiosk-Modus: Beleg wird präsentiert und geschnitten.")
        case .some(.linerlessPeel), .some(.linerlessCut), .some(.linerlessDelayedCut), .some(.linerlessRewind),
             .some(.linerlessTear):
            return context.isZPL
                ? tr("Linerless-Etiketten ohne Trägermaterial – der Modus wird per SGD (media.printmode) gesetzt.")
                : tr("Linerless-Modi gibt es nur mit ZPL.")
        }
    }

    private var tearOffNote: String? {
        guard let dots = settings.tearOffAdjust, dots != 0 else { return nil }
        return tr("%@: %@", dots > 0 ? tr("Weiter heraus") : tr("Weiter zurück"), context.length.text(dots: abs(dots)))
    }
}

// MARK: - Grafik Optionen

/// „Grafik Optionen“: Rasterung mit Live-Vorschau, Schwelle, Kompression mit Größenschätzung,
/// leere Etiketten überspringen.
@MainActor
struct PrintPrefsGraphicsPane: View {
    let context: PrintPrefsContext

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var editor: PrintPrefsEditor { context.editor }
    private var settings: PrintSettings { editor.draft.settings }

    private var thresholdBinding: Binding<Double> {
        let editor = self.editor
        return Binding(
            get: { Double(editor.draft.settings.threshold) },
            set: { editor.draft.settings.threshold = Int($0.rounded()).clamped(to: 1...254) }
        )
    }

    var body: some View {
        let session = context.session
        let resolution = session.resolution
        let maxWidth = session.model?.printWidthDots(resolution)
        let widthDots = min(resolution.dots(fromMM: editor.draft.widthMM), maxWidth ?? .max)
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Rasterung"), systemImage: "circle.grid.cross") {
                PrintPrefsRow(.dither, context: context, note: ditherHint) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.dither), options: DitherAlgorithm.allCases,
                                         width: 260) { tr($0.displayName) }
                }
                PrintPrefsRow(.threshold, context: context) {
                    HStack(spacing: 10) {
                        Slider(value: thresholdBinding, in: 1...254, step: 1) {
                            Text(tr("Schwelle"))
                        } minimumValueLabel: {
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "moon.fill").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        Text(verbatim: "\(settings.threshold)")
                            .font(Theme.Typography.metricSmall)
                            .contentTransition(.numericText(value: Double(settings.threshold)))
                            .frame(minWidth: 40, alignment: .trailing)
                            .animation(context.reduceMotion ? nil : Motion.snappy, value: settings.threshold)
                    }
                }
                PrintPrefsDitherPreview(algorithm: settings.dither, threshold: settings.threshold,
                                        reduceMotion: context.reduceMotion) { algorithm in
                    context.change { $0.settings.dither = algorithm }
                }
                .padding(.top, 6)
            }

            PrintPrefsGroup(tr("Kompression"), systemImage: "archivebox") {
                PrintPrefsRow(.compression, context: context) {
                    Picker("", selection: context.binding(\.settings.compression)) {
                        ForEach(GraphicCompression.allCases) { compression in
                            Text(tr(compression.displayName)).tag(compression)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                PrintPrefsCompressionEstimate(
                    settings: settings,
                    language: editor.draft.language,
                    resolution: resolution,
                    stock: session.stock,
                    widthDots: max(8, widthDots),
                    heightDots: max(8, resolution.dots(fromMM: editor.draft.heightMM)),
                    maxPrintWidthDots: maxWidth,
                    reduceMotion: context.reduceMotion
                ) { compression in
                    context.change { $0.settings.compression = compression }
                }
                .padding(.top, 4)
            }

            PrintPrefsGroup(tr("Seiten"), systemImage: "rectangle.dashed") {
                PrintPrefsRow(.skipBlank, context: context) {
                    PrintPrefsSwitch(isOn: context.binding(\.settings.skipBlankLabels),
                                     caption: settings.skipBlankLabels ? tr("Seiten ohne Inhalt werden nicht gedruckt") : nil)
                }
            }
        }
    }

    private var ditherHint: String {
        switch settings.dither {
        case .threshold: return tr("Harte Schwelle: gestochen scharf – ideal für Text, Linien und Barcodes.")
        case .ordered: return tr("Gleichmäßiges Bayer-Muster: ruhige Flächen, gut für Grafiken und Logos.")
        case .halftone: return tr("Klassisches Punktraster wie im Zeitungsdruck – robust bei niedriger Auflösung.")
        case .floydSteinberg: return tr("Fehlerdiffusion: feine Verläufe, empfohlen für Fotos.")
        case .atkinson: return tr("Kontrastreiche Fehlerdiffusion: helle Bereiche bleiben sauber.")
        case .stucki: return tr("Sehr feine Fehlerdiffusion: beste Detailtreue, etwas mehr Rechenzeit.")
        }
    }
}

// MARK: - Kundenspezifische Befehle

/// „Kundenspezifische Befehle“: Rohbefehle am Auftragsbeginn/-ende und an jedem Etikettenbeginn/-ende.
@MainActor
struct PrintPrefsCommandsPane: View {
    let context: PrintPrefsContext

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var language: PrinterLanguage { context.editor.draft.language }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Auftrag"), systemImage: "doc.on.doc") {
                PrintPrefsCommandEditor(setting: .startCommands, keyPath: \.settings.startCommands,
                                        subtitle: tr("Vor dem ersten Etikett des Auftrags"),
                                        snippets: startSnippets, context: context)
                PrintPrefsCommandEditor(setting: .endCommands, keyPath: \.settings.endCommands,
                                        subtitle: tr("Nach dem letzten Etikett des Auftrags"),
                                        snippets: endSnippets, context: context)
                    .padding(.top, 8)
            }
            PrintPrefsGroup(tr("Etikett"), systemImage: "tag") {
                PrintPrefsCommandEditor(setting: .labelStartCommands, keyPath: \.settings.labelStartCommands,
                                        subtitle: language == .zpl ? tr("Am Anfang jedes Etiketts, direkt nach ^XA")
                                                                   : tr("Am Anfang jedes Etiketts"),
                                        snippets: labelSnippets, context: context)
                PrintPrefsCommandEditor(setting: .labelEndCommands, keyPath: \.settings.labelEndCommands,
                                        subtitle: language == .zpl ? tr("Am Ende jedes Etiketts, direkt vor ^XZ")
                                                                   : tr("Am Ende jedes Etiketts"),
                                        snippets: [], context: context)
                    .padding(.top, 8)
                if language == .cpcl {
                    PrintPrefsHint(tr("CPCL kennt keine Auftrags- und Etikettenbefehle – sie werden nicht gesendet."),
                                   systemImage: "exclamationmark.triangle", tint: Theme.warning)
                }
            }
        }
    }

    private var startSnippets: [PrintPrefsCommandEditor.Snippet] {
        guard language == .zpl else { return [] }
        return [
            .init(title: tr("UTF-8-Zeichensatz aktivieren"), code: "^XA^CI28^XZ"),
            .init(title: tr("Medien kalibrieren"), code: "~JC"),
            .init(title: tr("Etikettenursprung zurücksetzen"), code: "^XA^LH0,0^XZ"),
        ]
    }

    private var endSnippets: [PrintPrefsCommandEditor.Snippet] {
        guard language == .zpl else { return [] }
        return [
            .init(title: tr("Ein Leeretikett vorschieben"), code: "~PH"),
            .init(title: tr("Einstellungen dauerhaft speichern"), code: "^XA^JUS^XZ"),
        ]
    }

    private var labelSnippets: [PrintPrefsCommandEditor.Snippet] {
        guard language == .zpl else { return [] }
        return [
            .init(title: tr("UTF-8-Zeichensatz"), code: "^CI28"),
            .init(title: tr("Etikettenursprung"), code: "^LH0,0"),
        ]
    }
}

/// Code-Editor für eine Befehlsfolge mit Vorlagen, Löschen und Stift-Menü.
@MainActor
struct PrintPrefsCommandEditor: View {
    struct Snippet: Identifiable {
        let title: String
        let code: String
        var id: String { code }
    }

    let setting: PrintPrefsSetting
    let keyPath: WritableKeyPath<PrintPrefsDraft, String>
    let subtitle: String
    let snippets: [Snippet]
    let context: PrintPrefsContext

    init(setting: PrintPrefsSetting, keyPath: WritableKeyPath<PrintPrefsDraft, String>, subtitle: String,
         snippets: [Snippet], context: PrintPrefsContext) {
        self.setting = setting
        self.keyPath = keyPath
        self.subtitle = subtitle
        self.snippets = snippets
        self.context = context
    }

    var body: some View {
        let text = context.binding(keyPath)
        let value = text.wrappedValue
        let issue = formatIssue(value)
        let changed = context.editor.isChanged(setting)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.warning)
                    .frame(width: 6, height: 6)
                    .opacity(changed ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(setting.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !snippets.isEmpty {
                    Menu {
                        ForEach(snippets) { snippet in
                            Button {
                                let current = text.wrappedValue
                                text.wrappedValue = current.isEmpty || current.hasSuffix("\n")
                                    ? current + snippet.code
                                    : current + "\n" + snippet.code
                            } label: {
                                Text(verbatim: snippet.code + "  –  " + snippet.title)
                            }
                        }
                    } label: {
                        Label(tr("Vorlage"), systemImage: "text.badge.plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(tr("Häufig genutzten Befehl einfügen"))
                }
                if !value.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("Befehle löschen"))
                    .transition(.opacity)
                }
                PrintPrefsPencilMenu(setting: setting, context: context)
            }
            CodeEditor(text: text, language: context.editor.draft.language == .zpl ? .zpl : .plain, fontSize: 12)
                .frame(height: 104)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(issue == nil ? Theme.cardStroke : Theme.warning.opacity(0.6), lineWidth: 1)
                }
            if let issue {
                PrintPrefsHint(issue, systemImage: "exclamationmark.triangle", tint: Theme.warning)
                    .transition(.opacity)
            } else {
                PrintPrefsHint(value.isEmpty ? tr("Keine Befehle – nichts wird zusätzlich gesendet.")
                                             : tr("%d Zeichen werden unverändert gesendet.", value.count),
                               systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .modifier(PrintPrefsPulse(token: context.editor.pulseTokens[setting] ?? 0, cornerRadius: 12))
        .animation(context.animation, value: value.isEmpty)
        .animation(context.animation, value: issue)
    }

    /// Plausibilitätsprüfung für ZPL: Auftragsbefehle sollten `^XA`/`^XZ` paarweise enthalten,
    /// Etikettenbefehle gar keine (sie stehen bereits innerhalb von `^XA … ^XZ`).
    private func formatIssue(_ text: String) -> String? {
        guard context.editor.draft.language == .zpl, !text.isEmpty else { return nil }
        let upper = text.uppercased()
        let starts = upper.components(separatedBy: "^XA").count - 1
        let ends = upper.components(separatedBy: "^XZ").count - 1
        if setting == .labelStartCommands || setting == .labelEndCommands {
            if starts > 0 || ends > 0 {
                return tr("Etikettenbefehle stehen bereits zwischen ^XA und ^XZ – bitte ohne ^XA/^XZ eingeben.")
            }
            return nil
        }
        if starts != ends {
            return tr("Unvollständiges Format: %d × ^XA, aber %d × ^XZ.", starts, ends)
        }
        return nil
    }
}

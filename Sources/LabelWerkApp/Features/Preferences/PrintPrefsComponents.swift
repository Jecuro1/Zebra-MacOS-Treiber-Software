import SwiftUI
import LabelWerkKit

// MARK: - Kontext

/// Was jede Zeile des Dialogs braucht: Editor (Entwurf), Drucker, Einheit und „Bewegung reduzieren“.
@MainActor
struct PrintPrefsContext {
    let editor: PrintPrefsEditor
    let session: PrinterSession
    let length: PrintPrefsLength
    let reduceMotion: Bool

    var animation: Animation? { reduceMotion ? nil : Motion.spring }

    /// Ändert den Entwurf animiert.
    func change(_ update: (inout PrintPrefsDraft) -> Void) {
        withAnimation(animation) { update(&editor.draft) }
    }

    /// Bindung an einen Wert des Entwurfs (Änderungen werden animiert).
    func binding<Value>(_ keyPath: WritableKeyPath<PrintPrefsDraft, Value>) -> Binding<Value> {
        let editor = self.editor
        let animation = self.animation
        return Binding(
            get: { editor.draft[keyPath: keyPath] },
            set: { newValue in withAnimation(animation) { editor.draft[keyPath: keyPath] = newValue } }
        )
    }

    /// Bindung an einen optionalen Wert, der in der Zeile nur angezeigt wird, solange er gesetzt ist
    /// (sonst zeigt die Zeile „Druckerwert“).
    func binding<Value>(_ keyPath: WritableKeyPath<PrintPrefsDraft, Value?>, fallback: Value) -> Binding<Value> {
        let editor = self.editor
        let animation = self.animation
        return Binding(
            get: { editor.draft[keyPath: keyPath] ?? fallback },
            set: { newValue in withAnimation(animation) { editor.draft[keyPath: keyPath] = newValue } }
        )
    }

    /// ZPL-Funktionen wirken bei EPL/CPCL nicht.
    var isZPL: Bool { editor.draft.language == .zpl }
}

// MARK: - Gruppe

/// Abschnitt mit Überschrift (wie die Gruppen des Windows-Dialogs), als Glaskarte.
struct PrintPrefsGroup<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        GlassCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.brandGradient)
                        .frame(width: 18)
                    Text(title)
                        .font(Theme.Typography.headline)
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 1)
                        .padding(.leading, 4)
                }
                .padding(.bottom, 4)
                content
            }
        }
    }
}

// MARK: - Zeile

/// Eine Einstellung: Beschriftung links, Steuerelement in der Mitte, rechts das Stift-Menü
/// („Treiberwert verwenden“ / „Druckerwert verwenden“ / „Vom Drucker lesen“). Steht der Wert auf
/// „Druckerwert“, zeigt die Zeile statt des Steuerelements den (zuletzt gelesenen) Druckerwert
/// grau und kursiv – ein Klick darauf legt wieder einen Treiberwert fest.
@MainActor
struct PrintPrefsRow<Content: View>: View {
    let setting: PrintPrefsSetting
    let context: PrintPrefsContext
    let title: String?
    let isEnabled: Bool
    let note: String?
    let content: Content

    init(_ setting: PrintPrefsSetting, context: PrintPrefsContext, title: String? = nil, isEnabled: Bool = true,
         note: String? = nil, @ViewBuilder content: () -> Content) {
        self.setting = setting
        self.context = context
        self.title = title
        self.isEnabled = isEnabled
        self.note = note
        self.content = content()
    }

    private var editor: PrintPrefsEditor { context.editor }

    var body: some View {
        let usesPrinter = setting.usesPrinterValue(editor.draft)
        let changed = editor.isChanged(setting)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 6, height: 6)
                        .scaleEffect(changed ? 1 : 0.2)
                        .opacity(changed ? 1 : 0)
                        .help(tr("Geändert – noch nicht gespeichert"))
                    Text(title ?? setting.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 196, alignment: .leading)

                ZStack(alignment: .leading) {
                    if usesPrinter {
                        printerWell
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                    } else {
                        content
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!isEnabled)

                PrintPrefsPencilMenu(setting: setting, context: context)
                    .disabled(!isEnabled)
            }
            if let note {
                PrintPrefsHint(note, systemImage: isEnabled ? "info.circle" : "lock")
                    .padding(.leading, 208)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .opacity(isEnabled ? 1 : 0.6)
        .modifier(PrintPrefsPulse(token: editor.pulseTokens[setting] ?? 0, cornerRadius: 9))
        .animation(context.animation, value: usesPrinter)
        .animation(context.animation, value: changed)
        .animation(context.animation, value: isEnabled)
    }

    private var printerWell: some View {
        let known = editor.printerValues.flatMap { setting.printerValueText($0, length: context.length) }
        return Button {
            context.change { setting.useDriverValue(&$0, printer: editor.printerValues, session: context.session) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "printer")
                    .font(.system(size: 11, weight: .medium))
                Text(known.map { tr("Druckerwert · %@", $0) } ?? tr("Druckerwert"))
                    .italic()
                    .lineLimit(1)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tr("Der Drucker behält seine eigene Einstellung. Klicken, um einen Treiberwert festzulegen."))
    }
}

// MARK: - Stift-Menü

/// Stift mit Pfeil (wie im Windows-Treiber): Treiberwert oder Druckerwert verwenden, Wert lesen.
@MainActor
struct PrintPrefsPencilMenu: View {
    let setting: PrintPrefsSetting
    let context: PrintPrefsContext

    var body: some View {
        let editor = context.editor
        let usesPrinter = setting.usesPrinterValue(editor.draft)
        let isReading = editor.readingSetting == setting
        HStack(spacing: 2) {
            if isReading {
                ProgressRing(progress: nil, size: 12, lineWidth: 1.8)
                    .transition(.scale.combined(with: .opacity))
            }
            // Jede Menü-Aktion beendet zuerst eine laufende Eingabe im Textfeld der Zeile – sonst
            // überschriebe der getippte Wert beim späteren Fokusverlust die Wahl aus dem Menü.
            Menu {
                Toggle(isOn: Binding(get: { !usesPrinter }, set: { on in
                    guard on else { return }
                    afterCommittingTextEditing {
                        context.change { setting.useDriverValue(&$0, printer: editor.printerValues, session: context.session) }
                    }
                })) {
                    Label(tr("Treiberwert verwenden"), systemImage: "pencil")
                }
                Toggle(isOn: Binding(get: { usesPrinter }, set: { on in
                    guard on else { return }
                    afterCommittingTextEditing {
                        context.change { setting.usePrinterValue(&$0) }
                    }
                })) {
                    Label(tr("Druckerwert verwenden"), systemImage: "printer")
                }
                .disabled(!setting.supportsPrinterValue)
                Divider()
                Button {
                    afterCommittingTextEditing {
                        Task { await editor.read(setting, session: context.session) }
                    }
                } label: {
                    Label(tr("Vom Drucker lesen"), systemImage: "arrow.down.circle")
                }
                .disabled(!setting.isReadable || !context.session.supportsStatus || editor.readingSetting != nil)
                if !setting.supportsPrinterValue && setting.hasDriverDefault {
                    Button {
                        afterCommittingTextEditing {
                            context.change { setting.resetToDefault(&$0) }
                            editor.pulse([setting])
                        }
                    } label: {
                        Label(tr("Standardwert wiederherstellen"), systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(usesPrinter ? Color.secondary : Theme.accent)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .tint(Theme.accent)
            .fixedSize()
        }
        .frame(minWidth: 44, alignment: .trailing)
        .animation(context.animation, value: isReading)
        .help(helpText(usesPrinter: usesPrinter))
        .accessibilityLabel(tr("Wertquelle für „%@“", setting.summaryTitle))
    }

    private func helpText(usesPrinter: Bool) -> String {
        if !setting.supportsPrinterValue {
            return tr("Treiberwert – diese Einstellung wirkt nur im Treiber.")
        }
        return usesPrinter ? tr("Druckerwert – der Drucker behält seine Einstellung.")
                           : tr("Treiberwert – wird mit jedem Auftrag gesendet.")
    }
}

// MARK: - Aktionszeile (Wartung)

/// Beschreibung links, Knopf rechts (z. B. „Medien kalibrieren“ → „Kalibrieren“).
struct PrintPrefsActionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let buttonTitle: String
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(title: String, detail: String, systemImage: String, tint: Color, buttonTitle: String,
         isBusy: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.buttonTitle = buttonTitle
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action: action) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressRing(progress: nil, size: 12, lineWidth: 2)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(buttonTitle)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .disabled(!isEnabled || isBusy)
            .fixedSize()
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Schalter

/// Schalter ohne eigene Beschriftung (die Zeile beschriftet ihn).
struct PrintPrefsSwitch: View {
    @Binding var isOn: Bool
    var caption: String?

    init(isOn: Binding<Bool>, caption: String? = nil) {
        self._isOn = isOn
        self.caption = caption
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            if let caption {
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
    }
}

/// Auswahlliste in der Zeilenbreite (Menü).
struct PrintPrefsMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var width: CGFloat

    init(selection: Binding<Value>, options: [Value], width: CGFloat = 260, title: @escaping (Value) -> String) {
        self._selection = selection
        self.options = options
        self.width = width
        self.title = title
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: width, alignment: .leading)
    }
}

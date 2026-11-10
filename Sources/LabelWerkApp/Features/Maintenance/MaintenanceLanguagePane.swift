import SwiftUI
import LabelWerkKit

/// Druckersprache am Gerät (`device.languages`) umstellen und mit der Ausgabesprache von LabelWerk
/// abgleichen.
struct MaintLanguagePane: View {
    let session: PrinterSession
    @Bindable var controller: MaintLanguageController
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @Namespace private var namespace

    private var options: [MaintDeviceLanguageOption] {
        MaintDeviceLanguage.options(for: session.model)
    }

    private var selectedTitle: String {
        if controller.isCustom {
            let value = MaintDeviceLanguage.normalized(controller.customValue)
            return value.isEmpty ? tr("eigener Wert") : value
        }
        return MaintDeviceLanguage.option(for: controller.choice)?.title ?? controller.choice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            deviceCard
                .maintAppear(1, reduceMotion: reduceMotion)
            MaintOutputLanguageCard(session: session, controller: controller, reduceMotion: reduceMotion)
                .maintAppear(2, reduceMotion: reduceMotion)
        }
        .task {
            await controller.loadIfNeeded(session: session)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: controller.phase)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: controller.isCustom)
    }

    // MARK: Gerät

    private var deviceCard: some View {
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.printing) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 20) {
                    currentBadge
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Druckersprache am Gerät"))
                            .font(Theme.Typography.title)
                        Text(tr("Legt fest, welche Befehlssprache der Drucker selbst erwartet. Unter Windows nur über das Bedienfeld oder die Setup Utilities erreichbar – hier mit einem Klick."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await controller.load(session: session) }
                    } label: {
                        Label(tr("Neu lesen"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(controller.phase == .loading || controller.isApplying)
                }

                if controller.phase == .unavailable {
                    MaintNote(tr("Der Drucker meldet keine Gerätesprache – vermutlich unterstützt er die Umschaltung per SGD nicht (kein Link-OS). Ein Wert kann trotzdem gesendet werden."),
                              style: .warning)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(options) { option in
                        optionTile(option)
                    }
                    customTile
                }
                .disabled(controller.isApplying)

                if controller.isCustom {
                    HStack(spacing: 10) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.secondary)
                        TextField(tr("Eigener Wert, z. B. apl-e"), text: $controller.customValue)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.Typography.code)
                            .frame(maxWidth: 320)
                        Text(tr("Wird unverändert als device.languages gesendet."))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                applyRow

                MaintNote(tr("Nach dem Umstellen verarbeitet der Drucker nur noch Befehle der gewählten Sprache. SGD-Befehle wie dieser funktionieren in jedem Modus – du kannst jederzeit zurückwechseln."),
                          style: .info)
            }
        }
    }

    private var currentBadge: some View {
        let value = controller.deviceValue
        let title = value.map { MaintDeviceLanguage.option(for: $0)?.title ?? $0 } ?? "–"
        return VStack(spacing: 4) {
            Text(verbatim: MaintDeviceLanguage.sgdName)
                .font(Theme.Typography.codeSmall)
                .foregroundStyle(Color.white.opacity(0.85))
            if controller.phase == .loading && value == nil {
                ProgressRing(progress: nil, size: 26, lineWidth: 3)
                    .padding(.vertical, 4)
            } else {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.opacity)
            }
            Text(tr("aktiv am Drucker"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .frame(width: 170, height: 104)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Theme.printing, Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.printing.opacity(0.35), radius: 12, y: 5)
        }
        .phaseAnimator([false, true], trigger: reduceMotion ? 0 : controller.changeCount) { content, pop in
            content.scaleEffect(pop ? 1.08 : 1)
        } animation: { pop in
            pop ? Animation.spring(response: 0.25, dampingFraction: 0.55) : Animation.spring(response: 0.45, dampingFraction: 0.75)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: controller.deviceValue)
        .accessibilityElement(children: .combine)
    }

    private func optionTile(_ option: MaintDeviceLanguageOption) -> some View {
        let isSelected = !controller.isCustom && controller.choice == option.value
        let isActive = controller.deviceValue.map { MaintDeviceLanguage.normalized($0) == option.value } ?? false
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8)) {
                controller.select(option)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.printing)
                        .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                    Text(option.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 0)
                    if isActive {
                        MaintChip(tr("Aktiv"), systemImage: "checkmark", tint: Theme.ready)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(option.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(verbatim: option.value)
                        .font(Theme.Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    ForEach(MaintDeviceLanguage.outputs(of: option, model: session.model)) { output in
                        MaintChip(output.displayName, tint: output == session.saved.language ? Theme.ready : Theme.offline)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background {
                ZStack {
                    shape.fill(Theme.subtleFill)
                    if isSelected {
                        shape
                            .fill(Theme.printing.opacity(0.14))
                            .overlay(shape.strokeBorder(Theme.printing.opacity(0.7), lineWidth: 1.5))
                            .matchedGeometryEffect(id: "maintenance.language.choice", in: namespace)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customTile: some View {
        let isSelected = controller.isCustom
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8)) {
                controller.isCustom = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.magenta)
                    Text(tr("Eigener Wert"))
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 0)
                    MaintChip(tr("Profi"), tint: Theme.magenta)
                }
                Text(tr("Für Sonderfälle wie APL-Emulationen oder modellspezifische Kombinationen."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background {
                ZStack {
                    shape.fill(Theme.subtleFill)
                    if isSelected {
                        shape
                            .fill(Theme.magenta.opacity(0.12))
                            .overlay(shape.strokeBorder(Theme.magenta.opacity(0.65), lineWidth: 1.5))
                            .matchedGeometryEffect(id: "maintenance.language.choice", in: namespace)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var applyRow: some View {
        let pending = controller.hasPendingChange
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pending ? tr("Neu: %@", selectedTitle) : tr("Keine Änderung"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .contentTransition(.opacity)
                Text(pending ? tr("Gedrückt halten, um den Drucker umzustellen.")
                             : tr("Wähle eine andere Sprache, um den Drucker umzustellen."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if pending {
                Button(tr("Verwerfen")) {
                    withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { controller.revert() }
                }
                .buttonStyle(.labelWerkPlain)
                .disabled(controller.deviceValue == nil || controller.isApplying)
                .transition(.opacity)
            }
            if controller.isApplying {
                HStack(spacing: 8) {
                    ProgressRing(progress: nil, size: 16, lineWidth: 2.5)
                    Text(tr("Wird umgestellt …"))
                        .font(.system(size: 12.5, weight: .medium))
                }
                .transition(.opacity)
            } else {
                HoldToConfirmButton(title: tr("Am Drucker umstellen"), systemImage: "character.bubble.fill",
                                    tint: Theme.printing, duration: 1.0) {
                    Task { await controller.apply(session: session, model: model) }
                }
                .disabled(!pending)
                .allowsHitTesting(pending)
                .opacity(pending ? 1 : 0.45)
                .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: pending)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: controller.isApplying)
    }
}

// MARK: - Ausgabesprache von LabelWerk

private struct MaintOutputLanguageCard: View {
    let session: PrinterSession
    let controller: MaintLanguageController
    let reduceMotion: Bool

    private var availableOutputs: [PrinterLanguage] {
        let supported = session.model?.languages ?? PrinterLanguage.allCases
        return supported.isEmpty ? PrinterLanguage.allCases : supported
    }

    private var outputBinding: Binding<PrinterLanguage> {
        Binding(
            get: { session.saved.language },
            set: { newValue in
                withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                    session.saved.language = newValue
                }
            }
        )
    }

    var body: some View {
        let device = controller.deviceValue
        let output = session.saved.language
        let compatible = device.map {
            MaintDeviceLanguage.isCompatible(deviceValue: $0, output: output, model: session.model)
        }
        let suggestion = device.flatMap {
            MaintDeviceLanguage.suggestedOutput(forDeviceValue: $0, model: session.model, current: output)
        }
        let tint: Color = compatible == false ? Theme.warning : (compatible == true ? Theme.ready : Theme.offline)

        GlassCard(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Ausgabesprache von LabelWerk"),
                              subtitle: tr("Diese Sprache erzeugen LabelWerk und die macOS-Warteschlange beim Drucken"),
                              systemImage: "arrow.left.arrow.right")

                HStack(alignment: .center, spacing: 16) {
                    side(title: tr("Drucker erwartet"),
                         value: device.map { MaintDeviceLanguage.option(for: $0)?.title ?? $0 } ?? tr("unbekannt"),
                         symbol: "printer")
                    Image(systemName: compatible == false ? "exclamationmark.triangle.fill"
                                      : (compatible == true ? "checkmark.circle.fill" : "questionmark.circle"))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: reduceMotion ? Bool?.none : compatible)
                    side(title: tr("LabelWerk sendet"), value: output.displayName, symbol: "laptopcomputer")
                    Spacer(minLength: 8)
                    if compatible == false, let suggestion, suggestion != output {
                        Button {
                            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                                session.saved.language = suggestion
                            }
                        } label: {
                            Label(tr("LabelWerk auf %@ umstellen", suggestion.displayName), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.labelWerkPrimary)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }

                Text(explanation(compatible: compatible, device: device, output: output))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)

                HStack(spacing: 12) {
                    Text(tr("Ausgabesprache"))
                        .font(.system(size: 12.5, weight: .medium))
                    Picker(tr("Ausgabesprache"), selection: outputBinding) {
                        ForEach(availableOutputs) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Spacer(minLength: 0)
                }
                MaintNote(tr("Ein Wechsel der Ausgabesprache baut die Verbindung kurz neu auf. Auch die macOS-Warteschlange druckt danach in der neuen Sprache."),
                          style: .info)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: compatible)
    }

    private func side(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: symbol, tint: Theme.printing, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .contentTransition(.opacity)
            }
        }
    }

    private func explanation(compatible: Bool?, device: String?, output: PrinterLanguage) -> String {
        guard let device else {
            return tr("Die Gerätesprache ist unbekannt. Stimmen Drucker- und Ausgabesprache nicht überein, druckt der Drucker Befehlstext statt Etiketten – oder gar nichts.")
        }
        if compatible == true {
            return tr("Passt: Der Drucker versteht %@, was LabelWerk sendet.", output.displayName)
        }
        return tr("Achtung: Der Drucker erwartet „%@“, LabelWerk sendet aber %@. Etiketten werden dann als Text gedruckt oder ignoriert – Gerätesprache oder Ausgabesprache angleichen.",
                  MaintDeviceLanguage.option(for: device)?.title ?? device, output.displayName)
    }
}

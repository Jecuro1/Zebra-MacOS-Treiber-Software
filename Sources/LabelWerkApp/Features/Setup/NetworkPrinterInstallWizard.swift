import AppKit
import SwiftUI
import LabelWerkKit

/// Installationsassistent „Drucker installieren“ – wie „Drucker hinzufügen“ unter Windows, nur
/// schöner: Drucker im Netzwerk finden oder Adresse eingeben, Modell automatisch erkennen,
/// benennen, installieren. Danach ist der Drucker ein normaler macOS-Drucker (Systemeinstellungen
/// „Drucker & Scanner“, Druckdialog jedes Programms) mit dem LabelWerk-Treiber.
///
/// Tastatur: ↩ = Weiter/Installieren/Fertig, Esc = Abbrechen. Respektiert „Bewegung reduzieren“.
struct NetworkPrinterInstallWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var wizard = PrinterSetupWizardModel()
    @Namespace private var namespace

    /// Wird beim Schließen aufgerufen (z. B. damit ein umgebendes Sheet sich mit schließt).
    private let onExit: ((PrinterSetupExit) -> Void)?
    /// Adresse eines schon gefundenen Druckers (Seitenleiste „Im Netzwerk“ › Hinzufügen).
    private let prefill: InstallWizardPrefill?

    init(prefill: InstallWizardPrefill? = nil, onExit: ((PrinterSetupExit) -> Void)? = nil) {
        self.prefill = prefill
        self.onExit = onExit
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ZStack {
                stepContent(wizard.step)
                    .id(wizard.step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 720, height: 560)
        .background { AnimatedBackground(style: .subtle).ignoresSafeArea() }
        .environment(\.appReduceMotion, model.preferences.reduceMotion)
        .interactiveDismissDisabled(wizard.service.isRunning)
        .onAppear {
            wizard.start(app: model)
            if let prefill { wizard.prefill(prefill) }
        }
        .onDisappear { wizard.stop() }
    }

    // MARK: Seiten

    @ViewBuilder
    private func stepContent(_ step: PrinterSetupStep) -> some View {
        switch step {
        case .choose:
            SetupChooseStep(wizard: wizard, reduceMotion: reduceMotion)
        case .model:
            SetupModelStep(wizard: wizard, reduceMotion: reduceMotion)
        case .options:
            SetupOptionsStep(wizard: wizard, reduceMotion: reduceMotion)
        case .install:
            SetupInstallStep(wizard: wizard, reduceMotion: reduceMotion,
                             onRecovery: handle, onOpenPrinter: openPrinter)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = 70
        return .asymmetric(
            insertion: .modifier(
                active: OnboardingPageEffect(offset: wizard.forward ? distance : -distance, blur: 6, opacity: 0, scale: 0.98),
                identity: OnboardingPageEffect(offset: 0, blur: 0, opacity: 1, scale: 1)
            ),
            removal: .modifier(
                active: OnboardingPageEffect(offset: wizard.forward ? -distance : distance, blur: 6, opacity: 0, scale: 0.98),
                identity: OnboardingPageEffect(offset: 0, blur: 0, opacity: 1, scale: 1)
            )
        )
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: "printer.filled.and.paper", tint: Theme.violet, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Drucker installieren"))
                    .font(Theme.Typography.title)
                Text(wizard.step.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            stepIndicator
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.step)
    }

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(PrinterSetupStep.allCases) { item in
                let isCurrent = item == wizard.step
                let isDone = item.rawValue < wizard.step.rawValue
                    || (item == .install && wizard.service.phase == .succeeded)
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(isCurrent ? Color.white.opacity(0.25) : (isDone ? Theme.ready.opacity(0.18) : Theme.subtleFill))
                            .frame(width: 20, height: 20)
                        if isDone && !isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.ready)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Text(verbatim: "\(item.rawValue + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                        }
                    }
                    if isCurrent {
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                .padding(.leading, 3)
                .padding(.trailing, isCurrent ? 10 : 3)
                .padding(.vertical, 3)
                .background {
                    if isCurrent {
                        Capsule()
                            .fill(Theme.brandGradient)
                            .shadow(color: Theme.violet.opacity(0.35), radius: 5, y: 2)
                            .matchedGeometryEffect(id: "setupActiveStep", in: namespace)
                    }
                }
                .help(item.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("Schritt %d von %d: %@", item.rawValue + 1, PrinterSetupStep.allCases.count, item.title))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack(spacing: 10) {
            Button(leftTitle) { close(.cancelled) }
                .buttonStyle(.labelWerkPlain)
                .keyboardShortcut(.cancelAction)
                .disabled(wizard.service.isRunning)
                .help(tr("Assistent schließen (Esc)"))

            Spacer(minLength: 8)

            if let hint = footerHint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            if showsBack {
                Button {
                    wizard.goBack()
                } label: {
                    Label(tr("Zurück"), systemImage: "chevron.left")
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.large)
                .transition(.opacity)
            }

            Button(action: primaryAction) {
                HStack(spacing: 7) {
                    if isBusy {
                        ProgressRing(progress: nil, size: 14, lineWidth: 2.5)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(primaryTitle)
                        .contentTransition(.opacity)
                    if let symbol = primarySymbol, !isBusy {
                        Image(systemName: symbol)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.labelWerkPrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryEnabled)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: wizard.step)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isBusy)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: wizard.service.phase)
    }

    private var isBusy: Bool { wizard.isDetecting || wizard.service.isRunning }

    private var leftTitle: String {
        wizard.service.phase == .succeeded ? tr("Schließen") : tr("Abbrechen")
    }

    private var showsBack: Bool {
        switch wizard.step {
        case .choose: return false
        case .model, .options: return true
        case .install: return wizard.service.phase == .failed
        }
    }

    private var footerHint: String? {
        switch wizard.step {
        case .choose:
            if let descriptor = wizard.currentDescriptor { return descriptor.displayString }
            return nil
        case .model:
            return wizard.selectedModel?.displayName
        case .options:
            if wizard.isLoadingQueueMatches { return tr("Vorhandene macOS-Drucker werden geprüft …") }
            if wizard.driverInstalled { return nil }
            return wizard.driverInstallable ? tr("Der Treiber wird mitinstalliert") : tr("Treiberpaket fehlt")
        case .install:
            return nil
        }
    }

    private var primaryTitle: String {
        switch wizard.step {
        case .choose:
            return wizard.isDetecting ? tr("Drucker wird geprüft …") : tr("Weiter")
        case .model:
            return wizard.isDetecting ? tr("Modell wird erkannt …") : tr("Weiter")
        case .options:
            return tr("Installieren")
        case .install:
            switch wizard.service.phase {
            case .idle, .running: return tr("Wird installiert …")
            case .failed: return tr("Erneut versuchen")
            case .succeeded: return tr("Fertig")
            }
        }
    }

    private var primarySymbol: String? {
        switch wizard.step {
        case .choose, .model: return "chevron.right"
        case .options: return "arrow.down.circle.fill"
        case .install:
            switch wizard.service.phase {
            case .failed: return "arrow.clockwise"
            case .succeeded: return "checkmark"
            case .idle, .running: return nil
            }
        }
    }

    private var primaryEnabled: Bool {
        switch wizard.step {
        case .choose: return wizard.canContinueFromChoose
        // Ohne gültiges Etikett (z. B. „Benutzerdefiniert …“ mit fehlender Höhe) geht es nicht weiter.
        case .model: return !wizard.isDetecting && wizard.selectedStock != nil
        case .options: return wizard.canInstall
        case .install: return !wizard.service.isRunning && wizard.service.phase != .idle
        }
    }

    private func primaryAction() {
        switch wizard.step {
        case .choose:
            wizard.continueFromChoose()
        case .model:
            wizard.go(to: .options)
        case .options:
            wizard.startInstall()
        case .install:
            switch wizard.service.phase {
            case .failed: wizard.retryInstall()
            case .succeeded: close(.finished)
            case .idle, .running: break
            }
        }
    }

    // MARK: Aktionen

    private func handle(_ recovery: PrinterInstallFailure.Recovery) {
        switch recovery {
        case .retry:
            wizard.retryInstall()
        case .editConnection:
            wizard.go(to: .choose)
        case .chooseModel:
            wizard.go(to: .model)
        case .openDriver:
            model.selection = .driver
            close(.navigated)
        case .openPrinterSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openPrinter() {
        if let id = wizard.service.result?.sessionID {
            model.selection = .printer(id)
        }
        close(.navigated)
    }

    private func close(_ exit: PrinterSetupExit) {
        guard !wizard.service.isRunning else { return }
        wizard.stop()
        model.isInstallWizardPresented = false
        dismiss()
        // Erst nach dem eigenen Schließen: Ein umgebendes Sheet kann sich danach mit schließen.
        onExit?(exit)
    }
}

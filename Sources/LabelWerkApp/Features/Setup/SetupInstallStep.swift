import SwiftUI
import LabelWerkKit

/// Schritt 4 „Installieren“: animierte Checkliste der Installationsschritte mit Live-Fortschritt,
/// verständliche Fehler mit Lösungswegen und ein Erfolgsbildschirm.
struct SetupInstallStep: View {
    @Bindable var wizard: PrinterSetupWizardModel
    let reduceMotion: Bool
    let onRecovery: (PrinterInstallFailure.Recovery) -> Void
    let onOpenPrinter: () -> Void

    var body: some View {
        ZStack {
            if wizard.service.phase == .succeeded, let result = wizard.service.result {
                successView(result)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                progressView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.service.phase)
    }

    // MARK: Fortschritt

    private var progressView: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.brandAngularGradient)
                        .frame(width: 150, height: 150)
                        .blur(radius: 42)
                        .opacity(0.4)
                    PrinterIllustration(state: illustrationState, isPrinting: false, accent: accent,
                                        category: wizard.selectedModel?.category ?? .desktop,
                                        labelAspect: labelAspect,
                                        printTrigger: reduceMotion ? 0 : finishedCount)
                        .frame(width: 170, height: 188)
                }
                Text(statusText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                StripedProgressBar(progress: progressFraction, tint: progressTint)
                    .frame(width: 170)
            }
            .frame(width: 200)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GlassCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(wizard.displayedSteps.enumerated()), id: \.element.id) { index, step in
                                SetupChecklistRow(step: step, reduceMotion: reduceMotion)
                                if index < wizard.displayedSteps.count - 1 {
                                    Divider().opacity(0.35).padding(.leading, 38)
                                }
                            }
                        }
                    }
                    if let failure = wizard.service.failure {
                        failureCard(failure)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 22)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.service.failure)
    }

    private var accent: Color { DiscoveryAccentPalette.color(wizard.accentHue) }

    private var labelAspect: CGFloat {
        guard let stock = wizard.selectedStock else { return 1.5 }
        return CGFloat(stock.heightMM / max(stock.widthMM, 1))
    }

    private var finishedCount: Int {
        wizard.service.steps.filter { step in
            switch step.state {
            case .done, .warning: return true
            case .pending, .running, .skipped, .failed: return false
            }
        }.count
    }

    private var progressFraction: Double? {
        let steps = wizard.displayedSteps
        guard !steps.isEmpty else { return nil }
        if wizard.service.phase == .failed { return Double(finishedCount) / Double(steps.count) }
        let finished = steps.filter { $0.state.isFinished }.count
        // Laufender Schritt zählt halb – der Balken bewegt sich sichtbar weiter.
        let running = steps.contains { if case .running = $0.state { return true } else { return false } } ? 0.5 : 0
        return min(1, (Double(finished) + running) / Double(steps.count))
    }

    private var progressTint: Color {
        switch wizard.service.phase {
        case .failed: return wizard.service.failure?.isCancellation == true ? Theme.warning : Theme.error
        default: return Theme.accent
        }
    }

    private var illustrationState: PrinterState {
        switch wizard.service.phase {
        case .failed: return wizard.service.failure?.isCancellation == true ? .paused : .error
        case .running: return .printing
        case .idle, .succeeded: return .ready
        }
    }

    private var statusText: String {
        switch wizard.service.phase {
        case .idle: return tr("Installation wird vorbereitet …")
        case .running:
            if let running = wizard.service.steps.first(where: { if case .running = $0.state { return true } else { return false } }) {
                return running.kind.title
            }
            return tr("Wird installiert …")
        case .failed:
            return wizard.service.failure?.isCancellation == true ? tr("Abgebrochen") : tr("Installation fehlgeschlagen")
        case .succeeded: return tr("Fertig")
        }
    }

    // MARK: Fehler

    private func failureCard(_ failure: PrinterInstallFailure) -> some View {
        let tint = failure.isCancellation ? Theme.warning : Theme.error
        return GlassCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: failure.isCancellation ? "hand.raised.fill" : "xmark.octagon.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, value: reduceMotion ? "" : failure.title)
                    Text(failure.title)
                        .font(Theme.Typography.headline)
                }
                Text(failure.message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.paused)
                    Text(failure.hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let actions = failure.recoveries.filter { $0 != .retry }
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.self) { recovery in
                            Button {
                                onRecovery(recovery)
                            } label: {
                                Label(title(for: recovery), systemImage: symbol(for: recovery))
                            }
                            .buttonStyle(.labelWerkSecondary)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func title(for recovery: PrinterInstallFailure.Recovery) -> String {
        switch recovery {
        case .retry: return tr("Erneut versuchen")
        case .editConnection: return tr("Adresse ändern")
        case .chooseModel: return tr("Modell ändern")
        case .openDriver: return tr("Treiber & Warteschlangen")
        case .openPrinterSettings: return tr("Drucker & Scanner öffnen")
        }
    }

    private func symbol(for recovery: PrinterInstallFailure.Recovery) -> String {
        switch recovery {
        case .retry: return "arrow.clockwise"
        case .editConnection: return "network"
        case .chooseModel: return "printer"
        case .openDriver: return "shippingbox"
        case .openPrinterSettings: return "gearshape"
        }
    }

    // MARK: Erfolg

    private func successView(_ result: PrinterInstallResult) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(Theme.ready.opacity(0.14))
                    .frame(width: 118, height: 118)
                IconBadge(systemImage: "checkmark", tint: Theme.ready, size: 74)
                    .keyframeAnimator(initialValue: 1.0, trigger: wizard.celebration) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.22, duration: 0.22, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.6, spring: .bouncy)
                    }
                CelebrationBurst(trigger: wizard.celebration, colors: [Theme.ready, Theme.teal, Theme.violet])
                    .frame(width: 340, height: 300)
            }
            .frame(height: 124)

            VStack(spacing: 6) {
                Text(tr("„%@“ ist installiert", result.displayName))
                    .font(Theme.Typography.title)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(tr("Der Drucker erscheint jetzt in den Systemeinstellungen unter „Drucker & Scanner“ und im Druckdialog jedes Programms (⌘P)."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DiscoveryFlowLayout(spacing: 6) {
                chip(result.reusedQueue ? tr("Aktualisiert: %@", result.queueName) : tr("Warteschlange: %@", result.queueName),
                     symbol: "list.bullet.rectangle", tint: Theme.indigo)
                chip(result.usesGenericDriver ? tr("Allgemeiner Treiber") : tr("Modelltreiber"),
                     symbol: "shippingbox.fill", tint: Theme.teal)
                if result.isDefault {
                    chip(tr("Standarddrucker"), symbol: "star.fill", tint: Theme.paused)
                }
                if result.testPageSent {
                    chip(tr("Testseite gesendet"), symbol: "doc.text.fill", tint: Theme.printing)
                }
                if result.sessionID != nil {
                    chip(tr("In LabelWerk überwacht"), symbol: "waveform.path.ecg", tint: Theme.ready)
                }
            }
            .frame(maxWidth: 560)

            if !result.warnings.isEmpty {
                VStack(spacing: 6) {
                    ForEach(result.warnings, id: \.self) { warning in
                        DiscoveryInlineNote(systemImage: "exclamationmark.triangle.fill", text: warning, tint: Theme.warning)
                    }
                }
                .frame(maxWidth: 560)
            }

            HStack(spacing: 10) {
                if result.sessionID != nil {
                    Button(action: onOpenPrinter) {
                        Label(tr("Drucker öffnen"), systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.labelWerkSecondary)
                }
                Button {
                    wizard.installAnother()
                } label: {
                    Label(tr("Weiteren Drucker installieren"), systemImage: "plus.circle")
                }
                .buttonStyle(.labelWerkSecondary)
                Button {
                    onRecovery(.openPrinterSettings)
                } label: {
                    Label(tr("Drucker & Scanner öffnen"), systemImage: "gearshape")
                }
                .buttonStyle(.labelWerkPlain)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.8))
    }
}

// MARK: - Zeile der Checkliste

struct SetupChecklistRow: View {
    let step: PrinterInstallStep
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                statusIcon
                    .id(iconKey)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isPending ? Color.secondary : Color.primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contentTransition(.opacity)
                        .transition(.opacity)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(isSkipped ? 0.6 : 1)
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: iconKey)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: detail)
        .accessibilityElement(children: .combine)
    }

    private var isPending: Bool { step.state == .pending }

    private var isSkipped: Bool {
        if case .skipped = step.state { return true }
        return false
    }

    private var iconKey: String {
        switch step.state {
        case .pending: return "pending"
        case .running: return "running"
        case .done: return "done"
        case .warning: return "warning"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.state {
        case .pending:
            ZStack {
                Circle()
                    .strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: step.kind.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        case .running:
            ProgressRing(progress: nil, size: 22, lineWidth: 3)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.ready)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.error)
        }
    }

    private var detail: String? {
        switch step.state {
        case .pending: return nil
        case .running(let text): return text
        case .done(let text): return text
        case .warning(let text): return text
        case .skipped(let text): return text
        case .failed(let text): return text
        }
    }

    private var detailColor: Color {
        switch step.state {
        case .warning: return Theme.warning
        case .failed: return Theme.error
        default: return Color.secondary
        }
    }
}

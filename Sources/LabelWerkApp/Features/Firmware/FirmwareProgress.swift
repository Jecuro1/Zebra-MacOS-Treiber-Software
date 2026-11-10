import SwiftUI
import LabelWerkKit

// MARK: - Chip-Illustration

/// Stilisierter Prozessor mit Kontakten; während des Updates läuft ein Farbring um den Chip.
struct FirmwareChipIllustration: View {
    let active: Bool
    let reduceMotion: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    init(active: Bool, reduceMotion: Bool) {
        self.active = active
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let pinCount = 4
                let inset = size.width * 0.24
                let span = size.width - inset * 2
                let length = size.width * 0.1
                let thickness: CGFloat = 4
                for index in 0..<pinCount {
                    let offset = inset + span * CGFloat(index) / CGFloat(pinCount - 1)
                    let rects = [
                        CGRect(x: offset - thickness / 2, y: 0, width: thickness, height: length),
                        CGRect(x: offset - thickness / 2, y: size.height - length, width: thickness, height: length),
                        CGRect(x: 0, y: offset - thickness / 2, width: length, height: thickness),
                        CGRect(x: size.width - length, y: offset - thickness / 2, width: length, height: thickness),
                    ]
                    for rect in rects {
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Theme.separator))
                    }
                }
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !active || reduceMotion || controlActiveState == .inactive)) { timeline in
                let angle = active && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate * 140 : 0
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        AngularGradient(colors: [Theme.violet, Theme.teal, Theme.magenta, Theme.violet],
                                        center: .center, angle: .degrees(angle)),
                        lineWidth: 3
                    )
                    .padding(9)
                    .opacity(active ? 1 : 0.3)
            }
            IconBadge(systemImage: "cpu", tint: Theme.violet, size: 58)
                .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? nil : Motion.gentle, value: active)
        .accessibilityHidden(true)
    }
}

// MARK: - Übertragung

/// Fortschritt der Übertragung: Ring, Streifenbalken, Prozent, Rate, Restzeit, Dauer.
struct FirmwareTransferCard: View {
    let session: PrinterSession
    let controller: FirmwareUpdateController
    let reduceMotion: Bool

    init(session: PrinterSession, controller: FirmwareUpdateController, reduceMotion: Bool) {
        self.session = session
        self.controller = controller
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        // Live-Wert der Sitzung, sonst der zuletzt gemessene Stand.
        let progress = min(1, max(0, session.progress ?? controller.progress))
        let known = progress > 0
        let total = controller.file?.size ?? 0
        let transferred = Int(Double(total) * progress)
        GlassCard(padding: 22, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.printing) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    ProgressRing(progress: known ? progress : nil, size: 136, lineWidth: 11)
                    VStack(spacing: 1) {
                        Text(TransferFormat.percent(progress))
                            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: progress))
                            .animation(reduceMotion ? nil : Motion.snappy, value: progress)
                        Text(tr("übertragen"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    CelebrationBurst(trigger: controller.celebration)
                        .frame(width: 280, height: 280)
                }
                .frame(width: 136, height: 136)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Firmware wird übertragen …"))
                            .font(Theme.Typography.title)
                        Text(verbatim: controller.file?.fileName ?? "")
                            .font(Theme.Typography.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    StripedProgressBar(progress: known ? progress : nil, tint: Theme.printing)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .leading)],
                              alignment: .leading, spacing: 10) {
                        stat(title: tr("Übertragen"), systemImage: "arrow.up.circle",
                             value: tr("%@ von %@", TransferFormat.bytes(transferred), TransferFormat.bytes(total)))
                        stat(title: tr("Rate"), systemImage: "speedometer",
                             value: controller.bytesPerSecond.map(TransferFormat.rate) ?? tr("wird gemessen …"))
                        stat(title: tr("Restzeit"), systemImage: "hourglass",
                             value: controller.estimatedRemaining.map(TransferFormat.duration) ?? tr("wird berechnet …"))
                        VStack(alignment: .leading, spacing: 2) {
                            Label(tr("Vergangen"), systemImage: "clock")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            if let started = controller.startedAt {
                                Text(started, style: .timer)
                                    .font(Theme.Typography.metricSmall)
                            } else {
                                Text(verbatim: "–")
                                    .font(Theme.Typography.metricSmall)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Firmware wird übertragen"))
        .accessibilityValue(TransferFormat.percent(progress))
    }

    private func stat(title: String, systemImage: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.Typography.metricSmall)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : Motion.snappy, value: value)
        }
    }
}

// MARK: - Nach der Übertragung

private enum FirmwareStepState: Equatable {
    case pending, active, done, failed
}

private struct FirmwareStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String?
    let state: FirmwareStepState
}

/// Neustart-Countdown, automatische Wiederverbindung und Ergebnis.
struct FirmwarePostUpdateCard: View {
    let session: PrinterSession
    let controller: FirmwareUpdateController
    let reduceMotion: Bool

    init(session: PrinterSession, controller: FirmwareUpdateController, reduceMotion: Bool) {
        self.session = session
        self.controller = controller
        self.reduceMotion = reduceMotion
    }

    private var tint: Color {
        switch controller.phase {
        case .completed: return Theme.ready
        case .reconnectFailed: return Theme.warning
        default: return Theme.printing
        }
    }

    private var title: String {
        switch controller.phase {
        case .rebooting: return tr("Drucker installiert die Firmware")
        case .reconnecting: return tr("Verbindung wird wiederhergestellt …")
        case .completed: return tr("Firmware-Update abgeschlossen")
        case .reconnectFailed: return tr("Drucker antwortet noch nicht")
        default: return tr("Firmware-Update")
        }
    }

    private var message: String {
        switch controller.phase {
        case .rebooting:
            return tr("Der Drucker schreibt die Firmware in seinen Speicher und startet anschließend neu. Bitte nicht ausschalten – die Anzeigen können dabei blinken.")
        case .reconnecting(let attempt, let total):
            return tr("Versuch %d von %d – der Drucker kann nach dem Update etwas länger zum Starten brauchen.", attempt, total)
        case .completed(let newFirmware):
            return completionMessage(newFirmware)
        case .reconnectFailed:
            return tr("Manche Drucker brauchen nach dem Update mehrere Minuten. Prüfe die Anzeige am Drucker und schalte ihn erst aus und wieder ein, wenn die Installation sichtbar abgeschlossen ist.")
        default:
            return ""
        }
    }

    private func completionMessage(_ newFirmware: String?) -> String {
        guard let newFirmware, !newFirmware.isEmpty else {
            return tr("Der Drucker ist wieder erreichbar.")
        }
        if let previous = controller.previousFirmware, !previous.isEmpty {
            if FirmwareVersion(previous) == FirmwareVersion(newFirmware), FirmwareVersion(newFirmware) != nil {
                return tr("Die Version ist unverändert (%@). Falls eine andere Version erwartet wurde, das Konfigurationsetikett prüfen.", newFirmware)
            }
            return tr("Jetzt installiert: %@ (vorher %@).", newFirmware, previous)
        }
        return tr("Jetzt installiert: %@.", newFirmware)
    }

    private var steps: [FirmwareStep] {
        let duration = controller.transferDuration.map(TransferFormat.duration)
        let size = TransferFormat.bytes(controller.file?.size ?? 0)
        let transferDetail = duration.map { tr("%@ in %@", size, $0) } ?? size
        let install: FirmwareStepState
        let reconnect: FirmwareStepState
        let verify: FirmwareStepState
        switch controller.phase {
        case .rebooting:
            install = .active; reconnect = .pending; verify = .pending
        case .reconnecting:
            install = .done; reconnect = .active; verify = .pending
        case .completed:
            install = .done; reconnect = .done; verify = .done
        case .reconnectFailed:
            install = .done; reconnect = .failed; verify = .pending
        default:
            install = .pending; reconnect = .pending; verify = .pending
        }
        var verifyDetail: String?
        if case .completed(let newFirmware) = controller.phase, let newFirmware {
            verifyDetail = newFirmware
        }
        return [
            FirmwareStep(id: 0, title: tr("Übertragung abgeschlossen"), detail: transferDetail, state: .done),
            FirmwareStep(id: 1, title: tr("Installation & Neustart"), detail: tr("Der Drucker arbeitet selbstständig"), state: install),
            FirmwareStep(id: 2, title: tr("Verbindung wiederherstellen"), detail: session.saved.descriptor.displayString, state: reconnect),
            FirmwareStep(id: 3, title: tr("Neue Version prüfen"), detail: verifyDetail, state: verify),
        ]
    }

    var body: some View {
        GlassCard(padding: 22, cornerRadius: Theme.Metrics.cornerLarge, tint: tint) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 24) {
                    indicator
                        .frame(width: 124, height: 124)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(Theme.Typography.title)
                            .contentTransition(.opacity)
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        actions
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                FirmwareStepList(steps: steps, reduceMotion: reduceMotion)
                if !controller.reconnectLog.isEmpty {
                    attemptLog
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: controller.phase)
        .animation(reduceMotion ? nil : Motion.spring, value: controller.reconnectLog)
    }

    // MARK: Anzeige

    @ViewBuilder
    private var indicator: some View {
        switch controller.phase {
        case .rebooting(let start, let until):
            let total = max(1, until.timeIntervalSince(start))
            TimelineView(.periodic(from: start, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let remaining = max(0, total - elapsed)
                RingGauge(value: min(1, max(0, elapsed / total)), lineWidth: 10,
                          colors: [Theme.printing, Theme.teal],
                          label: tr("Neustart"), valueText: TransferFormat.duration(remaining))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .reconnecting:
            ZStack {
                PulseRings(color: Theme.printing, active: true)
                IconBadge(systemImage: "antenna.radiowaves.left.and.right", tint: Theme.printing, size: 58)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .completed:
            ZStack {
                IconBadge(systemImage: "checkmark.seal.fill", tint: Theme.ready, size: 84)
                    .keyframeAnimator(initialValue: FirmwareBadgeBounce(), trigger: controller.celebration) { content, value in
                        content
                            .scaleEffect(value.scale)
                            .rotationEffect(.degrees(value.angle))
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(0.6, duration: 0.01)
                            SpringKeyframe(1.15, duration: 0.3, spring: .bouncy)
                            SpringKeyframe(1.0, duration: 0.5, spring: .smooth)
                        }
                        KeyframeTrack(\.angle) {
                            CubicKeyframe(-12, duration: 0.15)
                            CubicKeyframe(8, duration: 0.18)
                            SpringKeyframe(0, duration: 0.45, spring: .bouncy)
                        }
                    }
                CelebrationBurst(trigger: controller.celebration, colors: [Theme.ready, Theme.teal, Theme.violet, Theme.magenta])
                    .frame(width: 320, height: 320)
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .reconnectFailed:
            IconBadge(systemImage: "wifi.exclamationmark", tint: Theme.warning, size: 84)
                .symbolEffect(.bounce, value: controller.reconnectLog.count)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        default:
            ProgressRing(progress: nil, size: 60, lineWidth: 6)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.phase {
        case .rebooting(_, let until):
            HStack(spacing: 10) {
                Button {
                    controller.skipWaiting(session: session, reduceMotion: reduceMotion)
                } label: {
                    Label(tr("Nicht warten – jetzt verbinden"), systemImage: "bolt.horizontal")
                }
                .buttonStyle(.labelWerkSecondary)
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(tr("Automatische Verbindung in"))
                    Text(timerInterval: Date.now...max(Date.now, until), countsDown: true)
                        .monospacedDigit()
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        case .reconnecting:
            HStack(spacing: 8) {
                ProgressRing(progress: nil, size: 16, lineWidth: 2)
                Text(tr("Verbinde mit %@ …", session.saved.descriptor.displayString))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .completed:
            HStack(spacing: 8) {
                Button {
                    Task { await session.printTestLabel() }
                } label: {
                    Label(tr("Testetikett"), systemImage: "printer.dotmatrix.filled.and.paper")
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(session.isBusy)
                Button {
                    Task { await session.perform(.printConfiguration) }
                } label: {
                    Label(tr("Konfiguration drucken"), systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(session.isBusy)
                Button(tr("Fertig")) {
                    controller.finish(reduceMotion: reduceMotion)
                }
                .buttonStyle(.labelWerkPlain)
            }
        case .reconnectFailed:
            HStack(spacing: 8) {
                Button {
                    controller.retryReconnect(session: session, reduceMotion: reduceMotion)
                } label: {
                    Label(tr("Erneut versuchen"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkPrimary)
                Button(tr("Fertig")) {
                    controller.finish(reduceMotion: reduceMotion)
                }
                .buttonStyle(.labelWerkPlain)
            }
        default:
            EmptyView()
        }
    }

    private var attemptLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Verbindungsversuche"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(controller.reconnectLog.suffix(5)) { attempt in
                HStack(spacing: 8) {
                    Image(systemName: attempt.success ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(attempt.success ? Theme.ready : Theme.offline)
                    Text(attempt.date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(attempt.success ? tr("Verbunden") : (attempt.message ?? tr("Keine Antwort")))
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.subtleFill)
        }
    }
}

struct FirmwareBadgeBounce {
    var scale: CGFloat = 1
    var angle: Double = 0
}

// MARK: - Schrittliste

private struct FirmwareStepList: View {
    let steps: [FirmwareStep]
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        marker(step.state)
                            .frame(width: 22, height: 22)
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(step.state == .done ? Theme.ready.opacity(0.6) : Theme.separator)
                                .frame(width: 2)
                                .frame(minHeight: 16, maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 13, weight: step.state == .active ? .semibold : .medium))
                            .foregroundStyle(step.state == .pending ? Color.secondary : Color.primary)
                        if let detail = step.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, index < steps.count - 1 ? 12 : 0)
                    Spacer(minLength: 0)
                }
                .transferAppear(index: index, reduceMotion: reduceMotion)
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: steps)
    }

    @ViewBuilder
    private func marker(_ state: FirmwareStepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(Theme.ready)
                .transition(.scale.combined(with: .opacity))
        case .active:
            ProgressRing(progress: nil, size: 19, lineWidth: 2.5)
                .transition(.opacity)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(Theme.warning)
                .transition(.scale.combined(with: .opacity))
        case .pending:
            Circle()
                .strokeBorder(Theme.separator, lineWidth: 2)
                .frame(width: 17, height: 17)
        }
    }
}

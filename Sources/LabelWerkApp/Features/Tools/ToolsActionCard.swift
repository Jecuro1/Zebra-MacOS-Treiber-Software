import SwiftUI
import LabelWerkKit

// MARK: - Gruppen

/// Gruppe von Gerätebefehlen auf der Werkzeugseite.
struct ToolsActionGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let actions: [PrinterAction]

    /// Alle Gruppen in Anzeigereihenfolge. Befehle, die keiner Gruppe zugeordnet sind (z. B. künftige
    /// Ergänzungen von `PrinterAction`), landen automatisch in „Weitere Befehle“.
    static func makeAll() -> [ToolsActionGroup] {
        var groups: [ToolsActionGroup] = [
            ToolsActionGroup(
                id: "print",
                title: tr("Drucken & Testen"),
                subtitle: tr("Test- und Konfigurationsetiketten, Netzwerkdaten und Speicherverzeichnis"),
                systemImage: "printer.dotmatrix.filled.and.paper",
                tint: Theme.violet,
                actions: [.printTestLabel, .printConfiguration, .printNetworkConfiguration, .printDirectory]
            ),
            ToolsActionGroup(
                id: "media",
                title: tr("Medien"),
                subtitle: tr("Sensoren kalibrieren, Sensorprofil drucken, Etikett vorschieben"),
                systemImage: "square.stack.3d.up",
                tint: Theme.teal,
                actions: [.calibrate, .sensorProfile, .feedLabel]
            ),
            ToolsActionGroup(
                id: "control",
                title: tr("Steuerung"),
                subtitle: tr("Pausieren, fortsetzen, Aufträge abbrechen und Neustart"),
                systemImage: "playpause",
                tint: Theme.printing,
                actions: [.pause, .resume, .cancelCurrent, .cancelAll, .reset]
            ),
            ToolsActionGroup(
                id: "persist",
                title: tr("Speichern & Zurücksetzen"),
                subtitle: tr("Einstellungen dauerhaft sichern oder Werkseinstellungen laden"),
                systemImage: "externaldrive.badge.checkmark",
                tint: Theme.magenta,
                actions: [.saveSettings, .restoreNetworkDefaults, .restoreFactoryDefaults]
            ),
        ]
        let covered = Set(groups.flatMap(\.actions))
        let remaining = PrinterAction.allCases.filter { !covered.contains($0) }
        if !remaining.isEmpty {
            groups.append(ToolsActionGroup(
                id: "more",
                title: tr("Weitere Befehle"),
                subtitle: tr("Zusätzliche Gerätebefehle dieses Druckers"),
                systemImage: "ellipsis.circle",
                tint: Theme.indigo,
                actions: remaining
            ))
        }
        return groups
    }
}

// MARK: - Aktionskarte

/// Karte für einen Gerätebefehl: animiert Ausführung (Fortschrittsring → Häkchen bzw. Kreuz mit
/// Schütteln), fragt bei zerstörerischen Befehlen per Gedrückthalten nach und erklärt, warum ein
/// Befehl für die eingestellte Druckersprache nicht verfügbar ist.
struct ToolsActionCard: View {
    let action: PrinterAction
    let session: PrinterSession
    let tint: Color
    let isSupported: Bool
    let appearanceIndex: Int
    let appeared: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var phase: ToolsRunPhase = .idle
    @State private var shakeCount = 0
    @State private var successCount = 0
    @State private var resetTask: Task<Void, Never>?

    init(action: PrinterAction, session: PrinterSession, tint: Color, isSupported: Bool,
         appearanceIndex: Int, appeared: Bool) {
        self.action = action
        self.session = session
        self.tint = tint
        self.isSupported = isSupported
        self.appearanceIndex = appearanceIndex
        self.appeared = appeared
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var needsConfirmation: Bool { action.isDestructive && model.preferences.confirmDestructiveActions }
    private var isDisabled: Bool { !isSupported || phase == .running || session.isBusy }
    private var isVisible: Bool { appeared || reduceMotion }

    private var accent: Color {
        switch phase {
        case .succeeded: return Theme.ready
        case .failed: return Theme.error
        case .idle, .running: return action.isDestructive ? Theme.error : tint
        }
    }

    private var badgeSymbol: String {
        switch phase {
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .idle, .running: return action.systemImage
        }
    }

    private var statusText: String {
        if !isSupported {
            return tr("Mit %@ nicht verfügbar", session.saved.language.displayName)
        }
        switch phase {
        case .idle: return needsConfirmation ? tr("Zum Ausführen gedrückt halten") : tr("Bereit")
        case .running: return tr("Wird ausgeführt …")
        case .succeeded: return tr("Erledigt")
        case .failed: return tr("Fehlgeschlagen")
        }
    }

    private var statusColor: Color {
        switch phase {
        case .idle: return Color.secondary
        case .running: return Theme.accent
        case .succeeded: return Theme.ready
        case .failed: return Theme.error
        }
    }

    var body: some View {
        GlassCard(padding: 14, tint: phase == .idle ? nil : accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    badge
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(tr(action.displayName))
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            if action.isDestructive {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.error)
                                    .help(tr("Zerstörerischer Befehl"))
                            }
                        }
                        Text(tr(action.detail))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    Spacer(minLength: 6)
                    runControl
                }
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        }
        .saturation(isSupported ? 1 : 0.2)
        .opacity(isSupported ? 1 : 0.62)
        .modifier(ToolsShakeEffect(trigger: shakeCount))
        .cardHoverEffect()
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 14)
        .animation(reduceMotion ? nil : Motion.spring.delay(Double(appearanceIndex) * 0.035), value: appeared)
        .help(isSupported ? tr(action.detail)
                          : tr("Dieser Befehl ist für die Druckersprache %@ nicht verfügbar.",
                               session.saved.language.displayName))
        .onDisappear { resetTask?.cancel() }
    }

    // MARK: Symbol

    private struct BadgePop {
        var scale: CGFloat = 1
        var angle: Double = 0
    }

    private var badge: some View {
        ZStack {
            if phase == .running {
                ProgressRing(progress: nil, size: 52, lineWidth: 3)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            IconBadge(systemImage: badgeSymbol, tint: isSupported ? accent : Theme.offline, size: 40)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: successCount)
                .keyframeAnimator(initialValue: BadgePop(), trigger: successCount) { content, value in
                    content
                        .scaleEffect(value.scale)
                        .rotationEffect(.degrees(value.angle))
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.18, duration: 0.14)
                        SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                    }
                    KeyframeTrack(\.angle) {
                        CubicKeyframe(-8, duration: 0.1)
                        CubicKeyframe(6, duration: 0.12)
                        SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                    }
                }
        }
        .frame(width: 52, height: 52)
    }

    // MARK: Auslöser

    @ViewBuilder
    private var runControl: some View {
        if !isSupported {
            Image(systemName: "nosign")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        } else if needsConfirmation {
            HoldToConfirmButton(title: tr("Ausführen"), systemImage: action.systemImage, tint: Theme.error) {
                run()
            }
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
        } else {
            Button(action: run) {
                Label(phase == .running ? tr("Läuft …") : tr("Ausführen"), systemImage: "play.fill")
            }
            .buttonStyle(action.isDestructive ? LabelWerkButtonStyle.labelWerkDestructive
                                              : LabelWerkButtonStyle.labelWerkSecondary)
            .controlSize(.small)
            .disabled(isDisabled)
        }
    }

    private func run() {
        guard isSupported, phase != .running else { return }
        resetTask?.cancel()
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
            phase = .running
        }
        Task {
            let ok = await session.perform(action)
            withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
                phase = ok ? .succeeded : .failed
            }
            if !reduceMotion {
                if ok {
                    successCount += 1
                } else {
                    withAnimation(.linear(duration: 0.45)) { shakeCount += 1 }
                }
            }
            scheduleReset(after: ok ? 2.4 : 3.6)
        }
    }

    private func scheduleReset(after seconds: Double) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                phase = .idle
            }
        }
    }
}

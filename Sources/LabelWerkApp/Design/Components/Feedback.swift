import AppKit
import SwiftUI

/// Leerer Zustand mit animiertem Symbol, Erklärung und optionaler Aktion.
struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    @State private var appeared = false

    init(title: String, message: String, systemImage: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                PulseRings(color: Theme.violet, active: true)
                    .frame(width: 150, height: 150)
                    .opacity(0.6)
                IconBadge(systemImage: systemImage, tint: Theme.violet, size: 68)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.Typography.title)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).padding(.horizontal, 8)
                }
                .buttonStyle(.labelWerkPrimary)
                .opacity(appeared ? 1 : 0)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.05)) { appeared = true }
        }
    }
}

/// Gedrückt halten zum Bestätigen – für zerstörerische Aktionen (Werkseinstellungen, Firmware …).
struct HoldToConfirmButton: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.error
    var duration: Double = 1.2
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var completed = false
    @State private var pressing = false

    init(title: String, systemImage: String, tint: Color = Theme.error, duration: Double = 1.2, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.duration = duration
        self.action = action
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: completed ? "checkmark" : systemImage)
                .contentTransition(.symbolEffect(.replace))
            Text(pressing ? tr("Gedrückt halten …") : title)
                .contentTransition(.opacity)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(progress > 0.5 ? Color.white : tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    Capsule().fill(tint).frame(width: proxy.size.width * progress)
                }
            }
        }
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .clipShape(Capsule())
        .scaleEffect(pressing ? 0.97 : 1)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 30) {
            completed = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            action()
            Task {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeOut(duration: 0.3)) {
                    progress = 0
                    completed = false
                }
            }
        } onPressingChanged: { isPressing in
            pressing = isPressing
            if isPressing {
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else if !completed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { progress = 0 }
            }
        }
        .animation(Motion.snappy, value: pressing)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityHint(tr("Zum Bestätigen gedrückt halten"))
        .accessibilityAction { action() }
        .help(tr("Zum Bestätigen gedrückt halten"))
    }
}

/// Stapel der aktuellen Hinweise (unten rechts im Fenster).
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(model.toasts) { toast in
                ToastView(toast: toast) { model.dismissToast(toast.id) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .trailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }
        }
        .frame(maxWidth: 380, alignment: .trailing)
    }
}

private struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch toast.style {
        case .info: return Theme.printing
        case .success: return Theme.ready
        case .warning: return Theme.warning
        case .error: return Theme.error
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: toast.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.4)
        }
        .padding(14)
        .labelWerkGlass(cornerRadius: 16, tint: tint)
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 12).padding(.leading, 4)
        }
        .onHover { hovering = $0 }
        .onTapGesture(perform: dismiss)
    }
}

/// Sich ausbreitende Radar-Wellen (Suche, leere Zustände).
struct PulseRings: View {
    let color: Color
    var active: Bool = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    init(color: Color, active: Bool = true) {
        self.color = color
        self.active = active
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) / 2
                for ring in 0..<3 {
                    let phase = ((t / 2.4) + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    let radius = maxRadius * CGFloat(0.25 + 0.75 * phase)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.55 * (1 - phase))), lineWidth: 1.5)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.06 * (1 - phase))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Partikelexplosion bei Erfolgen (z. B. erfolgreicher Druck). Läuft ca. 1,4 s nach jeder Änderung von `trigger`.
struct CelebrationBurst: View {
    let trigger: Int
    var colors: [Color] = [Theme.violet, Theme.teal, Theme.magenta]

    @State private var start: Date?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private let duration: TimeInterval = 1.4

    init(trigger: Int, colors: [Color] = [Theme.violet, Theme.teal, Theme.magenta]) {
        self.trigger = trigger
        self.colors = colors
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: start == nil)) { timeline in
            Canvas { context, size in
                guard let start else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                guard elapsed < duration else { return }
                let progress = elapsed / duration
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var seed = UInt64(truncatingIfNeeded: trigger &* 2654435761)
                func random() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 33) / Double(UInt32.max)
                }
                for index in 0..<46 {
                    let angle = random() * .pi * 2
                    let speed = 80 + random() * 160
                    let distance = speed * progress
                    let gravity = 140 * progress * progress
                    let x = center.x + CGFloat(cos(angle) * distance)
                    let y = center.y + CGFloat(sin(angle) * distance + gravity)
                    let side = CGFloat(4 + random() * 5)
                    let color = colors[index % max(1, colors.count)]
                    var particle = context
                    particle.opacity = 1 - progress
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(angle + progress * 8))
                    let rect = CGRect(x: -side / 2, y: -side / 4, width: side, height: side / 2)
                    particle.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            start = Date()
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.1))
                start = nil
            }
        }
    }
}

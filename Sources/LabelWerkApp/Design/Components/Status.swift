import SwiftUI
import LabelWerkKit

/// Leuchtender Statuspunkt; pulsiert, solange der Drucker druckt oder einen Fehler/Warnung meldet.
struct StatusOrb: View {
    let state: PrinterState
    var size: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: PrinterState, size: CGFloat = 12) {
        self.state = state
        self.size = size
    }

    private var pulses: Bool { [.printing, .error, .warning].contains(state) && !reduceMotion }

    var body: some View {
        ZStack {
            if pulses {
                PulsingRing(color: state.color)
                    .id(state)
            }
            Circle()
                .fill(
                    RadialGradient(colors: [state.color.opacity(0.95), state.color],
                                   center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size)
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: max(1, size * 0.09)))
                .shadow(color: state.color.opacity(0.65), radius: size * 0.45)
        }
        .frame(width: size, height: size)
        .animation(Motion.spring, value: state)
        .accessibilityLabel(state.displayName)
    }
}

/// Einzelner sich ausbreitender Ring (startet beim Erscheinen).
private struct PulsingRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .scaleEffect(expanded ? 2.6 : 1)
            .opacity(expanded ? 0 : 0.85)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// Kapsel mit Statussymbol und -text.
struct StatusPill: View {
    let state: PrinterState
    var text: String?

    init(state: PrinterState, text: String? = nil) {
        self.state = state
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.systemImage)
                .font(.system(size: 11, weight: .bold))
                .symbolEffect(.bounce, value: state)
                .contentTransition(.symbolEffect(.replace))
            Text(text ?? state.displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(state.color.opacity(0.14))
                .overlay(Capsule().strokeBorder(state.color.opacity(0.35), lineWidth: 1))
        }
        .animation(Motion.spring, value: state)
        .accessibilityElement(children: .combine)
    }
}

/// Abgerundetes Quadrat mit Farbverlauf und weißem Symbol (wie App-Icons).
struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 34

    init(systemImage: String, tint: Color, size: CGFloat = 34) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                         startPoint: .top, endPoint: .center))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
            }
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: size * 0.18, y: size * 0.08)
    }
}

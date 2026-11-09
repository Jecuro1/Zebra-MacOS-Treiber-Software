import SwiftUI

/// Einheitlicher Button-Stil von LabelWerk.
struct LabelWerkButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        private var verticalPadding: CGFloat {
            switch controlSize {
            case .mini: return 3
            case .small: return 5
            case .large, .extraLarge: return 11
            default: return 7
            }
        }

        var body: some View {
            configuration.label
                .font(.system(size: controlSize == .small || controlSize == .mini ? 11.5 : 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, kind == .plain ? 8 : 14)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(foreground)
                .background { background }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.965 : (hovering && kind != .plain ? 1.015 : 1))
                .brightness(configuration.isPressed ? -0.05 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 && isEnabled }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .secondary: return .primary
            case .destructive: return .white
            case .plain: return hovering ? Theme.accent : .primary
            }
        }

        @ViewBuilder
        private var background: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            switch kind {
            case .primary:
                shape
                    .fill(Theme.brandGradient)
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                       startPoint: .top, endPoint: .center)))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
                    .shadow(color: Theme.violet.opacity(hovering ? 0.55 : 0.32), radius: hovering ? 12 : 7, y: 3)
            case .destructive:
                shape
                    .fill(LinearGradient(colors: [Theme.error, Theme.error.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
                    .shadow(color: Theme.error.opacity(0.35), radius: 7, y: 3)
            case .secondary:
                shape
                    .fill(.thinMaterial)
                    .overlay(shape.fill(Theme.subtleFill.opacity(hovering ? 1.6 : 1)))
                    .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
            case .plain:
                shape.fill(hovering ? Theme.subtleFill : Color.clear)
            }
        }
    }
}

extension ButtonStyle where Self == LabelWerkButtonStyle {
    /// Markenverlauf, weiße Schrift.
    static var labelWerkPrimary: LabelWerkButtonStyle { LabelWerkButtonStyle(kind: .primary) }
    /// Material/Glas.
    static var labelWerkSecondary: LabelWerkButtonStyle { LabelWerkButtonStyle(kind: .secondary) }
    /// Rot, für zerstörerische Aktionen.
    static var labelWerkDestructive: LabelWerkButtonStyle { LabelWerkButtonStyle(kind: .destructive) }
    /// Nur Hover-Hervorhebung.
    static var labelWerkPlain: LabelWerkButtonStyle { LabelWerkButtonStyle(kind: .plain) }
}

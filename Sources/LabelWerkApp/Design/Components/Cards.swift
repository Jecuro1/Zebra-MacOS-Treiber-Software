import SwiftUI

// MARK: - Glas-/Materialfläche

/// Ab macOS 26 „Liquid Glass“, davor Material mit feinem Rand, Glanzkante und weichem Schatten.
private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular
            content
                .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.07))
                    }
                    // Glanzkante oben
                    shape.fill(
                        LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.06 : 0.35), .clear],
                                       startPoint: .top, endPoint: .center)
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.16 : 0.6),
                                            Theme.cardStroke],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 14, x: 0, y: 6)
    }
}

extension View {
    /// Glasfläche mit abgerundeten Ecken (Liquid Glass ab macOS 26).
    func labelWerkGlass(cornerRadius: CGFloat = Theme.Metrics.corner, tint: Color? = nil) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint))
    }

    /// Lässt Inhalte mit einem wandernden Glanz schimmern (z. B. beim Laden).
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }

    /// Leichtes Anheben mit Schatten, wenn der Mauszeiger darüber ist.
    func cardHoverEffect() -> some View {
        modifier(CardHoverModifier())
    }
}

/// Karte mit Glasfläche als Standard-Container für Inhalte.
struct GlassCard<Content: View>: View {
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let tint: Color?
    private let content: Content

    init(padding: CGFloat = Theme.Metrics.padding, cornerRadius: CGFloat = Theme.Metrics.corner,
         tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .labelWerkGlass(cornerRadius: cornerRadius, tint: tint)
    }
}

// MARK: - Schimmer

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.45), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        phase = -1
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            phase = 1
                        }
                    }
                }
            }
    }
}

// MARK: - Hover

private struct CardHoverModifier: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: hovering ? 18 : 0, y: hovering ? 8 : 0)
            .animation(Motion.spring, value: hovering)
            .onHover { hovering = $0 }
    }
}

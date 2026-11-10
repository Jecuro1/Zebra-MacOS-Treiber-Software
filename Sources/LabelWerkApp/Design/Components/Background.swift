import SwiftUI
import LabelWerkKit

enum AnimatedBackgroundStyle: Equatable {
    /// Markenfarben (Onboarding, Hero-Flächen).
    case brand
    /// Sehr dezent (Listen, Formulare).
    case subtle
    /// Getönt nach Druckerzustand.
    case state(PrinterState)
}

/// Lebendiger, sehr ruhig animierter Hintergrund.
///
/// macOS 15+: `MeshGradient` mit langsam wandernden Stützpunkten. macOS 14: weichgezeichnete
/// Farbflächen. Bei „Bewegung reduzieren“ statisch.
struct AnimatedBackground: View {
    let style: AnimatedBackgroundStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @Environment(\.controlActiveState) private var controlActiveState

    init(style: AnimatedBackgroundStyle) {
        self.style = style
    }

    private var palette: [Color] {
        switch style {
        case .brand:
            return [Theme.indigo, Theme.violet, Theme.teal, Theme.magenta]
        case .subtle:
            return [Theme.violet, Theme.teal, Theme.indigo, Theme.violet]
        case .state(let state):
            let c = Theme.color(for: state)
            switch state {
            case .ready, .unknown, .offline:
                return [Theme.violet, Theme.teal, c, Theme.indigo]
            default:
                return [c, Theme.violet, c, Theme.indigo]
            }
        }
    }

    private var intensity: Double {
        switch style {
        case .brand: return colorScheme == .dark ? 0.85 : 0.75
        case .subtle: return colorScheme == .dark ? 0.16 : 0.10
        case .state: return colorScheme == .dark ? 0.22 : 0.13
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if #available(macOS 15.0, *) {
                MeshBackground(palette: palette, intensity: intensity,
                               paused: reduceMotion || controlActiveState == .inactive)
            } else {
                BlobBackground(palette: palette, intensity: intensity, animated: !reduceMotion)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: style)
        .allowsHitTesting(false)
    }
}

@available(macOS 15.0, *)
private struct MeshBackground: View {
    let palette: [Color]
    let intensity: Double
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3,
                points: points(t),
                colors: colors
            )
            .opacity(intensity)
            .blur(radius: 30)
        }
    }

    private var colors: [Color] {
        let p = palette + palette
        return [p[0], p[1], p[2],
                p[3], p[0].opacity(0.8), p[1],
                p[2], p[3], p[0]]
    }

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func wobble(_ phase: Double, _ amount: Double) -> Float { Float(sin(t * 0.18 + phase) * amount) }
        return [
            [0, 0], [0.5 + wobble(0, 0.12), 0], [1, 0],
            [0, 0.5 + wobble(1.3, 0.14)], [0.5 + wobble(2.1, 0.16), 0.5 + wobble(0.7, 0.16)], [1, 0.5 + wobble(2.9, 0.14)],
            [0, 1], [0.5 + wobble(4.2, 0.12), 1], [1, 1],
        ]
    }
}

private struct BlobBackground: View {
    let palette: [Color]
    let intensity: Double
    let animated: Bool
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(palette[index % palette.count])
                        .frame(width: size.width * 0.7, height: size.width * 0.7)
                        .offset(blobOffset(index, size: size))
                        .blur(radius: 90)
                }
            }
            .frame(width: size.width, height: size.height)
            .opacity(intensity)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private func blobOffset(_ index: Int, size: CGSize) -> CGSize {
        let base: [CGSize] = [
            CGSize(width: -0.35, height: -0.35), CGSize(width: 0.4, height: -0.25),
            CGSize(width: -0.25, height: 0.4), CGSize(width: 0.35, height: 0.35),
        ]
        let shift: [CGSize] = [
            CGSize(width: 0.12, height: 0.08), CGSize(width: -0.1, height: 0.12),
            CGSize(width: 0.1, height: -0.1), CGSize(width: -0.12, height: -0.06),
        ]
        let b = base[index], s = shift[index]
        let k: CGFloat = drift ? 1 : 0
        return CGSize(width: (b.width + s.width * k) * size.width, height: (b.height + s.height * k) * size.height)
    }
}

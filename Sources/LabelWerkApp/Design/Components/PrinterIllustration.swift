import SwiftUI
import LabelWerkKit

/// Animierte, stilisierte Druckerdarstellung für die Übersicht.
///
/// * `printTrigger` ändern → ein Etikett fährt heraus, wird „abgerissen“ und fällt weg.
/// * `isPrinting` → Etiketten laufen kontinuierlich aus dem Schlitz.
/// * Zustand färbt die Status-LED (Fehler blinkt, Pause „atmet“), offline wirkt entsättigt.
struct PrinterIllustration: View {
    let state: PrinterState
    let isPrinting: Bool
    let accent: Color
    var category: PrinterCategory = .desktop
    var labelAspect: CGFloat = 1.5
    var printTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @Environment(\.colorScheme) private var colorScheme

    init(state: PrinterState, isPrinting: Bool, accent: Color,
         category: PrinterCategory = .desktop, labelAspect: CGFloat = 1.5, printTrigger: Int = 0) {
        self.state = state
        self.isPrinting = isPrinting
        self.accent = accent
        self.category = category
        self.labelAspect = labelAspect
        self.printTrigger = printTrigger
    }

    var body: some View {
        GeometryReader { geo in
            let W = min(geo.size.width, geo.size.height / 1.1)
            let H = W * 1.1
            let geometry = PrinterGeometry(width: W, height: H, category: category, labelAspect: labelAspect)
            ZStack(alignment: .topLeading) {
                // Bodenschatten
                Ellipse()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.22))
                    .frame(width: geometry.bodyRect.width * 0.92, height: W * 0.07)
                    .blur(radius: W * 0.03)
                    .position(x: W / 2, y: geometry.bodyRect.maxY + W * 0.01)

                // Etiketten (nur unterhalb des Schlitzes sichtbar)
                LabelFeed(geometry: geometry, isPrinting: isPrinting && !reduceMotion,
                          printTrigger: printTrigger, accent: accent, reduceMotion: reduceMotion)
                    .frame(width: W, height: H)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: W, height: max(0, H - geometry.slotY))
                            .offset(y: geometry.slotY)
                    }

                PrinterBody(geometry: geometry, state: state, accent: accent, category: category,
                            colorScheme: colorScheme, reduceMotion: reduceMotion)
            }
            .frame(width: W, height: H)
            .saturation(state == .offline ? 0.15 : 1)
            .opacity(state == .offline ? 0.75 : 1)
            .modifier(ShakeEffect(shakes: state == .error && !reduceMotion ? 1 : 0))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1 / 1.1, contentMode: .fit)
        .animation(.spring(response: 0.5, dampingFraction: 0.35), value: state == .error)
        .animation(Motion.gentle, value: state)
        .accessibilityElement()
        .accessibilityLabel(tr("Drucker, Zustand: %@", state.displayName))
    }
}

// MARK: - Geometrie

private struct PrinterGeometry {
    let width: CGFloat
    let height: CGFloat
    let category: PrinterCategory
    let labelAspect: CGFloat

    var bodyRect: CGRect {
        switch category {
        case .mobile:
            return CGRect(x: width * 0.2, y: height * 0.14, width: width * 0.6, height: height * 0.42)
        case .industrial, .printEngine:
            return CGRect(x: width * 0.06, y: height * 0.08, width: width * 0.88, height: height * 0.5)
        case .desktop, .healthcare:
            return CGRect(x: width * 0.1, y: height * 0.12, width: width * 0.8, height: height * 0.44)
        }
    }

    /// y-Position des Ausgabeschlitzes.
    var slotY: CGFloat { bodyRect.maxY - bodyRect.height * 0.14 }
    var labelWidth: CGFloat { bodyRect.width * (category == .mobile ? 0.7 : 0.55) }
    var labelLength: CGFloat { min(labelWidth * max(0.4, min(labelAspect, 2.2)), height - slotY - height * 0.04) }
    var gap: CGFloat { width * 0.025 }
    var cornerTop: CGFloat {
        switch category {
        case .desktop, .healthcare: return bodyRect.width * 0.2
        case .mobile: return bodyRect.width * 0.16
        case .industrial, .printEngine: return bodyRect.width * 0.04
        }
    }
}

// MARK: - Gehäuse

private struct PrinterBody: View {
    let geometry: PrinterGeometry
    let state: PrinterState
    let accent: Color
    let category: PrinterCategory
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    var body: some View {
        let r = geometry.bodyRect
        let shell = UnevenRoundedRectangle(
            topLeadingRadius: geometry.cornerTop, bottomLeadingRadius: r.width * 0.05,
            bottomTrailingRadius: r.width * 0.05, topTrailingRadius: geometry.cornerTop, style: .continuous
        )
        let dark = colorScheme == .dark
        ZStack(alignment: .topLeading) {
            // Grundkörper
            shell
                .fill(LinearGradient(colors: dark ? [Color(white: 0.30), Color(white: 0.13)]
                                                  : [Color(white: 0.38), Color(white: 0.17)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    shell.fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                              startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
                }
                .overlay { shell.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .shadow(color: .black.opacity(0.3), radius: r.width * 0.04, y: r.width * 0.02)

            // Deckelfuge mit Akzentlinie
            Capsule()
                .fill(LinearGradient(colors: [accent.opacity(0.0), accent, accent.opacity(0.0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: r.width * 0.86, height: max(1.5, r.height * 0.018))
                .offset(x: r.minX + r.width * 0.07, y: r.minY + r.height * 0.42)
                .shadow(color: accent.opacity(0.7), radius: 4)

            // Sichtfenster (Etikettenrolle), nicht bei Industriegeräten
            if category != .industrial && category != .printEngine {
                RoundedRectangle(cornerRadius: r.width * 0.05, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .overlay {
                        RollGlimpse(spinning: state == .printing && !reduceMotion)
                            .padding(r.width * 0.02)
                    }
                    .frame(width: r.width * 0.34, height: r.height * 0.22)
                    .clipShape(RoundedRectangle(cornerRadius: r.width * 0.05, style: .continuous))
                    .offset(x: r.minX + r.width * 0.33, y: r.minY + r.height * 0.12)
            } else {
                // Display der Industriedrucker
                RoundedRectangle(cornerRadius: r.width * 0.02, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.85), accent.opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: r.height * 0.02) {
                            Capsule().fill(.white.opacity(0.9)).frame(width: r.width * 0.12, height: r.height * 0.025)
                            Capsule().fill(.white.opacity(0.6)).frame(width: r.width * 0.08, height: r.height * 0.02)
                        }
                        .padding(.leading, r.width * 0.02)
                    }
                    .frame(width: r.width * 0.22, height: r.height * 0.16)
                    .offset(x: r.minX + r.width * 0.68, y: r.minY + r.height * 0.14)
            }

            // Frontblende
            RoundedRectangle(cornerRadius: r.width * 0.04, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: dark ? 0.22 : 0.28), Color(white: dark ? 0.1 : 0.14)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: r.width * 0.92, height: r.height * 0.36)
                .offset(x: r.minX + r.width * 0.04, y: r.minY + r.height * 0.56)

            // Ausgabeschlitz
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .frame(width: geometry.labelWidth * 1.12, height: max(3, r.height * 0.035))
                .offset(x: geometry.width / 2 - geometry.labelWidth * 0.56, y: geometry.slotY - max(3, r.height * 0.035) / 2)

            // Bedientaste
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.25)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .frame(width: r.width * 0.075, height: r.width * 0.075)
                .offset(x: r.minX + r.width * 0.1, y: r.minY + r.height * 0.62)

            // Status-LED
            StatusLED(state: state, reduceMotion: reduceMotion)
                .frame(width: r.width * 0.05, height: r.width * 0.05)
                .offset(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.635)
        }
    }
}

/// Status-LED mit Glühen; blinkt bei Fehler, „atmet“ bei Pause.
private struct StatusLED: View {
    let state: PrinterState
    let reduceMotion: Bool
    @State private var phase = false

    var body: some View {
        let color = Theme.color(for: state)
        Circle()
            .fill(color)
            .overlay(Circle().fill(Color.white.opacity(0.6)).scaleEffect(0.35).offset(x: -1, y: -1))
            .shadow(color: color, radius: phase ? 8 : 4)
            .opacity(animated ? (phase ? 1 : 0.35) : 1)
            .onAppear(perform: start)
            .onChange(of: state) { _, _ in start() }
    }

    private var animated: Bool { !reduceMotion && (state == .error || state == .paused || state == .warning) }

    private func start() {
        phase = false
        guard animated else { phase = true; return }
        let duration = state == .error ? 0.45 : 1.2
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            phase = true
        }
    }
}

/// Angedeutete Etikettenrolle im Sichtfenster.
private struct RollGlimpse: View {
    let spinning: Bool
    @State private var angle = 0.0

    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height) * 1.6
            ZStack {
                Circle().fill(Theme.labelPaper.opacity(0.92))
                Circle().stroke(Color.black.opacity(0.08), lineWidth: d * 0.02).scaleEffect(0.8)
                Circle().stroke(Color.black.opacity(0.06), lineWidth: d * 0.02).scaleEffect(0.6)
                Circle().fill(Color(white: 0.3)).scaleEffect(0.3)
                Rectangle().fill(Color.black.opacity(0.12)).frame(width: d * 0.02, height: d * 0.5)
                    .offset(y: -d * 0.2)
            }
            .frame(width: d, height: d)
            .rotationEffect(.degrees(angle))
            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.95)
        }
        .onAppear(perform: update)
        .onChange(of: spinning) { _, _ in update() }
    }

    private func update() {
        if spinning {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.6)) { angle = 0 }
        }
    }
}

// MARK: - Etikettenausgabe

private struct FeedValue {
    var progress: CGFloat = 0.12   // 0 = im Schlitz, 1 = vollständig heraus
    var tilt: Double = 0
    var drop: CGFloat = 0
    var opacity: Double = 1
}

private struct LabelFeed: View {
    let geometry: PrinterGeometry
    let isPrinting: Bool
    let printTrigger: Int
    let accent: Color
    let reduceMotion: Bool

    var body: some View {
        let x = geometry.width / 2 - geometry.labelWidth / 2
        if isPrinting {
            TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let period = geometry.labelLength + geometry.gap
                let offset = CGFloat((t * Double(geometry.width) * 0.22).truncatingRemainder(dividingBy: Double(period)))
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3, id: \.self) { index in
                        LabelFace(accent: accent, seed: index)
                            .frame(width: geometry.labelWidth, height: geometry.labelLength)
                            .offset(x: x, y: geometry.slotY - geometry.labelLength + offset - CGFloat(index - 1) * period)
                    }
                }
            }
        } else {
            LabelFace(accent: accent, seed: printTrigger)
                .frame(width: geometry.labelWidth, height: geometry.labelLength)
                .keyframeAnimator(initialValue: FeedValue(), trigger: printTrigger) { content, value in
                    content
                        .rotationEffect(.degrees(value.tilt), anchor: .top)
                        .offset(x: x, y: geometry.slotY - geometry.labelLength + geometry.labelLength * value.progress + value.drop)
                        .opacity(value.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.progress) {
                        LinearKeyframe(0, duration: 0.05)
                        SpringKeyframe(1, duration: reduceMotion ? 0.2 : 1.0, spring: .smooth)
                        LinearKeyframe(1, duration: 0.9)
                        LinearKeyframe(1, duration: 0.5)
                        LinearKeyframe(0.12, duration: 0.01)
                        LinearKeyframe(0.12, duration: 0.3)
                    }
                    KeyframeTrack(\.tilt) {
                        LinearKeyframe(0, duration: 1.95)
                        CubicKeyframe(-7, duration: 0.15)
                        CubicKeyframe(14, duration: 0.35)
                        LinearKeyframe(0, duration: 0.01)
                        LinearKeyframe(0, duration: 0.3)
                    }
                    KeyframeTrack(\.drop) {
                        LinearKeyframe(0, duration: 2.0)
                        CubicKeyframe(geometry.height * 0.5, duration: 0.45)
                        LinearKeyframe(0, duration: 0.01)
                        LinearKeyframe(0, duration: 0.3)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 2.05)
                        LinearKeyframe(0, duration: 0.4)
                        LinearKeyframe(0, duration: 0.01)
                        LinearKeyframe(1, duration: 0.3)
                    }
                }
        }
    }
}

/// Stilisierte Etikettenoberfläche mit Titelzeile, Textzeilen, Barcode und QR-Andeutung.
private struct LabelFace: View {
    let accent: Color
    let seed: Int

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.05, style: .continuous)
                    .fill(Theme.labelPaper)
                    .shadow(color: .black.opacity(0.18), radius: w * 0.03, y: w * 0.015)
                VStack(alignment: .leading, spacing: h * 0.04) {
                    RoundedRectangle(cornerRadius: w * 0.02)
                        .fill(Theme.labelInk)
                        .frame(height: h * 0.12)
                        .overlay(alignment: .leading) {
                            Capsule().fill(accent).frame(width: w * 0.28, height: h * 0.035).padding(.leading, w * 0.05)
                        }
                    ForEach(0..<3, id: \.self) { line in
                        Capsule()
                            .fill(Theme.labelInk.opacity(line == 0 ? 0.7 : 0.35))
                            .frame(width: w * [0.7, 0.55, 0.62][((line + seed) % 3 + 3) % 3], height: h * 0.035)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: w * 0.05) {
                        BarcodeGlyph(seed: seed)
                            .frame(height: h * 0.22)
                        QRGlyph(seed: seed)
                            .frame(width: h * 0.22, height: h * 0.22)
                    }
                }
                .padding(w * 0.08)
            }
        }
    }
}

private struct BarcodeGlyph: View {
    let seed: Int
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            var i = seed &* 7 &+ 3
            let unit = size.width / 64
            while x < size.width {
                i = (i &* 1103515245 &+ 12345) & 0x7fffffff
                let bar = CGFloat(1 + (i >> 8) % 3) * unit
                let space = CGFloat(1 + (i >> 12) % 2) * unit
                context.fill(Path(CGRect(x: x, y: 0, width: min(bar, size.width - x), height: size.height)),
                             with: .color(Theme.labelInk))
                x += bar + space
            }
        }
    }
}

private struct QRGlyph: View {
    let seed: Int
    var body: some View {
        Canvas { context, size in
            let n = 9
            let cell = size.width / CGFloat(n)
            var i = seed &* 31 &+ 17
            for y in 0..<n {
                for x in 0..<n {
                    let finder = (x < 3 && y < 3) || (x > 5 && y < 3) || (x < 3 && y > 5)
                    i = (i &* 1103515245 &+ 12345) & 0x7fffffff
                    if finder ? !(x % 6 == 1 && y % 6 == 1) : (i >> 9) % 2 == 0 {
                        context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)),
                                     with: .color(Theme.labelInk))
                    }
                }
            }
        }
    }
}

/// Kurzes Schütteln (z. B. beim Wechsel in einen Fehlerzustand).
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = 6 * sin(shakes * .pi * 6) * (1 - abs(shakes - 0.5) * 2 + 0.0001)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

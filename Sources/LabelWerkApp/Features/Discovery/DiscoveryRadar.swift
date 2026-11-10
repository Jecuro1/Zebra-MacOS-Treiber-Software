import SwiftUI
import LabelWerkKit

/// Radar der Druckersuche: Gitterringe, Radar-Wellen, rotierender Suchstrahl, Fortschrittsbogen
/// und gefundene Drucker als leuchtende Punkte. Punkte glühen auf, wenn der Strahl sie überstreicht.
///
/// Die Zeitleiste läuft nur während einer Suche (30 Bilder/s) und steht sonst still.
struct DiscoveryRadar: View {
    let printers: [DiscoveredPrinter]
    let isScanning: Bool
    let startedAt: Date?
    let duration: Double
    let addedIDs: Set<String>
    let highlightedID: String?
    let reduceMotion: Bool
    var onSelect: (DiscoveredPrinter) -> Void = { _ in }

    /// Grad pro Sekunde des Suchstrahls.
    private let sweepSpeed: Double = 120

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                DiscoveryRadarBackdrop(isScanning: isScanning)
                    .frame(width: side, height: side)

                if isScanning && !reduceMotion {
                    PulseRings(color: Theme.teal, active: true)
                        .frame(width: side, height: side)
                        .transition(.opacity)
                }

                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isScanning || reduceMotion)) { timeline in
                    let angle = sweepAngle(at: timeline.date)
                    let progress = scanProgress(at: timeline.date)
                    ZStack {
                        if isScanning && !reduceMotion {
                            DiscoveryRadarSweep(angle: angle)
                                .frame(width: side, height: side)
                                .transition(.opacity)
                        }
                        if isScanning {
                            Circle()
                                .trim(from: 0, to: max(0.002, progress))
                                .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: side - 4, height: side - 4)
                                .shadow(color: Theme.teal.opacity(0.5), radius: 4)
                                .transition(.opacity)
                        }
                        ForEach(printers) { printer in
                            blip(for: printer, sweep: angle, side: side)
                                .transition(.scale(scale: 0.1).combined(with: .opacity))
                        }
                    }
                    .frame(width: side, height: side)
                }

                DiscoveryRadarCore(isScanning: isScanning, count: printers.count, reduceMotion: reduceMotion)
                    .frame(width: side * 0.24, height: side * 0.24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: printers.map(\.id))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: isScanning)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isScanning ? tr("Suche läuft") : tr("Suchradar"))
    }

    // MARK: Zeitabhängige Werte

    private func sweepAngle(at date: Date) -> Double {
        guard let startedAt else { return -90 }
        return (date.timeIntervalSince(startedAt) * sweepSpeed - 90).truncatingRemainder(dividingBy: 360)
    }

    private func scanProgress(at date: Date) -> Double {
        guard isScanning, let startedAt else { return 0 }
        return min(1, max(0, date.timeIntervalSince(startedAt) / max(duration, 0.1)))
    }

    // MARK: Treffer

    private func blip(for printer: DiscoveredPrinter, sweep: Double, side: CGFloat) -> some View {
        let polar = DiscoveryGeometry.polar(for: printer.id)
        let radians = polar.degrees * .pi / 180
        let distance = side / 2 * CGFloat(polar.radius)
        let x = side / 2 + CGFloat(cos(radians)) * distance
        let y = side / 2 + CGFloat(sin(radians)) * distance
        let glow = glowIntensity(blipDegrees: polar.degrees, sweep: sweep)
        return DiscoveryRadarBlip(
            tint: DiscoverySourceStyle.tint(printer.source),
            glow: glow,
            isAdded: addedIDs.contains(printer.id),
            isHighlighted: highlightedID == printer.id,
            label: printer.name,
            reduceMotion: reduceMotion
        ) {
            onSelect(printer)
        }
        .position(x: x, y: y)
    }

    /// 1 direkt hinter dem Strahl, klingt über 140° ab; ohne Suche gleichmäßiges Leuchten.
    private func glowIntensity(blipDegrees: Double, sweep: Double) -> Double {
        guard isScanning, !reduceMotion else { return 0.55 }
        var delta = (sweep - blipDegrees).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        return max(0.25, 1 - delta / 140)
    }
}

// MARK: - Hintergrund

private struct DiscoveryRadarBackdrop: View {
    let isScanning: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.indigo.opacity(colorScheme == .dark ? 0.55 : 0.18),
                                 Theme.violet.opacity(colorScheme == .dark ? 0.22 : 0.08),
                                 Theme.teal.opacity(0.05)],
                        center: .center, startRadius: 0, endRadius: 220
                    )
                )
            ForEach(1..<5, id: \.self) { ring in
                Circle()
                    .strokeBorder(Theme.teal.opacity(isScanning ? 0.32 : 0.18),
                                  style: StrokeStyle(lineWidth: 1, dash: ring == 4 ? [] : [3, 4]))
                    .scaleEffect(CGFloat(ring) / 4)
            }
            // Fadenkreuz
            GeometryReader { proxy in
                let size = proxy.size
                Path { path in
                    path.move(to: CGPoint(x: size.width / 2, y: 6))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height - 6))
                    path.move(to: CGPoint(x: 6, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width - 6, y: size.height / 2))
                }
                .stroke(Theme.teal.opacity(0.14), lineWidth: 1)
            }
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.25 : 0.7), Theme.cardStroke],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.2
                )
        }
        .shadow(color: Theme.indigo.opacity(isScanning ? 0.35 : 0.15), radius: isScanning ? 22 : 12, y: 6)
        .animation(Motion.gentle, value: isScanning)
    }
}

// MARK: - Suchstrahl

private struct DiscoveryRadarSweep: View {
    let angle: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Theme.teal.opacity(0), location: 0),
                            .init(color: Theme.teal.opacity(0), location: 0.72),
                            .init(color: Theme.teal.opacity(0.18), location: 0.92),
                            .init(color: Theme.teal.opacity(0.5), location: 1),
                        ]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    )
                )
            // Leitkante des Strahls
            GeometryReader { proxy in
                let radius = min(proxy.size.width, proxy.size.height) / 2
                Capsule()
                    .fill(LinearGradient(colors: [Theme.teal.opacity(0.9), Theme.teal.opacity(0.1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: radius, height: 2)
                    .shadow(color: Theme.teal, radius: 4)
                    .position(x: proxy.size.width / 2 + radius / 2, y: proxy.size.height / 2)
            }
        }
        // Der Verlauf endet bei 0° (rechts); gedreht zeigt die Kante auf den aktuellen Winkel.
        .rotationEffect(.degrees(angle))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - Mitte

private struct DiscoveryRadarCore: View {
    let isScanning: Bool
    let count: Int
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.brandGradient)
                .overlay(Circle().fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                                      startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .shadow(color: Theme.violet.opacity(0.55), radius: isScanning ? 14 : 8)
            VStack(spacing: 1) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isScanning && !reduceMotion)
                if count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(count)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(.white)
        }
        .scaleEffect(isScanning && !reduceMotion ? 1.04 : 1)
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: count)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: isScanning)
        .allowsHitTesting(false)
    }
}

// MARK: - Treffer-Punkt

private struct DiscoveryRadarBlip: View {
    let tint: Color
    let glow: Double
    let isAdded: Bool
    let isHighlighted: Bool
    let label: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18 + 0.35 * glow))
                    .frame(width: 30, height: 30)
                    .blur(radius: 5)
                if isHighlighted {
                    Circle()
                        .strokeBorder(tint, lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                        .phaseAnimator([1.0, 1.35]) { ring, scale in
                            ring
                                .scaleEffect(reduceMotion ? 1 : scale)
                                .opacity(reduceMotion ? 1 : 1.4 - scale)
                        } animation: { _ in
                            .easeOut(duration: 0.9)
                        }
                        .transition(.opacity)
                }
                Circle()
                    .fill(RadialGradient(colors: [Color.white, tint], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: 8))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2))
                    .shadow(color: tint.opacity(0.9), radius: 3 + 5 * glow)
                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Circle().fill(Theme.ready))
                        .offset(x: 8, y: -8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect((1 + 0.22 * glow) * (hovering ? 1.25 : 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.snappy) { hovering = inside }
        }
        .overlay(alignment: .top) {
            if hovering || isHighlighted {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                    .offset(y: -26)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(Motion.snappy, value: isHighlighted)
        .animation(Motion.bouncy, value: isAdded)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

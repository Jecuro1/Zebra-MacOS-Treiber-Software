import AppKit
import SwiftUI

/// Kennzahl-Kachel mit Symbol, animiertem Zahlenwechsel und optionaler Sparkline.
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String?
    let systemImage: String
    let tint: Color
    var trend: [Double]?

    init(title: String, value: String, unit: String? = nil, systemImage: String, tint: Color, trend: [Double]? = nil) {
        self.title = title
        self.value = value
        self.unit = unit
        self.systemImage = systemImage
        self.tint = tint
        self.trend = trend
    }

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconBadge(systemImage: systemImage, tint: tint, size: 26)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(Theme.Typography.metric)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(Motion.spring, value: value)
                if let trend, trend.count > 1 {
                    Sparkline(values: trend, tint: tint)
                        .frame(height: 24)
                }
            }
        }
        .cardHoverEffect()
        .accessibilityElement(children: .combine)
    }
}

/// Ringanzeige 0…1 mit Verlauf und Text in der Mitte.
struct RingGauge: View {
    let value: Double
    var lineWidth: CGFloat = 10
    var colors: [Color] = [Theme.violet, Theme.teal]
    var label: String?
    var valueText: String?

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(value: Double, lineWidth: CGFloat = 10, colors: [Color] = [Theme.violet, Theme.teal],
         label: String? = nil, valueText: String? = nil) {
        self.value = value
        self.lineWidth = lineWidth
        self.colors = colors
        self.label = label
        self.valueText = valueText
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.subtleFill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, shown)))
                .stroke(
                    AngularGradient(colors: colors + [colors.first ?? Theme.violet], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: (colors.last ?? Theme.teal).opacity(0.35), radius: lineWidth * 0.6)
            VStack(spacing: 2) {
                if let valueText {
                    Text(valueText)
                        .font(Theme.Typography.metricSmall)
                        .contentTransition(.numericText())
                }
                if let label {
                    Text(label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(lineWidth)
        }
        .onAppear { animate(to: value) }
        .onChange(of: value) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(valueText ?? "\(Int(value * 100)) %")
    }

    private func animate(to newValue: Double) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.8)) {
            shown = newValue
        }
    }
}

/// Fortschrittsring; `progress == nil` → unbestimmt (drehender Bogen).
struct ProgressRing: View {
    let progress: Double?
    var size: CGFloat = 28
    var lineWidth: CGFloat = 4

    @State private var rotation = 0.0

    init(progress: Double?, size: CGFloat = 28, lineWidth: CGFloat = 4) {
        self.progress = progress
        self.size = size
        self.lineWidth = lineWidth
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.subtleFill, lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.01, min(1, progress)))
                    .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Fortschrittsbalken mit wandernden Streifen.
struct StripedProgressBar: View {
    let progress: Double?
    var tint: Color = Theme.accent

    @State private var stripeOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: Double?, tint: Color = Theme.accent) {
        self.progress = progress
        self.tint = tint
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = CGFloat(progress ?? 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtleFill)
                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        Stripes()
                            .stroke(Color.white.opacity(0.22), lineWidth: proxy.size.height * 0.45)
                            .offset(x: stripeOffset)
                            .clipShape(Capsule())
                    }
                    .frame(width: max(proxy.size.height, width * min(1, max(0, fraction))))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 10)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                stripeOffset = 20
            }
        }
        .accessibilityValue(progress.map { "\(Int($0 * 100)) %" } ?? tr("Läuft"))
    }

    private struct Stripes: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var x: CGFloat = -40
            while x < rect.width + 40 {
                path.move(to: CGPoint(x: x, y: rect.maxY + 4))
                path.addLine(to: CGPoint(x: x + rect.height + 8, y: rect.minY - 4))
                x += 20
            }
            return path
        }
    }
}

/// Kleine Verlaufskurve, beim Erscheinen gezeichnet.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    @State private var drawn: CGFloat = 0

    init(values: [Double], tint: Color) {
        self.values = values
        self.tint = tint
    }

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .opacity(Double(drawn))

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .trim(from: 0, to: drawn)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { drawn = 1 }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let minV = values.min(), let maxV = values.max() else { return [] }
        let span = max(maxV - minV, 0.0001)
        return values.enumerated().map { index, v in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: size.height - size.height * CGFloat((v - minV) / span) * 0.9 - size.height * 0.05)
        }
    }
}

/// Zeile „Schlüssel … Wert“ mit optionalem Kopieren.
struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced: Bool = false
    var copyable: Bool = false
    @State private var hovering = false
    @State private var copied = false

    init(_ key: String, _ value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
        self.copyable = copyable
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? Theme.Typography.code : .system(size: 12.5, weight: .medium))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    withAnimation(Motion.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation(Motion.snappy) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Theme.ready : .secondary)
                .opacity(hovering || copied ? 1 : 0)
                .help(tr("Kopieren"))
            }
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}

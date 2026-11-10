import SwiftUI
import LabelWerkKit

// Kleine, wiederverwendbare Bausteine für „Sicherung & Wartung“.

extension MaintPane {
    var tint: Color {
        switch self {
        case .backup: return Theme.violet
        case .restore: return Theme.teal
        case .language: return Theme.printing
        case .care: return Theme.magenta
        }
    }
}

extension MaintGroupKind {
    var tint: Color {
        switch self {
        case .recommended: return Theme.violet
        case .other: return Theme.teal
        case .network: return Theme.warning
        case .excluded: return Theme.offline
        }
    }

    var badge: String {
        switch self {
        case .recommended: return tr("Empfohlen")
        case .other: return tr("Weitere")
        case .network: return tr("Netzwerk")
        case .excluded: return tr("Ausgeschlossen")
        }
    }
}

// MARK: - Formatierung & Einstellungen

enum MaintFormat {
    /// Strecke als Zahl und Einheit, z. B. („152“, „m“) oder („1,25“, „km“).
    static func lengthParts(_ meters: Double) -> (value: String, unit: String) {
        let value = max(0, meters)
        if value >= 1000 {
            return ((value / 1000).formatted(.number.precision(.fractionLength(2))), "km")
        }
        if value >= 10 {
            return (value.formatted(.number.precision(.fractionLength(0))), "m")
        }
        if value >= 1 {
            return (value.formatted(.number.precision(.fractionLength(1))), "m")
        }
        return ((value * 100).formatted(.number.precision(.fractionLength(0))), "cm")
    }

    static func length(_ meters: Double) -> String {
        let parts = lengthParts(meters)
        return "\(parts.value) \(parts.unit)"
    }
}

enum MaintCareSettings {
    /// Erinnerungsintervall für die Druckkopfreinigung in Metern (App-weit).
    static let intervalKey = "LabelWerk.maintenance.cleaningIntervalMeters"
    static let defaultInterval: Double = 150
    static let intervalRange: ClosedRange<Double> = 25...1000
}

// MARK: - Gestaffeltes Erscheinen

private struct MaintAppearModifier: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Motion.spring.delay(Double(min(index, 8)) * 0.055)) { shown = true }
                }
            }
    }
}

extension View {
    /// Blendet die Ansicht gestaffelt mit leichtem Anheben ein.
    func maintAppear(_ index: Int, reduceMotion: Bool) -> some View {
        modifier(MaintAppearModifier(index: index, reduceMotion: reduceMotion))
    }
}

// MARK: - Hinweis

struct MaintNote: View {
    enum Style {
        case info, success, warning, error

        var tint: Color {
            switch self {
            case .info: return Theme.printing
            case .success: return Theme.ready
            case .warning: return Theme.warning
            case .error: return Theme.error
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let text: String
    let style: Style

    init(_ text: String, style: Style = .info) {
        self.text = text
        self.style = style
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.tint)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(shape.fill(style.tint.opacity(0.09)))
        .overlay(shape.strokeBorder(style.tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chip

struct MaintChip: View {
    let text: String
    let systemImage: String?
    let tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = Theme.accent) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

// MARK: - Kennzahl

struct MaintStat: View {
    let value: Int
    let title: String
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(value)))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: value)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bereichsauswahl

/// Vier Kacheln mit Live-Zusammenfassung; die Auswahl gleitet per `matchedGeometryEffect`.
struct MaintPanePicker: View {
    @Binding var selection: MaintPane
    let detail: (MaintPane) -> String
    let needsAttention: (MaintPane) -> Bool
    let reduceMotion: Bool

    @Namespace private var namespace
    @State private var hovered: MaintPane?
    @State private var availableWidth: CGFloat = 1000

    /// Vier Kacheln nebeneinander, bei schmalem Fenster 2 × 2.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: availableWidth >= 900 ? 4 : 2)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(MaintPane.allCases) { pane in
                tile(pane)
            }
        }
        .padding(6)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
        }
        .labelWerkGlass(cornerRadius: 18)
    }

    private func tile(_ pane: MaintPane) -> some View {
        let isSelected = pane == selection
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8)) {
                selection = pane
            }
        } label: {
            HStack(spacing: 10) {
                IconBadge(systemImage: pane.systemImage, tint: pane.tint, size: 30)
                    .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                    .overlay(alignment: .topTrailing) {
                        if needsAttention(pane) {
                            Circle()
                                .fill(Theme.warning)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.2))
                                .offset(x: 3, y: -3)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(detail(pane))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    shape
                        .fill(pane.tint.opacity(0.15))
                        .overlay(shape.strokeBorder(
                            LinearGradient(colors: [pane.tint.opacity(0.9), pane.tint.opacity(0.35)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.4))
                        .shadow(color: pane.tint.opacity(0.25), radius: 8, y: 3)
                        .matchedGeometryEffect(id: "maintenance.pane", in: namespace)
                } else if hovered == pane {
                    shape.fill(Theme.subtleFill)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                if inside { hovered = pane } else if hovered == pane { hovered = nil }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(pane.title)
    }
}

// MARK: - Arbeitsschritte

struct MaintStepRow: View {
    enum StepState: Equatable { case pending, active, done, failed }

    let title: String
    let systemImage: String
    let state: StepState

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var tint: Color {
        switch state {
        case .pending: return Theme.offline
        case .active: return Theme.accent
        case .done: return Theme.ready
        case .failed: return Theme.error
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 26, height: 26)
                switch state {
                case .active:
                    ProgressRing(progress: nil, size: 15, lineWidth: 2.5)
                        .transition(.opacity)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ready)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.error)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                case .pending:
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            Text(title)
                .font(.system(size: 12.5, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
        }
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: state)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Datenfluss

/// Animierte Datenpunkte zwischen zwei Symbolen (z. B. Drucker → Sicherung).
/// Läuft nur, solange `active` gesetzt ist (30 fps), bei „Bewegung reduzieren“ statisch.
struct MaintFlowView: View {
    let fromSymbol: String
    let toSymbol: String
    let tint: Color
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 6) {
            IconBadge(systemImage: fromSymbol, tint: tint, size: 40)
                .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let start = CGPoint(x: 4, y: size.height / 2)
                    let end = CGPoint(x: size.width - 4, y: size.height / 2)
                    let c1 = CGPoint(x: size.width * 0.33, y: size.height * 0.12)
                    let c2 = CGPoint(x: size.width * 0.66, y: size.height * 0.88)
                    var track = Path()
                    track.move(to: start)
                    track.addCurve(to: end, control1: c1, control2: c2)
                    context.stroke(track, with: .color(tint.opacity(0.28)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
                    guard active else { return }
                    let count = 7
                    for index in 0..<count {
                        let phase = (t * 0.55 + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
                        let point = Self.bezier(phase, start, c1, c2, end)
                        let strength = sin(phase * .pi)
                        let radius = 2.2 + 2.3 * strength
                        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.3 + 0.65 * strength)))
                    }
                }
            }
            .frame(minWidth: 70, maxWidth: 160)
            IconBadge(systemImage: toSymbol, tint: tint, size: 40)
                .symbolEffect(.bounce, value: reduceMotion ? false : active)
        }
        .frame(height: 48)
        .accessibilityHidden(true)
    }

    private static func bezier(_ t: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
}

// MARK: - Auswahlkästchen & Zustände

struct MaintCheckbox: View {
    let isOn: Bool
    var isEnabled: Bool = true
    var tint: Color = Theme.accent

    var body: some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isOn && isEnabled ? tint : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
            .opacity(isEnabled ? 1 : 0.35)
            .accessibilityHidden(true)
    }
}

struct MaintApplyStateIcon: View {
    let state: MaintApplyItem.State

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var symbol: String {
        switch state {
        case .pending: return "circle.dotted"
        case .writing: return "arrow.up.circle"
        case .written: return "checkmark.circle"
        case .verified: return "checkmark.circle.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .pending, .skipped: return Theme.offline
        case .writing: return Theme.accent
        case .written: return Theme.teal
        case .verified: return Theme.ready
        case .mismatch: return Theme.warning
        case .failed: return Theme.error
        }
    }

    var body: some View {
        ZStack {
            if state == .writing {
                ProgressRing(progress: nil, size: 16, lineWidth: 2.2)
                    .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: reduceMotion ? false : (state == .verified))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 20)
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: state)
    }
}

/// Zwei Werte mit Pfeil („alt → neu“), Netzwerkwerte und lange Werte werden gekürzt.
struct MaintValueTransition: View {
    let from: String?
    let to: String
    let highlight: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: display(from))
                .font(Theme.Typography.codeSmall)
                .strikethrough(highlight && from != nil, color: Theme.error.opacity(0.6))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(highlight ? Theme.accent : Color.secondary)
            Text(verbatim: display(to))
                .font(Theme.Typography.codeSmall.weight(highlight ? .semibold : .regular))
                .foregroundStyle(highlight ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func display(_ value: String?) -> String {
        guard let value else { return "–" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\u{201E}\u{201C}" : trimmed
    }
}

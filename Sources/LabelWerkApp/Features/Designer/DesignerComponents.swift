import SwiftUI
import LabelWerkKit

// MARK: - Druckknopf mit Sendeanimation

/// Primärknopf, der seinen Zustand animiert: Senden (Kreisel) → Erfolg (Haken, Konfetti) bzw.
/// Fehler (Ausrufezeichen, Schütteln).
struct DesignerSendButton: View {
    let title: String
    let systemImage: String
    let phase: DesignerSendPhase
    var fullWidth: Bool = false
    let reduceMotion: Bool
    let action: () -> Void

    @State private var successCount = 0
    @State private var shakes: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, systemImage: String, phase: DesignerSendPhase, fullWidth: Bool = false,
         reduceMotion: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.phase = phase
        self.fullWidth = fullWidth
        self.reduceMotion = reduceMotion
        self.action = action
    }

    private var label: String {
        switch phase {
        case .idle: return title
        case .sending: return tr("Wird gesendet …")
        case .success: return tr("Gesendet")
        case .failure: return tr("Fehlgeschlagen")
        }
    }

    private var symbol: String {
        switch phase {
        case .idle, .sending: return systemImage
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var fill: LinearGradient {
        switch phase {
        case .success:
            return LinearGradient(colors: [Theme.ready, Theme.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .failure:
            return LinearGradient(colors: [Theme.error, Theme.error.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        case .idle, .sending:
            return Theme.brandGradient
        }
    }

    private var glow: Color {
        switch phase {
        case .success: return Theme.ready
        case .failure: return Theme.error
        case .idle, .sending: return Theme.violet
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if phase == .sending {
                        DesignerSpinner()
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: symbol)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: reduceMotion ? 0 : successCount)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 18, height: 18)
                Text(label)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(minWidth: 132)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                shape
                    .fill(fill)
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                       startPoint: .top, endPoint: .center)))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
                    .shadow(color: glow.opacity(isEnabled ? 0.4 : 0), radius: 9, y: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(DesignerPressStyle(reduceMotion: reduceMotion))
        .opacity(isEnabled ? 1 : 0.45)
        .modifier(DesignerShakeEffect(travel: shakes))
        .overlay {
            CelebrationBurst(trigger: reduceMotion ? 0 : successCount,
                             colors: [Theme.ready, Theme.teal, Theme.violet, Theme.magenta])
                .frame(width: 240, height: 170)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : Motion.spring, value: phase)
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .success:
                successCount += 1
            case .failure:
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.5)) { shakes += 1 }
            case .idle, .sending:
                break
            }
        }
        .accessibilityLabel(label)
    }
}

/// Drückeffekt ohne eigene Gestaltung (bei „Bewegung reduzieren“ nur Abdunkeln).
struct DesignerPressStyle: ButtonStyle {
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Horizontales Schütteln (eine volle Bewegung je Erhöhung von `travel` um 1).
struct DesignerShakeEffect: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(travel * .pi * 6), y: 0))
    }
}

/// Kleiner Kreisel (läuft nur, solange er sichtbar ist).
struct DesignerSpinner: View {
    var color: Color = .white
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

// MARK: - Auswahlleiste

/// Kompakte Segmentauswahl mit gleitender Kapsel (`matchedGeometryEffect`).
struct DesignerChoiceBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let reduceMotion: Bool
    let title: (Item) -> String
    let systemImage: ((Item) -> String)?

    @Namespace private var namespace
    @State private var hovered: Item?

    init(items: [Item], selection: Binding<Item>, reduceMotion: Bool = false,
         title: @escaping (Item) -> String, systemImage: ((Item) -> String)? = nil) {
        self.items = items
        self._selection = selection
        self.reduceMotion = reduceMotion
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(3)
        .background(Theme.subtleFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { selection = item }
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage(item))
                        .font(.system(size: 10.5, weight: .semibold))
                        .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                }
                Text(title(item))
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(hovered == item ? 0.95 : 0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 5, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovered == item {
                    Capsule().fill(Theme.subtleFill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = item
            } else if hovered == item {
                hovered = nil
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Kachel für eine Option (Symbol + Titel) mit gleitender Auswahlmarkierung.
struct DesignerOptionTile: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Theme.accent : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                ZStack {
                    shape.fill(hovering ? Theme.subtleFill.opacity(1.8) : Theme.subtleFill)
                    if isSelected {
                        shape
                            .fill(Theme.accent.opacity(0.12))
                            .overlay(shape.strokeBorder(Theme.brandGradient, lineWidth: 1.6))
                            .matchedGeometryEffect(id: "tile", in: namespace)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(DesignerPressStyle(reduceMotion: reduceMotion))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Schieberegler mit Titel, animiertem Wert und Zurücksetzen-Knopf.
struct DesignerValueSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var step: Double?
    let reduceMotion: Bool
    let format: (Double) -> String

    init(title: String, systemImage: String, value: Binding<Double>, range: ClosedRange<Double>,
         neutral: Double = 0, step: Double? = nil, reduceMotion: Bool, format: @escaping (Double) -> String) {
        self.title = title
        self.systemImage = systemImage
        self._value = value
        self.range = range
        self.neutral = neutral
        self.step = step
        self.reduceMotion = reduceMotion
        self.format = format
    }

    private var animation: Animation? { Motion.animation(Motion.snappy, reduceMotion: reduceMotion) }

    private var isNeutral: Bool { abs(value - neutral) < 0.0005 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 4)
                Text(format(value))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: value))
                    .animation(animation, value: value)
                if !isNeutral {
                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { value = neutral }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help(tr("Zurücksetzen"))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .animation(animation, value: isNeutral)
    }
}

// MARK: - Ablagefläche

/// Große Ablagefläche mit gestricheltem Rand, der beim Darüberziehen „marschiert“.
struct DesignerDropZone: View {
    let isTargeted: Bool
    let isLoading: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var appeared = false

    private var active: Bool { isTargeted || hovering }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cornerLarge, style: .continuous)
        ZStack {
            shape.fill(isTargeted ? Theme.violet.opacity(0.09) : Theme.subtleFill)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { timeline in
                let phase = active && !reduceMotion
                    ? CGFloat(timeline.date.timeIntervalSinceReferenceDate * 26).truncatingRemainder(dividingBy: 24)
                    : 0
                shape
                    .strokeBorder(style: StrokeStyle(lineWidth: isTargeted ? 2.6 : 1.8, lineCap: .round,
                                                     dash: [14, 10], dashPhase: -phase))
                    .foregroundStyle(active ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.45)))
            }
            content
        }
        .scaleEffect(isTargeted && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : Motion.spring, value: isTargeted)
        .onHover { hovering = $0 }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.75).delay(0.05)) { appeared = true }
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            ZStack {
                if isLoading {
                    ProgressRing(progress: nil, size: 64, lineWidth: 5)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    IconBadge(systemImage: isTargeted ? "arrow.down.doc.fill" : "photo.badge.plus",
                              tint: Theme.violet, size: 64)
                        .symbolEffect(.bounce, value: reduceMotion ? false : isTargeted)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 70)
            .scaleEffect(appeared ? 1 : 0.6)
            VStack(spacing: 6) {
                Text(isLoading ? tr("Datei wird geladen …") : (isTargeted ? tr("Loslassen zum Laden") : tr("Bild oder PDF hierher ziehen")))
                    .font(Theme.Typography.title)
                    .contentTransition(.opacity)
                Text(tr("Wird exakt auf das Etikett eingepasst, in Druckerauflösung gerastert und kann gedruckt, als ZPL übernommen oder im Drucker gespeichert werden."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button(action: action) {
                Label(tr("Datei auswählen …"), systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.labelWerkPrimary)
            .disabled(isLoading)
            HStack(spacing: 6) {
                ForEach(["PNG", "JPEG", "TIFF", "HEIC", "GIF", "BMP", "PDF"], id: \.self) { format in
                    Text(verbatim: format)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.subtleFill, in: Capsule())
                }
            }
        }
        .padding(32)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(reduceMotion ? nil : Motion.spring, value: isLoading)
    }
}

// MARK: - Lineal, Raster, Hervorhebung

/// Millimeter-Lineal neben der Vorschau, optional mit hervorgehobenem Bereich.
struct DesignerRuler: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let lengthMM: Double
    var highlight: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            let isHorizontal = axis == .horizontal
            let length = isHorizontal ? size.width : size.height
            let thickness = isHorizontal ? size.height : size.width
            guard lengthMM > 0, length > 0 else { return }
            let perMM = length / CGFloat(lengthMM)

            if let highlight {
                let start = CGFloat(highlight.lowerBound) * perMM
                let extent = max(2, CGFloat(highlight.upperBound - highlight.lowerBound) * perMM)
                let band = isHorizontal
                    ? CGRect(x: start, y: 0, width: extent, height: thickness)
                    : CGRect(x: 0, y: start, width: thickness, height: extent)
                context.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Theme.accent.opacity(0.22)))
            }

            let step: Int = perMM >= 4 ? 1 : (perMM >= 0.9 ? 5 : 10)
            let labelEvery: Int = perMM * 10 >= 22 ? 10 : (perMM * 10 >= 9 ? 20 : 50)
            var ticks = Path()
            var millimeter = 0
            while Double(millimeter) <= lengthMM {
                let position = CGFloat(millimeter) * perMM
                let tick: CGFloat
                if millimeter % 10 == 0 {
                    tick = thickness * 0.55
                } else if millimeter % 5 == 0 {
                    tick = thickness * 0.38
                } else {
                    tick = thickness * 0.2
                }
                if isHorizontal {
                    ticks.move(to: CGPoint(x: position, y: thickness))
                    ticks.addLine(to: CGPoint(x: position, y: thickness - tick))
                } else {
                    ticks.move(to: CGPoint(x: thickness, y: position))
                    ticks.addLine(to: CGPoint(x: thickness - tick, y: position))
                }
                if millimeter > 0 && millimeter % labelEvery == 0 {
                    let text = Text(verbatim: String(millimeter))
                        .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                    if isHorizontal {
                        context.draw(text, at: CGPoint(x: position + 2, y: 0), anchor: .topLeading)
                    } else {
                        context.draw(text, at: CGPoint(x: 1, y: position + 1), anchor: .topLeading)
                    }
                }
                millimeter += step
            }
            context.stroke(ticks, with: .color(Color.secondary.opacity(0.65)), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 5-mm-Raster über der pixelgenauen Vorschau.
struct DesignerGridOverlay: View {
    let widthDots: Int
    let heightDots: Int
    let dotsPerMM: Int

    var body: some View {
        Canvas { context, size in
            guard widthDots > 0, heightDots > 0 else { return }
            let step = size.width / CGFloat(widthDots) * CGFloat(max(1, dotsPerMM) * 5)
            guard step > 3 else { return }
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Theme.accent.opacity(0.2)), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
}

/// Markierung eines Elements über der pixelgenauen Vorschau.
struct DesignerHighlightOverlay: View {
    let rect: CGRect?
    let labelSize: CGSize

    var body: some View {
        GeometryReader { geo in
            if let rect, labelSize.width > 0, labelSize.height > 0 {
                let sx = geo.size.width / labelSize.width
                let sy = geo.size.height / labelSize.height
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.accent.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    )
                    .frame(width: rect.width * sx + 8, height: rect.height * sy + 8)
                    .position(x: rect.midX * sx, y: rect.midY * sy)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Kleine Statusangabe mit Symbol.
struct DesignerStat: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Kurzer, selbst verschwindender Hinweis im Editor (z. B. „Eingefügt: Code 128“).
struct DesignerNotice: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var systemImage: String
}

struct DesignerNoticePill: View {
    let notice: DesignerNotice
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Theme.brandGradient)
                .symbolEffect(.bounce, value: reduceMotion ? nil : notice.id)
            Text(notice.text)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
    }
}

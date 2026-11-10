import SwiftUI
import LabelWerkKit

// MARK: - Eingaben

/// Alles, was die Druckvorschau zeigt – abgeleitet aus dem Entwurf.
struct PrintPrefsPreviewInput: Equatable {
    var widthMM: Double
    var heightMM: Double
    var gapMM: Double
    var tracking: MediaTracking?
    var rotation: PrintRotation
    var mirror: Bool
    var negative: Bool
    var printMode: PrintMode?
    var markOffsetMM: Double
    var stopAtLast: Bool
    var stopOffsetMM: Double
    var tearOffMM: Double
    var darkness: Int?

    init(draft: PrintPrefsDraft, resolution: Resolution) {
        let s = draft.settings
        widthMM = max(draft.widthMM, 1)
        heightMM = max(draft.heightMM, 1)
        gapMM = draft.gapMM
        tracking = s.tracking
        rotation = s.effectiveRotation
        mirror = s.mirror
        negative = s.negative
        printMode = s.printMode
        markOffsetMM = resolution.mm(fromDots: s.markOffset ?? 0)
        stopAtLast = s.stopAtLastElement && s.tracking == .continuous
        stopOffsetMM = resolution.mm(fromDots: s.stopOffset)
        tearOffMM = resolution.mm(fromDots: s.tearOffAdjust ?? 0)
        darkness = s.darkness
    }

    var isLinerless: Bool { printMode?.isLinerless == true }
    var isContinuous: Bool { tracking == .continuous || isLinerless }
    var hasLiner: Bool { !isContinuous }
}

// MARK: - Geometrie

/// Maße der Zeichnung (Drucker oben, darunter der Etikettenstreifen mit zwei Etiketten).
private struct PrintPrefsPreviewLayout {
    let size: CGSize
    let input: PrintPrefsPreviewInput

    var printerRect: CGRect {
        CGRect(x: size.width * 0.1, y: size.height * 0.03, width: size.width * 0.8, height: size.height * 0.3)
    }
    var slotY: CGFloat { printerRect.maxY - printerRect.height * 0.16 }
    /// Platz unten für die Aufwickelrolle.
    var bottomReserve: CGFloat {
        input.printMode == .rewind || input.printMode == .linerlessRewind ? size.height * 0.1 : size.height * 0.03
    }
    var lead: CGFloat { size.height * 0.025 }
    var ratio: CGFloat { CGFloat(input.heightMM / input.widthMM).clamped(to: 0.18...3.2) }
    var gapRatio: CGFloat {
        guard input.hasLiner else { return 0 }
        return CGFloat(max(input.gapMM, 1.5) / input.widthMM).clamped(to: 0.03...0.18)
    }

    var labelWidth: CGFloat {
        let available = size.height - slotY - lead - bottomReserve
        let maxWidth = printerRect.width * 0.66
        // Zwei Etiketten und zwei Lücken müssen unter den Schlitz passen.
        let fitting = available / (2 * ratio + 2 * gapRatio)
        return max(24, min(maxWidth, fitting))
    }
    var labelHeight: CGFloat { labelWidth * ratio }
    var gap: CGFloat { labelWidth * gapRatio }
    var scale: CGFloat { labelWidth / CGFloat(input.widthMM) }
    var linerInset: CGFloat { input.hasLiner ? max(6, labelWidth * 0.07) : 0 }
    var stripX: CGFloat { (size.width - labelWidth) / 2 }
    var firstTop: CGFloat { slotY + lead }
    /// Länge des ersten Etiketts – bei „Bei letztem Element stoppen“ nur bis zum Inhalt plus Stoppversatz.
    var firstHeight: CGFloat {
        guard input.stopAtLast else { return labelHeight }
        let content = labelHeight * 0.62
        return min(labelHeight, max(labelHeight * 0.3, content + CGFloat(input.stopOffsetMM) * scale))
    }
    var secondTop: CGFloat { firstTop + firstHeight + gap }
    var stripBottom: CGFloat { size.height - bottomReserve * 0.4 }
    /// Trennstelle zwischen den Etiketten (Schnitt, Abriss).
    var boundaryY: CGFloat { firstTop + firstHeight + gap / 2 }
    var markHeight: CGFloat { max(3, 4 * scale) }
}

// MARK: - Vorschau

/// „Druckvorschau“ wie im Windows-Treiber: ein Drucker, aus dem zwei Etiketten mit „123“ laufen –
/// Seitenverhältnis, Medientyp (Lücke, Endlos, schwarze Markierung, Seitenkerben), Drehung,
/// Spiegeln, Invers, Bedienermodus sowie Markierungs-, Stopp- und Abreißversatz werden live und
/// mit Federanimationen dargestellt.
struct PrintPrefsPrinterPreview: View {
    let input: PrintPrefsPreviewInput
    let state: PrinterState
    let accent: Color
    let printTrigger: Int
    let reduceMotion: Bool

    /// Angezeigter Drehwinkel (läuft fortlaufend weiter, damit stets der kürzeste Weg animiert wird).
    @State private var angle: Double
    @Environment(\.colorScheme) private var colorScheme

    init(input: PrintPrefsPreviewInput, state: PrinterState, accent: Color, printTrigger: Int, reduceMotion: Bool) {
        self.input = input
        self.state = state
        self.accent = accent
        self.printTrigger = printTrigger
        self.reduceMotion = reduceMotion
        self._angle = State(initialValue: Double(input.rotation.degrees))
    }

    private var spring: Animation? { reduceMotion ? nil : Motion.spring }

    var body: some View {
        GeometryReader { geo in
            let layout = PrintPrefsPreviewLayout(size: geo.size, input: input)
            ZStack(alignment: .topLeading) {
                if input.printMode == .rewind || input.printMode == .linerlessRewind {
                    rewinder(layout)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                // Testseite gedruckt → der Streifen fährt um ein Etikett heraus.
                let feedStart = reduceMotion ? 0.0 : -Double(layout.labelHeight + layout.gap)
                strip(layout)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .keyframeAnimator(initialValue: 0.0, trigger: printTrigger) { content, feed in
                        content.offset(y: CGFloat(feed))
                    } keyframes: { _ in
                        LinearKeyframe(feedStart, duration: 0.01)
                        SpringKeyframe(0.0, duration: reduceMotion ? 0.01 : 0.9, spring: .smooth)
                    }
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: geo.size.width, height: max(0, geo.size.height - layout.slotY))
                            .offset(y: layout.slotY)
                    }
                modeOverlay(layout)
                printerBody(layout)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(0.8, contentMode: .fit)
        .animation(spring, value: input)
        .onChange(of: input.rotation) { old, new in
            // Kürzester Weg: 270° → 0° dreht eine Vierteldrehung weiter statt drei zurück.
            let delta = Double(((new.degrees - old.degrees) % 360 + 540) % 360 - 180)
            withAnimation(reduceMotion ? nil : Motion.bouncy) { angle += delta }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Druckvorschau"))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [tr(input.rotation.displayName)]
        if let tracking = input.tracking { parts.append(tr(tracking.displayName)) }
        if input.mirror { parts.append(tr("Spiegeln")) }
        if input.negative { parts.append(tr("Invers")) }
        if let mode = input.printMode { parts.append(tr(mode.displayName)) }
        return parts.joined(separator: ", ")
    }

    // MARK: Drucker

    private func printerBody(_ layout: PrintPrefsPreviewLayout) -> some View {
        let r = layout.printerRect
        let dark = colorScheme == .dark
        let shell = UnevenRoundedRectangle(topLeadingRadius: r.width * 0.22, bottomLeadingRadius: r.width * 0.05,
                                           bottomTrailingRadius: r.width * 0.05, topTrailingRadius: r.width * 0.22,
                                           style: .continuous)
        return ZStack(alignment: .topLeading) {
            shell
                .fill(LinearGradient(colors: dark ? [Color(white: 0.32), Color(white: 0.13)]
                                                  : [Color(white: 0.40), Color(white: 0.17)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    shell.fill(LinearGradient(colors: [Color.white.opacity(0.24), .clear],
                                              startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)))
                }
                .overlay { shell.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .frame(width: r.width, height: r.height)
                .shadow(color: .black.opacity(0.28), radius: r.width * 0.04, y: r.width * 0.02)
                .offset(x: r.minX, y: r.minY)

            // Deckelfuge mit Akzentlinie
            Capsule()
                .fill(LinearGradient(colors: [accent.opacity(0), accent, accent.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: r.width * 0.84, height: max(1.5, r.height * 0.025))
                .shadow(color: accent.opacity(0.7), radius: 4)
                .offset(x: r.minX + r.width * 0.08, y: r.minY + r.height * 0.42)

            // Frontblende
            RoundedRectangle(cornerRadius: r.width * 0.04, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: dark ? 0.24 : 0.3), Color(white: dark ? 0.1 : 0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: r.width * 0.92, height: r.height * 0.34)
                .offset(x: r.minX + r.width * 0.04, y: r.minY + r.height * 0.56)

            // Bedientaste und Status-LED
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.48), Color(white: 0.26)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .frame(width: r.width * 0.08, height: r.width * 0.08)
                .offset(x: r.minX + r.width * 0.08, y: r.minY + r.height * 0.6)
            Circle()
                .fill(state.color)
                .shadow(color: state.color.opacity(0.9), radius: 5)
                .frame(width: r.width * 0.045, height: r.width * 0.045)
                .offset(x: r.minX + r.width * 0.86, y: r.minY + r.height * 0.62)

            // Ausgabeschlitz
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .frame(width: layout.labelWidth + layout.linerInset * 2 + 14, height: max(3, r.height * 0.045))
                .offset(x: layout.stripX - layout.linerInset - 7, y: layout.slotY - max(3, r.height * 0.045) / 2)
        }
    }

    // MARK: Etikettenstreifen

    private func strip(_ layout: PrintPrefsPreviewLayout) -> some View {
        let linerWidth = layout.labelWidth + layout.linerInset * 2
        let linerTop = layout.slotY - 6
        return ZStack(alignment: .topLeading) {
            // Trägermaterial (bei Endlos- und Linerless-Material das Papier selbst)
            PrintPrefsLinerShape(firstTop: layout.firstTop - linerTop, firstHeight: layout.firstHeight,
                                 labelHeight: layout.labelHeight, gap: layout.gap,
                                 notchRadius: input.tracking == .notch ? max(2.5, layout.gap * 0.55) : 0)
                .fill(input.hasLiner ? linerColor : paperColor, style: FillStyle(eoFill: true))
                .overlay {
                    PrintPrefsLinerShape(firstTop: layout.firstTop - linerTop, firstHeight: layout.firstHeight,
                                         labelHeight: layout.labelHeight, gap: layout.gap,
                                         notchRadius: input.tracking == .notch ? max(2.5, layout.gap * 0.55) : 0)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .frame(width: linerWidth, height: max(1, layout.stripBottom - linerTop))
                .offset(x: layout.stripX - layout.linerInset, y: linerTop)

            // Schwarze Markierungen auf der Rückseite (am Rand sichtbar)
            if input.tracking == .blackMark {
                ForEach(0..<3, id: \.self) { index in
                    let top = index == 0 ? layout.firstTop : layout.secondTop + CGFloat(index - 1) * (layout.labelHeight + layout.gap)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.labelInk)
                        .frame(width: max(3, layout.linerInset * 0.6), height: layout.markHeight)
                        .offset(x: layout.stripX - layout.linerInset + 1.5,
                                y: top - layout.gap / 2 - layout.markHeight / 2 + CGFloat(input.markOffsetMM) * layout.scale)
                }
                .transition(.opacity)
            }

            // Zwei Etiketten mit „123“
            label(layout, height: layout.firstHeight)
                .offset(x: layout.stripX, y: layout.firstTop)
            label(layout, height: layout.labelHeight)
                .rotationEffect(.degrees(isPeeling ? -7 : 0), anchor: .topTrailing)
                .offset(x: layout.stripX + (isPeeling ? layout.labelWidth * 0.08 : 0),
                        y: layout.secondTop + (isPeeling ? layout.gap * 0.6 : 0))
                .shadow(color: .black.opacity(isPeeling ? 0.25 : 0), radius: isPeeling ? 8 : 0, y: isPeeling ? 5 : 0)

            // Endlosmaterial: Seitengrenzen als Perforation
            if input.isContinuous {
                PrintPrefsDashLine()
                    .stroke(Theme.labelInk.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: layout.labelWidth, height: 2)
                    .offset(x: layout.stripX, y: layout.firstTop + layout.firstHeight - 1)
                    .transition(.opacity)
            }

            // Stoppversatz
            if input.stopAtLast {
                HStack(spacing: 3) {
                    PrintPrefsDashLine()
                        .stroke(Theme.error, style: StrokeStyle(lineWidth: 1.4, dash: [4, 2]))
                        .frame(height: 2)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.error)
                }
                .frame(width: layout.labelWidth + 16, height: 8)
                .offset(x: layout.stripX - 4, y: layout.firstTop + layout.firstHeight - 4)
                .transition(.opacity)
            }
        }
    }

    private var isPeeling: Bool {
        input.printMode == .peelOff || input.printMode == .linerlessPeel || input.printMode == .applicator
    }

    private var linerColor: Color {
        Color(red: 0.93, green: 0.90, blue: 0.83).opacity(colorScheme == .dark ? 0.85 : 1)
    }

    private var paperColor: Color { Theme.labelPaper }

    /// Tintendeckung nach „Temperatur“.
    private var inkOpacity: Double {
        guard let darkness = input.darkness else { return 0.92 }
        return 0.35 + 0.65 * min(1, Double(darkness) / 22)
    }

    private func label(_ layout: PrintPrefsPreviewLayout, height: CGFloat) -> some View {
        let width = layout.labelWidth
        let corner: CGFloat = input.isContinuous ? 0 : min(width, height) * 0.06
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let quarter = input.rotation.isQuarterTurn
        // „123“ ist etwa 1,8-mal so breit wie hoch; bei 90°/270° tauschen Breite und Höhe.
        let along = quarter ? height : width
        let across = quarter ? width : height
        let fontSize = max(6, min(along * 0.78 / 1.8, across * 0.62))
        let fill: Color = input.negative ? Theme.labelInk : (input.isContinuous ? Color.clear : paperColor)
        let ink: Color = input.negative ? Theme.labelPaper : Theme.labelInk.opacity(inkOpacity)
        return ZStack {
            shape
                .fill(fill)
                .shadow(color: .black.opacity(input.isContinuous ? 0 : 0.12), radius: 2, y: 1)
            Text(verbatim: "123")
                .font(.system(size: 100, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink)
                .fixedSize()
                .scaleEffect(fontSize / 100)
                .rotationEffect(.degrees(angle))
                .scaleEffect(x: input.mirror ? -1 : 1, y: 1)
                .frame(width: width, height: height)
                .clipped()
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.black.opacity(input.isContinuous ? 0 : 0.07), lineWidth: 0.6) }
    }

    // MARK: Bedienermodus

    @ViewBuilder
    private func modeOverlay(_ layout: PrintPrefsPreviewLayout) -> some View {
        let edgeX = layout.stripX - layout.linerInset - 10
        let edgeWidth = layout.labelWidth + layout.linerInset * 2 + 20
        switch input.printMode {
        case .some(.cutter), .some(.delayedCut), .some(.kiosk), .some(.linerlessCut), .some(.linerlessDelayedCut):
            let delayed = input.printMode == .delayedCut || input.printMode == .linerlessDelayedCut
            HStack(spacing: 3) {
                PrintPrefsDashLine()
                    .stroke(Theme.magenta, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(height: 2)
                Image(systemName: delayed ? "timer" : "scissors")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.magenta)
            }
            .frame(width: edgeWidth + 14, height: 12)
            .offset(x: edgeX, y: layout.boundaryY - 6)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        case .some(.tearOff), .some(.linerlessTear):
            HStack(spacing: 3) {
                PrintPrefsZigzagLine()
                    .stroke(Theme.teal, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    .frame(height: 5)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.teal)
            }
            .frame(width: edgeWidth + 14, height: 12)
            .offset(x: edgeX, y: layout.boundaryY - 6 + CGFloat(input.tearOffMM) * layout.scale)
            .transition(.opacity)
        case .some(.peelOff), .some(.linerlessPeel), .some(.applicator):
            Image(systemName: input.printMode == .applicator ? "hand.point.up.left.fill" : "arrow.turn.right.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.violet)
                .shadow(color: .white.opacity(0.6), radius: 1)
                .offset(x: layout.stripX + layout.labelWidth + layout.linerInset + 6, y: layout.secondTop)
                .transition(.opacity.combined(with: .scale))
        case .some(.rewind), .some(.linerlessRewind), .none:
            EmptyView()
        }
    }

    private func rewinder(_ layout: PrintPrefsPreviewLayout) -> some View {
        let diameter = layout.bottomReserve * 1.25
        return ZStack {
            Circle()
                .fill(input.hasLiner ? linerColor : paperColor)
                .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
            Circle()
                .fill(Color(white: 0.3))
                .scaleEffect(0.32)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: diameter * 0.32, weight: .bold))
                .foregroundStyle(Theme.violet)
                .offset(x: diameter * 0.75)
        }
        .frame(width: diameter, height: diameter)
        .offset(x: layout.size.width / 2 - diameter / 2, y: layout.size.height - diameter - 2)
    }
}

// MARK: - Formen

/// Trägermaterial mit optionalen Seitenkerben (Halbkreise an beiden Rändern auf Höhe der Lücken).
struct PrintPrefsLinerShape: Shape {
    var firstTop: CGFloat
    var firstHeight: CGFloat
    var labelHeight: CGFloat
    var gap: CGFloat
    var notchRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(AnimatablePair(firstTop, firstHeight),
                           AnimatablePair(labelHeight, AnimatablePair(gap, notchRadius)))
        }
        set {
            firstTop = newValue.first.first
            firstHeight = newValue.first.second
            labelHeight = newValue.second.first
            gap = newValue.second.second.first
            notchRadius = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        guard notchRadius > 0.5 else { return path }
        // Kerben in der Mitte jeder Lücke (vor dem ersten, zwischen den und nach den Etiketten).
        var centers: [CGFloat] = [firstTop - gap / 2, firstTop + firstHeight + gap / 2]
        var next = firstTop + firstHeight + gap + labelHeight + gap / 2
        while next < rect.maxY + notchRadius {
            centers.append(next)
            next += labelHeight + gap
        }
        for y in centers where y > rect.minY + notchRadius && y < rect.maxY - notchRadius {
            // Halbkreise innerhalb des Rechtecks – mit gerader/ungerader Füllung entstehen Löcher.
            var left = Path()
            left.addArc(center: CGPoint(x: rect.minX, y: y), radius: notchRadius,
                        startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            left.closeSubpath()
            var right = Path()
            right.addArc(center: CGPoint(x: rect.maxX, y: y), radius: notchRadius,
                         startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            right.closeSubpath()
            path.addPath(left)
            path.addPath(right)
        }
        return path
    }
}

/// Waagerechte Linie in der Mitte des Rahmens.
struct PrintPrefsDashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Zickzacklinie (Abreißkante).
struct PrintPrefsZigzagLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 4
        var x = rect.minX
        var up = true
        path.move(to: CGPoint(x: x, y: rect.midY))
        while x < rect.maxX {
            x = min(rect.maxX, x + step)
            path.addLine(to: CGPoint(x: x, y: up ? rect.minY : rect.maxY))
            up.toggle()
        }
        return path
    }
}

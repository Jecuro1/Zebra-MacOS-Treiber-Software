import SwiftUI
import LabelWerkKit

// MARK: - Beispieletikett

/// Generisches Beispieletikett (Rahmen, Titel, Textzeilen, echter QR- und Code-128-Code), skaliert
/// auf jede Etikettengröße. `inverted` zeigt den Negativdruck.
struct PrintPrefsSampleLabel: View {
    var inverted: Bool = false
    var drawsPaper: Bool = true

    init(inverted: Bool = false, drawsPaper: Bool = true) {
        self.inverted = inverted
        self.drawsPaper = drawsPaper
    }

    var body: some View {
        Canvas { context, size in
            let ink = inverted ? Theme.labelPaper : Theme.labelInk
            let paper = inverted ? Theme.labelInk : Theme.labelPaper
            if drawsPaper || inverted {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
            }
            let w = size.width
            let h = size.height
            guard w > 6, h > 6 else { return }
            let unit = min(w, h) / 14
            let frame = CGRect(x: unit, y: unit, width: w - unit * 2, height: h - unit * 2)
            context.stroke(Path(roundedRect: frame, cornerRadius: unit * 0.7), with: .color(ink),
                           lineWidth: max(0.8, unit * 0.16))
            let inner = frame.insetBy(dx: unit, dy: unit)
            guard inner.width > 2, inner.height > 2 else { return }

            // Barcode unten
            let barHeight = inner.height * 0.26
            let barRect = CGRect(x: inner.minX, y: inner.maxY - barHeight, width: inner.width, height: barHeight)
            context.fill(PrintPrefsSampleCodes.barcodePath(in: barRect), with: .color(ink))

            // QR-Code rechts oben
            let upperHeight = max(1, inner.height - barHeight - unit * 0.6)
            let qrSide = min(inner.width * 0.3, upperHeight * 0.85)
            let qrRect = CGRect(x: inner.maxX - qrSide, y: inner.minY, width: qrSide, height: qrSide)
            context.fill(PrintPrefsSampleCodes.qrPath(in: qrRect), with: .color(ink))

            // Titel
            let textWidth = max(1, inner.width - qrSide - unit)
            let titleSize = max(4, min(upperHeight * 0.26, textWidth * 0.17))
            let title = Text(verbatim: "LabelWerk")
                .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
            context.draw(title, at: CGPoint(x: inner.minX, y: inner.minY + titleSize * 0.6), anchor: .leading)

            // Textzeilen
            let lineHeight = max(1, titleSize * 0.28)
            var y = inner.minY + titleSize * 1.45
            let fractions: [CGFloat] = [0.92, 0.7, 0.82, 0.5]
            for fraction in fractions {
                if y + lineHeight > barRect.minY - unit * 0.5 { break }
                let rect = CGRect(x: inner.minX, y: y, width: textWidth * fraction, height: lineHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: lineHeight / 2), with: .color(ink.opacity(0.78)))
                y += lineHeight * 2.1
            }
        }
        .accessibilityHidden(true)
    }
}

/// Waagerechte Linie (für gestrichelte Hilfslinien).
struct PrintPrefsHorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Pfeil von der Mitte um (`dx`, `dy`) – animierbar.
struct PrintPrefsOffsetArrow: Shape {
    var dx: CGFloat
    var dy: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(dx, dy) }
        set {
            dx = newValue.first
            dy = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 2 else { return path }
        let start = CGPoint(x: rect.midX, y: rect.midY)
        let end = CGPoint(x: start.x + dx, y: start.y + dy)
        path.addEllipse(in: CGRect(x: start.x - 2.5, y: start.y - 2.5, width: 5, height: 5))
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(dy, dx)
        let head = min(9, length * 0.45)
        let spread = CGFloat.pi * 0.8
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + cos(angle + spread) * head, y: end.y + sin(angle + spread) * head))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + cos(angle - spread) * head, y: end.y + sin(angle - spread) * head))
        return path
    }
}

// MARK: - Schwärzungs-Simulation

/// Simuliert, wie Text und Barcode bei der gewählten Schwärzung (und Geschwindigkeit) aussehen:
/// zu hell → blass mit Fehlstellen, zu dunkel → verlaufene, verbreiterte Balken.
struct PrintPrefsDarknessSwatch: View {
    let darkness: Int?
    let speed: Int?
    let reduceMotion: Bool

    init(darkness: Int?, speed: Int?, reduceMotion: Bool) {
        self.darkness = darkness
        self.speed = speed
        self.reduceMotion = reduceMotion
    }

    /// Wirksame Schwärzung: höhere Geschwindigkeit bedeutet weniger Energie pro Punkt.
    private var level: Double {
        let base = Double(darkness ?? 15)
        let speedPenalty = max(0, Double(speed ?? 4) - 4) * 0.9
        return max(0, min(30, base - speedPenalty))
    }

    private var inkOpacity: Double { 0.16 + 0.84 * min(1, pow(level / 21, 0.85)) }
    private var bleed: CGFloat { CGFloat(max(0, (level - 21) / 9) * 1.8) }
    private var dropout: Double { max(0, (10 - level) / 10) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            swatch
            scale
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Schwärzungsvorschau"))
        .accessibilityValue(darkness.map { String($0) } ?? tr("Druckerwert"))
    }

    private var swatch: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.labelPaper)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "LabelWerk")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                    Spacer(minLength: 4)
                    Text(verbatim: "No. 4711")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Theme.labelInk.opacity(inkOpacity))
                .blur(radius: bleed * 0.45)
                PrintPrefsBarcodeShape(widen: bleed)
                    .fill(Theme.labelInk.opacity(inkOpacity))
                    .blur(radius: bleed * 0.25)
                    .frame(height: 46)
            }
            .padding(14)
            PrintPrefsSpeckleShape(amount: dropout)
                .fill(Theme.labelPaper)
                .padding(10)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
        .overlay(alignment: .topTrailing) {
            if darkness == nil {
                Text(tr("Druckerwert"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.offline, in: Capsule())
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: level)
        .animation(reduceMotion ? nil : Motion.snappy, value: darkness == nil)
    }

    private var scale: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.labelInk.opacity(0.1), Theme.labelInk.opacity(0.9)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Capsule()
                        .fill(Theme.ready.opacity(0.55))
                        .frame(width: width * 12 / 30, height: 3)
                        .offset(x: width * 10 / 30)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: 14, height: 14)
                        .offset(x: width * CGFloat(level / 30) - 7)
                        .opacity(darkness == nil ? 0.45 : 1)
                }
                .frame(width: width, height: 14)
                .animation(reduceMotion ? nil : Motion.spring, value: level)
            }
            .frame(height: 14)
            HStack {
                Text(tr("Hell"))
                Spacer()
                Text(tr("Empfohlen"))
                    .foregroundStyle(Theme.ready)
                Spacer()
                Text(tr("Dunkel"))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Positionsdiagramm

/// Etikett auf Trägerpapier mit Lücke, nächstem Etikett und Abreißkante. Der Druckinhalt verschiebt
/// sich live um `^LT` (oben) und `^LS` (links, positive Werte nach links), die Abreißkante um `~TA`.
struct PrintPrefsPositionDiagram: View {
    let stock: LabelStock
    let resolution: Resolution
    let widthDots: Int
    let heightDots: Int
    let labelTop: Int
    let labelLeft: Int
    let tearOff: Int
    let reduceMotion: Bool

    init(stock: LabelStock, resolution: Resolution, widthDots: Int, heightDots: Int,
         labelTop: Int, labelLeft: Int, tearOff: Int, reduceMotion: Bool) {
        self.stock = stock
        self.resolution = resolution
        self.widthDots = widthDots
        self.heightDots = heightDots
        self.labelTop = labelTop
        self.labelLeft = labelLeft
        self.tearOff = tearOff
        self.reduceMotion = reduceMotion
    }

    private var widthMM: Double { max(stock.widthMM, 1) }
    private var heightMM: Double { max(stock.heightMM, 1) }
    private var gapMM: Double { stock.isContinuous ? 0 : max(stock.gapMM, 1.5) }
    private var sliverMM: Double { min(heightMM * 0.22, 14) }
    private var totalMM: Double { heightMM + gapMM + sliverMM }

    var body: some View {
        VStack(spacing: 12) {
            diagram
                .frame(maxWidth: 240, maxHeight: 300)
                .padding(.horizontal, 12)
            readouts
        }
        .animation(reduceMotion ? nil : Motion.spring, value: labelTop)
        .animation(reduceMotion ? nil : Motion.spring, value: labelLeft)
        .animation(reduceMotion ? nil : Motion.spring, value: tearOff)
    }

    private var diagram: some View {
        GeometryReader { geo in
            let scale = geo.size.width / CGFloat(widthMM)
            let labelHeight = CGFloat(heightMM) * scale
            let gapHeight = CGFloat(gapMM) * scale
            let sliverHeight = CGFloat(sliverMM) * scale
            let tearMM = resolution.mm(fromDots: tearOff)
            let tearCenter = (CGFloat(heightMM) + CGFloat(gapMM) / 2 + CGFloat(tearMM)) * scale
            let tearY = min(max(tearCenter, labelHeight * 0.5), geo.size.height - 2)
            ZStack(alignment: .topLeading) {
                // Trägerpapier
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.subtleFill)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
                    .frame(width: geo.size.width + 16, height: geo.size.height + 8)
                    .offset(x: -8, y: -4)

                // Aktuelles Etikett mit verschobenem Inhalt
                LabelSheet(widthMM: widthMM, heightMM: heightMM) {
                    PrintPrefsShiftedContent(
                        shiftX: -CGFloat(labelLeft) / CGFloat(max(1, widthDots)),
                        shiftY: CGFloat(labelTop) / CGFloat(max(1, heightDots))
                    )
                }
                .frame(width: geo.size.width, height: labelHeight)

                // Nächstes Etikett (bzw. weiterlaufendes Endlosmaterial)
                RoundedRectangle(cornerRadius: stock.isContinuous ? 0 : 5, style: .continuous)
                    .fill(Theme.labelPaper)
                    .mask {
                        LinearGradient(colors: [Color.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    }
                    .frame(width: geo.size.width, height: max(1, sliverHeight))
                    .offset(y: labelHeight + gapHeight)

                // Abreißkante
                HStack(spacing: 4) {
                    PrintPrefsHorizontalLine()
                        .stroke(Theme.magenta, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(height: 3)
                    Image(systemName: "scissors")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.magenta)
                }
                .frame(width: geo.size.width + 26, height: 12)
                .offset(x: -8, y: tearY - 6)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(CGFloat(widthMM / totalMM), contentMode: .fit)
    }

    private var readouts: some View {
        HStack(spacing: 8) {
            readout(symbol: labelTop > 0 ? "arrow.down" : (labelTop < 0 ? "arrow.up" : "arrow.up.and.down"),
                    title: tr("Oben"), dots: labelTop, tint: Theme.violet)
            readout(symbol: labelLeft > 0 ? "arrow.left" : (labelLeft < 0 ? "arrow.right" : "arrow.left.and.right"),
                    title: tr("Links"), dots: labelLeft, tint: Theme.teal)
            readout(symbol: "scissors", title: tr("Abriss"), dots: tearOff, tint: Theme.magenta)
        }
    }

    private func readout(symbol: String, title: String, dots: Int, tint: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5, weight: .semibold))
            Text(tr("%@ mm", PrintPrefsFormat.signed(resolution.mm(fromDots: dots))))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: Double(dots)))
            Text(tr("%@ Punkte", PrintPrefsFormat.signedInt(dots)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText(value: Double(dots)))
        }
        .frame(minWidth: 64)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Druckinhalt innerhalb des Etiketts, verschoben um Bruchteile der Etikettengröße.
private struct PrintPrefsShiftedContent: View {
    let shiftX: CGFloat
    let shiftY: CGFloat

    var body: some View {
        GeometryReader { geo in
            let dx = shiftX * geo.size.width
            let dy = shiftY * geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(2)
                PrintPrefsSampleLabel(drawsPaper: false)
                    .opacity(0.9)
                    .offset(x: dx, y: dy)
                PrintPrefsOffsetArrow(dx: dx, dy: dy)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .shadow(color: Color.white.opacity(0.8), radius: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Spiegeln, Negativ, Drehen

/// Vorschau der Bildtransformationen mit 3D-Drehung (Spiegeln), Drehung (180°) und Wischblende (Negativ).
struct PrintPrefsTransformPreview: View {
    let stock: LabelStock
    let mirror: Bool
    let negative: Bool
    let rotate180: Bool
    let reduceMotion: Bool

    init(stock: LabelStock, mirror: Bool, negative: Bool, rotate180: Bool, reduceMotion: Bool) {
        self.stock = stock
        self.mirror = mirror
        self.negative = negative
        self.rotate180 = rotate180
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        VStack(spacing: 14) {
            LabelSheet(widthMM: max(stock.widthMM, 1), heightMM: max(stock.heightMM, 1)) {
                ZStack {
                    PrintPrefsSampleLabel()
                    PrintPrefsSampleLabel(inverted: true)
                        .mask {
                            Rectangle()
                                .scaleEffect(x: negative ? 1 : 0.001, y: 1, anchor: .leading)
                        }
                }
            }
            .rotation3DEffect(.degrees(mirror ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .rotationEffect(.degrees(rotate180 ? 180 : 0))
            .frame(maxWidth: 230, maxHeight: 210)
            .padding(8)
            .animation(reduceMotion ? nil : Motion.bouncy, value: mirror)
            .animation(reduceMotion ? nil : Motion.bouncy, value: rotate180)
            .animation(reduceMotion ? nil : Motion.gentle, value: negative)

            HStack(spacing: 6) {
                codeChip(mirror ? "^PMY" : "^PMN", active: mirror)
                codeChip(rotate180 ? "^POI" : "^PON", active: rotate180)
                HStack(spacing: 4) {
                    Image(systemName: "circle.righthalf.filled")
                    Text(negative ? tr("Negativ") : tr("Positiv"))
                        .contentTransition(.opacity)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(negative ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(negative ? AnyShapeStyle(Theme.labelInk) : AnyShapeStyle(Theme.subtleFill), in: Capsule())
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: negative)
            .animation(reduceMotion ? nil : Motion.snappy, value: mirror)
            .animation(reduceMotion ? nil : Motion.snappy, value: rotate180)

            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                Text(tr("Druckrichtung: Etikett verlässt den Drucker oben"))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func codeChip(_ code: String, active: Bool) -> some View {
        Text(verbatim: code)
            .font(Theme.Typography.codeSmall)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.subtleFill), in: Capsule())
            .contentTransition(.opacity)
    }
}

// MARK: - Rasterungsvorschau

/// Ergebnis der Hintergrundberechnung (nur wertartige, sendbare Daten).
private struct PrintPrefsDitherOutput: Sendable {
    var source: GrayImage
    var result: MonoBitmap
    var thumbnails: [DitherAlgorithm: MonoBitmap]
}

/// Vorher/Nachher-Vergleich (ziehbarer Teiler) plus Galerie aller Verfahren bei der aktuellen Schwelle.
struct PrintPrefsDitherPreview: View {
    let algorithm: DitherAlgorithm
    let threshold: Int
    let reduceMotion: Bool
    let onSelect: (DitherAlgorithm) -> Void

    @State private var source: GrayImage?
    @State private var result: MonoBitmap?
    @State private var thumbnails: [DitherAlgorithm: MonoBitmap] = [:]
    @State private var version = 0
    @State private var split: CGFloat = 0.5
    @State private var isRendering = false
    @Namespace private var namespace

    private struct RenderKey: Hashable {
        var algorithm: DitherAlgorithm
        var threshold: Int
    }

    init(algorithm: DitherAlgorithm, threshold: Int, reduceMotion: Bool, onSelect: @escaping (DitherAlgorithm) -> Void) {
        self.algorithm = algorithm
        self.threshold = threshold
        self.reduceMotion = reduceMotion
        self.onSelect = onSelect
    }

    static func shortName(_ algorithm: DitherAlgorithm) -> String {
        switch algorithm {
        case .threshold: return tr("Schwellenwert")
        case .ordered: return tr("Bayer")
        case .halftone: return tr("Halbton")
        case .floydSteinberg: return tr("Floyd–Steinberg")
        case .atkinson: return tr("Atkinson")
        case .stucki: return tr("Stucki")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            comparison
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            gallery
        }
        .task(id: RenderKey(algorithm: algorithm, threshold: threshold)) {
            await render()
        }
    }

    private var comparison: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let splitX = width * split
            ZStack(alignment: .topLeading) {
                Group {
                    if let source {
                        GrayImagePreview(image: source)
                    } else {
                        Theme.labelPaper
                    }
                }
                .frame(width: width, height: geo.size.height)

                if let result {
                    BitmapPreview(bitmap: result)
                        .frame(width: width, height: geo.size.height)
                        .id(version)
                        .transition(.opacity)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: max(0, width - splitX))
                        }
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geo.size.height)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: splitX - 1)

                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .frame(width: 26, height: 26)
                    .position(x: splitX, y: geo.size.height / 2)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        split = min(0.98, max(0.02, value.location.x / max(1, width)))
                    }
            )
            .overlay(alignment: .topLeading) {
                tag(tr("Original"))
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                tag(Self.shortName(algorithm))
                    .padding(8)
                    .id(algorithm)
                    .transition(.opacity)
            }
        }
        .aspectRatio(360.0 / 220.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .shimmering(active: isRendering && result == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Vergleich Original und gerastertes Bild"))
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var gallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
            ForEach(DitherAlgorithm.allCases) { candidate in
                galleryItem(candidate)
            }
        }
    }

    private func galleryItem(_ candidate: DitherAlgorithm) -> some View {
        let isSelected = candidate == algorithm
        return Button {
            onSelect(candidate)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let bitmap = thumbnails[candidate] {
                        BitmapPreview(bitmap: bitmap)
                    } else {
                        Theme.labelPaper
                            .aspectRatio(132.0 / 80.0, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(3)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.brandGradient, lineWidth: 2.5)
                            .shadow(color: Theme.violet.opacity(0.35), radius: 5)
                            .matchedGeometryEffect(id: "ditherSelection", in: namespace)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                }
                Text(Self.shortName(candidate))
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.shortName(candidate))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func render() async {
        isRendering = true
        // Entprellen, solange der Schwellenwert-Regler gezogen wird.
        try? await Task.sleep(for: .milliseconds(70))
        guard !Task.isCancelled else { return }
        let algorithm = self.algorithm
        let threshold = self.threshold
        // `Task.detached` erbt den Abbruch von `.task(id:)` nicht – daher weiterreichen.
        let job = Task.detached(priority: .userInitiated) { () -> PrintPrefsDitherOutput? in
            let image = PrintPrefsArtwork.sample(width: 360, height: 220)
            let main = Ditherer.dither(image, algorithm: algorithm, threshold: threshold)
            let small = PrintPrefsArtwork.sample(width: 132, height: 80)
            var thumbs: [DitherAlgorithm: MonoBitmap] = [:]
            for candidate in DitherAlgorithm.allCases {
                if Task.isCancelled { return nil }
                thumbs[candidate] = Ditherer.dither(small, algorithm: candidate, threshold: threshold)
            }
            return PrintPrefsDitherOutput(source: image, result: main, thumbnails: thumbs)
        }
        let rendered = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
        guard !Task.isCancelled, let output = rendered else { return }
        withAnimation(reduceMotion ? nil : Motion.snappy) {
            source = output.source
            result = output.result
            thumbnails = output.thumbnails
            version += 1
        }
        isRendering = false
    }
}

// MARK: - Auftragsgröße je Kompression

private struct PrintPrefsEstimateOutput: Sendable {
    var sizes: [GraphicCompression: Int]
    var error: String?
}

/// Kodiert eine Musterseite in Etikettengröße mit `JobEncoder` für jede Kompression und zeigt die
/// geschätzte Auftragsgröße; die kleinste wird hervorgehoben.
struct PrintPrefsCompressionEstimate: View {
    let settings: PrintSettings
    let language: PrinterLanguage
    let resolution: Resolution
    let stock: LabelStock
    let widthDots: Int
    let heightDots: Int
    let maxPrintWidthDots: Int?
    let reduceMotion: Bool
    let onSelect: (GraphicCompression) -> Void

    @State private var sizes: [GraphicCompression: Int] = [:]
    @State private var isEstimating = false
    @State private var errorMessage: String?
    @State private var barsShown = false

    private struct EstimateKey: Hashable {
        var settings: PrintSettings
        var language: PrinterLanguage
        var resolution: Resolution
        var stock: LabelStock
        var widthDots: Int
        var heightDots: Int
        var maxPrintWidthDots: Int?
    }

    init(settings: PrintSettings, language: PrinterLanguage, resolution: Resolution, stock: LabelStock,
         widthDots: Int, heightDots: Int, maxPrintWidthDots: Int?, reduceMotion: Bool,
         onSelect: @escaping (GraphicCompression) -> Void) {
        self.settings = settings
        self.language = language
        self.resolution = resolution
        self.stock = stock
        self.widthDots = widthDots
        self.heightDots = heightDots
        self.maxPrintWidthDots = maxPrintWidthDots
        self.reduceMotion = reduceMotion
        self.onSelect = onSelect
    }

    private var key: EstimateKey {
        var normalized = settings
        normalized.compression = .z64
        return EstimateKey(settings: normalized, language: language, resolution: resolution, stock: stock,
                           widthDots: widthDots, heightDots: heightDots, maxPrintWidthDots: maxPrintWidthDots)
    }

    var body: some View {
        let maxSize = max(1, sizes.values.max() ?? 1)
        let smallest = smallestCompression
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GraphicCompression.allCases) { compression in
                row(compression, maxSize: maxSize, isSmallest: compression == smallest)
            }
            footer
        }
        .animation(reduceMotion ? nil : Motion.spring, value: sizes)
        .animation(reduceMotion ? nil : Motion.snappy, value: settings.compression)
        .task(id: key) {
            await estimate()
        }
    }

    /// Kompression mit der kleinsten Auftragsgröße – nur bei ZPL und nur, wenn sich die Größen
    /// unterscheiden (EPL/CPCL ignorieren die Kompression, alle Werte sind dort gleich).
    /// Bei Gleichstand gewinnt die erste in `allCases`, damit die Markierung nicht springt.
    private var smallestCompression: GraphicCompression? {
        guard language == .zpl, Set(sizes.values).count > 1 else { return nil }
        var best: GraphicCompression?
        var bestSize = Int.max
        for compression in GraphicCompression.allCases {
            if let size = sizes[compression], size < bestSize {
                best = compression
                bestSize = size
            }
        }
        return best
    }

    private func row(_ compression: GraphicCompression, maxSize: Int, isSmallest: Bool) -> some View {
        let isSelected = compression == settings.compression
        let size = sizes[compression]
        let fraction = CGFloat(size ?? 0) / CGFloat(maxSize)
        let isRelevant = language == .zpl
        return Button {
            onSelect(compression)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(tr(compression.displayName))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    if isSmallest && size != nil {
                        Label(tr("Kleinste"), systemImage: "crown.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.ready)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.ready.opacity(0.14), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer(minLength: 8)
                    Text(size.map(PrintPrefsFormat.bytes) ?? "–")
                        .font(Theme.Typography.code)
                        .contentTransition(.numericText())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.subtleFill)
                        Capsule()
                            .fill(isSmallest ? AnyShapeStyle(LinearGradient(colors: [Theme.teal, Theme.ready],
                                                                            startPoint: .leading, endPoint: .trailing))
                                             : AnyShapeStyle(Theme.brandGradient))
                            .frame(width: max(6, geo.size.width * (barsShown ? fraction : 0)))
                            .saturation(isRelevant ? 1 : 0)
                            .opacity(isRelevant ? 1 : 0.45)
                    }
                }
                .frame(height: 6)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.08) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Theme.cardStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .shimmering(active: isEstimating)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var footer: some View {
        if let errorMessage {
            PrintPrefsHint(tr("Schätzung nicht möglich: %@", errorMessage),
                           systemImage: "exclamationmark.triangle", tint: Theme.warning)
        } else if language != .zpl {
            PrintPrefsHint(tr("%@ überträgt Grafiken binär – die Kompression wirkt nur bei ZPL.", language.displayName),
                           systemImage: "info.circle")
        } else if let hex = sizes[.hex], let best = sizes.values.min(), hex > 0 {
            let saving = max(0, 1 - Double(best) / Double(hex))
            PrintPrefsHint(tr("Geschätzt für ein Etikett „%@“ bei %d dpi. Die beste Kompression spart %@ gegenüber Hex.",
                              stock.name, resolution.dpi, saving.formatted(.percent.precision(.fractionLength(0)))),
                           systemImage: "gauge.with.dots.needle.33percent")
        }
    }

    private func estimate() async {
        isEstimating = true
        // Entprellen: Regler und Eingaben lösen sonst viele Berechnungen aus.
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        let base = settings
        let language = self.language
        let resolution = self.resolution
        let stock = self.stock
        let maxWidth = maxPrintWidthDots
        let width = max(8, min(widthDots, maxWidth ?? widthDots))
        // Sehr große Etiketten (600 dpi) begrenzen, damit die Schätzung flott bleibt.
        let height = max(8, min(heightDots, 6_000_000 / width))
        // `Task.detached` erbt den Abbruch von `.task(id:)` nicht – ohne Weiterreichen liefen veraltete
        // Schätzungen (bis zu ~6 MP Rastern + drei Kodierungen) bei schnellen Änderungen weiter.
        let job = Task.detached(priority: .utility) { () -> PrintPrefsEstimateOutput? in
            let image = PrintPrefsArtwork.sample(width: width, height: height)
            if Task.isCancelled { return nil }
            let page = Ditherer.dither(image, algorithm: base.dither, threshold: base.threshold)
            var measured: [GraphicCompression: Int] = [:]
            do {
                for compression in GraphicCompression.allCases {
                    if Task.isCancelled { return nil }
                    var variant = base
                    variant.compression = compression
                    let encoder = JobEncoder(language: language, resolution: resolution, settings: variant,
                                             stock: stock, maxPrintWidthDots: maxWidth)
                    measured[compression] = try encoder.encode(pages: [page], copies: 1, collate: true).count
                }
                return PrintPrefsEstimateOutput(sizes: measured, error: nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return PrintPrefsEstimateOutput(sizes: [:], error: message)
            }
        }
        let estimated = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
        guard !Task.isCancelled, let output = estimated else { return }
        withAnimation(reduceMotion ? nil : Motion.spring) {
            sizes = output.sizes
            errorMessage = output.error
            barsShown = true
        }
        isEstimating = false
    }
}

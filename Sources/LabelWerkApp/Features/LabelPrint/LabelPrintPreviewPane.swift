import AppKit
import SwiftUI
import LabelWerkKit

/// Mitte des Etikettendrucks: das Etikett genau so, wie es aus dem Drucker kommt – Punkt für Punkt
/// die Druckdaten (`LabelPrintRenderedPage.label`), seitenverhältnistreu auf einem Etikett mit
/// abgerundeten Ecken auf dem Trägerpapier (Lücke zum nächsten Etikett angedeutet). „Originalseite“
/// zeigt zum Vergleich die Seite, wie das Programm sie geliefert hat.
struct LabelPrintPreviewPane: View {
    @Bindable var store: LabelPrintStore
    let reduceMotion: Bool

    @State private var original: LabelPrintImageBox?
    @State private var originalKey: String?

    private static let zoomRange: ClosedRange<Double> = 0.5...4

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            stage
            Divider().opacity(0.5)
            infoBar
        }
    }

    // MARK: Werkzeugleiste

    private var jobPages: [Int] { store.jobPages }

    private var position: Int? {
        guard let page = store.displayedPage else { return nil }
        return jobPages.firstIndex(of: page)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled((position ?? 0) <= 0)
                .help(tr("Vorheriges Etikett"))
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled((position ?? jobPages.count) >= jobPages.count - 1)
                .help(tr("Nächstes Etikett"))
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.labelWerkPlain)
            Text(position.map { tr("Etikett %d von %d", $0 + 1, jobPages.count) } ?? tr("Keine Seite gewählt"))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Toggle(isOn: $store.showsOriginal.animation(reduceMotion ? nil : Motion.spring)) {
                Label(tr("Originalseite"), systemImage: "doc.richtext")
            }
            .toggleStyle(.button)
            .help(tr("Zum Vergleich die Seite zeigen, wie das Programm sie geliefert hat"))
            Divider().frame(height: 18)
            HStack(spacing: 6) {
                Button {
                    setZoom(store.zoom / 1.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Verkleinern"))
                Slider(value: Binding(get: { log2(store.zoom) }, set: { setZoom(pow(2, $0)) }),
                       in: log2(Self.zoomRange.lowerBound)...log2(Self.zoomRange.upperBound))
                    .frame(width: 110)
                    .controlSize(.small)
                    .accessibilityLabel(tr("Zoom"))
                Button {
                    setZoom(store.zoom * 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Vergrößern"))
                Button {
                    setZoom(1)
                } label: {
                    Text(String(format: "%.0f %%", store.zoom * 100))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 42)
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Ins Fenster einpassen"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func step(_ delta: Int) {
        guard let position else { return }
        let next = min(max(0, position + delta), jobPages.count - 1)
        withAnimation(reduceMotion ? nil : Motion.snappy) {
            store.focusedPage = jobPages[next]
            if store.pageMode == .all { store.selection = [jobPages[next]] }
        }
    }

    private func setZoom(_ value: Double) {
        withAnimation(reduceMotion ? nil : Motion.snappy) {
            store.zoom = value.clamped(to: Self.zoomRange)
        }
    }

    // MARK: Bühne

    private var stage: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(100, geometry.size.width - 80), height: max(100, geometry.size.height - 80))
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    if store.showsOriginal {
                        originalView(available: available)
                            .transition(flipTransition(from: .trailing))
                    } else {
                        labelView(available: available)
                            .transition(flipTransition(from: .leading))
                    }
                }
                .padding(40)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .scrollIndicators(store.zoom > 1 ? .automatic : .never)
        }
        .overlay {
            CelebrationBurst(trigger: store.printSuccessCount)
                .allowsHitTesting(false)
        }
    }

    private func flipTransition(from edge: HorizontalEdge) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: LabelPrintFlip(angle: edge == .leading ? -90 : 90, opacity: 0),
                                 identity: LabelPrintFlip(angle: 0, opacity: 1)),
            removal: .modifier(active: LabelPrintFlip(angle: edge == .leading ? 90 : -90, opacity: 0),
                               identity: LabelPrintFlip(angle: 0, opacity: 1))
        )
    }

    @ViewBuilder
    private func labelView(available: CGSize) -> some View {
        if let target = store.renderedKey?.target ?? store.target, let page = store.displayedPage {
            let rendered = store.renderedKey?.pages.contains(page) == true ? store.rendered[page] : nil
            let widthDots = target.labelWidthDots
            let heightDots = rendered?.label?.height ?? target.labelHeightDots ?? max(1, target.labelWidthDots / 2)
            let size = Self.fitted(width: CGFloat(widthDots), height: CGFloat(heightDots), in: available, zoom: store.zoom)
            LabelPrintLabelStage(
                label: rendered?.label,
                isPending: rendered == nil,
                isSkipped: rendered != nil && rendered?.label == nil,
                widthDots: widthDots,
                heightDots: heightDots,
                widthMM: target.stock.widthMM,
                isContinuous: target.labelHeightDots == nil,
                size: size,
                reduceMotion: reduceMotion
            )
            .id(page)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            .keyframeAnimator(initialValue: LabelPrintFeed(), trigger: reduceMotion ? 0 : store.printSuccessCount) { content, value in
                content
                    .offset(y: value.offset)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offset) {
                    CubicKeyframe(-24, duration: 0.28)
                    CubicKeyframe(-90, duration: 0.22)
                    MoveKeyframe(40)
                    SpringKeyframe(0, duration: 0.55, spring: .bouncy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.28)
                    LinearKeyframe(0, duration: 0.22)
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.35)
                }
            }
        } else {
            Text(tr("Keine Seite gewählt"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func originalView(available: CGSize) -> some View {
        if let page = store.displayedPage, page < store.pages.count, let document = store.document(for: store.pages[page]) {
            let ref = store.pages[page]
            let key = "\(ref.documentID)-\(ref.page)"
            let image = originalKey == key ? original?.image : nil
            let aspect: CGFloat = image.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 0.707
            let size = Self.fitted(width: aspect * 1000, height: 1000, in: available, zoom: store.zoom)
            ZStack {
                Rectangle().fill(Color.white)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ProgressRing(progress: nil, size: 26, lineWidth: 3)
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            .overlay(alignment: .topLeading) {
                Text(tr("Originalseite"))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .labelWerkGlass(cornerRadius: 7)
                    .padding(8)
            }
            .task(id: key) {
                guard originalKey != key else { return }
                let rendered = await Task.detached(priority: .userInitiated) {
                    LabelPrintImageBox(image: document.originalPreview(at: ref.page))
                }.value
                original = rendered
                originalKey = key
            }
        }
    }

    /// Größe für ein Etikett `width` × `height` (Punkte), eingepasst in `available`, mal `zoom`.
    static func fitted(width: CGFloat, height: CGFloat, in available: CGSize, zoom: Double) -> CGSize {
        let scale = min(available.width / max(1, width), available.height / max(1, height))
        return CGSize(width: max(1, width * scale * zoom), height: max(1, height * scale * zoom))
    }

    // MARK: Infozeile

    private var infoBar: some View {
        let target = store.renderedKey?.target ?? store.target
        let page = store.displayedPage
        let rendered = page.flatMap { store.renderedKey?.pages.contains($0) == true ? store.rendered[$0] : nil }
        return HStack(spacing: 8) {
            if let target {
                LabelPrintChip(text: sizeText(target, rendered: rendered), systemImage: "ruler", tint: .secondary)
                LabelPrintChip(text: tr("%d dpi", target.resolution.dpi), systemImage: "circle.grid.3x3", tint: .secondary)
            }
            if let rendered {
                if rendered.label == nil {
                    LabelPrintChip(text: tr("Leere Seite – wird übersprungen"), systemImage: "forward.end", tint: Theme.warning)
                } else if rendered.wasFitted {
                    LabelPrintChip(text: tr("An Etikett angepasst"), systemImage: "arrow.down.right.and.arrow.up.left",
                                   tint: Theme.teal)
                        .help(tr("Die Seite war größer oder kleiner als das Etikett (z. B. A4 aus dem Druckdialog). LabelWerk legt den Inhalt aufrecht und formatfüllend mit 1,5 mm Rand auf das Etikett – genau wie der Treiber."))
                }
                if rendered.isClipped {
                    LabelPrintChip(text: tr("Inhalt ragt über das Etikett"), systemImage: "exclamationmark.triangle.fill",
                                   tint: Theme.warning)
                        .help(tr("Teile der Seite liegen außerhalb des Etiketts bzw. der Druckbreite und werden nicht gedruckt."))
                }
            } else if store.isRendering {
                HStack(spacing: 6) {
                    ProgressRing(progress: Double(store.renderedCount) / Double(max(1, store.renderedKey?.pages.count ?? 1)),
                                 size: 14, lineWidth: 2)
                    Text(tr("Etiketten werden vorbereitet …"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(tr("Ansicht wie gedruckt"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help(tr("Genau die Punkte, die an den Drucker gehen: angepasst, gedreht, gerastert, mit Versatz, Spiegeln und Invertieren aus den Einstellungen des Etikettentyps."))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : Motion.snappy, value: rendered?.wasFitted)
    }

    private func sizeText(_ target: LabelPrintTarget, rendered: LabelPrintRenderedPage?) -> String {
        let widthMM = target.stock.widthMM
        if target.labelHeightDots == nil {
            // Endlosmaterial: Länge folgt dem Inhalt der Seite.
            guard let height = rendered?.label?.height else {
                return tr("%@ mm breit · Endlos", LabelSizing.format(widthMM))
            }
            return LabelSizing.sizeText(widthMM: widthMM, heightMM: target.resolution.mm(fromDots: height))
        }
        return LabelSizing.sizeText(widthMM: widthMM, heightMM: target.stock.heightMM)
    }
}

/// Werte der „Etikett kommt heraus“-Animation nach dem Drucken.
struct LabelPrintFeed {
    var offset: CGFloat = 0
    var opacity: Double = 1
}

/// Umblättern zwischen Etikett und Originalseite.
private struct LabelPrintFlip: ViewModifier {
    let angle: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .opacity(opacity)
    }
}

/// Etikett auf dem Trägerpapier: Nachbaretiketten oben und unten angedeutet (Lücke), bei
/// Endlosmaterial eine Abrisskante. `size` = Etikett in Bildschirmpunkten.
struct LabelPrintLabelStage: View {
    let label: MonoBitmap?
    let isPending: Bool
    let isSkipped: Bool
    let widthDots: Int
    let heightDots: Int
    let widthMM: Double
    let isContinuous: Bool
    let size: CGSize
    let reduceMotion: Bool

    @State private var image: CGImage?

    var body: some View {
        let pointsPerMM = size.width / CGFloat(max(1, widthMM))
        let radius = isContinuous ? 0 : (pointsPerMM * 1.6).clamped(to: 2...18)
        let gap = (pointsPerMM * 3).clamped(to: 6...28)
        let sliver = (pointsPerMM * 6).clamped(to: 10...44)
        let liner = (pointsPerMM * 2.5).clamped(to: 6...24)
        VStack(spacing: gap) {
            if !isContinuous {
                neighbor(height: sliver, radius: radius, edge: .top)
            }
            labelCard(radius: radius)
            if isContinuous {
                tearEdge
            } else {
                neighbor(height: sliver, radius: radius, edge: .bottom)
            }
        }
        .padding(.horizontal, liner)
        .background(
            Rectangle()
                .fill(Color(red: 0.93, green: 0.92, blue: 0.88))
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .opacity(isContinuous ? 0 : 1)
        )
        .onAppear { image = label.flatMap(ImageImport.cgImage(from:)) }
        .onChange(of: label) { _, newValue in image = newValue.flatMap(ImageImport.cgImage(from:)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Etikettenvorschau"))
    }

    private func labelCard(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(Theme.labelPaper)
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .blendMode(.multiply)
                    .transition(.opacity)
            }
            if isPending {
                ProgressRing(progress: nil, size: 26, lineWidth: 3)
            } else if isSkipped {
                Label(tr("Wird übersprungen"), systemImage: "forward.end")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: image == nil)
    }

    private enum Edge { case top, bottom }

    /// Angeschnittenes Nachbaretikett (zeigt die Lücke auf dem Trägerpapier).
    private func neighbor(height: CGFloat, radius: CGFloat, edge: Edge) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.labelPaper.opacity(0.75))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.6))
            .frame(width: size.width, height: height * 3)
            .frame(width: size.width, height: height, alignment: edge == .top ? .bottom : .top)
            .clipped()
            .mask(LinearGradient(colors: [.clear, .black], startPoint: edge == .top ? .top : .bottom,
                                 endPoint: edge == .top ? .bottom : .top))
            .accessibilityHidden(true)
    }

    /// Abrisskante bei Endlosmaterial.
    private var tearEdge: some View {
        Path { path in
            let width = size.width
            let tooth: CGFloat = 8
            path.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            var up = false
            while x < width {
                x = min(width, x + tooth)
                path.addLine(to: CGPoint(x: x, y: up ? 0 : tooth / 2))
                up.toggle()
            }
        }
        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .frame(width: size.width, height: 6)
        .accessibilityHidden(true)
    }
}

/// Kleiner Hinweis-Chip.
struct LabelPrintChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
            .lineLimit(1)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

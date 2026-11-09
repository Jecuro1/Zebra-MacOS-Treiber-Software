import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Etikettenblatt

/// Etikett auf Trägerpapier: hält das Seitenverhältnis `widthMM:heightMM`, zeigt Papier, Schatten
/// und abgerundete Ecken. Der Inhalt füllt die Etikettenfläche.
struct LabelSheet<Content: View>: View {
    let widthMM: Double
    let heightMM: Double
    let content: Content

    init(widthMM: Double, heightMM: Double, @ViewBuilder content: () -> Content) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.content = content()
    }

    var body: some View {
        let aspect = CGFloat(max(widthMM, 1) / max(heightMM, 1))
        let radius = CGFloat(min(widthMM, heightMM) / 30).clamped(to: 3...10)
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.labelPaper)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            content
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.6)
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Vektorvorschau

/// Vektor-Rendering einer ZPL-Displayliste (`RenderedLabel`) mit `Canvas`.
///
/// Texte werden mit Systemschriften angenähert (Schrift 0 ≈ schmale, fette Grotesk; Bitmap-Schriften
/// A–H ≈ Monospace). Für eine pixelgenaue Ansicht `BitmapPreview` mit `SoftwareRasterizer` verwenden.
struct LabelCanvas: View {
    let label: RenderedLabel
    var showsGrid: Bool = false
    var highlightedElement: Int?

    init(label: RenderedLabel, showsGrid: Bool = false, highlightedElement: Int? = nil) {
        self.label = label
        self.showsGrid = showsGrid
        self.highlightedElement = highlightedElement
    }

    /// Textfelder mit ^FB werden als SwiftUI-Symbole gerendert (Umbruch & Ausrichtung).
    private var blockTexts: [(index: Int, element: TextElement, block: FieldBlock)] {
        label.elements.enumerated().compactMap { index, element in
            if case .text(let text) = element, let block = text.block { return (index, text, block) }
            return nil
        }
    }

    var body: some View {
        let width = CGFloat(max(1, label.widthDots))
        let height = CGFloat(max(1, label.heightDots))
        let blocks = blockTexts
        Canvas(rendersAsynchronously: false) { context, size in
            let scale = min(size.width / width, size.height / height)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var ctx = context
            ctx.scaleBy(x: scale, y: scale)
            if label.inverted {
                ctx.translateBy(x: width, y: height)
                ctx.rotate(by: .degrees(180))
            }
            if label.mirrored {
                ctx.translateBy(x: width, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            if showsGrid { drawGrid(ctx, width: width, height: height) }
            for (index, element) in label.elements.enumerated() {
                LabelElementPainter.draw(element, in: ctx, symbol: ctx.resolveSymbol(id: index))
                if index == highlightedElement {
                    let box = element.boundingBox
                    let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height).insetBy(dx: -4, dy: -4)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.accent),
                               style: StrokeStyle(lineWidth: 3 / scale * 2, dash: [8 / scale * 2, 5 / scale * 2]))
                }
            }
        } symbols: {
            ForEach(blocks, id: \.index) { item in
                FieldBlockText(element: item.element, block: item.block)
                    .tag(item.index)
            }
        }
        .aspectRatio(width / height, contentMode: .fit)
        .accessibilityLabel(tr("Etikettenvorschau"))
    }

    private func drawGrid(_ context: GraphicsContext, width: CGFloat, height: CGFloat) {
        let dpmm = CGFloat(max(1, label.dotsPerMM))
        let step = dpmm * 5
        var path = Path()
        var x: CGFloat = 0
        while x <= width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height)); x += step }
        var y: CGFloat = 0
        while y <= height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y)); y += step }
        context.stroke(path, with: .color(Theme.accent.opacity(0.12)), lineWidth: 0.6)
    }
}

/// Zeichnet einzelne Elemente der Displayliste in Druckpunkt-Koordinaten.
enum LabelElementPainter {
    static func draw(_ element: LabelElement, in context: GraphicsContext,
                     symbol: GraphicsContext.ResolvedSymbol? = nil) {
        switch element {
        case .text(let text): drawText(text, in: context, symbol: symbol)
        case .box(let box): drawBox(box, in: context)
        case .ellipse(let ellipse): drawEllipse(ellipse, in: context)
        case .diagonal(let diagonal): drawDiagonal(diagonal, in: context)
        case .graphic(let graphic): drawGraphic(graphic, in: context)
        case .linearBarcode(let barcode): drawLinear(barcode, in: context)
        case .matrixBarcode(let barcode): drawMatrix(barcode, in: context)
        }
    }

    /// Farbe & Mischmodus: Umkehrfelder (`^FR`) invertieren den Untergrund.
    private static func ink(_ color: LineColor, reverse: Bool, context: inout GraphicsContext) -> Color {
        if reverse {
            context.blendMode = .difference
            return .white
        }
        return color == .white ? .white : .black
    }

    /// Dreht um den Feldursprung so, dass die linke obere Ecke des gedrehten Felds am Ursprung liegt.
    private static func oriented(_ context: GraphicsContext, origin: LabelPoint, size: CGSize,
                                 orientation: FieldOrientation) -> GraphicsContext {
        var ctx = context
        let x = CGFloat(origin.x), y = CGFloat(origin.y)
        switch orientation {
        case .normal:
            ctx.translateBy(x: x, y: y)
        case .rotated90:
            ctx.translateBy(x: x + size.height, y: y)
            ctx.rotate(by: .degrees(90))
        case .inverted180:
            ctx.translateBy(x: x + size.width, y: y + size.height)
            ctx.rotate(by: .degrees(180))
        case .rotated270:
            ctx.translateBy(x: x, y: y + size.width)
            ctx.rotate(by: .degrees(270))
        }
        return ctx
    }

    static func font(for element: TextElement) -> Font {
        let size = CGFloat(max(4, element.height)) * 0.94
        let name = element.fontName.uppercased()
        if name == "0" || name.isEmpty {
            return .system(size: size, weight: .bold).width(.condensed)
        }
        if name.count == 1, let c = name.first, c.isLetter || c.isNumber {
            return .system(size: size, weight: .regular, design: .monospaced)
        }
        return .system(size: size, weight: .regular)
    }

    /// Horizontale Streckung: Breite == Höhe entspricht der natürlichen Laufweite.
    static func horizontalScale(for element: TextElement) -> CGFloat {
        guard element.width > 0, element.height > 0 else { return 1 }
        return min(3, max(0.25, CGFloat(element.width) / CGFloat(element.height)))
    }

    private static func drawText(_ element: TextElement, in context: GraphicsContext,
                                 symbol: GraphicsContext.ResolvedSymbol?) {
        var ctx = context
        let color = ink(.black, reverse: element.reverse, context: &ctx)
        let height = CGFloat(max(1, element.height))
        let scaleX = horizontalScale(for: element)
        if let block = element.block {
            let lines = max(1, block.maxLines)
            let blockSize = CGSize(width: CGFloat(max(1, block.width)),
                                   height: CGFloat(lines) * height + CGFloat(max(0, lines - 1) * block.lineSpacing))
            let drawCtx = oriented(ctx, origin: element.origin, size: blockSize, orientation: element.orientation)
            if let symbol {
                drawCtx.draw(symbol, in: CGRect(origin: .zero, size: blockSize))
            }
        } else {
            let text = Text(element.text).font(font(for: element)).foregroundStyle(color)
            let resolved = ctx.resolve(text)
            let measured = resolved.measure(in: CGSize(width: 100_000, height: 100_000))
            let fieldSize = CGSize(width: measured.width * scaleX, height: height)
            var drawCtx = oriented(ctx, origin: element.origin, size: fieldSize, orientation: element.orientation)
            drawCtx.scaleBy(x: scaleX, y: 1)
            drawCtx.draw(resolved, at: CGPoint(x: 0, y: height * 0.5), anchor: .leading)
        }
    }

    private static func drawBox(_ box: BoxElement, in context: GraphicsContext) {
        var ctx = context
        let shading = GraphicsContext.Shading.color(ink(box.color, reverse: box.reverse, context: &ctx))
        let w = CGFloat(max(box.width, box.thickness)), h = CGFloat(max(box.height, box.thickness))
        let t = CGFloat(max(1, box.thickness))
        let rect = CGRect(x: CGFloat(box.origin.x), y: CGFloat(box.origin.y), width: w, height: h)
        // ZPL-Rundung 0…8: Radius = Rundung/8 × kürzere Seite/2
        let radius = CGFloat(box.rounding) / 8 * min(w, h) / 2
        if t * 2 >= min(w, h) {
            ctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: shading)
        } else {
            var path = Path(roundedRect: rect, cornerRadius: radius)
            path.addPath(Path(roundedRect: rect.insetBy(dx: t, dy: t), cornerRadius: max(0, radius - t)))
            ctx.fill(path, with: shading, style: FillStyle(eoFill: true))
        }
    }

    private static func drawEllipse(_ ellipse: EllipseElement, in context: GraphicsContext) {
        var ctx = context
        let shading = GraphicsContext.Shading.color(ink(ellipse.color, reverse: ellipse.reverse, context: &ctx))
        let rect = CGRect(x: CGFloat(ellipse.origin.x), y: CGFloat(ellipse.origin.y),
                          width: CGFloat(ellipse.width), height: CGFloat(ellipse.height))
        let t = CGFloat(max(1, ellipse.thickness))
        if t * 2 >= min(rect.width, rect.height) {
            ctx.fill(Path(ellipseIn: rect), with: shading)
        } else {
            var path = Path(ellipseIn: rect)
            path.addPath(Path(ellipseIn: rect.insetBy(dx: t, dy: t)))
            ctx.fill(path, with: shading, style: FillStyle(eoFill: true))
        }
    }

    private static func drawDiagonal(_ diagonal: DiagonalElement, in context: GraphicsContext) {
        var ctx = context
        let shading = GraphicsContext.Shading.color(ink(diagonal.color, reverse: diagonal.reverse, context: &ctx))
        let x = CGFloat(diagonal.origin.x), y = CGFloat(diagonal.origin.y)
        let w = CGFloat(diagonal.width), h = CGFloat(diagonal.height), t = CGFloat(max(1, diagonal.thickness))
        var path = Path()
        if diagonal.leansRight {
            path.move(to: CGPoint(x: x, y: y + h))
            path.addLine(to: CGPoint(x: x + w - t, y: y))
            path.addLine(to: CGPoint(x: x + w, y: y))
            path.addLine(to: CGPoint(x: x + t, y: y + h))
        } else {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + t, y: y))
            path.addLine(to: CGPoint(x: x + w, y: y + h))
            path.addLine(to: CGPoint(x: x + w - t, y: y + h))
        }
        path.closeSubpath()
        ctx.fill(path, with: shading)
    }

    private static func drawGraphic(_ graphic: GraphicElement, in context: GraphicsContext) {
        var ctx = context
        let rect = CGRect(x: CGFloat(graphic.origin.x), y: CGFloat(graphic.origin.y),
                          width: CGFloat(graphic.bitmap.width * max(1, graphic.magnificationX)),
                          height: CGFloat(graphic.bitmap.height * max(1, graphic.magnificationY)))
        if graphic.reverse {
            // Punkte weiß auf schwarz + Differenz: kehrt den Untergrund nur unter den Punkten um.
            guard let cg = ImageImport.cgImage(from: graphic.bitmap.inverted()) else { return }
            ctx.blendMode = .difference
            ctx.draw(Image(decorative: cg, scale: 1).interpolation(.none), in: rect)
        } else {
            guard let cg = ImageImport.cgImage(from: graphic.bitmap) else { return }
            ctx.blendMode = .multiply
            ctx.draw(Image(decorative: cg, scale: 1).interpolation(.none), in: rect)
        }
    }

    private static func drawLinear(_ element: LinearBarcodeElement, in context: GraphicsContext) {
        let module = max(1, element.moduleWidth)
        let widths = element.barcode.widthsInDots(moduleWidth: module, ratio: element.ratio)
        let total = CGFloat(widths.reduce(0) { $0 + $1.dots })
        let barHeight = CGFloat(max(1, element.height))
        let textHeight: CGFloat = element.printInterpretation ? max(12, CGFloat(module) * 9) : 0
        let fieldSize = CGSize(width: total, height: barHeight + textHeight)
        var ctx = oriented(context, origin: element.origin, size: fieldSize, orientation: element.orientation)
        var x: CGFloat = 0
        let barTop: CGFloat = element.printInterpretation && element.interpretationAbove ? textHeight : 0
        var bars = Path()
        for piece in widths {
            if piece.isBar {
                bars.addRect(CGRect(x: x, y: barTop, width: CGFloat(piece.dots), height: barHeight))
            }
            x += CGFloat(piece.dots)
        }
        ctx.fill(bars, with: .color(.black))
        if element.printInterpretation {
            let label = element.barcode.humanReadable.isEmpty ? element.text : element.barcode.humanReadable
            let text = Text(label)
                .font(.system(size: textHeight * 0.82, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.black)
            let y = element.interpretationAbove ? textHeight * 0.5 : barHeight + textHeight * 0.55
            ctx.draw(text, at: CGPoint(x: total / 2, y: y), anchor: .center)
        }
    }

    private static func drawMatrix(_ element: MatrixBarcodeElement, in context: GraphicsContext) {
        let m = CGFloat(max(1, element.moduleSize))
        let matrix = element.matrix
        let size = CGSize(width: CGFloat(matrix.width) * m, height: CGFloat(matrix.height) * m)
        let ctx = oriented(context, origin: element.origin, size: size, orientation: element.orientation)
        var path = Path()
        for y in 0..<matrix.height {
            for x in 0..<matrix.width where matrix[x, y] {
                path.addRect(CGRect(x: CGFloat(x) * m, y: CGFloat(y) * m, width: m, height: m))
            }
        }
        ctx.fill(path, with: .color(.black))
    }
}

/// Feldblock-Text (`^FB`) mit Umbruch, Zeilenzahl und Ausrichtung, gerendert als Canvas-Symbol.
private struct FieldBlockText: View {
    let element: TextElement
    let block: FieldBlock

    var body: some View {
        let height = CGFloat(max(1, element.height))
        let lines = max(1, block.maxLines)
        let scaleX = LabelElementPainter.horizontalScale(for: element)
        let blockWidth = CGFloat(max(1, block.width))
        let alignment: TextAlignment = {
            switch block.justification {
            case .left, .justified: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }()
        let frameAlignment: Alignment = alignment == .center ? .top : (alignment == .trailing ? .topTrailing : .topLeading)
        Text(element.text.replacingOccurrences(of: "\\&", with: "\n"))
            .font(LabelElementPainter.font(for: element))
            .foregroundStyle(element.reverse ? Color.white : Color.black)
            .lineSpacing(CGFloat(block.lineSpacing))
            .lineLimit(lines)
            .multilineTextAlignment(alignment)
            .frame(width: blockWidth / scaleX, alignment: frameAlignment)
            .scaleEffect(x: scaleX, y: 1, anchor: .topLeading)
            .frame(width: blockWidth, height: CGFloat(lines) * height + CGFloat(max(0, lines - 1) * block.lineSpacing),
                   alignment: .topLeading)
    }
}

// MARK: - Pixelgenaue Vorschau

/// 1-Bit-Bitmap pixelgenau (ohne Interpolation) und seitenverhältnistreu.
struct BitmapPreview: View {
    let bitmap: MonoBitmap
    @State private var image: CGImage?

    init(bitmap: MonoBitmap) {
        self.bitmap = bitmap
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white
                    .aspectRatio(CGFloat(max(1, bitmap.width)) / CGFloat(max(1, bitmap.height)), contentMode: .fit)
            }
        }
        .onAppear { image = ImageImport.cgImage(from: bitmap) }
        .onChange(of: bitmap) { _, newValue in image = ImageImport.cgImage(from: newValue) }
    }
}

/// Graustufenbild (z. B. vor dem Rastern).
struct GrayImagePreview: View {
    let image: GrayImage
    @State private var cgImage: CGImage?

    init(image: GrayImage) {
        self.image = image
    }

    var body: some View {
        Group {
            if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white
                    .aspectRatio(CGFloat(max(1, image.width)) / CGFloat(max(1, image.height)), contentMode: .fit)
            }
        }
        .onAppear { cgImage = ImageImport.cgImage(from: image) }
        .onChange(of: image) { _, newValue in cgImage = ImageImport.cgImage(from: newValue) }
    }
}

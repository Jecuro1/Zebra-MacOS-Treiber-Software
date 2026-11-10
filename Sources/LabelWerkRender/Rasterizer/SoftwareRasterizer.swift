import Foundation
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging

/// Rastert eine Displayliste (`RenderedLabel`) pixelgenau in eine 1-Bit-Bitmap – so, wie der
/// Drucker das Etikett ausgeben würde.
///
/// * Bitmapgröße = `widthDots × heightDots`; alles außerhalb wird abgeschnitten.
/// * Jedes Feld wird zuerst in eine eigene Maske gezeichnet (ungedreht, auf den sichtbaren Teil
///   beschränkt), dann gedreht und übertragen: schwarz = ODER, weiße Linienfarbe = löschen,
///   `^FR`/`^LR` = XOR. Überlappungen innerhalb eines Felds heben sich daher nicht auf.
/// * Text verwendet die eingebauten Bitmap-Schriften (DejaVu-Mastervorlagen, siehe `TextFont`).
/// * Zum Schluss werden `^POI` (180°) und `^PMY` (Spiegelung) angewandt.
public enum SoftwareRasterizer {

    /// Rastert das Etikett wie gedruckt (inklusive `^PO`/`^PM`).
    public static func rasterize(_ label: RenderedLabel) -> MonoBitmap {
        rasterize(label, applyingPrintTransforms: true)
    }

    /// Rastert das Etikett; ohne `applyingPrintTransforms` in Formatkoordinaten (ohne `^PO`/`^PM`).
    public static func rasterize(_ label: RenderedLabel, applyingPrintTransforms: Bool) -> MonoBitmap {
        var canvas = BitCanvas(width: label.widthDots, height: label.heightDots)
        var glyphs = GlyphRenderer()
        let dotsPerMM = max(1, label.dotsPerMM)
        for element in label.elements {
            draw(element, into: &canvas, dotsPerMM: dotsPerMM, glyphs: &glyphs)
        }
        var bitmap = canvas.monoBitmap
        if applyingPrintTransforms {
            if label.inverted { bitmap = bitmap.rotated180() }
            if label.mirrored { bitmap = bitmap.mirrored() }
        }
        return bitmap
    }

    /// Rastert ein einzelnes Element in eine Bitmap der angegebenen Größe (z. B. für Vorschaubilder).
    public static func rasterize(_ element: LabelElement, widthDots: Int, heightDots: Int,
                                 dotsPerMM: Int = 8) -> MonoBitmap {
        var canvas = BitCanvas(width: widthDots, height: heightDots)
        var glyphs = GlyphRenderer()
        draw(element, into: &canvas, dotsPerMM: max(1, dotsPerMM), glyphs: &glyphs)
        return canvas.monoBitmap
    }

    // MARK: Elemente

    static func draw(_ element: LabelElement, into canvas: inout BitCanvas, dotsPerMM: Int,
                     glyphs: inout GlyphRenderer) {
        switch element {
        case .text(let text):
            // Eigene Auflösung des Elements (vom Interpreter gesetzt) vor der des Etiketts – so
            // stimmen Rasterung und `LabelElement.boundingBox` stets überein.
            let layout = TextLayout(element: text, dotsPerMM: max(1, text.dotsPerMM ?? dotsPerMM))
            // Akzente und Unterlängen dürfen über das Feldrechteck hinausragen.
            let margin = max(2, text.height / 2 + 2)
            let ink = IntRect(x: -margin, y: -margin, width: layout.width + 2 * margin,
                              height: layout.height + 2 * margin)
            paintField(size: (layout.width, layout.height), ink: ink, origin: text.origin,
                       orientation: text.orientation, mode: text.reverse ? .reverse : .black, canvas: &canvas) { mask in
                glyphs.draw(layout, into: &mask)
            }
        case .box(let box):
            let size = (max(1, box.width), max(1, box.height))
            paintField(size: size, ink: nil, origin: box.origin, orientation: .normal,
                       mode: mode(box.color, box.reverse), canvas: &canvas) { mask in
                ShapePainter.box(x: 0, y: 0, width: size.0, height: size.1, thickness: box.thickness,
                                 rounding: box.rounding, into: &mask)
            }
        case .ellipse(let ellipse):
            let size = (max(1, ellipse.width), max(1, ellipse.height))
            paintField(size: size, ink: nil, origin: ellipse.origin, orientation: .normal,
                       mode: mode(ellipse.color, ellipse.reverse), canvas: &canvas) { mask in
                ShapePainter.ellipse(x: 0, y: 0, width: size.0, height: size.1, thickness: ellipse.thickness,
                                     into: &mask)
            }
        case .diagonal(let diagonal):
            let size = (max(1, diagonal.width), max(1, diagonal.height))
            paintField(size: size, ink: nil, origin: diagonal.origin, orientation: .normal,
                       mode: mode(diagonal.color, diagonal.reverse), canvas: &canvas) { mask in
                ShapePainter.diagonal(x: 0, y: 0, width: size.0, height: size.1, thickness: diagonal.thickness,
                                      leansRight: diagonal.leansRight, into: &mask)
            }
        case .graphic(let graphic):
            let mx = max(1, graphic.magnificationX), my = max(1, graphic.magnificationY)
            let size = (graphic.bitmap.width * mx, graphic.bitmap.height * my)
            paintField(size: size, ink: nil, origin: graphic.origin, orientation: .normal,
                       mode: graphic.reverse ? .reverse : .black, canvas: &canvas) { mask in
                drawBitmap(graphic.bitmap, magnificationX: mx, magnificationY: my, into: &mask)
            }
        case .linearBarcode(let barcode):
            let layout = LinearBarcodeLayout(barcode)
            let ink = IntRect(x: layout.inkMinX, y: 0, width: layout.inkMaxX - layout.inkMinX,
                              height: layout.height + layout.guardExtension)
            paintField(size: (layout.width, layout.height), ink: ink, origin: barcode.origin,
                       orientation: barcode.orientation, mode: barcode.reverse ? .reverse : .black,
                       canvas: &canvas) { mask in
                drawLinear(layout, into: &mask, glyphs: &glyphs)
            }
        case .matrixBarcode(let barcode):
            let module = max(1, barcode.moduleSize)
            let matrix = barcode.matrix
            let size = (matrix.width * module, matrix.height * module)
            paintField(size: size, ink: nil, origin: barcode.origin, orientation: barcode.orientation,
                       mode: barcode.reverse ? .reverse : .black, canvas: &canvas) { mask in
                drawMatrix(matrix, module: module, into: &mask)
            }
        }
    }

    private static func mode(_ color: LineColor, _ reverse: Bool) -> CompositeMode {
        if reverse { return .reverse }
        return color == .white ? .white : .black
    }

    /// Zeichnet ein Feld: sichtbaren Ausschnitt bestimmen, in Feldkoordinaten malen, drehen, übertragen.
    ///
    /// - Parameters:
    ///   - size: ungedrehte Feldgröße (bestimmt zusammen mit `origin` die Drehgeometrie).
    ///   - ink: Bereich in Feldkoordinaten, in dem gezeichnet werden kann (Standard: Feldrechteck).
    static func paintField(size: (Int, Int), ink: IntRect?, origin: LabelPoint, orientation: FieldOrientation,
                           mode: CompositeMode, canvas: inout BitCanvas, paint: (inout FieldMask) -> Void) {
        let (width, height) = size
        let inkRect = ink ?? IntRect(x: 0, y: 0, width: width, height: height)
        guard !inkRect.isEmpty else { return }
        let screen = screenRect(of: inkRect, width: width, height: height, origin: origin, orientation: orientation)
        let visible = screen.intersection(canvas.bounds)
        guard !visible.isEmpty else { return }
        let clip = fieldRect(of: visible, width: width, height: height, origin: origin, orientation: orientation)
        var mask = FieldMask(clip: clip)
        paint(&mask)
        let rotated = mask.canvas.rotated(orientation)
        canvas.composite(rotated, x: visible.x, y: visible.y, mode: mode)
    }

    /// Bildet ein Rechteck in Feldkoordinaten auf das Etikett ab (Drehung im Uhrzeigersinn um
    /// das Feldrechteck `width × height`, dessen gedrehte linke obere Ecke bei `origin` liegt).
    static func screenRect(of rect: IntRect, width: Int, height: Int, origin: LabelPoint,
                           orientation: FieldOrientation) -> IntRect {
        let ox = origin.x, oy = origin.y
        switch orientation {
        case .normal:
            return IntRect(x: ox + rect.x, y: oy + rect.y, width: rect.width, height: rect.height)
        case .rotated90:
            return IntRect(x: ox + height - rect.maxY, y: oy + rect.x, width: rect.height, height: rect.width)
        case .inverted180:
            return IntRect(x: ox + width - rect.maxX, y: oy + height - rect.maxY, width: rect.width, height: rect.height)
        case .rotated270:
            return IntRect(x: ox + rect.y, y: oy + width - rect.maxX, width: rect.height, height: rect.width)
        }
    }

    /// Umkehrung von `screenRect`: Etikettenrechteck → Feldkoordinaten.
    static func fieldRect(of rect: IntRect, width: Int, height: Int, origin: LabelPoint,
                          orientation: FieldOrientation) -> IntRect {
        let ox = origin.x, oy = origin.y
        switch orientation {
        case .normal:
            return IntRect(x: rect.x - ox, y: rect.y - oy, width: rect.width, height: rect.height)
        case .rotated90:
            return IntRect(x: rect.y - oy, y: ox + height - rect.maxX, width: rect.height, height: rect.width)
        case .inverted180:
            return IntRect(x: ox + width - rect.maxX, y: oy + height - rect.maxY, width: rect.width, height: rect.height)
        case .rotated270:
            return IntRect(x: oy + width - rect.maxY, y: rect.x - ox, width: rect.height, height: rect.width)
        }
    }

    // MARK: Inhalte

    private static func drawBitmap(_ bitmap: MonoBitmap, magnificationX mx: Int, magnificationY my: Int,
                                   into mask: inout FieldMask) {
        let clip = mask.clip
        let firstRow = max(0, clip.y / my)
        let lastRow = min(bitmap.height, (clip.maxY + my - 1) / my)
        guard firstRow < lastRow else { return }
        let bpr = bitmap.bytesPerRow
        for sourceY in firstRow..<lastRow {
            var runStart: Int?
            let rowBase = sourceY * bpr
            for sourceX in 0...bitmap.width {
                let black = sourceX < bitmap.width
                    && bitmap.data[rowBase + (sourceX >> 3)] & (0x80 >> UInt8(sourceX & 7)) != 0
                if black && runStart == nil { runStart = sourceX }
                if !black, let start = runStart {
                    for dy in 0..<my {
                        mask.span(y: sourceY * my + dy, from: start * mx, to: sourceX * mx)
                    }
                    runStart = nil
                }
            }
        }
    }

    private static func drawLinear(_ layout: LinearBarcodeLayout, into mask: inout FieldMask,
                                   glyphs: inout GlyphRenderer) {
        for bar in layout.bars {
            let extra = bar.isGuard ? layout.guardExtension : 0
            mask.rect(x: bar.x, y: layout.barsY, width: bar.width, height: layout.barHeight + extra)
        }
        guard !layout.texts.isEmpty else { return }
        // Klarschrift: Schrift A, vergrößert um die Modulbreite.
        let font = TextFont(fontName: "A", height: layout.textHeight, width: layout.textCellWidth, dotsPerMM: 8)
        for run in layout.texts {
            let text = TextLayout(text: run.text, font: font, block: nil, direction: .horizontal, characterGap: 0)
            glyphs.draw(text, offsetX: run.x, offsetY: run.y, into: &mask)
        }
    }

    private static func drawMatrix(_ matrix: BitMatrix, module: Int, into mask: inout FieldMask) {
        let clip = mask.clip
        let firstRow = max(0, clip.y / module)
        let lastRow = min(matrix.height, (clip.maxY + module - 1) / module)
        guard firstRow < lastRow else { return }
        for my in firstRow..<lastRow {
            var runStart: Int?
            for mx in 0...matrix.width {
                let dark = mx < matrix.width && matrix.bits[my * matrix.width + mx]
                if dark && runStart == nil { runStart = mx }
                if !dark, let start = runStart {
                    mask.rect(x: start * module, y: my * module, width: (mx - start) * module, height: module)
                    runStart = nil
                }
            }
        }
    }
}

import Foundation

/// Skaliert Glyphen der Masterschriften auf Zielgröße und zeichnet Textlayouts.
///
/// Verfahren: Jeder Zielpunkt wird mit `ceil(1/Skalierung)` × `ceil(1/Skalierung)` Abtastpunkten
/// (1…6 je Achse) überdeckt; jeder Abtastwert ist eine bilineare Interpolation der 1-Bit-Master-
/// vorlage. Beim Verkleinern entspricht das einer Flächenmittelung, beim Vergrößern glättet die
/// Interpolation die Treppenstufen. Ein Punkt wird schwarz bei einer Deckung ≥ 50 %
/// (beim Verkleinern ≥ 42 %, damit feine Striche erhalten bleiben).
struct GlyphRenderer {

    /// Gerasterte Glyphe relativ zu Stiftpunkt (x) und Grundlinie (y).
    struct Raster {
        let offsetX: Int
        let offsetY: Int
        let width: Int
        let height: Int
        /// Zeilenweise Spannen `[start, end)` relativ zu `offsetX`.
        let spans: [[(Int, Int)]]
    }

    private struct Key: Hashable {
        let master: Int
        let character: String
        let scaleX: Int
        let scaleY: Int
    }

    private var cache: [Key: Raster] = [:]

    /// Zeichnet ein Textlayout in eine Feldmaske (optional um `offsetX`/`offsetY` verschoben).
    mutating func draw(_ layout: TextLayout, offsetX: Int = 0, offsetY: Int = 0, into mask: inout FieldMask) {
        let font = layout.font
        for placed in layout.characters {
            let penX = offsetX + Int(placed.x.rounded())
            let baseline = offsetY + Int(placed.baseline.rounded())
            if case .symbol = font.style {
                drawSymbol(placed.character, font: font, penX: penX, baseline: baseline, into: &mask)
                continue
            }
            // Grob verwerfen, wenn die Zeichenzelle vollständig außerhalb des Ausschnitts liegt.
            let reach = Int((Double(font.master.emSize) * max(font.scaleX, font.scaleY)).rounded(.up)) + 2
            if penX + reach < mask.clip.x || penX - reach > mask.clip.maxX
                || baseline + reach < mask.clip.y || baseline - reach > mask.clip.maxY {
                continue
            }
            var glyphOrigin = penX
            if case .bitmap = font.style {
                // Monospace-Vorschub auf die Matrixbreite zentrieren (der Zwischenraum folgt rechts).
                let cellWidth = Double(font.width)
                let glyphAdvance = (font.master.glyph(" ")?.advance ?? 26) * font.scaleX
                glyphOrigin = penX + Int(((cellWidth - glyphAdvance) / 2).rounded())
            }
            let glyph = font.master.resolve(placed.character)
            let extent = Self.extent(glyph, scaleX: font.scaleX, scaleY: font.scaleY)
            if extent.width * extent.height > Self.maxCachedArea {
                // Sehr große Glyphen nur im sichtbaren Ausschnitt rastern (ohne Zwischenspeicher).
                let visible = IntRect(x: mask.clip.x - glyphOrigin, y: mask.clip.y - baseline,
                                      width: mask.clip.width, height: mask.clip.height)
                let raster = Self.render(glyph, scaleX: font.scaleX, scaleY: font.scaleY, region: visible)
                blit(raster, penX: glyphOrigin, baseline: baseline, into: &mask)
            } else {
                let raster = rasterize(placed.character, master: font.master, masterID: Self.masterID(font),
                                       scaleX: font.scaleX, scaleY: font.scaleY)
                blit(raster, penX: glyphOrigin, baseline: baseline, into: &mask)
            }
        }
    }

    /// Glyphen bis zu dieser Fläche (Punkte²) werden vollständig gerastert und zwischengespeichert.
    static let maxCachedArea = 512 * 512

    /// Zielbereich einer Glyphe relativ zu Stiftpunkt und Grundlinie.
    static func extent(_ glyph: BitmapFont.Glyph, scaleX: Double, scaleY: Double) -> IntRect {
        guard !glyph.isEmpty, scaleX > 0, scaleY > 0, scaleX.isFinite, scaleY.isFinite else {
            return IntRect(x: 0, y: 0, width: 0, height: 0)
        }
        let x0 = Int((Double(glyph.left) * scaleX).rounded(.down))
        let x1 = Int((Double(glyph.left + glyph.width) * scaleX).rounded(.up))
        let y0 = Int((Double(-glyph.top) * scaleY).rounded(.down))
        let y1 = Int((Double(glyph.height - glyph.top) * scaleY).rounded(.up))
        return IntRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private static func masterID(_ font: TextFont) -> Int {
        switch font.style {
        case .scalableBold: return 0
        case .scalable, .symbol: return 1
        case .bitmap: return 2
        }
    }

    private func blit(_ raster: Raster, penX: Int, baseline: Int, into mask: inout FieldMask) {
        let top = baseline + raster.offsetY
        for row in mask.rows(top, top + raster.height) {
            let left = penX + raster.offsetX
            for span in raster.spans[row - top] {
                mask.span(y: row, from: left + span.0, to: left + span.1)
            }
        }
    }

    /// Rastert eine Glyphe in der gewünschten Skalierung (mit Zwischenspeicher).
    mutating func rasterize(_ character: Character, master: BitmapFont, masterID: Int,
                            scaleX: Double, scaleY: Double) -> Raster {
        let key = Key(master: masterID, character: String(character),
                      scaleX: Int((scaleX * 10_000).rounded()), scaleY: Int((scaleY * 10_000).rounded()))
        if let cached = cache[key] { return cached }
        let raster = Self.render(master.resolve(character), scaleX: scaleX, scaleY: scaleY)
        cache[key] = raster
        return raster
    }

    /// Rastert eine Glyphe; mit `region` (relativ zu Stift/Grundlinie) nur diesen Ausschnitt.
    static func render(_ glyph: BitmapFont.Glyph, scaleX: Double, scaleY: Double, region: IntRect? = nil) -> Raster {
        var target = extent(glyph, scaleX: scaleX, scaleY: scaleY)
        if let region { target = target.intersection(region) }
        let x0 = target.x, y0 = target.y
        let width = target.width, height = target.height
        guard width > 0, height > 0 else {
            return Raster(offsetX: 0, offsetY: 0, width: 0, height: 0, spans: [])
        }
        let samplesX = min(6, max(1, Int((1 / scaleX).rounded(.up))))
        let samplesY = min(6, max(1, Int((1 / scaleY).rounded(.up))))
        let threshold = (samplesX > 1 || samplesY > 1) ? 0.42 : 0.5
        let sampleCount = Double(samplesX * samplesY)

        func sample(_ gx: Double, _ gy: Double) -> Double {
            // Bilineare Interpolation; Pixelzentren liegen bei (i + 0,5).
            let fx = gx - 0.5, fy = gy - 0.5
            let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
            let tx = fx - Double(ix), ty = fy - Double(iy)
            let a = Double(glyph.pixel(ix, iy)), b = Double(glyph.pixel(ix + 1, iy))
            let c = Double(glyph.pixel(ix, iy + 1)), d = Double(glyph.pixel(ix + 1, iy + 1))
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }

        var spans: [[(Int, Int)]] = Array(repeating: [], count: height)
        for row in 0..<height {
            var runStart: Int?
            for column in 0..<width {
                var sum = 0.0
                for sy in 0..<samplesY {
                    let py = Double(y0 + row) + (Double(sy) + 0.5) / Double(samplesY)
                    let gy = py / scaleY + Double(glyph.top)
                    for sx in 0..<samplesX {
                        let px = Double(x0 + column) + (Double(sx) + 0.5) / Double(samplesX)
                        let gx = px / scaleX - Double(glyph.left)
                        sum += sample(gx, gy)
                    }
                }
                let on = sum / sampleCount >= threshold
                if on && runStart == nil { runStart = column }
                if !on, let start = runStart {
                    spans[row].append((start, column))
                    runStart = nil
                }
            }
            if let start = runStart { spans[row].append((start, width)) }
        }
        return Raster(offsetX: x0, offsetY: y0, width: width, height: height, spans: spans)
    }

    // MARK: Symbolschrift GS

    /// `^GS`: A = ®, B = ©, C = ™, D = UL-Prüfzeichen, E = CSA-Prüfzeichen (je eine Zelle).
    private mutating func drawSymbol(_ character: Character, font: TextFont, penX: Int, baseline: Int,
                                     into mask: inout FieldMask) {
        let cellTop = baseline - font.baseline
        let cellWidth = font.width, cellHeight = font.height
        let mapped: Character?
        switch character {
        case "A": mapped = "®"
        case "B": mapped = "©"
        case "C": mapped = "™"
        default: mapped = nil
        }
        if let mapped {
            let glyph = font.master.resolve(mapped)
            // Zeichen in die Zelle einpassen (Tintenrechteck → Zelle mit 5 % Rand).
            let scaleX = Double(cellWidth) * 0.9 / Double(max(1, glyph.width))
            let scaleY = Double(cellHeight) * 0.9 / Double(max(1, glyph.height))
            let raster = rasterize(mapped, master: font.master, masterID: 1, scaleX: scaleX, scaleY: scaleY)
            let originX = penX + cellWidth / 20 - raster.offsetX
            let originY = cellTop + cellHeight / 20 - raster.offsetY
            blit(raster, penX: originX, baseline: originY, into: &mask)
            return
        }
        guard character == "D" || character == "E" else { return }
        // Kreis mit Beschriftung.
        let stroke = max(1, min(cellWidth, cellHeight) / 12)
        ShapePainter.ellipse(x: penX, y: cellTop, width: cellWidth, height: cellHeight, thickness: stroke, into: &mask)
        let label = character == "D" ? "UL" : "CSA"
        let textHeight = max(4, cellHeight * 45 / 100)
        let inner = TextFont(fontName: "0", height: textHeight, width: textHeight, dotsPerMM: 8)
        let layout = TextLayout(text: label, font: inner, block: nil, direction: .horizontal, characterGap: 0)
        let offsetX = penX + (cellWidth - layout.width) / 2
        let offsetY = cellTop + (cellHeight - textHeight) / 2
        for placed in layout.characters {
            let raster = rasterize(placed.character, master: inner.master, masterID: 0,
                                   scaleX: inner.scaleX, scaleY: inner.scaleY)
            blit(raster, penX: offsetX + Int(placed.x.rounded()), baseline: offsetY + Int(placed.baseline.rounded()),
                 into: &mask)
        }
    }
}

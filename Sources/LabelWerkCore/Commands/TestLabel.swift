import Foundation

/// Hochwertiges Testetikett in ZPL, EPL2 und CPCL.
///
/// Inhalt (je nach Platz): Passermarken (Fadenkreuze) in allen vier Ecken, Rahmen mit
/// abgerundeten Ecken, invertierte Titelleiste mit Auflösung, Modell/Untertitel, Auflösung,
/// Datum, Format und Sprache, Code 128, QR-Code, Schwärzungsskala (zehn Stufen von der
/// Haarlinie bis zur Vollfläche) und ein Millimeterlineal, das ab der linken Etikettenkante
/// misst. Das Layout skaliert mit Breite, Höhe und Auflösung und bleibt stets innerhalb des
/// Etiketts (geprüft für 2–8 Zoll Breite und 1–12 Zoll Höhe bei 152–600 dpi).
///
/// EPL2 und CPCL nutzen residente Bitmap-Schriften und ASCII-Text (Umlaute werden
/// umschrieben); EPL2 hat keinen QR-Code, abgerundete Ecken gibt es nur in ZPL.
public enum TestLabel {

    // MARK: - Öffentliche API (Vertrag)

    /// Testetikett in ZPL II (`^XA … ^XZ`, UTF-8 mit `^CI28`).
    public static func zpl(widthDots: Int, heightDots: Int, resolution: Resolution,
                           title: String = "LabelWerk", subtitle: String = "") -> String {
        zpl(widthDots: widthDots, heightDots: heightDots, resolution: resolution, title: title,
            subtitle: subtitle, date: Date(), timeZone: .current)
    }

    /// Testetikett in EPL2 (Zeilenende `\n`, nur ASCII).
    public static func epl(widthDots: Int, heightDots: Int, resolution: Resolution,
                           title: String = "LabelWerk") -> String {
        epl(widthDots: widthDots, heightDots: heightDots, resolution: resolution, title: title,
            subtitle: "", date: Date(), timeZone: .current)
    }

    /// Testetikett in CPCL (Zeilenende `\r\n`, nur ASCII).
    public static func cpcl(widthDots: Int, heightDots: Int, resolution: Resolution,
                            title: String = "LabelWerk") -> String {
        cpcl(widthDots: widthDots, heightDots: heightDots, resolution: resolution, title: title,
             subtitle: "", date: Date(), timeZone: .current)
    }

    // MARK: - Erweiterte API (reproduzierbares Datum)

    /// Wie ``zpl(widthDots:heightDots:resolution:title:subtitle:)``, mit festem Druckdatum.
    public static func zpl(widthDots: Int, heightDots: Int, resolution: Resolution, title: String = "LabelWerk",
                           subtitle: String = "", date: Date, timeZone: TimeZone = .current) -> String {
        let layout = TestLabelLayout.make(widthDots: widthDots, heightDots: heightDots, resolution: resolution,
                                          title: title, subtitle: subtitle, date: date, timeZone: timeZone,
                                          style: .zpl(resolution))
        return ZPLTestLabelRenderer.render(layout, resolution: resolution, style: .zpl(resolution))
    }

    /// Wie ``epl(widthDots:heightDots:resolution:title:)``, mit Untertitel und festem Druckdatum.
    public static func epl(widthDots: Int, heightDots: Int, resolution: Resolution, title: String = "LabelWerk",
                           subtitle: String = "", date: Date, timeZone: TimeZone = .current) -> String {
        let style = TestLabelLayout.Style.epl(resolution)
        let layout = TestLabelLayout.make(widthDots: widthDots, heightDots: heightDots, resolution: resolution,
                                          title: title, subtitle: subtitle, date: date, timeZone: timeZone,
                                          style: style)
        return EPLTestLabelRenderer.render(layout, resolution: resolution, style: style)
    }

    /// Wie ``cpcl(widthDots:heightDots:resolution:title:)``, mit Untertitel und festem Druckdatum.
    public static func cpcl(widthDots: Int, heightDots: Int, resolution: Resolution, title: String = "LabelWerk",
                            subtitle: String = "", date: Date, timeZone: TimeZone = .current) -> String {
        let style = TestLabelLayout.Style.cpcl(resolution)
        let layout = TestLabelLayout.make(widthDots: widthDots, heightDots: heightDots, resolution: resolution,
                                          title: title, subtitle: subtitle, date: date, timeZone: timeZone,
                                          style: style)
        return CPCLTestLabelRenderer.render(layout, resolution: resolution, style: style)
    }
}

// MARK: - Textanpassung

/// Eine verfügbare Schriftgröße einer Sprache.
struct FontOption: Hashable, Sendable {
    /// Schrifthöhe in Punkten.
    var height: Int
    /// Zeichenvorschub in Punkten.
    var advance: Double
    /// Sprachspezifische Kennung (EPL: Schrift, CPCL: Vergrößerung).
    var font: String
    var multiplier: Int

    func width(of text: String) -> Int { Int((Double(text.count) * advance).rounded(.up)) }
}

enum TextFitter {
    /// Wählt Variante und Schrift so, dass der Text in `rect` passt; kürzt im Notfall mit `ellipsis`.
    ///
    /// - Parameter options: Schriftgrößen absteigend nach Höhe.
    static func fit(_ variants: [String], width: Int, height: Int, options: [FontOption],
                    ellipsis: String) -> (text: String, font: FontOption)? {
        let usable = options.filter { $0.height <= height }
        guard let largest = usable.first, !variants.isEmpty else { return nil }
        // 1. Große Schrift (≥ 70 % der größten) mit der ausführlichsten passenden Variante.
        for option in usable where Double(option.height) >= Double(largest.height) * 0.7 {
            if let variant = variants.first(where: { option.width(of: $0) <= width }) { return (variant, option) }
        }
        // 2. Jede Variante in jeder Größe.
        for variant in variants {
            if let option = usable.first(where: { $0.width(of: variant) <= width }) { return (variant, option) }
        }
        // 3. Kürzen in der kleinsten Größe.
        guard let smallest = usable.last, let shortest = variants.min(by: { $0.count < $1.count }) else { return nil }
        let capacity = Int(Double(width) / smallest.advance)
        guard capacity > ellipsis.count else { return nil }
        return (String(shortest.prefix(capacity - ellipsis.count)) + ellipsis, smallest)
    }
}

// MARK: - ZPL

enum ZPLTestLabelRenderer {
    static func render(_ layout: TestLabelLayout, resolution: Resolution, style: TestLabelLayout.Style) -> String {
        let width = max(1, layout.widthDots)
        let height = max(1, layout.heightDots)
        var commands: [ZPLCommand] = [
            ZPL.comment("LabelWerk Testetikett \(width) x \(height) Punkte, \(resolution.dpi) dpi"),
            ZPL.changeEncoding(),
            ZPL.printWidth(width),
            ZPL.labelLength(height),
            ZPL.labelHome(x: 0, y: 0),
        ]
        for element in layout.elements {
            commands += self.commands(for: element, style: style)
        }
        commands.append(ZPL.printQuantity(1))
        return ZPL.format { commands }
    }

    static func options(maxHeight: Int, style: TestLabelLayout.Style) -> [FontOption] {
        guard maxHeight >= style.minimumTextHeight else { return [] }
        let step = max(1, maxHeight / 24)
        return stride(from: maxHeight, through: style.minimumTextHeight, by: -step).map {
            FontOption(height: $0, advance: Double($0) * style.charWidthFactor, font: "0", multiplier: 1)
        }
    }

    private static func commands(for element: TestLabelLayout.Element, style: TestLabelLayout.Style) -> [ZPLCommand] {
        switch element {
        case .frame(let r, let thickness, let rounding):
            return [ZPL.fieldOrigin(x: r.x, y: r.y),
                    ZPL.graphicBox(width: r.width, height: r.height, thickness: thickness, rounding: rounding),
                    ZPL.fieldSeparator()]
        case .fill(let r):
            return [ZPL.fieldOrigin(x: r.x, y: r.y),
                    ZPL.graphicBox(width: r.width, height: r.height, thickness: min(r.width, r.height)),
                    ZPL.fieldSeparator()]
        case .titleBar(let r, let rounding):
            return [ZPL.fieldOrigin(x: r.x, y: r.y),
                    ZPL.graphicBox(width: r.width, height: r.height, thickness: min(r.width, r.height), rounding: rounding),
                    ZPL.fieldSeparator()]
        case .gradientBox(let r, let thickness):
            return [ZPL.fieldOrigin(x: r.x, y: r.y),
                    ZPL.graphicBox(width: r.width, height: r.height, thickness: thickness),
                    ZPL.fieldSeparator()]
        case .circle(let r, let thickness):
            return [ZPL.fieldOrigin(x: r.x, y: r.y),
                    ZPL.graphicCircle(diameter: r.width, thickness: thickness),
                    ZPL.fieldSeparator()]
        case .text(let slot):
            guard let fitted = TextFitter.fit(slot.variants, width: slot.rect.width, height: slot.rect.height,
                                              options: options(maxHeight: slot.rect.height, style: style),
                                              ellipsis: "…") else { return [] }
            let h = fitted.font.height
            var commands = [
                ZPL.fieldOrigin(x: slot.rect.x, y: slot.rect.y + (slot.rect.height - h) / 2),
                ZPL.font("0", height: h, width: h),
                ZPL.fieldBlock(width: slot.rect.width, maxLines: 1, justification: slot.alignment.rawValue),
            ]
            if slot.reversed { commands.append(ZPL.fieldReverse()) }
            commands += ZPL.fieldData(fitted.text)
            commands.append(ZPL.fieldSeparator())
            return commands
        case .code128(let r, let data, let moduleWidth):
            return [ZPL.barcodeDefaults(moduleWidth: moduleWidth, ratio: 3.0, height: r.height),
                    ZPL.fieldOrigin(x: r.x, y: r.y),
                    ZPL.code128(height: r.height, printInterpretation: false)]
                + ZPL.fieldData(data) + [ZPL.fieldSeparator()]
        case .qr(let r, let data, let magnification):
            return [ZPL.fieldOrigin(x: r.x, y: r.y), ZPL.qrCode(magnification: magnification, errorCorrection: "M")]
                + ZPL.qrFieldData(data, errorCorrection: "M") + [ZPL.fieldSeparator()]
        }
    }
}

// MARK: - EPL2

enum EPLTestLabelRenderer {
    /// Residente EPL-Schriften 1–4: (Zeichenbreite, Höhe) in Punkten.
    static func baseFonts(_ resolution: Resolution) -> [(font: String, width: Int, height: Int, spacing: Int)] {
        if resolution.dpi >= 300 {
            return [("1", 12, 20, 4), ("2", 16, 28, 4), ("3", 20, 36, 4), ("4", 24, 44, 4)]
        }
        return [("1", 8, 12, 2), ("2", 10, 16, 2), ("3", 12, 20, 2), ("4", 14, 24, 2)]
    }

    static func options(maxHeight: Int, resolution: Resolution) -> [FontOption] {
        var result: [FontOption] = []
        for base in baseFonts(resolution) {
            for multiplier in 1...6 where base.height * multiplier <= maxHeight {
                result.append(FontOption(height: base.height * multiplier,
                                         advance: Double((base.width + base.spacing) * multiplier),
                                         font: base.font, multiplier: multiplier))
            }
        }
        // Absteigend nach Höhe, bei gleicher Höhe die schmalere Schrift zuerst.
        return result.sorted { $0.height != $1.height ? $0.height > $1.height : $0.advance < $1.advance }
    }

    static func render(_ layout: TestLabelLayout, resolution: Resolution, style: TestLabelLayout.Style) -> String {
        var lines: [String] = [EPL.labelWidth(max(1, layout.widthDots))]
        var pendingBar: TestLabelLayout.Rect?
        for element in layout.elements {
            if case .text(let slot) = element, slot.reversed {
                // Titeltext wird schwarz gedruckt und anschließend per XOR invertiert.
            } else if let bar = pendingBar {
                lines.append(EPL.lineXOR(x: bar.x, y: bar.y, width: bar.width, height: bar.height))
                pendingBar = nil
            }
            switch element {
            case .frame(let r, let thickness, _):
                lines.append(EPL.box(x1: r.x, y1: r.y, thickness: thickness,
                                     x2: r.maxX - thickness, y2: r.maxY - thickness))
            case .fill(let r):
                lines.append(EPL.lineBlack(x: r.x, y: r.y, width: r.width, height: r.height))
            case .titleBar(let r, _):
                pendingBar = r
            case .gradientBox(let r, let thickness):
                if thickness * 2 >= min(r.width, r.height) {
                    lines.append(EPL.lineBlack(x: r.x, y: r.y, width: r.width, height: r.height))
                } else {
                    lines.append(EPL.box(x1: r.x, y1: r.y, thickness: thickness,
                                         x2: r.maxX - thickness, y2: r.maxY - thickness))
                }
            case .circle:
                break
            case .text(let slot):
                let variants = slot.variants.map(EPL.transliterated)
                guard let fitted = TextFitter.fit(variants, width: slot.rect.width, height: slot.rect.height,
                                                  options: options(maxHeight: slot.rect.height, resolution: resolution),
                                                  ellipsis: "...") else { continue }
                let textWidth = fitted.font.width(of: fitted.text)
                let x: Int
                switch slot.alignment {
                case .left: x = slot.rect.x
                case .center: x = slot.rect.x + max(0, (slot.rect.width - textWidth) / 2)
                case .right: x = slot.rect.x + max(0, slot.rect.width - textWidth)
                }
                lines.append(EPL.text(fitted.text, x: x, y: slot.rect.y + (slot.rect.height - fitted.font.height) / 2,
                                      font: fitted.font.font, horizontalMultiplier: fitted.font.multiplier,
                                      verticalMultiplier: fitted.font.multiplier))
            case .code128(let r, let data, let moduleWidth):
                lines.append(EPL.barcode(data, x: r.x, y: r.y, type: .code128, narrowBar: moduleWidth,
                                         wideBar: moduleWidth * 2, height: r.height, humanReadable: false))
            case .qr:
                break
            }
        }
        if let bar = pendingBar {
            lines.append(EPL.lineXOR(x: bar.x, y: bar.y, width: bar.width, height: bar.height))
        }
        return EPL.lineEnding + EPL.render([EPL.clearImageBuffer()] + lines + [EPL.print(1)])
    }
}

// MARK: - CPCL

enum CPCLTestLabelRenderer {
    /// Schrift 7, Größe 0 (12 × 24 Punkte) mit `SETMAG`-Vergrößerung 1…8.
    static func options(maxHeight: Int) -> [FontOption] {
        (1...8).reversed().compactMap { magnification in
            let height = 24 * magnification
            guard height <= maxHeight else { return nil }
            return FontOption(height: height, advance: Double(13 * magnification), font: "7", multiplier: magnification)
        }
    }

    static func render(_ layout: TestLabelLayout, resolution: Resolution, style: TestLabelLayout.Style) -> String {
        var lines: [String] = [
            CPCL.header(resolution: resolution, height: max(1, layout.heightDots), quantity: 1),
            CPCL.pageWidth(max(1, layout.widthDots)),
        ]
        var magnification = 1
        var pendingBar: TestLabelLayout.Rect?
        func flushBar() {
            if let bar = pendingBar {
                lines.append(CPCL.inverseLine(x0: bar.x, y0: bar.y, x1: bar.maxX - 1, y1: bar.y, thickness: bar.height))
                pendingBar = nil
            }
        }
        func fill(_ r: TestLabelLayout.Rect) {
            if r.width >= r.height {
                lines.append(CPCL.line(x0: r.x, y0: r.y, x1: r.maxX - 1, y1: r.y, thickness: r.height))
            } else {
                lines.append(CPCL.line(x0: r.x, y0: r.y, x1: r.x, y1: r.maxY - 1, thickness: r.width))
            }
        }
        for element in layout.elements {
            if case .text(let slot) = element, slot.reversed {
                // Titeltext zuerst zeichnen; INVERSE-LINE invertiert ihn danach.
            } else {
                flushBar()
            }
            switch element {
            case .frame(let r, let thickness, _):
                lines.append(CPCL.box(x0: r.x, y0: r.y, x1: r.maxX - thickness, y1: r.maxY - thickness,
                                      thickness: thickness))
            case .fill(let r):
                fill(r)
            case .titleBar(let r, _):
                pendingBar = r
            case .gradientBox(let r, let thickness):
                if thickness * 2 >= min(r.width, r.height) {
                    fill(r)
                } else {
                    lines.append(CPCL.box(x0: r.x, y0: r.y, x1: r.maxX - thickness, y1: r.maxY - thickness,
                                          thickness: thickness))
                }
            case .circle:
                break
            case .text(let slot):
                let variants = slot.variants.map(CPCL.transliterated)
                guard let fitted = TextFitter.fit(variants, width: slot.rect.width, height: slot.rect.height,
                                                  options: options(maxHeight: slot.rect.height),
                                                  ellipsis: "...") else { continue }
                if fitted.font.multiplier != magnification {
                    magnification = fitted.font.multiplier
                    lines.append(CPCL.setMagnification(width: magnification, height: magnification))
                }
                let textWidth = fitted.font.width(of: fitted.text)
                let x: Int
                switch slot.alignment {
                case .left: x = slot.rect.x
                case .center: x = slot.rect.x + max(0, (slot.rect.width - textWidth) / 2)
                case .right: x = slot.rect.x + max(0, slot.rect.width - textWidth)
                }
                lines.append(CPCL.text(fitted.text, font: "7", size: 0, x: x,
                                       y: slot.rect.y + (slot.rect.height - fitted.font.height) / 2))
            case .code128(let r, let data, let moduleWidth):
                lines.append(CPCL.barcode(data, type: .code128, x: r.x, y: r.y, height: r.height,
                                          narrowBar: moduleWidth, ratio: 1))
            case .qr(let r, let data, let magnificationQR):
                lines.append(CPCL.qrCode(data, x: r.x, y: r.y, model: 2, unitSize: magnificationQR, errorCorrection: "M"))
            }
        }
        flushBar()
        if magnification != 1 { lines.append(CPCL.setMagnification(width: 0, height: 0)) }
        lines.append(CPCL.form())
        lines.append(CPCL.print())
        return CPCL.render(lines)
    }
}

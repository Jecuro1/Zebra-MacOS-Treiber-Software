import Foundation

/// Sprachunabhängiges Layout des Testetiketts.
///
/// Das Layout arbeitet ausschließlich in Druckerpunkten und passt sich Breite, Höhe und
/// Auflösung an: Auf kleinen Etiketten werden Elemente nach Priorität weggelassen
/// (Titel → Lineal → Info → Barcodes → Schwärzungsskala → weitere Info), auf großen Etiketten
/// wachsen Barcodes und Abstände. Alle Elemente liegen garantiert innerhalb des Etiketts.
struct TestLabelLayout: Sendable {

    // MARK: Bausteine

    struct Rect: Hashable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var maxX: Int { x + width }
        var maxY: Int { y + height }

        func contains(_ other: Rect) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }

        func intersects(_ other: Rect) -> Bool {
            x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
        }
    }

    enum Alignment: String, Sendable {
        case left = "L"
        case center = "C"
        case right = "R"
    }

    struct TextSlot: Hashable, Sendable {
        /// Verfügbare Fläche; die Schrift wird so gewählt, dass sie hineinpasst (vertikal zentriert).
        var rect: Rect
        /// Textvarianten von ausführlich bis knapp.
        var variants: [String]
        var alignment: Alignment
        /// Weiß auf schwarz (in der Titelleiste).
        var reversed: Bool
    }

    enum Element: Hashable, Sendable {
        /// Rahmen mit Linienstärke und ZPL-Rundung (0…8).
        case frame(Rect, thickness: Int, rounding: Int)
        /// Gefüllte Fläche (Linien, Skalenstriche).
        case fill(Rect)
        /// Gefüllte Titelleiste; Texte mit `reversed == true` folgen unmittelbar.
        case titleBar(Rect, rounding: Int)
        /// Kreis (Passermarke).
        case circle(Rect, thickness: Int)
        /// Rahmen einer Schwärzungsstufe mit Linienstärke (`thickness ≥ min(w,h)/2` = gefüllt).
        case gradientBox(Rect, thickness: Int)
        case text(TextSlot)
        /// Code 128 (Teilmenge B); `rect.height` = Balkenhöhe.
        case code128(Rect, data: String, moduleWidth: Int)
        /// QR-Code Modell 2, Fehlerkorrektur M; `rect` = Symbolfläche.
        case qr(Rect, data: String, magnification: Int)

        var rect: Rect {
            switch self {
            case .frame(let r, _, _), .fill(let r), .titleBar(let r, _), .circle(let r, _),
                 .gradientBox(let r, _), .code128(let r, _, _), .qr(let r, _, _):
                return r
            case .text(let slot):
                return slot.rect
            }
        }
    }

    /// Fähigkeiten und Schriftmaße der Zielsprache.
    struct Style: Sendable {
        var language: PrinterLanguage
        /// Kleinste darstellbare Schrifthöhe in Punkten.
        var minimumTextHeight: Int
        /// Geschätzte Zeichenbreite relativ zur Schrifthöhe (für die Platzplanung).
        var charWidthFactor: Double
        var supportsQR: Bool
        var supportsRounding: Bool
        var supportsCircle: Bool
        var maxQRMagnification: Int
        /// Schrifthöhen (Punkte) für die Schriftproben – exakt darstellbare Größen der Sprache.
        var sampleHeights: [Int]

        static func zpl(_ resolution: Resolution) -> Style {
            Style(language: .zpl, minimumTextHeight: max(12, Int((1.6 * resolution.exactDotsPerMM).rounded())),
                  charWidthFactor: 0.6, supportsQR: true, supportsRounding: true, supportsCircle: true,
                  maxQRMagnification: 10,
                  sampleHeights: [2.0, 3.0, 4.0, 6.0].map { Int(($0 * resolution.exactDotsPerMM).rounded()) })
        }

        static func epl(_ resolution: Resolution) -> Style {
            let fonts = EPLTestLabelRenderer.baseFonts(resolution)
            return Style(language: .epl, minimumTextHeight: fonts[0].height,
                         charWidthFactor: 0.85, supportsQR: false, supportsRounding: false, supportsCircle: false,
                         maxQRMagnification: 0,
                         sampleHeights: fonts.map(\.height) + [fonts[fonts.count - 1].height * 2])
        }

        static func cpcl(_ resolution: Resolution) -> Style {
            Style(language: .cpcl, minimumTextHeight: 24, charWidthFactor: 0.56, supportsQR: true,
                  supportsRounding: false, supportsCircle: false, maxQRMagnification: 32,
                  sampleHeights: [24, 48, 72])
        }
    }

    var widthDots: Int
    var heightDots: Int
    var elements: [Element]

    // MARK: - Aufbau

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func make(widthDots: Int, heightDots: Int, resolution: Resolution, title: String, subtitle: String,
                     date: Date, timeZone: TimeZone, style: Style) -> TestLabelLayout {
        let W = max(0, widthDots)
        let H = max(0, heightDots)
        var layout = TestLabelLayout(widthDots: W, heightDots: H, elements: [])
        let dpmm = resolution.exactDotsPerMM
        func d(_ mm: Double) -> Int { Int((mm * dpmm).rounded()) }
        func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

        let stamp = DateStamp(date: date, timeZone: timeZone)
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "LabelWerk" : title
        let minText = style.minimumTextHeight
        guard W >= 8, H >= 8 else { return layout }

        // Winzige Etiketten: nur Titel.
        guard W >= minText * 4, H >= minText + 4 else {
            layout.elements = [.text(TextSlot(rect: Rect(x: 0, y: 0, width: W, height: min(H, minText * 2)),
                                              variants: [titleText], alignment: .left, reversed: false))]
            return layout
        }

        let wMM = Double(W) / dpmm
        let hMM = Double(H) / dpmm
        let k = clampD(min(wMM, hMM) / 50, 0.6, 1.0)

        // --- Passermarken (Fadenkreuze in den Ecken) ---------------------------------------
        let markLine = max(1, d(0.25))
        let markCenter = max(3, d(1.6 * k))
        let markArm = max(2, min(markCenter, d(1.2 * k)))
        let inset = max(markCenter + markArm + 2, d(3.4 * k))
        let borderThickness = max(2, d(0.5))
        let borderWidth = W - 2 * inset
        let borderHeight = H - 2 * inset
        guard borderWidth > 4 * borderThickness + minText, borderHeight > 2 * borderThickness + minText else {
            layout.elements = [.text(TextSlot(rect: Rect(x: 0, y: 0, width: W, height: min(H, minText * 2)),
                                              variants: [titleText], alignment: .left, reversed: false))]
            return layout
        }

        var elements: [Element] = []
        let centers = [
            (markCenter, markCenter), (W - 1 - markCenter, markCenter),
            (markCenter, H - 1 - markCenter), (W - 1 - markCenter, H - 1 - markCenter),
        ]
        for (cx, cy) in centers {
            elements.append(.fill(Rect(x: cx - markArm, y: cy - markLine / 2, width: 2 * markArm + 1, height: markLine)))
            elements.append(.fill(Rect(x: cx - markLine / 2, y: cy - markArm, width: markLine, height: 2 * markArm + 1)))
            if style.supportsCircle {
                let diameter = max(3, markArm * 13 / 10)
                elements.append(.circle(Rect(x: cx - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter),
                                        thickness: markLine))
            }
        }

        // --- Rahmen ----------------------------------------------------------------------
        let shorter = min(borderWidth, borderHeight)
        let rounding = style.supportsRounding ? (shorter >= d(20) ? 1 : 2) : 0
        let radius = Double(rounding) * Double(shorter) / 16
        elements.append(.frame(Rect(x: inset, y: inset, width: borderWidth, height: borderHeight),
                               thickness: borderThickness, rounding: rounding))

        let pad = max(d(1.4 * k), Int(0.3 * radius) + d(0.6))
        let left = inset + borderThickness + pad
        let top = left
        let right = W - left
        let bottom = H - top
        let cw = right - left
        let ch = bottom - top
        guard cw >= minText * 3, ch >= minText + 2 else {
            layout.elements = elements
            return layout
        }

        // --- Maße ------------------------------------------------------------------------
        // u: Breitenmaßstab (Schriften), g: Grafikmaßstab (wächst auf hohen Etiketten mit).
        let cwMM = Double(cw) / dpmm
        let chMM = Double(ch) / dpmm
        let u = clampD(min(cwMM / 90, chMM / 60), 0.45, 2.0)
        let g = clampD(min(cwMM / 90 * 1.6, chMM / 60), 0.45, 2.0)
        let gap = max(2, d(clampD(1.6 * u, 0.8, 3)))

        var titleHeight = max(d(clampD(8 * g, 4.5, 12)), minText + max(4, d(1)))
        titleHeight = min(titleHeight, ch)

        let tickWidth = max(1, d(0.18))
        let tickMinor = max(3, d(clampD(1.1 * u, 0.8, 2)))
        let tickMid = tickMinor * 16 / 10
        let tickMajor = tickMinor * 22 / 10
        let digitHeight = max(minText, d(clampD(2.2 * u, 1.8, 3.5)))
        let digitGap = max(1, d(0.4))
        let rulerHeight = digitHeight + digitGap + tickMajor + tickWidth

        // Infozeilen: so groß, dass eine Zeile mit ~36 Zeichen noch in die Breite passt.
        let infoWidthLimit = Int(Double(cw) / (36 * style.charWidthFactor))
        let infoHeight = max(minText, min(d(clampD(3.4 * g, 2.2, 5.5)), infoWidthLimit))
        let infoPitch = infoHeight + max(2, infoHeight * 3 / 10)

        let gradientHeight = max(d(2.5), d(clampD(5 * g, 2.5, 9)))
        let headBarHeight = max(d(2), d(clampD(2.5 * g, 2, 4)))

        let moduleWidth = max(1, d(0.25))
        let hrHeight = max(minText, d(clampD(2.4 * u, 1.8, 4)))
        let hrGap = max(1, d(0.6))
        let codeMinHeight = d(6)
        let codeMaxHeight = max(codeMinHeight, d(clampD(20 * g, 10, 45)))

        let infoVariants = makeInfoVariants(resolution: resolution, widthDots: W, heightDots: H, subtitle: subtitle,
                                            stamp: stamp, language: style.language)
        let sampleSizes = style.sampleHeights.filter { $0 >= minText && $0 <= d(clampD(6 * u, 3, 8)) }
        let sampleGap = max(2, d(0.8))
        let samplesHeight = sampleSizes.reduce(0) { $0 + $1 + sampleGap } - (sampleSizes.isEmpty ? 0 : sampleGap)

        // --- Platzvergabe nach Priorität -------------------------------------------------
        var remaining = ch - titleHeight
        func take(_ height: Int) -> Bool {
            if height > 0, remaining >= height + gap {
                remaining -= height + gap
                return true
            }
            return false
        }
        let hasRuler = take(rulerHeight)
        let hasCode = take(codeMinHeight)
        var infoCount = take(infoHeight) ? 1 : 0
        let hasGradient = take(gradientHeight)
        var codeHeight = codeMinHeight
        while infoCount > 0, infoCount < min(3, infoVariants.count), remaining >= infoPitch {
            remaining -= infoPitch
            infoCount += 1
        }
        if hasCode {
            let growth = min(codeMaxHeight - codeMinHeight, remaining * 6 / 10)
            codeHeight += max(0, growth)
            remaining -= max(0, growth)
        }
        while infoCount > 0, infoCount < infoVariants.count, remaining >= infoPitch {
            remaining -= infoPitch
            infoCount += 1
        }
        let hasHeadBar = hasGradient && take(headBarHeight)
        let hasSamples = hasHeadBar && remaining >= (samplesHeight + gap) * 2 && take(samplesHeight)

        // Restfläche gleichmäßig auf die Abstände verteilen (höchstens 12 mm je Abstand);
        // was dann noch frei ist, zentriert die mittleren Blöcke zwischen Titel und Lineal.
        let middleBlocks = [infoCount > 0, hasCode, hasGradient, hasHeadBar, hasSamples].filter { $0 }.count
        let gapSlots = middleBlocks + (hasRuler ? 1 : 0)
        var extraPerGap = 0
        if gapSlots > 0 {
            extraPerGap = min(remaining / gapSlots, d(12))
            remaining -= extraPerGap * gapSlots
        }
        let blockGap = gap + extraPerGap
        let centeringOffset = middleBlocks > 0 && hasRuler ? remaining / 2 : 0

        // --- Titelleiste -----------------------------------------------------------------
        let titleRect = Rect(x: left, y: top, width: cw, height: titleHeight)
        elements.append(.titleBar(titleRect, rounding: style.supportsRounding ? 4 : 0))
        let titleTextHeight = max(minText, min(titleHeight - 2, titleHeight * 62 / 100))
        let paddingX = max(d(1.5), titleHeight * 35 / 100)
        let badgeText = "\(resolution.dpi) dpi"
        let badgeHeight = max(minText, min(titleTextHeight, titleTextHeight * 72 / 100))
        let badgeWidth = Int((Double(badgeText.count) * style.charWidthFactor * Double(badgeHeight)).rounded(.up)) + 2
        var titleSlotWidth = cw - 2 * paddingX
        var badgeSlot: TextSlot?
        if titleSlotWidth - badgeWidth - gap >= cw * 45 / 100 {
            titleSlotWidth -= badgeWidth + gap
            badgeSlot = TextSlot(
                rect: Rect(x: right - paddingX - badgeWidth, y: top + (titleHeight - badgeHeight) / 2,
                           width: badgeWidth, height: badgeHeight),
                variants: [badgeText], alignment: .right, reversed: true)
        }
        if titleSlotWidth > minText {
            elements.append(.text(TextSlot(
                rect: Rect(x: left + paddingX, y: top + (titleHeight - titleTextHeight) / 2,
                           width: titleSlotWidth, height: titleTextHeight),
                variants: [titleText], alignment: .left, reversed: true)))
        }
        if let badgeSlot { elements.append(.text(badgeSlot)) }

        // --- Mittlere Blöcke -------------------------------------------------------------
        var y = top + titleHeight + blockGap + centeringOffset

        for index in 0..<infoCount {
            let lineY = y + index * infoPitch
            elements.append(.text(TextSlot(rect: Rect(x: left, y: lineY, width: cw, height: infoHeight),
                                           variants: infoVariants[index], alignment: .left, reversed: false)))
        }
        if infoCount > 0 { y += (infoCount - 1) * infoPitch + infoHeight + blockGap }

        if hasCode {
            elements += makeCodeRow(left: left, top: y, width: cw, height: codeHeight, moduleWidth: moduleWidth,
                                    hrHeight: hrHeight, hrGap: hrGap, columnGap: max(gap, d(3)), resolution: resolution,
                                    widthDots: W, heightDots: H, title: titleText, stamp: stamp, style: style,
                                    sideInfo: Array(infoVariants.dropFirst(infoCount)), infoHeight: infoHeight,
                                    infoPitch: infoPitch)
            y += codeHeight + blockGap
        }

        if hasGradient {
            elements += makeGradient(left: left, top: y, width: cw, height: gradientHeight, gap: max(2, d(0.8 * u)),
                                     minBoxWidth: max(3, d(2)))
            y += gradientHeight + blockGap
        }

        if hasHeadBar {
            // Vollfläche über die ganze Breite: ausgefallene Heizelemente erscheinen als weiße Linien.
            elements.append(.fill(Rect(x: left, y: y, width: cw, height: headBarHeight)))
            y += headBarHeight + blockGap
        }

        if hasSamples {
            for height in sampleSizes {
                let label = TestLabelLayout.decimalComma(Double(height) / dpmm).replacingOccurrences(of: ",0", with: "")
                elements.append(.text(TextSlot(
                    rect: Rect(x: left, y: y, width: cw, height: height),
                    variants: ["\(label) mm · AaBbCc 0123456789 ÄÖÜ äöü ß €", "\(label) mm · AaBbCc 0123456789",
                               "\(label) mm · AaBb 0123", "\(label) mm"],
                    alignment: .left, reversed: false)))
                y += height + sampleGap
            }
            y += blockGap - sampleGap
        }

        // --- Lineal (unten verankert) ----------------------------------------------------
        if hasRuler {
            let baselineY = bottom - tickWidth
            let rulerTop = bottom - rulerHeight
            elements.append(.fill(Rect(x: left, y: baselineY, width: cw, height: tickWidth)))
            var numberSlots: [Rect] = []
            var millimetre = 0
            while true {
                let x = Int((Double(millimetre) * dpmm).rounded())
                if x + tickWidth > right { break }
                if x >= left {
                    let length = millimetre % 10 == 0 ? tickMajor : (millimetre % 5 == 0 ? tickMid : tickMinor)
                    elements.append(.fill(Rect(x: x, y: baselineY - length, width: tickWidth, height: length)))
                    if millimetre % 10 == 0, millimetre > 0 {
                        let label = "\(millimetre)"
                        let numberWidth = Int((Double(label.count) * style.charWidthFactor * Double(digitHeight)).rounded(.up)) + 4
                        let centerX = x + tickWidth / 2
                        let slot = Rect(x: centerX - numberWidth / 2, y: rulerTop, width: numberWidth, height: digitHeight)
                        if slot.x >= left, slot.maxX <= right {
                            numberSlots.append(slot)
                            elements.append(.text(TextSlot(rect: slot, variants: [label], alignment: .center,
                                                           reversed: false)))
                        }
                    }
                }
                millimetre += 1
            }
            // Einheit links, falls frei.
            let unitWidth = Int((2.0 * max(style.charWidthFactor, 0.9) * Double(digitHeight)).rounded(.up)) + 4
            let unitSlot = Rect(x: left, y: rulerTop, width: unitWidth, height: digitHeight)
            if unitSlot.maxX <= right, !numberSlots.contains(where: { $0.intersects(unitSlot) }) {
                elements.append(.text(TextSlot(rect: unitSlot, variants: ["mm"], alignment: .left, reversed: false)))
            }
        }

        layout.elements = elements
        return layout
    }

    // MARK: - Teilblöcke

    private static func makeInfoVariants(resolution: Resolution, widthDots: Int, heightDots: Int, subtitle: String,
                                         stamp: DateStamp, language: PrinterLanguage) -> [[String]] {
        let wmm = decimalComma(resolution.mm(fromDots: widthDots))
        let hmm = decimalComma(resolution.mm(fromDots: heightDots))
        var lines: [[String]] = []
        let sub = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sub.isEmpty { lines.append([sub]) }
        lines.append([
            "Auflösung: \(resolution.dpi) dpi · \(resolution.dotsPerMM) Punkte/mm",
            "Auflösung: \(resolution.dpi) dpi",
            "\(resolution.dpi) dpi · \(resolution.dotsPerMM) Pkt/mm",
            "\(resolution.dpi) dpi",
        ])
        lines.append([
            "Gedruckt am \(stamp.date) um \(stamp.time) Uhr",
            "Gedruckt: \(stamp.date) \(stamp.time)",
            "\(stamp.date) \(stamp.time)",
            stamp.date,
        ])
        lines.append([
            "Format: \(wmm) × \(hmm) mm",
            "\(wmm) × \(hmm) mm",
        ])
        lines.append([
            "Druckfläche: \(widthDots) × \(heightDots) Punkte",
            "\(widthDots) × \(heightDots) Punkte",
            "\(widthDots)×\(heightDots)",
        ])
        lines.append([
            "Sprache: \(language.displayName) · Ränder, Schwärzung & Barcodes prüfen",
            "Sprache: \(language.displayName)",
            language.displayName,
        ])
        return lines
    }

    // swiftlint:disable:next function_parameter_count function_body_length
    private static func makeCodeRow(left: Int, top: Int, width: Int, height: Int, moduleWidth: Int, hrHeight: Int,
                                    hrGap: Int, columnGap: Int, resolution: Resolution, widthDots: Int, heightDots: Int,
                                    title: String, stamp: DateStamp, style: Style, sideInfo: [[String]],
                                    infoHeight: Int, infoPitch: Int) -> [Element] {
        let dpmm = resolution.exactDotsPerMM
        func d(_ mm: Double) -> Int { Int((mm * dpmm).rounded()) }

        // QR-Code: ausführlichste Variante, die mit mindestens 0,25 mm Modulgröße passt.
        var qrElement: Element?
        var qrSide = 0
        if style.supportsQR {
            let asciiTitle = String(LegacyText.asciiTransliterated(title).prefix(24))
            let candidates = [
                "\(asciiTitle) \(resolution.dpi)dpi \(widthDots)x\(heightDots) \(stamp.iso)",
                "LW \(resolution.dpi)dpi \(widthDots)x\(heightDots)",
                "LW-\(resolution.dpi)",
            ]
            let minMag = max(1, d(0.25))
            let maxMag = min(style.maxQRMagnification, max(minMag, d(1.2)))
            let margin = style.language == .zpl ? max(2, d(0.5)) : 0
            let target = min(height - margin, width * 4 / 10)
            for data in candidates {
                let modules = qrModuleCount(byteCount: data.utf8.count)
                let magnification = min(maxMag, target / modules)
                if magnification >= minMag {
                    qrSide = modules * magnification
                    qrElement = .qr(Rect(x: left + width - qrSide, y: top + (height - margin - qrSide) / 2,
                                         width: qrSide, height: qrSide),
                                    data: data, magnification: magnification)
                    break
                }
            }
        }

        // Code 128 (Teilmenge B: 11 Module je Zeichen + Start, Prüfzeichen, Stopp).
        func code128Width(_ data: String, _ module: Int) -> Int { (11 * data.count + 35) * module }
        let candidates = [
            "LW-\(resolution.dpi)-\(Int(resolution.mm(fromDots: widthDots).rounded()))X\(Int(resolution.mm(fromDots: heightDots).rounded()))",
            "LW-\(resolution.dpi)",
        ]
        let maxModuleWidth = max(moduleWidth, d(0.5))
        func chooseBarcode(available: Int) -> (data: String, module: Int)? {
            // Bevorzugt: Barcode füllt gut die Hälfte der Spalte (Modul 0,25…0,5 mm).
            for data in candidates {
                let modules = 11 * data.count + 35
                let preferred = min(maxModuleWidth, max(moduleWidth, available * 55 / 100 / modules))
                if code128Width(data, preferred) <= available { return (data, preferred) }
            }
            var module = moduleWidth
            while module >= 1 {
                if let data = candidates.first(where: { code128Width($0, module) <= available }) { return (data, module) }
                module -= 1
            }
            return nil
        }
        var barcode = chooseBarcode(available: qrElement == nil ? width : width - qrSide - columnGap)
        if barcode == nil, qrElement != nil, chooseBarcode(available: width) != nil {
            // Lieber Barcode als QR-Code, wenn nur eins passt.
            qrElement = nil
            qrSide = 0
            barcode = chooseBarcode(available: width)
        }
        let codeColumnLimit = qrElement == nil ? width : width - qrSide - columnGap

        var elements: [Element] = []
        var barcodeBlockWidth = 0
        if let barcode {
            let barWidth = code128Width(barcode.data, barcode.module)
            let showText = height - hrHeight - hrGap >= d(4)
            let barHeight = showText ? height - hrHeight - hrGap : height
            elements.append(.code128(Rect(x: left, y: top, width: barWidth, height: barHeight),
                                     data: barcode.data, moduleWidth: barcode.module))
            barcodeBlockWidth = barWidth
            if showText {
                let estimated = Int((Double(barcode.data.count) * style.charWidthFactor * Double(hrHeight)).rounded(.up)) + 4
                let textWidth = min(max(barWidth, estimated), codeColumnLimit)
                barcodeBlockWidth = max(barWidth, textWidth)
                elements.append(.text(TextSlot(
                    rect: Rect(x: left, y: top + barHeight + hrGap, width: textWidth, height: hrHeight),
                    variants: [barcode.data], alignment: textWidth <= barWidth ? .center : .left, reversed: false)))
            }
        }
        if let qrElement { elements.append(qrElement) }

        // Freie Spalte zwischen Barcode und QR-Code: weitere Infozeilen (z. B. auf 4 × 1 Zoll).
        let sideX = left + (barcodeBlockWidth > 0 ? barcodeBlockWidth + columnGap : 0)
        let sideMaxX = left + (qrElement == nil ? width : width - qrSide - columnGap)
        let sideWidth = sideMaxX - sideX
        if !sideInfo.isEmpty, sideWidth >= max(d(22), style.minimumTextHeight * 6) {
            let lines = height >= infoHeight ? min(sideInfo.count, (height - infoHeight) / infoPitch + 1) : 0
            let blockHeight = lines > 0 ? (lines - 1) * infoPitch + infoHeight : 0
            let startY = top + max(0, (height - blockHeight) / 2)
            for index in 0..<lines {
                elements.append(.text(TextSlot(
                    rect: Rect(x: sideX, y: startY + index * infoPitch, width: sideWidth, height: infoHeight),
                    variants: sideInfo[index], alignment: .left, reversed: false)))
            }
        }
        return elements
    }

    private static func makeGradient(left: Int, top: Int, width: Int, height: Int, gap: Int,
                                     minBoxWidth: Int) -> [Element] {
        var count = 10
        while count > 4, (width - (count - 1) * gap) / count < minBoxWidth { count -= 1 }
        guard (width - (count - 1) * gap) / count >= 2 else { return [] }
        var elements: [Element] = []
        for index in 0..<count {
            let x0 = left + Int((Double(index) * Double(width + gap) / Double(count)).rounded(.down))
            let x1 = left + Int((Double(index + 1) * Double(width + gap) / Double(count)).rounded(.down)) - gap
            let boxWidth = max(2, min(x1, left + width) - x0)
            let full = min(boxWidth, height)
            let thickness: Int
            if index == count - 1 {
                thickness = full
            } else {
                let coverage = Double(index) / Double(count - 1)
                let half = Double(full) / 2
                thickness = max(1, Int((half * (1 - (1 - coverage).squareRoot())).rounded()))
            }
            elements.append(.gradientBox(Rect(x: x0, y: top, width: boxWidth, height: height), thickness: thickness))
        }
        return elements
    }

    // MARK: - Hilfen

    /// Kapazität (Byte-Modus, Fehlerkorrektur M) der QR-Versionen 1–20.
    private static let qrByteCapacityM = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213,
                                          251, 287, 331, 362, 412, 450, 504, 560, 624, 666]

    /// Kantenlänge in Modulen (ohne Ruhezone) für `byteCount` Bytes im Byte-Modus.
    static func qrModuleCount(byteCount: Int) -> Int {
        let version = (qrByteCapacityM.firstIndex { $0 >= byteCount } ?? (qrByteCapacityM.count - 1)) + 1
        return 17 + 4 * version
    }

    static func decimalComma(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Datum und Uhrzeit für das Testetikett (deterministisch über Zeitzone).
struct DateStamp: Sendable {
    /// `09.11.2026`
    var date: String
    /// `14:03`
    var time: String
    /// `2026-11-09`
    var iso: String

    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = c.year ?? 1970
        let month = c.month ?? 1
        let day = c.day ?? 1
        self.date = String(format: "%02d.%02d.%04d", day, month, year)
        self.time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        self.iso = String(format: "%04d-%02d-%02d", year, month, day)
    }
}

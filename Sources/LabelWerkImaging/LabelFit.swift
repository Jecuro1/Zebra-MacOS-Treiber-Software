import Foundation
import LabelWerkCore

/// Seitengröße in PostScript-Punkten (1/72 Zoll) – wie `cupsPageSize` im CUPS-Rasterkopf.
public struct PageSizePoints: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// DIN A4 (595,28 × 841,89 pt).
    public static let a4 = PageSizePoints(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72)
    /// US Letter (612 × 792 pt).
    public static let letter = PageSizePoints(width: 612, height: 792)
}

/// „An Etikett anpassen“ – Schritt F aus ARCHITECTURE.md §8.
///
/// macOS-Programme schicken oft die Systempapiergröße (A4/Letter, „Andere 210 × 297 mm“) statt der
/// Etikettengröße der Warteschlange – und drehen ein quer liegendes Etikett dabei oft um 90° gegen
/// den Uhrzeigersinn. Weicht die Seitengröße um mehr als 2 mm vom Etikett ab
/// (``PrintSettings/labelWidthHundredthsMM`` × ``PrintSettings/labelHeightHundredthsMM``), wird das
/// Graustufenbild **vor** dem Rastern auf seinen Inhalt (`L < 250`) zugeschnitten, bei Bedarf um 90°
/// gedreht (Inhalt und Etikett verschieden ausgerichtet), per Flächenmittel auf das Etikett abzüglich
/// 1,5 mm Rand je Seite vergrößert oder verkleinert und mittig auf ein weißes Etikett gesetzt.
///
/// Einheitlich je Auftrag (``Reference``): Die erste angepasste Seite mit Inhalt legt Drehung und
/// Maßstab fest; folgende Seiten gleicher Größe (± 2 mm) und gleichen Etiketts übernehmen beides
/// (den Maßstab nur, wenn ihr Inhalt damit in den Rahmen passt). Eine Seite, zu der die Referenz nicht
/// passt, entscheidet selbst und wird die neue Referenz. Bei freier Länge (Endlosmaterial) wird nie
/// vergrößert.
///
/// Byte-gleich mit `lw_fit` im CUPS-Filter und `fit_page` der Python-Referenz: Bis auf die
/// Umrechnung Punkte → 1/100 mm (``hundredthsMM(fromPoints:)``, `Double`) rechnet alles mit
/// Ganzzahlen.
public enum LabelFit {
    /// Ein Punkt ist Inhalt ⇔ `L < contentLevel`.
    public static let contentLevel: UInt8 = 250
    /// Abweichung in 1/100 mm, ab der angepasst wird (mehr als 2 mm).
    public static let toleranceHundredthsMM = 200
    /// Größte feste Etikettenseite in Punkten (ZPL `^LL`).
    public static let maxDots = 32_000
    /// Sicherheitsrand je Seite in 1/100 mm (1,5 mm).
    public static let marginHundredthsMM = 150
    /// Größte gültige Seitenseite in Punkten.
    public static let maxPagePoints = 100_000.0
    /// Größte unterstützte Auflösung (wie der Filter: größere Werte gelten als unbekannt).
    public static let maxDPI = 100_000

    /// Etikett in Punkten der Seite (`nil` = frei: Endlosmaterial, Länge beliebig) und
    /// Sicherheitsrand je Seite in Punkten (`marginX` links/rechts, `marginY` oben/unten).
    public struct Plan: Hashable, Sendable {
        public var width: Int?
        public var height: Int?
        public var marginX: Int
        public var marginY: Int

        public init(width: Int?, height: Int?, marginX: Int = 0, marginY: Int = 0) {
            self.width = width
            self.height = height
            self.marginX = marginX
            self.marginY = marginY
        }
    }

    /// Maßstab als Bruch `numerator / denominator` (Schritt F.4).
    public struct Scale: Hashable, Sendable {
        public var numerator: Int
        public var denominator: Int

        public init(numerator: Int, denominator: Int) {
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    /// Referenz eines Auftrags (§8 „F“): Entscheidung einer Seite, die für die folgenden Seiten gleicher
    /// Größe gilt.
    public struct Reference: Hashable, Sendable {
        /// Etikett und Rand der Referenzseite.
        public var plan: Plan
        /// Seitengröße der Referenzseite in 1/100 mm.
        public var pageWidth: Int
        public var pageHeight: Int
        /// Drehung aus Schritt F.3.
        public var turn: QuarterTurn
        /// Maßstab aus Schritt F.4.
        public var scale: Scale

        public init(plan: Plan, pageWidth: Int, pageHeight: Int, turn: QuarterTurn, scale: Scale) {
            self.plan = plan
            self.pageWidth = pageWidth
            self.pageHeight = pageHeight
            self.turn = turn
            self.scale = scale
        }

        /// Gilt die Referenz für eine Seite? Gleiches Etikett und gleicher Rand, Seitengröße (1/100 mm)
        /// auf ± 2 mm gleich.
        public func applies(to plan: Plan, pageWidth: Int, pageHeight: Int) -> Bool {
            self.plan == plan && abs(pageWidth - self.pageWidth) <= LabelFit.toleranceHundredthsMM
                && abs(pageHeight - self.pageHeight) <= LabelFit.toleranceHundredthsMM
        }
    }

    /// Punkte → 1/100 mm: `⌊pt · 2540 / 72 + 0,5⌋` in `Double` (genau diese Reihenfolge, wie C und
    /// Python); `nil`, wenn die Seitengröße ungültig ist (nicht `0 < pt ≤ 100 000`).
    public static func hundredthsMM(fromPoints points: Double) -> Int? {
        guard points > 0, points <= maxPagePoints else { return nil }
        return Int((points * 2540.0 / 72.0 + 0.5).rounded(.down))
    }

    /// 1,5 mm in Punkten bei `dpi`, kaufmännisch gerundet: `(150 · dpi + 1270) / 2540`.
    public static func margin(dpi: Int) -> Int {
        (marginHundredthsMM * dpi + 1270) / 2540
    }

    /// Schritt F.1: Etikett samt Rand oder `nil` (keine Anpassung: `Off`, Etikett bzw. Seitengröße
    /// unbekannt, Größe passt auf ± 2 mm, Auflösung ungültig, Bild ohne Fläche).
    ///
    /// Bei Endlosmaterial oder Etikettenlänge 0 ist die Länge frei; bei einer wirksamen Drehung um
    /// 90°/270° liegt die Seite quer (Breite = Etikettenlänge).
    public static func plan(settings: PrintSettings, pageSize: PageSizePoints?, xDPI: Int, yDPI: Int,
                            imageWidth: Int, imageHeight: Int) -> Plan? {
        let s = settings.clamped()
        guard s.fitToLabel == .auto, s.labelWidthHundredthsMM > 0, let pageSize, imageWidth > 0, imageHeight > 0,
              let pageWidth = hundredthsMM(fromPoints: pageSize.width),
              let pageHeight = hundredthsMM(fromPoints: pageSize.height) else { return nil }
        let length = s.tracking == .continuous ? 0 : s.labelHeightHundredthsMM
        let (labelWidth, labelHeight) = s.effectiveRotation.isQuarterTurn
            ? (length, s.labelWidthHundredthsMM)
            : (s.labelWidthHundredthsMM, length)
        let differs = (labelWidth > 0 && abs(pageWidth - labelWidth) > toleranceHundredthsMM)
            || (labelHeight > 0 && abs(pageHeight - labelHeight) > toleranceHundredthsMM)
        guard differs, (1...maxDPI).contains(xDPI), (1...maxDPI).contains(yDPI) else { return nil }
        let width = labelWidth > 0 ? (labelWidth * xDPI + 1270) / 2540 : nil
        let height = labelHeight > 0 ? (labelHeight * yDPI + 1270) / 2540 : nil
        for value in [width, height] {
            if let value, !(1...maxDots).contains(value) { return nil }
        }
        return Plan(width: width, height: height, marginX: margin(dpi: xDPI), marginY: margin(dpi: yDPI))
    }

    /// Schritt F.2: Rahmen der Punkte mit `L < 250`; `nil` bei leerer Seite.
    public static func contentBounds(_ image: GrayImage) -> (x: Int, y: Int, width: Int, height: Int)? {
        let width = image.width
        var left = width, right = -1, top = -1, bottom = -1
        image.pixels.withUnsafeBufferPointer { p in
            for y in 0..<image.height {
                let row = y * width
                var first = -1
                for x in 0..<width where p[row + x] < contentLevel {
                    first = x
                    break
                }
                guard first >= 0 else { continue }
                var last = first
                var x = width - 1
                while x > first {
                    if p[row + x] < contentLevel {
                        last = x
                        break
                    }
                    x -= 1
                }
                if top < 0 { top = y }
                bottom = y
                left = min(left, first)
                right = max(right, last)
            }
        }
        guard top >= 0 else { return nil }
        return (left, top, right - left + 1, bottom - top + 1)
    }

    /// Schritt F.3: Drehung des Inhalts `bw` × `bh` – ``QuarterTurn/r90`` (im Uhrzeigersinn),
    /// ``QuarterTurn/r270`` (gegen den Uhrzeigersinn) oder ``QuarterTurn/r0``.
    ///
    /// Nur bei festem Etikett und nur, wenn der gedrehte Inhalt mehr als 10 % größer würde
    /// (`s90 > 1,1 · s0` mit `s0 = min(W'/bw, H'/bh)`, `s90 = min(W'/bh, H'/bw)`). Das ist genau dann
    /// der Fall, wenn Inhalt und Etikett (abzüglich Rand) je um mehr als 10 % verschieden ausgerichtet
    /// sind: Hochformat-Inhalt auf Querformat-Etikett wird im Uhrzeigersinn gedreht (macht die
    /// Drehung gegen den Uhrzeigersinn rückgängig, mit der macOS ein Querformat auf Hochformat legt),
    /// Querformat-Inhalt auf Hochformat-Etikett dagegen.
    public static func rotation(contentWidth bw: Int, contentHeight bh: Int, plan: Plan) -> QuarterTurn {
        guard plan.width != nil, plan.height != nil else { return .r0 }
        let inner = box(contentWidth: bw, contentHeight: bh, plan: plan)
        if 10 * bh > 11 * bw && 10 * inner.width > 11 * inner.height { return .r90 }
        if 10 * bw > 11 * bh && 10 * inner.height > 11 * inner.width { return .r270 }
        return .r0
    }

    /// Schritt F.3/F.4: Zielrahmen für Inhalt `rw` × `rh`: feste Seite abzüglich zweimal Rand (zu klein →
    /// ganze Seite), freie Seite = Inhalt (entlang einer freien Seite wird nie vergrößert).
    public static func box(contentWidth rw: Int, contentHeight rh: Int, plan: Plan) -> (width: Int, height: Int) {
        func inner(_ side: Int, _ margin: Int) -> Int {
            let value = side - 2 * margin
            return value >= 1 ? value : side
        }
        return (plan.width.map { inner($0, plan.marginX) } ?? rw,
                plan.height.map { inner($0, plan.marginY) } ?? rh)
    }

    /// Schritt F.4: eigener Maßstab des (ggf. gedrehten) Inhalts `rw` × `rh` – `BW / rw`, wenn
    /// `BW · rh ≤ BH · rw`, sonst `BH / rh` (so groß wie möglich im Rahmen).
    public static func scale(contentWidth rw: Int, contentHeight rh: Int, plan: Plan) -> Scale {
        let frame = box(contentWidth: rw, contentHeight: rh, plan: plan)
        return frame.width * rh <= frame.height * rw
            ? Scale(numerator: frame.width, denominator: rw)
            : Scale(numerator: frame.height, denominator: rh)
    }

    /// Schritt F.4: `rw` × `rh` mit dem Maßstab, je Seite kaufmännisch gerundet, mindestens 1.
    public static func scaledSize(contentWidth rw: Int, contentHeight rh: Int, scale: Scale) -> (width: Int, height: Int) {
        let n = scale.numerator, d = scale.denominator
        return (max(1, (2 * rw * n + d) / (2 * d)), max(1, (2 * rh * n + d) / (2 * d)))
    }

    /// Schritt F.4 ohne Referenz: Zielgröße des (ggf. gedrehten) Inhalts – so groß wie möglich im
    /// Rahmen (vergrößern und verkleinern), Seitenverhältnis erhalten (die begrenzende Seite füllt den
    /// Rahmen genau, die abhängige kaufmännisch gerundet, mindestens 1).
    public static func targetSize(contentWidth rw: Int, contentHeight rh: Int, plan: Plan) -> (width: Int, height: Int) {
        scaledSize(contentWidth: rw, contentHeight: rh, scale: scale(contentWidth: rw, contentHeight: rh, plan: plan))
    }

    /// Schritt F.5: Flächenmittel des Ausschnitts (`x`, `y`, `width`, `height`) auf
    /// `toWidth` × `toHeight` – verkleinern **und** vergrößern, je Achse unabhängig. Jeder Zielpunkt
    /// ist die exakt gewichtete Summe der überdeckten Quellflächen, einmal gerundet: `(S + T/2) / T`,
    /// `T` = Fläche des Ausschnitts. Gleiche Größe → unveränderte Kopie.
    public static func areaAverage(_ image: GrayImage, x x0: Int, y y0: Int, width bw: Int, height bh: Int,
                                   toWidth tw: Int, toHeight th: Int) -> GrayImage {
        precondition(bw > 0 && bh > 0 && tw > 0 && th > 0, "LabelFit: ungültige Größen")
        precondition(x0 >= 0 && y0 >= 0 && x0 + bw <= image.width && y0 + bh <= image.height,
                     "LabelFit: Ausschnitt außerhalb des Bildes")
        let stride = image.width
        if tw == bw && th == bh {
            var pixels = [UInt8](repeating: 0, count: bw * bh)
            image.pixels.withUnsafeBufferPointer { src in
                pixels.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<bh {
                        let from = (y0 + y) * stride + x0
                        for x in 0..<bw { dst[y * bw + x] = src[from + x] }
                    }
                }
            }
            return GrayImage(width: bw, height: bh, pixels: pixels)
        }
        /// Überlappung der Quelle `s` (`[s·nDst, (s+1)·nDst)`) mit dem Ziel `d` (`[d·nSrc, (d+1)·nSrc)`).
        func overlap(_ s: Int, _ d: Int, _ nSrc: Int, _ nDst: Int) -> UInt64 {
            let lo = max(s * nDst, d * nSrc), hi = min((s + 1) * nDst, (d + 1) * nSrc)
            return hi > lo ? UInt64(hi - lo) : 0
        }
        let total = UInt64(bw) * UInt64(bh)
        var out = [UInt8](repeating: 255, count: tw * th)
        var acc = [UInt64](repeating: 0, count: tw)
        var cached = [UInt64](repeating: 0, count: tw)   // Summen der Quellzeile `cachedRow`
        var fresh = [UInt64](repeating: 0, count: tw)
        var cachedRow = -1
        image.pixels.withUnsafeBufferPointer { src in
            /// Waagerecht: Σx ax(X, x) · L je Zielspalte X der Quellzeile `y`.
            func horizontal(_ y: Int, into sums: inout [UInt64]) {
                let base = (y0 + y) * stride + x0
                for column in 0..<tw {
                    let first = column * bw / tw, last = ((column + 1) * bw - 1) / tw
                    var sum: UInt64 = 0
                    for x in first...last { sum += overlap(x, column, bw, tw) * UInt64(src[base + x]) }
                    sums[column] = sum
                }
            }
            for row in 0..<th {
                // Zielzeile deckt [row·bh, (row+1)·bh), Quellzeile y deckt [y·th, (y+1)·th).
                // Aufeinanderfolgende Zielzeilen teilen höchstens eine Quellzeile (die letzte der
                // vorigen) – beim Vergrößern oft dieselbe; sie wird aus `cached` wiederverwendet.
                let first = row * bh / th, last = ((row + 1) * bh - 1) / th
                for column in 0..<tw { acc[column] = 0 }
                for y in first...last {
                    let weight = overlap(y, row, bh, th)
                    if y == cachedRow {
                        for column in 0..<tw { acc[column] += weight * cached[column] }
                    } else {
                        horizontal(y, into: &fresh)
                        for column in 0..<tw { acc[column] += weight * fresh[column] }
                        if y == last {
                            swap(&cached, &fresh)
                            cachedRow = y
                        }
                    }
                }
                for column in 0..<tw { out[row * tw + column] = UInt8((acc[column] + total / 2) / total) }
            }
        }
        return GrayImage(width: tw, height: th, pixels: out)
    }

    /// Schritte F.2–F.6 für eine Seite ohne Referenz (allein bzw. als erste Seite eines Auftrags):
    /// legt das Bild nach `plan` auf das Etikett – Inhalt zuschneiden, bei Bedarf drehen
    /// (``rotation(contentWidth:contentHeight:plan:)``), skalieren, mittig einsetzen (leere Seite →
    /// weißes Etikett, freie Seite 1 Punkt).
    public static func apply(_ image: GrayImage, plan: Plan) -> GrayImage {
        var reference: Reference?
        return apply(image, plan: plan, pageWidth: 0, pageHeight: 0, reference: &reference)
    }

    /// Schritte F.2–F.6 für eine Seite eines Auftrags: Gilt `reference`
    /// (``Reference/applies(to:pageWidth:pageHeight:)`` mit der Seitengröße in 1/100 mm), übernimmt die
    /// Seite deren Drehung und – wenn ihr Inhalt damit in den Rahmen passt – deren Maßstab; sonst
    /// entscheidet sie selbst und wird (mit Inhalt) die neue Referenz. Leere Seiten ändern `reference`
    /// nicht.
    public static func apply(_ image: GrayImage, plan: Plan, pageWidth: Int, pageHeight: Int,
                             reference: inout Reference?) -> GrayImage {
        guard let bounds = contentBounds(image) else {
            return GrayImage(width: plan.width ?? 1, height: plan.height ?? 1, fill: 255)
        }
        let current = reference.flatMap { $0.applies(to: plan, pageWidth: pageWidth, pageHeight: pageHeight) ? $0 : nil }
        let turn = current?.turn ?? rotation(contentWidth: bounds.width, contentHeight: bounds.height, plan: plan)
        let source: GrayImage
        let region: (x: Int, y: Int, width: Int, height: Int)
        if turn == .r0 {
            source = image
            region = bounds
        } else {
            source = image.cropped(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height).rotated(turn)
            region = (0, 0, source.width, source.height)
        }
        // Maßstab: eigener; mit Referenz deren, solange der Inhalt damit in den Rahmen passt
        // (s_R ≤ s_p ⇔ n_R · d_p ≤ n_p · d_R).
        var factor = scale(contentWidth: region.width, contentHeight: region.height, plan: plan)
        if let current,
           current.scale.numerator * factor.denominator <= factor.numerator * current.scale.denominator {
            factor = current.scale
        } else if current == nil {
            reference = Reference(plan: plan, pageWidth: pageWidth, pageHeight: pageHeight, turn: turn, scale: factor)
        }
        let target = scaledSize(contentWidth: region.width, contentHeight: region.height, scale: factor)
        let scaled = areaAverage(source, x: region.x, y: region.y, width: region.width, height: region.height,
                                 toWidth: target.width, toHeight: target.height)
        let canvasWidth = plan.width ?? target.width
        let canvasHeight = plan.height ?? target.height
        let ox = (canvasWidth - target.width) / 2, oy = (canvasHeight - target.height) / 2
        var pixels = [UInt8](repeating: 255, count: canvasWidth * canvasHeight)
        scaled.pixels.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<target.height {
                    let to = (oy + y) * canvasWidth + ox
                    for x in 0..<target.width { dst[to + x] = src[y * target.width + x] }
                }
            }
        }
        return GrayImage(width: canvasWidth, height: canvasHeight, pixels: pixels)
    }
}

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
/// Etikettengröße der Warteschlange. Weicht die Seitengröße um mehr als 2 mm vom Etikett ab
/// (``PrintSettings/labelWidthHundredthsMM`` × ``PrintSettings/labelHeightHundredthsMM``), wird das
/// Graustufenbild **vor** dem Rastern auf seinen Inhalt (`L < 250`) zugeschnitten, bei Bedarf per
/// Flächenmittel verkleinert (nie vergrößert) und mittig auf ein weißes Etikett gesetzt.
///
/// Byte-gleich mit `lw_fit` im CUPS-Filter und `fit_page` der Python-Referenz: Bis auf die
/// Umrechnung Punkte → 1/100 mm (``hundredthsMM(fromPoints:)``, `Double`) rechnet alles mit
/// Ganzzahlen.
public enum LabelFit {
    /// Ein Punkt ist Inhalt ⇔ `L < contentLevel`.
    public static let contentLevel: UInt8 = 250
    /// Abweichung in 1/100 mm, ab der angepasst wird (mehr als 2 mm).
    public static let toleranceHundredthsMM = 200
    /// Größte Etikettenseite in Punkten (ZPL `^LL`).
    public static let maxDots = 32_000
    /// Größte gültige Seitenseite in Punkten.
    public static let maxPagePoints = 100_000.0
    /// Größte unterstützte Auflösung (wie der Filter: größere Werte gelten als unbekannt).
    public static let maxDPI = 100_000

    /// Zielgröße in Punkten der Seite; `nil` = frei (Endlosmaterial: Länge beliebig).
    public struct Plan: Hashable, Sendable {
        public var width: Int?
        public var height: Int?

        public init(width: Int?, height: Int?) {
            self.width = width
            self.height = height
        }
    }

    /// Punkte → 1/100 mm: `⌊pt · 2540 / 72 + 0,5⌋` in `Double` (genau diese Reihenfolge, wie C und
    /// Python); `nil`, wenn die Seitengröße ungültig ist (nicht `0 < pt ≤ 100 000`).
    public static func hundredthsMM(fromPoints points: Double) -> Int? {
        guard points > 0, points <= maxPagePoints else { return nil }
        return Int((points * 2540.0 / 72.0 + 0.5).rounded(.down))
    }

    /// Schritt F.1: Zielgröße oder `nil` (keine Anpassung: `Off`, Etikett bzw. Seitengröße
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
        return Plan(width: width, height: height)
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

    /// Schritt F.3: Zielgröße des Inhalts – nie größer als der Inhalt, Seitenverhältnis erhalten
    /// (die abhängige Seite kaufmännisch gerundet, mindestens 1).
    public static func targetSize(contentWidth bw: Int, contentHeight bh: Int, plan: Plan) -> (width: Int, height: Int) {
        func height(forWidth target: Int) -> Int { max(1, (2 * bh * target + bw) / (2 * bw)) }
        func width(forHeight target: Int) -> Int { max(1, (2 * bw * target + bh) / (2 * bh)) }
        switch (plan.width, plan.height) {
        case let (w?, h?):
            if bw <= w && bh <= h { return (bw, bh) }
            return w * bh <= h * bw ? (w, height(forWidth: w)) : (width(forHeight: h), h)
        case let (w?, nil):
            return bw <= w ? (bw, bh) : (w, height(forWidth: w))
        case let (nil, h?):
            return bh <= h ? (bw, bh) : (width(forHeight: h), h)
        case (nil, nil):
            return (bw, bh)
        }
    }

    /// Schritt F.4: Flächenmittel des Ausschnitts (`x`, `y`, `width`, `height`) auf
    /// `toWidth` × `toHeight` (höchstens so groß wie der Ausschnitt). Jeder Zielpunkt ist die exakt
    /// gewichtete Summe der überdeckten Quellflächen, einmal gerundet: `(S + T/2) / T`, `T` = Fläche
    /// des Ausschnitts. Gleiche Größe → unveränderte Kopie.
    public static func areaAverage(_ image: GrayImage, x x0: Int, y y0: Int, width bw: Int, height bh: Int,
                                   toWidth tw: Int, toHeight th: Int) -> GrayImage {
        precondition(bw > 0 && bh > 0 && tw > 0 && th > 0 && tw <= bw && th <= bh, "LabelFit: ungültige Größen")
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
        var sums = [UInt64](repeating: 0, count: tw)
        var current = [UInt64](repeating: 0, count: tw)
        var next = [UInt64](repeating: 0, count: tw)
        var row = 0   // nächste auszugebende Zielzeile
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<bh {
                // Waagerecht: Σx ax(X, x) · L je Zielspalte.
                let base = (y0 + y) * stride + x0
                for column in 0..<tw {
                    let first = column * bw / tw, last = ((column + 1) * bw - 1) / tw
                    var sum: UInt64 = 0
                    for x in first...last { sum += overlap(x, column, bw, tw) * UInt64(src[base + x]) }
                    sums[column] = sum
                }
                // Senkrecht: Quellzeile y deckt [y·th, (y+1)·th) und trifft höchstens zwei Zielzeilen.
                let lo = y * th, hi = lo + th
                for target in (lo / bh)...((hi - 1) / bh) where target < th {
                    let weight = overlap(y, target, bh, th)
                    if target == row {
                        for column in 0..<tw { current[column] += weight * sums[column] }
                    } else {
                        for column in 0..<tw { next[column] += weight * sums[column] }
                    }
                }
                while row < th && (row + 1) * bh <= hi {
                    for column in 0..<tw { out[row * tw + column] = UInt8((current[column] + total / 2) / total) }
                    swap(&current, &next)
                    for column in 0..<tw { next[column] = 0 }
                    row += 1
                }
            }
        }
        return GrayImage(width: tw, height: th, pixels: out)
    }

    /// Schritte F.2–F.5: legt das Bild nach `plan` auf das Etikett (leere Seite → weißes Etikett,
    /// freie Seite 1 Punkt).
    public static func apply(_ image: GrayImage, plan: Plan) -> GrayImage {
        guard let bounds = contentBounds(image) else {
            return GrayImage(width: plan.width ?? 1, height: plan.height ?? 1, fill: 255)
        }
        let target = targetSize(contentWidth: bounds.width, contentHeight: bounds.height, plan: plan)
        let scaled = areaAverage(image, x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height,
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

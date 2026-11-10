import Foundation

/// Pixelgenaue Grundformen. Ein Punkt gehört zur Form, wenn sein Mittelpunkt (x + 0,5, y + 0,5)
/// innerhalb liegt; dadurch sind achsparallele Rechtecke exakt `[x, x + w) × [y, y + h)`.
enum ShapePainter {

    /// Erster und letzter Punkt (exklusiv), deren Mittelpunkt in `[left, right)` liegt.
    @inline(__always)
    static func pixelRange(_ left: Double, _ right: Double) -> (Int, Int) {
        (Int((left - 0.5).rounded(.up)), Int((right - 0.5).rounded(.up)))
    }

    /// Rechteck/Rahmen (`^GB`) mit Linienstärke und Eckenrundung 0…8.
    static func box(x: Int, y: Int, width: Int, height: Int, thickness: Int, rounding: Int,
                    into mask: inout FieldMask) {
        let w = max(1, width), h = max(1, height)
        let t = max(1, thickness)
        if rounding <= 0 {
            if 2 * t >= w || 2 * t >= h {
                mask.rect(x: x, y: y, width: w, height: h)
            } else {
                mask.rect(x: x, y: y, width: w, height: t)
                mask.rect(x: x, y: y + h - t, width: w, height: t)
                mask.rect(x: x, y: y + t, width: t, height: h - 2 * t)
                mask.rect(x: x + w - t, y: y + t, width: t, height: h - 2 * t)
            }
            return
        }
        let radius = Double(min(8, rounding)) / 8 * Double(min(w, h)) / 2
        let filled = 2 * t >= w || 2 * t >= h
        let innerRadius = max(0, radius - Double(t))
        for row in mask.rows(y, y + h) {
            let yc = Double(row - y) + 0.5
            guard let outer = roundedSpan(yc, width: Double(w), height: Double(h), radius: radius) else { continue }
            let (ox0, ox1) = pixelRange(outer.0, outer.1)
            let innerY = yc - Double(t)
            if !filled, innerY > 0, innerY < Double(h - 2 * t),
               let inner = roundedSpan(innerY, width: Double(w - 2 * t), height: Double(h - 2 * t), radius: innerRadius) {
                let (ix0, ix1) = pixelRange(inner.0 + Double(t), inner.1 + Double(t))
                mask.span(y: row, from: x + ox0, to: x + min(ix0, ox1))
                mask.span(y: row, from: x + max(ix1, ox0), to: x + ox1)
            } else {
                mask.span(y: row, from: x + ox0, to: x + ox1)
            }
        }
    }

    /// Horizontale Ausdehnung eines abgerundeten Rechtecks `[0, width) × [0, height)` auf Höhe `yc`.
    private static func roundedSpan(_ yc: Double, width: Double, height: Double, radius: Double) -> (Double, Double)? {
        guard yc >= 0, yc <= height, width > 0 else { return nil }
        let r = min(radius, width / 2, height / 2)
        var dy = 0.0
        if yc < r { dy = r - yc } else if yc > height - r { dy = yc - (height - r) }
        let inset = dy > 0 ? r - (max(0, r * r - dy * dy)).squareRoot() : 0
        return (inset, width - inset)
    }

    /// Ellipse bzw. Kreis (`^GE`, `^GC`) im Rechteck `width × height` mit Ringstärke.
    static func ellipse(x: Int, y: Int, width: Int, height: Int, thickness: Int, into mask: inout FieldMask) {
        let a = Double(max(1, width)) / 2, b = Double(max(1, height)) / 2
        let t = Double(max(1, thickness))
        let ai = a - t, bi = b - t
        let hasHole = ai > 0 && bi > 0
        for row in mask.rows(y, y + max(1, height)) {
            let dy = Double(row - y) + 0.5 - b
            let outerRatio = 1 - (dy * dy) / (b * b)
            guard outerRatio > 0 else { continue }
            let outerHalf = a * outerRatio.squareRoot()
            let (ox0, ox1) = pixelRange(a - outerHalf, a + outerHalf)
            if hasHole, abs(dy) < bi {
                let innerHalf = ai * (1 - (dy * dy) / (bi * bi)).squareRoot()
                let (ix0, ix1) = pixelRange(a - innerHalf, a + innerHalf)
                mask.span(y: row, from: x + ox0, to: x + min(ix0, ox1))
                mask.span(y: row, from: x + max(ix1, ox0), to: x + ox1)
            } else {
                mask.span(y: row, from: x + ox0, to: x + ox1)
            }
        }
    }

    /// Diagonale (`^GD`): Parallelogramm mit waagerechter Stärke `thickness`; „/“ von links unten
    /// nach rechts oben (`leansRight`) bzw. „\“. Steile Linien (Versatz ≤ 1 Punkt je Zeile) nach der
    /// Mittelpunktregel; flache Linien decken je Zeile den vollen Versatz zwischen Ober- und
    /// Unterkante der Zeile ab, damit keine Lücken entstehen und die Ecken erreicht werden.
    static func diagonal(x: Int, y: Int, width: Int, height: Int, thickness: Int, leansRight: Bool,
                         into mask: inout FieldMask) {
        let w = Double(max(1, width)), h = Double(max(1, height))
        let t = Double(max(1, min(thickness, width)))
        let travel = w - t
        let steep = travel / h <= 1
        func left(_ position: Double) -> Double {
            let fraction = position / h
            return leansRight ? travel * (1 - fraction) : travel * fraction
        }
        for row in mask.rows(y, y + max(1, height)) {
            let local = Double(row - y)
            let start: Double, end: Double
            if steep {
                start = left(local + 0.5)
                end = start + t
            } else {
                let top = left(local), bottom = left(local + 1)
                start = min(top, bottom)
                end = max(top, bottom) + t
            }
            let (x0, x1) = pixelRange(start, end)
            mask.span(y: row, from: x + max(0, x0), to: x + min(width, x1))
        }
    }
}

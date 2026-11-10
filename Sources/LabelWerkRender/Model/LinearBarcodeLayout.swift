import Foundation
import LabelWerkBarcode

/// Geometrie eines linearen Barcodefelds in **ungedrehten Feldkoordinaten** (Ursprung = linke
/// obere Ecke des ungedrehten Feldrechtecks `width × height`; auf dem Etikett liegt es gemäß
/// `LinearBarcodeElement.origin` und `orientation`, siehe `LinearBarcodeElement.barsFrame`).
///
/// * Klarschrift: Bitmap-Schrift A, vergrößert um die Modulbreite (Zelle 9m × 5m, Vorschub 6m),
///   mit einem Modul Abstand zu den Balken; zentriert unter (bzw. über) dem Symbol.
/// * EAN-13, EAN-8, UPC-A, UPC-E (Klarschrift unten): Ziffern zwischen den Begrenzungszeichen,
///   außen stehende Ziffern links (EAN-13, UPC-A, UPC-E) bzw. rechts (UPC-A, UPC-E) in eigenen
///   Randzonen von 7 Modulen; Begrenzungsbalken werden um die halbe Schrifthöhe + Abstand verlängert.
///   Die Balken beginnen dann bei `barsX = 7 × Modulbreite`.
/// * Feldgröße = Randzonen + Symbolbreite × Balkenhöhe + Klarschriftzeile. Klarschrift, die
///   breiter als das Symbol ist, ragt zentriert seitlich über das Feld hinaus (`inkMinX`/`inkMaxX`).
///
/// Der `SoftwareRasterizer` zeichnet genau diese Geometrie; Vorschauen (z. B. die App) sollten sie
/// ebenfalls verwenden, damit Vektor- und Bitmapdarstellung übereinstimmen.
public struct LinearBarcodeLayout: Hashable, Sendable {

    /// Ein Balken.
    public struct Bar: Hashable, Sendable {
        /// Linke Kante in Feldkoordinaten.
        public let x: Int
        /// Breite in Punkten.
        public let width: Int
        /// Begrenzungs- bzw. Trennbalken (bei EAN/UPC nach unten verlängert).
        public let isGuard: Bool
    }

    /// Ein Lauf der Klarschriftzeile (Schrift A × Modulbreite, siehe `textHeight` …).
    public struct TextRun: Hashable, Sendable {
        public let text: String
        /// Linke Kante des ersten Zeichens.
        public let x: Int
        /// Oberkante der Schriftzelle.
        public let y: Int
    }

    /// Modulbreite in Punkten (1…100).
    public let module: Int
    /// Feldbreite (ungedreht) inklusive EAN/UPC-Randzonen.
    public let width: Int
    /// Feldhöhe (ungedreht): Balkenhöhe + gegebenenfalls Abstand und Klarschriftzeile.
    public let height: Int
    /// Linke Kante des ersten Balkens (7 Module bei EAN-13/UPC-A/UPC-E mit Klarschrift unten, sonst 0).
    public let barsX: Int
    /// Oberkante der Balken (bei Klarschrift oben: Schrifthöhe + Abstand, sonst 0).
    public let barsY: Int
    /// Breite des Symbols von der linken Kante des ersten bis zur rechten Kante des letzten Balkens.
    public let barsWidth: Int
    /// Höhe der Balken (ohne Verlängerung der Begrenzungsbalken).
    public let barHeight: Int
    /// Verlängerung der Begrenzungsbalken nach unten (EAN/UPC), sonst 0.
    public let guardExtension: Int
    public let bars: [Bar]
    public let texts: [TextRun]
    /// Zellhöhe der Klarschrift (9 × Modulbreite).
    public let textHeight: Int
    /// Zeichenbreite der Klarschrift (5 × Modulbreite).
    public let textCellWidth: Int
    /// Zeichenvorschub der Klarschrift (6 × Modulbreite).
    public let textAdvance: Int
    /// Horizontale Ausdehnung inklusive überstehender Klarschrift.
    public let inkMinX: Int
    public let inkMaxX: Int

    /// Berechnet die Geometrie eines Barcodeelements (dieselbe wie `LinearBarcodeElement.layout`).
    public init(_ element: LinearBarcodeElement) {
        let module = min(100, max(1, element.moduleWidth))
        self.module = module
        let barHeight = max(1, element.height)
        self.barHeight = barHeight
        let widths = element.barcode.widthsInDots(moduleWidth: module, ratio: element.ratio)
        let barsWidth = widths.reduce(0) { $0 + $1.dots }
        self.barsWidth = barsWidth

        let textHeight = 9 * module
        let textCellWidth = 5 * module
        let textAdvance = 6 * module
        let gap = module
        self.textHeight = textHeight
        self.textCellWidth = textCellWidth
        self.textAdvance = textAdvance

        let humanReadable = element.barcode.humanReadable.isEmpty ? element.text : element.barcode.humanReadable
        let digits = Array(humanReadable)
        let eanStyle = element.printInterpretation && !element.interpretationAbove
            && Self.eanLayout(element.symbology, digitCount: digits.count) != nil

        var leftExtra = 0, rightExtra = 0
        var guardExtension = 0
        var barsY = 0
        var height = barHeight
        var texts: [TextRun] = []

        if eanStyle, let plan = Self.eanLayout(element.symbology, digitCount: digits.count) {
            let zone = 7 * module
            leftExtra = plan.outsideLeft > 0 ? zone : 0
            rightExtra = plan.outsideRight > 0 ? zone : 0
            guardExtension = textHeight / 2 + gap
            height = barHeight + gap + textHeight
            let textY = barHeight + gap
            // Datensegmente = Läufe nicht begrenzender Elemente.
            var segments: [(start: Int, end: Int)] = []
            var x = leftExtra
            var segmentStart: Int?
            for (index, piece) in widths.enumerated() {
                let isGuard = element.barcode.elements[index].isGuard
                if isGuard {
                    if let start = segmentStart { segments.append((start, x)); segmentStart = nil }
                } else if segmentStart == nil {
                    segmentStart = x
                }
                x += piece.dots
            }
            if let start = segmentStart { segments.append((start, x)) }
            var cursor = 0
            if plan.outsideLeft > 0 {
                let run = String(digits[0..<plan.outsideLeft])
                let runWidth = plan.outsideLeft * textAdvance - gap
                texts.append(TextRun(text: run, x: max(0, (leftExtra - gap - runWidth) / 2), y: textY))
                cursor = plan.outsideLeft
            }
            for (segmentIndex, count) in plan.segments.enumerated() where segmentIndex < segments.count {
                let segment = segments[segmentIndex]
                let end = min(digits.count, cursor + count)
                let run = String(digits[cursor..<end])
                let runWidth = run.count * textAdvance - gap
                texts.append(TextRun(text: run, x: segment.start + (segment.end - segment.start - runWidth) / 2, y: textY))
                cursor = end
            }
            if plan.outsideRight > 0, cursor < digits.count {
                let run = String(digits[cursor...])
                let runWidth = run.count * textAdvance - gap
                let zoneStart = leftExtra + barsWidth + gap
                texts.append(TextRun(text: run, x: zoneStart + max(0, (rightExtra - gap - runWidth) / 2), y: textY))
            }
        } else if element.printInterpretation && !humanReadable.isEmpty {
            height = barHeight + gap + textHeight
            let runWidth = digits.count * textAdvance - gap
            let textX = (barsWidth - runWidth) / 2
            if element.interpretationAbove {
                barsY = textHeight + gap
                texts.append(TextRun(text: humanReadable, x: textX, y: 0))
            } else {
                texts.append(TextRun(text: humanReadable, x: textX, y: barHeight + gap))
            }
        }

        var bars: [Bar] = []
        var x = leftExtra
        for (index, piece) in widths.enumerated() {
            if piece.isBar {
                bars.append(Bar(x: x, width: piece.dots, isGuard: element.barcode.elements[index].isGuard))
            }
            x += piece.dots
        }
        self.bars = bars
        self.barsX = leftExtra
        self.barsY = barsY
        self.guardExtension = eanStyle ? guardExtension : 0
        self.texts = texts
        self.width = leftExtra + barsWidth + rightExtra
        self.height = height
        var minX = 0, maxX = leftExtra + barsWidth + rightExtra
        for run in texts {
            minX = min(minX, run.x)
            maxX = max(maxX, run.x + run.text.count * textAdvance)
        }
        self.inkMinX = minX
        self.inkMaxX = maxX
    }

    /// Ziffernaufteilung der EAN/UPC-Klarschrift: außen links, je Datensegment, außen rechts.
    private static func eanLayout(_ symbology: BarcodeSymbology, digitCount: Int)
        -> (outsideLeft: Int, segments: [Int], outsideRight: Int)? {
        switch (symbology, digitCount) {
        case (.ean13, 13): return (1, [6, 6], 0)
        case (.ean8, 8): return (0, [4, 4], 0)
        case (.upcA, 12): return (1, [5, 5], 1)
        case (.upcA, 11): return (1, [5, 5], 0)        // ohne gedruckte Prüfziffer
        case (.upcE, 8): return (1, [6], 1)
        case (.upcE, 7): return (1, [6], 0)
        default: return nil
        }
    }
}

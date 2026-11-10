import Foundation

// MARK: - Vierteldrehung

/// Drehung um ein Vielfaches von 90° **im Uhrzeigersinn**.
public enum QuarterTurn: Int, Sendable, CaseIterable, Codable {
    case r0 = 0
    case r90 = 90
    case r180 = 180
    case r270 = 270

    /// Erzeugt eine Drehung aus einem beliebigen Gradwert (wird auf 0…359 normiert und
    /// auf das nächste Vielfache von 90° gerundet).
    public init(degrees: Int) {
        let normalized = ((degrees % 360) + 360) % 360
        let quarter = ((normalized + 45) / 90) % 4
        self = QuarterTurn(rawValue: quarter * 90) ?? .r0
    }

    /// Gegenläufige Drehung (macht `self` rückgängig).
    public var inverse: QuarterTurn {
        QuarterTurn(degrees: 360 - rawValue)
    }

    /// Hintereinanderausführung zweier Drehungen.
    public func followed(by other: QuarterTurn) -> QuarterTurn {
        QuarterTurn(degrees: rawValue + other.rawValue)
    }

    /// `true`, wenn Breite und Höhe vertauscht werden (90° bzw. 270°).
    public var swapsDimensions: Bool { self == .r90 || self == .r270 }
}

// MARK: - Ausrichtung

/// Ausrichtung eines Bildes innerhalb einer größeren (oder kleineren) Fläche.
public enum ImageAlignment: String, Sendable, CaseIterable, Codable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    /// Horizontaler Anteil: 0 = links, 1 = Mitte, 2 = rechts.
    var horizontal: Int {
        switch self {
        case .topLeading, .leading, .bottomLeading: return 0
        case .top, .center, .bottom: return 1
        case .topTrailing, .trailing, .bottomTrailing: return 2
        }
    }

    /// Vertikaler Anteil: 0 = oben, 1 = Mitte, 2 = unten.
    var vertical: Int {
        switch self {
        case .topLeading, .top, .topTrailing: return 0
        case .leading, .center, .trailing: return 1
        case .bottomLeading, .bottom, .bottomTrailing: return 2
        }
    }

    /// Versatz des Inhalts (Größe `content`) innerhalb der Fläche (Größe `container`).
    /// Negative Werte bedeuten, dass der Inhalt beschnitten wird.
    func offset(content: Int, container: Int, axis vertical: Bool) -> Int {
        let free = container - content
        let part = vertical ? self.vertical : self.horizontal
        switch part {
        case 0: return 0
        case 1: return free >= 0 ? free / 2 : -((-free + 1) / 2)
        default: return free
        }
    }
}

// MARK: - Graustufenbild

/// 8-Bit-Graustufenbild (Luminanz): 0 = schwarz, 255 = weiß.
///
/// Die Pixel liegen zeilenweise von oben nach unten, jede Zeile von links nach rechts
/// (`pixels[y * width + x]`). Der Typ ist ein reiner Werttyp und damit `Sendable`.
public struct GrayImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Zeilenweise Pixeldaten, `count == width * height`.
    public var pixels: [UInt8]

    /// Erzeugt ein einfarbiges Bild (Standard: weiß).
    public init(width: Int, height: Int, fill: UInt8 = 255) {
        precondition(width >= 0 && height >= 0, "GrayImage: negative Abmessungen \(width) × \(height)")
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: fill, count: width * height)
    }

    /// Erzeugt ein Bild aus vorhandenen Pixeldaten (`pixels.count` muss `width * height` sein).
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0, "GrayImage: negative Abmessungen \(width) × \(height)")
        precondition(pixels.count == width * height,
                     "GrayImage: \(pixels.count) Pixel passen nicht zu \(width) × \(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Zugriff auf ein einzelnes Pixel; Koordinaten müssen im Bild liegen.
    public subscript(x: Int, y: Int) -> UInt8 {
        get {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "GrayImage: (\(x), \(y)) außerhalb des Bildes")
            return pixels[y * width + x]
        }
        set {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "GrayImage: (\(x), \(y)) außerhalb des Bildes")
            pixels[y * width + x] = newValue
        }
    }

    /// `true`, wenn das Bild keine Pixel enthält.
    public var isEmpty: Bool { width == 0 || height == 0 }

    // MARK: Geometrie

    /// Dreht das Bild im Uhrzeigersinn um die angegebene Vierteldrehung.
    public func rotated(_ turn: QuarterTurn) -> GrayImage {
        let w = width, h = height
        switch turn {
        case .r0:
            return self
        case .r180:
            return GrayImage(width: w, height: h, pixels: pixels.reversed())
        case .r90, .r270:
            // Neues Bild: Breite = alte Höhe, Höhe = alte Breite.
            var out = [UInt8](repeating: 0, count: w * h)
            pixels.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = y * w
                        for x in 0..<w {
                            // r90: (x, y) → (h−1−y, x); r270: (x, y) → (y, w−1−x)
                            let nx = turn == .r90 ? h - 1 - y : y
                            let ny = turn == .r90 ? x : w - 1 - x
                            dst[ny * h + nx] = src[row + x]
                        }
                    }
                }
            }
            return GrayImage(width: h, height: w, pixels: out)
        }
    }

    /// Spiegelt das Bild horizontal (links ↔ rechts).
    public func mirrored() -> GrayImage {
        var out = pixels
        let w = width
        out.withUnsafeMutableBufferPointer { buf in
            for y in 0..<height {
                let row = y * w
                var a = row, b = row + w - 1
                while a < b {
                    buf.swapAt(a, b)
                    a += 1
                    b -= 1
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Spiegelt das Bild vertikal (oben ↔ unten).
    public func flippedVertically() -> GrayImage {
        var out = [UInt8]()
        out.reserveCapacity(pixels.count)
        for y in stride(from: height - 1, through: 0, by: -1) {
            out.append(contentsOf: pixels[(y * width)..<(y * width + width)])
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Negativ: jeder Wert `v` wird zu `255 − v`.
    public func inverted() -> GrayImage {
        GrayImage(width: width, height: height, pixels: pixels.map { 255 &- $0 })
    }

    /// Skaliert das Bild auf die Zielgröße.
    ///
    /// Je Achse getrennt: beim Verkleinern Flächenmittel (Box-Filter, jedes Quellpixel trägt mit
    /// seinem überdeckten Flächenanteil bei), beim Vergrößern bilineare Interpolation
    /// (pixelzentriert, Ränder werden fortgesetzt). Ergebnis wird gerundet.
    public func scaled(width newWidth: Int, height newHeight: Int) -> GrayImage {
        precondition(newWidth >= 0 && newHeight >= 0, "GrayImage.scaled: negative Zielgröße")
        if newWidth == width && newHeight == height { return self }
        if newWidth == 0 || newHeight == 0 { return GrayImage(width: newWidth, height: newHeight) }
        if isEmpty { return GrayImage(width: newWidth, height: newHeight, fill: 255) }

        let hWeights = ResampleWeights(source: width, destination: newWidth)
        let vWeights = ResampleWeights(source: height, destination: newHeight)

        // 1. Horizontaler Durchgang: width × height → newWidth × height (Double)
        var temp = [Double](repeating: 0, count: newWidth * height)
        pixels.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let srcRow = y * width
                    let dstRow = y * newWidth
                    for x in 0..<newWidth {
                        let start = hWeights.starts[x]
                        let offset = hWeights.offsets[x]
                        let count = hWeights.offsets[x + 1] - offset
                        var sum = 0.0
                        for k in 0..<count {
                            sum += Double(src[srcRow + start + k]) * hWeights.weights[offset + k]
                        }
                        dst[dstRow + x] = sum
                    }
                }
            }
        }

        // 2. Vertikaler Durchgang: newWidth × height → newWidth × newHeight
        var out = [UInt8](repeating: 0, count: newWidth * newHeight)
        temp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<newHeight {
                    let start = vWeights.starts[y]
                    let offset = vWeights.offsets[y]
                    let count = vWeights.offsets[y + 1] - offset
                    let dstRow = y * newWidth
                    for x in 0..<newWidth {
                        var sum = 0.0
                        for k in 0..<count {
                            sum += src[(start + k) * newWidth + x] * vWeights.weights[offset + k]
                        }
                        dst[dstRow + x] = UInt8(clamping: Int(sum.rounded()))
                    }
                }
            }
        }
        return GrayImage(width: newWidth, height: newHeight, pixels: out)
    }

    /// Skaliert das Bild seitenverhältnistreu so, dass es vollständig in `width × height`
    /// passt, und füllt den Rest gemäß `alignment` mit `fill` auf.
    public func scaledToFit(width boxWidth: Int, height boxHeight: Int,
                            alignment: ImageAlignment = .center, fill: UInt8 = 255) -> GrayImage {
        precondition(boxWidth >= 0 && boxHeight >= 0, "GrayImage.scaledToFit: negative Zielgröße")
        guard !isEmpty, boxWidth > 0, boxHeight > 0 else {
            return GrayImage(width: boxWidth, height: boxHeight, fill: fill)
        }
        let factor = min(Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
        let w = min(boxWidth, max(1, Int((Double(width) * factor).rounded())))
        let h = min(boxHeight, max(1, Int((Double(height) * factor).rounded())))
        return scaled(width: w, height: h).padded(toWidth: boxWidth, height: boxHeight, alignment: alignment, fill: fill)
    }

    /// Schneidet einen Ausschnitt aus. Das Ergebnis hat immer genau `width × height` Pixel;
    /// Bereiche außerhalb des Quellbildes werden weiß (255) aufgefüllt.
    public func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> GrayImage {
        precondition(cropWidth >= 0 && cropHeight >= 0, "GrayImage.cropped: negative Größe")
        return blit(into: cropWidth, cropHeight, offsetX: -x, offsetY: -y, fill: 255)
    }

    /// Bettet das Bild in eine Fläche der Größe `toWidth × height` ein (Ausrichtung gemäß
    /// `alignment`). Ist die Fläche kleiner als das Bild, wird entsprechend beschnitten.
    public func padded(toWidth newWidth: Int, height newHeight: Int,
                       alignment: ImageAlignment = .topLeading, fill: UInt8 = 255) -> GrayImage {
        precondition(newWidth >= 0 && newHeight >= 0, "GrayImage.padded: negative Größe")
        let ox = alignment.offset(content: width, container: newWidth, axis: false)
        let oy = alignment.offset(content: height, container: newHeight, axis: true)
        return blit(into: newWidth, newHeight, offsetX: ox, offsetY: oy, fill: fill)
    }

    /// Kopiert das Bild mit Versatz in eine neue Fläche.
    private func blit(into newWidth: Int, _ newHeight: Int, offsetX: Int, offsetY: Int, fill: UInt8) -> GrayImage {
        var out = [UInt8](repeating: fill, count: newWidth * newHeight)
        let x0 = max(0, offsetX), x1 = min(newWidth, offsetX + width)
        let y0 = max(0, offsetY), y1 = min(newHeight, offsetY + height)
        if x0 < x1 && y0 < y1 {
            let span = x1 - x0
            pixels.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for ny in y0..<y1 {
                        let sy = ny - offsetY
                        let srcStart = sy * width + (x0 - offsetX)
                        let dstStart = ny * newWidth + x0
                        for i in 0..<span { dst[dstStart + i] = src[srcStart + i] }
                    }
                }
            }
        }
        return GrayImage(width: newWidth, height: newHeight, pixels: out)
    }

    // MARK: Tonwerte

    /// Passt Helligkeit, Kontrast und Gamma an.
    ///
    /// - Parameters:
    ///   - brightness: −1…1, wird zum normierten Wert (0…1) addiert.
    ///   - contrast: −1…1; positive Werte spreizen um die Mitte mit Faktor `1 / (1 − c)`,
    ///     negative Werte stauchen mit Faktor `1 + c` (−1 ergibt einheitliches Mittelgrau).
    ///   - gamma: > 0; der normierte Wert wird mit `1 / gamma` potenziert
    ///     (gamma > 1 hellt Mitteltöne auf, gamma < 1 dunkelt sie ab).
    ///
    /// Reihenfolge: Kontrast → Helligkeit → Begrenzung auf 0…1 → Gamma → Rundung.
    /// Mit den Standardwerten bleibt das Bild unverändert.
    public func adjusted(brightness: Double = 0, contrast: Double = 0, gamma: Double = 1) -> GrayImage {
        if brightness == 0 && contrast == 0 && gamma == 1 { return self }
        let lut = Self.toneCurve(brightness: brightness, contrast: contrast, gamma: gamma)
        return GrayImage(width: width, height: height, pixels: pixels.map { lut[Int($0)] })
    }

    /// Erzeugt die Tonwertkurve (256 Einträge) für `adjusted`.
    static func toneCurve(brightness: Double, contrast: Double, gamma: Double) -> [UInt8] {
        let b = brightness.isFinite ? min(max(brightness, -1), 1) : 0
        let c = contrast.isFinite ? min(max(contrast, -1), 1) : 0
        let g = (gamma.isFinite && gamma > 0) ? gamma : 1
        let factor = c >= 0 ? 1 / max(1 - c, 1e-4) : 1 + c
        return (0...255).map { v -> UInt8 in
            var x = Double(v) / 255
            x = (x - 0.5) * factor + 0.5
            x += b
            x = min(max(x, 0), 1)
            if g != 1 { x = pow(x, 1 / g) }
            return UInt8(clamping: Int((x * 255).rounded()))
        }
    }

    /// Mittlere Helligkeit 0…255 (leeres Bild: 255).
    public var meanLuminance: Double {
        guard !pixels.isEmpty else { return 255 }
        var sum = 0
        for p in pixels { sum += Int(p) }
        return Double(sum) / Double(pixels.count)
    }
}

// MARK: - Resampling-Gewichte

/// Vorberechnete Gewichte für eine Achse (CSR-artig: `offsets[i]..<offsets[i+1]` in `weights`).
struct ResampleWeights {
    var starts: [Int] = []
    var offsets: [Int] = [0]
    var weights: [Double] = []

    init(source: Int, destination: Int) {
        starts.reserveCapacity(destination)
        offsets.reserveCapacity(destination + 1)
        if destination == source {
            for i in 0..<destination {
                starts.append(i)
                weights.append(1)
                offsets.append(weights.count)
            }
        } else if destination < source {
            // Flächenmittel: Ausgabepixel i deckt [i·s, (i+1)·s) der Quelle ab.
            let scale = Double(source) / Double(destination)
            for i in 0..<destination {
                let lo = Double(i) * scale
                let hi = min(Double(i + 1) * scale, Double(source))
                let first = Int(lo.rounded(.down))
                let last = min(source - 1, Int(hi.rounded(.up)) - 1)
                starts.append(first)
                var total = 0.0
                let base = weights.count
                for j in first...max(first, last) {
                    let overlap = min(hi, Double(j + 1)) - max(lo, Double(j))
                    let w = max(0, overlap)
                    weights.append(w)
                    total += w
                }
                // Normieren (gleicht Rundungsfehler aus).
                if total > 0 {
                    for k in base..<weights.count { weights[k] /= total }
                }
                offsets.append(weights.count)
            }
        } else {
            // Bilinear, pixelzentriert.
            let scale = Double(source) / Double(destination)
            for i in 0..<destination {
                var pos = (Double(i) + 0.5) * scale - 0.5
                pos = min(max(pos, 0), Double(source - 1))
                let j0 = Int(pos.rounded(.down))
                let f = pos - Double(j0)
                starts.append(j0)
                if j0 + 1 < source && f > 0 {
                    weights.append(1 - f)
                    weights.append(f)
                } else {
                    weights.append(1)
                }
                offsets.append(weights.count)
            }
        }
    }
}

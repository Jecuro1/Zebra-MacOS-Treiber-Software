import Foundation
import LabelWerkCore
import LabelWerkImaging

/// Bringt beliebige Bilder auf Etikettengröße – gemeinsam für App (Bilddruck, Designer) und
/// `lwctl print`/`lwctl encode`.
///
/// Reihenfolge: (1) drehen, (2) einpassen gemäß ``FitMode``, (3) ausrichten. Freie Flächen
/// werden weiß (bzw. mit `background`) gefüllt.
public enum ImageLayout {

    /// Art des Einpassens in die Zielfläche.
    public enum FitMode: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Seitenverhältnistreu so groß wie möglich, vollständig sichtbar (Ränder bleiben frei).
        case contain
        /// Seitenverhältnistreu flächenfüllend; Überstand wird abgeschnitten.
        case cover
        /// Exakt auf die Zielgröße verzerrt.
        case stretch
        /// Originalgröße (1 Bildpixel = 1 Druckpunkt); zu große Bilder werden beschnitten.
        case none

        public var id: String { rawValue }

        /// Deutscher Anzeigename.
        public var displayName: String {
            switch self {
            case .contain: return "Einpassen"
            case .cover: return "Füllen (beschneiden)"
            case .stretch: return "Strecken"
            case .none: return "Originalgröße"
            }
        }
    }

    /// Drehung vor dem Einpassen.
    public enum Rotation: Hashable, Sendable {
        /// Feste Drehung im Uhrzeigersinn.
        case fixed(QuarterTurn)
        /// Um 90° drehen, wenn Bild und Etikett unterschiedlich ausgerichtet sind
        /// (Querformat-Bild auf Hochformat-Etikett und umgekehrt).
        case automatic

        /// Liest `0`, `90`, `180`, `270` bzw. `auto`.
        public init?(argument: String) {
            let text = argument.trimmingCharacters(in: .whitespaces).lowercased()
            if text == "auto" || text == "automatisch" {
                self = .automatic
                return
            }
            guard let degrees = Int(text), [0, 90, 180, 270, -90].contains(degrees) else { return nil }
            self = .fixed(QuarterTurn(degrees: degrees))
        }
    }

    // MARK: - Zielgröße

    /// Etikettengröße in Punkten; die Breite wird auf `maxPrintWidthDots` (Kopfbreite) begrenzt.
    public static func labelSize(for stock: LabelStock, resolution: Resolution,
                                 maxPrintWidthDots: Int? = nil) -> (width: Int, height: Int) {
        var width = max(1, stock.widthDots(resolution))
        if let maxPrintWidthDots, maxPrintWidthDots > 0 { width = min(width, maxPrintWidthDots) }
        return (width, max(1, stock.heightDots(resolution)))
    }

    /// Größe des skalierten Bildinhalts (vor dem Auffüllen bzw. Beschneiden).
    public static func scaledSize(width: Int, height: Int, toFit boxWidth: Int, _ boxHeight: Int,
                                  mode: FitMode) -> (width: Int, height: Int) {
        guard width > 0, height > 0, boxWidth > 0, boxHeight > 0 else { return (max(0, boxWidth), max(0, boxHeight)) }
        switch mode {
        case .stretch:
            return (boxWidth, boxHeight)
        case .none:
            return (width, height)
        case .contain, .cover:
            let sx = Double(boxWidth) / Double(width)
            let sy = Double(boxHeight) / Double(height)
            let factor = mode == .contain ? min(sx, sy) : max(sx, sy)
            var w = max(1, Int((Double(width) * factor).rounded()))
            var h = max(1, Int((Double(height) * factor).rounded()))
            if mode == .contain {
                w = min(w, boxWidth)
                h = min(h, boxHeight)
            } else {
                w = max(w, boxWidth)
                h = max(h, boxHeight)
            }
            return (w, h)
        }
    }

    /// Drehung, die das Bild an die Ausrichtung der Zielfläche anpasst.
    public static func automaticTurn(imageWidth: Int, imageHeight: Int, targetWidth: Int, targetHeight: Int) -> QuarterTurn {
        let imageLandscape = imageWidth > imageHeight
        let targetLandscape = targetWidth > targetHeight
        guard imageWidth != imageHeight, targetWidth != targetHeight else { return .r0 }
        return imageLandscape == targetLandscape ? .r0 : .r90
    }

    // MARK: - Einpassen

    /// Passt ein Bild in `width × height` Punkte ein.
    public static func fit(_ image: GrayImage, width: Int, height: Int, mode: FitMode = .contain,
                           alignment: ImageAlignment = .center, background: UInt8 = 255) -> GrayImage {
        let width = max(0, width), height = max(0, height)
        guard width > 0, height > 0 else { return GrayImage(width: width, height: height, fill: background) }
        guard !image.isEmpty else { return GrayImage(width: width, height: height, fill: background) }
        switch mode {
        case .stretch:
            return image.scaled(width: width, height: height)
        case .none:
            return image.padded(toWidth: width, height: height, alignment: alignment, fill: background)
        case .contain, .cover:
            let size = scaledSize(width: image.width, height: image.height, toFit: width, height, mode: mode)
            return image.scaled(width: size.width, height: size.height)
                .padded(toWidth: width, height: height, alignment: alignment, fill: background)
        }
    }

    /// Dreht und passt ein Bild in `width × height` Punkte ein.
    public static func layout(_ image: GrayImage, width: Int, height: Int, mode: FitMode = .contain,
                              rotation: Rotation = .fixed(.r0), alignment: ImageAlignment = .center,
                              background: UInt8 = 255) -> GrayImage {
        let turn: QuarterTurn
        switch rotation {
        case .fixed(let fixed): turn = fixed
        case .automatic:
            turn = automaticTurn(imageWidth: image.width, imageHeight: image.height, targetWidth: width, targetHeight: height)
        }
        let rotated = turn == .r0 ? image : image.rotated(turn)
        return fit(rotated, width: width, height: height, mode: mode, alignment: alignment, background: background)
    }

    /// Dreht und passt ein Bild auf ein Etikettenformat ein.
    public static func layout(_ image: GrayImage, for stock: LabelStock, resolution: Resolution,
                              mode: FitMode = .contain, rotation: Rotation = .fixed(.r0),
                              alignment: ImageAlignment = .center, maxPrintWidthDots: Int? = nil,
                              background: UInt8 = 255) -> GrayImage {
        let size = labelSize(for: stock, resolution: resolution, maxPrintWidthDots: maxPrintWidthDots)
        return layout(image, width: size.width, height: size.height, mode: mode, rotation: rotation,
                      alignment: alignment, background: background)
    }
}

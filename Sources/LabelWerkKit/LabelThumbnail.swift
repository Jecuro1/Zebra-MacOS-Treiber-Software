import Foundation
import LabelWerkCore
import LabelWerkImaging
import LabelWerkRender

/// Kleine Vorschaubilder einzelner ZPL-Etiketten (Kopf + ein Format), z. B. für „Nachdrucken“ und den
/// Hinweis bei Papier-/Farbbandende. Rendert mit `ZPLInterpreter` und `SoftwareRasterizer` – rein
/// rechnend, also abseits des Main Threads aufrufen.
public enum LabelThumbnail {

    /// Text eines Auftrags für den Interpreter: UTF-8, sonst Latin-1 (binäre `^GFB`-Daten gehen nicht
    /// verloren, jedes Byte bleibt ein Zeichen).
    public static func text(of data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Rendert das erste Etikett aus `data` und verkleinert es (seitenverhältnistreu) auf höchstens
    /// `maxSide` Pixel. `nil`, wenn `data` kein Etikett enthält.
    /// - Parameters:
    ///   - dotsPerMM: Auflösung des Druckers (8 = 203 dpi, 12 = 300 dpi, 24 = 600 dpi).
    ///   - widthDots/heightDots: Etikettengröße, falls das Format sie nicht selbst setzt (`^PW`/`^LL`).
    public static func render(_ data: Data, dotsPerMM: Int = 8, widthDots: Int = 812, heightDots: Int = 1218,
                              maxSide: Int = 180) -> GrayImage? {
        let interpreter = ZPLInterpreter(dotsPerMM: max(1, dotsPerMM), defaultWidthDots: max(8, widthDots),
                                         defaultHeightDots: max(8, heightDots))
        guard let label = interpreter.render(text(of: data)).labels.first else { return nil }
        let image = SoftwareRasterizer.rasterize(label).toGrayImage()
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(max(1, maxSide)) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        return image.scaled(width: width, height: height)
    }
}

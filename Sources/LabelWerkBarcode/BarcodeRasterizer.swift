import Foundation

/// Rastert Barcodes in Pixelraster (`true` = schwarz), z. B. für Tests, Vorschauen und das
/// Software-Rendering von Etiketten.
///
/// Ruhezonen werden in **Moduln** angegeben und mit der Modulbreite bzw. -größe multipliziert.
public enum BarcodeRasterizer {

    /// Rastert einen linearen Barcode.
    ///
    /// - Parameters:
    ///   - moduleWidth: Breite eines schmalen Elements in Pixeln (mindestens 1).
    ///   - ratio: Verhältnis breit : schmal für Zweibreiten-Codes (2,0…3,0).
    ///   - height: Balkenhöhe in Pixeln (mindestens 1); das Ergebnis hat genau diese Höhe.
    ///   - quietZone: Ruhezone links und rechts in Moduln (0 = keine).
    /// - Returns: Breite, Höhe und zeilenweise Pixel (`true` = schwarz).
    public static func render(_ barcode: LinearBarcode, moduleWidth: Int, ratio: Double, height: Int,
                              quietZone: Int) -> (width: Int, height: Int, pixels: [Bool]) {
        let module = max(1, moduleWidth)
        let rows = max(1, height)
        let margin = max(0, quietZone) * module
        let widths = barcode.widthsInDots(moduleWidth: module, ratio: ratio)
        let symbolWidth = widths.reduce(0) { $0 + $1.dots }
        let width = symbolWidth + 2 * margin

        var row = [Bool](repeating: false, count: width)
        var x = margin
        for element in widths {
            if element.isBar {
                for i in x..<(x + element.dots) { row[i] = true }
            }
            x += element.dots
        }
        var pixels: [Bool] = []
        pixels.reserveCapacity(width * rows)
        for _ in 0..<rows { pixels.append(contentsOf: row) }
        return (width, rows, pixels)
    }

    /// Rastert eine 2D-Matrix mit quadratischen Modulen.
    ///
    /// - Parameters:
    ///   - moduleSize: Kantenlänge eines Moduls in Pixeln (mindestens 1).
    ///   - quietZone: Ruhezone an allen vier Seiten in Moduln (0 = keine).
    public static func render(_ matrix: BitMatrix, moduleSize: Int, quietZone: Int) -> (width: Int, height: Int, pixels: [Bool]) {
        let module = max(1, moduleSize)
        let margin = max(0, quietZone)
        let width = (matrix.width + 2 * margin) * module
        let height = (matrix.height + 2 * margin) * module
        var pixels = [Bool](repeating: false, count: width * height)
        for my in 0..<matrix.height {
            let rowStart = (my + margin) * module
            for mx in 0..<matrix.width where matrix.bits[my * matrix.width + mx] {
                let columnStart = (mx + margin) * module
                for py in rowStart..<(rowStart + module) {
                    let base = py * width + columnStart
                    for px in 0..<module { pixels[base + px] = true }
                }
            }
        }
        return (width, height, pixels)
    }
}

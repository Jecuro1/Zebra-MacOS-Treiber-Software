import Foundation
import LabelWerkKit

// Etikettendruck („Mit LabelWerk drucken“): Die Vorschau ist der Druck.
//
// Jede Seite läuft genau den Weg des Treibers bzw. von `JobEncoder.encode(images:pageSizes:)`:
//   1. Seite in Graustufen in der Druckerauflösung (Seitengröße in Punkten wie `cupsPageSize`),
//   2. Schritt F „An Etikett anpassen“ mit der Referenz des Auftrags (`JobEncoder.fitted(_:pageSize:reference:)`
//      – Seite für Seite in Druckreihenfolge, also einheitliche Drehung und Maßstab wie im Treiber),
//   3. Rastern (`JobEncoder.dithered`) → `MonoBitmap` – das ist die Druckseite,
//   4. Vorschau: `JobEncoder.preprocess` (Schritte 0–5: Drehung, Abschneiden auf die Druckbreite, Negativ,
//      Leerseiten …) und danach das, was der Drucker selbst tut (ZPL `^LS`/`^LT`, `^PM`, `^PO`; EPL `ZB`),
//      auf einem Etikett in Originalgröße (`LabelPrintComposer`).
// Gedruckt werden die Bitmaps aus 3 mit `JobEncoder.encode(pages:)` – dieselben Bytes wie
// `encode(images:pageSizes:)` (Test `streamingFitMatchesJob` in LabelWerkImagingTests).

/// Alles, was die Ausgabe eines Etikettendrucks bestimmt: Drucker, Etikettentyp, wirksame Einstellungen
/// (mit `lwLabelWidth`/`lwLabelHeight` aus dem Format des Typs), Sprache, Auflösung, Druckbreite.
struct LabelPrintTarget: Hashable, Sendable {
    var printerID: UUID
    /// `nil` = Standard des Druckers (seine eigenen Einstellungen und sein Format).
    var labelTypeID: UUID?
    var language: PrinterLanguage
    var resolution: Resolution
    var settings: PrintSettings
    var stock: LabelStock
    var maxPrintWidthDots: Int?

    init(printerID: UUID, labelTypeID: UUID?, language: PrinterLanguage, resolution: Resolution,
         settings: PrintSettings, stock: LabelStock, maxPrintWidthDots: Int?) {
        self.printerID = printerID
        self.labelTypeID = labelTypeID
        self.language = language
        self.resolution = resolution
        // Wie die Warteschlange (QueueDefaults.plan): Größe für Schritt F aus dem Format.
        self.settings = settings.withLabelSize(of: stock)
        self.stock = stock
        self.maxPrintWidthDots = maxPrintWidthDots.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Der Encoder des Auftrags (identisch für Vorschau und Druck).
    var encoder: JobEncoder {
        JobEncoder(language: language, resolution: resolution, settings: settings, stock: stock,
                   maxPrintWidthDots: maxPrintWidthDots)
    }

    /// Etikettenbreite in Punkten (quer zum Druckkopf).
    var labelWidthDots: Int { max(1, stock.widthDots(resolution)) }

    /// Etikettenlänge in Punkten; `nil` bei Endlosmaterial (die Länge folgt dem Inhalt).
    var labelHeightDots: Int? {
        let tracking = settings.clamped().tracking ?? stock.tracking
        if tracking == .continuous || stock.isContinuous { return nil }
        return max(1, stock.heightDots(resolution))
    }
}

/// Eine Seite des Auftrags nach der Aufbereitung.
struct LabelPrintRenderedPage: Sendable {
    /// Gerasterte Druckseite (Eingang von `JobEncoder.encode(pages:)`).
    var bitmap: MonoBitmap
    /// Das Etikett, wie es aus dem Drucker kommt (Etikettengröße); `nil`, wenn der Treiber die Seite
    /// überspringt („Leere Etiketten überspringen“ bzw. keine Fläche).
    var label: MonoBitmap?
    /// Schritt F hat die Seite auf das Etikett gelegt (Seitengröße wich mehr als 2 mm ab).
    var wasFitted: Bool
    /// Teile des Inhalts liegen außerhalb des Etiketts bzw. der Druckbreite und fehlen im Druck.
    var isClipped: Bool
}

enum LabelPrintPipeline {
    /// Bereitet die nächste Seite des Auftrags auf (`reference` von Seite zu Seite weiterreichen,
    /// anfangs `nil`; Reihenfolge = Druckreihenfolge).
    static func render(_ page: GrayImage, pageSize: PageSizePoints?, target: LabelPrintTarget,
                       encoder: JobEncoder, reference: inout LabelFit.Reference?) -> LabelPrintRenderedPage {
        let wasFitted = LabelFit.plan(settings: target.settings, pageSize: pageSize,
                                      xDPI: target.resolution.dpi, yDPI: target.resolution.dpi,
                                      imageWidth: page.width, imageHeight: page.height) != nil
        let fitted = encoder.fitted(page, pageSize: pageSize, reference: &reference)
        let bitmap = encoder.dithered(fitted)
        guard let processed = encoder.preprocess(bitmap) else {
            return LabelPrintRenderedPage(bitmap: bitmap, label: nil, wasFitted: wasFitted, isClipped: false)
        }
        let composed = LabelPrintComposer.physicalLabel(processed, target: target)
        // Abgeschnitten: über die Druckbreite (Schritt 1) oder über den Etikettenrand hinaus.
        return LabelPrintRenderedPage(bitmap: bitmap, label: composed.bitmap, wasFitted: wasFitted,
                                      isClipped: composed.clipped || hasInkBeyondPrintWidth(bitmap, target: target))
    }

    /// Schwarze Punkte jenseits der Druckbreite (nach der Benutzer-Drehung, vor dem Abschneiden in
    /// Schritt 1)?
    static func hasInkBeyondPrintWidth(_ bitmap: MonoBitmap, target: LabelPrintTarget) -> Bool {
        guard let maxWidth = target.maxPrintWidthDots else { return false }
        let oriented: MonoBitmap
        switch target.settings.clamped().effectiveRotation {
        case .r90: oriented = bitmap.rotated(.r90)
        case .r270: oriented = bitmap.rotated(.r270)
        case .r0, .r180: oriented = bitmap
        }
        guard oriented.width > maxWidth else { return false }
        for y in 0..<oriented.height {
            for x in maxWidth..<oriented.width where oriented[x, y] { return true }
        }
        return false
    }

    /// Anzahl gedruckter Etiketten: Seiten, die der Treiber nicht überspringt, mal Kopien.
    static func labelCount(_ pages: [LabelPrintRenderedPage], copies: Int) -> Int {
        pages.filter { $0.label != nil }.count * max(1, copies)
    }

    /// Kodiert den Auftrag aus den aufbereiteten Seiten (sortiert: A B A B … wie der Treiber).
    static func encode(_ pages: [LabelPrintRenderedPage], target: LabelPrintTarget, copies: Int) throws -> Data {
        try target.encoder.encode(pages: pages.map(\.bitmap), copies: max(1, copies), collate: true)
    }
}

/// Setzt eine vorverarbeitete Druckseite so auf ein Etikett, wie der Drucker sie ausgibt.
enum LabelPrintComposer {
    /// - Etikett: Breite des Formats; Länge des Formats bzw. bei Endlosmaterial die Seitenlänge.
    /// - ZPL: `^LS` (positiv = nach links) und `^LT` (positiv = nach unten) verschieben das Bild,
    ///   `^PM` spiegelt, `^POI` dreht um 180°. EPL: `ZB` dreht um 180° (Spiegeln hat der Encoder schon
    ///   erledigt). CPCL: Drehung und Spiegeln stecken schon in der Bitmap.
    /// - `clipped`: schwarze Punkte, die außerhalb des Etiketts landen.
    static func physicalLabel(_ page: MonoBitmap, target: LabelPrintTarget) -> (bitmap: MonoBitmap, clipped: Bool) {
        let s = target.settings.clamped()
        let width = target.labelWidthDots
        let isZPL = target.language == .zpl
        let dx = isZPL ? -(s.labelLeft ?? 0) : 0
        let dy = isZPL ? (s.labelTop ?? 0) : 0
        let height = target.labelHeightDots ?? max(1, page.height)
        var canvas = MonoBitmap(width: width, height: height)
        var clipped = false
        let bytesPerRow = page.bytesPerRow
        for y in 0..<page.height {
            let ty = y + dy
            let rowStart = y * bytesPerRow
            for byteIndex in 0..<bytesPerRow {
                let byte = page.data[rowStart + byteIndex]
                if byte == 0 { continue }
                for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                    let x = byteIndex * 8 + bit
                    guard x < page.width else { break }
                    let tx = x + dx
                    if tx >= 0, tx < width, ty >= 0, ty < height {
                        canvas[tx, ty] = true
                    } else {
                        clipped = true
                    }
                }
            }
        }
        if isZPL && s.mirror { canvas = canvas.mirrored() }
        if s.effectiveRotation == .r180 && target.language != .cpcl { canvas = canvas.rotated180() }
        return (canvas, clipped)
    }
}

/// Seitenauswahl „1–3, 5“ (für Anzeige und Zusammenfassung).
enum LabelPrintPageRanges {
    /// Aufsteigende 1-basierte Bereiche aus 0-basierten Seitenindizes, z. B. [0, 1, 2, 4] → „1–3, 5“.
    static func describe(_ indices: [Int]) -> String {
        let sorted = Array(Set(indices)).sorted()
        var parts: [String] = []
        var start: Int?
        var previous: Int?
        func flush() {
            guard let start, let previous else { return }
            parts.append(start == previous ? "\(start + 1)" : "\(start + 1)–\(previous + 1)")
        }
        for index in sorted {
            if let p = previous, index == p + 1 {
                previous = index
            } else {
                flush()
                start = index
                previous = index
            }
        }
        flush()
        return parts.joined(separator: ", ")
    }
}

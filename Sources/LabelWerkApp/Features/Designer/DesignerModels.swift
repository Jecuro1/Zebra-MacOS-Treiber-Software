import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Modi & Optionen

/// Arbeitsbereiche des Designers.
enum DesignerMode: String, CaseIterable, Identifiable {
    case zpl
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zpl: return tr("ZPL-Designer")
        case .image: return tr("Bild & PDF")
        }
    }

    var systemImage: String {
        switch self {
        case .zpl: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo.on.rectangle.angled"
        }
    }
}

/// Darstellung der Live-Vorschau.
enum DesignerPreviewStyle: String, CaseIterable, Identifiable {
    /// Vektor-Rendering der Displayliste (scharf bei jedem Zoom).
    case vector
    /// Exakt wie gedruckt: Software-Rasterizer in Druckerauflösung.
    case pixel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vector: return tr("Vektor")
        case .pixel: return tr("Pixelgenau")
        }
    }

    var systemImage: String {
        switch self {
        case .vector: return "scribble.variable"
        case .pixel: return "square.grid.3x3.fill"
        }
    }
}

/// Bereiche des Inspektors unter der Vorschau.
enum DesignerInspectorTab: String, CaseIterable, Identifiable {
    case elements
    case warnings

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .elements: return "square.on.square.dashed"
        case .warnings: return "exclamationmark.bubble"
        }
    }
}

/// Zustand eines Sendevorgangs (steuert die Animation des Druckknopfs).
enum DesignerSendPhase: Equatable {
    case idle
    case sending
    case success
    case failure
}

/// Werte der „Etikett fährt in den Drucker“-Animation nach erfolgreichem Druck.
struct DesignerPrintMotion {
    var offset: Double = 0
    var scale: Double = 1
    var opacity: Double = 1
}

// MARK: - Zieletikett

/// Alles, was der Designer über das Ziel wissen muss: Drucker, Auflösung, Etikettengröße.
struct DesignerTarget: Equatable {
    var sessionID: UUID?
    var printerName: String?
    var modelName: String?
    var resolution: Resolution
    var stock: LabelStock
    var widthDots: Int
    var heightDots: Int
    var language: PrinterLanguage
    var maxPrintWidthDots: Int?
    var isStockOverridden: Bool

    var geometry: DesignerLabelGeometry {
        DesignerLabelGeometry(widthDots: widthDots, heightDots: heightDots, dotsPerMM: resolution.dotsPerMM)
    }

    var widthMM: Double { resolution.mm(fromDots: widthDots) }
    var heightMM: Double { resolution.mm(fromDots: heightDots) }

    var sizeText: String {
        tr("%@ × %@ mm", DesignerFormat.mm(widthMM), DesignerFormat.mm(heightMM))
    }

    /// z. B. „Zebra ZD421t · 203 dpi · 101,6 × 152,4 mm“
    var detailLine: String {
        let parts: [String?] = [modelName, tr("%d dpi", resolution.dpi), sizeText]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var summary: String {
        (printerName ?? tr("Ohne Drucker")) + " · " + detailLine
    }

    /// Ermittelt das Ziel aus Drucker, optional abweichendem Etikettenformat und Ersatzauflösung.
    @MainActor
    static func make(session: PrinterSession?, stockOverride: LabelStock?, fallbackResolution: Resolution) -> DesignerTarget {
        let resolution = session?.resolution ?? fallbackResolution
        let fallbackStock = ModelCatalog.shared.stock(id: "w4h6in")
            ?? LabelStock(id: "w4h6in", name: tr("4 × 6 Zoll"), widthMM: 101.6, heightMM: 152.4,
                          category: .shipping, isCustom: false)
        let stock = stockOverride ?? session?.stock ?? fallbackStock
        let headWidth = session?.model?.printWidthDots(resolution)
        var width = stock.widthDots(resolution)
        if let headWidth { width = min(width, headWidth) }
        return DesignerTarget(
            sessionID: session?.id,
            printerName: session?.displayName,
            modelName: session?.model?.displayName,
            resolution: resolution,
            stock: stock,
            widthDots: max(32, width),
            heightDots: max(32, stock.heightDots(resolution)),
            language: session?.saved.language ?? .zpl,
            maxPrintWidthDots: headWidth,
            isStockOverridden: stockOverride != nil
        )
    }
}

extension DesignerTemplate {
    /// Passende Startvorlage für ein Etikettenformat.
    static func suggested(for stock: LabelStock) -> DesignerTemplate {
        switch stock.category {
        case .shipping: return .shipping
        case .product: return .product
        case .barcode: return .shelf
        case .address: return .address
        case .jewelry: return .priceTag
        default: return stock.widthMM >= 80 && stock.heightMM >= 100 ? .shipping : .product
        }
    }
}

// MARK: - Formatierung

enum DesignerFormat {
    static func mm(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    static func mm(dots: Int, dotsPerMM: Int) -> String {
        mm(Double(dots) / Double(max(1, dotsPerMM)))
    }

    static func position(x: Int, y: Int, dotsPerMM: Int) -> String {
        tr("x %@ · y %@ mm", mm(dots: x, dotsPerMM: dotsPerMM), mm(dots: y, dotsPerMM: dotsPerMM))
    }

    static func size(width: Int, height: Int, dotsPerMM: Int) -> String {
        tr("%@ × %@ mm", mm(dots: width, dotsPerMM: dotsPerMM), mm(dots: height, dotsPerMM: dotsPerMM))
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func signedPercent(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent) %" : "\(percent) %"
    }
}

// MARK: - Elementbeschreibung (Inspektor)

/// Lesbare Beschreibung eines Elements der Displayliste.
struct DesignerElementInfo {
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color

    /// Anzeigenamen der Symbologien (über den Rohwert, damit neue Fälle nicht brechen).
    private static let symbologyNames: [String: String] = [
        "code128": "Code 128", "code39": "Code 39", "code93": "Code 93", "ean13": "EAN-13", "ean8": "EAN-8",
        "upcA": "UPC-A", "upcE": "UPC-E", "interleaved2of5": "Interleaved 2 of 5", "codabar": "Codabar",
        "qr": "QR-Code", "dataMatrix": "DataMatrix", "pdf417": "PDF417",
    ]

    static func symbologyName(_ symbology: BarcodeSymbology) -> String {
        symbologyNames[symbology.rawValue] ?? symbology.rawValue.uppercased()
    }

    private static func quoted(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        let short = single.count > 60 ? String(single.prefix(60)) + "…" : single
        return tr("„%@“", short)
    }

    static func make(_ element: LabelElement) -> DesignerElementInfo {
        switch element {
        case .text(let text):
            return DesignerElementInfo(title: text.reverse ? tr("Text (invertiert)") : tr("Text"),
                                       detail: quoted(text.text), systemImage: "textformat", tint: Theme.violet)
        case .box(let box):
            let shortSide = min(box.width, box.height)
            let title: String
            let symbol: String
            if box.thickness >= shortSide && max(box.width, box.height) > shortSide * 4 {
                title = tr("Linie")
                symbol = "line.horizontal.3"
            } else if box.thickness * 2 >= shortSide {
                title = tr("Fläche")
                symbol = "rectangle.fill"
            } else {
                title = tr("Rahmen")
                symbol = "rectangle"
            }
            return DesignerElementInfo(title: title, detail: tr("Linienstärke %d Punkte", box.thickness),
                                       systemImage: symbol, tint: Theme.indigo)
        case .ellipse(let ellipse):
            let isCircle = ellipse.width == ellipse.height
            return DesignerElementInfo(title: isCircle ? tr("Kreis") : tr("Ellipse"),
                                       detail: tr("Linienstärke %d Punkte", ellipse.thickness),
                                       systemImage: isCircle ? "circle" : "oval", tint: Theme.indigo)
        case .diagonal(let diagonal):
            return DesignerElementInfo(title: tr("Diagonale"), detail: tr("Linienstärke %d Punkte", diagonal.thickness),
                                       systemImage: "line.diagonal", tint: Theme.indigo)
        case .graphic(let graphic):
            return DesignerElementInfo(title: tr("Grafik"),
                                       detail: tr("%d × %d Punkte", graphic.bitmap.width, graphic.bitmap.height),
                                       systemImage: "photo", tint: Theme.magenta)
        case .linearBarcode(let barcode):
            return DesignerElementInfo(title: symbologyName(barcode.symbology), detail: quoted(barcode.text),
                                       systemImage: "barcode", tint: Theme.teal)
        case .matrixBarcode(let barcode):
            return DesignerElementInfo(title: symbologyName(barcode.symbology), detail: quoted(barcode.text),
                                       systemImage: barcode.symbology.rawValue == "qr" ? "qrcode" : "square.grid.3x3",
                                       tint: Theme.teal)
        }
    }
}

// MARK: - Geometrie der Vorschau

enum DesignerCanvasMath {
    /// Größte Fläche mit dem Seitenverhältnis des Etiketts, die in `available` passt.
    static func fitSize(widthDots: Int, heightDots: Int, in available: CGSize) -> CGSize {
        let w = CGFloat(max(1, widthDots)), h = CGFloat(max(1, heightDots))
        let scale = max(0.0001, min(available.width / w, available.height / h))
        return CGSize(width: max(24, w * scale), height: max(24, h * scale))
    }

    /// Umrandung eines Elements in Anzeigekoordinaten (Punkte), berücksichtigt `^POI`/`^PMY`
    /// genau wie `LabelCanvas` und `DesignerRaster.asPrinted(_:)`.
    static func displayRect(of index: Int, in label: RenderedLabel) -> CGRect? {
        guard label.elements.indices.contains(index) else { return nil }
        let box = label.elements[index].boundingBox
        var rect = CGRect(x: box.x, y: box.y, width: max(1, box.width), height: max(1, box.height))
        let width = CGFloat(label.widthDots), height = CGFloat(label.heightDots)
        if label.inverted != label.mirrored { rect.origin.x = width - rect.maxX }
        if label.inverted { rect.origin.y = height - rect.maxY }
        return rect
    }

    /// Kleinstes Element unter dem Mauszeiger (innere Elemente gewinnen gegen Rahmen).
    static func element(at point: CGPoint, viewSize: CGSize, in label: RenderedLabel) -> Int? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let dot = CGPoint(x: point.x / viewSize.width * CGFloat(label.widthDots),
                          y: point.y / viewSize.height * CGFloat(label.heightDots))
        let tolerance = max(2, CGFloat(label.widthDots) / viewSize.width * 4)
        var best: (index: Int, area: CGFloat)?
        for index in label.elements.indices {
            guard let rect = displayRect(of: index, in: label),
                  rect.insetBy(dx: -tolerance, dy: -tolerance).contains(dot) else { continue }
            let area = rect.width * rect.height
            if let current = best, current.area < area { continue }
            best = (index, area)
        }
        return best?.index
    }

    /// Ausdehnung eines Rechtecks (Punkte) auf einer Achse in Millimetern.
    static func span(_ rect: CGRect, horizontal: Bool, dotsPerMM: Int) -> ClosedRange<Double> {
        let dpmm = Double(max(1, dotsPerMM))
        let lower = Double(horizontal ? rect.minX : rect.minY) / dpmm
        let upper = Double(horizontal ? rect.maxX : rect.maxY) / dpmm
        return lower...max(lower, upper)
    }
}

// MARK: - Rasterung „wie gedruckt“

/// Druckaufträge aus dem ZPL-Designer für Drucker ohne ZPL (EPL/CPCL).
enum DesignerGraphicJob: Sendable {
    /// Gerasterte Etiketten in Druckreihenfolge und Kopien des Auftrags (> 1 nur bei einem Bild).
    case ready(images: [GrayImage], copies: Int)
    /// Das Dokument enthält kein Etikett.
    case empty
    /// Die Mengen mehrerer Etiketten ergäben mehr Einzelbilder als sinnvoll übertragbar.
    case tooManyLabels(Int)
}

enum DesignerRaster {
    /// Obergrenze für einzeln gerasterte Etiketten, wenn mehrere Etiketten Mengen > 1 haben.
    static let maximumExpandedLabels = 2000

    /// Pixelgenaue Rasterung „wie gedruckt“. `^POI` (180°) und `^PMY` (Spiegeln) werden hier
    /// selbst angewendet – unabhängig davon, ob `SoftwareRasterizer` die Flags auswertet. So passt
    /// das Ergebnis immer zur Vektorvorschau (`LabelCanvas`) und zu `DesignerCanvasMath.displayRect`.
    static func asPrinted(_ label: RenderedLabel) -> MonoBitmap {
        var plain = label
        plain.inverted = false
        plain.mirrored = false
        var bitmap = SoftwareRasterizer.rasterize(plain)
        if label.inverted { bitmap = bitmap.rotated180() }
        if label.mirrored { bitmap = bitmap.mirrored() }
        return bitmap
    }

    /// Rastert alle Etiketten eines ZPL-Dokuments für den Grafikdruck. Eine `^PQ`-Menge im Format
    /// hat Vorrang vor `copies` – genau wie beim ZPL-Druck (`PrinterSession.applyingQuantity`).
    static func graphicJob(zpl: String, geometry: DesignerLabelGeometry, copies: Int) -> DesignerGraphicJob {
        let document = ZPLInterpreter(dotsPerMM: geometry.dotsPerMM,
                                      defaultWidthDots: geometry.widthDots,
                                      defaultHeightDots: geometry.heightDots).render(zpl)
        let labels = document.labels.filter { $0.widthDots > 0 && $0.heightDots > 0 }
        guard !labels.isEmpty else { return .empty }
        let quantities = labels.map { $0.quantity > 1 ? $0.quantity : max(1, copies) }
        // Ein Etikett bzw. jedes Etikett nur einmal: Die Menge geht als Kopien in den Auftrag.
        if labels.count == 1 || quantities.allSatisfy({ $0 == 1 }) {
            return .ready(images: labels.map { asPrinted($0).toGrayImage() }, copies: quantities[0])
        }
        // Mehrere Etiketten: jedes in seiner Menge hintereinander (A A A B B B) wie `^PQ` beim
        // ZPL-Druck. `PrinterSession.printImages` sortiert Kopien (A B A B A B), deshalb werden
        // die Etiketten hier einzeln aufgereiht und als ein Durchlauf gesendet.
        let total = quantities.reduce(0, +)
        guard total <= maximumExpandedLabels else { return .tooManyLabels(total) }
        var images: [GrayImage] = []
        images.reserveCapacity(total)
        for (label, quantity) in zip(labels, quantities) {
            // Gleiche Bilder teilen sich den Speicher (Copy-on-Write).
            images.append(contentsOf: repeatElement(asPrinted(label).toGrayImage(), count: quantity))
        }
        return .ready(images: images, copies: 1)
    }
}

// MARK: - Zustand der ZPL-Vorschau

struct DesignerRenderKey: Equatable {
    var zpl: String
    var geometry: DesignerLabelGeometry
}

struct DesignerRasterRequest: Equatable {
    var generation: Int
    var index: Int
    var style: DesignerPreviewStyle
}

/// Live-Vorschau des ZPL-Designers: Rendering im Hintergrund (entprellt), Seitenwahl,
/// pixelgenaue Rasterung und Hervorhebung von Elementen.
@Observable
@MainActor
final class DesignerPreviewState {
    private(set) var document: LabelDocument?
    /// Zählt jedes neue Rendering (Schlüssel für abhängige Berechnungen).
    private(set) var generation = 0
    private(set) var labelIndex = 0
    /// Richtung des letzten Seitenwechsels (für die Übergangsanimation).
    private(set) var pagingForward = true
    private(set) var isRendering = false
    private(set) var renderMilliseconds = 0
    private(set) var raster: MonoBitmap?
    private(set) var rasterRequest: DesignerRasterRequest?
    private(set) var isRasterizing = false
    private(set) var hoveredElement: Int?
    private(set) var pinnedElement: Int?
    /// Hover kam aus der Vorschau (dann scrollt die Elementliste mit).
    private(set) var hoverFromCanvas = false

    @ObservationIgnored private var renderToken = 0
    @ObservationIgnored private var rasterToken = 0
    @ObservationIgnored private var lastKey: DesignerRenderKey?

    var labels: [RenderedLabel] { document?.labels ?? [] }

    var currentLabel: RenderedLabel? {
        guard let labels = document?.labels, !labels.isEmpty else { return nil }
        return labels[min(max(0, labelIndex), labels.count - 1)]
    }

    var highlightedElement: Int? { hoveredElement ?? pinnedElement }

    /// `true`, wenn die angezeigte Rasterung nicht zum aktuellen Etikett gehört.
    var isRasterStale: Bool {
        rasterRequest?.generation != generation || rasterRequest?.index != labelIndex
    }

    /// Rendert das Dokument im Hintergrund; bei `debounce` erst nach 250 ms Ruhe.
    func render(_ key: DesignerRenderKey, debounce: Bool) async {
        if key == lastKey, document != nil {
            // Zurück auf den angezeigten Stand (z. B. ⌘Z): Ein noch laufendes Rendering eines
            // verworfenen Stands darf danach nicht mehr landen.
            renderToken += 1
            isRendering = false
            return
        }
        if debounce && document != nil {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        renderToken += 1
        let token = renderToken
        isRendering = true
        let started = Date()
        let rendered = await Task.detached(priority: .userInitiated) {
            ZPLInterpreter(dotsPerMM: key.geometry.dotsPerMM,
                           defaultWidthDots: key.geometry.widthDots,
                           defaultHeightDots: key.geometry.heightDots).render(key.zpl)
        }.value
        guard token == renderToken else { return }
        let previousCount = document?.labels.count ?? 0
        document = rendered
        lastKey = key
        generation += 1
        isRendering = false
        renderMilliseconds = max(1, Int(Date().timeIntervalSince(started) * 1000))
        if labelIndex >= rendered.labels.count { labelIndex = max(0, rendered.labels.count - 1) }
        let elementCount = currentLabel?.elements.count ?? 0
        if rendered.labels.count != previousCount { pinnedElement = nil }
        if let pinned = pinnedElement, pinned >= elementCount { pinnedElement = nil }
        if let hovered = hoveredElement, hovered >= elementCount { hoveredElement = nil }
    }

    /// Rastert das aktuelle Etikett pixelgenau (nur im Pixelmodus, nur bei Bedarf).
    func rasterizeIfNeeded(style: DesignerPreviewStyle) async {
        guard style == .pixel, let label = currentLabel else { return }
        let request = DesignerRasterRequest(generation: generation, index: labelIndex, style: .pixel)
        guard rasterRequest != request else { return }
        rasterToken += 1
        let token = rasterToken
        isRasterizing = true
        let bitmap = await Task.detached(priority: .userInitiated) {
            DesignerRaster.asPrinted(label)
        }.value
        // Eine neuere Rasterung läuft bereits – sie setzt Ergebnis und Anzeige.
        guard token == rasterToken else { return }
        isRasterizing = false
        guard generation == request.generation, labelIndex == request.index else { return }
        raster = bitmap
        rasterRequest = request
    }

    func select(_ index: Int) {
        guard index != labelIndex, labels.indices.contains(index) else { return }
        pagingForward = index > labelIndex
        labelIndex = index
        hoveredElement = nil
        pinnedElement = nil
    }

    func hover(_ index: Int?, fromCanvas: Bool) {
        if hoverFromCanvas != fromCanvas { hoverFromCanvas = fromCanvas }
        if hoveredElement != index { hoveredElement = index }
    }

    func endHover(_ index: Int) {
        if hoveredElement == index { hoveredElement = nil }
    }

    func togglePin(_ index: Int?) {
        if let index, pinnedElement != index {
            pinnedElement = index
        } else {
            pinnedElement = nil
        }
    }
}

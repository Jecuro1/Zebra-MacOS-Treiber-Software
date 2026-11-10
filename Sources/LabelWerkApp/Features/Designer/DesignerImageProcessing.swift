import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Werte

/// Geladenes Bild bzw. PDF. PDF-Seiten werden erst bei Bedarf in Druckerauflösung gerendert
/// (`DesignerPDFPages`), damit auch lange PDFs sofort erscheinen und wenig Speicher belegen.
struct DesignerImageSource: @unchecked Sendable {
    let id = UUID()
    let name: String
    let url: URL
    let isPDF: Bool
    /// Auflösung, mit der PDF-Seiten gerendert werden.
    let renderedDPI: Int
    /// Nutzbare Seiten (bei PDFs höchstens `DesignerImageProcessing.maximumPDFPages`).
    let pageCount: Int
    /// Seiten im Dokument insgesamt.
    let totalPageCount: Int
    /// Größe der ersten Seite in Pixeln.
    let pixelWidth: Int
    let pixelHeight: Int
    private let bitmap: CGImage?
    private let bitmapThumbnail: CGImage?
    private let pdf: DesignerPDFPages?

    /// Einzelbild (PNG, JPEG, TIFF …).
    init(name: String, url: URL, image: CGImage, thumbnail: CGImage?, dpi: Int) {
        self.name = name
        self.url = url
        isPDF = false
        renderedDPI = dpi
        pageCount = 1
        totalPageCount = 1
        pixelWidth = image.width
        pixelHeight = image.height
        bitmap = image
        bitmapThumbnail = thumbnail
        pdf = nil
    }

    /// PDF mit Seiten auf Abruf.
    init(name: String, url: URL, pdf: DesignerPDFPages, dpi: Int) {
        self.name = name
        self.url = url
        isPDF = true
        renderedDPI = dpi
        pageCount = pdf.count
        totalPageCount = pdf.totalCount
        pixelWidth = pdf.firstPageWidth
        pixelHeight = pdf.firstPageHeight
        bitmap = nil
        bitmapThumbnail = nil
        self.pdf = pdf
    }

    /// Seite in Druckerauflösung (PDF: wird bei Bedarf gerendert – nicht auf dem Hauptthread aufrufen).
    func page(at index: Int) -> CGImage? {
        guard index >= 0, index < pageCount else { return nil }
        if let pdf { return pdf.image(at: index) }
        return bitmap
    }

    /// Kleines Vorschaubild einer Seite (PDF: wird bei Bedarf gerendert).
    func thumbnail(at index: Int) -> CGImage? {
        guard index >= 0, index < pageCount else { return nil }
        if let pdf { return pdf.thumbnail(at: index) }
        return bitmapThumbnail ?? bitmap
    }
}

/// Seiten eines PDFs auf Abruf: Gerendert wird nur, was gebraucht wird (aktuelle Seite bzw. beim
/// Druck „Alle Seiten“ eine nach der anderen). Die zuletzt benutzten Seiten und alle Vorschaubilder
/// bleiben im Zwischenspeicher. Seiten und Vorschaubilder nutzen je ein eigenes Dokumentobjekt mit
/// eigener Sperre – die Seitenleiste bremst die große Vorschau also nicht aus.
final class DesignerPDFPages: @unchecked Sendable {
    let count: Int
    let totalCount: Int
    let firstPageWidth: Int
    let firstPageHeight: Int

    private let document: CGPDFDocument
    private let thumbnailDocument: CGPDFDocument
    private let scale: CGFloat
    private let pageLock = NSLock()
    private let thumbnailLock = NSLock()
    private var pageCache: [(index: Int, image: CGImage)] = []
    private var thumbnailCache: [Int: CGImage] = [:]
    private static let pageCacheLimit = 3
    private static let thumbnailSide: CGFloat = 180

    init(document: CGPDFDocument, thumbnailDocument: CGPDFDocument, dpi: Int) {
        let scale = CGFloat(max(1, dpi)) / 72
        self.document = document
        self.thumbnailDocument = thumbnailDocument
        self.scale = scale
        totalCount = document.numberOfPages
        count = min(document.numberOfPages, DesignerImageProcessing.maximumPDFPages)
        if let first = document.page(at: 1) {
            let size = DesignerImageProcessing.pixelSize(of: first, scale: scale)
            firstPageWidth = size.width
            firstPageHeight = size.height
        } else {
            firstPageWidth = 0
            firstPageHeight = 0
        }
    }

    func image(at index: Int) -> CGImage? {
        pageLock.lock()
        defer { pageLock.unlock() }
        if let hit = pageCache.firstIndex(where: { $0.index == index }) {
            let entry = pageCache.remove(at: hit)
            pageCache.append(entry)
            return entry.image
        }
        guard index >= 0, index < count, let page = document.page(at: index + 1),
              let image = DesignerImageProcessing.render(page, scale: scale) else { return nil }
        pageCache.append((index: index, image: image))
        if pageCache.count > Self.pageCacheLimit { pageCache.removeFirst() }
        return image
    }

    func thumbnail(at index: Int) -> CGImage? {
        thumbnailLock.lock()
        defer { thumbnailLock.unlock() }
        if let cached = thumbnailCache[index] { return cached }
        guard index >= 0, index < count, let page = thumbnailDocument.page(at: index + 1) else { return nil }
        let points = DesignerImageProcessing.pixelSize(of: page, scale: 1)
        let thumbnailScale = Self.thumbnailSide / CGFloat(max(1, max(points.width, points.height)))
        guard let image = DesignerImageProcessing.render(page, scale: min(thumbnailScale, scale)) else { return nil }
        thumbnailCache[index] = image
        return image
    }
}

/// Hülle, um ein `CGImage` aus einer Hintergrundaufgabe zurückzugeben.
struct DesignerImageBox: @unchecked Sendable {
    let image: CGImage?
}

/// Ergebnis der Hintergrundberechnung für die aktuelle Seite.
struct DesignerProcessedImage: Sendable {
    var gray: GrayImage
    var bitmap: MonoBitmap
    /// Exakte Größe des Druckauftrags (eine Seite, eine Kopie) mit den Treibereinstellungen.
    var jobBytes: Int?
    var blackRatio: Double
}

/// Alle Eingaben der Bildaufbereitung – ändert sich einer, wird neu gerechnet.
struct DesignerImageKey: Equatable, Sendable {
    var sourceID: UUID
    var page: Int
    var widthDots: Int
    var heightDots: Int
    var fitMode: ImageFitMode
    var rotation: QuarterTurn
    var brightness: Double
    var contrast: Double
    var dither: DitherAlgorithm
    var threshold: Int
    var invert: Bool
    var settings: PrintSettings
    var language: PrinterLanguage
    var resolution: Resolution
    var stock: LabelStock
    var maxPrintWidthDots: Int?
}

/// Grafikfeld zum Einfügen in ein ZPL-Dokument.
struct DesignerGraphicSnippet: Sendable {
    var snippet: String
    var width: Int
    var height: Int
}

// MARK: - Berechnung (threadunabhängig)

enum DesignerImageProcessing {
    /// Höchstzahl nutzbarer PDF-Seiten (Drucken „Alle Seiten“ hält je Seite ein Etikettenbild).
    static let maximumPDFPages = 200
    /// Obergrenze für eine gerenderte PDF-Seite (Graustufen, 1 Byte je Pixel ≈ 150 MB).
    static let maximumPagePixels: CGFloat = 150_000_000

    /// Lädt Bild bzw. PDF. PDF-Seiten werden erst bei Bedarf gerendert.
    static func loadSource(url: URL, dpi: Int) throws -> DesignerImageSource {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        guard ImageImport.isPDF(url) else {
            let image = try ImageImport.cgImage(contentsOf: url)
            return DesignerImageSource(name: name, url: url, image: image,
                                       thumbnail: thumbnail(image, maxSide: 180), dpi: dpi)
        }
        // Abgebildet statt gelesen: Seiten werden später außerhalb des Dateizugriffs gerendert.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func openDocument() throws -> CGPDFDocument {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
                throw ImageImport.ImportError.unreadable(url.lastPathComponent)
            }
            // Dokumente mit leerem Benutzerpasswort (nur Rechte eingeschränkt) entsperren.
            if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
                throw ImageImport.ImportError.unreadable(url.lastPathComponent)
            }
            return document
        }
        let document = try openDocument()
        guard document.numberOfPages > 0 else { throw DesignerFileError.noPages(url.lastPathComponent) }
        let pages = DesignerPDFPages(document: document, thumbnailDocument: try openDocument(), dpi: dpi)
        return DesignerImageSource(name: name, url: url, pdf: pages, dpi: dpi)
    }

    /// Ausgabegröße einer PDF-Seite (CropBox, `/Rotate`) bei `scale` Pixeln je Punkt.
    static func pixelSize(of page: CGPDFPage, scale: CGFloat) -> (width: Int, height: Int) {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let quarter = rotation == 90 || rotation == 270
        return (Int(((quarter ? box.height : box.width) * scale).rounded()),
                Int(((quarter ? box.width : box.height) * scale).rounded()))
    }

    /// Rendert eine PDF-Seite in Graustufen auf weißem Grund (CropBox, `/Rotate`). Riesige Seiten
    /// werden so weit verkleinert, dass sie `maximumPagePixels` nicht überschreiten.
    static func render(_ page: CGPDFPage, scale requestedScale: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let area = box.width * box.height * requestedScale * requestedScale
        let scale = area > maximumPagePixels ? requestedScale * (maximumPagePixels / area).squareRoot() : requestedScale
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = pixelSize(of: page, scale: scale)
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        // Eigene Transformation: CGPDFPage.getDrawingTransform skaliert nie vergrößernd.
        let w = box.width * scale, h = box.height * scale
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: w, y: h)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Verkleinertes Vorschaubild auf weißem Grund.
    static func thumbnail(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(1, max(image.width, image.height))
        let scale = min(1, Double(maxSide) / Double(longest))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Bringt eine Seite auf Etikettengröße (Einpassen, Drehen, Helligkeit/Kontrast, Invertieren).
    static func gray(_ image: CGImage, key: DesignerImageKey) -> GrayImage {
        let fitted = ImageImport.grayImage(from: image, width: key.widthDots, height: key.heightDots, mode: key.fitMode,
                                           rotation: key.rotation, brightness: key.brightness, contrast: key.contrast)
        return key.invert ? fitted.inverted() : fitted
    }

    /// Rastert eine Seite und berechnet Kennzahlen für die Anzeige. Eine Seite, die sich nicht
    /// rendern lässt (`nil`), erscheint als leeres Etikett.
    static func process(_ image: CGImage?, key: DesignerImageKey) -> DesignerProcessedImage {
        let prepared = image.map { Self.gray($0, key: key) }
            ?? GrayImage(width: max(1, key.widthDots), height: max(1, key.heightDots))
        let bitmap = Ditherer.dither(prepared, algorithm: key.dither, threshold: key.threshold)
        let pixels = max(1, bitmap.width * bitmap.height)
        let encoder = JobEncoder(language: key.language, resolution: key.resolution, settings: key.settings,
                                 stock: key.stock, maxPrintWidthDots: key.maxPrintWidthDots)
        let bytes = (try? encoder.encode(pages: [bitmap], copies: 1, collate: true))?.count
        return DesignerProcessedImage(gray: prepared, bitmap: bitmap, jobBytes: bytes,
                                      blackRatio: Double(bitmap.blackPixelCount) / Double(pixels))
    }

    /// Ein ZPL-Format je Seite: `^XA ^PW ^LL ^FO0,0 ^GFA(Z64) ^FS ^XZ`.
    static func zplDocument(images: [GrayImage], key: DesignerImageKey, title: String) -> String {
        let formats = images.map { image -> String in
            let bitmap = Ditherer.dither(image, algorithm: key.dither, threshold: key.threshold)
            return [
                "^XA",
                "^CI28",
                "^FX " + DesignerZPLBuilder.sanitizedComment(title) + " – LabelWerk",
                "^PW\(bitmap.width)",
                "^LL\(bitmap.height)",
                "^LH0,0",
                "^FO0,0" + ZPLGraphicEncoder.graphicField(bitmap, compression: .z64) + "^FS",
                "^XZ",
            ].joined(separator: "\n")
        }
        return formats.joined(separator: "\n\n") + "\n"
    }

    /// Lädt ein Bild, verkleinert es auf höchstens die halbe Etikettenfläche (nie vergrößernd),
    /// rastert es und erzeugt ein Grafikfeld an einer freien Position.
    static func graphicSnippet(url: URL, dpi: Int, geometry: DesignerLabelGeometry, slot: Int,
                               dither: DitherAlgorithm) throws -> DesignerGraphicSnippet {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = try loadSource(url: url, dpi: dpi).page(at: 0) else {
            throw DesignerFileError.noPages(url.lastPathComponent)
        }
        let margin = geometry.margin
        let maxWidth = max(16, (geometry.widthDots - 2 * margin) / 2)
        let maxHeight = max(16, (geometry.heightDots - 2 * margin) / 2)
        let scale = min(1, min(Double(maxWidth) / Double(max(1, image.width)), Double(maxHeight) / Double(max(1, image.height))))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        let gray = ImageImport.grayImage(from: image, width: width, height: height, mode: .stretch)
        let bitmap = Ditherer.dither(gray, algorithm: dither, threshold: 128)
        let step = max(geometry.dots(4), geometry.heightDots / 12)
        let x = margin + (slot % 4) * geometry.dots(2)
        let y = max(margin, min(margin + (slot % 9) * step, geometry.heightDots - margin - height))
        let comment = "^FX " + DesignerZPLBuilder.sanitizedComment(tr("Grafik") + " " + url.lastPathComponent)
        let field = "^FO\(x),\(y)" + ZPLGraphicEncoder.graphicField(bitmap, compression: .z64) + "^FS"
        return DesignerGraphicSnippet(snippet: comment + "\n" + field, width: bitmap.width, height: bitmap.height)
    }
}

// MARK: - Zustand „Bild & PDF“

/// Zustand des Bild-/PDF-Bereichs. Liegt im `DesignerStore`, damit Bild und Einstellungen beim
/// Wechsel zwischen den Bereichen und beim Verlassen des Designers erhalten bleiben.
@Observable
@MainActor
final class DesignerImageState {
    private(set) var source: DesignerImageSource?
    var pageIndex = 0
    var fitMode: ImageFitMode = .contain
    var rotation: QuarterTurn = .r0
    var brightness = 0.0
    var contrast = 0.0
    var dither: DitherAlgorithm = .floydSteinberg
    var threshold = 128
    var invert = false
    var allPages = false
    var copies = 1
    /// Position des Vorher/Nachher-Teilers (0…1).
    var split: CGFloat = 0.5
    var printPhase: DesignerSendPhase = .idle
    var didApplyPreferences = false

    private(set) var processed: DesignerProcessedImage?
    private(set) var processedKey: DesignerImageKey?
    private(set) var isLoading = false
    private(set) var isProcessing = false

    /// Jede neue Berechnung bzw. jeder neue Ladevorgang erhöht den Zähler; Ergebnisse älterer
    /// (verworfener) Vorgänge werden beim Eintreffen ignoriert.
    @ObservationIgnored private var processToken = 0
    @ObservationIgnored private var loadToken = 0

    func hasAdjustments(defaultDither: DitherAlgorithm) -> Bool {
        fitMode != .contain || rotation != .r0 || brightness != 0 || contrast != 0 || invert
            || dither != defaultDither || threshold != 128
    }

    func resetAdjustments(defaultDither: DitherAlgorithm) {
        fitMode = .contain
        rotation = .r0
        brightness = 0
        contrast = 0
        invert = false
        dither = defaultDither
        threshold = 128
    }

    func rotateClockwise() {
        rotation = QuarterTurn(rawValue: (rotation.rawValue + 90) % 360) ?? .r0
    }

    /// Schließt die Datei; laufende Lade- und Rechenvorgänge werden verworfen.
    func clear() {
        loadToken += 1
        processToken += 1
        isLoading = false
        isProcessing = false
        source = nil
        processed = nil
        processedKey = nil
        pageIndex = 0
        allPages = false
    }

    /// Lädt eine Datei im Hintergrund. Fehler werden an den Aufrufer weitergereicht; wurde
    /// inzwischen eine andere Datei gewählt (oder geschlossen), verfällt das Ergebnis still.
    func load(_ url: URL, dpi: Int, animation: Animation?) async throws {
        loadToken += 1
        let token = loadToken
        isLoading = true
        let loaded: DesignerImageSource
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                try DesignerImageProcessing.loadSource(url: url, dpi: dpi)
            }.value
        } catch {
            guard token == loadToken else { return }
            isLoading = false
            throw error
        }
        guard token == loadToken else { return }
        isLoading = false
        let keepPage = source?.url == url ? min(pageIndex, loaded.pageCount - 1) : 0
        // Rechnungen für die bisherige Datei verwerfen.
        processToken += 1
        isProcessing = false
        withAnimation(animation) {
            source = loaded
            pageIndex = max(0, keepPage)
            processed = nil
            processedKey = nil
            if loaded.pageCount < 2 { allPages = false }
        }
    }

    /// Berechnet Graustufen- und Rasterbild der aktuellen Seite (entprellt).
    func process(_ key: DesignerImageKey) async {
        guard let source, source.id == key.sourceID, key.page >= 0, key.page < source.pageCount else { return }
        guard processedKey != key else {
            // Zurück auf den angezeigten Stand (z. B. Schalter wieder aus): Eine noch laufende
            // Berechnung eines verworfenen Stands darf danach nicht mehr landen.
            processToken += 1
            isProcessing = false
            return
        }
        if processed != nil {
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
        }
        processToken += 1
        let token = processToken
        isProcessing = true
        let result = await Task.detached(priority: .userInitiated) {
            DesignerImageProcessing.process(source.page(at: key.page), key: key)
        }.value
        guard token == processToken, self.source?.id == key.sourceID else { return }
        isProcessing = false
        processed = result
        processedKey = key
    }

    /// Graustufenbilder für Druck/Übernahme: aktuelle Seite oder alle Seiten (nacheinander
    /// gerendert; Seiten, die sich nicht rendern lassen, werden übersprungen).
    func renderPages(for key: DesignerImageKey, allPages: Bool) async -> [GrayImage] {
        guard let source, source.id == key.sourceID, key.page >= 0, key.page < source.pageCount else { return [] }
        if !allPages, let processed, processedKey == key { return [processed.gray] }
        let indices = allPages ? Array(0..<source.pageCount) : [key.page]
        return await Task.detached(priority: .userInitiated) {
            indices.compactMap { index in
                source.page(at: index).map { DesignerImageProcessing.gray($0, key: key) }
            }
        }.value
    }
}

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LabelWerkKit

/// Ein im Etikettendruck geöffnetes Dokument (PDF oder Bild). Seiten werden erst bei Bedarf in der
/// Druckerauflösung gerendert (`grayPage`), Vorschaubilder klein und zwischengespeichert.
///
/// Seitengröße (für Schritt F „An Etikett anpassen“): PDF – CropBox mit `/Rotate` in Punkten, so wie
/// macOS die Seite an den Treiber gibt. Bild – ein Bildpunkt = ein Druckpunkt (`Pixel · 72 / dpi`):
/// Bilder in Etikettengröße druckt LabelWerk also 1:1, alle anderen passt Schritt F ein.
final class LabelPrintDocument: Identifiable, @unchecked Sendable {
    enum Kind: Sendable { case pdf, image }

    let id = UUID()
    let url: URL
    /// Anzeigename (Titel aus „Mit LabelWerk drucken“, sonst PDF-Titel, sonst Dateiname).
    let title: String
    /// Programm, das das PDF erzeugt hat (PDF-Eintrag „Creator“, z. B. „Safari“), falls bekannt.
    let creator: String?
    let kind: Kind
    let pageCount: Int
    /// Seiten über dieser Zahl werden nicht angeboten (Speicher und Rechenzeit).
    static let maximumPages = 500

    private let pdf: CGPDFDocument?
    private let thumbnailPDF: CGPDFDocument?
    private let image: CGImage?
    private let pageLock = NSLock()
    private let thumbnailLock = NSLock()
    private var thumbnailCache: [Int: CGImage] = [:]
    static let thumbnailSide: CGFloat = 220

    private init(url: URL, title: String, creator: String?, kind: Kind, pageCount: Int,
                 pdf: CGPDFDocument?, thumbnailPDF: CGPDFDocument?, image: CGImage?) {
        self.url = url
        self.title = title
        self.creator = creator
        self.kind = kind
        self.pageCount = pageCount
        self.pdf = pdf
        self.thumbnailPDF = thumbnailPDF
        self.image = image
    }

    /// Dateitypen, die der Etikettendruck öffnet (wie `CFBundleDocumentTypes` in der Info.plist).
    static let contentTypes: [UTType] = [.pdf, .png, .jpeg, .tiff, .heic, .gif, .bmp]

    static func isSupported(_ url: URL) -> Bool {
        if ImageImport.isPDF(url) { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type.map { candidate in contentTypes.contains { candidate.conforms(to: $0) } || candidate.conforms(to: .image) }
            ?? false
    }

    // MARK: Laden

    /// Öffnet `url` (blockiert: aus einer Hintergrundaufgabe aufrufen).
    static func load(_ url: URL) throws -> LabelPrintDocument {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let fileName = displayName(fromFileName: url.deletingPathExtension().lastPathComponent)
        guard ImageImport.isPDF(url) else {
            let image = try ImageImport.cgImage(contentsOf: url)
            return LabelPrintDocument(url: url, title: PDFServiceInstaller.storedTitle(for: url) ?? fileName,
                                      creator: nil, kind: .image, pageCount: 1, pdf: nil, thumbnailPDF: nil,
                                      image: image)
        }
        // Abgebildet statt gelesen; ein eigenes Dokumentobjekt für die Vorschaubilder.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func open() throws -> CGPDFDocument {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
                throw ImageImport.ImportError.unreadable(url.lastPathComponent)
            }
            // Dokumente mit leerem Benutzerpasswort (nur Rechte eingeschränkt) entsperren.
            if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
                throw ImageImport.ImportError.unreadable(url.lastPathComponent)
            }
            return document
        }
        let document = try open()
        guard document.numberOfPages > 0 else { throw ImageImport.ImportError.emptyPDF }
        let info = document.info
        let pdfTitle = info.flatMap { Self.string(in: $0, key: "Title") }
        let creator = info.flatMap { Self.string(in: $0, key: "Creator") }
        let title = PDFServiceInstaller.storedTitle(for: url) ?? pdfTitle ?? fileName
        return LabelPrintDocument(url: url, title: title, creator: creator, kind: .pdf,
                                  pageCount: min(document.numberOfPages, maximumPages),
                                  pdf: document, thumbnailPDF: try open(), image: nil)
    }

    /// Dateiname ohne den Zeitstempel, den „Mit LabelWerk drucken“ voranstellt („20261110-143012-“).
    static func displayName(fromFileName name: String) -> String {
        let pattern = #"^\d{8}-\d{6}-(.+)$"#
        guard let match = name.range(of: pattern, options: .regularExpression) else { return name }
        let stripped = String(name[match]).dropFirst(16)
        return stripped.isEmpty ? name : String(stripped)
    }

    private static func string(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value,
              let text = CGPDFStringCopyTextString(value) as String? else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Seiten

    /// Seitengröße in Punkten bei `dpi` (Bilder hängen von der Druckerauflösung ab).
    func pageSize(at index: Int, dpi: Int) -> PageSizePoints? {
        switch kind {
        case .image:
            guard let image else { return nil }
            let scale = 72.0 / Double(max(1, dpi))
            return PageSizePoints(width: Double(image.width) * scale, height: Double(image.height) * scale)
        case .pdf:
            pageLock.lock()
            defer { pageLock.unlock() }
            return pdf?.page(at: index + 1).map(Self.pageSize(of:))
        }
    }

    /// CropBox in Punkten, bei `/Rotate` 90°/270° vertauscht (so liegt die Seite im Druck).
    private static func pageSize(of page: CGPDFPage) -> PageSizePoints {
        let box = page.getBoxRect(.cropBox)
        let quarter = ((Int(page.rotationAngle) % 360) + 360) % 360 % 180 == 90
        return PageSizePoints(width: Double(quarter ? box.height : box.width),
                              height: Double(quarter ? box.width : box.height))
    }

    /// Die Seite in Graustufen bei `dpi` (wie CUPS sie dem Treiber gibt) samt Seitengröße.
    func grayPage(at index: Int, dpi: Int) -> (image: GrayImage, pageSize: PageSizePoints?)? {
        switch kind {
        case .image:
            guard let image else { return nil }
            let gray = Self.bounded(image)
            let scale = 72.0 / Double(max(1, dpi))
            return (gray, PageSizePoints(width: Double(gray.width) * scale, height: Double(gray.height) * scale))
        case .pdf:
            pageLock.lock()
            defer { pageLock.unlock() }
            guard let page = pdf?.page(at: index + 1),
                  let rendered = DesignerImageProcessing.render(page, scale: CGFloat(max(1, dpi)) / 72) else { return nil }
            return (ImageImport.grayImage(from: rendered), Self.pageSize(of: page))
        }
    }

    /// Bilder über 60 Millionen Pixel werden verkleinert (Seitengröße folgt der verkleinerten Fassung).
    private static func bounded(_ image: CGImage) -> GrayImage {
        let limit = 60_000_000.0
        let area = Double(image.width) * Double(image.height)
        guard area > limit else { return ImageImport.grayImage(from: image) }
        let factor = (limit / area).squareRoot()
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        return ImageImport.grayImage(from: image, width: width, height: height, mode: .stretch)
    }

    /// Kleines Vorschaubild der Originalseite (zwischengespeichert).
    func thumbnail(at index: Int) -> CGImage? {
        thumbnailLock.lock()
        defer { thumbnailLock.unlock() }
        if let cached = thumbnailCache[index] { return cached }
        let result: CGImage?
        switch kind {
        case .image:
            result = image.flatMap { DesignerImageProcessing.thumbnail($0, maxSide: Int(Self.thumbnailSide)) }
        case .pdf:
            guard let page = thumbnailPDF?.page(at: index + 1) else { return nil }
            let points = DesignerImageProcessing.pixelSize(of: page, scale: 1)
            let scale = Self.thumbnailSide / CGFloat(max(1, max(points.width, points.height)))
            result = DesignerImageProcessing.render(page, scale: min(scale, 4))
        }
        if let result { thumbnailCache[index] = result }
        return result
    }

    /// Originalseite für den Vergleich in der Vorschau (Bildschirmauflösung, höchstens `maxSide` Pixel).
    func originalPreview(at index: Int, maxSide: CGFloat = 1600) -> CGImage? {
        switch kind {
        case .image:
            return image.flatMap { DesignerImageProcessing.thumbnail($0, maxSide: Int(maxSide)) }
        case .pdf:
            thumbnailLock.lock()
            defer { thumbnailLock.unlock() }
            guard let page = thumbnailPDF?.page(at: index + 1) else { return nil }
            let points = DesignerImageProcessing.pixelSize(of: page, scale: 1)
            let scale = maxSide / CGFloat(max(1, max(points.width, points.height)))
            return DesignerImageProcessing.render(page, scale: min(scale, 8))
        }
    }
}

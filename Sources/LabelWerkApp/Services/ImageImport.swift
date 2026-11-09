import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LabelWerkKit

/// Einpassung eines Bildes in das Etikett.
enum ImageFitMode: String, CaseIterable, Identifiable, Codable {
    /// Vollständig sichtbar, Seitenverhältnis bleibt erhalten.
    case contain
    /// Füllt das Etikett, Ränder werden beschnitten.
    case cover
    /// Auf Etikettengröße verzerrt.
    case stretch
    /// Originalgröße (1 Bildpixel = 1 Druckpunkt), zentriert.
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .contain: return tr("Einpassen")
        case .cover: return tr("Füllen")
        case .stretch: return tr("Strecken")
        case .original: return tr("Originalgröße")
        }
    }

    var systemImage: String {
        switch self {
        case .contain: return "arrow.down.right.and.arrow.up.left"
        case .cover: return "arrow.up.left.and.arrow.down.right"
        case .stretch: return "arrow.left.and.right"
        case .original: return "1.square"
        }
    }
}

/// Bild- und PDF-Import für Druck, Grafik-Upload und Vorschau.
enum ImageImport {
    enum ImportError: LocalizedError {
        case unreadable(String)
        case emptyPDF

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return tr("„%@“ konnte nicht gelesen werden.", name)
            case .emptyPDF: return tr("Das PDF enthält keine Seiten.")
            }
        }
    }

    /// Unterstützte Dateitypen für Öffnen-Dialoge und Drag & Drop.
    static let supportedTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .pdf, .image]

    static func isPDF(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
            || url.pathExtension.lowercased() == "pdf"
    }

    // MARK: Laden

    static func cgImage(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImportError.unreadable(url.lastPathComponent) }
        return image
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Rendert alle (oder die ersten `maxPages`) PDF-Seiten in der Druckauflösung.
    static func pdfPages(url: URL, dpi: Int, maxPages: Int = 100) throws -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL) else { throw ImportError.unreadable(url.lastPathComponent) }
        guard document.numberOfPages > 0 else { throw ImportError.emptyPDF }
        var pages: [CGImage] = []
        for index in 1...min(document.numberOfPages, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotation = page.rotationAngle % 360
            let rotated = rotation == 90 || rotation == 270
            let scale = CGFloat(dpi) / 72.0
            let width = Int((rotated ? box.height : box.width) * scale)
            let height = Int((rotated ? box.width : box.height) * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { continue }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.setShouldAntialias(true)
            // Eigene Transformation: CGPDFPage.getDrawingTransform skaliert nie vergrößernd.
            let w = box.width * scale, h = box.height * scale
            switch (rotation + 360) % 360 {
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
            if let image = context.makeImage() { pages.append(image) }
        }
        return pages
    }

    /// Lädt Bild oder PDF als Liste von Seiten.
    static func pages(contentsOf url: URL, dpi: Int) throws -> [CGImage] {
        if isPDF(url) { return try pdfPages(url: url, dpi: dpi) }
        return [try cgImage(contentsOf: url)]
    }

    // MARK: Einpassen & Umwandeln

    /// Zeichnet `image` in ein Graustufen-Etikett der Größe `width`×`height` Punkte.
    static func grayImage(from image: CGImage, width: Int, height: Int, mode: ImageFitMode,
                          rotation: QuarterTurn = .r0, brightness: Double = 0, contrast: Double = 0) -> GrayImage {
        let width = max(1, width), height = max(1, height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return GrayImage(width: width, height: height) }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        let quarter = rotation == .r90 || rotation == .r270
        let srcW = CGFloat(quarter ? image.height : image.width)
        let srcH = CGFloat(quarter ? image.width : image.height)
        let W = CGFloat(width), H = CGFloat(height)
        var drawW: CGFloat, drawH: CGFloat
        switch mode {
        case .contain:
            let s = min(W / srcW, H / srcH)
            drawW = srcW * s; drawH = srcH * s
        case .cover:
            let s = max(W / srcW, H / srcH)
            drawW = srcW * s; drawH = srcH * s
        case .stretch:
            drawW = W; drawH = H
        case .original:
            drawW = srcW; drawH = srcH
        }
        // Mittelpunkt des Etiketts als Ursprung, dann drehen (CoreGraphics dreht gegen den Uhrzeigersinn).
        context.translateBy(x: W / 2, y: H / 2)
        context.rotate(by: -CGFloat(rotation.rawValue) * .pi / 180)
        let rectW = quarter ? drawH : drawW
        let rectH = quarter ? drawW : drawH
        context.draw(image, in: CGRect(x: -rectW / 2, y: -rectH / 2, width: rectW, height: rectH))

        guard let data = context.data else { return GrayImage(width: width, height: height) }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        let pixels = Array(UnsafeBufferPointer(start: buffer, count: width * height))
        var gray = GrayImage(width: width, height: height, pixels: pixels)
        if brightness != 0 || contrast != 0 {
            gray = gray.adjusted(brightness: brightness, contrast: contrast)
        }
        return gray
    }

    /// Wandelt ein beliebiges Bild ohne Skalierung in Graustufen um.
    static func grayImage(from image: CGImage) -> GrayImage {
        grayImage(from: image, width: image.width, height: image.height, mode: .stretch)
    }

    // MARK: Zurück zu CGImage (Vorschau)

    static func cgImage(from gray: GrayImage) -> CGImage? {
        guard gray.width > 0, gray.height > 0 else { return nil }
        let data = Data(gray.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: gray.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 1-Bit-Bitmap als CGImage (schwarz auf weiß).
    static func cgImage(from bitmap: MonoBitmap) -> CGImage? {
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        // In CoreGraphics ist bei 1-Bit-Graustufen 0 = schwarz → Bits invertieren.
        let inverted = bitmap.data.map { ~$0 }
        let data = Data(inverted) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 1, bitsPerPixel: 1,
                       bytesPerRow: bitmap.bytesPerRow, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func nsImage(from bitmap: MonoBitmap) -> NSImage? {
        guard let cg = cgImage(from: bitmap) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: bitmap.width, height: bitmap.height))
    }

    static func nsImage(from gray: GrayImage) -> NSImage? {
        guard let cg = cgImage(from: gray) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: gray.width, height: gray.height))
    }

    /// PNG-Daten eines CGImage (für Export/Teilen).
    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Werte

/// Geladenes Bild bzw. PDF (alle Seiten in Druckerauflösung gerendert).
struct DesignerImageSource: @unchecked Sendable {
    let id = UUID()
    var name: String
    var url: URL
    var pages: [CGImage]
    var thumbnails: [CGImage]
    var isPDF: Bool
    /// Auflösung, mit der PDF-Seiten gerendert wurden.
    var renderedDPI: Int

    var pixelWidth: Int { pages.first?.width ?? 0 }
    var pixelHeight: Int { pages.first?.height ?? 0 }
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
    /// Lädt Bild/PDF und erzeugt kleine Vorschaubilder für die Seitenleiste.
    static func loadSource(url: URL, dpi: Int) throws -> DesignerImageSource {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let pages = try ImageImport.pages(contentsOf: url, dpi: dpi)
        guard !pages.isEmpty else { throw DesignerFileError.noPages(url.lastPathComponent) }
        let thumbnails = pages.map { thumbnail($0, maxSide: 180) ?? $0 }
        return DesignerImageSource(name: url.deletingPathExtension().lastPathComponent, url: url, pages: pages,
                                   thumbnails: thumbnails, isPDF: ImageImport.isPDF(url), renderedDPI: dpi)
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

    /// Rastert eine Seite und berechnet Kennzahlen für die Anzeige.
    static func process(_ image: CGImage, key: DesignerImageKey) -> DesignerProcessedImage {
        let prepared = Self.gray(image, key: key)
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
        guard let image = try ImageImport.pages(contentsOf: url, dpi: dpi).first else {
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

/// Zustand des Bild-/PDF-Bereichs. Liegt in `DesignerView`, damit Bild und Einstellungen beim
/// Wechsel zwischen den Bereichen erhalten bleiben.
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

    @ObservationIgnored private var processToken = 0

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

    func clear() {
        source = nil
        processed = nil
        processedKey = nil
        pageIndex = 0
        allPages = false
    }

    /// Lädt eine Datei im Hintergrund. Fehler werden an den Aufrufer weitergereicht.
    func load(_ url: URL, dpi: Int, animation: Animation?) async throws {
        isLoading = true
        defer { isLoading = false }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try DesignerImageProcessing.loadSource(url: url, dpi: dpi)
        }.value
        let keepPage = source?.url == url ? min(pageIndex, loaded.pages.count - 1) : 0
        withAnimation(animation) {
            source = loaded
            pageIndex = max(0, keepPage)
            processed = nil
            processedKey = nil
            if loaded.pages.count < 2 { allPages = false }
        }
    }

    /// Berechnet Graustufen- und Rasterbild der aktuellen Seite (entprellt).
    func process(_ key: DesignerImageKey) async {
        guard let source, source.id == key.sourceID, source.pages.indices.contains(key.page) else { return }
        guard processedKey != key else { return }
        if processed != nil {
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
        }
        processToken += 1
        let token = processToken
        isProcessing = true
        let page = source.pages[key.page]
        let result = await Task.detached(priority: .userInitiated) {
            DesignerImageProcessing.process(page, key: key)
        }.value
        guard token == processToken else { return }
        isProcessing = false
        processed = result
        processedKey = key
    }

    /// Graustufenbilder für Druck/Übernahme: aktuelle Seite oder alle Seiten.
    func renderPages(for key: DesignerImageKey, allPages: Bool) async -> [GrayImage] {
        guard let source, source.id == key.sourceID, source.pages.indices.contains(key.page) else { return [] }
        if !allPages, let processed, processedKey == key { return [processed.gray] }
        let pages = allPages ? source.pages : [source.pages[key.page]]
        return await Task.detached(priority: .userInitiated) {
            pages.map { DesignerImageProcessing.gray($0, key: key) }
        }.value
    }
}

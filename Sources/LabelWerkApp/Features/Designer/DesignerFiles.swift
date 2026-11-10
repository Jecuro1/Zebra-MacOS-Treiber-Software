import AppKit
import Foundation
import UniformTypeIdentifiers
import LabelWerkKit

/// Fehler beim Öffnen von Dokumenten im Designer.
enum DesignerFileError: LocalizedError {
    case tooLarge(String)
    case unreadable(String)
    case binary(String)
    case noPages(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name): return tr("„%@“ ist zu groß für den Editor (höchstens 16 MB).", name)
        case .unreadable(let name): return tr("„%@“ ist keine lesbare Textdatei.", name)
        case .binary(let name):
            return tr("„%@“ enthält Binärdaten (z. B. ein ZebraDesigner-Etikett) und kann nicht als ZPL-Text bearbeitet werden.", name)
        case .noPages(let name): return tr("„%@“ enthält keine darstellbaren Seiten.", name)
        }
    }
}

/// Öffnen, Sichern und Ablegen von Dateien im Designer.
enum DesignerFiles {
    /// Größte Datei, die im Editor geöffnet wird.
    static let maximumDocumentBytes = 16 * 1024 * 1024

    /// Dateitypen für ZPL-Dokumente.
    static var zplTypes: [UTType] {
        let candidates: [UTType?] = [UTType(filenameExtension: "zpl"), UTType(filenameExtension: "prn"), .plainText, .text]
        var result: [UTType] = []
        for case let type? in candidates where !result.contains(type) {
            result.append(type)
        }
        return result
    }

    @MainActor
    static func chooseFile(title: String, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseDestination(name: String, types: [UTType], title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Liest eine Textdatei (UTF-8, UTF-16 mit BOM, ersatzweise ISO-Latin-1). Dateien mit
    /// NUL-Bytes sind binär (ISO-Latin-1 würde sie sonst stillschweigend als Zeichensalat laden).
    static func readText(_ url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maximumDocumentBytes {
            throw DesignerFileError.tooLarge(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        let byteOrderMarks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]
        if byteOrderMarks.contains(where: { data.starts(with: $0) }), let text = String(data: data, encoding: .utf16) {
            return text
        }
        if data.contains(0) { throw DesignerFileError.binary(url.lastPathComponent) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw DesignerFileError.unreadable(url.lastPathComponent)
    }

    /// `true` für Bilder und PDFs (werden als Grafik behandelt).
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// `true` für ZPL-/Textdokumente.
    static func isDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || DesignerZPLFormatter.openableExtensions.contains(ext)
    }

    /// Dateiname ohne unzulässige Zeichen.
    static func safeFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? tr("Etikett") : String(cleaned.prefix(80))
    }

    /// Lädt die Datei-URL aus einem Drag-&-Drop-Anbieter und ruft `completion` auf dem Hauptthread auf.
    static func loadFileURL(from providers: [NSItemProvider], completion: @escaping @MainActor (URL) -> Void) -> Bool {
        let identifier = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            let resolved: URL?
            if let data = item as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                resolved = direct
            } else {
                resolved = nil
            }
            guard let fileURL = resolved else { return }
            Task { @MainActor in completion(fileURL) }
        }
        return true
    }
}

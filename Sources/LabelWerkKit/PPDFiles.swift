import Foundation
import LabelWerkCore
import LabelWerkImaging

/// PPD-Dateien lesen und für eine Warteschlange ergänzen (App und `lwctl`).
///
/// Die installierten Modell-PPDs liegen gzip-komprimiert vor (`LabelWerk-zd421t-203dpi.ppd.gz`),
/// Warteschlangen-PPDs (`/etc/cups/ppd/<queue>.ppd`) unkomprimiert; beides wird hier gelesen.
public enum PPDFiles {

    public enum FileError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case notLabelWerk(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Die PPD-Datei „\(path)“ ist nicht lesbar."
            case .notLabelWerk(let path): return "„\(path)“ ist keine LabelWerk-PPD."
            }
        }
    }

    /// Text einer PPD aus Dateidaten (gzip wird erkannt): UTF-8, sonst ISO-Latin-1.
    public static func text(from data: Data) throws -> String {
        let plain = try Gzip.decompress(data)
        if let text = String(data: plain, encoding: .utf8) { return text }
        // ISO-Latin-1: jedes Byte ist das gleichnamige Unicode-Zeichen.
        return String(String.UnicodeScalarView(plain.map { Unicode.Scalar($0) }))
    }

    /// Liest eine PPD (`.ppd` oder `.ppd.gz`).
    public static func read(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else { throw FileError.unreadable(path) }
        do {
            return try text(from: data)
        } catch {
            throw FileError.unreadable(path)
        }
    }

    /// Steht die Etikettengröße schon als Seitengröße in der Modell-PPD?
    ///
    /// Entscheidet nach dem Inhalt der Datei – die installierte PPD kann aus einer anderen Version als
    /// der Katalog der App stammen (``installedPageSizes(basePPD:)``).
    public static func containsPageSize(_ size: QueueLabelSize, basePPD path: String) -> Bool {
        installedPageSizes(basePPD: path)?.contains(size.keyword) ?? false
    }

    /// Seitengrößen einer Modell-PPD: aus der Datei, wenn sie lesbar ist und Seitengrößen enthält;
    /// sonst (z. B. `lwctl install --dry-run` ohne installierten Treiber) nach dem Dateinamen
    /// (``PPDPageSizes``, wie der Generator). `nil` = unbekannt.
    public static func installedPageSizes(basePPD path: String) -> [String]? {
        if let text = try? read(path) {
            let keywords = QueuePPD.pageSizeKeywords(in: text)
            if !keywords.isEmpty { return keywords }
        }
        return PPDPageSizes.keywords(forPPDNamed: path)
    }

    /// Text einer Kopie der Modell-PPD `path`, die `size` als benannte Standard-Seitengröße enthält
    /// (``QueuePPD/patched(_:adding:)``).
    public static func patchedText(basePPD path: String, size: QueueLabelSize) throws -> String {
        let text = try read(path)
        do {
            return try QueuePPD.patched(text, adding: size)
        } catch {
            throw FileError.notLabelWerk(path)
        }
    }

    /// Pfad für die ergänzte PPD einer Warteschlange in einem eigenen temporären Ordner, z. B.
    /// `…/LabelWerk-ppd-1A2B3C4D/Zebra_ZD421t-w295h216.ppd`. Die Datei wird nicht angelegt.
    public static func temporaryPath(queue: String, size: QueueLabelSize,
                                     directory: URL = FileManager.default.temporaryDirectory) -> URL {
        let safeQueue = String(queue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "_-.".unicodeScalars.contains(scalar)
                ? Character(scalar) : "_"
        })
        let folder = directory.appendingPathComponent("LabelWerk-ppd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return folder.appendingPathComponent("\(safeQueue)-\(size.keyword).ppd")
    }

    /// Schreibt eine PPD (UTF-8, lesbar für alle: `lpadmin` liest sie, ggf. als anderer Benutzer).
    public static func write(_ text: String, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try Data(text.utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    /// Entfernt eine mit ``temporaryPath(queue:size:directory:)`` angelegte Datei samt Ordner.
    public static func removeTemporary(_ url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent.hasPrefix("LabelWerk-ppd-") {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// Etikettengröße, die LabelWerk früher in eine Warteschlangen-PPD ergänzt hat (aus
    /// `*lwLabelPageSize` und dem zugehörigen `*PaperDimension`), sonst `nil`.
    public static func addedLabelSize(inQueuePPD text: String) -> QueueLabelSize? {
        guard let keyword = QueuePPD.addedPageSize(in: text),
              let points = QueuePPD.paperDimension(of: keyword, in: text) else { return nil }
        let size = QueueLabelSize(widthMM: points.width / 72.0 * 25.4, heightMM: points.height / 72.0 * 25.4)
        return size.keyword == keyword ? size : nil
    }

    /// Etikettengröße der Standard-Seitengröße einer (Warteschlangen-)PPD (`*DefaultPageSize` und
    /// dessen `*PaperDimension`), sonst `nil`.
    public static func defaultLabelSize(in text: String) -> QueueLabelSize? {
        guard let keyword = QueuePPD.defaultPageSize(in: text),
              let points = QueuePPD.paperDimension(of: keyword, in: text) else { return nil }
        return QueueLabelSize(widthMM: points.width / 72.0 * 25.4, heightMM: points.height / 72.0 * 25.4)
    }
}

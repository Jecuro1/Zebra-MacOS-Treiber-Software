import Foundation

/// Die benannten Seitengrößen der LabelWerk-PPDs – exakt wie `page_sizes_for` und
/// `build_generic_target` in `Driver/ppd/generate_ppds.py` (ein Test vergleicht beide für jede PPD).
///
/// Eine Modell-PPD enthält alle Katalogformate, die auf das Modell passen (Breite höchstens
/// Druckbreite + 2 mm, Länge höchstens die größte Etikettenlänge), dazu immer das Standardformat des
/// Modells; Formate mit gleichem Schlüsselwort `w<pt>h<pt>` werden zusammengeführt (das
/// Standardformat gewinnt, sonst das erste im Katalog). Generische PPDs verwenden die größte
/// Druckbreite und Etikettenlänge aller Modelle der Sprache und deren häufigstes Standardformat.
///
/// Damit entscheiden App und `lwctl`, ob die Etikettengröße einer Warteschlange schon in der PPD
/// steht (`lpadmin -o PageSize=…` genügt) oder als eigener Eintrag in eine Kopie der PPD muss
/// (``QueuePPD``) – `lpadmin` verwirft eine unbekannte Seitengröße stillschweigend.
public enum PPDPageSizes {

    /// Toleranz für passende Etikettenbreiten in mm (`STOCK_WIDTH_TOLERANCE_MM`).
    public static let widthToleranceMM = 2.0

    /// Rückfallwerte generischer PPDs ohne Modell der Sprache (`GENERIC_FALLBACK`).
    static let genericFallbackPrintWidthMM = 104.0
    static let genericFallbackMaxLabelLengthMM = 991.0

    /// Eine Seitengröße der PPD.
    public struct Entry: Hashable, Sendable {
        /// `w<pt>h<pt>` (``LabelStock/ppdKeyword``).
        public var keyword: String
        /// Das Format, dessen Name und Maße in der PPD stehen.
        public var stock: LabelStock
        /// Weitere Katalogformate mit demselben Schlüsselwort.
        public var mergedStockIDs: [String]
    }

    /// Wofür eine PPD erzeugt wurde.
    public enum Target: Hashable, Sendable {
        /// Modell-PPD (`LabelWerk-<id>-<dpi>dpi`).
        case model(String)
        /// Generische PPD einer Sprache (`LabelWerk-generic-<sprache>-<dpi>dpi`).
        case generic(PrinterLanguage)

        /// Wert von `*lwModel` in der PPD (`zd421t` bzw. `generic-zpl`).
        public var lwModel: String {
            switch self {
            case .model(let id): return id
            case .generic(let language): return "generic-\(language.rawValue)"
            }
        }

        /// Aus dem Wert von `*lwModel`.
        public init?(lwModel: String) {
            let value = lwModel.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("generic-") {
                guard let language = PrinterLanguage(rawValue: String(value.dropFirst(8))) else { return nil }
                self = .generic(language)
            } else {
                self = .model(value)
            }
        }

        /// Dateiname ohne Endung, z. B. `LabelWerk-zd421t-203dpi`.
        public func stem(resolution: Resolution) -> String { "LabelWerk-\(lwModel)-\(resolution.dpi)dpi" }
    }

    /// Ziel und Auflösung aus einem PPD-Dateinamen: `LabelWerk-zd421t-203dpi`,
    /// `LabelWerk-generic-zpl-300dpi.ppd.gz`, auch mit Pfad. `nil` bei fremden Namen.
    public static func target(forPPDNamed name: String) -> (target: Target, dpi: Int)? {
        var stem = name.split(separator: "/").last.map(String.init) ?? name
        for suffix in [".gz", ".ppd"] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
        guard stem.hasPrefix("LabelWerk-"), stem.hasSuffix("dpi"),
              let dash = stem.lastIndex(of: "-") else { return nil }
        let dpiText = stem[stem.index(after: dash)...].dropLast(3)
        guard !dpiText.isEmpty, dpiText.allSatisfy({ $0.isASCII && $0.isNumber }), let dpi = Int(dpiText) else { return nil }
        let middle = String(stem[stem.index(stem.startIndex, offsetBy: 10)..<dash])
        guard let target = Target(lwModel: middle) else { return nil }
        return (target, dpi)
    }

    /// Passt ein Format auf ein Gerät dieser Druckbreite/Etikettenlänge? (`Stock.fits`)
    public static func fits(_ stock: LabelStock, printWidthMM: Double, maxLabelLengthMM: Double) -> Bool {
        stock.widthMM <= printWidthMM + widthToleranceMM && stock.heightMM <= maxLabelLengthMM
    }

    /// Seitengrößen für Druckbreite, Etikettenlänge und Standardformat (`page_sizes_for`), in
    /// Katalogreihenfolge.
    public static func entries(printWidthMM: Double, maxLabelLengthMM: Double, defaultStock: LabelStock,
                               catalog: ModelCatalog = .shared) -> [Entry] {
        var order: [String] = []
        var chosen: [String: LabelStock] = [:]
        var merged: [String: [String]] = [:]
        for stock in catalog.stocks {
            if stock.id != defaultStock.id,
               !fits(stock, printWidthMM: printWidthMM, maxLabelLengthMM: maxLabelLengthMM) {
                continue
            }
            let keyword = stock.ppdKeyword
            if let existing = chosen[keyword] {
                if stock.id == defaultStock.id {
                    merged[keyword, default: []].append(existing.id)
                    chosen[keyword] = stock
                } else {
                    merged[keyword, default: []].append(stock.id)
                }
            } else {
                order.append(keyword)
                chosen[keyword] = stock
                merged[keyword] = []
            }
        }
        return order.compactMap { keyword in
            chosen[keyword].map { Entry(keyword: keyword, stock: $0, mergedStockIDs: merged[keyword] ?? []) }
        }
    }

    /// Druckbreite, Etikettenlänge und Standardformat einer PPD (`nil`: unbekanntes Modell bzw.
    /// Katalog ohne Formate).
    public static func parameters(for target: Target, catalog: ModelCatalog = .shared)
        -> (printWidthMM: Double, maxLabelLengthMM: Double, defaultStock: LabelStock)? {
        switch target {
        case .model(let id):
            guard let model = catalog.model(id: id), let stock = catalog.stock(id: model.defaultStock) else { return nil }
            return (model.printWidthMM, model.maxLabelLengthMM, stock)
        case .generic(let language):
            guard !catalog.stocks.isEmpty else { return nil }
            let models = catalog.models.filter { $0.languages.contains(language) }
            let width = models.map(\.printWidthMM).max() ?? genericFallbackPrintWidthMM
            let length = models.map(\.maxLabelLengthMM).max() ?? genericFallbackMaxLabelLengthMM
            // Häufigstes Standardformat der Modelle (Gleichstand: früher im Katalog), ohne Modelle
            // der Sprache 4 × 6 Zoll bzw. das erste passende Format.
            var counts: [String: Int] = [:]
            for model in models { counts[model.defaultStock, default: 0] += 1 }
            var defaultStock: LabelStock?
            if !counts.isEmpty {
                var best: (stock: LabelStock, count: Int)?
                for stock in catalog.stocks {
                    guard let count = counts[stock.id] else { continue }
                    if best == nil || count > best!.count { best = (stock, count) }
                }
                defaultStock = best?.stock
            } else {
                let fitting = catalog.stocks.filter { fits($0, printWidthMM: width, maxLabelLengthMM: length) }
                if let preferred = catalog.stock(id: "w4h6in"), fitting.contains(preferred) {
                    defaultStock = preferred
                } else {
                    defaultStock = fitting.first ?? catalog.stocks.first
                }
            }
            guard let defaultStock else { return nil }
            return (width, length, defaultStock)
        }
    }

    /// Seitengrößen der PPD eines Ziels (`nil`: unbekanntes Modell).
    public static func entries(for target: Target, catalog: ModelCatalog = .shared) -> [Entry]? {
        guard let p = parameters(for: target, catalog: catalog) else { return nil }
        return entries(printWidthMM: p.printWidthMM, maxLabelLengthMM: p.maxLabelLengthMM,
                       defaultStock: p.defaultStock, catalog: catalog)
    }

    /// Schlüsselwörter der Seitengrößen einer PPD, z. B. für `LabelWerk-zd421t-203dpi`.
    public static func keywords(forPPDNamed name: String, catalog: ModelCatalog = .shared) -> [String]? {
        guard let target = target(forPPDNamed: name)?.target else { return nil }
        return entries(for: target, catalog: catalog)?.map(\.keyword)
    }

    /// Standardschlüsselwort (`*DefaultPageSize`) der PPD eines Ziels.
    public static func defaultKeyword(for target: Target, catalog: ModelCatalog = .shared) -> String? {
        parameters(for: target, catalog: catalog)?.defaultStock.ppdKeyword
    }

    /// Steht eine Etikettengröße als benannte Seitengröße in der PPD des Ziels?
    public static func contains(_ stock: LabelStock, target: Target, catalog: ModelCatalog = .shared) -> Bool {
        entries(for: target, catalog: catalog)?.contains { $0.keyword == stock.ppdKeyword } ?? false
    }
}

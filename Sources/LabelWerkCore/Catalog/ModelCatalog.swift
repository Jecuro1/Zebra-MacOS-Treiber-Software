import Foundation

/// Katalog aller bekannten Druckermodelle und Standard-Etikettenformate.
///
/// Quelle ist `Catalog/models.json`; der Inhalt wird zur Build-Zeit als Swift-Quelltext
/// eingebettet (`ModelCatalogData.swift`).
public final class ModelCatalog: Sendable {
    public let schemaVersion: Int
    public let models: [PrinterModel]
    public let stocks: [LabelStock]

    private struct Payload: Decodable {
        var schemaVersion: Int
        var models: [PrinterModel]
        var stocks: [LabelStock]
    }

    /// Der eingebettete Standardkatalog.
    public static let shared: ModelCatalog = {
        do {
            return try ModelCatalog(jsonData: Data(ModelCatalogData.json.utf8))
        } catch {
            preconditionFailure("Eingebetteter Modellkatalog ist ungültig: \(error)")
        }
    }()

    public init(jsonData: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: jsonData)
        self.schemaVersion = payload.schemaVersion
        self.models = payload.models
        self.stocks = payload.stocks
    }

    public init(models: [PrinterModel], stocks: [LabelStock]) {
        self.schemaVersion = 1
        self.models = models
        self.stocks = stocks
    }

    public func model(id: String) -> PrinterModel? {
        models.first { $0.id == id.lowercased() }
    }

    public func stock(id: String) -> LabelStock? {
        stocks.first { $0.id == id }
    }

    /// Modelle einer Kategorie, alphabetisch sortiert.
    public func models(in category: PrinterCategory) -> [PrinterModel] {
        models.filter { $0.category == category }.sorted { $0.name < $1.name }
    }

    /// Etikettenformate, die auf das Modell passen (Breite ≤ Druckbreite + 2 mm Toleranz).
    public func stocks(fitting model: PrinterModel) -> [LabelStock] {
        stocks.filter { $0.widthMM <= model.printWidthMM + 2 && $0.heightMM <= model.maxLabelLengthMM }
    }

    /// Ordnet einen IEEE-1284-Modellnamen (`MDL:`-Feld) exakt einem Modell zu.
    public func match(ieee1284Model mdl: String) -> PrinterModel? {
        let needle = Self.normalize(mdl)
        return models.first { model in model.ieee1284.contains { Self.normalize($0) == needle } }
    }

    /// Unscharfe Zuordnung anhand eines Produktnamens, z. B. aus `~HI` („ZD421-203dpi“),
    /// SGD `device.product_name` („ZD421t“), Bonjour-Namen oder CUPS-URIs.
    ///
    /// Bevorzugt die längste übereinstimmende Modellbezeichnung, sodass „ZD421t“ vor „ZD421d“
    /// und „ZT410“ vor „ZT41“ gewinnt.
    public func match(productName raw: String) -> PrinterModel? {
        if let exact = match(ieee1284Model: raw) { return exact }
        let hay = Self.normalize(raw)
        guard !hay.isEmpty else { return nil }
        var best: (model: PrinterModel, score: Int)?
        for model in models {
            let full = Self.normalize(model.name)
            // Basisname ohne d/t/c-Suffix (ZD421t -> ZD421)
            var base = full
            if let last = base.last, "dtc".contains(last), base.dropLast().last?.isNumber == true {
                base.removeLast()
            }
            var score = 0
            if hay.contains(full) { score = full.count * 2 + 1 }
            else if hay.contains(base) { score = base.count * 2 }
            if score > 0, score > (best?.score ?? 0) { best = (model, score) }
        }
        return best?.model
    }

    /// Kleinbuchstaben, nur Buchstaben und Ziffern.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

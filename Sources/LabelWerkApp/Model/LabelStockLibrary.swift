import Foundation
import LabelWerkKit

/// Eigene Etikettenformate anlegen und wiederverwenden – gemeinsam für „Druckeinstellungen“
/// („Benutzerdefiniert“), den Installationsassistenten („Vom Drucker“, „Benutzerdefiniert …“) und
/// das manuelle Hinzufügen. Die reine Zuordnungslogik steht in ``LabelSizing`` (LabelWerkCore, unter
/// Linux getestet).
@MainActor
enum LabelStockLibrary {

    /// Kennungspräfix der hier erzeugten eigenen Formate.
    static let customStockPrefix = "custom-prefs-"

    /// „Benutzerdefiniert 104 × 76,2 mm“.
    static func customStockName(widthMM: Double, heightMM: Double) -> String {
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
        return tr("Benutzerdefiniert %@ × %@ mm", number(widthMM), number(heightMM))
    }

    /// Vorhandenes Format zu einer erkannten bzw. eingegebenen Größe: eigene Formate vor dem Katalog,
    /// je Maß höchstens ± 0,6 mm Abweichung, passender Medientyp (``LabelSizing/matchingStock``).
    static func matchingStock(widthMM: Double, heightMM: Double, tracking: MediaTracking?,
                              model: AppModel) -> LabelStock? {
        LabelSizing.matchingStock(widthMM: widthMM, heightMM: heightMM, tracking: tracking,
                                  custom: model.customStocks, catalog: model.catalog.stocks)
    }

    /// Vorhandenes Format zur Größe, die der Drucker meldet (``PrinterClient/readMediaSize()``).
    static func matchingStock(for media: DetectedMedia, model: AppModel) -> LabelStock? {
        matchingStock(widthMM: media.widthMM, heightMM: media.heightMM, tracking: media.tracking, model: model)
    }

    /// Format für eine erkannte bzw. eingegebene Größe – vor dem Anlegen eines Installationsauftrags
    /// aufrufen („Vom Drucker“ bzw. „Benutzerdefiniert …“ im Assistenten und beim manuellen
    /// Hinzufügen): ein passendes vorhandenes Format (``matchingStock(widthMM:heightMM:tracking:model:)``),
    /// sonst ein neues eigenes Format „Benutzerdefiniert B × H mm“ (Maße auf 0,01 mm gerundet), das
    /// sofort in `model.customStocks` steht.
    @discardableResult
    static func resolveStock(widthMM: Double, heightMM: Double, tracking: MediaTracking?,
                             gapMM: Double = 3, mediaType: MediaType? = nil, model: AppModel) -> LabelStock {
        let width = LabelSizing.rounded(widthMM)
        let height = LabelSizing.rounded(heightMM)
        if let match = matchingStock(widthMM: width, heightMM: height, tracking: tracking, model: model) {
            return match
        }
        let stock = LabelStock(id: customStockPrefix + UUID().uuidString.lowercased(),
                               name: customStockName(widthMM: width, heightMM: height),
                               widthMM: width, heightMM: height, gapMM: gapMM, tracking: tracking ?? .gap,
                               mediaType: mediaType, category: .custom, isCustom: true)
        model.addCustomStock(stock)
        return model.stock(id: stock.id) ?? stock
    }

    /// Format für die Größe, die der Drucker meldet (siehe ``resolveStock(widthMM:heightMM:tracking:gapMM:mediaType:model:)``).
    @discardableResult
    static func resolveStock(for media: DetectedMedia, model: AppModel) -> LabelStock {
        resolveStock(widthMM: media.widthMM, heightMM: media.heightMM, tracking: media.tracking,
                     mediaType: media.mediaType, model: model)
    }

    /// Kennung des eigenen Formats für „Benutzerdefiniert“ im Dialog „Druckeinstellungen“:
    ///
    /// 1. Ein eigenes Format gleicher Größe (± 0,05 mm) und gleichen Medientyps wird wiederverwendet.
    /// 2. Sonst wird das zuletzt hier erzeugte Format des Druckers (`currentStock`, Präfix
    ///    ``customStockPrefix``) aktualisiert, solange es kein anderer Drucker und kein Etikettentyp nutzt,
    /// 3. sonst ein neues Format angelegt.
    static func customStockID(widthMM: Double, heightMM: Double, gapMM: Double, tracking: MediaTracking,
                              mediaType: MediaType?, currentStock: LabelStock, ownerID: UUID,
                              model: AppModel) -> String {
        let width = LabelSizing.rounded(widthMM)
        let height = LabelSizing.rounded(heightMM)
        if let match = LabelSizing.sameSizeStock(widthMM: width, heightMM: height, tracking: tracking,
                                                 in: model.customStocks) {
            return match.id
        }
        // Auch Etikettentypen (jedes Druckers) zählen: Ihr Format darf sich nicht unbemerkt ändern.
        let sharedWithOthers = model.sessions.contains { session in
            (session.id != ownerID && session.saved.stockID == currentStock.id)
                || session.saved.labelTypes.contains { $0.stockID == currentStock.id }
        }
        let id = currentStock.isCustom && currentStock.id.hasPrefix(customStockPrefix) && !sharedWithOthers
            ? currentStock.id
            : customStockPrefix + UUID().uuidString.lowercased()
        model.addCustomStock(LabelStock(id: id, name: customStockName(widthMM: width, heightMM: height),
                                        widthMM: width, heightMM: height, gapMM: gapMM, tracking: tracking,
                                        mediaType: mediaType, category: .custom, isCustom: true))
        return id
    }
}

import Foundation

/// Auswahl „Etikett“ im Installationsassistenten und beim manuellen Hinzufügen (ARCHITECTURE.md §9
/// „Etikettengröße der Warteschlange“): ein vorhandenes Format, die vom Drucker gemeldete Größe oder
/// eine eigene Eingabe. „Vom Drucker“ und „Benutzerdefiniert …“ werden erst beim Installieren bzw.
/// Hinzufügen zu einem echten Format (`LabelStockLibrary.resolveStock` in der App) – vorher legt die
/// Auswahl nichts an.
public enum LabelStockChoice: Hashable, Sendable {
    /// Vorhandenes Format (Katalog oder eigenes), Kennung `LabelStock.id`.
    case stock(String)
    /// „Vom Drucker: 104 × 76,2 mm“ – die gemeldete Größe, zu der es noch kein passendes Format gibt.
    case printer
    /// „Benutzerdefiniert …“ – Breite, Höhe und Medientyp von Hand (``LabelSizeEntry``).
    case custom

    /// Kennung des gewählten vorhandenen Formats (`nil` bei „Vom Drucker“ und „Benutzerdefiniert …“).
    public var stockID: String? {
        if case .stock(let id) = self { return id }
        return nil
    }

    /// Vorauswahl nach einer Größenmeldung des Druckers.
    ///
    /// * Ohne gemeldete Größe bleibt die Auswahl – nur „Vom Drucker“ fällt auf `fallbackStockID`
    ///   zurück (die Meldung gibt es nicht mehr, z. B. nach dem Wechsel des Druckers).
    /// * Hat der Benutzer die Auswahl geändert (`touched`), bleibt sie.
    /// * Sonst gewinnt die gemeldete Größe: als passendes vorhandenes Format (`matchingStockID`, siehe
    ///   ``LabelSizing/matchingStock(widthMM:heightMM:tracking:custom:catalog:)``), sonst als
    ///   „Vom Drucker“.
    public static func preselection(current: LabelStockChoice, touched: Bool, hasDetectedSize: Bool,
                                    matchingStockID: String?, fallbackStockID: String) -> LabelStockChoice {
        guard hasDetectedSize else {
            return current == .printer ? .stock(fallbackStockID) : current
        }
        if touched { return current }
        return matchingStockID.map(LabelStockChoice.stock) ?? .printer
    }
}

/// Eingabe „Benutzerdefiniert …“: Breite und Höhe als Text in Millimetern (Komma oder Punkt als
/// Dezimaltrenner, ``LabelSizing/parseMillimeters(_:)``) und der Medientyp.
public struct LabelSizeEntry: Equatable, Sendable {
    public var widthText: String
    public var heightText: String
    public var tracking: MediaTracking

    public init(widthText: String = "", heightText: String = "", tracking: MediaTracking = .gap) {
        self.widthText = widthText
        self.heightText = heightText
        self.tracking = tracking
    }

    /// Vorbelegt mit einer Größe, z. B. `104` × `76,2` (deutsches Komma).
    public init(widthMM: Double, heightMM: Double, tracking: MediaTracking) {
        self.init(widthText: LabelSizing.format(widthMM), heightText: LabelSizing.format(heightMM),
                  tracking: tracking)
    }

    /// Eingegebene Breite in mm (auf 0,01 mm gerundet), `nil` bei leerer oder ungültiger Eingabe.
    public var widthMM: Double? { LabelSizing.parseMillimeters(widthText).map(LabelSizing.rounded) }
    /// Eingegebene Höhe in mm (auf 0,01 mm gerundet), `nil` bei leerer oder ungültiger Eingabe.
    public var heightMM: Double? { LabelSizing.parseMillimeters(heightText).map(LabelSizing.rounded) }

    /// Noch nichts eingegeben.
    public var isEmpty: Bool {
        widthText.trimmingCharacters(in: .whitespaces).isEmpty && heightText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Fehler der Eingabe in den Grenzen des Modells (leer = gültig).
    public func issues(in limits: LabelSizing.Limits) -> [LabelSizing.Issue] {
        limits.issues(widthMM: widthMM, heightMM: heightMM)
    }

    /// Fehler, die das Feld „Breite“ betreffen.
    public func widthIssues(in limits: LabelSizing.Limits) -> [LabelSizing.Issue] {
        issues(in: limits).filter(\.concernsWidth)
    }

    /// Fehler, die das Feld „Höhe“ betreffen.
    public func heightIssues(in limits: LabelSizing.Limits) -> [LabelSizing.Issue] {
        issues(in: limits).filter { !$0.concernsWidth }
    }

    /// Gültige Größe in mm, sonst `nil`.
    public func size(in limits: LabelSizing.Limits) -> (widthMM: Double, heightMM: Double)? {
        guard let widthMM, let heightMM, issues(in: limits).isEmpty else { return nil }
        return (widthMM, heightMM)
    }
}

extension LabelSizing.Issue {
    /// Betrifft der Fehler die Breite (sonst die Höhe)?
    public var concernsWidth: Bool {
        switch self {
        case .widthMissing, .widthTooSmall, .widthTooLarge: return true
        case .heightMissing, .heightTooSmall, .heightTooLarge: return false
        }
    }
}

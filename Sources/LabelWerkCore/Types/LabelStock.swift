import Foundation

/// Etikettenmaterial („Stock“) – entspricht den Etikettenformaten des Windows-Treibers.
public struct LabelStock: Codable, Identifiable, Hashable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case shipping
        case product
        case barcode
        case address
        case receipt
        case jewelry
        case wristband
        case custom

        public var displayName: String {
            switch self {
            case .shipping: return "Versand"
            case .product: return "Produkt"
            case .barcode: return "Barcode"
            case .address: return "Adresse"
            case .receipt: return "Beleg"
            case .jewelry: return "Schmuck"
            case .wristband: return "Armband"
            case .custom: return "Benutzerdefiniert"
            }
        }
    }

    /// Stabile Kennung, z. B. `w4h6in` oder eine UUID für eigene Formate.
    public var id: String
    public var name: String
    public var widthMM: Double
    /// Etikettenlänge (bei Endlosmaterial: Standardlänge eines Abschnitts).
    public var heightMM: Double
    /// Lücke bzw. Markenhöhe in mm.
    public var gapMM: Double
    public var tracking: MediaTracking
    public var mediaType: MediaType?
    public var category: Category
    public var isCustom: Bool

    public init(
        id: String,
        name: String,
        widthMM: Double,
        heightMM: Double,
        gapMM: Double = 3,
        tracking: MediaTracking = .gap,
        mediaType: MediaType? = nil,
        category: Category = .custom,
        isCustom: Bool = true
    ) {
        self.id = id
        self.name = name
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.gapMM = gapMM
        self.tracking = tracking
        self.mediaType = mediaType
        self.category = category
        self.isCustom = isCustom
    }

    public var isContinuous: Bool { tracking == .continuous }

    public func widthDots(_ resolution: Resolution) -> Int { resolution.dots(fromMM: widthMM) }
    public func heightDots(_ resolution: Resolution) -> Int { resolution.dots(fromMM: heightMM) }
    public func gapDots(_ resolution: Resolution) -> Int { resolution.dots(fromMM: gapMM) }

    /// Breite in PostScript-Punkten (1/72 Zoll).
    public var widthPoints: Double { widthMM / 25.4 * 72.0 }
    /// Höhe in PostScript-Punkten (1/72 Zoll).
    public var heightPoints: Double { heightMM / 25.4 * 72.0 }

    /// PPD-Schlüsselwort der Seitengröße nach CUPS-Konvention `w<pt>h<pt>` (gerundet).
    public var ppdKeyword: String {
        "w\(Int(widthPoints.rounded()))h\(Int(heightPoints.rounded()))"
    }

    /// Lesbare Größenangabe, z. B. `101,6 × 152,4 mm (4,00 × 6,00 Zoll)`.
    public var sizeDescription: String {
        func fmt(_ v: Double, _ digits: Int) -> String {
            String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
        }
        return "\(fmt(widthMM, 1)) × \(fmt(heightMM, 1)) mm (\(fmt(widthMM / 25.4, 2)) × \(fmt(heightMM / 25.4, 2)) Zoll)"
    }
}

// MARK: - Tolerantes Dekodieren

extension LabelStock {
    /// Pflicht sind nur Kennung, Name und Maße; fehlende oder unbekannte übrige Werte
    /// (z. B. aus einer neueren App-Version) erhalten Standardwerte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            widthMM: try c.decode(Double.self, forKey: .widthMM),
            heightMM: try c.decode(Double.self, forKey: .heightMM),
            gapMM: value(Double.self, .gapMM) ?? 3,
            tracking: value(MediaTracking.self, .tracking) ?? .gap,
            mediaType: value(MediaType.self, .mediaType),
            category: value(Category.self, .category) ?? .custom,
            isCustom: value(Bool.self, .isCustom) ?? true
        )
    }
}

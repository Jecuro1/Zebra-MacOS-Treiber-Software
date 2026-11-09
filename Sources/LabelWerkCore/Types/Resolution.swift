import Foundation

/// Druckauflösung eines Druckkopfs.
///
/// Zebra-Drucker arbeiten intern mit "dots per millimetre" (dpmm). 203 dpi entsprechen 8 dpmm,
/// 300 dpi 12 dpmm, 600 dpi 24 dpmm.
public enum Resolution: Int, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case dpi152 = 152
    case dpi203 = 203
    case dpi300 = 300
    case dpi600 = 600

    public var id: Int { rawValue }

    /// Nominelle Auflösung in dpi.
    public var dpi: Int { rawValue }

    /// Punkte pro Millimeter, wie ihn ZPL (`~HI`, `^MU`) verwendet.
    public var dotsPerMM: Int {
        switch self {
        case .dpi152: return 6
        case .dpi203: return 8
        case .dpi300: return 12
        case .dpi600: return 24
        }
    }

    /// Exakter Wert für Umrechnungen (dpi / 25.4).
    public var exactDotsPerMM: Double { Double(rawValue) / 25.4 }

    public init?(dpi: Int) { self.init(rawValue: dpi) }

    /// Erzeugt die Auflösung aus einem dpmm-Wert (6, 8, 12, 24).
    public init?(dotsPerMM: Int) {
        switch dotsPerMM {
        case 6: self = .dpi152
        case 8: self = .dpi203
        case 12: self = .dpi300
        case 24: self = .dpi600
        default: return nil
        }
    }

    /// Wandelt Millimeter in Punkte um (gerundet).
    public func dots(fromMM mm: Double) -> Int { Int((mm * exactDotsPerMM).rounded()) }

    /// Wandelt Zoll in Punkte um (gerundet).
    public func dots(fromInches inches: Double) -> Int { Int((inches * Double(rawValue)).rounded()) }

    /// Wandelt PostScript-Punkte (1/72 Zoll) in Druckerpunkte um (gerundet).
    public func dots(fromPoints points: Double) -> Int { Int((points * Double(rawValue) / 72.0).rounded()) }

    /// Wandelt Punkte in Millimeter um.
    public func mm(fromDots dots: Int) -> Double { Double(dots) / exactDotsPerMM }

    /// Wandelt Punkte in Zoll um.
    public func inches(fromDots dots: Int) -> Double { Double(dots) / Double(rawValue) }

    public var displayName: String { "\(rawValue) dpi" }

    public static func < (lhs: Resolution, rhs: Resolution) -> Bool { lhs.rawValue < rhs.rawValue }
}

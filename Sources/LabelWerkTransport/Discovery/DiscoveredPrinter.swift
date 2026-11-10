import Foundation

/// Quelle, über die ein Drucker gefunden wurde.
public enum DiscoverySource: String, Codable, Sendable, CaseIterable {
    case bonjour, usb, network, cups, bluetooth, ble

    /// Deutscher Anzeigename.
    public var displayName: String {
        switch self {
        case .bonjour: return "Bonjour"
        case .usb: return "USB"
        case .network: return "Netzwerksuche"
        case .cups: return "CUPS"
        case .bluetooth: return "Bluetooth"
        case .ble: return "Bluetooth LE"
        }
    }

    /// SF Symbol der Quelle.
    public var systemImage: String {
        switch self {
        case .bonjour: return "bonjour"
        case .usb: return "cable.connector"
        case .network: return "network"
        case .cups: return "printer"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .ble: return "dot.radiowaves.left.and.right"
        }
    }

    /// `true`, wenn die Quelle auf dieser Plattform Ergebnisse liefern kann.
    public var isAvailableOnThisPlatform: Bool {
        switch self {
        case .network, .cups, .bonjour:
            return true
        case .usb, .bluetooth, .ble:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        }
    }
}

/// Ein bei der Suche gefundener Drucker.
///
/// Übliche Schlüssel in `details` (alle optional): `host`, `port`, `serviceName`, `serviceType`,
/// `firmware`, `serialNumber`, `locationID`, `productID`, `productName`, `sysDescr`, `deviceURI`,
/// `makeAndModel`, `isDefault`, `address`, `rssi`, `identifiedBy`.
public struct DiscoveredPrinter: Identifiable, Hashable, Codable, Sendable {
    /// Stabil, aus dem Deskriptor abgeleitet (`ConnectionDescriptor.stableID`).
    public var id: String
    public var name: String
    /// z. B. „ZD421-203dpi“ → `ModelCatalog.match(productName:)`.
    public var modelHint: String?
    public var descriptor: ConnectionDescriptor
    public var source: DiscoverySource
    public var details: [String: String]

    public init(
        name: String,
        modelHint: String? = nil,
        descriptor: ConnectionDescriptor,
        source: DiscoverySource,
        details: [String: String] = [:]
    ) {
        self.id = descriptor.stableID
        self.name = name
        self.modelHint = modelHint
        self.descriptor = descriptor
        self.source = source
        self.details = details
    }

    public init(
        id: String,
        name: String,
        modelHint: String?,
        descriptor: ConnectionDescriptor,
        source: DiscoverySource,
        details: [String: String]
    ) {
        self.id = id
        self.name = name
        self.modelHint = modelHint
        self.descriptor = descriptor
        self.source = source
        self.details = details
    }
}

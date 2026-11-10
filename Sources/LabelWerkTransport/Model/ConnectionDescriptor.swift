import Foundation

// MARK: - USB-Gerätekennung

/// Kennung eines USB-Druckers.
///
/// `serialNumber` identifiziert ein Gerät dauerhaft, `locationID` beschreibt den Anschluss
/// (ändert sich beim Umstecken). Beim Öffnen wird zuerst die Seriennummer, dann die
/// Anschlussposition, sonst das erste passende Gerät verwendet.
public struct USBDeviceIdentifier: Codable, Hashable, Sendable {
    public var vendorID: Int
    /// Produkt-ID; `0` bedeutet „beliebiges Produkt dieses Herstellers“.
    public var productID: Int
    public var serialNumber: String?
    public var locationID: UInt32?
    public var productName: String?

    public init(
        vendorID: Int = ZebraIdentifiers.usbVendorID,
        productID: Int,
        serialNumber: String? = nil,
        locationID: UInt32? = nil,
        productName: String? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.productName = productName
    }
}

// MARK: - Verbindungsart

/// Art einer Druckerverbindung.
public enum ConnectionKind: String, Codable, Sendable, CaseIterable {
    case tcp, usb, bluetooth, ble, cupsQueue, virtual

    /// Deutscher Anzeigename.
    public var displayName: String {
        switch self {
        case .tcp: return "Netzwerk"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .ble: return "Bluetooth LE"
        case .cupsQueue: return "CUPS-Warteschlange"
        case .virtual: return "Virtueller Drucker"
        }
    }

    /// SF Symbol der Verbindungsart (alle ab SF Symbols 2 / macOS 11 verfügbar).
    public var systemImage: String {
        switch self {
        case .tcp: return "network"
        case .usb: return "cable.connector"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .ble: return "dot.radiowaves.left.and.right"
        case .cupsQueue: return "printer"
        case .virtual: return "cube.transparent"
        }
    }
}

// MARK: - Verbindungsbeschreibung

/// Vollständige, speicherbare Beschreibung einer Druckerverbindung.
///
/// Die JSON-Darstellung ist bewusst flach und stabil (siehe `CodingKeys`):
/// `{"kind":"tcp","host":"192.168.1.20","port":9100}`,
/// `{"kind":"usb","device":{"vendorID":2655,"productID":385,…}}`,
/// `{"kind":"bluetooth","address":"AC-3F-A4-12-34-56","name":"XXZBJ"}`,
/// `{"kind":"ble","identifier":"<UUID>","name":"…"}`,
/// `{"kind":"cupsQueue","name":"Zebra_ZD421"}`, `{"kind":"virtual","id":"demo"}`.
public enum ConnectionDescriptor: Codable, Hashable, Sendable {
    case tcp(host: String, port: Int)
    case usb(USBDeviceIdentifier)
    /// Klassisches Bluetooth, RFCOMM/SPP.
    case bluetooth(address: String, name: String?)
    /// CoreBluetooth-Peripheral-UUID.
    case ble(identifier: String, name: String?)
    /// Nur Senden (`lp -o raw`).
    case cupsQueue(name: String)
    /// Virtueller Drucker (LabelWerkKit).
    case virtual(id: String)

    public var kind: ConnectionKind {
        switch self {
        case .tcp: return .tcp
        case .usb: return .usb
        case .bluetooth: return .bluetooth
        case .ble: return .ble
        case .cupsQueue: return .cupsQueue
        case .virtual: return .virtual
        }
    }

    /// Anzeigetext, z. B. `"192.168.1.20:9100"`, `"USB · ZD421"`, `"Bluetooth · XXZBJ203"`.
    public var displayString: String {
        switch self {
        case .tcp(let host, let port):
            let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "\(shownHost):\(port)"
        case .usb(let device):
            if let name = device.productName.flatMap(ZebraIdentifiers.shortModelName(from:)) {
                return "USB · \(name)"
            }
            if let serial = device.serialNumber, !serial.isEmpty {
                return "USB · Seriennr. \(serial)"
            }
            return String(format: "USB · %04lX:%04lX", device.vendorID, device.productID)
        case .bluetooth(let address, let name):
            return "Bluetooth · \(Self.nonEmpty(name) ?? address)"
        case .ble(let identifier, let name):
            return "Bluetooth LE · \(Self.nonEmpty(name) ?? String(identifier.prefix(8)))"
        case .cupsQueue(let name):
            return "CUPS-Warteschlange · \(name)"
        case .virtual(let id):
            return "Virtueller Drucker · \(id)"
        }
    }

    /// SF Symbol der Verbindung.
    public var systemImage: String { kind.systemImage }

    /// `false` nur für CUPS-Warteschlangen (reines Senden, keine Statusabfrage möglich).
    public var supportsBidirectional: Bool {
        if case .cupsQueue = self { return false }
        return true
    }

    /// Stabile Kennung des Geräts, unabhängig von veränderlichen Zusatzangaben
    /// (Anzeigename, Produktname; bei USB mit Seriennummer auch der Anschluss).
    ///
    /// Wird als `DiscoveredPrinter.id` verwendet und eignet sich zum Wiedererkennen gespeicherter Drucker.
    public var stableID: String {
        switch self {
        case .tcp(let host, let port):
            var normalized = host.lowercased()
            if normalized.hasPrefix("["), normalized.hasSuffix("]") {
                normalized = String(normalized.dropFirst().dropLast())
            }
            return "tcp:\(normalized):\(port)"
        case .usb(let device):
            let base = String(format: "usb:%04lx:%04lx", device.vendorID, device.productID)
            if let serial = device.serialNumber, !serial.isEmpty { return "\(base):\(serial)" }
            if let location = device.locationID { return base + String(format: ":@%08x", location) }
            return base
        case .bluetooth(let address, _):
            return "bluetooth:\(Self.normalizedBluetoothAddress(address))"
        case .ble(let identifier, _):
            return "ble:\(identifier.uppercased())"
        case .cupsQueue(let name):
            return "cups:\(name)"
        case .virtual(let id):
            return "virtual:\(id)"
        }
    }

    /// `true`, wenn beide Beschreibungen dasselbe Gerät meinen (Vergleich über `stableID`).
    public func refersToSameDevice(as other: ConnectionDescriptor) -> Bool {
        stableID == other.stableID
    }

    /// Bluetooth-Adresse in der Form `AA-BB-CC-DD-EE-FF` (wie IOBluetooth sie liefert).
    public static func normalizedBluetoothAddress(_ address: String) -> String {
        let hex = address.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return address.uppercased() }
        var parts: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: "-")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Codable (stabiles, flaches Format)

    private enum CodingKeys: String, CodingKey {
        case kind, host, port, device, address, name, identifier, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ConnectionKind.self, forKey: .kind)
        switch kind {
        case .tcp:
            let host = try container.decode(String.self, forKey: .host)
            let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? ZebraIdentifiers.rawPort
            self = .tcp(host: host, port: port)
        case .usb:
            self = .usb(try container.decode(USBDeviceIdentifier.self, forKey: .device))
        case .bluetooth:
            self = .bluetooth(
                address: try container.decode(String.self, forKey: .address),
                name: try container.decodeIfPresent(String.self, forKey: .name)
            )
        case .ble:
            self = .ble(
                identifier: try container.decode(String.self, forKey: .identifier),
                name: try container.decodeIfPresent(String.self, forKey: .name)
            )
        case .cupsQueue:
            self = .cupsQueue(name: try container.decode(String.self, forKey: .name))
        case .virtual:
            self = .virtual(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .tcp(let host, let port):
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case .usb(let device):
            try container.encode(device, forKey: .device)
        case .bluetooth(let address, let name):
            try container.encode(address, forKey: .address)
            try container.encodeIfPresent(name, forKey: .name)
        case .ble(let identifier, let name):
            try container.encode(identifier, forKey: .identifier)
            try container.encodeIfPresent(name, forKey: .name)
        case .cupsQueue(let name):
            try container.encode(name, forKey: .name)
        case .virtual(let id):
            try container.encode(id, forKey: .id)
        }
    }
}

// MARK: - URI-Darstellung (lwctl `--printer`)

extension ConnectionDescriptor {
    /// Erzeugt eine Beschreibung aus einer Drucker-URI.
    ///
    /// Unterstützt: `tcp://host[:port]` (auch `socket://`), `usb://vid:pid[/seriennummer]` (hex),
    /// `cups://warteschlange`, `virtual://id`, `bluetooth://AA:BB:CC:DD:EE:FF` (auch `bt://`),
    /// `ble://<UUID>`. Ohne Schema wird `host[:port]` als TCP interpretiert.
    public init?(uriString raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let scheme: String
        let rest: String
        if let range = text.range(of: "://") {
            scheme = text[..<range.lowerBound].lowercased()
            rest = String(text[range.upperBound...])
        } else {
            scheme = "tcp"
            rest = text
        }
        let body = rest.hasSuffix("/") ? String(rest.dropLast()) : rest
        guard !body.isEmpty else { return nil }
        let decoded = body.removingPercentEncoding ?? body

        switch scheme {
        case "tcp", "socket", "raw":
            guard let (host, port) = Self.splitHostPort(body) else { return nil }
            self = .tcp(host: host, port: port ?? ZebraIdentifiers.rawPort)
        case "usb":
            let pieces = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let ids = pieces[0].split(separator: ":")
            guard ids.count == 2,
                  let vendor = Int(ids[0], radix: 16),
                  let product = Int(ids[1], radix: 16)
            else { return nil }
            var serial: String?
            if pieces.count == 2, !pieces[1].isEmpty {
                serial = String(pieces[1]).removingPercentEncoding ?? String(pieces[1])
            }
            self = .usb(USBDeviceIdentifier(vendorID: vendor, productID: product, serialNumber: serial))
        case "cups", "queue":
            self = .cupsQueue(name: decoded)
        case "virtual":
            self = .virtual(id: decoded)
        case "bluetooth", "bt":
            self = .bluetooth(address: Self.normalizedBluetoothAddress(decoded), name: nil)
        case "ble":
            guard UUID(uuidString: decoded) != nil else { return nil }
            self = .ble(identifier: decoded.uppercased(), name: nil)
        default:
            return nil
        }
    }

    /// URI-Darstellung, die `init(uriString:)` wieder einliest.
    public var uriString: String {
        switch self {
        case .tcp(let host, let port):
            let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "tcp://\(shownHost):\(port)"
        case .usb(let device):
            var uri = String(format: "usb://%04lx:%04lx", device.vendorID, device.productID)
            if let serial = device.serialNumber, !serial.isEmpty {
                uri += "/" + Self.percentEncoded(serial)
            }
            return uri
        case .cupsQueue(let name):
            return "cups://" + Self.percentEncoded(name)
        case .virtual(let id):
            return "virtual://" + Self.percentEncoded(id)
        case .bluetooth(let address, _):
            return "bluetooth://" + Self.normalizedBluetoothAddress(address)
        case .ble(let identifier, _):
            return "ble://" + identifier.uppercased()
        }
    }

    private static func percentEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Zerlegt `host`, `host:port`, `[v6]`, `[v6]:port` oder eine reine IPv6-Adresse.
    static func splitHostPort(_ text: String) -> (host: String, port: Int?)? {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let remainder = text[text.index(after: close)...]
            if remainder.isEmpty { return host.isEmpty ? nil : (host, nil) }
            guard remainder.hasPrefix(":"), let port = Int(remainder.dropFirst()), (1...65535).contains(port) else {
                return nil
            }
            return host.isEmpty ? nil : (host, port)
        }
        let colons = text.filter { $0 == ":" }.count
        if colons == 1, let colon = text.firstIndex(of: ":") {
            let host = String(text[..<colon])
            guard !host.isEmpty, let port = Int(text[text.index(after: colon)...]), (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }
        return (text, nil)
    }
}

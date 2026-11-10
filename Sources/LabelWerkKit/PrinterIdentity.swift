import Foundation
import LabelWerkCore

// MARK: - Identität

/// Identität eines verbundenen Druckers, ermittelt aus `~HI` und SGD-Variablen
/// (siehe ``PrinterClient/identify()``).
///
/// Alle Angaben sind optional, weil ältere Drucker (ohne Link-OS bzw. SGD) nur einen Teil
/// liefern und mobile Drucker im Line-Print-Modus kein `~HI` beantworten.
public struct PrinterIdentity: Codable, Hashable, Sendable {
    /// Rohname aus `device.product_name` bzw. `~HI` (z. B. „ZD421t“ oder „ZD421-203dpi“).
    public var model: String?
    /// Kennung des zugeordneten Modells im ``ModelCatalog`` (z. B. `zd421t`).
    public var matchedModelID: String?
    /// Seriennummer (`device.unique_id`).
    public var serialNumber: String?
    /// Firmware-Version (`appl.name` bzw. `~HI`), z. B. „V84.20.18Z“.
    public var firmware: String?
    /// Anzeigename des Druckers (`device.friendly_name`).
    public var friendlyName: String?
    /// Druckkopfauflösung (`head.resolution.in_dpi` bzw. dpmm aus `~HI`).
    public var resolution: Resolution?
    /// Eingestellte Druckbreite in Punkten (`ezpl.print_width`).
    public var printWidthDots: Int?
    /// Speicher in KB laut `~HI`.
    public var memoryKB: Int?
    /// Unterstützte bzw. aktive Befehlssprachen.
    public var languages: [PrinterLanguage]
    /// Aktive IP-Adresse.
    public var ipAddress: String?
    /// MAC-Adresse der aktiven Netzwerkschnittstelle.
    public var macAddress: String?
    /// `true`, wenn der Drucker Link-OS (JSON-SGD, `allconfig`) unterstützt.
    public var isLinkOS: Bool

    public init(
        model: String? = nil,
        matchedModelID: String? = nil,
        serialNumber: String? = nil,
        firmware: String? = nil,
        friendlyName: String? = nil,
        resolution: Resolution? = nil,
        printWidthDots: Int? = nil,
        memoryKB: Int? = nil,
        languages: [PrinterLanguage] = [],
        ipAddress: String? = nil,
        macAddress: String? = nil,
        isLinkOS: Bool = false
    ) {
        self.model = model
        self.matchedModelID = matchedModelID
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.friendlyName = friendlyName
        self.resolution = resolution
        self.printWidthDots = printWidthDots
        self.memoryKB = memoryKB
        self.languages = languages
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.isLinkOS = isLinkOS
    }

    /// Das zugeordnete Katalogmodell (sofern bekannt).
    public var matchedModel: PrinterModel? {
        matchedModelID.flatMap { ModelCatalog.shared.model(id: $0) }
    }

    /// Lesbarer Name: Anzeigename, sonst Katalogname, sonst Rohname.
    public var displayName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        if let model = matchedModel { return model.displayName }
        return model ?? "Unbekannter Drucker"
    }
}

// MARK: - Netzwerkeinstellungen

/// Netzwerkeinstellungen eines Druckers (kabelgebunden/aktive Schnittstelle und WLAN), gelesen
/// und geschrieben über SGD (`ip.*`, `wlan.*`).
public struct NetworkSettings: Codable, Hashable, Sendable {
    /// Adresse per DHCP beziehen (`ip.ip_protocol` ≠ `permanent`).
    public var useDHCP: Bool
    /// IPv4-Adresse (bei DHCP: die aktuell zugewiesene).
    public var ipAddress: String
    /// Subnetzmaske.
    public var subnetMask: String
    /// Standard-Gateway.
    public var gateway: String
    /// DNS-Server (`ip.dns.servers`).
    public var dnsServer: String?
    /// Hostname, den der Drucker per DHCP (Option 12) meldet.
    public var hostname: String?
    /// WLAN ein/aus (`wlan.enable`); `nil` = Drucker ohne WLAN.
    public var wlanEnabled: Bool?
    /// SSID (`wlan.essid`).
    public var wlanSSID: String?
    /// Sicherheitsmodus (`wlan.security`, z. B. „wpa2 psk“).
    public var wlanSecurity: String?
    /// WPA-Passphrase – nur schreiben; wird beim Lesen nie gefüllt.
    public var wlanPassphrase: String?
    /// MAC-Adresse der aktiven Schnittstelle – nur lesen.
    public var macAddress: String?

    public init(
        useDHCP: Bool = true,
        ipAddress: String = "0.0.0.0",
        subnetMask: String = "255.255.255.0",
        gateway: String = "0.0.0.0",
        dnsServer: String? = nil,
        hostname: String? = nil,
        wlanEnabled: Bool? = nil,
        wlanSSID: String? = nil,
        wlanSecurity: String? = nil,
        wlanPassphrase: String? = nil,
        macAddress: String? = nil
    ) {
        self.useDHCP = useDHCP
        self.ipAddress = ipAddress
        self.subnetMask = subnetMask
        self.gateway = gateway
        self.dnsServer = dnsServer
        self.hostname = hostname
        self.wlanEnabled = wlanEnabled
        self.wlanSSID = wlanSSID
        self.wlanSecurity = wlanSecurity
        self.wlanPassphrase = wlanPassphrase
        self.macAddress = macAddress
    }

    /// `true`, wenn `text` eine gültige IPv4-Adresse in Punktschreibweise ist (`192.168.1.20`).
    public static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return false }
            return value <= 255
        }
    }
}

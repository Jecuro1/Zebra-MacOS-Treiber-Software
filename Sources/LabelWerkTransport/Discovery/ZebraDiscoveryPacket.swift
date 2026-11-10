import Foundation

/// Zebras eigene Netzwerksuche („Zebra-Suche“, UDP-Port 4201) – Aufbau der Anfrage und Auswertung
/// der Antwort, ohne Netzwerkzugriff (unter Linux getestet).
///
/// So finden die Windows-Programme von Zebra (Zebra Setup Utilities, ZebraNet Bridge, ZDownloader)
/// und das Link-OS-SDK (`NetworkDiscoverer`: `localBroadcast`, `directedBroadcast`, `multicast`,
/// `subnetSearch`) Zebra-Drucker: Der Rechner schickt sechs Bytes an UDP 4201 – als Broadcast, an die
/// Multicast-Gruppe 224.0.1.55 oder direkt an einzelne Adressen eines Bereichs –, und jeder
/// Zebra-Druckserver antwortet von Port 4201 an den Absenderport mit einem Paket fester Länge (376
/// Byte), das Modell, Firmware, MAC-Adresse, Seriennummer, IP-Einstellungen und Systemnamen enthält.
/// Die Anfrage ist für fremde Geräte bedeutungslos (kein Ausdruck, keine Konfiguration).
///
/// **Paketaufbau** (Offsets dezimal; Texte enden am ersten NUL, Rest mit NUL aufgefüllt):
///
/// | Offset | Länge | Inhalt | Beispiel |
/// |---:|---:|---|---|
/// | 0 | 3 | Kennung `3A 2C 2E` („:,.“) | |
/// | 3 | 1 | Paketversion | `03` |
/// | 4 | 8 | Produktnummer | „V84“, „79071“ |
/// | 12 | 20 | Produktname (auf 20 Zeichen gekürzt) | „ZTC ZD620-300dpi ZPL“ |
/// | 32 | 7 | Datumscode | „72221“ |
/// | 39 | 10 | Firmware | „V84.20.23Z“ |
/// | 49 | 5 | Firmenkürzel | „ZBR“ |
/// | 54 | 6 | MAC-Adresse | `00 07 4D A3 CC A7` |
/// | 60 | 10 | Seriennummer des Druckservers | „10734759“ |
/// | 70 | 2 | „Netzwerkprotokoll aktiv“ (unsicher) | `01 00` |
/// | 72 | 4 | IP-Adresse | |
/// | 76 | 4 | Subnetzmaske | |
/// | 80 | 4 | Gateway | |
/// | 84 | 25 | Systemname | „ZEBRA-ZD620“, „ZBR4262077“ |
///
/// Anfrage: `2E 2C 3A 01 00 00` („.,:“ + `01 00 00`). Multicast-Gruppe 224.0.1.55, Port 4201.
///
/// Quellen (abgerufen 2026-11-10; drei voneinander unabhängige Beschreibungen, zwei davon an echten
/// Druckern gemessen, alle mit denselben Offsets):
/// * J. Runyon, „Zebra network discovery protocol“ (2024-09-11), vollständiger Mitschnitt einer
///   Antwort eines ZebraNet-Druckservers: <https://jfr.im/blog/2024/09/zebra-network-discovery-protocol/>
/// * Zebra Print Service für Android (Quelltext), Multicast-Gruppe 224.0.1.55:4201, Anfrage
///   `{46, 44, 58, 1, 0, 0}`, Produktname @12, IP @72, Systemname @84, Seriennummer @60:
///   <https://github.com/Thunderlight-Software/Zebra-Print-Service> (`AddActivity.java`,
///   `NetworkDevice.java`)
/// * monochrome-unicorn, an ZD620 und ZD500R gemessene Tabelle (2026-10-24, 376 Byte):
///   <https://github.com/TylerWhittaker/monochrome-unicorn> (`docs/printer-notes.md`, `tools/discover.mjs`)
/// * Port 4201 für die Suche: Zebra ZDownloader User Guide und Zebra Print System Requirements
///   (docs.zebra.com); Suchverfahren und Bereichsangaben: Link-OS SDK `NetworkDiscoverer`
///   (techdocs.zebra.com/link-os, `subnetSearch`: „192.168.2.*“, „192.168.2.37-42“).
public enum ZebraDiscoveryPacket {
    /// UDP-Port, an dem Zebra-Druckserver auf Suchanfragen warten.
    public static let port = 4201
    /// Multicast-Gruppe der Zebra-Suche (Link-OS `NetworkDiscoverer.multicast`).
    public static let multicastGroup = "224.0.1.55"
    /// Reichweite der Multicast-Anfrage in Routersprüngen (TTL), wie Zebra Setup Utilities.
    public static let defaultMulticastHops = 3
    /// Die Suchanfrage („.,:“ + `01 00 00`).
    public static let request: [UInt8] = [0x2E, 0x2C, 0x3A, 0x01, 0x00, 0x00]
    /// Kennung am Anfang jeder Antwort („:,.“).
    public static let replyMagic: [UInt8] = [0x3A, 0x2C, 0x2E]
    /// Länge einer vollständigen Antwort (ZD620, ZD500R; der Mitschnitt des ZebraNet-Druckservers
    /// endet nach 375 Byte). Ausgewertet werden nur die ersten 109 Byte.
    public static let replyLength = 376

    /// Lage der Felder in der Antwort (Offset, Länge).
    enum Field {
        static let version = 3
        static let productNumber = (offset: 4, length: 8)
        static let productName = (offset: 12, length: 20)
        static let dateCode = (offset: 32, length: 7)
        static let firmware = (offset: 39, length: 10)
        static let company = (offset: 49, length: 5)
        static let macAddress = (offset: 54, length: 6)
        static let serialNumber = (offset: 60, length: 10)
        static let ipAddress = (offset: 72, length: 4)
        static let subnetMask = (offset: 76, length: 4)
        static let gateway = (offset: 80, length: 4)
        static let systemName = (offset: 84, length: 25)
    }

    /// Ausgewertete Antwort eines Zebra-Druckservers. Fehlende oder nicht druckbare Felder sind `nil`.
    public struct Reply: Hashable, Sendable, Codable {
        public var version: UInt8
        public var productNumber: String?
        /// Produktname, z. B. „ZTC ZD620-300dpi ZPL“ (höchstens 20 Zeichen) – bei externen
        /// Druckservern deren Name („ZebraNet Wired PS“).
        public var productName: String?
        public var dateCode: String?
        public var firmware: String?
        public var company: String?
        /// „00:07:4D:A3:CC:A7“ (Großbuchstaben, Doppelpunkte).
        public var macAddress: String?
        /// Seriennummer des Druckservers (bei eingebauten Druckservern nicht immer die des Druckers).
        public var serialNumber: String?
        public var ipAddress: String?
        public var subnetMask: String?
        public var gateway: String?
        /// Systemname (frei einstellbar, Werkseinstellung z. B. „ZEBRA-ZD620“ oder „ZBR<Seriennummer>“).
        public var systemName: String?

        public init(
            version: UInt8 = 3, productNumber: String? = nil, productName: String? = nil, dateCode: String? = nil,
            firmware: String? = nil, company: String? = nil, macAddress: String? = nil, serialNumber: String? = nil,
            ipAddress: String? = nil, subnetMask: String? = nil, gateway: String? = nil, systemName: String? = nil
        ) {
            self.version = version
            self.productNumber = productNumber
            self.productName = productName
            self.dateCode = dateCode
            self.firmware = firmware
            self.company = company
            self.macAddress = macAddress
            self.serialNumber = serialNumber
            self.ipAddress = ipAddress
            self.subnetMask = subnetMask
            self.gateway = gateway
            self.systemName = systemName
        }

        /// `true`, wenn der Produktname einen externen ZebraNet-Druckserver bezeichnet (dann sagt er
        /// nichts über das Druckermodell).
        public var isExternalPrintServer: Bool {
            productName?.lowercased().contains("zebranet") ?? false
        }

        /// Modellhinweis für `ModelCatalog.match(productName:)` (`nil` bei externen Druckservern).
        public var modelHint: String? {
            isExternalPrintServer ? nil : productName
        }

        /// Kurzer Modellname: „ZTC ZD500R-300dpi ZP“ (auf 20 Zeichen gekürzt) → „ZD500R“.
        public var shortModelName: String? {
            guard let hint = modelHint else { return nil }
            let withoutResolution = hint.replacingOccurrences(of: #"-\d{3}dpi.*$"#, with: "",
                                                              options: [.regularExpression, .caseInsensitive])
            return ZebraIdentifiers.shortModelName(from: withoutResolution)
        }
    }

    // MARK: Auswerten

    /// Wertet eine Antwort aus; `nil`, wenn die Kennung „:,.“ fehlt. Kürzere Pakete (ältere
    /// Druckserver) liefern nur die enthaltenen Felder.
    public static func parse(_ data: Data) -> Reply? {
        parse([UInt8](data))
    }

    public static func parse(_ bytes: [UInt8]) -> Reply? {
        guard bytes.count > Field.version, Array(bytes[0..<replyMagic.count]) == replyMagic else { return nil }
        return Reply(
            version: bytes[Field.version],
            productNumber: text(bytes, Field.productNumber),
            productName: text(bytes, Field.productName),
            dateCode: text(bytes, Field.dateCode),
            firmware: text(bytes, Field.firmware),
            company: text(bytes, Field.company),
            macAddress: mac(bytes, Field.macAddress),
            serialNumber: text(bytes, Field.serialNumber),
            ipAddress: ipv4(bytes, Field.ipAddress, allowZero: false),
            subnetMask: ipv4(bytes, Field.subnetMask, allowZero: false),
            gateway: ipv4(bytes, Field.gateway, allowZero: false),
            systemName: text(bytes, Field.systemName)
        )
    }

    /// Textfeld bis zum ersten NUL; nur druckbares ASCII (sonst `nil`, z. B. bei abweichendem Aufbau).
    static func text(_ bytes: [UInt8], _ field: (offset: Int, length: Int)) -> String? {
        guard field.offset < bytes.count else { return nil }
        let end = min(field.offset + field.length, bytes.count)
        let slice = bytes[field.offset..<end].prefix { $0 != 0 }
        guard !slice.isEmpty, slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let value = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func mac(_ bytes: [UInt8], _ field: (offset: Int, length: Int)) -> String? {
        guard field.offset + field.length <= bytes.count else { return nil }
        let raw = bytes[field.offset..<(field.offset + field.length)]
        guard raw.contains(where: { $0 != 0 }), raw.contains(where: { $0 != 0xFF }) else { return nil }
        return raw.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func ipv4(_ bytes: [UInt8], _ field: (offset: Int, length: Int), allowZero: Bool) -> String? {
        guard field.offset + field.length <= bytes.count else { return nil }
        let raw = Array(bytes[field.offset..<(field.offset + field.length)])
        if !allowZero && raw.allSatisfy({ $0 == 0 }) { return nil }
        return raw.map(String.init).joined(separator: ".")
    }

    // MARK: Erzeugen (Testdaten, virtuelle Drucker)

    /// Baut eine Antwort im Format der Druckserver (376 Byte). Für Tests und Simulatoren.
    public static func encode(_ reply: Reply, length: Int = replyLength) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: max(length, Field.systemName.offset + Field.systemName.length))
        bytes.replaceSubrange(0..<replyMagic.count, with: replyMagic)
        bytes[Field.version] = reply.version
        func put(_ text: String?, _ field: (offset: Int, length: Int)) {
            guard let text else { return }
            let data = Array(text.utf8.prefix(field.length))
            bytes.replaceSubrange(field.offset..<(field.offset + data.count), with: data)
        }
        func putIPv4(_ text: String?, _ field: (offset: Int, length: Int)) {
            guard let text, let value = SubnetScanner.parseIPv4(text) else { return }
            for index in 0..<4 { bytes[field.offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * index)) }
        }
        put(reply.productNumber, Field.productNumber)
        put(reply.productName, Field.productName)
        put(reply.dateCode, Field.dateCode)
        put(reply.firmware, Field.firmware)
        put(reply.company, Field.company)
        if let mac = reply.macAddress {
            let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
            if parts.count == Field.macAddress.length {
                bytes.replaceSubrange(Field.macAddress.offset..<(Field.macAddress.offset + parts.count), with: parts)
            }
        }
        put(reply.serialNumber, Field.serialNumber)
        // „Netzwerkprotokoll aktiv“ wie in allen bekannten Mitschnitten.
        bytes[70] = 0x01
        putIPv4(reply.ipAddress, Field.ipAddress)
        putIPv4(reply.subnetMask, Field.subnetMask)
        putIPv4(reply.gateway, Field.gateway)
        put(reply.systemName, Field.systemName)
        return Array(bytes.prefix(max(length, Field.version + 1)))
    }

    // MARK: Gefundener Drucker

    /// Gefundener Drucker aus einer Antwort. `host` ist die Absenderadresse des Pakets (die
    /// tatsächlich erreichbare Adresse – hinter NAT oder VPN kann die im Paket genannte abweichen).
    public static func makeDiscoveredPrinter(_ reply: Reply, host: String, port: Int = ZebraIdentifiers.rawPort) -> DiscoveredPrinter {
        var details: [String: String] = ["host": host, "port": String(port), "identifiedBy": "zebra"]
        if let value = reply.systemName { details["name"] = value }
        if let value = reply.productName {
            details[reply.isExternalPrintServer ? "printServer" : "productName"] = value
        }
        if let value = reply.productNumber { details["productNumber"] = value }
        if let value = reply.firmware { details["firmware"] = value }
        // Seriennummer des Druckservers – nicht unbedingt die des Druckers, daher ein eigener Schlüssel
        // (eine per SNMP/`~HI` gelesene Drucker-Seriennummer unter „serialNumber“ bleibt erhalten).
        if let value = reply.serialNumber { details["printServerSerial"] = value }
        if let value = reply.macAddress { details["macAddress"] = value }
        if let value = reply.subnetMask { details["subnetMask"] = value }
        if let value = reply.gateway { details["gateway"] = value }
        if let reported = reply.ipAddress, reported != host { details["reportedAddress"] = reported }
        let name = reply.systemName ?? reply.shortModelName.map { "Zebra \($0)" } ?? "Zebra \(host)"
        return DiscoveredPrinter(
            name: name,
            modelHint: reply.modelHint,
            descriptor: .tcp(host: host, port: port),
            source: .zebra,
            details: details
        )
    }
}

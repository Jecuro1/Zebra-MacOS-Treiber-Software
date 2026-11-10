import Foundation
import LabelWerkCore

/// SGD-Variablen des virtuellen Druckers mit Typ, Wertebereich, Zugriff und Prüfung.
///
/// Werte und Bereiche entsprechen einem Link-OS-Desktopdrucker (ZD421) und werden aus dem
/// gewählten Katalogmodell abgeleitet (Druckbreite, Geschwindigkeit, Druckverfahren,
/// Druckmodi, Sprachen, Akku, Display).
struct VirtualSGDStore: Sendable {

    /// Datentyp einer Variablen (bestimmt Prüfung und `allconfig`-Angaben).
    enum Kind: Sendable, Hashable {
        /// Zeichenkette mit Höchstlänge.
        case string(maxLength: Int)
        /// Ganzzahl im Bereich.
        case integer(ClosedRange<Int>)
        /// Dezimalzahl im Bereich, gespeichert mit einer Nachkommastelle.
        case decimal(ClosedRange<Double>)
        /// Auswahl aus festen Werten.
        case choice([String])
        /// IPv4-Adresse.
        case ipv4

        var typeName: String {
            switch self {
            case .string: return "string"
            case .integer: return "integer"
            case .decimal: return "double"
            case .choice: return "enum"
            case .ipv4: return "ipv4-address"
            }
        }

        var rangeText: String {
            switch self {
            case .string(let maxLength): return "0-\(maxLength)"
            case .integer(let range): return "\(range.lowerBound)-\(range.upperBound)"
            case .decimal(let range): return "\(Self.format(range.lowerBound))-\(Self.format(range.upperBound))"
            case .choice(let values): return values.joined(separator: ",")
            case .ipv4: return ""
            }
        }

        /// Text der `allcv`-Ausgabe hinter „Choices:“.
        var choicesText: String {
            switch self {
            case .string(let maxLength): return "A string of 0 - \(maxLength) characters"
            case .integer(let range): return "\(range.lowerBound)-\(range.upperBound)"
            case .decimal(let range): return "\(Self.format(range.lowerBound))-\(Self.format(range.upperBound))"
            case .choice(let values): return values.joined(separator: ",")
            case .ipv4: return "A valid IP address"
            }
        }

        static func format(_ value: Double) -> String { String(format: "%.1f", value) }

        /// Prüft und normalisiert einen Wert; `nil` = ungültig.
        func normalize(_ raw: String) -> String? {
            let text = raw.trimmingCharacters(in: .whitespaces)
            switch self {
            case .string(let maxLength):
                return raw.count <= maxLength ? raw : nil
            case .integer(let range):
                guard let value = Double(text), value.isFinite else { return nil }
                let rounded = Int(value.rounded())
                return range.contains(rounded) ? String(rounded) : nil
            case .decimal(let range):
                guard let value = Double(text), value.isFinite, range.contains(value) else { return nil }
                return Self.format(value)
            case .choice(let values):
                let lower = text.lowercased()
                if let match = values.first(where: { $0.lowercased() == lower }) { return match }
                // Gängige Synonyme für Schalter.
                if values.contains("on"), ["yes", "true", "1", "enabled"].contains(lower) { return "on" }
                if values.contains("off"), ["no", "false", "0", "disabled"].contains(lower) { return "off" }
                return nil
            case .ipv4:
                return NetworkSettings.isValidIPv4(text) ? text : nil
            }
        }
    }

    /// Zugriffsrechte.
    enum Access: String, Sendable {
        case readOnly = "R"
        case readWrite = "RW"
        case writeOnly = "W"
    }

    /// Bereich für `device.restore_defaults`, `^JUF` (`general`) und `^JUN` (`ip`, `wlan`).
    enum Scope: String, Sendable, CaseIterable {
        /// Allgemeine Druckereinstellungen (Medien, Druck, Gerät).
        case general
        case ip, wlan, bluetooth, display, power
        /// Alle Bereiche.
        case all
    }

    struct Definition: Sendable {
        var name: String
        var defaultValue: String
        var kind: Kind
        var access: Access
        var archive: Bool
        var clone: Bool
        /// Bereich für `device.restore_defaults` bzw. `^JUN`/`^JUF`.
        var scope: Scope
    }

    /// Variablen in Ausgabereihenfolge.
    let definitions: [Definition]
    private let index: [String: Int]
    private(set) var values: [String: String]

    init(model: PrinterModel, resolution: Resolution, identity: VirtualDeviceIdentity) {
        let definitions = Self.makeDefinitions(model: model, resolution: resolution, identity: identity)
        self.definitions = definitions
        var index: [String: Int] = [:]
        var values: [String: String] = [:]
        for (position, definition) in definitions.enumerated() {
            index[definition.name] = position
            values[definition.name] = definition.defaultValue
        }
        self.index = index
        self.values = values
    }

    // MARK: Zugriff

    func definition(_ name: String) -> Definition? {
        index[name.lowercased()].map { definitions[$0] }
    }

    /// Lesbarer Wert (`nil` für unbekannte und Nur-Schreib-Variablen).
    func readableValue(_ name: String) -> String? {
        guard let definition = definition(name), definition.access != .writeOnly else { return nil }
        return values[definition.name]
    }

    /// Interner Wert unabhängig vom Zugriffsrecht.
    func rawValue(_ name: String) -> String? {
        definition(name).flatMap { values[$0.name] }
    }

    /// Setzt einen Wert, wie es ein Host per `setvar` täte: nur beschreibbare Variablen, nur
    /// gültige Werte. Liefert `true` bei Erfolg.
    @discardableResult
    mutating func assign(_ name: String, _ raw: String) -> Bool {
        guard let definition = definition(name), definition.access != .readOnly,
              let value = definition.kind.normalize(raw) else { return false }
        values[definition.name] = value
        return true
    }

    /// Setzt einen Wert intern (Zustandsänderungen des Druckers), mit Prüfung, aber ohne
    /// Zugriffsbeschränkung.
    @discardableResult
    mutating func update(_ name: String, _ raw: String) -> Bool {
        guard let definition = definition(name), let value = definition.kind.normalize(raw) else { return false }
        values[definition.name] = value
        return true
    }

    /// Setzt einen Wert intern ohne Prüfung (berechnete Werte wie Odometer, Uhrzeit).
    mutating func force(_ name: String, _ value: String) {
        guard let definition = definition(name) else { return }
        values[definition.name] = value
    }

    /// Namen unterhalb eines Zweigs (`ip` → `ip.addr`, `ip.netmask` …).
    func names(inBranch branch: String) -> [String] {
        let prefix = branch.lowercased() + "."
        return definitions.map(\.name).filter { $0.hasPrefix(prefix) }
    }

    /// Setzt alle beschreibbaren Variablen eines Bereichs auf Werkseinstellung zurück
    /// (`all` = alle Bereiche).
    mutating func restoreDefaults(_ scope: Scope) {
        for definition in definitions where definition.access != .readOnly {
            if scope == .all || definition.scope == scope {
                values[definition.name] = definition.defaultValue
            }
        }
    }

    /// `true`, wenn EPL-Zeilen ausgewertet werden (`device.languages` enthält „epl“).
    var acceptsEPL: Bool {
        (values["device.languages"] ?? "").contains("epl")
    }

    // MARK: Definitionen

    // swiftlint:disable:next function_body_length
    static func makeDefinitions(model: PrinterModel, resolution: Resolution,
                                identity: VirtualDeviceIdentity) -> [Definition] {
        var list: [Definition] = []
        func add(_ name: String, _ value: String, _ kind: Kind, _ access: Access = .readWrite,
                 archive: Bool = true, clone: Bool = true, scope: Scope = .general) {
            list.append(Definition(name: name, defaultValue: value, kind: kind, access: access,
                                   archive: archive, clone: clone, scope: scope))
        }
        let linkOS = model.supports(.linkOS)
        let maxSpeed = Double(model.maxSpeed(resolution))
        let printWidth = model.printWidthDots(resolution)
        let defaultStock = ModelCatalog.shared.stock(id: model.defaultStock)
        let labelLength = min(model.maxLabelLengthDots(resolution), defaultStock?.heightDots(resolution) ?? resolution.dots(fromInches: 6))
        let transfer = model.supportsThermalTransfer
        var printModes = model.printModes.map(SGDValueMapping.printMode)
        if model.supports(.linerless) {
            // Linerless-Modelle kennen zusätzlich die Linerless-Modi (nur per SGD einstellbar).
            printModes += PrintMode.allCases.filter { $0.isLinerless && !model.printModes.contains($0) }
                .map(SGDValueMapping.printMode)
        }

        // Gerät
        add("device.friendly_name", identity.serialNumber, .string(maxLength: 17))
        add("device.product_name", model.name, .string(maxLength: 20), .readOnly, archive: false, clone: false)
        add("device.unique_id", identity.serialNumber, .string(maxLength: 20), .readOnly, archive: false, clone: false)
        add("device.location", "", .string(maxLength: 64))
        add("device.company_contact", "", .string(maxLength: 64))
        var languageChoices = ["zpl", "hybrid_xml_zpl"]
        if model.supports(.epl) { languageChoices += ["epl", "epl_zpl"] }
        if model.supports(.cpcl) { languageChoices += ["line_print"] }
        let defaultLanguages: String
        switch model.defaultLanguage {
        case .cpcl: defaultLanguages = "line_print"
        case .epl: defaultLanguages = "epl_zpl"
        case .zpl: defaultLanguages = model.supports(.epl) ? "epl_zpl" : "hybrid_xml_zpl"
        }
        add("device.languages", defaultLanguages, .choice(languageChoices))
        add("device.uptime", "0 days 00:00:00", .string(maxLength: 32), .readOnly, archive: false, clone: false)
        add("device.pnp_option", "zpl", .choice(["zpl", "epl"]))
        add("appl.name", identity.firmware, .string(maxLength: 20), .readOnly, archive: false, clone: false)
        add("appl.date", "07/20/23", .string(maxLength: 10), .readOnly, archive: false, clone: false)
        if linkOS {
            add("appl.link_os_version", "6.6", .string(maxLength: 8), .readOnly, archive: false, clone: false)
        }
        add("rtc.date", "01-01-2026", .string(maxLength: 10), archive: false, clone: false)
        add("rtc.time", "00:00:00", .string(maxLength: 8), archive: false, clone: false)
        if model.supports(.display) {
            add("display.language", "english", .choice(["english", "german", "french", "spanish", "italian", "dutch"]),
                scope: .display)
        }

        // Druckkopf & Medien
        add("head.resolution.in_dpi", String(resolution.dpi), .integer(150...600), .readOnly, archive: false, clone: false)
        add("head.latch", "ok", .choice(["ok", "open"]), .readOnly, archive: false, clone: false)
        add("head.temperature", "27", .integer(-40...150), .readOnly, archive: false, clone: false)
        add("print.tone", "15.0", .decimal(0...30))
        add("media.speed", Kind.format(min(4, maxSpeed)), .decimal(2...max(2, maxSpeed)))
        add("media.printmode", SGDValueMapping.printMode(model.printModes.first ?? .tearOff), .choice(printModes))
        add("media.status", "ok", .choice(["ok", "out"]), .readOnly, archive: false, clone: false)
        add("media.sense_mode", "gap", .choice(["gap", "bar"]))
        add("media.type", "label", .choice(["label", "journal"]))
        add("ezpl.print_method", transfer ? "thermal trans" : "direct thermal",
            .choice(transfer ? ["direct thermal", "thermal trans"] : ["direct thermal"]))
        add("ezpl.media_type", "gap/notch", .choice(["continuous", "gap/notch", "mark", "continuous variable"]))
        add("ezpl.print_width", String(printWidth), .integer(2...printWidth))
        add("ezpl.label_length_max", Kind.format(model.maxLabelLengthMM / 25.4), .decimal(1...Double(Int(model.maxLabelLengthMM / 25.4) + 1)))
        add("ezpl.tear_off", "0", .integer(-120...120))
        add("ezpl.power_up_action", "feed", .choice(["feed", "calibrate", "length", "no motion", "short cal"]))
        add("ezpl.head_close_action", "feed", .choice(["feed", "calibrate", "length", "no motion", "short cal"]))
        add("zpl.zpl_mode", "zpl II", .choice(["zpl", "zpl II"]))
        add("zpl.left_position", "0", .integer(-9999...9999))
        add("zpl.label_top", "0", .integer(-120...120))
        add("zpl.label_length", String(labelLength), .integer(1...model.maxLabelLengthDots(resolution)))
        add("zpl.caret", "^", .string(maxLength: 1))
        add("zpl.control_character", "~", .string(maxLength: 1))
        add("zpl.delimiter", ",", .string(maxLength: 1))

        // Zähler
        add("odometer.total_print_length", identity.odometerText(mm: identity.initialPrintLengthMM),
            .string(maxLength: 48), .readOnly, archive: false, clone: false)
        add("odometer.total_label_count", String(identity.initialLabelCount), .string(maxLength: 16), .readOnly,
            archive: false, clone: false)
        add("odometer.headclean", identity.odometerText(mm: identity.initialHeadCleanMM), .string(maxLength: 48),
            .readOnly, archive: false, clone: false)
        add("odometer.headnew", identity.odometerText(mm: identity.initialPrintLengthMM), .string(maxLength: 48),
            .readOnly, archive: false, clone: false)

        // Netzwerk (kabelgebunden / aktiv)
        add("ip.ip_protocol", "dhcp", .choice(["all", "bootp", "dhcp", "dhcp and bootp", "gleaning only", "rarp", "permanent"]),
            scope: .ip)
        add("ip.addr", identity.ipAddress, .ipv4, scope: .ip)
        add("ip.netmask", "255.255.255.0", .ipv4, scope: .ip)
        add("ip.gateway", identity.gateway, .ipv4, scope: .ip)
        add("ip.dns.servers", identity.gateway, .string(maxLength: 64), scope: .ip)
        add("ip.port", "9100", .integer(1...65535), scope: .ip)
        add("ip.dhcp.option12", "on", .choice(["on", "off"]), scope: .ip)
        add("ip.dhcp.option12_value", "", .string(maxLength: 63), scope: .ip)
        add("interface.network.active.ip_addr", identity.ipAddress, .ipv4, .readOnly, archive: false, clone: false)
        add("interface.network.active.netmask", "255.255.255.0", .ipv4, .readOnly, archive: false, clone: false)
        add("interface.network.active.gateway", identity.gateway, .ipv4, .readOnly, archive: false, clone: false)
        add("interface.network.active.protocol", "dhcp", .string(maxLength: 16), .readOnly, archive: false, clone: false)
        add("interface.network.active.mac_addr", identity.wiredMAC, .string(maxLength: 17), .readOnly, archive: false,
            clone: false)
        add("internal_wired.ip.addr", identity.ipAddress, .ipv4, .readOnly, archive: false, clone: false)
        add("internal_wired.mac_addr", identity.wiredMAC, .string(maxLength: 17), .readOnly, archive: false, clone: false)

        // WLAN
        if model.connectivity.contains(.wifi) {
            add("wlan.enable", "off", .choice(["on", "off"]), scope: .wlan)
            add("wlan.essid", "125", .string(maxLength: 32), scope: .wlan)
            add("wlan.security", "none", .choice(["none", "wep 40-bit", "wep 128-bit", "wpa psk", "wpa2 psk",
                                                  "wpa3 psk", "wpa eap-tls", "wpa eap-peap"]), scope: .wlan)
            add("wlan.wpa.psk", "", .string(maxLength: 64), .writeOnly, clone: false, scope: .wlan)
            add("wlan.ip.addr", "0.0.0.0", .ipv4, scope: .wlan)
            add("wlan.ip.protocol", "all", .choice(["all", "bootp", "dhcp", "dhcp and bootp", "gleaning only", "rarp",
                                                   "permanent"]), scope: .wlan)
            add("wlan.mac_addr", identity.wirelessMAC, .string(maxLength: 17), .readOnly, archive: false, clone: false)
            add("wlan.signal_strength", "0", .integer(0...100), .readOnly, archive: false, clone: false)
            add("wlan.signal_quality", "0", .integer(0...100), .readOnly, archive: false, clone: false)
        }

        // Bluetooth
        if model.connectivity.contains(.bluetooth) || model.connectivity.contains(.ble) {
            add("bluetooth.enable", "on", .choice(["on", "off"]), scope: .bluetooth)
            add("bluetooth.friendly_name", identity.serialNumber, .string(maxLength: 17), scope: .bluetooth)
            add("bluetooth.address", identity.bluetoothAddress, .string(maxLength: 17), .readOnly, archive: false,
                clone: false)
            add("bluetooth.discoverable", "on", .choice(["on", "off"]), scope: .bluetooth)
            add("bluetooth.le.controller_mode", "both", .choice(["both", "classic", "le"]), scope: .bluetooth)
        }

        // Energie
        if model.supports(.battery) {
            add("power.percent_full", "87", .integer(0...100), .readOnly, archive: false, clone: false)
            add("power.health", "good", .choice(["good", "fair", "poor", "replace"]), .readOnly, archive: false, clone: false)
            add("power.sleep.enable", "on", .choice(["on", "off"]), scope: .power)
            add("power.sleep.timeout", "1800", .integer(0...86400), scope: .power)
        }
        return list
    }
}

/// Feste, aus der Kennung des virtuellen Druckers abgeleitete Gerätedaten (Seriennummer,
/// MAC-Adressen, Startwerte der Zähler) – stabil, damit derselbe Demo-Drucker immer gleich
/// aussieht.
struct VirtualDeviceIdentity: Sendable {
    let serialNumber: String
    let wiredMAC: String
    let wirelessMAC: String
    let bluetoothAddress: String
    let ipAddress: String
    let gateway: String
    let firmware: String
    let initialPrintLengthMM: Double
    let initialHeadCleanMM: Double
    let initialLabelCount: Int

    init(id: String, model: PrinterModel) {
        // FNV-1a (64 Bit) – plattformunabhängig und stabil (anders als `Hasher`).
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (id + "|" + model.id).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        func byte(_ shift: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: hash >> shift) }
        let digits = String(format: "%09llu", hash % 1_000_000_000)
        serialNumber = "D4J" + digits
        wiredMAC = String(format: "00:07:4d:%02x:%02x:%02x", byte(8), byte(16), byte(24))
        wirelessMAC = String(format: "00:07:4d:%02x:%02x:%02x", byte(8), byte(16), byte(24) &+ 1)
        bluetoothAddress = String(format: "AC:3F:A4:%02X:%02X:%02X", byte(32), byte(40), byte(48))
        ipAddress = "192.168.1.\(100 + Int(byte(56)) % 100)"
        gateway = "192.168.1.1"
        firmware = Self.firmware(for: model)
        initialPrintLengthMM = Double(150_000 + Int(hash % 50_000) * 10)
        initialHeadCleanMM = Double(5_000 + Int((hash >> 20) % 20_000))
        initialLabelCount = 1_200 + Int((hash >> 12) % 9_000)
    }

    /// Typische Firmware-Stände je Baureihe.
    static func firmware(for model: PrinterModel) -> String {
        let name = model.name.uppercased()
        if name.hasPrefix("ZD4") || name.hasPrefix("ZD6") { return "V84.20.21Z" }
        if name.hasPrefix("ZD2") { return "V84.20.17Z" }
        if name.hasPrefix("ZT6") { return "V75.20.32Z" }
        if name.hasPrefix("ZT") { return "V92.21.26Z" }
        if name.hasPrefix("ZQ") || name.hasPrefix("ZR") { return "V85.20.19Z" }
        if name.hasPrefix("ZE") { return "V75.20.11Z" }
        return model.supports(.linkOS) ? "V83.20.17Z" : "V61.17.17Z"
    }

    /// Odometer im Link-OS-Format: „8560 INCHES, 21744 CENTIMETERS“.
    func odometerText(mm: Double) -> String {
        "\(Int(mm / 25.4)) INCHES, \(Int(mm / 10)) CENTIMETERS"
    }
}

import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - IPv4

enum NetConfigIPv4 {
    /// Liest eine IPv4-Adresse in Punktschreibweise (führende Nullen erlaubt).
    static func parse(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
                  let octet = UInt32(part), octet <= 255
            else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func format(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// Zusammenhängende Einsen, weder /0 noch /32.
    static func isValidMask(_ mask: UInt32) -> Bool {
        guard mask != 0, mask != 0xFFFF_FFFF else { return false }
        let inverted = ~mask
        return inverted & (inverted &+ 1) == 0
    }

    static func prefixLength(_ mask: UInt32) -> Int { mask.nonzeroBitCount }

    static func sameSubnet(_ a: UInt32, _ b: UInt32, mask: UInt32) -> Bool {
        (a & mask) == (b & mask)
    }

    /// Normalisiert „192.168.001.020“ zu „192.168.1.20“ (ungültige Eingaben bleiben unverändert).
    static func normalized(_ text: String) -> String {
        guard let value = parse(text) else { return text.trimmingCharacters(in: .whitespaces) }
        return format(value)
    }

    static let commonMasks: [(prefix: Int, mask: String)] = [
        (24, "255.255.255.0"), (23, "255.255.254.0"), (22, "255.255.252.0"),
        (16, "255.255.0.0"), (8, "255.0.0.0"), (25, "255.255.255.128"), (28, "255.255.255.240"),
    ]
}

// MARK: - Prüfergebnis

enum NetConfigIssue: Equatable {
    /// Leer bzw. ohne Bewertung.
    case none
    case valid
    case warning(String)
    case error(String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .warning(let text), .error(let text): return text
        case .none, .valid: return nil
        }
    }

    var tint: Color {
        switch self {
        case .none: return Theme.cardStroke
        case .valid: return Theme.ready
        case .warning: return Theme.warning
        case .error: return Theme.error
        }
    }
}

enum NetConfigField: String, CaseIterable, Hashable {
    case ipAddress, subnetMask, gateway, dnsServer, hostname, ssid, passphrase, bluetoothName
}

// MARK: - WLAN-Sicherheit

enum NetConfigSecurity: Hashable {
    case open
    case wpaPSK
    case wpa2PSK
    case wpa3
    /// Vom Drucker gemeldeter, hier nicht bearbeitbarer Modus (z. B. „eap-tls“) – bleibt unverändert.
    case other(String)

    static let selectable: [NetConfigSecurity] = [.open, .wpaPSK, .wpa2PSK, .wpa3]

    init(raw: String?) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty || value == "none" || value == "off" || value == "open" || value == "1" {
            self = .open
        } else if value.contains("wpa3") || value.contains("sae") {
            self = .wpa3
        } else if value.contains("wpa2") {
            self = .wpa2PSK
        } else if value.contains("psk") || value == "wpa" {
            self = .wpaPSK
        } else {
            self = .other(raw ?? value)
        }
    }

    /// Wert für `NetworkSettings.wlanSecurity` (SGD `wlan.security`).
    var rawValue: String {
        switch self {
        case .open: return "none"
        case .wpaPSK: return "wpa psk"
        case .wpa2PSK: return "wpa2 psk"
        case .wpa3: return "wpa3 psk"
        case .other(let raw): return raw
        }
    }

    var title: String {
        switch self {
        case .open: return tr("Keine (offen)")
        case .wpaPSK: return tr("WPA-PSK")
        case .wpa2PSK: return tr("WPA2-PSK")
        case .wpa3: return tr("WPA3-Personal")
        case .other(let raw): return tr("Andere: %@", raw)
        }
    }

    var systemImage: String {
        switch self {
        case .open: return "lock.open"
        case .wpaPSK, .wpa2PSK, .wpa3: return "lock.fill"
        case .other: return "lock.shield"
        }
    }

    var needsPassphrase: Bool {
        switch self {
        case .wpaPSK, .wpa2PSK, .wpa3: return true
        case .open, .other: return false
        }
    }
}

// MARK: - Bluetooth

struct NetConfigBluetooth: Equatable {
    var friendlyName: String
    var discoverable: Bool

    static let variables = ["bluetooth.friendly_name", "bluetooth.discoverable"]

    init(friendlyName: String, discoverable: Bool) {
        self.friendlyName = friendlyName
        self.discoverable = discoverable
    }

    init?(values: [String: String]) {
        guard values["bluetooth.friendly_name"] != nil || values["bluetooth.discoverable"] != nil else { return nil }
        friendlyName = values["bluetooth.friendly_name"] ?? ""
        let flag = (values["bluetooth.discoverable"] ?? "").lowercased()
        discoverable = ["on", "yes", "true", "1", "enabled"].contains(flag)
    }
}

// MARK: - Entwurf

/// Bearbeitbare Kopie der Netzwerkeinstellungen (alle Felder als Text für die Eingabe).
struct NetConfigDraft: Equatable {
    var useDHCP = true
    var ipAddress = ""
    var subnetMask = ""
    var gateway = ""
    var dnsServer = ""
    var hostname = ""
    var wlanEnabled = false
    var wlanSSID = ""
    var wlanSecurity: NetConfigSecurity = .open
    /// Nur schreiben: leer = unverändert.
    var wlanPassphrase = ""
    var bluetoothName = ""
    var bluetoothDiscoverable = false

    init() {}

    init(settings: NetworkSettings, bluetooth: NetConfigBluetooth?) {
        useDHCP = settings.useDHCP
        ipAddress = NetConfigIPv4.normalized(settings.ipAddress)
        subnetMask = NetConfigIPv4.normalized(settings.subnetMask)
        gateway = NetConfigIPv4.normalized(settings.gateway)
        dnsServer = settings.dnsServer.map(NetConfigIPv4.normalized) ?? ""
        hostname = settings.hostname ?? ""
        wlanEnabled = settings.wlanEnabled ?? false
        wlanSSID = settings.wlanSSID ?? ""
        wlanSecurity = NetConfigSecurity(raw: settings.wlanSecurity)
        bluetoothName = bluetooth?.friendlyName ?? ""
        bluetoothDiscoverable = bluetooth?.discoverable ?? false
    }

    private static func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Überträgt nur die gegenüber `initial` geänderten Felder auf `base` (unberührte Werte bleiben exakt erhalten).
    func applying(to base: NetworkSettings, initial: NetConfigDraft) -> NetworkSettings {
        var settings = base
        if useDHCP != initial.useDHCP { settings.useDHCP = useDHCP }
        if !useDHCP {
            if ipAddress != initial.ipAddress { settings.ipAddress = NetConfigIPv4.normalized(ipAddress) }
            if subnetMask != initial.subnetMask { settings.subnetMask = NetConfigIPv4.normalized(subnetMask) }
            if gateway != initial.gateway {
                let value = Self.clean(gateway)
                settings.gateway = value.isEmpty ? "0.0.0.0" : NetConfigIPv4.normalized(value)
            }
        }
        if dnsServer != initial.dnsServer {
            let value = Self.clean(dnsServer)
            settings.dnsServer = value.isEmpty ? nil : NetConfigIPv4.normalized(value)
        }
        if hostname != initial.hostname {
            let value = Self.clean(hostname)
            settings.hostname = value.isEmpty ? nil : value
        }
        if wlanEnabled != initial.wlanEnabled { settings.wlanEnabled = wlanEnabled }
        if wlanSSID != initial.wlanSSID { settings.wlanSSID = wlanSSID }
        if wlanSecurity != initial.wlanSecurity { settings.wlanSecurity = wlanSecurity.rawValue }
        settings.wlanPassphrase = wlanPassphrase.isEmpty ? nil : wlanPassphrase
        return settings
    }

    /// Ändert sich etwas, das per `applyNetworkSettings` übertragen werden muss?
    func networkDiffers(from initial: NetConfigDraft) -> Bool {
        var a = self, b = initial
        a.bluetoothName = ""; a.bluetoothDiscoverable = false
        b.bluetoothName = ""; b.bluetoothDiscoverable = false
        if a.useDHCP && b.useDHCP {
            a.ipAddress = b.ipAddress; a.subnetMask = b.subnetMask; a.gateway = b.gateway
        }
        return a != b
    }

    func bluetoothDiffers(from initial: NetConfigDraft) -> Bool {
        bluetoothName != initial.bluetoothName || bluetoothDiscoverable != initial.bluetoothDiscoverable
    }
}

// MARK: - Änderungsliste

struct NetConfigChange: Identifiable, Equatable {
    let id: String
    let title: String
    let oldValue: String
    let newValue: String
    let systemImage: String
    let requiresRestart: Bool
}

extension NetConfigDraft {
    func changes(from initial: NetConfigDraft) -> [NetConfigChange] {
        var list: [NetConfigChange] = []
        func onOff(_ value: Bool) -> String { value ? tr("Ein") : tr("Aus") }
        func shown(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces).isEmpty ? "–" : value }
        func add(_ id: String, _ title: String, _ old: String, _ new: String, _ symbol: String, restart: Bool = true) {
            guard old != new else { return }
            list.append(NetConfigChange(id: id, title: title, oldValue: old, newValue: new, systemImage: symbol, requiresRestart: restart))
        }
        add("dhcp", tr("Adressvergabe"), initial.useDHCP ? tr("DHCP") : tr("Statisch"),
            useDHCP ? tr("DHCP") : tr("Statisch"), "arrow.triangle.branch")
        if !useDHCP {
            add("ip", tr("IP-Adresse"), shown(initial.ipAddress), shown(ipAddress), "number")
            add("mask", tr("Subnetzmaske"), shown(initial.subnetMask), shown(subnetMask), "square.grid.3x3.square")
            add("gateway", tr("Gateway"), shown(initial.gateway), shown(gateway), "arrow.triangle.turn.up.right.diamond")
        }
        add("dns", tr("DNS-Server"), shown(initial.dnsServer), shown(dnsServer), "server.rack")
        add("hostname", tr("Hostname"), shown(initial.hostname), shown(hostname), "character.cursor.ibeam")
        add("wlan", tr("WLAN"), onOff(initial.wlanEnabled), onOff(wlanEnabled), "wifi")
        add("ssid", tr("WLAN-Name (SSID)"), shown(initial.wlanSSID), shown(wlanSSID), "wifi.router")
        add("security", tr("WLAN-Sicherheit"), initial.wlanSecurity.title, wlanSecurity.title, "lock.shield")
        if !wlanPassphrase.isEmpty {
            list.append(NetConfigChange(id: "passphrase", title: tr("WLAN-Passwort"), oldValue: "••••••",
                                        newValue: tr("neu gesetzt"), systemImage: "key.fill", requiresRestart: true))
        }
        add("btname", tr("Bluetooth-Name"), shown(initial.bluetoothName), shown(bluetoothName), "dot.radiowaves.left.and.right", restart: false)
        add("btdisc", tr("Bluetooth sichtbar"), onOff(initial.bluetoothDiscoverable), onOff(bluetoothDiscoverable), "eye", restart: false)
        return list
    }
}

// MARK: - Prüfung

enum NetConfigValidator {
    static func ipAddress(_ text: String, mask: String, localInterfaces: [NetworkInterfaceInfo]) -> NetConfigIssue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .error(tr("Pflichtfeld – z. B. 192.168.1.50")) }
        guard let ip = NetConfigIPv4.parse(trimmed) else { return .error(tr("Keine gültige IPv4-Adresse (z. B. 192.168.1.50).")) }
        let first = ip >> 24
        if ip == 0 || ip == 0xFFFF_FFFF { return .error(tr("Diese Adresse ist nicht zulässig.")) }
        if first == 127 { return .error(tr("Loopback-Adressen (127.x.x.x) sind nicht zulässig.")) }
        if first >= 224 { return .error(tr("Multicast- und reservierte Adressen sind nicht zulässig.")) }
        if let maskValue = NetConfigIPv4.parse(mask), NetConfigIPv4.isValidMask(maskValue) {
            let host = ip & ~maskValue
            if host == 0 { return .error(tr("Das ist die Netzadresse des Subnetzes.")) }
            if host == ~maskValue { return .error(tr("Das ist die Broadcast-Adresse des Subnetzes.")) }
        }
        if first == 169 && (ip >> 16 & 0xFF) == 254 {
            return .warning(tr("Link-Local-Adresse (169.254.x.x) – nur ohne Router sinnvoll."))
        }
        let reachable = localInterfaces.contains { iface in
            guard let address = NetConfigIPv4.parse(iface.address), let ifaceMask = NetConfigIPv4.parse(iface.netmask) else { return false }
            return NetConfigIPv4.sameSubnet(address, ip, mask: ifaceMask)
        }
        if !localInterfaces.isEmpty && !reachable {
            let mine = localInterfaces.first.map(\.address) ?? ""
            return .warning(tr("Liegt nicht im Netz dieses Macs (%@) – der Drucker ist danach evtl. nur über einen Router erreichbar.", mine))
        }
        if localInterfaces.contains(where: { NetConfigIPv4.parse($0.address) == ip }) {
            return .error(tr("Diese Adresse verwendet bereits dieser Mac."))
        }
        return .valid
    }

    static func subnetMask(_ text: String) -> NetConfigIssue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .error(tr("Pflichtfeld – meist 255.255.255.0")) }
        guard let mask = NetConfigIPv4.parse(trimmed) else { return .error(tr("Keine gültige Subnetzmaske.")) }
        guard NetConfigIPv4.isValidMask(mask) else {
            return .error(tr("Die Maske muss aus zusammenhängenden Einsen bestehen (z. B. 255.255.255.0)."))
        }
        return .valid
    }

    static func gateway(_ text: String, ip: String, mask: String) -> NetConfigIssue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0.0.0.0" { return .none }
        guard let gateway = NetConfigIPv4.parse(trimmed) else { return .error(tr("Keine gültige IPv4-Adresse.")) }
        if let ipValue = NetConfigIPv4.parse(ip), gateway == ipValue {
            return .error(tr("Gateway und IP-Adresse dürfen nicht gleich sein."))
        }
        if let ipValue = NetConfigIPv4.parse(ip), let maskValue = NetConfigIPv4.parse(mask),
           NetConfigIPv4.isValidMask(maskValue), !NetConfigIPv4.sameSubnet(ipValue, gateway, mask: maskValue) {
            return .warning(tr("Das Gateway liegt außerhalb des Subnetzes der IP-Adresse."))
        }
        return .valid
    }

    static func dnsServer(_ text: String) -> NetConfigIssue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .none }
        return NetConfigIPv4.parse(trimmed) == nil ? .error(tr("Keine gültige IPv4-Adresse.")) : .valid
    }

    static func hostname(_ text: String) -> NetConfigIssue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .none }
        if trimmed.count > 63 { return .error(tr("Höchstens 63 Zeichen.")) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else {
            return .error(tr("Nur Buchstaben, Ziffern und Bindestrich (keine Umlaute, Leer- oder Sonderzeichen)."))
        }
        if trimmed.hasPrefix("-") || trimmed.hasSuffix("-") { return .error(tr("Darf nicht mit einem Bindestrich beginnen oder enden.")) }
        return .valid
    }

    static func ssid(_ text: String, enabled: Bool) -> NetConfigIssue {
        if !enabled { return .none }
        if text.isEmpty { return .error(tr("Bitte den WLAN-Namen eingeben.")) }
        if text.utf8.count > 32 { return .error(tr("Höchstens 32 Byte.")) }
        return .valid
    }

    static func passphrase(_ text: String, security: NetConfigSecurity, enabled: Bool, required: Bool) -> NetConfigIssue {
        guard enabled, security.needsPassphrase else { return .none }
        if text.isEmpty {
            return required ? .error(tr("Für diesen Sicherheitsmodus ist ein Passwort erforderlich.")) : .none
        }
        let isHexKey = text.count == 64 && text.allSatisfy(\.isHexDigit)
        if !isHexKey && (text.count < 8 || text.count > 63) {
            return .error(tr("8 bis 63 Zeichen (oder 64 Hex-Zeichen)."))
        }
        if text.unicodeScalars.contains(where: { !$0.isASCII }) {
            return .warning(tr("Sonderzeichen außerhalb von ASCII werden nicht von allen Druckern unterstützt."))
        }
        return .valid
    }

    static func bluetoothName(_ text: String) -> NetConfigIssue {
        if text.isEmpty { return .error(tr("Der Name darf nicht leer sein.")) }
        if text.count > 17 { return .error(tr("Höchstens 17 Zeichen.")) }
        return .valid
    }
}

// MARK: - Bearbeitungsmodell

enum NetConfigLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Ergebnis einer Übertragung (für die Neustart-Karte).
struct NetConfigOutcome: Equatable {
    var appliedAt: Date
    var restartExpected: Bool
    /// Neue Adresse, auf die die Verbindung umgestellt werden kann.
    var suggestedHost: String?
    var port: Int?
    /// Von statisch auf DHCP gewechselt – neue Adresse unbekannt.
    var switchedToDHCP: Bool
    var hostUpdated = false
    var reconnected = false
}

@Observable
@MainActor
final class NetConfigEditor {
    var draft = NetConfigDraft()
    private(set) var initial = NetConfigDraft()
    private(set) var original: NetworkSettings?
    private(set) var originalBluetooth: NetConfigBluetooth?
    private(set) var loadPhase: NetConfigLoadPhase = .idle
    private(set) var active: [String: String] = [:]
    private(set) var isLoadingActive = false
    private(set) var isApplying = false
    private(set) var outcome: NetConfigOutcome?
    private(set) var shakeTokens: [NetConfigField: Int] = [:]
    private(set) var localInterfaces: [NetworkInterfaceInfo] = []
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    static let activeVariables = [
        "interface.network.active.ip_addr", "interface.network.active.netmask",
        "interface.network.active.gateway", "interface.network.active.mac_addr",
        "interface.network.active.protocol", "wlan.signal_strength", "wlan.essid",
    ]

    init() {}

    var changes: [NetConfigChange] { draft.changes(from: initial) }
    var hasChanges: Bool { draft != initial || !draft.wlanPassphrase.isEmpty }
    var needsRestart: Bool { draft.networkDiffers(from: initial) || !draft.wlanPassphrase.isEmpty }

    var activeIP: String? { nonEmpty(active["interface.network.active.ip_addr"]) }
    var activeMAC: String? { nonEmpty(active["interface.network.active.mac_addr"]) }
    var activeSSID: String? { nonEmpty(active["wlan.essid"]) }
    var signalPercent: Int? {
        guard let raw = nonEmpty(active["wlan.signal_strength"]) else { return nil }
        let digits = raw.prefix { $0.isWholeNumber || $0 == "-" }
        return Int(digits).map { min(100, max(0, $0)) }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value != "0.0.0.0" else { return nil }
        return value
    }

    // MARK: Laden

    func load(session: PrinterSession, reduceMotion: Bool, wantsBluetooth: Bool) async {
        localInterfaces = SubnetScanner.localIPv4Interfaces()
        withAnimation(reduceMotion ? nil : Motion.snappy) { loadPhase = .loading }
        guard let settings = await session.networkSettings() else {
            let message = session.lastError ?? tr("Die Netzwerkeinstellungen konnten nicht gelesen werden.")
            withAnimation(reduceMotion ? nil : Motion.spring) { loadPhase = .failed(message) }
            return
        }
        var bluetooth: NetConfigBluetooth?
        if wantsBluetooth {
            let values = await session.getvars(NetConfigBluetooth.variables)
            bluetooth = NetConfigBluetooth(values: values)
        }
        let fresh = NetConfigDraft(settings: settings, bluetooth: bluetooth)
        withAnimation(reduceMotion ? nil : Motion.spring) {
            original = settings
            originalBluetooth = bluetooth
            initial = fresh
            draft = fresh
            loadPhase = .loaded
        }
        await loadActive(session: session, reduceMotion: reduceMotion)
    }

    func loadActive(session: PrinterSession, reduceMotion: Bool) async {
        guard session.supportsStatus else { return }
        withAnimation(reduceMotion ? nil : Motion.snappy) { isLoadingActive = true }
        let values = await session.getvars(Self.activeVariables)
        withAnimation(reduceMotion ? nil : Motion.spring) {
            active = values
            isLoadingActive = false
        }
    }

    func discard(reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : Motion.spring) { draft = initial }
    }

    /// Beim Wechsel auf „statisch“ leere Felder mit den aktiven Werten vorbelegen.
    func prefillStaticFieldsIfNeeded() {
        guard !draft.useDHCP else { return }
        func usable(_ text: String) -> Bool {
            let value = text.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value != "0.0.0.0"
        }
        if !usable(draft.ipAddress), let ip = active["interface.network.active.ip_addr"], usable(ip) {
            draft.ipAddress = NetConfigIPv4.normalized(ip)
        }
        if !usable(draft.subnetMask) {
            if let mask = active["interface.network.active.netmask"], usable(mask) {
                draft.subnetMask = NetConfigIPv4.normalized(mask)
            } else {
                draft.subnetMask = "255.255.255.0"
            }
        }
        if !usable(draft.gateway), let gateway = active["interface.network.active.gateway"], usable(gateway) {
            draft.gateway = NetConfigIPv4.normalized(gateway)
        }
    }

    // MARK: Prüfung

    func issue(_ field: NetConfigField, hasBluetooth: Bool, hasWLAN: Bool) -> NetConfigIssue {
        switch field {
        case .ipAddress:
            return draft.useDHCP ? .none : NetConfigValidator.ipAddress(draft.ipAddress, mask: draft.subnetMask,
                                                                        localInterfaces: localInterfaces)
        case .subnetMask:
            return draft.useDHCP ? .none : NetConfigValidator.subnetMask(draft.subnetMask)
        case .gateway:
            return draft.useDHCP ? .none : NetConfigValidator.gateway(draft.gateway, ip: draft.ipAddress, mask: draft.subnetMask)
        case .dnsServer:
            return NetConfigValidator.dnsServer(draft.dnsServer)
        case .hostname:
            return NetConfigValidator.hostname(draft.hostname)
        case .ssid:
            return hasWLAN ? NetConfigValidator.ssid(draft.wlanSSID, enabled: draft.wlanEnabled) : .none
        case .passphrase:
            let securityChanged = draft.wlanSecurity != initial.wlanSecurity
            let required = securityChanged || draft.wlanSSID != initial.wlanSSID || (draft.wlanEnabled && !initial.wlanEnabled)
            return hasWLAN ? NetConfigValidator.passphrase(draft.wlanPassphrase, security: draft.wlanSecurity,
                                                          enabled: draft.wlanEnabled, required: required) : .none
        case .bluetoothName:
            guard hasBluetooth, originalBluetooth != nil, draft.bluetoothName != initial.bluetoothName else { return .none }
            return NetConfigValidator.bluetoothName(draft.bluetoothName)
        }
    }

    func invalidFields(hasBluetooth: Bool, hasWLAN: Bool) -> [NetConfigField] {
        NetConfigField.allCases.filter { issue($0, hasBluetooth: hasBluetooth, hasWLAN: hasWLAN).isError }
    }

    func shake(_ fields: [NetConfigField], reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : .linear(duration: 0.45)) {
            for field in fields { shakeTokens[field, default: 0] += 1 }
        }
    }

    func shakeToken(_ field: NetConfigField) -> Int { shakeTokens[field] ?? 0 }

    // MARK: Übertragen

    func apply(session: PrinterSession, model: AppModel, hasBluetooth: Bool, hasWLAN: Bool, reduceMotion: Bool) async {
        let invalid = invalidFields(hasBluetooth: hasBluetooth, hasWLAN: hasWLAN)
        guard invalid.isEmpty else {
            shake(invalid, reduceMotion: reduceMotion)
            model.toast(tr("Bitte Eingaben prüfen"), message: tr("Rot markierte Felder enthalten ungültige Werte."), style: .warning)
            return
        }
        guard let original, hasChanges, !isApplying else { return }
        withAnimation(reduceMotion ? nil : Motion.spring) { isApplying = true }
        defer { withAnimation(reduceMotion ? nil : Motion.spring) { isApplying = false } }

        var ok = true
        if hasBluetooth, originalBluetooth != nil {
            if draft.bluetoothName != initial.bluetoothName {
                let result = await session.setvar("bluetooth.friendly_name", draft.bluetoothName)
                ok = ok && result
            }
            if draft.bluetoothDiscoverable != initial.bluetoothDiscoverable {
                let result = await session.setvar("bluetooth.discoverable", draft.bluetoothDiscoverable ? "on" : "off")
                ok = ok && result
            }
        }

        let restart = needsRestart
        let target = draft.applying(to: original, initial: initial)
        if restart {
            let result = await session.applyNetworkSettings(target)
            ok = ok && result
        } else if ok {
            model.toast(tr("Bluetooth-Einstellungen übernommen"), style: .success)
        }
        guard ok else { return }

        var suggestedHost: String?
        var port: Int?
        if restart, case .tcp(let host, let currentPort) = session.saved.descriptor {
            port = currentPort
            if !target.useDHCP {
                let newIP = NetConfigIPv4.normalized(target.ipAddress)
                let currentIsOldIP = NetConfigIPv4.parse(host) != nil || host == original.ipAddress
                if newIP != host && currentIsOldIP { suggestedHost = newIP }
            }
        }
        let switchedToDHCP = restart && target.useDHCP && !original.useDHCP
        let applied = draft
        withAnimation(reduceMotion ? nil : Motion.bouncy) {
            outcome = NetConfigOutcome(appliedAt: Date(), restartExpected: restart, suggestedHost: suggestedHost,
                                       port: port, switchedToDHCP: switchedToDHCP)
            // Übernommene Werte sind der neue Ausgangszustand; das Passwort wird nie gespeichert.
            var accepted = applied
            accepted.wlanPassphrase = ""
            initial = accepted
            draft = accepted
            self.original = target
            if hasBluetooth, originalBluetooth != nil {
                originalBluetooth = NetConfigBluetooth(friendlyName: applied.bluetoothName,
                                                       discoverable: applied.bluetoothDiscoverable)
            }
        }
        if restart && suggestedHost == nil && !switchedToDHCP {
            scheduleReconnect(session: session, reduceMotion: reduceMotion, wantsBluetooth: hasBluetooth)
        }
    }

    /// Verbindung auf die neue Adresse umstellen (baut die Verbindung automatisch neu auf).
    func adoptSuggestedHost(session: PrinterSession, reduceMotion: Bool, wantsBluetooth: Bool) {
        guard var current = outcome, let host = current.suggestedHost else { return }
        let port = current.port ?? 9100
        session.saved.descriptor = .tcp(host: host, port: port)
        current.hostUpdated = true
        withAnimation(reduceMotion ? nil : Motion.spring) { outcome = current }
        scheduleReconnect(session: session, reduceMotion: reduceMotion, wantsBluetooth: wantsBluetooth)
    }

    /// Wartet den Neustart ab und verbindet sich dann erneut (mehrere Versuche).
    func scheduleReconnect(session: PrinterSession, reduceMotion: Bool, wantsBluetooth: Bool, initialDelay: Double? = nil) {
        reconnectTask?.cancel()
        let delay = initialDelay ?? (session.isVirtual ? 2 : 25)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            for _ in 0..<6 {
                guard !Task.isCancelled, let self else { return }
                if !session.connectionState.isConnected { await session.reconnect() }
                if session.connectionState.isConnected {
                    if var current = self.outcome {
                        current.reconnected = true
                        withAnimation(reduceMotion ? nil : Motion.bouncy) { self.outcome = current }
                    }
                    await session.refreshIdentity()
                    await self.load(session: session, reduceMotion: reduceMotion, wantsBluetooth: wantsBluetooth)
                    return
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func reconnectNow(session: PrinterSession, reduceMotion: Bool, wantsBluetooth: Bool) {
        scheduleReconnect(session: session, reduceMotion: reduceMotion, wantsBluetooth: wantsBluetooth, initialDelay: 0)
    }

    func dismissOutcome(reduceMotion: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        withAnimation(reduceMotion ? nil : Motion.spring) { outcome = nil }
    }

    func cancelBackgroundWork() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}

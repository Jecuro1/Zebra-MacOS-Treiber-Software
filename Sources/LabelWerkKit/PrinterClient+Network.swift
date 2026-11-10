import Foundation
import LabelWerkCore

extension PrinterClient {

    /// SGD-Namen, die ``networkSettings()`` liest.
    enum NetworkVariable {
        static let dhcpHostnameEnabled = "ip.dhcp.option12"
        static let dhcpHostname = "ip.dhcp.option12_value"
        static let activeNetmask = "interface.network.active.netmask"
        static let activeGateway = "interface.network.active.gateway"

        static let all: [String] = [
            SGD.Variable.ipProtocol, SGD.Variable.ip, SGD.Variable.netmask, SGD.Variable.gateway,
            SGD.Variable.activeIP, activeNetmask, activeGateway, SGD.Variable.dnsServers,
            dhcpHostname, SGD.Variable.wlanEnabled, SGD.Variable.wlanESSID, SGD.Variable.wlanSecurity,
            SGD.Variable.mac, SGD.Variable.wiredMAC, SGD.Variable.wlanMAC,
        ]
    }

    // MARK: - Lesen

    /// Netzwerkeinstellungen über SGD (`ip.*`, `interface.network.active.*`, `wlan.*`).
    ///
    /// Bei DHCP enthalten Adresse, Maske und Gateway die aktuell zugewiesenen Werte der aktiven
    /// Schnittstelle. Die WLAN-Passphrase wird nie gelesen.
    ///
    /// - Throws: ``PrinterClientError/noResponse(_:)``, wenn der Drucker keine SGD-Werte liefert.
    public func networkSettings() async throws -> NetworkSettings {
        try await guarded {
            let values = try await self.fetchVariables(NetworkVariable.all)
            guard values[SGD.Variable.ipProtocol] != nil || values[SGD.Variable.ip] != nil
                || values[SGD.Variable.activeIP] != nil else {
                throw PrinterClientError.noResponse("Netzwerkeinstellungen lesen")
            }
            return Self.makeNetworkSettings(values)
        }
    }

    static func makeNetworkSettings(_ values: [String: String]) -> NetworkSettings {
        func value(_ key: String) -> String? {
            guard let raw = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  raw != "?" else { return nil }
            return raw
        }
        let useDHCP = isDynamic(protocol: value(SGD.Variable.ipProtocol) ?? "dhcp")
        func pick(active: String, configured: String) -> String? {
            useDHCP ? (value(active) ?? value(configured)) : (value(configured) ?? value(active))
        }
        var settings = NetworkSettings(useDHCP: useDHCP)
        settings.ipAddress = pick(active: SGD.Variable.activeIP, configured: SGD.Variable.ip) ?? "0.0.0.0"
        settings.subnetMask = pick(active: NetworkVariable.activeNetmask, configured: SGD.Variable.netmask) ?? "0.0.0.0"
        settings.gateway = pick(active: NetworkVariable.activeGateway, configured: SGD.Variable.gateway) ?? "0.0.0.0"
        settings.dnsServer = value(SGD.Variable.dnsServers)
        settings.hostname = value(NetworkVariable.dhcpHostname)
        if let wlan = value(SGD.Variable.wlanEnabled) {
            settings.wlanEnabled = isOn(wlan)
            settings.wlanSSID = value(SGD.Variable.wlanESSID)
            settings.wlanSecurity = value(SGD.Variable.wlanSecurity)
        }
        settings.macAddress = value(SGD.Variable.mac) ?? value(SGD.Variable.wiredMAC) ?? value(SGD.Variable.wlanMAC)
        return settings
    }

    /// Alles außer `permanent` vergibt Adressen dynamisch (`dhcp`, `bootp`, `all`, `glean`, `rarp` …).
    static func isDynamic(protocol value: String) -> Bool {
        !value.lowercased().contains("permanent")
    }

    static func isOn(_ value: String) -> Bool {
        ["on", "yes", "true", "1", "enabled"].contains(value.lowercased())
    }

    // MARK: - Schreiben

    /// Überträgt Netzwerkeinstellungen per SGD und startet den Drucker neu (`device.reset`),
    /// damit er sie übernimmt.
    ///
    /// Bei Verbindungen mit Rückkanal werden zuerst die aktuellen Werte gelesen und nur
    /// geänderte Variablen geschrieben (die Passphrase immer, wenn angegeben); ohne Änderung
    /// entfällt auch der Neustart. Ohne Rückkanal werden alle Werte geschrieben.
    /// Hinweis: Nach dem Neustart ist der Drucker ggf. unter einer neuen Adresse erreichbar. Die
    /// bestehende Verbindung wird vor der nächsten Operation geschlossen und (zur bisherigen
    /// Adresse) neu aufgebaut.
    ///
    /// - Throws: ``PrinterClientError/invalidNetworkSettings(_:)`` bei ungültigen Adressen.
    public func applyNetworkSettings(_ settings: NetworkSettings) async throws {
        try await guarded {
            try Self.validate(settings)
            var currentValues: [String: String] = [:]
            if self.supportsBidirectional {
                currentValues = try await self.fetchVariables(NetworkVariable.all + [NetworkVariable.dhcpHostnameEnabled])
            }
            let changes = Self.networkChanges(settings, configured: currentValues)
            guard !changes.isEmpty else { return }
            var commands = ""
            for change in changes { commands += SGD.setvar(change.name, change.value) }
            commands += SGD.reset()
            try await self.transmit(commands)
            self.printerWillRestart()
            self.lastIdentity = nil
        }
    }

    static func validate(_ settings: NetworkSettings) throws {
        if !settings.useDHCP {
            guard NetworkSettings.isValidIPv4(settings.ipAddress), settings.ipAddress != "0.0.0.0" else {
                throw PrinterClientError.invalidNetworkSettings("„\(settings.ipAddress)“ ist keine gültige IP-Adresse.")
            }
            guard NetworkSettings.isValidIPv4(settings.subnetMask) else {
                throw PrinterClientError.invalidNetworkSettings("„\(settings.subnetMask)“ ist keine gültige Subnetzmaske.")
            }
            guard NetworkSettings.isValidIPv4(settings.gateway) else {
                throw PrinterClientError.invalidNetworkSettings("„\(settings.gateway)“ ist kein gültiges Gateway.")
            }
        }
        if let dns = settings.dnsServer, !dns.isEmpty, !NetworkSettings.isValidIPv4(dns) {
            throw PrinterClientError.invalidNetworkSettings("„\(dns)“ ist kein gültiger DNS-Server.")
        }
        if let hostname = settings.hostname, !hostname.isEmpty {
            let allowed = hostname.unicodeScalars.allSatisfy { scalar in
                (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                    || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "."
            }
            guard allowed, hostname.count <= 63 else {
                throw PrinterClientError.invalidNetworkSettings("„\(hostname)“ ist kein gültiger Hostname (Buchstaben, Ziffern, Bindestrich).")
            }
        }
        if let ssid = settings.wlanSSID, ssid.utf8.count > 32 {
            throw PrinterClientError.invalidNetworkSettings("Die SSID darf höchstens 32 Byte lang sein.")
        }
        if let passphrase = settings.wlanPassphrase, !passphrase.isEmpty,
           !(8...63).contains(passphrase.count) && !(passphrase.count == 64 && passphrase.allSatisfy(\.isHexDigit)) {
            throw PrinterClientError.invalidNetworkSettings("Die WLAN-Passphrase muss 8 bis 63 Zeichen lang sein.")
        }
    }

    /// Zu schreibende SGD-Werte – nur Änderungen gegenüber den gelesenen Werten `configured`
    /// (leer = alles schreiben).
    static func networkChanges(_ target: NetworkSettings,
                               configured: [String: String]) -> [(name: String, value: String)] {
        let currentProtocol = configured[SGD.Variable.ipProtocol]
        var changes: [(name: String, value: String)] = []
        func set(_ name: String, _ value: String, unchangedIf currentValue: String?) {
            if let currentValue, currentValue.trimmingCharacters(in: .whitespaces).lowercased() == value.lowercased() { return }
            changes.append((name, value))
        }

        // Adressvergabe: ein bereits dynamischer Modus (z. B. „all“) bleibt bei DHCP erhalten.
        if target.useDHCP {
            if let currentProtocol, isDynamic(protocol: currentProtocol) {
                // unverändert
            } else {
                changes.append((SGD.Variable.ipProtocol, "dhcp"))
            }
        } else {
            set(SGD.Variable.ipProtocol, "permanent", unchangedIf: currentProtocol)
            let isStatic = currentProtocol.map { !isDynamic(protocol: $0) } ?? false
            set(SGD.Variable.ip, target.ipAddress, unchangedIf: isStatic ? configured[SGD.Variable.ip] : nil)
            set(SGD.Variable.netmask, target.subnetMask, unchangedIf: isStatic ? configured[SGD.Variable.netmask] : nil)
            set(SGD.Variable.gateway, target.gateway, unchangedIf: isStatic ? configured[SGD.Variable.gateway] : nil)
        }
        if let dns = target.dnsServer, !dns.isEmpty {
            set(SGD.Variable.dnsServers, dns, unchangedIf: configured[SGD.Variable.dnsServers])
        }
        if let hostname = target.hostname, !hostname.isEmpty {
            set(NetworkVariable.dhcpHostname, hostname, unchangedIf: configured[NetworkVariable.dhcpHostname])
            set(NetworkVariable.dhcpHostnameEnabled, "on", unchangedIf: configured[NetworkVariable.dhcpHostnameEnabled])
        }
        if let enabled = target.wlanEnabled {
            let currentEnabled = configured[SGD.Variable.wlanEnabled].map { isOn($0) ? "on" : "off" }
            set(SGD.Variable.wlanEnabled, enabled ? "on" : "off", unchangedIf: currentEnabled)
        }
        if let ssid = target.wlanSSID {
            set(SGD.Variable.wlanESSID, ssid, unchangedIf: configured[SGD.Variable.wlanESSID])
        }
        if let security = target.wlanSecurity, !security.isEmpty {
            set(SGD.Variable.wlanSecurity, security, unchangedIf: configured[SGD.Variable.wlanSecurity])
        }
        if let passphrase = target.wlanPassphrase, !passphrase.isEmpty {
            changes.append((SGD.Variable.wlanPSK, passphrase))
        }
        return changes
    }
}

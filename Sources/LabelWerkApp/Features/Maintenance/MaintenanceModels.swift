import Foundation
import LabelWerkKit

// Reine Logik des Bereichs „Sicherung & Wartung“ (ohne SwiftUI/AppKit):
// Sicherungsdatei, SGD-Richtlinien (was gesichert/geschrieben werden darf), Vergleich,
// Gerätesprache, Zählerstände und das Druckkopf-Testmuster.

// MARK: - Bereiche

/// Unterbereiche der Seite „Sicherung & Wartung“.
enum MaintPane: String, CaseIterable, Identifiable, Hashable {
    case backup
    case restore
    case language
    case care

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backup: return tr("Sicherung")
        case .restore: return tr("Wiederherstellen & Klonen")
        case .language: return tr("Druckersprache")
        case .care: return tr("Druckkopf & Wartung")
        }
    }

    var systemImage: String {
        switch self {
        case .backup: return "externaldrive.badge.plus"
        case .restore: return "arrow.triangle.2.circlepath"
        case .language: return "character.bubble"
        case .care: return "stethoscope"
        }
    }
}

// MARK: - Sicherungsdatei (.lwbackup)

/// Ein gesicherter SGD-Wert.
struct MaintBackupEntry: Codable, Hashable, Identifiable {
    var name: String
    var value: String
    var type: String?
    var access: String?
    var range: String?
    var archive: Bool?
    var clone: Bool?

    var id: String { name }
    var group: String { MaintSGDPolicy.group(of: name) }

    init(name: String, value: String, type: String? = nil, access: String? = nil, range: String? = nil,
         archive: Bool? = nil, clone: Bool? = nil) {
        self.name = name
        self.value = value
        self.type = type
        self.access = access
        self.range = range
        self.archive = archive
        self.clone = clone
    }

    init(setting: SGDSetting) {
        self.init(name: setting.name, value: setting.value, type: setting.type, access: setting.access,
                  range: setting.range, archive: setting.archive, clone: setting.clone)
    }
}

/// Identität des gesicherten Druckers (bewusst eigene, tolerante Struktur).
struct MaintBackupIdentity: Codable, Hashable {
    var model: String?
    var serialNumber: String?
    var firmware: String?
    var friendlyName: String?
    var ipAddress: String?
    var macAddress: String?
    var isLinkOS: Bool?

    init(model: String? = nil, serialNumber: String? = nil, firmware: String? = nil, friendlyName: String? = nil,
         ipAddress: String? = nil, macAddress: String? = nil, isLinkOS: Bool? = nil) {
        self.model = model
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.friendlyName = friendlyName
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.isLinkOS = isLinkOS
    }
}

/// Eintrag der Dateiliste (nur Metadaten, keine Inhalte).
struct MaintBackupFileRef: Codable, Hashable, Identifiable {
    var path: String
    var size: Int
    var kind: String

    var id: String { path }

    init(path: String, size: Int, kind: String) {
        self.path = path
        self.size = size
        self.kind = kind
    }

    init(file: PrinterFile) {
        self.init(path: file.path, size: file.size, kind: file.kind.rawValue)
    }
}

enum MaintBackupError: LocalizedError, Equatable {
    case notABackup
    case unsupportedVersion(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .notABackup:
            return tr("Die Datei ist keine LabelWerk-Sicherung.")
        case .unsupportedVersion(let version):
            return tr("Die Sicherung verwendet das neuere Format %d. Bitte LabelWerk aktualisieren.", version)
        case .empty:
            return tr("Die Sicherung enthält keine Einstellungen.")
        }
    }
}

/// Inhalt einer `.lwbackup`-Datei (JSON).
struct MaintBackupDocument: Codable, Hashable {
    static let formatIdentifier = "de.labelwerk.printer-backup"
    static let currentVersion = 1
    static let fileExtension = "lwbackup"

    var format: String
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String?
    var printerName: String
    var identity: MaintBackupIdentity
    var modelID: String?
    var resolution: Resolution
    var language: PrinterLanguage
    /// Treibereinstellungen von LabelWerk (`SavedPrinter.settings`).
    var driverSettings: PrintSettings?
    var stockID: String
    /// Definition des Etikettenformats (für eigene Formate auf anderen Macs).
    var stock: LabelStock?
    /// Gesicherte SGD-Gruppen.
    var groups: [String]
    /// SGD-Werte, nach Namen sortiert.
    var entries: [MaintBackupEntry]
    /// Dateiliste des Druckers (nur Metadaten), falls gewünscht.
    var files: [MaintBackupFileRef]?

    enum CodingKeys: String, CodingKey {
        case format, formatVersion, createdAt, appVersion, printerName, identity, modelID, resolution, language
        case driverSettings, stockID, stock, groups, entries, files
    }

    init(printerName: String, identity: MaintBackupIdentity, modelID: String?, resolution: Resolution,
         language: PrinterLanguage, driverSettings: PrintSettings?, stockID: String, stock: LabelStock?,
         groups: [String], entries: [MaintBackupEntry], files: [MaintBackupFileRef]?, appVersion: String?,
         createdAt: Date = Date()) {
        self.format = Self.formatIdentifier
        self.formatVersion = Self.currentVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.printerName = printerName
        self.identity = identity
        self.modelID = modelID
        self.resolution = resolution
        self.language = language
        self.driverSettings = driverSettings
        self.stockID = stockID
        self.stock = stock
        self.groups = groups
        self.entries = entries
        self.files = files
    }

    /// Tolerantes Lesen: fehlende oder unbekannte Zusatzangaben verhindern das Laden nicht.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.formatIdentifier
        guard format == Self.formatIdentifier else { throw MaintBackupError.notABackup }
        self.format = format
        formatVersion = (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? Self.currentVersion
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
        printerName = (try? c.decodeIfPresent(String.self, forKey: .printerName)) ?? ""
        identity = (try? c.decodeIfPresent(MaintBackupIdentity.self, forKey: .identity)) ?? MaintBackupIdentity()
        modelID = try? c.decodeIfPresent(String.self, forKey: .modelID)
        resolution = (try? c.decodeIfPresent(Resolution.self, forKey: .resolution)) ?? .dpi203
        language = (try? c.decodeIfPresent(PrinterLanguage.self, forKey: .language)) ?? .zpl
        driverSettings = try? c.decodeIfPresent(PrintSettings.self, forKey: .driverSettings)
        stockID = (try? c.decodeIfPresent(String.self, forKey: .stockID)) ?? ""
        stock = try? c.decodeIfPresent(LabelStock.self, forKey: .stock)
        groups = (try? c.decodeIfPresent([String].self, forKey: .groups)) ?? []
        entries = try c.decode([MaintBackupEntry].self, forKey: .entries)
        files = try? c.decodeIfPresent([MaintBackupFileRef].self, forKey: .files)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> MaintBackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: MaintBackupDocument
        do {
            document = try decoder.decode(MaintBackupDocument.self, from: data)
        } catch let error as MaintBackupError {
            throw error
        } catch {
            throw MaintBackupError.notABackup
        }
        guard document.formatVersion <= currentVersion else {
            throw MaintBackupError.unsupportedVersion(document.formatVersion)
        }
        guard !document.entries.isEmpty else { throw MaintBackupError.empty }
        return document
    }

    /// Baut eine Sicherung aus gelesenen Druckerwerten. Es werden nur wiederherstellbare Werte der
    /// gewählten Gruppen übernommen (keine Befehle, keine geheimen oder rein lesbaren Werte).
    static func make(printerName: String, identity: MaintBackupIdentity, modelID: String?, resolution: Resolution,
                     language: PrinterLanguage, driverSettings: PrintSettings, stock: LabelStock,
                     settings: [String: SGDSetting], groups: Set<String>, files: [PrinterFile]?,
                     appVersion: String?, now: Date = Date()) -> MaintBackupDocument {
        let entries = settings.values
            .filter { groups.contains($0.group) && MaintSGDPolicy.isRestorable($0) }
            .map(MaintBackupEntry.init(setting:))
            .sorted { $0.name < $1.name }
        let usedGroups = Set(entries.map(\.group)).sorted()
        return MaintBackupDocument(
            printerName: printerName, identity: identity, modelID: modelID, resolution: resolution,
            language: language, driverSettings: driverSettings, stockID: stock.id, stock: stock,
            groups: usedGroups, entries: entries, files: files?.map(MaintBackupFileRef.init(file:)),
            appVersion: appVersion, createdAt: now
        )
    }

    /// Vorschlag für den Dateinamen, z. B. „LabelWerk-Sicherung ZD421 2026-11-10.lwbackup“.
    static func suggestedFileName(printerName: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let unsafe = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = printerName.unicodeScalars.map { unsafe.contains($0) ? "-" : String($0) }.joined()
        let name = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "LabelWerk-Sicherung" : "LabelWerk-Sicherung \(name)"
        return "\(base) \(formatter.string(from: date)).\(fileExtension)"
    }

    var groupCounts: [String: Int] {
        Dictionary(grouping: entries, by: \.group).mapValues(\.count)
    }
}

// MARK: - SGD-Richtlinien

/// Art einer SGD-Gruppe für Sicherung und Wiederherstellung.
enum MaintGroupKind: Int, Comparable, Hashable {
    /// Kerneinstellungen (Gerät, Medien, Druck, EZPL, ZPL) – standardmäßig gesichert.
    case recommended
    /// Weitere Einstellungen – standardmäßig gesichert.
    case other
    /// Netzwerk – nur auf ausdrücklichen Wunsch (kann die Verbindung trennen).
    case network
    /// Zähler, Sensoren, reine Lese- oder Befehlsgruppen – nie gesichert.
    case excluded

    static func < (lhs: MaintGroupKind, rhs: MaintGroupKind) -> Bool { lhs.rawValue < rhs.rawValue }

    var includedByDefault: Bool { self == .recommended || self == .other }
}

/// Zusammenfassung einer Gruppe nach dem Lesen.
struct MaintGroupSummary: Identifiable, Hashable {
    let id: String
    let kind: MaintGroupKind
    /// Alle Werte der Gruppe.
    let total: Int
    /// Wiederherstellbare Werte (lesbar, beschreibbar, kein Befehl, nicht geheim).
    let restorable: Int
    /// Nur lesbare Werte.
    let readOnly: Int
    /// Befehle und geheime Werte (Passwörter), die nie gesichert werden.
    let protected: Int
}

enum MaintSGDPolicy {
    /// Standardmäßig gesicherte Kerngruppen in Anzeigereihenfolge.
    static let recommendedGroups: [String] = ["device", "media", "print", "ezpl", "zpl"]

    /// Gruppen mit Netzwerk-/Funkeinstellungen.
    static let networkGroups: Set<String> = [
        "ip", "ip6", "wlan", "bluetooth", "ble", "internal_wired", "external_wired", "wired", "card",
        "netmanage", "weblink", "interface", "smtp", "snmp", "http", "https", "ftp", "lpd", "tcp", "udp",
        "telnet", "netbios", "dhcp", "ntp", "wifi",
    ]

    /// Gruppen, die nur Zählerstände bzw. Messwerte enthalten.
    static let readOnlyGroups: Set<String> = ["odometer", "sensor"]

    /// SGD-Namen, die beim Schreiben eine Aktion auslösen.
    static let commandNames: Set<String> = [
        "device.reset", "device.restore_defaults", "device.frontpanel.key_press", "device.shutdown",
        "file.dir", "file.delete", "file.run", "file.type", "file.print", "file.rename", "file.capture",
        "ezpl.manual_calibration", "media.calibrate", "power.shutdown", "power.reset", "zbi.run", "zbi.terminate",
    ]

    /// Namensendungen typischer Befehle.
    static let commandSuffixes: [String] = [
        ".reset", ".restore_defaults", ".manual_calibration", ".calibrate", ".key_press", ".delete",
    ]

    /// Teilzeichenfolgen geheimer Werte (werden nie gesichert oder geschrieben).
    static let secretMarkers: [String] = [
        "password", "passwd", "passphrase", "psk", "secret", "wep.key", "private_key", "credential", "_pin", ".pin",
    ]

    static func group(of name: String) -> String {
        name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }

    static func isNetwork(group: String) -> Bool { networkGroups.contains(group.lowercased()) }

    static func isNetwork(name: String) -> Bool { isNetwork(group: group(of: name)) }

    /// Ohne Angabe gilt ein Wert als lesbar.
    static func isReadable(access: String?) -> Bool {
        guard let access = access?.trimmingCharacters(in: .whitespaces), !access.isEmpty else { return true }
        return access.uppercased().contains("R")
    }

    /// Ohne Angabe gilt ein Wert als beschreibbar.
    static func isWritable(access: String?) -> Bool {
        guard let access = access?.trimmingCharacters(in: .whitespaces), !access.isEmpty else { return true }
        return access.uppercased().contains("W")
    }

    static func isCommand(name: String, access: String?) -> Bool {
        let lower = name.lowercased()
        if commandNames.contains(lower) { return true }
        if commandSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }
        // Reine Schreibvariablen (W ohne R) sind Befehle bzw. Geheimnisse.
        if let access = access?.uppercased(), access.contains("W"), !access.contains("R") { return true }
        return false
    }

    static func isSecret(name: String, value: String) -> Bool {
        let lower = name.lowercased()
        if secretMarkers.contains(where: { lower.contains($0) }) { return true }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "*" }
    }

    static func isProtected(name: String, value: String, access: String?) -> Bool {
        isCommand(name: name, access: access) || isSecret(name: name, value: value)
    }

    /// Lesbar, beschreibbar, kein Befehl, nicht geheim und nicht in einer Zählergruppe.
    static func isRestorable(_ setting: SGDSetting) -> Bool {
        guard !readOnlyGroups.contains(group(of: setting.name).lowercased()) else { return false }
        guard !isProtected(name: setting.name, value: setting.value, access: setting.access) else { return false }
        return isReadable(access: setting.access) && isWritable(access: setting.access)
    }

    /// Fasst die gelesenen Werte nach Gruppen zusammen (sortiert: Kern, Weitere, Netzwerk, Ausgeschlossen).
    static func summarize(_ settings: [String: SGDSetting]) -> [MaintGroupSummary] {
        let grouped = Dictionary(grouping: settings.values, by: \.group)
        let summaries = grouped.map { name, values -> MaintGroupSummary in
            var restorable = 0
            var readOnly = 0
            var protected = 0
            for setting in values {
                if isProtected(name: setting.name, value: setting.value, access: setting.access) {
                    protected += 1
                } else if isRestorable(setting) {
                    restorable += 1
                } else {
                    readOnly += 1
                }
            }
            let lower = name.lowercased()
            let kind: MaintGroupKind
            if readOnlyGroups.contains(lower) || restorable == 0 {
                kind = .excluded
            } else if networkGroups.contains(lower) {
                kind = .network
            } else if recommendedGroups.contains(lower) {
                kind = .recommended
            } else {
                kind = .other
            }
            return MaintGroupSummary(id: name, kind: kind, total: values.count, restorable: restorable,
                                     readOnly: readOnly, protected: protected)
        }
        return summaries.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.kind == .recommended {
                let l = recommendedGroups.firstIndex(of: lhs.id.lowercased()) ?? Int.max
                let r = recommendedGroups.firstIndex(of: rhs.id.lowercased()) ?? Int.max
                if l != r { return l < r }
            }
            return lhs.id < rhs.id
        }
    }

    static func displayName(group: String) -> String {
        switch group.lowercased() {
        case "device": return tr("Gerät")
        case "media": return tr("Medien")
        case "print": return tr("Druck")
        case "ezpl": return tr("Bedienung & Verhalten")
        case "zpl": return tr("ZPL")
        case "ip": return tr("IP-Netzwerk")
        case "ip6": return tr("IPv6")
        case "wlan", "wifi": return tr("WLAN")
        case "bluetooth", "ble": return tr("Bluetooth")
        case "internal_wired", "wired": return tr("Ethernet")
        case "external_wired": return tr("Externer Druckserver")
        case "card": return tr("Funkkarte")
        case "netmanage": return tr("Netzwerkverwaltung")
        case "weblink": return tr("Weblink (Cloud)")
        case "interface": return tr("Schnittstellen")
        case "odometer": return tr("Zähler")
        case "sensor": return tr("Sensoren")
        case "head": return tr("Druckkopf")
        case "rfid": return tr("RFID")
        case "display": return tr("Anzeige")
        case "alerts": return tr("Benachrichtigungen")
        case "power": return tr("Energie")
        case "usb": return tr("USB")
        case "comm": return tr("Serielle Schnittstelle")
        case "parallel_port": return tr("Parallelport")
        case "file": return tr("Dateien")
        case "zbi": return tr("ZBI-Programme")
        case "apl": return tr("Sprachemulation")
        case "capture": return tr("Datenmitschnitt")
        case "cutter": return tr("Schneidwerk")
        case "input": return tr("Eingabegeräte")
        case "memory": return tr("Speicher")
        case "format": return tr("Formate")
        case "log", "logging": return tr("Protokoll")
        case "smartcard": return tr("Smartcard")
        case "mcr": return tr("Magnetkartenleser")
        case "cradle": return tr("Ladestation")
        case "kiosk": return tr("Kiosk")
        default:
            return group.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func systemImage(group: String) -> String {
        switch group.lowercased() {
        case "device": return "printer"
        case "media": return "square.stack.3d.up"
        case "print": return "slider.horizontal.3"
        case "ezpl": return "gearshape"
        case "zpl": return "chevron.left.forwardslash.chevron.right"
        case "ip", "ip6", "internal_wired", "external_wired", "wired", "netmanage", "interface": return "network"
        case "wlan", "wifi", "card": return "wifi"
        case "bluetooth", "ble": return "antenna.radiowaves.left.and.right"
        case "weblink": return "cloud"
        case "odometer": return "gauge.with.dots.needle.33percent"
        case "sensor": return "dot.radiowaves.right"
        case "head": return "flame"
        case "rfid": return "wave.3.right"
        case "display": return "display"
        case "alerts": return "bell"
        case "power": return "bolt"
        case "usb", "comm", "parallel_port": return "cable.connector"
        case "file", "format": return "doc"
        case "zbi": return "curlybraces"
        case "cutter": return "scissors"
        default: return "square.grid.2x2"
        }
    }
}

// MARK: - Vergleich (Wiederherstellen/Klonen)

struct MaintRestoreRow: Identifiable, Hashable {
    enum Status: Int, Hashable, Comparable {
        /// Wert weicht ab und ist beschreibbar.
        case changed
        /// Wert ist bereits gleich.
        case unchanged
        /// Der Zieldrucker meldet den Wert als nur lesbar.
        case readOnly
        /// Der Zieldrucker kennt den Wert nicht.
        case missing
        /// Befehl oder geheimer Wert – wird nie geschrieben.
        case protected

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let name: String
    let group: String
    let backupValue: String
    let currentValue: String?
    let status: Status
    let isNetwork: Bool
    /// Laut Drucker gerätespezifisch (`clone: false`, z. B. Gerätename oder IP-Adresse).
    let isDeviceSpecific: Bool
    let range: String?

    var id: String { name }
    var isSelectable: Bool { status == .changed || status == .unchanged }
}

enum MaintDiff {
    /// Vergleicht die gesicherten Werte mit den aktuellen Werten des Zieldruckers.
    static func rows(document: MaintBackupDocument, current: [String: SGDSetting]) -> [MaintRestoreRow] {
        document.entries.map { entry in
            let target = current[entry.name]
            let access = target?.access ?? entry.access
            let status: MaintRestoreRow.Status
            if MaintSGDPolicy.isProtected(name: entry.name, value: entry.value, access: entry.access)
                || MaintSGDPolicy.readOnlyGroups.contains(entry.group.lowercased()) {
                status = .protected
            } else if let target {
                if !MaintSGDPolicy.isWritable(access: access) {
                    status = .readOnly
                } else if valuesMatch(target.value, entry.value) {
                    status = .unchanged
                } else {
                    status = .changed
                }
            } else {
                status = .missing
            }
            let cloneFlag = target?.clone ?? entry.clone
            return MaintRestoreRow(name: entry.name, group: entry.group, backupValue: entry.value,
                                   currentValue: target?.value, status: status,
                                   isNetwork: MaintSGDPolicy.isNetwork(name: entry.name),
                                   isDeviceSpecific: cloneFlag == false, range: target?.range ?? entry.range)
        }
        .sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status < rhs.status }
            return lhs.name < rhs.name
        }
    }

    /// Vorauswahl: abweichende, beschreibbare Werte – ohne Netzwerk, beim Klonen ohne gerätespezifische
    /// Werte und ohne eine Gerätesprache, die die Ausgabesprache von LabelWerk (`targetOutput`) nicht
    /// versteht (sonst druckte das Ziel danach Befehlstext oder gar nichts).
    static func defaultSelection(_ rows: [MaintRestoreRow], sameDevice: Bool, targetOutput: PrinterLanguage,
                                 model: PrinterModel?) -> Set<String> {
        Set(rows.filter { row in
            guard row.status == .changed, !row.isNetwork, sameDevice || !row.isDeviceSpecific else { return false }
            if MaintDeviceLanguage.isLanguageSetting(row.name),
               !MaintDeviceLanguage.isCompatible(deviceValue: row.backupValue, output: targetOutput, model: model) {
                return false
            }
            return true
        }.map(\.name))
    }

    /// Schreibreihenfolge: normale Werte zuerst, dann die Gerätesprache, zuletzt Netzwerkwerte.
    static func applyOrder(_ rows: [MaintRestoreRow]) -> [MaintRestoreRow] {
        func rank(_ row: MaintRestoreRow) -> Int {
            if row.isNetwork { return 2 }
            if MaintDeviceLanguage.isLanguageSetting(row.name) { return 1 }
            return 0
        }
        return rows.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l != r { return l < r }
            return lhs.name < rhs.name
        }
    }

    /// Vergleicht Werte tolerant (Leerraum, Groß-/Kleinschreibung, Zahlenformat).
    static func valuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return true }
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        if let x = Double(a), let y = Double(b) { return abs(x - y) < 0.000_1 }
        return false
    }
}

// MARK: - Gerätesprache

struct MaintDeviceLanguageOption: Identifiable, Hashable {
    let value: String
    let title: String
    let detail: String
    let systemImage: String
    /// Ausgabesprachen von LabelWerk, die der Drucker in diesem Modus versteht.
    let outputs: [PrinterLanguage]

    var id: String { value }
}

enum MaintDeviceLanguage {
    static let sgdName = "device.languages"

    static var all: [MaintDeviceLanguageOption] {
        [
            MaintDeviceLanguageOption(value: "zpl", title: tr("ZPL"),
                                      detail: tr("Nur ZPL II – empfohlen für LabelWerk und die meisten Programme."),
                                      systemImage: "chevron.left.forwardslash.chevron.right", outputs: [.zpl]),
            MaintDeviceLanguageOption(value: "epl_zpl", title: tr("EPL & ZPL"),
                                      detail: tr("Erkennt EPL2 und ZPL automatisch – praktisch bei gemischten Altsystemen."),
                                      systemImage: "arrow.left.arrow.right", outputs: [.zpl, .epl]),
            MaintDeviceLanguageOption(value: "epl", title: tr("EPL"),
                                      detail: tr("Nur EPL2 – für ältere Software, die EPL-Befehle erzeugt."),
                                      systemImage: "text.alignleft", outputs: [.epl]),
            MaintDeviceLanguageOption(value: "line_print", title: tr("Zeilendruck"),
                                      detail: tr("Druckt empfangenen Text zeilenweise (bei Mobildruckern CPCL-Zeilenmodus)."),
                                      systemImage: "text.justify.left", outputs: [.cpcl]),
            MaintDeviceLanguageOption(value: "hybrid_xml_zpl", title: tr("XML & ZPL"),
                                      detail: tr("ZPL plus XML-Druckaufträge (z. B. aus SAP/ERP-Systemen)."),
                                      systemImage: "curlybraces", outputs: [.zpl]),
        ]
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `true` für den SGD-Namen der Gerätesprache (unabhängig von Groß-/Kleinschreibung).
    static func isLanguageSetting(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).lowercased() == sgdName
    }

    /// Zebra-Mobildrucker (ZQ, QLn …) verarbeiten CPCL in jedem Modus von `device.languages`.
    static func alwaysAcceptsCPCL(_ model: PrinterModel?) -> Bool {
        model?.supports(PrinterLanguage.cpcl) == true
    }

    /// Für das Modell plausible Optionen (ohne Modell: alle).
    static func options(for model: PrinterModel?) -> [MaintDeviceLanguageOption] {
        guard let model else { return all }
        let zpl = model.supports(PrinterLanguage.zpl)
        let epl = model.supports(PrinterLanguage.epl)
        return all.filter { option in
            switch option.value {
            case "zpl", "hybrid_xml_zpl": return zpl
            case "epl_zpl": return zpl && epl
            case "epl": return epl
            default: return true
            }
        }
    }

    static func option(for value: String) -> MaintDeviceLanguageOption? {
        let key = normalized(value)
        return all.first { $0.value == key }
    }

    /// Ausgabesprachen, die zum Gerätewert passen (auch für frei eingegebene Werte).
    static func outputs(forDeviceValue value: String) -> [PrinterLanguage] {
        if let option = option(for: value) { return option.outputs }
        let key = normalized(value)
        var result: [PrinterLanguage] = []
        if key.contains("zpl") { result.append(.zpl) }
        if key.contains("epl") { result.append(.epl) }
        if key.contains("cpcl") || key.contains("line") { result.append(.cpcl) }
        return result
    }

    /// Wie `outputs(forDeviceValue:)`, ergänzt um CPCL bei Mobildruckern, die CPCL immer verstehen.
    static func outputs(forDeviceValue value: String, model: PrinterModel?) -> [PrinterLanguage] {
        withAlwaysOnCPCL(outputs(forDeviceValue: value), model: model)
    }

    /// Ausgabesprachen einer Option für das Modell (Mobildrucker: zusätzlich CPCL).
    static func outputs(of option: MaintDeviceLanguageOption, model: PrinterModel?) -> [PrinterLanguage] {
        withAlwaysOnCPCL(option.outputs, model: model)
    }

    private static func withAlwaysOnCPCL(_ outputs: [PrinterLanguage], model: PrinterModel?) -> [PrinterLanguage] {
        guard alwaysAcceptsCPCL(model), !outputs.contains(PrinterLanguage.cpcl) else { return outputs }
        return outputs + [PrinterLanguage.cpcl]
    }

    /// Versteht der Drucker im Modus `deviceValue` die Ausgabesprache `output`?
    static func isCompatible(deviceValue: String, output: PrinterLanguage, model: PrinterModel?) -> Bool {
        if output == .cpcl && alwaysAcceptsCPCL(model) { return true }
        return outputs(forDeviceValue: deviceValue).contains(output)
    }

    /// Vorschlag für die Ausgabesprache von LabelWerk passend zum Gerätewert.
    static func suggestedOutput(forDeviceValue value: String, model: PrinterModel?,
                                current: PrinterLanguage) -> PrinterLanguage? {
        let candidates = outputs(forDeviceValue: value, model: model)
        if candidates.contains(current) { return current }
        return candidates.first { model?.supports($0) ?? true }
    }
}

// MARK: - Dauerhaft speichern

/// Warum „Einstellungen dauerhaft speichern“ (ZPL `^JUS`) nicht gesendet wird.
enum MaintSaveSkip: Equatable {
    /// Gerätesprache unbekannt und LabelWerk spricht den Drucker nicht in ZPL an (EPL, CPCL).
    case outputLanguage(PrinterLanguage)
    /// Der Drucker erwartet (nach der Übertragung) eine Sprache ohne ZPL, z. B. `epl` oder `line_print` –
    /// dort würde `^JUS` ignoriert oder sogar als Text gedruckt.
    case deviceLanguage(String)

    /// `nil`, wenn der Drucker `^JUS` versteht: Gerätesprache mit ZPL – oder, falls die Gerätesprache
    /// unbekannt ist, Ausgabesprache ZPL.
    static func evaluate(deviceLanguage: String?, output: PrinterLanguage, model: PrinterModel?) -> MaintSaveSkip? {
        if let deviceLanguage, !MaintDeviceLanguage.normalized(deviceLanguage).isEmpty {
            if MaintDeviceLanguage.isCompatible(deviceValue: deviceLanguage, output: PrinterLanguage.zpl, model: model) {
                return nil
            }
            return .deviceLanguage(deviceLanguage)
        }
        if PrinterAction.saveSettings.isSupported(language: output) { return nil }
        return .outputLanguage(output)
    }

    var explanation: String {
        switch self {
        case .outputLanguage(let language):
            return tr("Dauerhaft speichern nicht möglich: ^JUS ist ein ZPL-Befehl, LabelWerk spricht den Drucker aber in %@ an. Ob die Werte einen Neustart überstehen, bitte danach prüfen.",
                      language.displayName)
        case .deviceLanguage(let value):
            return tr("Dauerhaft speichern nicht möglich: Der Drucker erwartet „%@“ und würde den ZPL-Befehl ^JUS nicht verstehen. Ob die Werte einen Neustart überstehen, bitte danach prüfen.",
                      MaintDeviceLanguage.option(for: value)?.title ?? value)
        }
    }
}

// MARK: - Zählerstände

struct MaintOdometerReading: Equatable {
    var totalMeters: Double?
    var sinceCleanMeters: Double?
    var headMeters: Double?
    var markerMeters: Double?
    var totalLabels: Int?
    var elementTest: String?
    /// Rohwerte, wie der Drucker sie meldet.
    var raw: [String: String]

    var supportsCleaningReset: Bool { raw[MaintOdometer.headCleanKey] != nil }
    var isEmpty: Bool { raw.isEmpty }
}

enum MaintOdometer {
    static let totalKey = "odometer.total_print_length"
    static let headCleanKey = "odometer.headclean"
    static let headNewKey = "odometer.headnew"
    static let markerKey = "odometer.media_marker_count1"
    static let labelCountKey = "odometer.total_label_count"
    static let elementTestKey = "head.element_test"

    static let keys: [String] = [totalKey, headCleanKey, headNewKey, markerKey, labelCountKey, elementTestKey]

    static func reading(from values: [String: String]) -> MaintOdometerReading {
        var raw: [String: String] = [:]
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "?" else { continue }
            raw[key] = trimmed
        }
        func length(_ key: String) -> Double? {
            raw[key].flatMap { StatusInterpreter.meters(fromOdometer: $0) }
        }
        return MaintOdometerReading(
            totalMeters: length(totalKey),
            sinceCleanMeters: length(headCleanKey),
            headMeters: length(headNewKey),
            markerMeters: length(markerKey),
            totalLabels: raw[labelCountKey].flatMap { StatusInterpreter.integer(fromSGD: $0) },
            elementTest: raw[elementTestKey],
            raw: raw
        )
    }
}

enum MaintCleaningLevel: Int, Comparable, Hashable {
    case fine, soon, due, overdue

    static func < (lhs: MaintCleaningLevel, rhs: MaintCleaningLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct MaintCleaningAssessment: Equatable {
    /// Anteil des Intervalls seit der letzten Reinigung (kann > 1 sein).
    let ratio: Double
    let level: MaintCleaningLevel
    /// Verbleibende Strecke bis zur Empfehlung (negativ = überfällig).
    let remainingMeters: Double

    static func assess(sinceCleanMeters: Double, intervalMeters: Double, printerRequests: Bool) -> MaintCleaningAssessment {
        let interval = max(1, intervalMeters)
        let ratio = max(0, sinceCleanMeters) / interval
        var level: MaintCleaningLevel
        switch ratio {
        case ..<0.6: level = .fine
        case ..<0.9: level = .soon
        case ..<1.0: level = .due
        default: level = .overdue
        }
        if printerRequests && level < .due { level = .due }
        return MaintCleaningAssessment(ratio: ratio, level: level, remainingMeters: interval - max(0, sinceCleanMeters))
    }
}

// MARK: - Druckkopf-Testmuster

enum MaintHeadTest {
    enum Element: Hashable {
        /// Rechteck; `thickness >= min(width, height)` ergibt eine gefüllte Fläche.
        case box(x: Int, y: Int, width: Int, height: Int, thickness: Int)
        /// Einzeilige Beschriftung in Schrift 0, auf `width` begrenzt.
        case text(x: Int, y: Int, width: Int, height: Int, value: String)
    }

    enum Part: Hashable {
        case title, info, band, combEven, combOdd, ruler, footer
    }

    struct Layout: Hashable {
        let widthDots: Int
        let heightDots: Int
        let elements: [Element]
        /// Senkrechte Lage der Testbereiche (für Erklärungen in der Vorschau).
        let parts: [Part: ClosedRange<Int>]
    }

    /// Berechnet das Testmuster: Titel, durchgehender schwarzer Balken (fehlende Heizelemente
    /// erscheinen als weiße Streifen), zwei versetzte 1-Punkt-Linienraster (jedes Element einzeln),
    /// Millimeter-Lineal und Hinweis. Kleine Etiketten erhalten nur Balken und Raster.
    static func layout(widthDots: Int, heightDots: Int, resolution: Resolution,
                       title: String, info: String, footer: String) -> Layout {
        let w = max(16, widthDots)
        let h = max(16, heightDots)
        let dpmm = resolution.exactDotsPerMM
        func dots(_ mm: Double) -> Int { max(1, Int((mm * dpmm).rounded())) }

        let margin = min(dots(2), max(1, h / 20))
        var gap = dots(1.2)
        let available = h - 2 * margin

        var parts: [(part: Part, height: Int)] = [
            (.title, dots(4.5)), (.info, dots(2.6)), (.band, dots(6)), (.combEven, dots(6)),
            (.combOdd, dots(6)), (.ruler, dots(4)), (.footer, dots(2.4)),
        ]
        func total() -> Int { parts.reduce(0) { $0 + $1.height } + gap * max(0, parts.count - 1) }

        for droppable in [Part.footer, .info, .ruler, .title] where total() > available {
            parts.removeAll { $0.part == droppable }
        }
        if total() > available {
            gap = max(1, gap / 2)
            let room = max(parts.count, available - gap * max(0, parts.count - 1))
            let sum = max(1, parts.reduce(0) { $0 + $1.height })
            parts = parts.map { (part: $0.part, height: max(1, $0.height * room / sum)) }
        } else {
            let growable = parts.indices.filter { [Part.band, .combEven, .combOdd].contains(parts[$0].part) }
            let extra = available - total()
            if !growable.isEmpty && extra > 0 {
                let share = extra / growable.count
                for index in growable {
                    parts[index].height += min(share, parts[index].height * 2)
                }
            }
        }

        var elements: [Element] = []
        var ranges: [Part: ClosedRange<Int>] = [:]
        var y = margin
        let textWidth = max(1, w - 2 * margin)
        for (part, height) in parts {
            ranges[part] = y...(y + max(0, height - 1))
            switch part {
            case .title:
                elements.append(.text(x: margin, y: y, width: textWidth, height: height, value: title))
            case .info:
                elements.append(.text(x: margin, y: y, width: textWidth, height: height, value: info))
            case .footer:
                elements.append(.text(x: margin, y: y, width: textWidth, height: height, value: footer))
            case .band:
                elements.append(.box(x: 0, y: y, width: w, height: height, thickness: height))
            case .combEven:
                for x in stride(from: 0, to: w, by: 2) {
                    elements.append(.box(x: x, y: y, width: 1, height: height, thickness: 1))
                }
            case .combOdd:
                for x in stride(from: 1, to: w, by: 2) {
                    elements.append(.box(x: x, y: y, width: 1, height: height, thickness: 1))
                }
            case .ruler:
                elements.append(.box(x: 0, y: y, width: w, height: 1, thickness: 1))
                let tickWidth = max(1, Int((0.12 * dpmm).rounded()))
                let longTick = max(2, height / 2)
                let labelHeight = max(1, height - longTick - 1)
                let millimeters = Int(Double(w) / dpmm)
                if millimeters >= 0 {
                    for mm in 0...millimeters {
                        let x = Int((Double(mm) * dpmm).rounded())
                        guard x + tickWidth <= w else { break }
                        let tick: Int
                        if mm % 10 == 0 {
                            tick = longTick
                        } else if mm % 5 == 0 {
                            tick = max(1, height * 3 / 10)
                        } else {
                            tick = max(1, height / 6)
                        }
                        elements.append(.box(x: x, y: y, width: tickWidth, height: tick, thickness: tickWidth))
                        if mm % 10 == 0 && mm > 0 && labelHeight >= 6 {
                            let labelX = x + tickWidth + 2
                            let labelWidth = labelHeight * 3
                            if labelX + labelWidth <= w {
                                elements.append(.text(x: labelX, y: y + longTick + 1, width: labelWidth,
                                                      height: labelHeight, value: String(mm)))
                            }
                        }
                    }
                }
            }
            y += height + gap
        }
        return Layout(widthDots: w, heightDots: h, elements: elements, parts: ranges)
    }

    /// ZPL des Testmusters.
    static func zpl(_ layout: Layout) -> String {
        var lines = ["^XA", "^CI28", "^PW\(layout.widthDots)", "^LL\(layout.heightDots)", "^LH0,0"]
        for element in layout.elements {
            switch element {
            case let .box(x, y, width, height, thickness):
                lines.append("^FO\(x),\(y)^GB\(width),\(height),\(thickness)^FS")
            case let .text(x, y, width, height, value):
                let text = sanitize(value)
                guard !text.isEmpty else { continue }
                lines.append("^FO\(x),\(y)^A0N,\(height),\(height)^FB\(width),1,0,L,0^FD\(text)^FS")
            }
        }
        lines.append("^PQ1")
        lines.append("^XZ")
        return lines.joined(separator: "\n")
    }

    /// Entfernt Steuerzeichen sowie `^` und `~`, die ZPL als Befehlsbeginn deuten würde.
    static func sanitize(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "^" && scalar != "~"
        }
        var result = String(String.UnicodeScalarView(scalars))
        if result.count > 120 { result = String(result.prefix(120)) }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

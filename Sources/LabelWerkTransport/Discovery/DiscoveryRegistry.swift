import Foundation

/// Führt Funde aller Quellen zusammen: Jeder Drucker erscheint einmal – erkannt an derselben
/// Verbindung (`id`), derselben Seriennummer des Druckers, derselben Seriennummer des Druckservers bzw.
/// MAC-Adresse (Zebra-Suche) oder (bei Netzwerkdruckern) derselben Adresse. Die Nummernarten werden
/// nie miteinander verglichen.
///
/// Bringt ein späterer Fund **bessere** Angaben zum selben Gerät (z. B. die Zebra-Suche nach dem
/// Netzwerk-Scan, der das Gerät mangels SNMP nicht erkennen konnte), wird der vorhandene Eintrag
/// ergänzt: Kennung und Verbindung bleiben, Name, Modellhinweis, Quelle und Details werden
/// übernommen (`Outcome.updated`). Sonst bleibt der erste Fund (`Outcome.duplicate`).
public struct DiscoveryRegistry: Sendable {
    public enum Outcome: Equatable, Sendable {
        case added(DiscoveredPrinter)
        case updated(DiscoveredPrinter)
        case duplicate

        /// Der neue bzw. ergänzte Eintrag (`nil` bei Duplikaten).
        public var printer: DiscoveredPrinter? {
            switch self {
            case .added(let printer), .updated(let printer): return printer
            case .duplicate: return nil
            }
        }
    }

    /// Einträge in der Reihenfolge ihres ersten Auftretens.
    public private(set) var printers: [DiscoveredPrinter] = []
    private var indexByID: [String: Int] = [:]
    private var idBySerial: [String: String] = [:]
    private var idByPrintServerSerial: [String: String] = [:]
    private var idByMAC: [String: String] = [:]
    private var idByHost: [String: String] = [:]

    public init() {}

    public init(_ printers: [DiscoveredPrinter]) {
        for printer in printers { insert(printer) }
    }

    public func printer(id: String) -> DiscoveredPrinter? {
        indexByID[id].map { printers[$0] }
    }

    /// Fügt einen Fund hinzu bzw. ergänzt den vorhandenen Eintrag desselben Geräts.
    @discardableResult
    public mutating func insert(_ printer: DiscoveredPrinter) -> Outcome {
        guard let existingID = matchingID(for: printer), let index = indexByID[existingID] else {
            let index = printers.count
            printers.append(printer)
            indexByID[printer.id] = index
            register(printer, as: printer.id)
            return .added(printer)
        }
        let existing = printers[index]
        guard Self.identificationRank(printer) > Self.identificationRank(existing) else {
            // Gleichwertig: nur fehlende Schlüssel (Seriennummer, MAC …) für spätere Vergleiche merken.
            register(printer, as: existingID)
            return .duplicate
        }
        let merged = Self.merged(existing: existing, with: printer)
        printers[index] = merged
        register(merged, as: existingID)
        return .updated(merged)
    }

    /// Kennung des vorhandenen Eintrags desselben Geräts: gleiche `id`, dann gleiche Seriennummer des
    /// Druckers, dann gleiche Seriennummer des Druckservers, dann gleiche MAC-Adresse, dann (Netzwerk)
    /// gleiche Adresse.
    public func matchingID(for printer: DiscoveredPrinter) -> String? {
        if indexByID[printer.id] != nil { return printer.id }
        if let serial = Self.serialKey(printer), let id = idBySerial[serial] { return id }
        if let serial = Self.printServerSerialKey(printer), let id = idByPrintServerSerial[serial] { return id }
        if let mac = Self.macKey(printer), let id = idByMAC[mac] { return id }
        if let host = Self.hostKey(printer), let id = idByHost[host] { return id }
        return nil
    }

    private mutating func register(_ printer: DiscoveredPrinter, as id: String) {
        if let serial = Self.serialKey(printer), idBySerial[serial] == nil { idBySerial[serial] = id }
        if let serial = Self.printServerSerialKey(printer), idByPrintServerSerial[serial] == nil {
            idByPrintServerSerial[serial] = id
        }
        if let mac = Self.macKey(printer), idByMAC[mac] == nil { idByMAC[mac] = id }
        if let host = Self.hostKey(printer), idByHost[host] == nil { idByHost[host] = id }
    }

    // MARK: Regeln

    /// Wie sicher ein Fund als Zebra-Drucker erkannt ist: 3 = Antwort auf die Zebra-Suche,
    /// 2 = SNMP/`~HI`, Bonjour, USB, CUPS, Bluetooth, 1 = offener Port ohne Identifikation.
    public static func identificationRank(_ printer: DiscoveredPrinter) -> Int {
        let identifiedBy = printer.details["identifiedBy"]?.lowercased() ?? ""
        if printer.source == .zebra || identifiedBy.split(separator: "+").contains("zebra") { return 3 }
        if printer.source == .network && identifiedBy.isEmpty { return 1 }
        return 2
    }

    /// Vorhandener Eintrag, ergänzt um die Angaben des besseren Funds (Kennung und Verbindung bleiben).
    public static func merged(existing: DiscoveredPrinter, with better: DiscoveredPrinter) -> DiscoveredPrinter {
        var details = existing.details
        for (key, value) in better.details where key != "host" && key != "port" { details[key] = value }
        let existingMethods = existing.details["identifiedBy"].map { $0.split(separator: "+").map(String.init) } ?? []
        let betterMethods = better.details["identifiedBy"].map { $0.split(separator: "+").map(String.init) } ?? []
        var methods: [String] = []
        for method in betterMethods + existingMethods where !methods.contains(method) { methods.append(method) }
        if !methods.isEmpty { details["identifiedBy"] = methods.joined(separator: "+") }
        let host: String? = {
            if case .tcp(let host, _) = existing.descriptor { return host }
            return nil
        }()
        // Allgemeine Namen („10.62.13.19“, „Zebra 10.62.13.19“, „Zebra ZD421“) weichen einem
        // eigenen Namen (Bonjour-Dienst, SNMP-`sysName`, Systemname) – nie umgekehrt.
        func isGeneric(_ name: String) -> Bool { name == host || name.hasPrefix("Zebra ") }
        let name = isGeneric(better.name) && !isGeneric(existing.name) ? existing.name : better.name
        return DiscoveredPrinter(
            id: existing.id,
            name: name,
            modelHint: better.modelHint ?? existing.modelHint,
            descriptor: existing.descriptor,
            source: better.source,
            details: details
        )
    }

    /// Seriennummer des Druckers (Großbuchstaben, ohne Leerraum) oder `nil`.
    static func serialKey(_ printer: DiscoveredPrinter) -> String? {
        guard let serial = printer.details["serialNumber"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serial.isEmpty else { return nil }
        return serial.uppercased()
    }

    /// Seriennummer des Druckservers (Zebra-Suche) oder `nil`.
    static func printServerSerialKey(_ printer: DiscoveredPrinter) -> String? {
        guard let serial = printer.details["printServerSerial"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serial.isEmpty else { return nil }
        return serial.uppercased()
    }

    /// MAC-Adresse (zwölf Hex-Ziffern, Großbuchstaben) oder `nil` (auch für 00…00 bzw. FF…FF).
    public static func macKey(_ text: String?) -> String? {
        let hex = (text ?? "").uppercased().filter(\.isHexDigit)
        guard hex.count == 12, hex != "000000000000", hex != "FFFFFFFFFFFF" else { return nil }
        return hex
    }

    static func macKey(_ printer: DiscoveredPrinter) -> String? {
        macKey(printer.details["macAddress"])
    }

    /// Adresse eines Netzwerkdruckers (klein geschrieben, ohne eckige Klammern) oder `nil`.
    static func hostKey(_ printer: DiscoveredPrinter) -> String? {
        guard case .tcp(let host, _) = printer.descriptor else { return nil }
        var normalized = host.lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") { normalized = String(normalized.dropFirst().dropLast()) }
        return normalized.isEmpty ? nil : normalized
    }
}

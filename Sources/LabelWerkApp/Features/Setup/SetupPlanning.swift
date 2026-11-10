import Foundation
import LabelWerkKit

// Reine Logik der Druckerinstallation (ohne SwiftUI/AppKit/CUPS-Aufrufe): Erkennung aus
// Suchhinweisen, Warteschlangennamen, Vergleich von Geräte-URIs, Namensvorschläge und Prüfungen.
// Wird von `PrinterInstallService` und dem Installationsassistenten verwendet.

// MARK: - Erkennung

/// Woher das Modell eines Druckers stammt – bestimmt die angezeigte Sicherheit der Erkennung.
enum PrinterDetectionSource: String, Equatable, Sendable {
    /// Der Drucker hat sein Modell selbst gemeldet (`~HI` bzw. SGD `device.product_name`).
    case printer
    /// Netzwerksuche: SNMP-Systembeschreibung (ggf. mit `~HI`).
    case snmp
    /// USB-Produktname (Zebra-Hersteller-ID).
    case usb
    /// Bonjour-Dienst (Produktangabe im TXT-Eintrag bzw. Dienstname).
    case bonjour
    /// Nicht erkannt – das Modell muss gewählt werden.
    case none

    /// Sicherheit der Zuordnung 0…1 (für die Ringanzeige).
    var confidence: Double {
        switch self {
        case .printer: return 1.0
        case .snmp: return 0.9
        case .usb: return 0.85
        case .bonjour: return 0.75
        case .none: return 0
        }
    }

    var title: String {
        switch self {
        case .printer: return tr("Vom Drucker gemeldet")
        case .snmp: return tr("Per SNMP erkannt")
        case .usb: return tr("Aus der USB-Gerätekennung")
        case .bonjour: return tr("Aus der Bonjour-Anmeldung")
        case .none: return tr("Nicht erkannt")
        }
    }
}

/// Ob ein Netzwerkgerät nachweislich ein Zebra-Drucker ist. Nur dann darf LabelWerk ihm von sich
/// aus Abfragen wie `~HI` senden – ein Bürodrucker an Port 9100 würde sie als Textseite drucken.
enum PrinterZebraCheck: Equatable, Sendable {
    /// Zebra-Drucker (USB-Hersteller-ID, Bonjour-Filter, SNMP oder eigene Antwort).
    case confirmed
    /// Das Gerät meldet sich per SNMP als anderes Gerät (Systembeschreibung).
    case notZebra(String)
    /// Keine Aussage möglich (kein SNMP, andere Community …).
    case unverified
}

/// Ergebnis der Druckererkennung im Installationsassistenten.
struct PrinterDetection: Equatable, Sendable {
    var descriptor: ConnectionDescriptor
    /// Verbindung geprüft und erreichbar.
    var reachable: Bool = false
    /// Dauer des Verbindungsaufbaus in Millisekunden (nil = nicht gemessen).
    var latencyMS: Int?
    /// Fehlermeldung der Erreichbarkeitsprüfung.
    var connectionError: String?
    var source: PrinterDetectionSource = .none
    var zebraCheck: PrinterZebraCheck = .unverified
    /// Katalog-ID des erkannten Modells.
    var modelID: String?
    /// Rohname des Modells (z. B. „ZTC ZD421-203dpi ZPL“), auch wenn der Katalog ihn nicht kennt.
    var rawModel: String?
    var resolution: Resolution?
    var languages: [PrinterLanguage] = []
    var friendlyName: String?
    var serialNumber: String?
    var firmware: String?
    /// Standort aus der Bonjour-Anmeldung (`note`).
    var location: String?
    /// Die Abfrage beim Drucker wurde versucht, schlug aber fehl.
    var identifyError: String?
    /// Beim Drucker wurde nicht nachgefragt, weil er nicht als Zebra-Drucker bestätigt ist.
    var queryWithheld = false

    /// Das Modell darf beim Drucker abgefragt werden (ohne Rückfrage).
    var mayQueryPrinter: Bool { zebraCheck == .confirmed }
}

// MARK: - Planung

enum PrinterSetupPlanning {
    /// Höchstlänge eines CUPS-Warteschlangennamens.
    static let maxQueueNameLength = 127

    // MARK: Erkennung aus Suchhinweisen

    /// Startwerte der Erkennung aus einem Suchtreffer (ohne Netzwerkzugriff).
    static func detection(from printer: DiscoveredPrinter?, descriptor: ConnectionDescriptor,
                          catalog: ModelCatalog = .shared) -> PrinterDetection {
        var detection = PrinterDetection(descriptor: descriptor)
        guard let printer else {
            // USB-Geräte stammen immer von Zebra (Hersteller-ID); Netzwerkadressen sind offen.
            if case .usb(let device) = descriptor {
                detection.zebraCheck = .confirmed
                apply(hint: device.productName, source: .usb, to: &detection, catalog: catalog)
            }
            return detection
        }
        detection.location = nonEmpty(printer.details["location"])
        switch printer.source {
        case .usb:
            detection.zebraCheck = .confirmed
            apply(hint: printer.modelHint, source: .usb, to: &detection, catalog: catalog)
        case .bonjour:
            // Die Bonjour-Suche liefert nur Geräte, die sich als Zebra anmelden.
            detection.zebraCheck = .confirmed
            apply(hint: printer.modelHint ?? printer.name, source: .bonjour, to: &detection, catalog: catalog)
        case .network:
            if let identifiedBy = printer.details["identifiedBy"], !identifiedBy.isEmpty {
                let description = printer.details["sysDescr"] ?? printer.modelHint ?? ""
                if identifiedBy.lowercased().contains("hi") || ZebraIdentifiers.looksLikeZebra(description) {
                    detection.zebraCheck = .confirmed
                    apply(hint: printer.modelHint, source: .snmp, to: &detection, catalog: catalog)
                } else if !description.isEmpty {
                    detection.zebraCheck = .notZebra(description)
                }
            }
            if let sysName = nonEmpty(printer.details["sysName"]) { detection.friendlyName = sysName }
        case .cups, .bluetooth, .ble:
            // Nicht Teil des Assistenten (nur Netzwerk und USB): nur den Rohnamen merken.
            detection.rawModel = nonEmpty(printer.modelHint)
        }
        if let dpmm = printer.details["dotsPerMM"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           let resolution = Resolution(dotsPerMM: dpmm) {
            detection.resolution = resolution
        }
        if let firmware = nonEmpty(printer.details["firmware"]) { detection.firmware = firmware }
        return detection
    }

    /// Übernimmt einen Produktnamen als Modellhinweis.
    static func apply(hint: String?, source: PrinterDetectionSource, to detection: inout PrinterDetection,
                      catalog: ModelCatalog = .shared) {
        guard let hint = nonEmpty(hint) else { return }
        detection.rawModel = hint
        if let model = catalog.match(productName: hint) {
            detection.modelID = model.id
            detection.source = source
            if detection.languages.isEmpty { detection.languages = model.languages }
        }
        if let resolution = resolution(fromHint: hint) { detection.resolution = resolution }
    }

    /// Übernimmt die Antwort des Druckers (`PrinterClient.identify()`).
    static func apply(identity: PrinterIdentity, to detection: inout PrinterDetection) {
        detection.zebraCheck = .confirmed
        detection.identifyError = nil
        detection.queryWithheld = false
        if let raw = nonEmpty(identity.model) { detection.rawModel = raw }
        if let id = identity.matchedModelID {
            detection.modelID = id
            detection.source = .printer
        }
        if let resolution = identity.resolution { detection.resolution = resolution }
        if !identity.languages.isEmpty { detection.languages = identity.languages }
        if let name = nonEmpty(identity.friendlyName) { detection.friendlyName = name }
        if let serial = nonEmpty(identity.serialNumber) { detection.serialNumber = serial }
        if let firmware = nonEmpty(identity.firmware) { detection.firmware = firmware }
    }

    /// Liest die Auflösung aus Hinweisen wie „ZD421-300dpi“ (wie `AppModel.resolution(fromHint:)`).
    static func resolution(fromHint hint: String?) -> Resolution? {
        guard let hint = hint?.lowercased() else { return nil }
        for resolution in Resolution.allCases.reversed()
        where hint.contains("\(resolution.dpi)dpi") || hint.contains("\(resolution.dpi) dpi") {
            return resolution
        }
        return nil
    }

    // MARK: Modell, Auflösung, Sprache, Etikett

    /// Auflösung, die zum Modell passt (Erkennung bevorzugt, sonst 203 dpi bzw. die erste).
    static func resolution(preferred: Resolution?, current: Resolution, model: PrinterModel?) -> Resolution {
        let supported = model?.supportedResolutions ?? []
        let options = supported.isEmpty ? Resolution.allCases : supported
        if let preferred, options.contains(preferred) { return preferred }
        if options.contains(current) { return current }
        return options.contains(.dpi203) ? .dpi203 : (options.first ?? .dpi203)
    }

    /// Druckersprache, die zum Modell passt. Hat der Drucker Sprachen gemeldet, gewinnt die
    /// Standardsprache des Modells, sofern er sie beherrscht, sonst die erste gemeldete. Ohne
    /// Meldung bleibt die aktuelle Wahl, solange das Modell sie kennt.
    static func language(preferred: [PrinterLanguage], current: PrinterLanguage, model: PrinterModel?) -> PrinterLanguage {
        let supported = model?.languages ?? []
        let options = supported.isEmpty ? PrinterLanguage.allCases : supported
        if !preferred.isEmpty {
            if let model, preferred.contains(model.defaultLanguage), options.contains(model.defaultLanguage) {
                return model.defaultLanguage
            }
            if preferred.contains(current), options.contains(current) { return current }
            if let first = preferred.first(where: { options.contains($0) }) { return first }
        }
        if options.contains(current) { return current }
        return model?.defaultLanguage ?? options.first ?? .zpl
    }

    /// Etikettenformate, die auf das Modell passen (sonst alle).
    static func fittingStocks(for model: PrinterModel?, in stocks: [LabelStock]) -> [LabelStock] {
        guard let model else { return stocks }
        let fitting = stocks.filter { $0.widthMM <= model.printWidthMM + 2 && $0.heightMM <= model.maxLabelLengthMM }
        return fitting.isEmpty ? stocks : fitting
    }

    /// Etikett, das zum Modell passt: das aktuelle, sonst das Standardformat des Modells, sonst das erste.
    static func preferredStockID(current: String, model: PrinterModel?, stocks: [LabelStock]) -> String {
        let fitting = fittingStocks(for: model, in: stocks)
        if fitting.contains(where: { $0.id == current }) { return current }
        if let model, fitting.contains(where: { $0.id == model.defaultStock }) { return model.defaultStock }
        return fitting.first?.id ?? current
    }

    // MARK: Namen

    /// Vorschlag für den Druckernamen in macOS, z. B. „Zebra ZD421t (Lager)“ – eindeutig gegenüber
    /// `taken` (Groß-/Kleinschreibung zählt nicht).
    static func suggestedName(modelName: String?, location: String, fallback: String, taken: [String]) -> String {
        let base = nonEmpty(modelName) ?? fallback
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = place.isEmpty ? base : "\(base) (\(place))"
        return uniqueDisplayName(name, taken: taken)
    }

    /// Hängt bei Bedarf „ 2“, „ 3“ … an.
    static func uniqueDisplayName(_ name: String, taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        var index = 2
        while lowered.contains("\(name) \(index)".lowercased()) { index += 1 }
        return "\(name) \(index)"
    }

    /// Eindeutiger CUPS-Warteschlangenname. `base` ist bereits bereinigt
    /// (`CUPSService.sanitizedQueueName`). CUPS unterscheidet nicht zwischen Groß- und
    /// Kleinschreibung: „Lager“ und „lager“ wären dieselbe Warteschlange – `lpadmin -p` würde dann
    /// die eines anderen Druckers umschreiben. Mit `reusing` darf genau diese vorhandene
    /// Warteschlange weiterverwendet werden.
    static func uniqueQueueName(_ base: String, taken: [String], reusing: String? = nil) -> String {
        if let reusing, taken.contains(reusing) { return reusing }
        let trimmed = String(base.prefix(maxQueueNameLength))
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(trimmed.lowercased()) else { return trimmed }
        var index = 2
        while true {
            let suffix = "_\(index)"
            let candidate = String(trimmed.prefix(maxQueueNameLength - suffix.count)) + suffix
            if !lowered.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    // MARK: Geräte-URIs

    /// Wie eine vorhandene Warteschlange zum Gerät passt.
    enum QueueMatch: Equatable, Sendable {
        /// Dieselbe Geräte-URI (gleiches Gerät, gleiches Protokoll, gleicher Port).
        case exact
        /// Gleicher Host, aber anderes Protokoll oder anderer Port (z. B. `lpd://` oder `ipp://`).
        case sameHost
    }

    /// Schema, Host (klein, ohne eckige Klammern) und Port einer Geräte-URI.
    static func endpoint(ofDeviceURI uri: String) -> (scheme: String, host: String, port: Int?)? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<range.lowerBound].lowercased()
        var rest = String(trimmed[range.upperBound...])
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<end])
        }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        var host: String
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let remainder = rest[rest.index(after: close)...]
            if remainder.hasPrefix(":") { port = Int(remainder.dropFirst()) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...])
        } else {
            host = rest
        }
        host = (host.removingPercentEncoding ?? host).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return (scheme, host, port)
    }

    /// Vergleicht die Geräte-URI einer vorhandenen Warteschlange mit der des Druckers.
    ///
    /// `serviceName` ist der Bonjour-Name des Druckers (falls per Bonjour gefunden): Damit werden
    /// auch Warteschlangen erkannt, die „Drucker & Scanner“ über den Bonjour-Eintrag angelegt hat
    /// (`dnssd://…`).
    static func queueMatch(queueURI: String, deviceURI: String, serviceName: String? = nil) -> QueueMatch? {
        let lhs = queueURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = deviceURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
        func decoded(_ text: String) -> String {
            var value = (text.removingPercentEncoding ?? text).lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        if decoded(lhs) == decoded(rhs) { return .exact }
        if let serviceName = nonEmpty(serviceName), let match = dnssdMatch(queueURI: lhs, serviceName: serviceName) {
            return match
        }
        guard let a = endpoint(ofDeviceURI: lhs), let b = endpoint(ofDeviceURI: rhs) else { return nil }
        // USB-URIs nennen Hersteller/Modell statt eines Hosts; dort zählt nur die exakte URI.
        let networkSchemes: Set<String> = ["socket", "lpd", "ipp", "ipps", "http", "https"]
        guard networkSchemes.contains(a.scheme), networkSchemes.contains(b.scheme), a.host == b.host else { return nil }
        if a.scheme == "socket" && b.scheme == "socket" {
            return (a.port ?? ZebraIdentifiers.rawPort) == (b.port ?? ZebraIdentifiers.rawPort) ? .exact : .sameHost
        }
        return .sameHost
    }

    /// Bonjour-Warteschlange des Druckers? „Drucker & Scanner“ legt per Bonjour gefundene Drucker
    /// mit einer URI wie `dnssd://Zebra%20ZD421._pdl-datastream._tcp.local./?uuid=…` an – der
    /// Dienstname steht vor dem Diensttyp (Punkte und Backslashes darin maskiert DNS-SD mit `\`).
    /// Derselbe Rohdatendienst (`_pdl-datastream`, Port 9100) gilt als exakt, andere Dienste des
    /// Druckers (`_ipp`, `_printer` …) als gleicher Host.
    static func dnssdMatch(queueURI: String, serviceName: String) -> QueueMatch? {
        let trimmed = queueURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://"), trimmed[..<range.lowerBound].lowercased() == "dnssd" else { return nil }
        var rest = String(trimmed[range.upperBound...])
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<end])
        }
        let host = (rest.removingPercentEncoding ?? rest).lowercased()
        let name = serviceName.lowercased()
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.")
        for candidate in [escaped, name] where host.hasPrefix(candidate + ".") {
            // Nach dem Dienstnamen muss der Diensttyp folgen („_pdl-datastream._tcp…“) – sonst wäre
            // es ein anderer Drucker, dessen Name nur gleich beginnt.
            let serviceType = host.dropFirst(candidate.count + 1)
            guard serviceType.hasPrefix("_") else { continue }
            return serviceType.hasPrefix("_pdl-datastream.") ? .exact : .sameHost
        }
        return nil
    }

    /// Ist `fileName` eine allgemeine PPD (ohne eigenes Modell)?
    static func isGenericPPD(_ fileName: String) -> Bool {
        fileName.lowercased().contains("-generic-")
    }

    // MARK: Netzwerk

    /// IPv4-Adresse als Zahl (nil, wenn keine gültige Punktschreibweise).
    static func ipv4Value(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let byte = UInt32(part), byte <= 255 else { return nil }
            value = (value << 8) | byte
        }
        return value
    }

    /// Liegt `host` in einem der lokalen IPv4-Subnetze? nil = nicht beurteilbar (Hostname, IPv6,
    /// keine Schnittstelle).
    static func isInLocalSubnet(host: String, interfaces: [NetworkInterfaceInfo]) -> Bool? {
        guard let address = ipv4Value(host) else { return nil }
        let usable = interfaces.compactMap { info -> (UInt32, UInt32)? in
            guard let local = ipv4Value(info.address), let mask = ipv4Value(info.netmask), mask != 0 else { return nil }
            return (local, mask)
        }
        guard !usable.isEmpty else { return nil }
        return usable.contains { local, mask in (local & mask) == (address & mask) }
    }

    // MARK: Fehlertexte

    /// Meldet `lpadmin`/`osascript` einen abgebrochenen Passwortdialog (Fehler −128)?
    static func isAdministratorCancellation(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("-128") || lower.contains("user canceled") || lower.contains("user cancelled")
            || lower.contains("abgebrochen")
    }

    // MARK: Hilfen

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

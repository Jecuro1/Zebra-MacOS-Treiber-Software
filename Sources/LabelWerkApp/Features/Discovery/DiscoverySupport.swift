import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Suchquellen (Anzeige)

/// Deutsche Bezeichnungen, Symbole und Farben der Suchquellen.
///
/// Bewusst als eigener Namensraum statt einer Erweiterung von `DiscoverySource`, damit es keine
/// Mehrdeutigkeit mit eventuellen Erweiterungen des Transport-Moduls gibt.
enum DiscoverySourceStyle {
    /// Reihenfolge der Schalter in der Oberfläche.
    static let ordered: [DiscoverySource] = [.bonjour, .usb, .network, .cups, .bluetooth, .ble]

    /// Standardauswahl: schnelle Quellen ohne Systemabfrage (Bluetooth fragt nach Erlaubnis).
    static let defaultSources: Set<DiscoverySource> = [.bonjour, .usb, .network, .cups]

    static func title(_ source: DiscoverySource) -> String {
        switch source {
        case .bonjour: return tr("Bonjour")
        case .usb: return tr("USB")
        case .network: return tr("Netzwerk-Scan")
        case .cups: return tr("macOS-Warteschlangen")
        case .bluetooth: return tr("Bluetooth")
        case .ble: return tr("Bluetooth LE")
        }
    }

    static func detail(_ source: DiscoverySource) -> String {
        switch source {
        case .bonjour: return tr("Netzwerkdrucker, die sich per Bonjour (mDNS) melden")
        case .usb: return tr("Direkt per USB angeschlossene Zebra-Drucker")
        case .network: return tr("Durchsucht das lokale Subnetz nach Port 9100 (RAW)")
        case .cups: return tr("Bereits in macOS eingerichtete Etikettendrucker")
        case .bluetooth: return tr("Klassisches Bluetooth (SPP), z. B. mobile ZQ-Drucker")
        case .ble: return tr("Bluetooth Low Energy (Link-OS-Drucker)")
        }
    }

    static func systemImage(_ source: DiscoverySource) -> String {
        switch source {
        case .bonjour: return "bonjour"
        case .usb: return "cable.connector"
        case .network: return "network"
        case .cups: return "printer.filled.and.paper"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .ble: return "dot.radiowaves.right"
        }
    }

    static func tint(_ source: DiscoverySource) -> Color {
        switch source {
        case .bonjour: return Theme.teal
        case .usb: return Theme.violet
        case .network: return Theme.printing
        case .cups: return Theme.indigo
        case .bluetooth: return Theme.magenta
        case .ble: return Theme.warning
        }
    }

    /// Erwartete Suchdauer in Sekunden (Subnetz-Scan und Bluetooth-Inquiry brauchen länger).
    static func duration(for sources: Set<DiscoverySource>) -> Double {
        var seconds = 6.0
        if sources.contains(.network) { seconds = max(seconds, 10) }
        if sources.contains(.bluetooth) || sources.contains(.ble) { seconds = max(seconds, 12) }
        return seconds
    }
}

// MARK: - Suche (Zustand)

/// Steuert eine Druckersuche über `PrinterDiscovery` und sammelt die Ergebnisse.
@Observable
@MainActor
final class DiscoveryController {
    /// Gewählte Quellen (werden auf Wunsch zwischen Starts gemerkt).
    var sources: Set<DiscoverySource> {
        didSet {
            guard persistsSources, sources != oldValue else { return }
            Self.storeSources(sources)
        }
    }

    private(set) var found: [DiscoveredPrinter] = []
    private(set) var isScanning = false
    /// Quellen der laufenden Suche (leer, wenn keine läuft).
    private(set) var activeSources: Set<DiscoverySource> = []
    private(set) var startedAt: Date?
    private(set) var duration: Double = 8
    /// Anzahl abgeschlossener Suchläufe.
    private(set) var scanCount = 0
    private(set) var lastFinishedAt: Date?
    /// Verzögerung je Treffer für das gestaffelte Einfliegen der Karten.
    private(set) var appearanceDelays: [String: Double] = [:]

    private let persistsSources: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discovery: PrinterDiscovery?
    @ObservationIgnored private var lastInsertion: Date?
    @ObservationIgnored private var lastDelay: Double = 0
    @ObservationIgnored private var generation = 0

    private static let sourcesKey = "LabelWerk.discovery.sources"

    init(sources: Set<DiscoverySource>? = nil, persistsSources: Bool = true) {
        self.persistsSources = persistsSources
        self.sources = sources ?? (persistsSources ? Self.loadSources() : DiscoverySourceStyle.defaultSources)
    }

    /// Fortschritt 0…1 der laufenden Suche zum Zeitpunkt `date`.
    func progress(at date: Date) -> Double {
        guard isScanning, let startedAt else { return 0 }
        return min(1, max(0, date.timeIntervalSince(startedAt) / max(duration, 0.1)))
    }

    func count(for source: DiscoverySource) -> Int {
        found.reduce(0) { $0 + ($1.source == source ? 1 : 0) }
    }

    /// `true`, wenn gerade eine Suche über mindestens eine der Quellen läuft.
    func isScanningAny(of candidates: Set<DiscoverySource>) -> Bool {
        isScanning && !activeSources.isDisjoint(with: candidates)
    }

    /// Startet eine neue Suche (eine laufende wird beendet). `override` ersetzt die gewählten Quellen.
    func start(sources override: Set<DiscoverySource>? = nil) {
        // Ohne Quellen nichts tun – vor allem eine laufende Suche nicht abbrechen, ohne sie zu beenden
        // (sonst bliebe `isScanning` hängen und das Radar liefe weiter).
        let selected = override ?? sources
        guard !selected.isEmpty else { return }
        cancelRunningTask()
        let currentGeneration = generation
        let seconds = DiscoverySourceStyle.duration(for: selected)
        found = []
        appearanceDelays = [:]
        lastInsertion = nil
        lastDelay = 0
        duration = seconds
        startedAt = Date()
        activeSources = selected
        isScanning = true

        let discovery = PrinterDiscovery()
        self.discovery = discovery
        let stream = discovery.discover(sources: selected, timeout: .seconds(seconds))
        task = Task { [weak self] in
            for await printer in stream {
                guard !Task.isCancelled, let self else { break }
                self.insert(printer)
            }
            guard let self, self.generation == currentGeneration else { return }
            self.finish()
        }
    }

    /// Beendet die Suche vorzeitig; bisherige Treffer bleiben erhalten.
    func stop() {
        guard isScanning else { return }
        cancelRunningTask()
        finish()
    }

    private func cancelRunningTask() {
        // Neue Generation: Ein abgebrochener Suchlauf meldet sein Ende nicht mehr.
        generation += 1
        task?.cancel()
        task = nil
        discovery = nil
    }

    private func finish() {
        isScanning = false
        activeSources = []
        startedAt = nil
        scanCount += 1
        lastFinishedAt = Date()
        discovery = nil
        task = nil
    }

    private func insert(_ printer: DiscoveredPrinter) {
        if let index = found.firstIndex(where: { $0.id == printer.id }) {
            found[index] = printer
            return
        }
        // Treffer, die kurz nacheinander eintreffen, fliegen gestaffelt ein.
        let now = Date()
        var delay = 0.0
        if let last = lastInsertion, now.timeIntervalSince(last) < 0.2 {
            delay = min(lastDelay + 0.07, 0.6)
        }
        lastInsertion = now
        lastDelay = delay
        appearanceDelays[printer.id] = delay
        found.append(printer)
    }

    // MARK: Gemerkte Quellen

    private static func loadSources() -> Set<DiscoverySource> {
        guard let stored = UserDefaults.standard.array(forKey: sourcesKey) as? [String] else {
            return DiscoverySourceStyle.defaultSources
        }
        let parsed = Set(stored.compactMap(DiscoverySource.init(rawValue:)))
        return parsed.isEmpty ? DiscoverySourceStyle.defaultSources : parsed
    }

    private static func storeSources(_ sources: Set<DiscoverySource>) {
        UserDefaults.standard.set(sources.map(\.rawValue).sorted(), forKey: sourcesKey)
    }
}

// MARK: - Modellzuordnung

enum DiscoveryMatcher {
    /// Katalogmodell anhand des Modellhinweises (wie `AppModel.addPrinter(from:)`).
    static func model(for printer: DiscoveredPrinter) -> PrinterModel? {
        guard let hint = printer.modelHint, !hint.isEmpty else { return nil }
        return ModelCatalog.shared.match(productName: hint)
    }

    /// Katalogmodell zu einer macOS-Warteschlange (Geräte-URI bzw. Hersteller/Modell).
    static func model(for queue: CUPSQueueInfo) -> PrinterModel? {
        if let hint = CUPSQueueLister.modelHint(fromDeviceURI: queue.deviceURI),
           let match = ModelCatalog.shared.match(productName: hint) {
            return match
        }
        if let makeAndModel = queue.makeAndModel {
            return ModelCatalog.shared.match(productName: makeAndModel)
        }
        return nil
    }

    /// Kurze Beschreibung „Zebra ZD421t · 300 dpi“ für Karten.
    @MainActor
    static func modelLine(for printer: DiscoveredPrinter) -> String? {
        guard let model = model(for: printer) else { return nil }
        if let resolution = AppModel.resolution(fromHint: printer.modelHint) {
            return "\(model.displayName) · \(resolution.displayName)"
        }
        let dpis = model.supportedResolutions.map { String($0.dpi) }.joined(separator: "/")
        return dpis.isEmpty ? model.displayName : "\(model.displayName) · \(dpis) dpi"
    }
}

// MARK: - Erreichbarkeit

enum DiscoveryReachability: Equatable {
    case idle
    case checking
    case reachable(milliseconds: Int)
    case unreachable(String)
}

enum DiscoveryProbe {
    /// Öffnet kurz eine TCP-Verbindung zum Drucker und schließt sie wieder.
    static func check(host: String, port: Int) async -> DiscoveryReachability {
        let connection = TCPConnection(host: host, port: port, connectTimeout: .seconds(3))
        let start = Date()
        do {
            try await connection.open()
            let elapsed = Int((Date().timeIntervalSince(start) * 1000).rounded())
            await connection.close()
            return .reachable(milliseconds: max(1, elapsed))
        } catch {
            await connection.close()
            if let localized = error as? LocalizedError, let text = localized.errorDescription {
                return .unreachable(text)
            }
            return .unreachable(error.localizedDescription)
        }
    }
}

// MARK: - Eingaben prüfen

enum DiscoveryInput {
    /// Zerlegt Eingaben wie „tcp://192.168.1.20:9100/“ in Host und optionalen Port.
    static func split(_ input: String) -> (host: String, port: Int?) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["tcp://", "socket://", "http://", "https://", "raw://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        while text.hasSuffix("/") { text.removeLast() }
        // IPv6 in eckigen Klammern: [fe80::1]:9100
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) { return (host, port) }
            return (host, nil)
        }
        let colons = text.filter { $0 == ":" }.count
        if colons == 1, let colon = text.firstIndex(of: ":") {
            let host = String(text[..<colon])
            let port = Int(text[text.index(after: colon)...])
            return (host, port)
        }
        return (text, nil)
    }

    /// Plausibler Hostname oder IP-Adresse (keine Leerzeichen, nur erlaubte Zeichen).
    static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:_%"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if host.hasPrefix(".") || host.hasSuffix(".") || host.hasPrefix("-") { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return parts.allSatisfy { (Int($0) ?? 256) <= 255 }
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return true
    }

    /// Normalisiert eine Bluetooth-Adresse zu „AC-3F-A4-12-34-56“ (Schreibweise von IOBluetooth und
    /// `ConnectionDescriptor`, damit gleiche Geräte als gleich erkannt werden; nil bei ungültiger Eingabe).
    static func normalizedBluetoothAddress(_ input: String) -> String? {
        let hex = input.uppercased().filter { $0.isHexDigit }
        let separators = input.filter { !$0.isHexDigit && $0 != " " }
        guard hex.count == 12, separators.allSatisfy({ $0 == ":" || $0 == "-" }) else { return nil }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]))
            index = next
        }
        return pairs.joined(separator: "-")
    }
}

// MARK: - Manuelle Einrichtung

/// Entwurf für das manuelle Hinzufügen eines Druckers.
struct DiscoveryManualDraft: Equatable {
    enum Connection: String, CaseIterable, Identifiable, Hashable {
        case network, queue, usb, bluetooth

        var id: String { rawValue }

        var title: String {
            switch self {
            case .network: return tr("Netzwerk")
            case .queue: return tr("macOS-Warteschlange")
            case .usb: return tr("USB")
            case .bluetooth: return tr("Bluetooth")
            }
        }

        var systemImage: String {
            switch self {
            case .network: return "network"
            case .queue: return "printer.filled.and.paper"
            case .usb: return "cable.connector"
            case .bluetooth: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    var connection: Connection = .network
    var host: String = ""
    var port: Int = 9100
    var queueName: String?
    /// `DiscoveredPrinter.id` eines gefundenen USB-/Bluetooth-Geräts.
    var deviceID: String?
    var bluetoothAddress: String = ""
    var modelID: String?
    var resolution: Resolution = .dpi203
    var language: PrinterLanguage = .zpl
    var stockID: String = "w4h6in"
    var name: String = ""
    var nameEdited = false
    var location: String = ""
    var accentHue: Double = 0.72
}

// MARK: - Akzentfarben

enum DiscoveryAccentPalette {
    static let hues: [Double] = [0.72, 0.55, 0.92, 0.08, 0.36, 0.62, 0.82, 0.14, 0.0, 0.47]

    /// Gleiche Formel wie `PrinterSession.accentColor`.
    static func color(_ hue: Double) -> Color {
        Color(hue: hue, saturation: 0.72, brightness: 0.95)
    }
}

// MARK: - Fähigkeiten (Anzeige)

enum DiscoveryFeatureText {
    static func title(_ feature: PrinterFeature) -> String {
        switch feature {
        case .linkOS: return tr("Link-OS")
        case .sgd: return tr("SGD-Befehle")
        case .rfid: return tr("RFID")
        case .display: return tr("Display")
        case .linerless: return tr("Linerless")
        case .battery: return tr("Akku")
        }
    }
}

// MARK: - Details gefundener Drucker (Anzeige)

/// Lesbare Bezeichnungen und Werte für `DiscoveredPrinter.details` (Schlüssel aus dem Transport-Modul).
enum DiscoveryDetailText {
    /// Anzeigereihenfolge bekannter Schlüssel; unbekannte folgen alphabetisch.
    private static let order: [String] = [
        "name", "sysName", "serviceName", "productName", "makeAndModel", "sysDescr",
        "host", "port", "servicePort", "serviceType", "deviceURI", "isDefault",
        "address", "identifier", "rssi",
        "serialNumber", "vendorID", "productID", "locationID",
        "firmware", "dotsPerMM", "memory", "location", "adminURL", "identifiedBy",
    ]

    /// Schlüssel in sinnvoller Reihenfolge.
    static func sortedKeys(_ details: [String: String]) -> [String] {
        details.keys.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs) ?? Int.max
            let right = order.firstIndex(of: rhs) ?? Int.max
            if left != right { return left < right }
            return lhs < rhs
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case "host": return tr("Adresse")
        case "port": return tr("Port")
        case "servicePort": return tr("Dienst-Port")
        case "serviceName": return tr("Dienstname")
        case "serviceType": return tr("Diensttyp")
        case "sysDescr": return tr("Systembeschreibung (SNMP)")
        case "sysName": return tr("Gerätename (SNMP)")
        case "identifiedBy": return tr("Erkannt über")
        case "firmware": return tr("Firmware")
        case "dotsPerMM": return tr("Auflösung")
        case "memory": return tr("Speicher")
        case "deviceURI": return tr("Geräte-URI")
        case "isDefault": return tr("Standarddrucker")
        case "makeAndModel": return tr("Treiber")
        case "location": return tr("Standort")
        case "adminURL": return tr("Verwaltungsseite")
        case "productName": return tr("Produktname")
        case "productID": return tr("Produkt-ID")
        case "vendorID": return tr("Hersteller-ID")
        case "serialNumber": return tr("Seriennummer")
        case "locationID": return tr("USB-Anschluss")
        case "address": return tr("Bluetooth-Adresse")
        case "name": return tr("Gerätename")
        case "identifier": return tr("Kennung")
        case "rssi": return tr("Signalstärke")
        default: return key
        }
    }

    static func value(for key: String, raw: String) -> String {
        switch key {
        case "isDefault":
            switch raw.lowercased() {
            case "true", "yes", "1": return tr("Ja")
            case "false", "no", "0": return tr("Nein")
            default: return raw
            }
        case "identifiedBy":
            let methods = raw.split(separator: "+").map { part -> String in
                switch part.lowercased() {
                case "snmp": return "SNMP"
                case "hi": return tr("Host-Identifikation (~HI)")
                default: return String(part)
                }
            }
            return methods.joined(separator: " + ")
        case "rssi":
            guard let level = Int(raw.trimmingCharacters(in: .whitespaces)) else { return raw }
            return tr("%d dBm", level)
        case "dotsPerMM":
            guard let dotsPerMM = Int(raw.trimmingCharacters(in: .whitespaces)), dotsPerMM > 0 else { return raw }
            return tr("%d Punkte/mm (%d dpi)", dotsPerMM, dpi(forDotsPerMM: dotsPerMM))
        default:
            return raw
        }
    }

    /// Zebra-Druckköpfe: 6 → 152, 8 → 203, 12 → 300, 24 → 600 dpi.
    static func dpi(forDotsPerMM dotsPerMM: Int) -> Int {
        switch dotsPerMM {
        case 6: return 152
        case 8: return 203
        case 12: return 300
        case 24: return 600
        default: return Int((Double(dotsPerMM) * 25.4).rounded())
        }
    }
}

// MARK: - Geometrie & Hilfen

enum DiscoveryGeometry {
    /// Stabiler FNV-1a-Hash (unabhängig vom Prozessstart, anders als `hashValue`).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Position eines Treffers auf dem Radar: Winkel in Grad (0…360) und Radius-Anteil (0,32…0,86).
    static func polar(for id: String) -> (degrees: Double, radius: Double) {
        let hash = stableHash(id)
        let degrees = Double(hash % 3600) / 10
        let radius = 0.32 + Double((hash >> 20) % 540) / 1000
        return (degrees, radius)
    }
}

/// Einfaches Fließlayout (Umbruch in neue Zeilen), z. B. für Quellenschalter.
struct DiscoveryFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = proposal.width.map { min($0, widest) } ?? widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

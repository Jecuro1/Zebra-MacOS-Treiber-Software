import Foundation
import LabelWerkCore
import LabelWerkImaging
import LabelWerkRender
import LabelWerkStatus
import LabelWerkTransport

/// Vollständig simulierter Link-OS-Drucker (Standard: Zebra ZD421t) – für den Demo-Modus der
/// App, für Tests und für `lwctl virtual-printer`.
///
/// Der virtuelle Drucker ist zugleich Gerät und `PrinterConnection`: Gesendete Bytes werden
/// inkrementell zerlegt (Befehle dürfen auf mehrere Schreibvorgänge verteilt sein) und wie von
/// der Firmware verarbeitet; Antworten stehen anschließend über `read(timeout:)` bereit.
///
/// Verhalten:
/// * `~HS`, `~HI`, `~HQES` (auch `~HQSN`, `~HQHA`, `~HQOD`), `~HM`, `~HD` liefern Antworten im
///   Druckerformat; `^HH` die Konfiguration, `^HW` die Dateiliste, `^HF`/`^HG` gespeicherte
///   Formate bzw. Grafiken.
/// * SGD `getvar`/`setvar`/`do` und JSON `{}{…}` (inkl. `allconfig`) arbeiten auf rund 70
///   Variablen mit Typ, Bereich und Zugriffsrecht; `setvar` prüft Werte und speichert sie.
/// * `~SD`, `~TA`, `~JS`, `^MT`, `^MN`, `^MM`, `^PR`, `^LT`, `^LS`, `^PW`, `^LL`, `^MF`, `^KN`
///   ändern dieselben Einstellungen, `^ST` stellt die Echtzeituhr (`rtc.date`, `rtc.time`); `^JUS` ist ohne Wirkung (alles ist sofort dauerhaft),
///   `^JUF`/`^JUN` laden Werkseinstellungen. `^MD` setzt wie bei der Firmware nur einen
///   Versatz zur gespeicherten Schwärzung (`print.tone` bleibt unverändert, nach einem Neustart
///   gilt wieder 0); `^JS` ist die Sensorwahl und ändert den Rückzug nicht.
/// * Neustart (`~JR`, SGD `device.reset`): Was im selben Datenblock danach folgt, geht verloren;
///   ``VirtualPrinterServer`` trennt die TCP-Verbindung wie ein echter Netzwerkdrucker.
/// * Jedes empfangene `^XA…^XZ`-Format wird mit `ZPLInterpreter` gerendert. Druckende Formate
///   werden „gedruckt“ (``renderedLabels``, höchstens 50) und erhöhen Etikettenzähler und
///   Odometer – solange der Drucker pausiert ist oder ein Fehler vorliegt (Kopf offen, Medium
///   bzw. Farbband leer), warten sie in ``pendingLabels`` und werden danach gedruckt.
/// * `~DG`, `~DY` (Schriften, Grafiken), `^DF` (Formate) speichern Dateien, `^ID` löscht sie;
///   `^XG`/`^IM`/`^XF` finden sie in späteren Formaten wieder.
/// * EPL-Zeilen (bei `device.languages` = `epl_zpl`) und CPCL-Blöcke (Modelle mit CPCL) werden
///   ebenfalls zu Etiketten (Grafiken, Linien, Rahmen, Text).
/// * Fehlerzustände lassen sich lokal (``setHeadOpen(_:)`` …) und über die Leitung mit den
///   Simulationsvariablen `labelwerk.simulation.head_open|media_out|ribbon_out|paused` setzen.
public actor VirtualPrinter: PrinterConnection {

    /// Katalog-ID des Standardmodells.
    public static let defaultModelID = "zd421t"

    /// Höchstzahl gespeicherter gedruckter Etiketten.
    public static let historyLimit = 50

    /// Höchstmenge gespeicherter empfangener Bytes (ältere Daten werden verworfen).
    public static let receivedDataLimit = 16 << 20

    public nonisolated let descriptor: ConnectionDescriptor
    /// Kennung (z. B. `demo`).
    public nonisolated let id: String
    /// Simuliertes Modell.
    public nonisolated let model: PrinterModel
    /// Simulierte Auflösung.
    public nonisolated let resolution: Resolution
    /// Seriennummer (aus der Kennung abgeleitet, stabil).
    public nonisolated let serialNumber: String

    struct Reader {
        let id: UInt64
        let continuation: CheckedContinuation<Data, Error>
        let timer: Task<Void, Never>
    }

    /// Eine Datei im simulierten Speicher.
    struct StoredFile: Sendable {
        var drive: String
        var name: String
        var data: Data
        var bitmap: MonoBitmap?
        var formatText: String?
        var path: String { drive + name }
    }

    // MARK: Verbindung
    var opened = false
    var outbox = Data()
    var readers: [Reader] = []
    var nextReaderID: UInt64 = 0
    var maximumReadChunk: Int?

    // MARK: Empfang
    var stream = VirtualPrinterStream()
    var received = Data()

    // MARK: Gerätezustand
    let identity: VirtualDeviceIdentity
    var store: VirtualSGDStore
    var paused = false
    var headOpen = false
    var mediaOut = false
    var ribbonOut = false
    var simulatedWarnings: PrinterWarningFlags = []
    var calibrationNeeded = false
    var printed: [RenderedLabel] = []
    var queued: [RenderedLabel] = []
    var storedFiles: [String: StoredFile] = [:]
    var bootDate = Date()
    var printLengthMM: Double
    var headCleanMM: Double
    var headNewMM: Double
    var labelCount: Int
    var printInverted = false
    var printMirrored = false
    var backfeed: BackfeedMode = .normal
    /// Schwärzungsversatz aus `^MD` (−30…30) – gilt für alle folgenden Etiketten zusätzlich zur
    /// gespeicherten Schwärzung `print.tone`; beim Einschalten bzw. Neustart 0.
    var relativeDarkness: Double = 0
    /// Anzahl der Neustarts seit dem Erzeugen (`~JR`, `device.reset`).
    var restartCount = 0
    /// Abweichung der Echtzeituhr von der Systemzeit in Sekunden (gestellt per `^ST` bzw. SGD
    /// `rtc.date`/`rtc.time`).
    var clockOffset: TimeInterval = 0
    var jsonEnabled: Bool
    var sgdEnabled: Bool
    var eplPage = EPLPageBuilder()

    // MARK: - Erzeugen

    /// Erzeugt einen virtuellen Drucker.
    ///
    /// - Parameters:
    ///   - id: Kennung; bestimmt Seriennummer und MAC-Adressen (stabil je Kennung).
    ///   - model: Katalogmodell; JSON/`allconfig` nur bei Link-OS-Modellen, SGD bei Link-OS
    ///     bzw. SGD-fähigen Modellen.
    ///   - resolution: Auflösung des Druckkopfs.
    public init(id: String = "demo", model: PrinterModel, resolution: Resolution = .dpi203) {
        self.id = id
        self.model = model
        self.resolution = resolution
        self.descriptor = .virtual(id: id)
        let identity = VirtualDeviceIdentity(id: id, model: model)
        self.identity = identity
        self.serialNumber = identity.serialNumber
        self.store = VirtualSGDStore(model: model, resolution: resolution, identity: identity)
        self.printLengthMM = identity.initialPrintLengthMM
        self.headCleanMM = identity.initialHeadCleanMM
        self.headNewMM = identity.initialPrintLengthMM
        self.labelCount = identity.initialLabelCount
        self.jsonEnabled = model.supports(.linkOS)
        self.sgdEnabled = model.supports(.linkOS) || model.supports(.sgd)
    }

    /// Virtueller Drucker mit dem Standardmodell (ZD421t, 203 dpi).
    public static func makeDefault(id: String = "demo") -> VirtualPrinter {
        let model = ModelCatalog.shared.model(id: defaultModelID) ?? ModelCatalog.shared.models[0]
        return VirtualPrinter(id: id, model: model, resolution: .dpi203)
    }

    /// Erzeugt einen Drucker passend zur Kennung: Ist sie eine Katalog-ID (`zt410`) oder
    /// Katalog-ID mit Auflösung (`zt410-300`, `zt410@300dpi`), wird dieses Modell simuliert,
    /// sonst das Standardmodell ZD421t.
    public static func make(forID id: String) -> VirtualPrinter {
        let catalog = ModelCatalog.shared
        let lower = id.lowercased()
        var modelPart = lower
        var dpi: Int?
        if let separator = lower.lastIndex(where: { $0 == "-" || $0 == "@" }) {
            let suffix = lower[lower.index(after: separator)...].replacingOccurrences(of: "dpi", with: "")
            if let value = Int(suffix) {
                dpi = value
                modelPart = String(lower[..<separator])
            }
        }
        guard let model = catalog.model(id: modelPart) else { return makeDefault(id: id) }
        let resolution = dpi.flatMap(Resolution.init(dpi:)).flatMap { model.supportedResolutions.contains($0) ? $0 : nil }
            ?? (model.supportedResolutions.contains(.dpi203) ? .dpi203 : model.supportedResolutions.first ?? .dpi203)
        return VirtualPrinter(id: id, model: model, resolution: resolution)
    }

    /// Registriert die Fabrik für `.virtual(id:)` bei `ConnectionFactory`.
    ///
    /// Je Kennung gibt es prozessweit genau einen virtuellen Drucker (Dateien, Zähler und
    /// Einstellungen bleiben beim erneuten Verbinden erhalten). Das Modell ergibt sich aus der
    /// Kennung (siehe ``make(forID:)``), Standard ist der ZD421t.
    public static func registerWithConnectionFactory() {
        ConnectionFactory.registerVirtualFactory { id in VirtualPrinterRegistry.shared.printer(for: id) }
    }

    /// Der prozessweit gemeinsame virtuelle Drucker zu einer Kennung.
    public static func shared(id: String) -> VirtualPrinter {
        VirtualPrinterRegistry.shared.printer(for: id)
    }

    // MARK: - PrinterConnection

    public var isOpen: Bool { opened }

    public func open() async throws {
        opened = true
    }

    /// Schließt die Verbindung: wartende Leser erhalten `TransportError.notOpen`, ungelesene
    /// Antworten und unvollständige Befehle werden verworfen. Der Gerätezustand bleibt erhalten.
    public func close() async {
        guard opened else { return }
        opened = false
        outbox.removeAll()
        stream.reset()
        let pending = readers
        readers.removeAll()
        for reader in pending {
            reader.timer.cancel()
            reader.continuation.resume(throwing: TransportError.notOpen)
        }
    }

    public func write(_ data: Data) async throws {
        try Task.checkCancellation()
        guard opened else { throw TransportError.notOpen }
        guard !data.isEmpty else { return }
        appendReceived(data)
        process(data)
        deliver()
    }

    public func read(timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        guard opened else { throw TransportError.notOpen }
        if !outbox.isEmpty { return takeOutput() }
        guard timeout > .zero else { return Data() }
        let readerID = nextReaderID
        nextReaderID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expireReader(readerID)
                }
                readers.append(Reader(id: readerID, continuation: continuation, timer: timer))
            }
        } onCancel: {
            Task { await self.cancelReader(readerID) }
        }
    }

    private func expireReader(_ readerID: UInt64) {
        guard let index = readers.firstIndex(where: { $0.id == readerID }) else { return }
        let reader = readers.remove(at: index)
        reader.continuation.resume(returning: Data())
    }

    private func cancelReader(_ readerID: UInt64) {
        guard let index = readers.firstIndex(where: { $0.id == readerID }) else { return }
        let reader = readers.remove(at: index)
        reader.timer.cancel()
        reader.continuation.resume(throwing: CancellationError())
    }

    /// Übergibt bereitliegende Antworten an wartende Leser.
    func deliver() {
        while !outbox.isEmpty, !readers.isEmpty {
            let reader = readers.removeFirst()
            reader.timer.cancel()
            reader.continuation.resume(returning: takeOutput())
        }
    }

    private func takeOutput() -> Data {
        if let limit = maximumReadChunk, limit > 0, outbox.count > limit {
            let chunk = outbox.prefix(limit)
            outbox.removeFirst(limit)
            return Data(chunk)
        }
        let all = outbox
        outbox = Data()
        return all
    }

    private func appendReceived(_ data: Data) {
        received.append(data)
        if received.count > Self.receivedDataLimit {
            received.removeFirst(received.count - Self.receivedDataLimit)
        }
    }

    /// Antwort an den Host anhängen.
    func respond(_ text: String) {
        outbox.append(contentsOf: Array(text.utf8))
    }

    func respond(_ data: Data) {
        outbox.append(data)
    }

    /// Neue Sitzung (z. B. neuer TCP-Client): verwirft ungelesene Antworten und unvollständige
    /// Befehle der vorherigen Sitzung.
    func beginSession() {
        outbox.removeAll()
        stream.reset()
    }

    // MARK: - Öffentlicher Zustand

    /// Alle empfangenen Bytes (höchstens ``receivedDataLimit``, die neuesten).
    public var receivedData: Data { received }

    /// Gedruckte Etiketten (die letzten ``historyLimit``, älteste zuerst).
    public var renderedLabels: [RenderedLabel] { printed }

    /// Etiketten, die wegen Pause oder Fehler noch auf den Druck warten.
    public var pendingLabels: [RenderedLabel] { queued }

    /// Dateien im simulierten Speicher, sortiert nach Laufwerk und Name.
    public var files: [PrinterFile] {
        storedFiles.values.sorted { ($0.drive, $0.name) < ($1.drive, $1.name) }
            .map { PrinterFile(drive: $0.drive, name: $0.name, size: $0.data.count) }
    }

    /// Inhalt einer gespeicherten Datei (`E:LOGO.GRF`).
    public func fileData(_ path: String) -> Data? {
        storedFiles[path.uppercased()]?.data
    }

    /// Gesamtzahl gedruckter Etiketten (Zählerstand `odometer.total_label_count`).
    public var labelsPrinted: Int { labelCount }

    /// Aktueller Wert einer SGD-Variablen (auch Nur-Schreib-Variablen).
    public func sgdValue(_ name: String) -> String? {
        refreshDynamicValues()
        return store.rawValue(name)
    }

    /// Alle SGD-Werte.
    public var sgdValues: [String: String] {
        refreshDynamicValues()
        return store.values
    }

    /// Aktuelle Zeit der simulierten Echtzeituhr (Systemzeit plus gestellte Abweichung).
    public var clockDate: Date { Date().addingTimeInterval(clockOffset) }

    public var isPaused: Bool { paused }
    public var isHeadOpen: Bool { headOpen }
    public var isMediaOut: Bool { mediaOut }
    public var isRibbonOut: Bool { ribbonOut }

    // MARK: - Simulation

    /// Pause (wie die Pause-Taste bzw. `~PP`/`~PS`). Beim Fortsetzen werden wartende Etiketten gedruckt.
    public func setPaused(_ on: Bool) {
        paused = on
        flushQueue()
    }

    /// Druckkopf geöffnet. Nach dem Schließen werden wartende Etiketten gedruckt.
    public func setHeadOpen(_ on: Bool) {
        headOpen = on
        store.force("head.latch", on ? "open" : "ok")
        flushQueue()
    }

    /// Etiketten aufgebraucht. Nach dem Einlegen werden wartende Etiketten gedruckt.
    public func setMediaOut(_ on: Bool) {
        mediaOut = on
        store.force("media.status", on ? "out" : "ok")
        if on { calibrationNeeded = true }
        flushQueue()
    }

    /// Farbband aufgebraucht (nur im Thermotransfer-Modus ein Fehler).
    public func setRibbonOut(_ on: Bool) {
        ribbonOut = on
        flushQueue()
    }

    /// Zusätzliche Warnungen in `~HQES` (z. B. `cleanPrinthead`, `paperNearEnd`).
    public func setWarnings(_ warnings: PrinterWarningFlags) {
        simulatedWarnings = warnings
    }

    /// Simuliert ältere Firmware ohne JSON-SGD (`false`) bzw. Link-OS (`true`).
    public func setSupportsJSON(_ on: Bool) {
        jsonEnabled = on
    }

    /// Begrenzt die Bytes je `read(timeout:)` (simuliert stückweise eintreffende Antworten);
    /// `nil` = unbegrenzt.
    public func setMaximumReadChunk(_ bytes: Int?) {
        maximumReadChunk = bytes.map { max(1, $0) }
    }

    /// Verwirft empfangene Daten und gedruckte Etiketten (Zähler bleiben erhalten).
    public func clearHistory() {
        received.removeAll()
        printed.removeAll()
    }
}

/// Prozessweite Zuordnung Kennung → virtueller Drucker.
final class VirtualPrinterRegistry: @unchecked Sendable {
    static let shared = VirtualPrinterRegistry()

    private let lock = NSLock()
    private var printers: [String: VirtualPrinter] = [:]

    func printer(for id: String) -> VirtualPrinter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = printers[id] { return existing }
        let printer = VirtualPrinter.make(forID: id)
        printers[id] = printer
        return printer
    }
}

import Foundation
import LabelWerkCore
import LabelWerkImaging
import LabelWerkStatus
import LabelWerkTransport

/// High-Level-Schnittstelle zu einem Zebra-Drucker.
///
/// `PrinterClient` kapselt eine beliebige `PrinterConnection` (TCP, USB, Bluetooth, CUPS,
/// ``VirtualPrinter``) und bietet Status, Identität, SGD-Zugriff, Druck, Dateiverwaltung,
/// Firmware-Übertragung, Terminal und Netzwerkkonfiguration.
///
/// Robustheit:
/// * **Serialisierung:** Alle Operationen laufen nacheinander. Ein Actor allein genügt dafür
///   nicht (Wiedereintritt an jedem `await`), deshalb hält jede öffentliche Methode für ihre
///   gesamte Dauer eine interne FIFO-Sperre. So können sich Anfragen und Antworten zweier
///   Aufrufer (z. B. Statusabfrage der Oberfläche und Terminal) nie vermischen.
/// * **Antwortende:** Jede Abfrage kennt das Ende ihrer Antwort (`ResponseFraming`): `~HS`
///   nach drei `ETX`, `~HI`/`^HH`/`^HW` mit `ETX`, `~HQES` mit abgeschlossener `WARNINGS`-Zeile,
///   SGD `getvar` mit dem schließenden Anführungszeichen, JSON mit ausgeglichenen Klammern.
///   Fehlt das Ende, beendet die Leerlauffrist die Sammlung.
/// * **Liegengebliebene Daten:** Vor jeder Abfrage werden verspätete Antworten früherer,
///   abgelaufener Abfragen verworfen (`read(timeout: .zero)`), damit sie nicht als Antwort der
///   neuen Abfrage gelten.
/// * **Getrennte Verbindungen:** Vor *jedem* Senden – auch bei reinen Sendeoperationen wie
///   ``printZPL(_:)`` – wird bei Verbindungen mit Rückkanal mit `read(timeout: .zero)` geprüft, ob
///   die Gegenstelle die Verbindung inzwischen beendet hat (z. B. Neustart des Druckers, Zeitlimit
///   des Druckservers). Dann wird neu verbunden, statt in die tote Verbindung zu schreiben: TCP
///   meldet das Verbindungsende sonst erst beim übernächsten Schreiben, und die Daten des
///   ersten gingen unbemerkt verloren. Was dabei empfangen wird, liefert ``terminal(_:timeout:)``
///   später mit aus. Nach Befehlen, die den Drucker neu starten (``perform(_:resolution:widthDots:heightDots:)``
///   mit `reset`, `restoreNetworkDefaults` oder `restoreFactoryDefaults`, ``applyNetworkSettings(_:)``,
///   ``sendFirmware(_:chunkSize:progress:)``), wird die Verbindung vor der nächsten Operation
///   geschlossen und neu aufgebaut – auch wenn der Drucker beim Neustart gar kein Verbindungsende
///   meldet. Erst dann, nicht sofort, weil ein `close()` mit ungelesenen Empfangsdaten die
///   Verbindung hart (RST) beenden und noch nicht übertragene Befehlsbytes verwerfen könnte.
/// * **Fähigkeiten:** Ob der Drucker SGD bzw. JSON (Link-OS) beherrscht, wird beim ersten Bedarf
///   ermittelt und zwischengespeichert; `getvars` fällt ohne JSON auf einzelne `getvar` zurück.
/// * **Fehler:** Alle Fehler sind ``PrinterClientError`` (Transportfehler als
///   ``PrinterClientError/transport(_:)``); ein Abbruch des Tasks wirft `CancellationError`.
public actor PrinterClient {

    // MARK: Zeitlimits

    /// Zeitlimits für Abfragen.
    public struct Timeouts: Sendable, Hashable {
        /// Wartezeit auf eine Antwort (Status, Identität, `getvar`).
        public var response: Duration
        /// Leerlauffrist nach dem ersten empfangenen Byte.
        public var idle: Duration
        /// Wartezeit beim Erkennen der Fähigkeiten (SGD/JSON); kurz, damit Drucker ohne SGD
        /// nicht lange blockieren.
        public var probe: Duration
        /// Wartezeit für umfangreiche Antworten (`allconfig`, `allcv`, `^HH`).
        public var bulk: Duration
        /// Leerlauffrist für umfangreiche Antworten ohne erkennbares Ende (`allcv`).
        public var bulkIdle: Duration

        public init(response: Duration = .seconds(3), idle: Duration = .milliseconds(400),
                    probe: Duration = .milliseconds(1500), bulk: Duration = .seconds(20),
                    bulkIdle: Duration = .milliseconds(1500)) {
            self.response = response
            self.idle = idle
            self.probe = probe
            self.bulk = bulk
            self.bulkIdle = bulkIdle
        }

        /// Standardwerte für Netzwerk- und USB-Drucker.
        public static let standard = Timeouts()
    }

    /// Zwischengespeicherte Fähigkeiten des Druckers.
    struct Capabilities: Sendable, Hashable {
        /// Klassische SGD-Befehle (`! U1 getvar`) werden beantwortet.
        var sgd: Bool
        /// JSON-SGD (`{}{…}`) wird beantwortet.
        var json: Bool
        /// Link-OS-Drucker.
        var linkOS: Bool
    }

    // MARK: Zustand

    /// Verbindung zum Drucker.
    public nonisolated let connection: any PrinterConnection
    /// Befehlssprache, in der Aufträge und Einstellungen gesendet werden.
    public var language: PrinterLanguage
    /// Aktuelle Zeitlimits.
    public private(set) var timeouts: Timeouts
    /// Ergebnis der letzten erfolgreichen ``identify()``-Abfrage.
    public internal(set) var lastIdentity: PrinterIdentity?

    var capabilities: Capabilities?

    /// Höchstmenge aufbewahrter, noch nicht abgeholter Empfangsdaten (``unclaimedInput``).
    static let unclaimedInputLimit = 1 << 20

    /// Daten, die bei der Prüfung vor dem Senden empfangen und noch nicht abgeholt wurden
    /// (höchstens ``unclaimedInputLimit`` Byte, die neuesten). ``terminal(_:timeout:)`` liefert sie
    /// vor seiner Antwort aus; Abfragen verwerfen sie wie andere verspätete Daten.
    var unclaimedInput = Data()

    /// `true` nach einem Befehl, der den Drucker neu startet: Die nächste Operation schließt die
    /// Verbindung und baut sie neu auf.
    var reconnectPending = false

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(connection: any PrinterConnection, language: PrinterLanguage = .zpl) {
        self.connection = connection
        self.language = language
        self.timeouts = .standard
    }

    /// Ändert die Befehlssprache.
    public func setLanguage(_ language: PrinterLanguage) {
        self.language = language
    }

    /// Ändert die Zeitlimits.
    public func setTimeouts(_ timeouts: Timeouts) {
        self.timeouts = timeouts
    }

    /// `true`, wenn die Verbindung Antworten empfangen kann (nicht bei CUPS-Warteschlangen).
    public nonisolated var supportsBidirectional: Bool {
        connection.descriptor.supportsBidirectional
    }

    // MARK: Verbindung

    /// Öffnet die Verbindung, falls sie noch nicht offen ist.
    public func connect() async throws {
        try await guarded { try await self.ensureOpen() }
    }

    /// Schließt die Verbindung und verwirft zwischengespeicherte Fähigkeiten sowie noch nicht
    /// abgeholte Empfangsdaten.
    public func disconnect() async {
        await acquire()
        defer { release() }
        capabilities = nil
        reconnectPending = false
        unclaimedInput.removeAll()
        await connection.close()
    }

    // MARK: SGD

    /// Liest eine SGD-Variable. `nil`, wenn der Drucker die Variable nicht kennt (`"?"`).
    ///
    /// - Throws: ``PrinterClientError/noResponse(_:)``, wenn gar keine Antwort kommt.
    public func getvar(_ name: String) async throws -> String? {
        try await guarded {
            let name = try Self.validatedName(name)
            return try await self.fetchVariable(name)
        }
    }

    /// Liest mehrere SGD-Variablen – per JSON in einer Abfrage, wenn der Drucker das kann,
    /// sonst nacheinander per `getvar`. Unbekannte Variablen fehlen im Ergebnis.
    public func getvars(_ names: [String]) async throws -> [String: String] {
        try await guarded { try await self.fetchVariables(names) }
    }

    /// Setzt eine SGD-Variable.
    public func setvar(_ name: String, _ value: String) async throws {
        try await guarded {
            let name = try Self.validatedName(name)
            try await self.storeVariable(name, value)
        }
    }

    /// Führt einen SGD-`do`-Befehl aus und liefert die Antwort (falls der Drucker antwortet).
    public func doCommand(_ name: String, _ value: String = "") async throws -> String? {
        try await guarded {
            let name = try Self.validatedName(name)
            return try await self.runDoCommand(name, value)
        }
    }

    /// Alle Einstellungen mit Wert, Typ, Wertebereich und Zugriff: per `allconfig` (Link-OS),
    /// sonst per `allcv`.
    public func allSettings() async throws -> [String: SGDSetting] {
        try await guarded { try await self.fetchAllSettings() }
    }

    /// Konfiguration als Liste (`^HH` bei ZPL, `UQ` bei EPL, SGD bei CPCL).
    public func configuration() async throws -> [ConfigurationEntry] {
        try await guarded { try await self.fetchConfiguration() }
    }

    // MARK: Senden

    /// Führt eine Gerätefunktion aus (Kalibrieren, Pause, Testetikett …).
    ///
    /// Nach Aktionen, die den Drucker neu starten (`reset`, `restoreNetworkDefaults`) oder auf
    /// Werkseinstellungen setzen, verwirft der Client die erkannten Fähigkeiten und baut die
    /// Verbindung vor der nächsten Operation neu auf.
    ///
    /// - Throws: ``PrinterClientError/unsupportedAction(_:_:)``, wenn die Aktion in der
    ///   eingestellten Sprache keine Entsprechung hat.
    public func perform(_ action: PrinterAction, resolution: Resolution = .dpi203, widthDots: Int = 812,
                        heightDots: Int = 1218) async throws {
        try await guarded {
            guard let payload = action.payload(language: self.language, resolution: resolution,
                                               widthDots: widthDots, heightDots: heightDots) else {
                throw PrinterClientError.unsupportedAction(action, self.language)
            }
            try await self.transmit(payload)
            if action.restartsPrinter || action == .restoreFactoryDefaults {
                // Werkseinstellungen sind hier eingeschlossen: Je nach Sprache und Firmware
                // (EPL `^default`, SGD `device.restore_defaults "all"`) setzt der Drucker dabei
                // auch die Schnittstellen zurück. Ein unnötiger Neuaufbau kostet nur einen
                // Verbindungsaufbau, eine tote Verbindung dagegen das nächste Etikett.
                self.printerWillRestart()
            }
        }
    }

    /// Sendet Rohdaten unverändert.
    public func send(_ data: Data) async throws {
        try await guarded { try await self.transmit(data) }
    }

    /// Sendet Text (UTF-8) unverändert.
    public func send(_ text: String) async throws {
        try await guarded { try await self.transmit(Data(text.utf8)) }
    }

    /// Sendet ZPL-Code (UTF-8).
    ///
    /// - Throws: ``PrinterClientError/invalidArgument(_:)`` bei leerem Code.
    public func printZPL(_ zpl: String) async throws {
        try await guarded {
            guard !zpl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PrinterClientError.invalidArgument("Der ZPL-Code ist leer.")
            }
            try await self.transmit(Data(zpl.utf8))
        }
    }

    /// Terminal: sendet `input` unverändert (keine Umwandlung von Zeilenenden oder
    /// Maskierungen) und liefert alles, was danach empfangen wird – bis `timeout` abgelaufen ist
    /// bzw. nach dem ersten Empfang die Leerlauffrist verstrichen ist.
    ///
    /// Mit leerem `input` wird nur gelesen. Verbindungen ohne Rückkanal liefern stets leere Daten.
    /// Daten, die seit der letzten Abfrage unaufgefordert eingetroffen sind (z. B. Antworten auf
    /// Befehle, die mit `send(_:)` gesendet wurden), stehen am Anfang der Antwort.
    public func terminal(_ input: String, timeout: Duration = .seconds(2)) async throws -> Data {
        try await guarded {
            let payload = Data(input.utf8)
            guard self.supportsBidirectional else {
                if !payload.isEmpty { try await self.transmit(payload) }
                return Data()
            }
            try Task.checkCancellation()
            if payload.isEmpty {
                // Nur lesen: Ein Verbindungsende soll hier sichtbar werden, nicht übergangen.
                try await self.ensureOpen()
            } else {
                try await self.prepareForWriting()
            }
            let response = try await self.connection.request(payload, timeout: timeout, idleTimeout: self.timeouts.idle)
            // Erst nach erfolgreichem Empfang abholen – bei einem Fehler bleiben die Daten erhalten.
            let earlier = self.unclaimedInput
            self.unclaimedInput = Data()
            return earlier + response
        }
    }

    // MARK: - Sperre & Fehlerumwandlung

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // Die Sperre geht direkt an den nächsten Wartenden über (FIFO).
            waiters.removeFirst().resume()
        }
    }

    /// Führt `body` exklusiv aus und wandelt Fehler in ``PrinterClientError`` um.
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        do {
            return try await body()
        } catch let error as TransportError {
            throw PrinterClientError.transport(error)
        } catch let error as ImagingError {
            throw PrinterClientError.encodingFailed(error.errorDescription ?? String(describing: error))
        }
    }

    // MARK: - Ein-/Ausgabe (ohne Sperre, nur innerhalb von `guarded`)

    /// Öffnet die Verbindung, falls sie nicht offen ist. Steht nach einem Neustartbefehl ein
    /// Neuaufbau aus (``reconnectPending``), wird die bisherige Verbindung zuerst geschlossen.
    func ensureOpen() async throws {
        if reconnectPending {
            reconnectPending = false
            unclaimedInput.removeAll()
            await connection.close()
        }
        if await connection.isOpen { return }
        try await connection.open()
    }

    /// Merkt vor, dass der Drucker nach dem gerade gesendeten Befehl neu startet: Die erkannten
    /// Fähigkeiten gelten nicht mehr, die nächste Operation verbindet neu (siehe ``ensureOpen()``).
    func printerWillRestart() {
        capabilities = nil
        reconnectPending = true
    }

    /// Bereitet das Senden vor: öffnet die Verbindung bei Bedarf und verbindet bei Verbindungen
    /// mit Rückkanal neu, wenn die Gegenstelle sie inzwischen beendet hat. Bereits empfangene
    /// Daten bleiben für ``terminal(_:timeout:)`` erhalten (``unclaimedInput``).
    func prepareForWriting() async throws {
        try await ensureOpen()
        guard supportsBidirectional else { return }
        try await collectPendingInput(keep: true)
    }

    /// Sendet Daten (öffnet die Verbindung bei Bedarf und erkennt zuvor getrennte Verbindungen).
    func transmit(_ data: Data) async throws {
        try Task.checkCancellation()
        try await prepareForWriting()
        guard !data.isEmpty else { return }
        try await connection.write(data)
    }

    func transmit(_ text: String) async throws {
        try await transmit(Data(text.utf8))
    }

    /// Holt sofort verfügbare Daten ab (`read(timeout: .zero)`) und verbindet neu, wenn die
    /// Gegenstelle die Verbindung beendet hat (z. B. Neustart des Druckers).
    ///
    /// - Parameter keep: `true` bewahrt die Daten in ``unclaimedInput`` auf; `false` verwirft sie
    ///   samt bisher aufbewahrter Daten (verspätete Antworten früherer Abfragen).
    private func collectPendingInput(keep: Bool) async throws {
        if !keep { unclaimedInput.removeAll() }
        for _ in 0..<32 {
            let chunk: Data
            do {
                chunk = try await connection.read(timeout: .zero)
            } catch TransportError.closedByPeer {
                try await connection.open()
                return
            }
            if chunk.isEmpty { break }
            if keep { retainUnclaimed(chunk) }
        }
        // Restdaten und Verbindungsende können gemeinsam eintreffen: Die Leseoperation liefert
        // dann die Daten, die Verbindung gilt danach als geschlossen.
        if !(await connection.isOpen) { try await connection.open() }
    }

    private func retainUnclaimed(_ chunk: Data) {
        unclaimedInput.append(chunk)
        if unclaimedInput.count > Self.unclaimedInputLimit {
            unclaimedInput = Data(unclaimedInput.suffix(Self.unclaimedInputLimit))
        }
    }

    /// Sendet eine Abfrage und sammelt die Antwort.
    func exchange(_ payload: Data, operation: String, timeout: Duration? = nil, idle: Duration? = nil,
                  isComplete: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        guard supportsBidirectional else { throw PrinterClientError.notBidirectional(operation) }
        try Task.checkCancellation()
        try await ensureOpen()
        try await collectPendingInput(keep: false)
        return try await connection.request(payload, timeout: timeout ?? timeouts.response,
                                            idleTimeout: idle ?? timeouts.idle, isComplete: isComplete)
    }

    func exchange(_ text: String, operation: String, timeout: Duration? = nil, idle: Duration? = nil,
                  isComplete: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        try await exchange(Data(text.utf8), operation: operation, timeout: timeout, idle: idle,
                           isComplete: isComplete)
    }

    // MARK: - Fähigkeiten

    /// Ermittelt (einmalig) SGD- und JSON-Unterstützung.
    ///
    /// - Parameter knownAlive: Der Drucker hat in derselben Operation bereits geantwortet
    ///   (`~HS`, `~HI`). Nur dann wird ein negatives Ergebnis zwischengespeichert – sonst könnte
    ///   ein kurzzeitig nicht erreichbarer Drucker dauerhaft als „ohne SGD“ gelten.
    func resolveCapabilities(knownAlive: Bool) async throws -> Capabilities {
        if let capabilities { return capabilities }
        guard supportsBidirectional else { return Capabilities(sgd: false, json: false, linkOS: false) }
        var result = Capabilities(sgd: false, json: false, linkOS: false)
        var responded = false

        let probe = ["appl.name", "device.product_name", "appl.link_os_version"]
        let json = try await exchange(SGD.jsonGet(probe), operation: "SGD-Erkennung", timeout: timeouts.probe,
                                      isComplete: ResponseFraming.jsonComplete)
        if !json.isEmpty {
            responded = true
            if let values = try? SGDResponseParser.parseJSON(json), !values.isEmpty {
                result = Capabilities(sgd: true, json: true, linkOS: true)
            }
        }
        if !result.sgd {
            let classic = try await exchange(SGD.getvar("appl.name"), operation: "SGD-Erkennung",
                                             timeout: timeouts.probe, isComplete: ResponseFraming.quotedValueComplete)
            if !classic.isEmpty {
                responded = true
                if SGDResponseParser.parseValue(classic) != nil {
                    result.sgd = true
                    let linkOS = try await exchange(SGD.getvar("appl.link_os_version"), operation: "SGD-Erkennung",
                                                    timeout: timeouts.probe,
                                                    isComplete: ResponseFraming.quotedValueComplete)
                    result.linkOS = SGDResponseParser.parseValue(linkOS) != nil
                }
            }
        }
        if result.sgd || responded || knownAlive {
            capabilities = result
        }
        return result
    }

    // MARK: - SGD (ohne Sperre)

    static func validatedName(_ name: String) throws -> String {
        let cleaned = sanitizedSGD(name).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else {
            throw PrinterClientError.invalidArgument("Der Name der SGD-Variablen ist leer.")
        }
        return cleaned
    }

    /// Entfernt Steuerzeichen wie `SGD` (Core) es beim Erzeugen der Befehle tut.
    static func sanitizedSGD(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars where scalar.value >= 0x20 && scalar.value != 0x7F {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Variablen ohne Punkt (`ip`, `allcv`) liefern ganze Zweige als mehrzeiligen Text.
    static func isBranchQuery(_ name: String) -> Bool { !name.contains(".") }

    func fetchVariable(_ name: String) async throws -> String? {
        let operation = "getvar \(name)"
        if SGD.requiresJSON(name) {
            let data = try await exchange(SGD.getvar(name), operation: operation,
                                          isComplete: ResponseFraming.jsonComplete)
            guard !data.isEmpty else { throw PrinterClientError.noResponse(operation) }
            let parsed = try? SGDResponseParser.parseJSON(data)
            return parsed?[name]?.value
        }
        let branch = Self.isBranchQuery(name)
        let complete: @Sendable (Data) -> Bool = branch ? ResponseFraming.neverComplete : ResponseFraming.quotedValueComplete
        let data = try await exchange(
            SGD.getvar(name), operation: operation,
            timeout: branch ? timeouts.bulk : timeouts.response,
            idle: branch ? timeouts.bulkIdle : timeouts.idle,
            isComplete: complete)
        guard !data.isEmpty else { throw PrinterClientError.noResponse(operation) }
        return SGDResponseParser.parseValue(data)
    }

    func fetchVariables(_ requested: [String]) async throws -> [String: String] {
        var seen = Set<String>()
        let names = requested.map(Self.sanitizedSGD).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !names.isEmpty else { return [:] }
        guard supportsBidirectional else { throw PrinterClientError.notBidirectional("SGD-Abfrage") }

        let capabilities = try await resolveCapabilities(knownAlive: false)
        if capabilities.json {
            let data = try await exchange(SGD.jsonGet(names), operation: "SGD-Abfrage",
                                          isComplete: ResponseFraming.jsonComplete)
            if !data.isEmpty, let parsed = try? SGDResponseParser.parseJSON(data) {
                var result: [String: String] = [:]
                for name in names {
                    if let setting = parsed[name] {
                        result[name] = setting.value
                    } else if Self.isBranchQuery(name) {
                        // Zweigabfrage: alle Variablen unterhalb des Zweigs übernehmen.
                        for (key, setting) in parsed where key.hasPrefix(name + ".") { result[key] = setting.value }
                    }
                }
                return result
            }
            // Keine oder unverständliche JSON-Antwort: einzeln nachfragen.
        }

        var result: [String: String] = [:]
        var silentInARow = 0
        for name in names {
            try Task.checkCancellation()
            let data = try await exchange(SGD.getvar(name), operation: "getvar \(name)",
                                          isComplete: SGD.requiresJSON(name)
                                              ? ResponseFraming.jsonComplete : ResponseFraming.quotedValueComplete)
            if data.isEmpty {
                // Zwei Abfragen ohne jede Antwort: Der Drucker beherrscht kein SGD bzw. ist
                // nicht erreichbar – nicht jede weitere Variable einzeln abwarten.
                silentInARow += 1
                if silentInARow >= 2 { break }
                continue
            }
            silentInARow = 0
            if SGD.requiresJSON(name) {
                if let value = (try? SGDResponseParser.parseJSON(data))?[name]?.value { result[name] = value }
            } else if let value = SGDResponseParser.parseValue(data) {
                result[name] = value
            }
        }
        return result
    }

    func storeVariable(_ name: String, _ value: String) async throws {
        let command = SGD.setvar(name, value)
        if SGD.requiresJSON(name, value), supportsBidirectional {
            // Die JSON-Form wird mit dem neuen (bzw. alten) Wert beantwortet – Antwort abholen,
            // damit sie nicht als Antwort der nächsten Abfrage gilt.
            _ = try await exchange(command, operation: "setvar \(name)", isComplete: ResponseFraming.jsonComplete)
        } else {
            try await transmit(command)
        }
    }

    func runDoCommand(_ name: String, _ value: String) async throws -> String? {
        let command = SGD.do(name, value)
        guard supportsBidirectional else {
            try await transmit(command)
            return nil
        }
        let json = SGD.requiresJSON(name, value)
        let data = try await exchange(command, operation: "do \(name)",
                                      isComplete: json ? ResponseFraming.jsonComplete : ResponseFraming.quotedValueComplete)
        guard !data.isEmpty else { return nil }
        if json { return (try? SGDResponseParser.parseJSON(data))?[name]?.value }
        return SGDResponseParser.parseValue(data)
    }

    func fetchAllSettings() async throws -> [String: SGDSetting] {
        let capabilities = try await resolveCapabilities(knownAlive: false)
        if capabilities.json {
            let data = try await exchange(SGD.allConfigJSON, operation: "allconfig", timeout: timeouts.bulk,
                                          idle: timeouts.bulkIdle, isComplete: ResponseFraming.jsonComplete)
            if !data.isEmpty {
                do {
                    let parsed = try SGDResponseParser.parseJSON(data)
                    if !parsed.isEmpty { return parsed }
                } catch {
                    throw PrinterClientError.invalidResponse("allconfig", error.localizedDescription)
                }
            }
        }
        let data = try await exchange(SGD.allVariables, operation: "allcv", timeout: timeouts.bulk,
                                      idle: timeouts.bulkIdle, isComplete: ResponseFraming.neverComplete)
        guard !data.isEmpty else { throw PrinterClientError.noResponse("Alle Einstellungen lesen") }
        let parsed = SGDResponseParser.parseAllCV(Self.text(data))
        guard !parsed.isEmpty else {
            throw PrinterClientError.invalidResponse("allcv", "Keine Einstellungen erkannt.")
        }
        return parsed
    }

    func fetchConfiguration() async throws -> [ConfigurationEntry] {
        switch language {
        case .zpl, .epl:
            let data = try await exchange(ZPL.hostConfigurationFormat(), operation: "Konfiguration (^HH)",
                                          timeout: timeouts.bulk, isComplete: ResponseFraming.etxComplete)
            if !data.isEmpty {
                let entries = ConfigurationLabelParser.parse(data: data)
                if !entries.isEmpty { return entries }
            }
            if language == .epl {
                let uq = try await exchange(EPL.render([EPL.queryConfiguration()]), operation: "Konfiguration (UQ)",
                                            timeout: timeouts.bulk, idle: timeouts.bulkIdle, isComplete: ResponseFraming.neverComplete)
                let entries = Self.parseEPLConfiguration(Self.text(uq))
                if !entries.isEmpty { return entries }
            }
            if data.isEmpty { throw PrinterClientError.noResponse("Konfiguration lesen") }
            throw PrinterClientError.invalidResponse("Konfiguration (^HH)", "Keine Einträge erkannt.")
        case .cpcl:
            let settings = try await fetchAllSettings()
            return settings.values.sorted { $0.name < $1.name }
                .map { ConfigurationEntry(name: $0.name, value: $0.value) }
        }
    }

    /// Wertet die EPL-Antwort auf `UQ` aus: `Name: Wert`-Zeilen; die erste Zeile (Modell und
    /// Firmware) und Zeilen ohne Doppelpunkt werden nummeriert übernommen.
    static func parseEPLConfiguration(_ text: String) -> [ConfigurationEntry] {
        var entries: [ConfigurationEntry] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.filter { $0 != "\u{02}" && $0 != "\u{03}" } }
            .filter { !$0.isEmpty }
        for (index, line) in lines.enumerated() {
            if index == 0 {
                entries.append(ConfigurationEntry(name: "MODELL", value: line))
            } else if let colon = line.firstIndex(of: ":"), colon != line.startIndex {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                entries.append(ConfigurationEntry(name: name, value: value))
            } else {
                entries.append(ConfigurationEntry(name: "ZEILE \(index + 1)", value: line))
            }
        }
        return entries
    }

    /// Dekodiert Antwortdaten (UTF-8, sonst ISO-Latin-1).
    static func text(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data.map { Character(Unicode.Scalar($0)) })
    }
}

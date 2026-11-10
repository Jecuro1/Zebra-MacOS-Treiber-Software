import Foundation
import Testing
@testable import LabelWerkKit

/// Regressionstests: Sendeoperationen erkennen vom Drucker beendete Verbindungen, und nach
/// Neustartbefehlen wird vor der nächsten Operation neu verbunden.
@Suite("PrinterClient – Verbindungsende und Neuaufbau")
struct ReconnectTests {

    /// Sehr kurze Zeitlimits für die stumme Testverbindung.
    static let shortTimeouts = PrinterClient.Timeouts(response: .milliseconds(120), idle: .milliseconds(40),
                                                      probe: .milliseconds(60), bulk: .milliseconds(200),
                                                      bulkIdle: .milliseconds(60))

    static func makeClient(_ connection: ScriptedConnection) async -> PrinterClient {
        let client = PrinterClient(connection: connection)
        await client.setTimeouts(shortTimeouts)
        return client
    }

    // MARK: - Verbindungsende vor dem Senden

    /// Alle Operationen, die Daten senden.
    enum SendOperation: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case sendData, sendText, printZPL, printImages, applySettings, uploadFont, uploadGraphic, deleteFile,
             perform, setvar, sendFirmware, terminal

        var testDescription: String { rawValue }

        func run(_ client: PrinterClient) async throws {
            switch self {
            case .sendData:
                try await client.send(Data("~JL".utf8))
            case .sendText:
                try await client.send("~JL")
            case .printZPL:
                try await client.printZPL("^XA^FO0,0^GB10,10,10^FS^XZ")
            case .printImages:
                try await client.printImages([GrayImage(width: 16, height: 8, fill: 0)], settings: .default,
                                             resolution: .dpi203, stock: nil)
            case .applySettings:
                try await client.applySettings(PrintSettings(darkness: 12), permanently: false)
            case .uploadFont:
                try await client.uploadFont(name: "Test", data: Data([0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0, count: 28)))
            case .uploadGraphic:
                var bitmap = MonoBitmap(width: 8, height: 4)
                bitmap[1, 1] = true
                try await client.uploadGraphic(name: "LOGO", bitmap: bitmap)
            case .deleteFile:
                try await client.deleteFile("E:LOGO.GRF")
            case .perform:
                try await client.perform(.feedLabel)
            case .setvar:
                try await client.setvar("device.friendly_name", "Lager")
            case .sendFirmware:
                try await client.sendFirmware(Data(repeating: 0x5A, count: 200), chunkSize: 64) { _ in }
            case .terminal:
                _ = try await client.terminal("~HS", timeout: .milliseconds(60))
            }
        }
    }

    @Test("Nach Verbindungsende durch den Drucker verbindet jede Sendeoperation neu, statt Daten zu verlieren",
          arguments: SendOperation.allCases)
    func sendAfterPeerClose(_ operation: SendOperation) async throws {
        let connection = ScriptedConnection()
        let client = await Self.makeClient(connection)
        try await client.connect()
        // Der Drucker beendet die Verbindung, solange der Client nichts tut (z. B. Neustart).
        await connection.peerCloses()

        try await operation.run(client)

        #expect(await connection.lost.isEmpty, "Keine Daten in die tote Verbindung geschrieben")
        #expect(await connection.opens == 2, "Genau ein Neuaufbau")
        let deliveries = await connection.delivered
        #expect(!deliveries.isEmpty)
        #expect(deliveries.allSatisfy { $0.connection == 2 }, "Alles kommt über die neue Verbindung an")
    }

    @Test("Ohne Verbindungsende bleibt die Verbindung bestehen (kein unnötiger Neuaufbau)")
    func noReconnectWhileAlive() async throws {
        let connection = ScriptedConnection()
        let client = await Self.makeClient(connection)
        for _ in 0..<3 { try await client.printZPL("^XA^XZ") }
        #expect(await connection.opens == 1)
        #expect(await connection.closes == 0)
        #expect(await connection.delivered.count == 3)
    }

    @Test("Vor dem Senden empfangene Daten liefert terminal() nach – auch bei gleichzeitigem Verbindungsende")
    func unclaimedInputReachesTerminal() async throws {
        let connection = ScriptedConnection()
        let client = await Self.makeClient(connection)
        try await client.connect()

        // Antwort auf einen per send() gesendeten Befehl, noch nicht abgeholt.
        await connection.receive(Data("ANTWORT-1".utf8))
        try await client.send("~JL")
        // Restdaten und Verbindungsende kommen gemeinsam an.
        await connection.peerCloses(after: Data("|REST".utf8))
        try await client.send("~JL")
        #expect(await connection.opens == 2)
        #expect(await connection.lost.isEmpty)

        let response = try await client.terminal("", timeout: .milliseconds(60))
        #expect(String(decoding: response, as: UTF8.self) == "ANTWORT-1|REST")
        let again = try await client.terminal("", timeout: .milliseconds(60))
        #expect(again.isEmpty, "Aufbewahrte Daten werden genau einmal ausgeliefert")
    }

    @Test("Abfragen verwerfen aufbewahrte Daten als verspätete Antworten")
    func exchangeDiscardsUnclaimedInput() async throws {
        let connection = ScriptedConnection()
        let client = await Self.makeClient(connection)
        try await client.connect()
        await connection.receive(Data("\"ALT\"".utf8))
        try await client.send("~JL")
        await #expect(throws: PrinterClientError.noResponse("getvar device.friendly_name")) {
            try await client.getvar("device.friendly_name")
        }
        #expect(try await client.terminal("", timeout: .milliseconds(60)).isEmpty)
    }

    @Test("Verbindungen ohne Rückkanal werden vor dem Senden nicht gelesen")
    func sendOnlyConnectionIsNotProbed() async throws {
        let connection = ScriptedConnection(bidirectional: false)
        let client = await Self.makeClient(connection)
        try await client.printZPL("^XA^XZ")
        try await client.perform(.feedLabel)
        #expect(await connection.reads == 0)
        #expect(await connection.delivered.count == 2)
    }

    // MARK: - Neustartbefehle

    /// Operationen, nach denen der Drucker neu startet.
    enum RestartOperation: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case reset, restoreNetworkDefaults, restoreFactoryDefaults, sendFirmware

        var testDescription: String { rawValue }

        func run(_ client: PrinterClient) async throws {
            switch self {
            case .reset: try await client.perform(.reset)
            case .restoreNetworkDefaults: try await client.perform(.restoreNetworkDefaults)
            case .restoreFactoryDefaults: try await client.perform(.restoreFactoryDefaults)
            case .sendFirmware: try await client.sendFirmware(Data(repeating: 0x33, count: 300), chunkSize: 100) { _ in }
            }
        }
    }

    @Test("Nach Neustartbefehlen baut die nächste Operation die Verbindung neu auf",
          arguments: RestartOperation.allCases)
    func reconnectAfterRestartCommand(_ operation: RestartOperation) async throws {
        let connection = ScriptedConnection()
        let client = await Self.makeClient(connection)
        try await client.connect()

        try await operation.run(client)
        // Nicht sofort schließen: Ein close() mit ungelesenen Daten könnte die Verbindung hart
        // beenden, bevor die Befehlsbytes übertragen sind.
        #expect(await connection.closes == 0)
        #expect(await client.reconnectPending)
        #expect(await client.capabilities == nil)

        // Der Drucker startet neu, ohne das Verbindungsende zu melden: Ohne Neuaufbau ginge
        // das nächste Etikett in die tote Verbindung.
        try await client.printZPL("^XA^FO0,0^GB10,10,10^FS^XZ")
        #expect(await connection.closes == 1)
        #expect(await connection.opens == 2)
        #expect(await connection.delivered.last?.connection == 2)
        #expect(await client.reconnectPending == false)
    }

    @Test("Gewöhnliche Aktionen verbinden nicht neu; disconnect() verwirft einen ausstehenden Neuaufbau")
    func ordinaryActionsKeepConnection() async throws {
        let connection = ScriptedConnection()
        let client = await Self.makeClient(connection)
        try await client.perform(.calibrate)
        try await client.perform(.saveSettings)
        try await client.printZPL("^XA^XZ")
        #expect(await connection.opens == 1)
        #expect(await connection.closes == 0)

        try await client.perform(.reset)
        await client.disconnect()
        #expect(await client.reconnectPending == false)
        try await client.printZPL("^XA^XZ")
        #expect(await connection.opens == 2)
        #expect(await connection.closes == 1, "Nur das ausdrückliche disconnect() hat geschlossen")
    }

    @Test("Abgebrochene Firmware-Übertragung löst keinen Neuaufbau aus")
    func cancelledFirmwareKeepsConnection() async throws {
        let connection = ScriptedConnection(writeDelay: .milliseconds(5))
        let client = await Self.makeClient(connection)
        let task = Task {
            try await client.sendFirmware(Data(repeating: 1, count: 100_000), chunkSize: 100) { _ in }
        }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await client.reconnectPending == false, "Der Drucker behält die bisherige Firmware")
    }

    @Test("applyNetworkSettings mit Neustart: nächste Operation verbindet neu (virtueller Drucker)")
    func networkSettingsReconnect() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        var settings = try await client.networkSettings()
        settings.hostname = "lager-2"
        try await client.applyNetworkSettings(settings)
        #expect(await client.reconnectPending)
        #expect(await printer.restartCount == 1)
        let snapshot = try await client.status()
        #expect(snapshot.state == .ready)
        #expect(await client.reconnectPending == false)
        #expect(await printer.isOpen)
    }
}

// MARK: - Testverbindung mit TCP-Verhalten

/// Verbindung, die das Verhalten von TCP nachbildet: Beendet die Gegenstelle die Verbindung,
/// meldet erst ein Lesevorgang das Ende (`closedByPeer`). Der erste Schreibvorgang danach
/// „gelingt“, seine Daten gehen aber verloren (``lost``); erst der zweite scheitert.
actor ScriptedConnection: PrinterConnection {

    /// Ein bei der Gegenstelle angekommener Schreibvorgang.
    struct Delivery: Sendable, Equatable {
        /// Nummer der Verbindung (1 = erste, 2 = nach dem ersten Neuaufbau …).
        var connection: Int
        var data: Data
    }

    nonisolated let descriptor: ConnectionDescriptor
    private let writeDelay: Duration

    private(set) var opens = 0
    private(set) var closes = 0
    private(set) var reads = 0
    private(set) var delivered: [Delivery] = []
    private(set) var lost: [Data] = []

    private var opened = false
    /// Die Gegenstelle hat beendet; noch kein Lesevorgang hat es bemerkt.
    private var peerFinished = false
    /// Ein Lese- oder Schreibvorgang hat das Ende gemeldet.
    private var endDetected = false
    private var wroteIntoDeadConnection = false
    private var inbound = Data()

    init(bidirectional: Bool = true, writeDelay: Duration = .zero) {
        descriptor = bidirectional ? .tcp(host: "192.0.2.10", port: 9100) : .cupsQueue(name: "LabelWerk_Test")
        self.writeDelay = writeDelay
    }

    var isOpen: Bool { opened && !endDetected }

    func open() async throws {
        if opened && !endDetected { return }
        opened = true
        peerFinished = false
        endDetected = false
        wroteIntoDeadConnection = false
        inbound = Data()
        opens += 1
    }

    func close() async {
        if opened { closes += 1 }
        opened = false
        peerFinished = false
        endDetected = false
        inbound = Data()
    }

    func write(_ data: Data) async throws {
        if writeDelay > .zero { try await Task.sleep(for: writeDelay) }
        guard opened else { throw TransportError.notOpen }
        if endDetected { throw TransportError.closedByPeer }
        if peerFinished {
            if wroteIntoDeadConnection {
                endDetected = true
                throw TransportError.closedByPeer
            }
            wroteIntoDeadConnection = true
            lost.append(data)
            return
        }
        delivered.append(Delivery(connection: opens, data: data))
    }

    func read(timeout: Duration) async throws -> Data {
        reads += 1
        guard opened else { throw TransportError.notOpen }
        if endDetected { throw TransportError.closedByPeer }
        if !inbound.isEmpty {
            let data = inbound
            inbound = Data()
            if peerFinished { endDetected = true }
            return data
        }
        if peerFinished {
            endDetected = true
            throw TransportError.closedByPeer
        }
        if timeout > .zero { try await Task.sleep(for: min(timeout, .milliseconds(20))) }
        return Data()
    }

    /// Der Drucker sendet Daten.
    func receive(_ data: Data) {
        inbound.append(data)
    }

    /// Der Drucker beendet die Verbindung (optional nach letzten Daten).
    func peerCloses(after data: Data = Data()) {
        inbound.append(data)
        peerFinished = true
    }
}

import Foundation
import Testing
@testable import LabelWerkKit

/// Hilfsfunktionen für die LabelWerkKit-Tests.
enum KitTestSupport {

    struct SupportError: Error, CustomStringConvertible {
        var description: String
    }

    /// Katalogmodell ZD421t.
    static var zd421t: PrinterModel {
        guard let model = ModelCatalog.shared.model(id: "zd421t") else {
            preconditionFailure("ZD421t fehlt im Katalog")
        }
        return model
    }

    /// Neuer, geöffneter virtueller Drucker mit eindeutiger Kennung.
    static func makePrinter(id: String = "test-\(UUID().uuidString.prefix(8))",
                            model: PrinterModel = zd421t,
                            resolution: Resolution = .dpi203) async throws -> VirtualPrinter {
        let printer = VirtualPrinter(id: id, model: model, resolution: resolution)
        try await printer.open()
        return printer
    }

    /// Kurze Zeitlimits für schnelle Tests.
    static let fastTimeouts = PrinterClient.Timeouts(response: .seconds(2), idle: .milliseconds(150),
                                                     probe: .milliseconds(300), bulk: .seconds(5),
                                                     bulkIdle: .milliseconds(250))

    /// Client für eine Verbindung mit kurzen Zeitlimits.
    static func makeClient(_ connection: any PrinterConnection, language: PrinterLanguage = .zpl) async -> PrinterClient {
        let client = PrinterClient(connection: connection, language: language)
        await client.setTimeouts(fastTimeouts)
        return client
    }

    /// Sendet Text an den virtuellen Drucker und liefert die sofort verfügbare Antwort.
    static func exchange(_ printer: VirtualPrinter, _ text: String) async throws -> String {
        try await exchange(printer, Data(text.utf8))
    }

    static func exchange(_ printer: VirtualPrinter, _ data: Data) async throws -> String {
        try await printer.write(data)
        var collected = Data()
        while true {
            let chunk = try await printer.read(timeout: .milliseconds(30))
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
        return String(decoding: collected, as: UTF8.self)
    }

    /// Graustufenverlauf mit Muster (für Rasterungstests).
    static func gradientImage(width: Int, height: Int) -> GrayImage {
        var image = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let base = (x * 255) / max(1, width - 1)
                let ring = ((x / 6) + (y / 6)) % 2 == 0 ? 0 : 40
                image[x, y] = UInt8(clamping: base - ring + (y % 7))
            }
        }
        return image
    }

    // MARK: - TCP-Server

    /// Laufender Testserver.
    struct RunningServer: Sendable {
        let port: Int
        let task: Task<Void, Error>

        func stop() async {
            task.cancel()
            _ = await task.result
        }
    }

    /// Startet ``VirtualPrinterServer`` auf 127.0.0.1 – auf `port` bzw. (`0`) einem freien Port.
    static func startServer(_ printer: VirtualPrinter, port requestedPort: Int = 0) async throws -> RunningServer {
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let task = Task {
            do {
                try await VirtualPrinterServer.run(port: requestedPort, host: "127.0.0.1", printer: printer) { port in
                    continuation.yield(port)
                    continuation.finish()
                }
            } catch {
                continuation.finish()
                throw error
            }
        }
        var iterator = ports.makeAsyncIterator()
        guard let port = await iterator.next() else {
            _ = await task.result
            throw SupportError(description: "Server konnte nicht gestartet werden")
        }
        return RunningServer(port: port, task: task)
    }
}

/// Thread-sicherer Sammler für Werte aus `@Sendable`-Rückrufen.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

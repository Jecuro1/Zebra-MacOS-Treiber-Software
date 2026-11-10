import Foundation
import Testing
@testable import LabelWerkKit

@Suite("Virtueller Drucker über TCP (VirtualPrinterServer + TCPConnection)")
struct VirtualPrinterServerTests {

    @Test("Status, Identität, SGD und Druck über eine echte TCP-Verbindung")
    func endToEnd() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        let client = await KitTestSupport.makeClient(connection)
        do {
            try await client.connect()
            let snapshot = try await client.status()
            #expect(snapshot.state == .ready)

            await printer.setHeadOpen(true)
            let open = try await client.status()
            #expect(open.state == .error)
            #expect(open.hasAlert(.headOpen))
            await printer.setHeadOpen(false)

            let identity = try await client.identify()
            #expect(identity.matchedModelID == "zd421t")
            #expect(identity.serialNumber == printer.serialNumber)

            let values = try await client.getvars(["device.product_name", "media.printmode"])
            #expect(values["device.product_name"] == "ZD421t")
            #expect(values["media.printmode"] == "tear off")

            let image = KitTestSupport.gradientImage(width: 128, height: 80)
            try await client.printImages([image], settings: PrintSettings(dither: .atkinson), resolution: .dpi203, stock: nil)
            // Die Daten laufen asynchron durch den Server: kurz auf das Etikett warten.
            var labels: [RenderedLabel] = []
            for _ in 0..<100 {
                labels = await printer.renderedLabels
                if !labels.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .graphic(let graphic)? = labels.first?.elements.first else {
                Issue.record("Kein Etikett über TCP empfangen")
                await server.stop()
                return
            }
            #expect(graphic.bitmap == Ditherer.dither(image, algorithm: .atkinson))

            let settings = try await client.allSettings()
            #expect(settings.count >= 60)
            let entries = try await client.configuration()
            #expect(entries.value(named: "PRINT SPEED") == "4.0 IPS")
        } catch {
            await connection.close()
            await server.stop()
            throw error
        }
        await connection.close()
        await server.stop()
    }

    @Test("Mehrere Clients nacheinander; Zustand bleibt erhalten, alte Antworten nicht")
    func sequentialClients() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        defer { Task { await server.stop() } }

        let first = TCPConnection(host: "127.0.0.1", port: server.port)
        let firstClient = await KitTestSupport.makeClient(first)
        try await firstClient.setvar("device.friendly_name", "Client-1")
        // Unabgeholte Antwort zurücklassen und trennen.
        try await first.write(Data("~HS".utf8))
        try await Task.sleep(for: .milliseconds(100))
        await first.close()

        for index in 2...3 {
            let connection = TCPConnection(host: "127.0.0.1", port: server.port)
            try await connection.open()
            let response = try await connection.request(Data(SGD.getvar("device.friendly_name").utf8),
                                                        timeout: .seconds(3), idleTimeout: .milliseconds(200),
                                                        isComplete: ResponseFraming.quotedValueComplete)
            #expect(String(decoding: response, as: UTF8.self) == "\"Client-\(index - 1)\"")
            try await connection.write(Data(SGD.setvar("device.friendly_name", "Client-\(index)").utf8))
            try await Task.sleep(for: .milliseconds(50))
            await connection.close()
        }
        await server.stop()
    }

    @Test("Halb geschlossene Verbindung erhält noch die Antwort")
    func halfClosedClient() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        let response = try await connection.request(Data("~HI".utf8), timeout: .seconds(3), idleTimeout: .milliseconds(200),
                                                    isComplete: ResponseFraming.etxComplete)
        #expect(String(decoding: response, as: UTF8.self).contains("ZD421-203dpi"))
        await connection.close()
        await server.stop()
    }

    /// Wartet, bis der Drucker `count` Etiketten gedruckt hat (Daten laufen asynchron durch den Server).
    static func waitForLabels(_ printer: VirtualPrinter, count: Int) async throws -> Int {
        for _ in 0..<150 {
            let printed = await printer.renderedLabels.count
            if printed >= count { return printed }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await printer.renderedLabels.count
    }

    @Test("Druckserver neu gestartet: Der erste Druck danach kommt an")
    func printAfterServerRestart() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let first = try await KitTestSupport.startServer(printer)
        let port = first.port
        let connection = TCPConnection(host: "127.0.0.1", port: port)
        let client = await KitTestSupport.makeClient(connection)
        #expect(try await client.status().state == .ready)

        // Gegenstelle beendet die Verbindung (wie ein Drucker beim Neustart) und ist danach
        // unter derselben Adresse wieder erreichbar.
        await first.stop()
        let second = try await KitTestSupport.startServer(printer, port: port)
        try await Task.sleep(for: .milliseconds(200))

        do {
            try await client.printZPL("^XA^FO0,0^GB10,10,10^FS^XZ")
            #expect(try await Self.waitForLabels(printer, count: 1) == 1, "Das Etikett ging nicht verloren")
            try await client.printZPL("^XA^FO0,0^GB20,20,20^FS^XZ")
            #expect(try await Self.waitForLabels(printer, count: 2) == 2)
        } catch {
            Issue.record("Druck nach Neustart des Servers fehlgeschlagen: \(error)")
        }
        await connection.close()
        await second.stop()
    }

    @Test("Nach ~JR bzw. device.reset trennt der Server; der nächste Druck verbindet neu und kommt an")
    func printAfterRestartCommands() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        let client = await KitTestSupport.makeClient(connection)
        do {
            try await client.perform(.reset)
            // Sofort weiterdrucken – ohne Pause, in der das Verbindungsende ankommen könnte.
            try await client.printZPL("^XA^FO0,0^GB10,10,10^FS^XZ")
            #expect(try await Self.waitForLabels(printer, count: 1) == 1, "Etikett nach ~JR")
            #expect(await printer.restartCount == 1)

            var settings = try await client.networkSettings()
            settings.hostname = "lager-3"
            try await client.applyNetworkSettings(settings)
            try await client.printZPL("^XA^FO0,0^GB10,10,10^FS^XZ")
            #expect(try await Self.waitForLabels(printer, count: 2) == 2, "Etikett nach device.reset")
            #expect(await printer.restartCount == 2)
            #expect(await printer.sgdValue("ip.dhcp.option12_value") == "lager-3")
            #expect(try await client.status().state == .ready)
        } catch {
            Issue.record("Operation nach Neustartbefehl fehlgeschlagen: \(error)")
        }
        await connection.close()
        await server.stop()
    }

    @Test("Neustart beendet die TCP-Verbindung; Daten dahinter gehen verloren")
    func restartDropsConnection() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        let connection = TCPConnection(host: "127.0.0.1", port: server.port)
        try await connection.open()
        try await connection.write(Data("~JR\n^XA^FO0,0^GB10,10,10^FS^XZ\n".utf8))
        var closed = false
        for _ in 0..<60 {
            do {
                _ = try await connection.read(timeout: .milliseconds(50))
            } catch TransportError.closedByPeer {
                closed = true
                break
            }
        }
        #expect(closed, "Der Server trennt die Verbindung beim Neustart")
        #expect(await printer.restartCount == 1)
        #expect(await printer.renderedLabels.isEmpty)

        // Neue Verbindung: Der Drucker arbeitet normal weiter.
        let fresh = TCPConnection(host: "127.0.0.1", port: server.port)
        let client = await KitTestSupport.makeClient(fresh)
        try await client.printZPL("^XA^FO0,0^GB10,10,10^FS^XZ")
        #expect(try await Self.waitForLabels(printer, count: 1) == 1)
        await connection.close()
        await fresh.close()
        await server.stop()
    }

    @Test("Belegter Port führt zu listenFailed")
    func portInUse() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        await #expect(throws: VirtualPrinterServerError.self) {
            try await VirtualPrinterServer.run(port: server.port, host: "127.0.0.1", printer: printer) { _ in }
        }
        await server.stop()
    }

    @Test("Abbruch beendet den Server mit CancellationError und gibt den Port frei")
    func cancellation() async throws {
        let printer = try await KitTestSupport.makePrinter(id: "cancel-test")
        await printer.close()
        let server = try await KitTestSupport.startServer(printer)
        #expect(await printer.isOpen)
        server.task.cancel()
        let result = await server.task.result
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Server endete ohne Abbruchfehler")
        }
        #expect(await printer.isOpen == false, "Der Server schließt den Drucker, den er selbst geöffnet hat")
        // Port ist wieder frei.
        let again = try await KitTestSupport.startServer(printer)
        await again.stop()
    }
}

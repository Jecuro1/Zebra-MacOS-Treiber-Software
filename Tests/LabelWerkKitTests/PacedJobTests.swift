import Foundation
import Testing
@testable import LabelWerkKit

// MARK: - Hilfen

/// Sammelt Ereignisse eines Auftrags (aus beliebigen Threads).
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PacedJobEvent] = []

    func append(_ event: PacedJobEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [PacedJobEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var waitReasons: [PacedJobWaitReason] {
        events.compactMap { if case .waiting(let reason, _, _) = $0 { return reason } else { return nil } }
    }

    var progress: [Int] {
        events.compactMap { if case .progress(let printed, _) = $0 { return printed } else { return nil } }
    }

    func contains(_ predicate: (PacedJobEvent) -> Bool) -> Bool { events.contains(where: predicate) }
}

/// Verbindung um einen virtuellen Drucker, die Verbindungsabbrüche und einen stummen Drucker simuliert.
private actor FlakyConnection: PrinterConnection {
    nonisolated let descriptor: ConnectionDescriptor
    let printer: VirtualPrinter
    private var broken = false
    private var opened = true
    private var failWriteContaining: String?
    private var dropReplyContaining: String?
    private(set) var muted = false
    private(set) var opens = 0

    init(printer: VirtualPrinter) {
        self.printer = printer
        self.descriptor = printer.descriptor
    }

    /// Die Verbindung bricht ab: Lesen/Schreiben scheitern, bis neu geöffnet wird.
    func breakConnection() { broken = true }
    /// Das nächste Schreiben, das `text` enthält, scheitert (und bricht die Verbindung ab).
    func failWrite(containing text: String) { failWriteContaining = text }
    /// Antworten des Druckers verwerfen (Drucker ohne `~HS`).
    func mute(_ on: Bool) { muted = on }
    /// Antworten verwerfen, die `text` enthalten (z. B. Drucker ohne `^HW`).
    func dropReplies(containing text: String?) { dropReplyContaining = text }

    /// Wie bei TCP bemerkt die Verbindung den Abbruch erst beim nächsten Lesen/Schreiben.
    var isOpen: Bool { opened }

    func open() async throws {
        opens += 1
        broken = false
        opened = true
        try await printer.open()
    }

    func close() async {
        opened = false
    }

    func write(_ data: Data) async throws {
        guard opened, !broken else { throw TransportError.ioError("Verbindung unterbrochen") }
        if let marker = failWriteContaining, String(decoding: data, as: UTF8.self).contains(marker) {
            failWriteContaining = nil
            broken = true
            throw TransportError.ioError("Verbindung beim Senden unterbrochen")
        }
        try await printer.write(data)
    }

    func read(timeout: Duration) async throws -> Data {
        guard opened, !broken else { throw TransportError.ioError("Verbindung unterbrochen") }
        let data = try await printer.read(timeout: timeout)
        if let text = dropReplyContaining, String(decoding: data, as: UTF8.self).contains(text) { return Data() }
        return muted ? Data() : data
    }
}

private enum Paced {
    /// Schnelle Abfragen für Tests.
    static let options = PacedJobOptions(pollInterval: .milliseconds(5), waitPollInterval: .milliseconds(25),
                                         statusTimeout: .milliseconds(500), maxReconnectAttempts: 5,
                                         reconnectDelay: .milliseconds(10), maxSilentPolls: 3)

    /// ZPL-Auftrag mit je einem Format pro Etikett („L1“ …), Kopf und Ende.
    static func job(labels: Int, quantity: Int = 1, prefix: String = "L") -> Data {
        var text = "~JA\n~SD15\n^XA^MFF,F^XZ\n"
        for index in 1...labels {
            text += "^XA\n^MTT\n^PW400\n^LL200\n^FO10,10^A0N,30,30^FD\(prefix)\(index)^FS\n^PQ\(quantity)\n^XZ\n"
        }
        return Data(text.utf8)
    }

    static func expectedLog(labels: Int, quantity: Int = 1, prefix: String = "L") -> [String] {
        (1...labels).flatMap { index in Array(repeating: "\(prefix)\(index)", count: quantity) }
    }

    /// Wartet (höchstens `seconds`), bis `condition` erfüllt ist.
    static func waitUntil(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

// MARK: - Zerlegen

@Suite("PacedJobPlan – Auftrag in Etiketten zerlegen")
struct PacedJobPlanTests {

    @Test("Kopf, druckende Formate samt vorangehender Daten, Rest – lückenlos")
    func splitsJobEncoderShape() throws {
        let text = "~JA\n~SD15\n^XA^MFF,F^XZ\n^XA\n^FO0,0^FDA^FS\n^PQ1\n^XZ\n^XA^ST01,02,2026,10,00,00,M^XZ\n"
            + "^XA^FO0,0^FDB^FS^PQ3,0,0,N^XZ\nENDE\n"
        let plan = PacedJobPlan.split(Data(text.utf8))
        #expect(String(decoding: plan.prologue, as: UTF8.self) == "~JA\n~SD15\n")
        #expect(plan.segments.count == 2)
        #expect(String(decoding: plan.segments[0].data, as: UTF8.self) == "^XA^MFF,F^XZ\n^XA\n^FO0,0^FDA^FS\n^PQ1\n^XZ")
        #expect(String(decoding: plan.segments[1].data, as: UTF8.self)
                == "\n^XA^ST01,02,2026,10,00,00,M^XZ\n^XA^FO0,0^FDB^FS^PQ3,0,0,N^XZ")
        #expect(plan.segments.map(\.quantity) == [1, 3])
        #expect(plan.totalLabels == 4)
        #expect(String(decoding: plan.epilogue, as: UTF8.self) == "\nENDE\n")
        let joined = plan.prologue + plan.segments.reduce(Data()) { $0 + $1.data } + plan.epilogue
        #expect(joined == Data(text.utf8))
    }

    @Test("Eigene Steuerzeichen („Intern“): übergeben und erkannt")
    func customPrefixes() throws {
        let text = "$JA\n$SD10\n@XA@FO0;0@FDX@FS@PQ2@XZ\n@XA@FO0;0@FDY@FS@XZ\n"
        let given = ControlCharacters(formatPrefix: UInt8(ascii: "@"), controlPrefix: UInt8(ascii: "$"),
                                      delimiter: UInt8(ascii: ";"))
        let plan = PacedJobPlan.split(Data(text.utf8), characters: given)
        #expect(plan.segments.map(\.quantity) == [2, 1])
        #expect(String(decoding: plan.prologue, as: UTF8.self) == "$JA\n$SD10\n")

        let detected = PacedJobPlan.detectCharacters(in: Data(text.utf8))
        #expect(detected.formatPrefix == UInt8(ascii: "@"))
        #expect(detected.controlPrefix == UInt8(ascii: "$"))
        #expect(PacedJobPlan.split(Data(text.utf8)).segments.count == 2)
        // Standardzeichen werden als solche erkannt.
        #expect(PacedJobPlan.detectCharacters(in: Data("~JA\n^XA^XZ".utf8)).isStandard)
    }

    @Test("Binärdaten (^GFB, ~DY) beenden kein Format")
    func skipsBinaryData() throws {
        var bytes = Data("^XA^FO0,0^GFB,6,6,1,".utf8)
        bytes += Data("^XZ^XA".utf8)            // 6 Binärbytes, die wie Befehle aussehen
        bytes += Data("^FS^PQ2^XZ\n".utf8)
        var job = Data("~DYR:LOGO,B,G,4,1,".utf8) + Data("^XA^".utf8)   // Binärdaten mit „^XA“
        job += bytes
        let plan = PacedJobPlan.split(job)
        #expect(plan.segments.count == 1)
        #expect(plan.segments[0].quantity == 2)
        #expect(plan.prologue.count == job.count - plan.segments[0].data.count - plan.epilogue.count)
        #expect(String(decoding: plan.epilogue, as: UTF8.self) == "\n")
    }

    @Test("Nicht druckende Formate (^DF, Einstellungen) zählen nicht als Etikett")
    func nonPrintingFormats() {
        let text = "^XA^DFR:FORM.ZPL^FO0,0^FN1^FS^XZ\n^XA^MMT^PR4^XZ\n^XA^XFR:FORM.ZPL^FN1^FDA^FS^XZ\n^XA^JUS^XZ\n"
        let plan = PacedJobPlan.split(Data(text.utf8))
        #expect(plan.segments.count == 1)
        #expect(plan.totalLabels == 1)
        #expect(String(decoding: plan.epilogue, as: UTF8.self) == "\n^XA^JUS^XZ\n")
        // Ohne druckende Formate bleibt alles im Rest.
        let none = PacedJobPlan.split(Data("~SD10\n^XA^MMT^XZ\n".utf8))
        #expect(none.segments.isEmpty)
        #expect(none.prologue + none.epilogue == Data("~SD10\n^XA^MMT^XZ\n".utf8))
    }

    @Test("Menge ersetzen (Rest nach Verbindungsabbruch)")
    func withQuantity() {
        let plan = PacedJobPlan.split(Data("^XA^FDA^FS^PQ12,0,0,N^XZ".utf8))
        let segment = try! #require(plan.segments.first)
        #expect(segment.quantity == 12)
        let rest = segment.withQuantity(3)
        #expect(String(decoding: rest.data, as: UTF8.self) == "^XA^FDA^FS^PQ3,0,0,N^XZ")
        #expect(rest.quantity == 3)
        #expect(rest.withQuantity(100).quantity == 100)
        #expect(String(decoding: rest.withQuantity(100).data, as: UTF8.self) == "^XA^FDA^FS^PQ100,0,0,N^XZ")
    }

    @Test("JobEncoder-Auftrag: ein Segment je Etikett, auch mit eigenen Steuerzeichen")
    func jobEncoderOutput() throws {
        let images = [KitTestSupport.gradientImage(width: 64, height: 40), KitTestSupport.gradientImage(width: 64, height: 40)]
        var settings = PrintSettings()
        settings.cancelJobsBeforePrint = true
        settings.darkness = 12
        let plain = try JobEncoder(language: .zpl, resolution: .dpi203, settings: settings, stock: nil)
            .encode(images: images, copies: 3, collate: true)
        let plan = PacedJobPlan.split(plain)
        #expect(plan.segments.count == 6)
        #expect(plan.totalLabels == 6)
        #expect(plan.prologue + plan.segments.reduce(Data()) { $0 + $1.data } + plan.epilogue == plain)

        settings.controlCharacters = ControlCharacters(formatPrefix: UInt8(ascii: "@"), controlPrefix: UInt8(ascii: "#"),
                                                       delimiter: UInt8(ascii: ";"))
        let custom = try JobEncoder(language: .zpl, resolution: .dpi203, settings: settings, stock: nil)
            .encode(images: images, copies: 2, collate: true)
        #expect(PacedJobPlan.split(custom, characters: settings.effectiveControlCharacters).totalLabels == 4)
        let detected = PacedJobPlan.split(custom)
        #expect(detected.totalLabels == 4)
        #expect(detected.characters.formatPrefix == UInt8(ascii: "@"))
        #expect(detected.characters.controlPrefix == UInt8(ascii: "#"))
    }
}

// MARK: - Virtueller Drucker mit Druckzeit

@Suite("VirtualPrinter – Druckzeit, Puffer, Fehler mitten im Etikett, ^JZ")
struct VirtualPrinterEngineTests {

    @Test("Mit Druckzeit meldet ~HS Formate im Puffer und Restetiketten")
    func timedStatus() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(200))
        _ = try await KitTestSupport.exchange(printer, "^XA^FO0,0^FDA^FS^PQ3^XZ^XA^FO0,0^FDB^FS^XZ")
        let status = try HostStatusParser.parse(Data(try await KitTestSupport.exchange(printer, "~HS").utf8))
        #expect(status.formatsInReceiveBuffer == 1)       // B wartet, A wird gedruckt
        // 3 × A + 1 × B (unter Last kann das erste A schon fertig sein).
        #expect((3...4).contains(status.labelsRemainingInBatch))
        #expect(await Paced.waitUntil { await printer.printLog == ["A", "A", "A", "B"] })
        let idle = try HostStatusParser.parse(Data(try await KitTestSupport.exchange(printer, "~HS").utf8))
        #expect(!idle.isBusy)
    }

    @Test("Papier leer mitten im Etikett: ^JZY druckt es erneut, ^JZN verliert es")
    func reprintSemantics() async throws {
        for reprint in [true, false] {
            let printer = try await KitTestSupport.makePrinter()
            await printer.setPrintTime(.milliseconds(5))
            _ = try await KitTestSupport.exchange(printer, reprint ? "^XA^JZY^XZ" : "^XA^JZN^XZ")
            #expect(await printer.reprintsAfterError == reprint)
            await printer.scheduleFault(.mediaOut, afterLabels: 2)
            _ = try await KitTestSupport.exchange(printer, "^XA^FO0,0^FDX^FS^PQ5^XZ")
            #expect(await Paced.waitUntil { await printer.isMediaOut })
            #expect(await printer.printLog.count == 2)
            await printer.setMediaOut(false)
            #expect(await Paced.waitUntil { await !printer.isPrintingOrQueued })
            #expect(await printer.printLog.count == (reprint ? 5 : 4))
            #expect(await printer.spoiledLabels == (reprint ? 0 : 1))
        }
    }

    @Test("Simulationsvariable print_time_ms")
    func printTimeVariable() async throws {
        let printer = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(printer, "! U1 setvar \"labelwerk.simulation.print_time_ms\" \"40\"\r\n")
        #expect(await printer.currentPrintTime == .milliseconds(40))
        let reply = try await KitTestSupport.exchange(printer, "! U1 getvar \"labelwerk.simulation.print_time_ms\"\r\n")
        #expect(reply.contains("\"40\""))
        _ = try await KitTestSupport.exchange(printer, "! U1 setvar \"labelwerk.simulation.print_time_ms\" \"0\"\r\n")
        #expect(await printer.currentPrintTime == nil)
    }
}

// MARK: - Sender

@Suite("PacedJobSender – Etikett für Etikett, warten und fortsetzen")
struct PacedJobSenderTests {

    private func makeTimedPrinter(printTime: Duration = .milliseconds(8)) async throws -> (VirtualPrinter, PrinterClient) {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(printTime)
        // Der Sender muss ^JZY selbst setzen.
        await printer.setReprintAfterError(false)
        let client = await KitTestSupport.makeClient(printer)
        return (printer, client)
    }

    @Test("Ohne Störung: jedes Etikett genau einmal, höchstens ein Format im Drucker")
    func plainRun() async throws {
        let (printer, client) = try await makeTimedPrinter()
        let log = EventLog()
        let result = try await PacedJobSender(client: client, options: Paced.options)
            .send(Paced.job(labels: 6), cancelPrefixLength: 4, delayMilliseconds: 5, onEvent: log.append)
        #expect(result == PacedJobResult(printed: 6, total: 6, paced: true))
        #expect(await printer.printLog == Paced.expectedLog(labels: 6))
        #expect(await printer.reprintsAfterError)
        #expect(log.events.first == .started(total: 6, paced: true))
        #expect(log.events.last == .finished(printed: 6, total: 6))
        #expect(log.progress == Array(0...6))
        let received = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(received.contains("~JA\n~SD15\n^XA^JZY^XZ\n"))
    }

    @Test("Papier, Farbband, Druckkopf: Auftrag wartet und druckt danach jedes Etikett genau einmal",
          arguments: [VirtualPrinter.Fault.mediaOut, .ribbonOut, .headOpen])
    func resumesAfterFault(_ fault: VirtualPrinter.Fault) async throws {
        let (printer, client) = try await makeTimedPrinter()
        await printer.scheduleFault(fault, afterLabels: 3, clearAfter: .milliseconds(150))
        let log = EventLog()
        let result = try await PacedJobSender(client: client, options: Paced.options)
            .send(Paced.job(labels: 8), onEvent: log.append)
        #expect(result.printed == 8)
        #expect(await printer.printLog == Paced.expectedLog(labels: 8))
        #expect(await printer.spoiledLabels == 0)
        let expected: PacedJobWaitReason = fault == .mediaOut ? .mediaOut : fault == .ribbonOut ? .ribbonOut : .headOpen
        #expect(log.waitReasons == [expected])
        #expect(log.contains { if case .waiting(_, let printed, _) = $0 { return printed == 3 } else { return false } })
        #expect(log.contains { if case .resumed = $0 { return true } else { return false } })
    }

    @Test("Pause nach behobenem Fehler wird mit ~PS aufgehoben")
    func resumesPauseAfterFault() async throws {
        let (printer, client) = try await makeTimedPrinter()
        await printer.scheduleFault(.mediaOut, afterLabels: 2, clearAfter: .milliseconds(100), pauseAfterRecovery: true)
        let log = EventLog()
        try await PacedJobSender(client: client, options: Paced.options).send(Paced.job(labels: 5), onEvent: log.append)
        #expect(await printer.printLog == Paced.expectedLog(labels: 5))
        #expect(log.contains { $0 == .resumeSent })
        #expect(await !printer.isPaused)
    }

    @Test("Pause-Taste ohne Fehler: Auftrag wartet, bis der Drucker fortgesetzt wird")
    func waitsForManualPause() async throws {
        let (printer, client) = try await makeTimedPrinter()
        await printer.setPaused(true)
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: Paced.options).send(Paced.job(labels: 3), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { log.waitReasons == [.paused] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await printer.printLog.isEmpty)
        #expect(!log.contains { $0 == .resumeSent })
        await printer.setPaused(false)
        _ = try await job.value
        #expect(await printer.printLog == Paced.expectedLog(labels: 3))
    }

    @Test("^PQ > 1: Fortschritt Etikett für Etikett, Papier leer mitten in der Menge")
    func quantityProgress() async throws {
        let (printer, client) = try await makeTimedPrinter(printTime: .milliseconds(60))
        await printer.scheduleFault(.mediaOut, afterLabels: 4, clearAfter: .milliseconds(100))
        let log = EventLog()
        let result = try await PacedJobSender(client: client, options: Paced.options)
            .send(Paced.job(labels: 2, quantity: 5), onEvent: log.append)
        #expect(result.total == 10)
        #expect(await printer.printLog == Paced.expectedLog(labels: 2, quantity: 5))
        // Zwischenstände innerhalb eines Formats werden gemeldet.
        #expect(log.progress.contains(2))
        #expect(log.progress.contains(7))
        #expect(log.progress == log.progress.sorted())
    }

    @Test("Abbrechen sendet ~JA und hinterlässt keinen Rest im Drucker")
    func cancel() async throws {
        let (printer, client) = try await makeTimedPrinter(printTime: .milliseconds(30))
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: Paced.options).send(Paced.job(labels: 20), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { (log.progress.last ?? 0) >= 2 })
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
        #expect(log.contains { if case .cancelled = $0 { return true } else { return false } })
        #expect(await Paced.waitUntil { await !printer.isPrintingOrQueued })
        try await Task.sleep(for: .milliseconds(80))
        let printedCount = await printer.printLog.count
        #expect(printedCount < 20)
        let received = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(received.hasSuffix("~JA"))
    }

    @Test("EPL bzw. Drucker ohne ~HS-Antwort: Versand in einem Stück")
    func unpacedFallback() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let flaky = FlakyConnection(printer: printer)
        await flaky.mute(true)
        let client = await KitTestSupport.makeClient(flaky)
        let log = EventLog()
        let result = try await PacedJobSender(client: client, options: Paced.options).send(Paced.job(labels: 3), onEvent: log.append)
        #expect(result.paced == false)
        #expect(log.contains { if case .unpaced = $0 { return true } else { return false } })
        #expect(await printer.printLog == Paced.expectedLog(labels: 3))

        let eplClient = await KitTestSupport.makeClient(printer, language: .epl)
        let eplLog = EventLog()
        let epl = try await PacedJobSender(client: eplClient).send(Data("N\nA10,10,0,1,1,1,N,\"X\"\nP1\n".utf8),
                                                                   onEvent: eplLog.append)
        #expect(epl.paced == false)
        #expect(eplLog.contains { if case .unpaced = $0 { return true } else { return false } })
    }

    @Test("Verbindungsabbruch während des Drucks: neu verbinden, nichts doppelt")
    func reconnectWhilePrinting() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(20))
        let flaky = FlakyConnection(printer: printer)
        let client = await KitTestSupport.makeClient(flaky)
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: Paced.options).send(Paced.job(labels: 6), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { (log.progress.last ?? 0) >= 2 })
        await flaky.breakConnection()
        _ = try await job.value
        #expect(log.contains { if case .connectionLost = $0 { return true } else { return false } })
        #expect(log.contains { $0 == .reconnected })
        #expect(await printer.printLog == Paced.expectedLog(labels: 6))
    }

    @Test("Verbindungsabbruch beim Senden eines Etiketts: erneut senden, genau einmal gedruckt")
    func reconnectWhileSending() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(5))
        let flaky = FlakyConnection(printer: printer)
        await flaky.failWrite(containing: "^FDL3^FS")
        let client = await KitTestSupport.makeClient(flaky)
        let log = EventLog()
        try await PacedJobSender(client: client, options: Paced.options).send(Paced.job(labels: 5), onEvent: log.append)
        #expect(log.contains { $0 == .resending(labels: 1) })
        #expect(await printer.printLog == Paced.expectedLog(labels: 5))
    }

    @Test("Drucker bei „Papier leer“ aus- und eingeschaltet: restliche Exemplare erneut gesendet")
    func powerCycleDuringFault() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(5))
        await printer.scheduleFault(.mediaOut, afterLabels: 2)
        let flaky = FlakyConnection(printer: printer)
        let client = await KitTestSupport.makeClient(flaky)
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: Paced.options)
                .send(Paced.job(labels: 1, quantity: 5, prefix: "P"), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { log.waitReasons == [.mediaOut] })
        // Neue Rolle, Drucker aus und wieder an: Puffer leer, Verbindung weg.
        await flaky.breakConnection()
        await printer.restartDevice()
        await printer.setMediaOut(false)
        _ = try await job.value
        #expect(log.contains { $0 == .resending(labels: 3) })
        #expect(await printer.printLog == Array(repeating: "P1", count: 5))
    }

    @Test("Nur die Verbindung bricht bei „Papier leer“ ab, Rolle wird währenddessen eingelegt: nichts doppelt")
    func networkDropDuringFault() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(5))
        await printer.scheduleFault(.mediaOut, afterLabels: 2)
        let flaky = FlakyConnection(printer: printer)
        let client = await KitTestSupport.makeClient(flaky)
        var options = Paced.options
        options.reconnectDelay = .milliseconds(300)
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: options)
                .send(Paced.job(labels: 1, quantity: 5, prefix: "P"), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { log.waitReasons == [.mediaOut] })
        // WLAN weg, Drucker bleibt an: Er behält den Puffer und druckt nach dem Einlegen allein weiter.
        await flaky.breakConnection()
        await printer.setMediaOut(false)
        let result = try await job.value
        #expect(await printer.printLog == Array(repeating: "P1", count: 5))
        #expect(!log.contains { if case .resending = $0 { return true } else { return false } })
        #expect(result.uncertain == 0)
        #expect(log.contains { $0 == .reconnected })
    }

    @Test("Drucker mitten in der Menge ohne Fehler aus- und eingeschaltet: Rest erneut gesendet")
    func restartWithoutFault() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(60))
        await printer.setReprintAfterError(false)
        let flaky = FlakyConnection(printer: printer)
        let client = await KitTestSupport.makeClient(flaky)
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: Paced.options)
                .send(Paced.job(labels: 1, quantity: 5, prefix: "P"), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { await printer.printLog.count >= 2 })
        try await Task.sleep(for: .milliseconds(25))   // der Sender hat „3 Restexemplare“ gesehen
        await flaky.breakConnection()
        await printer.restartDevice()
        _ = try await job.value
        #expect(log.contains { $0 == .resending(labels: 3) })
        #expect(await printer.printLog == Array(repeating: "P1", count: 5))
        #expect(await printer.reprintsAfterError, "^JZY nach dem Neustart nicht erneut gesetzt")
    }

    @Test("Drucker ohne ^HW-Antwort: nach einem Abbruch nichts wiederholen, sondern melden")
    func markerUnsupported() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setPrintTime(.milliseconds(5))
        await printer.scheduleFault(.mediaOut, afterLabels: 2)
        let flaky = FlakyConnection(printer: printer)
        await flaky.dropReplies(containing: "bytes free")
        let client = await KitTestSupport.makeClient(flaky)
        var options = Paced.options
        options.reconnectDelay = .milliseconds(300)
        let log = EventLog()
        let job = Task {
            try await PacedJobSender(client: client, options: options)
                .send(Paced.job(labels: 1, quantity: 5, prefix: "P"), onEvent: log.append)
        }
        #expect(await Paced.waitUntil { log.waitReasons == [.mediaOut] })
        await flaky.breakConnection()
        await printer.setMediaOut(false)
        let result = try await job.value
        #expect(await printer.printLog == Array(repeating: "P1", count: 5))
        #expect(log.contains { $0 == .uncertain(labels: 3) })
        #expect(result.uncertain == 3)
    }
}

@Suite("Neustart-Merker – Befehle und ^HW-Antwort")
struct VolatileMarkerTests {

    @Test("Befehle mit Standard- und eigenen Steuerzeichen")
    func commands() {
        #expect(VolatileMarker.storeCommand("R:LWAPP.GRF", characters: .standard) == "~DGR:LWAPP.GRF,1,1,00\n")
        #expect(VolatileMarker.queryCommand("R:LWAPP.GRF", characters: .standard) == "^XA^HWR:LWAPP.GRF^XZ\n")
        #expect(VolatileMarker.deleteCommand("R:LWAPP.GRF", characters: .standard) == "^XA^IDR:LWAPP.GRF^XZ\n")
        let custom = ControlCharacters(formatPrefix: UInt8(ascii: "!"), controlPrefix: UInt8(ascii: "#"),
                                       delimiter: UInt8(ascii: ";"))
        #expect(VolatileMarker.storeCommand("R:LWAPP.GRF", characters: custom) == "#DGR:LWAPP.GRF;1;1;00\n")
        #expect(VolatileMarker.queryCommand("R:LWAPP.GRF", characters: custom) == "!XA!HWR:LWAPP.GRF!XZ\n")
    }

    @Test("Dateiliste auswerten: Eintrag, nur Kopfzeile, ähnlicher Name, ~HS davor, unvollständig")
    func parsing() {
        let present = Data("\u{02}\r\n- DIR R:LWAPP.GRF\r\n*R:LWAPP.GRF        1\r\n\r\n-  794292 bytes free R:RAM\r\n\u{03}\r\n".utf8)
        #expect(VolatileMarker.listed("R:LWAPP.GRF", in: present) == true)
        #expect(VolatileMarker.replyComplete(present))
        let absent = Data("\u{02}\r\n- DIR R:LWAPP.GRF\r\n\r\n-  794293 bytes free R:RAM\r\n\u{03}".utf8)
        #expect(VolatileMarker.listed("R:LWAPP.GRF", in: absent) == false)
        let similar = Data("\u{02}- DIR R:*.*\r\n*R:LWAPP.GRF2 1\r\n-1 bytes free\u{03}".utf8)
        #expect(VolatileMarker.listed("R:LWAPP.GRF", in: similar) == false)
        let hostStatus = Data("\u{02}030,0,0,0609,000,0,0,0,000,0,0,0\u{03}\r\n".utf8)
        #expect(VolatileMarker.listed("R:LWAPP.GRF", in: hostStatus) == nil)
        #expect(!VolatileMarker.replyComplete(hostStatus))
        #expect(VolatileMarker.listed("R:LWAPP.GRF", in: hostStatus + present) == true)
        #expect(!VolatileMarker.replyComplete(present.prefix(present.count - 4)))
    }

    @Test("Virtueller Drucker: Merker im RAM, nach Neustart weg")
    func virtualPrinter() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.storeVolatileMarker("R:LWAPP.GRF", characters: .standard)
        #expect(try await client.volatileMarkerExists("R:LWAPP.GRF", characters: .standard, timeout: .seconds(2)) == true)
        await printer.restartDevice()
        #expect(try await client.volatileMarkerExists("R:LWAPP.GRF", characters: .standard, timeout: .seconds(2)) == false)
        try await client.storeVolatileMarker("R:LWAPP.GRF", characters: .standard)
        await client.deleteVolatileMarker("R:LWAPP.GRF", characters: .standard)
        #expect(try await client.volatileMarkerExists("R:LWAPP.GRF", characters: .standard, timeout: .seconds(2)) == false)
    }
}

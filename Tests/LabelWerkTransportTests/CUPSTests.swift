import Foundation
import Testing
@testable import LabelWerkTransport

@Suite("CUPSQueueLister")
struct CUPSQueueListerTests {
    static let englishOutput = """
    device for Zebra_ZD421: usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J222602341
    device for Lager: socket://192.168.1.20:9100
    device for Büro Drucker: dnssd://Zebra%20ZT410%20%5BB%C3%BCro%5D._pdl-datastream._tcp.local./?uuid=1234
    device for HP_LaserJet: ipp://10.0.0.5/ipp/print
    device for Null: ///dev/null

    """

    static let germanOutput = """
    Gerät für Zebra_ZD421: usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J222602341
    Gerät für Versand Halle 2: lpd://192.168.7.3/queue
    Gerät für Etiketten:Links: socket://192.168.1.21
    """

    @Test("lpstat -v (englisch)")
    func parseEnglish() {
        let entries = CUPSQueueLister.parseLpstatV(Self.englishOutput)
        #expect(entries.map(\.name) == ["Zebra_ZD421", "Lager", "Büro Drucker", "HP_LaserJet", "Null"])
        #expect(entries[0].uri == "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J222602341")
        #expect(entries[1].uri == "socket://192.168.1.20:9100")
        #expect(entries[2].uri.hasPrefix("dnssd://Zebra%20ZT410"))
        #expect(entries[4].uri == "///dev/null")
    }

    @Test("lpstat -v (deutsch, Leerzeichen und Doppelpunkte im Namen)")
    func parseGerman() {
        let entries = CUPSQueueLister.parseLpstatV(Self.germanOutput)
        #expect(entries.count == 3)
        #expect(entries[0].name == "Zebra_ZD421")
        #expect(entries[1].name == "Versand Halle 2")
        #expect(entries[1].uri == "lpd://192.168.7.3/queue")
        #expect(entries[2].name == "Etiketten:Links")
        #expect(entries[2].uri == "socket://192.168.1.21")
    }

    @Test("lpstat -v: Windows-Zeilenenden, unbekannte Sprache, Müll")
    func parseRobust() {
        let text = "device for A: socket://1.2.3.4\r\nperiferica per B: usb://Zebra/ZD420\r\nlpstat: Scheduler is not running.\r\nkein Doppelpunkt\r\n"
        let entries = CUPSQueueLister.parseLpstatV(text)
        #expect(entries.map(\.name) == ["A", "B"])
        #expect(entries.map(\.uri) == ["socket://1.2.3.4", "usb://Zebra/ZD420"])
        #expect(CUPSQueueLister.parseLpstatV("").isEmpty)
    }

    @Test("lpstat -d")
    func parseDefault() {
        #expect(CUPSQueueLister.parseLpstatD("system default destination: Zebra_ZD421\n") == "Zebra_ZD421")
        #expect(CUPSQueueLister.parseLpstatD("Standardziel des Systems: Lager\n") == "Lager")
        #expect(CUPSQueueLister.parseLpstatD("no system default destination\n") == nil)
        #expect(CUPSQueueLister.parseLpstatD("Kein systemweites Standardziel\n") == nil)
        #expect(CUPSQueueLister.parseLpstatD("lpstat: Scheduler is not running.\n") == nil)
        #expect(CUPSQueueLister.parseLpstatD("") == nil)
    }

    @Test("lpoptions -p")
    func parseOptions() {
        let text = #"copies=1 device-uri=usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J222602341 finishings=3 job-hold-until=no-hold marker-change-time=0 printer-info='Zebra ZD421' printer-is-accepting-jobs=true printer-make-and-model='Zebra ZD421 (203 dpi) – LabelWerk' printer-location=Lager\ Halle\ 2 printer-state=3 printer-type=8425492 empty="#
        let options = CUPSQueueLister.parseLpoptions(text)
        #expect(options["copies"] == "1")
        #expect(options["printer-info"] == "Zebra ZD421")
        #expect(options["printer-make-and-model"] == "Zebra ZD421 (203 dpi) – LabelWerk")
        #expect(options["printer-location"] == "Lager Halle 2")
        #expect(options["device-uri"]?.hasPrefix("usb://Zebra%20Technologies/") == true)
        #expect(options["empty"] == "")
        #expect(CUPSQueueLister.parseLpoptions(#"a="x y" b='z' c"#) == ["a": "x y", "b": "z", "c": ""])
    }

    @Test("Modellhinweis aus Geräte-URI (Prozentdekodierung)")
    func modelHints() {
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J222602341")
            == "ZTC ZD421-203dpi ZPL")
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "usb://Zebra/LP2844?location=14100000") == "LP2844")
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "dnssd://Zebra%20ZT410%20%5BB%C3%BCro%5D._pdl-datastream._tcp.local./?uuid=1")
            == "Zebra ZT410 [Büro]")
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "socket://192.168.1.20:9100") == nil)
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "ipp://10.0.0.5/ipp/print") == nil)
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "usb://Zebra%20Technologies") == nil)
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "kein-uri") == nil)
        #expect(CUPSQueueLister.modelHint(fromDeviceURI: "usb://Zebra/ZD%ZZ") == "ZD%ZZ")
    }

    @Test("Zebra-Erkennung von Warteschlangen")
    func zebraQueues() {
        let usb = CUPSQueueInfo(name: "Q1", deviceURI: "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL", isDefault: false)
        #expect(usb.looksLikeZebra)
        #expect(usb.modelHint == "ZTC ZD421-203dpi ZPL")
        let socket = CUPSQueueInfo(name: "Lager", deviceURI: "socket://1.2.3.4", isDefault: true, makeAndModel: "Zebra ZD421 (203 dpi) – LabelWerk")
        #expect(socket.looksLikeZebra)
        #expect(socket.modelHint == "Zebra ZD421 (203 dpi) – LabelWerk")
        let office = CUPSQueueInfo(name: "HP", deviceURI: "ipp://10.0.0.5/ipp/print", isDefault: false, makeAndModel: "HP LaserJet Pro M404")
        #expect(!office.looksLikeZebra)
        let named = CUPSQueueInfo(name: "ZDesigner_GK420d", deviceURI: "socket://1.2.3.5", isDefault: false)
        #expect(named.looksLikeZebra)
    }

    @Test("queues() liefert ohne laufenden CUPS-Dienst ein Ergebnis ohne Absturz")
    func queuesDoesNotCrash() async {
        let queues = await CUPSQueueLister.queuesAsync()
        // Auf CI-Systemen läuft meist kein cupsd: dann leer. Läuft er, sind Namen und URIs gesetzt.
        for queue in queues {
            #expect(!queue.name.isEmpty)
            #expect(!queue.deviceURI.isEmpty)
        }
    }
}

@Suite("CUPSQueueConnection")
struct CUPSQueueConnectionTests {
    /// Legt ein ausführbares Shell-Skript als Ersatz für `lp`/`lpstat` an.
    static func makeScript(_ body: String) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelwerk-cups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tool.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    @Test("write() übergibt die Rohdaten unverändert an lp")
    func writeUsesLp() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("labelwerk-lp-\(UUID().uuidString).bin")
        let arguments = FileManager.default.temporaryDirectory.appendingPathComponent("labelwerk-lp-\(UUID().uuidString).args")
        let lp = try Self.makeScript("echo \"$@\" > '\(arguments.path)'\ncat > '\(output.path)'\necho 'request id is Q-1 (1 file(s))'")
        let lpstat = try Self.makeScript("echo \"device for $2: socket://127.0.0.1\"")
        defer {
            try? FileManager.default.removeItem(at: lp.directory)
            try? FileManager.default.removeItem(at: lpstat.directory)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: arguments)
        }
        let connection = CUPSQueueConnection(queue: "Zebra_ZD421", jobTitle: "Test", lpPath: lp.url.path, lpstatPath: lpstat.url.path)
        #expect(connection.descriptor == .cupsQueue(name: "Zebra_ZD421"))
        #expect(connection.descriptor.supportsBidirectional == false)
        await #expect(throws: TransportError.notOpen) { try await connection.write(Data([0x41])) }
        try await connection.open()
        #expect(await connection.isOpen)

        var payload = Data("^XA^FO50,50^A0N,40^FDÄÖÜ ß^FS^XZ\n".utf8)
        payload.append(contentsOf: (0...255).map { UInt8($0) })
        payload.append(Data(repeating: 0x5A, count: 300_000))
        try await connection.write(payload)
        #expect(try Data(contentsOf: output) == payload)
        let args = try String(contentsOf: arguments, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(args == "-d Zebra_ZD421 -o raw -t Test")

        let (empty, elapsed) = try await measure { try await connection.read(timeout: .milliseconds(100)) }
        #expect(empty.isEmpty)
        #expect(elapsed >= .milliseconds(90))
        await connection.close()
        #expect(await connection.isOpen == false)
    }

    @Test("Fehler von lp werden abgebildet")
    func lpErrors() async throws {
        let missing = try Self.makeScript("cat > /dev/null\necho 'lp: The printer or class does not exist.' >&2\nexit 1")
        let lpstat = try Self.makeScript("exit 0")
        defer {
            try? FileManager.default.removeItem(at: missing.directory)
            try? FileManager.default.removeItem(at: lpstat.directory)
        }
        let connection = CUPSQueueConnection(queue: "Fehlt", jobTitle: "T", lpPath: missing.url.path, lpstatPath: lpstat.url.path)
        try await connection.open()
        await #expect(throws: TransportError.deviceNotFound("Die CUPS-Warteschlange „Fehlt“ existiert nicht.")) {
            try await connection.write(Data("^XA^XZ".utf8))
        }

        // lp beendet sich, ohne die Eingabe zu lesen (großer Auftrag): kein Absturz durch SIGPIPE.
        let early = try Self.makeScript("echo 'lp: Forbidden' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: early.directory) }
        let rejecting = CUPSQueueConnection(queue: "Q", jobTitle: "T", lpPath: early.url.path, lpstatPath: lpstat.url.path)
        try await rejecting.open()
        do {
            try await rejecting.write(Data(repeating: 0x41, count: 2_000_000))
            Issue.record("write() hätte fehlschlagen müssen")
        } catch let error as TransportError {
            #expect(error == .permissionDenied("lp: Forbidden"))
        }
    }

    @Test("open() prüft die Warteschlange und das Vorhandensein von lp")
    func openChecks() async throws {
        let lpstat = try Self.makeScript("echo 'lpstat: Invalid destination name in list \"Fehlt\"!' >&2\nexit 1")
        let lp = try Self.makeScript("cat > /dev/null")
        defer {
            try? FileManager.default.removeItem(at: lpstat.directory)
            try? FileManager.default.removeItem(at: lp.directory)
        }
        let unknown = CUPSQueueConnection(queue: "Fehlt", jobTitle: "T", lpPath: lp.url.path, lpstatPath: lpstat.url.path)
        await #expect(throws: TransportError.deviceNotFound("Die CUPS-Warteschlange „Fehlt“ existiert nicht.")) {
            try await unknown.open()
        }
        let noLp = CUPSQueueConnection(queue: "Q", jobTitle: "T", lpPath: "/nicht/vorhanden/lp", lpstatPath: nil)
        do {
            try await noLp.open()
            Issue.record("open() hätte fehlschlagen müssen")
        } catch let error as TransportError {
            guard case .unsupported = error else { Issue.record("Unerwartet: \(error)"); return }
        }
        let invalidName = CUPSQueueConnection(queue: "mit leerzeichen", jobTitle: "T", lpPath: lp.url.path, lpstatPath: nil)
        await #expect(throws: TransportError.self) { try await invalidName.open() }
    }

    @Test("Fehlertexte (englisch/deutsch)")
    func messageMapping() {
        func map(_ text: String) -> TransportError {
            CUPSQueueConnection.mapMessage(text, status: 1, queue: "Q", tool: "lp")
        }
        #expect(map("lp: The printer or class does not exist.") == .deviceNotFound("Die CUPS-Warteschlange „Q“ existiert nicht."))
        #expect(map("lp: Der Drucker oder die Klasse existiert nicht.") == .deviceNotFound("Die CUPS-Warteschlange „Q“ existiert nicht."))
        #expect(map("lp: Forbidden") == .permissionDenied("lp: Forbidden"))
        #expect(map("lp: Destination \"Q\" is not accepting jobs.") == .ioError("Die Warteschlange „Q“ nimmt derzeit keine Aufträge an."))
        if case .connectionFailed = map("lp: Scheduler is not running.") {} else { Issue.record("Scheduler-Fehler falsch abgebildet") }
        #expect(map("") == .ioError("„lp“ wurde mit Status 1 beendet."))
        #expect(map("lp: Irgendetwas") == .ioError("lp: Irgendetwas"))
        #expect(CUPSQueueConnection.isValidQueueName("Zebra_ZD421-2.0"))
        #expect(!CUPSQueueConnection.isValidQueueName("a b"))
        #expect(!CUPSQueueConnection.isValidQueueName("a/b"))
        #expect(!CUPSQueueConnection.isValidQueueName("-d"))
        #expect(!CUPSQueueConnection.isValidQueueName(""))
    }
}

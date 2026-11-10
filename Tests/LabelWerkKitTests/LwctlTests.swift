import Foundation
import Testing
@testable import LabelWerkKit

/// Startet das gebaute `lwctl` als eigenen Prozess.
enum CLIRunner {

    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var output: String { String(decoding: stdout, as: UTF8.self) }
        var errors: String { String(decoding: stderr, as: UTF8.self) }
    }

    struct RunnerError: Error, CustomStringConvertible {
        var description: String
    }

    /// Pfad zu `lwctl`: `LWCTL_PATH`, sonst neben dem Testprogramm (SwiftPM legt alle Produkte
    /// in dasselbe Build-Verzeichnis), sonst `.build/debug` des Pakets.
    static func executable() throws -> URL {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["LWCTL_PATH"], fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        var directories: [URL] = []
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        directories.append(argv0.deletingLastPathComponent())
        for bundle in Bundle.allBundles + [Bundle.main] {
            directories.append(bundle.bundleURL.deletingLastPathComponent())
            directories.append(bundle.bundleURL)
        }
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        directories.append(packageRoot.appendingPathComponent(".build/debug"))
        for directory in directories {
            let candidate = directory.appendingPathComponent("lwctl")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw RunnerError(description: "lwctl wurde nicht gefunden (gesucht in \(directories.map(\.path))). "
                          + "Bitte zuerst „swift build“ ausführen oder LWCTL_PATH setzen.")
    }

    /// Führt `lwctl` aus und wartet auf das Ende.
    static func run(_ arguments: [String], stdin: Data? = nil, environment: [String: String] = [:],
                    workingDirectory: URL? = nil) async throws -> Result {
        let url = try executable()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            Thread.detachNewThread {
                do {
                    let process = Process()
                    process.executableURL = url
                    process.arguments = arguments
                    var env = ProcessInfo.processInfo.environment
                    env.removeValue(forKey: "LWCTL_PRINTER")
                    for (key, value) in environment { env[key] = value }
                    process.environment = env
                    if let workingDirectory { process.currentDirectoryURL = workingDirectory }
                    let output = Pipe(), errors = Pipe(), input = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    process.standardInput = input
                    try process.run()
                    if let stdin { input.fileHandleForWriting.write(stdin) }
                    try? input.fileHandleForWriting.close()
                    let collector = DataCollector()
                    let group = DispatchGroup()
                    group.enter()
                    Thread.detachNewThread {
                        collector.setErrors(errors.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    let stdout = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    continuation.resume(returning: Result(status: process.terminationStatus, stdout: stdout,
                                                          stderr: collector.errors))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Im Hintergrund laufender `lwctl virtual-printer`.
    final class VirtualPrinterProcess: @unchecked Sendable {
        let process: Process
        let port: Int

        init(process: Process, port: Int) {
            self.process = process
            self.port = port
        }

        /// Beendet den Server mit SIGINT und liefert den Rückgabewert.
        func stop() async -> Int32 {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    if self.process.isRunning { self.process.interrupt() }
                    self.process.waitUntilExit()
                    continuation.resume(returning: self.process.terminationStatus)
                }
            }
        }
    }

    /// Startet `lwctl virtual-printer --port 0` und liest den gebundenen Port aus der Ausgabe.
    static func startVirtualPrinter(extra: [String] = []) async throws -> VirtualPrinterProcess {
        let url = try executable()
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let process = Process()
                    process.executableURL = url
                    process.arguments = ["virtual-printer", "--port", "0", "--host", "127.0.0.1"] + extra
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    var text = ""
                    let deadline = Date().addingTimeInterval(30)
                    while Date() < deadline {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        text += String(decoding: chunk, as: UTF8.self)
                        if let line = text.split(separator: "\n").first(where: { $0.contains("bereit auf") }),
                           let portText = line.split(separator: ":").last, let port = Int(portText) {
                            continuation.resume(returning: VirtualPrinterProcess(process: process, port: port))
                            return
                        }
                    }
                    process.terminate()
                    continuation.resume(throwing: RunnerError(description: "virtual-printer meldete keinen Port: \(text)"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Sammelt stderr eines Prozesses threadsicher.
final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func setErrors(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var errors: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("lwctl als Prozess", .serialized)
struct LwctlTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lwctl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("version, help und Aufruffehler mit Rückgabewerten")
    func basics() async throws {
        let version = try await CLIRunner.run(["version"])
        #expect(version.status == 0)
        #expect(version.output.hasPrefix("lwctl \(LabelWerkKitInfo.version)"))

        let help = try await CLIRunner.run(["help", "print"])
        #expect(help.status == 0)
        #expect(help.output.contains("--dither"))
        #expect(help.output.contains("Bilder als Etiketten drucken"))

        let unknown = try await CLIRunner.run(["drucken"])
        #expect(unknown.status == 2)
        #expect(unknown.errors.contains("Unbekannter Befehl"))

        let noPrinter = try await CLIRunner.run(["status"])
        #expect(noPrinter.status == 2)
        #expect(noPrinter.errors.contains("Kein Drucker angegeben"))

        let badOption = try await CLIRunner.run(["models", "--farbe", "rot"])
        #expect(badOption.status == 2)

        let refused = try await CLIRunner.run(["--printer", "tcp://127.0.0.1:1", "--timeout", "1", "status"])
        #expect(refused.status == 3, "Verbindungsfehler: \(refused.errors)")
    }

    @Test("models und stocks als JSON")
    func catalogJSON() async throws {
        let models = try await CLIRunner.run(["models", "--json"])
        #expect(models.status == 0)
        let decodedModels = try JSONDecoder().decode([PrinterModel].self, from: models.stdout)
        #expect(decodedModels.contains { $0.id == "zd421t" })
        #expect(decodedModels.count == ModelCatalog.shared.models.count)

        let desktop = try await CLIRunner.run(["models", "--category", "desktop"])
        #expect(desktop.status == 0)
        #expect(desktop.output.contains("Zebra ZD421t"))
        #expect(!desktop.output.contains("ZT410"))

        let stocks = try await CLIRunner.run(["stocks", "--json", "--model", "zd421t"])
        #expect(stocks.status == 0)
        let decodedStocks = try JSONDecoder().decode([LabelStock].self, from: stocks.stdout)
        #expect(decodedStocks.contains { $0.id == "w4h6in" })
    }

    @Test("render schreibt PNG-Vorschauen je Etikett")
    func render() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zpl = "^XA^FO40,40^GB300,200,8^FS^FO60,80^A0N,40^FDLabelWerk^FS^XZ^XA^FO0,0^GB100,100,100^FS^XZ"
        try Data(zpl.utf8).write(to: directory.appendingPathComponent("etikett.zpl"))
        let result = try await CLIRunner.run(["render", "etikett.zpl", "-o", "vorschau.png", "--dpmm", "12"],
                                             workingDirectory: directory)
        #expect(result.status == 0, "\(result.errors)")
        let first = try PNGCodec.decode(Data(contentsOf: directory.appendingPathComponent("vorschau.png")))
        #expect(first.width == 1200 && first.height == 1800, "4 × 6 Zoll bei 300 dpi")
        #expect(first[44, 100] == 0, "Rahmen schwarz")
        #expect(first[600, 900] == 255)
        let second = try PNGCodec.decode(Data(contentsOf: directory.appendingPathComponent("vorschau-2.png")))
        #expect(second[50, 50] == 0)
        #expect(result.output.contains("vorschau-2.png"))

        let missing = try await CLIRunner.run(["render", "fehlt.zpl", "-o", "x.png"], workingDirectory: directory)
        #expect(missing.status == 1)
    }

    @Test("encode erzeugt ZPL, EPL und CPCL im Byteformat des JobEncoder")
    func encode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = KitTestSupport.gradientImage(width: 120, height: 60)
        try PNGCodec.encode(image).write(to: directory.appendingPathComponent("bild.png"))

        let zpl = try await CLIRunner.run(["encode", "bild.png", "-o", "auftrag.zpl", "--stock", "w2h1in",
                                           "--dither", "stucki", "--fit", "contain"], workingDirectory: directory)
        #expect(zpl.status == 0, "\(zpl.errors)")
        let job = try Data(contentsOf: directory.appendingPathComponent("auftrag.zpl"))
        let stock = try #require(ModelCatalog.shared.stock(id: "w2h1in"))
        let expectedImage = ImageLayout.layout(image, for: stock, resolution: .dpi203, mode: .contain)
        let expected = try JobEncoder(language: .zpl, resolution: .dpi203,
                                      settings: PrintSettings(dither: .stucki), stock: stock)
            .encode(images: [expectedImage])
        #expect(job == expected, "lwctl encode ist byte-gleich mit JobEncoder")

        let epl = try await CLIRunner.run(["--language", "epl", "encode", "bild.png", "--stock", "w2h1in"],
                                          workingDirectory: directory)
        #expect(epl.status == 0)
        #expect(epl.stdout.starts(with: Data("\nN\nq406\n".utf8)))

        let cpcl = try await CLIRunner.run(["encode", "bild.png", "-l", "cpcl", "--stock", "w2h1in", "--copies", "3"],
                                           workingDirectory: directory)
        #expect(cpcl.status == 0)
        #expect(cpcl.output.hasPrefix("! 0 200 200 203 3\r\n"))

        let bad = try await CLIRunner.run(["encode", "bild.png", "--dither", "zufall"], workingDirectory: directory)
        #expect(bad.status == 2)
    }

    @Test("Eingebauter virtueller Drucker (virtual://) ohne Server")
    func inProcessVirtual() async throws {
        let status = try await CLIRunner.run(["-p", "virtual://demo", "status", "--json"])
        #expect(status.status == 0, "\(status.errors)")
        let snapshot = try decoder().decode(PrinterStatusSnapshot.self, from: status.stdout)
        #expect(snapshot.state == .ready)

        let terminal = try await CLIRunner.run(["-p", "virtual://demo", "terminal"],
                                               stdin: Data("~HI\n! U1 getvar \"device.product_name\"\n:ende\n".utf8))
        #expect(terminal.status == 0)
        #expect(terminal.output.contains("<STX>ZD421-203dpi,"))
        #expect(terminal.output.contains("\"ZD421t\""))

        let model = try await CLIRunner.run(["-p", "virtual://zt410-300", "info", "--json"])
        let identity = try decoder().decode(PrinterIdentity.self, from: model.stdout)
        #expect(identity.matchedModelID == "zt410")
        #expect(identity.resolution == .dpi300)
    }

    @Test("virtual-printer auf freiem Port: status --json, info, setvar/getvar, print, files")
    func virtualPrinterServer() async throws {
        let server = try await CLIRunner.startVirtualPrinter()
        let printer = "tcp://127.0.0.1:\(server.port)"
        do {
            let status = try await CLIRunner.run(["--printer", printer, "status", "--json"])
            #expect(status.status == 0, "\(status.errors)")
            let snapshot = try decoder().decode(PrinterStatusSnapshot.self, from: status.stdout)
            #expect(snapshot.state == .ready)
            #expect(snapshot.hostStatus != nil)
            let labelsBefore = try #require(snapshot.labelsPrinted)

            let info = try await CLIRunner.run(["--printer", printer, "info", "--json"])
            #expect(info.status == 0)
            let identity = try decoder().decode(PrinterIdentity.self, from: info.stdout)
            #expect(identity.matchedModelID == "zd421t")

            let setvar = try await CLIRunner.run(["--printer", printer, "setvar", "device.friendly_name", "CLI-Test"])
            #expect(setvar.status == 0)
            let getvar = try await CLIRunner.run(["--printer", printer, "getvar", "device.friendly_name"])
            #expect(getvar.output == "CLI-Test\n")

            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try PNGCodec.encode(KitTestSupport.gradientImage(width: 64, height: 64)).write(to: directory.appendingPathComponent("a.png"))
            let print = try await CLIRunner.run(["--printer", printer, "print", "a.png", "--stock", "w2h1in", "--copies", "2",
                                                 "--dither", "atkinson"], workingDirectory: directory)
            #expect(print.status == 0, "\(print.errors)")

            let upload = try await CLIRunner.run(["--printer", printer, "upload-graphic", "a.png", "--name", "Logo"],
                                                 workingDirectory: directory)
            #expect(upload.status == 0, "\(upload.errors)")
            let files = try await CLIRunner.run(["--printer", printer, "files", "--json"])
            let listed = try decoder().decode([PrinterFile].self, from: files.stdout)
            #expect(listed.map(\.id) == ["E:LOGO.GRF"])

            let after = try await CLIRunner.run(["--printer", printer, "getvar", "odometer.total_label_count"])
            #expect(Int(after.output.trimmingCharacters(in: .whitespacesAndNewlines)) == labelsBefore + 2)

            let settings = try await CLIRunner.run(["--printer", printer, "settings", "--json", "--filter", "device."])
            let decoded = try decoder().decode([String: SGDSetting].self, from: settings.stdout)
            #expect(decoded["device.friendly_name"]?.value == "CLI-Test")

            let action = try await CLIRunner.run(["--printer", printer, "action", "pause"])
            #expect(action.status == 0)
            let paused = try await CLIRunner.run(["--printer", printer, "status"])
            #expect(paused.status == 0)
            #expect(paused.output.contains("Pausiert"))

            let firmware = Data(repeating: 0x20, count: 200_000)
            try firmware.write(to: directory.appendingPathComponent("fw.bin"))
            let flash = try await CLIRunner.run(["--printer", printer, "firmware", "fw.bin", "--yes"], workingDirectory: directory)
            #expect(flash.status == 0)
            #expect(flash.errors.contains("100 %"))
        } catch {
            _ = await server.stop()
            throw error
        }
        let exit = await server.stop()
        #expect(exit == 0, "Ctrl+C beendet den virtuellen Drucker regulär")
    }

    @Test("Fehlerzustand des Druckers ergibt Rückgabewert 4")
    func printerErrorExitCode() async throws {
        let server = try await CLIRunner.startVirtualPrinter(extra: ["--model", "zd421d"])
        let printer = "tcp://127.0.0.1:\(server.port)"
        do {
            let paused = try await CLIRunner.run(["--printer", printer, "action", "pause"])
            #expect(paused.status == 0)
            let status = try await CLIRunner.run(["--printer", printer, "status"])
            #expect(status.status == 0, "Pause ist kein Fehlerzustand")
            #expect(status.output.contains("Pausiert"))

            let open = try await CLIRunner.run(["--printer", printer, "setvar", "labelwerk.simulation.head_open", "on"])
            #expect(open.status == 0)
            let failed = try await CLIRunner.run(["--printer", printer, "status"])
            #expect(failed.status == 4)
            #expect(failed.output.contains("Fehler"))
            #expect(failed.output.contains(PrinterAlert.make(.headOpen).title))

            let info = try await CLIRunner.run(["--printer", printer, "info", "--json"])
            let identity = try decoder().decode(PrinterIdentity.self, from: info.stdout)
            #expect(identity.matchedModelID == "zd421d", "Thermodirekt-Variante wird erkannt")
        } catch {
            _ = await server.stop()
            throw error
        }
        _ = await server.stop()
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}


import Foundation
import Testing
@testable import LabelWerkKit

/// `lwctl install`, `queues` und `uninstall-queue` als Prozess – ohne laufenden CUPS-Dienst:
/// Probeläufe (`--dry-run`) gegen den virtuellen Drucker bzw. ohne Verbindung (`--model`) und
/// Attrappen von `lpadmin`/`lp`, die in `$PATH` vor den Systemwerkzeugen liegen.
@Suite("lwctl install: Netzwerkdrucker einrichten", .serialized)
struct LwctlInstallTests {

    /// JSON-Ausgabe von `install --json`.
    private struct Plan: Decodable {
        var printer: String
        var deviceURI: String
        var queue: String
        var description: String
        var location: String?
        var detected: Bool
        var detectedProduct: String?
        var serialNumber: String?
        var model: String?
        var resolution: Int
        var language: String
        var ppd: String
        var genericPPD: Bool
        var stock: String?
        var pageSize: String?
        var labelSize: String?
        var labelWidth: Int?
        var labelHeight: Int?
        var addedPageSize: Bool
        var queuePPD: String
        var setDefault: Bool
        var testPage: Bool
        var dryRun: Bool
        var commands: [[String]]
        var existing: Bool
        var reused: Bool
        var keptSettings: [String]
        var warnings: [String]
        var installed: Bool
    }

    /// JSON-Zeile von `queues --json`.
    private struct QueueRow: Decodable {
        var name: String
        var deviceURI: String
        var isDefault: Bool
        var labelWerk: Bool
    }

    /// Dokumentations-Adresse (TEST-NET-1): wird nie kontaktiert, weil `--model` die Erkennung abschaltet.
    private let offlinePrinter = "tcp://192.0.2.10"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lwctl-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Ordner mit Attrappen-PPDs (Inhalt egal: lwctl wählt nur die Datei aus).
    private func ppdDirectory(_ names: [String]) throws -> URL {
        let directory = try temporaryDirectory()
        for name in names {
            try Data("*PPD-Adobe: \"4.3\"\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    /// Die angezeigten Befehle („$ …“) ohne Programmpfad: `/usr/sbin/lpadmin -p …` → `lpadmin -p …`.
    private func commandLines(_ output: String) -> [String] {
        output.split(separator: "\n").filter { $0.hasPrefix("$ ") }.map { line in
            let text = line.dropFirst(2)
            let program = text.prefix { $0 != " " }
            return String(program.split(separator: "/").last ?? program) + String(text.dropFirst(program.count))
        }
    }

    private func decodePlan(_ result: CLIRunner.Result) throws -> Plan {
        try JSONDecoder().decode(Plan.self, from: result.stdout)
    }

    /// Eingerichtete Warteschlange für die CUPS-Attrappen.
    private struct StubQueue {
        var name: String
        var uri: String
        /// `printer-make-and-model` (Treiberbezeichnung).
        var makeAndModel: String
        /// `printer-info` (Beschreibung).
        var info: String
        /// Inhalt von `$CUPS_SERVERROOT/ppd/<name>.ppd` (`nil`: keine Datei).
        var ppd: String?
    }

    /// Attrappen der CUPS-Werkzeuge in `directory/bin` (in `$PATH` vor den Systemwerkzeugen):
    /// `lpstat -v`/`lpoptions -p` melden `queues`, `lpadmin` und `lp` protokollieren ihre Aufrufe
    /// (Programmname, Argumente, „--“) in `calls.log`. `$CUPS_SERVERROOT` zeigt auf
    /// `directory/cups` mit den PPDs der Warteschlangen.
    private func stubCUPS(in directory: URL, queues: [StubQueue]) throws -> (environment: [String: String], log: URL) {
        let fileManager = FileManager.default
        let bin = directory.appendingPathComponent("bin")
        let options = directory.appendingPathComponent("lpoptions")
        let serverRoot = directory.appendingPathComponent("cups")
        for folder in [bin, options, serverRoot.appendingPathComponent("ppd")] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let log = directory.appendingPathComponent("calls.log")
        func executable(_ name: String, _ script: String) throws {
            let url = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for tool in ["lpadmin", "lp"] {
            // lpadmin legt eine Kopie der übergebenen PPD (-P) als „lpadmin-P.ppd“ ab.
            try executable(tool, """
            #!/bin/sh
            printf '%s\\n' "\(tool)" >> '\(log.path)'
            previous=""
            for argument in "$@"; do
                printf '%s\\n' "$argument" >> '\(log.path)'
                if [ "$previous" = "-P" ] && [ -f "$argument" ]; then cp "$argument" '\(directory.path)/lpadmin-P.ppd'; fi
                previous="$argument"
            done
            printf -- '--\\n' >> '\(log.path)'
            echo "\(tool): Printer drivers are deprecated and will stop working in a future version of CUPS." >&2
            exit 0
            """)
        }
        let devices = directory.appendingPathComponent("lpstat-v.txt")
        try Data(queues.map { "device for \($0.name): \($0.uri)\n" }.joined().utf8).write(to: devices)
        try executable("lpstat", """
            #!/bin/sh
            case "$1" in
                -v) cat '\(devices.path)' ;;
                -d) echo 'no system default destination' ;;
            esac
            exit 0
            """)
        try executable("lpoptions", """
            #!/bin/sh
            [ "$1" = "-p" ] && [ -f '\(options.path)/'"$2" ] && cat '\(options.path)/'"$2"
            exit 0
            """)
        for queue in queues {
            try Data("printer-info='\(queue.info)' printer-make-and-model='\(queue.makeAndModel)'\n".utf8)
                .write(to: options.appendingPathComponent(queue.name))
            if let ppd = queue.ppd {
                try Data(ppd.utf8).write(to: serverRoot.appendingPathComponent("ppd/\(queue.name).ppd"))
            }
        }
        let path = "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
        return (["PATH": path, "CUPS_SERVERROOT": serverRoot.path], log)
    }

    /// Protokollierte Aufrufe der Attrappen, je Aufruf Programmname und Argumente.
    private func loggedCalls(_ log: URL) throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .split(separator: "--").map { $0.map(String.init) }
    }

    /// PPD einer LabelWerk-Warteschlange (Ausschnitt, CRLF wie bei manchen Editoren) mit geänderten
    /// Standardwerten: Schwärzung 15, Etikett 2 × 4 Zoll, gedreht.
    private let labelWerkQueuePPD = """
        *PPD-Adobe: "4.3"\r
        *NickName: "Zebra ZD421t (203 dpi) - LabelWerk"\r
        *lwModel: "zd421t"\r
        *DefaultColorSpace: Gray\r
        *OpenUI *PageSize/Media Size: PickOne\r
        *DefaultPageSize: w144h288\r
        *CloseUI: *PageSize\r
        *OpenUI *PageRegion/Media Size: PickOne\r
        *DefaultPageRegion: w144h288\r
        *CloseUI: *PageRegion\r
        *DefaultImageableArea: w144h288\r
        *OpenUI *Resolution/Resolution: PickOne\r
        *DefaultResolution: 203dpi\r
        *CloseUI: *Resolution\r
        *OpenUI *lwLanguage/Printer Language: PickOne\r
        *DefaultlwLanguage: ZPL\r
        *CloseUI: *lwLanguage\r
        *OpenUI *lwDarkness/Darkness: PickOne\r
        *DefaultlwDarkness: 15\r
        *CloseUI: *lwDarkness\r
        *OpenUI *lwRotate180: Boolean\r
        *DefaultlwRotate180: True\r
        *CloseUI: *lwRotate180\r

        """

    // MARK: - Erkennung

    @Test("--model auto erkennt den ZD421t am virtuellen Drucker und wählt LabelWerk-zd421t-203dpi.ppd")
    func autoDetectDryRun() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let server = try await KitTestSupport.startServer(printer)
        let ppds = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd", "LabelWerk-zd421t-300dpi.ppd.gz",
                                     "LabelWerk-generic-zpl-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let uri = "tcp://127.0.0.1:\(server.port)"
        let ppd = ppds.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd").path
        do {
            let text = try await CLIRunner.run(["install", "--printer", uri, "--ppd-dir", ppds.path, "--dry-run"])
            #expect(text.status == 0, "\(text.errors)")
            #expect(commandLines(text.output) == [
                "lpadmin -p Zebra_ZD421t_127.0.0.1 -E -v socket://127.0.0.1:\(server.port) -P \(ppd) "
                    + "-D 'Zebra ZD421t (127.0.0.1)' -o printer-is-shared=false",
            ])
            #expect(text.output.contains("Modell:         Zebra ZD421t (zd421t)"))
            #expect(text.output.contains("Probelauf"))

            let json = try await CLIRunner.run(["install", "-p", uri, "--ppd-dir", ppds.path, "--dry-run", "--json"])
            #expect(json.status == 0, "\(json.errors)")
            let plan = try decodePlan(json)
            #expect(plan.detected)
            #expect(plan.detectedProduct == "ZD421t")
            #expect(plan.serialNumber == printer.serialNumber)
            #expect(plan.model == "zd421t")
            #expect(plan.resolution == 203)
            #expect(plan.language == "zpl")
            #expect(plan.ppd == ppd)
            #expect(!plan.genericPPD)
            #expect(plan.queue == "Zebra_ZD421t_127.0.0.1")
            #expect(plan.deviceURI == "socket://127.0.0.1:\(server.port)")
            #expect(plan.dryRun && !plan.installed)
            #expect(plan.commands.count == 1)
            #expect(Array(plan.commands[0].dropFirst()) == [
                "-p", "Zebra_ZD421t_127.0.0.1", "-E", "-v", "socket://127.0.0.1:\(server.port)", "-P", ppd,
                "-D", "Zebra ZD421t (127.0.0.1)", "-o", "printer-is-shared=false",
            ])
            #expect(await printer.renderedLabels.isEmpty, "Die Erkennung druckt nichts")
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test("Erkennung eines 300-dpi-Druckers wählt die 300-dpi-PPD")
    func autoDetectResolution() async throws {
        let model = try #require(ModelCatalog.shared.model(id: "zt410"))
        let printer = try await KitTestSupport.makePrinter(model: model, resolution: .dpi300)
        let server = try await KitTestSupport.startServer(printer)
        let ppds = try ppdDirectory(["LabelWerk-zt410-203dpi.ppd.gz", "LabelWerk-zt410-300dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        do {
            let result = try await CLIRunner.run(["install", "-p", "127.0.0.1:\(server.port)", "--ppd-dir", ppds.path,
                                                  "--name", "Versand", "--dry-run", "--json"])
            #expect(result.status == 0, "\(result.errors)")
            let plan = try decodePlan(result)
            #expect(plan.model == "zt410")
            #expect(plan.resolution == 300)
            #expect(plan.ppd == ppds.appendingPathComponent("LabelWerk-zt410-300dpi.ppd.gz").path)
            #expect(plan.queue == "Versand")
            #expect(plan.description == "Versand")
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test("Nicht erreichbarer Drucker: Rückgabewert 3 mit Hinweis auf --model")
    func unreachablePrinter() async throws {
        let ppds = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let result = try await CLIRunner.run(["install", "-p", "tcp://127.0.0.1:1", "--timeout", "1",
                                              "--ppd-dir", ppds.path, "--dry-run"])
        #expect(result.status == 3, "\(result.errors)")
        #expect(result.errors.contains("--model"))
        #expect(commandLines(result.output).isEmpty)
    }

    // MARK: - Ohne Verbindung

    @Test("Ausdrückliches Modell mit Name, Standort, Etikett, Standarddrucker und Testseite")
    func explicitModelWithOptions() async throws {
        let ppds = try ppdDirectory(["LabelWerk-zt410-203dpi.ppd.gz", "LabelWerk-zt410-300dpi.ppd.gz",
                                     "LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let stock = try #require(ModelCatalog.shared.stock(id: "w4h6in"))
        let ppd = ppds.appendingPathComponent("LabelWerk-zt410-300dpi.ppd.gz").path
        let result = try await CLIRunner.run([
            "install", "--printer", offlinePrinter, "--model", "zt410", "--dpi", "300", "--name", "Lager 1",
            "--location", "Halle 2, Tor 3", "--stock", "w4h6in", "--default", "--test-page", "--ppd-dir", ppds.path,
            "--dry-run",
        ])
        #expect(result.status == 0, "\(result.errors)")
        let lines = commandLines(result.output)
        #expect(lines.count == 3)
        #expect(lines.first == "lpadmin -p Lager_1 -E -v socket://192.0.2.10:9100 -P \(ppd) -D 'Lager 1' "
                + "-L 'Halle 2, Tor 3' -o printer-is-shared=false -o PageSize=\(stock.ppdKeyword) "
                + "-o lwLabelWidth-default=10160 -o lwLabelHeight-default=15240")
        #expect(lines.dropFirst().first == "lpadmin -d Lager_1")
        #expect(lines.last?.hasPrefix("lp -d Lager_1 -t LabelWerk-Testseite ") == true)
        #expect(!result.output.contains("Erkannt:"), "ohne Verbindung keine Erkennung")

        // Ausdrücklich gewählte Sprache wird als Standard der Warteschlange gesetzt (ZD421t: ZPL und EPL).
        let epl = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--dpi", "203", "-l", "epl",
                                           "--ppd-dir", ppds.path, "--dry-run", "--json"])
        #expect(epl.status == 0, "\(epl.errors)")
        let plan = try decodePlan(epl)
        #expect(plan.language == "epl")
        #expect(plan.commands.first.map { Array($0.suffix(2)) } == ["-o", "lwLanguage=EPL"])
        #expect(!plan.detected)
    }

    @Test("Ohne Modell-PPD greift die generische PPD (wie in der App)")
    func genericFallback() async throws {
        let ppds = try ppdDirectory(["LabelWerk-generic-zpl-203dpi.ppd.gz", "LabelWerk-generic-epl-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }

        let zpl = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "zd421t", "--ppd-dir", ppds.path,
                                           "--dry-run"])
        #expect(zpl.status == 0, "\(zpl.errors)")
        #expect(zpl.errors.contains("generische PPD LabelWerk-generic-zpl-203dpi"))
        #expect(commandLines(zpl.output).first?.contains(
            "-P \(ppds.appendingPathComponent("LabelWerk-generic-zpl-203dpi.ppd.gz").path) ") == true)

        let epl = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "generic", "--language", "epl",
                                           "--ppd-dir", ppds.path, "--dry-run", "--json"])
        #expect(epl.status == 0, "\(epl.errors)")
        let plan = try decodePlan(epl)
        #expect(plan.genericPPD)
        #expect(plan.model == nil)
        #expect(plan.language == "epl")
        #expect(plan.ppd == ppds.appendingPathComponent("LabelWerk-generic-epl-203dpi.ppd.gz").path)
        #expect(plan.queue == "Zebra_EPL_192.0.2.10")
        #expect(plan.commands.first?.contains { $0.hasPrefix("lwLanguage=") } == false,
                "Die Sprache steckt in der generischen PPD")
        #expect(plan.warnings.isEmpty, "\(plan.warnings)")

        // TLP 3842: nur EPL mit 300 dpi. Ohne 300-dpi-PPD für EPL bleibt nur die 203-dpi-PPD – mit Hinweis
        // (auch im JSON), denn so gedruckte Etiketten sind auf rund zwei Drittel verkleinert.
        let scaled = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "tlp3842", "--ppd-dir", ppds.path,
                                              "--dry-run"])
        #expect(scaled.status == 0, "\(scaled.errors)")
        #expect(scaled.errors.contains("Keine PPD für EPL2 mit 300 dpi – es wird LabelWerk-generic-epl-203dpi (EPL2, 203 dpi) verwendet"),
                "\(scaled.errors)")
        #expect(scaled.errors.contains("falsch skaliert"))
        let scaledJSON = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "tlp3842", "--ppd-dir", ppds.path,
                                                  "--dry-run", "--json"])
        #expect(scaledJSON.status == 0, "\(scaledJSON.errors)")
        #expect(scaledJSON.errors.isEmpty, "mit --json stehen Hinweise nur im Ergebnis")
        let scaledPlan = try decodePlan(scaledJSON)
        #expect(scaledPlan.resolution == 203)
        #expect(scaledPlan.warnings.contains { $0.contains("falsch skaliert") }, "\(scaledPlan.warnings)")

        // Ausdrücklich gewählte Auflösung bzw. Sprache ohne PPD: Fehler statt stillem Ersatz.
        let mismatches: [([String], String)] = [
            (["--model", "generic", "--dpi", "600", "--language", "epl"], "Keine PPD für EPL2 mit 600 dpi"),
            (["--model", "generic", "--dpi", "300"], "Keine PPD für ZPL II mit 300 dpi"),
            (["--model", "tlp3842", "--dpi", "300"], "Keine PPD für Zebra TLP 3842 mit 300 dpi"),
            (["--model", "generic", "--language", "cpcl"], "Keine PPD für CPCL mit 203 dpi"),
        ]
        for (options, message) in mismatches {
            let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "--ppd-dir", ppds.path, "--dry-run"] + options)
            #expect(result.status == 1, "\(options): \(result.errors)")
            #expect(result.errors.contains(message), "\(options): \(result.errors)")
            #expect(commandLines(result.output).isEmpty, "\(options)")
        }
    }

    @Test("--stock muss auf den Drucker passen (sonst verwirft lpadmin die Papiergröße stillschweigend)")
    func stockMustFit() async throws {
        let ppds = try ppdDirectory(["LabelWerk-zd410-203dpi.ppd.gz", "LabelWerk-generic-zpl-203dpi.ppd.gz",
                                     "LabelWerk-generic-cpcl-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        // ZD410: 56 mm Druckbreite – 4 × 6 Zoll passt nicht, das Standardformat 2 × 1 Zoll schon.
        let wide = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd410", "--stock", "w4h6in",
                                            "--ppd-dir", ppds.path, "--dry-run"])
        #expect(wide.status == 2, "\(wide.errors)")
        #expect(wide.errors.contains("passt nicht auf Zebra ZD410 (Druckbreite 56 mm"), "\(wide.errors)")
        #expect(wide.errors.contains("lwctl stocks --model zd410"))
        #expect(commandLines(wide.output).isEmpty)
        let fitting = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd410", "--stock", "w2h1in",
                                               "--ppd-dir", ppds.path, "--dry-run", "--json"])
        #expect(fitting.status == 0, "\(fitting.errors)")
        #expect(try decodePlan(fitting).pageSize == ModelCatalog.shared.stock(id: "w2h1in")?.ppdKeyword)

        // Ohne Katalogmodell: Grenzen der generischen PPD (größtes Modell der Sprache).
        let cpcl = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "generic", "-l", "cpcl",
                                            "--stock", "w8h6in", "--ppd-dir", ppds.path, "--dry-run"])
        #expect(cpcl.status == 2, "\(cpcl.errors)")
        #expect(cpcl.errors.contains("passt nicht auf die generische CPCL-PPD"), "\(cpcl.errors)")
        let zpl = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "generic", "--stock", "w8h6in",
                                           "--ppd-dir", ppds.path, "--dry-run"])
        #expect(zpl.status == 0, "ZPL-Modelle bis 216 mm Druckbreite: \(zpl.errors)")
    }

    @Test("Fehlende PPD bzw. fehlender PPD-Ordner: Rückgabewert 1")
    func missingPPD() async throws {
        let empty = try ppdDirectory([])
        defer { try? FileManager.default.removeItem(at: empty) }
        let missing = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "zd421t", "--ppd-dir", empty.path,
                                               "--dry-run"])
        #expect(missing.status == 1)
        #expect(missing.errors.contains("Keine passende PPD-Datei"))
        #expect(missing.errors.contains("LabelWerk-zd421t-203dpi.ppd.gz"))
        #expect(commandLines(missing.output).isEmpty)

        let noDirectory = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "zd421t",
                                                   "--ppd-dir", empty.appendingPathComponent("fehlt").path, "--dry-run"])
        #expect(noDirectory.status == 1)
        #expect(noDirectory.errors.contains("existiert nicht"))
    }

    @Test("Ungültige URIs und Optionen: Rückgabewert 2, ohne Verbindungsversuch")
    func invalidArguments() async throws {
        let ppds = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let cases: [([String], String)] = [
            (["install", "--dry-run"], "Kein Drucker angegeben"),
            (["install", "-p", "tcp://drucker:99999"], "Ungültige Drucker-URI"),
            (["install", "-p", "tcp://zwei worte"], "Ungültige Drucker-URI"),
            (["install", "-p", "tcp://drucker/pfad"], "Ungültige Drucker-URI"),
            (["install", "-p", "usb://0a5f:0181"], "Netzwerkdrucker"),
            (["install", "-p", "cups://Versand"], "Netzwerkdrucker"),
            (["install", "-p", offlinePrinter, "--model", "zx999"], "Unbekanntes Modell"),
            (["install", "-p", offlinePrinter, "--model", "zd421t", "--dpi", "600"], "600 dpi"),
            (["install", "-p", offlinePrinter, "--model", "zd421t", "--dpi", "250"], "--dpi"),
            (["install", "-p", offlinePrinter, "--model", "zd421t", "--language", "cpcl"], "CPCL"),
            (["install", "-p", offlinePrinter, "--model", "zd421t", "--stock", "gibtsnicht"], "Etikettenformat"),
            (["install", "-p", offlinePrinter, "--model", "zd410", "--stock", "w4h6in"], "passt nicht auf Zebra ZD410"),
            (["install", "-p", offlinePrinter, "--model", "zd421t", "--name", " "], "--name"),
            (["install", "-p", offlinePrinter, "extra"], "Falscher Aufruf"),
        ]
        for (arguments, message) in cases {
            let result = try await CLIRunner.run(arguments + ["--ppd-dir", ppds.path, "--dry-run"])
            #expect(result.status == 2, "\(arguments): \(result.errors)")
            #expect(result.errors.contains(message), "\(arguments): \(result.errors)")
            #expect(commandLines(result.output).isEmpty, "\(arguments)")
        }
    }

    // MARK: - Ausführung (Attrappen)

    @Test("Ohne --dry-run: genau die angezeigten Befehle werden ausgeführt (lpadmin/lp-Attrappen)")
    func executesShownCommands() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ppds = directory.appendingPathComponent("ppd")
        try FileManager.default.createDirectory(at: ppds, withIntermediateDirectories: true)
        try Data().write(to: ppds.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd.gz"))
        let (environment, log) = try stubCUPS(in: directory, queues: [])
        let bin = directory.appendingPathComponent("bin")

        let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "zd421t", "--ppd-dir", ppds.path,
                                              "--default", "--test-page", "--json"], environment: environment)
        #expect(result.status == 0, "\(result.errors)")
        #expect(!result.errors.contains("deprecated"), "Der CUPS-Hinweis auf veraltete Treiber wird ausgeblendet")
        let plan = try decodePlan(result)
        #expect(plan.installed && !plan.dryRun)
        #expect(plan.commands.count == 3)
        #expect(plan.commands.allSatisfy { $0.first?.hasPrefix(bin.path) == true }, "Werkzeuge aus $PATH")
        let expected = plan.commands.map { command in
            [URL(fileURLWithPath: command[0]).lastPathComponent] + command.dropFirst()
        }
        #expect(try loggedCalls(log) == expected)
        #expect(!plan.existing && !plan.reused && plan.keptSettings.isEmpty)

        // Fehlende Rechte: Rückgabewert 1 mit Hinweis auf sudo.
        try Data("#!/bin/sh\necho 'lpadmin: Forbidden' >&2\nexit 1\n".utf8).write(to: bin.appendingPathComponent("lpadmin"))
        let forbidden = try await CLIRunner.run(["install", "-p", offlinePrinter, "--model", "zd421t", "--ppd-dir", ppds.path],
                                                environment: environment)
        #expect(forbidden.status == 1)
        #expect(forbidden.errors.contains("Forbidden"))
        #expect(forbidden.errors.contains("sudo lwctl install"))
        #expect(!forbidden.output.contains("Fertig"))
    }

    // MARK: - Vorhandene Warteschlangen (CUPS-Attrappen)

    @Test("Eine fremde Warteschlange gleichen Namens wird nur mit --replace ersetzt – auch im Probelauf geprüft")
    func refusesExistingQueueOfSameName() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ppds = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let (environment, log) = try stubCUPS(in: directory, queues: [
            StubQueue(name: "Versand", uri: "socket://10.0.0.5:9100", makeAndModel: "HP LaserJet 4000 Series",
                      info: "Versand Büro", ppd: nil),
            StubQueue(name: "Lager", uri: "socket://192.0.2.99:9100", makeAndModel: "Zebra ZD421t (203 dpi) - LabelWerk",
                      info: "Lager", ppd: nil),
        ])
        // CUPS unterscheidet bei Namen keine Groß-/Kleinschreibung: „versand“ ist die Warteschlange „Versand“.
        for extra in [["--dry-run"], [], ["--json"]] {
            let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--name", "versand",
                                                  "--ppd-dir", ppds.path] + extra, environment: environment)
            #expect(result.status == 1, "\(extra): \(result.errors)")
            #expect(result.errors.contains(
                "Die Warteschlange „Versand“ gibt es bereits (socket://10.0.0.5:9100, HP LaserJet 4000 Series)"), "\(result.errors)")
            #expect(result.errors.contains("--replace"))
            #expect(commandLines(result.output).isEmpty, "\(extra)")
        }
        // Ebenso eine LabelWerk-Warteschlange gleichen Namens, die auf ein anderes Gerät druckt.
        let otherDevice = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--name", "Lager",
                                                   "--ppd-dir", ppds.path, "--dry-run"], environment: environment)
        #expect(otherDevice.status == 1, "\(otherDevice.errors)")
        #expect(otherDevice.errors.contains("„Lager“ gibt es bereits (socket://192.0.2.99:9100, LabelWerk-Treiber)"),
                "\(otherDevice.errors)")
        #expect(try loggedCalls(log).isEmpty, "lpadmin wurde nicht aufgerufen")

        // --replace: dieselbe Warteschlange (Schreibweise von CUPS), Freigabe unverändert, keine fremden Standardwerte.
        let replaced = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--name", "versand",
                                                "--replace", "--ppd-dir", ppds.path, "--json"], environment: environment)
        #expect(replaced.status == 0, "\(replaced.errors)")
        let plan = try decodePlan(replaced)
        #expect(plan.queue == "Versand")
        #expect(plan.existing && !plan.reused && plan.keptSettings.isEmpty)
        #expect(plan.warnings.contains { $0.contains("„Versand“ (socket://10.0.0.5:9100, HP LaserJet 4000 Series) wird ersetzt") },
                "\(plan.warnings)")
        let ppd = ppds.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd.gz").path
        #expect(try loggedCalls(log) == [
            ["lpadmin", "-p", "Versand", "-E", "-v", "socket://192.0.2.10:9100", "-P", ppd, "-D", "versand"],
        ])
    }

    @Test("Ohne --name: Eine LabelWerk-Warteschlange desselben Druckers wird aktualisiert statt verdoppelt")
    func reusesQueueOfSameDevice() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ppds = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let (environment, _) = try stubCUPS(in: directory, queues: [
            // Gleiches Gerät mit fremdem Treiber: wird nicht gewählt.
            StubQueue(name: "Buero", uri: "socket://192.0.2.10:9100", makeAndModel: "Generic PCL Printer", info: "Büro", ppd: nil),
            // Vom Assistenten der App angelegt: anderer Name, Port weggelassen (Standard 9100).
            StubQueue(name: "Zebra_ZD421t", uri: "socket://192.0.2.10", makeAndModel: "Zebra ZD421t (203 dpi) - LabelWerk",
                      info: "Zebra ZD421t (Lager)", ppd: nil),
            StubQueue(name: "Versand", uri: "socket://ETIKETTEN-2.local.:9100", makeAndModel: "Zebra ZD421t (203 dpi) - LabelWerk",
                      info: "Versand", ppd: nil),
        ])
        let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--ppd-dir", ppds.path,
                                              "--dry-run", "--json"], environment: environment)
        #expect(result.status == 0, "\(result.errors)")
        let plan = try decodePlan(result)
        #expect(plan.queue == "Zebra_ZD421t")
        #expect(plan.reused && plan.existing)
        #expect(plan.description == "Zebra ZD421t (Lager)", "die Beschreibung der Warteschlange bleibt")
        #expect(plan.warnings.contains { $0.contains("„Zebra_ZD421t“ druckt bereits auf socket://192.0.2.10:9100") },
                "\(plan.warnings)")
        #expect(plan.commands.first?.contains("printer-is-shared=false") == false, "die Freigabe bleibt, wie sie ist")

        let text = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--ppd-dir", ppds.path,
                                            "--dry-run"], environment: environment)
        #expect(text.status == 0, "\(text.errors)")
        #expect(text.output.contains("Warteschlange:  Zebra_ZD421t (vorhanden – wird aktualisiert)"))
        #expect(text.output.contains("Ohne --dry-run wird die Warteschlange aktualisiert."))

        // Hostname in anderer Schreibweise, mit abschließendem Punkt.
        let host = try await CLIRunner.run(["install", "-p", "tcp://etiketten-2.local", "-m", "zd421t", "--ppd-dir", ppds.path,
                                            "--dry-run", "--json"], environment: environment)
        #expect(host.status == 0, "\(host.errors)")
        let hostPlan = try decodePlan(host)
        #expect(hostPlan.queue == "Versand" && hostPlan.reused)

        // Anderer Port bzw. ausdrücklicher Name: neue Warteschlange.
        for (options, queue) in [(["-p", "tcp://192.0.2.10:9101"], "Zebra_ZD421t_192.0.2.10"),
                                 (["-p", offlinePrinter, "--name", "Lager 2"], "Lager_2")] {
            let other = try await CLIRunner.run(["install", "-m", "zd421t", "--ppd-dir", ppds.path, "--dry-run", "--json"] + options,
                                                environment: environment)
            #expect(other.status == 0, "\(options): \(other.errors)")
            let otherPlan = try decodePlan(other)
            #expect(otherPlan.queue == queue && !otherPlan.existing && !otherPlan.reused, "\(options)")
            #expect(otherPlan.commands.first?.contains("printer-is-shared=false") == true)
        }
    }

    @Test("Aktualisieren behält die Einstellungen der Warteschlange (wie das Treiber-Update)")
    func keepsSettingsOfExistingQueue() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ppds = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: ppds) }
        let ppd = ppds.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd.gz").path
        let (environment, log) = try stubCUPS(in: directory, queues: [
            // Ohne Treiberbezeichnung: als LabelWerk-Warteschlange erkannt an *lwModel in ihrer PPD.
            StubQueue(name: "Etiketten", uri: "socket://192.0.2.10:9100", makeAndModel: "", info: "Etiketten",
                      ppd: labelWerkQueuePPD),
            StubQueue(name: "Ohne_PPD", uri: "socket://192.0.2.20:9100", makeAndModel: "Zebra ZD421t (203 dpi) - LabelWerk",
                      info: "Ohne PPD", ppd: nil),
        ])
        let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--name", "etiketten",
                                              "--ppd-dir", ppds.path, "--json"], environment: environment)
        #expect(result.status == 0, "\(result.errors)")
        let plan = try decodePlan(result)
        #expect(plan.existing && plan.installed)
        // Die Auflösung steckt in der gewählten PPD und wird nicht übernommen.
        // lwRotate180 steht nicht mehr in der PPD (lpadmin verwürfe es): als lwRotation=180 übernommen.
        #expect(plan.keptSettings == ["PageSize=w144h288", "PageRegion=w144h288", "lwLanguage=ZPL", "lwDarkness=15",
                                      "lwRotation=180"])
        #expect(try loggedCalls(log) == [[
            "lpadmin", "-p", "Etiketten", "-E", "-v", "socket://192.0.2.10:9100", "-P", ppd, "-D", "etiketten",
            "-o", "PageSize=w144h288", "-o", "PageRegion=w144h288", "-o", "lwLanguage=ZPL", "-o", "lwDarkness=15",
            "-o", "lwRotation=180",
        ]])

        // Ausdrücklich gewählte Werte (--stock, --language) gelten statt der bisherigen.
        let stock = try #require(ModelCatalog.shared.stock(id: "w4h6in"))
        let explicit = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--name", "Etiketten",
                                                "--stock", "w4h6in", "-l", "epl", "--ppd-dir", ppds.path, "--dry-run", "--json"],
                                               environment: environment)
        #expect(explicit.status == 0, "\(explicit.errors)")
        let explicitPlan = try decodePlan(explicit)
        #expect(explicitPlan.keptSettings == ["lwDarkness=15", "lwRotation=180"])
        #expect(explicitPlan.commands.first.map { Array($0.suffix(12)) } == [
            "-o", "lwDarkness=15", "-o", "lwRotation=180", "-o", "PageSize=\(stock.ppdKeyword)",
            "-o", "lwLabelWidth-default=10160", "-o", "lwLabelHeight-default=15240", "-o", "lwLanguage=EPL",
        ])

        // PPD der Warteschlange nicht lesbar: Hinweis statt stillem Zurücksetzen.
        let unreadable = try await CLIRunner.run(["install", "-p", "tcp://192.0.2.20", "-m", "zd421t", "--ppd-dir", ppds.path,
                                                  "--dry-run", "--json"], environment: environment)
        #expect(unreadable.status == 0, "\(unreadable.errors)")
        let unreadablePlan = try decodePlan(unreadable)
        #expect(unreadablePlan.queue == "Ohne_PPD" && unreadablePlan.keptSettings.isEmpty)
        #expect(unreadablePlan.warnings.contains { $0.contains("Die bisherigen Einstellungen von „Ohne_PPD“ sind nicht lesbar") },
                "\(unreadablePlan.warnings)")
    }

    // MARK: - Eigene Etikettengröße (--size)

    /// Ordner mit einer LabelWerk-PPD im Aufbau des Generators (ergänzbar).
    private func patchablePPDDirectory(_ name: String = "LabelWerk-zd421t-203dpi.ppd.gz") throws -> URL {
        let directory = try temporaryDirectory()
        try Data(QueuePPDSample.text.utf8).write(to: directory.appendingPathComponent(name))
        return directory
    }

    @Test("--size 104x76.2mm: benannte Seitengröße in einer Kopie der PPD, lwLabelWidth/lwLabelHeight")
    func customSizeDryRun() async throws {
        let ppds = try patchablePPDDirectory()
        defer { try? FileManager.default.removeItem(at: ppds) }
        let ppd = ppds.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd.gz").path
        let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--size", "104x76.2mm",
                                              "--ppd-dir", ppds.path, "--dry-run", "--json"])
        #expect(result.status == 0, "\(result.errors)")
        let plan = try decodePlan(result)
        #expect(plan.pageSize == "w295h216")
        #expect(plan.labelSize == "104x76.2mm")
        #expect(plan.labelWidth == 10400 && plan.labelHeight == 7620)
        #expect(plan.addedPageSize)
        #expect(plan.ppd == ppd && plan.queuePPD != ppd && plan.queuePPD.hasSuffix("-w295h216.ppd"))
        #expect(plan.stock == nil)
        let command = try #require(plan.commands.first)
        #expect(command.contains(plan.queuePPD))
        #expect(Array(command.suffix(6)) == ["-o", "PageSize=w295h216", "-o", "lwLabelWidth-default=10400",
                                             "-o", "lwLabelHeight-default=7620"])
        #expect(!FileManager.default.fileExists(atPath: plan.queuePPD), "Probelauf legt keine Datei an")

        let text = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--size", "104 x 76,2 mm",
                                            "--ppd-dir", ppds.path, "--dry-run"])
        #expect(text.status == 0, "\(text.errors)")
        #expect(text.output.contains("Etikett:        Etikett 104 × 76,2 mm (PageSize w295h216, als benannte Seitengröße ergänzt)"))

        // Steht die Größe schon in der Modell-PPD (4 × 6 Zoll), genügt -o PageSize ohne Kopie.
        let catalog = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--size", "4x6in",
                                               "--ppd-dir", ppds.path, "--dry-run", "--json"])
        #expect(catalog.status == 0, "\(catalog.errors)")
        let catalogPlan = try decodePlan(catalog)
        #expect(catalogPlan.pageSize == "w288h432" && !catalogPlan.addedPageSize && catalogPlan.queuePPD == ppd)
    }

    @Test("--size richtet die Warteschlange mit der ergänzten PPD ein und räumt die Kopie auf")
    func customSizeInstall() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ppds = try patchablePPDDirectory()
        defer { try? FileManager.default.removeItem(at: ppds) }
        let (environment, log) = try stubCUPS(in: directory, queues: [])
        let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--size", "104x76.2mm",
                                              "--name", "Versand", "--ppd-dir", ppds.path, "--json"], environment: environment)
        #expect(result.status == 0, "\(result.errors)")
        let plan = try decodePlan(result)
        #expect(plan.installed && plan.addedPageSize)
        let calls = try loggedCalls(log)
        #expect(calls.count == 1)
        #expect(calls.first?.contains(plan.queuePPD) == true)
        let copy = try String(contentsOf: directory.appendingPathComponent("lpadmin-P.ppd"), encoding: .utf8)
        #expect(copy == (try QueuePPD.patched(QueuePPDSample.text, adding: QueueLabelSize(widthMM: 104, heightMM: 76.2))))
        #expect(QueuePPD.defaultPageSize(in: copy) == "w295h216")
        #expect(!FileManager.default.fileExists(atPath: plan.queuePPD), "Kopie wird nach lpadmin entfernt")
    }

    @Test("Aktualisieren ohne --size behält eine früher ergänzte Etikettengröße")
    func keepsAddedSize() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ppds = try patchablePPDDirectory()
        defer { try? FileManager.default.removeItem(at: ppds) }
        let size = QueueLabelSize(widthMM: 104, heightMM: 76.2)
        let queuePPD = try QueuePPD.patched(QueuePPDSample.text, adding: size)
        let (environment, _) = try stubCUPS(in: directory, queues: [
            StubQueue(name: "Etiketten", uri: "socket://192.0.2.10:9100", makeAndModel: "", info: "Etiketten", ppd: queuePPD),
        ])
        let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--ppd-dir", ppds.path,
                                              "--json"], environment: environment)
        #expect(result.status == 0, "\(result.errors)")
        let plan = try decodePlan(result)
        #expect(plan.existing && plan.reused && plan.addedPageSize)
        #expect(plan.pageSize == "w295h216" && plan.labelWidth == nil)
        #expect(plan.keptSettings.contains("PageSize=w295h216"))
        let copy = try String(contentsOf: directory.appendingPathComponent("lpadmin-P.ppd"), encoding: .utf8)
        #expect(QueuePPD.addedPageSize(in: copy) == "w295h216")
    }

    @Test("--size: Fehler bei ungültiger, zu großer oder doppelter Angabe")
    func customSizeErrors() async throws {
        let ppds = try patchablePPDDirectory()
        defer { try? FileManager.default.removeItem(at: ppds) }
        for (arguments, message) in [
            (["--size", "104"], "Ungültige Etikettengröße"),
            (["--size", "120x76mm"], "passt nicht auf Zebra ZD421t"),
            (["--size", "8x3mm"], "mindestens 10 mm breit"),
            (["--size", "104x76mm", "--stock", "w4h6in"], "schließen sich aus"),
        ] {
            let result = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--ppd-dir", ppds.path,
                                                  "--dry-run"] + arguments)
            #expect(result.status == 2, "\(arguments): \(result.errors)")
            #expect(result.errors.contains(message), "\(arguments): \(result.errors)")
        }
        // Keine LabelWerk-PPD (Attrappe ohne *lwModel): Fehler statt einer Warteschlange ohne Größe.
        let dummy = try ppdDirectory(["LabelWerk-zd421t-203dpi.ppd.gz"])
        defer { try? FileManager.default.removeItem(at: dummy) }
        let foreign = try await CLIRunner.run(["install", "-p", offlinePrinter, "-m", "zd421t", "--size", "104x76.2mm",
                                               "--ppd-dir", dummy.path, "--dry-run"])
        #expect(foreign.status == 1, "\(foreign.errors)")
        #expect(foreign.errors.contains("kann nicht in"))
    }

    @Test("queues und uninstall-queue lesen die Warteschlangen mit lpstat/lpoptions aus $PATH")
    func queuesWithStubbedCUPS() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (environment, log) = try stubCUPS(in: directory, queues: [
            StubQueue(name: "Versand", uri: "socket://10.0.0.5:9100", makeAndModel: "HP LaserJet 4000 Series",
                      info: "Versand Büro", ppd: nil),
            StubQueue(name: "Etiketten", uri: "socket://192.0.2.10:9100", makeAndModel: "", info: "Etiketten",
                      ppd: labelWerkQueuePPD),
        ])
        let all = try await CLIRunner.run(["queues", "--json"], environment: environment)
        #expect(all.status == 0, "\(all.errors)")
        let rows = try JSONDecoder().decode([QueueRow].self, from: all.stdout)
        #expect(rows.map(\.name) == ["Etiketten", "Versand"])
        #expect(rows.map(\.labelWerk) == [true, false])
        let labelWerk = try await CLIRunner.run(["queues", "--labelwerk", "--json"], environment: environment)
        #expect(try JSONDecoder().decode([QueueRow].self, from: labelWerk.stdout).map(\.name) == ["Etiketten"])

        let foreign = try await CLIRunner.run(["uninstall-queue", "versand"], environment: environment)
        #expect(foreign.status == 1, "\(foreign.errors)")
        #expect(foreign.errors.contains("„Versand“ verwendet nicht den LabelWerk-Treiber"))
        #expect(try loggedCalls(log).isEmpty)
        let removed = try await CLIRunner.run(["uninstall-queue", "etiketten"], environment: environment)
        #expect(removed.status == 0, "\(removed.errors)")
        #expect(try loggedCalls(log) == [["lpadmin", "-x", "Etiketten"]])
    }

    // MARK: - queues, uninstall-queue, Hilfe

    @Test("queues und uninstall-queue ohne laufenden CUPS-Dienst")
    func queuesAndUninstall() async throws {
        let queues = try await CLIRunner.run(["queues", "--json"])
        #expect(queues.status == 0, "\(queues.errors)")
        _ = try JSONDecoder().decode([QueueRow].self, from: queues.stdout)
        let labelWerk = try await CLIRunner.run(["queues", "--labelwerk", "--json"])
        #expect(labelWerk.status == 0)
        let rows = try JSONDecoder().decode([QueueRow].self, from: labelWerk.stdout)
        #expect(rows.allSatisfy { $0.labelWerk })
        let table = try await CLIRunner.run(["queues"])
        #expect(table.status == 0)

        let name = "LabelWerk-Test-\(UUID().uuidString.prefix(8))"
        let dryRun = try await CLIRunner.run(["uninstall-queue", name, "--dry-run"])
        #expect(dryRun.status == 0, "\(dryRun.errors)")
        #expect(commandLines(dryRun.output) == ["lpadmin -x \(name)"])
        #expect(dryRun.output.contains("Probelauf"))

        let missing = try await CLIRunner.run(["uninstall-queue"])
        #expect(missing.status == 2)
    }

    @Test("Hilfe und Übersicht nennen install, queues und uninstall-queue")
    func help() async throws {
        let help = try await CLIRunner.run(["help", "install"])
        #expect(help.status == 0)
        for text in ["--ppd-dir", "--dry-run", "--test-page", "--model <auto|id|generic>", "Netzwerkdrucker", "lwctl models",
                     "--size <BxH(mm|in)>", "104x76.2mm"] {
            #expect(help.output.contains(text), "\(text)")
        }
        let overview = try await CLIRunner.run(["help"])
        for command in ["install", "queues", "uninstall-queue"] {
            #expect(overview.output.contains("  \(command) "), "\(command)")
        }
    }
}

import Foundation
import Testing
@testable import LabelWerkKit

/// Installationsbefehle des Update-Dienstes: Maskierung für `/bin/sh` und AppleScript, Neustart.
/// Die Shell-Befehle werden tatsächlich mit `/bin/sh` ausgeführt – mit Attrappen statt
/// `installer` und `open`.
@Suite("Update-Dienst: Installation und Neustart")
struct UpdateInstallerTests {

    /// Pfad mit allem, was beim Maskieren schiefgehen kann.
    static let trickyName = "O'Brien \"Ü\" $HOME `id` \\ x; rm -rf ~ 'n' ä"

    // MARK: - Hilfen

    final class Sandbox {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lw-install-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: false) }

        /// Legt ein ausführbares Shell-Skript an.
        func script(_ name: String, _ body: String) throws -> URL {
            let url = url(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        /// Attrappe für `installer`: schreibt die Argumente (eines je Zeile) und kopiert das Paket.
        func fakeInstaller(exitCode: Int = 0) throws -> URL {
            try script("installer", """
            for a in "$@"; do printf 'ARG:%s\\n' "$a"; done
            /bin/cp "$2" \(UpdateInstaller.shellQuote(url("installiert.pkg").path))
            exit \(exitCode)
            """)
        }
    }

    @discardableResult
    static func runShell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func tools(_ sandbox: Sandbox, installer: URL, shasum: String = "/usr/bin/shasum") -> UpdateInstaller.Tools {
        var tools = UpdateInstaller.Tools.macOS
        tools.installer = installer.path
        tools.temporaryBase = sandbox.directory.path
        tools.shasum = shasum
        return tools
    }

    static var hashToolAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/shasum")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")
    }

    // MARK: - Shell-Befehl

    @Test("Shell-Befehl: installer mit Protokoll, einfache Anführungszeichen")
    func shellCommandText() {
        let command = UpdateInstaller.shellCommand(
            pkg: URL(fileURLWithPath: "/Users/anna/Library/Caches/LabelWerk/Updates/LabelWerk-1.1.0-58.pkg"),
            logFile: URL(fileURLWithPath: "/Users/anna/Library/Logs/LabelWerk/update.log"))
        #expect(command == "/usr/sbin/installer -pkg '/Users/anna/Library/Caches/LabelWerk/Updates/LabelWerk-1.1.0-58.pkg'"
                + " -target / > '/Users/anna/Library/Logs/LabelWerk/update.log' 2>&1")
        #expect(UpdateInstaller.shellQuote("a'b") == "'a'\\''b'")
        #expect(UpdateInstaller.shellQuote("") == "''")
        // Ungültige Prüfsumme → einfache Variante ohne Prüfung.
        let plain = UpdateInstaller.shellCommand(pkg: URL(fileURLWithPath: "/a.pkg"), logFile: URL(fileURLWithPath: "/l"),
                                                 expectedSHA256: "xyz")
        #expect(plain == "/usr/sbin/installer -pkg '/a.pkg' -target / > '/l' 2>&1")
    }

    @Test("Shell-Befehl übergibt schwierige Pfade unverändert (mit /bin/sh ausgeführt)")
    func shellCommandQuoting() throws {
        let sandbox = try Sandbox()
        let pkgDirectory = sandbox.directory.appendingPathComponent(Self.trickyName, isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDirectory, withIntermediateDirectories: true)
        let pkg = pkgDirectory.appendingPathComponent("LabelWerk 1.1.0 (58) \(Self.trickyName).pkg")
        let payload = Data("paket".utf8)
        try payload.write(to: pkg)
        let log = sandbox.url("Protokoll \(Self.trickyName).log")
        let command = UpdateInstaller.shellCommand(pkg: pkg, logFile: log, expectedSHA256: nil,
                                                   tools: Self.tools(sandbox, installer: try sandbox.fakeInstaller()))
        #expect(try Self.runShell(command) == 0)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["ARG:-pkg", "ARG:\(pkg.path)", "ARG:-target", "ARG:/"])
        #expect(try Data(contentsOf: sandbox.url("installiert.pkg")) == payload)
    }

    @Test("Shell-Befehl meldet den Exit-Code von installer")
    func shellCommandExitCode() throws {
        let sandbox = try Sandbox()
        let pkg = sandbox.url("a.pkg")
        try Data("x".utf8).write(to: pkg)
        let command = UpdateInstaller.shellCommand(pkg: pkg, logFile: sandbox.url("log"), expectedSHA256: nil,
                                                   tools: Self.tools(sandbox, installer: try sandbox.fakeInstaller(exitCode: 1)))
        #expect(try Self.runShell(command) == 1)
    }

    @Test("Mit Prüfsumme: Kopie in privatem Ordner prüfen, dann installieren, aufräumen",
          .enabled(if: UpdateInstallerTests.hashToolAvailable))
    func shellCommandWithChecksum() throws {
        let sandbox = try Sandbox()
        let pkg = sandbox.url("Update \(Self.trickyName).pkg")
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try payload.write(to: pkg)
        let sha = SHA256Hasher.hexDigest(payload)
        let log = sandbox.url("update.log")
        let installer = try sandbox.fakeInstaller()
        var shasums = ["/nonexistent/shasum"]      // Rückfall auf openssl
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/shasum") { shasums.append("/usr/bin/shasum") }
        for shasum in shasums {
            if shasum.hasPrefix("/nonexistent"), !FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") { continue }
            let command = UpdateInstaller.shellCommand(pkg: pkg, logFile: log, expectedSHA256: sha.uppercased(),
                                                       tools: Self.tools(sandbox, installer: installer, shasum: shasum))
            #expect(try Self.runShell(command) == 0, "\(shasum)")
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(lines.count == 4 && lines[0] == "ARG:-pkg" && lines[2] == "ARG:-target" && lines[3] == "ARG:/")
            let installed = lines.count > 1 ? String(lines[1].dropFirst(4)) : ""
            #expect(installed.hasPrefix(sandbox.directory.path + "/labelwerk-update."))
            #expect(installed.hasSuffix("/update.pkg"))
            #expect(try Data(contentsOf: sandbox.url("installiert.pkg")) == payload)
            #expect(!FileManager.default.fileExists(atPath: installed))     // privater Ordner entfernt
            try FileManager.default.removeItem(at: sandbox.url("installiert.pkg"))
        }

        // Falsche Prüfsumme: installer wird nicht aufgerufen, Exit-Code 3, Meldung im Protokoll.
        let wrong = String(repeating: "0", count: 64)
        let command = UpdateInstaller.shellCommand(pkg: pkg, logFile: log, expectedSHA256: wrong,
                                                   tools: Self.tools(sandbox, installer: installer))
        #expect(try Self.runShell(command) == 3)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("Prüfsumme"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.url("installiert.pkg").path))

        // Fehlendes Paket: Exit-Code 2.
        let missing = UpdateInstaller.shellCommand(pkg: sandbox.url("fehlt.pkg"), logFile: log, expectedSHA256: sha,
                                                   tools: Self.tools(sandbox, installer: installer))
        #expect(try Self.runShell(missing) == 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)
            .filter { $0.hasPrefix("labelwerk-update.") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - AppleScript

    /// Liest ein AppleScript-Stringliteral ab `index` (nach dem öffnenden Anführungszeichen).
    static func readLiteral(_ scalars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        var out = String.UnicodeScalarView()
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" { return (String(out), index + 1) }
            if scalar == "\\" {
                guard index + 1 < scalars.count else { return nil }
                switch scalars[index + 1] {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: return nil
                }
                index += 2
                continue
            }
            if scalar == "\n" || scalar == "\r" { return nil }     // unmaskierter Umbruch
            out.append(scalar)
            index += 1
        }
        return nil
    }

    /// Zerlegt `do shell script "…" with prompt "…" with administrator privileges`.
    static func parseAppleScript(_ source: String) -> (command: String, prompt: String)? {
        let scalars = Array(source.unicodeScalars)
        func expect(_ text: String, at index: Int) -> Int? {
            let wanted = Array(text.unicodeScalars)
            guard index + wanted.count <= scalars.count, Array(scalars[index..<index + wanted.count]) == wanted else { return nil }
            return index + wanted.count
        }
        guard let a = expect("do shell script \"", at: 0),
              let (command, b) = readLiteral(scalars, from: a),
              let c = expect(" with prompt \"", at: b),
              let (prompt, d) = readLiteral(scalars, from: c),
              let e = expect(" with administrator privileges", at: d), e == scalars.count
        else { return nil }
        return (command, prompt)
    }

    @Test("AppleScript: do shell script … with administrator privileges")
    func appleScriptText() {
        let script = UpdateInstaller.appleScript(shellCommand: "echo hi",
                                                 prompt: "LabelWerk möchte das Update 1.1.0 (Build 58) installieren.")
        #expect(script == "do shell script \"echo hi\" with prompt \"LabelWerk möchte das Update 1.1.0 (Build 58) installieren.\""
                + " with administrator privileges")
        #expect(UpdateInstaller.appleScriptLiteral("a\"b\\c\nd\te\rf") == "\"a\\\"b\\\\c\\nd\\te\\rf\"")
    }

    @Test("AppleScript-Maskierung übersteht Anführungszeichen, Backslashes, Umlaute und Umbrüche", arguments: [
        "einfach",
        UpdateInstallerTests.trickyName,
        "\"\"\"\\\\\\\"",
        "Zeile 1\nZeile 2\r\n\tEingerückt",
        "Ünïcödé – „deutsch“ – 日本語 – 🙂",
        "\\\"; do shell script \"rm -rf ~\" --",
    ])
    func appleScriptRoundTrip(text: String) throws {
        let script = UpdateInstaller.appleScript(shellCommand: text, prompt: "Prompt: " + text)
        let parsed = try #require(Self.parseAppleScript(script))
        #expect(parsed.command == text)
        #expect(parsed.prompt == "Prompt: " + text)
    }

    @Test("AppleScript umschließt den vollständigen Installationsbefehl verlustfrei")
    func appleScriptWithInstallCommand() throws {
        let pkg = URL(fileURLWithPath: "/Users/o'brien/Library/Caches/LabelWerk \"Updates\"/LabelWerk-1.1.0-58.pkg")
        let command = UpdateInstaller.shellCommand(pkg: pkg, logFile: URL(fileURLWithPath: "/tmp/lw \\ log.txt"),
                                                   expectedSHA256: String(repeating: "a", count: 64))
        let parsed = try #require(Self.parseAppleScript(UpdateInstaller.appleScript(shellCommand: command, prompt: "Ä")))
        #expect(parsed.command == command)
        #expect(parsed.prompt == "Ä")
    }

    @Test("Abbruch des Passwortdialogs erkennen")
    func userCancellation() {
        #expect(UpdateInstaller.isUserCancellation("0:153: execution error: User canceled. (-128)"))
        #expect(UpdateInstaller.isUserCancellation("0:153: execution error: Vom Benutzer abgebrochen. (-128)\n"))
        #expect(!UpdateInstaller.isUserCancellation("0:153: execution error: installer: Error (1)"))
    }

    // MARK: - Neustart

    @Test("Neustart-Befehl: warten, dann open")
    func relaunchText() {
        let command = UpdateInstaller.relaunchCommand(waitingFor: 4242, appPath: "/Applications/LabelWerk.app")
        #expect(command == ["/bin/sh", "-c",
                            "i=0; while kill -0 4242 2>/dev/null && [ \"$i\" -lt 600 ]; do sleep 0.2; i=$((i+1)); done; "
                            + "/usr/bin/open '/Applications/LabelWerk.app'"])
    }

    @Test("Neustart wartet auf das Ende des Prozesses und startet den Pfad unverändert")
    func relaunchRuns() throws {
        let sandbox = try Sandbox()
        let capture = sandbox.url("geoeffnet.txt")
        let fakeOpen = try sandbox.script("open", "printf '%s' \"$1\" > \(UpdateInstaller.shellQuote(capture.path))")
        let appPath = "/Applications/\(Self.trickyName)/LabelWerk.app"

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sh")
        sleeper.arguments = ["-c", "sleep 1"]
        try sleeper.run()
        let started = Date()

        let arguments = UpdateInstaller.relaunchCommand(waitingFor: sleeper.processIdentifier, appPath: appPath,
                                                        openPath: fakeOpen.path)
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: arguments[0])
        relauncher.arguments = Array(arguments.dropFirst())
        try relauncher.run()
        // Bevor der wartende Prozess endet, darf nichts gestartet werden.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        sleeper.waitUntilExit()        // beendet und eingesammelt (kein Zombie)
        relauncher.waitUntilExit()
        #expect(relauncher.terminationStatus == 0)
        #expect(Date().timeIntervalSince(started) >= 0.8)
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(try String(contentsOf: capture, encoding: .utf8) == appPath)

        // Prozess bereits beendet → sofort starten.
        try FileManager.default.removeItem(at: capture)
        let gone = UpdateInstaller.relaunchCommand(waitingFor: sleeper.processIdentifier, appPath: "/x y.app",
                                                   openPath: fakeOpen.path)
        let quick = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gone[0])
        process.arguments = Array(gone.dropFirst())
        try process.run()
        process.waitUntilExit()
        #expect(Date().timeIntervalSince(quick) < 5)
        #expect(try String(contentsOf: capture, encoding: .utf8) == "/x y.app")
    }
}

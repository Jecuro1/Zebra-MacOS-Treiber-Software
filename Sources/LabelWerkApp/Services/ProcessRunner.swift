import Foundation

/// Führt Kommandozeilenprogramme asynchron aus (lpadmin, lpstat, lpoptions, osascript …).
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var succeeded: Bool { status == 0 }
    }

    enum RunError: LocalizedError {
        case launchFailed(String)
        case failed(command: String, status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return tr("Programm konnte nicht gestartet werden: %@", message)
            case .failed(let command, let status, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return tr("„%@“ ist fehlgeschlagen (Code %d): %@", command, Int(status), detail)
            }
        }
    }

    /// Startet `executable` mit `arguments` und wartet auf das Ende (ohne den Main-Thread zu blockieren).
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment: [String: String]? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let inPipe = Pipe()
                if input != nil { process.standardInput = inPipe }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: RunError.launchFailed(error.localizedDescription))
                    return
                }
                if let input {
                    // EPIPE (Prozess hat vorzeitig beendet) als Fehler statt SIGPIPE/Ausnahme.
                    _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inPipe.fileHandleForWriting.close()
                }
                // Ausgaben vollständig lesen, bevor auf das Prozessende gewartet wird (verhindert Deadlocks).
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Wie `run`, wirft aber bei Exit-Code ≠ 0.
    @discardableResult
    static func runChecked(_ executable: String, _ arguments: [String], input: Data? = nil) async throws -> Result {
        let result = try await run(executable, arguments, input: input)
        guard result.succeeded else {
            let name = (executable as NSString).lastPathComponent
            throw RunError.failed(command: name, status: result.status,
                                  message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    /// Führt ein Shell-Skript mit Administratorrechten aus (macOS fragt nach dem Passwort).
    @discardableResult
    static func runAsAdministrator(_ shellScript: String, prompt: String) async throws -> Result {
        let escapedScript = appleScriptEscape(shellScript)
        let escapedPrompt = appleScriptEscape(prompt)
        let source = "do shell script \"\(escapedScript)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
        return try await runChecked("/usr/bin/osascript", ["-e", source])
    }

    /// Maskiert Text für ein AppleScript-Stringliteral.
    static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Maskiert ein Argument für `/bin/sh` (einfache Anführungszeichen).
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

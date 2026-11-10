import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Ergebnis eines Hilfsprozesses (`lp`, `lpstat`, `lpoptions`, `avahi-browse`).
struct ProcessOutput: Sendable {
    var status: Int32
    var standardOutput: Data
    var standardError: Data
    /// `true`, wenn der Prozess wegen Zeitüberschreitung beendet wurde.
    var timedOut: Bool
    /// `true`, wenn der Prozess Standardeingabe nicht vollständig gelesen hat (vorzeitig beendet).
    var inputTruncated: Bool

    var succeeded: Bool { status == 0 && !timedOut }
    var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var errorText: String { String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Startet Kommandozeilenwerkzeuge synchron (auf einer Hintergrund-Queue aufzurufen).
enum ProcessRunner {
    /// Sucht ein Werkzeug: zuerst die bevorzugten Pfade, dann `/usr/bin`, `/usr/sbin`,
    /// `/usr/local/bin`, `/opt/homebrew/bin`, zuletzt `$PATH`.
    static func locate(_ name: String, preferred: [String] = []) -> URL? {
        let fileManager = FileManager.default
        var candidates = preferred
        candidates += ["/usr/bin", "/usr/sbin", "/usr/local/bin", "/opt/homebrew/bin", "/bin"].map { "\($0)/\(name)" }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Umgebung für CUPS-Werkzeuge: englische, unübersetzte Meldungen (stabile Auswertung).
    static func neutralEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["LC_MESSAGES"] = "C"
        return environment
    }

    /// Startet `executable` mit `arguments`, schreibt optional `input` auf stdin und sammelt
    /// stdout/stderr gleichzeitig (keine Verklemmung bei großen Ausgaben).
    ///
    /// Blockiert den aufrufenden Thread bis zum Prozessende oder `timeout`.
    static func run(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProcessOutput {
        ignoreSIGPIPEOnLinux()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe: Pipe? = input == nil ? nil : Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw TransportError.unsupported("„\(executable.lastPathComponent)“ konnte nicht gestartet werden (\(error.localizedDescription)).")
        }

        // stdout und stderr parallel lesen.
        let collected = LockedValue<(out: Data, err: Data)>((Data(), Data()))
        let readers = DispatchGroup()
        let outHandle = UncheckedSendable(outputPipe.fileHandleForReading)
        let errHandle = UncheckedSendable(errorPipe.fileHandleForReading)
        // Eigene serielle Queues (overcommit), damit das Warten unten nie auf einen
        // ausgelasteten globalen Thread-Pool trifft.
        BlockingIO.makeQueue("de.labelwerk.transport.process.stdout").async(group: readers) {
            let data = outHandle.value.readDataToEndOfFile()
            collected.withLock { $0.out = data }
        }
        BlockingIO.makeQueue("de.labelwerk.transport.process.stderr").async(group: readers) {
            let data = errHandle.value.readDataToEndOfFile()
            collected.withLock { $0.err = data }
        }

        // Zeitüberwachung.
        let timedOut = LockedValue(false)
        let watchedProcess = UncheckedSendable(process)
        let watchdog = DispatchWorkItem {
            if watchedProcess.value.isRunning {
                timedOut.set(true)
                watchedProcess.value.terminate()
            }
        }
        BlockingIO.makeQueue("de.labelwerk.transport.process.watchdog")
            .asyncAfter(deadline: .now() + max(0.1, timeout), execute: watchdog)

        var truncated = false
        if let inputPipe, let input {
            let writeHandle = inputPipe.fileHandleForWriting
            truncated = !writeFully(writeHandle.fileDescriptor, input)
            try? writeHandle.close()
        }

        process.waitUntilExit()
        watchdog.cancel()
        readers.wait()
        let output = collected.value
        return ProcessOutput(
            status: process.terminationStatus,
            standardOutput: output.out,
            standardError: output.err,
            timedOut: timedOut.value,
            inputTruncated: truncated
        )
    }

    /// Asynchrone Variante: führt `run` auf einer Hintergrund-Queue aus.
    static func runAsync(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> ProcessOutput {
        try await BlockingIO.run { _ in
            try run(executable, arguments: arguments, input: input, environment: environment, timeout: timeout)
        }
    }

    /// Schreibt alle Bytes in eine Pipe; `false`, wenn der Leser vorzeitig beendet wurde.
    private static func writeFully(_ fd: Int32, _ data: Data) -> Bool {
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #endif
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                #else
                let written = Glibc.write(fd, base + offset, raw.count - offset)
                #endif
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Unter Linux gibt es kein `F_SETNOSIGPIPE`; Schreiben in eine Pipe, deren Leser beendet ist,
    /// würde den Prozess per SIGPIPE beenden. Daher wird SIGPIPE einmalig ignoriert
    /// (Schreibfehler kommen dann als `EPIPE` zurück).
    private static func ignoreSIGPIPEOnLinux() {
        #if !canImport(Darwin)
        _ = sigpipeIgnored
        #endif
    }
}

#if !canImport(Darwin)
/// Einmalige Initialisierung (Swift garantiert threadsichere, einmalige Auswertung globaler Konstanten).
private let sigpipeIgnored: Bool = {
    signal(SIGPIPE, SIG_IGN)
    return true
}()
#endif

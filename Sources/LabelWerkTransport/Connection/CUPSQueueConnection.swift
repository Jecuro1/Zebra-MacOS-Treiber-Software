import Foundation

/// Sendet Rohdaten über eine bestehende CUPS-Warteschlange (`lp -d <queue> -o raw`).
///
/// Jeder `write(_:)`-Aufruf erzeugt einen eigenen CUPS-Auftrag. Die Verbindung ist nur zum
/// Senden geeignet: `read(timeout:)` wartet die Frist ab und liefert stets leere Daten.
public actor CUPSQueueConnection: PrinterConnection {
    public nonisolated let descriptor: ConnectionDescriptor
    public nonisolated let queue: String
    /// Auftragsname, wie er in der CUPS-Warteschlange erscheint.
    public nonisolated let jobTitle: String

    private let lpPath: String?
    private let lpstatPath: String?
    private var opened = false

    public init(queue: String) {
        self.init(queue: queue, jobTitle: "LabelWerk", lpPath: nil, lpstatPath: nil)
    }

    /// Erweiterte Initialisierung (Tests, andere Installationsorte der CUPS-Werkzeuge).
    ///
    /// - Parameters:
    ///   - lpPath: Pfad zu `lp`; `nil` = `/usr/bin/lp`, sonst Suche im `PATH`.
    ///   - lpstatPath: Pfad zu `lpstat` für die Existenzprüfung beim Öffnen; `nil` = Standardsuche.
    public init(queue: String, jobTitle: String, lpPath: String? = nil, lpstatPath: String? = nil) {
        self.queue = queue
        self.jobTitle = jobTitle
        self.lpPath = lpPath
        self.lpstatPath = lpstatPath
        self.descriptor = .cupsQueue(name: queue)
    }

    public var isOpen: Bool { opened }

    /// Prüft, ob `lp` vorhanden ist und die Warteschlange existiert.
    public func open() async throws {
        if opened { return }
        guard Self.isValidQueueName(queue) else {
            throw TransportError.deviceNotFound("Ungültiger Name der CUPS-Warteschlange „\(queue)“.")
        }
        _ = try locateLp()
        if let lpstat = locateLpstat() {
            let output = try await ProcessRunner.runAsync(
                lpstat, arguments: ["-v", queue],
                environment: ProcessRunner.neutralEnvironment(), timeout: 15
            )
            if !output.succeeded {
                throw Self.mapFailure(output, queue: queue, tool: "lpstat")
            }
        }
        opened = true
    }

    public func close() async {
        opened = false
    }

    /// Übergibt `data` als Rohauftrag an CUPS.
    public func write(_ data: Data) async throws {
        guard opened else { throw TransportError.notOpen }
        guard !data.isEmpty else { return }
        let lp = try locateLp()
        let arguments = ["-d", queue, "-o", "raw", "-t", jobTitle]
        let output = try await ProcessRunner.runAsync(
            lp, arguments: arguments, input: data,
            environment: ProcessRunner.neutralEnvironment(), timeout: 120
        )
        guard output.succeeded, !output.inputTruncated else {
            throw Self.mapFailure(output, queue: queue, tool: "lp")
        }
    }

    /// CUPS liefert keine Antworten: wartet `timeout` ab und gibt leere Daten zurück.
    public func read(timeout: Duration) async throws -> Data {
        guard opened else { throw TransportError.notOpen }
        if timeout > .zero {
            try await Task.sleep(for: timeout)
        }
        return Data()
    }

    // MARK: Intern

    private func locateLp() throws -> URL {
        if let lpPath {
            guard FileManager.default.isExecutableFile(atPath: lpPath) else {
                throw TransportError.unsupported("Das CUPS-Programm „lp“ wurde unter \(lpPath) nicht gefunden.")
            }
            return URL(fileURLWithPath: lpPath)
        }
        guard let url = ProcessRunner.locate("lp", preferred: ["/usr/bin/lp"]) else {
            throw TransportError.unsupported("Das CUPS-Programm „lp“ ist nicht installiert.")
        }
        return url
    }

    private func locateLpstat() -> URL? {
        if let lpstatPath {
            return FileManager.default.isExecutableFile(atPath: lpstatPath) ? URL(fileURLWithPath: lpstatPath) : nil
        }
        return ProcessRunner.locate("lpstat", preferred: ["/usr/bin/lpstat"])
    }

    /// CUPS-Warteschlangennamen: druckbar, ohne Leerzeichen, `/`, `#`, max. 127 Zeichen.
    static func isValidQueueName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 127, !name.hasPrefix("-") else { return false }
        return !name.unicodeScalars.contains { scalar in
            scalar.value <= 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "#" || scalar == "\\"
        }
    }

    /// Bildet Fehlermeldungen von `lp`/`lpstat` (englisch oder deutsch) auf `TransportError` ab.
    static func mapFailure(_ output: ProcessOutput, queue: String, tool: String) -> TransportError {
        if output.timedOut {
            return .timeout
        }
        let message = output.errorText.isEmpty ? output.outputText.trimmingCharacters(in: .whitespacesAndNewlines) : output.errorText
        return mapMessage(message, status: output.status, queue: queue, tool: tool)
    }

    static func mapMessage(_ message: String, status: Int32, queue: String, tool: String) -> TransportError {
        let lower = message.lowercased()
        let notFound = ["does not exist", "unknown destination", "invalid destination", "no such",
                        "existiert nicht", "unbekanntes ziel", "ungültiger zielname", "ungültiges ziel"]
        if notFound.contains(where: lower.contains) {
            return .deviceNotFound("Die CUPS-Warteschlange „\(queue)“ existiert nicht.")
        }
        let denied = ["forbidden", "not authorized", "unauthorized", "permission denied", "not allowed",
                      "nicht berechtigt", "verboten", "zugriff verweigert", "keine berechtigung"]
        if denied.contains(where: lower.contains) {
            return .permissionDenied(message.isEmpty ? "CUPS hat den Auftrag abgelehnt." : message)
        }
        let rejecting = ["not accepting", "nimmt keine", "akzeptiert keine"]
        if rejecting.contains(where: lower.contains) {
            return .ioError("Die Warteschlange „\(queue)“ nimmt derzeit keine Aufträge an.")
        }
        let noServer = ["scheduler is not running", "unable to connect", "connection refused",
                        "server-error-service-unavailable", "verbindung zum server", "nicht ausgeführt",
                        "läuft nicht"]
        if noServer.contains(where: lower.contains) {
            return .connectionFailed("Der CUPS-Dienst ist nicht erreichbar (\(message)).")
        }
        if message.isEmpty {
            return .ioError("„\(tool)“ wurde mit Status \(status) beendet.")
        }
        return .ioError(message)
    }
}

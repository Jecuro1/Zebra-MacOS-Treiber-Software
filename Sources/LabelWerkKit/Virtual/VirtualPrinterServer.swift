import Foundation

/// TCP-Server (POSIX-Sockets, macOS & Linux), der einen ``VirtualPrinter`` wie einen
/// Netzwerkdrucker auf Port 9100 („RAW“) bereitstellt.
///
/// Clients werden nacheinander bedient (wie bei Zebra-Druckern: eine Verbindung zur Zeit,
/// weitere warten in der Warteschlange des Betriebssystems). Empfangene Bytes gehen an
/// `VirtualPrinter.write`, Antworten des Druckers an den Client. Beim Wechsel des Clients werden
/// ungelesene Antworten und unvollständige Befehle verworfen. Startet der Drucker neu (`~JR`,
/// SGD `device.reset`), trennt der Server die Verbindung sofort – wie ein echter Drucker, dessen
/// Netzwerkschnittstelle beim Neustart alle Verbindungen verliert; danach eintreffende Daten der
/// alten Verbindung gehen verloren. Der Server läuft, bis der aufrufende Task abgebrochen wird,
/// und wirft dann `CancellationError`.
public enum VirtualPrinterServer {

    /// Stellt `printer` auf `port` (alle IPv4-Adressen) bereit, bis der Task abgebrochen wird.
    public static func run(port: Int, printer: VirtualPrinter) async throws {
        try await run(port: port, host: nil, printer: printer, onListening: { _ in })
    }

    /// Stellt `printer` bereit und meldet den tatsächlich gebundenen Port.
    ///
    /// - Parameters:
    ///   - port: TCP-Port; `0` wählt einen freien Port (siehe `onListening`).
    ///   - host: numerische Adresse, an die gebunden wird (`127.0.0.1`, `::1`, `0.0.0.0`);
    ///     `nil` = alle IPv4-Adressen.
    ///   - onListening: wird einmal aufgerufen, sobald der Server Verbindungen annimmt.
    /// - Throws: Fehler beim Öffnen des Ports (z. B. belegt) bzw. `CancellationError` beim Beenden.
    public static func run(port: Int, host: String?, printer: VirtualPrinter,
                           onListening: @escaping @Sendable (Int) -> Void) async throws {
        let listener: (fd: Int32, port: Int)
        do {
            listener = try ServerSocket.listen(host: host, port: port)
        } catch let error as ServerSocket.SocketError {
            throw VirtualPrinterServerError.listenFailed(error.message)
        }
        defer { ServerSocket.closeDescriptor(listener.fd) }

        let wasOpen = await printer.isOpen
        try await printer.open()
        onListening(listener.port)

        let acceptQueue = DispatchQueue(label: "de.labelwerk.virtualprinter.accept", qos: .userInitiated)
        let fd = listener.fd
        do {
            while true {
                try Task.checkCancellation()
                let client: Int32? = try await ServerIO.run(on: acceptQueue) { flag in
                    while !flag.isCancelled {
                        if let client = try ServerSocket.accept(fd, timeoutMilliseconds: ServerSocket.sliceMilliseconds) {
                            return client
                        }
                    }
                    throw CancellationError()
                }
                guard let client else { continue }
                await serve(client: client, printer: printer)
            }
        } catch {
            if !wasOpen { await printer.close() }
            if error is CancellationError { throw error }
            if let socketError = error as? ServerSocket.SocketError {
                throw VirtualPrinterServerError.connectionFailed(socketError.message)
            }
            throw error
        }
    }

    /// Bedient einen Client, bis er die Verbindung beendet, der Drucker neu startet oder der Task
    /// abgebrochen wird.
    static func serve(client fd: Int32, printer: VirtualPrinter) async {
        let readQueue = DispatchQueue(label: "de.labelwerk.virtualprinter.read", qos: .userInitiated)
        let writeQueue = DispatchQueue(label: "de.labelwerk.virtualprinter.write", qos: .userInitiated)
        await printer.beginSession()
        let restartsAtStart = await printer.restartCount
        await withTaskGroup(of: Void.self) { group in
            // Client → Drucker
            group.addTask {
                do {
                    while true {
                        let result = try await ServerIO.run(on: readQueue) { flag -> ServerSocket.ReceiveResult in
                            if flag.isCancelled { throw CancellationError() }
                            return try ServerSocket.receive(fd, timeoutMilliseconds: ServerSocket.sliceMilliseconds)
                        }
                        switch result {
                        case .data(let data):
                            try await printer.write(data)
                            // Neustart: Die Verbindung endet ohne Nachlauf (wie beim echten Gerät).
                            if await printer.restartCount != restartsAtStart { return }
                        case .timeout:
                            try Task.checkCancellation()
                        case .closed:
                            // Antworten auf die letzten Befehle noch zustellen (halb geschlossene
                            // Verbindungen lesen weiter).
                            try? await Task.sleep(for: .milliseconds(150))
                            return
                        }
                    }
                } catch {
                    return
                }
            }
            // Drucker → Client
            group.addTask {
                do {
                    while true {
                        let data = try await printer.read(timeout: .milliseconds(100))
                        guard !data.isEmpty else { continue }
                        try await ServerIO.run(on: writeQueue) { flag in
                            try ServerSocket.sendAll(fd, data, isCancelled: { flag.isCancelled })
                        }
                    }
                } catch {
                    return
                }
            }
            // Endet eine Richtung (Client getrennt, Sendefehler, Abbruch), endet die Sitzung.
            await group.next()
            group.cancelAll()
        }
        ServerSocket.closeDescriptor(fd)
        await printer.beginSession()
    }
}

/// Fehler von ``VirtualPrinterServer``.
public enum VirtualPrinterServerError: Error, LocalizedError, Equatable, Sendable {
    /// Der Port konnte nicht geöffnet werden (belegt, keine Berechtigung …).
    case listenFailed(String)
    /// Fehler beim Annehmen von Verbindungen.
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .listenFailed(let detail): return "Der virtuelle Drucker konnte nicht gestartet werden: \(detail)"
        case .connectionFailed(let detail): return "Fehler im Server des virtuellen Druckers: \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .listenFailed:
            return "Wählen Sie einen anderen Port (z. B. --port 9101). Ports unter 1024 erfordern Administratorrechte."
        case .connectionFailed:
            return "Starten Sie den virtuellen Drucker neu."
        }
    }
}

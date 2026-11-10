import Foundation

/// TCP-Verbindung zu einem Netzwerkdrucker (Standard: Port 9100, „RAW“), auf POSIX-Sockets
/// für macOS und Linux.
///
/// Umsetzung:
/// * Nicht-blockierendes `connect` mit `poll()`-Zeitlimit, `TCP_NODELAY`, `SO_KEEPALIVE`,
///   SIGPIPE-Schutz (`SO_NOSIGPIPE` auf Darwin, `MSG_NOSIGNAL` auf Linux).
/// * Alle blockierenden Systemaufrufe laufen auf zwei eigenen seriellen `DispatchQueue`s
///   (Lesen/Schreiben getrennt, damit ein wartender Lesevorgang das Senden nicht aufhält) –
///   nie auf dem kooperativen Thread-Pool von Swift Concurrency.
/// * Der Deskriptor gehört einem `SocketHandle` und wird nur innerhalb der blockierenden Arbeit
///   über `withDescriptor(_:)` benutzt. Ein `close()`, das zwischen dem Abholen des Sockets auf dem
///   Actor und dem Start der Arbeit auf der Queue läuft, führt deshalb zu `.notOpen` – nie zu einem
///   Systemaufruf auf einer bereits freigegebenen (und vom Kernel womöglich an eine andere
///   Verbindung vergebenen) Deskriptornummer.
/// * `close()` weckt laufende Lese-/Schreibvorgänge sofort per `shutdown()`; freigegeben wird der
///   Deskriptor, sobald ihn kein Vorgang mehr benutzt. `close()` kehrt zurück, nachdem alle bis
///   dahin eingereihten Vorgänge beendet sind.
public actor TCPConnection: PrinterConnection {
    public nonisolated let descriptor: ConnectionDescriptor
    public nonisolated let host: String
    public nonisolated let port: Int
    public nonisolated let connectTimeout: Duration
    /// Maximale Zeit ohne Sendefortschritt (Drucker nimmt keine Daten an), danach `.timeout`.
    public nonisolated let writeTimeout: Duration

    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var socket: SocketHandle?
    private var peerClosed = false
    /// Wird bei jedem `close()` erhöht, damit ein parallel laufendes `open()` sein Ergebnis verwirft.
    private var generation: UInt64 = 0
    /// Nur für Tests: wird in `read(timeout:)`/`write(_:)` nach dem Abholen des Sockets und vor dem
    /// Einreihen der blockierenden Arbeit erwartet. Damit lässt sich genau die Lücke herstellen, in
    /// der ein paralleles `close()` (und ein neues `open()` einer anderen Verbindung) laufen kann.
    private var beforeBlockingIOHook: (@Sendable () async -> Void)?

    /// Nur für Tests: setzt bzw. entfernt `beforeBlockingIOHook`.
    func setBeforeBlockingIOHook(_ hook: (@Sendable () async -> Void)?) {
        beforeBlockingIOHook = hook
    }

    public init(
        host: String,
        port: Int = 9100,
        connectTimeout: Duration = .seconds(5),
        writeTimeout: Duration = .seconds(60)
    ) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
        self.descriptor = .tcp(host: host, port: port)
        self.readQueue = DispatchQueue(label: "de.labelwerk.transport.tcp.read", qos: .userInitiated)
        self.writeQueue = DispatchQueue(label: "de.labelwerk.transport.tcp.write", qos: .userInitiated)
    }

    deinit {
        // Kein Aufruf kann mehr laufen (er hielte eine Referenz auf `self`); Deskriptor freigeben.
        socket?.close()
    }

    public var isOpen: Bool {
        socket != nil && !peerClosed
    }

    public func open() async throws {
        if socket != nil, !peerClosed { return }
        if socket != nil { await close() }
        let startGeneration = generation
        let host = self.host, port = self.port, timeout = self.connectTimeout
        let fd = try await BlockingIO.run(on: writeQueue) { flag in
            try POSIXSocket.connect(host: host, port: port, timeout: timeout, cancellation: flag)
        }
        let handle = SocketHandle(fd: fd)
        if generation != startGeneration {
            handle.close()
            throw TransportError.connectionFailed("Der Verbindungsaufbau wurde durch Schließen der Verbindung abgebrochen.")
        }
        if let previous = socket {
            if !peerClosed {
                // Ein paralleles open() war schneller – dessen Verbindung behalten.
                handle.close()
                return
            }
            // Die bisherige Verbindung wurde inzwischen von der Gegenstelle beendet: ersetzen.
            previous.close()
        }
        socket = handle
        peerClosed = false
    }

    public func close() async {
        generation &+= 1
        guard let handle = socket else { return }
        socket = nil
        peerClosed = false
        // Neue Benutzungen abweisen und laufende per shutdown() wecken. Den Deskriptor gibt der
        // letzte Benutzer frei (bzw. sofort, falls keiner aktiv ist) – nie, während er benutzt wird.
        handle.close()
        // Erst zurückkehren, wenn alle bereits eingereihten Vorgänge beendet sind.
        await BlockingIO.drain([writeQueue, readQueue])
    }

    public func write(_ data: Data) async throws {
        let handle = try currentSocket()
        guard !data.isEmpty else { return }
        let stall = writeTimeout
        if let hook = beforeBlockingIOHook { await hook() }
        do {
            try await BlockingIO.run(on: writeQueue) { flag in
                // Prüfung „noch offen?“ und Systemaufrufe decken dieselbe Lebensdauer des Deskriptors ab.
                try handle.withDescriptor { fd in
                    try POSIXSocket.sendAll(fd, data, stallTimeout: stall, cancellation: flag)
                }
            }
        } catch let error as TransportError {
            // Lokal geschlossen, bevor oder während gesendet wurde?
            guard socket === handle else { throw TransportError.notOpen }
            if error == .closedByPeer { peerClosed = true }
            throw error
        }
    }

    public func read(timeout: Duration) async throws -> Data {
        let handle = try currentSocket()
        if let hook = beforeBlockingIOHook { await hook() }
        let outcome: POSIXSocket.ReceiveOutcome
        do {
            outcome = try await BlockingIO.run(on: readQueue) { flag in
                try handle.withDescriptor { fd in
                    try POSIXSocket.receive(fd, timeout: timeout, cancellation: flag)
                }
            }
        } catch let error as TransportError {
            guard socket === handle else { throw TransportError.notOpen }
            throw error
        }
        // Lokal geschlossen, während gelesen wurde?
        guard socket === handle else { throw TransportError.notOpen }
        switch outcome {
        case .data(let data, let closed):
            if closed { peerClosed = true }
            return data
        case .timeout:
            return Data()
        case .closed:
            peerClosed = true
            throw TransportError.closedByPeer
        }
    }

    private func currentSocket() throws -> SocketHandle {
        guard let handle = socket else { throw TransportError.notOpen }
        if peerClosed { throw TransportError.closedByPeer }
        return handle
    }
}

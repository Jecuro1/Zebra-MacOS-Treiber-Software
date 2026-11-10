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
/// * `close()` weckt laufende Lese-/Schreibvorgänge sofort per `shutdown()` und gibt den
///   Deskriptor erst frei, wenn beide Queues ihn nicht mehr verwenden.
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
        if socket != nil, !peerClosed {
            // Ein paralleles open() war schneller – dessen Verbindung behalten.
            handle.close()
            return
        }
        socket = handle
        peerClosed = false
    }

    public func close() async {
        generation &+= 1
        guard let handle = socket else { return }
        socket = nil
        peerClosed = false
        handle.shutdownBoth()
        // Erst freigeben, wenn keine Queue den Deskriptor mehr benutzt.
        await BlockingIO.drain([writeQueue, readQueue])
        handle.close()
    }

    public func write(_ data: Data) async throws {
        let handle = try currentSocket()
        guard !data.isEmpty else { return }
        let stall = writeTimeout
        do {
            try await BlockingIO.run(on: writeQueue) { flag in
                try POSIXSocket.sendAll(handle.fd, data, stallTimeout: stall, cancellation: flag)
            }
        } catch let error as TransportError {
            guard socket === handle else { throw TransportError.notOpen }
            if error == .closedByPeer { peerClosed = true }
            throw error
        }
    }

    public func read(timeout: Duration) async throws -> Data {
        let handle = try currentSocket()
        let outcome = try await BlockingIO.run(on: readQueue) { flag in
            try POSIXSocket.receive(handle.fd, timeout: timeout, cancellation: flag)
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

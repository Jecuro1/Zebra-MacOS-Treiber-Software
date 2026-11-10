#if os(macOS) && canImport(IOBluetooth)
import Foundation
import IOBluetooth
import IOKit

/// Klassische Bluetooth-Verbindung (RFCOMM, Serial Port Profile) zu mobilen Zebra-Druckern
/// (z. B. ZQ-, QLn-, iMZ-Serie) über IOBluetooth.
///
/// IOBluetooth-Objekte werden ausschließlich auf dem Main-Thread verwendet (`RFCOMMSession` ist
/// `@MainActor`); dort werden auch die Delegate-Rückrufe des Kanals zugestellt. Der Kanal wird
/// asynchron geöffnet und beschrieben (`openRFCOMMChannelAsync`, `writeAsync`), damit die
/// Oberfläche nie blockiert. Empfangene Daten landen in einem threadsicheren Puffer.
public final class BluetoothClassicConnection: PrinterConnection {
    public let descriptor: ConnectionDescriptor
    /// Adresse in der Form `AA-BB-CC-DD-EE-FF`.
    public let address: String
    public let openTimeout: Duration

    private let buffer: IncomingDataBuffer
    private let channelDelegate: RFCOMMChannelDelegate
    private let session: RFCOMMSession

    public init(address: String, name: String? = nil, openTimeout: Duration = .seconds(20)) {
        let normalized = ConnectionDescriptor.normalizedBluetoothAddress(address)
        let buffer = IncomingDataBuffer()
        self.address = normalized
        self.descriptor = .bluetooth(address: normalized, name: name)
        self.openTimeout = openTimeout
        self.buffer = buffer
        self.channelDelegate = RFCOMMChannelDelegate(buffer: buffer)
        self.session = RFCOMMSession()
    }

    deinit {
        // Kanal auch ohne vorheriges close() schließen; Delegate bleibt bis dahin am Leben.
        let session = self.session
        let channelDelegate = self.channelDelegate
        Task { @MainActor in
            session.close(delegate: channelDelegate)
        }
    }

    public var isOpen: Bool {
        get async { channelDelegate.state == .open }
    }

    public func open() async throws {
        if channelDelegate.state == .open { return }
        buffer.reset()
        try await session.open(address: address, delegate: channelDelegate, timeout: openTimeout)
    }

    public func close() async {
        await session.close(delegate: channelDelegate)
        // Wartende Leser wecken; sie erhalten `notOpen`.
        buffer.fail(.notOpen)
    }

    public func write(_ data: Data) async throws {
        switch channelDelegate.state {
        case .open: break
        case .closedByPeer: throw TransportError.closedByPeer
        case .closed, .opening: throw TransportError.notOpen
        }
        guard !data.isEmpty else { return }
        try await session.write(data, delegate: channelDelegate)
    }

    public func read(timeout: Duration) async throws -> Data {
        switch channelDelegate.state {
        case .open, .closedByPeer:
            // Nach Verbindungsende erst Restdaten, dann `closedByPeer` (aus dem Puffer).
            return try await buffer.read(timeout: timeout)
        case .closed, .opening:
            throw TransportError.notOpen
        }
    }
}

/// Zustand eines RFCOMM-Kanals.
enum RFCOMMChannelState: Sendable, Equatable {
    case closed, opening, open, closedByPeer
}

/// Delegate des RFCOMM-Kanals. Bewusst **ohne** formale Konformität zu
/// `IOBluetoothRFCOMMChannelDelegate`: IOBluetooth prüft die Methoden zur Laufzeit per
/// `respondsToSelector:`; die Selektoren sind explizit festgelegt. Alle Zustände sind durch
/// eine Sperre geschützt, sodass Rückrufe auf beliebigen Threads sicher sind.
final class RFCOMMChannelDelegate: NSObject, @unchecked Sendable {
    private let buffer: IncomingDataBuffer
    private let lock = NSLock()
    private var currentState: RFCOMMChannelState = .closed
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResult: Result<Void, Error>?
    private var openAttempt: UInt64 = 0
    /// Ausstehende Schreibvorgänge, Schlüssel = Adresse des Datenblocks (zugleich `refcon`).
    /// Der Block gehört IOBluetooth bis zum Rückruf `rfcommChannelWriteComplete`; erst dann wird er
    /// freigegeben. Die Continuation kann vorher (Zeitablauf, Schließen) beendet werden.
    private var pendingWrites: [UInt: CheckedContinuation<Void, Error>?] = [:]
    /// Kennung des aktuell gültigen Kanals; Rückrufe älterer Kanäle werden ignoriert.
    private var activeChannel: ObjectIdentifier?

    init(buffer: IncomingDataBuffer) {
        self.buffer = buffer
    }

    var state: RFCOMMChannelState { lock.locked { currentState } }

    /// Legt den Kanal fest, dessen Rückrufe ausgewertet werden (`nil` = keiner).
    func setActiveChannel(_ channel: IOBluetoothRFCOMMChannel?) {
        let identifier = channel.map(ObjectIdentifier.init)
        lock.locked { activeChannel = identifier }
    }

    private func isActive(_ channel: IOBluetoothRFCOMMChannel?) -> Bool {
        guard let channel else { return false }
        let identifier = ObjectIdentifier(channel)
        return lock.locked { activeChannel == identifier }
    }

    // MARK: Öffnen

    /// Bereitet einen neuen Öffnungsversuch vor; liefert dessen Nummer.
    func beginOpening() -> UInt64 {
        lock.locked {
            currentState = .opening
            openResult = nil
            openAttempt &+= 1
            return openAttempt
        }
    }

    /// Wartet auf `rfcommChannelOpenComplete` (oder Zeitablauf bzw. Abbruch).
    func waitForOpen(attempt: UInt64, timeout: Duration) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishOpen(attempt: attempt, .failure(TransportError.timeout))
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early: Result<Void, Error>? = lock.locked {
                    if attempt != openAttempt { return .failure(TransportError.notOpen) }
                    if let result = openResult { return result }
                    openContinuation = continuation
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            self.finishOpen(attempt: attempt, .failure(CancellationError()))
        }
    }

    /// Beendet den Öffnungsversuch `attempt` (nur der erste Aufruf wirkt).
    func finishOpen(attempt: UInt64, _ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.locked {
            guard attempt == openAttempt, openResult == nil else { return nil }
            openResult = result
            if currentState == .opening {
                switch result {
                case .success: currentState = .open
                case .failure: currentState = .closed
                }
            }
            let continuation = openContinuation
            openContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    /// Lokales Schließen: Zustand zurücksetzen, offene Vorgänge beenden.
    func markClosed() {
        let (open, writes): (CheckedContinuation<Void, Error>?, [CheckedContinuation<Void, Error>]) = lock.locked {
            currentState = .closed
            activeChannel = nil
            openAttempt &+= 1
            let open = openContinuation
            openContinuation = nil
            return (open, takeWriteContinuationsLocked())
        }
        open?.resume(throwing: TransportError.notOpen)
        for write in writes { write.resume(throwing: TransportError.notOpen) }
    }

    // MARK: Schreiben

    /// Meldet einen Schreibvorgang an. Liefert `false` (und beendet die Continuation mit einem
    /// Fehler), wenn der Kanal nicht offen ist – der Block wurde dann nicht an IOBluetooth übergeben.
    func registerWrite(key: UInt, _ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let failure: TransportError? = lock.locked {
            switch currentState {
            case .open:
                pendingWrites[key] = .some(continuation)
                return nil
            case .closedByPeer:
                return .closedByPeer
            case .closed, .opening:
                return .notOpen
            }
        }
        if let failure { continuation.resume(throwing: failure) }
        return failure == nil
    }

    /// `writeAsync` hat den Block sofort abgelehnt: Block freigeben, Fehler melden.
    func rejectWrite(key: UInt, status: IOReturn) {
        let continuation = lock.locked { pendingWrites.removeValue(forKey: key) } ?? nil
        UnsafeMutableRawPointer(bitPattern: key)?.deallocate()
        continuation?.resume(throwing: TransportError.ioError("Bluetooth-Schreibfehler (\(Self.hex(status)))."))
    }

    /// Zeitablauf oder Abbruch: nur die Continuation beenden. Der Block bleibt registriert, bis
    /// IOBluetooth den Abschluss meldet (sonst könnte IOBluetooth auf freigegebenen Speicher zugreifen).
    func abandonWrite(key: UInt, with error: Error) {
        let continuation: CheckedContinuation<Void, Error>? = lock.locked {
            guard let entry = pendingWrites[key], let continuation = entry else { return nil }
            pendingWrites[key] = .some(nil)
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    /// Entnimmt alle noch wartenden Continuations; die Blöcke bleiben registriert.
    private func takeWriteContinuationsLocked() -> [CheckedContinuation<Void, Error>] {
        var result: [CheckedContinuation<Void, Error>] = []
        for (key, entry) in pendingWrites {
            if let continuation = entry {
                result.append(continuation)
                pendingWrites[key] = .some(nil)
            }
        }
        return result
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate (informell)

    @objc(rfcommChannelData:data:length:)
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel?, data dataPointer: UnsafeMutableRawPointer?, length dataLength: Int) {
        guard let dataPointer, dataLength > 0, isActive(rfcommChannel) else { return }
        buffer.append(Data(bytes: dataPointer, count: dataLength))
    }

    @objc(rfcommChannelOpenComplete:status:)
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel?, status error: IOReturn) {
        guard isActive(rfcommChannel) else { return }
        let attempt = lock.locked { openAttempt }
        if error == kIOReturnSuccess {
            finishOpen(attempt: attempt, .success(()))
        } else {
            finishOpen(attempt: attempt, .failure(TransportError.connectionFailed(
                "Der Bluetooth-Kanal konnte nicht geöffnet werden (\(Self.hex(error))). Ist der Drucker eingeschaltet und gekoppelt?"
            )))
        }
    }

    @objc(rfcommChannelClosed:)
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel?) {
        guard isActive(rfcommChannel) else { return }
        let (wasOpen, open, writes): (Bool, CheckedContinuation<Void, Error>?, [CheckedContinuation<Void, Error>]) = lock.locked {
            let wasOpen = currentState == .open
            if currentState == .open || currentState == .opening { currentState = .closedByPeer }
            let open = openContinuation
            openContinuation = nil
            // Auch ohne wartende Continuation festhalten, damit `waitForOpen` sofort endet.
            if currentState == .closedByPeer, openResult == nil, !wasOpen {
                openResult = .failure(TransportError.closedByPeer)
            }
            return (wasOpen, open, takeWriteContinuationsLocked())
        }
        if wasOpen { buffer.fail(.closedByPeer) }
        open?.resume(throwing: TransportError.closedByPeer)
        for write in writes { write.resume(throwing: TransportError.closedByPeer) }
    }

    @objc(rfcommChannelWriteComplete:refcon:status:)
    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel?, refcon: UnsafeMutableRawPointer?, status error: IOReturn) {
        guard let refcon else { return }
        let key = UInt(bitPattern: refcon)
        let (known, continuation): (Bool, CheckedContinuation<Void, Error>?) = lock.locked {
            guard let entry = pendingWrites.removeValue(forKey: key) else { return (false, nil) }
            return (true, entry)
        }
        // Nur selbst angelegte Blöcke freigeben; IOBluetooth benötigt ihn nach diesem Rückruf nicht mehr.
        guard known else { return }
        refcon.deallocate()
        if error == kIOReturnSuccess {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: TransportError.ioError("Bluetooth-Schreibfehler (\(Self.hex(error)))."))
        }
    }

    static func hex(_ code: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }
}

/// Besitzt Gerät und Kanal; alle IOBluetooth-Aufrufe laufen auf dem Main-Thread.
@MainActor
final class RFCOMMSession {
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?

    nonisolated init() {}

    func open(address: String, delegate: RFCOMMChannelDelegate, timeout: Duration) async throws {
        if delegate.state == .open, channel != nil { return }
        if delegate.state == .opening {
            throw TransportError.connectionFailed("Der Verbindungsaufbau zu \(address) läuft bereits.")
        }
        closeChannel()
        delegate.setActiveChannel(nil)

        let resolved: IOBluetoothDevice? = IOBluetoothDevice(addressString: address)
        guard let device = resolved else {
            throw TransportError.deviceNotFound("Bluetooth-Gerät \(address) ist unbekannt. Bitte zuerst in den Systemeinstellungen koppeln.")
        }
        let channelID = Self.serialPortChannelID(of: device)
        let attempt = delegate.beginOpening()

        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: delegate)
        guard status == kIOReturnSuccess else {
            delegate.finishOpen(attempt: attempt, .failure(TransportError.notOpen))
            throw TransportError.connectionFailed(
                "Der Bluetooth-Kanal \(channelID) konnte nicht geöffnet werden (\(RFCOMMChannelDelegate.hex(status)))."
            )
        }
        self.device = device
        self.channel = opened
        // Rückrufe werden erst über die Run-Loop des Main-Threads zugestellt, also nach dieser Zuweisung.
        delegate.setActiveChannel(opened)
        do {
            try await delegate.waitForOpen(attempt: attempt, timeout: timeout)
        } catch {
            delegate.markClosed()
            closeChannel()
            if let transport = error as? TransportError, transport == .closedByPeer || transport == .notOpen {
                throw TransportError.connectionFailed("Der Drucker \(address) hat die Bluetooth-Verbindung nicht angenommen.")
            }
            throw error
        }
    }

    func close(delegate: RFCOMMChannelDelegate) {
        // Zuerst abmelden, damit Rückrufe des schließenden Kanals ignoriert werden.
        delegate.markClosed()
        closeChannel()
    }

    /// Schreibt in MTU-großen Blöcken per `writeAsync`. Jeder Block wird bis zum Abschluss-Rückruf
    /// von IOBluetooth gehalten und erst dann freigegeben (siehe `RFCOMMChannelDelegate`).
    func write(_ data: Data, delegate: RFCOMMChannelDelegate) async throws {
        guard let channel else { throw TransportError.notOpen }
        let mtu = max(1, min(Int(channel.getMTU()), Int(UInt16.max)))
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            let end = min(offset + mtu, data.endIndex)
            let count = end - offset
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            data.copyBytes(to: chunk.assumingMemoryBound(to: UInt8.self), from: offset..<end)
            let key = UInt(bitPattern: chunk)

            let timer = Task { [weak delegate] in
                try? await Task.sleep(for: .seconds(30))
                delegate?.abandonWrite(key: key, with: TransportError.timeout)
            }
            defer { timer.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard delegate.registerWrite(key: key, continuation) else {
                        chunk.deallocate()
                        return
                    }
                    let status = channel.writeAsync(chunk, length: UInt16(count), refcon: chunk)
                    if status != kIOReturnSuccess {
                        delegate.rejectWrite(key: key, status: status)
                    }
                }
            } onCancel: {
                delegate.abandonWrite(key: key, with: CancellationError())
            }
            offset = end
        }
    }

    private func closeChannel() {
        if let channel {
            _ = channel.close()
        }
        if let device {
            _ = device.closeConnection()
        }
        channel = nil
        device = nil
    }

    /// RFCOMM-Kanal des Serial Port Profile aus dem SDP-Eintrag; ohne Eintrag Kanal 1
    /// (Standard bei Zebra-Mobildruckern).
    private static func serialPortChannelID(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        let sppUUID: IOBluetoothSDPUUID? = IOBluetoothSDPUUID(uuid16: ZebraIdentifiers.sppServiceUUID16)
        guard let sppUUID else { return 1 }
        let record: IOBluetoothSDPServiceRecord? = device.getServiceRecord(for: sppUUID)
        guard let record else { return 1 }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, channelID != 0 else { return 1 }
        return channelID
    }
}
#endif

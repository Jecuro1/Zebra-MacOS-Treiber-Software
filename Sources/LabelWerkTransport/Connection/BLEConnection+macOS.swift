#if os(macOS) && canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Bluetooth-LE-Verbindung zu Link-OS-Druckern über den Zebra Parser Service.
///
/// * Dienst `38EB4A80-C570-11E3-9507-0002A5D5C51B`
/// * Schreiben: Charakteristik `…4A82…` (Write with Response, in Blöcken der maximalen Länge)
/// * Lesen: Charakteristik `…4A81…` (Notify) → threadsicherer Empfangspuffer
///
/// Das Peripheriegerät wird über seine CoreBluetooth-UUID (`identifier`) zuerst per
/// `retrievePeripherals(withIdentifiers:)`, sonst per Scan gefunden. Für den Zugriff benötigt die
/// App `NSBluetoothAlwaysUsageDescription` in der Info.plist.
public final class BLEConnection: PrinterConnection {
    public let descriptor: ConnectionDescriptor
    /// CoreBluetooth-Peripheral-UUID.
    public let identifier: String
    public let openTimeout: Duration

    private let buffer: IncomingDataBuffer
    private let session: BLESession

    public init(identifier: String, name: String? = nil, openTimeout: Duration = .seconds(20)) {
        let buffer = IncomingDataBuffer()
        self.identifier = identifier
        self.descriptor = .ble(identifier: identifier, name: name)
        self.openTimeout = openTimeout
        self.buffer = buffer
        self.session = BLESession(buffer: buffer)
    }

    deinit {
        // Verbindung auch ohne vorheriges close() trennen.
        let session = self.session
        Task { await session.close() }
    }

    public var isOpen: Bool {
        get async { await session.currentPhase() == .open }
    }

    public func open() async throws {
        guard let uuid = UUID(uuidString: identifier) else {
            throw TransportError.deviceNotFound("Ungültige Bluetooth-LE-Kennung „\(identifier)“.")
        }
        if await session.currentPhase() == .open { return }
        buffer.reset()
        try await session.open(identifier: uuid, timeout: openTimeout)
    }

    public func close() async {
        await session.close()
        buffer.fail(.notOpen)
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else {
            if await session.currentPhase() != .open { throw TransportError.notOpen }
            return
        }
        try await session.write(data)
    }

    public func read(timeout: Duration) async throws -> Data {
        switch await session.currentPhase() {
        case .open, .disconnected:
            // Nach Verbindungsende erst Restdaten, dann `closedByPeer` (aus dem Puffer).
            return try await buffer.read(timeout: timeout)
        default:
            throw TransportError.notOpen
        }
    }
}

/// CoreBluetooth-Sitzung. **Alle** veränderlichen Zustände werden ausschließlich auf `queue`
/// gelesen und geschrieben – dieselbe Queue, auf der CoreBluetooth die Delegate-Methoden aufruft.
final class BLESession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case idle, waitingForBluetooth, scanning, connecting, discovering, open, disconnected
    }

    private struct PendingWrite {
        var chunk: Data
        var continuation: CheckedContinuation<Void, Error>
    }

    // Berechnete Eigenschaften: `CBUUID` ist nicht als `Sendable` annotiert (keine globalen Instanzen).
    private static var serviceUUID: CBUUID { CBUUID(string: ZebraIdentifiers.bleParserServiceUUID) }
    private static var writeUUID: CBUUID { CBUUID(string: ZebraIdentifiers.bleWriteCharacteristicUUID) }
    private static var readUUID: CBUUID { CBUUID(string: ZebraIdentifiers.bleReadCharacteristicUUID) }
    /// Zeitlimit für die Bestätigung eines einzelnen Schreibblocks.
    private static let writeAcknowledgeTimeout: TimeInterval = 15

    private let queue = DispatchQueue(label: "de.labelwerk.transport.ble", qos: .userInitiated)
    private let buffer: IncomingDataBuffer

    // Nur auf `queue` verwenden:
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readCharacteristic: CBCharacteristic?
    private var phase: Phase = .idle
    private var target: UUID?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openAttempt: UInt64 = 0
    private var writeQueue: [PendingWrite] = []
    private var writeInFlight: PendingWrite?
    private var writeAttempt: UInt64 = 0

    init(buffer: IncomingDataBuffer) {
        self.buffer = buffer
        super.init()
    }

    // MARK: Öffentliche Operationen (beliebiger Kontext)

    func currentPhase() async -> Phase {
        await withCheckedContinuation { (continuation: CheckedContinuation<Phase, Never>) in
            queue.async { continuation.resume(returning: self.phase) }
        }
    }

    func open(identifier: UUID, timeout: Duration) async throws {
        let seconds = max(timeout.timeInterval, 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { self.beginOpen(identifier, timeout: seconds, continuation) }
        }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.tearDown(failure: .notOpen, newPhase: .idle)
                continuation.resume()
            }
        }
    }

    /// Schreibt `data` in Blöcken der maximal zulässigen Länge, jeweils mit Bestätigung.
    func write(_ data: Data) async throws {
        let chunkSize = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            queue.async {
                let length = self.peripheral?.maximumWriteValueLength(for: .withResponse) ?? 20
                continuation.resume(returning: max(20, min(length, 512)))
            }
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, data.endIndex)
            let chunk = Data(data[offset..<end])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { self.enqueueWrite(PendingWrite(chunk: chunk, continuation: continuation)) }
            }
            offset = end
        }
    }

    // MARK: Ablauf (nur auf `queue`)

    private func beginOpen(_ identifier: UUID, timeout: TimeInterval, _ continuation: CheckedContinuation<Void, Error>) {
        if phase == .open, peripheral?.identifier == identifier {
            continuation.resume()
            return
        }
        if openContinuation != nil {
            continuation.resume(throwing: TransportError.connectionFailed("Der Verbindungsaufbau läuft bereits."))
            return
        }
        if phase != .idle {
            tearDown(failure: .notOpen, newPhase: .idle)
        }
        openContinuation = continuation
        target = identifier
        openAttempt &+= 1
        let attempt = openAttempt
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.openAttempt == attempt, self.openContinuation != nil else { return }
            self.failOpen(.timeout)
        }
        if let central {
            proceed(with: central)
        } else {
            phase = .waitingForBluetooth
            central = CBCentralManager(
                delegate: self,
                queue: queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
        }
    }

    private func proceed(with central: CBCentralManager) {
        guard openContinuation != nil else { return }
        switch central.state {
        case .poweredOn:
            connectOrScan(central)
        case .unauthorized:
            failOpen(.permissionDenied(
                "LabelWerk darf Bluetooth nicht verwenden. Erlauben Sie den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth."
            ))
        case .unsupported:
            failOpen(.unsupported("Dieser Mac unterstützt Bluetooth LE nicht."))
        case .poweredOff:
            failOpen(.connectionFailed("Bluetooth ist ausgeschaltet."))
        default:
            // .unknown / .resetting: auf centralManagerDidUpdateState warten.
            phase = .waitingForBluetooth
        }
    }

    private func connectOrScan(_ central: CBCentralManager) {
        guard let target else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [target]).first {
            connect(known, using: central)
        } else {
            phase = .scanning
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
        self.peripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        central.connect(peripheral, options: nil)
    }

    private func completeOpen() {
        guard let continuation = openContinuation else { return }
        openContinuation = nil
        phase = .open
        continuation.resume()
    }

    private func failOpen(_ error: TransportError) {
        guard let continuation = openContinuation else { return }
        openContinuation = nil
        tearDown(failure: .notOpen, newPhase: .idle)
        continuation.resume(throwing: error)
    }

    /// Trennt die Verbindung und beendet alle wartenden Schreibvorgänge mit `failure`.
    private func tearDown(failure: TransportError, newPhase: Phase) {
        if phase == .scanning { central?.stopScan() }
        if let peripheral {
            if let readCharacteristic, peripheral.state == .connected {
                peripheral.setNotifyValue(false, for: readCharacteristic)
            }
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
        readCharacteristic = nil
        phase = newPhase
        failWrites(failure)
        if let pendingOpen = openContinuation {
            openContinuation = nil
            pendingOpen.resume(throwing: failure)
        }
    }

    private func enqueueWrite(_ write: PendingWrite) {
        guard phase == .open, peripheral != nil, writeCharacteristic != nil else {
            write.continuation.resume(throwing: phase == .disconnected ? TransportError.closedByPeer : TransportError.notOpen)
            return
        }
        writeQueue.append(write)
        startNextWrite()
    }

    private func startNextWrite() {
        guard writeInFlight == nil, !writeQueue.isEmpty,
              let peripheral, let characteristic = writeCharacteristic
        else { return }
        let next = writeQueue.removeFirst()
        writeInFlight = next
        writeAttempt &+= 1
        let attempt = writeAttempt
        peripheral.writeValue(next.chunk, for: characteristic, type: .withResponse)
        queue.asyncAfter(deadline: .now() + Self.writeAcknowledgeTimeout) { [weak self] in
            guard let self, self.writeAttempt == attempt, self.writeInFlight != nil else { return }
            self.finishWrite(.failure(TransportError.timeout))
        }
    }

    private func finishWrite(_ result: Result<Void, Error>) {
        guard let current = writeInFlight else { return }
        writeInFlight = nil
        current.continuation.resume(with: result)
        startNextWrite()
    }

    private func failWrites(_ error: TransportError) {
        let pending = (writeInFlight.map { [$0] } ?? []) + writeQueue
        writeInFlight = nil
        writeQueue.removeAll()
        for write in pending { write.continuation.resume(throwing: error) }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if openContinuation != nil, phase == .waitingForBluetooth {
            proceed(with: central)
        } else if central.state != .poweredOn, phase == .open {
            tearDown(failure: .closedByPeer, newPhase: .disconnected)
            buffer.fail(.closedByPeer)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning, peripheral.identifier == target else { return }
        central.stopScan()
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral, openContinuation != nil else { return }
        phase = .discovering
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        failOpen(.connectionFailed(error?.localizedDescription ?? "Die Bluetooth-LE-Verbindung ist fehlgeschlagen."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if openContinuation != nil {
            failOpen(.connectionFailed(error?.localizedDescription ?? "Der Drucker hat die Verbindung getrennt."))
        } else if phase == .open {
            tearDown(failure: .closedByPeer, newPhase: .disconnected)
            buffer.fail(.closedByPeer)
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral, openContinuation != nil else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failOpen(.unsupported("Der Drucker bietet den Zebra-Parser-Dienst nicht an (Bluetooth LE in den Druckereinstellungen aktiviert?)."))
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.readUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral, openContinuation != nil, service.uuid == Self.serviceUUID else { return }
        let characteristics = service.characteristics ?? []
        writeCharacteristic = characteristics.first { $0.uuid == Self.writeUUID }
        readCharacteristic = characteristics.first { $0.uuid == Self.readUUID }
        guard error == nil, writeCharacteristic != nil else {
            failOpen(.unsupported("Die Schreib-Charakteristik des Zebra-Parser-Dienstes fehlt."))
            return
        }
        if let readCharacteristic,
           readCharacteristic.properties.contains(.notify) || readCharacteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: readCharacteristic)
        } else {
            completeOpen()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.readUUID, openContinuation != nil else { return }
        // Auch ohne Benachrichtigungen ist Senden möglich; Antworten bleiben dann aus.
        completeOpen()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, error == nil, characteristic.uuid == Self.readUUID,
              let value = characteristic.value, !value.isEmpty
        else { return }
        buffer.append(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.writeUUID else { return }
        if let error {
            finishWrite(.failure(TransportError.ioError("Bluetooth-LE-Schreibfehler: \(error.localizedDescription)")))
        } else {
            finishWrite(.success(()))
        }
    }
}
#endif

#if os(macOS) && canImport(IOUSBHost)
import Foundation
import IOKit
import IOUSBHost

/// Direkte USB-Verbindung zu einem Zebra-Drucker über das IOUSBHost-Framework (macOS 10.15+).
///
/// * Gerät: `IOUSBHostDevice` mit Hersteller-ID 0x0A5F, Auswahl über Seriennummer, `locationID`
///   bzw. Produkt-ID (siehe `USBDeviceSelection`).
/// * Schnittstelle: `IOUSBHostInterface` der Klasse 7 (Drucker); Bulk-OUT- und (bei bidirektionalen
///   Druckern) Bulk-IN-Pipe werden über `copyPipe(withAddress:)` ermittelt.
/// * Übertragung: synchrones `sendIORequest(with:bytesTransferred:completionTimeout:)` auf eigenen
///   seriellen Queues (Lesen und Schreiben getrennt), in Zeitscheiben, damit Abbruch und
///   Schließen zügig wirken.
///
/// Hinweis: Während CUPS gerade über dieselbe Schnittstelle druckt, ist das Gerät exklusiv
/// belegt; `open()` wirft dann `TransportError.permissionDenied`.
public actor USBConnection: PrinterConnection {
    public nonisolated let descriptor: ConnectionDescriptor
    public nonisolated let device: USBDeviceIdentifier
    /// Maximale Zeit ohne Sendefortschritt (z. B. Drucker pausiert), danach `.timeout`.
    public nonisolated let writeTimeout: Duration

    private let readQueue = DispatchQueue(label: "de.labelwerk.transport.usb.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "de.labelwerk.transport.usb.write", qos: .userInitiated)
    private var session: USBPrinterSession?
    private var disconnected = false
    private var generation: UInt64 = 0

    public init(device: USBDeviceIdentifier, writeTimeout: Duration = .seconds(60)) {
        self.device = device
        self.writeTimeout = writeTimeout
        self.descriptor = .usb(device)
    }

    deinit {
        session?.destroy()
    }

    public var isOpen: Bool {
        session != nil && !disconnected
    }

    public func open() async throws {
        if session != nil, !disconnected { return }
        if session != nil { await close() }
        let startGeneration = generation
        let wanted = device
        let opened = try await BlockingIO.run(on: writeQueue) { _ in
            try USBPrinterSession.open(wanted)
        }
        if generation != startGeneration {
            opened.destroy()
            throw TransportError.connectionFailed("Der Verbindungsaufbau wurde durch Schließen der Verbindung abgebrochen.")
        }
        if session != nil, !disconnected {
            opened.destroy()
            return
        }
        session = opened
        disconnected = false
    }

    public func close() async {
        generation &+= 1
        guard let current = session else { return }
        session = nil
        disconnected = false
        // Bricht laufende Übertragungen ab; danach warten, bis beide Queues frei sind.
        current.destroy()
        await BlockingIO.drain([writeQueue, readQueue])
    }

    public func write(_ data: Data) async throws {
        let current = try currentSession()
        guard !data.isEmpty else { return }
        let stall = writeTimeout
        do {
            try await BlockingIO.run(on: writeQueue) { flag in
                try current.write(data, stallTimeout: stall, cancellation: flag)
            }
        } catch let error as TransportError {
            throw handle(error, from: current)
        }
    }

    public func read(timeout: Duration) async throws -> Data {
        let current = try currentSession()
        guard current.canRead else {
            // Unidirektionaler Drucker: keine Antworten möglich.
            if timeout > .zero { try await Task.sleep(for: timeout) }
            return Data()
        }
        do {
            return try await BlockingIO.run(on: readQueue) { flag in
                try current.read(timeout: timeout, cancellation: flag)
            }
        } catch let error as TransportError {
            throw handle(error, from: current)
        }
    }

    private func currentSession() throws -> USBPrinterSession {
        guard let current = session else { throw TransportError.notOpen }
        if disconnected { throw TransportError.closedByPeer }
        return current
    }

    private func handle(_ error: TransportError, from current: USBPrinterSession) -> TransportError {
        // Lokal geschlossen, während übertragen wurde?
        guard session === current else { return .notOpen }
        if error == .closedByPeer { disconnected = true }
        return error
    }
}

/// Geöffnete USB-Druckerschnittstelle mit ihren Pipes.
///
/// `IOUSBHostInterface`/`IOUSBHostPipe` sind für synchrone Aufrufe aus beliebigen Threads ausgelegt
/// (nicht jedoch von ihrer eigenen Rückruf-Queue); Lese- und Schreibzugriffe laufen jeweils auf
/// einer eigenen seriellen Queue von `USBConnection`.
final class USBPrinterSession: @unchecked Sendable {
    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe?
    private let lock = NSLock()
    private var destroyed = false

    /// Größe einer einzelnen Übertragung (Vielfaches aller üblichen Paketgrößen 8 … 1024).
    static let transferSize = 16 * 1024
    /// Länge einer Zeitscheibe für synchrone Übertragungen (Reaktionszeit auf Abbruch).
    static let slice: TimeInterval = 0.5

    var canRead: Bool { inPipe != nil }

    private init(interface: IOUSBHostInterface, outPipe: IOUSBHostPipe, inPipe: IOUSBHostPipe?) {
        self.interface = interface
        self.outPipe = outPipe
        self.inPipe = inPipe
    }

    deinit {
        destroy()
    }

    /// Sucht das Gerät, öffnet dessen Druckerschnittstelle und ermittelt die Bulk-Pipes (blockierend).
    static func open(_ wanted: USBDeviceIdentifier) throws -> USBPrinterSession {
        let devices = USBRegistry.devices(
            vendorID: wanted.vendorID,
            productID: wanted.productID == 0 ? nil : wanted.productID
        )
        guard let index = USBDeviceSelection.bestMatch(for: wanted, among: devices.map(\.identifier)) else {
            throw TransportError.deviceNotFound(
                "\(USBDeviceSelection.describe(wanted)) ist nicht angeschlossen oder ausgeschaltet."
            )
        }
        let device = devices[index]
        guard let printerInterface = USBRegistry.printerInterface(of: device.handle.object) else {
            throw TransportError.unsupported(
                "\(USBDeviceSelection.describe(device.identifier)) stellt keine USB-Druckerschnittstelle bereit."
            )
        }

        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(
                __ioService: printerInterface.handle.object,
                options: [],
                queue: nil,
                interestHandler: nil
            )
        } catch {
            throw map(error, fallback: "Die USB-Schnittstelle konnte nicht geöffnet werden")
        }

        // Endpunkte ermitteln: OUT 0x01 … 0x0F, IN 0x81 … 0x8F.
        var outPipe: IOUSBHostPipe?
        for address in 0x01...0x0F where outPipe == nil {
            outPipe = try? interface.copyPipe(withAddress: address)
        }
        var inPipe: IOUSBHostPipe?
        if printerInterface.interfaceProtocol != 1 {
            for address in 0x81...0x8F where inPipe == nil {
                inPipe = try? interface.copyPipe(withAddress: address)
            }
        }
        guard let outPipe else {
            interface.destroy()
            throw TransportError.unsupported("Die Druckerschnittstelle besitzt keinen Bulk-OUT-Endpunkt.")
        }
        return USBPrinterSession(interface: interface, outPipe: outPipe, inPipe: inPipe)
    }

    /// Gibt die Schnittstelle frei und bricht laufende Übertragungen ab (idempotent).
    func destroy() {
        let shouldDestroy: Bool = lock.locked {
            guard !destroyed else { return false }
            destroyed = true
            return true
        }
        if shouldDestroy { interface.destroy() }
    }

    private var isDestroyed: Bool { lock.locked { destroyed } }

    /// Sendet alle Bytes in Blöcken; Teilübertragungen bei Zeitablauf werden fortgesetzt.
    func write(_ data: Data, stallTimeout: Duration, cancellation: CancellationFlag) throws {
        var offset = 0
        var lastProgress = ContinuousClock.now
        while offset < data.count {
            try cancellation.check()
            if isDestroyed { throw TransportError.notOpen }
            let end = min(offset + Self.transferSize, data.count)
            guard let buffer = NSMutableData(length: end - offset) else {
                throw TransportError.ioError("Nicht genügend Speicher für die USB-Übertragung.")
            }
            // Indizes relativ zu `startIndex` (Data kann ein Ausschnitt sein).
            let base = data.startIndex
            data.copyBytes(
                to: buffer.mutableBytes.assumingMemoryBound(to: UInt8.self),
                from: (base + offset)..<(base + end)
            )

            let started = ContinuousClock.now
            let result = Self.transfer { (count: UnsafeMutablePointer<Int>) in
                try outPipe.__sendIORequest(with: buffer, bytesTransferred: count, completionTimeout: Self.slice)
            }
            let elapsed = started.duration(to: .now).timeInterval
            let transferred = max(0, min(result.count, end - offset))
            if transferred > 0 {
                offset += transferred
                lastProgress = .now
            }
            guard let error = result.error else {
                // Erfolgreich: Ohne Fehler wurde der ganze Block übertragen.
                if transferred == 0 { offset = end }
                continue
            }
            if isDestroyed { throw TransportError.notOpen }
            if Self.isTimeout(error, elapsed: elapsed, requested: Self.slice) {
                if lastProgress.duration(to: .now) >= stallTimeout { throw TransportError.timeout }
                continue
            }
            throw Self.map(error, fallback: "USB-Übertragung fehlgeschlagen")
        }
    }

    /// Wartet bis `timeout` auf Daten vom Drucker und liefert den ersten empfangenen Block.
    func read(timeout: Duration, cancellation: CancellationFlag) throws -> Data {
        guard let inPipe else { return Data() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        repeat {
            try cancellation.check()
            if isDestroyed { throw TransportError.notOpen }
            let remaining = max(clock.now.duration(to: deadline).timeInterval, 0.01)
            guard let buffer = NSMutableData(length: Self.transferSize) else {
                throw TransportError.ioError("Nicht genügend Speicher für die USB-Übertragung.")
            }
            let requested = min(remaining, Self.slice)
            let started = ContinuousClock.now
            let result = Self.transfer { (count: UnsafeMutablePointer<Int>) in
                try inPipe.__sendIORequest(with: buffer, bytesTransferred: count, completionTimeout: requested)
            }
            let elapsed = started.duration(to: .now).timeInterval
            let received = max(0, min(result.count, buffer.length))
            if received > 0 {
                return Data(bytes: buffer.bytes, count: received)
            }
            if let error = result.error {
                if isDestroyed { throw TransportError.notOpen }
                if !Self.isTimeout(error, elapsed: elapsed, requested: requested) {
                    throw Self.map(error, fallback: "USB-Empfang fehlgeschlagen")
                }
            }
        } while clock.now < deadline
        return Data()
    }

    // MARK: Hilfen

    /// Führt eine IOUSBHost-Übertragung aus und liefert die übertragene Byteanzahl – auch im Fehlerfall.
    ///
    /// `NSUInteger *` wird in Swift als `UnsafeMutablePointer<Int>` importiert. Die synchrone
    /// Bulk-Methode ist `NS_REFINED_FOR_SWIFT` und erscheint daher als `__sendIORequest`.
    private static func transfer(
        _ body: (UnsafeMutablePointer<Int>) throws -> Void
    ) -> (count: Int, error: Error?) {
        var count = 0
        do {
            try withUnsafeMutablePointer(to: &count) { try body($0) }
            return (count, nil)
        } catch {
            return (count, error)
        }
    }

    // IOReturn-Codes (Makros aus IOKit/IOReturn.h werden nicht nach Swift importiert).
    static let ioReturnTimeout = Int32(bitPattern: 0xE000_02D6)
    static let ioReturnAborted = Int32(bitPattern: 0xE000_02EB)
    static let ioReturnNoDevice = Int32(bitPattern: 0xE000_02C0)
    static let ioReturnNotResponding = Int32(bitPattern: 0xE000_02ED)
    static let ioReturnExclusiveAccess = Int32(bitPattern: 0xE000_02C5)
    static let ioReturnNotPermitted = Int32(bitPattern: 0xE000_02E2)
    static let ioReturnNotPrivileged = Int32(bitPattern: 0xE000_02C1)
    static let ioReturnNotOpen = Int32(bitPattern: 0xE000_02CD)
    static let usbTransactionTimeout = Int32(bitPattern: 0xE000_4051)
    static let usbPipeStalled = Int32(bitPattern: 0xE000_404F)

    static func ioReturn(of error: Error) -> Int32 {
        Int32(truncatingIfNeeded: (error as NSError).code)
    }

    /// `true`, wenn die Übertragung wegen Ablaufs des eigenen Zeitlimits endete.
    ///
    /// Neben den Zeitablauf-Codes wird auch `kIOReturnAborted` als Zeitablauf gewertet, wenn die
    /// angeforderte Frist tatsächlich verstrichen ist (je nach macOS-Version meldet IOUSBHost einen
    /// abgebrochenen Auftrag mit diesem Code). Ein *vorzeitiger* Abbruch bedeutet dagegen, dass das
    /// Gerät entfernt wurde.
    static func isTimeout(_ error: Error, elapsed: TimeInterval, requested: TimeInterval) -> Bool {
        let code = ioReturn(of: error)
        if code == ioReturnTimeout || code == usbTransactionTimeout { return true }
        return code == ioReturnAborted && elapsed >= requested * 0.9
    }

    static func map(_ error: Error, fallback: String) -> TransportError {
        if let transport = error as? TransportError { return transport }
        let code = ioReturn(of: error)
        let hex = String(format: "0x%08X", UInt32(bitPattern: code))
        switch code {
        case ioReturnTimeout, usbTransactionTimeout:
            return .timeout
        case ioReturnNoDevice, ioReturnNotResponding, ioReturnAborted:
            // Vorzeitiger Abbruch ohne lokales Schließen: Gerät entfernt oder ausgeschaltet.
            return .closedByPeer
        case ioReturnNotOpen:
            return .notOpen
        case ioReturnExclusiveAccess:
            return .permissionDenied("Der Drucker wird gerade von einem anderen Programm verwendet (z. B. vom CUPS-Druckdienst).")
        case ioReturnNotPermitted, ioReturnNotPrivileged:
            return .permissionDenied("macOS erlaubt den direkten USB-Zugriff nicht (\(hex)).")
        case usbPipeStalled:
            return .ioError("Der Drucker hat die Übertragung angehalten (USB-Stall, \(hex)).")
        default:
            let description = (error as NSError).localizedDescription
            return .ioError("\(fallback): \(description) (\(hex))")
        }
    }
}
#endif

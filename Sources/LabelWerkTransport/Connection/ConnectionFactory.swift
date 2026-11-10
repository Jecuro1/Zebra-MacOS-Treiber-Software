import Foundation

/// Erzeugt passende `PrinterConnection`-Objekte aus einer `ConnectionDescriptor`.
public enum ConnectionFactory {
    /// Fabrik für `.virtual(id:)`; wird von LabelWerkKit registriert (threadsicher).
    private static let virtualFactory = LockedValue<(@Sendable (String) -> any PrinterConnection)?>(nil)

    /// Erzeugt eine (noch nicht geöffnete) Verbindung.
    ///
    /// - Throws: `TransportError.unsupported`, wenn die Verbindungsart auf dieser Plattform nicht
    ///   verfügbar ist (USB/Bluetooth/BLE außerhalb von macOS) oder für `.virtual` keine Fabrik
    ///   registriert wurde; `TransportError.connectionFailed` bei offensichtlich ungültigen Angaben.
    public static func make(_ descriptor: ConnectionDescriptor) throws -> any PrinterConnection {
        switch descriptor {
        case .tcp(let host, let port):
            guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TransportError.connectionFailed("Es wurde keine Netzwerkadresse angegeben.")
            }
            guard (1...65535).contains(port) else {
                throw TransportError.connectionFailed("Ungültiger Port \(port) (erlaubt: 1–65535).")
            }
            return TCPConnection(host: host, port: port)

        case .usb(let device):
            #if os(macOS) && canImport(IOUSBHost)
            return USBConnection(device: device)
            #else
            _ = device
            throw TransportError.unsupported("USB-Verbindungen sind nur unter macOS verfügbar. Verwenden Sie stattdessen eine CUPS-Warteschlange.")
            #endif

        case .bluetooth(let address, let name):
            #if os(macOS) && canImport(IOBluetooth)
            return BluetoothClassicConnection(address: address, name: name)
            #else
            _ = (address, name)
            throw TransportError.unsupported("Bluetooth-Verbindungen sind nur unter macOS verfügbar.")
            #endif

        case .ble(let identifier, let name):
            #if os(macOS) && canImport(CoreBluetooth)
            return BLEConnection(identifier: identifier, name: name)
            #else
            _ = (identifier, name)
            throw TransportError.unsupported("Bluetooth-LE-Verbindungen sind nur unter macOS verfügbar.")
            #endif

        case .cupsQueue(let name):
            return CUPSQueueConnection(queue: name)

        case .virtual(let id):
            guard let factory = virtualFactory.value else {
                throw TransportError.unsupported("Virtuelle Drucker sind nicht verfügbar (keine Fabrik registriert).")
            }
            return factory(id)
        }
    }

    /// Wird von LabelWerkKit registriert, um `.virtual` zu bedienen. Eine erneute Registrierung
    /// ersetzt die vorherige Fabrik.
    public static func registerVirtualFactory(_ factory: @escaping @Sendable (String) -> any PrinterConnection) {
        virtualFactory.set(factory)
    }

    /// Entfernt die registrierte Fabrik für virtuelle Drucker.
    public static func unregisterVirtualFactory() {
        virtualFactory.set(nil)
    }

    /// `true`, wenn eine Fabrik für virtuelle Drucker registriert ist.
    public static var hasVirtualFactory: Bool {
        virtualFactory.value != nil
    }

    /// Verbindungsarten, die auf dieser Plattform grundsätzlich erzeugt werden können.
    public static var supportedKinds: Set<ConnectionKind> {
        var kinds: Set<ConnectionKind> = [.tcp, .cupsQueue, .virtual]
        #if os(macOS) && canImport(IOUSBHost)
        kinds.insert(.usb)
        #endif
        #if os(macOS) && canImport(IOBluetooth)
        kinds.insert(.bluetooth)
        #endif
        #if os(macOS) && canImport(CoreBluetooth)
        kinds.insert(.ble)
        #endif
        return kinds
    }
}

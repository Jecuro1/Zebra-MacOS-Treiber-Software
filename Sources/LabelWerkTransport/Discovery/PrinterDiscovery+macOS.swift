import Foundation

// MARK: - Bonjour (Network.framework)

#if canImport(Network)
import Network

extension PrinterDiscovery {
    /// Durchsucht alle Diensttypen gleichzeitig, bis der Task abgebrochen wird.
    static func discoverBonjourWithNetworkFramework(types: [String], sink: DiscoverySink) async {
        await withTaskGroup(of: Void.self) { group in
            for type in types {
                group.addTask { await browseBonjour(type: type, sink: sink) }
            }
        }
    }

    /// `NWBrowser` für einen Diensttyp; jeder neue Dienst wird aufgelöst und – falls Zebra – gemeldet.
    static func browseBonjour(type: String, sink: DiscoverySink) async {
        let (results, continuation) = AsyncStream<BonjourBrowseResult>.makeStream()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                if case .added(let result) = change {
                    continuation.yield(BonjourBrowseResult(result))
                }
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        let browserBox = UncheckedSendable(browser)
        browser.start(queue: DispatchQueue(label: "de.labelwerk.transport.bonjour.browse", qos: .userInitiated))

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for await result in results where result.looksLikeZebra {
                    // Nur Zebra-Kandidaten auflösen (keine Verbindungen zu fremden Geräten).
                    group.addTask {
                        guard let service = await result.resolve() else { return }
                        sink.emit(service.makeDiscoveredPrinter())
                    }
                }
            }
        } onCancel: {
            browserBox.value.cancel()
            continuation.finish()
        }
        browserBox.value.cancel()
    }
}

/// Ein Bonjour-Fund (Endpunkt + TXT-Daten), noch nicht aufgelöst.
struct BonjourBrowseResult: @unchecked Sendable {
    let endpoint: NWEndpoint
    let name: String
    let type: String
    let domain: String
    let txt: [String: String]

    init(_ result: NWBrowser.Result) {
        endpoint = result.endpoint
        if case let .service(name, type, domain, _) = result.endpoint {
            self.name = name
            self.type = type
            self.domain = domain
        } else {
            self.name = "\(result.endpoint)"
            self.type = ""
            self.domain = ""
        }
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        } else {
            txt = [:]
        }
    }

    /// Dienstbeschreibung ohne aufgelöste Adresse (für die Zebra-Vorauswahl anhand Name/TXT).
    var unresolvedService: BonjourService {
        BonjourService(name: name, type: type, domain: domain, host: "", port: 0, txt: txt)
    }

    var looksLikeZebra: Bool { unresolvedService.looksLikeZebra }

    /// Löst den Dienst auf eine IP-Adresse auf (zuerst IPv4, dann beliebig).
    func resolve() async -> BonjourService? {
        var resolved = await EndpointResolver.resolve(endpoint, ipv4Only: true, timeout: 2.5)
        if resolved == nil, !Task.isCancelled {
            resolved = await EndpointResolver.resolve(endpoint, ipv4Only: false, timeout: 3)
        }
        guard let resolved else { return nil }
        return BonjourService(
            name: name, type: type.trimmingCharacters(in: CharacterSet(charactersIn: ".")), domain: domain,
            host: resolved.host, port: resolved.port, txt: txt
        )
    }
}

/// Löst einen Bonjour-Endpunkt auf, indem kurz eine TCP-Verbindung aufgebaut und deren
/// Gegenstelle (`currentPath.remoteEndpoint`) gelesen wird. Zustand nur auf `queue`.
final class EndpointResolver: @unchecked Sendable {
    typealias Resolved = (host: String, port: Int)

    private let queue = DispatchQueue(label: "de.labelwerk.transport.bonjour.resolve", qos: .userInitiated)
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Resolved?, Never>?

    static func resolve(_ endpoint: NWEndpoint, ipv4Only: Bool, timeout: TimeInterval) async -> Resolved? {
        await EndpointResolver().run(UncheckedSendable(endpoint), ipv4Only: ipv4Only, timeout: timeout)
    }

    private func run(_ endpoint: UncheckedSendable<NWEndpoint>, ipv4Only: Bool, timeout: TimeInterval) async -> Resolved? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Resolved?, Never>) in
                queue.async {
                    self.start(endpoint.value, ipv4Only: ipv4Only, timeout: timeout, continuation: continuation)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(nil) }
        }
    }

    /// Startet die Verbindung (auf `queue`).
    private func start(_ endpoint: NWEndpoint, ipv4Only: Bool, timeout: TimeInterval,
                       continuation: CheckedContinuation<Resolved?, Never>) {
        self.continuation = continuation
        let parameters = NWParameters.tcp
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    /// Wird auf `queue` aufgerufen (Start-Queue der Verbindung).
    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            var resolved: Resolved?
            if let remote = connection?.currentPath?.remoteEndpoint,
               case let .hostPort(host, port) = remote {
                resolved = (Self.describe(host), Int(port.rawValue))
            }
            finish(resolved)
        case .failed, .waiting, .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func finish(_ result: Resolved?) {
        guard let continuation else { return }
        self.continuation = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation.resume(returning: result)
    }

    /// Numerische Darstellung einer Adresse (`192.168.1.20`, `fe80::1%en0`).
    static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case .ipv6(let address):
            var bytes = [UInt8](address.rawValue)
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let formatted = bytes.withUnsafeMutableBytes { raw in
                inet_ntop(AF_INET6, raw.baseAddress, &text, socklen_t(text.count))
            }
            var result = formatted != nil ? POSIXSocket.string(fromCString: text) : "\(address)"
            if let interface = address.interface {
                result += "%" + interface.name
            }
            return result
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
#endif

// MARK: - USB (IOKit)

#if os(macOS) && canImport(IOKit)
import IOKit

extension PrinterDiscovery {
    /// Angeschlossene Zebra-USB-Geräte (Hersteller-ID 0x0A5F).
    static func discoverUSB(sink: DiscoverySink) async {
        let identifiers = (try? await BlockingIO.run { _ in
            USBRegistry.devices(vendorID: ZebraIdentifiers.usbVendorID).map(\.identifier)
        }) ?? []
        for identifier in identifiers {
            var details = [
                "productID": String(format: "0x%04lX", identifier.productID),
                "vendorID": String(format: "0x%04lX", identifier.vendorID),
            ]
            if let serial = identifier.serialNumber { details["serialNumber"] = serial }
            if let location = identifier.locationID { details["locationID"] = String(format: "0x%08X", location) }
            if let product = identifier.productName { details["productName"] = product }
            let shortName = identifier.productName.flatMap(ZebraIdentifiers.shortModelName(from:))
            sink.emit(DiscoveredPrinter(
                name: shortName.map { "Zebra \($0)" } ?? "Zebra USB-Drucker",
                modelHint: identifier.productName,
                descriptor: .usb(identifier),
                source: .usb,
                details: details
            ))
        }
    }
}
#endif

// MARK: - Bluetooth klassisch (IOBluetooth)

#if os(macOS) && canImport(IOBluetooth)
import IOBluetooth

extension PrinterDiscovery {
    /// Gekoppelte Geräte der Klasse „Bildgebung/Drucker“ oder mit Zebra-Namen.
    static func discoverBluetooth(sink: DiscoverySink) async {
        let printers: [DiscoveredPrinter] = await MainActor.run {
            let paired: [Any] = IOBluetoothDevice.pairedDevices() ?? []
            var result: [DiscoveredPrinter] = []
            for case let device as IOBluetoothDevice in paired {
                let rawAddress: String? = device.addressString
                guard let rawAddress, !rawAddress.isEmpty else { continue }
                let name: String? = device.name
                // Hauptklasse 0x06 = Imaging, Nebenklasse Bit 0x20 = Drucker.
                let isPrinterClass = device.deviceClassMajor == 0x06 && (device.deviceClassMinor & 0x20) != 0
                let hasZebraName = name.map(ZebraIdentifiers.looksLikeZebra) ?? false
                guard isPrinterClass || hasZebraName else { continue }
                let address = ConnectionDescriptor.normalizedBluetoothAddress(rawAddress)
                var details = ["address": address]
                if let name { details["name"] = name }
                result.append(DiscoveredPrinter(
                    name: name ?? address,
                    // Ab Werk ist der Name die Seriennummer – kein Modellhinweis.
                    modelHint: name.flatMap { ZebraIdentifiers.looksLikeZebraSerialNumber($0) ? nil : $0 },
                    descriptor: .bluetooth(address: address, name: name),
                    source: .bluetooth,
                    details: details
                ))
            }
            return result
        }
        for printer in printers { sink.emit(printer) }
    }
}
#endif

// MARK: - Bluetooth LE (CoreBluetooth)

#if os(macOS) && canImport(CoreBluetooth)
import CoreBluetooth

extension PrinterDiscovery {
    /// Sucht BLE-Geräte mit Zebra-Dienstkennung bzw. Zebra-Namen, bis der Task abgebrochen wird.
    static func discoverBLE(timeout: Duration, sink: DiscoverySink) async {
        let scanner = BLEScanner { printer in sink.emit(printer) }
        scanner.start()
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
        } onCancel: {
            scanner.stop()
        }
        scanner.stop()
    }
}

/// BLE-Scanner; Zustand ausschließlich auf `queue` (zugleich Delegate-Queue von CoreBluetooth).
final class BLEScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "de.labelwerk.transport.ble.scan", qos: .utility)
    private let onFound: @Sendable (DiscoveredPrinter) -> Void
    private var central: CBCentralManager?
    private var reported = Set<UUID>()
    private var stopped = false

    init(onFound: @escaping @Sendable (DiscoveredPrinter) -> Void) {
        self.onFound = onFound
        super.init()
    }

    func start() {
        queue.async {
            guard !self.stopped, self.central == nil else { return }
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            if let central = self.central {
                if central.state == .poweredOn { central.stopScan() }
                central.delegate = nil
            }
            self.central = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, !reported.contains(peripheral.identifier) else { return }
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName
        let zebraServices: Set<String> = [
            ZebraIdentifiers.bleAdvertisedServiceUUID.uppercased(),
            ZebraIdentifiers.bleParserServiceUUID.uppercased(),
        ]
        let advertisesZebra = advertisedServices.contains { zebraServices.contains($0.uuidString.uppercased()) }
        let hasZebraName = name.map(ZebraIdentifiers.looksLikeZebra) ?? false
        guard advertisesZebra || hasZebraName else { return }
        reported.insert(peripheral.identifier)

        let identifier = peripheral.identifier.uuidString
        var details = ["identifier": identifier, "rssi": RSSI.stringValue]
        if let name { details["name"] = name }
        onFound(DiscoveredPrinter(
            name: name ?? "Zebra-Drucker (BLE)",
            // Link-OS-Drucker werben ab Werk mit ihrer Seriennummer als Namen – kein Modellhinweis.
            modelHint: name.flatMap { ZebraIdentifiers.looksLikeZebraSerialNumber($0) ? nil : $0 },
            descriptor: .ble(identifier: identifier, name: name),
            source: .ble,
            details: details
        ))
    }
}
#endif

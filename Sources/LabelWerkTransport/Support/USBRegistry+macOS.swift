#if os(macOS) && canImport(IOKit)
import Foundation
import IOKit

/// Besitzt eine IOKit-Objektreferenz und gibt sie beim Freigeben wieder ab.
final class IOObjectHandle: @unchecked Sendable {
    let object: io_object_t

    /// Übernimmt eine bereits gehaltene (+1) Referenz.
    init(adopting object: io_object_t) {
        self.object = object
    }

    deinit {
        if object != 0 { IOObjectRelease(object) }
    }
}

/// Zugriff auf die IORegistry für USB-Drucker (`IOUSBHostDevice`, `IOUSBHostInterface`).
enum USBRegistry {
    /// Ein gefundenes USB-Gerät samt Registry-Eintrag.
    struct Device {
        let handle: IOObjectHandle
        let identifier: USBDeviceIdentifier
    }

    /// Klassenname der USB-Geräte-Nubs seit macOS 10.11.
    static let deviceClassName = "IOUSBHostDevice"
    /// Klassenname der USB-Interface-Nubs.
    static let interfaceClassName = "IOUSBHostInterface"
    /// `kIORegistryIterateRecursively`.
    private static let iterateRecursively: IOOptionBits = 0x0000_0001

    /// Alle angeschlossenen Geräte eines Herstellers (optional eingeschränkt auf eine Produkt-ID).
    static func devices(vendorID: Int, productID: Int? = nil) -> [Device] {
        let matchingReference: CFMutableDictionary? = IOServiceMatching(deviceClassName)
        guard let matchingReference else { return [] }
        let matching = matchingReference as NSMutableDictionary
        matching["idVendor"] = NSNumber(value: vendorID)
        if let productID, productID != 0 {
            matching["idProduct"] = NSNumber(value: productID)
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [Device] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let handle = IOObjectHandle(adopting: service)
            result.append(Device(handle: handle, identifier: identifier(of: service)))
            service = IOIteratorNext(iterator)
        }
        return result
    }

    /// Liest die Kenndaten eines Geräte-Eintrags.
    static func identifier(of service: io_service_t) -> USBDeviceIdentifier {
        USBDeviceIdentifier(
            vendorID: intProperty(service, "idVendor") ?? 0,
            productID: intProperty(service, "idProduct") ?? 0,
            serialNumber: stringProperty(service, "USB Serial Number") ?? stringProperty(service, "kUSBSerialNumberString"),
            locationID: (property(service, "locationID") as? NSNumber)?.uint32Value,
            productName: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString")
        )
    }

    /// Sucht unterhalb eines Geräts die Schnittstelle der Klasse „Drucker“ (7).
    ///
    /// - Returns: Registry-Eintrag der Schnittstelle (+1 gehalten) und `bInterfaceProtocol`
    ///   (1 = unidirektional, 2 = bidirektional, 3 = IEEE 1284.4).
    static func printerInterface(of device: io_service_t) -> (handle: IOObjectHandle, interfaceProtocol: Int)? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, "IOService", iterateRecursively, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: (handle: IOObjectHandle, interfaceProtocol: Int)?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let handle = IOObjectHandle(adopting: entry)
            if IOObjectConformsTo(entry, interfaceClassName) != 0,
               intProperty(entry, "bInterfaceClass") == ZebraIdentifiers.usbPrinterInterfaceClass {
                let interfaceProtocol = intProperty(entry, "bInterfaceProtocol") ?? 0
                // Bidirektionale Schnittstelle (Protokoll 2) bevorzugen.
                if best == nil || (interfaceProtocol == 2 && best?.interfaceProtocol != 2) {
                    best = (handle, interfaceProtocol)
                }
            }
            entry = IOIteratorNext(iterator)
        }
        return best
    }

    // MARK: Eigenschaften

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        let value: Unmanaged<CFTypeRef>? = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue()
    }

    static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let text = property(entry, key) as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif

import Foundation
import Testing
@testable import LabelWerkTransport

@Suite("USB-Geräteauswahl")
struct USBSelectionTests {
    static let zd421A = USBDeviceIdentifier(productID: 0x0181, serialNumber: "D4J222602341", locationID: 0x1410_0000, productName: "ZTC ZD421-203dpi ZPL")
    static let zd421B = USBDeviceIdentifier(productID: 0x0181, serialNumber: "D4J222609999", locationID: 0x1420_0000, productName: "ZTC ZD421-203dpi ZPL")
    static let gk420 = USBDeviceIdentifier(productID: 0x0080, serialNumber: nil, locationID: 0x1430_0000, productName: "ZDesigner GK420d")
    static let foreign = USBDeviceIdentifier(vendorID: 0x05AC, productID: 0x0181, serialNumber: "D4J222602341", locationID: 0x1440_0000)
    static let all = [foreign, zd421A, zd421B, gk420]

    @Test("Seriennummer hat Vorrang (auch nach Umstecken)")
    func serialWins() {
        let wanted = USBDeviceIdentifier(productID: 0x0181, serialNumber: "d4j222609999", locationID: 0x1410_0000)
        #expect(USBDeviceSelection.bestMatch(for: wanted, among: Self.all) == 2)
    }

    @Test("Anschlussposition, wenn keine Seriennummer passt")
    func locationFallback() {
        let byLocation = USBDeviceIdentifier(productID: 0x0080, locationID: 0x1430_0000)
        #expect(USBDeviceSelection.bestMatch(for: byLocation, among: Self.all) == 3)
        // Anderer Drucker (abweichende Seriennummer) am gespeicherten Anschluss → kein Treffer.
        let replaced = USBDeviceIdentifier(productID: 0x0181, serialNumber: "ANDERER", locationID: 0x1410_0000)
        #expect(USBDeviceSelection.bestMatch(for: replaced, among: Self.all) == nil)
        // Gerät ohne Seriennummer am gespeicherten Anschluss ist zulässig.
        let serialOnSaved = USBDeviceIdentifier(productID: 0x0080, serialNumber: "X", locationID: 0x1430_0000)
        #expect(USBDeviceSelection.bestMatch(for: serialOnSaved, among: Self.all) == 3)
    }

    @Test("Ohne Seriennummer und Anschluss: erstes passendes Gerät, Hersteller muss stimmen")
    func firstMatch() {
        #expect(USBDeviceSelection.bestMatch(for: USBDeviceIdentifier(productID: 0x0181), among: Self.all) == 1)
        #expect(USBDeviceSelection.bestMatch(for: USBDeviceIdentifier(productID: 0), among: Self.all) == 1)
        #expect(USBDeviceSelection.bestMatch(for: USBDeviceIdentifier(productID: 0x9999), among: Self.all) == nil)
        #expect(USBDeviceSelection.bestMatch(for: USBDeviceIdentifier(productID: 0x0181), among: []) == nil)
        #expect(USBDeviceSelection.bestMatch(for: USBDeviceIdentifier(vendorID: 0x05AC, productID: 0x0181), among: Self.all) == 0)
    }

    @Test("Beschreibung für Fehlermeldungen")
    func describe() {
        #expect(USBDeviceSelection.describe(Self.zd421A) == "ZD421 (Seriennr. D4J222602341)")
        #expect(USBDeviceSelection.describe(USBDeviceIdentifier(productID: 0x0120)) == "USB-Gerät 0A5F:0120")
    }
}

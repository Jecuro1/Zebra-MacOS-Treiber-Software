import Foundation
import LabelWerkCore

/// Feste Kennungen von Zebra-Druckern für die verschiedenen Transportwege.
public enum ZebraIdentifiers {
    /// USB-Hersteller-ID von Zebra Technologies.
    public static let usbVendorID = 0x0A5F

    /// USB-Geräteklasse „Drucker“ (Interface-Klasse 7).
    public static let usbPrinterInterfaceClass = 7

    /// Standard-Port für Rohdaten (JetDirect/„RAW“).
    public static let rawPort = 9100

    /// Zweiter Rohdatenport vieler Zebra-Drucker (Link-OS, ZBI) – dasselbe Gerät wie Port 9100.
    public static let alternateRawPort = 6101

    /// Herstellerkennungen (OUI, sechs Hex-Ziffern) von Bluetooth-Adressen mobiler Zebra-Drucker:
    /// bei Zebra Technologies registrierte Blöcke und `AC3FA4` (Bluetooth-Modul von Taiyo Yuden in
    /// ZQ-/QLn-/iMZ-Druckern).
    public static let bluetoothOUIs: Set<String> = ["00074D", "4083DE", "84248D", "94FB29", "AC3FA4"]

    /// `true`, wenn die Bluetooth-Adresse aus einem Adressblock mobiler Zebra-Drucker stammt.
    public static func isZebraBluetoothAddress(_ address: String) -> Bool {
        let hex = address.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return false }
        return bluetoothOUIs.contains(String(hex.prefix(6)))
    }

    /// `true` für Seriennummern im Format von Zebra-Druckern – Link-OS-Drucker melden sich ab Werk unter
    /// ihrer Seriennummer (Bluetooth-/BLE-Name, Systemname der Zebra-Suche, Bonjour-Name):
    ///
    /// * mobile Drucker: „XX“ + drei Buchstaben + mindestens sechs Ziffern („XXQLJ120900310“);
    /// * Desktop- und Industriedrucker: zwei Zeichen (Werk/Baureihe) + „J“ + Jahr (zwei Ziffern) +
    ///   Kalenderwoche (01–53) + fünfstellige laufende Nummer („D6J250301793“, „28J154300589“,
    ///   „52J162000000“). Das „J“ an dritter Stelle haben alle bekannten Desktop-Seriennummern; ohne
    ///   diese Einschränkung passten auch beliebige andere Gerätenamen („ABC123451234“), die dann als
    ///   Zebra-Drucker und als Seriennummer zum Zusammenführen gälten.
    public static func looksLikeZebraSerialNumber(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.range(of: #"^XX[A-Z]{3}[0-9]{6,}$"#, options: .regularExpression) != nil { return true }
        guard value.range(of: #"^[0-9A-Z]{2}J[0-9]{9}$"#, options: .regularExpression) != nil else { return false }
        let digits = Array(value.dropFirst(3))
        guard let week = Int(String(digits[2...3])) else { return false }
        return (1...53).contains(week)
    }

    /// Zebra Parser Service (BLE, Link-OS).
    public static let bleParserServiceUUID = "38EB4A80-C570-11E3-9507-0002A5D5C51B"
    /// Charakteristik „Write to Printer“.
    public static let bleWriteCharacteristicUUID = "38EB4A82-C570-11E3-9507-0002A5D5C51B"
    /// Charakteristik „Read from Printer“ (Notify).
    public static let bleReadCharacteristicUUID = "38EB4A81-C570-11E3-9507-0002A5D5C51B"
    /// 16-Bit-Dienstkennung, die Zebra-Drucker in BLE-Advertisements senden.
    public static let bleAdvertisedServiceUUID = "FE79"

    /// Bonjour-Diensttypen, unter denen Zebra-Netzwerkdrucker auftreten.
    public static let bonjourServiceTypes = ["_pdl-datastream._tcp", "_printer._tcp", "_ipp._tcp"]

    /// Bluetooth-Serial-Port-Profile (SPP), 16-Bit-UUID.
    public static let sppServiceUUID16: UInt16 = 0x1101

    /// Prüft, ob ein Name/Beschreibungstext (Bonjour-TXT, SNMP `sysDescr`, CUPS-URI, BLE-Name …)
    /// wahrscheinlich zu einem Zebra-Drucker gehört.
    ///
    /// Treffer: Schlüsselwörter „Zebra“, „ZTC“, „ZDesigner“ oder ein eindeutiger Modellname aus dem
    /// Modellkatalog (mindestens vier signifikante Zeichen, damit kurze Namen keine Fehltreffer erzeugen).
    public static func looksLikeZebra(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("zebra") || lower.contains("zdesigner") { return true }
        if lower.range(of: #"(^|[^a-z])ztc([^a-z]|$)"#, options: .regularExpression) != nil { return true }
        guard let model = ModelCatalog.shared.match(productName: text) else { return false }
        let significant = model.name.lowercased().filter { $0.isLetter || $0.isNumber }
        return significant.count >= 4
    }

    /// Kurzer, gut lesbarer Modellname aus einem Produktnamen.
    ///
    /// `"ZTC ZD421-203dpi ZPL"` → `"ZD421"`, `"Zebra Technologies ZTC ZT410-300dpi ZPL"` → `"ZT410"`,
    /// `"ZDesigner GK420d"` → `"GK420d"`. Unbekannte Formate werden nur bereinigt zurückgegeben.
    public static func shortModelName(from productName: String) -> String? {
        let wrapping = CharacterSet(charactersIn: "()[]\"").union(.whitespacesAndNewlines)
        var text = productName.trimmingCharacters(in: wrapping)
        guard !text.isEmpty else { return nil }
        let prefixes = ["Zebra Technologies", "Zebra", "ZTC", "ZDesigner"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.lowercased().hasPrefix(prefix.lowercased() + " ") {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        for suffix in [" ZPL", " EPL", " CPCL", " ZPL II", " EPL2"] where text.uppercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: #"-\d{3}dpi$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: wrapping)
        return text.isEmpty ? nil : text
    }
}

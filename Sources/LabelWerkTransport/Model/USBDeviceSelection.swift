import Foundation

/// Plattformunabhängige Auswahl des passenden USB-Geräts (von `USBConnection` genutzt, auf Linux getestet).
enum USBDeviceSelection {
    /// Index des Geräts in `candidates`, das zu `wanted` passt, oder `nil`.
    ///
    /// Regeln (in dieser Reihenfolge):
    /// 1. Hersteller-ID muss stimmen; Produkt-ID nur, wenn `wanted.productID != 0`.
    /// 2. Ist eine Seriennummer angegeben, gewinnt das Gerät mit gleicher Seriennummer.
    /// 3. Sonst (oder ohne Treffer) das Gerät an der angegebenen `locationID` – aber nur, wenn es
    ///    keine *abweichende* Seriennummer meldet (ein anderer Drucker am selben Anschluss).
    /// 4. Ohne Seriennummer und `locationID`: das erste passende Gerät.
    static func bestMatch(for wanted: USBDeviceIdentifier, among candidates: [USBDeviceIdentifier]) -> Int? {
        let eligible = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.vendorID == wanted.vendorID else { return false }
            return wanted.productID == 0 || candidate.productID == wanted.productID
        }
        let wantedSerial = normalizedSerial(wanted.serialNumber)
        if let wantedSerial,
           let match = eligible.first(where: { normalizedSerial(candidates[$0].serialNumber) == wantedSerial }) {
            return match
        }
        if let location = wanted.locationID,
           let match = eligible.first(where: { index in
               let candidate = candidates[index]
               guard candidate.locationID == location else { return false }
               guard let wantedSerial, let serial = normalizedSerial(candidate.serialNumber) else { return true }
               return serial == wantedSerial
           }) {
            return match
        }
        if wantedSerial == nil, wanted.locationID == nil {
            return eligible.first
        }
        return nil
    }

    private static func normalizedSerial(_ serial: String?) -> String? {
        guard let trimmed = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    /// Beschreibung für Fehlermeldungen, z. B. „ZD421 (Seriennr. D4J…)“.
    static func describe(_ device: USBDeviceIdentifier) -> String {
        var text = device.productName.flatMap(ZebraIdentifiers.shortModelName(from:))
            ?? String(format: "USB-Gerät %04lX:%04lX", device.vendorID, device.productID)
        if let serial = device.serialNumber, !serial.isEmpty { text += " (Seriennr. \(serial))" }
        return text
    }
}

import Foundation

/// Erkennt, wann eine Druckerantwort vollständig ist.
///
/// Die Prüfungen werden von ``PrinterClient`` als `isComplete`-Bedingung an
/// `PrinterConnection.request` übergeben. Sie arbeiten auf Rohbytes, sind tolerant gegenüber
/// Zeilenenden und werden nach jedem empfangenen Block erneut aufgerufen – deshalb dürfen sie bei
/// unvollständigen Daten nie `true` liefern. Kommt eine Antwort ohne erkennbares Ende, beendet
/// die Leerlauffrist (`idleTimeout`) die Sammlung.
public enum ResponseFraming {
    static let stx: UInt8 = 0x02
    static let etx: UInt8 = 0x03
    static let cr: UInt8 = 0x0D
    static let lf: UInt8 = 0x0A
    static let quote: UInt8 = 0x22

    /// Antwort ohne erkennbares Ende (z. B. `allcv`): Nur Leerlauffrist bzw. Zeitlimit beenden sie.
    public static func neverComplete(_ data: Data) -> Bool { false }

    /// `~HS`: vollständig, sobald drei `ETX` empfangen wurden (drei Zeilen `STX…ETX CR LF`).
    public static func hostStatusComplete(_ data: Data) -> Bool {
        count(etx, in: data) >= 3
    }

    /// `~HI`, `^HH`, `^HW` und andere `STX…ETX`-Antworten: vollständig mit dem ersten `ETX`.
    public static func etxComplete(_ data: Data) -> Bool {
        data.contains(etx)
    }

    /// `~HQES`: vollständig, sobald die Zeile `WARNINGS:` abgeschlossen ist (CR, LF oder `ETX`
    /// danach). Die Zeile `ERRORS:` steht laut ZPL-Handbuch immer davor.
    public static func hostQueryComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard let start = find(Array("WARNINGS".utf8), in: bytes, caseInsensitive: true) else { return false }
        var index = start + 8
        var sawContent = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == cr || byte == lf || byte == etx { return sawContent }
            if byte != 0x3A && byte != 0x20 && byte != 0x09 { sawContent = true }
            index += 1
        }
        return false
    }

    /// SGD `getvar`: Die Antwort ist eine Zeichenkette in Anführungszeichen (`"203"`); vollständig
    /// mit dem schließenden Anführungszeichen.
    public static func quotedValueComplete(_ data: Data) -> Bool {
        count(quote, in: data) >= 2
    }

    /// JSON-SGD (`{}{…}`): vollständig, sobald ein nicht leeres JSON-Objekt geschlossen ist
    /// (Klammern ausgeglichen; Klammern in Zeichenketten zählen nicht). Ein vorangestelltes
    /// leeres Objekt `{}` (Echo der Anfrage) beendet die Antwort nicht.
    public static func jsonComplete(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        var hasContent = false
        for byte in data {
            if inString {
                hasContent = true
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x7B: // {
                depth += 1
            case 0x7D: // }
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 {
                    if hasContent { return true }
                    hasContent = false
                }
            case quote:
                if depth > 0 { inString = true; hasContent = true }
            case 0x20, 0x09, cr, lf:
                continue
            default:
                if depth > 0 { hasContent = true }
            }
        }
        return false
    }

    /// Dateiliste per SGD `file.dir`: vollständig mit der Zeile „bytes free“ bzw. dem
    /// schließenden Anführungszeichen einer in Anführungszeichen gefassten Antwort.
    public static func directoryComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if let start = find(Array("bytes free".utf8), in: bytes, caseInsensitive: true) {
            // Die Zeile muss abgeschlossen sein (CR/LF, ETX oder Anführungszeichen).
            return bytes[(start + 10)...].contains { $0 == cr || $0 == lf || $0 == etx || $0 == quote }
        }
        if bytes.first(where: { $0 > 0x20 }) == quote { return quotedValueComplete(data) }
        return etxComplete(data)
    }

    // MARK: - Hilfen

    static func count(_ byte: UInt8, in data: Data) -> Int {
        var total = 0
        for value in data where value == byte { total += 1 }
        return total
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], caseInsensitive: Bool) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        func fold(_ b: UInt8) -> UInt8 { caseInsensitive && b >= 0x41 && b <= 0x5A ? b + 0x20 : b }
        let pattern = needle.map(fold)
        outer: for start in 0...(haystack.count - pattern.count) {
            for offset in 0..<pattern.count where fold(haystack[start + offset]) != pattern[offset] {
                continue outer
            }
            return start
        }
        return nil
    }
}

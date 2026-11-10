import Foundation
import LabelWerkKit

// RFID-Logik ohne Oberfläche: Speicherbänke, ZPL-Befehle (^RF, ^HV, ^HR, ^RS, ^RR), Auswertung
// der Druckerantworten, Hex-Hilfen, EPC-/TID-Dekodierung, SGTIN-96-Erzeugung,
// Kalibrierauswertung und SGD-Statuswerte.
//
// ZPL-Referenz der verwendeten RFID-Befehle (ZPL II / RFID Programming Guide):
//
//   ^RFo,f,b,n,m   Read or Write RFID Format
//     o  Operation      R = lesen, W = schreiben
//     f  Format         H = Hexadezimal (A = ASCII, E = EPC nach ^RB – hier nicht verwendet)
//     b  Startwort      Gen 2: 16-Bit-Wortadresse innerhalb der Bank. In der EPC-Bank beginnt der
//                       EPC bei Wort 2 (Wort 0 = CRC, Wort 1 = PC-Wort mit der EPC-Länge).
//     n  Bytes          Anzahl der zu lesenden bzw. zu schreibenden Bytes (2 Hex-Zeichen je Byte)
//     m  Speicherbank   0 = Reserviert (Passwörter), 1 = EPC, 2 = TID, 3 = Benutzerspeicher
//                       (E = EPC mit automatischer PC-Anpassung – hier nicht verwendet, wir
//                       adressieren explizit und schreiben das PC-Wort bei Bedarf selbst).
//
//   ^FNx           Feldnummer – nimmt die gelesenen Daten auf
//   ^HVa,b,c       Host Verification: Feld a mit b Bytes und dem Kopf c an den Host senden
//   ^RS8           RFID-Setup: Tag-Typ EPC Class 1 Gen 2
//   ^RRn           Wiederholungen je Block bei Lese-/Schreibfehlern (0 … 10)
//   ^HR            RFID-Kalibrierung; liefert eine Ergebnistabelle (start … end) an den Host
//
// Beispiele:
//   EPC lesen (96 Bit):  ^XA ^RFR,H,1,2,1^FN2^FS^HV2,4,PCW-1:^FS ^RFR,H,2,12,1^FN1^FS^HV1,24,EPC-1:^FS ^XZ
//   TID lesen (64 Bit):  ^XA ^RFR,H,0,8,2^FN1^FS^HV1,16,TID-2:^FS ^XZ
//   EPC schreiben:       ^XA ^RS8 ^RFW,H,2,12,1^FD3074257BF7194E4000001A85^FS ^XZ
//   … mit Prüfung:       zusätzlich ^RFR,H,2,12,1^FN1^FS^HV1,24,EPC#7:^FS (Kopf je Tag eindeutig)
//
// Jede ^HV-Antwort trägt einen Kopf mit laufender Nummer („EPC-12:“ beim Lesen, „EPC#7:“ beim
// Kodieren mit Prüfung). Antworten, die erst nach Ablauf der Wartezeit eintreffen (Drucker angehalten,
// Papier leer, VOID-Wiederholungen), lassen sich so ihrem Auftrag zuordnen, statt als Antwort des
// nächsten zu gelten.

// MARK: - Speicherbänke

/// Gen-2-Speicherbank eines UHF-Tags (Parameter `m` von `^RF`).
enum RFIDMemoryBank: Int, CaseIterable, Identifiable, Hashable {
    case reserved = 0
    case epc = 1
    case tid = 2
    case user = 3

    /// Bänke, die die Oberfläche zum Lesen anbietet (die Passwortbank bleibt bewusst außen vor).
    static let readable: [RFIDMemoryBank] = [.epc, .tid, .user]

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reserved: return tr("Reserviert")
        case .epc: return tr("EPC")
        case .tid: return tr("TID")
        case .user: return tr("Benutzerspeicher")
        }
    }

    var detail: String {
        switch self {
        case .reserved:
            return tr("Kill- und Zugriffspasswort des Tags (Bank 0).")
        case .epc:
            return tr("Elektronischer Produktcode – die Kennung, die Lesegeräte sehen. Bank 1, ab Wort 2 (nach CRC und PC-Wort).")
        case .tid:
            return tr("Werkseitig fest programmierte Chip-Kennung mit Hersteller, Chipmodell und Seriendaten. Bank 2, nur lesbar.")
        case .user:
            return tr("Optionaler Benutzerspeicher für eigene Daten. Bank 3 – nicht jeder Chip besitzt ihn.")
        }
    }

    var systemImage: String {
        switch self {
        case .reserved: return "lock"
        case .epc: return "barcode"
        case .tid: return "cpu"
        case .user: return "person.text.rectangle"
        }
    }

    /// Startwort für `^RF` (Parameter `b`).
    var startWord: Int { self == .epc ? 2 : 0 }

    /// Wählbare Leselängen in Bytes.
    var lengthOptions: [Int] {
        switch self {
        case .reserved: return [8]
        case .epc: return [8, 12, 16, 20, 24, 32]
        case .tid: return [4, 8, 12, 16]
        case .user: return [2, 4, 8, 16, 32, 64]
        }
    }

    var defaultLength: Int {
        switch self {
        case .reserved: return 8
        case .epc: return 12
        case .tid: return 8
        case .user: return 8
        }
    }

    /// Grundform des Kopfs, den `^HV` der Antwort voranstellt (bewusst ohne gemeinsame
    /// Teilzeichenfolgen); gesendet wird er mit Auftragsnummer (``RFIDCommand/header(_:request:)``).
    var responseHeader: String {
        switch self {
        case .reserved: return "RSV:"
        case .epc: return "EPC:"
        case .tid: return "TID:"
        case .user: return "USR:"
        }
    }
}

// MARK: - ZPL-Befehle

/// Ein erklärter Parameter eines RFID-Befehls (für die Befehlsanzeige der Oberfläche).
struct RFIDCommandParameter: Hashable, Identifiable {
    let key: String
    let value: String
    let meaning: String
    var id: String { key }
}

/// Bausteine für die ZPL-RFID-Befehle.
enum RFIDCommand {
    /// Kopf der PC-Wort-Antwort (Länge des EPC laut Tag).
    static let pcHeader = "PCW:"
    /// Tag-Typ EPC Class 1 Gen 2.
    static let tagTypeGen2 = "^RS8"
    /// RFID-Kalibrierung mit Ergebnistabelle an den Host.
    static let calibrationFormat = "^XA^HR^XZ"
    /// Größte Datenmenge, die `^HV` zurückliefert.
    static let maxHostVerificationBytes = 256

    /// `^RFo,H,b,n,m`
    static func rf(operation: String, startWord: Int, byteCount: Int, bank: RFIDMemoryBank) -> String {
        "^RF\(operation),H,\(max(0, startWord)),\(max(1, byteCount)),\(bank.rawValue)"
    }

    /// Erklärung der Parameter von `^RFo,f,b,n,m`.
    static func parameters(operation: String, startWord: Int, byteCount: Int,
                           bank: RFIDMemoryBank) -> [RFIDCommandParameter] {
        let operationText = operation == "W" ? tr("Schreiben") : tr("Lesen")
        return [
            RFIDCommandParameter(key: "o", value: operation, meaning: operationText),
            RFIDCommandParameter(key: "f", value: "H", meaning: tr("Hexadezimal")),
            RFIDCommandParameter(key: "b", value: String(startWord), meaning: tr("Startwort %d", startWord)),
            RFIDCommandParameter(key: "n", value: String(byteCount),
                                 meaning: tr("%d Bytes (%d Bit)", byteCount, byteCount * 8)),
            RFIDCommandParameter(key: "m", value: String(bank.rawValue),
                                 meaning: tr("Bank %d · %@", bank.rawValue, bank.title)),
        ]
    }

    /// Lesefeld: `^RFR…^FNx^FS^HVx,len,KOPF^FS` – liest in Feld `field` und sendet es an den Host.
    static func readField(bank: RFIDMemoryBank, startWord: Int, byteCount: Int, field: Int, header: String) -> String {
        let hexLength = min(max(1, byteCount * 2), maxHostVerificationBytes)
        return rf(operation: "R", startWord: startWord, byteCount: byteCount, bank: bank)
            + "^FN\(field)^FS^HV\(field),\(hexLength),\(header)^FS"
    }

    /// Kopf einer Leseantwort mit Auftragsnummer: aus „EPC:“ wird „EPC-12:“. Eine verspätete Antwort
    /// eines früheren Lesevorgangs gilt so nie als Ergebnis des aktuellen.
    static func header(_ base: String, request: Int) -> String {
        let stem = base.hasSuffix(":") ? String(base.dropLast()) : base
        return "\(stem)-\(request):"
    }

    /// Präfix der Prüfantwort beim Kodieren, siehe ``verifyHeader(number:)``.
    static let verifyHeaderPrefix = "EPC#"

    /// Kopf der ^HV-Prüfantwort beim Kodieren (`EPC#7:`) – je Tag eindeutig, damit sich eine verspätete
    /// Antwort ihrem Tag zuordnen lässt statt dem nächsten.
    static func verifyHeader(number: Int) -> String {
        "\(verifyHeaderPrefix)\(number):"
    }

    /// Vollständiges Leseformat. Für die EPC-Bank wird zusätzlich das PC-Wort gelesen, um die
    /// vom Tag gemeldete EPC-Länge anzuzeigen. `request` nummeriert die Antwortköpfe
    /// (``header(_:request:)``).
    static func readFormat(bank: RFIDMemoryBank, byteCount: Int, includePCWord: Bool, request: Int) -> String {
        var lines = ["^XA"]
        if bank == .epc && includePCWord {
            lines.append(readField(bank: .epc, startWord: 1, byteCount: 2, field: 2,
                                   header: header(pcHeader, request: request)))
        }
        lines.append(readField(bank: bank, startWord: bank.startWord, byteCount: byteCount, field: 1,
                               header: header(bank.responseHeader, request: request)))
        lines.append("^XZ")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Eine Prüfantwort beim Kodieren: laufende Nummer aus dem Kopf und zurückgelesener EPC
/// (`nil` = Kopf ohne Daten).
struct RFIDVerification: Equatable {
    let number: Int
    let hex: String?
}

// MARK: - Antworten

/// Auswertung der Druckerantworten (`^HV`, `^HR`).
enum RFIDResponseParser {
    /// Antwort als Text; Steuerzeichen (STX, ETX, NUL …) werden zu Leerzeichen, Zeilenenden zu `\n`.
    static func text(_ data: Data) -> String {
        let decoded = String(decoding: data, as: UTF8.self)
        var scalars = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in decoded.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                scalars.append("\n")
                previousWasCR = true
                continue
            case 0x0A:
                if !previousWasCR { scalars.append("\n") }
            case 0x00..<0x20, 0x7F:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
            previousWasCR = false
        }
        return String(scalars)
    }

    /// Antwort ohne STX/ETX/NUL/CR/LF – für die kompakte Anzeige der Rohantwort.
    static func compact(_ data: Data) -> String {
        let collapsed = text(data).replacingOccurrences(of: "\n", with: " ")
        return collapsed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Sucht `KOPF<hex>` und liefert höchstens `expectedDigits` Hex-Ziffern (Großbuchstaben).
    ///
    /// Leerraum vor den Daten wird übersprungen; die Daten enden am ersten Zeichen, das keine
    /// Hex-Ziffer ist, bzw. nach `expectedDigits` Ziffern (Antworten mehrerer `^HV` können ohne
    /// Trenner aneinanderhängen). `nil`, wenn der Kopf fehlt oder keine Daten folgen.
    static func hexValue(in text: String, header: String, expectedDigits: Int) -> String? {
        guard expectedDigits > 0,
              let range = text.range(of: header, options: [.caseInsensitive]) else { return nil }
        return leadingHex(text[range.upperBound...], expectedDigits: expectedDigits)
    }

    /// Alle Prüfantworten (`EPC#<nr>:<hex>`, siehe ``RFIDCommand/verifyHeader(number:)``) in der
    /// Reihenfolge des Eintreffens.
    ///
    /// Die Daten einer Antwort enden spätestens am nächsten Kopf bzw. nach `expectedDigits` Ziffern.
    /// Mehrere Antworten zu derselben Nummer (Wiederholung nach VOID) bleiben erhalten – die letzte
    /// ist die aktuelle.
    static func verifications(in text: String, expectedDigits: Int) -> [RFIDVerification] {
        var heads: [(number: Int, start: String.Index, dataStart: String.Index)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let found = text.range(of: RFIDCommand.verifyHeaderPrefix, options: [.caseInsensitive],
                                     range: cursor..<text.endIndex) {
            var index = found.upperBound
            var digits = ""
            while index < text.endIndex, text[index].isASCII, text[index].isNumber {
                digits.append(text[index])
                index = text.index(after: index)
            }
            if !digits.isEmpty, index < text.endIndex, text[index] == ":", let number = Int(digits) {
                let dataStart = text.index(after: index)
                heads.append((number, found.lowerBound, dataStart))
                cursor = dataStart
            } else {
                cursor = found.upperBound
            }
        }
        return heads.indices.map { position in
            let head = heads[position]
            let end = position + 1 < heads.count ? heads[position + 1].start : text.endIndex
            return RFIDVerification(number: head.number,
                                    hex: leadingHex(text[head.dataStart..<end], expectedDigits: expectedDigits))
        }
    }

    /// Hex-Ziffern am Anfang von `text` (führender Leerraum wird übersprungen), höchstens
    /// `expectedDigits`, in Großbuchstaben; `nil`, wenn keine folgen.
    private static func leadingHex(_ text: Substring, expectedDigits: Int) -> String? {
        guard expectedDigits > 0 else { return nil }
        var digits = ""
        for character in text {
            if digits.count >= expectedDigits { break }
            if RFIDHex.isHexDigit(character) {
                digits.append(character)
            } else if character.isWhitespace && digits.isEmpty {
                continue
            } else {
                break
            }
        }
        return digits.isEmpty ? nil : digits.uppercased()
    }

    /// `true`, wenn der Kopf in der Antwort vorkommt (auch ohne Daten).
    static func containsHeader(_ text: String, header: String) -> Bool {
        text.range(of: header, options: [.caseInsensitive]) != nil
    }
}

// MARK: - Hex

/// Hilfen für Hex-Daten (EPC, TID, Benutzerspeicher).
enum RFIDHex {
    /// Größte EPC-Länge nach Gen 2 (31 Wörter).
    static let maxEPCBits = 496

    enum Issue: Equatable {
        case empty
        case invalidCharacter(Character)
        case notWordAligned(Int)
        case tooLong(Int)

        var message: String {
            switch self {
            case .empty:
                return tr("Bitte EPC-Daten als Hex eingeben.")
            case .invalidCharacter(let character):
                return tr("„%@“ ist keine Hex-Ziffer. Erlaubt sind 0–9 und A–F.", String(character))
            case .notWordAligned(let count):
                return tr("%d Hex-Zeichen – die Länge muss ein Vielfaches von 4 sein (16-Bit-Wörter).", count)
            case .tooLong(let bits):
                return tr("%d Bit sind zu lang – Gen-2-Tags fassen höchstens 496 Bit EPC.", bits)
            }
        }
    }

    static func isHexDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (0x30...0x39).contains(ascii) || (0x41...0x46).contains(ascii) || (0x61...0x66).contains(ascii)
    }

    /// Entfernt Leerraum und übliche Trenner (`-`, `:`, `.`) und wandelt in Großbuchstaben.
    static func sanitize(_ input: String) -> String {
        String(input.filter { !$0.isWhitespace && $0 != "-" && $0 != ":" && $0 != "." }).uppercased()
    }

    static func validate(_ hex: String, maxBits: Int = maxEPCBits) -> Issue? {
        if hex.isEmpty { return .empty }
        if let bad = hex.first(where: { !isHexDigit($0) }) { return .invalidCharacter(bad) }
        if hex.count % 4 != 0 { return .notWordAligned(hex.count) }
        if hex.count * 4 > maxBits { return .tooLong(hex.count * 4) }
        return nil
    }

    /// Gruppiert in Blöcke (Standard: 4 Hex-Zeichen = ein 16-Bit-Wort).
    static func grouped(_ hex: String, size: Int = 4) -> String {
        guard size > 0 else { return hex }
        var out = ""
        out.reserveCapacity(hex.count + hex.count / size)
        for (index, character) in hex.enumerated() {
            if index > 0 && index % size == 0 { out.append(" ") }
            out.append(character)
        }
        return out
    }

    /// Bytes aus Hex (ein übrig bleibendes Halbbyte wird ignoriert).
    static func bytes(_ hex: String) -> [UInt8] {
        let values = hex.compactMap { isHexDigit($0) ? $0.hexDigitValue : nil }
        var result: [UInt8] = []
        result.reserveCapacity(values.count / 2)
        var index = 0
        while index + 1 < values.count {
            result.append(UInt8(values[index] << 4 | values[index + 1]))
            index += 2
        }
        return result
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Addiert `amount` zur Hex-Zahl (Länge bleibt gleich). `nil` bei Überlauf oder ungültiger Eingabe.
    static func increment(_ hex: String, by amount: UInt64) -> String? {
        guard !hex.isEmpty, hex.allSatisfy(isHexDigit) else { return nil }
        var values = hex.compactMap { $0.hexDigitValue }
        var carry = amount
        var index = values.count - 1
        while carry > 0 {
            guard index >= 0 else { return nil }
            let total = UInt64(values[index]) + (carry & 0xF)
            values[index] = Int(total & 0xF)
            carry = (carry >> 4) + (total >> 4)
            index -= 1
        }
        return String(values.map { Character(String($0, radix: 16, uppercase: true)) })
    }

    /// Zufällige Hex-Daten (z. B. für Testtags).
    static func random(digits: Int) -> String {
        let alphabet = Array("0123456789ABCDEF")
        return String((0..<max(0, digits)).map { _ in alphabet[Int.random(in: 0..<16)] })
    }

    /// PC-Wort (Protocol Control) für eine EPC-Länge in Bytes: Länge in Wörtern in Bit 15…11.
    static func pcWord(forByteCount byteCount: Int) -> String {
        let words = max(0, min(31, byteCount / 2))
        return String(format: "%04lX", words << 11)
    }

    /// EPC-Länge in Bit laut PC-Wort.
    static func epcBits(fromPCWord pc: String) -> Int? {
        guard pc.count == 4, let value = UInt16(pc, radix: 16) else { return nil }
        return Int((value >> 11) & 0x1F) * 16
    }

    /// Text, falls alle Bytes druckbares ASCII sind (manche Anwender kodieren Klartext).
    static func printableASCII(_ hex: String) -> String? {
        let data = bytes(hex)
        guard !data.isEmpty, data.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Dekodierung

/// Ein beschrifteter Wert der Tag-Auswertung.
struct RFIDInfoItem: Hashable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Ergebnis einer Dekodierung (Schema bzw. Chip und Einzelwerte).
struct RFIDDecodedInfo: Hashable {
    var title: String
    var items: [RFIDInfoItem]
}

/// Liest Bitfelder (MSB zuerst).
struct RFIDBitReader {
    let bytes: [UInt8]
    private(set) var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count * 8 - position }

    mutating func read(_ count: Int) -> UInt64? {
        guard count >= 0, count <= 64, count <= remaining else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            let byte = bytes[position / 8]
            let bit = (byte >> UInt8(7 - position % 8)) & 1
            value = (value << 1) | UInt64(bit)
            position += 1
        }
        return value
    }
}

/// Fehler beim Erzeugen eines SGTIN-96.
enum RFIDSGTINError: Error, Equatable {
    case invalidGTIN
    case checkDigit(expected: Int)
    case companyPrefixLength
    case filter
    case serialTooLarge

    var message: String {
        switch self {
        case .invalidGTIN:
            return tr("Bitte eine GTIN mit 8, 12, 13 oder 14 Ziffern eingeben.")
        case .checkDigit(let expected):
            return tr("Die Prüfziffer stimmt nicht – erwartet wird %d.", expected)
        case .companyPrefixLength:
            return tr("Die Länge des Firmenpräfixes muss zwischen 6 und 12 Stellen liegen.")
        case .filter:
            return tr("Der Filterwert muss zwischen 0 und 7 liegen.")
        case .serialTooLarge:
            return tr("Die Seriennummer ist zu groß (höchstens 274.877.906.943).")
        }
    }
}

/// Dekodierung von EPC-Daten nach GS1 EPC Tag Data Standard (SGTIN-96, SSCC-96, GID-96).
enum RFIDEPCDecoder {
    /// Partitionstabelle (Bits/Stellen von Firmenpräfix und Referenz).
    struct Partition {
        let prefixBits: Int
        let prefixDigits: Int
        let referenceBits: Int
        let referenceDigits: Int
    }

    static let sgtinPartitions: [Partition] = [
        Partition(prefixBits: 40, prefixDigits: 12, referenceBits: 4, referenceDigits: 1),
        Partition(prefixBits: 37, prefixDigits: 11, referenceBits: 7, referenceDigits: 2),
        Partition(prefixBits: 34, prefixDigits: 10, referenceBits: 10, referenceDigits: 3),
        Partition(prefixBits: 30, prefixDigits: 9, referenceBits: 14, referenceDigits: 4),
        Partition(prefixBits: 27, prefixDigits: 8, referenceBits: 17, referenceDigits: 5),
        Partition(prefixBits: 24, prefixDigits: 7, referenceBits: 20, referenceDigits: 6),
        Partition(prefixBits: 20, prefixDigits: 6, referenceBits: 24, referenceDigits: 7),
    ]

    static let ssccPartitions: [Partition] = [
        Partition(prefixBits: 40, prefixDigits: 12, referenceBits: 18, referenceDigits: 5),
        Partition(prefixBits: 37, prefixDigits: 11, referenceBits: 21, referenceDigits: 6),
        Partition(prefixBits: 34, prefixDigits: 10, referenceBits: 24, referenceDigits: 7),
        Partition(prefixBits: 30, prefixDigits: 9, referenceBits: 28, referenceDigits: 8),
        Partition(prefixBits: 27, prefixDigits: 8, referenceBits: 31, referenceDigits: 9),
        Partition(prefixBits: 24, prefixDigits: 7, referenceBits: 34, referenceDigits: 10),
        Partition(prefixBits: 20, prefixDigits: 6, referenceBits: 38, referenceDigits: 11),
    ]

    /// Größte Seriennummer eines SGTIN-96 (38 Bit).
    static let maxSGTINSerial: UInt64 = (1 << 38) - 1

    /// Name des Kodierschemas zum EPC-Header.
    static func schemeName(header: UInt8) -> String? {
        switch header {
        case 0x2C: return "GDTI-96"
        case 0x2D: return "GSRN-96"
        case 0x2F: return "DoD-96"
        case 0x30: return "SGTIN-96"
        case 0x31: return "SSCC-96"
        case 0x32: return "SGLN-96"
        case 0x33: return "GRAI-96"
        case 0x34: return "GIAI-96"
        case 0x35: return "GID-96"
        case 0x36: return "SGTIN-198"
        case 0x37: return "GRAI-170"
        case 0x38: return "GIAI-202"
        case 0x39: return "SGLN-195"
        default: return nil
        }
    }

    /// Bedeutung des SGTIN-Filterwerts.
    static func filterName(_ value: Int) -> String {
        switch value {
        case 0: return tr("Sonstige")
        case 1: return tr("Verkaufseinheit (POS)")
        case 2: return tr("Transportverpackung")
        case 4: return tr("Innenverpackung")
        case 6: return tr("Ladeeinheit")
        case 7: return tr("Komponente / Einzelteil")
        default: return tr("Reserviert")
        }
    }

    static func decode(hex: String) -> RFIDDecodedInfo? {
        let bytes = RFIDHex.bytes(hex)
        guard let header = bytes.first else { return nil }
        if bytes.count >= 12 {
            switch header {
            case 0x30: return sgtin96(Array(bytes.prefix(12)))
            case 0x31: return sscc96(Array(bytes.prefix(12)))
            case 0x35: return gid96(Array(bytes.prefix(12)))
            default: break
            }
        }
        if let name = schemeName(header: header) {
            return RFIDDecodedInfo(title: name, items: [
                RFIDInfoItem(label: tr("Kopf"), value: String(format: "0x%02X", header)),
                RFIDInfoItem(label: tr("Hinweis"), value: tr("GS1-Schema erkannt; Felder werden nicht einzeln zerlegt.")),
            ])
        }
        if let ascii = RFIDHex.printableASCII(hex) {
            return RFIDDecodedInfo(title: tr("Freie Daten"), items: [RFIDInfoItem(label: tr("Als Text"), value: ascii)])
        }
        return nil
    }

    static func sgtin96(_ bytes: [UInt8]) -> RFIDDecodedInfo? {
        var reader = RFIDBitReader(bytes: bytes)
        guard reader.read(8) == 0x30,
              let filter = reader.read(3), let partitionValue = reader.read(3),
              Int(partitionValue) < sgtinPartitions.count else { return nil }
        let partition = sgtinPartitions[Int(partitionValue)]
        guard let prefix = reader.read(partition.prefixBits),
              let reference = reader.read(partition.referenceBits),
              let serial = reader.read(38) else { return nil }
        guard prefix < pow10(partition.prefixDigits), reference < pow10(partition.referenceDigits) else {
            return RFIDDecodedInfo(title: "SGTIN-96", items: [
                RFIDInfoItem(label: tr("Hinweis"), value: tr("Die Felder passen nicht zur Partition – kein gültiger SGTIN-96.")),
            ])
        }
        let prefixText = padded(prefix, partition.prefixDigits)
        let referenceText = padded(reference, partition.referenceDigits)
        let body = String(referenceText.prefix(1)) + prefixText + String(referenceText.dropFirst())
        let gtin = body + String(gs1CheckDigit(body))
        return RFIDDecodedInfo(title: "SGTIN-96", items: [
            RFIDInfoItem(label: tr("GTIN"), value: gtin),
            RFIDInfoItem(label: tr("Seriennummer"), value: String(serial)),
            RFIDInfoItem(label: tr("Firmenpräfix"), value: prefixText),
            RFIDInfoItem(label: tr("Artikelreferenz"), value: referenceText),
            RFIDInfoItem(label: tr("Filter"), value: "\(filter) · " + filterName(Int(filter))),
            RFIDInfoItem(label: tr("EPC-URI"), value: "urn:epc:id:sgtin:\(prefixText).\(referenceText).\(serial)"),
        ])
    }

    static func sscc96(_ bytes: [UInt8]) -> RFIDDecodedInfo? {
        var reader = RFIDBitReader(bytes: bytes)
        guard reader.read(8) == 0x31,
              let filter = reader.read(3), let partitionValue = reader.read(3),
              Int(partitionValue) < ssccPartitions.count else { return nil }
        let partition = ssccPartitions[Int(partitionValue)]
        guard let prefix = reader.read(partition.prefixBits),
              let reference = reader.read(partition.referenceBits) else { return nil }
        guard prefix < pow10(partition.prefixDigits), reference < pow10(partition.referenceDigits) else {
            return RFIDDecodedInfo(title: "SSCC-96", items: [
                RFIDInfoItem(label: tr("Hinweis"), value: tr("Die Felder passen nicht zur Partition – kein gültiger SSCC-96.")),
            ])
        }
        let prefixText = padded(prefix, partition.prefixDigits)
        let referenceText = padded(reference, partition.referenceDigits)
        let body = String(referenceText.prefix(1)) + prefixText + String(referenceText.dropFirst())
        let sscc = body + String(gs1CheckDigit(body))
        return RFIDDecodedInfo(title: "SSCC-96", items: [
            RFIDInfoItem(label: tr("SSCC"), value: sscc),
            RFIDInfoItem(label: tr("Firmenpräfix"), value: prefixText),
            RFIDInfoItem(label: tr("Seriennummer"), value: referenceText),
            RFIDInfoItem(label: tr("Filter"), value: String(filter)),
            RFIDInfoItem(label: tr("EPC-URI"), value: "urn:epc:id:sscc:\(prefixText).\(referenceText)"),
        ])
    }

    static func gid96(_ bytes: [UInt8]) -> RFIDDecodedInfo? {
        var reader = RFIDBitReader(bytes: bytes)
        guard reader.read(8) == 0x35,
              let manager = reader.read(28), let objectClass = reader.read(24), let serial = reader.read(36) else {
            return nil
        }
        return RFIDDecodedInfo(title: "GID-96", items: [
            RFIDInfoItem(label: tr("Verwalter"), value: String(manager)),
            RFIDInfoItem(label: tr("Objektklasse"), value: String(objectClass)),
            RFIDInfoItem(label: tr("Seriennummer"), value: String(serial)),
            RFIDInfoItem(label: tr("EPC-URI"), value: "urn:epc:id:gid:\(manager).\(objectClass).\(serial)"),
        ])
    }

    /// Erzeugt einen SGTIN-96 (24 Hex-Zeichen) aus GTIN, Länge des Firmenpräfixes, Filter und Seriennummer.
    static func encodeSGTIN96(gtin rawGTIN: String, companyPrefixLength: Int, filter: Int,
                              serial: UInt64) throws -> String {
        let digits = rawGTIN.filter { !$0.isWhitespace && $0 != "-" }
        guard [8, 12, 13, 14].contains(digits.count),
              digits.allSatisfy({ $0.asciiValue.map { (0x30...0x39).contains($0) } ?? false }) else {
            throw RFIDSGTINError.invalidGTIN
        }
        let gtin14 = String(repeating: "0", count: 14 - digits.count) + digits
        let body = String(gtin14.prefix(13))
        let expected = gs1CheckDigit(body)
        guard gtin14.last?.wholeNumberValue == expected else { throw RFIDSGTINError.checkDigit(expected: expected) }
        guard (6...12).contains(companyPrefixLength) else { throw RFIDSGTINError.companyPrefixLength }
        guard (0...7).contains(filter) else { throw RFIDSGTINError.filter }
        guard serial <= maxSGTINSerial else { throw RFIDSGTINError.serialTooLarge }

        let partitionIndex = 12 - companyPrefixLength
        let partition = sgtinPartitions[partitionIndex]
        let indicator = String(body.prefix(1))
        let prefixText = String(body.dropFirst().prefix(companyPrefixLength))
        let referenceText = indicator + String(body.dropFirst(1 + companyPrefixLength))
        guard let prefix = UInt64(prefixText), let reference = UInt64(referenceText) else {
            throw RFIDSGTINError.invalidGTIN
        }

        var bits: [Bool] = []
        bits.reserveCapacity(96)
        func append(_ value: UInt64, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                bits.append((value >> UInt64(shift)) & 1 == 1)
            }
        }
        append(0x30, 8)
        append(UInt64(filter), 3)
        append(UInt64(partitionIndex), 3)
        append(prefix, partition.prefixBits)
        append(reference, partition.referenceBits)
        append(serial, 38)

        var bytes = [UInt8](repeating: 0, count: 12)
        for (index, bit) in bits.enumerated() where bit {
            bytes[index / 8] |= UInt8(1) << UInt8(7 - index % 8)
        }
        return RFIDHex.hex(bytes)
    }

    /// GS1-Prüfziffer (Gewichte 3/1 von rechts).
    static func gs1CheckDigit(_ digits: String) -> Int {
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            let value = character.wholeNumberValue ?? 0
            sum += offset % 2 == 0 ? value * 3 : value
        }
        return (10 - sum % 10) % 10
    }

    static func pow10(_ exponent: Int) -> UInt64 {
        var value: UInt64 = 1
        for _ in 0..<max(0, min(exponent, 19)) { value *= 10 }
        return value
    }

    static func padded(_ value: UInt64, _ digits: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

/// Dekodierung der TID (Chiphersteller nach GS1-Liste der Mask Designer IDs).
enum RFIDTIDDecoder {
    static func manufacturer(maskDesignerID: Int) -> String? {
        switch maskDesignerID {
        case 0x001: return "Impinj"
        case 0x002: return "Texas Instruments"
        case 0x003: return "Alien Technology"
        case 0x004: return "Intelleflex"
        case 0x005: return "Atmel"
        case 0x006: return "NXP Semiconductors"
        case 0x007: return "STMicroelectronics"
        case 0x008: return "EP Microelectronics"
        case 0x009: return "Motorola"
        case 0x00A: return "Sentech"
        case 0x00B: return "EM Microelectronic"
        case 0x00C: return "Renesas"
        case 0x00D: return "Mstar"
        case 0x00E: return "Tyco International"
        case 0x00F: return "Quanray Electronics"
        case 0x010: return "Fujitsu"
        case 0x011: return "LSIS"
        case 0x012: return "CAEN RFID"
        case 0x013: return "Productivity Engineering"
        case 0x014: return "Federal Electric"
        case 0x015: return "ON Semiconductor"
        case 0x016: return "Ramtron"
        case 0x017: return "Tego"
        case 0x018: return "Ceitec"
        default: return nil
        }
    }

    static func decode(hex: String) -> RFIDDecodedInfo? {
        let bytes = RFIDHex.bytes(hex)
        guard bytes.count >= 4 else { return nil }
        switch bytes[0] {
        case 0xE2:
            let designer12 = Int(bytes[1]) << 4 | Int(bytes[2]) >> 4
            let model = (Int(bytes[2]) & 0x0F) << 8 | Int(bytes[3])
            let extended = designer12 & 0x800 != 0
            let designer = designer12 & 0x1FF
            let maker = manufacturer(maskDesignerID: designer)
                ?? tr("Unbekannt (ID 0x%03lX)", designer)
            var items = [
                RFIDInfoItem(label: tr("Klasse"), value: tr("E2 · EPCglobal (Gen 2)")),
                RFIDInfoItem(label: tr("Chiphersteller"), value: maker),
                RFIDInfoItem(label: tr("Chipmodell"), value: String(format: "0x%03lX", model)),
                RFIDInfoItem(label: tr("Erweiterte TID (XTID)"), value: extended ? tr("Ja") : tr("Nein")),
            ]
            if bytes.count > 4 {
                items.append(RFIDInfoItem(label: tr("Seriendaten"), value: RFIDHex.grouped(RFIDHex.hex(Array(bytes[4...])))))
            }
            return RFIDDecodedInfo(title: maker, items: items)
        case 0xE0:
            var items = [
                RFIDInfoItem(label: tr("Klasse"), value: tr("E0 · ISO/IEC 7816-6")),
                RFIDInfoItem(label: tr("Herstellercode"), value: String(format: "0x%02X", bytes[1])),
            ]
            items.append(RFIDInfoItem(label: tr("Seriendaten"), value: RFIDHex.grouped(RFIDHex.hex(Array(bytes[2...])))))
            return RFIDDecodedInfo(title: tr("ISO-Kennung"), items: items)
        default:
            return nil
        }
    }
}

// MARK: - Kalibrierung (^HR)

/// Eine Messposition aus der Kalibriertabelle.
struct RFIDCalibrationSample: Hashable, Identifiable {
    /// Position wie vom Drucker gemeldet (z. B. `F12`, `B4`).
    let position: String
    /// Versatz in mm (rückwärts negativ).
    let offset: Int
    /// An dieser Position gelesene Tag-Kennung.
    let tagData: String?
    var id: Int { offset }
    var isHit: Bool { tagData != nil }
}

/// Ausgewertete Antwort von `^HR`.
struct RFIDCalibrationResult: Hashable {
    let text: String
    let lines: [String]
    let samples: [RFIDCalibrationSample]
    let isComplete: Bool
    /// Längster zusammenhängender Bereich mit Tag-Antwort (Versätze in mm).
    let window: ClosedRange<Int>?
    /// Mitte des Lesefensters als Positionsangabe.
    let recommendedPosition: String?

    static func containsEnd(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "end"
        }
    }

    static func positionText(offset: Int) -> String {
        offset < 0 ? "B\(-offset)" : "F\(offset)"
    }

    /// Liest `F12`, `B4` (Groß-/Kleinschreibung egal) als Versatz in mm.
    static func offset(of token: String) -> Int? {
        let trimmed = token.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count >= 2, trimmed.count <= 4, let first = trimmed.first, first == "F" || first == "B",
              let value = Int(trimmed.dropFirst()), value >= 0 else { return nil }
        return first == "B" ? -value : value
    }

    static func parse(_ rawText: String) -> RFIDCalibrationResult {
        let lines = rawText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var byOffset: [Int: RFIDCalibrationSample] = [:]
        for line in lines {
            let tokens = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = tokens.first, let offset = offset(of: first) else { continue }
            let tag = tokens.dropFirst().map { $0.replacingOccurrences(of: " ", with: "") }
                .first { $0.count >= 8 && $0.allSatisfy(RFIDHex.isHexDigit) }
            if let existing = byOffset[offset], existing.isHit { continue }
            byOffset[offset] = RFIDCalibrationSample(position: first.uppercased(), offset: offset,
                                                     tagData: tag?.uppercased())
        }
        let samples = byOffset.values.sorted { $0.offset < $1.offset }

        // Längster zusammenhängender Lauf mit Treffern.
        var best: (start: Int, end: Int)?
        var runStart: Int?
        for (index, sample) in samples.enumerated() {
            if sample.isHit {
                if runStart == nil { runStart = index }
                let start = runStart ?? index
                if best == nil || index - start > (best?.end ?? 0) - (best?.start ?? 0) {
                    best = (start, index)
                }
            } else {
                runStart = nil
            }
        }
        var window: ClosedRange<Int>?
        var recommended: String?
        if let best {
            window = samples[best.start].offset...samples[best.end].offset
            let middle = samples[(best.start + best.end) / 2]
            recommended = positionText(offset: middle.offset)
        }
        return RFIDCalibrationResult(text: rawText, lines: lines, samples: samples,
                                     isComplete: containsEnd(rawText), window: window,
                                     recommendedPosition: recommended)
    }
}

// MARK: - Programmierposition

/// Prüfung und Erklärung der Programmierposition (`rfid.position.program`).
enum RFIDProgramPosition {
    struct Assessment: Equatable {
        let isValid: Bool
        let text: String
    }

    static func assess(_ raw: String) -> Assessment {
        let value = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !value.isEmpty else {
            return Assessment(isValid: false, text: tr("Bitte eine Position angeben."))
        }
        if let offset = RFIDCalibrationResult.offset(of: value) {
            if offset < 0 {
                guard -offset <= 30 else {
                    return Assessment(isValid: false, text: tr("Rückwärts sind höchstens 30 mm möglich (B0 … B30)."))
                }
                return Assessment(isValid: true,
                                  text: tr("Rückwärts %d mm: Der Drucker zieht das Etikett vor dem Kodieren um %d mm zurück. Dieser Bereich darf nicht bedruckt sein.", -offset, -offset))
            }
            if offset == 0 {
                return Assessment(isValid: true,
                                  text: tr("F0: Kodieren, sobald der Etikettenanfang die Antenne erreicht – der übliche Ausgangswert."))
            }
            return Assessment(isValid: true,
                              text: tr("Vorwärts %d mm: Der Drucker bedruckt die ersten %d mm, kodiert dann den Tag und druckt anschließend den Rest.", offset, offset))
        }
        if value.allSatisfy({ $0.asciiValue.map { (0x30...0x39).contains($0) } ?? false }), value.count <= 4 {
            return Assessment(isValid: true,
                              text: tr("Absolutwert %@ – je nach Modell in Millimetern bzw. Punktreihen ab Etikettenanfang.", value))
        }
        return Assessment(isValid: false,
                          text: tr("Unbekanntes Format. Üblich sind F0 … F999 (vorwärts) oder B0 … B30 (rückwärts)."))
    }
}

// MARK: - Statuswerte (SGD)

/// Erkennung des RFID-Moduls aus den SGD-Werten.
enum RFIDAvailability: Equatable {
    /// Kodierer meldet sich mit Firmware.
    case available
    /// Werte vorhanden, aber keine Kodierer-Firmware gemeldet (eingeschränkt prüfbar).
    case unverified
    /// RFID ist im Drucker abgeschaltet (`rfid.enable` = off).
    case disabled
    /// Keine RFID-Werte – vermutlich kein Kodierer eingebaut.
    case notDetected
}

/// RFID-Statuswerte des Druckers (alle optional – fehlende Werte werden toleriert).
struct RFIDStatusValues: Equatable {
    static let enableKey = "rfid.enable"
    static let firmwareKey = "rfid.reader_1.firmware_version"
    static let versionKey = "rfid.reader_1.version"
    static let tagTypeKey = "rfid.tag.type"
    static let positionKey = "rfid.position.program"
    static let readPowerKey = "rfid.reader_1.power.read"
    static let writePowerKey = "rfid.reader_1.power.write"
    static let errorKey = "rfid.error.response"
    static let validKey = "odometer.rfid.valid_resettable"
    static let voidKey = "odometer.rfid.void_resettable"
    static let regionKey = "rfid.region_code"
    static let readerModelKey = "rfid.reader_1.model"
    static let antennaKey = "rfid.reader_1.antenna_port"

    static let keys: [String] = [
        enableKey, firmwareKey, versionKey, tagTypeKey, positionKey, readPowerKey, writePowerKey,
        errorKey, validKey, voidKey, regionKey, readerModelKey, antennaKey,
    ]

    /// Bereinigte Rohwerte (leere Werte und „?“ entfernt).
    let raw: [String: String]

    init(values: [String: String]) {
        var cleaned: [String: String] = [:]
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !trimmed.isEmpty, trimmed != "?" else { continue }
            cleaned[key.lowercased()] = trimmed
        }
        raw = cleaned
    }

    var enabled: Bool? {
        guard let value = raw[Self.enableKey]?.lowercased() else { return nil }
        if ["on", "1", "yes", "true", "enabled"].contains(value) { return true }
        if ["off", "0", "no", "false", "disabled"].contains(value) { return false }
        return nil
    }

    var firmware: String? { raw[Self.firmwareKey] ?? raw[Self.versionKey] }
    var tagType: String? { raw[Self.tagTypeKey] }
    var programPosition: String? { raw[Self.positionKey] }
    var readPower: Int? { Self.integer(raw[Self.readPowerKey]) }
    var writePower: Int? { Self.integer(raw[Self.writePowerKey]) }
    var errorResponse: String? { raw[Self.errorKey] }
    var validCount: Int? { Self.counter(raw[Self.validKey]) }
    var voidCount: Int? { Self.counter(raw[Self.voidKey]) }
    var region: String? { raw[Self.regionKey] }
    var readerModel: String? { raw[Self.readerModelKey] }
    var antenna: String? { raw[Self.antennaKey] }

    /// Anteil gültiger Etiketten an allen kodierten (nil ohne Zählerstände).
    var successRate: Double? {
        guard let valid = validCount, let void = voidCount, valid + void > 0 else { return nil }
        return Double(valid) / Double(valid + void)
    }

    var availability: RFIDAvailability {
        if raw.isEmpty { return .notDetected }
        if let error = errorResponse?.uppercased(),
           ["NOT INSTALLED", "NOT PRESENT", "NO READER", "NOT DETECTED", "NO RFID"].contains(where: { error.contains($0) }) {
            return .notDetected
        }
        if enabled == false { return .disabled }
        if firmware != nil { return .available }
        let anyCoreValue = tagType != nil || programPosition != nil || readPower != nil || writePower != nil
        return anyCoreValue ? .unverified : .notDetected
    }

    static func integer(_ text: String?) -> Int? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let value = Int(normalized) { return value }
        if let value = Double(normalized), value.isFinite { return Int(value.rounded()) }
        return nil
    }

    static func counter(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.filter { $0.asciiValue.map { (0x30...0x39).contains($0) } ?? false }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Lesbarer Name des Tag-Typs.
    static func tagTypeName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "gen2", "gen 2", "gen_2", "8", "epc class 1 gen 2", "epc_class1_gen2":
            return tr("EPC Class 1 Gen 2 (ISO 18000-63)")
        case "none", "0":
            return tr("Kein Tag-Typ")
        default:
            return raw
        }
    }
}

// MARK: - SGD-Einstellungen (Erweitert)

/// Eine RFID-bezogene SGD-Variable für die Tabelle „Alle RFID-Einstellungen“.
struct RFIDSettingRow: Identifiable, Hashable {
    let name: String
    var value: String
    let type: String?
    let range: String?
    let isWritable: Bool
    let choices: [String]
    let numericRange: ClosedRange<Double>?
    var id: String { name }

    init(name: String, setting: SGDSetting) {
        self.name = name
        self.value = setting.value
        self.type = setting.type
        self.range = setting.range
        self.isWritable = setting.isWritable
        self.choices = setting.choices
        self.numericRange = setting.numericRange
    }

    static func isRFIDKey(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("rfid.") || lower.hasPrefix("odometer.rfid")
    }

    /// `true`, wenn der Bereich Zahlenwerte (und nicht etwa eine Textlänge) beschreibt.
    var isNumeric: Bool {
        let kind = (type ?? "").lowercased()
        if kind.contains("int") || kind.contains("double") || kind.contains("float") || kind.contains("decimal") {
            return true
        }
        return kind.isEmpty && Double(value.replacingOccurrences(of: ",", with: ".")) != nil
    }

    /// Fehlermeldung für einen ungültigen neuen Wert (nil = gültig).
    func validate(_ newValue: String) -> String? {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("\"") {
            return tr("Anführungszeichen sind in SGD-Werten nicht erlaubt.")
        }
        if !choices.isEmpty {
            return choices.contains(trimmed) ? nil : tr("Bitte einen der erlaubten Werte wählen.")
        }
        if let range = numericRange, isNumeric {
            guard let number = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
                return tr("Bitte eine Zahl eingeben.")
            }
            if !range.contains(number) {
                return tr("Erlaubt sind Werte von %@ bis %@.",
                          range.lowerBound.formatted(.number.precision(.fractionLength(0...3))),
                          range.upperBound.formatted(.number.precision(.fractionLength(0...3))))
            }
        }
        return nil
    }
}

// MARK: - Kodieren

/// Optionen für den aufgedruckten Teil des RFID-Etiketts.
struct RFIDPrintOptions: Hashable {
    var enabled = false
    var humanReadable = true
    var barcode = true
    /// Eigener Text; Platzhalter `{EPC}` und `{NR}`.
    var customText = ""
}

/// Einstellungen eines Kodierauftrags.
struct RFIDWriteOptions: Hashable {
    /// EPC-Eingabe (Leerzeichen/Trenner erlaubt).
    var startHex = ""
    var autoIncrement = true
    var step = 1
    var count = 1
    /// PC-Wort mitschreiben; `nil` = automatisch (nur wenn die Länge von 96 Bit abweicht).
    var writePCWordOverride: Bool?
    /// Wiederholungen je Block (`^RR`, 0 = Druckerstandard).
    var retries = 0
    /// Nach dem Schreiben zurücklesen und vergleichen.
    var verify = true
    var print = RFIDPrintOptions()

    var normalizedHex: String { RFIDHex.sanitize(startHex) }
    var issue: RFIDHex.Issue? { RFIDHex.validate(normalizedHex) }
    var byteCount: Int { normalizedHex.count / 2 }

    func writesPCWord(byteCount: Int) -> Bool {
        writePCWordOverride ?? (byteCount != 12)
    }
}

/// Druckgeometrie für den aufgedruckten Teil.
struct RFIDLabelGeometry: Hashable {
    var widthDots: Int
    var heightDots: Int
    var dotsPerMM: Int
}

/// Fehler bei der Planung eines Kodierauftrags.
enum RFIDPlanError: Error, Equatable {
    case invalid(RFIDHex.Issue)
    case overflow(index: Int)

    var message: String {
        switch self {
        case .invalid(let issue): return issue.message
        case .overflow(let index):
            return tr("Beim Hochzählen läuft der EPC bei Tag %d über. Bitte Startwert, Schrittweite oder Anzahl verringern.", index)
        }
    }
}

/// Plant die EPC-Werte eines Kodierauftrags und baut die ZPL-Formate.
enum RFIDEncoder {
    static let maxCount = 9_999

    static func plan(_ options: RFIDWriteOptions) -> Result<[String], RFIDPlanError> {
        let base = options.normalizedHex
        if let issue = RFIDHex.validate(base) { return .failure(.invalid(issue)) }
        let count = min(max(1, options.count), maxCount)
        let step = UInt64(max(1, options.step))
        var values: [String] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            if options.autoIncrement {
                guard let value = RFIDHex.increment(base, by: UInt64(index) * step) else {
                    return .failure(.overflow(index: index + 1))
                }
                values.append(value)
            } else {
                values.append(base)
            }
        }
        return .success(values)
    }

    /// Ersetzt `{EPC}` und `{NR}` im eigenen Text.
    static func resolve(_ template: String, epc: String, number: Int) -> String {
        template
            .replacingOccurrences(of: "{EPC}", with: epc)
            .replacingOccurrences(of: "{epc}", with: epc)
            .replacingOccurrences(of: "{NR}", with: String(number))
            .replacingOccurrences(of: "{nr}", with: String(number))
    }

    static func estimatedLines(_ text: String, height: Int, width: Int) -> Int {
        let characterWidth = max(1.0, Double(height) * 0.62)
        let perLine = max(1, Int(Double(width) / characterWidth))
        return text.count > perLine ? 2 : 1
    }

    /// Druckbefehle (Text, Klartext-EPC, Code 128) für ein Etikett.
    static func printCommands(epc: String, number: Int, options: RFIDPrintOptions,
                              geometry: RFIDLabelGeometry) -> [ZPLCommand] {
        let dpmm = max(1, geometry.dotsPerMM)
        let margin = 3 * dpmm
        let usableWidth = max(geometry.widthDots - 2 * margin, 8 * dpmm)
        var y = margin
        var commands: [ZPLCommand] = [ZPL.changeEncoding(utf8: true)]

        let custom = resolve(options.customText, epc: epc, number: number)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let height = 5 * dpmm
            commands += ZPL.blockText(custom, x: margin, y: y, width: usableWidth, height: height, maxLines: 2)
            y += height * estimatedLines(custom, height: height, width: usableWidth) + 2 * dpmm
        }
        if options.humanReadable {
            let height = Int((3.2 * Double(dpmm)).rounded())
            let text = "EPC " + RFIDHex.grouped(epc)
            commands += ZPL.blockText(text, x: margin, y: y, width: usableWidth, height: height, maxLines: 2)
            y += height * estimatedLines(text, height: height, width: usableWidth) + 2 * dpmm
        }
        if options.barcode {
            let interpretation = !options.humanReadable
            let reserve = interpretation ? 5 * dpmm : dpmm
            let available = geometry.heightDots - margin - y - reserve
            let barHeight = min(12 * dpmm, available)
            if barHeight >= 4 * dpmm {
                let modules = (epc.count + 3) * 11 + 2
                let moduleWidth = max(1, min(3, usableWidth / max(1, modules)))
                commands.append(ZPL.barcodeDefaults(moduleWidth: moduleWidth, ratio: 3.0, height: barHeight))
                commands.append(ZPL.fieldOrigin(x: margin, y: y))
                commands.append(ZPL.code128(height: barHeight, printInterpretation: interpretation, above: false,
                                            checkDigit: false, mode: .automatic))
                commands += ZPL.fieldData(epc)
                commands.append(ZPL.fieldSeparator())
            }
        }
        return commands
    }

    /// Vollständiges Kodierformat für einen Tag. `reply` nummeriert den Kopf der Prüfantwort
    /// (``RFIDCommand/verifyHeader(number:)``, Standard: `number`).
    static func encodeFormat(epc: String, number: Int, options: RFIDWriteOptions,
                             geometry: RFIDLabelGeometry, reply: Int? = nil) -> String {
        let byteCount = epc.count / 2
        var out = "^XA\n" + RFIDCommand.tagTypeGen2 + "\n"
        if options.retries > 0 {
            out += "^RR\(min(options.retries, 10))\n"
        }
        if options.writesPCWord(byteCount: byteCount) {
            out += RFIDCommand.rf(operation: "W", startWord: 1, byteCount: 2, bank: .epc)
                + "^FD" + RFIDHex.pcWord(forByteCount: byteCount) + "^FS\n"
        }
        out += RFIDCommand.rf(operation: "W", startWord: 2, byteCount: byteCount, bank: .epc) + "^FD" + epc + "^FS\n"
        if options.verify {
            out += RFIDCommand.readField(bank: .epc, startWord: 2, byteCount: byteCount, field: 1,
                                         header: RFIDCommand.verifyHeader(number: reply ?? number)) + "\n"
        }
        if options.print.enabled {
            out += ZPL.render(printCommands(epc: epc, number: number, options: options.print, geometry: geometry))
        }
        out += "^XZ\n"
        return out
    }

    /// Nur der aufgedruckte Teil (für die Vorschau – ohne RFID-Befehle).
    static func previewFormat(epc: String, number: Int, options: RFIDPrintOptions,
                              geometry: RFIDLabelGeometry) -> String {
        "^XA\n" + ZPL.render(printCommands(epc: epc, number: number, options: options, geometry: geometry)) + "^XZ\n"
    }
}

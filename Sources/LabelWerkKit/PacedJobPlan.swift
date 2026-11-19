import Foundation
import LabelWerkCore

/// Ein ZPL-Auftrag, zerlegt für den Versand Etikett für Etikett (``PacedJobSender``).
///
/// * ``prologue``: alles vor dem ersten Format (`~JA`, Startbefehle, `~SD`, `~TA`, `~JS`, `~JC`,
///   SGD-Zeile …) – wird einmal vorab gesendet.
/// * ``segments``: je ein **druckendes** Format (`^XA … ^XZ`) samt allem, was seit dem vorigen
///   Segment davor steht – Zeilenenden, Downloads (`~DG`, `~DY`) und nicht druckende Formate wie
///   `^XA^MF…^XZ` oder `^XA^ST…^XZ` vor dem Etikett. So wartet der Sender nur nach Etiketten.
/// * ``epilogue``: Rest nach dem letzten druckenden Format (Endbefehle, abschließende nicht
///   druckende Formate, ein Format ohne `^XZ`).
///
/// Formatpräfix, Steuerpräfix und Trennzeichen („Intern“, `lwControlChars`) werden übergeben oder
/// erkannt (``detectCharacters(in:)``). Binärdaten von `^GFB`/`^GFC` und `~DY` (Format `B`/`C`)
/// werden exakt übersprungen, damit zufällige Bytes wie `^XZ` darin kein Format beenden.
///
/// Ein Format gilt als druckend, wenn es ein Feld oder eine Grafik enthält (`^FD`, `^FV`, `^GF`,
/// `^GB`, `^GC`, `^GD`, `^GE`, `^GS`, `^XG`, `^IM`, `^XF`) und kein Format speichert (`^DF`). Die
/// Menge stammt aus `^PQ` (ohne Angabe 1).
public struct PacedJobPlan: Sendable, Hashable {

    /// Ein druckendes Format mit allen Daten seit dem vorigen Segment.
    public struct Segment: Sendable, Hashable {
        /// Zu sendende Bytes.
        public var data: Data
        /// Exemplare dieses Formats (`^PQ`, mindestens 1).
        public var quantity: Int
        /// Byte-Bereich der `^PQ`-Menge in ``data`` (`nil`, wenn das Format kein `^PQ` hat).
        public var quantityRange: Range<Int>?

        public init(data: Data, quantity: Int, quantityRange: Range<Int>? = nil) {
            self.data = data
            self.quantity = max(1, quantity)
            self.quantityRange = quantityRange
        }

        /// Dasselbe Segment mit einer anderen Menge (z. B. nur noch die restlichen Exemplare nach
        /// einem Verbindungsabbruch). Ohne `^PQ` und mit `quantity == 1` unverändert.
        public func withQuantity(_ quantity: Int) -> Segment {
            let quantity = max(1, quantity)
            guard quantity != self.quantity else { return self }
            guard let range = quantityRange else { return self }
            var bytes = [UInt8](data)
            bytes.replaceSubrange(range, with: Array(String(quantity).utf8))
            let newRange = range.lowerBound..<(range.lowerBound + String(quantity).utf8.count)
            return Segment(data: Data(bytes), quantity: quantity, quantityRange: newRange)
        }
    }

    public var prologue: Data
    public var segments: [Segment]
    public var epilogue: Data
    /// Verwendete Steuerzeichen (übergeben oder erkannt).
    public var characters: ControlCharacters

    /// Gesamtzahl der Etiketten (Summe der Mengen aller Segmente).
    public var totalLabels: Int { segments.reduce(0) { $0 + $1.quantity } }

    public init(prologue: Data, segments: [Segment], epilogue: Data, characters: ControlCharacters) {
        self.prologue = prologue
        self.segments = segments
        self.epilogue = epilogue
        self.characters = characters
    }

    // MARK: - Zerlegen

    /// Zerlegt einen ZPL-Auftrag. Ohne `characters` werden die Steuerzeichen erkannt.
    /// Die Teile ergeben aneinandergehängt wieder genau `data`.
    public static func split(_ data: Data, characters: ControlCharacters? = nil) -> PacedJobPlan {
        let chars = (characters ?? detectCharacters(in: data)).clamped()
        let bytes = [UInt8](data)
        let fp = chars.formatPrefix
        let cp = chars.controlPrefix
        var segments: [Segment] = []
        var prologueEnd: Int?
        var segmentStart = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == cp, let end = binaryDownloadEnd(bytes, at: index, delimiter: chars.delimiter) {
                index = end
                continue
            }
            guard byte == fp, matches(bytes, index + 1, "XA") else {
                index += 1
                continue
            }
            if prologueEnd == nil {
                prologueEnd = index
                segmentStart = index
            }
            guard let format = scanFormat(bytes, from: index, characters: chars) else {
                // Format ohne ^XZ: bleibt im Rest.
                break
            }
            index = format.end
            if format.prints {
                let range = format.quantityRange.map { $0.lowerBound - segmentStart..<$0.upperBound - segmentStart }
                segments.append(Segment(data: Data(bytes[segmentStart..<format.end]), quantity: format.quantity,
                                        quantityRange: range))
                segmentStart = format.end
            }
        }
        let headEnd = prologueEnd ?? bytes.count
        return PacedJobPlan(prologue: Data(bytes[0..<headEnd]), segments: segments,
                            epilogue: Data(bytes[max(headEnd, segmentStart)...]), characters: chars)
    }

    /// Erkennt die Steuerzeichen eines Auftrags: Formatpräfix `^`, wenn `^XA` vorkommt, sonst das
    /// Zeichen vor dem ersten `XA`, das auch vor einem späteren `XZ` steht. Steuerpräfix aus einer
    /// führenden `<c>JA`-Zeile bzw. dem Zeichen vor `HS`/`JA`/`SD`/`TA`/`JS`/`JC`/`DG`/`DY`, sonst `~`.
    /// Trennzeichen: `,` (aus dem Auftrag nicht sicher erkennbar).
    public static func detectCharacters(in data: Data) -> ControlCharacters {
        let bytes = [UInt8](data)
        var format: UInt8 = 0x5E
        if !contains(bytes, prefix: 0x5E, "XA") {
            for index in 0..<max(0, bytes.count - 2) where isPrefixCandidate(bytes[index]) && matches(bytes, index + 1, "XA") {
                if contains(bytes, prefix: bytes[index], "XZ", from: index + 3) {
                    format = bytes[index]
                    break
                }
            }
        }
        var control: UInt8 = 0x7E
        if !bytes.isEmpty, bytes[0] != format, isPrefixCandidate(bytes[0]), matches(bytes, 1, "JA") {
            control = bytes[0]
        } else if !contains(bytes, prefix: 0x7E, nil) {
            let names = ["HS", "JA", "SD", "TA", "JS", "JC", "DG", "DY"]
            outer: for index in 0..<max(0, bytes.count - 2) where bytes[index] != format && isPrefixCandidate(bytes[index]) {
                for name in names where matches(bytes, index + 1, name) {
                    // Nur am Zeilenanfang (Kopf des Auftrags), damit Text in Feldern nicht zählt.
                    if index == 0 || bytes[index - 1] == 0x0A || bytes[index - 1] == 0x0D {
                        control = bytes[index]
                        break outer
                    }
                }
            }
        }
        return ControlCharacters(formatPrefix: format, controlPrefix: control, delimiter: 0x2C)
    }

    // MARK: - Hilfen

    private struct ScannedFormat {
        var end: Int
        var prints: Bool
        var quantity: Int
        var quantityRange: Range<Int>?
    }

    /// Befehle, die ein Etikett drucken lassen.
    private static let printingCommands: Set<String> = ["FD", "FV", "GF", "GB", "GC", "GD", "GE", "GS", "XG", "IM", "XF"]

    /// Durchsucht ein Format ab `start` (`^XA`) bis einschließlich `^XZ`.
    private static func scanFormat(_ bytes: [UInt8], from start: Int, characters: ControlCharacters) -> ScannedFormat? {
        let fp = characters.formatPrefix
        var index = start + 3
        var prints = false
        var storesFormat = false
        var quantity = 1
        var quantityRange: Range<Int>?
        var inFieldData = false
        while index < bytes.count {
            guard bytes[index] == fp, index + 2 < bytes.count else {
                index += 1
                continue
            }
            let name = String(decoding: [upper(bytes[index + 1]), upper(bytes[index + 2])], as: UTF8.self)
            if name == "XZ" {
                return ScannedFormat(end: index + 3, prints: prints && !storesFormat, quantity: quantity,
                                     quantityRange: quantityRange)
            }
            if inFieldData && name != "FS" {
                // Innerhalb von ^FD … ^FS beendet nur ^FS (bzw. ^XZ) das Feld – andere Präfixe sind
                // dort nur bei ^FH-Kodierung üblich und zählen nicht als Befehl.
                index += 1
                continue
            }
            inFieldData = false
            if printingCommands.contains(name) { prints = true }
            switch name {
            case "DF":
                storesFormat = true
            case "FD", "FV":
                inFieldData = true
            case "PQ":
                var cursor = index + 3
                while cursor < bytes.count, bytes[cursor] == 0x20 { cursor += 1 }
                let digitsStart = cursor
                while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) { cursor += 1 }
                if cursor > digitsStart, let value = Int(String(decoding: bytes[digitsStart..<cursor], as: UTF8.self)) {
                    quantity = max(1, min(value, 99_999_999))
                    quantityRange = digitsStart..<cursor
                }
            case "GF":
                if let end = binaryGraphicEnd(bytes, at: index, delimiter: characters.delimiter, prefixes: [fp, characters.controlPrefix]) {
                    index = end
                    continue
                }
            default:
                break
            }
            index += 3
        }
        return nil
    }

    /// `^GF{a},{b},{c},{d},{daten}` mit Format `B`/`C`: Ende der Binärdaten (`b` Bytes nach dem
    /// vierten Trennzeichen), sonst `nil`.
    private static func binaryGraphicEnd(_ bytes: [UInt8], at start: Int, delimiter: UInt8, prefixes: [UInt8]) -> Int? {
        guard let header = fields(bytes, from: start + 3, count: 4, delimiter: delimiter, stopAt: prefixes) else { return nil }
        let format = header.fields[0].uppercased()
        guard format == "B" || format == "C", let total = Int(header.fields[1]), total >= 0 else { return nil }
        return min(bytes.count, header.dataStart + total)
    }

    /// `~DY{pfad},{format},{endung},{gesamt},{bytes je zeile},{daten}` mit Format `B`/`C`: Ende der
    /// Binärdaten, sonst `nil`.
    private static func binaryDownloadEnd(_ bytes: [UInt8], at start: Int, delimiter: UInt8) -> Int? {
        guard matches(bytes, start + 1, "DY"),
              let header = fields(bytes, from: start + 3, count: 5, delimiter: delimiter, stopAt: []) else { return nil }
        let format = header.fields[1].uppercased()
        guard format == "B" || format == "C", let total = Int(header.fields[3]), total >= 0 else { return nil }
        return min(bytes.count, header.dataStart + total)
    }

    /// Liest `count` Felder bis zum `count`-ten Trennzeichen (höchstens 128 Bytes Kopf).
    private static func fields(_ bytes: [UInt8], from start: Int, count: Int, delimiter: UInt8,
                               stopAt: [UInt8]) -> (fields: [String], dataStart: Int)? {
        var result: [String] = []
        var current: [UInt8] = []
        var index = start
        while index < bytes.count, index - start < 128 {
            let byte = bytes[index]
            if stopAt.contains(byte) { return nil }
            if byte == delimiter {
                result.append(String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll()
                if result.count == count { return (result, index + 1) }
            } else {
                current.append(byte)
            }
            index += 1
        }
        return nil
    }

    private static func upper(_ byte: UInt8) -> UInt8 {
        (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
    }

    private static func matches(_ bytes: [UInt8], _ index: Int, _ name: String) -> Bool {
        let name = Array(name.utf8)
        guard index >= 0, index + name.count <= bytes.count else { return false }
        for offset in 0..<name.count where upper(bytes[index + offset]) != name[offset] { return false }
        return true
    }

    /// Kommt `prefix` + `name` vor (bei `name == nil` nur das Präfix)?
    private static func contains(_ bytes: [UInt8], prefix: UInt8, _ name: String?, from start: Int = 0) -> Bool {
        guard start < bytes.count else { return false }
        for index in start..<bytes.count where bytes[index] == prefix {
            guard let name else { return true }
            if matches(bytes, index + 1, name) { return true }
        }
        return false
    }

    /// Mögliche Präfixzeichen: druckbares ASCII ohne Buchstaben, Ziffern und Leerzeichen.
    private static func isPrefixCandidate(_ byte: UInt8) -> Bool {
        ControlCharacters.validRange.contains(byte) && !(0x30...0x39).contains(byte)
            && !(0x41...0x5A).contains(byte) && !(0x61...0x7A).contains(byte)
    }
}

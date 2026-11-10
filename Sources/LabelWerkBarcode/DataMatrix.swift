import Foundation

/// Form eines Data-Matrix-Symbols.
public enum DataMatrixShape: String, Sendable, CaseIterable, Codable {
    /// Nur quadratische Symbole 10×10 … 144×144 (Standard, wie ZPL `^BX`).
    case square
    /// Nur rechteckige Symbole 8×18 … 16×48.
    case rectangle
    /// Das kleinste passende Symbol beliebiger Form.
    case any
}

/// Erweiterte Einstellungen für Data Matrix (siehe `BarcodeEncoder.dataMatrix(_:options:)`).
public struct DataMatrixOptions: Hashable, Sendable {
    /// Symbolform, falls keine feste Größe angegeben ist.
    public var shape: DataMatrixShape
    /// Feste Zeilenzahl des Symbols (z. B. 24), 0 = automatisch.
    public var rows: Int
    /// Feste Spaltenzahl des Symbols (z. B. 24), 0 = automatisch.
    ///
    /// Ist `rows` und/oder `columns` gesetzt, wird `shape` ignoriert und das kleinste Symbol
    /// mit genau diesen Abmessungen gewählt (wie ZPL `^BX` mit Spalten/Zeilen-Parametern).
    public var columns: Int

    public init(shape: DataMatrixShape = .square, rows: Int = 0, columns: Int = 0) {
        self.shape = shape
        self.rows = rows
        self.columns = columns
    }
}

/// Data Matrix ECC200 (ISO/IEC 16022).
///
/// * Kodierung: ASCII (Ziffernpaare in einem Codewort, erweitertes ASCII per Upper Shift), C40,
///   Text, X12, EDIFACT und Base 256 – die Aufteilung wird per dynamischer Programmierung
///   codewortminimal bestimmt (inklusive der Sonderregeln am Symbolende).
/// * Fehlerkorrektur: Reed-Solomon über GF(256) mit dem Polynom 0x12D, Blöcke verschachtelt
///   (144×144: 8 Blöcke à 156 und 2 à 155 Datencodewörter).
/// * Platzierung nach dem Standardalgorithmus (Anhang F) inklusive Mehrbereichssymbolen.
/// * Text wird als UTF-8 kodiert (ohne ECI); für ISO 8859-1 oder Binärdaten steht
///   `BarcodeEncoder.dataMatrix(bytes:options:)` zur Verfügung.
enum DataMatrix {

    // MARK: Symbolgrößen (ISO/IEC 16022, Tabelle 7)

    struct SymbolSize: Equatable, Sendable {
        /// Symbolhöhe und -breite in Modulen (inklusive Suchmuster).
        let rows: Int
        let columns: Int
        /// Größe eines Datenbereichs.
        let regionRows: Int
        let regionColumns: Int
        /// Anzahl der Datenbereiche vertikal und horizontal.
        let verticalRegions: Int
        let horizontalRegions: Int
        /// Datenkapazität und Fehlerkorrektur-Codewörter (gesamt).
        let dataCodewords: Int
        let errorCodewords: Int
        /// Anzahl der verschachtelten Reed-Solomon-Blöcke.
        let blocks: Int

        var isSquare: Bool { rows == columns }
        /// Größe der Abbildungsmatrix (alle Datenbereiche ohne Suchmuster).
        var mappingRows: Int { regionRows * verticalRegions }
        var mappingColumns: Int { regionColumns * horizontalRegions }

        /// Datencodewörter des Blocks `block` (0-basiert); nur 144×144 hat ungleiche Blöcke.
        func dataCodewords(inBlock block: Int) -> Int {
            if rows == 144 && columns == 144 { return block < 8 ? 156 : 155 }
            return dataCodewords / blocks
        }

        var errorCodewordsPerBlock: Int { errorCodewords / blocks }
    }

    static let sizes: [SymbolSize] = [
        // quadratisch
        SymbolSize(rows: 10, columns: 10, regionRows: 8, regionColumns: 8, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 3, errorCodewords: 5, blocks: 1),
        SymbolSize(rows: 12, columns: 12, regionRows: 10, regionColumns: 10, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 5, errorCodewords: 7, blocks: 1),
        SymbolSize(rows: 14, columns: 14, regionRows: 12, regionColumns: 12, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 8, errorCodewords: 10, blocks: 1),
        SymbolSize(rows: 16, columns: 16, regionRows: 14, regionColumns: 14, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 12, errorCodewords: 12, blocks: 1),
        SymbolSize(rows: 18, columns: 18, regionRows: 16, regionColumns: 16, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 18, errorCodewords: 14, blocks: 1),
        SymbolSize(rows: 20, columns: 20, regionRows: 18, regionColumns: 18, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 22, errorCodewords: 18, blocks: 1),
        SymbolSize(rows: 22, columns: 22, regionRows: 20, regionColumns: 20, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 30, errorCodewords: 20, blocks: 1),
        SymbolSize(rows: 24, columns: 24, regionRows: 22, regionColumns: 22, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 36, errorCodewords: 24, blocks: 1),
        SymbolSize(rows: 26, columns: 26, regionRows: 24, regionColumns: 24, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 44, errorCodewords: 28, blocks: 1),
        SymbolSize(rows: 32, columns: 32, regionRows: 14, regionColumns: 14, verticalRegions: 2, horizontalRegions: 2, dataCodewords: 62, errorCodewords: 36, blocks: 1),
        SymbolSize(rows: 36, columns: 36, regionRows: 16, regionColumns: 16, verticalRegions: 2, horizontalRegions: 2, dataCodewords: 86, errorCodewords: 42, blocks: 1),
        SymbolSize(rows: 40, columns: 40, regionRows: 18, regionColumns: 18, verticalRegions: 2, horizontalRegions: 2, dataCodewords: 114, errorCodewords: 48, blocks: 1),
        SymbolSize(rows: 44, columns: 44, regionRows: 20, regionColumns: 20, verticalRegions: 2, horizontalRegions: 2, dataCodewords: 144, errorCodewords: 56, blocks: 1),
        SymbolSize(rows: 48, columns: 48, regionRows: 22, regionColumns: 22, verticalRegions: 2, horizontalRegions: 2, dataCodewords: 174, errorCodewords: 68, blocks: 1),
        SymbolSize(rows: 52, columns: 52, regionRows: 24, regionColumns: 24, verticalRegions: 2, horizontalRegions: 2, dataCodewords: 204, errorCodewords: 84, blocks: 2),
        SymbolSize(rows: 64, columns: 64, regionRows: 14, regionColumns: 14, verticalRegions: 4, horizontalRegions: 4, dataCodewords: 280, errorCodewords: 112, blocks: 2),
        SymbolSize(rows: 72, columns: 72, regionRows: 16, regionColumns: 16, verticalRegions: 4, horizontalRegions: 4, dataCodewords: 368, errorCodewords: 144, blocks: 4),
        SymbolSize(rows: 80, columns: 80, regionRows: 18, regionColumns: 18, verticalRegions: 4, horizontalRegions: 4, dataCodewords: 456, errorCodewords: 192, blocks: 4),
        SymbolSize(rows: 88, columns: 88, regionRows: 20, regionColumns: 20, verticalRegions: 4, horizontalRegions: 4, dataCodewords: 576, errorCodewords: 224, blocks: 4),
        SymbolSize(rows: 96, columns: 96, regionRows: 22, regionColumns: 22, verticalRegions: 4, horizontalRegions: 4, dataCodewords: 696, errorCodewords: 272, blocks: 4),
        SymbolSize(rows: 104, columns: 104, regionRows: 24, regionColumns: 24, verticalRegions: 4, horizontalRegions: 4, dataCodewords: 816, errorCodewords: 336, blocks: 6),
        SymbolSize(rows: 120, columns: 120, regionRows: 18, regionColumns: 18, verticalRegions: 6, horizontalRegions: 6, dataCodewords: 1050, errorCodewords: 408, blocks: 6),
        SymbolSize(rows: 132, columns: 132, regionRows: 20, regionColumns: 20, verticalRegions: 6, horizontalRegions: 6, dataCodewords: 1304, errorCodewords: 496, blocks: 8),
        SymbolSize(rows: 144, columns: 144, regionRows: 22, regionColumns: 22, verticalRegions: 6, horizontalRegions: 6, dataCodewords: 1558, errorCodewords: 620, blocks: 10),
        // rechteckig
        SymbolSize(rows: 8, columns: 18, regionRows: 6, regionColumns: 16, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 5, errorCodewords: 7, blocks: 1),
        SymbolSize(rows: 8, columns: 32, regionRows: 6, regionColumns: 14, verticalRegions: 1, horizontalRegions: 2, dataCodewords: 10, errorCodewords: 11, blocks: 1),
        SymbolSize(rows: 12, columns: 26, regionRows: 10, regionColumns: 24, verticalRegions: 1, horizontalRegions: 1, dataCodewords: 16, errorCodewords: 14, blocks: 1),
        SymbolSize(rows: 12, columns: 36, regionRows: 10, regionColumns: 16, verticalRegions: 1, horizontalRegions: 2, dataCodewords: 22, errorCodewords: 18, blocks: 1),
        SymbolSize(rows: 16, columns: 36, regionRows: 14, regionColumns: 16, verticalRegions: 1, horizontalRegions: 2, dataCodewords: 32, errorCodewords: 24, blocks: 1),
        SymbolSize(rows: 16, columns: 48, regionRows: 14, regionColumns: 22, verticalRegions: 1, horizontalRegions: 2, dataCodewords: 49, errorCodewords: 28, blocks: 1),
    ]

    /// Kleinstes Symbol der gewünschten Form mit mindestens `codewords` Datencodewörtern.
    static func smallestSize(for codewords: Int, shape: DataMatrixShape) -> SymbolSize? {
        sizes
            .filter { size in
                switch shape {
                case .square: return size.isSquare
                case .rectangle: return !size.isSquare
                case .any: return true
                }
            }
            .filter { $0.dataCodewords >= codewords }
            .min { ($0.dataCodewords, $0.rows * $0.columns) < ($1.dataCodewords, $1.rows * $1.columns) }
    }

    // MARK: Datenkodierung

    static let latchC40: UInt8 = 230
    static let latchBase256: UInt8 = 231
    static let upperShift: UInt8 = 235
    static let latchX12: UInt8 = 238
    static let latchText: UInt8 = 239
    static let latchEDIFACT: UInt8 = 240
    static let unlatch: UInt8 = 254
    static let padCodeword: UInt8 = 129
    /// EDIFACT-Wert für den Rücksprung nach ASCII.
    static let edifactUnlatch = 31

    /// Datenkapazität des größten Symbols (144×144).
    static let maximumDataCodewords = 1558

    /// Längste Base-256-Folge, die in das größte Symbol passt (Latch + 2 Byte Längenfeld + Daten = 1558).
    static let maximumBase256Run = 1555

    /// Kosten (Codewörter) einer Base-256-Folge der Länge `n` inklusive Latch und Längenfeld.
    static func base256Cost(_ n: Int) -> Int { 1 + (n <= 249 ? 1 : 2) + n }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// C40- bzw. Text-Werte eines Bytes (1–4 Werte inklusive Shift-Zeichen und Upper Shift).
    ///
    /// Grundzeichensatz: Leerzeichen = 3, Ziffern = 4…13, Großbuchstaben (C40) bzw.
    /// Kleinbuchstaben (Text) = 14…39. Shift 1 (0) = Steuerzeichen, Shift 2 (1) = Satzzeichen
    /// bzw. Upper Shift (30), Shift 3 (2) = jeweils andere Buchstabenart und `` ` { | } ~ DEL``.
    static func c40Values(_ byte: UInt8, text: Bool) -> [Int] {
        let c = Int(byte)
        if c >= 128 { return [1, 30] + c40Values(byte - 128, text: text) }
        switch c {
        case 32: return [3]
        case 48...57: return [c - 48 + 4]
        case 65...90: return text ? [2, c - 65 + 1] : [c - 65 + 14]
        case 97...122: return text ? [c - 97 + 14] : [2, c - 97 + 1]
        case 0...31: return [0, c]
        case 33...47: return [1, c - 33]
        case 58...64: return [1, c - 58 + 15]
        case 91...95: return [1, c - 91 + 22]
        case 96: return [2, 0]
        default: return [2, c - 123 + 27]  // 123…127
        }
    }

    /// X12-Wert (CR, `*`, `>`, Leerzeichen, Ziffern, Großbuchstaben) oder `nil`.
    static func x12Value(_ byte: UInt8) -> Int? {
        switch byte {
        case 13: return 0
        case 42: return 1
        case 62: return 2
        case 32: return 3
        case 48...57: return Int(byte) - 48 + 4
        case 65...90: return Int(byte) - 65 + 14
        default: return nil
        }
    }

    /// EDIFACT-Wert (ASCII 32…94, untere 6 Bit) oder `nil`.
    static func edifactValue(_ byte: UInt8) -> Int? {
        (32...94).contains(byte) ? Int(byte & 0x3F) : nil
    }

    /// Kodierungsarten (ISO/IEC 16022, Abschnitt 5.2), die dieser Encoder verwendet.
    enum Encodation: Hashable, Sendable { case ascii, c40, text, x12, edifact, base256 }

    /// Ergebnis der Datenkodierung.
    struct EncodedData: Equatable {
        /// Codewortminimale Folge, die im ASCII-Zustand endet (Füllzeichen können folgen).
        var codewords: [UInt8]
        /// Tatsächlich verwendete Kodierungsarten (für Tests und Diagnose).
        var encodations: Set<Encodation>
        /// Endet `codewords` mit dem Unlatch (254) eines C40-/Text-/X12-Abschnitts?
        var endsWithUnlatch: Bool
        /// Codewortindex, an dem die letzte EDIFACT-Gruppe beginnt (falls vorhanden). Ab dort
        /// müssen im Symbol noch mindestens 3 Codewörter Platz haben, sonst würde ein Decoder
        /// die Gruppe gemäß Norm bereits als ASCII lesen.
        var lastEdifactGroupStart: Int?
        /// Günstigste Folge, die in C40/Text/X12 **ohne** abschließendes Unlatch endet. Zulässig
        /// nur, wenn sie das Symbol exakt füllt (impliziter Rücksprung am Symbolende), sonst `nil`.
        var withoutFinalUnlatch: [UInt8]?
    }

    /// Zustände der dynamischen Programmierung.
    private enum State {
        static let ascii = 0
        static let c40 = 1        // 1…3: Rest 0…2 Werte im laufenden Tripel
        static let text = 4       // 4…6
        static let x12 = 7        // 7…9
        static let edifact = 10   // 10…13: Rest 0…3 Werte in der laufenden Vierergruppe
        static let count = 14
    }

    private enum Step: Equatable {
        case none, latch(Encodation), unlatch, asciiPair, asciiSingle, base256, value
    }

    /// Kodiert Bytes codewortminimal mit ASCII-, C40-, Text-, X12-, EDIFACT- und Base-256-Abschnitten.
    ///
    /// Dynamische Programmierung über alle Kodierungsarten samt Teilfüllung der Wertegruppen;
    /// Kosten in Zwölftel-Codewörtern (ASCII-Codewort = 12, C40/Text/X12-Wert = 8,
    /// EDIFACT-Wert = 9). C40/Text/X12-Abschnitte enden mit vollständigen Tripeln und Unlatch
    /// (254), EDIFACT-Abschnitte mit dem Unlatch-Wert 31 und Auffüllung auf ganze Codewörter.
    static func encodeData(_ bytes: [UInt8]) throws -> EncodedData {
        let n = bytes.count
        // Mehr als 2 Zeichen je Codewort ist unmöglich (Ziffernpaare) – früh abbrechen.
        guard n <= 2 * maximumDataCodewords else { throw BarcodeError.dataTooLong }
        let infinity = Int.max / 4
        struct Back { var position: Int; var state: Int; var step: Step }
        var cost = [Int](repeating: infinity, count: (n + 1) * State.count)
        var back = [Back](repeating: Back(position: -1, state: -1, step: .none), count: (n + 1) * State.count)
        func slot(_ position: Int, _ state: Int) -> Int { position * State.count + state }
        func relax(_ fromPosition: Int, _ fromState: Int, _ toPosition: Int, _ toState: Int, _ added: Int, _ step: Step) {
            let candidate = cost[slot(fromPosition, fromState)] + added
            if candidate < cost[slot(toPosition, toState)] {
                cost[slot(toPosition, toState)] = candidate
                back[slot(toPosition, toState)] = Back(position: fromPosition, state: fromState, step: step)
            }
        }
        let c40Counts = bytes.map { c40Values($0, text: false).count }
        let textCounts = bytes.map { c40Values($0, text: true).count }
        /// Zusatzkosten des EDIFACT-Unlatch abhängig vom Gruppenrest (Unlatch-Wert + Auffüllung).
        let edifactUnlatchCost = [12, 15, 18, 9]

        cost[slot(0, State.ascii)] = 0
        for i in 0...n {
            // Unlatch (C40/Text/X12 nur nach vollständigen Tripeln, EDIFACT jederzeit) …
            for base in [State.c40, State.text, State.x12] where cost[slot(i, base)] < infinity {
                relax(i, base, i, State.ascii, 12, .unlatch)
            }
            for residue in 0..<4 where cost[slot(i, State.edifact + residue)] < infinity {
                relax(i, State.edifact + residue, i, State.ascii, edifactUnlatchCost[residue], .unlatch)
            }
            // … danach Latch, damit auch direkte Wechsel (z. B. C40 → Text) möglich sind.
            if i < n && cost[slot(i, State.ascii)] < infinity {
                relax(i, State.ascii, i, State.c40, 12, .latch(.c40))
                relax(i, State.ascii, i, State.text, 12, .latch(.text))
                relax(i, State.ascii, i, State.x12, 12, .latch(.x12))
                relax(i, State.ascii, i, State.edifact, 12, .latch(.edifact))
            }
            guard i < n else { break }
            let byte = bytes[i]

            // ASCII
            if cost[slot(i, State.ascii)] < infinity {
                if i + 1 < n && isDigit(byte) && isDigit(bytes[i + 1]) {
                    relax(i, State.ascii, i + 2, State.ascii, 12, .asciiPair)
                }
                relax(i, State.ascii, i + 1, State.ascii, byte < 128 ? 12 : 24, .asciiSingle)
                // Base 256 lohnt sich nur ab einem Byte ≥ 128.
                if byte >= 128 {
                    for j in (i + 1)...min(n, i + maximumBase256Run) {
                        relax(i, State.ascii, j, State.ascii, 12 * base256Cost(j - i), .base256)
                    }
                }
            }
            // C40 / Text / X12 (Tripel aus Werten zu je 2/3 Codewort)
            let x12 = x12Value(byte)
            for residue in 0..<3 {
                if cost[slot(i, State.c40 + residue)] < infinity {
                    relax(i, State.c40 + residue, i + 1, State.c40 + (residue + c40Counts[i]) % 3, 8 * c40Counts[i], .value)
                }
                if cost[slot(i, State.text + residue)] < infinity {
                    relax(i, State.text + residue, i + 1, State.text + (residue + textCounts[i]) % 3, 8 * textCounts[i], .value)
                }
                if x12 != nil && cost[slot(i, State.x12 + residue)] < infinity {
                    relax(i, State.x12 + residue, i + 1, State.x12 + (residue + 1) % 3, 8, .value)
                }
            }
            // EDIFACT (Vierergruppen zu je 3 Codewörtern)
            if edifactValue(byte) != nil {
                for residue in 0..<4 where cost[slot(i, State.edifact + residue)] < infinity {
                    relax(i, State.edifact + residue, i + 1, State.edifact + (residue + 1) % 4, 9, .value)
                }
            }
        }
        guard cost[slot(n, State.ascii)] < infinity else { throw BarcodeError.dataTooLong }

        // Pfad ab einem Endzustand rekonstruieren und in Codewörter übersetzen.
        func emit(endState: Int) -> (codewords: [UInt8], encodations: Set<Encodation>, endsWithUnlatch: Bool, lastEdifactGroup: Int?) {
            var path: [(from: Int, to: Int, step: Step)] = []
            var position = n
            var state = endState
            while true {
                let entry = back[slot(position, state)]
                if entry.step == .none { break }
                path.append((entry.position, position, entry.step))
                position = entry.position
                state = entry.state
            }
            path.reverse()

            var codewords: [UInt8] = []
            var encodations: Set<Encodation> = []
            var mode = Encodation.ascii
            var pending: [Int] = []
            var lastEdifactGroup: Int?
            var endsWithUnlatch = false

            func flushTriples() {
                precondition(pending.count % 3 == 0)
                var k = 0
                while k < pending.count {
                    let value = 1600 * pending[k] + 40 * pending[k + 1] + pending[k + 2] + 1
                    codewords.append(UInt8(value / 256))
                    codewords.append(UInt8(value % 256))
                    k += 3
                }
                pending.removeAll()
            }
            func flushEdifact() {
                var k = 0
                while k < pending.count {
                    let group = Array(pending[k..<min(k + 4, pending.count)])
                    lastEdifactGroup = codewords.count
                    var bits = 0
                    for slotIndex in 0..<4 { bits = bits << 6 | (slotIndex < group.count ? group[slotIndex] : 0) }
                    let groupBytes = [UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
                    codewords.append(contentsOf: groupBytes.prefix((group.count * 6 + 7) / 8))
                    k += 4
                }
                pending.removeAll()
            }

            for segment in path {
                endsWithUnlatch = false
                switch segment.step {
                case .none:
                    break
                case .latch(let target):
                    mode = target
                    encodations.insert(target)
                    switch target {
                    case .c40: codewords.append(latchC40)
                    case .text: codewords.append(latchText)
                    case .x12: codewords.append(latchX12)
                    case .edifact: codewords.append(latchEDIFACT)
                    case .ascii, .base256: break
                    }
                case .value:
                    let byte = bytes[segment.from]
                    switch mode {
                    case .c40: pending.append(contentsOf: c40Values(byte, text: false))
                    case .text: pending.append(contentsOf: c40Values(byte, text: true))
                    case .x12: pending.append(x12Value(byte)!)
                    case .edifact: pending.append(edifactValue(byte)!)
                    case .ascii, .base256: preconditionFailure("Wert außerhalb eines Wertemodus")
                    }
                case .unlatch:
                    if mode == .edifact {
                        pending.append(edifactUnlatch)
                        flushEdifact()
                    } else {
                        flushTriples()
                        codewords.append(unlatch)
                        endsWithUnlatch = true
                    }
                    mode = .ascii
                case .asciiPair:
                    encodations.insert(.ascii)
                    codewords.append(UInt8(130 + Int(bytes[segment.from] - 0x30) * 10 + Int(bytes[segment.from + 1] - 0x30)))
                case .asciiSingle:
                    encodations.insert(.ascii)
                    let byte = bytes[segment.from]
                    if byte < 128 {
                        codewords.append(byte + 1)
                    } else {
                        codewords.append(upperShift)
                        codewords.append(byte - 128 + 1)
                    }
                case .base256:
                    encodations.insert(.base256)
                    let length = segment.to - segment.from
                    codewords.append(latchBase256)
                    let field: [UInt8] = length <= 249 ? [UInt8(length)] : [UInt8(length / 250 + 249), UInt8(length % 250)]
                    for value in field + bytes[segment.from..<segment.to] {
                        codewords.append(randomize255(value, position: codewords.count + 1))
                    }
                }
            }
            flushTriples()  // Ende in C40/Text/X12 ohne Unlatch (nur vollständige Tripel)
            return (codewords, encodations, endsWithUnlatch, lastEdifactGroup)
        }

        let main = emit(endState: State.ascii)
        // Alternative: Ende in C40/Text/X12 mit vollständigem Tripel, ohne Unlatch.
        var alternative: [UInt8]?
        let ends = [State.c40, State.text, State.x12].map { (state: $0, cost: cost[slot(n, $0)]) }
        if let best = ends.min(by: { $0.cost < $1.cost }), best.cost < infinity {
            let candidate = emit(endState: best.state)
            if candidate.lastEdifactGroup == nil || candidate.lastEdifactGroup! + 3 <= candidate.codewords.count {
                alternative = candidate.codewords
            }
        }
        return EncodedData(codewords: main.codewords, encodations: main.encodations, endsWithUnlatch: main.endsWithUnlatch,
                           lastEdifactGroupStart: main.lastEdifactGroup, withoutFinalUnlatch: alternative)
    }

    /// 255-Zustands-Randomisierung für Base-256-Codewörter (`position` 1-basiert).
    static func randomize255(_ value: UInt8, position: Int) -> UInt8 {
        let pseudoRandom = (149 * position) % 255 + 1
        let temp = Int(value) + pseudoRandom
        return UInt8(temp <= 255 ? temp : temp - 256)
    }

    /// Füllt bis zur Symbolkapazität auf: erstes Füllzeichen 129, danach 253-Zustands-randomisiert.
    static func pad(_ codewords: inout [UInt8], to capacity: Int) {
        if codewords.count < capacity { codewords.append(padCodeword) }
        while codewords.count < capacity {
            let position = codewords.count + 1
            let pseudoRandom = (149 * position) % 253 + 1
            let temp = 129 + pseudoRandom
            codewords.append(UInt8(temp <= 254 ? temp : temp - 254))
        }
    }

    // MARK: Fehlerkorrektur

    /// Ergänzt die Fehlerkorrektur (verschachtelte Blöcke) zu den Datencodewörtern.
    static func addErrorCorrection(_ data: [UInt8], size: SymbolSize) -> [UInt8] {
        precondition(data.count == size.dataCodewords)
        let blockCount = size.blocks
        let eccPerBlock = size.errorCodewordsPerBlock
        let field = GaloisField256.dataMatrix
        let generator = field.generator(degree: eccPerBlock, firstRoot: 1)
        var result = data + [UInt8](repeating: 0, count: size.errorCodewords)
        for block in 0..<blockCount {
            var blockData: [UInt8] = []
            blockData.reserveCapacity(size.dataCodewords(inBlock: block))
            var i = block
            while i < data.count {
                blockData.append(data[i])
                i += blockCount
            }
            precondition(blockData.count == size.dataCodewords(inBlock: block))
            let ecc = field.remainder(blockData, generator: generator)
            for (k, value) in ecc.enumerated() {
                result[data.count + k * blockCount + block] = value
            }
        }
        return result
    }

    // MARK: Platzierung (ISO/IEC 16022, Anhang F)

    /// Abbildung der Codewort-Bits auf die Abbildungsmatrix (alle Datenbereiche ohne Suchmuster).
    ///
    /// `cells` enthält je Modul `codewort · 8 + (bit − 1)` (Bit 1 = höchstwertiges Bit) bzw. für
    /// die bei 4 Restbits unbelegte Ecke rechts unten −1 (fest dunkel) oder −2 (fest hell).
    struct Placement {
        let rows: Int
        let columns: Int
        var cells: [Int]

        init(rows: Int, columns: Int) {
            self.rows = rows
            self.columns = columns
            cells = [Int](repeating: Int.min, count: rows * columns)
            run()
        }

        private mutating func module(_ rowIn: Int, _ columnIn: Int, _ codeword: Int, _ bit: Int) {
            var row = rowIn
            var column = columnIn
            if row < 0 {
                row += rows
                column += 4 - ((rows + 4) % 8)
            }
            if column < 0 {
                column += columns
                row += 4 - ((columns + 4) % 8)
            }
            cells[row * columns + column] = codeword * 8 + (bit - 1)
        }

        private mutating func utah(_ row: Int, _ column: Int, _ codeword: Int) {
            module(row - 2, column - 2, codeword, 1)
            module(row - 2, column - 1, codeword, 2)
            module(row - 1, column - 2, codeword, 3)
            module(row - 1, column - 1, codeword, 4)
            module(row - 1, column, codeword, 5)
            module(row, column - 2, codeword, 6)
            module(row, column - 1, codeword, 7)
            module(row, column, codeword, 8)
        }

        private mutating func corner1(_ codeword: Int) {
            module(rows - 1, 0, codeword, 1)
            module(rows - 1, 1, codeword, 2)
            module(rows - 1, 2, codeword, 3)
            module(0, columns - 2, codeword, 4)
            module(0, columns - 1, codeword, 5)
            module(1, columns - 1, codeword, 6)
            module(2, columns - 1, codeword, 7)
            module(3, columns - 1, codeword, 8)
        }

        private mutating func corner2(_ codeword: Int) {
            module(rows - 3, 0, codeword, 1)
            module(rows - 2, 0, codeword, 2)
            module(rows - 1, 0, codeword, 3)
            module(0, columns - 4, codeword, 4)
            module(0, columns - 3, codeword, 5)
            module(0, columns - 2, codeword, 6)
            module(0, columns - 1, codeword, 7)
            module(1, columns - 1, codeword, 8)
        }

        private mutating func corner3(_ codeword: Int) {
            module(rows - 3, 0, codeword, 1)
            module(rows - 2, 0, codeword, 2)
            module(rows - 1, 0, codeword, 3)
            module(0, columns - 2, codeword, 4)
            module(0, columns - 1, codeword, 5)
            module(1, columns - 1, codeword, 6)
            module(2, columns - 1, codeword, 7)
            module(3, columns - 1, codeword, 8)
        }

        private mutating func corner4(_ codeword: Int) {
            module(rows - 1, 0, codeword, 1)
            module(rows - 1, columns - 1, codeword, 2)
            module(0, columns - 3, codeword, 3)
            module(0, columns - 2, codeword, 4)
            module(0, columns - 1, codeword, 5)
            module(1, columns - 3, codeword, 6)
            module(1, columns - 2, codeword, 7)
            module(1, columns - 1, codeword, 8)
        }

        private func isUnset(_ row: Int, _ column: Int) -> Bool { cells[row * columns + column] == Int.min }

        private mutating func run() {
            var codeword = 0
            var row = 4
            var column = 0
            repeat {
                // Sonderfälle der Ecken
                if row == rows && column == 0 { corner1(codeword); codeword += 1 }
                if row == rows - 2 && column == 0 && columns % 4 != 0 { corner2(codeword); codeword += 1 }
                if row == rows - 2 && column == 0 && columns % 8 == 4 { corner3(codeword); codeword += 1 }
                if row == rows + 4 && column == 2 && columns % 8 == 0 { corner4(codeword); codeword += 1 }
                // Diagonal nach rechts oben
                repeat {
                    if row < rows && column >= 0 && isUnset(row, column) { utah(row, column, codeword); codeword += 1 }
                    row -= 2
                    column += 2
                } while row >= 0 && column < columns
                row += 1
                column += 3
                // Diagonal nach links unten
                repeat {
                    if row >= 0 && column < columns && isUnset(row, column) { utah(row, column, codeword); codeword += 1 }
                    row += 2
                    column -= 2
                } while row < rows && column >= 0
                row += 3
                column += 1
            } while row < rows || column < columns
            // Nicht belegte Ecke rechts unten: fest dunkel/hell (Schachbrett)
            if isUnset(rows - 1, columns - 1) {
                cells[(rows - 1) * columns + columns - 1] = -1
                cells[(rows - 2) * columns + columns - 2] = -1
                cells[(rows - 1) * columns + columns - 2] = -2
                cells[(rows - 2) * columns + columns - 1] = -2
            }
        }
    }

    /// Baut das Symbol aus allen Codewörtern (Daten + Fehlerkorrektur).
    static func symbol(codewords: [UInt8], size: SymbolSize) -> BitMatrix {
        let placement = Placement(rows: size.mappingRows, columns: size.mappingColumns)
        var matrix = BitMatrix(width: size.columns, height: size.rows)
        for regionY in 0..<size.verticalRegions {
            for regionX in 0..<size.horizontalRegions {
                let originX = regionX * (size.regionColumns + 2)
                let originY = regionY * (size.regionRows + 2)
                let height = size.regionRows + 2
                let width = size.regionColumns + 2
                // Suchmuster: durchgehend links und unten, Taktmuster oben und rechts.
                for y in 0..<height {
                    matrix[originX, originY + y] = true
                    matrix[originX + width - 1, originY + y] = y % 2 == 1
                }
                for x in 0..<width {
                    matrix[originX + x, originY + height - 1] = true
                    matrix[originX + x, originY] = x % 2 == 0
                }
                // Daten
                for r in 0..<size.regionRows {
                    for c in 0..<size.regionColumns {
                        let mappingRow = regionY * size.regionRows + r
                        let mappingColumn = regionX * size.regionColumns + c
                        let cell = placement.cells[mappingRow * size.mappingColumns + mappingColumn]
                        let dark: Bool
                        if cell >= 0 {
                            let codeword = codewords[cell / 8]
                            dark = (codeword >> UInt8(7 - cell % 8)) & 1 == 1
                        } else {
                            dark = cell == -1
                        }
                        matrix[originX + 1 + c, originY + 1 + r] = dark
                    }
                }
            }
        }
        return matrix
    }

    // MARK: Einstiegspunkt

    /// Wählt die Symbolgröße für die kodierten Daten und füllt auf.
    ///
    /// * Endet eine C40-/Text-/X12-Variante ohne Unlatch und füllt sie ein kleineres Symbol exakt,
    ///   wird sie verwendet (impliziter Rücksprung am Symbolende, ISO/IEC 16022, 5.2.5.2).
    /// * Stünde ein abschließendes Unlatch (254) genau auf dem letzten Codewort, würde ein Decoder
    ///   es als ASCII lesen; es wird dann durch das Füllzeichen 129 ersetzt.
    /// * Die letzte EDIFACT-Gruppe braucht ab ihrem Beginn mindestens 3 Codewörter im Symbol.
    static func finalize(_ encoded: EncodedData, options: DataMatrixOptions) throws -> (size: SymbolSize, data: [UInt8]) {
        var data = encoded.codewords
        var minimum = data.count
        if let start = encoded.lastEdifactGroupStart { minimum = max(minimum, start + 3) }
        var size = try selectSize(for: minimum, options: options)
        if let alternative = encoded.withoutFinalUnlatch, let exact = try selectSize(for: alternative.count, options: options),
           exact.dataCodewords == alternative.count, size == nil || exact.dataCodewords < size!.dataCodewords {
            data = alternative
            size = exact
        } else if let chosen = size, encoded.endsWithUnlatch, data.count == chosen.dataCodewords {
            data.removeLast()  // pad() setzt an diese Stelle das ASCII-Füllzeichen 129
        }
        guard let size else { throw BarcodeError.dataTooLong }
        pad(&data, to: size.dataCodewords)
        return (size, data)
    }

    /// Kleinstes zulässiges Symbol nach den Optionen; wirft `unsupported`, wenn die feste Größe
    /// nicht existiert, und liefert `nil`, wenn keine passende Größe genug Kapazität hat.
    static func selectSize(for codewords: Int, options: DataMatrixOptions) throws -> SymbolSize? {
        if options.rows > 0 || options.columns > 0 {
            let candidates = sizes.filter {
                (options.rows == 0 || $0.rows == options.rows) && (options.columns == 0 || $0.columns == options.columns)
            }
            guard !candidates.isEmpty else {
                throw BarcodeError.unsupported("Data Matrix: Es gibt kein ECC200-Symbol mit \(options.rows) × \(options.columns) Modulen.")
            }
            return candidates
                .filter { $0.dataCodewords >= codewords }
                .min { ($0.dataCodewords, $0.rows * $0.columns) < ($1.dataCodewords, $1.rows * $1.columns) }
        }
        return smallestSize(for: codewords, shape: options.shape)
    }

    /// Erzeugt ein Data-Matrix-Symbol aus Bytes.
    static func encode(bytes: [UInt8], options: DataMatrixOptions) throws -> BitMatrix {
        guard !bytes.isEmpty else { throw BarcodeError.invalidLength(0) }
        let (size, data) = try finalize(try encodeData(bytes), options: options)
        return symbol(codewords: addErrorCorrection(data, size: size), size: size)
    }

    /// Erzeugt ein Data-Matrix-Symbol aus Text (UTF-8).
    static func encode(_ text: String, options: DataMatrixOptions) throws -> BitMatrix {
        try encode(bytes: Array(text.utf8), options: options)
    }
}

import Foundation

/// Code 128 (ISO/IEC 15417) inklusive GS1-128.
///
/// Der Automatikmodus wählt Startzeichen, Zeichensatzwechsel (CODE A/B/C), SHIFT und FNC4 per
/// dynamischer Programmierung so, dass die Anzahl der Symbolzeichen minimal ist. Ungerade
/// Ziffernfolgen werden dabei optimal aufgeteilt (eine Ziffer in A/B, der Rest paarweise in C).
enum Code128 {

    // MARK: Symbolwerte

    static let shift = 98
    static let codeC = 99
    /// In Zeichensatz A: CODE B, in B: FNC4, in C: CODE B.
    static let value100 = 100
    /// In Zeichensatz A: FNC4, in B: CODE A, in C: CODE A.
    static let value101 = 101
    static let fnc1 = 102
    static let startA = 103
    static let startB = 104
    static let startC = 105
    static let stop = 106

    /// Balken-/Lückenbreiten der Symbolwerte 0…105 (je 6 Elemente, 11 Module) und des
    /// Stoppzeichens 106 (7 Elemente, 13 Module).
    static let patterns: [[Int]] = [
        [2, 1, 2, 2, 2, 2], [2, 2, 2, 1, 2, 2], [2, 2, 2, 2, 2, 1], [1, 2, 1, 2, 2, 3], [1, 2, 1, 3, 2, 2],
        [1, 3, 1, 2, 2, 2], [1, 2, 2, 2, 1, 3], [1, 2, 2, 3, 1, 2], [1, 3, 2, 2, 1, 2], [2, 2, 1, 2, 1, 3],
        [2, 2, 1, 3, 1, 2], [2, 3, 1, 2, 1, 2], [1, 1, 2, 2, 3, 2], [1, 2, 2, 1, 3, 2], [1, 2, 2, 2, 3, 1],
        [1, 1, 3, 2, 2, 2], [1, 2, 3, 1, 2, 2], [1, 2, 3, 2, 2, 1], [2, 2, 3, 2, 1, 1], [2, 2, 1, 1, 3, 2],
        [2, 2, 1, 2, 3, 1], [2, 1, 3, 2, 1, 2], [2, 2, 3, 1, 1, 2], [3, 1, 2, 1, 3, 1], [3, 1, 1, 2, 2, 2],
        [3, 2, 1, 1, 2, 2], [3, 2, 1, 2, 2, 1], [3, 1, 2, 2, 1, 2], [3, 2, 2, 1, 1, 2], [3, 2, 2, 2, 1, 1],
        [2, 1, 2, 1, 2, 3], [2, 1, 2, 3, 2, 1], [2, 3, 2, 1, 2, 1], [1, 1, 1, 3, 2, 3], [1, 3, 1, 1, 2, 3],
        [1, 3, 1, 3, 2, 1], [1, 1, 2, 3, 1, 3], [1, 3, 2, 1, 1, 3], [1, 3, 2, 3, 1, 1], [2, 1, 1, 3, 1, 3],
        [2, 3, 1, 1, 1, 3], [2, 3, 1, 3, 1, 1], [1, 1, 2, 1, 3, 3], [1, 1, 2, 3, 3, 1], [1, 3, 2, 1, 3, 1],
        [1, 1, 3, 1, 2, 3], [1, 1, 3, 3, 2, 1], [1, 3, 3, 1, 2, 1], [3, 1, 3, 1, 2, 1], [2, 1, 1, 3, 3, 1],
        [2, 3, 1, 1, 3, 1], [2, 1, 3, 1, 1, 3], [2, 1, 3, 3, 1, 1], [2, 1, 3, 1, 3, 1], [3, 1, 1, 1, 2, 3],
        [3, 1, 1, 3, 2, 1], [3, 3, 1, 1, 2, 1], [3, 1, 2, 1, 1, 3], [3, 1, 2, 3, 1, 1], [3, 3, 2, 1, 1, 1],
        [3, 1, 4, 1, 1, 1], [2, 2, 1, 4, 1, 1], [4, 3, 1, 1, 1, 1], [1, 1, 1, 2, 2, 4], [1, 1, 1, 4, 2, 2],
        [1, 2, 1, 1, 2, 4], [1, 2, 1, 4, 2, 1], [1, 4, 1, 1, 2, 2], [1, 4, 1, 2, 2, 1], [1, 1, 2, 2, 1, 4],
        [1, 1, 2, 4, 1, 2], [1, 2, 2, 1, 1, 4], [1, 2, 2, 4, 1, 1], [1, 4, 2, 1, 1, 2], [1, 4, 2, 2, 1, 1],
        [2, 4, 1, 2, 1, 1], [2, 2, 1, 1, 1, 4], [4, 1, 3, 1, 1, 1], [2, 4, 1, 1, 1, 2], [1, 3, 4, 1, 1, 1],
        [1, 1, 1, 2, 4, 2], [1, 2, 1, 1, 4, 2], [1, 2, 1, 2, 4, 1], [1, 1, 4, 2, 1, 2], [1, 2, 4, 1, 1, 2],
        [1, 2, 4, 2, 1, 1], [4, 1, 1, 2, 1, 2], [4, 2, 1, 1, 1, 2], [4, 2, 1, 2, 1, 1], [2, 1, 2, 1, 4, 1],
        [2, 1, 4, 1, 2, 1], [4, 1, 2, 1, 2, 1], [1, 1, 1, 1, 4, 3], [1, 1, 1, 3, 4, 1], [1, 3, 1, 1, 4, 1],
        [1, 1, 4, 1, 1, 3], [1, 1, 4, 3, 1, 1], [4, 1, 1, 1, 1, 3], [4, 1, 1, 3, 1, 1], [1, 1, 3, 1, 4, 1],
        [1, 1, 4, 1, 3, 1], [3, 1, 1, 1, 4, 1], [4, 1, 1, 1, 3, 1], [2, 1, 1, 4, 1, 2], [2, 1, 1, 2, 1, 4],
        [2, 1, 1, 2, 3, 2], [2, 3, 3, 1, 1, 1, 2],
    ]

    // MARK: Eingabe-Token

    /// Ein zu kodierendes Datenelement: ein Byte (ISO 8859-1) oder das Funktionszeichen FNC1.
    enum Token: Equatable, Sendable {
        case byte(UInt8)
        case fnc1

        var isDigit: Bool {
            if case .byte(let value) = self { return value >= 0x30 && value <= 0x39 }
            return false
        }

        var digitValue: Int {
            if case .byte(let value) = self { return Int(value) - 0x30 }
            return 0
        }
    }

    /// Zeichensätze A, B, C.
    enum CodeSet: Int, CaseIterable, Sendable {
        case a = 0, b = 1, c = 2

        var startValue: Int {
            switch self {
            case .a: return Code128.startA
            case .b: return Code128.startB
            case .c: return Code128.startC
            }
        }

        /// Symbolwert, der aus `self` in den Zeichensatz `target` umschaltet.
        func switchValue(to target: CodeSet) -> Int {
            switch target {
            case .a: return Code128.value101
            case .b: return Code128.value100
            case .c: return Code128.codeC
            }
        }

        /// Symbolwert des Funktionszeichens FNC4 (nur A und B).
        var fnc4Value: Int { self == .a ? Code128.value101 : Code128.value100 }
    }

    /// Symbolwert eines 7-Bit-Zeichens im Zeichensatz A bzw. B, oder `nil`, wenn nicht enthalten.
    static func value(of base: UInt8, in set: CodeSet) -> Int? {
        switch set {
        case .a:
            if base < 32 { return Int(base) + 64 }
            if base < 96 { return Int(base) - 32 }
            return nil
        case .b:
            if base >= 32 && base < 128 { return Int(base) - 32 }
            return nil
        case .c:
            return nil
        }
    }

    // MARK: Kodierung

    /// Wandelt einen Text (ISO 8859-1) in Token um.
    static func tokens(from text: String) throws -> [Token] {
        var result: [Token] = []
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { throw BarcodeError.invalidCharacter(Character(scalar)) }
            result.append(.byte(UInt8(scalar.value)))
        }
        return result
    }

    /// Ermittelt die Symbolwerte (Startzeichen + Daten, ohne Prüfzeichen und Stopp).
    ///
    /// - Parameter allowedSets: Erlaubte Zeichensätze. Bei genau einem Satz werden keine
    ///   Zeichensatzwechsel erzeugt (SHIFT bleibt zwischen A und B erlaubt).
    static func symbolValues(for tokens: [Token], allowedSets: [CodeSet]) throws -> [Int] {
        let count = tokens.count
        let infinity = Int.max / 4
        let forced = allowedSets.count == 1

        struct Step { var previousPosition: Int; var previousSet: Int; var values: [Int] }
        var cost = Array(repeating: Array(repeating: infinity, count: 3), count: count + 1)
        var step = Array(repeating: Array<Step?>(repeating: nil, count: 3), count: count + 1)

        for set in allowedSets {
            cost[0][set.rawValue] = 1
            step[0][set.rawValue] = Step(previousPosition: -1, previousSet: -1, values: [set.startValue])
        }

        for position in 0...count {
            // 1) Zeichensatzwechsel an dieser Position (ein Wechsel genügt, Ketten sind nie günstiger).
            if !forced {
                let before = cost[position]
                for target in allowedSets {
                    for source in allowedSets where source != target {
                        let candidate = before[source.rawValue] + 1
                        if candidate < cost[position][target.rawValue] {
                            cost[position][target.rawValue] = candidate
                            step[position][target.rawValue] = Step(
                                previousPosition: position, previousSet: source.rawValue,
                                values: [source.switchValue(to: target)])
                        }
                    }
                }
            }
            guard position < count else { break }

            // 2) Zeichen kodieren.
            for set in allowedSets {
                let current = cost[position][set.rawValue]
                guard current < infinity else { continue }

                func relax(_ next: Int, _ values: [Int]) {
                    let candidate = current + values.count
                    if candidate < cost[next][set.rawValue] {
                        cost[next][set.rawValue] = candidate
                        step[next][set.rawValue] = Step(previousPosition: position, previousSet: set.rawValue, values: values)
                    }
                }

                switch tokens[position] {
                case .fnc1:
                    relax(position + 1, [fnc1])
                case .byte(let byte):
                    if set == .c {
                        if position + 1 < count, tokens[position].isDigit, tokens[position + 1].isDigit {
                            relax(position + 2, [tokens[position].digitValue * 10 + tokens[position + 1].digitValue])
                        }
                        continue
                    }
                    let base = byte & 0x7F
                    let extended = byte >= 0x80
                    if let value = value(of: base, in: set) {
                        relax(position + 1, extended ? [set.fnc4Value, value] : [value])
                    } else if !extended {
                        let other: CodeSet = set == .a ? .b : .a
                        if let value = value(of: base, in: other) {
                            relax(position + 1, [shift, value])
                        }
                    }
                }
            }
        }

        // Bestes Endergebnis wählen und Pfad rekonstruieren.
        var bestSet = -1
        var bestCost = infinity
        for set in allowedSets where cost[count][set.rawValue] < bestCost {
            bestCost = cost[count][set.rawValue]
            bestSet = set.rawValue
        }
        guard bestSet >= 0 else {
            if let bad = firstUnencodable(tokens, allowedSets: allowedSets) { throw bad }
            throw BarcodeError.invalidLength(count)
        }

        var chunks: [[Int]] = []
        var position = count
        var set = bestSet
        while position >= 0, let current = step[position][set] {
            chunks.append(current.values)
            if current.previousPosition < 0 { break }
            position = current.previousPosition
            set = current.previousSet
        }
        return chunks.reversed().flatMap { $0 }
    }

    /// Ermittelt den passenden Fehler für nicht kodierbare Eingaben.
    private static func firstUnencodable(_ tokens: [Token], allowedSets: [CodeSet]) -> BarcodeError? {
        if allowedSets == [.c] {
            for token in tokens {
                if case .byte(let byte) = token, !(byte >= 0x30 && byte <= 0x39) {
                    return .invalidCharacter(Character(Unicode.Scalar(byte)))
                }
            }
            let digitCount = tokens.filter { $0.isDigit }.count
            return .invalidLength(digitCount)
        }
        for token in tokens {
            guard case .byte(let byte) = token else { continue }
            let base = byte & 0x7F
            let encodable = allowedSets.contains { value(of: base, in: $0) != nil }
            if !encodable { return .invalidCharacter(Character(Unicode.Scalar(byte))) }
        }
        return nil
    }

    /// Erzeugt das vollständige Symbol aus Symbolwerten (Startzeichen + Daten).
    /// Prüfzeichen (Modulo 103) und Stoppzeichen werden angehängt.
    static func symbol(values: [Int], humanReadable: String) -> LinearBarcode {
        var elements: [LinearBarcode.Element] = []
        for value in values + [checksum(values), stop] {
            elements.append(contentsOf: LinearSupport.elements(widths: patterns[value]))
        }
        return LinearBarcode(elements: elements, humanReadable: humanReadable, isTwoWidth: false)
    }

    /// Prüfzeichenwert (Modulo 103) für Symbolwerte inklusive Startzeichen.
    static func checksum(_ values: [Int]) -> Int {
        var sum = values.first ?? 0
        for (index, value) in values.enumerated().dropFirst() { sum += index * value }
        return sum % 103
    }

    /// Klarschrift: Steuerzeichen werden ausgelassen.
    static func readable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    }

    // MARK: Öffentliche Einstiegspunkte (über BarcodeEncoder)

    static func encode(_ text: String, mode: Code128Mode) throws -> LinearBarcode {
        switch mode {
        case .auto:
            let tokens = try tokens(from: text)
            guard !tokens.isEmpty else { throw BarcodeError.invalidLength(0) }
            let values = try symbolValues(for: tokens, allowedSets: [.b, .c, .a])
            return symbol(values: values, humanReadable: readable(text))
        case .subsetA, .subsetB:
            let tokens = try tokens(from: text)
            guard !tokens.isEmpty else { throw BarcodeError.invalidLength(0) }
            let values = try symbolValues(for: tokens, allowedSets: [mode == .subsetA ? .a : .b])
            return symbol(values: values, humanReadable: readable(text))
        case .subsetC:
            let tokens = try tokens(from: text)
            guard !tokens.isEmpty else { throw BarcodeError.invalidLength(0) }
            for token in tokens where !token.isDigit {
                if case .byte(let byte) = token { throw BarcodeError.invalidCharacter(Character(Unicode.Scalar(byte))) }
            }
            guard tokens.count % 2 == 0 else { throw BarcodeError.invalidLength(tokens.count) }
            let values = try symbolValues(for: tokens, allowedSets: [.c])
            return symbol(values: values, humanReadable: text)
        case .ucc:
            let parsed = try GS1.parse(text)
            let values = try symbolValues(for: parsed.tokens, allowedSets: [.c, .b, .a])
            return symbol(values: values, humanReadable: parsed.humanReadable)
        }
    }

    /// Erzeugt ein Symbol aus vorgegebenen Symbolwerten (für ZPL-Aufrufcodes u. Ä.).
    static func encode(symbolValues values: [Int], humanReadable: String) throws -> LinearBarcode {
        guard let first = values.first, (startA...startC).contains(first) else {
            throw BarcodeError.unsupported("Code 128: Die Symbolwerte müssen mit einem Startzeichen (103–105) beginnen.")
        }
        guard values.count >= 2 else { throw BarcodeError.invalidLength(0) }
        for value in values.dropFirst() where !(0...fnc1).contains(value) {
            throw BarcodeError.unsupported("Code 128: Ungültiger Symbolwert \(value).")
        }
        return symbol(values: values, humanReadable: humanReadable)
    }
}

// MARK: - GS1-Elementketten

/// Zerlegt GS1-Elementketten für GS1-128.
///
/// Akzeptiert werden
/// * die Klarschriftform mit Datenbezeichnern in runden oder eckigen Klammern,
///   z. B. `(01)09501101530003(17)140704(10)AB-123`, sowie
/// * die Rohform ohne Klammern, in der variable Felder mit dem Gruppentrennzeichen
///   GS (ASCII 29) abgeschlossen sind.
///
/// Für die Datenbezeichner 00 (17 Ziffern), 01 und 02 (je 13 Ziffern) wird die fehlende
/// Prüfziffer automatisch ergänzt.
enum GS1 {
    /// Zweistellige Präfixe von Datenbezeichnern mit vordefinierter (fester) Länge, nach denen
    /// kein FNC1-Trennzeichen nötig ist (GS1 General Specifications, Abbildung 7.8.5-2).
    static let predefinedLengthPrefixes: Set<String> = [
        "00", "01", "02", "03", "04", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20",
        "31", "32", "33", "34", "35", "36", "41",
    ]

    struct Parsed {
        var tokens: [Code128.Token]
        var humanReadable: String
    }

    static func parse(_ text: String) throws -> Parsed {
        guard !text.isEmpty else { throw BarcodeError.invalidLength(0) }
        let scalars = Array(text.unicodeScalars)
        if let first = scalars.first, first == "(" || first == "[" {
            return try parseBracketed(scalars)
        }
        return try parseRaw(scalars)
    }

    private static func parseBracketed(_ scalars: [Unicode.Scalar]) throws -> Parsed {
        var elements: [(ai: String, data: String)] = []
        var index = 0
        while index < scalars.count {
            let open = scalars[index]
            guard open == "(" || open == "[" else { throw BarcodeError.invalidCharacter(Character(open)) }
            let close: Unicode.Scalar = open == "(" ? ")" : "]"
            index += 1
            var ai = ""
            while index < scalars.count, scalars[index] != close {
                let scalar = scalars[index]
                guard scalar.value >= 0x30 && scalar.value <= 0x39 else { throw BarcodeError.invalidCharacter(Character(scalar)) }
                ai.unicodeScalars.append(scalar)
                index += 1
            }
            guard index < scalars.count else { throw BarcodeError.unsupported("GS1-128: Datenbezeichner ohne schließende Klammer.") }
            guard (2...4).contains(ai.count) else { throw BarcodeError.invalidLength(ai.count) }
            index += 1  // schließende Klammer
            var data = ""
            while index < scalars.count, scalars[index] != open {
                let scalar = scalars[index]
                guard scalar.value >= 0x20 && scalar.value < 0x7F else { throw BarcodeError.invalidCharacter(Character(scalar)) }
                data.unicodeScalars.append(scalar)
                index += 1
            }
            guard !data.isEmpty else { throw BarcodeError.invalidLength(0) }
            elements.append((ai, completeCheckDigit(ai: ai, data: data)))
        }

        var tokens: [Code128.Token] = [.fnc1]
        var readable = ""
        for (offset, element) in elements.enumerated() {
            for byte in (element.ai + element.data).utf8 { tokens.append(.byte(byte)) }
            readable += "(\(element.ai))\(element.data)"
            let isLast = offset == elements.count - 1
            if !isLast && !predefinedLengthPrefixes.contains(String(element.ai.prefix(2))) {
                tokens.append(.fnc1)
            }
        }
        return Parsed(tokens: tokens, humanReadable: readable)
    }

    private static func parseRaw(_ scalars: [Unicode.Scalar]) throws -> Parsed {
        var tokens: [Code128.Token] = [.fnc1]
        var readable = ""
        for scalar in scalars {
            if scalar.value == 0x1D {
                if tokens.last != .fnc1 { tokens.append(.fnc1) }
                continue
            }
            guard scalar.value >= 0x20 && scalar.value < 0x7F else { throw BarcodeError.invalidCharacter(Character(scalar)) }
            tokens.append(.byte(UInt8(scalar.value)))
            readable.unicodeScalars.append(scalar)
        }
        while tokens.count > 1, tokens.last == .fnc1 { tokens.removeLast() }
        guard tokens.count > 1 else { throw BarcodeError.invalidLength(0) }
        return Parsed(tokens: tokens, humanReadable: readable)
    }

    /// Ergänzt die GS1-Prüfziffer für SSCC (00) und GTIN (01/02), falls genau eine Ziffer fehlt.
    static func completeCheckDigit(ai: String, data: String) -> String {
        let expectedWithoutCheck: Int
        switch ai {
        case "00": expectedWithoutCheck = 17
        case "01", "02": expectedWithoutCheck = 13
        default: return data
        }
        guard data.count == expectedWithoutCheck, let digits = try? LinearSupport.digits(data) else { return data }
        return data + String(LinearSupport.digitCharacter(LinearSupport.mod10Weighted31(digits)))
    }
}

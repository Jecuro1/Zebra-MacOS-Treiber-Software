import Foundation

/// Erweiterte Einstellungen für PDF417 (siehe `BarcodeEncoder.pdf417(_:options:)`).
public struct PDF417Options: Hashable, Sendable {
    /// Datenspalten 1…30, 0 = automatisch (Seitenverhältnis ca. 3 : 1).
    public var columns: Int
    /// Zeilen 3…90, 0 = automatisch (aus Spalten und Datenmenge).
    public var rows: Int
    /// Fehlerkorrekturstufe 0…8 (2^(s+1) Korrektur-Codewörter).
    public var securityLevel: Int
    /// Höhe einer Symbolzeile in Matrixzeilen (Modulen), mindestens 1. Die Norm empfiehlt ≥ 3.
    public var rowHeight: Int
    /// Kompakt-PDF417 (früher „Truncated PDF417“): ohne rechten Zeilenindikator, Stoppmuster
    /// auf einen Balken verkürzt (wie ZPL `^B7` mit Parameter t = Y).
    public var compact: Bool

    public init(columns: Int = 0, rows: Int = 0, securityLevel: Int = 2, rowHeight: Int = 3, compact: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.securityLevel = securityLevel
        self.rowHeight = rowHeight
        self.compact = compact
    }
}

/// PDF417 (ISO/IEC 15438).
///
/// Hochebenen-Kodierung mit Text-Kompaktierung (Teilmodi Alpha/Lower/Mixed/Punctuation inklusive
/// Shift-Zeichen), Byte-Kompaktierung (901/924, Einzelbyte-Shift 913) und numerischer
/// Kompaktierung (902, ab 13 Ziffern), Reed-Solomon-Fehlerkorrektur über GF(929),
/// Zeilenindikatoren und Clustertabellen 0/3/6.
///
/// In der `BitMatrix` umfasst jede Symbolzeile `rowHeight` Matrixzeilen (Standard 3), damit
/// das Symbol mit quadratischen Modulen gerastert werden kann. Text wird als UTF-8 kodiert;
/// für ISO 8859-1 oder Binärdaten dient `BarcodeEncoder.pdf417(bytes:options:)`.
enum PDF417 {

    // MARK: Konstanten

    static let latchText = 900
    static let latchByte = 901
    static let latchNumeric = 902
    static let shiftByte = 913
    static let latchByte6 = 924
    static let padding = 900

    /// Startmuster (8,1,1,1,1,1,1,3) und Stoppmuster (7,1,1,3,1,1,1,2,1) als Modulfolgen.
    static let startPattern: [Bool] = "11111111010101000".map { $0 == "1" }
    static let stopPattern: [Bool] = "111111101000101001".map { $0 == "1" }

    // MARK: Text-Kompaktierung

    enum Submode: Sendable { case alpha, lower, mixed, punctuation }

    /// Zeichen des Mixed-Teilmodus in Wertreihenfolge (0…24, 26 = Leerzeichen).
    static let mixedCharacters: [UInt8] = [
        48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 38, 13, 9, 44, 58, 35, 45, 46, 36, 47, 43, 37, 42, 61, 94,
    ]
    /// Zeichen des Punctuation-Teilmodus in Wertreihenfolge (0…28).
    static let punctuationCharacters: [UInt8] = [
        59, 60, 62, 64, 91, 92, 93, 95, 96, 126, 33, 13, 9, 44, 58, 10, 45, 46, 36, 47, 34, 124, 42, 40, 41, 63, 123, 125, 39,
    ]

    static let mixedValue: [Int] = {
        var table = [Int](repeating: -1, count: 128)
        for (value, character) in mixedCharacters.enumerated() { table[Int(character)] = value }
        table[32] = 26
        return table
    }()

    static let punctuationValue: [Int] = {
        var table = [Int](repeating: -1, count: 128)
        for (value, character) in punctuationCharacters.enumerated() { table[Int(character)] = value }
        return table
    }()

    static func isAlphaUpper(_ c: UInt8) -> Bool { c == 32 || (c >= 65 && c <= 90) }
    static func isAlphaLower(_ c: UInt8) -> Bool { c == 32 || (c >= 97 && c <= 122) }
    static func isMixed(_ c: UInt8) -> Bool { c < 128 && mixedValue[Int(c)] >= 0 }
    static func isPunctuation(_ c: UInt8) -> Bool { c < 128 && punctuationValue[Int(c)] >= 0 }
    static func isText(_ c: UInt8) -> Bool { c == 9 || c == 10 || c == 13 || (c >= 32 && c <= 126) }
    static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// Laufender Zustand der Text-Kompaktierung (Teilmodus und noch nicht gepaarte Werte).
    struct TextState {
        var submode: Submode = .alpha
        var pending: [Int] = []

        /// Hängt die Teilmoduswerte für `bytes` an.
        mutating func append(_ bytes: ArraySlice<UInt8>) {
            var index = bytes.startIndex
            while index < bytes.endIndex {
                let c = bytes[index]
                switch submode {
                case .alpha:
                    if isAlphaUpper(c) {
                        pending.append(c == 32 ? 26 : Int(c) - 65)
                    } else if isAlphaLower(c) {
                        pending.append(27)  // ll
                        submode = .lower
                        continue
                    } else if isMixed(c) {
                        pending.append(28)  // ml
                        submode = .mixed
                        continue
                    } else {
                        pending.append(29)  // ps
                        pending.append(punctuationValue[Int(c)])
                    }
                case .lower:
                    if isAlphaLower(c) {
                        pending.append(c == 32 ? 26 : Int(c) - 97)
                    } else if isAlphaUpper(c) {
                        if index + 1 < bytes.endIndex, bytes[index + 1] >= 65, bytes[index + 1] <= 90 {
                            // Mehrere Großbuchstaben: ml + al (2 Werte) statt as je Zeichen
                            pending.append(28)  // ml
                            pending.append(28)  // al
                            submode = .alpha
                            continue
                        }
                        pending.append(27)  // as
                        pending.append(Int(c) - 65)
                    } else if isMixed(c) {
                        pending.append(28)  // ml
                        submode = .mixed
                        continue
                    } else {
                        pending.append(29)  // ps
                        pending.append(punctuationValue[Int(c)])
                    }
                case .mixed:
                    if isMixed(c) {
                        pending.append(mixedValue[Int(c)])
                    } else if isAlphaUpper(c) {
                        pending.append(28)  // al
                        submode = .alpha
                        continue
                    } else if isAlphaLower(c) {
                        pending.append(27)  // ll
                        submode = .lower
                        continue
                    } else if index + 1 < bytes.endIndex && isPunctuation(bytes[index + 1]) {
                        pending.append(25)  // pl
                        submode = .punctuation
                        continue
                    } else {
                        pending.append(29)  // ps
                        pending.append(punctuationValue[Int(c)])
                    }
                case .punctuation:
                    if isPunctuation(c) {
                        pending.append(punctuationValue[Int(c)])
                    } else {
                        pending.append(29)  // al
                        submode = .alpha
                        continue
                    }
                }
                index += 1
            }
        }

        /// Paart die Werte zu Codewörtern (30·h + l).
        ///
        /// - Parameter beforeByteShift: Folgt ein Einzelbyte-Shift (913), wird ein ungerader Rest
        ///   mit einem Latch statt mit `ps` aufgefüllt, damit kein offener Punctuation-Shift über
        ///   das Byte hinweg wirkt (eindeutig für jeden Decoder). Gewählt wird jeweils der Latch,
        ///   von dem aus die Rückkehr am günstigsten ist (Alpha → Mixed, Lower → Mixed, Mixed → Alpha).
        mutating func flush(into codewords: inout [Int], beforeByteShift: Bool) {
            if pending.count % 2 == 1 {
                if beforeByteShift {
                    switch submode {
                    case .alpha: pending.append(28); submode = .mixed        // ml
                    case .lower: pending.append(28); submode = .mixed        // ml
                    case .mixed: pending.append(28); submode = .alpha        // al
                    case .punctuation: pending.append(29); submode = .alpha  // al
                    }
                } else {
                    pending.append(29)
                }
            }
            var index = 0
            while index < pending.count {
                codewords.append(pending[index] * 30 + pending[index + 1])
                index += 2
            }
            pending.removeAll(keepingCapacity: true)
        }
    }

    // MARK: Byte- und numerische Kompaktierung

    static func appendBytes(_ bytes: ArraySlice<UInt8>, to codewords: inout [Int]) {
        codewords.append(bytes.count % 6 == 0 ? latchByte6 : latchByte)
        var index = bytes.startIndex
        while bytes.endIndex - index >= 6 {
            var value: UInt64 = 0
            for k in 0..<6 { value = value << 8 | UInt64(bytes[index + k]) }
            var group = [Int](repeating: 0, count: 5)
            for k in stride(from: 4, through: 0, by: -1) {
                group[k] = Int(value % 900)
                value /= 900
            }
            codewords.append(contentsOf: group)
            index += 6
        }
        while index < bytes.endIndex {
            codewords.append(Int(bytes[index]))
            index += 1
        }
    }

    /// Numerische Kompaktierung: Gruppen bis 44 Ziffern, mit führender „1“ zur Basis 900.
    static func appendNumeric(_ digits: ArraySlice<UInt8>, to codewords: inout [Int]) {
        var index = digits.startIndex
        while index < digits.endIndex {
            let length = min(44, digits.endIndex - index)
            var decimal = [1] + digits[index..<(index + length)].map { Int($0) - 48 }
            var group: [Int] = []
            // Wiederholte Division der Dezimalzahl durch 900.
            while !(decimal.count == 1 && decimal[0] == 0) {
                var remainder = 0
                var quotient: [Int] = []
                quotient.reserveCapacity(decimal.count)
                for digit in decimal {
                    let current = remainder * 10 + digit
                    let q = current / 900
                    remainder = current % 900
                    if !quotient.isEmpty || q != 0 { quotient.append(q) }
                }
                group.append(remainder)
                decimal = quotient.isEmpty ? [0] : quotient
            }
            codewords.append(contentsOf: group.reversed())
            index += length
        }
    }

    // MARK: Hochebenen-Kodierung

    private static func consecutiveDigits(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        return index - start
    }

    /// Anzahl text-kompaktierbarer Bytes ab `start`, endet vor einer Ziffernfolge ≥ 13.
    private static func consecutiveText(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            var digits = 0
            while digits < 13 && index < bytes.count && isDigit(bytes[index]) {
                digits += 1
                index += 1
            }
            if digits >= 13 { return index - start - digits }
            if digits > 0 { continue }
            if !isText(bytes[index]) { break }
            index += 1
        }
        return index - start
    }

    /// Anzahl der Bytes ab `start`, die byte-kompaktiert werden sollten (bis zu einer
    /// Ziffernfolge ≥ 13 oder einer Textfolge ≥ 5).
    private static func consecutiveBinary(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            var digits = 0
            while digits < 13 && index + digits < bytes.count && isDigit(bytes[index + digits]) { digits += 1 }
            if digits >= 13 { return index - start }
            var text = 0
            while text < 5 && index + text < bytes.count && isText(bytes[index + text]) { text += 1 }
            if text >= 5 { return index - start }
            index += 1
        }
        return index - start
    }

    /// Erzeugt die Datencodewörter (ohne Längenangabe, Füllzeichen und Fehlerkorrektur).
    static func highLevelEncode(_ bytes: [UInt8]) -> [Int] {
        enum Compaction { case text, byte, numeric }
        var codewords: [Int] = []
        var compaction = Compaction.text
        var text = TextState()
        var position = 0
        while position < bytes.count {
            let digits = consecutiveDigits(bytes, from: position)
            if digits >= 13 {
                text.flush(into: &codewords, beforeByteShift: false)
                codewords.append(latchNumeric)
                compaction = .numeric
                text.submode = .alpha
                appendNumeric(bytes[position..<(position + digits)], to: &codewords)
                position += digits
                continue
            }
            let textCount = consecutiveText(bytes, from: position)
            // Text lohnt sich ab 5 Zeichen, im Textmodus immer, und am Datenende (Latch ≤ Byte-Kosten).
            if textCount >= 5 || (textCount > 0 && (compaction == .text || position + textCount == bytes.count)) {
                if compaction != .text {
                    codewords.append(latchText)
                    compaction = .text
                    text.submode = .alpha
                }
                text.append(bytes[position..<(position + textCount)])
                position += textCount
                continue
            }
            var binaryCount = consecutiveBinary(bytes, from: position)
            if binaryCount == 0 { binaryCount = 1 }
            if binaryCount == 1 && compaction == .text {
                text.flush(into: &codewords, beforeByteShift: true)
                codewords.append(shiftByte)
                codewords.append(Int(bytes[position]))
            } else {
                text.flush(into: &codewords, beforeByteShift: false)
                appendBytes(bytes[position..<(position + binaryCount)], to: &codewords)
                compaction = .byte
                text.submode = .alpha
            }
            position += binaryCount
        }
        text.flush(into: &codewords, beforeByteShift: false)
        return codewords
    }

    // MARK: Fehlerkorrektur über GF(929)

    /// Koeffizienten des Generatorpolynoms g(x) = ∏_{i=1}^{k} (x − 3^i) mod 929,
    /// niedrigste Potenz zuerst, ohne den führenden Koeffizienten 1.
    static func generatorCoefficients(securityLevel: Int) -> [Int] {
        let k = 1 << (securityLevel + 1)
        var poly = [1]  // niedrigste Potenz zuerst
        var root = 1
        for _ in 0..<k {
            root = root * 3 % 929
            var next = [Int](repeating: 0, count: poly.count + 1)
            for (j, coefficient) in poly.enumerated() {
                next[j + 1] = (next[j + 1] + coefficient) % 929
                next[j] = (next[j] + (929 - root) * coefficient) % 929
            }
            poly = next
        }
        return Array(poly.dropLast())
    }

    /// Fehlerkorrektur-Codewörter (ISO/IEC 15438, Anhang A).
    static func errorCorrection(_ data: [Int], securityLevel: Int) -> [Int] {
        let a = generatorCoefficients(securityLevel: securityLevel)
        let k = a.count
        var e = [Int](repeating: 0, count: k)
        for d in data {
            let t1 = (d + e[k - 1]) % 929
            for j in stride(from: k - 1, through: 1, by: -1) {
                let t2 = (t1 * a[j]) % 929
                let t3 = 929 - t2
                e[j] = (e[j - 1] + t3) % 929
            }
            let t2 = (t1 * a[0]) % 929
            e[0] = (929 - t2) % 929
        }
        return e.reversed().map { $0 == 0 ? 0 : 929 - $0 }
    }

    // MARK: Abmessungen

    struct Dimensions: Equatable {
        var rows: Int
        var columns: Int
    }

    /// Höchstzahl der Codewörter eines Symbols (Zeilen × Spalten, inklusive Fehlerkorrektur).
    static let maximumCodewords = 928

    /// Bestimmt Zeilen und Spalten für `totalCodewords` (Längenangabe + Daten + Fehlerkorrektur).
    static func dimensions(totalCodewords: Int, options: PDF417Options) throws -> Dimensions {
        func rowsFor(_ columns: Int) -> Int { max(3, (totalCodewords + columns - 1) / columns) }
        if options.columns > 0 && options.rows > 0 {
            guard options.columns * options.rows >= totalCodewords else { throw BarcodeError.dataTooLong }
            guard options.columns * options.rows <= maximumCodewords else {
                throw BarcodeError.unsupported("PDF417: Zeilen × Spalten darf höchstens \(maximumCodewords) betragen.")
            }
            return Dimensions(rows: options.rows, columns: options.columns)
        }
        if options.columns > 0 {
            let rows = rowsFor(options.columns)
            guard rows <= 90, rows * options.columns <= maximumCodewords else { throw BarcodeError.dataTooLong }
            return Dimensions(rows: rows, columns: options.columns)
        }
        if options.rows > 0 {
            let columns = max(1, (totalCodewords + options.rows - 1) / options.rows)
            guard columns <= 30 else { throw BarcodeError.dataTooLong }
            guard columns * options.rows <= maximumCodewords else {
                throw BarcodeError.unsupported("PDF417: Zeilen × Spalten darf höchstens \(maximumCodewords) betragen.")
            }
            return Dimensions(rows: options.rows, columns: columns)
        }
        // Automatisch: physisches Seitenverhältnis (Breite : Höhe) möglichst nahe 3 : 1.
        let rowHeight = Double(max(1, options.rowHeight))
        var best: Dimensions?
        var bestScore = Double.infinity
        for columns in 1...30 {
            let rows = rowsFor(columns)
            guard rows <= 90, rows * columns <= maximumCodewords else { continue }
            let width = Double(17 * columns + (options.compact ? 35 : 69))
            let height = Double(rows) * rowHeight
            let score = abs(width / height - 3.0) + Double(rows * columns - totalCodewords) * 0.001
            if score < bestScore {
                bestScore = score
                best = Dimensions(rows: rows, columns: columns)
            }
        }
        guard let best else { throw BarcodeError.dataTooLong }
        return best
    }

    // MARK: Einstiegspunkt

    static func encode(bytes: [UInt8], options: PDF417Options) throws -> BitMatrix {
        guard !bytes.isEmpty else { throw BarcodeError.invalidLength(0) }
        guard (0...8).contains(options.securityLevel) else {
            throw BarcodeError.unsupported("PDF417: Sicherheitsstufe \(options.securityLevel) existiert nicht (0–8).")
        }
        guard options.columns == 0 || (1...30).contains(options.columns) else {
            throw BarcodeError.unsupported("PDF417: \(options.columns) Spalten sind unzulässig (1–30).")
        }
        guard options.rows == 0 || (3...90).contains(options.rows) else {
            throw BarcodeError.unsupported("PDF417: \(options.rows) Zeilen sind unzulässig (3–90).")
        }
        guard options.rowHeight >= 1 else {
            throw BarcodeError.unsupported("PDF417: Die Zeilenhöhe muss mindestens 1 Modul betragen.")
        }

        let payload = highLevelEncode(bytes)
        let eccCount = 1 << (options.securityLevel + 1)
        let needed = 1 + payload.count + eccCount
        guard needed <= maximumCodewords else { throw BarcodeError.dataTooLong }
        let dims = try dimensions(totalCodewords: needed, options: options)
        let capacity = dims.rows * dims.columns

        // Daten: Längenangabe + Nutzdaten + Füllzeichen; danach Fehlerkorrektur.
        var data = [capacity - eccCount] + payload
        data.append(contentsOf: repeatElement(padding, count: capacity - needed))
        let codewords = data + errorCorrection(data, securityLevel: options.securityLevel)

        return matrix(codewords: codewords, dimensions: dims, options: options)
    }

    /// Setzt Start-/Stoppmuster, Zeilenindikatoren und Datencodewörter zur Matrix zusammen.
    static func matrix(codewords: [Int], dimensions: Dimensions, options: PDF417Options) -> BitMatrix {
        let rows = dimensions.rows
        let columns = dimensions.columns
        let level = options.securityLevel
        let width = 17 * columns + (options.compact ? 35 : 69)
        let rowHeight = options.rowHeight
        var matrix = BitMatrix(width: width, height: rows * rowHeight)

        for row in 0..<rows {
            let cluster = row % 3
            let base = 30 * (row / 3)
            let rowIndicator = base + (rows - 1) / 3
            let levelIndicator = base + level * 3 + (rows - 1) % 3
            let columnIndicator = base + (columns - 1)
            let left: Int
            let right: Int
            switch cluster {
            case 0: left = rowIndicator; right = columnIndicator
            case 1: left = levelIndicator; right = rowIndicator
            default: left = columnIndicator; right = levelIndicator
            }

            var modules: [Bool] = []
            modules.reserveCapacity(width)
            func appendCodeword(_ value: Int) {
                let pattern = clusterTables[cluster][value]
                for bit in stride(from: 16, through: 0, by: -1) { modules.append((pattern >> UInt32(bit)) & 1 == 1) }
            }
            modules.append(contentsOf: startPattern)
            appendCodeword(left)
            for column in 0..<columns { appendCodeword(codewords[row * columns + column]) }
            if options.compact {
                modules.append(true)
            } else {
                appendCodeword(right)
                modules.append(contentsOf: stopPattern)
            }
            precondition(modules.count == width)

            for y in (row * rowHeight)..<((row + 1) * rowHeight) {
                matrix.bits.replaceSubrange((y * width)..<((y + 1) * width), with: modules)
            }
        }
        return matrix
    }
}

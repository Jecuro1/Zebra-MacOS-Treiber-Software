import Foundation
import Testing
@testable import LabelWerkBarcode

/// Unabhängiger PDF417-Leser (Muster → Codewörter → Bytes) nach ISO/IEC 15438, nur für Tests.
enum PDF417TestDecoder {

    static let mixed: [Character] = Array("0123456789&\r\t,:#-.$/+%*=^")
    static let punctuation: [Character] = Array(";<>@[\\]_`~!\r\t,:\n-.$/\"|*()?{}'")

    /// Dekodiert die Datencodewörter nach der Längenangabe (ohne Füllzeichen 900 am Ende).
    static func decode(_ data: [Int]) -> [UInt8]? {
        enum Sub { case alpha, lower, mixed, punctuation }
        var out: [UInt8] = []
        var sub = Sub.alpha
        var shift: Sub?
        var i = 0
        func emit(_ c: Character) { out.append(c.asciiValue!) }
        func process(_ v: Int) -> Bool {
            let current = shift ?? sub
            let wasShift = shift != nil
            shift = nil
            switch current {
            case .alpha:
                if v < 26 { out.append(UInt8(65 + v)) } else if v == 26 { out.append(32) }
                else if wasShift { return false }
                else if v == 27 { sub = .lower } else if v == 28 { sub = .mixed } else { shift = .punctuation }
            case .lower:
                if v < 26 { out.append(UInt8(97 + v)) } else if v == 26 { out.append(32) }
                else if v == 27 { shift = .alpha } else if v == 28 { sub = .mixed } else { shift = .punctuation }
            case .mixed:
                if v < 25 { emit(mixed[v]) } else if v == 25 { sub = .punctuation } else if v == 26 { out.append(32) }
                else if v == 27 { sub = .lower } else if v == 28 { sub = .alpha } else { shift = .punctuation }
            case .punctuation:
                if v < 29 { emit(punctuation[v]) } else if wasShift { /* Füllwert */ } else { sub = .alpha }
            }
            return true
        }
        while i < data.count {
            let cw = data[i]
            switch cw {
            case 900:
                sub = .alpha
                shift = nil
                i += 1
            case 901, 924:
                i += 1
                var run: [Int] = []
                while i < data.count && data[i] < 900 { run.append(data[i]); i += 1 }
                var k = 0
                while cw == 924 ? k + 5 <= run.count : k + 5 < run.count {
                    var value: UInt64 = 0
                    for c in run[k..<(k + 5)] { value = value * 900 + UInt64(c) }
                    for shiftBits in stride(from: 40, through: 0, by: -8) { out.append(UInt8(value >> UInt64(shiftBits) & 0xFF)) }
                    k += 5
                }
                if cw == 924 && k != run.count { return nil }
                for c in run[k...] { guard c < 256 else { return nil }; out.append(UInt8(c)) }
                shift = nil
                sub = .alpha
            case 902:
                i += 1
                var run: [Int] = []
                while i < data.count && data[i] < 900 { run.append(data[i]); i += 1 }
                var k = 0
                while k < run.count {
                    var decimal = [0]  // Dezimalziffern, höchstwertige zuerst
                    for c in run[k..<min(k + 15, run.count)] {
                        var carry = c
                        for index in stride(from: decimal.count - 1, through: 0, by: -1) {
                            let product = decimal[index] * 900 + carry
                            decimal[index] = product % 10
                            carry = product / 10
                        }
                        while carry > 0 { decimal.insert(carry % 10, at: 0); carry /= 10 }
                    }
                    while decimal.first == 0 && decimal.count > 1 { decimal.removeFirst() }
                    guard decimal.first == 1 else { return nil }
                    out.append(contentsOf: decimal.dropFirst().map { UInt8(48 + $0) })
                    k += 15
                }
                shift = nil
                sub = .alpha
            case 913:
                guard i + 1 < data.count, data[i + 1] < 256 else { return nil }
                if shift == .punctuation { shift = nil }  // ps-Füllwert vor dem Shift verfällt
                out.append(UInt8(data[i + 1]))
                i += 2
            default:
                guard cw < 900 else { return nil }
                guard process(cw / 30), process(cw % 30) else { return nil }
                i += 1
            }
        }
        return out
    }

    /// Liest eine Symbolmatrix zurück: Codewörter je Zeile samt Zeilenindikatoren.
    static func read(_ matrix: BitMatrix, rowHeight: Int, compact: Bool) -> (rows: [[Int]], left: [Int], right: [Int])? {
        var lookup: [[UInt32: Int]] = [[:], [:], [:]]
        for cluster in 0..<3 {
            for (value, pattern) in PDF417.clusterTables[cluster].enumerated() { lookup[cluster][pattern] = value }
        }
        let width = matrix.width
        let columns = (width - (compact ? 35 : 69)) / 17
        guard (width - (compact ? 35 : 69)) % 17 == 0, matrix.height % rowHeight == 0 else { return nil }
        var rows: [[Int]] = []
        var left: [Int] = []
        var right: [Int] = []
        for row in 0..<(matrix.height / rowHeight) {
            let y = row * rowHeight
            // Alle Zeilen einer Symbolzeile identisch
            for dy in 1..<rowHeight {
                for x in 0..<width where matrix[x, y] != matrix[x, y + dy] { return nil }
            }
            func codeword(at x: Int) -> Int? {
                var pattern: UInt32 = 0
                for k in 0..<17 { pattern = pattern << 1 | (matrix[x + k, y] ? 1 : 0) }
                return lookup[row % 3][pattern]
            }
            let start = (0..<17).map { matrix[$0, y] }
            guard start == PDF417.startPattern else { return nil }
            guard let l = codeword(at: 17) else { return nil }
            left.append(l)
            var data: [Int] = []
            for c in 0..<columns {
                guard let value = codeword(at: 34 + 17 * c) else { return nil }
                data.append(value)
            }
            rows.append(data)
            if compact {
                guard matrix[width - 1, y] else { return nil }
            } else {
                guard let r = codeword(at: 34 + 17 * columns) else { return nil }
                right.append(r)
                guard (0..<18).map({ matrix[width - 18 + $0, y] }) == PDF417.stopPattern else { return nil }
            }
        }
        return (rows, left, right)
    }

    /// Wertet das Codewort-Polynom an 3^1 … 3^k über GF(929) aus (muss jeweils 0 ergeben).
    static func syndromesVanish(_ codewords: [Int], eccCount: Int) -> Bool {
        var root = 1
        for _ in 0..<eccCount {
            root = root * 3 % 929
            var value = 0
            for c in codewords { value = (value * root + c) % 929 }
            if value != 0 { return false }
        }
        return true
    }
}

@Suite("PDF417")
struct PDF417Tests {

    @Test("Clustertabellen: 3 × 929 gültige, eindeutige Muster mit korrekter Clusternummer")
    func clusterTables() {
        #expect(PDF417.clusterTables.count == 3)
        var all = Set<UInt32>()
        for (cluster, table) in PDF417.clusterTables.enumerated() {
            #expect(table.count == 929)
            for pattern in table {
                all.insert(pattern)
                var widths: [Int] = []
                var current = true
                var run = 0
                for bit in stride(from: 16, through: 0, by: -1) {
                    let dark = (pattern >> UInt32(bit)) & 1 == 1
                    if dark == current { run += 1 } else { widths.append(run); current = dark; run = 1 }
                }
                widths.append(run)
                #expect(widths.count == 8 && widths.allSatisfy { (1...6).contains($0) } && widths.reduce(0, +) == 17)
                #expect((widths[0] - widths[2] + widths[4] - widths[6] + 9) % 9 == cluster * 3)
            }
        }
        #expect(all.count == 3 * 929)
        // Stichproben aus ISO/IEC 15438 (Codewort 0 je Cluster)
        #expect(PDF417.clusterTables[0][0] == 0x1D5C0)
        #expect(PDF417.clusterTables[1][0] == 0x1F560)
        #expect(PDF417.clusterTables[2][0] == 0x1ABE0)
    }

    @Test("ISO-Beispiel: „PDF417“ → 453 178 121 239, Stufe 1 → 452 327 657 619")
    func isoTextExample() throws {
        #expect(PDF417.highLevelEncode(Array("PDF417".utf8)) == [453, 178, 121, 239])
        #expect(PDF417.errorCorrection([5, 453, 178, 121, 239], securityLevel: 1) == [452, 327, 657, 619])
        // Vollständiges Symbol mit einer Spalte: genau diese 9 Codewörter
        let matrix = try BarcodeEncoder.pdf417("PDF417", options: PDF417Options(columns: 1, securityLevel: 1))
        let read = try #require(PDF417TestDecoder.read(matrix, rowHeight: 3, compact: false))
        #expect(read.rows.flatMap { $0 } == [5, 453, 178, 121, 239, 452, 327, 657, 619])
    }

    @Test("ISO-Beispiel numerische Kompaktierung: 000213298174000 → 1 624 434 632 282 200")
    func isoNumericExample() {
        #expect(PDF417.highLevelEncode(Array("000213298174000".utf8)) == [902, 1, 624, 434, 632, 282, 200])
        // 45 Ziffern: Gruppe zu 44 (15 Codewörter) + Rest
        let encoded = PDF417.highLevelEncode(Array(String(repeating: "9", count: 45).utf8))
        #expect(encoded.first == 902 && encoded.count == 1 + 15 + 1)
        #expect(PDF417TestDecoder.decode(encoded) == Array(String(repeating: "9", count: 45).utf8))
    }

    @Test("Generatorpolynome für Stufe 0, 1, 2 (Referenzwerte)")
    func generatorPolynomials() {
        #expect(PDF417.generatorCoefficients(securityLevel: 0) == [27, 917])
        #expect(PDF417.generatorCoefficients(securityLevel: 1) == [522, 568, 723, 809])
        #expect(PDF417.generatorCoefficients(securityLevel: 2) == [237, 308, 436, 284, 646, 653, 428, 379])
        #expect(PDF417.generatorCoefficients(securityLevel: 8).count == 512)
    }

    @Test("Byte-Kompaktierung: 924 bei Vielfachen von 6, sonst 901")
    func byteCompaction() {
        #expect(PDF417.highLevelEncode([1, 2, 3, 4, 5, 6]) == [924, 1, 620, 89, 74, 846])
        #expect(PDF417.highLevelEncode([1, 2, 3, 4, 5, 6, 7]) == [901, 1, 620, 89, 74, 846, 7])
        #expect(PDF417.highLevelEncode([255, 255, 255, 255, 255, 255]) == [924, 429, 11, 71, 222, 855])
    }

    @Test("Text-Kompaktierung: Teilmodi, Shift, Latch und Einzelbyte-Shift")
    func textCompaction() {
        // Lower → Upper: Einzelzeichen per as, Folgen per ml + al
        #expect(PDF417.highLevelEncode(Array("abCd".utf8)) == [810, 57, 63])
        #expect(PDF417.highLevelEncode(Array("abcDEF".utf8)) == [810, 32, 868, 94, 179])
        // Mixed → Punctuation-Latch bei mehreren Satzzeichen
        #expect(PDF417.highLevelEncode(Array("1;<".utf8)) == [841, 750, 59])
        // Einzelbyte im Text: ungerader Rest wird mit ml statt ps aufgefüllt, danach 913
        #expect(PDF417.highLevelEncode(Array("ABCDE".utf8) + [0] + Array("FGHIJ".utf8)) == [1, 63, 148, 913, 0, 845, 187, 249])
    }

    @Test("Rundreise mit unabhängigem Decoder", arguments: 0..<6)
    func roundTrip(alphabetIndex: Int) {
        let alphabets: [[UInt8]] = [
            Array(32...126), Array(48...57), Array(65...90) + Array(97...122) + [32],
            Array(32...126) + [9, 10, 13] + Array(48...57) + Array(48...57), Array(0...255), [0, 1, 65, 97, 49, 59, 255],
        ]
        var random = TestSupport.Random(seed: UInt64(417 + alphabetIndex))
        for _ in 0..<200 {
            let alphabet = alphabets[alphabetIndex]
            var bytes = (0..<random.int(1...150)).map { _ in alphabet[random.int(0...(alphabet.count - 1))] }
            if random.int(0...3) == 0 { bytes += Array(repeating: UInt8(ascii: "7"), count: random.int(13...60)) }
            let encoded = PDF417.highLevelEncode(bytes)
            #expect(encoded.allSatisfy { (0...928).contains($0) })
            #expect(PDF417TestDecoder.decode(encoded) == bytes, "\(bytes)")
        }
    }

    @Test("Symbol: Zeilenindikatoren, Längenangabe, Reed-Solomon und Inhalt", arguments: [
        (0, 0, false), (2, 1, false), (5, 4, false), (8, 12, false), (3, 30, false), (4, 3, true), (1, 0, true),
    ])
    func symbolReadBack(level: Int, columns: Int, compact: Bool) throws {
        var random = TestSupport.Random(seed: UInt64(level * 100 + columns))
        let bytes = (0..<random.int(20...180)).map { _ in UInt8(random.int(0...255)) }
        let options = PDF417Options(columns: columns, securityLevel: level, rowHeight: 2, compact: compact)
        let matrix = try BarcodeEncoder.pdf417(bytes: bytes, options: options)
        let read = try #require(PDF417TestDecoder.read(matrix, rowHeight: 2, compact: compact))
        let rows = read.rows.count
        let cols = read.rows[0].count
        if columns > 0 { #expect(cols == columns) }
        #expect(matrix.width == 17 * cols + (compact ? 35 : 69))
        #expect(matrix.height == rows * 2)

        // Zeilenindikatoren wie ein Decoder auswerten: Zeilen, Spalten, Stufe
        #expect(3 * (read.left[0] % 30) + (read.left[1] % 30) % 3 + 1 == rows)
        #expect((read.left[1] % 30) / 3 == level)
        #expect(read.left[2] % 30 + 1 == cols)
        for row in 0..<rows {
            let base = 30 * (row / 3)
            #expect(read.left[row] / 30 * 30 == base)
            if !compact {
                let expectedRight: Int
                switch row % 3 {
                case 0: expectedRight = base + cols - 1
                case 1: expectedRight = base + (rows - 1) / 3
                default: expectedRight = base + level * 3 + (rows - 1) % 3
                }
                #expect(read.right[row] == expectedRight)
            }
        }

        let codewords = read.rows.flatMap { $0 }
        let eccCount = 1 << (level + 1)
        #expect(PDF417TestDecoder.syndromesVanish(codewords, eccCount: eccCount))
        let length = codewords[0]
        #expect(length == codewords.count - eccCount)
        var data = Array(codewords[1..<length])
        while data.last == 900 { data.removeLast() }
        #expect(PDF417TestDecoder.decode(data) == bytes)
    }

    @Test("Abmessungen: automatisch ≈ 3 : 1, feste Spalten/Zeilen, Grenzen")
    func dimensions() throws {
        #expect(try PDF417.dimensions(totalCodewords: 100, options: PDF417Options()) == .init(rows: 17, columns: 6))
        #expect(try PDF417.dimensions(totalCodewords: 10, options: PDF417Options(columns: 5)) == .init(rows: 3, columns: 5))
        #expect(try PDF417.dimensions(totalCodewords: 100, options: PDF417Options(rows: 10)) == .init(rows: 10, columns: 10))
        #expect(throws: BarcodeError.dataTooLong) { try PDF417.dimensions(totalCodewords: 100, options: PDF417Options(columns: 1)) }
        #expect(throws: BarcodeError.dataTooLong) { try PDF417.dimensions(totalCodewords: 928, options: PDF417Options(columns: 30)) }
        #expect(throws: BarcodeError.self) { try PDF417.dimensions(totalCodewords: 10, options: PDF417Options(columns: 30, rows: 90)) }
        #expect(try PDF417.dimensions(totalCodewords: 928, options: PDF417Options(columns: 29)) == .init(rows: 32, columns: 29))
    }

    @Test("Fehler und Grenzen der Parameter")
    func errors() {
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.pdf417("") }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.pdf417("x", securityLevel: 9) }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.pdf417("x", columns: 31) }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.pdf417("x", options: PDF417Options(rows: 2)) }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.pdf417("x", options: PDF417Options(rowHeight: 0)) }
        #expect(throws: BarcodeError.dataTooLong) { try BarcodeEncoder.pdf417(bytes: [UInt8](repeating: 0xAB, count: 1200)) }
        #expect(throws: BarcodeError.dataTooLong) { try BarcodeEncoder.pdf417(String(repeating: "x", count: 400), columns: 1) }
        // Maximal: 1100 Bytes bei Stufe 0 passen (924 + 5/6 · 1100 ≈ 918 Codewörter)
        #expect(throws: Never.self) { try BarcodeEncoder.pdf417(bytes: [UInt8](repeating: 0xAB, count: 1098), options: PDF417Options(securityLevel: 0)) }
    }

    @Test("Zeilenhöhe und Kompaktform")
    func rowHeightAndCompact() throws {
        let standard = try BarcodeEncoder.pdf417("LabelWerk", columns: 2)
        #expect(standard.width == 17 * 2 + 69)
        #expect(standard.height % 3 == 0)
        let compact = try BarcodeEncoder.pdf417("LabelWerk", options: PDF417Options(columns: 2, rowHeight: 1, compact: true))
        #expect(compact.width == 17 * 2 + 35)
        #expect(compact.height * 3 == standard.height)
    }

    @Test("Goldene Fingerabdrücke (Symbole mit zxing-cpp verifiziert)")
    func golden() throws {
        #expect(TestSupport.fingerprint(try BarcodeEncoder.pdf417("LabelWerk PDF417 Test 1234567890123")) == "0x5575021E08C8B626")
        #expect(TestSupport.fingerprint(try BarcodeEncoder.pdf417(String(repeating: "abcXYZ-0815 ", count: 10), columns: 30, securityLevel: 8)) == "0xABFACD75F3AF7F58")
        #expect(TestSupport.fingerprint(try BarcodeEncoder.pdf417("Kompakt", options: PDF417Options(columns: 2, securityLevel: 3, rowHeight: 2, compact: true))) == "0x1C1E31BD03894C7C")
    }
}

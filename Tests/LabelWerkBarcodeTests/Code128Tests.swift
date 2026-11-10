import Foundation
import Testing
@testable import LabelWerkBarcode

@Suite("Code 128")
struct Code128Tests {

    @Test("Mustertabelle: 107 eindeutige Muster, 11 bzw. 13 Module, gerade Balkensumme")
    func patternTable() {
        #expect(Code128.patterns.count == 107)
        #expect(Set(Code128.patterns).count == 107)
        for (value, pattern) in Code128.patterns.enumerated() {
            let isStop = value == 106
            #expect(pattern.count == (isStop ? 7 : 6))
            #expect(pattern.reduce(0, +) == (isStop ? 13 : 11))
            #expect(pattern.allSatisfy { (1...4).contains($0) })
            let bars = stride(from: 0, to: pattern.count, by: 2).map { pattern[$0] }.reduce(0, +)
            #expect(bars % 2 == 0, "Paritätsregel verletzt bei \(value)")
        }
        #expect(Code128.patterns[104] == [2, 1, 1, 2, 1, 4])  // Start B
        #expect(Code128.patterns[105] == [2, 1, 1, 2, 3, 2])  // Start C
    }

    @Test("Bekanntes Beispiel „Wikipedia“: Start B, Symbolwerte und Prüfzeichen 88")
    func wikipedia() throws {
        let barcode = try BarcodeEncoder.code128("Wikipedia")
        let values = try #require(TestSupport.code128Values(barcode))
        #expect(values == [104, 55, 73, 75, 73, 80, 69, 68, 73, 65, 88, 106])
        #expect(barcode.moduleCount == 11 * 11 + 13)
        #expect(barcode.humanReadable == "Wikipedia")
        #expect(!barcode.isTwoWidth)
        #expect(barcode.elements.first?.isBar == true && barcode.elements.last?.isBar == true)
    }

    @Test("Ziffernfolgen nutzen Zeichensatz C, ungerade Folgen optimal")
    func digitRuns() throws {
        #expect(try Code128.symbolValues(for: Code128.tokens(from: "12345678"), allowedSets: [.b, .c, .a]) == [105, 12, 34, 56, 78])
        // 9 Ziffern: Start + 4 Paare + Wechsel + Einzelziffer = 7 Symbolzeichen (statt 10 in B)
        let odd = try Code128.symbolValues(for: Code128.tokens(from: "123456789"), allowedSets: [.b, .c, .a])
        #expect(odd.count == 7)
        #expect(TestSupport.interpretCode128(odd) == "123456789")
        // Mitten im Text: "AB" + 6 Ziffern + "CD" → C lohnt sich (10 statt 11 Zeichen)
        let mixed = try Code128.symbolValues(for: Code128.tokens(from: "AB123456CD"), allowedSets: [.b, .c, .a])
        #expect(mixed == [104, 33, 34, 99, 12, 34, 56, 100, 35, 36])
        // Nur 3 Ziffern: Wechsel lohnt nicht
        #expect(try Code128.symbolValues(for: Code128.tokens(from: "A123"), allowedSets: [.b, .c, .a]) == [104, 33, 17, 18, 19])
    }

    @Test("Steuerzeichen: SHIFT für Einzelzeichen, Zeichensatz A für Folgen")
    func controlCharacters() throws {
        let single = try Code128.symbolValues(for: Code128.tokens(from: "ab\tcd"), allowedSets: [.b, .c, .a])
        #expect(single == [104, 65, 66, 98, 73, 67, 68])
        let run = try Code128.symbolValues(for: Code128.tokens(from: "\t\r\n\u{0}"), allowedSets: [.b, .c, .a])
        #expect(run == [103, 73, 77, 74, 64])
    }

    @Test("ISO-8859-1-Zeichen über FNC4")
    func extendedCharacters() throws {
        let values = try Code128.symbolValues(for: Code128.tokens(from: "aé"), allowedSets: [.b, .c, .a])
        #expect(values == [104, 65, 100, 73])  // é = 0xE9 → FNC4 + 'i'
        #expect(throws: BarcodeError.invalidCharacter("€")) { try BarcodeEncoder.code128("1€") }
    }

    @Test("Automatikmodus: Rundreise und Minimalität bei Zufallsdaten")
    func randomRoundTrip() throws {
        var random = TestSupport.Random(seed: 128)
        let alphabets: [[Unicode.Scalar]] = [
            TestSupport.scalars(32...126), TestSupport.scalars(48...57), TestSupport.scalars(0...127),
            TestSupport.scalars(48...57) + TestSupport.scalars(65...70), TestSupport.scalars(0...255),
        ]
        for round in 0..<400 {
            let text = random.string(from: alphabets[round % alphabets.count], length: random.int(1...40))
            let barcode = try BarcodeEncoder.code128(text)
            let values = try #require(TestSupport.code128Values(barcode))
            #expect(values[values.count - 2] == Code128.checksum(Array(values.dropLast(2))))
            #expect(TestSupport.interpretCode128(Array(values.dropLast(2))) == text)
            // Nie länger als reine B-Kodierung mit SHIFT/FNC4 (Obergrenze 1 + 3 je Zeichen)
            #expect(values.count - 3 <= 1 + 3 * text.unicodeScalars.count)
        }
    }

    @Test("Minimalität: dynamische Programmierung entspricht erschöpfender Suche")
    func exhaustiveOptimality() throws {
        // Für kurze Texte aus einem kleinen Alphabet alle Zeichensatzfolgen per Breitensuche prüfen.
        let alphabet: [Unicode.Scalar] = ["1", "2", "a", "\t", "A"]
        var random = TestSupport.Random(seed: 7)
        for _ in 0..<150 {
            let text = random.string(from: alphabet, length: random.int(1...8))
            let tokens = try Code128.tokens(from: text)
            let dp = try Code128.symbolValues(for: tokens, allowedSets: [.b, .c, .a])
            #expect(dp.count == bruteForceLength(tokens), "Text \(text.debugDescription)")
            #expect(TestSupport.interpretCode128(dp) == text)
        }
    }

    /// Kürzeste Länge per Dijkstra über (Position, Zeichensatz) – unabhängig vom Encoder.
    private func bruteForceLength(_ tokens: [Code128.Token]) -> Int {
        var best = [[Int]](repeating: [Int](repeating: Int.max, count: 3), count: tokens.count + 1)
        var queue: [(Int, Int, Int)] = [(0, 0, 1), (0, 1, 1), (0, 2, 1)]
        while let current = queue.min(by: { $0.2 < $1.2 }) {
            queue.removeAll { $0 == current }
            let (position, set, cost) = current
            guard cost < best[position][set] else { continue }
            best[position][set] = cost
            if position == tokens.count { continue }
            for other in 0..<3 where other != set { queue.append((position, other, cost + 1)) }
            guard case .byte(let byte) = tokens[position] else { continue }
            if set == 2 {
                if position + 1 < tokens.count, tokens[position].isDigit, tokens[position + 1].isDigit {
                    queue.append((position + 2, 2, cost + 1))
                }
            } else {
                let inA = byte < 96
                let inB = byte >= 32 && byte < 128
                if (set == 0 && inA) || (set == 1 && inB) { queue.append((position + 1, set, cost + 1)) }
                else { queue.append((position + 1, set, cost + 2)) }  // SHIFT
            }
        }
        return best[tokens.count].min()!
    }

    @Test("Feste Zeichensätze")
    func forcedSubsets() throws {
        let a = try BarcodeEncoder.code128("AB\t", mode: .subsetA)
        #expect(TestSupport.code128Values(a)?.prefix(4) == [103, 33, 34, 73])
        let aShift = try Code128.symbolValues(for: Code128.tokens(from: "AbC"), allowedSets: [.a])
        #expect(aShift == [103, 33, 98, 66, 35])
        let b = try BarcodeEncoder.code128("1234", mode: .subsetB)
        #expect(TestSupport.code128Values(b)?.prefix(5) == [104, 17, 18, 19, 20])
        let c = try BarcodeEncoder.code128("123456", mode: .subsetC)
        #expect(TestSupport.code128Values(c)?.prefix(4) == [105, 12, 34, 56])
        #expect(throws: BarcodeError.invalidLength(3)) { try BarcodeEncoder.code128("123", mode: .subsetC) }
        #expect(throws: BarcodeError.invalidCharacter("A")) { try BarcodeEncoder.code128("12A4", mode: .subsetC) }
        #expect(throws: BarcodeError.invalidCharacter("á")) { try BarcodeEncoder.code128("á", mode: .subsetA) }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.code128("") }
    }

    @Test("GS1-128: FNC1, Datenbezeichner, Trennzeichen nur nach variablen Feldern")
    func gs1() throws {
        let barcode = try BarcodeEncoder.code128("(01)09501101530003(17)140704(10)AB-123", mode: .ucc)
        #expect(barcode.humanReadable == "(01)09501101530003(17)140704(10)AB-123")
        let values = try #require(TestSupport.code128Values(barcode))
        // Start C, FNC1, 01 09 50 11 01 53 00 03 | 17 14 07 04 | 10, dann „AB-123“ (optimal: 6 Zeichen)
        #expect(Array(values.prefix(15)) == [105, 102, 1, 9, 50, 11, 1, 53, 0, 3, 17, 14, 7, 4, 10])
        #expect(values.count - 2 == 22)
        #expect(TestSupport.interpretCode128(Array(values.dropLast(2))) == "01095011015300031714070410AB-123")

        // Variables Feld (10) vor einem weiteren Feld → FNC1 als Trenner
        let separated = try BarcodeEncoder.code128("(10)ABC(21)XYZ", mode: .ucc)
        let text = TestSupport.interpretCode128(Array(try #require(TestSupport.code128Values(separated)).dropLast(2)))
        #expect(text == "10ABC\u{1D}21XYZ")

        // Prüfziffer für GTIN wird ergänzt, eckige Klammern und Rohform werden akzeptiert
        #expect(try BarcodeEncoder.code128("[01]0950110153000", mode: .ucc).humanReadable == "(01)09501101530003")
        #expect(try BarcodeEncoder.code128("(00)34000123456789012", mode: .ucc).humanReadable == "(00)340001234567890125")
        let raw = try BarcodeEncoder.code128("0109501101530003\u{1D}10ABC", mode: .ucc)
        #expect(raw.humanReadable == "0109501101530003" + "10ABC")
        #expect(TestSupport.interpretCode128(Array(try #require(TestSupport.code128Values(raw)).dropLast(2))) == "0109501101530003\u{1D}10ABC")

        #expect(throws: BarcodeError.invalidCharacter("A")) { try BarcodeEncoder.code128("(0A)123", mode: .ucc) }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.code128("(10)", mode: .ucc) }
        #expect(throws: BarcodeError.invalidLength(1)) { try BarcodeEncoder.code128("(1)23", mode: .ucc) }
        #expect(throws: BarcodeError.invalidCharacter("é")) { try BarcodeEncoder.code128("(10)é", mode: .ucc) }
    }

    @Test("GS1-Prüfziffern: SSCC und GTIN")
    func gs1CheckDigits() {
        #expect(GS1.completeCheckDigit(ai: "01", data: "0950110153000") == "09501101530003")
        #expect(GS1.completeCheckDigit(ai: "00", data: "34000123456789012") == "340001234567890125")
        #expect(GS1.completeCheckDigit(ai: "01", data: "09501101530003") == "09501101530003")
        #expect(GS1.completeCheckDigit(ai: "10", data: "123") == "123")
    }

    @Test("Symbolwerte direkt (ZPL-Aufrufcodes)")
    func explicitValues() throws {
        let barcode = try BarcodeEncoder.code128(symbolValues: [105, 12, 34], humanReadable: "1234")
        #expect(TestSupport.code128Values(barcode) == [105, 12, 34, Code128.checksum([105, 12, 34]), 106])
        #expect(barcode.humanReadable == "1234")
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.code128(symbolValues: [12, 34], humanReadable: "") }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.code128(symbolValues: [104, 103], humanReadable: "") }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.code128(symbolValues: [104], humanReadable: "") }
    }
}

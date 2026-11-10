import Foundation
import Testing
@testable import LabelWerkBarcode

@Suite("Code 39 und Code 93")
struct Code39And93Tests {

    /// Liest Code-39-Zeichen aus den Elementen zurück (9 Elemente je Zeichen + schmale Lücke).
    private func readCode39(_ barcode: LinearBarcode) -> String? {
        var result = ""
        var index = 0
        let elements = barcode.elements
        while index + 9 <= elements.count {
            var pattern: UInt16 = 0
            for element in elements[index..<(index + 9)] { pattern = pattern << 1 | (element.width == 2 ? 1 : 0) }
            if pattern == Code39.startStop {
                result.append("*")
            } else if let value = Code39.patterns.firstIndex(of: pattern) {
                result.append(Code39.alphabet[value])
            } else {
                return nil
            }
            index += 9
            if index < elements.count {
                guard !elements[index].isBar, elements[index].width == 1 else { return nil }
                index += 1
            }
        }
        return index == elements.count ? result : nil
    }

    @Test("Mustertabelle: genau 3 von 9 Elementen breit, alle verschieden")
    func code39Table() {
        let all = Code39.patterns + [Code39.startStop]
        #expect(all.count == 44 && Set(all).count == 44)
        for pattern in all { #expect(pattern.nonzeroBitCount == 3 && pattern < 512) }
    }

    @Test("Code 39 mit Modulo-43-Prüfziffer: CODE39 → W")
    func code39CheckDigit() throws {
        let barcode = try BarcodeEncoder.code39("CODE39", checkDigit: true)
        #expect(barcode.humanReadable == "*CODE39W*")
        #expect(barcode.isTwoWidth)
        #expect(readCode39(barcode) == "*CODE39W*")
        // 9 Symbolzeichen (* C O D E 3 9 W *) zu je 9 Elementen, dazwischen 8 schmale Lücken
        #expect(barcode.elements.count == 9 * 9 + 8)
        #expect(barcode.elements.filter { $0.width == 2 }.count == 9 * 3)
        // Breite bei Verhältnis 3: je Zeichen 6 schmale + 3 breite (= 15 Module) + Lücke
        #expect(barcode.totalWidth(moduleWidth: 1, ratio: 3) == 9 * 15 + 8)
    }

    @Test("Code 39 ohne Prüfziffer und Full ASCII")
    func code39Variants() throws {
        #expect(readCode39(try BarcodeEncoder.code39("A-1 $")) == "*A-1 $*")
        let full = try BarcodeEncoder.code39("Code!", fullASCII: true)
        #expect(readCode39(full) == "*C+O+D+E/A*")
        #expect(full.humanReadable == "*Code!*")
        // $ % + / werden in Full ASCII escaped
        #expect(readCode39(try BarcodeEncoder.code39("$/", fullASCII: true)) == "*/D/O*")
        #expect(readCode39(try BarcodeEncoder.code39("\u{0}\u{7F}@`", fullASCII: true)) == "*%U%T%V%W*")
        // Prüfziffer über die Symbolzeichen: "+A" → (41 + 10) mod 43 = 8
        #expect(try BarcodeEncoder.code39("a", checkDigit: true, fullASCII: true).humanReadable == "*a8*")
    }

    @Test("Code 39: Fehler")
    func code39Errors() {
        #expect(throws: BarcodeError.invalidCharacter("a")) { try BarcodeEncoder.code39("abc") }
        #expect(throws: BarcodeError.invalidCharacter("*")) { try BarcodeEncoder.code39("A*B") }
        #expect(throws: BarcodeError.invalidCharacter("é")) { try BarcodeEncoder.code39("é", fullASCII: true) }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.code39("") }
    }

    @Test("Full-ASCII-Tabelle deckt ASCII 0…127 eindeutig ab")
    func fullASCIITable() {
        var seen = Set<String>()
        for code in UInt8(0)...127 {
            let encoded = Code39.fullASCII(code)
            #expect(encoded.allSatisfy { Code39.valueOf[$0] != nil })
            #expect(seen.insert(encoded).inserted, "doppelt: \(code)")
        }
    }

    /// Liest Code-93-Werte (9 Module je Zeichen) zurück.
    private func readCode93(_ barcode: LinearBarcode) -> [Int]? {
        let modules = barcode.modules
        guard (modules.count - 1) % 9 == 0, modules.last == true else { return nil }
        var values: [Int] = []
        for start in stride(from: 0, to: modules.count - 1, by: 9) {
            var pattern: UInt16 = 0
            for bit in modules[start..<(start + 9)] { pattern = pattern << 1 | (bit ? 1 : 0) }
            guard let value = Code93.patterns.firstIndex(of: pattern) else { return nil }
            values.append(value)
        }
        return values
    }

    @Test("Code 93: TEST93 mit Prüfzeichen C = '+' und K = '6'")
    func code93Known() throws {
        let barcode = try BarcodeEncoder.code93("TEST93")
        #expect(readCode93(barcode) == [47, 29, 14, 28, 29, 9, 3, 41, 6, 47])
        #expect(barcode.moduleCount == (6 + 4) * 9 + 1)
        #expect(barcode.humanReadable == "TEST93")
        #expect(barcode.elements.allSatisfy { (1...4).contains($0.width) })
    }

    @Test("Code 93: Muster 9 Module, je 3 Balken und 3 Lücken")
    func code93Table() {
        #expect(Code93.patterns.count == 48 && Set(Code93.patterns).count == 48)
        for pattern in Code93.patterns {
            let elements = Code93.elements(for: pattern)
            #expect(elements.count == 6 && elements.reduce(0) { $0 + $1.width } == 9)
            #expect(elements.first?.isBar == true)
        }
    }

    @Test("Code 93: Full ASCII über Umschaltzeichen, Grundzeichen direkt")
    func code93FullASCII() throws {
        #expect(try Code93.values(for: "a") == [46, 10])          // (+)A
        #expect(try Code93.values(for: "$%/+") == [39, 42, 40, 41])  // direkt
        #expect(try Code93.values(for: "\u{0}!") == [44, 30, 45, 10])  // (%)U (/)A
        #expect(throws: BarcodeError.invalidCharacter("ü")) { try BarcodeEncoder.code93("ü") }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.code93("") }
    }
}

@Suite("EAN und UPC")
struct EANUPCTests {

    @Test("EAN-13 400638133393 → Prüfziffer 1, exakte Modulfolge")
    func ean13Known() throws {
        let barcode = try BarcodeEncoder.ean13("400638133393")
        #expect(barcode.humanReadable == "4006381333931")
        let expected = "101" + "0001101" + "0100111" + "0101111" + "0111101" + "0001001" + "0110011" + "01010"
            + "1000010" + "1000010" + "1000010" + "1110100" + "1000010" + "1100110" + "101"
        #expect(TestSupport.moduleString(barcode) == expected)
        #expect(barcode.moduleCount == 95)
        // Begrenzungszeichen: 3 + 5 + 3 Elemente
        #expect(barcode.elements.filter(\.isGuard).count == 11)
        #expect(try BarcodeEncoder.ean13("4006381333931") == barcode)
    }

    @Test("EAN-8 9638507 → 96385074")
    func ean8Known() throws {
        let barcode = try BarcodeEncoder.ean8("9638507")
        #expect(barcode.humanReadable == "96385074")
        let expected = "101" + "0001011" + "0101111" + "0111101" + "0110111" + "01010"
            + "1001110" + "1110010" + "1000100" + "1011100" + "101"
        #expect(TestSupport.moduleString(barcode) == expected)
    }

    @Test("UPC-A 03600029145 → 036000291452")
    func upcAKnown() throws {
        let barcode = try BarcodeEncoder.upcA("03600029145")
        #expect(barcode.humanReadable == "036000291452")
        let expected = "101" + "0001101" + "0111101" + "0101111" + "0001101" + "0001101" + "0001101" + "01010"
            + "1101100" + "1110100" + "1100110" + "1011100" + "1001110" + "1101100" + "101"
        #expect(TestSupport.moduleString(barcode) == expected)
    }

    @Test("UPC-E 0425261 → 04252614 (Expansion für die Prüfziffer)")
    func upcEKnown() throws {
        let barcode = try BarcodeEncoder.upcE("0425261")
        #expect(barcode.humanReadable == "04252614")
        let expected = "101" + "0011101" + "0010011" + "0111001" + "0011011" + "0101111" + "0011001" + "010101"
        #expect(TestSupport.moduleString(barcode) == expected)
        #expect(barcode.moduleCount == 51)
        #expect(try BarcodeEncoder.upcE("425261") == barcode)
        #expect(try BarcodeEncoder.upcE("04252614") == barcode)
        #expect(try BarcodeEncoder.upcE("042100005264") == barcode)  // komprimierbares UPC-A
        #expect(try BarcodeEncoder.upcE("04210000526") == barcode)
        #expect(EANUPC.expandUPCE(numberSystem: 0, [4, 2, 5, 2, 6, 1]) == [0, 4, 2, 1, 0, 0, 0, 0, 5, 2, 6])
    }

    @Test("UPC-E Nummernsystem 1 kehrt die Parität um")
    func upcENumberSystem1() throws {
        let ns0 = try BarcodeEncoder.upcE("0123457")
        let ns1 = try BarcodeEncoder.upcE("1123457")
        #expect(ns0.humanReadable.first == "0" && ns1.humanReadable.first == "1")
        #expect(ns0 != ns1)
    }

    @Test("UPC-E: Expansionsregeln und Kompression sind zueinander invers")
    func upcEExpansionRules() {
        #expect(EANUPC.expandUPCE(numberSystem: 0, [1, 2, 3, 4, 5, 0]) == [0, 1, 2, 0, 0, 0, 0, 0, 3, 4, 5])
        #expect(EANUPC.expandUPCE(numberSystem: 0, [1, 2, 3, 4, 5, 3]) == [0, 1, 2, 3, 0, 0, 0, 0, 0, 4, 5])
        #expect(EANUPC.expandUPCE(numberSystem: 1, [1, 2, 3, 4, 5, 4]) == [1, 1, 2, 3, 4, 0, 0, 0, 0, 0, 5])
        #expect(EANUPC.expandUPCE(numberSystem: 0, [1, 2, 3, 4, 5, 9]) == [0, 1, 2, 3, 4, 5, 0, 0, 0, 0, 9])
        var random = TestSupport.Random(seed: 6)
        for _ in 0..<300 {
            let e = (0..<6).map { _ in random.int(0...9) }
            let upcA = EANUPC.expandUPCE(numberSystem: random.int(0...1), e)
            let compressed = EANUPC.compressUPCA(upcA)
            #expect(compressed != nil)
            #expect(compressed.map { EANUPC.expandUPCE(numberSystem: upcA[0], $0) } == upcA)
        }
        #expect(EANUPC.compressUPCA([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0]) == nil)
    }

    @Test("Zeichensätze A/B/C: B = gespiegeltes C, C = Komplement von A")
    func characterSets() {
        for digit in 0..<10 {
            #expect(EANUPC.setC[digit] == ~EANUPC.setA[digit] & 0x7F)
            #expect(EANUPC.setB[digit] == EANUPC.reverse7(EANUPC.setC[digit]))
            #expect(EANUPC.setA[digit] & 0x40 == 0 && EANUPC.setA[digit] & 1 == 1)  // L beginnt hell, endet dunkel
        }
    }

    @Test("EAN/UPC: Fehler")
    func errors() {
        #expect(throws: BarcodeError.invalidCharacter("2")) { try BarcodeEncoder.ean13("4006381333932") }
        #expect(throws: BarcodeError.invalidLength(11)) { try BarcodeEncoder.ean13("40063813339") }
        #expect(throws: BarcodeError.invalidCharacter("A")) { try BarcodeEncoder.ean13("40063813339A") }
        #expect(throws: BarcodeError.invalidLength(9)) { try BarcodeEncoder.ean8("123456789") }
        #expect(throws: BarcodeError.invalidCharacter("3")) { try BarcodeEncoder.upcA("036000291453") }
        #expect(throws: BarcodeError.invalidCharacter("2")) { try BarcodeEncoder.upcE("2425261") }
        #expect(throws: BarcodeError.invalidCharacter("5")) { try BarcodeEncoder.upcE("04252615") }
        #expect(throws: BarcodeError.invalidLength(5)) { try BarcodeEncoder.upcE("12345") }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.upcE("036000291452") }  // nicht komprimierbar
    }
}

@Suite("Interleaved 2 of 5 und Codabar")
struct TwoWidthCodesTests {

    @Test("ITF: Start, verschachtelte Paare, Stopp")
    func itfStructure() throws {
        let barcode = try BarcodeEncoder.interleaved2of5("12")
        #expect(barcode.elements.map(\.width) == [1, 1, 1, 1, 2, 1, 1, 2, 1, 1, 1, 1, 2, 2, 2, 1, 1])
        #expect(barcode.isTwoWidth)
        #expect(barcode.humanReadable == "12")
    }

    @Test("ITF: Auffüllen mit führender 0 und Prüfziffer")
    func itfPaddingAndCheck() throws {
        #expect(try BarcodeEncoder.interleaved2of5("1234567").humanReadable == "01234567")
        #expect(try BarcodeEncoder.interleaved2of5("1234567", checkDigit: true).humanReadable == "12345670")
        #expect(try BarcodeEncoder.interleaved2of5("123456", checkDigit: true).humanReadable == "01234565")
        let barcode = try BarcodeEncoder.interleaved2of5("12345678")
        #expect(barcode.elements.count == 4 + 4 * 10 + 3)
        #expect(barcode.elements.filter { $0.width == 2 }.count == 8 * 2 + 1)
        #expect(throws: BarcodeError.invalidCharacter("A")) { try BarcodeEncoder.interleaved2of5("12A") }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.interleaved2of5("") }
    }

    @Test("ITF-Muster: genau 2 von 5 breit")
    func itfTable() {
        #expect(Set(Interleaved2of5.patterns).count == 10)
        for pattern in Interleaved2of5.patterns { #expect(pattern.nonzeroBitCount == 2) }
    }

    @Test("Codabar: Start/Stopp, Zeichenmuster, Lücken")
    func codabar() throws {
        let barcode = try BarcodeEncoder.codabar("40156", start: "A", stop: "B")
        #expect(barcode.humanReadable == "A40156B")
        #expect(barcode.elements.count == 7 * 7 + 6)
        #expect(Array(barcode.elements.prefix(8).map(\.width)) == [1, 1, 2, 2, 1, 2, 1, 1])  // A + Lücke
        #expect(barcode.isTwoWidth)
        #expect(try BarcodeEncoder.codabar("1", start: "t", stop: "*").humanReadable == "A1C")
        #expect(try BarcodeEncoder.codabar("1", start: "n", stop: "e").humanReadable == "B1D")
        #expect(throws: BarcodeError.invalidCharacter("X")) { try BarcodeEncoder.codabar("1", start: "X") }
        #expect(throws: BarcodeError.invalidCharacter("A")) { try BarcodeEncoder.codabar("1A2") }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.codabar("") }
    }

    @Test("Codabar-Muster: Ziffern/–/$ zwei, übrige drei breite Elemente")
    func codabarTable() {
        #expect(Set(Codabar.patterns).count == 20)
        for (index, pattern) in Codabar.patterns.enumerated() {
            #expect(pattern.nonzeroBitCount == (index < 12 ? 2 : 3), "\(Codabar.alphabet[index])")
        }
    }
}

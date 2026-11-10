import Foundation
import Testing
@testable import LabelWerkBarcode

/// Unabhängiger Decoder für Data-Matrix-Datencodewörter nach ISO/IEC 16022 (nur für Tests).
enum DataMatrixTestDecoder {

    static func unrandomize255(_ value: UInt8, position: Int) -> UInt8 {
        let temp = Int(value) - ((149 * position) % 255 + 1)
        return UInt8(temp >= 0 ? temp : temp + 256)
    }

    /// Dekodiert Datencodewörter (inklusive Füllzeichen) zu Bytes; `nil` bei ungültiger Folge.
    static func decode(_ cw: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var i = 0
        let n = cw.count
        var upperShift = false
        func emit(_ value: Int) {
            out.append(UInt8(value + (upperShift ? 128 : 0)))
            upperShift = false
        }
        while i < n {
            let c = Int(cw[i])
            i += 1
            switch c {
            case 1...128:
                emit(c - 1)
            case 129:
                return out
            case 130...229:
                emit(48 + (c - 130) / 10)
                emit(48 + (c - 130) % 10)
            case 230, 239:
                let text = c == 239
                var shift = 0
                while i < n {
                    if n - i == 1 { break }  // ein einzelnes Codewort am Ende ist ASCII
                    if cw[i] == 254 { i += 1; break }
                    let packed = Int(cw[i]) * 256 + Int(cw[i + 1]) - 1
                    i += 2
                    for v in [packed / 1600, (packed / 40) % 40, packed % 40] {
                        switch shift {
                        case 0:
                            if v < 3 { shift = v + 1 } else if v == 3 { emit(32) } else if v < 14 { emit(48 + v - 4) } else { emit((text ? 97 : 65) + v - 14) }
                        case 1:
                            emit(v)
                            shift = 0
                        case 2:
                            if v < 15 { emit(33 + v) } else if v < 22 { emit(58 + v - 15) } else if v < 27 { emit(91 + v - 22) } else if v == 30 { upperShift = true } else { return nil }
                            shift = 0
                        default:
                            if v == 0 { emit(96) } else if v < 27 { emit((text ? 65 : 97) + v - 1) } else { emit(123 + v - 27) }
                            shift = 0
                        }
                    }
                }
            case 238:
                while i < n {
                    if n - i == 1 { break }
                    if cw[i] == 254 { i += 1; break }
                    let packed = Int(cw[i]) * 256 + Int(cw[i + 1]) - 1
                    i += 2
                    for v in [packed / 1600, (packed / 40) % 40, packed % 40] {
                        switch v {
                        case 0: emit(13)
                        case 1: emit(42)
                        case 2: emit(62)
                        case 3: emit(32)
                        case 4...13: emit(48 + v - 4)
                        default: emit(65 + v - 14)
                        }
                    }
                }
            case 240:
                var bitPosition = i * 8
                func readValue() -> Int {
                    var value = 0
                    for _ in 0..<6 {
                        let bit = (cw[bitPosition / 8] >> UInt8(7 - bitPosition % 8)) & 1
                        value = value << 1 | Int(bit)
                        bitPosition += 1
                    }
                    return value
                }
                edifact: while true {
                    // Gruppenbeginn: höchstens 2 verbleibende Codewörter → ASCII
                    if n - bitPosition / 8 <= 2 { break }
                    for _ in 0..<4 {
                        let value = readValue()
                        if value == 31 {
                            bitPosition = (bitPosition + 7) / 8 * 8
                            break edifact
                        }
                        emit(value < 32 ? value + 64 : value)
                    }
                }
                i = bitPosition / 8
            case 231:
                var length = Int(unrandomize255(cw[i], position: i + 1))
                i += 1
                if length == 0 {
                    length = n - i
                } else if length > 249 {
                    length = 250 * (length - 249) + Int(unrandomize255(cw[i], position: i + 1))
                    i += 1
                }
                guard i + length <= n else { return nil }
                for _ in 0..<length {
                    emit(Int(unrandomize255(cw[i], position: i + 1)))
                    i += 1
                }
            case 235:
                upperShift = true
            default:
                return nil
            }
        }
        return out
    }
}

@Suite("Data Matrix")
struct DataMatrixTests {

    @Test("ISO-Beispiel 123456: Daten 142 164 186, Fehlerkorrektur 114 25 5 88 102")
    func knownExample() throws {
        let encoded = try DataMatrix.encodeData(Array("123456".utf8))
        #expect(encoded.codewords == [142, 164, 186])
        let size = try #require(DataMatrix.smallestSize(for: 3, shape: .square))
        #expect(size.rows == 10)
        #expect(DataMatrix.addErrorCorrection(encoded.codewords, size: size) == [142, 164, 186, 114, 25, 5, 88, 102])
    }

    @Test("Symboltabelle: Geometrie, Kapazität und Blockaufteilung stimmig")
    func sizeTable() {
        #expect(DataMatrix.sizes.count == 30)
        #expect(DataMatrix.sizes.filter(\.isSquare).count == 24)
        for size in DataMatrix.sizes {
            #expect(size.rows == size.verticalRegions * (size.regionRows + 2))
            #expect(size.columns == size.horizontalRegions * (size.regionColumns + 2))
            let spare = size.mappingRows * size.mappingColumns - 8 * (size.dataCodewords + size.errorCodewords)
            #expect(spare == 0 || spare == 4, "\(size.rows)x\(size.columns)")
            #expect(size.errorCodewords % size.blocks == 0)
            let dataSum = (0..<size.blocks).reduce(0) { $0 + size.dataCodewords(inBlock: $1) }
            #expect(dataSum == size.dataCodewords)
        }
    }

    @Test("Platzierung: jedes Codewort-Bit genau einmal, Eckmodule nur bei 4 Restbits")
    func placement() {
        for size in DataMatrix.sizes {
            let placement = DataMatrix.Placement(rows: size.mappingRows, columns: size.mappingColumns)
            let total = 8 * (size.dataCodewords + size.errorCodewords)
            let assigned = placement.cells.filter { $0 >= 0 }
            #expect(assigned.count == total && Set(assigned) == Set(0..<total), "\(size.rows)x\(size.columns)")
            let fixed = placement.cells.filter { $0 < 0 }.count
            #expect(fixed == size.mappingRows * size.mappingColumns - total)
        }
    }

    @Test("Füllzeichen: 129, danach 253-Zustands-randomisiert")
    func padding() throws {
        let (size, data) = try DataMatrix.finalize(try DataMatrix.encodeData(Array("A".utf8)), options: DataMatrixOptions())
        #expect(size.rows == 10)
        #expect(data == [66, 129, 70])
        var long: [UInt8] = [66]
        DataMatrix.pad(&long, to: 6)
        #expect(long == [66, 129, 70, 220, 115, 11])
    }

    @Test("Kodierungsarten: ASCII, Upper Shift, Base 256, C40, Text, X12, EDIFACT")
    func encodations() throws {
        #expect(try DataMatrix.encodeData([0xE9]).codewords == [235, 106])
        let base256 = try DataMatrix.encodeData(Array(0x80...0x8F))
        #expect(base256.encodations == [.base256])
        #expect(Array(base256.codewords.prefix(2)) == [231, 60])
        #expect(base256.codewords.count == 18)

        let c40 = try DataMatrix.encodeData(Array("ABCDEFGHI".utf8))
        #expect(c40.encodations == [.c40])
        #expect(Array(c40.codewords.prefix(3)) == [230, 89, 233])  // A,B,C → 1600·14 + 40·15 + 16 + 1
        #expect(c40.codewords.last == 254)
        let text = try DataMatrix.encodeData(Array("abcdefghi".utf8))
        #expect(text.encodations == [.text] && Array(text.codewords.prefix(3)) == [239, 89, 233])
        let x12 = try DataMatrix.encodeData(Array("AB*CD>EF*".utf8))
        #expect(x12.encodations == [.x12] && x12.codewords.first == 238)
        let edifact = try DataMatrix.encodeData(Array("A.B,C;D:E-F/G".utf8))
        #expect(edifact.encodations.contains(.edifact) && edifact.codewords.first == 240)
        #expect(edifact.codewords.count == 12)
        #expect(try DataMatrix.encodeData(Array("1234567890".utf8)).encodations == [.ascii])
    }

    @Test("C40-/Text-Werte inklusive Shift-Zeichen und Upper Shift")
    func c40Values() {
        #expect(DataMatrix.c40Values(65, text: false) == [14])
        #expect(DataMatrix.c40Values(97, text: false) == [2, 1])
        #expect(DataMatrix.c40Values(97, text: true) == [14])
        #expect(DataMatrix.c40Values(65, text: true) == [2, 1])
        #expect(DataMatrix.c40Values(9, text: false) == [0, 9])
        #expect(DataMatrix.c40Values(UInt8(ascii: "!"), text: false) == [1, 0])
        #expect(DataMatrix.c40Values(UInt8(ascii: "@"), text: false) == [1, 21])
        #expect(DataMatrix.c40Values(UInt8(ascii: "_"), text: false) == [1, 26])
        #expect(DataMatrix.c40Values(127, text: false) == [2, 31])
        #expect(DataMatrix.c40Values(0xC1, text: false) == [1, 30, 14])  // Á = Upper Shift + A
        #expect(DataMatrix.x12Value(13) == 0 && DataMatrix.x12Value(UInt8(ascii: "a")) == nil)
        #expect(DataMatrix.edifactValue(UInt8(ascii: "A")) == 1 && DataMatrix.edifactValue(UInt8(ascii: "a")) == nil)
    }

    @Test("Rundreise mit unabhängigem Decoder über alle Kodierungsarten", arguments: 0..<8)
    func roundTrip(alphabetIndex: Int) throws {
        let alphabets: [[UInt8]] = [
            Array(48...57), Array(65...90) + [32], Array(97...122) + [32], Array(32...94),
            Array(65...90) + [13, 42, 62, 32], Array(1...127), Array(128...255) + Array(65...70),
            Array(0...255),
        ]
        var random = TestSupport.Random(seed: UInt64(1000 + alphabetIndex))
        var used = Set<DataMatrix.Encodation>()
        for _ in 0..<150 {
            let alphabet = alphabets[alphabetIndex]
            let bytes = (0..<random.int(1...120)).map { _ in alphabet[random.int(0...(alphabet.count - 1))] }
            let encoded = try DataMatrix.encodeData(bytes)
            used.formUnion(encoded.encodations)
            // Die Hauptfolge endet im ASCII-Zustand; im Symbol folgt mindestens ein Füllzeichen
            // oder `finalize` ersetzt ein abschließendes Unlatch (ein einzelnes letztes Codewort
            // wird nach Norm als ASCII gelesen).
            #expect(DataMatrixTestDecoder.decode(encoded.codewords + [DataMatrix.padCodeword]) == bytes, "\(bytes) → \(encoded.codewords)")
            if let alternative = encoded.withoutFinalUnlatch {
                #expect(DataMatrixTestDecoder.decode(alternative) == bytes)
            }
            for shape in DataMatrixShape.allCases {
                let size: DataMatrix.SymbolSize
                let data: [UInt8]
                do {
                    (size, data) = try DataMatrix.finalize(encoded, options: DataMatrixOptions(shape: shape))
                } catch BarcodeError.dataTooLong {
                    #expect(shape == .rectangle && encoded.codewords.count > 49)  // größtes Rechteck: 49
                    continue
                }
                #expect(data.count == size.dataCodewords)
                #expect(DataMatrixTestDecoder.decode(data) == bytes, "Form \(shape)")
                #expect(size.dataCodewords >= encoded.codewords.count - 1)
            }
        }
        #expect(!used.isEmpty)
    }

    @Test("Codewortminimalität: nie schlechter als reines ASCII oder Base 256")
    func neverWorseThanSimpleEncodations() throws {
        var random = TestSupport.Random(seed: 31)
        for _ in 0..<300 {
            let bytes = (0..<random.int(1...80)).map { _ in UInt8(random.int(0...255)) }
            var ascii = 0
            var i = 0
            while i < bytes.count {
                if i + 1 < bytes.count, DataMatrix.isDigit(bytes[i]), DataMatrix.isDigit(bytes[i + 1]) { ascii += 1; i += 2; continue }
                ascii += bytes[i] < 128 ? 1 : 2
                i += 1
            }
            let encoded = try DataMatrix.encodeData(bytes)
            #expect(encoded.codewords.count <= min(ascii, DataMatrix.base256Cost(bytes.count)))
        }
    }

    @Test("Fehlerkorrektur: jeder verschachtelte Block hat Syndrome null (inkl. 144×144)")
    func errorCorrectionBlocks() {
        var random = TestSupport.Random(seed: 144)
        for size in DataMatrix.sizes {
            let data = (0..<size.dataCodewords).map { _ in UInt8(random.int(0...255)) }
            let all = DataMatrix.addErrorCorrection(data, size: size)
            #expect(all.count == size.dataCodewords + size.errorCodewords)
            for block in 0..<size.blocks {
                var codeword: [UInt8] = []
                var i = block
                while i < size.dataCodewords { codeword.append(all[i]); i += size.blocks }
                i = size.dataCodewords + block
                while i < all.count { codeword.append(all[i]); i += size.blocks }
                #expect(TestSupport.hasZeroSyndromes(codeword, field: .dataMatrix, firstRoot: 1, count: size.errorCodewordsPerBlock))
            }
        }
    }

    @Test("Symbolaufbau: Suchmuster je Datenbereich und Rücklesen der Codewörter")
    func symbolStructure() throws {
        for size in DataMatrix.sizes {
            var random = TestSupport.Random(seed: UInt64(size.rows * 1000 + size.columns))
            let codewords = (0..<(size.dataCodewords + size.errorCodewords)).map { _ in UInt8(random.int(0...255)) }
            let matrix = DataMatrix.symbol(codewords: codewords, size: size)
            #expect(matrix.width == size.columns && matrix.height == size.rows)
            let regionHeight = size.regionRows + 2
            let regionWidth = size.regionColumns + 2
            for y in 0..<size.rows {
                for x in 0..<size.columns {
                    let rx = x % regionWidth
                    let ry = y % regionHeight
                    if rx == 0 || ry == regionHeight - 1 { #expect(matrix[x, y], "L-Muster \(x),\(y)") }
                    else if ry == 0 { #expect(matrix[x, y] == (rx % 2 == 0)) }
                    else if rx == regionWidth - 1 { #expect(matrix[x, y] == (ry % 2 == 1)) }
                }
            }
            // Datenmodule zurücklesen
            let placement = DataMatrix.Placement(rows: size.mappingRows, columns: size.mappingColumns)
            var read = [UInt8](repeating: 0, count: codewords.count)
            for row in 0..<size.mappingRows {
                for column in 0..<size.mappingColumns {
                    let cell = placement.cells[row * size.mappingColumns + column]
                    guard cell >= 0 else { continue }
                    let x = column / size.regionColumns * regionWidth + 1 + column % size.regionColumns
                    let y = row / size.regionRows * regionHeight + 1 + row % size.regionRows
                    if matrix[x, y] { read[cell / 8] |= 0x80 >> UInt8(cell % 8) }
                }
            }
            #expect(read == codewords)
        }
    }

    @Test("Größenwahl: quadratisch, rechteckig, beliebig, feste Größe")
    func sizeSelection() throws {
        #expect(DataMatrix.smallestSize(for: 3, shape: .square)?.rows == 10)
        #expect(DataMatrix.smallestSize(for: 4, shape: .square)?.rows == 12)
        #expect(DataMatrix.smallestSize(for: 1558, shape: .square)?.rows == 144)
        #expect(DataMatrix.smallestSize(for: 1559, shape: .square) == nil)
        #expect(DataMatrix.smallestSize(for: 10, shape: .rectangle).map { "\($0.rows)x\($0.columns)" } == "8x32")
        #expect(DataMatrix.smallestSize(for: 50, shape: .rectangle) == nil)
        #expect(DataMatrix.smallestSize(for: 6, shape: .any).map { "\($0.rows)x\($0.columns)" } == "14x14")

        let rectangle = try BarcodeEncoder.dataMatrix("12345678901234567890", shape: .rectangle)
        #expect(rectangle.height == 8 && rectangle.width == 32)
        let fixed = try BarcodeEncoder.dataMatrix("A", options: DataMatrixOptions(rows: 24, columns: 24))
        #expect(fixed.width == 24)
        let fixedRows = try BarcodeEncoder.dataMatrix("A", options: DataMatrixOptions(rows: 16, columns: 0))
        #expect(fixedRows.height == 16 && fixedRows.width == 16)
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.dataMatrix("A", options: DataMatrixOptions(rows: 25, columns: 25)) }
        #expect(throws: BarcodeError.dataTooLong) {
            try BarcodeEncoder.dataMatrix(String(repeating: "1", count: 30), options: DataMatrixOptions(rows: 10, columns: 10))
        }
        #expect(throws: BarcodeError.dataTooLong) { try BarcodeEncoder.dataMatrix(String(repeating: "1", count: 3117)) }
        #expect(throws: BarcodeError.dataTooLong) { try BarcodeEncoder.dataMatrix(bytes: [UInt8](repeating: 0xC4, count: 20_000)) }
        #expect(try BarcodeEncoder.dataMatrix(String(repeating: "1", count: 3116)).width == 144)
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.dataMatrix("") }
        #expect(try BarcodeEncoder.dataMatrix(bytes: [0, 255, 128]).width == 12)
    }

    @Test("Randregeln: Unlatch am Symbolende, implizites Unlatch, EDIFACT-Restgruppe")
    func endOfSymbolRules() throws {
        // Unlatch genau auf dem letzten Codewort wird durch 129 ersetzt.
        let encoded = try DataMatrix.encodeData(Array("ABCDEFGHI".utf8))  // 230 + 6 + 254 = 8 Codewörter
        let (size, data) = try DataMatrix.finalize(encoded, options: DataMatrixOptions())
        #expect(size.dataCodewords == 8 && data.last == 129 && !data.contains(254))
        #expect(DataMatrixTestDecoder.decode(data) == Array("ABCDEFGHI".utf8))

        // C40 ohne Unlatch, wenn das Symbol damit exakt gefüllt ist (5 Codewörter → 12×12).
        let six = try DataMatrix.encodeData(Array("ABCDEF".utf8))
        let alternative = try #require(six.withoutFinalUnlatch)
        #expect(alternative.count == 5)
        let (sixSize, sixData) = try DataMatrix.finalize(six, options: DataMatrixOptions())
        #expect(sixSize.rows == 12 && sixData == alternative)

        // EDIFACT: Beginnt die letzte Gruppe weniger als 3 Codewörter vor dem Symbolende, liest ein
        // Decoder sie als ASCII – es muss ein größeres Symbol gewählt werden.
        let synthetic = DataMatrix.EncodedData(codewords: [240, 4, 32, 124], encodations: [.edifact], endsWithUnlatch: false,
                                               lastEdifactGroupStart: 3, withoutFinalUnlatch: nil)
        let (edifactSize, edifactData) = try DataMatrix.finalize(synthetic, options: DataMatrixOptions())
        #expect(edifactSize.dataCodewords - 3 >= 3)
        #expect(edifactSize.rows == 14 && Array(edifactData.prefix(5)) == [240, 4, 32, 124, 129])
        // Satzzeichenlastige Daten: EDIFACT (0,75 Codewörter je Zeichen) schlägt ASCII und C40.
        let real = try DataMatrix.encodeData(Array(".,;:.,;:.,;:.,;:".utf8))
        #expect(real.encodations.contains(.edifact) && real.codewords.count == 14)
        let (_, realData) = try DataMatrix.finalize(real, options: DataMatrixOptions())
        #expect(DataMatrixTestDecoder.decode(realData) == Array(".,;:.,;:.,;:.,;:".utf8))
    }

    @Test("Goldene Matrizen (mit zxing-cpp verifiziert, 123456 bitgleich mit dem zxing-cpp-Writer)")
    func goldenMatrices() throws {
        #expect(try BarcodeEncoder.dataMatrix("123456").description == """
            #.#.#.#.#.
            ##..#.##.#
            ##.....#..
            ##...###.#
            ##....#...
            #.....####
            ###.##....
            ####.##..#
            #..###.#..
            ##########
            """)
        #expect(try BarcodeEncoder.dataMatrix("ABC", shape: .rectangle).description == """
            #.#.#.#.#.#.#.#.#.
            #.##.....#.####..#
            #....#..##........
            #.####..######..##
            #....##.###.###...
            #...#.#.##.#..#.##
            ###.....#...#...#.
            ##################
            """)
        #expect(TestSupport.fingerprint(try BarcodeEncoder.dataMatrix("LabelWerk")) == "0xF69D2F5951E79197")
        let digits = String((0..<3116).map { Character(String($0 % 10)) })
        #expect(TestSupport.fingerprint(try BarcodeEncoder.dataMatrix(digits)) == "0xF3E1483283ECBF73")
        #expect(TestSupport.fingerprint(try BarcodeEncoder.dataMatrix(String(repeating: "ZEBRA LABEL ", count: 25))) == "0xD1908EE1A78885F7")
        #expect(TestSupport.fingerprint(try BarcodeEncoder.dataMatrix("Charge: A-1234/56 • Menge 10 Stk. ÄÖÜ")) == "0x5393B58CDBC48BCD")
    }
}

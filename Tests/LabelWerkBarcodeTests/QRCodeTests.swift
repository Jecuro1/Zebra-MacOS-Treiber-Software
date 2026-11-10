import Foundation
import Testing
@testable import LabelWerkBarcode

@Suite("QR-Code")
struct QRCodeTests {

    @Test("HELLO WORLD 1-Q: Daten- und Fehlerkorrektur-Codewörter (Thonky-Tutorial)")
    func helloWorldCodewords() throws {
        let (version, data) = try QRCode.dataCodewords(for: "HELLO WORLD", level: .quartile)
        #expect(version == 1)
        #expect(data == [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236])
        let all = QRCode.addErrorCorrectionAndInterleave(data, version: 1, level: .quartile)
        #expect(Array(all.suffix(13)) == [168, 72, 22, 82, 217, 54, 156, 0, 46, 15, 180, 122, 16])
    }

    @Test("Mehrblock-Verschachtelung 5-Q (Thonky): Blocklängen 15/15/16/16")
    func interleaving() {
        // 5-Q: 2 Blöcke à 15 und 2 Blöcke à 16 Datencodewörter, je 18 Fehlerkorrektur-Codewörter.
        #expect(QRCode.dataCodewords(version: 5, level: .quartile) == 62)
        let data = (0..<62).map { UInt8($0) }
        let all = QRCode.addErrorCorrectionAndInterleave(data, version: 5, level: .quartile)
        #expect(all.count == QRCode.totalCodewords(version: 5))
        #expect(Array(all.prefix(8)) == [0, 15, 30, 46, 1, 16, 31, 47])
        // Nach 15 Runden nur noch die langen Blöcke
        #expect(Array(all[60..<62]) == [45, 61])
    }

    @Test("Kapazitäten (Datencodewörter) nach ISO/IEC 18004, Tabelle 7")
    func capacities() {
        #expect(QRCode.dataCodewords(version: 1, level: .low) == 19)
        #expect(QRCode.dataCodewords(version: 1, level: .high) == 9)
        #expect(QRCode.dataCodewords(version: 10, level: .medium) == 216)
        #expect(QRCode.dataCodewords(version: 40, level: .low) == 2956)
        #expect(QRCode.dataCodewords(version: 40, level: .high) == 1276)
        #expect(QRCode.totalCodewords(version: 7) == 196)
        #expect(QRCode.totalCodewords(version: 40) == 3706)
        // Konsistenz: Blöcke teilen die Codewörter so, dass höchstens 1 Byte Unterschied besteht
        for version in 1...40 {
            for level in QRErrorCorrection.allCases {
                let ord = QRCode.ordinal(level)
                let blocks = QRCode.errorCorrectionBlocks[ord][version]
                let short = QRCode.totalCodewords(version: version) / blocks - QRCode.eccCodewordsPerBlock[ord][version]
                #expect(short > 0)
            }
        }
    }

    @Test("Format-Information: Referenzwerte und BCH-Eigenschaft für alle 32 Kombinationen")
    func formatInformation() {
        #expect(QRCode.formatInformation(level: .low, mask: 0) == 0x77C4)
        #expect(QRCode.formatInformation(level: .medium, mask: 0) == 0x5412)
        #expect(QRCode.formatInformation(level: .quartile, mask: 0) == 0x355F)
        #expect(QRCode.formatInformation(level: .high, mask: 0) == 0x1689)
        #expect(QRCode.formatInformation(level: .medium, mask: 5) == 0x40CE)
        for level in QRErrorCorrection.allCases {
            for mask in 0..<8 {
                var value = QRCode.formatInformation(level: level, mask: mask) ^ 0x5412
                // Polynomdivision über GF(2) durch den Generator 0x537 muss aufgehen.
                for bit in stride(from: 14, through: 10, by: -1) where value & (1 << bit) != 0 {
                    value ^= 0x537 << (bit - 10)
                }
                #expect(value == 0)
            }
        }
    }

    @Test("Versions-Information: Referenzwerte (Anhang D)")
    func versionInformation() {
        #expect(QRCode.versionInformation(7) == 0x07C94)
        #expect(QRCode.versionInformation(8) == 0x085BC)
        #expect(QRCode.versionInformation(21) == 0x15683)
        #expect(QRCode.versionInformation(40) == 0x28C69)
    }

    @Test("Ausrichtungsmuster und Rohmodule")
    func geometry() {
        #expect(QRCode.alignmentPatternPositions.count == 41)
        #expect(QRCode.alignmentPatternPositions[7] == [6, 22, 38])
        #expect(QRCode.alignmentPatternPositions[32] == [6, 34, 60, 86, 112, 138])
        for version in 2...40 {
            let positions = QRCode.alignmentPatternPositions[version]
            #expect(positions.count == version / 7 + 2)
            #expect(positions.last == QRCode.size(version: version) - 7)
        }
        #expect(QRCode.rawDataModules(version: 1) == 208)
        #expect(QRCode.rawDataModules(version: 40) == 29648)
    }

    @Test("Segmentierung: optimal zwischen Numerisch, Alphanumerisch und Byte")
    func segmentation() {
        func modes(_ text: String) -> [QRCode.Mode] {
            QRCode.optimalSegments(Array(text.unicodeScalars), version: 1).map(\.mode)
        }
        #expect(modes("0123456789") == [.numeric])
        #expect(modes("HELLO WORLD") == [.alphanumeric])
        #expect(modes("hello") == [.byte])
        #expect(modes("ABC123") == [.alphanumeric])                 // kurze Ziffernfolge lohnt keinen Wechsel
        #expect(modes("abc0123456789012345") == [.byte, .numeric])  // lange Ziffernfolge schon
        #expect(modes("HELLO 0123456789012345678901 WORLD") == [.alphanumeric, .numeric, .alphanumeric])
        let unicode = QRCode.optimalSegments(Array("Ä€".unicodeScalars), version: 1)
        #expect(unicode.count == 1 && unicode[0].characterCount == 5)  // UTF-8: 2 + 3 Bytes
        #expect(QRCode.numericSegment(Array("01234567".utf8)).data.count == 27)
        #expect(QRCode.alphanumericSegment(Array("AC-42".utf8)).data.count == 28)
    }

    @Test("Matrix: Positionsmuster, Taktmuster, dunkles Modul, gültige Format-Information")
    func matrixStructure() throws {
        let matrix = try BarcodeEncoder.qr("LabelWerk", errorCorrection: .medium)
        #expect(matrix.width == 21 && matrix.height == 21)
        let finder = ["#######", "#.....#", "#.###.#", "#.###.#", "#.###.#", "#.....#", "#######"]
        for (dy, row) in finder.enumerated() {
            for (dx, character) in row.enumerated() {
                #expect(matrix[dx, dy] == (character == "#"))
                #expect(matrix[14 + dx, dy] == (character == "#"))
                #expect(matrix[dx, 14 + dy] == (character == "#"))
            }
        }
        for i in 8...12 {
            #expect(matrix[i, 6] == (i % 2 == 0))
            #expect(matrix[6, i] == (i % 2 == 0))
        }
        #expect(matrix[8, 13])  // dunkles Modul
        let format = TestSupport.qrFormatBits(matrix)
        let mask = (0..<8).first { QRCode.formatInformation(level: .medium, mask: $0) == format }
        #expect(mask != nil)
    }

    @Test("Rücklesen: Codewörter aus der Matrix ergeben gültige Reed-Solomon-Blöcke", arguments: [1, 2, 6, 7, 14, 27, 40])
    func readBack(version: Int) throws {
        var random = TestSupport.Random(seed: UInt64(version))
        for level in QRErrorCorrection.allCases {
            let capacity = QRCode.dataCodewords(version: version, level: level)
            let text = random.string(from: TestSupport.scalars(97...122), length: max(1, capacity - 4))
            let mask = random.int(0...7)
            let matrix = try BarcodeEncoder.qr(text, errorCorrection: level, minimumVersion: version, mask: mask)
            #expect(matrix.width == QRCode.size(version: version))
            #expect(TestSupport.qrFormatBits(matrix) == QRCode.formatInformation(level: level, mask: mask))
            let codewords = TestSupport.qrReadCodewords(matrix, version: version, mask: mask)
            #expect(codewords.count == QRCode.totalCodewords(version: version))

            // Entschachteln und jeden Block per Syndrom prüfen.
            let ord = QRCode.ordinal(level)
            let blocks = QRCode.errorCorrectionBlocks[ord][version]
            let ecc = QRCode.eccCodewordsPerBlock[ord][version]
            let total = QRCode.totalCodewords(version: version)
            let shortData = total / blocks - ecc
            let longBlocks = total % blocks
            var blockData = [[UInt8]](repeating: [], count: blocks)
            var index = 0
            for i in 0...shortData {
                for b in 0..<blocks where i < shortData || b >= blocks - longBlocks {
                    blockData[b].append(codewords[index])
                    index += 1
                }
            }
            for _ in 0..<ecc { for b in 0..<blocks { blockData[b].append(codewords[index]); index += 1 } }
            for block in blockData {
                #expect(TestSupport.hasZeroSyndromes(block, field: .qrCode, firstRoot: 0, count: ecc))
            }
            // Byte-Modus-Kopf: 0100 + Zeichenzähler
            let header = Int(blockData[0][0]) >> 4
            #expect(header == 0b0100)
        }
    }

    @Test("Versionswahl, Mindestversion, feste Maske")
    func versionSelection() throws {
        #expect(try BarcodeEncoder.qr("1", errorCorrection: .low).width == 21)
        #expect(try BarcodeEncoder.qr("1", errorCorrection: .low, minimumVersion: 10, mask: nil).width == 57)
        let numeric7089 = String(repeating: "1234567890", count: 709).prefix(7089)
        #expect(try BarcodeEncoder.qr(String(numeric7089), errorCorrection: .low).width == 177)
        #expect(throws: BarcodeError.dataTooLong) { try BarcodeEncoder.qr(String(numeric7089) + "1", errorCorrection: .low) }
        #expect(throws: BarcodeError.dataTooLong) { try BarcodeEncoder.qr(String(repeating: "a", count: 2954), errorCorrection: .low) }
        #expect(try BarcodeEncoder.qr(String(repeating: "a", count: 2953), errorCorrection: .low).width == 177)
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.qr("x", errorCorrection: .low, minimumVersion: 41, mask: nil) }
        #expect(throws: BarcodeError.self) { try BarcodeEncoder.qr("x", errorCorrection: .low, minimumVersion: 1, mask: 8) }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.qr("") }
        // Höhere Fehlerkorrektur → größeres Symbol
        let text = String(repeating: "LabelWerk ", count: 8)
        #expect(try BarcodeEncoder.qr(text, errorCorrection: .high).width > BarcodeEncoder.qr(text, errorCorrection: .low).width)
    }

    @Test("Maskenbewertung: Strafpunkte sind deterministisch und Regel 4 korrekt")
    func penalty() {
        var symbol = QRCode.Symbol(version: 1)
        symbol.modules = [Bool](repeating: true, count: 21 * 21)
        // Komplett dunkel: Regel 1 (2·21 Läufe à 21: je 3 + 16), Regel 2 (20·20 Blöcke), Regel 4 (100 % → 10·10)
        #expect(symbol.penaltyScore() == 42 * 19 + 400 * 3 + 100)
    }

    @Test("Goldene Matrizen (mit zxing-cpp und segno verifiziert)")
    func goldenMatrices() throws {
        let hello = try BarcodeEncoder.qr("HELLO WORLD", errorCorrection: .quartile)
        #expect(hello.description == """
            #######.##....#######
            #.....#.#..#..#.....#
            #.###.#.#..##.#.###.#
            #.###.#.#.....#.###.#
            #.###.#.#.#...#.###.#
            #.....#...#...#.....#
            #######.#.#.#.#######
            ........#............
            .##.#.##....#.#.#####
            .#......####....#...#
            ..##.###.##...#.##...
            .##.##.#..##.#.#.###.
            #...#.#.#.###.###.#.#
            ........##.#..#...#.#
            #######.#.#....#.##..
            #.....#..#.##.##.#...
            #.###.#.#.#...#######
            #.###.#..#.#.#.#...#.
            #.###.#.#..#.###.#..#
            #.....#.#.####...#.##
            #######....#.###....#
            """)
        #expect(TestSupport.fingerprint(try BarcodeEncoder.qr("LabelWerk", errorCorrection: .medium)) == "0x4B80ACB5AFB8B957")
        #expect(TestSupport.fingerprint(try BarcodeEncoder.qr(String(repeating: "LabelWerk 2026 ", count: 9), errorCorrection: .medium)) == "0x76409E432001A0FF")
        let digits = String((0..<7089).map { Character(String($0 % 10)) })
        #expect(TestSupport.fingerprint(try BarcodeEncoder.qr(digits, errorCorrection: .low)) == "0x682B9CC17244B9A0")
        #expect(TestSupport.fingerprint(try BarcodeEncoder.qr("Größe 42 € – 漢字 🙂", errorCorrection: .high)) == "0x750FFDC3E1874FF5")
    }
}

@Suite("Reed-Solomon GF(256)")
struct ReedSolomonTests {

    @Test("Körperarithmetik: α^255 = 1, Inverse, Polynome 0x11D und 0x12D")
    func field() {
        for field in [GaloisField256.qrCode, GaloisField256.dataMatrix] {
            #expect(field.exp[0] == 1 && field.exp[255] == 1)
            #expect(Set(field.exp[0..<255]).count == 255)  // α ist primitiv
            for value in 1...255 {
                let inverse = field.exp[(255 - field.log[value]) % 255]
                #expect(field.multiply(UInt8(value), inverse) == 1)
            }
        }
        #expect(GaloisField256.qrCode.exp[8] == 0x1D)
        #expect(GaloisField256.dataMatrix.exp[8] == 0x2D)
    }

    @Test("Generatorpolynome: QR (Grad 7/10) und Data Matrix (Grad 5, ISO/IEC 16022 Anhang E)")
    func generators() {
        // QR Grad 7: α-Exponenten 87, 229, 146, 149, 238, 102, 21
        let qr7 = GaloisField256.qrCode.generator(degree: 7, firstRoot: 0)
        #expect(qr7.map { GaloisField256.qrCode.log[Int($0)] } == [87, 229, 146, 149, 238, 102, 21])
        let qr10 = GaloisField256.qrCode.generator(degree: 10, firstRoot: 0)
        #expect(qr10.map { GaloisField256.qrCode.log[Int($0)] } == [251, 67, 46, 61, 118, 70, 64, 94, 32, 45])
        #expect(GaloisField256.dataMatrix.generator(degree: 5, firstRoot: 1) == [62, 111, 15, 48, 228])
    }

    @Test("Rest ist ein gültiges Codewort")
    func remainder() {
        let field = GaloisField256.dataMatrix
        var random = TestSupport.Random(seed: 99)
        for degree in [5, 7, 10, 28, 62, 68] {
            let data = (0..<random.int(1...150)).map { _ in UInt8(random.int(0...255)) }
            let ecc = field.errorCorrection(for: data, count: degree, firstRoot: 1)
            #expect(ecc.count == degree)
            #expect(TestSupport.hasZeroSyndromes(data + ecc, field: field, firstRoot: 1, count: degree))
        }
    }
}

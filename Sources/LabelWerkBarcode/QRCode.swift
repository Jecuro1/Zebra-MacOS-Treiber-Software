import Foundation

/// QR-Code Modell 2 (ISO/IEC 18004), Versionen 1–40, Fehlerkorrekturstufen L/M/Q/H.
///
/// Ablauf:
/// 1. Optimale Segmentierung des Textes in Numerisch/Alphanumerisch/Byte (UTF-8) per
///    dynamischer Programmierung, getrennt für die drei Versionsgruppen (1–9, 10–26, 27–40),
///    da sich dort die Länge der Zeichenzähler unterscheidet.
/// 2. Kleinste passende Version, Terminator, Füllbytes 0xEC/0x11.
/// 3. Aufteilung in Blöcke, Reed-Solomon über GF(256) (Polynom 0x11D), Verschachtelung.
/// 4. Funktionsmuster, Zickzack-Platzierung, Bewertung aller 8 Masken nach den
///    Strafregeln N1–N4, Format- und Versionsinformation (BCH).
///
/// Byte-Segmente enthalten UTF-8 ohne ECI-Kennung (verbreitete Praxis, wie ZPL mit `^CI28`).
/// Bei fester Version/Maske ist das Ergebnis bitgleich mit unabhängigen Referenz-Encodern.
enum QRCode {

    // MARK: Fehlerkorrekturstufe

    /// Tabellenindex (L, M, Q, H).
    static func ordinal(_ level: QRErrorCorrection) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 1
        case .quartile: return 2
        case .high: return 3
        }
    }

    /// Zwei Bit der Formatinformation (L = 01, M = 00, Q = 11, H = 10).
    static func formatBits(_ level: QRErrorCorrection) -> Int {
        switch level {
        case .low: return 1
        case .medium: return 0
        case .quartile: return 3
        case .high: return 2
        }
    }

    // MARK: Tabellen (ISO/IEC 18004:2015, Tabelle 9 und Anhang E)

    /// Fehlerkorrektur-Codewörter je Block, `[Stufe][Version]` (Index 0 unbenutzt).
    static let eccCodewordsPerBlock: [[Int]] = [
        // 0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16  17  18  19  20  21  22  23  24  25  26  27  28  29  30  31  32  33  34  35  36  37  38  39  40
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],  // L
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],  // M
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],  // Q
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],  // H
    ]

    /// Anzahl der Fehlerkorrekturblöcke, `[Stufe][Version]` (Index 0 unbenutzt).
    static let errorCorrectionBlocks: [[Int]] = [
        // 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],  // L
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],  // M
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],  // Q
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],  // H
    ]

    /// Mittelpunkt-Koordinaten der Ausrichtungsmuster je Version (Anhang E, Tabelle E.1).
    static let alignmentPatternPositions: [[Int]] = [
        [], [],
        [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
        [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54], [6, 32, 58], [6, 34, 62],
        [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86],
        [6, 34, 62, 90],
        [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102], [6, 28, 54, 80, 106],
        [6, 32, 58, 84, 110], [6, 30, 58, 86, 114], [6, 34, 62, 90, 118],
        [6, 26, 50, 74, 98, 122], [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130],
        [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138], [6, 30, 58, 86, 114, 142],
        [6, 34, 62, 90, 118, 146],
        [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154], [6, 28, 54, 80, 106, 132, 158],
        [6, 32, 58, 84, 110, 136, 162], [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170],
    ]

    /// Kantenlänge in Modulen.
    static func size(version: Int) -> Int { version * 4 + 17 }

    /// Anzahl der Datenmodule (Daten + Fehlerkorrektur, inkl. Restbits) einer Version.
    static func rawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignmentCount = version / 7 + 2
            result -= (25 * alignmentCount - 10) * alignmentCount - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    /// Gesamtzahl der Codewörter einer Version.
    static func totalCodewords(version: Int) -> Int { rawDataModules(version: version) / 8 }

    /// Anzahl der Datencodewörter für Version und Fehlerkorrekturstufe.
    static func dataCodewords(version: Int, level: QRErrorCorrection) -> Int {
        let ord = ordinal(level)
        return totalCodewords(version: version)
            - eccCodewordsPerBlock[ord][version] * errorCorrectionBlocks[ord][version]
    }

    // MARK: Segmente

    enum Mode: Int, Sendable {
        case numeric = 0x1
        case alphanumeric = 0x2
        case byte = 0x4

        /// Länge des Zeichenzählers in Bit.
        func characterCountBits(version: Int) -> Int {
            let group = version <= 9 ? 0 : (version <= 26 ? 1 : 2)
            switch self {
            case .numeric: return [10, 12, 14][group]
            case .alphanumeric: return [9, 11, 13][group]
            case .byte: return [8, 16, 16][group]
            }
        }
    }

    struct Segment: Equatable, Sendable {
        var mode: Mode
        /// Zeichenanzahl (bei Byte-Segmenten: Anzahl der Bytes).
        var characterCount: Int
        var data: BitBuffer
    }

    /// Bitpuffer, höchstwertiges Bit zuerst.
    struct BitBuffer: Equatable, Sendable {
        var bits: [Bool] = []

        var count: Int { bits.count }

        mutating func append(_ value: Int, bitCount: Int) {
            precondition(bitCount >= 0 && bitCount <= 31 && value >> bitCount == 0, "BitBuffer: Wert passt nicht")
            for bit in stride(from: bitCount - 1, through: 0, by: -1) { bits.append((value >> bit) & 1 == 1) }
        }

        mutating func append(_ other: BitBuffer) { bits.append(contentsOf: other.bits) }

        /// Bytes (Länge muss ein Vielfaches von 8 sein).
        var bytes: [UInt8] {
            var result = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
            for (index, bit) in bits.enumerated() where bit { result[index >> 3] |= 0x80 >> UInt8(index & 7) }
            return result
        }
    }

    /// Alphanumerischer Zeichensatz in Wertreihenfolge.
    static let alphanumericCharset: [UInt8] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

    /// Wert eines Zeichens im alphanumerischen Modus oder −1.
    static let alphanumericValue: [Int] = {
        var table = [Int](repeating: -1, count: 128)
        for (index, byte) in alphanumericCharset.enumerated() { table[Int(byte)] = index }
        return table
    }()

    static func isNumeric(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 128 && alphanumericValue[Int(scalar.value)] >= 0
    }

    static func numericSegment(_ digits: [UInt8]) -> Segment {
        var buffer = BitBuffer()
        var index = 0
        while index < digits.count {
            let n = min(3, digits.count - index)
            var value = 0
            for k in 0..<n { value = value * 10 + Int(digits[index + k] - 0x30) }
            buffer.append(value, bitCount: n * 3 + 1)
            index += n
        }
        return Segment(mode: .numeric, characterCount: digits.count, data: buffer)
    }

    static func alphanumericSegment(_ characters: [UInt8]) -> Segment {
        var buffer = BitBuffer()
        var index = 0
        while index + 1 < characters.count {
            let value = alphanumericValue[Int(characters[index])] * 45 + alphanumericValue[Int(characters[index + 1])]
            buffer.append(value, bitCount: 11)
            index += 2
        }
        if index < characters.count { buffer.append(alphanumericValue[Int(characters[index])], bitCount: 6) }
        return Segment(mode: .alphanumeric, characterCount: characters.count, data: buffer)
    }

    static func byteSegment(_ bytes: [UInt8]) -> Segment {
        var buffer = BitBuffer()
        for byte in bytes { buffer.append(Int(byte), bitCount: 8) }
        return Segment(mode: .byte, characterCount: bytes.count, data: buffer)
    }

    /// Optimale Segmentierung für eine bestimmte Version (relevant ist nur die Versionsgruppe).
    ///
    /// Kosten werden in Sechstel-Bit gerechnet (numerisch 10/3 Bit = 20, alphanumerisch
    /// 11/2 Bit = 33, Byte 8 Bit je UTF-8-Byte = 48); ein Moduswechsel kostet Moduskennung +
    /// Zeichenzähler, aufgerundet auf ganze Bits.
    static func optimalSegments(_ scalars: [Unicode.Scalar], version: Int) -> [Segment] {
        guard !scalars.isEmpty else { return [] }
        let modes: [Mode] = [.byte, .alphanumeric, .numeric]
        let headCosts = modes.map { (4 + $0.characterCountBits(version: version)) * 6 }
        let infinity = Int.max / 4

        // charModes[i][j]: Modus, in dem Zeichen i kodiert wurde, wenn danach Zustand j gilt.
        var charModes = [[Int]](repeating: [-1, -1, -1], count: scalars.count)
        var previous = headCosts
        for (i, scalar) in scalars.enumerated() {
            var current = [infinity, infinity, infinity]
            current[0] = previous[0] + String(scalar).utf8.count * 8 * 6
            charModes[i][0] = 0
            if isAlphanumeric(scalar) {
                current[1] = previous[1] + 33
                charModes[i][1] = 1
            }
            if isNumeric(scalar) {
                current[2] = previous[2] + 20
                charModes[i][2] = 2
            }
            // Nach diesem Zeichen in einen anderen Modus wechseln (neuer Segmentkopf).
            let afterCharacter = current
            for j in 0..<3 {
                for k in 0..<3 where charModes[i][k] >= 0 && afterCharacter[k] < infinity {
                    let candidate = (afterCharacter[k] + 5) / 6 * 6 + headCosts[j]
                    if candidate < current[j] {
                        current[j] = candidate
                        charModes[i][j] = charModes[i][k]
                    }
                }
            }
            previous = current
        }

        // Zurückverfolgen.
        var state = 0
        for j in 1..<3 where previous[j] < previous[state] { state = j }
        var assigned = [Int](repeating: 0, count: scalars.count)
        for i in stride(from: scalars.count - 1, through: 0, by: -1) {
            let mode = charModes[i][state]
            assigned[i] = mode
            state = mode
        }

        // Gleichartige Nachbarn zu Segmenten zusammenfassen.
        var segments: [Segment] = []
        var start = 0
        while start < scalars.count {
            var end = start + 1
            while end < scalars.count && assigned[end] == assigned[start] { end += 1 }
            let run = scalars[start..<end]
            switch modes[assigned[start]] {
            case .numeric:
                segments.append(numericSegment(run.map { UInt8($0.value) }))
            case .alphanumeric:
                segments.append(alphanumericSegment(run.map { UInt8($0.value) }))
            case .byte:
                var bytes: [UInt8] = []
                for scalar in run { bytes.append(contentsOf: String(scalar).utf8) }
                segments.append(byteSegment(bytes))
            }
            start = end
        }
        return segments
    }

    /// Gesamtlänge der Segmente in Bit für eine Version, oder `nil`, wenn ein Zeichenzähler überläuft.
    static func totalBits(_ segments: [Segment], version: Int) -> Int? {
        var total = 0
        for segment in segments {
            let countBits = segment.mode.characterCountBits(version: version)
            guard segment.characterCount < (1 << countBits) else { return nil }
            total += 4 + countBits + segment.data.count
        }
        return total
    }

    // MARK: Datencodewörter

    /// Wählt die kleinste passende Version und liefert die Datencodewörter (ohne Fehlerkorrektur).
    static func dataCodewords(for text: String, level: QRErrorCorrection, minimumVersion: Int = 1) throws
        -> (version: Int, codewords: [UInt8])
    {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { throw BarcodeError.invalidLength(0) }
        guard (1...40).contains(minimumVersion) else {
            throw BarcodeError.unsupported("QR-Code: Version \(minimumVersion) existiert nicht (1–40).")
        }
        var segments: [Segment] = []
        var chosenVersion = 0
        for version in minimumVersion...40 {
            if version == minimumVersion || version == 10 || version == 27 {
                segments = optimalSegments(scalars, version: version)
            }
            let capacityBits = dataCodewords(version: version, level: level) * 8
            if let used = totalBits(segments, version: version), used <= capacityBits {
                chosenVersion = version
                break
            }
        }
        guard chosenVersion > 0 else { throw BarcodeError.dataTooLong }

        let capacityBits = dataCodewords(version: chosenVersion, level: level) * 8
        var buffer = BitBuffer()
        for segment in segments {
            buffer.append(segment.mode.rawValue, bitCount: 4)
            buffer.append(segment.characterCount, bitCount: segment.mode.characterCountBits(version: chosenVersion))
            buffer.append(segment.data)
        }
        buffer.append(0, bitCount: min(4, capacityBits - buffer.count))       // Terminator
        buffer.append(0, bitCount: (8 - buffer.count % 8) % 8)               // Bytegrenze
        var padByte = 0xEC
        while buffer.count < capacityBits {
            buffer.append(padByte, bitCount: 8)
            padByte ^= 0xEC ^ 0x11
        }
        return (chosenVersion, buffer.bytes)
    }

    /// Ergänzt die Fehlerkorrektur und verschachtelt die Blöcke.
    static func addErrorCorrectionAndInterleave(_ data: [UInt8], version: Int, level: QRErrorCorrection) -> [UInt8] {
        let ord = ordinal(level)
        let blockCount = errorCorrectionBlocks[ord][version]
        let eccLength = eccCodewordsPerBlock[ord][version]
        let total = totalCodewords(version: version)
        precondition(data.count == total - blockCount * eccLength)
        let shortBlockCount = blockCount - total % blockCount
        let shortBlockLength = total / blockCount   // inklusive Fehlerkorrektur
        let generator = GaloisField256.qrCode.generator(degree: eccLength, firstRoot: 0)

        var dataBlocks: [[UInt8]] = []
        var eccBlocks: [[UInt8]] = []
        var offset = 0
        for block in 0..<blockCount {
            let length = shortBlockLength - eccLength + (block < shortBlockCount ? 0 : 1)
            let blockData = Array(data[offset..<(offset + length)])
            offset += length
            dataBlocks.append(blockData)
            eccBlocks.append(GaloisField256.qrCode.remainder(blockData, generator: generator))
        }

        var result: [UInt8] = []
        result.reserveCapacity(total)
        let maxDataLength = dataBlocks.map(\.count).max() ?? 0
        for i in 0..<maxDataLength {
            for block in dataBlocks where i < block.count { result.append(block[i]) }
        }
        for i in 0..<eccLength {
            for block in eccBlocks { result.append(block[i]) }
        }
        return result
    }

    // MARK: Symbolaufbau

    /// Format-Information (15 Bit) inklusive BCH(15,5) und Maske 0x5412.
    static func formatInformation(level: QRErrorCorrection, mask: Int) -> Int {
        let data = formatBits(level) << 3 | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        return (data << 10 | remainder) ^ 0x5412
    }

    /// Versions-Information (18 Bit) inklusive BCH(18,6), ab Version 7.
    static func versionInformation(_ version: Int) -> Int {
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        return version << 12 | remainder
    }

    /// Maskenbedingung (true = Modul invertieren); x = Spalte, y = Zeile.
    @inline(__always)
    static func maskCondition(_ mask: Int, x: Int, y: Int) -> Bool {
        switch mask {
        case 0: return (x + y) % 2 == 0
        case 1: return y % 2 == 0
        case 2: return x % 3 == 0
        case 3: return (x + y) % 3 == 0
        case 4: return (x / 3 + y / 2) % 2 == 0
        case 5: return x * y % 2 + x * y % 3 == 0
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }

    struct Symbol {
        let version: Int
        let size: Int
        var modules: [Bool]
        var isFunction: [Bool]

        init(version: Int) {
            self.version = version
            self.size = QRCode.size(version: version)
            modules = [Bool](repeating: false, count: size * size)
            isFunction = [Bool](repeating: false, count: size * size)
        }

        subscript(x: Int, y: Int) -> Bool {
            get { modules[y * size + x] }
            set { modules[y * size + x] = newValue }
        }

        mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y * size + x] = dark
            isFunction[y * size + x] = true
        }

        mutating func drawFunctionPatterns(level: QRErrorCorrection) {
            // Taktmuster
            for i in 0..<size {
                setFunction(6, i, i % 2 == 0)
                setFunction(i, 6, i % 2 == 0)
            }
            // Positionsmuster samt Separatoren
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            // Ausrichtungsmuster (nicht auf den Positionsmustern)
            let positions = QRCode.alignmentPatternPositions[version]
            let n = positions.count
            for i in 0..<n {
                for j in 0..<n where !((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)) {
                    drawAlignment(positions[i], positions[j])
                }
            }
            // Format (Platzhalter) und Version reservieren
            drawFormat(level: level, mask: 0)
            drawVersion()
        }

        mutating func drawFinder(_ cx: Int, _ cy: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx
                    let y = cy + dy
                    guard x >= 0, x < size, y >= 0, y < size else { continue }
                    let distance = max(abs(dx), abs(dy))
                    setFunction(x, y, distance != 2 && distance != 4)
                }
            }
        }

        mutating func drawAlignment(_ cx: Int, _ cy: Int) {
            for dy in -2...2 {
                for dx in -2...2 {
                    setFunction(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)
                }
            }
        }

        mutating func drawFormat(level: QRErrorCorrection, mask: Int) {
            let bits = QRCode.formatInformation(level: level, mask: mask)
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            // Erste Kopie (um das Positionsmuster links oben)
            for i in 0...5 { setFunction(8, i, bit(i)) }
            setFunction(8, 7, bit(6))
            setFunction(8, 8, bit(7))
            setFunction(7, 8, bit(8))
            for i in 9..<15 { setFunction(14 - i, 8, bit(i)) }
            // Zweite Kopie (rechts oben / links unten)
            for i in 0..<8 { setFunction(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { setFunction(8, size - 15 + i, bit(i)) }
            setFunction(8, size - 8, true)  // stets dunkles Modul
        }

        mutating func drawVersion() {
            guard version >= 7 else { return }
            let bits = QRCode.versionInformation(version)
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3
                let b = i / 3
                setFunction(a, b, dark)
                setFunction(b, a, dark)
            }
        }

        /// Platziert die Codewörter im Zickzack (zwei Spalten breit, von rechts unten beginnend).
        mutating func drawCodewords(_ codewords: [UInt8]) {
            let totalBits = codewords.count * 8
            var bitIndex = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }  // vertikales Taktmuster überspringen
                for vertical in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        guard !isFunction[y * size + x] else { continue }
                        if bitIndex < totalBits {
                            self[x, y] = (codewords[bitIndex >> 3] >> UInt8(7 - (bitIndex & 7))) & 1 == 1
                            bitIndex += 1
                        }
                        // Restbits bleiben hell (0).
                    }
                }
                right -= 2
            }
            precondition(bitIndex == totalBits, "QR: Codewörter passen nicht in die Matrix")
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y * size + x] && QRCode.maskCondition(mask, x: x, y: y) {
                    modules[y * size + x].toggle()
                }
            }
        }

        /// Strafpunkte nach ISO/IEC 18004, Abschnitt 7.8.3 (N1 = 3, N2 = 3, N3 = 40, N4 = 10).
        func penaltyScore() -> Int {
            var penalty = 0
            let n = size
            func module(_ x: Int, _ y: Int) -> Bool { modules[y * n + x] }

            // Regel 1: Folgen ≥ 5 gleichfarbiger Module in Zeilen und Spalten.
            for horizontal in [true, false] {
                for a in 0..<n {
                    var runColor = false
                    var runLength = 0
                    for b in 0..<n {
                        let color = horizontal ? module(b, a) : module(a, b)
                        if b > 0 && color == runColor {
                            runLength += 1
                        } else {
                            if runLength >= 5 { penalty += 3 + (runLength - 5) }
                            runColor = color
                            runLength = 1
                        }
                    }
                    if runLength >= 5 { penalty += 3 + (runLength - 5) }
                }
            }

            // Regel 2: gleichfarbige 2×2-Blöcke.
            for y in 0..<(n - 1) {
                for x in 0..<(n - 1) {
                    let color = module(x, y)
                    if color == module(x + 1, y) && color == module(x, y + 1) && color == module(x + 1, y + 1) {
                        penalty += 3
                    }
                }
            }

            // Regel 3: 1:1:3:1:1-Muster mit vier hellen Modulen davor oder danach
            // (Bereiche außerhalb des Symbols zählen als hell).
            func isLightRange(_ horizontal: Bool, _ line: Int, _ from: Int, _ to: Int) -> Bool {
                let start = max(from, 0)
                let end = min(to, n)
                guard start < end else { return true }
                for i in start..<end where (horizontal ? module(i, line) : module(line, i)) { return false }
                return true
            }
            let finderLike: [Bool] = [true, false, true, true, true, false, true]
            for horizontal in [true, false] {
                for line in 0..<n {
                    for start in 0..<(n - 6) {
                        var matches = true
                        for k in 0..<7 where (horizontal ? module(start + k, line) : module(line, start + k)) != finderLike[k] {
                            matches = false
                            break
                        }
                        if matches && (isLightRange(horizontal, line, start - 4, start)
                            || isLightRange(horizontal, line, start + 7, start + 11)) {
                            penalty += 40
                        }
                    }
                }
            }

            // Regel 4: Abweichung des Dunkelanteils von 50 % in 5-%-Schritten.
            let dark = modules.reduce(0) { $0 + ($1 ? 1 : 0) }
            let total = n * n
            penalty += abs(dark * 2 - total) * 10 / total * 10
            return penalty
        }

        var bitMatrix: BitMatrix { BitMatrix(width: size, height: size, bits: modules) }
    }

    // MARK: Einstiegspunkt

    /// Erzeugt einen QR-Code.
    ///
    /// - Parameters:
    ///   - minimumVersion: Kleinste zulässige Version (1…40).
    ///   - mask: Feste Maske 0…7 oder `nil` für die automatische Wahl nach Strafpunkten.
    static func encode(_ text: String, level: QRErrorCorrection, minimumVersion: Int = 1, mask: Int? = nil) throws -> BitMatrix {
        if let mask, !(0...7).contains(mask) {
            throw BarcodeError.unsupported("QR-Code: Maske \(mask) existiert nicht (0–7).")
        }
        let (version, data) = try dataCodewords(for: text, level: level, minimumVersion: minimumVersion)
        let codewords = addErrorCorrectionAndInterleave(data, version: version, level: level)

        var symbol = Symbol(version: version)
        symbol.drawFunctionPatterns(level: level)
        symbol.drawCodewords(codewords)

        let chosenMask: Int
        if let mask {
            chosenMask = mask
        } else {
            var best = 0
            var bestPenalty = Int.max
            for candidate in 0..<8 {
                symbol.applyMask(candidate)
                symbol.drawFormat(level: level, mask: candidate)
                let penalty = symbol.penaltyScore()
                if penalty < bestPenalty {
                    bestPenalty = penalty
                    best = candidate
                }
                symbol.applyMask(candidate)  // rückgängig (XOR)
            }
            chosenMask = best
        }
        symbol.applyMask(chosenMask)
        symbol.drawFormat(level: level, mask: chosenMask)
        return symbol.bitMatrix
    }
}

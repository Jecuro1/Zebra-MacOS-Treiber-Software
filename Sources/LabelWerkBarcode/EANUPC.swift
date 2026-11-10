import Foundation

/// EAN-13, EAN-8, UPC-A und UPC-E (ISO/IEC 15420).
enum EANUPC {

    /// Zeichensatz A (ungerade Parität, „L“) je Ziffer als 7-Bit-Modulfolge (1 = Balken).
    static let setA: [UInt8] = [0x0D, 0x19, 0x13, 0x3D, 0x23, 0x31, 0x2F, 0x3B, 0x37, 0x0B]

    /// Zeichensatz B (gerade Parität, „G“): gespiegeltes Muster des Zeichensatzes C.
    static let setB: [UInt8] = setC.map { reverse7($0) }

    /// Zeichensatz C (rechte Hälfte, „R“): Komplement des Zeichensatzes A.
    static let setC: [UInt8] = setA.map { ~$0 & 0x7F }

    /// Paritätsmuster der linken sechs Ziffern bei EAN-13 abhängig von der ersten Ziffer
    /// (Bit 5 = zweite Ziffer, 1 = Zeichensatz B).
    static let ean13Parity: [UInt8] = [0x00, 0x0B, 0x0D, 0x0E, 0x13, 0x19, 0x1C, 0x15, 0x16, 0x1A]

    /// Paritätsmuster bei UPC-E für Nummernsystem 0, abhängig von der Prüfziffer
    /// (Bit 5 = erste Ziffer, 1 = gerade Parität/Zeichensatz B). Nummernsystem 1: Komplement.
    static let upcEParity: [UInt8] = [0x38, 0x34, 0x32, 0x31, 0x2C, 0x26, 0x23, 0x2A, 0x29, 0x25]

    static func reverse7(_ value: UInt8) -> UInt8 {
        var result: UInt8 = 0
        for bit in 0..<7 where value & (1 << bit) != 0 { result |= 1 << (6 - bit) }
        return result
    }

    /// Sammelt Module samt Begrenzungs-Kennzeichen.
    struct ModuleWriter {
        var modules: [Bool] = []
        var guards: [Bool] = []

        mutating func append(pattern: UInt8, bits: Int, isGuard: Bool) {
            for bit in stride(from: bits - 1, through: 0, by: -1) {
                modules.append(pattern & (1 << UInt8(bit)) != 0)
                guards.append(isGuard)
            }
        }

        mutating func append(guardPattern: String) {
            for character in guardPattern {
                modules.append(character == "1")
                guards.append(true)
            }
        }

        func barcode(humanReadable: String) -> LinearBarcode {
            LinearBarcode(elements: LinearSupport.elements(modules: modules, guards: guards),
                          humanReadable: humanReadable, isTwoWidth: false)
        }
    }

    /// Prüft die Länge, berechnet bzw. validiert die Prüfziffer und liefert alle Ziffern.
    static func completeDigits(_ text: String, dataLength: Int) throws -> [Int] {
        let digits = try LinearSupport.digits(text)
        switch digits.count {
        case dataLength:
            return digits + [LinearSupport.mod10Weighted31(digits)]
        case dataLength + 1:
            let data = Array(digits.prefix(dataLength))
            let expected = LinearSupport.mod10Weighted31(data)
            guard expected == digits[dataLength] else {
                throw BarcodeError.invalidCharacter(LinearSupport.digitCharacter(digits[dataLength]))
            }
            return digits
        default:
            throw BarcodeError.invalidLength(digits.count)
        }
    }

    static func string(_ digits: [Int]) -> String {
        String(digits.map { LinearSupport.digitCharacter($0) })
    }

    // MARK: EAN-13 / UPC-A

    static func ean13Symbol(_ digits: [Int], humanReadable: String) -> LinearBarcode {
        precondition(digits.count == 13)
        var writer = ModuleWriter()
        writer.append(guardPattern: "101")
        let parity = ean13Parity[digits[0]]
        for index in 1...6 {
            let useB = parity & (1 << UInt8(6 - index)) != 0
            writer.append(pattern: useB ? setB[digits[index]] : setA[digits[index]], bits: 7, isGuard: false)
        }
        writer.append(guardPattern: "01010")
        for index in 7...12 {
            writer.append(pattern: setC[digits[index]], bits: 7, isGuard: false)
        }
        writer.append(guardPattern: "101")
        return writer.barcode(humanReadable: humanReadable)
    }

    static func ean13(_ text: String) throws -> LinearBarcode {
        let digits = try completeDigits(text, dataLength: 12)
        return ean13Symbol(digits, humanReadable: string(digits))
    }

    static func upcA(_ text: String) throws -> LinearBarcode {
        let digits = try completeDigits(text, dataLength: 11)
        return ean13Symbol([0] + digits, humanReadable: string(digits))
    }

    // MARK: EAN-8

    static func ean8(_ text: String) throws -> LinearBarcode {
        let digits = try completeDigits(text, dataLength: 7)
        var writer = ModuleWriter()
        writer.append(guardPattern: "101")
        for index in 0...3 { writer.append(pattern: setA[digits[index]], bits: 7, isGuard: false) }
        writer.append(guardPattern: "01010")
        for index in 4...7 { writer.append(pattern: setC[digits[index]], bits: 7, isGuard: false) }
        writer.append(guardPattern: "101")
        return writer.barcode(humanReadable: string(digits))
    }

    // MARK: UPC-E

    /// Expandiert die sechs UPC-E-Datenziffern samt Nummernsystem zu den elf UPC-A-Datenziffern.
    static func expandUPCE(numberSystem: Int, _ e: [Int]) -> [Int] {
        precondition(e.count == 6)
        let manufacturer: [Int]
        let product: [Int]
        switch e[5] {
        case 0, 1, 2:
            manufacturer = [e[0], e[1], e[5], 0, 0]
            product = [0, 0, e[2], e[3], e[4]]
        case 3:
            manufacturer = [e[0], e[1], e[2], 0, 0]
            product = [0, 0, 0, e[3], e[4]]
        case 4:
            manufacturer = [e[0], e[1], e[2], e[3], 0]
            product = [0, 0, 0, 0, e[4]]
        default:
            manufacturer = [e[0], e[1], e[2], e[3], e[4]]
            product = [0, 0, 0, 0, e[5]]
        }
        return [numberSystem] + manufacturer + product
    }

    /// Komprimiert elf UPC-A-Datenziffern (inkl. Nummernsystem 0/1) zu sechs UPC-E-Ziffern,
    /// falls möglich.
    static func compressUPCA(_ a: [Int]) -> [Int]? {
        guard a.count == 11, a[0] == 0 || a[0] == 1 else { return nil }
        let m = Array(a[1...5])
        let p = Array(a[6...10])
        var candidate: [Int]?
        if m[2] <= 2 && m[3] == 0 && m[4] == 0 && p[0] == 0 && p[1] == 0 {
            candidate = [m[0], m[1], p[2], p[3], p[4], m[2]]
        } else if m[3] == 0 && m[4] == 0 && p[0] == 0 && p[1] == 0 && p[2] == 0 {
            candidate = [m[0], m[1], m[2], p[3], p[4], 3]
        } else if m[4] == 0 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0 {
            candidate = [m[0], m[1], m[2], m[3], p[4], 4]
        } else if p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0 && p[4] >= 5 {
            candidate = [m[0], m[1], m[2], m[3], m[4], p[4]]
        }
        guard let e = candidate, expandUPCE(numberSystem: a[0], e) == a else { return nil }
        return e
    }

    /// UPC-E aus 6 (Nummernsystem 0), 7 (NS + 6) oder 8 Ziffern (NS + 6 + Prüfziffer);
    /// zusätzlich werden 11/12-stellige, komprimierbare UPC-A-Nummern akzeptiert.
    static func upcE(_ text: String) throws -> LinearBarcode {
        let digits = try LinearSupport.digits(text)
        let numberSystem: Int
        let data: [Int]
        var givenCheck: Int?
        switch digits.count {
        case 6:
            numberSystem = 0
            data = digits
        case 7, 8:
            numberSystem = digits[0]
            data = Array(digits[1...6])
            if digits.count == 8 { givenCheck = digits[7] }
        case 11, 12:
            guard let compressed = compressUPCA(Array(digits.prefix(11))) else {
                throw BarcodeError.unsupported("UPC-E: Die UPC-A-Nummer lässt sich nicht zu UPC-E komprimieren.")
            }
            numberSystem = digits[0]
            data = compressed
            if digits.count == 12 { givenCheck = digits[11] }
        default:
            throw BarcodeError.invalidLength(digits.count)
        }
        guard numberSystem == 0 || numberSystem == 1 else {
            throw BarcodeError.invalidCharacter(LinearSupport.digitCharacter(numberSystem))
        }
        let check = LinearSupport.mod10Weighted31(expandUPCE(numberSystem: numberSystem, data))
        if let givenCheck, givenCheck != check {
            throw BarcodeError.invalidCharacter(LinearSupport.digitCharacter(givenCheck))
        }

        var parity = upcEParity[check]
        if numberSystem == 1 { parity = ~parity & 0x3F }
        var writer = ModuleWriter()
        writer.append(guardPattern: "101")
        for index in 0..<6 {
            let useB = parity & (1 << UInt8(5 - index)) != 0
            writer.append(pattern: useB ? setB[data[index]] : setA[data[index]], bits: 7, isGuard: false)
        }
        writer.append(guardPattern: "010101")
        return writer.barcode(humanReadable: string([numberSystem] + data + [check]))
    }
}

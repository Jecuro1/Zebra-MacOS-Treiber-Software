import Foundation

/// Arithmetik im endlichen Körper GF(2⁸) mit wählbarem primitivem Polynom (Erzeuger α = 2)
/// sowie systematische Reed-Solomon-Kodierung.
///
/// * QR-Code: Polynom 0x11D (x⁸+x⁴+x³+x²+1), Generator-Nullstellen α⁰…α^(n−1)
/// * Data Matrix ECC200: Polynom 0x12D (x⁸+x⁵+x³+x²+1), Generator-Nullstellen α¹…αⁿ
struct GaloisField256: Sendable {
    let primitive: Int
    /// α^i für i = 0…509 (doppelt, damit Summen von Logarithmen nicht reduziert werden müssen).
    let exp: [UInt8]
    /// log_α(v) für v = 1…255 (Index 0 unbenutzt).
    let log: [Int]

    init(primitive: Int) {
        self.primitive = primitive
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var value = 1
        for i in 0..<255 {
            exp[i] = UInt8(value)
            log[value] = i
            value <<= 1
            if value & 0x100 != 0 { value ^= primitive }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        self.exp = exp
        self.log = log
    }

    static let qrCode = GaloisField256(primitive: 0x11D)
    static let dataMatrix = GaloisField256(primitive: 0x12D)

    @inline(__always)
    func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[log[Int(a)] + log[Int(b)]]
    }

    /// Generatorpolynom g(x) = ∏_{i=0}^{degree−1} (x − α^(firstRoot+i)).
    ///
    /// - Returns: Koeffizienten ohne den führenden Koeffizienten 1, höchste Potenz zuerst
    ///   (`[g_{n−1}, …, g_0]`).
    func generator(degree: Int, firstRoot: Int) -> [UInt8] {
        precondition(degree >= 1 && degree <= 254)
        // Koeffizienten höchste Potenz zuerst, inklusive führender 1.
        var poly: [UInt8] = [1]
        for i in 0..<degree {
            let root = exp[(firstRoot + i) % 255]
            var next = [UInt8](repeating: 0, count: poly.count + 1)
            for (j, coefficient) in poly.enumerated() {
                next[j] ^= coefficient                       // · x
                next[j + 1] ^= multiply(coefficient, root)   // · root (− = + in GF(2⁸))
            }
            poly = next
        }
        return Array(poly.dropFirst())
    }

    /// Rest der Division data(x) · x^n durch g(x) – die n Fehlerkorrektur-Codewörter.
    func remainder(_ data: [UInt8], generator: [UInt8]) -> [UInt8] {
        let degree = generator.count
        var result = [UInt8](repeating: 0, count: degree)
        for byte in data {
            let factor = byte ^ result[0]
            result.removeFirst()
            result.append(0)
            if factor != 0 {
                let logFactor = log[Int(factor)]
                for j in 0..<degree where generator[j] != 0 {
                    result[j] ^= exp[logFactor + log[Int(generator[j])]]
                }
            }
        }
        return result
    }

    /// Bequemlichkeitsfunktion: Fehlerkorrektur-Codewörter für einen Block.
    func errorCorrection(for data: [UInt8], count: Int, firstRoot: Int) -> [UInt8] {
        remainder(data, generator: generator(degree: count, firstRoot: firstRoot))
    }
}

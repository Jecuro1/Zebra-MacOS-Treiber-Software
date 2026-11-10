import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("ACS (Alternative Compression Scheme)")
struct ACSTests {

    // MARK: Dekodierung – Beispiele aus der ZPL-Dokumentation und Sonderfälle

    @Test("Wiederholungszähler G–Y (1–19) und g–z (20–400)")
    func counts() throws {
        // "M6" = 7 × '6'
        #expect(try ACS.decode("M6", bytesPerRow: 4, totalBytes: 4) == [0x66, 0x66, 0x66, 0x60])
        // "hB" = 40 × 'B'
        #expect(try ACS.decode("hB", bytesPerRow: 20, totalBytes: 20) == [UInt8](repeating: 0xBB, count: 20))
        // "vMB" = 320 + 7 = 327 × 'B'
        let vmb = try ACS.decode("vMB", bytesPerRow: 200, totalBytes: 200)
        #expect(Array(vmb[0..<163]) == [UInt8](repeating: 0xBB, count: 163))
        #expect(vmb[163] == 0xB0)
        #expect(vmb[164...].allSatisfy { $0 == 0 })
        // Reihenfolge der Zähler egal (additiv)
        #expect(try ACS.decode("MvB", bytesPerRow: 200, totalBytes: 200) == vmb)
        // Grenzen: G = 1, Y = 19, g = 20, z = 400
        #expect(try ACS.decode("G7", bytesPerRow: 1, totalBytes: 1) == [0x70])
        #expect(try ACS.decode("Y1", bytesPerRow: 10, totalBytes: 10).prefix(10) == [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x10])
        let z = try ACS.decode("zA", bytesPerRow: 250, totalBytes: 250)
        #expect(z.prefix(200).allSatisfy { $0 == 0xAA } && z[200...].allSatisfy { $0 == 0 })
        // Alle Zählerbuchstaben
        for (i, c) in "GHIJKLMNOPQRSTUVWXY".enumerated() {
            let decoded = try ACS.decode("\(c)F", bytesPerRow: 10, totalBytes: 10)
            let nibbles = decoded.flatMap { [$0 >> 4, $0 & 0xF] }
            #expect(nibbles.prefix { $0 == 0xF }.count == i + 1, "\(c)")
        }
        for (i, c) in "ghijklmnopqrstuvwxyz".enumerated() {
            let decoded = try ACS.decode("\(c)F", bytesPerRow: 200, totalBytes: 200)
            let nibbles = decoded.flatMap { [$0 >> 4, $0 & 0xF] }
            #expect(nibbles.prefix { $0 == 0xF }.count == (i + 1) * 20, "\(c)")
        }
    }

    @Test("',' füllt mit 0, '!' füllt mit F – bis Zeilenende (am Zeilenanfang: ganze Zeile)")
    func fills() throws {
        #expect(try ACS.decode("F,!", bytesPerRow: 3, totalBytes: 6) == [0xF0, 0x00, 0x00, 0xFF, 0xFF, 0xFF])
        // ',' genau an der Zeilengrenze → ganze (nächste) Zeile weiß
        #expect(try ACS.decode("FFFFFF,F", bytesPerRow: 3, totalBytes: 9) ==
                [0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00])
        #expect(try ACS.decode("!,1", bytesPerRow: 1, totalBytes: 3) == [0xFF, 0x00, 0x10])
        // ungerade Nibble-Position: '!' füllt ab dem Nibble
        #expect(try ACS.decode("A!", bytesPerRow: 2, totalBytes: 2) == [0xAF, 0xFF])
        #expect(try ACS.decode("12A!", bytesPerRow: 2, totalBytes: 4) == [0x12, 0xAF, 0x00, 0x00])
    }

    @Test("':' wiederholt die Vorzeile")
    func repeatRow() throws {
        #expect(try ACS.decode("A1B2,:", bytesPerRow: 3, totalBytes: 9) ==
                [0xA1, 0xB2, 0x00, 0xA1, 0xB2, 0x00, 0x00, 0x00, 0x00])
        #expect(try ACS.decode("A1B2,::", bytesPerRow: 3, totalBytes: 9) ==
                [0xA1, 0xB2, 0x00, 0xA1, 0xB2, 0x00, 0xA1, 0xB2, 0x00])
        // ':' in der ersten Zeile → leere Zeile
        #expect(try ACS.decode(":F", bytesPerRow: 1, totalBytes: 2) == [0x00, 0xF0])
        // ':' mitten in der Zeile → Rest aus der Vorzeile
        #expect(try ACS.decode("123456789:", bytesPerRow: 2, totalBytes: 6) == [0x12, 0x34, 0x56, 0x78, 0x96, 0x78])
    }

    @Test("Läufe über Zeilengrenzen, Leerraum, Kleinbuchstaben, Längenabweichungen")
    func tolerance() throws {
        #expect(try ACS.decode("KF", bytesPerRow: 1, totalBytes: 3) == [0xFF, 0xFF, 0xF0])
        #expect(try ACS.decode("12\r\n 3\t4", bytesPerRow: 2, totalBytes: 2) == [0x12, 0x34])
        #expect(try ACS.decode("ab", bytesPerRow: 1, totalBytes: 1) == [0xAB])
        #expect(try ACS.decode("FFFFFFFF", bytesPerRow: 1, totalBytes: 2) == [0xFF, 0xFF])
        #expect(try ACS.decode("F", bytesPerRow: 2, totalBytes: 4) == [0xF0, 0x00, 0x00, 0x00])
        #expect(try ACS.decode("", bytesPerRow: 2, totalBytes: 2) == [0x00, 0x00])
        #expect(try ACS.decode("anything", bytesPerRow: 1, totalBytes: 0) == [])
        // Zähler ohne folgende Hexziffer wird verworfen
        #expect(try ACS.decode("K,F", bytesPerRow: 1, totalBytes: 2) == [0x00, 0xF0])
        #expect(try ACS.decode("12K", bytesPerRow: 1, totalBytes: 1) == [0x12])
        // Reines Hex ist gültiges ACS
        #expect(try ACS.decode("C0000040FFC0", bytesPerRow: 2, totalBytes: 6) == [0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0])
    }

    @Test("Fehlerfälle")
    func errors() {
        #expect(throws: ImagingError.self) { try ACS.decode("12Z4", bytesPerRow: 2, totalBytes: 2) }
        #expect(throws: ImagingError.self) { try ACS.decode("12^4", bytesPerRow: 2, totalBytes: 2) }
        #expect(throws: ImagingError.self) { try ACS.decode("12", bytesPerRow: 0, totalBytes: 2) }
        #expect(throws: ImagingError.self) { try ACS.decode("12", bytesPerRow: 1, totalBytes: -1) }
    }

    // MARK: Kodierung

    @Test("Kodierung: exakte Ausgaben")
    func encodeExact() {
        // 10 × 3: C0 00 / 00 40 / FF C0
        let page = MonoBitmap(width: 10, height: 3, data: [0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0])
        #expect(ACS.encode(page) == "C,0040FFC0")
        #expect(ACS.encode(MonoBitmap(width: 16, height: 3)) == ",::")
        #expect(ACS.encode(MonoBitmap(width: 16, height: 2, data: [0xFF, 0xFF, 0xFF, 0xFF])) == "!:")
        // 50 × 'A' = 40 + 10 → "hPA"
        #expect(ACS.encode(MonoBitmap(width: 200, height: 1, data: [UInt8](repeating: 0xAA, count: 25))) == "hPA")
        // 420 × '5' → 419 ("zY5") + 1 ("5")
        #expect(ACS.encode(MonoBitmap(width: 1680, height: 1, data: [UInt8](repeating: 0x55, count: 210))) == "zY55")
        // Kurze Läufe: 2 × direkt, 3 × mit Zähler
        #expect(ACS.encode(MonoBitmap(width: 16, height: 1, data: [0x55, 0x51])) == "I51")
        #expect(ACS.encode(MonoBitmap(width: 8, height: 1, data: [0x55])) == "55")
        // Abschluss nur bei Lauf ≥ 2 aus 0 bzw. F
        #expect(ACS.encode(MonoBitmap(width: 8, height: 1, data: [0xF0])) == "F0")
        #expect(ACS.encode(MonoBitmap(width: 8, height: 1, data: [0x0F])) == "0F")
        #expect(ACS.encode(MonoBitmap(width: 24, height: 1, data: [0x12, 0x00, 0x00])) == "12,")
        #expect(ACS.encode(MonoBitmap(width: 24, height: 1, data: [0xF1, 0xFF, 0xFF])) == "F1!")
        // 20 und 21 Wiederholungen
        #expect(ACS.encode(MonoBitmap(width: 88, height: 1, data: [UInt8](repeating: 0x77, count: 10) + [0x1F])) == "g71F")
        #expect(ACS.encode(MonoBitmap(width: 88, height: 1, data: [UInt8](repeating: 0x77, count: 10) + [0x7F])) == "gG7F")
        #expect(ACS.encode(MonoBitmap(width: 0, height: 0)) == "")
    }

    @Test("Rundlauf zufälliger Bitmaps mit ungeraden Breiten 1…77")
    func roundTrip() throws {
        var rng = SplitMix64(seed: 0xAC5)
        for width in 1...77 {
            for _ in 0..<4 {
                let height = Int(rng.next() % 9) + 1
                let density = [0.02, 0.5, 0.98][Int(rng.next() % 3)]
                let bitmap = TestSupport.randomBitmap(width: width, height: height, rng: &rng, density: density)
                let encoded = ACS.encode(bitmap)
                let decoded = try ACS.decode(encoded, bytesPerRow: bitmap.bytesPerRow, totalBytes: bitmap.data.count)
                #expect(decoded == bitmap.data, "Breite \(width): \(encoded)")
                // Nie länger als reines Hex
                #expect(encoded.utf8.count <= bitmap.data.count * 2)
                // Nur zulässige Zeichen
                #expect(encoded.utf8.allSatisfy { c in
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Y")).contains(c)
                        || (UInt8(ascii: "g")...UInt8(ascii: "z")).contains(c) || c == UInt8(ascii: ",") || c == UInt8(ascii: "!") || c == UInt8(ascii: ":")
                })
            }
        }
    }

    @Test("Kompakt bei typischen Etiketten (große weiße Flächen)")
    func compactness() throws {
        var bitmap = MonoBitmap(width: 832, height: 400)
        for y in 100..<140 { for x in 50..<700 { bitmap[x, y] = true } }   // Balken
        for y in 200..<300 where y % 10 == 0 { for x in stride(from: 100, to: 600, by: 7) { bitmap[x, y] = true } }
        let encoded = ACS.encode(bitmap)
        #expect(encoded.utf8.count * 20 < bitmap.data.count * 2, "\(encoded.utf8.count) Zeichen")
        #expect(try ACS.decode(encoded, bytesPerRow: 104, totalBytes: bitmap.data.count) == bitmap.data)
    }
}

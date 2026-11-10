import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("Grafik-Encoder (ZPL, EPL, CPCL)")
struct GraphicEncoderTests {
    /// 10 × 3 Punkte:
    /// `##........` → C0 00
    /// `.........#` → 00 40
    /// `##########` → FF C0
    static let pageA = TestSupport.bitmap([
        "##........",
        ".........#",
        "##########",
    ])

    @Test("Testbitmap hat das erwartete Byteformat")
    func fixture() {
        #expect(Self.pageA.data == [0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0])
    }

    // MARK: ZPL ^GF

    @Test("^GFA mit Hex, ACS und Z64")
    func graphicField() throws {
        #expect(ZPLGraphicEncoder.graphicField(Self.pageA, compression: .hex) == "^GFA,6,6,2,C0000040FFC0")
        #expect(ZPLGraphicEncoder.graphicField(Self.pageA, compression: .acs) == "^GFA,6,6,2,C,0040FFC0")
        let z64 = ZPLGraphicEncoder.graphicField(Self.pageA, compression: .z64)
        #expect(z64.hasPrefix("^GFA,6,6,2,:Z64:"))
        let payload = String(z64.dropFirst("^GFA,6,6,2,".count))
        #expect(try [UInt8](Z64.decode(payload)) == Self.pageA.data)
        #expect(ZPLGraphicEncoder.graphicData(Self.pageA, compression: .hex) == "C0000040FFC0")
    }

    @Test("~DG Grafik-Download")
    func downloadGraphic() {
        #expect(ZPLGraphicEncoder.downloadGraphic(name: "logo", bitmap: Self.pageA) == "~DGR:LOGO.GRF,6,2,C0000040FFC0")
        #expect(ZPLGraphicEncoder.downloadGraphic(name: "Logo.grf", drive: "e", bitmap: Self.pageA) == "~DGE:LOGO.GRF,6,2,C0000040FFC0")
        #expect(ZPLGraphicEncoder.downloadGraphic(name: "X", drive: "B:", bitmap: MonoBitmap(width: 8, height: 1, data: [0x0F])) == "~DGB:X.GRF,1,1,0F")
    }

    @Test("decodeGraphicField: Format A – Hex, ACS, Z64, B64")
    func decodeFormatA() throws {
        let expected = MonoBitmap(width: 16, height: 3, data: [0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0])
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: "C0000040FFC0") == expected)
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: "C,0040FFC0") == expected)
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "a", totalBytes: 6, bytesPerRow: 2, data: "c0000040ffc0") == expected)
        let z64 = try Z64.encode(Data(expected.data))
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: z64) == expected)
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: "\r\n" + z64 + "\r\n") == expected)
        // :B64: (Base64 „wAAAQP/A“, CRC 956C mit Python berechnet)
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: ":B64:wAAAQP/A:956C") == expected)
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: ":B64:wAAAQP/A") == expected)
        #expect(B64.encode(bytes: expected.data) == ":B64:wAAAQP/A:956C")
        #expect(throws: ImagingError.checksumMismatch(expected: 0x1234, actual: 0x956C)) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 6, bytesPerRow: 2, data: ":B64:wAAAQP/A:1234")
        }
    }

    @Test("decodeGraphicField: Format B – Binär als ISO-Latin-1")
    func decodeFormatB() throws {
        let binary = String(String.UnicodeScalarView([0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0].map { Unicode.Scalar(UInt8($0)) }))
        let bitmap = try ZPLGraphicEncoder.decodeGraphicField(format: "B", totalBytes: 6, bytesPerRow: 2, data: binary)
        #expect(bitmap.data == [0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0])
        #expect(bitmap.width == 16 && bitmap.height == 3)
        #expect(throws: ImagingError.self) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "B", totalBytes: 2, bytesPerRow: 1, data: "A€")
        }
        // überzählige Zeichen werden ignoriert, auch wenn sie außerhalb von Latin-1 liegen
        #expect(try ZPLGraphicEncoder.decodeGraphicField(format: "B", totalBytes: 1, bytesPerRow: 1, data: "A€").data == [0x41])
    }

    @Test("decodeGraphicField: Größen, Auffüllen, Fehler")
    func decodeEdgeCases() throws {
        // totalBytes kein Vielfaches von bytesPerRow → letzte Zeile wird aufgefüllt
        let partial = try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 5, bytesPerRow: 2, data: "FFFFFFFFFFFF")
        #expect(partial.height == 3)
        #expect(partial.data == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        // zu wenige Daten → weiß
        let short = try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 4, bytesPerRow: 2, data: "C0")
        #expect(short.data == [0xC0, 0x00, 0x00, 0x00])
        let empty = try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 0, bytesPerRow: 2, data: "")
        #expect(empty.height == 0 && empty.width == 16)
        #expect(throws: ImagingError.unsupportedGraphicFormat("^GF Format C (komprimiertes Binärformat)")) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "C", totalBytes: 2, bytesPerRow: 1, data: "")
        }
        #expect(throws: ImagingError.self) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "X", totalBytes: 2, bytesPerRow: 1, data: "")
        }
        #expect(throws: ImagingError.self) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 2, bytesPerRow: 0, data: "FF")
        }
        #expect(throws: ImagingError.self) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: -1, bytesPerRow: 1, data: "FF")
        }
        #expect(throws: ImagingError.self) {
            try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: 2, bytesPerRow: 1, data: "XYZ")
        }
    }

    @Test("Rundlauf graphicField → decodeGraphicField für alle Kompressionen", arguments: GraphicCompression.allCases)
    func roundTrip(compression: GraphicCompression) throws {
        var rng = SplitMix64(seed: 0x6F)
        for width in [1, 5, 8, 13, 31, 64, 77, 100] {
            let bitmap = TestSupport.randomBitmap(width: width, height: Int(rng.next() % 12) + 1, rng: &rng)
            let field = ZPLGraphicEncoder.graphicField(bitmap, compression: compression)
            let parts = field.dropFirst(5).split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            #expect(parts.count == 4)
            #expect(Int(parts[0]) == bitmap.data.count && Int(parts[1]) == bitmap.data.count)
            #expect(Int(parts[2]) == bitmap.bytesPerRow)
            let total = try #require(Int(parts[0]))
            let bpr = try #require(Int(parts[2]))
            let decoded = try ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: total,
                                                                   bytesPerRow: bpr, data: String(parts[3]))
            #expect(decoded.cropped(x: 0, y: 0, width: width, height: bitmap.height) == bitmap)
        }
    }

    // MARK: EPL

    @Test("EPL GW: invertierte Binärdaten (0 = schwarz)")
    func eplGW() {
        let expected = TestSupport.data(.text("GW5,7,2,3,"), .bytes([0x3F, 0xFF, 0xFF, 0xBF, 0x00, 0x3F]), .text("\n"))
        #expect(EPLGraphicEncoder.gw(x: 5, y: 7, bitmap: Self.pageA) == expected)
        // Füllbits werden 1 (weiß)
        let narrow = EPLGraphicEncoder.gw(x: 0, y: 0, bitmap: TestSupport.bitmap(["#.."]))
        #expect(narrow == TestSupport.data(.text("GW0,0,1,1,"), .bytes([0x7F]), .text("\n")))
    }

    // MARK: CPCL

    @Test("CPCL CG (binär) und EG (hex)")
    func cpcl() {
        let cg = CPCLGraphicEncoder.cg(x: 0, y: 0, bitmap: Self.pageA)
        #expect(cg == TestSupport.data(.text("CG 2 3 0 0 "), .bytes([0xC0, 0x00, 0x00, 0x40, 0xFF, 0xC0]), .text("\r\n")))
        #expect(CPCLGraphicEncoder.eg(x: 10, y: 20, bitmap: Self.pageA) == "EG 2 3 10 20 C0000040FFC0\r\n")
    }
}

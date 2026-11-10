import Foundation
import Testing
@testable import LabelWerkBarcode

@Suite("Grundtypen")
struct BarcodeTypesTests {

    @Test("Symbologien: stabile Rohwerte, Anzeigenamen, 2D-Kennzeichen")
    func symbologies() throws {
        #expect(BarcodeSymbology.allCases.count == 12)
        #expect(BarcodeSymbology(rawValue: "dataMatrix") == .dataMatrix)
        #expect(BarcodeSymbology.qr.isTwoDimensional && BarcodeSymbology.pdf417.isTwoDimensional)
        #expect(!BarcodeSymbology.code128.isTwoDimensional)
        #expect(BarcodeSymbology.upcE.displayName == "UPC-E")
        let encoded = try JSONEncoder().encode([BarcodeSymbology.interleaved2of5])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"interleaved2of5\"]")
    }

    @Test("Einbreiten-Code: Punktbreiten = Modulbreite × Elementbreite, Verhältnis wirkungslos")
    func singleWidthDots() {
        let barcode = LinearBarcode(
            elements: [.init(isBar: true, width: 2), .init(isBar: false, width: 1), .init(isBar: true, width: 4)],
            humanReadable: "x", isTwoWidth: false)
        let dots = barcode.widthsInDots(moduleWidth: 3, ratio: 2.5)
        #expect(dots.map(\.dots) == [6, 3, 12])
        #expect(dots.map(\.isBar) == [true, false, true])
        #expect(barcode.totalWidth(moduleWidth: 3, ratio: 2.0) == 21)
        #expect(barcode.modules == [true, true, false, true, true, true, true])
        #expect(barcode.moduleCount == 7)
        // Modulbreite < 1 wird als 1 behandelt.
        #expect(barcode.totalWidth(moduleWidth: 0, ratio: 3) == 7)
    }

    @Test("Zweibreiten-Code: breite Elemente nach Verhältnis (2,0…3,0, gerundet)")
    func twoWidthDots() {
        let barcode = LinearBarcode(
            elements: [.init(isBar: true, width: 2), .init(isBar: false, width: 1), .init(isBar: true, width: 1)],
            humanReadable: "", isTwoWidth: true)
        #expect(barcode.widthsInDots(moduleWidth: 2, ratio: 3.0).map(\.dots) == [6, 2, 2])
        #expect(barcode.widthsInDots(moduleWidth: 2, ratio: 2.5).map(\.dots) == [5, 2, 2])
        #expect(barcode.widthsInDots(moduleWidth: 3, ratio: 2.5).map(\.dots) == [8, 3, 3])  // 7,5 → 8
        // Begrenzung auf 2,0…3,0
        #expect(barcode.widthsInDots(moduleWidth: 2, ratio: 9.0).map(\.dots) == [6, 2, 2])
        #expect(barcode.widthsInDots(moduleWidth: 2, ratio: 1.0).map(\.dots) == [4, 2, 2])
        #expect(LinearBarcode.wideDots(moduleWidth: 1, ratio: 2.2) == 2)
        #expect(LinearBarcode.wideDots(moduleWidth: 1, ratio: .nan) == 3)
        #expect(barcode.totalWidth(moduleWidth: 1, ratio: 2) == 4)
    }

    @Test("BitMatrix: Indexzugriff, Beschreibung, dunkle Module")
    func bitMatrix() {
        var matrix = BitMatrix(width: 3, height: 2)
        #expect(matrix.bits == [Bool](repeating: false, count: 6))
        matrix[2, 0] = true
        matrix[0, 1] = true
        #expect(matrix[2, 0] && matrix[0, 1] && !matrix[1, 1])
        #expect(matrix.bits == [false, false, true, true, false, false])
        #expect(matrix.description == "..#\n#..")
        #expect(matrix.darkCount == 2)
        let copy = BitMatrix(width: 3, height: 2, bits: matrix.bits)
        #expect(copy == matrix)
        #expect(BitMatrix(width: 0, height: 0).description == "")
    }

    @Test("Barcode-Hülle liefert den passenden Inhalt")
    func barcodeEnum() throws {
        let linear = try BarcodeEncoder.encode("123", as: .code128)
        #expect(linear.linearBarcode != nil && linear.bitMatrix == nil)
        let matrix = try BarcodeEncoder.encode("123", as: .qr)
        #expect(matrix.bitMatrix != nil && matrix.linearBarcode == nil)
    }

    @Test("Fehlermeldungen sind deutsch und vergleichbar")
    func errors() {
        #expect(BarcodeError.invalidLength(3) == .invalidLength(3))
        #expect(BarcodeError.invalidCharacter("a") != .invalidCharacter("b"))
        #expect(BarcodeError.dataTooLong.errorDescription == "Die Daten sind zu lang für diese Barcode-Art.")
        #expect(BarcodeError.invalidCharacter("€").errorDescription?.contains("U+20AC") == true)
        #expect(BarcodeError.invalidCharacter("\u{1}").errorDescription?.contains("U+0001") == true)
        #expect(BarcodeError.unsupported("X").errorDescription == "Nicht unterstützt: X")
    }

    @Test("Vereinheitlichte Kodierung für alle Symbologien")
    func unifiedEncode() throws {
        let samples: [BarcodeSymbology: String] = [
            .code128: "LabelWerk-128", .code39: "CODE 39", .code93: "Code 93", .ean13: "400638133393",
            .ean8: "9638507", .upcA: "03600029145", .upcE: "0425261", .interleaved2of5: "123456",
            .codabar: "40156", .qr: "https://example.org", .dataMatrix: "LabelWerk", .pdf417: "PDF417",
        ]
        for symbology in BarcodeSymbology.allCases {
            let barcode = try BarcodeEncoder.encode(try #require(samples[symbology]), as: symbology)
            #expect((barcode.bitMatrix != nil) == symbology.isTwoDimensional, "\(symbology)")
        }
        #expect(throws: BarcodeError.invalidLength(0)) { try BarcodeEncoder.encode("", as: .qr) }
    }
}

@Suite("Rasterung")
struct BarcodeRasterizerTests {

    @Test("Linearer Code mit Ruhezone in Moduln")
    func linear() {
        let barcode = LinearBarcode(elements: [.init(isBar: true, width: 1), .init(isBar: false, width: 2), .init(isBar: true, width: 1)],
                                    humanReadable: "", isTwoWidth: false)
        let raster = BarcodeRasterizer.render(barcode, moduleWidth: 2, ratio: 3, height: 3, quietZone: 1)
        #expect(raster.width == 2 * (4 + 2))
        #expect(raster.height == 3)
        let row = Array(raster.pixels[0..<raster.width])
        #expect(row == [false, false, true, true, false, false, false, false, true, true, false, false])
        #expect(Array(raster.pixels[(2 * raster.width)...]) == row)
    }

    @Test("Zweibreiten-Code berücksichtigt das Verhältnis")
    func twoWidth() throws {
        let barcode = try BarcodeEncoder.interleaved2of5("12")
        let raster = BarcodeRasterizer.render(barcode, moduleWidth: 1, ratio: 3, height: 1, quietZone: 0)
        #expect(raster.width == barcode.totalWidth(moduleWidth: 1, ratio: 3))
        // Start: schmal Balken/Lücke/Balken/Lücke
        #expect(Array(raster.pixels.prefix(4)) == [true, false, true, false])
        // Stopp: breiter Balken (3), schmale Lücke, schmaler Balken
        #expect(Array(raster.pixels.suffix(5)) == [true, true, true, false, true])
    }

    @Test("Matrix mit Modulgröße und Ruhezone")
    func matrix() {
        var matrix = BitMatrix(width: 2, height: 1)
        matrix[1, 0] = true
        let raster = BarcodeRasterizer.render(matrix, moduleSize: 2, quietZone: 1)
        #expect(raster.width == 8 && raster.height == 6)
        var expected = [Bool](repeating: false, count: 48)
        for y in 2..<4 { for x in 4..<6 { expected[y * 8 + x] = true } }
        #expect(raster.pixels == expected)
        // Ungültige Werte werden abgefangen.
        let minimal = BarcodeRasterizer.render(matrix, moduleSize: 0, quietZone: -3)
        #expect(minimal.width == 2 && minimal.height == 1 && minimal.pixels == [false, true])
    }
}

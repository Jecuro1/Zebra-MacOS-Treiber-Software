import Foundation
import Testing
import LabelWerkImaging
@testable import LabelWerkRender

/// Robustheit: Zufällige (teils ZPL-ähnliche) Eingaben dürfen weder Tokenizer, Interpreter noch
/// Rasterizer zum Absturz bringen.
@Suite("Robustheit gegen Zufallseingaben")
struct FuzzTests {

    /// Bausteine für ZPL-ähnliche Zufallsdaten.
    private static let commands: [String] = {
        var list = ZPLCommandReference.entries.map(\.command)
        list += ["^A0N", "^AAN", "^ADR", "^AGI", "^A@B", "^GFA", "^GFB", "^GFC", "~DGR:X.GRF", "~DYR:Y",
                 "^XGR:X.GRF", "^XFR:F.ZPL", "^DFR:F.ZPL", "^FN1", "^SN", "^SF", "^FH", "^FH_", "^CC#", "^CT+",
                 "^CD;", "#XA", "+DG", "^BQN", "^BXN", "^B7N", "^BCN", "^FB", "^FT", "^FO", "^FD", "^FS", "^XA",
                 "^XZ", "^PQ", "^ISR:I.GRF", "^ILR:I.GRF", "^MCN", "^MCY", "^FC%", "^FP"]
        return list
    }()

    private static let fragments: [String] = [
        "", ",", ",,", "0", "1", "-1", "9", "10", "50", "100", "999", "32000", "99999999", "-99999",
        "N", "R", "I", "B", "Y", "A", "D", "U", "QA,", "MM,", "HM,B0003", "_5E", "_7E", "_C3", "\\&",
        "FF", "00", "FFFF0000", ":Z64:eJwDAAAAAAE=:0000", ":B64:AAAA:1234", "!!", "::", "gG", "zZ",
        "E:LOGO.GRF", "R:*.*", " ", "\r\n", "\n", "Ä", "€", "漢", "😀", "\u{0}", "\u{1D}", "^", "~",
        "%d.%m.%Y", ">;", ">:", ">5", ">8", ">", "<", "=", "@",
    ]

    private static func randomInput(_ random: inout TestSupport.Random) -> String {
        var text = ""
        let style = random.int(0...9)
        let parts = random.int(1...40)
        for _ in 0..<parts {
            switch style {
            case 0:
                // Völlig zufällige Unicode-Skalare (inkl. Steuerzeichen und Präfixe)
                for _ in 0..<random.int(0...12) {
                    let value = random.int(0...4) == 0 ? UInt32(random.int(0...0x2FFF)) : UInt32(random.int(0...127))
                    if let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) }
                }
            default:
                text += random.element(commands)
                for index in 0..<random.int(0...6) {
                    if index > 0 { text += "," }
                    text += random.element(fragments)
                }
            }
        }
        return text
    }

    @Test("2000 Zufallseingaben: kein Absturz, Rasterung kleiner Etiketten")
    func randomInputs() {
        var random = TestSupport.Random(seed: 0xC0FF_EE00_2026)
        var labels = 0
        var warnings = 0
        for _ in 0..<2000 {
            let input = Self.randomInput(&random)
            let tokens = ZPLTokenizer.tokenize(input)
            #expect(tokens.count <= input.unicodeScalars.count)
            let document = ZPLInterpreter(dotsPerMM: random.element([6, 8, 12, 24]),
                                          defaultWidthDots: random.int(1...900),
                                          defaultHeightDots: random.int(1...900)).render(input)
            warnings += document.allWarnings.count
            for label in document.labels.prefix(3) {
                labels += 1
                _ = label.elements.map(\.boundingBox)
                guard label.widthDots * label.heightDots <= 1_500_000 else { continue }
                let bitmap = SoftwareRasterizer.rasterize(label)
                #expect(bitmap.width == label.widthDots && bitmap.height == label.heightDots)
            }
        }
        #expect(labels > 100)
        #expect(warnings > 100)
    }

    @Test("Bösartige Grenzfälle")
    func pathologicalInputs() {
        let inputs = [
            "^XA^FO0,0^GFA,33554433,33554433,1,FF^FS^XZ",
            "^XA^FO0,0^GFA,1000000,1000000,99999999,^FS^XZ",
            "^XA^FO0,0^GFB,999999999,10,1,abc^FS^XZ",
            "~DGR:A.GRF,99999999,1,FF",
            "^XA^FO0,0^A0N,32000,32000^FB32000,9999,-9999,J,9999^FD" + String(repeating: "W ", count: 1500) + "^FS^XZ",
            "^XA^FO32000,32000^GB32000,32000,32000^FS^XZ",
            "^XA^FO0,0^BXN,32000,200^FDA^FS^FO0,0^BQN,2,10^FDQA," + String(repeating: "x", count: 3000) + "^FS^XZ",
            "^XA^PQ99999999,0,99999999^FO0,0^A0N,20^SN1^FS^XZ",
            "^XA^FO0,0^A0N,20^FPV,9999^FD" + String(repeating: "A", count: 3000) + "^FS^XZ",
            String(repeating: "^XA", count: 2000),
            String(repeating: "^", count: 5000),
            String(repeating: "~", count: 5000),
            "^CC^^CT~^CD,",
        ]
        for input in inputs {
            let document = ZPLInterpreter(defaultWidthDots: 300, defaultHeightDots: 300).render(input)
            for label in document.labels.prefix(2) where label.widthDots * label.heightDots <= 1_500_000 {
                _ = SoftwareRasterizer.rasterize(label)
            }
        }
    }
}

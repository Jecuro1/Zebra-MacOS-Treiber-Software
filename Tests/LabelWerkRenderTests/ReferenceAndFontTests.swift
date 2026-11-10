import Foundation
import Testing
@testable import LabelWerkRender

@Suite("ZPLCommandReference")
struct CommandReferenceTests {

    @Test("Mindestens 120 eindeutige, vollständig beschriebene Befehle")
    func entries() {
        let entries = ZPLCommandReference.entries
        #expect(entries.count >= 120)
        #expect(Set(entries.map(\.command)).count == entries.count)
        for entry in entries {
            #expect(entry.command.first == "^" || entry.command.first == "~", "\(entry.command)")
            #expect(entry.syntax.hasPrefix(entry.command), "\(entry.command): \(entry.syntax)")
            #expect(!entry.name.isEmpty && !entry.summary.isEmpty, "\(entry.command)")
            #expect(entry.summary.hasSuffix("."), "\(entry.command)")
        }
        // Formatbefehle zuerst, jeweils alphabetisch
        let caret = entries.prefix { $0.command.first == "^" }.map(\.command)
        #expect(caret == caret.sorted())
    }

    @Test("Alle vom Interpreter ausgewerteten Befehle sind beschrieben")
    func interpreterCoverage() {
        let handled = ["^A", "^A@", "^B2", "^B3", "^B7", "^B8", "^B9", "^BA", "^BC", "^BE", "^BK", "^BL", "^BQ", "^BU",
                       "^BX", "^BY", "^CC", "^CD", "^CF", "^CI", "^CT", "^CW", "^DF", "^FB", "^FC", "^FD", "^FH",
                       "^FN", "^FO", "^FP", "^FR", "^FS", "^FT", "^FV", "^FW", "^FX", "^GB", "^GC", "^GD", "^GE",
                       "^GF", "^GS", "^ID", "^IL", "^IM", "^IS", "^LH", "^LL", "^LR", "^LS", "^LT", "^MC", "^MU",
                       "^PM", "^PO", "^PQ", "^PW", "^SF", "^SN", "^TB", "^XA", "^XF", "^XG", "^XZ", "~DG", "~DY",
                       "~EG", "~CC", "~CD", "~CT"]
        for command in handled {
            #expect(ZPLCommandReference.lookup(command)?.command == command, "\(command)")
        }
    }

    @Test("Nachschlagen ist tolerant gegenüber Schreibweise, Parametern und Präfix")
    func lookup() {
        #expect(ZPLCommandReference.lookup("^FO")?.name == "Feldursprung")
        #expect(ZPLCommandReference.lookup("fo")?.command == "^FO")
        #expect(ZPLCommandReference.lookup("^FO50,50")?.command == "^FO")
        #expect(ZPLCommandReference.lookup("^A0N,30,30")?.command == "^A")
        #expect(ZPLCommandReference.lookup("^A@N,30,30,E:ARIAL.TTF")?.command == "^A@")
        #expect(ZPLCommandReference.lookup("~hqes")?.command == "~HQ")
        #expect(ZPLCommandReference.lookup("HS")?.command == "~HS")
        #expect(ZPLCommandReference.lookup("~CC")?.command == "~CC")
        #expect(ZPLCommandReference.lookup(" ^XA ")?.command == "^XA")
        #expect(ZPLCommandReference.lookup("^QQ") == nil)
        #expect(ZPLCommandReference.lookup("") == nil)
        #expect(ZPLCommandReference.completions(for: "^F").count >= 10)
        #expect(ZPLCommandReference.completions(for: "^f").allSatisfy { $0.command.hasPrefix("^F") })
    }
}

@Suite("Eingebettete Schriften")
struct FontTests {

    private static let fonts: [String: BitmapFont] = ["sansBold": .sansBold, "sans": .sans, "mono": .mono]

    @Test("Masterschriften dekodieren vollständig", arguments: ["sansBold", "sans", "mono"])
    func decoding(name: String) throws {
        let font = try #require(Self.fonts[name])
        #expect(font.emSize == 44)
        #expect(font.capHeight == 32)
        // ASCII 95 + Latin-1 95 (ohne weiches Trennzeichen) + Windows-1252-Zusätze 20 + Latin Extended-A 128
        #expect(font.glyphs.count == 338, "\(name): \(font.glyphs.count)")
        for character in "AZaz09ÄÖÜäöüß€@&%„“–—™ŁőŽ" {
            let glyph = try #require(font.glyph(character.unicodeScalars.first!), "\(name): \(character)")
            #expect(!glyph.isEmpty && glyph.advance > 0, "\(name): \(character)")
            #expect(glyph.pixels.count == glyph.width * glyph.height)
        }
        let space = try #require(font.glyph(" "))
        #expect(space.isEmpty && space.advance > 0)
        // 'H' sitzt auf der Grundlinie und ist versalhoch
        let h = try #require(font.glyph("H"))
        #expect(h.top == font.capHeight && h.height == font.capHeight)
    }

    @Test("Monospace-Vorschübe sind identisch, Schrift 0 ist schmaler als DejaVu Sans Bold")
    func metrics() {
        let mono = BitmapFont.mono
        let advances = Set("AiW0 .".map { mono.resolve($0).advance })
        #expect(advances.count == 1)
        let condensed = TextFont(fontName: "0", height: 50, width: 50, dotsPerMM: 8)
        let regular = TextFont(fontName: "E:ARIAL.TTF", height: 50, width: 50, dotsPerMM: 8)
        #expect(condensed.advance("0") < regular.advance("0") * 1.05)
        #expect(condensed.baseline == 38 && regular.baseline == 38)
        let bitmapD = TextFont(fontName: "D", height: 36, width: 20, dotsPerMM: 8)
        #expect(bitmapD.advance("i") == 24 && bitmapD.advance("W") == 24)
        #expect(bitmapD.baseline == 28)
    }

    @Test("Fehlende Zeichen: Zerlegung, typografischer Ersatz, Tofu")
    func fallbacks() {
        let font = BitmapFont.sans
        #expect(font.resolve("ǒ").pixels == font.resolve("o").pixels)
        #expect(font.resolve("\u{2212}").pixels == font.resolve("-").pixels)
        #expect(font.resolve("漢").pixels == font.missingGlyph.pixels)
        #expect(font.resolve("e\u{301}").pixels == font.resolve("é").pixels)
    }

    @Test("Glyphenraster: Verkleinern und Vergrößern liefern Tinte in der erwarteten Größe")
    func glyphScaling() throws {
        let glyph = try #require(BitmapFont.sansBold.glyph("H"))
        for scale in [0.2, 0.5, 1.0, 2.0, 5.0] {
            let raster = GlyphRenderer.render(glyph, scaleX: scale, scaleY: scale)
            let rows = raster.spans.filter { !$0.isEmpty }.count
            #expect(abs(Double(rows) - 32 * scale) <= 1.5, "Skalierung \(scale): \(rows) Zeilen")
        }
        let region = GlyphRenderer.render(glyph, scaleX: 100, scaleY: 100, region: IntRect(x: 0, y: -100, width: 50, height: 50))
        #expect(region.width <= 50 && region.height <= 50)
    }
}

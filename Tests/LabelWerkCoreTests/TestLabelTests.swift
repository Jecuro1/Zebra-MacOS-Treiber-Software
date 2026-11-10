import Foundation
import Testing
@testable import LabelWerkCore

/// Etikettengröße in Zoll.
struct LabelSize: Sendable, CustomTestStringConvertible {
    let widthInches: Double
    let heightInches: Double
    var testDescription: String { "\(widthInches)×\(heightInches) in" }

    func dots(_ resolution: Resolution) -> (width: Int, height: Int) {
        (resolution.dots(fromInches: widthInches), resolution.dots(fromInches: heightInches))
    }
}

private let labelSizes: [LabelSize] = [
    LabelSize(widthInches: 2, heightInches: 1), LabelSize(widthInches: 2, heightInches: 12),
    LabelSize(widthInches: 2.25, heightInches: 1.25), LabelSize(widthInches: 2.25, heightInches: 0.75 + 0.25),
    LabelSize(widthInches: 3, heightInches: 2), LabelSize(widthInches: 3, heightInches: 1),
    LabelSize(widthInches: 4, heightInches: 1), LabelSize(widthInches: 4, heightInches: 2),
    LabelSize(widthInches: 4, heightInches: 3), LabelSize(widthInches: 4, heightInches: 4),
    LabelSize(widthInches: 4, heightInches: 6), LabelSize(widthInches: 4, heightInches: 12),
    LabelSize(widthInches: 5, heightInches: 3), LabelSize(widthInches: 6, heightInches: 1),
    LabelSize(widthInches: 6, heightInches: 4), LabelSize(widthInches: 8, heightInches: 1),
    LabelSize(widthInches: 8, heightInches: 6), LabelSize(widthInches: 8, heightInches: 12),
]

private let fixedDate: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 3))!
}()

private let utc = TimeZone(identifier: "UTC")!

private struct Box: CustomStringConvertible {
    var x: Int, y: Int, width: Int, height: Int
    var description: String { "(\(x),\(y) \(width)×\(height))" }
    func isInside(width w: Int, height h: Int) -> Bool { x >= 0 && y >= 0 && x + width <= w && y + height <= h }
}

private func int(_ s: Substring) -> Int { Int(s)! }

/// Entfernt die ^FH-Maskierung (_XX → Byte).
private func unescapeFH(_ s: Substring) -> String {
    let utf8 = Array(s.utf8)
    var out: [UInt8] = []
    var i = 0
    while i < utf8.count {
        if utf8[i] == UInt8(ascii: "_"), i + 2 < utf8.count,
           let b = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
            out.append(b)
            i += 3
        } else {
            out.append(utf8[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Bestimmt die Ausdehnung aller ZPL-Felder (^FO …^FS) des Testetiketts.
private func zplFieldBoxes(_ zpl: String) -> (boxes: [(String, Box)], unknown: [String]) {
    var boxes: [(String, Box)] = []
    var unknown: [String] = []
    var moduleWidth = 2
    for line in zpl.split(separator: "\n") {
        if let m = line.firstMatch(of: /^\^BY(\d+),/) { moduleWidth = int(m.1); continue }
        guard line.hasPrefix("^FO") else { continue }
        guard let fo = line.firstMatch(of: /^\^FO(\d+),(\d+)/) else { unknown.append(String(line)); continue }
        let x = int(fo.1), y = int(fo.2)
        let data = line.firstMatch(of: /\^FD(.*)\^FS$/).map { $0.1 }
        if let gb = line.firstMatch(of: /\^GB(\d+),(\d+),(\d+)/) {
            boxes.append((String(line), Box(x: x, y: y, width: int(gb.1), height: int(gb.2))))
        } else if let gc = line.firstMatch(of: /\^GC(\d+),/) {
            boxes.append((String(line), Box(x: x, y: y, width: int(gc.1), height: int(gc.1))))
        } else if let a = line.firstMatch(of: /\^A0N,(\d+),(\d+)/), let fb = line.firstMatch(of: /\^FB(\d+),1,/) {
            boxes.append((String(line), Box(x: x, y: y, width: int(fb.1), height: int(a.1))))
        } else if let bc = line.firstMatch(of: /\^BCN,(\d+),N,N,N/), let data {
            let count = unescapeFH(data).count
            boxes.append((String(line), Box(x: x, y: y, width: (11 * count + 35) * moduleWidth, height: int(bc.1))))
        } else if let bq = line.firstMatch(of: /\^BQN,2,(\d+),M/), let data, data.hasPrefix("MA,") {
            let modules = TestLabelLayout.qrModuleCount(byteCount: unescapeFH(data.dropFirst(3)).utf8.count)
            let side = modules * int(bq.1)
            boxes.append((String(line), Box(x: x, y: y, width: side, height: side)))
        } else {
            unknown.append(String(line))
        }
    }
    return (boxes, unknown)
}

@Suite("Testetikett")
struct TestLabelTests {

    // MARK: ZPL

    @Test("ZPL bleibt innerhalb des Etiketts", arguments: Resolution.allCases, labelSizes)
    func zplInBounds(resolution: Resolution, size: LabelSize) {
        let (w, h) = size.dots(resolution)
        let zpl = TestLabel.zpl(widthDots: w, heightDots: h, resolution: resolution, title: "LabelWerk",
                                subtitle: "Zebra ZD421t", date: fixedDate, timeZone: utc)
        #expect(zpl.hasPrefix("^XA\n"))
        #expect(zpl.hasSuffix("^XZ\n"))
        #expect(zpl.contains("^CI28\n^PW\(w)\n^LL\(h)\n^LH0,0\n"))
        #expect(zpl.components(separatedBy: "^XA").count == 2)
        let (boxes, unknown) = zplFieldBoxes(zpl)
        #expect(unknown.isEmpty, "Unbekannte Felder: \(unknown)")
        #expect(boxes.count > 20)
        for (line, box) in boxes {
            #expect(box.isInside(width: w, height: h), "\(box) außerhalb von \(w)×\(h): \(line)")
        }
        // Titel, Code 128 und Lineal sind immer vorhanden.
        #expect(zpl.contains("^FR^FH^FDLabelWerk^FS"))
        #expect(zpl.contains("^BCN,"))
        #expect(zpl.contains("^FH^FD10^FS") || zpl.contains("^FH^FD20^FS"))
    }

    @Test("ZPL-Inhalt eines 4×6-Zoll-Etiketts (203 dpi)")
    func zplContent() throws {
        let zpl = TestLabel.zpl(widthDots: 812, heightDots: 1218, resolution: .dpi203, title: "LabelWerk",
                                subtitle: "Zebra ZD421t", date: fixedDate, timeZone: utc)
        #expect(zpl.contains("^FXLabelWerk Testetikett 812 x 1218 Punkte, 203 dpi\n"))
        #expect(zpl.contains("^FDZebra ZD421t^FS"))
        #expect(zpl.contains("Auflösung: 203 dpi · 8 Punkte/mm"))
        #expect(zpl.contains("Gedruckt am 09.11.2026 um 14:03 Uhr"))
        #expect(zpl.contains("Format: 101,6 × 152,4 mm^FS"))
        #expect(zpl.contains("Druckfläche: 812 × 1218 Punkte^FS"))
        #expect(zpl.contains("Sprache: ZPL II"))
        #expect(zpl.contains("^FR^FH^FD203 dpi^FS"))
        #expect(zpl.contains("^FH^FDLW-203-102X152^FS"))
        #expect(zpl.contains("^BQN,2,"))
        #expect(zpl.contains("^FH^FDMA,LabelWerk 203dpi 812x1218 2026-11-09^FS"))
        #expect(zpl.components(separatedBy: "^GC").count - 1 == 4)
        #expect(zpl.contains(/\^GB\d+,\d+,\d+,B,[1-8]\^FS/))
        #expect(zpl.hasSuffix("^PQ1\n^XZ\n"))
        // Lineal: Zahlen 10, 20 … 90 mm.
        for mm in stride(from: 10, through: 90, by: 10) {
            #expect(zpl.contains("^FH^FD\(mm)^FS"), "\(mm) mm")
        }
    }

    @Test("Titel wird maskiert")
    func zplEscapedTitle() {
        let zpl = TestLabel.zpl(widthDots: 812, heightDots: 1218, resolution: .dpi203, title: "A^B~C_D",
                                subtitle: "x\\y", date: fixedDate, timeZone: utc)
        #expect(zpl.contains("^FR^FH^FDA_5EB_7EC_5FD^FS"))
        #expect(zpl.contains("^FH^FDx_5Cy^FS"))
        #expect(!zpl.contains("^B~"))
    }

    @Test("Ausgabe ist reproduzierbar")
    func deterministic() {
        let a = TestLabel.zpl(widthDots: 600, heightDots: 400, resolution: .dpi300, date: fixedDate, timeZone: utc)
        let b = TestLabel.zpl(widthDots: 600, heightDots: 400, resolution: .dpi300, date: fixedDate, timeZone: utc)
        #expect(a == b)
        #expect(TestLabel.epl(widthDots: 600, heightDots: 400, resolution: .dpi203, date: fixedDate, timeZone: utc)
            == TestLabel.epl(widthDots: 600, heightDots: 400, resolution: .dpi203, date: fixedDate, timeZone: utc))
    }

    @Test("Vertragsfunktionen mit Standardwerten")
    func contractOverloads() {
        let zpl = TestLabel.zpl(widthDots: 812, heightDots: 1218, resolution: .dpi203)
        #expect(zpl.hasPrefix("^XA") && zpl.contains("^XZ") && zpl.contains("LabelWerk"))
        let epl = TestLabel.epl(widthDots: 812, heightDots: 1218, resolution: .dpi203)
        #expect(epl.hasPrefix("\nN\nq812\n") && epl.hasSuffix("P1\n"))
        let cpcl = TestLabel.cpcl(widthDots: 576, heightDots: 406, resolution: .dpi203)
        #expect(cpcl.hasPrefix("! 0 200 200 406 1\r\n") && cpcl.hasSuffix("FORM\r\nPRINT\r\n"))
    }

    @Test("Winzige und ungültige Maße", arguments: [(0, 0), (5, 5), (40, 30), (100, 50), (50, 400), (400, 40), (160, 120)])
    func degenerateSizes(size: (Int, Int)) {
        let (w, h) = size
        let zpl = TestLabel.zpl(widthDots: w, heightDots: h, resolution: .dpi203, date: fixedDate, timeZone: utc)
        #expect(zpl.hasPrefix("^XA\n") && zpl.hasSuffix("^XZ\n"))
        let (boxes, unknown) = zplFieldBoxes(zpl)
        #expect(unknown.isEmpty)
        for (line, box) in boxes {
            #expect(box.isInside(width: max(1, w), height: max(1, h)), "\(line)")
        }
        _ = TestLabel.epl(widthDots: w, heightDots: h, resolution: .dpi203, date: fixedDate, timeZone: utc)
        _ = TestLabel.cpcl(widthDots: w, heightDots: h, resolution: .dpi203, date: fixedDate, timeZone: utc)
    }

    // MARK: Layout

    @Test("Layout: alles im Etikett, Inhalte überlappen nicht", arguments: Resolution.allCases, labelSizes)
    func layoutGeometry(resolution: Resolution, size: LabelSize) throws {
        let (w, h) = size.dots(resolution)
        for style in [TestLabelLayout.Style.zpl(resolution), .epl(resolution), .cpcl(resolution)] {
            let layout = TestLabelLayout.make(widthDots: w, heightDots: h, resolution: resolution, title: "LabelWerk",
                                              subtitle: "Zebra ZT411", date: fixedDate, timeZone: utc, style: style)
            let all = TestLabelLayout.Rect(x: 0, y: 0, width: w, height: h)
            for element in layout.elements {
                #expect(all.contains(element.rect), "\(element) außerhalb \(w)×\(h)")
                #expect(element.rect.width > 0 && element.rect.height > 0)
            }
            // Rahmen
            let frames = layout.elements.compactMap { e -> (TestLabelLayout.Rect, Int)? in
                if case .frame(let r, let t, _) = e { return (r, t) } else { return nil }
            }
            let (frame, thickness) = try #require(frames.first)
            let inner = TestLabelLayout.Rect(x: frame.x + thickness, y: frame.y + thickness,
                                             width: frame.width - 2 * thickness, height: frame.height - 2 * thickness)
            // Inhalte (außer Passermarken) liegen im Rahmen und überlappen nicht.
            var content: [TestLabelLayout.Rect] = []
            var titleBar: TestLabelLayout.Rect?
            for element in layout.elements {
                switch element {
                case .titleBar(let r, _):
                    titleBar = r
                    #expect(inner.contains(r))
                case .text(let slot) where slot.reversed:
                    #expect(titleBar?.contains(slot.rect) == true)
                case .text(let slot):
                    content.append(slot.rect)
                case .code128(let r, _, _), .qr(let r, _, _), .gradientBox(let r, _):
                    content.append(r)
                case .fill(let r) where inner.intersects(r):
                    content.append(r)
                default:
                    break
                }
            }
            for r in content { #expect(inner.contains(r), "\(r) nicht im Rahmen \(inner)") }
            if let titleBar { content.append(titleBar) }
            for i in content.indices {
                for j in content.indices where j > i {
                    #expect(!content[i].intersects(content[j]), "\(content[i]) überlappt \(content[j])")
                }
            }
            // Passermarken liegen außerhalb des Rahmens.
            for element in layout.elements {
                if case .fill(let r) = element, !inner.intersects(r) { #expect(!frame.intersects(r)) }
                if case .circle(let r, _) = element { #expect(!frame.intersects(r)) }
            }
        }
    }

    @Test("Flache Etiketten: Infozeilen rechts neben dem Barcode")
    func sideColumn() throws {
        let layout = TestLabelLayout.make(widthDots: 812, heightDots: 203, resolution: .dpi203, title: "LabelWerk",
                                          subtitle: "Zebra ZD421t", date: fixedDate, timeZone: utc, style: .zpl(.dpi203))
        let barcode = try #require(layout.elements.compactMap { e -> TestLabelLayout.Rect? in
            if case .code128(let r, _, _) = e { return r } else { return nil }
        }.first)
        let qr = try #require(layout.elements.compactMap { e -> TestLabelLayout.Rect? in
            if case .qr(let r, _, _) = e { return r } else { return nil }
        }.first)
        let sideTexts = layout.elements.compactMap { e -> TestLabelLayout.TextSlot? in
            if case .text(let slot) = e, slot.rect.x > barcode.maxX, slot.rect.maxX <= qr.x { return slot } else { return nil }
        }
        #expect(sideTexts.count >= 2)
        #expect(sideTexts.first?.variants == ["Zebra ZD421t"])
    }

    @Test("Schriftproben in exakt darstellbaren Größen")
    func fontSamples() {
        let epl = TestLabel.epl(widthDots: 812, heightDots: 1218, resolution: .dpi203, date: fixedDate, timeZone: utc)
        #expect(epl.contains("\"1,5 mm - AaBbCc"))
        #expect(epl.contains(",0,1,1,1,N,\"1,5 mm"))
        let zpl = TestLabel.zpl(widthDots: 812, heightDots: 1218, resolution: .dpi203, date: fixedDate, timeZone: utc)
        #expect(zpl.contains("^A0N,16,16^FB712,1,0,L,0^FH^FD2 mm · AaBbCc 0123456789 ÄÖÜ äöü ß €^FS"))
        #expect(zpl.contains("^A0N,32,32^FB712,1,0,L,0^FH^FD4 mm · AaBbCc 0123456789 ÄÖÜ äöü ß €^FS"))
        let cpcl = TestLabel.cpcl(widthDots: 812, heightDots: 1218, resolution: .dpi203, date: fixedDate, timeZone: utc)
        #expect(cpcl.contains(/TEXT 7 0 \d+ \d+ 3 mm - AaBbCc 0123456789/))
        #expect(cpcl.contains(/SETMAG 2 2\r\nTEXT 7 0 \d+ \d+ 6 mm - AaBbCc/))
    }

    @Test("Schwärzungsskala: zunehmende Linienstärke bis zur Vollfläche")
    func gradient() throws {
        let layout = TestLabelLayout.make(widthDots: 812, heightDots: 1218, resolution: .dpi203, title: "T",
                                          subtitle: "", date: fixedDate, timeZone: utc, style: .zpl(.dpi203))
        let boxes = layout.elements.compactMap { e -> (TestLabelLayout.Rect, Int)? in
            if case .gradientBox(let r, let t) = e { return (r, t) } else { return nil }
        }
        #expect(boxes.count == 10)
        let thicknesses = boxes.map(\.1)
        #expect(thicknesses == thicknesses.sorted())
        #expect(thicknesses.first == 1)
        let last = try #require(boxes.last)
        #expect(last.1 >= min(last.0.width, last.0.height))
    }

    @Test("Lineal misst ab der linken Etikettenkante (1-mm-Raster)")
    func ruler() {
        let resolution = Resolution.dpi300
        let layout = TestLabelLayout.make(widthDots: 1200, heightDots: 1800, resolution: resolution, title: "T",
                                          subtitle: "", date: fixedDate, timeZone: utc, style: .zpl(resolution))
        let ticks = layout.elements.compactMap { e -> TestLabelLayout.Rect? in
            if case .fill(let r) = e, r.width < r.height, r.height < 100, r.y > 1500, r.x > 100, r.maxX < 1100 {
                return r
            }
            return nil
        }
        #expect(ticks.count > 80)
        for tick in ticks {
            let mm = Double(tick.x) / resolution.exactDotsPerMM
            #expect(abs(mm - mm.rounded()) < 0.1, "Strich bei \(mm) mm")
        }
    }

    // MARK: EPL

    @Test("EPL bleibt innerhalb des Etiketts und ist reines ASCII", arguments: [Resolution.dpi203, .dpi300], labelSizes)
    func eplInBounds(resolution: Resolution, size: LabelSize) throws {
        let (w, h) = size.dots(resolution)
        let epl = TestLabel.epl(widthDots: w, heightDots: h, resolution: resolution, title: "Prüfdruck",
                                subtitle: "Zebra GK420d", date: fixedDate, timeZone: utc)
        #expect(epl.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(epl.hasPrefix("\nN\nq\(w)\n"))
        #expect(epl.hasSuffix("\nP1\n"))
        #expect(epl.contains("\"Pruefdruck\""))
        #expect(epl.contains("LE"))
        let fonts = Dictionary(uniqueKeysWithValues: EPLTestLabelRenderer.baseFonts(resolution).map { ($0.font, $0) })
        for line in epl.split(separator: "\n") {
            if let m = line.firstMatch(of: /^A(\d+),(\d+),0,(\d),(\d),(\d),N,"(.*)"$/) {
                let font = try #require(fonts[String(m.3)])
                let width = m.6.count * (font.width + font.spacing) * int(m.4)
                let height = font.height * int(m.5)
                #expect(Box(x: int(m.1), y: int(m.2), width: width, height: height).isInside(width: w, height: h), "\(line)")
            } else if let m = line.firstMatch(of: /^L[OEW](\d+),(\d+),(\d+),(\d+)$/) {
                #expect(Box(x: int(m.1), y: int(m.2), width: int(m.3), height: int(m.4)).isInside(width: w, height: h), "\(line)")
            } else if let m = line.firstMatch(of: /^X(\d+),(\d+),(\d+),(\d+),(\d+)$/) {
                #expect(int(m.4) + int(m.3) <= w && int(m.5) + int(m.3) <= h, "\(line)")
            } else if let m = line.firstMatch(of: /^B(\d+),(\d+),0,1,(\d+),\d+,(\d+),N,"(.*)"$/) {
                let width = (11 * m.5.count + 35) * int(m.3)
                #expect(Box(x: int(m.1), y: int(m.2), width: width, height: int(m.4)).isInside(width: w, height: h), "\(line)")
            } else {
                #expect(["", "N", "q\(w)", "P1"].contains(String(line)), "Unerwartete Zeile: \(line)")
            }
        }
    }

    // MARK: CPCL

    @Test("CPCL bleibt innerhalb des Etiketts", arguments: [Resolution.dpi203, .dpi300], labelSizes)
    func cpclInBounds(resolution: Resolution, size: LabelSize) {
        let (w, h) = size.dots(resolution)
        let cpcl = TestLabel.cpcl(widthDots: w, heightDots: h, resolution: resolution, title: "LabelWerk",
                                  subtitle: "Zebra ZQ630", date: fixedDate, timeZone: utc)
        #expect(cpcl.unicodeScalars.allSatisfy { $0.isASCII })
        let r = CPCL.resolutionValue(resolution)
        #expect(cpcl.hasPrefix("! 0 \(r) \(r) \(h) 1\r\nPAGE-WIDTH \(w)\r\n"))
        #expect(cpcl.hasSuffix("FORM\r\nPRINT\r\n"))
        #expect(cpcl.contains("INVERSE-LINE "))
        #expect(!cpcl.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        var magnification = 1
        var pendingQR: (x: Int, y: Int, unit: Int)?
        for line in cpcl.components(separatedBy: "\r\n") {
            if let qr = pendingQR {
                #expect(line.hasPrefix("MA,"))
                let side = TestLabelLayout.qrModuleCount(byteCount: line.utf8.count - 3) * qr.unit
                #expect(Box(x: qr.x, y: qr.y, width: side, height: side).isInside(width: w, height: h), "QR")
                pendingQR = nil
            } else if let m = line.firstMatch(of: /^SETMAG (\d+) (\d+)$/) {
                magnification = max(1, int(m.1))
            } else if let m = line.firstMatch(of: /^TEXT 7 0 (\d+) (\d+) (.*)$/) {
                let box = Box(x: int(m.1), y: int(m.2), width: m.3.count * 13 * magnification, height: 24 * magnification)
                #expect(box.isInside(width: w, height: h), "\(line)")
            } else if let m = line.firstMatch(of: /^BOX (\d+) (\d+) (\d+) (\d+) (\d+)$/) {
                #expect(int(m.3) + int(m.5) <= w && int(m.4) + int(m.5) <= h, "\(line)")
            } else if let m = line.firstMatch(of: /^(?:INVERSE-)?LINE (\d+) (\d+) (\d+) (\d+) (\d+)$/) {
                let (x0, y0, x1, y1, t) = (int(m.1), int(m.2), int(m.3), int(m.4), int(m.5))
                if y0 == y1 {
                    #expect(x1 < w && y0 + t <= h, "\(line)")
                } else {
                    #expect(x0 == x1 && x0 + t <= w && y1 < h, "\(line)")
                }
            } else if let m = line.firstMatch(of: /^BARCODE 128 (\d+) 1 (\d+) (\d+) (\d+) (.*)$/) {
                let box = Box(x: int(m.3), y: int(m.4), width: (11 * m.5.count + 35) * int(m.1), height: int(m.2))
                #expect(box.isInside(width: w, height: h), "\(line)")
            } else if let m = line.firstMatch(of: /^BARCODE QR (\d+) (\d+) M 2 U (\d+)$/) {
                pendingQR = (int(m.1), int(m.2), int(m.3))
            } else {
                #expect(line.hasPrefix("! 0 ") || line.hasPrefix("PAGE-WIDTH ") || ["ENDQR", "FORM", "PRINT", ""].contains(line),
                        "Unerwartete Zeile: \(line)")
            }
        }
        #expect(magnification == 1 || cpcl.contains("SETMAG 0 0\r\nFORM"))
    }

    // MARK: Hilfen

    @Test("QR-Modulanzahl je Datenlänge")
    func qrModules() {
        #expect(TestLabelLayout.qrModuleCount(byteCount: 1) == 21)
        #expect(TestLabelLayout.qrModuleCount(byteCount: 14) == 21)
        #expect(TestLabelLayout.qrModuleCount(byteCount: 15) == 25)
        #expect(TestLabelLayout.qrModuleCount(byteCount: 42) == 29)
        #expect(TestLabelLayout.qrModuleCount(byteCount: 43) == 33)
    }

    @Test("Datumsstempel")
    func dateStamp() {
        let stamp = DateStamp(date: fixedDate, timeZone: utc)
        #expect(stamp.date == "09.11.2026")
        #expect(stamp.time == "14:03")
        #expect(stamp.iso == "2026-11-09")
        let berlin = DateStamp(date: fixedDate, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        #expect(berlin.time == "15:03")
    }

    @Test("Textanpassung wählt Varianten und kürzt")
    func textFitter() throws {
        let options = (1...4).reversed().map { FontOption(height: 10 * $0, advance: Double(6 * $0), font: "0", multiplier: $0) }
        let big = try #require(TextFitter.fit(["Langer Text", "Kurz"], width: 300, height: 40, options: options, ellipsis: "…"))
        #expect(big.text == "Langer Text" && big.font.height == 40)
        let short = try #require(TextFitter.fit(["Langer Text", "Kurz"], width: 100, height: 40, options: options, ellipsis: "…"))
        #expect(short.text == "Kurz" && short.font.height == 40)
        let truncated = try #require(TextFitter.fit(["ABCDEFGHIJKLMNOP"], width: 30, height: 40, options: options, ellipsis: "…"))
        #expect(truncated.text == "ABCD…" && truncated.font.height == 10)
        #expect(TextFitter.fit(["X"], width: 100, height: 5, options: options, ellipsis: "…") == nil)
    }
}

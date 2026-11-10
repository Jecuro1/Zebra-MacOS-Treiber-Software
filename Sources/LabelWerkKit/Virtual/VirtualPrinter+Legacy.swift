import Foundation
import LabelWerkCore
import LabelWerkImaging
import LabelWerkRender

/// Baut aus EPL2-Zeilen ein Etikett zusammen (`N` … `P`).
///
/// Nachgebildet werden Grafiken (`GW`, Bit 0 = schwarz), Linien (`LO`, `LE`, `LW`), Rahmen
/// (`X`) und Text (`A`, mit den Zellgrößen der EPL-Schriften 1–5 bei 203 dpi bzw. skaliert).
/// Barcodes (`B`, `b`) werden als Hinweis vermerkt.
struct EPLPageBuilder: Sendable {
    var width: Int?
    var height: Int?
    var referenceX = 0
    var referenceY = 0
    var elements: [LabelElement] = []
    var warnings: [RenderWarning] = []

    mutating func clear() {
        elements.removeAll()
        warnings.removeAll()
    }

    /// Zellgröße (Breite, Höhe) der EPL-Schriften 1–5 bei 203 dpi.
    static let fontCells: [String: (width: Int, height: Int)] = [
        "1": (8, 12), "2": (10, 16), "3": (12, 20), "4": (14, 24), "5": (32, 48),
    ]

    /// Wertet `A`, `GW`, `LO`, `LE`, `LW`, `X`, `B`/`b` aus. Liefert `false` für andere Befehle.
    mutating func addElement(command: String, parameters: [String], binary: [UInt8], dotsPerMM: Int) -> Bool {
        func int(_ index: Int) -> Int { index < parameters.count ? Int(parameters[index].trimmingCharacters(in: .whitespaces)) ?? 0 : 0 }
        switch command {
        case "GW":
            let perRow = max(0, int(2)), rows = max(0, int(3))
            guard perRow > 0, rows > 0, binary.count >= perRow * rows else { return true }
            // EPL: Bit 0 = schwarz → für MonoBitmap (1 = schwarz) invertieren.
            let data = binary.prefix(perRow * rows).map { ~$0 }
            let bitmap = MonoBitmap(width: perRow * 8, height: rows, data: Array(data))
            elements.append(.graphic(GraphicElement(origin: point(int(0), int(1)), bitmap: bitmap)))
        case "LO", "LE", "LW":
            let width = max(1, int(2)), height = max(1, int(3))
            elements.append(.box(BoxElement(origin: point(int(0), int(1)), width: width, height: height,
                                            thickness: min(width, height), color: command == "LW" ? .white : .black,
                                            reverse: command == "LE")))
        case "X":
            let x1 = int(0), y1 = int(1), thickness = max(1, int(2)), x2 = int(3), y2 = int(4)
            elements.append(.box(BoxElement(origin: point(min(x1, x2), min(y1, y2)),
                                            width: max(thickness, abs(x2 - x1)), height: max(thickness, abs(y2 - y1)),
                                            thickness: thickness)))
        case "A":
            guard parameters.count >= 8 else { return true }
            let rotation: FieldOrientation
            switch int(2) {
            case 1: rotation = .rotated90
            case 2: rotation = .inverted180
            case 3: rotation = .rotated270
            default: rotation = .normal
            }
            let scale = Double(max(1, dotsPerMM)) / 8.0
            let cell = Self.fontCells[parameters[3].trimmingCharacters(in: .whitespaces)] ?? (12, 20)
            let horizontal = max(1, int(4)), vertical = max(1, int(5))
            let text = Self.unquote(parameters[7...].joined(separator: ","))
            elements.append(.text(TextElement(origin: point(int(0), int(1)), fontName: "0",
                                              height: Int((Double(cell.height * vertical) * scale).rounded()),
                                              width: Int((Double(cell.width * horizontal) * scale).rounded()),
                                              orientation: rotation, text: text,
                                              reverse: parameters[6].trimmingCharacters(in: .whitespaces).uppercased() == "R")))
        case "B", "b":
            warnings.append(RenderWarning(command: command, message: "EPL-Barcodes werden im virtuellen Drucker nicht dargestellt."))
        default:
            return false
        }
        return true
    }

    private func point(_ x: Int, _ y: Int) -> LabelPoint {
        LabelPoint(x: x + referenceX, y: y + referenceY)
    }

    /// Entfernt Anführungszeichen und EPL-Maskierungen (`\"`, `\\`).
    static func unquote(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") { text.removeFirst() }
        if text.hasSuffix("\""), !text.hasSuffix("\\\"") { text.removeLast() }
        return text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

extension VirtualPrinter {

    // MARK: - EPL

    /// Eine EPL-Zeile (Hybridmodus `epl_zpl`).
    func handleEPL(_ line: [UInt8]) {
        guard !line.isEmpty else { return }
        // Kopf (Befehl und Parameter) ist Text; bei GW folgen Binärdaten nach dem 4. Komma.
        var headerEnd = line.count
        var binary: [UInt8] = []
        if line.count >= 2, VirtualPrinterStream.upper(line[0]) == 0x47, VirtualPrinterStream.upper(line[1]) == 0x57 {
            var commas = 0
            for (index, byte) in line.enumerated() where byte == 0x2C {
                commas += 1
                if commas == 4 {
                    headerEnd = index
                    binary = Array(line[(index + 1)...])
                    break
                }
            }
        }
        let header = VirtualPrinterStream.decodeText(Array(line[..<headerEnd])).trimmingCharacters(in: .whitespaces)
        guard let first = header.first else { return }
        // Befehlsname: bekannte Zweibuchstabenbefehle (GW, LO, ZT …), sonst ein Buchstabe gefolgt
        // von Parametern (P2, D10, q812 …).
        let twoLetter = header.prefix(2).uppercased()
        let command: String
        if ["GW", "LO", "LE", "LW", "ZT", "ZB", "UQ", "XA", "GK", "GI", "GG"].contains(twoLetter) {
            command = twoLetter
        } else {
            command = String(first)
        }
        let parameterText = String(header.dropFirst(command.count))
        let parameters = parameterText.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        func int(_ index: Int) -> Int? {
            index < parameters.count ? Int(parameters[index].trimmingCharacters(in: .whitespaces)) : nil
        }

        if eplPage.addElement(command: command, parameters: parameters, binary: binary, dotsPerMM: resolution.dotsPerMM) {
            return
        }
        switch command {
        case "N":
            eplPage.clear()
        case "q":
            if let width = int(0) { eplPage.width = min(max(1, width), model.printWidthDots(resolution)) }
        case "Q":
            if let height = int(0) {
                eplPage.height = max(1, height)
                store.update("zpl.label_length", String(min(model.maxLabelLengthDots(resolution), max(1, height))))
            }
            let mode = parameters.count > 1 ? parameters[1].trimmingCharacters(in: .whitespaces).uppercased() : ""
            if mode == "0" {
                store.update("ezpl.media_type", "continuous")
            } else if mode.hasPrefix("B") {
                store.update("ezpl.media_type", "mark")
            } else if !mode.isEmpty {
                store.update("ezpl.media_type", "gap/notch")
            }
        case "S":
            if let speed = int(0) { store.update("media.speed", String(speed)) }
        case "D":
            if let density = int(0) { store.update("print.tone", String(min(30, max(0, density * 2)))) }
        case "ZT":
            printInverted = false
        case "ZB":
            printInverted = true
        case "O":
            let options = parameterText.uppercased()
            if options.contains("D") {
                store.update("ezpl.print_method", "direct thermal")
            } else if model.supportsThermalTransfer {
                store.update("ezpl.print_method", "thermal trans")
            }
            if options.contains("C") {
                store.update("media.printmode", "cutter")
            } else if options.contains("P") {
                store.update("media.printmode", "peel off")
            } else {
                store.update("media.printmode", "tear off")
            }
        case "R":
            eplPage.referenceX = max(0, int(0) ?? 0)
            eplPage.referenceY = max(0, int(1) ?? 0)
        case "P":
            let sets = max(1, int(0) ?? 1)
            let copies = max(1, int(1) ?? 1)
            let label = RenderedLabel(widthDots: eplPage.width ?? printWidthDots,
                                      heightDots: eplPage.height ?? labelLengthDots,
                                      dotsPerMM: resolution.dotsPerMM, elements: eplPage.elements,
                                      quantity: sets * copies, inverted: printInverted, mirrored: false,
                                      warnings: eplPage.warnings)
            printOrQueue(label)
        case "U":
            if command == "U", header.count == 1 {
                printReport(title: "PRINTER CONFIGURATION", lines: configurationEntries().map { "\($0.value)  \($0.name)" })
            }
        case "UQ":
            var text = "\(hostModelName)  \(store.rawValue("appl.name") ?? identity.firmware)\r\n"
            text += "S/N: \(serialNumber)\r\n"
            text += "Image buffer size:\(Self.ramBytes / 1024)K\r\n"
            text += "q\(eplPage.width ?? printWidthDots) Q\(eplPage.height ?? labelLengthDots),24\r\n"
            text += "S\(Int(Double(store.rawValue("media.speed") ?? "4") ?? 4)) D\(intValue("print.tone") / 2)\r\n"
            respond(text)
        case "XA":
            calibrate()
        default:
            break
        }
    }

    // MARK: - CPCL

    /// Ein CPCL-Block `! 0 …` bzw. `! UTILITIES` bis `PRINT`.
    func handleCPCL(_ bytes: [UInt8]) {
        var lines: [(text: String, binary: [UInt8])] = []
        var index = 0
        while index < bytes.count {
            while index < bytes.count, bytes[index] == 0x0D || bytes[index] == 0x0A { index += 1 }
            guard index < bytes.count else { break }
            // CG mit Binärdaten
            let upperPrefix = String(decoding: bytes[index..<min(bytes.count, index + 20)].map(VirtualPrinterStream.upper),
                                     as: UTF8.self)
            if upperPrefix.hasPrefix("CG ") || upperPrefix.hasPrefix("COMPRESSED-GRAPHICS ") {
                var cursor = index + (upperPrefix.hasPrefix("CG ") ? 3 : 20)
                var numbers: [Int] = []
                var digits: [UInt8] = []
                while cursor < bytes.count, numbers.count < 4 {
                    let byte = bytes[cursor]
                    if VirtualPrinterStream.isDigit(byte) {
                        digits.append(byte)
                    } else if !digits.isEmpty {
                        numbers.append(Int(String(decoding: digits, as: UTF8.self)) ?? 0)
                        digits.removeAll()
                    }
                    cursor += 1
                }
                guard numbers.count == 4 else { break }
                let length = numbers[0] * numbers[1]
                let end = min(bytes.count, cursor + length)
                lines.append(("CG \(numbers[0]) \(numbers[1]) \(numbers[2]) \(numbers[3])", Array(bytes[cursor..<end])))
                index = end
                continue
            }
            var end = index
            while end < bytes.count, bytes[end] != 0x0D, bytes[end] != 0x0A { end += 1 }
            lines.append((VirtualPrinterStream.decodeText(Array(bytes[index..<end])), []))
            index = end
        }
        guard let headerLine = lines.first?.text else { return }
        let header = headerLine.split(separator: " ").map(String.init)
        if header.count >= 2, header[1].uppercased().hasPrefix("UTIL") {
            for line in lines.dropFirst() {
                switch line.text.trimmingCharacters(in: .whitespaces).uppercased() {
                case "GAP-SENSE": store.update("ezpl.media_type", "gap/notch"); store.update("media.sense_mode", "gap")
                case "BAR-SENSE": store.update("ezpl.media_type", "mark"); store.update("media.sense_mode", "bar")
                default: break
                }
            }
            return
        }
        // ! {versatz} {hres} {vres} {höhe} {menge}
        let height = header.count > 4 ? Int(header[4]) ?? labelLengthDots : labelLengthDots
        let quantity = header.count > 5 ? Int(header[5]) ?? 1 : 1
        var width = printWidthDots
        var elements: [LabelElement] = []
        var warnings: [RenderWarning] = []
        var journal = false
        for line in lines.dropFirst() {
            let words = line.text.split(separator: " ").map(String.init)
            guard let keyword = words.first?.uppercased() else { continue }
            func number(_ i: Int) -> Int { i < words.count ? Int(words[i]) ?? 0 : 0 }
            switch keyword {
            case "PAGE-WIDTH", "PW":
                width = min(max(1, number(1)), model.printWidthDots(resolution))
            case "CG", "EG", "EXPANDED-GRAPHICS":
                let perRow = number(1), rows = number(2)
                let data: [UInt8]
                if keyword == "CG" {
                    data = line.binary
                } else {
                    data = VirtualPrinterStream.decodeHex(Array((words.count > 5 ? words[5] : "").utf8))
                }
                guard perRow > 0, rows > 0, data.count >= perRow * rows else { continue }
                let bitmap = MonoBitmap(width: perRow * 8, height: rows, data: Array(data.prefix(perRow * rows)))
                elements.append(.graphic(GraphicElement(origin: LabelPoint(x: number(3), y: number(4)), bitmap: bitmap)))
            case "BOX":
                let x0 = number(1), y0 = number(2), x1 = number(3), y1 = number(4), t = max(1, number(5))
                elements.append(.box(BoxElement(origin: LabelPoint(x: min(x0, x1), y: min(y0, y1)),
                                                width: max(t, abs(x1 - x0)), height: max(t, abs(y1 - y0)), thickness: t)))
            case "LINE", "L":
                let x0 = number(1), y0 = number(2), x1 = number(3), y1 = number(4), t = max(1, number(5))
                if x0 == x1 || y0 == y1 {
                    let w = x0 == x1 ? t : abs(x1 - x0)
                    let h = y0 == y1 ? t : abs(y1 - y0)
                    elements.append(.box(BoxElement(origin: LabelPoint(x: min(x0, x1), y: min(y0, y1)),
                                                    width: max(1, w), height: max(1, h), thickness: min(max(1, w), max(1, h)))))
                } else {
                    elements.append(.diagonal(DiagonalElement(origin: LabelPoint(x: min(x0, x1), y: min(y0, y1)),
                                                              width: abs(x1 - x0), height: abs(y1 - y0), thickness: t,
                                                              leansRight: (x1 > x0) != (y1 > y0))))
                }
            case "TEXT", "T", "T90", "TEXT90", "T180", "TEXT180", "T270", "TEXT270":
                guard words.count >= 6 else { continue }
                let orientation: FieldOrientation
                switch keyword {
                case "T90", "TEXT90": orientation = .rotated270
                case "T180", "TEXT180": orientation = .inverted180
                case "T270", "TEXT270": orientation = .rotated90
                default: orientation = .normal
                }
                // CPCL-Schriften: Größe 0 entspricht etwa 3 mm Zeilenhöhe.
                let size = number(2)
                let cellHeight = (3 + size) * resolution.dotsPerMM
                let text = words[5...].joined(separator: " ")
                elements.append(.text(TextElement(origin: LabelPoint(x: number(3), y: number(4)), fontName: "0",
                                                  height: cellHeight, width: cellHeight * 3 / 4,
                                                  orientation: orientation, text: text)))
            case "JOURNAL":
                journal = true
            case "BARCODE", "B", "VBARCODE", "VB":
                warnings.append(RenderWarning(command: keyword, message: "CPCL-Barcodes werden im virtuellen Drucker nicht dargestellt."))
            case "CONTRAST":
                store.update("print.tone", String(min(30, number(1) * 10)))
            case "SPEED":
                store.update("media.speed", String(max(2, number(1))))
            default:
                break
            }
        }
        if journal { store.update("media.type", "journal") }
        let label = RenderedLabel(widthDots: width, heightDots: max(1, height), dotsPerMM: resolution.dotsPerMM,
                                  elements: elements, quantity: max(1, quantity), warnings: warnings)
        printOrQueue(label)
    }
}

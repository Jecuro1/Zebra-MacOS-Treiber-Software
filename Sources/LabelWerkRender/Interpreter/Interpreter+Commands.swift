import Foundation
import LabelWerkCore
import LabelWerkImaging

/// Befehlsausführung des Interpreters.
extension InterpreterEngine {

    /// Formatbefehle ohne Wirkung auf das Druckbild (Medien, Sensorik, Netzwerk, Host-Abfragen,
    /// RFID …). Sie werden stillschweigend akzeptiert.
    static let silentCaretCommands: Set<String> = [
        "MM", "MN", "MT", "MD", "MF", "MP", "ML", "MW", "MA", "MI", "PR", "PF", "PH", "PP", "PN", "PA",
        "JS", "JU", "JZ", "JT", "JW", "JJ", "JH", "JI", "JB", "KD", "KL", "KN", "KP", "KV", "SC", "SE",
        "SL", "SO", "SP", "SQ", "SR", "SS", "ST", "SX", "SZ", "SI", "XB", "XS", "ZZ", "HH", "HW", "HF",
        "HG", "HT", "HV", "HY", "HZ", "HR", "WD", "TO", "CM", "CO", "CV", "FL", "LF", "NC", "ND", "NI",
        "NN", "NP", "NS", "NT", "NW", "NB", "CN", "CP", "LT", "FX", "CC", "CT", "CD", "XZ",
        "RS", "RF", "RW", "RB", "RR", "RT", "RU", "RL", "RM", "RN", "RQ", "RZ", "WT", "WF", "RI", "RA",
        "RE", "RV",
    ]

    /// Steuerbefehle ohne Wirkung auf das Druckbild.
    static let silentTildeCommands: Set<String> = [
        "SD", "TA", "JC", "JG", "JL", "JR", "JA", "JX", "HS", "HI", "HQ", "HM", "HD", "HB", "HU", "WC",
        "WL", "WQ", "PS", "PP", "PH", "PL", "PR", "RO", "NC", "NT", "JB", "JD", "JE", "JF", "JI", "JN",
        "JO", "JP", "JQ", "JS", "KB", "DB", "DE", "DS", "DT", "DU", "DN", "CC", "CT", "CD",
    ]

    /// Residente Schriften fester Größe (Zebra-Schrifttabelle: P 20 × 18 … V 80 × 71).
    static let fixedSizeFonts: Set<String> = ["P", "Q", "R", "S", "T", "U", "V"]

    /// Barcode-Symbologien, die ZPL kennt, die Vorschau aber nicht erzeugt.
    static let unsupportedBarcodes: [String: String] = [
        "B0": "Aztec", "BO": "Aztec", "B1": "Code 11", "B4": "Code 49", "B5": "Planet Code",
        "BB": "CODABLOCK", "BD": "MaxiCode", "BF": "MicroPDF417", "BI": "Industrial 2 of 5",
        "BJ": "Standard 2 of 5", "BM": "MSI", "BP": "Plessey", "BR": "GS1 DataBar",
        "BS": "UPC/EAN-Zusatzcode", "BT": "TLC39", "BZ": "POSTNET/USPS",
    ]

    // MARK: Steuerbefehle (~)

    mutating func executeControl(_ token: ZPLToken) {
        switch token.command {
        case "DG": downloadGraphic(token)
        case "DY": downloadObject(token)
        case "EG":
            for key in storedGraphics.keys where key.hasSuffix(".GRF") { storedGraphics.removeValue(forKey: key) }
        default:
            if !Self.silentTildeCommands.contains(token.command) {
                warn(token.name, token.command.isEmpty
                     ? "Einzelnes Präfixzeichen ohne Befehl – ignoriert."
                     : "Unbekannter Steuerbefehl – ignoriert.")
            }
        }
    }

    // MARK: Formatbefehle (^)

    mutating func execute(_ token: ZPLToken, fromStored: Bool) {
        if token.prefix == "~" {
            executeControl(token)
            return
        }
        let p = ZPLParameters(token)
        let name = token.name
        switch token.command {
        // Feldposition und -abschluss
        case "FO", "FT":
            if field.hasContent && field.position != nil { completeField(implicit: true) }
            setPosition(p, typeset: token.command == "FT")
        case "FS":
            completeField(implicit: false)
        case "FD", "FV":
            field.data = token.arguments
            field.isVariable = token.command == "FV"
        case "FH":
            field.hexIndicator = token.arguments.first ?? "_"
        case "FR":
            field.reverse = true
        case "FN":
            field.fieldNumber = p.int(0, in: 0...9999) ?? 0
            field.fieldNumberFromStored = fromStored
        case "FB":
            field.block = FieldBlock(width: p.int(0, in: 0...32_000) ?? 0,
                                     maxLines: p.int(1, in: 1...9999) ?? 1,
                                     lineSpacing: p.int(2, in: -9999...9999) ?? 0,
                                     justification: p.character(3).flatMap { TextJustification(rawValue: String($0)) } ?? .left,
                                     hangingIndent: p.int(4, in: 0...9999) ?? 0)
        case "TB":
            field.orientationOverride = p.orientation(0)
            field.block = FieldBlock(width: p.int(1, in: 0...32_000) ?? 0, maxLines: 1,
                                     lineSpacing: 0, justification: .left, hangingIndent: 0, truncatesOverflow: true)
            field.textBlockHeight = p.int(2, in: 1...32_000)
        case "FP":
            switch p.character(0) {
            case "V": field.direction = .vertical
            case "R": field.direction = .reverse
            default: field.direction = .horizontal
            }
            field.characterGap = p.int(1, in: 0...9999) ?? 0
        case "FW":
            if let orientation = p.orientation(0) { printer.defaultOrientation = orientation }
            if let justification = p.int(1, in: 0...2) { printer.defaultJustification = justification }
        case "FC":
            let indicators = token.parameters.compactMap { $0.first }
            field.clockIndicators = indicators.isEmpty ? ["%"] : indicators
        case "SN":
            field.serial = .number(start: p.string(0) ?? "1", increment: p.int(1) ?? 1,
                                   leadingZeros: p.bool(2) ?? false)
        case "SF":
            field.serial = .mask(base: "", mask: p.raw(0) ?? "", increment: p.raw(1) ?? "1")

        // Schriften und Zeichensatz
        case "A":
            selectFont(token)
        case "CF":
            changeDefaultFont(p)
        case "CI":
            changeCharacterSet(p)
        case "CW":
            if let alias = p.character(0), let file = p.string(1) {
                printer.fontAliases[String(alias)] = ObjectName.normalize(file, defaultExtension: ".FNT")
            } else {
                warn(name, "Ungültige Schriftzuordnung – ignoriert.")
            }
        case "GS":
            field.symbolFont = FontSelection(name: "GS", orientation: p.orientation(0), height: p.int(1),
                                             width: p.int(2))

        // Barcodes
        case "BY":
            if let module = p.int(0, in: 1...10) { printer.barcodeModuleWidth = module }
            if let ratio = p.double(1) { printer.barcodeRatio = min(3.0, max(2.0, ratio)) }
            if let height = p.int(2, in: 1...32_000) { printer.barcodeHeight = height }
        case "BC", "B3", "BA", "BE", "B8", "BU", "B9", "B2", "BK", "BL", "BQ", "BX", "B7":
            field.barcode = BarcodeSpec(command: name, parameters: p)
        case _ where Self.unsupportedBarcodes[token.command] != nil:
            field.barcode = BarcodeSpec(command: name, parameters: p)

        // Grafik
        case "GB": addBox(p)
        case "GC": addCircle(p)
        case "GE": addEllipse(p)
        case "GD": addDiagonal(p)
        case "GF": addGraphicField(p, delimiter: token.delimiter)
        case "XG", "IM": recallGraphic(p, command: name, magnification: token.command == "XG")
        case "IL": loadImage(p)
        case "IS": saveImage(p)
        case "ID": deleteObjects(p)

        // Etikett
        case "PW":
            if let width = p.int(0, in: 2...32_000) { printer.printWidth = width }
        case "LL":
            if let length = p.int(0, in: 1...32_000) { printer.labelLength = length }
        case "LH":
            printer.labelHome = LabelPoint(x: p.int(0, in: 0...32_000) ?? printer.labelHome.x,
                                           y: p.int(1, in: 0...32_000) ?? printer.labelHome.y)
        case "LS":
            printer.labelShift = p.int(0, in: -9999...9999) ?? 0
        case "LR":
            printer.labelReverse = p.bool(0) ?? false
        case "PO":
            switch p.character(0) {
            case "I": printer.inverted = true
            case "N", nil: printer.inverted = false
            default: warn(name, "Unbekannte Druckausrichtung „\(p.string(0) ?? "")“ – erwartet N oder I.")
            }
        case "PM":
            printer.mirrored = p.bool(0) ?? false
        case "PQ":
            format?.quantity = p.int(0, in: 1...99_999_999) ?? 1
            format?.replicates = p.int(2, in: 0...99_999_999) ?? 0
        case "MU":
            switch p.character(0) {
            case "D", nil: break
            case "I", "M":
                warn(name, "Maßeinheit Zoll/Millimeter wird nicht nachgebildet – Werte werden als Punkte gelesen.")
            default:
                warn(name, "Unbekannte Maßeinheit – Werte werden als Punkte gelesen.")
            }
            if let from = p.int(1), let to = p.int(2), from != to {
                warn(name, "Auflösungsumrechnung (\(from) → \(to) dpi) wird nicht nachgebildet.")
            }
        case "MC":
            printer.mapClear = p.bool(0) ?? true
        case "JM":
            if p.character(0) == "B" {
                warn(name, "Halbierte Punktdichte (^JMB) wird nicht nachgebildet.")
            }
        case "FM":
            warn(name, "Mehrere Feldursprünge (^FM) werden nicht nachgebildet.")
        case "XA":
            break
        case "XF":
            break   // bereits durch processFormat ersetzt
        case "DF":
            warn(name, "Weitere Formatdefinition im selben Format – ignoriert.")
        default:
            if !Self.silentCaretCommands.contains(token.command) {
                warn(name, token.command.isEmpty
                     ? "Einzelnes Präfixzeichen ohne Befehl – ignoriert."
                     : "Unbekannter oder nicht unterstützter Befehl – ignoriert.")
            }
        }
    }

    // MARK: Feldposition

    private mutating func setPosition(_ p: ZPLParameters, typeset: Bool) {
        var x = p.int(0, in: 0...32_000)
        var y = p.int(1, in: 0...32_000)
        if typeset, x == nil, y == nil, let end = format?.lastTypesetEnd {
            x = end.x
            y = end.y
        }
        field.position = FieldPosition(x: x ?? 0, y: y ?? 0, kind: typeset ? .typeset : .origin,
                                       justification: p.int(2, in: 0...2) ?? printer.defaultJustification)
    }

    // MARK: Schriften

    private mutating func selectFont(_ token: ZPLToken) {
        guard let first = token.arguments.first else {
            field.font = FontSelection(name: printer.defaultFontName, orientation: nil, height: nil, width: nil)
            return
        }
        let identifier = Character(first.uppercased())
        let rest = String(token.arguments.dropFirst())
        let p = ZPLParameters(rest.isEmpty ? [] : rest.split(separator: token.delimiter,
                                                             omittingEmptySubsequences: false).map(String.init))
        var name: String
        if identifier == "@" {
            if let file = p.string(3) {
                name = ObjectName.normalize(file, defaultExtension: ".FNT")
            } else {
                warn("^A@", "Schriftdatei fehlt – Schrift 0 wird verwendet.")
                name = "0"
            }
        } else if identifier.isASCII && (identifier.isLetter || identifier.isNumber) {
            name = String(identifier)
            if let alias = printer.fontAliases[name] {
                name = alias
            } else if !ZPLFonts.isResident(name) {
                warn("^A", "Schrift „\(name)“ ist nicht resident – Darstellung mit Ersatzschrift.")
            }
        } else {
            warn("^A", "Ungültiger Schriftbezeichner „\(identifier)“ – Standardschrift wird verwendet.")
            name = printer.defaultFontName
        }
        field.font = FontSelection(name: name, orientation: p.orientation(0), height: p.int(1), width: p.int(2))
    }

    private mutating func changeDefaultFont(_ p: ZPLParameters) {
        if let identifier = p.string(0)?.first {
            var name = identifier.uppercased()
            if let alias = printer.fontAliases[name] {
                name = alias
            } else if !ZPLFonts.isResident(name) {
                warn("^CF", "Schrift „\(name)“ ist nicht resident – Darstellung mit Ersatzschrift.")
            }
            printer.defaultFontName = name
        }
        if let height = p.int(1), height > 0 {
            printer.defaultFontHeight = height
            printer.defaultFontWidth = p.int(2).flatMap { $0 > 0 ? $0 : nil }
        } else if let width = p.int(2), width > 0 {
            printer.defaultFontWidth = width
        }
    }

    private mutating func changeCharacterSet(_ p: ZPLParameters) {
        if let value = p.int(0) {
            if let set = ZPLCharacterSet(ciValue: value) {
                printer.characterSet = set
                if (1...12).contains(value) {
                    warn("^CI", "Nationale Zeichenersetzungen von ^CI\(value) werden nicht nachgebildet (Codepage 850).")
                }
            } else {
                warn("^CI", "Zeichensatz ^CI\(value) wird nicht nachgebildet – Text wird unverändert dargestellt.")
            }
        }
        if p.count > 1, (1..<p.count).contains(where: { p.string($0) != nil }) {
            warn("^CI", "Zeichenumbelegungen in ^CI werden nicht nachgebildet.")
        }
    }

    // MARK: Feldabschluss

    /// Schließt das aktuelle Feld ab und erzeugt seine Elemente.
    mutating func completeField(implicit: Bool) {
        let current = field
        field = FieldState()
        guard format != nil else { return }
        // In Abrufformaten liefern ^FN-Felder nur Daten für das gespeicherte Format.
        if format!.isRecall, current.fieldNumber != nil, !current.fieldNumberFromStored { return }

        var data = current.data.map { raw in
            current.hexIndicator.map { FieldHexDecoder.decode(raw, indicator: $0, characterSet: printer.characterSet) } ?? raw
        }
        if format!.isRecall, let number = current.fieldNumber, let value = format!.fieldValues[number] {
            data = value
        }
        var serial = current.serial
        switch serial {
        case .number(let start, _, _)?:
            data = start
        case .mask(_, let mask, let increment)?:
            serial = .mask(base: data ?? "", mask: mask, increment: increment)
        case nil:
            break
        }
        if !current.clockIndicators.isEmpty, let text = data {
            data = ClockFormatter.format(text, indicators: current.clockIndicators, date: now, timeZone: timeZone)
        }
        guard data != nil || !current.graphics.isEmpty else { return }

        format!.hasPrintableContent = true
        if implicit {
            warn("^FS", "Feld ohne ^FS abgeschlossen.")
        }
        let start = format!.elements.count
        let result = makeElements(for: current, data: data)
        format!.elements.append(contentsOf: result.elements)
        format!.variableFlags.append(contentsOf: repeatElement(current.isVariable, count: result.elements.count))
        if let end = result.typesetEnd {
            format!.lastTypesetEnd = LabelPoint(x: max(0, end.x - printer.labelHome.x + printer.labelShift),
                                                y: max(0, end.y - printer.labelHome.y))
        }
        if let serial {
            var recorded = current
            recorded.data = data
            format!.serialRecords.append(SerialRecord(elementRange: start..<format!.elements.count,
                                                      field: recorded, serial: serial, printer: printer))
        }
    }

    /// Erzeugt die Elemente eines Felds (ohne Seiteneffekte außer Hinweisen).
    mutating func makeElements(for field: FieldState, data: String?) -> (elements: [LabelElement], typesetEnd: LabelPoint?) {
        let reverse = field.reverse || printer.labelReverse
        let position = field.position
            ?? FieldPosition(x: 0, y: 0, kind: .origin, justification: printer.defaultJustification)
        let placement = FieldPlacement(
            base: LabelPoint(x: printer.labelHome.x + position.x - printer.labelShift,
                             y: printer.labelHome.y + position.y),
            kind: position.kind, rightJustified: position.justification == 1)

        if !field.graphics.isEmpty {
            return (field.graphics.flatMap { graphicElements($0, placement: placement, reverse: reverse) }, nil)
        }
        if let barcode = field.barcode {
            return (makeBarcode(barcode, field: field, data: data ?? "", placement: placement, reverse: reverse), nil)
        }
        guard let text = data, !text.isEmpty else { return ([], nil) }
        return makeText(text, field: field, placement: placement, reverse: reverse)
    }

    private mutating func makeText(_ text: String, field: FieldState, placement: FieldPlacement,
                                   reverse: Bool) -> (elements: [LabelElement], typesetEnd: LabelPoint?) {
        let selection = field.symbolFont ?? field.font
        let fontName = selection?.name ?? printer.defaultFontName
        let orientation = field.orientationOverride ?? selection?.orientation ?? printer.defaultOrientation
        let requested: (Int?, Int?)
        if let selection, selection.height != nil || selection.width != nil {
            requested = (selection.height, selection.width)
        } else if Self.fixedSizeFonts.contains(fontName) {
            // P–V sind Schriften fester Größe: ohne Angabe gilt ihre eigene Zellgröße.
            requested = (nil, nil)
        } else {
            requested = (printer.defaultFontHeight, printer.defaultFontWidth)
        }
        let size = ZPLFonts.resolveSize(fontName: fontName, height: requested.0, width: requested.1,
                                        dotsPerMM: dotsPerMM)
        var block = field.block
        if var textBlock = block, let blockHeight = field.textBlockHeight {
            textBlock.maxLines = max(1, blockHeight / max(1, size.height))
            block = textBlock
        }
        if let block, block.width <= 0 {
            warn(block.truncatesOverflow ? "^TB" : "^FB", "Blockbreite 0 – der Text wird nicht gedruckt.")
            return ([], nil)
        }
        var element = TextElement(origin: .zero, fontName: fontName, height: size.height, width: size.width,
                                  orientation: orientation, text: text, reverse: reverse, block: block,
                                  direction: field.direction, characterGap: field.characterGap)
        let layout = TextLayout(element: element, dotsPerMM: dotsPerMM)
        if let block, layout.overflowLines > 0, !block.truncatesOverflow {
            warn("^FB", "Der Text benötigt \(layout.lineCount) Zeilen, ^FB erlaubt \(block.maxLines) – "
                 + "überzählige Zeilen überdrucken die letzte Zeile.")
        }
        element.origin = placement.origin(width: layout.width, height: layout.height, orientation: orientation,
                                          anchorX: 0, anchorRightX: Double(layout.width),
                                          anchorY: Double(layout.lastBaseline))
        let end = FieldPlacement.map(layout.endX, Double(layout.lastBaseline), width: layout.width,
                                     height: layout.height, orientation: orientation)
        let typesetEnd = LabelPoint(x: element.origin.x + Int(end.x.rounded()),
                                    y: element.origin.y + Int(end.y.rounded()))
        return ([.text(element)], typesetEnd)
    }
}

/// Umrechnung von Feldposition (`^FO`/`^FT`) und Feldgröße in den Elementursprung.
struct FieldPlacement {
    let base: LabelPoint
    let kind: FieldPosition.Kind
    let rightJustified: Bool

    /// Ursprung (linke obere Ecke des gedrehten Feldrechtecks).
    ///
    /// - Parameters:
    ///   - width, height: ungedrehte Feldgröße.
    ///   - anchorX, anchorRightX, anchorY: `^FT`-Bezugspunkt in Feldkoordinaten (links bzw. bei
    ///     rechtsbündiger Ausrichtung rechts).
    func origin(width: Int, height: Int, orientation: FieldOrientation,
                anchorX: Double, anchorRightX: Double, anchorY: Double) -> LabelPoint {
        switch kind {
        case .origin:
            let rotatedWidth = (orientation == .rotated90 || orientation == .rotated270) ? height : width
            return LabelPoint(x: base.x - (rightJustified ? rotatedWidth : 0), y: base.y)
        case .typeset:
            let anchor = Self.map(rightJustified ? anchorRightX : anchorX, anchorY, width: width, height: height,
                                  orientation: orientation)
            return LabelPoint(x: base.x - Int(anchor.x.rounded()), y: base.y - Int(anchor.y.rounded()))
        }
    }

    /// Bildet einen Punkt aus ungedrehten Feldkoordinaten in den Versatz zum Ursprung des
    /// gedrehten Feldrechtecks ab (Drehung im Uhrzeigersinn).
    static func map(_ x: Double, _ y: Double, width: Int, height: Int,
                    orientation: FieldOrientation) -> (x: Double, y: Double) {
        let w = Double(width), h = Double(height)
        switch orientation {
        case .normal: return (x, y)
        case .rotated90: return (h - y, x)
        case .inverted180: return (w - x, h - y)
        case .rotated270: return (y, w - x)
        }
    }
}

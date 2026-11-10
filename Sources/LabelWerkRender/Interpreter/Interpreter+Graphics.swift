import Foundation
import LabelWerkCore
import LabelWerkImaging

/// Grafikbefehle (`^GB`, `^GC`, `^GE`, `^GD`, `^GF`, `^XG`, `^IM`, `^IL`, `^IS`, `^ID`) und
/// Objekt-Downloads (`~DG`, `~DY`).
extension InterpreterEngine {

    /// Obergrenze für Grafikdaten eines Befehls (Schutz vor Speichererschöpfung): 32 MiB.
    static let maxGraphicBytes = 32 * 1024 * 1024

    // MARK: Formen

    mutating func addBox(_ p: ZPLParameters) {
        let thickness = p.int(2, in: 1...32_000) ?? 1
        let width = max(thickness, p.int(0, in: 1...32_000) ?? thickness)
        let height = max(thickness, p.int(1, in: 1...32_000) ?? thickness)
        field.graphics.append(.box(width: width, height: height, thickness: thickness,
                                   color: lineColor(p, 3), rounding: p.int(4, in: 0...8) ?? 0))
    }

    mutating func addCircle(_ p: ZPLParameters) {
        let diameter = p.int(0, in: 3...4095) ?? 3
        let thickness = p.int(1, in: 1...4095) ?? 1
        field.graphics.append(.ellipse(width: diameter, height: diameter, thickness: thickness, color: lineColor(p, 2)))
    }

    mutating func addEllipse(_ p: ZPLParameters) {
        let thickness = p.int(2, in: 1...4095) ?? 1
        let width = p.int(0, in: 3...4095) ?? max(3, thickness)
        let height = p.int(1, in: 3...4095) ?? max(3, thickness)
        field.graphics.append(.ellipse(width: width, height: height, thickness: thickness, color: lineColor(p, 3)))
    }

    mutating func addDiagonal(_ p: ZPLParameters) {
        let thickness = p.int(2, in: 1...32_000) ?? 1
        let width = max(thickness, p.int(0, in: 1...32_000) ?? thickness)
        let height = max(thickness, p.int(1, in: 1...32_000) ?? thickness)
        let leansRight: Bool
        switch p.string(4)?.first {
        case "L", "l", "\\": leansRight = false
        default: leansRight = true
        }
        field.graphics.append(.diagonal(width: width, height: height, thickness: thickness,
                                        color: lineColor(p, 3), leansRight: leansRight))
    }

    private func lineColor(_ p: ZPLParameters, _ index: Int) -> LineColor {
        p.character(index) == "W" ? .white : .black
    }

    // MARK: Rastergrafiken

    /// `^GFa,b,c,d,data`: a = Format, b = Datenbytes, c = Grafikbytes gesamt, d = Bytes je Zeile.
    mutating func addGraphicField(_ p: ZPLParameters, delimiter: Character) {
        let format = p.string(0) ?? "A"
        guard let total = p.int(2), let bytesPerRow = p.int(3), total >= 0, bytesPerRow > 0 else {
            warn("^GF", "Grafikfeld ohne gültige Gesamtgröße bzw. Bytes je Zeile – ignoriert.")
            return
        }
        guard total <= Self.maxGraphicBytes else {
            warn("^GF", "Grafikfeld mit \(total) Bytes ist zu groß – ignoriert.")
            return
        }
        let data = p.joined(from: 4, separator: delimiter)
        do {
            let bitmap = try ZPLGraphicEncoder.decodeGraphicField(format: format, totalBytes: total,
                                                                  bytesPerRow: bytesPerRow, data: data)
            if total == 0 || bitmap.height == 0 { return }
            field.graphics.append(.bitmap(bitmap, magnificationX: 1, magnificationY: 1))
        } catch {
            warn("^GF", "Grafikdaten ungültig: \(error.localizedDescription)")
        }
    }

    /// `^XGd:o.x,mx,my` bzw. `^IMd:o.x`.
    mutating func recallGraphic(_ p: ZPLParameters, command: String, magnification: Bool) {
        let name = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".GRF")
        let mx = magnification ? (p.int(1, in: 1...10) ?? 1) : 1
        let my = magnification ? (p.int(2, in: 1...10) ?? 1) : 1
        if let bitmap = lookup(name, in: storedGraphics) {
            field.graphics.append(.bitmap(bitmap, magnificationX: mx, magnificationY: my))
        } else if let elements = lookup(name, in: storedImages) {
            if mx != 1 || my != 1 {
                warn(command, "Vergrößerung gespeicherter Etikettenbilder (^IS) wird nicht nachgebildet.")
            }
            field.graphics.append(.storedElements(elements))
        } else {
            warn(command, "Grafik „\(name)“ nicht gefunden.")
        }
    }

    /// `^ILd:o.x`: lädt ein gespeichertes Bild an den Etikettenursprung (vor allen Feldern).
    mutating func loadImage(_ p: ZPLParameters) {
        let name = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".GRF")
        let home = printer.labelHome
        var elements: [LabelElement] = []
        if let bitmap = lookup(name, in: storedGraphics) {
            elements = [.graphic(GraphicElement(origin: home, bitmap: bitmap))]
        } else if let stored = lookup(name, in: storedImages) {
            elements = stored.map { $0.offset(by: home) }
        } else {
            warn("^IL", "Bild „\(name)“ nicht gefunden.")
            return
        }
        format?.elements.append(contentsOf: elements)
        format?.variableFlags.append(contentsOf: repeatElement(false, count: elements.count))
        format?.hasPrintableContent = true
    }

    /// `^ISd:o.x,p`: speichert das bisherige Etikettenbild; p = N unterdrückt den Druck.
    mutating func saveImage(_ p: ZPLParameters) {
        let name = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".GRF")
        storedImages[name] = format?.elements ?? []
        if p.bool(1) == false { format?.suppressPrint = true }
    }

    /// `^IDd:o.x`: löscht gespeicherte Objekte (Platzhalter `*` und `?` erlaubt).
    mutating func deleteObjects(_ p: ZPLParameters) {
        let pattern = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".GRF")
        for key in storedGraphics.keys where ObjectName.matches(key, pattern: pattern) {
            storedGraphics.removeValue(forKey: key)
        }
        for key in storedImages.keys where ObjectName.matches(key, pattern: pattern) {
            storedImages.removeValue(forKey: key)
        }
        for key in storedFormats.keys where ObjectName.matches(key, pattern: pattern) {
            storedFormats.removeValue(forKey: key)
        }
    }

    /// `~DGd:o.x,t,w,data`: Grafik im Druckerspeicher ablegen (ASCII-Hex, ACS oder Z64).
    mutating func downloadGraphic(_ token: ZPLToken) {
        let p = ZPLParameters(token)
        let name = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".GRF")
        guard let total = p.int(1), let bytesPerRow = p.int(2), total >= 0, bytesPerRow > 0 else {
            warn("~DG", "Grafik „\(name)“ ohne gültige Größenangaben – ignoriert.")
            return
        }
        guard total <= Self.maxGraphicBytes else {
            warn("~DG", "Grafik „\(name)“ mit \(total) Bytes ist zu groß – ignoriert.")
            return
        }
        do {
            storedGraphics[name] = try ZPLGraphicEncoder.decodeGraphicField(
                format: "A", totalBytes: total, bytesPerRow: bytesPerRow,
                data: p.joined(from: 3, separator: token.delimiter))
        } catch {
            warn("~DG", "Grafikdaten von „\(name)“ ungültig: \(error.localizedDescription)")
        }
    }

    /// `~DYd:f,b,x,t,w,data`: Objekt laden. Unterstützt Grafiken (x = G, .GRF) und PNG-Bilder
    /// (x = P); Schriften und andere Objekte werden akzeptiert, aber nicht ausgewertet.
    mutating func downloadObject(_ token: ZPLToken) {
        let p = ZPLParameters(token)
        let format = p.character(1) ?? "A"
        let kind = p.string(2)?.uppercased() ?? ""
        let total = p.int(3) ?? 0
        let data = p.joined(from: 5, separator: token.delimiter)
        switch kind {
        case "G":
            let name = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".GRF")
            guard let bytesPerRow = p.int(4), bytesPerRow > 0, total >= 0, total <= Self.maxGraphicBytes else {
                warn("~DY", "Grafik „\(name)“ ohne gültige Größenangaben – ignoriert.")
                return
            }
            guard format == "A" || format == "B" else {
                warn("~DY", "Format „\(format)“ für „\(name)“ wird nicht unterstützt.")
                return
            }
            do {
                storedGraphics[name] = try ZPLGraphicEncoder.decodeGraphicField(
                    format: String(format), totalBytes: total, bytesPerRow: bytesPerRow, data: data)
            } catch {
                warn("~DY", "Grafikdaten von „\(name)“ ungültig: \(error.localizedDescription)")
            }
        case "P":
            let name = ObjectName.normalize(p.string(0) ?? "", defaultExtension: ".PNG")
            guard let bytes = Self.objectBytes(data, format: format), !bytes.isEmpty else {
                warn("~DY", "PNG-Daten von „\(name)“ ungültig – ignoriert.")
                return
            }
            do {
                let image = try PNGCodec.decode(Data(bytes))
                storedGraphics[name] = Ditherer.dither(image, algorithm: .threshold, threshold: 128)
            } catch {
                warn("~DY", "PNG „\(name)“ konnte nicht gelesen werden: \(error.localizedDescription)")
            }
        default:
            break   // Schriften (T, E, B), Kodierungstabellen usw.: ohne Einfluss auf die Vorschau.
        }
    }

    /// Rohbytes eines `~DY`-Objekts: `B` = binär (ISO-Latin-1), `A`/`P` = Hex, `:B64:` oder `:Z64:`.
    static func objectBytes(_ data: String, format: Character) -> [UInt8]? {
        if format == "B" || format == "C" {
            var bytes: [UInt8] = []
            for scalar in data.unicodeScalars {
                guard scalar.value <= 0xFF else { return nil }
                bytes.append(UInt8(scalar.value))
            }
            return bytes
        }
        let trimmed = data.trimmingCharacters(in: .whitespaces)
        let marker = trimmed.prefix(5).uppercased()
        if marker == ":Z64:" {
            return (try? Z64.decode(trimmed)).map { [UInt8]($0) }
        }
        if marker == ":B64:" {
            var payload = trimmed.dropFirst(5)
            if let colon = payload.lastIndex(of: ":") { payload = payload[..<colon] }
            return Data(base64Encoded: String(payload)).map { [UInt8]($0) }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.utf8.count / 2)
        var high: UInt8?
        for character in trimmed {
            guard let value = character.hexDigitValue else { continue }
            if let h = high {
                bytes.append(h << 4 | UInt8(value))
                high = nil
            } else {
                high = UInt8(value)
            }
        }
        return bytes
    }

    // MARK: Elemente

    /// Elemente eines Grafikbefehls am Feldursprung (`^FT`: linke untere Ecke).
    func graphicElements(_ spec: GraphicSpec, placement: FieldPlacement, reverse: Bool) -> [LabelElement] {
        func origin(_ width: Int, _ height: Int) -> LabelPoint {
            placement.origin(width: width, height: height, orientation: .normal, anchorX: 0,
                             anchorRightX: Double(width), anchorY: Double(height))
        }
        switch spec {
        case let .box(width, height, thickness, color, rounding):
            return [.box(BoxElement(origin: origin(width, height), width: width, height: height, thickness: thickness,
                                    color: color, rounding: rounding, reverse: reverse))]
        case let .ellipse(width, height, thickness, color):
            return [.ellipse(EllipseElement(origin: origin(width, height), width: width, height: height,
                                            thickness: thickness, color: color, reverse: reverse))]
        case let .diagonal(width, height, thickness, color, leansRight):
            return [.diagonal(DiagonalElement(origin: origin(width, height), width: width, height: height,
                                              thickness: thickness, color: color, leansRight: leansRight,
                                              reverse: reverse))]
        case let .bitmap(bitmap, mx, my):
            return [.graphic(GraphicElement(origin: origin(bitmap.width * mx, bitmap.height * my), bitmap: bitmap,
                                            magnificationX: mx, magnificationY: my, reverse: reverse))]
        case .storedElements(let elements):
            let offset = origin(0, 0)
            return elements.map { element in
                var moved = element.offset(by: offset)
                if reverse { moved = moved.withReverse(true) }
                return moved
            }
        }
    }
}

extension LabelElement {
    /// Element um `delta` verschoben.
    func offset(by delta: LabelPoint) -> LabelElement {
        func shifted(_ point: LabelPoint) -> LabelPoint { LabelPoint(x: point.x + delta.x, y: point.y + delta.y) }
        switch self {
        case .text(var e): e.origin = shifted(e.origin); return .text(e)
        case .box(var e): e.origin = shifted(e.origin); return .box(e)
        case .ellipse(var e): e.origin = shifted(e.origin); return .ellipse(e)
        case .diagonal(var e): e.origin = shifted(e.origin); return .diagonal(e)
        case .graphic(var e): e.origin = shifted(e.origin); return .graphic(e)
        case .linearBarcode(var e): e.origin = shifted(e.origin); return .linearBarcode(e)
        case .matrixBarcode(var e): e.origin = shifted(e.origin); return .matrixBarcode(e)
        }
    }

    /// Element mit gesetztem Umkehrmodus.
    func withReverse(_ reverse: Bool) -> LabelElement {
        switch self {
        case .text(var e): e.reverse = reverse; return .text(e)
        case .box(var e): e.reverse = reverse; return .box(e)
        case .ellipse(var e): e.reverse = reverse; return .ellipse(e)
        case .diagonal(var e): e.reverse = reverse; return .diagonal(e)
        case .graphic(var e): e.reverse = reverse; return .graphic(e)
        case .linearBarcode(var e): e.reverse = reverse; return .linearBarcode(e)
        case .matrixBarcode(var e): e.reverse = reverse; return .matrixBarcode(e)
        }
    }
}

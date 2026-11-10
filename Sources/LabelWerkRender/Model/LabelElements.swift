import Foundation
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging

// MARK: - Grundtypen

/// Punkt in Druckerpunkten (Dots), Ursprung links oben auf dem Etikett.
public struct LabelPoint: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// Ursprung (0, 0).
    public static let zero = LabelPoint(x: 0, y: 0)
}

/// Ausrichtung der Zeilen eines Feldblocks (`^FB`, Parameter d).
public enum TextJustification: String, Sendable, Hashable, CaseIterable, Codable {
    case left = "L"
    case center = "C"
    case right = "R"
    /// Blocksatz: Wortabstände werden gedehnt; die letzte Zeile eines Absatzes bleibt linksbündig.
    case justified = "J"
}

/// Linienfarbe von Grafikelementen (`^GB`, `^GC`, `^GE`, `^GD`, Parameter c).
public enum LineColor: String, Sendable, Hashable, CaseIterable, Codable {
    case black = "B"
    case white = "W"
}

/// Schreibrichtung eines Textfelds (`^FP`).
public enum TextDirection: String, Sendable, Hashable, CaseIterable, Codable {
    /// Normal von links nach rechts.
    case horizontal = "H"
    /// Zeichen untereinander gestapelt (jedes Zeichen aufrecht).
    case vertical = "V"
    /// Von rechts nach links (erstes Zeichen rechts).
    case reverse = "R"
}

/// Feldblock (`^FB` bzw. `^TB`): Umbruch, Zeilenzahl, Zeilenabstand, Ausrichtung, hängender Einzug.
public struct FieldBlock: Hashable, Sendable {
    /// Zeilenbreite in Punkten.
    public var width: Int
    /// Maximale Zeilenzahl (1…9999).
    public var maxLines: Int
    /// Zusätzlicher Abstand zwischen den Zeilen in Punkten (negativ = enger).
    public var lineSpacing: Int
    public var justification: TextJustification
    /// Einzug der zweiten und aller folgenden Zeilen in Punkten.
    public var hangingIndent: Int
    /// `true` bei `^TB`: überzählige Zeilen entfallen. Bei `^FB` (`false`) überdrucken sie wie
    /// bei der Firmware die letzte Zeile.
    public var truncatesOverflow: Bool

    public init(width: Int, maxLines: Int = 1, lineSpacing: Int = 0, justification: TextJustification = .left,
                hangingIndent: Int = 0, truncatesOverflow: Bool = false) {
        self.width = width
        self.maxLines = maxLines
        self.lineSpacing = lineSpacing
        self.justification = justification
        self.hangingIndent = hangingIndent
        self.truncatesOverflow = truncatesOverflow
    }
}

// MARK: - Elemente

/// Textfeld (`^A`/`^CF` + `^FD`).
///
/// Geometrie: `origin` ist immer die linke obere Ecke des (gedrehten) Feldrechtecks. Das
/// Feldrechteck ist ungedreht `Textbreite × height` bzw. bei `^FB`
/// `block.width × (maxLines × height + (maxLines − 1) × lineSpacing)`; bei `R`/`B` sind Breite
/// und Höhe vertauscht. `^FT`-Angaben (Grundlinie) rechnet der Interpreter bereits um.
public struct TextElement: Hashable, Sendable {
    /// Linke obere Ecke des Textfelds (bei `^FT`: Grundlinie → in obere Ecke umgerechnet).
    public var origin: LabelPoint
    /// Schriftbezeichner: `"0"`, `"A"`…`"Z"`, `"1"`…`"9"`, `"GS"` (`^GS`) oder ein Dateiname
    /// wie `"E:ARIAL.TTF"` (`^A@`).
    public var fontName: String
    /// Zeichenhöhe in Punkten (bei Bitmap-Schriften inklusive Vergrößerung).
    public var height: Int
    /// Zeichenbreite in Punkten (bei Bitmap-Schriften die Matrixbreite inklusive Vergrößerung).
    public var width: Int
    public var orientation: FieldOrientation
    /// Feldinhalt (nach `^FH`-Dekodierung). Bei `^FB` bleiben `\&`-Zeilenumbrüche erhalten.
    public var text: String
    /// `^FR` bzw. `^LR`: das Feld invertiert den Untergrund.
    public var reverse: Bool
    public var block: FieldBlock?
    /// Schreibrichtung (`^FP`).
    public var direction: TextDirection
    /// Zusätzlicher Zeichenabstand in Punkten (`^FP`, Parameter g).
    public var characterGap: Int

    public init(origin: LabelPoint, fontName: String, height: Int, width: Int,
                orientation: FieldOrientation = .normal, text: String, reverse: Bool = false,
                block: FieldBlock? = nil, direction: TextDirection = .horizontal, characterGap: Int = 0) {
        self.origin = origin
        self.fontName = fontName
        self.height = height
        self.width = width
        self.orientation = orientation
        self.text = text
        self.reverse = reverse
        self.block = block
        self.direction = direction
        self.characterGap = characterGap
    }
}

/// Rechteck, Rahmen oder Linie (`^GB`). Breite und Höhe sind mindestens so groß wie die Linienstärke.
public struct BoxElement: Hashable, Sendable {
    public var origin: LabelPoint
    public var width: Int
    public var height: Int
    public var thickness: Int
    public var color: LineColor
    /// Eckenrundung 0…8; Radius = Rundung / 8 × kürzere Seite / 2.
    public var rounding: Int
    public var reverse: Bool

    public init(origin: LabelPoint, width: Int, height: Int, thickness: Int = 1, color: LineColor = .black,
                rounding: Int = 0, reverse: Bool = false) {
        self.origin = origin
        self.width = width
        self.height = height
        self.thickness = thickness
        self.color = color
        self.rounding = rounding
        self.reverse = reverse
    }
}

/// Ellipse oder Kreis (`^GE`, `^GC`), einbeschrieben in `width × height` ab `origin`.
public struct EllipseElement: Hashable, Sendable {
    public var origin: LabelPoint
    public var width: Int
    public var height: Int
    public var thickness: Int
    public var color: LineColor
    public var reverse: Bool

    public init(origin: LabelPoint, width: Int, height: Int, thickness: Int = 1, color: LineColor = .black,
                reverse: Bool = false) {
        self.origin = origin
        self.width = width
        self.height = height
        self.thickness = thickness
        self.color = color
        self.reverse = reverse
    }
}

/// Diagonale Linie (`^GD`) als Parallelogramm mit waagerechter Stärke `thickness`.
public struct DiagonalElement: Hashable, Sendable {
    public var origin: LabelPoint
    public var width: Int
    public var height: Int
    public var thickness: Int
    public var color: LineColor
    /// `true` = „/“ (von links unten nach rechts oben, `^GD…,R`), `false` = „\“ (`L`).
    public var leansRight: Bool
    public var reverse: Bool

    public init(origin: LabelPoint, width: Int, height: Int, thickness: Int = 1, color: LineColor = .black,
                leansRight: Bool = true, reverse: Bool = false) {
        self.origin = origin
        self.width = width
        self.height = height
        self.thickness = thickness
        self.color = color
        self.leansRight = leansRight
        self.reverse = reverse
    }
}

/// Rastergrafik (`^GF`, `^XG`, `^IM`) mit ganzzahliger Vergrößerung.
public struct GraphicElement: Hashable, Sendable {
    public var origin: LabelPoint
    public var bitmap: MonoBitmap
    public var magnificationX: Int
    public var magnificationY: Int
    public var reverse: Bool

    public init(origin: LabelPoint, bitmap: MonoBitmap, magnificationX: Int = 1, magnificationY: Int = 1,
                reverse: Bool = false) {
        self.origin = origin
        self.bitmap = bitmap
        self.magnificationX = magnificationX
        self.magnificationY = magnificationY
        self.reverse = reverse
    }
}

/// Eindimensionaler Barcode.
///
/// Feldrechteck (ungedreht): Symbolbreite (bei EAN/UPC mit Klarschrift zuzüglich der außen
/// stehenden Ziffern) × (Balkenhöhe + Klarschriftzeile). `origin` ist dessen linke obere Ecke
/// nach der Drehung. Die genaue Aufteilung liefert `LinearBarcodeLayout`.
public struct LinearBarcodeElement: Hashable, Sendable {
    public var origin: LabelPoint
    public var symbology: BarcodeSymbology
    public var barcode: LinearBarcode
    /// Modulbreite (schmales Element) in Punkten (`^BY` w).
    public var moduleWidth: Int
    /// Verhältnis breit : schmal (`^BY` r), nur für Zweibreiten-Codes relevant.
    public var ratio: Double
    /// Balkenhöhe in Punkten (ohne Klarschrift).
    public var height: Int
    public var orientation: FieldOrientation
    public var printInterpretation: Bool
    public var interpretationAbove: Bool
    /// Felddaten, wie sie kodiert wurden (nach `^FH`, inklusive ZPL-Aufrufcodes bei `^BC`).
    public var text: String
    /// `^FR`: Balken invertieren den Untergrund.
    public var reverse: Bool

    public init(origin: LabelPoint, symbology: BarcodeSymbology, barcode: LinearBarcode, moduleWidth: Int,
                ratio: Double = 3.0, height: Int, orientation: FieldOrientation = .normal,
                printInterpretation: Bool = true, interpretationAbove: Bool = false, text: String,
                reverse: Bool = false) {
        self.origin = origin
        self.symbology = symbology
        self.barcode = barcode
        self.moduleWidth = moduleWidth
        self.ratio = ratio
        self.height = height
        self.orientation = orientation
        self.printInterpretation = printInterpretation
        self.interpretationAbove = interpretationAbove
        self.text = text
        self.reverse = reverse
    }
}

/// Zweidimensionaler Code (QR, Data Matrix, PDF417) aus quadratischen Modulen.
///
/// Bei PDF417 sind die Symbolzeilen in der Matrix bereits auf die gewünschte Zeilenhöhe
/// (`^B7` h in Vielfachen der Modulbreite) vervielfacht.
public struct MatrixBarcodeElement: Hashable, Sendable {
    public var origin: LabelPoint
    public var symbology: BarcodeSymbology
    public var matrix: BitMatrix
    /// Kantenlänge eines Moduls in Punkten.
    public var moduleSize: Int
    public var orientation: FieldOrientation
    /// Kodierte Nutzdaten (ohne ZPL-Präfixe wie `QA,`).
    public var text: String
    public var reverse: Bool

    public init(origin: LabelPoint, symbology: BarcodeSymbology, matrix: BitMatrix, moduleSize: Int,
                orientation: FieldOrientation = .normal, text: String, reverse: Bool = false) {
        self.origin = origin
        self.symbology = symbology
        self.matrix = matrix
        self.moduleSize = moduleSize
        self.orientation = orientation
        self.text = text
        self.reverse = reverse
    }
}

/// Ein Element der Displayliste eines Etiketts.
public enum LabelElement: Hashable, Sendable {
    case text(TextElement)
    case box(BoxElement)
    case ellipse(EllipseElement)
    case diagonal(DiagonalElement)
    case graphic(GraphicElement)
    case linearBarcode(LinearBarcodeElement)
    case matrixBarcode(MatrixBarcodeElement)

    /// Umschließendes Rechteck in Etikettenpunkten (nach Drehung).
    ///
    /// Text wird mit den Metriken der eingebauten Rasterschriften vermessen; Akzente und
    /// Unterlängen können geringfügig über das Feldrechteck hinausragen.
    public var boundingBox: (x: Int, y: Int, width: Int, height: Int) {
        switch self {
        case .text(let text):
            let size = TextLayout.fieldSize(of: text)
            return Self.rotated(text.origin, size, text.orientation)
        case .box(let box):
            return (box.origin.x, box.origin.y, box.width, box.height)
        case .ellipse(let ellipse):
            return (ellipse.origin.x, ellipse.origin.y, ellipse.width, ellipse.height)
        case .diagonal(let diagonal):
            return (diagonal.origin.x, diagonal.origin.y, diagonal.width, diagonal.height)
        case .graphic(let graphic):
            return (graphic.origin.x, graphic.origin.y,
                    graphic.bitmap.width * max(1, graphic.magnificationX),
                    graphic.bitmap.height * max(1, graphic.magnificationY))
        case .linearBarcode(let barcode):
            let layout = LinearBarcodeLayout(barcode)
            return Self.rotated(barcode.origin, (layout.width, layout.height), barcode.orientation)
        case .matrixBarcode(let barcode):
            let module = max(1, barcode.moduleSize)
            return Self.rotated(barcode.origin, (barcode.matrix.width * module, barcode.matrix.height * module),
                                barcode.orientation)
        }
    }

    /// Ist das Element invertierend (`^FR`/`^LR`)?
    public var isReverse: Bool {
        switch self {
        case .text(let e): return e.reverse
        case .box(let e): return e.reverse
        case .ellipse(let e): return e.reverse
        case .diagonal(let e): return e.reverse
        case .graphic(let e): return e.reverse
        case .linearBarcode(let e): return e.reverse
        case .matrixBarcode(let e): return e.reverse
        }
    }

    /// Feldursprung (linke obere Ecke des Feldrechtecks).
    public var origin: LabelPoint {
        switch self {
        case .text(let e): return e.origin
        case .box(let e): return e.origin
        case .ellipse(let e): return e.origin
        case .diagonal(let e): return e.origin
        case .graphic(let e): return e.origin
        case .linearBarcode(let e): return e.origin
        case .matrixBarcode(let e): return e.origin
        }
    }

    private static func rotated(_ origin: LabelPoint, _ size: (Int, Int),
                                _ orientation: FieldOrientation) -> (x: Int, y: Int, width: Int, height: Int) {
        switch orientation {
        case .normal, .inverted180: return (origin.x, origin.y, size.0, size.1)
        case .rotated90, .rotated270: return (origin.x, origin.y, size.1, size.0)
        }
    }
}

// MARK: - Ergebnis

/// Hinweis des Interpreters (unbekannter Befehl, ungültige Daten, Näherung …). Nie ein Abbruch.
public struct RenderWarning: Hashable, Sendable, CustomStringConvertible {
    /// Befehl mit Präfix, z. B. `"^BQ"`, oder leer bei allgemeinen Hinweisen.
    public var command: String
    /// Deutschsprachige Beschreibung.
    public var message: String

    public init(command: String, message: String) {
        self.command = command
        self.message = message
    }

    public var description: String { command.isEmpty ? message : "\(command): \(message)" }
}

/// Ein gerendertes Etikett (ein `^XA…^XZ`-Format) als Displayliste.
public struct RenderedLabel: Hashable, Sendable {
    public var widthDots: Int
    public var heightDots: Int
    public var dotsPerMM: Int
    /// Elemente in Zeichenreihenfolge (in Formatkoordinaten, vor `^PO`/`^PM`).
    public var elements: [LabelElement]
    /// Druckmenge (`^PQ`).
    public var quantity: Int
    /// `^POI`: um 180° gedreht drucken.
    public var inverted: Bool
    /// `^PMY`: gespiegelt drucken.
    public var mirrored: Bool
    public var warnings: [RenderWarning]

    public init(widthDots: Int, heightDots: Int, dotsPerMM: Int = 8, elements: [LabelElement] = [],
                quantity: Int = 1, inverted: Bool = false, mirrored: Bool = false, warnings: [RenderWarning] = []) {
        self.widthDots = widthDots
        self.heightDots = heightDots
        self.dotsPerMM = dotsPerMM
        self.elements = elements
        self.quantity = quantity
        self.inverted = inverted
        self.mirrored = mirrored
        self.warnings = warnings
    }
}

/// Ergebnis der Interpretation eines ZPL-Datenstroms.
public struct LabelDocument: Hashable, Sendable {
    /// Alle druckenden Formate in Reihenfolge.
    public var labels: [RenderedLabel]
    /// Am Ende gespeicherte Grafiken (`~DG`, `~DY`), Schlüssel z. B. `"R:LOGO.GRF"`.
    public var storedGraphics: [String: MonoBitmap]
    /// Hinweise außerhalb eines druckenden Formats (z. B. Befehle zwischen `^XZ` und `^XA`).
    public var warnings: [RenderWarning]

    public init(labels: [RenderedLabel] = [], storedGraphics: [String: MonoBitmap] = [:],
                warnings: [RenderWarning] = []) {
        self.labels = labels
        self.storedGraphics = storedGraphics
        self.warnings = warnings
    }

    /// Alle Hinweise: dokumentweite und die aller Etiketten.
    public var allWarnings: [RenderWarning] {
        warnings + labels.flatMap(\.warnings)
    }
}

import Foundation
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging

/// Interpretiert ZPL II und erzeugt je druckendem Format eine Displayliste (`RenderedLabel`).
///
/// Eigenschaften:
/// * **Wirft nie.** Unbekannte oder nicht nachgebildete Befehle, ungültige Parameter und
///   Barcodedaten werden als `RenderWarning` gemeldet; die Verarbeitung läuft weiter.
/// * Dauerhafte Druckereinstellungen (`^PW`, `^LL`, `^LH`, `^LS`, `^LT`, `^PO`, `^PM`, `^LR`, `^BY`,
///   `^CF`, `^FW`, `^CI`, `^MC`) gelten wie in der Firmware über Formatgrenzen hinweg.
/// * Gespeicherte Objekte (`~DG`, `~DY`, `^DF`, `^IS`) leben nur innerhalb eines `render`-Aufrufs.
/// * Formate ohne druckendes Feld (z. B. `^XA^JUS^XZ`, `^DF`-Definitionen) erzeugen kein Etikett.
///   Feldbefehle außerhalb von `^XA…^XZ` werden nachsichtig als implizites Format behandelt.
///
/// Feldgeometrie (siehe auch `TextElement`): `^FO` setzt die linke obere Ecke des gedrehten
/// Feldrechtecks; `^FT` setzt bei Text den Anfang der Grundlinie (letzte Zeile bei `^FB`), bei
/// Barcodes die linke untere Ecke der Balken und bei Grafiken/2D-Codes die linke untere Ecke –
/// jeweils im gedrehten Koordinatensystem des Felds. Gedreht wird im Uhrzeigersinn
/// (`R` = 90°, `I` = 180°, `B` = 270°); dabei liegt das Feldrechteck stets rechts unterhalb des
/// Ursprungs. `^LH` verschiebt alle Felder, `^LS` verschiebt sie nach links, `^LT` verschiebt das
/// gesamte Druckbild um bis zu ±120 Punktzeilen (positiv = nach unten).
public struct ZPLInterpreter: Sendable {
    public var dotsPerMM: Int
    public var defaultWidthDots: Int
    public var defaultHeightDots: Int
    /// Zeitpunkt für Uhrzeitfelder (`^FC`); `nil` = aktuelle Zeit.
    public var currentDate: Date?
    /// Zeitzone für Uhrzeitfelder (`^FC`).
    public var timeZone: TimeZone

    public init(dotsPerMM: Int = 8, defaultWidthDots: Int = 812, defaultHeightDots: Int = 1218) {
        self.dotsPerMM = max(1, dotsPerMM)
        self.defaultWidthDots = defaultWidthDots
        self.defaultHeightDots = defaultHeightDots
        self.currentDate = nil
        self.timeZone = .current
    }

    /// Interpretiert einen ZPL-Datenstrom. Wirft nie; unbekannte Befehle → `warnings`.
    public func render(_ zpl: String) -> LabelDocument {
        var engine = InterpreterEngine(configuration: self)
        engine.run(ZPLTokenizer.tokenize(zpl))
        return engine.document
    }
}

// MARK: - Zustand

/// Dauerhafte Einstellungen (gelten über Formatgrenzen).
struct PrinterState {
    var labelHome = LabelPoint.zero
    /// `^LS`: Verschiebung aller Felder nach links (Punkte).
    var labelShift = 0
    /// `^LT`: Verschiebung des gesamten Druckbilds nach unten (Punktzeilen, −120…120).
    var labelTop = 0
    var printWidth: Int?
    var labelLength: Int?
    var inverted = false
    var mirrored = false
    var labelReverse = false
    var mapClear = true
    var barcodeModuleWidth = 2
    var barcodeRatio = 3.0
    var barcodeHeight = 10
    var defaultFontName = "A"
    var defaultFontHeight: Int? = 9
    var defaultFontWidth: Int? = 5
    var defaultOrientation: FieldOrientation = .normal
    var defaultJustification = 0
    var characterSet: ZPLCharacterSet = .codePage850
    var fontAliases: [String: String] = [:]
}

/// Position eines Felds (`^FO` oder `^FT`), relativ zu `^LH`.
struct FieldPosition {
    enum Kind { case origin, typeset }
    var x: Int
    var y: Int
    var kind: Kind
    /// 0 = links, 1 = rechts, 2 = automatisch (wie links).
    var justification: Int
}

/// Schriftwahl eines Felds (`^A`).
struct FontSelection {
    var name: String
    var orientation: FieldOrientation?
    var height: Int?
    var width: Int?
}

/// Ein Grafikbefehl innerhalb eines Felds.
enum GraphicSpec {
    case box(width: Int, height: Int, thickness: Int, color: LineColor, rounding: Int)
    case ellipse(width: Int, height: Int, thickness: Int, color: LineColor)
    case diagonal(width: Int, height: Int, thickness: Int, color: LineColor, leansRight: Bool)
    case bitmap(MonoBitmap, magnificationX: Int, magnificationY: Int)
    case storedElements([LabelElement])
}

/// Seriennummer (`^SN`) bzw. Serialisierungsmaske (`^SF`).
enum SerialSpec {
    /// `^SNv,n,z`: Startwert, Schrittweite, führende Nullen.
    case number(start: String, increment: Int, leadingZeros: Bool)
    /// `^SFa,b`: Felddaten `base`, Maske und Schrittweite (rechtsbündig ausgerichtet).
    case mask(base: String, mask: String, increment: String)
}

/// Barcodebefehl eines Felds (roh; ausgewertet beim Feldabschluss).
struct BarcodeSpec {
    var command: String
    var parameters: ZPLParameters
}

/// Zustand des aktuellen Felds (bis `^FS`).
struct FieldState {
    var position: FieldPosition?
    var font: FontSelection?
    var symbolFont: FontSelection?
    var block: FieldBlock?
    var reverse = false
    var hexIndicator: Character?
    var data: String?
    var isVariable = false
    var fieldNumber: Int?
    var fieldNumberFromStored = false
    var barcode: BarcodeSpec?
    var graphics: [GraphicSpec] = []
    var serial: SerialSpec?
    var clockIndicators: [Character] = []
    var direction: TextDirection = .horizontal
    var characterGap = 0
    var orientationOverride: FieldOrientation?
    /// Blockhöhe von `^TB` in Punkten (ergibt die Zeilenzahl).
    var textBlockHeight: Int?

    var hasContent: Bool { data != nil || !graphics.isEmpty || serial != nil }
    var isEmpty: Bool {
        position == nil && font == nil && block == nil && !reverse && data == nil && barcode == nil
            && graphics.isEmpty && serial == nil && fieldNumber == nil
    }
}

/// Ein serialisiertes Feld, dessen Elemente pro Etikettenkopie neu erzeugt werden.
struct SerialRecord {
    var elementRange: Range<Int>
    var field: FieldState
    var serial: SerialSpec
    /// Druckereinstellungen zum Zeitpunkt des Feldabschlusses (für `^LH`, `^BY` …).
    var printer: PrinterState
}

/// Zustand des laufenden Formats (`^XA…^XZ`).
struct FormatState {
    var elements: [LabelElement] = []
    var variableFlags: [Bool] = []
    var warnings: [RenderWarning] = []
    var quantity = 1
    var replicates = 0
    var hasPrintableContent = false
    var suppressPrint = false
    var isRecall = false
    var fieldValues: [Int: String] = [:]
    var serialRecords: [SerialRecord] = []
    var lastTypesetEnd: LabelPoint?
}

// MARK: - Engine

struct InterpreterEngine {
    let dotsPerMM: Int
    let defaultWidth: Int
    let defaultHeight: Int
    let now: Date
    let timeZone: TimeZone

    var printer = PrinterState()
    var storedGraphics: [String: MonoBitmap] = [:]
    var storedFormats: [String: [ZPLToken]] = [:]
    var storedImages: [String: [LabelElement]] = [:]
    var labels: [RenderedLabel] = []
    var documentWarnings: [RenderWarning] = []
    var retainedElements: [LabelElement] = []

    var format: FormatState?
    var field = FieldState()

    /// Maximale Verschachtelungstiefe von `^XF` in gespeicherten Formaten.
    static let maxRecallDepth = 8
    /// Höchstzahl unterschiedlicher Seriennummern-Etiketten, die ausgerollt werden.
    static let maxSerializedLabels = 100
    /// Höchstzahl an Befehlen nach dem Einsetzen gespeicherter Formate (Schutz vor Rekursion).
    static let maxExpandedTokens = 200_000

    init(configuration: ZPLInterpreter) {
        dotsPerMM = max(1, configuration.dotsPerMM)
        defaultWidth = min(32_000, max(1, configuration.defaultWidthDots))
        defaultHeight = min(32_000, max(1, configuration.defaultHeightDots))
        now = configuration.currentDate ?? Date()
        timeZone = configuration.timeZone
    }

    var document: LabelDocument {
        LabelDocument(labels: labels, storedGraphics: storedGraphics, warnings: documentWarnings)
    }

    // MARK: Hinweise

    mutating func warn(_ command: String, _ message: String) {
        let warning = RenderWarning(command: command, message: message)
        if format != nil {
            if !format!.warnings.contains(warning) { format!.warnings.append(warning) }
        } else if !documentWarnings.contains(warning) {
            documentWarnings.append(warning)
        }
    }

    // MARK: Ablauf

    mutating func run(_ tokens: [ZPLToken]) {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.prefix == "^" && token.command == "XA" {
                var end = index + 1
                while end < tokens.count && !Self.isFormatBoundary(tokens[end]) { end += 1 }
                let closed = end < tokens.count && tokens[end].command == "XZ"
                processFormat(Array(tokens[(index + 1)..<end]), implicit: false)
                if !closed {
                    let message = end < tokens.count
                        ? "^XA ohne abschließendes ^XZ – das Format wurde beim nächsten ^XA beendet."
                        : "^XZ fehlt am Ende des Datenstroms – das Format wurde trotzdem ausgewertet."
                    attachToLastLabelOrDocument(RenderWarning(command: "^XA", message: message))
                }
                index = closed ? end + 1 : end
            } else if token.prefix == "^" && token.command == "XZ" {
                warn("^XZ", "^XZ ohne vorangehendes ^XA – ignoriert.")
                index += 1
            } else if token.prefix == "~" {
                executeControl(token)
                index += 1
            } else {
                // Formatbefehle außerhalb von ^XA…^XZ: nachsichtig als implizites Format.
                var end = index
                while end < tokens.count && !Self.isFormatBoundary(tokens[end]) { end += 1 }
                let closed = end < tokens.count && tokens[end].command == "XZ"
                processFormat(Array(tokens[index..<end]), implicit: true)
                index = closed ? end + 1 : end
            }
        }
    }

    private static func isFormatBoundary(_ token: ZPLToken) -> Bool {
        token.prefix == "^" && (token.command == "XA" || token.command == "XZ")
    }

    private mutating func attachToLastLabelOrDocument(_ warning: RenderWarning) {
        if !labels.isEmpty, labels[labels.count - 1].warnings.contains(warning) == false {
            labels[labels.count - 1].warnings.append(warning)
        } else if labels.isEmpty, !documentWarnings.contains(warning) {
            documentWarnings.append(warning)
        }
    }

    /// Verarbeitet den Inhalt eines Formats (ohne `^XA`/`^XZ`).
    mutating func processFormat(_ body: [ZPLToken], implicit: Bool) {
        let labelCountBefore = labels.count
        format = FormatState()
        field = FieldState()

        // ^DF: alles danach wird gespeichert, nicht gedruckt.
        if let definition = body.firstIndex(where: { $0.prefix == "^" && $0.command == "DF" }) {
            for token in body[..<definition] { execute(token, fromStored: false) }
            let name = ObjectName.normalize(ZPLParameters(body[definition]).string(0) ?? "",
                                            defaultExtension: ".ZPL")
            storedFormats[name] = Array(body[(definition + 1)...])
            field = FieldState()
            discardFormat()
            return
        }

        var expanded: [(token: ZPLToken, fromStored: Bool)] = []
        if body.contains(where: { $0.prefix == "^" && $0.command == "XF" }) {
            format!.isRecall = true
            format!.fieldValues = collectFieldValues(body)
            var budget = Self.maxExpandedTokens
            expand(body, fromStored: false, depth: 0, budget: &budget, into: &expanded)
        } else {
            expanded = body.map { ($0, false) }
        }
        if !printer.mapClear, !retainedElements.isEmpty {
            format!.elements = retainedElements
            format!.variableFlags = Array(repeating: false, count: retainedElements.count)
        }
        for item in expanded { execute(item.token, fromStored: item.fromStored) }
        finishFormat(implicit: implicit)
        if implicit && labels.count > labelCountBefore {
            let warning = RenderWarning(command: "^XA",
                                        message: "Feldbefehle außerhalb von ^XA…^XZ – als eigenes Format ausgewertet.")
            if !labels[labels.count - 1].warnings.contains(warning) {
                labels[labels.count - 1].warnings.insert(warning, at: 0)
            }
        }
    }

    /// Ersetzt `^XF`-Aufrufe rekursiv durch die gespeicherten Befehle. `budget` begrenzt die Zahl
    /// der insgesamt besuchten Befehle (Schutz vor exponentieller Selbstreferenz).
    private mutating func expand(_ tokens: [ZPLToken], fromStored: Bool, depth: Int, budget: inout Int,
                                 into result: inout [(token: ZPLToken, fromStored: Bool)]) {
        for token in tokens {
            guard budget > 0 else { return }
            budget -= 1
            guard token.prefix == "^" && token.command == "XF" else {
                result.append((token, fromStored))
                continue
            }
            let name = ObjectName.normalize(ZPLParameters(token).string(0) ?? "", defaultExtension: ".ZPL")
            guard let stored = lookup(name, in: storedFormats) else {
                warn("^XF", "Gespeichertes Format „\(name)“ nicht gefunden.")
                continue
            }
            guard depth < Self.maxRecallDepth else {
                warn("^XF", "Zu tief verschachtelte Formataufrufe (\(name)) – abgebrochen.")
                continue
            }
            expand(stored, fromStored: true, depth: depth + 1, budget: &budget, into: &result)
            if budget <= 0 {
                warn("^XF", "Zu viele Befehle durch gespeicherte Formate (\(name)) – abgebrochen.")
            }
        }
    }

    /// Sammelt die Daten der `^FN`-Felder eines Abrufformats (`^FNn^FD…^FS`).
    private func collectFieldValues(_ body: [ZPLToken]) -> [Int: String] {
        var values: [Int: String] = [:]
        var number: Int?
        var indicator: Character?
        var data: String?
        var characterSet = printer.characterSet
        func flush() {
            if let number, let data {
                values[number] = indicator.map {
                    FieldHexDecoder.decode(data, indicator: $0, characterSet: characterSet)
                } ?? data
            }
            number = nil
            indicator = nil
            data = nil
        }
        for token in body where token.prefix == "^" {
            switch token.command {
            case "FN": number = ZPLParameters(token).int(0)
            case "FH": indicator = token.arguments.first ?? "_"
            case "FD", "FV": data = token.arguments
            case "FS": flush()
            case "CI":
                if let value = ZPLParameters(token).int(0), let set = ZPLCharacterSet(ciValue: value) {
                    characterSet = set
                }
            default: break
            }
        }
        flush()
        return values
    }

    /// Sucht ein gespeichertes Objekt: exakt, sonst gleicher Name auf einem anderen Laufwerk.
    func lookup<Value>(_ name: String, in storage: [String: Value]) -> Value? {
        if let value = storage[name] { return value }
        let bare = ObjectName.withoutDrive(name)
        let candidates = storage.keys.filter { ObjectName.withoutDrive($0) == bare }.sorted()
        return candidates.first.flatMap { storage[$0] }
    }

    /// Verwirft das laufende Format; Hinweise wandern ins Dokument.
    private mutating func discardFormat() {
        if let warnings = format?.warnings {
            for warning in warnings where !documentWarnings.contains(warning) { documentWarnings.append(warning) }
        }
        format = nil
    }

    /// Schließt das laufende Format ab und erzeugt die Etiketten.
    private mutating func finishFormat(implicit: Bool) {
        if field.hasContent {
            completeField(implicit: true)
        }
        field = FieldState()
        guard var current = format else { return }
        format = nil

        // ^MC: Nicht-variable Felder bleiben für das nächste Etikett erhalten.
        if printer.mapClear {
            retainedElements = []
        } else {
            retainedElements = zip(current.elements, current.variableFlags).filter { !$0.1 }.map(\.0)
        }

        guard current.hasPrintableContent, !current.suppressPrint else {
            for warning in current.warnings where !documentWarnings.contains(warning) {
                documentWarnings.append(warning)
            }
            return
        }
        let width = printer.printWidth ?? defaultWidth
        let height = printer.labelLength ?? defaultHeight
        let template = RenderedLabel(widthDots: width, heightDots: height, dotsPerMM: dotsPerMM,
                                     elements: current.elements, quantity: max(1, current.quantity),
                                     inverted: printer.inverted, mirrored: printer.mirrored,
                                     warnings: current.warnings)
        guard !current.serialRecords.isEmpty, current.quantity > 1 else {
            labels.append(applyingLabelTop(template))
            return
        }
        // Serialisierung: je Seriennummer ein Etikett mit (Wiederholungen + 1) Kopien.
        let perSerial = max(1, current.replicates + 1)
        let distinct = (current.quantity + perSerial - 1) / perSerial
        let rendered = min(distinct, Self.maxSerializedLabels)
        if distinct > rendered {
            current.warnings.append(RenderWarning(
                command: "^PQ",
                message: "Nur die ersten \(rendered) von \(distinct) Seriennummern werden als eigene Etiketten dargestellt."))
        }
        for copy in 0..<rendered {
            var label = template
            label.warnings = current.warnings
            label.quantity = min(perSerial, current.quantity - copy * perSerial)
            // Bereiche von hinten ersetzen, damit sich die Indizes nicht verschieben.
            for record in current.serialRecords.sorted(by: { $0.elementRange.lowerBound > $1.elementRange.lowerBound }) {
                let data = Serializer.value(record.serial, copy: copy)
                var scratch = self
                scratch.printer = record.printer
                scratch.format = FormatState()
                let replacement = scratch.makeElements(for: record.field, data: data).elements
                label.elements.replaceSubrange(record.elementRange, with: replacement)
            }
            labels.append(applyingLabelTop(label))
        }
    }

    /// `^LT`: verschiebt das fertige Druckbild (alle Elemente) um `labelTop` Punktzeilen.
    ///
    /// Die Verschiebung betrifft das gesamte Format – unabhängig davon, wo `^LT` darin steht –
    /// und wird erst beim Druck angewandt: Mit `^IS` gespeicherte Bilder, per `^MCN`
    /// übernommene Felder und `^FT`-Folgepositionen bleiben unverschoben, damit die
    /// Verschiebung nicht doppelt wirkt.
    private func applyingLabelTop(_ label: RenderedLabel) -> RenderedLabel {
        guard printer.labelTop != 0 else { return label }
        var shifted = label
        let delta = LabelPoint(x: 0, y: printer.labelTop)
        shifted.elements = label.elements.map { $0.offset(by: delta) }
        return shifted
    }
}

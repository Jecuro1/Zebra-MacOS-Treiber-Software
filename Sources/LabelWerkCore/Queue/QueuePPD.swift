import Foundation

// MARK: - Etikettengröße der Warteschlange

/// Die Etikettengröße einer macOS-/CUPS-Warteschlange als benannte Seitengröße (ARCHITECTURE.md §9
/// „Etikettengröße der Warteschlange“).
///
/// Steht die Größe nicht in der Modell-PPD, wird sie als eigener Eintrag in eine Kopie der PPD
/// geschrieben (``QueuePPD/patched(_:adding:)``) – mit Schlüsselwort `w<pt>h<pt>` wie
/// ``LabelStock/ppdKeyword`` und den Texten „Label 104 x 76.2 mm“ / „Etikett 104 × 76,2 mm“.
public struct QueueLabelSize: Hashable, Sendable {
    /// Breite in mm (auf 0,01 mm gerundet).
    public var widthMM: Double
    /// Höhe in mm (auf 0,01 mm gerundet).
    public var heightMM: Double

    public init(widthMM: Double, heightMM: Double) {
        self.widthMM = LabelSizing.rounded(widthMM)
        self.heightMM = LabelSizing.rounded(heightMM)
    }

    public init(stock: LabelStock) {
        self.init(widthMM: stock.widthMM, heightMM: stock.heightMM)
    }

    /// Breite in PostScript-Punkten (gleiche Rechnung wie ``LabelStock/widthPoints`` und der
    /// PPD-Generator).
    public var widthPoints: Double { widthMM / 25.4 * 72.0 }
    /// Höhe in PostScript-Punkten.
    public var heightPoints: Double { heightMM / 25.4 * 72.0 }

    /// PPD-Schlüsselwort `w<pt>h<pt>` (kaufmännisch gerundet), z. B. `w295h216`.
    public var keyword: String { "w\(Int(widthPoints.rounded()))h\(Int(heightPoints.rounded()))" }

    /// Englischer Grundtext (ASCII), z. B. „Label 104 x 76.2 mm“.
    public var englishName: String { "Label " + LabelSizing.sizeText(widthMM: widthMM, heightMM: heightMM, ascii: true) }

    /// Deutscher Text, z. B. „Etikett 104 × 76,2 mm“ – so erscheint die Größe im Druckdialog.
    public var germanName: String { "Etikett " + LabelSizing.sizeText(widthMM: widthMM, heightMM: heightMM) }

    /// Wert von `lwLabelWidth` (1/100 mm).
    public var widthHundredths: Int { LabelSizing.hundredthsOfMillimeter(widthMM) }
    /// Wert von `lwLabelHeight` (1/100 mm).
    public var heightHundredths: Int { LabelSizing.hundredthsOfMillimeter(heightMM) }
}

// MARK: - PPD einer Warteschlange

/// Liest und ergänzt LabelWerk-PPDs für eine Warteschlange.
///
/// `lpadmin -p <queue> -o PageSize=<wahl>` übernimmt nur Seitengrößen, die in der PPD stehen
/// (`cupsMarkOptions` verwirft andere stillschweigend). Für eine eigene Etikettengröße schreibt
/// LabelWerk deshalb eine Kopie der Modell-PPD mit einem zusätzlichen Eintrag und installiert sie
/// mit `lpadmin -P`. Der Eintrag entsteht mit derselben Syntax wie im Generator
/// (`Driver/ppd/generate_ppds.py`, `_emit_page_sizes`):
///
/// ```
/// *DefaultPageSize: w295h216
/// *PageSize w295h216/Label 104 x 76.2 mm: "<</PageSize[294.803 216]/ImagingBBox null>>setpagedevice"
/// … (ebenso *PageRegion, *ImageableArea "0 0 W H", *PaperDimension "W H")
/// *de.PageSize w295h216/Etikett 104 × 76,2 mm: ""
/// *de.PageRegion w295h216/Etikett 104 × 76,2 mm: ""
/// *lwLabelPageSize: "w295h216"
/// ```
///
/// Der neue Eintrag steht direkt nach der jeweiligen `*Default…`-Zeile (im Druckdialog oben), alle
/// vier `*Default…`-Zeilen zeigen auf ihn. `*lwLabelPageSize` markiert die ergänzte Größe: So
/// erkennt der postinstall des Treibers (gleiches Verfahren in `awk`) beim Update, welche Zeilen er
/// in die neue PPD übernehmen muss, und ein erneutes Ergänzen ersetzt eine frühere Größe.
public enum QueuePPD {

    /// Hauptschlüsselwort der Markierung (`*lwLabelPageSize: "w295h216"`).
    public static let markerKeyword = "lwLabelPageSize"
    /// Kommentar vor der Markierung (reines ASCII).
    public static let markerComment = "*% LabelWerk: Etikettengroesse dieser Warteschlange (von LabelWerk ergaenzt)"

    /// Seitengrößen-Schlüsselwörter, deren Einträge eine ergänzte Größe umfasst (Reihenfolge der
    /// Ausgabe ist die der Anker).
    static let entryKeywords = ["PageSize", "PageRegion", "ImageableArea", "PaperDimension"]

    public enum PatchError: Error, Equatable, CustomStringConvertible {
        /// Keine LabelWerk-PPD (`*lwModel` fehlt).
        case notLabelWerkPPD
        /// Eine nötige Zeile (z. B. `*DefaultPageSize:`) fehlt.
        case missingAnchor(String)

        public var description: String {
            switch self {
            case .notLabelWerkPPD: return "Die Datei ist keine LabelWerk-PPD (*lwModel fehlt)."
            case .missingAnchor(let line): return "Die PPD enthält keine Zeile „\(line)“."
            }
        }
    }

    // MARK: Lesen

    /// Zeilen ohne Zeilenende (`\n`, `\r\n` – in Swift ein einziges Zeichen –, `\r`).
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
    }

    /// Schlüsselwörter aller `*PageSize`-Einträge in Dateireihenfolge (ohne `*DefaultPageSize`).
    public static func pageSizeKeywords(in text: String) -> [String] {
        entryKeywords(of: "PageSize", in: text)
    }

    /// Schlüsselwörter aller Einträge `*<main> <wahl>/…:` in Dateireihenfolge.
    static func entryKeywords(of main: String, in text: String) -> [String] {
        let prefix = "*\(main) "
        var result: [String] = []
        for line in lines(text) where line.hasPrefix(prefix) {
            let spec = line.dropFirst(prefix.count).prefix { $0 != "/" && $0 != ":" && $0 != " " }
            if !spec.isEmpty, !result.contains(String(spec)) { result.append(String(spec)) }
        }
        return result
    }

    /// Wert einer Zeile `*<keyword>: wert` (ohne Anführungszeichen), z. B. `*DefaultPageSize`.
    public static func value(of keyword: String, in text: String) -> String? {
        let prefix = "*\(keyword):"
        for line in lines(text) where line.hasPrefix(prefix) {
            var value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    /// `*DefaultPageSize` einer PPD.
    public static func defaultPageSize(in text: String) -> String? { value(of: "DefaultPageSize", in: text) }

    /// Von LabelWerk ergänzte Seitengröße (`*lwLabelPageSize`), sonst `nil`.
    public static func addedPageSize(in text: String) -> String? {
        value(of: markerKeyword, in: text).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `*lwModel` (z. B. `zd421t`, `generic-zpl`).
    public static func lwModel(in text: String) -> String? { value(of: "lwModel", in: text) }

    /// Auflösung aus `*DefaultResolution: 203dpi`.
    public static func resolutionDPI(in text: String) -> Int? {
        guard let value = value(of: "DefaultResolution", in: text), value.hasSuffix("dpi") else { return nil }
        return Int(value.dropLast(3))
    }

    /// Name der Modell-PPD, aus der eine Warteschlangen-PPD stammt (`LabelWerk-zd421t-203dpi`).
    public static func baseStem(of text: String) -> String? {
        guard let model = lwModel(in: text), PPDPageSizes.Target(lwModel: model) != nil,
              let dpi = resolutionDPI(in: text) else { return nil }
        return "LabelWerk-\(model)-\(dpi)dpi"
    }

    /// Maße eines `*PaperDimension`-Eintrags in Punkten.
    public static func paperDimension(of keyword: String, in text: String) -> (width: Double, height: Double)? {
        let prefix = "*PaperDimension \(keyword)"
        for line in lines(text) where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard rest.first == "/" || rest.first == ":" else { continue }
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return nil }
            let numbers = line[line.index(after: open)..<close].split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2 else { return nil }
            return (numbers[0], numbers[1])
        }
        return nil
    }

    // MARK: Ergänzen

    /// Zahl wie im PPD-Generator (`format_number`, drei Nachkommastellen ohne Nullen am Ende).
    public static func formatNumber(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" || text.isEmpty ? "0" : text
    }

    /// Text für PPD-Übersetzungen/Optionstexte wie `sanitize_text` im Generator.
    static func sanitizedText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: ":", with: " -").replacingOccurrences(of: "<", with: "(")
            .replacingOccurrences(of: ">", with: ")").replacingOccurrences(of: "\"", with: "'")
        value = String(value.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
        while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
        value = value.trimmingCharacters(in: .whitespaces)
        while value.utf8.count > 80 { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
        return value
    }

    /// Die Zeilen eines ergänzten Eintrags je Anker.
    static func entryLines(for size: QueueLabelSize) -> (pageSize: String, pageRegion: String, imageableArea: String,
                                                           paperDimension: String, dePageSize: String, dePageRegion: String) {
        let k = size.keyword
        let w = formatNumber(size.widthPoints)
        let h = formatNumber(size.heightPoints)
        let en = sanitizedText(size.englishName)
        let de = sanitizedText(size.germanName)
        let code = "<</PageSize[\(w) \(h)]/ImagingBBox null>>setpagedevice"
        return (
            "*PageSize \(k)/\(en): \"\(code)\"",
            "*PageRegion \(k)/\(en): \"\(code)\"",
            "*ImageableArea \(k)/\(en): \"0 0 \(w) \(h)\"",
            "*PaperDimension \(k)/\(en): \"\(w) \(h)\"",
            "*de.PageSize \(k)/\(de): \"\"",
            "*de.PageRegion \(k)/\(de): \"\""
        )
    }

    /// Entfernt eine früher von LabelWerk ergänzte Seitengröße (Markierung und ihre Einträge);
    /// alles andere bleibt unverändert.
    public static func removingAddedPageSize(_ text: String) -> String {
        guard let added = addedPageSize(in: text) else { return text }
        let prefixes = (entryKeywords + ["de.PageSize", "de.PageRegion"]).map { "*\($0) \(added)/" }
            + ["*\(markerKeyword):"]
        var output: [Substring] = []
        for line in lines(text) {
            if line == markerComment[...] || prefixes.contains(where: { line.hasPrefix($0) }) { continue }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// Kopie der PPD `base`, deren Standard-Seitengröße `size` ist.
    ///
    /// Steht das Schlüsselwort schon in der PPD, werden nur die vier `*Default…`-Zeilen gesetzt.
    /// Sonst wird die Größe als benannter Eintrag ergänzt (siehe Typbeschreibung) – eine früher
    /// ergänzte Größe wird dabei ersetzt. Ergebnis endet mit einem Zeilenende.
    ///
    /// - Throws: ``PatchError`` bei Dateien ohne `*lwModel` oder ohne die `*Default…`-Zeilen.
    public static func patched(_ base: String, adding size: QueueLabelSize) throws -> String {
        guard lwModel(in: base) != nil else { throw PatchError.notLabelWerkPPD }
        let text = removingAddedPageSize(base)
        let keyword = size.keyword
        let alreadyThere = pageSizeKeywords(in: text).contains(keyword)
        let entries = entryLines(for: size)
        let defaults: [(anchor: String, entry: String)] = [
            ("*DefaultPageSize:", entries.pageSize),
            ("*DefaultPageRegion:", entries.pageRegion),
            ("*DefaultImageableArea:", entries.imageableArea),
            ("*DefaultPaperDimension:", entries.paperDimension),
        ]
        let translations: [(anchor: String, entry: String)] = [
            ("*de.Translation PageSize/", entries.dePageSize),
            ("*de.Translation PageRegion/", entries.dePageRegion),
        ]
        var found = Set<String>()
        var output: [String] = []
        for line in lines(text) {
            if let match = defaults.first(where: { line.hasPrefix($0.anchor) }), !found.contains(match.anchor) {
                found.insert(match.anchor)
                output.append("\(match.anchor) \(keyword)")
                if !alreadyThere { output.append(match.entry) }
                continue
            }
            output.append(String(line))
            if alreadyThere { continue }
            if let match = translations.first(where: { line.hasPrefix($0.anchor) }), !found.contains(match.anchor) {
                found.insert(match.anchor)
                output.append(match.entry)
            } else if line.hasPrefix("*lwModel:"), !found.contains("*lwModel:") {
                found.insert("*lwModel:")
                output.append(markerComment)
                output.append("*\(markerKeyword): \"\(keyword)\"")
            }
        }
        for anchor in defaults.map(\.anchor) where !found.contains(anchor) {
            throw PatchError.missingAnchor(anchor)
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }
}

// MARK: - lpoptions

/// Auswertung von `lpoptions -p <queue> -l` (Optionen der PPD mit Auswahl, `*` = Standard).
public enum LPOptionsList {
    /// Eine Option: alle Werte und der markierte Standardwert.
    public struct Option: Equatable, Sendable {
        public var choices: [String]
        public var selected: String?
    }

    /// `lwDarkness/Darkness: Default *15 16 …` → `["lwDarkness": Option(…)]`. Der Text vor dem
    /// Doppelpunkt darf selbst Doppelpunkte enthalten, Werte stehen nach dem letzten „: “.
    public static func parse(_ text: String) -> [String: Option] {
        var result: [String: Option] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = Substring(rawLine)
            guard let colon = line.range(of: ": ", options: .backwards) ?? line.range(of: ":", options: .backwards)
            else { continue }
            let head = line[..<colon.lowerBound]
            let name = String(head.split(separator: "/", maxSplits: 1).first ?? head).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            var choices: [String] = []
            var selected: String?
            for token in line[colon.upperBound...].split(separator: " ") where !token.isEmpty {
                if token.hasPrefix("*") {
                    let value = String(token.dropFirst())
                    selected = value
                    choices.append(value)
                } else {
                    choices.append(String(token))
                }
            }
            result[name] = Option(choices: choices, selected: selected)
        }
        return result
    }
}

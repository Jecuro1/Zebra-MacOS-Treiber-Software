import Foundation

/// Etikettengrößen: erkannte Druckerwerte in Millimeter umrechnen, Eingaben lesen und prüfen und
/// eine Größe einem vorhandenen Etikettenformat zuordnen (ARCHITECTURE.md §9 „Etikettengröße der
/// Warteschlange“).
///
/// Gemeinsam für den Einrichtungsassistenten, das manuelle Hinzufügen, den Dialog
/// „Druckeinstellungen“ und `lwctl install --size` – reine Logik, auch unter Linux getestet.
public enum LabelSizing {

    /// Toleranz je Maß, mit der eine erkannte bzw. eingegebene Größe einem vorhandenen Format
    /// zugeordnet wird (± 0,6 mm: ein Druckerpunkt bei 152 dpi plus Rundung der Formatnamen).
    public static let matchToleranceMM = 0.6

    /// Toleranz, mit der „Druckeinstellungen“ ein eigenes Format gleicher Größe wiederverwendet.
    public static let sameSizeToleranceMM = 0.05

    /// Kleinste eingebbare Etikettenbreite in mm.
    public static let minimumWidthMM = 10.0
    /// Kleinste eingebbare Etikettenhöhe in mm.
    public static let minimumHeightMM = 5.0

    /// Ein Zoll in Millimetern.
    public static let millimetersPerInch = 25.4

    // MARK: - Erkannte Größen

    /// Millimeter aus Druckerpunkten, wie Zebra-Drucker und ZDesigner rechnen (8, 12 bzw. 24 Punkte
    /// je mm bei 203, 300 bzw. 600 dpi), auf ein „rundes“ Maß gerastet.
    ///
    /// Der Drucker kennt nur ganze Punkte: Ein Etikett mit 3 Zoll (76,2 mm) meldet er bei 203 dpi als
    /// 609 oder 610 Punkte (76,125 bzw. 76,25 mm bei 8 Punkten je mm). Gewählt wird deshalb unter den
    /// Kandidaten *ganze Millimeter*, *Vielfache von 0,05 Zoll* (1,27 mm) und *halbe Millimeter*
    /// derjenige, dessen Punktzahl am nächsten an `dots` liegt – gerechnet mit 8/12/24 Punkten je mm
    /// (Drucker) und mit dpi/25,4 (Treiber, die mit 203 dpi rechnen), der kleinere Abstand zählt –
    /// sofern höchstens einen Punkt entfernt. Bei gleichem Abstand gewinnen ganze Millimeter, dann das
    /// Zollraster, dann halbe Millimeter. Ohne Kandidaten wird auf 0,1 mm gerundet. Ergebnis immer auf
    /// 0,01 mm gerundet.
    ///
    /// Beispiele (203 dpi): 832 → 104, 609 → 76,2, 610 → 76,2, 608 → 76, 812 → 101,6 (4 Zoll),
    /// 1218 → 152,4 (6 Zoll), 820 → 102,5.
    public static func millimeters(fromDots dots: Int, resolution: Resolution) -> Double {
        let dpmm = Double(resolution.dotsPerMM)
        let exact = resolution.exactDotsPerMM
        let raw = Double(dots) / dpmm
        guard dots > 0 else { return 0 }
        // (Wert, Rang): 0 = ganze mm, 1 = Zollraster, 2 = halbe mm.
        var candidates: [(value: Double, rank: Int)] = []
        let halves = Int((raw * 2).rounded(.down))
        for k in (halves - 2)...(halves + 2) where k > 0 {
            candidates.append((Double(k) / 2, k % 2 == 0 ? 0 : 2))
        }
        let step = millimetersPerInch / 20   // 0,05 Zoll
        let inches = Int((raw / step).rounded(.down))
        for k in (inches - 2)...(inches + 2) where k > 0 {
            candidates.append((Double(k) * step, 1))
        }
        var best: (value: Double, rank: Int, deviation: Double)?
        for candidate in candidates {
            let deviation = min(abs(candidate.value * dpmm - Double(dots)), abs(candidate.value * exact - Double(dots)))
            guard deviation <= 1.0 + 1e-9 else { continue }
            if let current = best {
                let closer = deviation < current.deviation - 1e-9
                let tieBetterRank = abs(deviation - current.deviation) <= 1e-9 && candidate.rank < current.rank
                if !(closer || tieBetterRank) { continue }
            }
            best = (candidate.value, candidate.rank, deviation)
        }
        guard let best else { return (raw * 10).rounded() / 10 }
        return rounded(best.value)
    }

    /// Auf 0,01 mm gerundet (so speichert LabelWerk eigene Formate).
    public static func rounded(_ millimeters: Double) -> Double {
        (millimeters * 100).rounded() / 100
    }

    /// Hundertstel Millimeter als Ganzzahl (Werte von `lwLabelWidth`/`lwLabelHeight`), kaufmännisch
    /// gerundet; negative oder ungültige Werte → 0 („unbekannt“).
    public static func hundredthsOfMillimeter(_ millimeters: Double) -> Int {
        guard millimeters.isFinite, millimeters > 0, millimeters < 1_000_000 else { return 0 }
        return Int((millimeters * 100).rounded())
    }

    // MARK: - Anzeige

    /// Millimeterwert mit höchstens zwei Nachkommastellen ohne überflüssige Nullen, z. B. `104`,
    /// `76,2` (deutsches Komma) bzw. `76.2` (`decimalSeparator: "."`).
    public static func format(_ millimeters: Double, decimalSeparator: String = ",") -> String {
        let hundredths = Int((abs(millimeters) * 100).rounded())
        let whole = hundredths / 100
        var fraction = String(format: "%02d", hundredths % 100)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let sign = millimeters < 0 && hundredths > 0 ? "-" : ""
        return fraction.isEmpty ? "\(sign)\(whole)" : "\(sign)\(whole)\(decimalSeparator)\(fraction)"
    }

    /// „104 × 76,2 mm“ (deutsch) bzw. „104 x 76.2 mm“ (`ascii: true`, z. B. für PPD-Grundtexte).
    public static func sizeText(widthMM: Double, heightMM: Double, ascii: Bool = false) -> String {
        let separator = ascii ? "." : ","
        let times = ascii ? "x" : "×"
        return "\(format(widthMM, decimalSeparator: separator)) \(times) \(format(heightMM, decimalSeparator: separator)) mm"
    }

    // MARK: - Eingabe

    /// Liest eine Längenangabe in Millimetern: `76,2`, `76.2`, ` 76,2 mm` (Komma oder Punkt als
    /// Dezimaltrenner, höchstens einer; keine Tausendertrenner). `nil` bei leerer, ungültiger oder
    /// nicht positiver Eingabe.
    public static func parseMillimeters(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix("mm") {
            value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return parseNumber(value)
    }

    /// Liest eine Größe `BREITExHÖHE[mm|in]`, z. B. `104x76.2mm`, `104 × 76,2 mm`, `4x3in`
    /// (`x`, `X`, `×` oder `*` als Trenner; ohne Einheit Millimeter). Ergebnis in Millimetern,
    /// gerundet auf 0,01 mm; `nil` bei ungültiger Eingabe.
    public static func parseSize(_ text: String) -> (widthMM: Double, heightMM: Double)? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var factor = 1.0
        if value.hasSuffix("mm") {
            value = String(value.dropLast(2))
        } else if value.hasSuffix("in") {
            value = String(value.dropLast(2))
            factor = millimetersPerInch
        } else if value.hasSuffix("\"") {
            value = String(value.dropLast())
            factor = millimetersPerInch
        }
        let parts = value.split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == "*" })
        guard parts.count == 2,
              let width = parseNumber(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = parseNumber(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (rounded(width * factor), rounded(height * factor))
    }

    private static func parseNumber(_ text: String) -> Double? {
        guard !text.isEmpty else { return nil }
        var separators = 0
        var digits = 0
        var normalized = ""
        for character in text {
            if character == "," || character == "." {
                separators += 1
                normalized.append(".")
            } else if character.isASCII, character.isNumber {
                digits += 1
                normalized.append(character)
            } else {
                return nil
            }
        }
        guard separators <= 1, digits > 0, let number = Double(normalized), number.isFinite, number > 0 else {
            return nil
        }
        return number
    }

    // MARK: - Grenzen

    /// Erlaubte Etikettengröße eines Modells: Breite 10 mm … Druckbreite + 2 mm (wie die PPDs und
    /// `ModelCatalog.stocks(fitting:)`), Höhe 5 mm … größte Etikettenlänge. Ohne Modell gelten die
    /// größten Werte des Katalogs.
    public struct Limits: Equatable, Sendable {
        public var widthMM: ClosedRange<Double>
        public var heightMM: ClosedRange<Double>

        public init(widthMM: ClosedRange<Double>, heightMM: ClosedRange<Double>) {
            self.widthMM = widthMM
            self.heightMM = heightMM
        }

        public init(model: PrinterModel?, catalog: ModelCatalog = .shared) {
            let printWidth = model?.printWidthMM ?? catalog.models.map(\.printWidthMM).max() ?? 104
            let length = model?.maxLabelLengthMM ?? catalog.models.map(\.maxLabelLengthMM).max() ?? 991
            self.widthMM = minimumWidthMM...max(minimumWidthMM, printWidth + PPDPageSizes.widthToleranceMM)
            self.heightMM = minimumHeightMM...max(minimumHeightMM, length)
        }

        /// Prüfung einer Eingabe; leer = gültig.
        public func issues(widthMM width: Double?, heightMM height: Double?) -> [Issue] {
            var result: [Issue] = []
            if let width {
                if width < widthMM.lowerBound - 1e-9 { result.append(.widthTooSmall(minimum: widthMM.lowerBound)) }
                if width > widthMM.upperBound + 1e-9 { result.append(.widthTooLarge(maximum: widthMM.upperBound)) }
            } else {
                result.append(.widthMissing)
            }
            if let height {
                if height < heightMM.lowerBound - 1e-9 { result.append(.heightTooSmall(minimum: heightMM.lowerBound)) }
                if height > heightMM.upperBound + 1e-9 { result.append(.heightTooLarge(maximum: heightMM.upperBound)) }
            } else {
                result.append(.heightMissing)
            }
            return result
        }

        public func contains(widthMM width: Double, heightMM height: Double) -> Bool {
            issues(widthMM: width, heightMM: height).isEmpty
        }
    }

    /// Fehler einer Größeneingabe (Grenzen in mm).
    public enum Issue: Equatable, Sendable {
        case widthMissing, heightMissing
        case widthTooSmall(minimum: Double), widthTooLarge(maximum: Double)
        case heightTooSmall(minimum: Double), heightTooLarge(maximum: Double)

        /// Deutsche Meldung, z. B. „Breite höchstens 106 mm“.
        public var message: String {
            switch self {
            case .widthMissing: return "Breite in mm eingeben"
            case .heightMissing: return "Höhe in mm eingeben"
            case .widthTooSmall(let minimum): return "Breite mindestens \(format(minimum)) mm"
            case .widthTooLarge(let maximum): return "Breite höchstens \(format(maximum)) mm"
            case .heightTooSmall(let minimum): return "Höhe mindestens \(format(minimum)) mm"
            case .heightTooLarge(let maximum): return "Höhe höchstens \(format(maximum)) mm"
            }
        }
    }

    // MARK: - Zuordnung zu vorhandenen Formaten

    /// Passt ein Format mit Medientyp `stock` zu einem erkannten bzw. gewünschten Medientyp?
    ///
    /// `nil` (unbekannt) passt zu allem. Einzeletiketten und Etiketten mit Seitenkerben gelten als
    /// gleichwertig, „Automatisch erkennen“ passt zu allen Etiketten (nicht zu Endlosmaterial),
    /// schwarze Markierungen nur zu schwarzen Markierungen, Endlosmaterial nur zu Endlosmaterial.
    public static func isCompatible(_ wanted: MediaTracking?, with stock: MediaTracking) -> Bool {
        guard let wanted else { return true }
        if wanted == .autoDetect { return stock != .continuous }
        if stock == .autoDetect { return wanted != .continuous }
        return group(wanted) == group(stock)
    }

    private static func group(_ tracking: MediaTracking) -> Int {
        switch tracking {
        case .continuous: return 0
        case .blackMark: return 1
        case .gap, .notch, .autoDetect: return 2
        }
    }

    /// Das nächstliegende Format aus `stocks`, dessen Breite und Höhe je höchstens `tolerance` von
    /// der Größe abweichen und dessen Medientyp passt (``isCompatible(_:with:)``). Bei mehreren
    /// gewinnt die kleinste Summe der Abweichungen, bei Gleichstand das erste in `stocks`.
    public static func bestMatch(widthMM: Double, heightMM: Double, tracking: MediaTracking?,
                                 in stocks: [LabelStock], tolerance: Double = matchToleranceMM) -> LabelStock? {
        var best: (stock: LabelStock, distance: Double)?
        for stock in stocks {
            let dw = abs(stock.widthMM - widthMM)
            let dh = abs(stock.heightMM - heightMM)
            guard dw <= tolerance + 1e-9, dh <= tolerance + 1e-9, isCompatible(tracking, with: stock.tracking) else {
                continue
            }
            if let current = best, dw + dh >= current.distance - 1e-9 { continue }
            best = (stock, dw + dh)
        }
        return best?.stock
    }

    /// Vorhandenes Format zu einer erkannten bzw. eingegebenen Größe: zuerst die eigenen Formate,
    /// dann der Katalog (je ``bestMatch(widthMM:heightMM:tracking:in:tolerance:)`` mit ± 0,6 mm).
    public static func matchingStock(widthMM: Double, heightMM: Double, tracking: MediaTracking?,
                                     custom: [LabelStock], catalog: [LabelStock]) -> LabelStock? {
        bestMatch(widthMM: widthMM, heightMM: heightMM, tracking: tracking, in: custom)
            ?? bestMatch(widthMM: widthMM, heightMM: heightMM, tracking: tracking, in: catalog)
    }

    /// Eigenes Format mit derselben Größe (± 0,05 mm) und genau diesem Medientyp – so verwendet
    /// „Druckeinstellungen“ ein früher angelegtes Format wieder, statt ein weiteres anzulegen.
    public static func sameSizeStock(widthMM: Double, heightMM: Double, tracking: MediaTracking,
                                     in stocks: [LabelStock]) -> LabelStock? {
        stocks.first {
            abs($0.widthMM - widthMM) < sameSizeToleranceMM && abs($0.heightMM - heightMM) < sameSizeToleranceMM
                && $0.tracking == tracking
        }
    }
}

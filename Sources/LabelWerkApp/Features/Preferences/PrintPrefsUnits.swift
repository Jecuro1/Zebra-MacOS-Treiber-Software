import SwiftUI
import LabelWerkKit

// MARK: - Umrechnung

/// Rechnet Längen zwischen Druckpunkten bzw. Millimetern und der gewählten Anzeigeeinheit um
/// („Einheiten“ → „Standard-Maßeinheiten“). Etikettenmaße: Millimeter mit einer, Zoll mit zwei
/// Nachkommastellen, Punkte ganzzahlig. Werte in Druckpunkten (Versätze) bekommen so viele
/// Nachkommastellen, dass jeder Punktwert bei der Auflösung des Druckers eingegeben werden kann
/// (siehe `dotDigits`).
struct PrintPrefsLength: Equatable {
    var unit: MeasurementUnit
    var resolution: Resolution

    init(unit: MeasurementUnit, resolution: Resolution) {
        self.unit = unit
        self.resolution = resolution
    }

    var digits: Int { unit.fractionDigits }
    var symbol: String { unit.symbol }

    /// Nachkommastellen für Werte in Druckpunkten: mindestens `digits`, aber so viele, dass der
    /// Rundungsfehler der Anzeige unter einem halben Punkt bleibt – dann ergibt jeder angezeigte
    /// Wert wieder genau denselben Punktwert, und jeder Punktwert lässt sich eintippen
    /// (z. B. 300 dpi: 0,01 mm statt 0,1 mm; Zoll: 0,001).
    var dotDigits: Int {
        let dotsPerUnit: Double
        switch unit {
        case .dots: return 0
        case .millimeters: dotsPerUnit = resolution.exactDotsPerMM
        case .inches: dotsPerUnit = Double(resolution.rawValue)
        }
        var result = digits
        while result < 4, dotsPerUnit >= pow(10, Double(result)) { result += 1 }
        return result
    }

    // Druckpunkte ↔ Anzeige

    func display(dots: Int) -> Double {
        switch unit {
        case .millimeters: return resolution.mm(fromDots: dots)
        case .inches: return resolution.inches(fromDots: dots)
        case .dots: return Double(dots)
        }
    }

    /// Anzeigewert → Druckpunkte. Begrenzt vor der Umwandlung in `Int`, die bei sehr großen
    /// Eingaben (z. B. „99999999999999999999“) sonst das Programm beendet.
    func dots(fromDisplay value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let v = min(max(value, -1_000_000), 1_000_000)
        switch unit {
        case .millimeters: return resolution.dots(fromMM: v)
        case .inches: return resolution.dots(fromInches: v)
        case .dots: return Int(v.rounded())
        }
    }

    // Millimeter ↔ Anzeige

    func display(mm: Double) -> Double {
        switch unit {
        case .millimeters: return mm
        case .inches: return mm / 25.4
        case .dots: return mm * resolution.exactDotsPerMM
        }
    }

    func mm(fromDisplay value: Double) -> Double {
        guard value.isFinite else { return 0 }
        switch unit {
        case .millimeters: return (value * 10).rounded() / 10
        case .inches: return value * 25.4
        case .dots: return value.rounded() / resolution.exactDotsPerMM
        }
    }

    /// Kleinster sinnvoller Schritt für Etikettenmaße in der Anzeigeeinheit.
    var displayStep: Double {
        switch unit {
        case .millimeters: return 0.1
        case .inches: return 0.01
        case .dots: return 1
        }
    }

    // Text

    func number(_ value: Double) -> String {
        number(value, digits: digits)
    }

    func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// „12,5 mm“, „0,492 Zoll“, „100 Punkte“ (Nachkommastellen wie im Eingabefeld, `dotDigits`).
    func text(dots: Int) -> String {
        number(display(dots: dots), digits: dotDigits) + " " + symbol
    }

    func text(mm: Double) -> String {
        number(display(mm: mm)) + " " + symbol
    }

    /// Breite × Höhe in der Anzeigeeinheit, z. B. „104,0 × 76,2 mm“.
    func size(widthMM: Double, heightMM: Double) -> String {
        number(display(mm: widthMM)) + " × " + number(display(mm: heightMM)) + " " + symbol
    }
}

// MARK: - Längenfeld

/// Zahlenfeld mit Stepper für eine Länge in der Anzeigeeinheit. Gespeichert wird ein kanonischer
/// Wert (Druckpunkte oder Millimeter), den `toDisplay`/`fromDisplay` umrechnen; Eingaben werden
/// auf `range` begrenzt und beim Beenden der Bearbeitung übernommen.
struct PrintPrefsMeasureField: View {
    @Binding var canonical: Double
    let range: ClosedRange<Double>
    let step: Double
    let digits: Int
    let unit: String
    let toDisplay: (Double) -> Double
    let fromDisplay: (Double) -> Double
    var width: CGFloat

    init(canonical: Binding<Double>, range: ClosedRange<Double>, step: Double, digits: Int, unit: String,
         width: CGFloat = 92, toDisplay: @escaping (Double) -> Double, fromDisplay: @escaping (Double) -> Double) {
        self._canonical = canonical
        self.range = range
        self.step = step
        self.digits = digits
        self.unit = unit
        self.width = width
        self.toDisplay = toDisplay
        self.fromDisplay = fromDisplay
    }

    private var format: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(digits))
    }

    private var displayBinding: Binding<Double> {
        let format = self.format
        return Binding(
            get: { toDisplay(canonical) },
            set: { newValue in
                guard newValue.isFinite else { return }
                // Das Feld übernimmt beim Beenden der Bearbeitung auch einen unveränderten Text. Ein
                // Wert, der genauso angezeigt wird wie der gespeicherte, ändert nichts – sonst würde
                // aus dem gerundeten Text zurückgerechnet (57,15 mm → „57,2“ → 57,2 mm, Vorlage
                // „Benutzerdefiniert“; 104 mm → „831“ Punkte → 103,98 mm). Verglichen wird mit
                // demselben Format wie in der Anzeige, damit dessen Rundung genau berücksichtigt ist.
                if format.format(newValue) == format.format(toDisplay(canonical)) { return }
                canonical = fromDisplay(newValue.clamped(to: -1e9...1e9)).clamped(to: range)
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: displayBinding, format: format)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .labelsHidden()
            Stepper("", onIncrement: {
                canonical = (canonical + step).clamped(to: range)
            }, onDecrement: {
                canonical = (canonical - step).clamped(to: range)
            })
            .labelsHidden()
            Text(unit)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .leading)
        }
    }
}

extension PrintPrefsMeasureField {
    /// Feld für einen Wert in Druckpunkten (Versätze), angezeigt in der gewählten Einheit.
    init(dots: Binding<Int>, range: ClosedRange<Int>, length: PrintPrefsLength, width: CGFloat = 92) {
        self.init(
            canonical: Binding(get: { Double(dots.wrappedValue) },
                               set: { dots.wrappedValue = Int($0.rounded()).clamped(to: range) }),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: 1,
            digits: length.dotDigits,
            unit: length.symbol,
            width: width,
            toDisplay: { length.display(dots: Int($0.rounded())) },
            fromDisplay: { Double(length.dots(fromDisplay: $0)) }
        )
    }

    /// Feld für eine Etikettengröße in Millimetern, angezeigt in der gewählten Einheit.
    init(millimetres: Binding<Double>, range: ClosedRange<Double>, length: PrintPrefsLength, width: CGFloat = 92) {
        self.init(
            canonical: millimetres,
            range: range,
            step: max(0.01, length.mm(fromDisplay: length.displayStep)),
            digits: length.digits,
            unit: length.symbol,
            width: width,
            toDisplay: { length.display(mm: $0) },
            fromDisplay: { length.mm(fromDisplay: $0) }
        )
    }
}

// MARK: - Ganzzahlfeld

/// Schlichtes Ganzzahlfeld mit Stepper (Etikettenanzahl, Millisekunden, Schwelle).
struct PrintPrefsIntegerField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String?
    var width: CGFloat = 72

    init(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil, width: CGFloat = 72) {
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.width = width
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { value = $0.clamped(to: range) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .labelsHidden()
            Stepper("", value: Binding(get: { value }, set: { value = $0.clamped(to: range) }), in: range, step: step)
                .labelsHidden()
            if let unit {
                Text(unit)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

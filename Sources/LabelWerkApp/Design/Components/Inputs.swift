import SwiftUI

/// Wert, der entweder vom Drucker übernommen (`nil`) oder ausdrücklich gesetzt wird.
/// Entspricht „Druckereinstellung verwenden“ im Windows-Treiber.
struct OptionalStepper: View {
    let title: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    var step: Int = 1
    let defaultValue: Int
    var unit: String?

    init(title: String, value: Binding<Int?>, range: ClosedRange<Int>, step: Int = 1, defaultValue: Int, unit: String? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.unit = unit
    }

    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { on in
                withAnimation(Motion.spring) { value = on ? (value ?? defaultValue) : nil }
            }
        )
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(value ?? defaultValue) },
            set: { newValue in
                let stepped = (Int(newValue.rounded()) / step) * step
                value = min(max(stepped, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle(isOn: isOverridden) {
                    Text(isOverridden.wrappedValue ? tr("Eigener Wert") : tr("Druckerwert"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            if let current = value {
                HStack(spacing: 12) {
                    Slider(value: sliderValue, in: Double(range.lowerBound)...Double(range.upperBound),
                           step: Double(step))
                    Stepper(value: Binding(get: { current }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                            in: range, step: step) {
                        HStack(spacing: 2) {
                            Text("\(current)")
                                .font(Theme.Typography.metricSmall)
                                .contentTransition(.numericText(value: Double(current)))
                                .frame(minWidth: 44, alignment: .trailing)
                            if let unit {
                                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .animation(Motion.snappy, value: current)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.spring, value: value == nil)
    }
}

/// Zahlenfeld mit Stepper und Einheit.
struct NumberStepperField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String?

    init(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .monospacedDigit()
            if let unit {
                Text(unit)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .leading)
            }
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

import SwiftUI
import LabelWerkKit

/// Einstellungen für Bild & PDF: Einpassen, Drehung, Helligkeit/Kontrast, Invertieren und Rasterung.
struct DesignerImageControls: View {
    @Bindable var state: DesignerImageState
    let reduceMotion: Bool
    let defaultDither: DitherAlgorithm

    @Namespace private var fitNamespace

    private var animation: Animation? { reduceMotion ? nil : Motion.spring }

    var body: some View {
        VStack(spacing: Theme.Metrics.cardSpacing) {
            adjustCard
            ditherCard
        }
    }

    // MARK: Anpassen

    private var adjustCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Anpassen"), subtitle: tr("Änderungen erscheinen sofort in der Vorschau"),
                              systemImage: "slider.horizontal.3") {
                    Button(tr("Zurücksetzen")) {
                        withAnimation(animation) { state.resetAdjustments(defaultDither: defaultDither) }
                    }
                    .buttonStyle(.labelWerkPlain)
                    .disabled(!state.hasAdjustments(defaultDither: defaultDither))
                }

                VStack(alignment: .leading, spacing: 6) {
                    caption(tr("Einpassen"))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(ImageFitMode.allCases) { mode in
                            DesignerOptionTile(title: mode.displayName, systemImage: mode.systemImage,
                                               isSelected: state.fitMode == mode, namespace: fitNamespace,
                                               reduceMotion: reduceMotion) {
                                withAnimation(animation) { state.fitMode = mode }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    caption(tr("Drehung"))
                    HStack(spacing: 8) {
                        DesignerChoiceBar(items: QuarterTurn.allCases, selection: $state.rotation, reduceMotion: reduceMotion,
                                          title: { "\($0.rawValue)°" })
                        Button {
                            withAnimation(animation) { state.rotateClockwise() }
                        } label: {
                            Image(systemName: "rotate.right")
                                .font(.system(size: 13, weight: .semibold))
                                .rotationEffect(.degrees(Double(state.rotation.rawValue)))
                                .frame(width: 28, height: 26)
                        }
                        .buttonStyle(.labelWerkPlain)
                        .help(tr("Um 90° im Uhrzeigersinn drehen"))
                        .accessibilityLabel(tr("Um 90° im Uhrzeigersinn drehen"))
                    }
                }

                DesignerValueSlider(title: tr("Helligkeit"), systemImage: "sun.max", value: $state.brightness,
                                    range: -1...1, reduceMotion: reduceMotion, format: DesignerFormat.signedPercent)
                DesignerValueSlider(title: tr("Kontrast"), systemImage: "circle.lefthalf.filled", value: $state.contrast,
                                    range: -1...1, reduceMotion: reduceMotion, format: DesignerFormat.signedPercent)

                Toggle(isOn: $state.invert.animation(animation)) {
                    Label(tr("Invertieren (Negativ)"), systemImage: "circle.righthalf.filled")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: Rasterung

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(state.threshold) },
            set: { state.threshold = min(254, max(1, Int($0.rounded()))) }
        )
    }

    private var ditherCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Rasterung"), subtitle: tr("Wie Graustufen in Druckpunkte übersetzt werden"),
                              systemImage: "circle.grid.cross")
                Picker(selection: $state.dither.animation(animation)) {
                    ForEach(DitherAlgorithm.allCases) { algorithm in
                        Text(tr(algorithm.displayName)).tag(algorithm)
                    }
                } label: {
                    Text(tr("Verfahren"))
                }
                .pickerStyle(.menu)

                Text(description(of: state.dither))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(state.dither)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                DesignerValueSlider(title: state.dither == .threshold ? tr("Schwelle") : tr("Helligkeitsbezug"),
                                    systemImage: "sun.min", value: thresholdBinding, range: 1...254,
                                    neutral: 128, step: 1, reduceMotion: reduceMotion,
                                    format: { String(Int($0.rounded())) })
                if state.dither != defaultDither {
                    Button {
                        withAnimation(animation) { state.dither = defaultDither }
                    } label: {
                        Label(tr("Standard aus den App-Einstellungen: %@", tr(defaultDither.displayName)),
                              systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.labelWerkPlain)
                    .transition(.opacity)
                }
            }
            .animation(animation, value: state.dither)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func description(of algorithm: DitherAlgorithm) -> String {
        switch algorithm {
        case .threshold: return tr("Harte Schwelle – ideal für Logos, Text und Barcodes.")
        case .ordered: return tr("Gleichmäßiges Bayer-Raster – ruhig und gut reproduzierbar.")
        case .halftone: return tr("Klassisches Punktraster wie im Zeitungsdruck.")
        case .floydSteinberg: return tr("Fehlerdiffusion mit feinen Verläufen – erste Wahl für Fotos.")
        case .atkinson: return tr("Kontrastreiche Fehlerdiffusion mit klaren Lichtern.")
        case .stucki: return tr("Sehr feine Fehlerdiffusion für maximalen Detailreichtum.")
        }
    }
}

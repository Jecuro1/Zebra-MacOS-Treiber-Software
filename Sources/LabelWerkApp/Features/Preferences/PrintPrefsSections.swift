import SwiftUI
import LabelWerkKit

// MARK: - Druckqualität

/// Schwärzung & Geschwindigkeit mit Live-Simulation und Durchsatz.
struct PrintPrefsQualityCard: View {
    @Binding var settings: PrintSettings
    let session: PrinterSession
    let pulse: [PrintPrefsField: Int]
    let reduceMotion: Bool

    init(settings: Binding<PrintSettings>, session: PrinterSession, pulse: [PrintPrefsField: Int], reduceMotion: Bool) {
        self._settings = settings
        self.session = session
        self.pulse = pulse
        self.reduceMotion = reduceMotion
    }

    private var maxSpeed: Int { max(2, min(14, session.model?.maxSpeed(session.resolution) ?? 14)) }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(tr("Druckqualität"),
                              subtitle: tr("Schwärzung und Geschwindigkeit bestimmen Kontrast, Schärfe und Durchsatz"),
                              systemImage: "circle.lefthalf.filled")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        controls
                            .frame(minWidth: 300, idealWidth: 380, maxWidth: .infinity)
                        swatch
                            .frame(width: 270)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        controls
                        swatch
                    }
                }
            }
        }
    }

    private var swatch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Simulation"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            PrintPrefsDarknessSwatch(darkness: settings.darkness, speed: settings.speed, reduceMotion: reduceMotion)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                OptionalStepper(title: tr("Schwärzung"), value: $settings.darkness, range: 0...30, defaultValue: 15)
                PrintPrefsHint(darknessHint.text, systemImage: darknessHint.symbol, tint: darknessHint.tint)
            }
            .modifier(PrintPrefsPulse(token: pulse[.darkness] ?? 0))

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                OptionalStepper(title: tr("Geschwindigkeit"), value: $settings.speed, range: 1...maxSpeed,
                                defaultValue: min(4, maxSpeed), unit: tr("Zoll/s"))
                if let speed = settings.speed, speed > maxSpeed {
                    PrintPrefsHint(tr("Dieses Modell druckt höchstens %d Zoll/s – der Drucker begrenzt den Wert.", maxSpeed),
                                   systemImage: "exclamationmark.triangle", tint: Theme.warning)
                } else {
                    PrintPrefsHint(tr("Langsamer druckt sauberer (kleine Schrift, 2D-Codes), schneller erhöht den Durchsatz. Höchstwert: %d Zoll/s.", maxSpeed),
                                   systemImage: "speedometer")
                }
            }
            .modifier(PrintPrefsPulse(token: pulse[.speed] ?? 0))

            if let speed = settings.speed {
                throughput(speed: speed)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: settings.speed == nil)
    }

    private func throughput(speed: Int) -> some View {
        let stock = session.stock
        let pitch = max(1, stock.heightMM + (stock.isContinuous ? 0 : stock.gapMM))
        let mmPerSecond = Double(speed) * 25.4
        let perMinute = Int((mmPerSecond * 60 / pitch).rounded(.down))
        return HStack(spacing: 10) {
            IconBadge(systemImage: "gauge.with.dots.needle.67percent", tint: Theme.teal, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("≈ %d Etiketten pro Minute", perMinute))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(perMinute)))
                Text(tr("%@ mm/s bei „%@“", PrintPrefsFormat.number(mmPerSecond, digits: 0), stock.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: mmPerSecond))
            }
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: speed)
    }

    private struct HintInfo {
        var text: String
        var symbol: String
        var tint: Color
    }

    private var darknessHint: HintInfo {
        guard let darkness = settings.darkness else {
            return HintInfo(text: tr("Der Drucker verwendet seine eigene Schwärzung (Gerätemenü bzw. zuletzt gespeicherter Wert)."),
                            symbol: "printer", tint: Color.secondary)
        }
        switch darkness {
        case ..<10:
            return HintInfo(text: tr("Sehr hell – schont den Druckkopf, Barcodes können aber unlesbar werden."),
                            symbol: "exclamationmark.triangle", tint: Theme.warning)
        case 10...22:
            return HintInfo(text: tr("Ausgewogen – empfohlen für die meisten Etiketten."),
                            symbol: "checkmark.circle", tint: Theme.ready)
        case 23...26:
            return HintInfo(text: tr("Kräftig – gut für Thermotransfer und feine Barcodes."),
                            symbol: "info.circle", tint: Theme.printing)
        default:
            return HintInfo(text: tr("Sehr dunkel – Balken können verlaufen, der Druckkopf altert schneller."),
                            symbol: "exclamationmark.triangle", tint: Theme.warning)
        }
    }
}

// MARK: - Medien

/// Druckverfahren, Medienerkennung, Druckmodus und Rückzug – jeweils mit „Druckerwert“.
struct PrintPrefsMediaCard: View {
    @Binding var settings: PrintSettings
    let session: PrinterSession
    let pulse: [PrintPrefsField: Int]
    let reduceMotion: Bool

    init(settings: Binding<PrintSettings>, session: PrinterSession, pulse: [PrintPrefsField: Int], reduceMotion: Bool) {
        self._settings = settings
        self.session = session
        self.pulse = pulse
        self.reduceMotion = reduceMotion
    }

    private var mediaTypes: [MediaType] {
        var types = session.model?.mediaTypes ?? MediaType.allCases
        if types.isEmpty { types = MediaType.allCases }
        if let current = settings.mediaType, !types.contains(current) { types.append(current) }
        return types
    }

    private var trackingOptions: [MediaTracking?] {
        [nil] + MediaTracking.allCases.map { Optional($0) }
    }

    private var printModeOptions: [PrintMode?] {
        var modes = session.model?.printModes ?? PrintMode.allCases
        if modes.isEmpty { modes = PrintMode.allCases }
        if let current = settings.printMode, !modes.contains(current) { modes.append(current) }
        return [nil] + modes.map { Optional($0) }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(tr("Medien"),
                              subtitle: tr("Druckverfahren, Etikettenerkennung und Verhalten nach dem Druck"),
                              systemImage: "square.stack.3d.up")

                field(tr("Druckverfahren"), .mediaType) {
                    Picker(tr("Druckverfahren"), selection: $settings.mediaType) {
                        Text(tr("Druckerwert")).tag(MediaType?.none)
                        ForEach(mediaTypes) { type in
                            Text(tr(type.displayName)).tag(MediaType?.some(type))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 460)
                    PrintPrefsHint(mediaTypeHint, systemImage: PrintPrefsSymbols.symbol(for: settings.mediaType))
                }

                field(tr("Medienerkennung"), .tracking) {
                    PrintPrefsChoiceStrip(
                        options: trackingOptions,
                        selection: $settings.tracking,
                        title: { value in value.map { tr($0.displayName) } ?? tr("Druckerwert") },
                        systemImage: { PrintPrefsSymbols.symbol(for: $0) }
                    )
                    PrintPrefsHint(trackingHint, systemImage: "sensor.tag.radiowaves.forward")
                    trackingMismatch
                }

                field(tr("Druckmodus"), .printMode) {
                    PrintPrefsChoiceStrip(
                        options: printModeOptions,
                        selection: $settings.printMode,
                        title: { value in value.map { tr($0.displayName) } ?? tr("Druckerwert") },
                        systemImage: { PrintPrefsSymbols.symbol(for: $0) }
                    )
                    PrintPrefsHint(printModeHint, systemImage: PrintPrefsSymbols.symbol(for: settings.printMode))
                }

                field(tr("Rückzug (Backfeed)"), .backfeed) {
                    Picker(tr("Rückzug"), selection: $settings.backfeed) {
                        Text(tr("Druckerwert")).tag(BackfeedMode?.none)
                        Divider()
                        ForEach(BackfeedMode.allCases) { mode in
                            Label(tr(mode.displayName), systemImage: PrintPrefsSymbols.symbol(for: mode))
                                .tag(BackfeedMode?.some(mode))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                    PrintPrefsHint(tr("Legt fest, wann das Etikett nach dem Abreißen oder Spenden zurückgezogen wird."),
                                   systemImage: PrintPrefsSymbols.symbol(for: settings.backfeed))
                }
            }
            .animation(reduceMotion ? nil : Motion.spring, value: settings.tracking)
            .animation(reduceMotion ? nil : Motion.spring, value: settings.mediaType)
        }
    }

    private func field<Content: View>(_ title: String, _ key: PrintPrefsField,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if !key.isOverridden(in: settings) {
                    Text(tr("Druckerwert"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.subtleFill, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: key.isOverridden(in: settings))
            content()
        }
        .modifier(PrintPrefsPulse(token: pulse[key] ?? 0))
    }

    private var mediaTypeHint: String {
        switch settings.mediaType {
        case .none:
            return tr("Der Drucker behält sein eingestelltes Druckverfahren.")
        case .some(.directThermal):
            return tr("Thermodirekt: Wärmeempfindliches Papier, kein Farbband nötig.")
        case .some(.thermalTransfer):
            return tr("Thermotransfer: Farbband erforderlich – langlebige, wischfeste Etiketten.")
        }
    }

    private var trackingHint: String {
        switch settings.tracking {
        case .none: return tr("Der Drucker nutzt die zuletzt kalibrierte Erkennung.")
        case .some(.gap): return tr("Der Durchlichtsensor erkennt die Lücke zwischen den Etiketten.")
        case .some(.blackMark): return tr("Der Reflexsensor erkennt schwarze Markierungen auf der Rückseite.")
        case .some(.continuous): return tr("Endlosmaterial – die Länge ergibt sich aus dem Etikettenformat.")
        case .some(.autoDetect): return tr("Der Drucker ermittelt die Medienart beim Kalibrieren selbst.")
        case .some(.notch): return tr("Der Durchlichtsensor erkennt die Kerben am Rand der Etiketten.")
        }
    }

    private var printModeHint: String {
        switch settings.printMode {
        case .none: return tr("Der Drucker behält seinen eingestellten Modus.")
        case .some(.tearOff): return tr("Etiketten werden an der Abreißkante abgetrennt.")
        case .some(.peelOff): return tr("Das Etikett wird vom Träger gelöst – Spender erforderlich.")
        case .some(.cutter): return tr("Der Schneider trennt die Etiketten automatisch (siehe „Schneiden nach je“).")
        case .some(.delayedCut): return tr("Der Schnitt erfolgt erst beim nächsten Etikett oder per Befehl.")
        case .some(.rewind): return tr("Bedruckte Etiketten werden aufgewickelt.")
        case .some(.applicator): return tr("Betrieb mit einem Etiketten-Applikator.")
        case .some(.kiosk): return tr("Kiosk-Modus: Beleg wird präsentiert und geschnitten.")
        case .some(.linerlessPeel), .some(.linerlessCut), .some(.linerlessDelayedCut), .some(.linerlessRewind),
             .some(.linerlessTear):
            return tr("Linerless-Etiketten ohne Trägermaterial – der Modus wird per SGD (media.printmode) gesetzt.")
        }
    }

    @ViewBuilder
    private var trackingMismatch: some View {
        let stock = session.stock
        if let tracking = settings.tracking, tracking != .autoDetect, tracking != stock.tracking {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text(tr("Das eingelegte Format „%@“ ist als „%@“ hinterlegt.", stock.name, tr(stock.tracking.displayName)))
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(tr("Angleichen")) {
                    withAnimation(reduceMotion ? nil : Motion.spring) { settings.tracking = stock.tracking }
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
            }
            .padding(10)
            .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Position

/// Oberer/linker Versatz und Abreißposition mit animiertem Etikettendiagramm.
struct PrintPrefsPositionCard: View {
    @Binding var settings: PrintSettings
    let session: PrinterSession
    let pulse: [PrintPrefsField: Int]
    let reduceMotion: Bool

    init(settings: Binding<PrintSettings>, session: PrinterSession, pulse: [PrintPrefsField: Int], reduceMotion: Bool) {
        self._settings = settings
        self.session = session
        self.pulse = pulse
        self.reduceMotion = reduceMotion
    }

    private var hasOffsets: Bool {
        settings.labelTop != nil || settings.labelLeft != nil || settings.tearOffAdjust != nil
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(tr("Position"),
                              subtitle: tr("Druckbild verschieben und Abreißkante feinjustieren (in Druckpunkten)"),
                              systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                    if hasOffsets {
                        Button {
                            withAnimation(reduceMotion ? nil : Motion.spring) {
                                settings.labelTop = nil
                                settings.labelLeft = nil
                                settings.tearOffAdjust = nil
                            }
                        } label: {
                            Label(tr("Druckerwerte"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .help(tr("Alle Versätze wieder vom Drucker übernehmen"))
                        .transition(.opacity)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        controls
                            .frame(minWidth: 300, idealWidth: 380, maxWidth: .infinity)
                        diagram
                            .frame(width: 280)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        controls
                        diagram
                    }
                }
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: hasOffsets)
        }
    }

    private var diagram: some View {
        let stock = session.stock
        return PrintPrefsPositionDiagram(
            stock: stock,
            resolution: session.resolution,
            widthDots: stock.widthDots(session.resolution),
            heightDots: stock.heightDots(session.resolution),
            labelTop: settings.labelTop ?? 0,
            labelLeft: settings.labelLeft ?? 0,
            tearOff: settings.tearOffAdjust ?? 0,
            reduceMotion: reduceMotion
        )
        .frame(maxWidth: .infinity)
    }

    private var leftRange: ClosedRange<Int> {
        let current = settings.labelLeft ?? 0
        return min(-200, current)...max(200, current)
    }

    private var exactLeft: Binding<Int> {
        Binding(
            get: { settings.labelLeft ?? 0 },
            set: { settings.labelLeft = min(max($0, -9999), 9999) }
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                OptionalStepper(title: tr("Oberer Versatz (^LT)"), value: $settings.labelTop, range: -120...120,
                                defaultValue: 0, unit: tr("Punkte"))
                PrintPrefsHint(offsetHint(settings.labelTop, positive: tr("nach unten"), negative: tr("nach oben")),
                               systemImage: "arrow.up.and.down")
            }
            .modifier(PrintPrefsPulse(token: pulse[.labelTop] ?? 0))

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                OptionalStepper(title: tr("Linker Versatz (^LS)"), value: $settings.labelLeft, range: leftRange,
                                defaultValue: 0, unit: tr("Punkte"))
                if settings.labelLeft != nil {
                    HStack(spacing: 8) {
                        Text(tr("Exakter Wert (−9999 … 9999)"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        TextField(tr("Punkte"), value: exactLeft, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                PrintPrefsHint(offsetHint(settings.labelLeft, positive: tr("nach links"), negative: tr("nach rechts")),
                               systemImage: "arrow.left.and.right")
            }
            .modifier(PrintPrefsPulse(token: pulse[.labelLeft] ?? 0))

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                OptionalStepper(title: tr("Abreißposition (~TA)"), value: $settings.tearOffAdjust, range: -120...120,
                                defaultValue: 0, unit: tr("Punkte"))
                PrintPrefsHint(offsetHint(settings.tearOffAdjust, positive: tr("weiter heraus"), negative: tr("weiter zurück")),
                               systemImage: "scissors")
            }
            .modifier(PrintPrefsPulse(token: pulse[.tearOff] ?? 0))
        }
        .animation(reduceMotion ? nil : Motion.spring, value: settings.labelLeft == nil)
    }

    private func offsetHint(_ dots: Int?, positive: String, negative: String) -> String {
        guard let dots else { return tr("Druckerwert – der Drucker verwendet seine gespeicherte Einstellung.") }
        if dots == 0 { return tr("Keine Verschiebung.") }
        let mm = session.resolution.mm(fromDots: abs(dots))
        return tr("≙ %@ mm %@", PrintPrefsFormat.number(mm), dots > 0 ? positive : negative)
    }
}

// MARK: - Bild

/// Spiegeln/Negativ/Drehen mit 3D-Vorschau, Rasterung mit Live-Vergleich, Kompression mit Größenschätzung.
struct PrintPrefsImageCard: View {
    @Binding var settings: PrintSettings
    let session: PrinterSession
    let reduceMotion: Bool

    init(settings: Binding<PrintSettings>, session: PrinterSession, reduceMotion: Bool) {
        self._settings = settings
        self.session = session
        self.reduceMotion = reduceMotion
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.threshold) },
            set: { settings.threshold = Int($0.rounded()).clamped(to: 1...254) }
        )
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(tr("Bild"),
                              subtitle: tr("Ausrichtung, Rasterung von Graustufen und Grafikkompression"),
                              systemImage: "photo")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        toggles
                            .frame(minWidth: 300, idealWidth: 380, maxWidth: .infinity)
                        transformPreview
                            .frame(width: 280)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        toggles
                        transformPreview
                    }
                }
                Divider().opacity(0.5)
                ditherSection
                Divider().opacity(0.5)
                compressionSection
            }
        }
    }

    private var transformPreview: some View {
        PrintPrefsTransformPreview(stock: session.stock, mirror: settings.mirror, negative: settings.negative,
                                   rotate180: settings.rotate180, reduceMotion: reduceMotion)
    }

    private var toggles: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $settings.mirror) {
                PrintPrefsTileLabel(title: tr("Spiegeln"),
                                    detail: tr("Horizontal spiegeln – z. B. für Etiketten hinter Glas."),
                                    systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                    tint: Theme.violet, isOn: settings.mirror)
            }
            Toggle(isOn: $settings.negative) {
                PrintPrefsTileLabel(title: tr("Negativ"),
                                    detail: tr("Schwarz und Weiß vertauschen."),
                                    systemImage: "circle.righthalf.filled",
                                    tint: Theme.indigo, isOn: settings.negative)
            }
            Toggle(isOn: $settings.rotate180) {
                PrintPrefsTileLabel(title: tr("Um 180° drehen"),
                                    detail: tr("Für Drucker, die Etiketten kopfüber ausgeben."),
                                    systemImage: "arrow.triangle.2.circlepath",
                                    tint: Theme.teal, isOn: settings.rotate180)
            }
        }
        .toggleStyle(PrintPrefsTileToggleStyle(reduceMotion: reduceMotion))
    }

    private var ditherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Rasterung (Dithering)"))
                        .font(Theme.Typography.headline)
                    Text(tr("Wie Graustufen und Fotos in Druckpunkte umgewandelt werden"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker(tr("Verfahren"), selection: $settings.dither) {
                    ForEach(DitherAlgorithm.allCases) { algorithm in
                        Text(tr(algorithm.displayName)).tag(algorithm)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            PrintPrefsHint(ditherHint, systemImage: "wand.and.rays")

            HStack(spacing: 12) {
                Text(tr("Schwelle"))
                    .font(.system(size: 13, weight: .medium))
                Slider(value: thresholdBinding, in: 1...254, step: 1) {
                    Text(tr("Schwelle"))
                } minimumValueLabel: {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.secondary)
                }
                .labelsHidden()
                Text(verbatim: "\(settings.threshold)")
                    .font(Theme.Typography.metricSmall)
                    .contentTransition(.numericText(value: Double(settings.threshold)))
                    .frame(minWidth: 40, alignment: .trailing)
                    .animation(reduceMotion ? nil : Motion.snappy, value: settings.threshold)
                Button {
                    withAnimation(reduceMotion ? nil : Motion.spring) { settings.threshold = 128 }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.labelWerkPlain)
                .disabled(settings.threshold == 128)
                .help(tr("Schwelle auf 128 zurücksetzen"))
            }

            PrintPrefsDitherPreview(algorithm: settings.dither, threshold: settings.threshold,
                                    reduceMotion: reduceMotion) { algorithm in
                withAnimation(reduceMotion ? nil : Motion.spring) { settings.dither = algorithm }
            }
        }
    }

    private var ditherHint: String {
        switch settings.dither {
        case .threshold: return tr("Harte Schwelle: gestochen scharf – ideal für Text, Linien und Barcodes.")
        case .ordered: return tr("Gleichmäßiges Bayer-Muster: ruhige Flächen, gut für Grafiken und Logos.")
        case .halftone: return tr("Klassisches Punktraster wie im Zeitungsdruck – robust bei niedriger Auflösung.")
        case .floydSteinberg: return tr("Fehlerdiffusion: feine Verläufe, empfohlen für Fotos.")
        case .atkinson: return tr("Kontrastreiche Fehlerdiffusion: helle Bereiche bleiben sauber.")
        case .stucki: return tr("Sehr feine Fehlerdiffusion: beste Detailtreue, etwas mehr Rechenzeit.")
        }
    }

    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Grafikkompression"))
                    .font(Theme.Typography.headline)
                Text(tr("Geschätzte Auftragsgröße eines Etiketts – kleinere Aufträge übertragen schneller"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            PrintPrefsCompressionEstimate(
                settings: settings,
                language: session.saved.language,
                resolution: session.resolution,
                stock: session.stock,
                widthDots: session.labelWidthDots,
                heightDots: session.labelHeightDots,
                maxPrintWidthDots: session.model?.printWidthDots(session.resolution),
                reduceMotion: reduceMotion
            ) { compression in
                withAnimation(reduceMotion ? nil : Motion.spring) { settings.compression = compression }
            }
        }
    }
}

/// Beschriftung einer Schalter-Kachel.
struct PrintPrefsTileLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let isOn: Bool

    init(title: String, detail: String, systemImage: String, tint: Color, isOn: Bool) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, tint: isOn ? tint : Theme.offline, size: 32)
                .symbolEffect(.bounce, value: isOn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Schalter als Kachel mit eigenem, animiertem Schiebeschalter.
struct PrintPrefsTileToggleStyle: ToggleStyle {
    let reduceMotion: Bool

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button {
            withAnimation(reduceMotion ? nil : Motion.spring) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.subtleFill))
                        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
                        .frame(width: 36, height: 21)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .frame(width: 17, height: 17)
                        .padding(2)
                }
                .frame(width: 36, height: 21)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Theme.accent.opacity(0.09) : Theme.subtleFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent.opacity(0.45) : Theme.cardStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? tr("Ein") : tr("Aus"))
    }
}

// MARK: - Erweitert

/// Sprache, Schneiden, Kalibrieren, Speichern, Leeretiketten und eigene Start-/Endbefehle.
struct PrintPrefsAdvancedCard: View {
    @Binding var settings: PrintSettings
    @Bindable var session: PrinterSession
    let reduceMotion: Bool

    init(settings: Binding<PrintSettings>, session: PrinterSession, reduceMotion: Bool) {
        self._settings = settings
        self._session = Bindable(session)
        self.reduceMotion = reduceMotion
    }

    private var languages: [PrinterLanguage] {
        var list = session.model?.languages ?? PrinterLanguage.allCases
        if list.isEmpty { list = PrinterLanguage.allCases }
        if !list.contains(session.saved.language) { list.append(session.saved.language) }
        return list
    }

    private var codeLanguage: CodeLanguage { session.saved.language == .zpl ? .zpl : .plain }

    private var cutterActive: Bool {
        settings.printMode == .cutter || settings.printMode == .delayedCut || settings.printMode == .kiosk
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(tr("Erweitert"),
                              subtitle: tr("Druckersprache, Schneiden, Kalibrierung und eigene Befehle"),
                              systemImage: "gearshape.2")

                languageSection

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 6) {
                    NumberStepperField(title: tr("Schneiden nach je"), value: $settings.cutEvery, range: 0...9999,
                                       unit: tr("Etiketten"))
                    if settings.cutEvery > 0 && !cutterActive {
                        PrintPrefsHint(tr("Wirkt nur im Druckmodus „Schneiden“ – aktuell ist ein anderer Modus gewählt."),
                                       systemImage: "exclamationmark.triangle", tint: Theme.warning)
                    } else {
                        PrintPrefsHint(tr("0 = nur am Ende des Auftrags schneiden."), systemImage: "scissors")
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                    Toggle(isOn: $settings.calibrateBeforeJob) {
                        PrintPrefsTileLabel(title: tr("Vor jedem Auftrag kalibrieren"),
                                            detail: tr("Sendet ~JC – sinnvoll nach jedem Rollenwechsel."),
                                            systemImage: "ruler", tint: Theme.teal, isOn: settings.calibrateBeforeJob)
                    }
                    Toggle(isOn: $settings.saveToPrinter) {
                        PrintPrefsTileLabel(title: tr("Einstellungen im Drucker speichern"),
                                            detail: tr("Hängt ^JUS an – Werte bleiben nach dem Ausschalten erhalten."),
                                            systemImage: "externaldrive.badge.checkmark", tint: Theme.violet,
                                            isOn: settings.saveToPrinter)
                    }
                    Toggle(isOn: $settings.skipBlankLabels) {
                        PrintPrefsTileLabel(title: tr("Leere Etiketten überspringen"),
                                            detail: tr("Seiten ohne Inhalt werden nicht gedruckt – spart Material."),
                                            systemImage: "rectangle.dashed", tint: Theme.magenta,
                                            isOn: settings.skipBlankLabels)
                    }
                }
                .toggleStyle(PrintPrefsTileToggleStyle(reduceMotion: reduceMotion))

                Divider().opacity(0.5)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        commandEditor(title: tr("Startbefehle"),
                                      subtitle: tr("Vor dem ersten Etikett"),
                                      text: $settings.startCommands, snippets: startSnippets)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity)
                        commandEditor(title: tr("Endbefehle"),
                                      subtitle: tr("Nach dem letzten Etikett"),
                                      text: $settings.endCommands, snippets: endSnippets)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        commandEditor(title: tr("Startbefehle"),
                                      subtitle: tr("Vor dem ersten Etikett"),
                                      text: $settings.startCommands, snippets: startSnippets)
                        commandEditor(title: tr("Endbefehle"),
                                      subtitle: tr("Nach dem letzten Etikett"),
                                      text: $settings.endCommands, snippets: endSnippets)
                    }
                }
            }
            .animation(reduceMotion ? nil : Motion.spring, value: settings.cutEvery > 0 && !cutterActive)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(tr("Druckersprache"))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Picker(tr("Druckersprache"), selection: $session.saved.language) {
                    ForEach(languages) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            PrintPrefsHint(languageHint, systemImage: PrintPrefsSymbols.symbol(for: session.saved.language))
        }
    }

    private var languageHint: String {
        switch session.saved.language {
        case .zpl:
            return tr("ZPL II bietet alle Funktionen (Status, Dateien, Kompression). Ein Wechsel baut die Verbindung neu auf.")
        case .epl:
            return tr("EPL2 für ältere Drucker: Grafiken werden binär übertragen, kein Versatz per ^LT/^LS. Ein Wechsel baut die Verbindung neu auf.")
        case .cpcl:
            return tr("CPCL für Mobildrucker: Grafiken werden binär übertragen. Ein Wechsel baut die Verbindung neu auf.")
        }
    }

    private struct Snippet: Identifiable {
        let title: String
        let code: String
        var id: String { code }
    }

    private var startSnippets: [Snippet] {
        guard session.saved.language == .zpl else { return [] }
        return [
            Snippet(title: tr("UTF-8-Zeichensatz aktivieren"), code: "^XA^CI28^XZ"),
            Snippet(title: tr("Medien kalibrieren"), code: "~JC"),
            Snippet(title: tr("Etikettenursprung zurücksetzen"), code: "^XA^LH0,0^XZ"),
        ]
    }

    private var endSnippets: [Snippet] {
        guard session.saved.language == .zpl else { return [] }
        return [
            Snippet(title: tr("Ein Leeretikett vorschieben"), code: "~PH"),
            Snippet(title: tr("Einstellungen dauerhaft speichern"), code: "^XA^JUS^XZ"),
        ]
    }

    private func commandEditor(title: String, subtitle: String, text: Binding<String>, snippets: [Snippet]) -> some View {
        let value = text.wrappedValue
        let issue = formatIssue(value)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !snippets.isEmpty {
                    Menu {
                        ForEach(snippets) { snippet in
                            Button {
                                let current = text.wrappedValue
                                text.wrappedValue = current.isEmpty || current.hasSuffix("\n")
                                    ? current + snippet.code
                                    : current + "\n" + snippet.code
                            } label: {
                                Text(verbatim: snippet.code + "  –  " + snippet.title)
                            }
                        }
                    } label: {
                        Label(tr("Vorlage"), systemImage: "text.badge.plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(tr("Häufig genutzten Befehl einfügen"))
                }
                if !value.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.snappy) { text.wrappedValue = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("Befehle löschen"))
                }
            }
            CodeEditor(text: text, language: codeLanguage, fontSize: 12)
                .frame(height: 118)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(issue == nil ? Theme.cardStroke : Theme.warning.opacity(0.6), lineWidth: 1)
                }
            if let issue {
                PrintPrefsHint(issue, systemImage: "exclamationmark.triangle", tint: Theme.warning)
                    .transition(.opacity)
            } else {
                PrintPrefsHint(value.isEmpty ? tr("Keine Befehle – nichts wird zusätzlich gesendet.")
                                             : tr("%d Zeichen werden unverändert gesendet.", value.count),
                               systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Einfache Plausibilitätsprüfung für ZPL: `^XA` und `^XZ` sollten paarweise vorkommen.
    private func formatIssue(_ text: String) -> String? {
        guard session.saved.language == .zpl, !text.isEmpty else { return nil }
        let upper = text.uppercased()
        let starts = upper.components(separatedBy: "^XA").count - 1
        let ends = upper.components(separatedBy: "^XZ").count - 1
        if starts != ends {
            return tr("Unvollständiges Format: %d × ^XA, aber %d × ^XZ.", starts, ends)
        }
        return nil
    }
}

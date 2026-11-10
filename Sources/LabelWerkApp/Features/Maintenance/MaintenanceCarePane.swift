import SwiftUI
import LabelWerkKit

/// Druckkopf & Wartung: Zählerstände, Reinigungserinnerung, Druckkopftest und bebilderte
/// Reinigungsanleitung.
struct MaintCarePane: View {
    let session: PrinterSession
    let store: MaintenanceStore
    let reduceMotion: Bool

    @AppStorage(MaintCareSettings.intervalKey) private var intervalMeters: Double = MaintCareSettings.defaultInterval

    private var care: MaintCareController { store.care }

    /// Thermotransfer (mit Farbband) – bestimmt die Reinigungsempfehlung.
    private var usesRibbon: Bool {
        if let hostStatus = session.status?.hostStatus { return hostStatus.thermalTransferMode }
        if let mediaType = session.saved.settings.mediaType { return mediaType == .thermalTransfer }
        if let mediaType = session.stock.mediaType { return mediaType == .thermalTransfer }
        return false
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                MaintCleaningReminderCard(session: session, care: care, intervalMeters: $intervalMeters,
                                          usesRibbon: usesRibbon, reduceMotion: reduceMotion) {
                    care.guideStep = 0
                    withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(Self.guideID, anchor: .top)
                    }
                }
                .maintAppear(1, reduceMotion: reduceMotion)

                MaintOdometerCard(session: session, care: care)
                    .maintAppear(2, reduceMotion: reduceMotion)

                MaintHeadTestCard(session: session, care: care, deviceLanguage: store.language.deviceValue,
                                  reduceMotion: reduceMotion)
                    .maintAppear(3, reduceMotion: reduceMotion)

                MaintCleaningGuideCard(session: session, care: care, usesRibbon: usesRibbon, reduceMotion: reduceMotion)
                    .id(Self.guideID)
                    .maintAppear(4, reduceMotion: reduceMotion)
            }
        }
        .task {
            await care.loadIfNeeded(session: session)
        }
    }

    private static let guideID = "maintenance.cleaning-guide"
}

// MARK: - Reinigungserinnerung

private struct MaintCleaningReminderCard: View {
    let session: PrinterSession
    let care: MaintCareController
    @Binding var intervalMeters: Double
    let usesRibbon: Bool
    let reduceMotion: Bool
    let showGuide: () -> Void

    @Environment(AppModel.self) private var model

    private var printerRequests: Bool {
        session.alerts.contains { $0.kind == .cleanPrinthead }
    }

    var body: some View {
        let since = care.reading?.sinceCleanMeters
        let assessment = since.map {
            MaintCleaningAssessment.assess(sinceCleanMeters: $0, intervalMeters: intervalMeters,
                                           printerRequests: printerRequests)
        }
        let known = assessment != nil || printerRequests
        let level = assessment?.level ?? (printerRequests ? .due : .fine)
        let tint = Self.tint(level, known: known)

        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: tint) {
            HStack(alignment: .center, spacing: 26) {
                gauge(since: since, assessment: assessment, level: level)
                    .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(level, known: known))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tint)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: reduceMotion ? MaintCleaningLevel.fine : level)
                            .symbolEffect(.pulse, options: .repeating, isActive: level == .overdue && !reduceMotion)
                        Text(Self.headline(level, known: known))
                            .font(Theme.Typography.title)
                            .contentTransition(.opacity)
                    }

                    Text(usesRibbon
                         ? tr("Empfehlung: bei jedem Farbbandwechsel reinigen – spätestens alle %@.", MaintFormat.length(intervalMeters))
                         : tr("Empfehlung: bei jeder neuen Etikettenrolle reinigen – spätestens alle %@.", MaintFormat.length(intervalMeters)))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let assessment {
                        Text(assessment.remainingMeters >= 0
                             ? tr("Noch %@ bis zur nächsten Reinigung.", MaintFormat.length(assessment.remainingMeters))
                             : tr("Seit %@ überfällig.", MaintFormat.length(-assessment.remainingMeters)))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tint)
                            .contentTransition(.opacity)
                    }

                    if printerRequests {
                        MaintNote(tr("Der Drucker meldet selbst: Druckkopf reinigen."), style: .warning)
                            .transition(.opacity)
                    }
                    if care.phase == .unavailable || (care.phase == .loaded && since == nil) {
                        MaintNote(tr("Der Drucker meldet keine Strecke seit der letzten Reinigung (odometer.headclean). Anleitung und Druckkopftest funktionieren trotzdem."),
                                  style: .info)
                    }

                    HStack(spacing: 10) {
                        Text(tr("Erinnern nach"))
                            .font(.system(size: 12.5))
                        Stepper(value: $intervalMeters, in: MaintCareSettings.intervalRange, step: 25) {
                            Text(MaintFormat.length(intervalMeters))
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText(value: intervalMeters))
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                        .fixedSize()
                        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: intervalMeters)
                        if intervalMeters != MaintCareSettings.defaultInterval {
                            Button(tr("Standard")) {
                                intervalMeters = MaintCareSettings.defaultInterval
                            }
                            .buttonStyle(.labelWerkPlain)
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(action: showGuide) {
                            Label(tr("Reinigungsanleitung"), systemImage: "bubbles.and.sparkles")
                        }
                        .buttonStyle(.labelWerkSecondary)
                        if care.reading?.supportsCleaningReset == true {
                            if care.isResetting {
                                HStack(spacing: 8) {
                                    ProgressRing(progress: nil, size: 16, lineWidth: 2.5)
                                    Text(tr("Wird zurückgesetzt …"))
                                        .font(.system(size: 12.5, weight: .medium))
                                }
                                .transition(.opacity)
                            } else {
                                HoldToConfirmButton(title: tr("Gereinigt – Zähler zurücksetzen"),
                                                    systemImage: "arrow.counterclockwise",
                                                    tint: Theme.teal, duration: 0.9) {
                                    Task { await care.resetCleaningCounter(session: session, model: model) }
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: level)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: care.isResetting)
    }

    @ViewBuilder
    private func gauge(since: Double?, assessment: MaintCleaningAssessment?, level: MaintCleaningLevel) -> some View {
        if care.phase == .loading && care.reading == nil {
            ZStack {
                Circle().stroke(Theme.subtleFill, lineWidth: 12)
                ProgressRing(progress: nil, size: 34, lineWidth: 3.5)
            }
        } else {
            RingGauge(value: min(1, assessment?.ratio ?? 0), lineWidth: 12, colors: Self.colors(level),
                      label: tr("seit Reinigung"), valueText: since.map(MaintFormat.length) ?? "–")
                .overlay {
                    CelebrationBurst(trigger: care.resetCelebration, colors: [Theme.teal, Theme.ready, Theme.violet])
                        .frame(width: 260, height: 260)
                        .allowsHitTesting(false)
                }
        }
    }

    static func tint(_ level: MaintCleaningLevel, known: Bool) -> Color {
        guard known else { return Theme.violet }
        switch level {
        case .fine: return Theme.ready
        case .soon: return Theme.teal
        case .due: return Theme.warning
        case .overdue: return Theme.error
        }
    }

    static func colors(_ level: MaintCleaningLevel) -> [Color] {
        switch level {
        case .fine: return [Theme.ready, Theme.teal]
        case .soon: return [Theme.teal, Theme.paused]
        case .due: return [Theme.paused, Theme.warning]
        case .overdue: return [Theme.warning, Theme.error]
        }
    }

    static func symbol(_ level: MaintCleaningLevel, known: Bool) -> String {
        guard known else { return "sparkles" }
        switch level {
        case .fine: return "checkmark.seal.fill"
        case .soon: return "clock"
        case .due: return "exclamationmark.triangle.fill"
        case .overdue: return "exclamationmark.octagon.fill"
        }
    }

    static func headline(_ level: MaintCleaningLevel, known: Bool) -> String {
        guard known else { return tr("Druckkopfpflege") }
        switch level {
        case .fine: return tr("Druckkopf sauber")
        case .soon: return tr("Reinigung bald fällig")
        case .due: return tr("Reinigung empfohlen")
        case .overdue: return tr("Reinigung überfällig")
        }
    }
}

// MARK: - Zählerstände

private struct MaintOdometerCard: View {
    let session: PrinterSession
    let care: MaintCareController

    private var subtitle: String {
        if let loadedAt = care.loadedAt {
            return tr("Stand: %@", loadedAt.formatted(date: .omitted, time: .standard))
        }
        return tr("Laufleistung, wie der Drucker sie meldet")
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Zählerstände"), subtitle: subtitle, systemImage: "gauge.with.dots.needle.33percent") {
                    Button {
                        Task { await care.load(session: session) }
                    } label: {
                        HStack(spacing: 6) {
                            if care.phase == .loading {
                                ProgressRing(progress: nil, size: 12, lineWidth: 2)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(tr("Neu lesen"))
                        }
                    }
                    .buttonStyle(.labelWerkPlain)
                    .disabled(care.phase == .loading)
                }

                if let reading = care.reading, !reading.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Theme.Metrics.cardSpacing)],
                              spacing: Theme.Metrics.cardSpacing) {
                        lengthTile(tr("Gesamtstrecke"), meters: reading.totalMeters ?? session.status?.odometerMeters,
                                   raw: reading.raw[MaintOdometer.totalKey], symbol: "road.lanes", tint: Theme.teal)
                        lengthTile(tr("Seit Reinigung"), meters: reading.sinceCleanMeters,
                                   raw: reading.raw[MaintOdometer.headCleanKey], symbol: "bubbles.and.sparkles",
                                   tint: Theme.magenta)
                        lengthTile(tr("Druckkopf seit Tausch"), meters: reading.headMeters,
                                   raw: reading.raw[MaintOdometer.headNewKey], symbol: "flame", tint: Theme.warning)
                        lengthTile(tr("Rücksetzbarer Zähler"), meters: reading.markerMeters,
                                   raw: reading.raw[MaintOdometer.markerKey], symbol: "ruler", tint: Theme.printing)
                        if let labels = reading.totalLabels {
                            MetricTile(title: tr("Etiketten gesamt"), value: labels.formatted(),
                                       systemImage: "square.stack.3d.up.fill", tint: Theme.violet)
                        }
                    }
                    if let element = reading.elementTest {
                        KeyValueRow(tr("Elementtest des Druckkopfs"), element, monospaced: true, copyable: true)
                    }
                } else if care.phase == .loading || care.phase == .idle {
                    HStack(spacing: 10) {
                        ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                        Text(tr("Zählerstände werden gelesen …"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    MaintNote(tr("Dieser Drucker meldet keine Zählerstände über SGD (odometer.*)."), style: .info)
                }
            }
        }
    }

    @ViewBuilder
    private func lengthTile(_ title: String, meters: Double?, raw: String?, symbol: String, tint: Color) -> some View {
        if let meters {
            let parts = MaintFormat.lengthParts(meters)
            MetricTile(title: title, value: parts.value, unit: parts.unit, systemImage: symbol, tint: tint)
        } else if let raw {
            MetricTile(title: title, value: raw, systemImage: symbol, tint: tint)
        }
    }
}

// MARK: - Druckkopftest

private struct MaintPrintMotion {
    var offset: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1
}

private struct MaintHeadTestCard: View {
    let session: PrinterSession
    let care: MaintCareController
    let deviceLanguage: String?
    let reduceMotion: Bool

    var body: some View {
        let layout = MaintCareController.testLayout(for: session)
        let aspect = CGFloat(layout.heightDots) / CGFloat(max(1, layout.widthDots))
        let previewWidth: CGFloat = 230
        let previewHeight = min(300, max(110, previewWidth * aspect))
        let headDots = session.model?.printWidthDots(session.resolution)
        let zplCapable = MaintCareController.canPrintTestPattern(session)
        let languageMismatch = deviceLanguage.map {
            !MaintDeviceLanguage.isCompatible(deviceValue: $0, output: PrinterLanguage.zpl, model: session.model)
        } ?? false

        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Druckkopftest"),
                              subtitle: tr("Testmuster über die volle Etikettenbreite – zeigt verschmutzte oder defekte Heizelemente"),
                              systemImage: "barcode")
                HStack(alignment: .top, spacing: 22) {
                    MaintHeadTestPreview(layout: layout)
                        .frame(width: previewWidth, height: previewHeight)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                        .keyframeAnimator(initialValue: MaintPrintMotion(),
                                          trigger: reduceMotion ? 0 : care.testPrintCount) { content, value in
                            content
                                .offset(y: value.offset)
                                .scaleEffect(value.scale, anchor: .top)
                                .opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.offset) {
                                CubicKeyframe(-8, duration: 0.16)
                                SpringKeyframe(16, duration: 0.42, spring: .bouncy)
                                SpringKeyframe(0, duration: 0.55, spring: .smooth)
                            }
                            KeyframeTrack(\.scale) {
                                CubicKeyframe(0.95, duration: 0.16)
                                SpringKeyframe(1.04, duration: 0.4, spring: .bouncy)
                                SpringKeyframe(1, duration: 0.5, spring: .smooth)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(0.55, duration: 0.16)
                                LinearKeyframe(1, duration: 0.3)
                            }
                        }
                        .accessibilityLabel(tr("Vorschau des Druckkopftests"))

                    VStack(alignment: .leading, spacing: 10) {
                        legendRow(symbol: "rectangle.fill", title: tr("Schwarzer Balken"),
                                  text: tr("Weiße Längsstreifen zeigen verschmutzte oder ausgefallene Heizelemente."))
                        legendRow(symbol: "barcode", title: tr("Linienraster"),
                                  text: tr("Jedes Heizelement druckt eine eigene Linie – Lücken verraten einzelne Ausfälle."))
                        legendRow(symbol: "ruler", title: tr("Lineal"),
                                  text: tr("Zeigt, wo (in mm ab dem linken Rand) eine Störung liegt."))
                        Divider().opacity(0.5)
                        KeyValueRow(tr("Testbreite"),
                                    tr("%d Punkte (%.1f mm)", layout.widthDots, session.resolution.mm(fromDots: layout.widthDots)))
                        KeyValueRow(tr("Etikett"), session.stock.name)
                        if let headDots, headDots > layout.widthDots + 8 {
                            MaintNote(tr("Das Etikett ist schmaler als der Druckkopf (%.0f von %.0f mm) – für einen vollständigen Test ein breiteres Etikett einlegen.",
                                         session.resolution.mm(fromDots: layout.widthDots),
                                         session.resolution.mm(fromDots: headDots)),
                                      style: .info)
                        }
                        if !zplCapable {
                            MaintNote(tr("Dieses Modell versteht kein ZPL – das Testmuster ist nicht verfügbar."), style: .warning)
                        } else if languageMismatch, let deviceLanguage {
                            MaintNote(tr("Der Drucker erwartet gerade „%@“ – das Testmuster ist ZPL und würde nicht korrekt gedruckt.",
                                         deviceLanguage),
                                      style: .warning)
                        }
                        Button {
                            Task { await care.printTestPattern(session: session) }
                        } label: {
                            HStack(spacing: 6) {
                                if care.isPrintingTest {
                                    ProgressRing(progress: nil, size: 13, lineWidth: 2)
                                } else {
                                    Image(systemName: "printer.fill")
                                }
                                Text(tr("Testmuster drucken"))
                            }
                        }
                        .buttonStyle(.labelWerkPrimary)
                        .disabled(care.isPrintingTest || !zplCapable)
                    }
                }
            }
        }
    }

    private func legendRow(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Maßstäbliche Vorschau des Testmusters (gleiche Geometrie wie das gesendete ZPL).
private struct MaintHeadTestPreview: View {
    let layout: MaintHeadTest.Layout

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / CGFloat(layout.widthDots), size.height / CGFloat(layout.heightDots))
            let width = CGFloat(layout.widthDots) * scale
            let height = CGFloat(layout.heightDots) * scale
            let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
            let paper = CGRect(origin: origin, size: CGSize(width: width, height: height))
            context.fill(Path(roundedRect: paper, cornerRadius: 4), with: .color(Theme.labelPaper))
            context.clip(to: Path(roundedRect: paper, cornerRadius: 4))

            var ink = Path()
            for element in layout.elements {
                switch element {
                case let .box(x, y, boxWidth, boxHeight, _):
                    ink.addRect(CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale,
                                       width: max(0.4, CGFloat(boxWidth) * scale),
                                       height: max(0.4, CGFloat(boxHeight) * scale)))
                case let .text(x, y, _, textHeight, value):
                    let fontSize = max(3, CGFloat(textHeight) * scale * 0.9)
                    var text = context.resolve(Text(verbatim: value).font(.system(size: fontSize, weight: .semibold)))
                    text.shading = .color(Theme.labelInk)
                    context.draw(text, at: CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale),
                                 anchor: .topLeading)
                }
            }
            context.fill(ink, with: .color(Theme.labelInk))
        }
    }
}

// MARK: - Reinigungsanleitung

private enum MaintGuideKind: Int, Hashable {
    case powerOff, open, head, platen, dry, finish
}

private struct MaintGuideStep: Identifiable {
    let kind: MaintGuideKind
    let title: String
    let detail: String
    let caution: String?
    let symbols: [String]
    let tint: Color

    var id: Int { kind.rawValue }

    static func all(usesRibbon: Bool) -> [MaintGuideStep] {
        [
            MaintGuideStep(kind: .powerOff, title: tr("Ausschalten & abkühlen lassen"),
                           detail: tr("Drucker ausschalten und einige Minuten warten – der Druckkopf wird beim Drucken sehr heiß."),
                           caution: tr("Den Druckkopf nicht direkt nach dem Drucken berühren."),
                           symbols: ["power", "thermometer.medium"], tint: Theme.warning),
            MaintGuideStep(kind: .open, title: tr("Öffnen & Medien entnehmen"),
                           detail: usesRibbon
                               ? tr("Abdeckung öffnen, Etikettenrolle und Farbband herausnehmen. Vorher ein geerdetes Metallteil berühren, um statische Aufladung abzubauen.")
                               : tr("Abdeckung öffnen und die Etikettenrolle herausnehmen. Vorher ein geerdetes Metallteil berühren, um statische Aufladung abzubauen."),
                           caution: nil,
                           symbols: ["printer", "hand.raised"], tint: Theme.printing),
            MaintGuideStep(kind: .head, title: tr("Druckkopf abwischen"),
                           detail: tr("Mit dem Reinigungsstift oder einem fusselfreien Tuch mit Isopropylalkohol (mind. 90 %) den dunklen Heizstreifen von der Mitte nach außen abwischen."),
                           caution: tr("Niemals mit scharfen oder harten Gegenständen kratzen – das zerstört Heizelemente."),
                           symbols: ["pencil.tip"], tint: Theme.magenta),
            MaintGuideStep(kind: .platen, title: tr("Andruckwalze reinigen"),
                           detail: usesRibbon
                               ? tr("Die Gummiwalze mit einem alkoholgetränkten Tupfer abwischen und dabei weiterdrehen, bis die ganze Oberfläche sauber ist. Auch die Farbbandführung kurz abwischen.")
                               : tr("Die Gummiwalze mit einem alkoholgetränkten Tupfer abwischen und dabei weiterdrehen, bis die ganze Oberfläche sauber ist."),
                           caution: nil,
                           symbols: ["circle.circle"], tint: Theme.teal),
            MaintGuideStep(kind: .dry, title: tr("Trocknen lassen"),
                           detail: tr("1–2 Minuten warten, bis der Alkohol vollständig verdunstet ist."),
                           caution: tr("Keine Druckluft verwenden – sie bläst Staub tiefer in die Mechanik."),
                           symbols: ["wind", "timer"], tint: Theme.teal),
            MaintGuideStep(kind: .finish, title: tr("Einlegen & prüfen"),
                           detail: usesRibbon
                               ? tr("Etiketten und Farbband wieder einlegen, Drucker schließen und einschalten. Danach den Reinigungszähler zurücksetzen und den Druckkopftest drucken.")
                               : tr("Etiketten wieder einlegen, Drucker schließen und einschalten. Danach den Reinigungszähler zurücksetzen und den Druckkopftest drucken."),
                           caution: nil,
                           symbols: ["checkmark.seal", "printer.fill"], tint: Theme.ready),
        ]
    }
}

private struct MaintCleaningGuideCard: View {
    let session: PrinterSession
    @Bindable var care: MaintCareController
    let usesRibbon: Bool
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var forward = true

    var body: some View {
        let steps = MaintGuideStep.all(usesRibbon: usesRibbon)
        let index = min(max(0, care.guideStep), steps.count - 1)
        let step = steps[index]

        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.magenta) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(tr("Druckkopf reinigen"),
                              subtitle: tr("Schritt für Schritt – mit Reinigungsstift oder Isopropylalkohol (mind. 90 %)"),
                              systemImage: "bubbles.and.sparkles") {
                    Text(tr("Schritt %d von %d", index + 1, steps.count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(index)))
                }

                ZStack {
                    HStack(alignment: .center, spacing: 22) {
                        illustration(step)
                            .frame(width: 280, height: 190)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(step.title)
                                .font(Theme.Typography.title)
                            Text(step.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let caution = step.caution {
                                MaintNote(caution, style: .warning)
                            }
                            if step.kind == .finish {
                                finishActions
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .id(index)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                .clipped()

                navigation(index: index, count: steps.count)
            }
        }
    }

    @ViewBuilder
    private func illustration(_ step: MaintGuideStep) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [step.tint.opacity(0.16), Theme.violet.opacity(0.06)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            switch step.kind {
            case .head:
                MaintHeadCleaningScene(reduceMotion: reduceMotion)
            case .platen:
                MaintPlatenScene(reduceMotion: reduceMotion)
            default:
                MaintGuideSymbolScene(symbols: step.symbols, tint: step.tint, reduceMotion: reduceMotion)
            }
        }
        .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
        .clipShape(shape)
    }

    private var finishActions: some View {
        HStack(spacing: 8) {
            if care.reading?.supportsCleaningReset == true {
                Button {
                    Task { await care.resetCleaningCounter(session: session, model: model) }
                } label: {
                    Label(tr("Zähler zurücksetzen"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(care.isResetting)
            }
            Button {
                Task { await care.printTestPattern(session: session) }
            } label: {
                Label(tr("Druckkopftest drucken"), systemImage: "printer.fill")
            }
            .buttonStyle(.labelWerkPrimary)
            .disabled(care.isPrintingTest || !MaintCareController.canPrintTestPattern(session))
            .help(MaintCareController.canPrintTestPattern(session)
                  ? tr("Testmuster über die volle Etikettenbreite – zeigt verschmutzte oder defekte Heizelemente")
                  : tr("Dieses Modell versteht kein ZPL – das Testmuster ist nicht verfügbar."))
        }
        .padding(.top, 4)
    }

    private func navigation(index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                go(to: index - 1, count: count)
            } label: {
                Label(tr("Zurück"), systemImage: "chevron.left")
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(index == 0)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { position in
                    Capsule()
                        .fill(position == index ? Theme.magenta
                              : (position < index ? Theme.magenta.opacity(0.4) : Theme.separator))
                        .frame(width: position == index ? 22 : 8, height: 8)
                        .contentShape(Rectangle())
                        .onTapGesture { go(to: position, count: count) }
                        .accessibilityLabel(tr("Schritt %d", position + 1))
                        .accessibilityAddTraits(.isButton)
                }
            }
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: index)

            Spacer(minLength: 8)

            Button {
                go(to: index + 1 < count ? index + 1 : 0, count: count)
            } label: {
                Label(index + 1 < count ? tr("Weiter") : tr("Von vorn"),
                      systemImage: index + 1 < count ? "chevron.right" : "arrow.counterclockwise")
            }
            .buttonStyle(.labelWerkPrimary)
        }
    }

    private func go(to newIndex: Int, count: Int) {
        let target = min(max(0, newIndex), count - 1)
        guard target != care.guideStep else { return }
        forward = target > care.guideStep
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            care.guideStep = target
        }
    }
}

// MARK: - Illustrationen

/// Große Symbole, die beim Erscheinen einmal „aufspringen“ (kein Dauerlauf).
private struct MaintGuideSymbolScene: View {
    let symbols: [String]
    let tint: Color
    let reduceMotion: Bool

    @State private var token = 0

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                let primary = index == 0
                ZStack {
                    Circle()
                        .fill(tint.opacity(primary ? 0.18 : 0.1))
                        .frame(width: primary ? 96 : 64, height: primary ? 96 : 64)
                    Image(systemName: symbol)
                        .font(.system(size: primary ? 40 : 26, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, value: token)
                }
                .phaseAnimator([false, true], trigger: token) { content, pop in
                    content
                        .scaleEffect(pop ? 1.1 : 1)
                        .rotationEffect(.degrees(pop ? (primary ? -6 : 6) : 0))
                } animation: { pop in
                    pop ? Animation.spring(response: 0.3, dampingFraction: 0.5).delay(Double(index) * 0.08)
                        : Animation.spring(response: 0.5, dampingFraction: 0.7)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                token += 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// Reinigungsstift wischt den Heizstreifen von der Mitte nach außen (30 fps, nur solange sichtbar und
/// das Fenster aktiv ist).
private struct MaintHeadCleaningScene: View {
    let reduceMotion: Bool
    @Environment(\.controlActiveState) private var controlActiveState
    /// Im sichtbaren Bereich der Seite (aus dem Bild gescrollt: Zeitleiste anhalten).
    @State private var isOnScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || controlActiveState == .inactive || !isOnScreen)) { timeline in
            Canvas { context, size in
                let cycle = 4.4
                let phase = reduceMotion
                    ? 0.3
                    : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                MaintCleaningArt.drawHead(in: &context, size: size, phase: phase)
            }
        }
        .maintScrollVisibility($isOnScreen)
        .accessibilityLabel(tr("Animation: Der Reinigungsstift wischt den Druckkopf von der Mitte nach außen."))
    }
}

/// Andruckwalze dreht sich unter einem Tupfer; Flecken verschwinden beim Vorbeidrehen (30 fps, nur
/// solange sichtbar und das Fenster aktiv ist).
private struct MaintPlatenScene: View {
    let reduceMotion: Bool
    @Environment(\.controlActiveState) private var controlActiveState
    /// Im sichtbaren Bereich der Seite (aus dem Bild gescrollt: Zeitleiste anhalten).
    @State private var isOnScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || controlActiveState == .inactive || !isOnScreen)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 2.2 : timeline.date.timeIntervalSinceReferenceDate
                MaintCleaningArt.drawPlaten(in: &context, size: size, time: time)
            }
        }
        .maintScrollVisibility($isOnScreen)
        .accessibilityLabel(tr("Animation: Die Andruckwalze wird beim Drehen mit einem Tupfer gereinigt."))
    }
}

private enum MaintCleaningArt {
    // Farben der Illustrationen – ausschließlich aus Theme-Tokens abgeleitet.
    /// Rückstände auf Heizstreifen und Walze.
    static let dirt = Theme.warning.opacity(0.85)
    /// Metall von Druckkopf und Halterung (hell → dunkel).
    static let metalLight = Theme.labelPaper
    static let metalDark = Theme.offline
    /// Heizstreifen und Gummiwalze.
    static let rubber = Theme.labelInk
    /// Reinigungsstift-Spitze, Tupferstiel und Watte.
    static let swabWhite = Theme.labelPaper
    static let specks: [Double] = [0.14, 0.2, 0.27, 0.33, 0.4, 0.46, 0.55, 0.61, 0.68, 0.74, 0.8, 0.86]

    static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// Stiftposition (Anteil der Breite) und Abheben (0…1) für eine Phase 0…1.
    static func pen(_ p: Double) -> (x: Double, lift: Double) {
        switch p {
        case ..<0.38:
            return (0.5 + 0.4 * smooth(p / 0.38), 0)
        case ..<0.48:
            let local = (p - 0.38) / 0.1
            return (0.9 - 0.4 * smooth(local), sin(local * .pi))
        case ..<0.86:
            return (0.5 - 0.4 * smooth((p - 0.48) / 0.38), 0)
        default:
            let local = (p - 0.86) / 0.14
            return (0.1 + 0.4 * smooth(local), sin(local * .pi))
        }
    }

    /// Sichtbarkeit eines Flecks (1 = schmutzig, 0 = gereinigt).
    static func speckAlpha(_ position: Double, phase p: Double) -> Double {
        if p >= 0.93 { return (p - 0.93) / 0.07 }
        let x = pen(p).x
        if position >= 0.5 {
            if p >= 0.38 { return 0 }
            return x >= position ? 0 : 1
        }
        if p >= 0.86 { return 0 }
        if p < 0.48 { return 1 }
        return x <= position ? 0 : 1
    }

    static func sparkle(center: CGPoint, size s: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - s))
        path.addQuadCurve(to: CGPoint(x: center.x + s, y: center.y), control: center)
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + s), control: center)
        path.addQuadCurve(to: CGPoint(x: center.x - s, y: center.y), control: center)
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - s), control: center)
        path.closeSubpath()
        return path
    }

    static func drawHead(in context: inout GraphicsContext, size: CGSize, phase p: Double) {
        let w = size.width
        let h = size.height
        let mount = CGRect(x: w * 0.05, y: h * 0.4, width: w * 0.9, height: h * 0.12)
        let head = CGRect(x: w * 0.08, y: h * 0.48, width: w * 0.84, height: h * 0.2)

        // Halterung und Druckkopf
        context.fill(Path(roundedRect: mount, cornerRadius: 6), with: .color(metalDark.opacity(0.5)))
        context.fill(Path(roundedRect: head, cornerRadius: 8),
                     with: .linearGradient(Gradient(colors: [metalLight, metalDark]),
                                           startPoint: CGPoint(x: head.midX, y: head.minY),
                                           endPoint: CGPoint(x: head.midX, y: head.maxY)))

        // Heizstreifen
        let lineY = head.minY + head.height * 0.62
        let heater = CGRect(x: head.minX + 10, y: lineY - 2, width: head.width - 20, height: 4)
        context.fill(Path(roundedRect: heater, cornerRadius: 2), with: .color(rubber))

        // Feuchte Wischspur
        let penState = pen(p)
        var wet: [(Double, Double)] = []
        if p < 0.38 {
            wet.append((0.5, penState.x))
        } else if p < 0.93 {
            wet.append((0.5, 0.9))
        }
        if p >= 0.48 && p < 0.86 {
            wet.append((penState.x, 0.5))
        } else if p >= 0.86 && p < 0.93 {
            wet.append((0.1, 0.5))
        }
        for (from, to) in wet where to > from {
            let rect = CGRect(x: w * from, y: lineY - 4, width: w * (to - from), height: 8)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.teal.opacity(0.32)))
        }

        // Schmutz und Glanz
        for (index, position) in specks.enumerated() {
            let alpha = speckAlpha(position, phase: p)
            let center = CGPoint(x: w * position, y: lineY)
            if alpha > 0.01 {
                let rect = CGRect(x: center.x - 4, y: center.y - 3.5, width: 8, height: 7)
                context.fill(Path(ellipseIn: rect), with: .color(dirt.opacity(0.85 * alpha)))
            }
            if alpha < 0.5 && p < 0.93 {
                let twinkle = 0.55 + 0.45 * sin(p * 28 + Double(index) * 1.7)
                context.fill(sparkle(center: CGPoint(x: center.x, y: lineY - 11), size: 4.5),
                             with: .color(Color.white.opacity(0.9 * twinkle)))
            }
        }

        // Reinigungsstift
        var stylus = context
        stylus.translateBy(x: w * penState.x, y: lineY - 2 - CGFloat(penState.lift) * h * 0.12)
        stylus.rotate(by: .degrees(28))
        let length = h * 0.5
        let tip = Path(roundedRect: CGRect(x: -3.5, y: -12, width: 7, height: 13), cornerRadius: 3)
        stylus.fill(tip, with: .color(swabWhite))
        stylus.fill(tip, with: .color(Theme.teal.opacity(0.22)))
        stylus.fill(Path(roundedRect: CGRect(x: -7, y: -length, width: 14, height: length - 10), cornerRadius: 5),
                    with: .linearGradient(Gradient(colors: [Theme.magenta, Theme.violet]),
                                          startPoint: CGPoint(x: -7, y: 0), endPoint: CGPoint(x: 7, y: 0)))
        stylus.fill(Path(CGRect(x: -7, y: -length * 0.55, width: 14, height: 5)), with: .color(Color.white.opacity(0.55)))
        if penState.lift < 0.05 {
            stylus.fill(Path(ellipseIn: CGRect(x: 5, y: -8, width: 4, height: 5)), with: .color(Theme.teal.opacity(0.75)))
        }
    }

    static func drawPlaten(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width
        let h = size.height
        let center = CGPoint(x: w * 0.45, y: h * 0.6)
        let radius = min(w, h) * 0.27
        let angle = t * 1.2
        let fullTurn = 2 * Double.pi

        // Achshalter
        context.fill(Path(roundedRect: CGRect(x: center.x - radius * 1.6, y: center.y - 3, width: radius * 3.2, height: 6),
                          cornerRadius: 3),
                     with: .color(metalDark.opacity(0.45)))

        // Walze
        let roller = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: roller), with: .color(rubber))
        context.fill(Path(ellipseIn: roller),
                     with: .radialGradient(Gradient(colors: [metalDark.opacity(0.55), metalDark.opacity(0)]),
                                           center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3),
                                           startRadius: 0, endRadius: radius * 1.4))
        for k in 0..<8 {
            let a = angle + Double(k) * Double.pi / 4
            var groove = Path()
            groove.move(to: CGPoint(x: center.x + CGFloat(cos(a)) * radius * 0.55, y: center.y + CGFloat(sin(a)) * radius * 0.55))
            groove.addLine(to: CGPoint(x: center.x + CGFloat(cos(a)) * radius * 0.9, y: center.y + CGFloat(sin(a)) * radius * 0.9))
            context.stroke(groove, with: .color(Color.white.opacity(0.13)), lineWidth: 2)
        }
        let hub = radius * 0.18
        context.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(metalDark))

        // Flecken auf der Oberfläche
        let cycleAngle = angle.truncatingRemainder(dividingBy: fullTurn)
        let returning = cycleAngle > fullTurn * 0.88 ? (cycleAngle - fullTurn * 0.88) / (fullTurn * 0.12) : 0
        let top = -Double.pi / 2
        for base in [0.3, 1.1, 1.9, 2.6, 3.4, 4.2, 5.0, 5.7] {
            var distance = (top - base).truncatingRemainder(dividingBy: fullTurn)
            if distance < 0 { distance += fullTurn }
            let cleaned = cycleAngle >= distance
            let alpha = cleaned ? returning : 1
            guard alpha > 0.01 else { continue }
            let current = base + angle
            let point = CGPoint(x: center.x + CGFloat(cos(current)) * radius * 0.96,
                                y: center.y + CGFloat(sin(current)) * radius * 0.96)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)),
                         with: .color(dirt.opacity(0.9 * alpha)))
        }

        // Drehrichtung
        var arc = Path()
        let arcRadius = radius + 14
        for step in 0...16 {
            let a = (15 + 60 * Double(step) / 16) * Double.pi / 180
            let point = CGPoint(x: center.x + CGFloat(cos(a)) * arcRadius, y: center.y + CGFloat(sin(a)) * arcRadius)
            if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
        }
        context.stroke(arc, with: .color(Theme.magenta.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        let endAngle = 75 * Double.pi / 180
        let end = CGPoint(x: center.x + CGFloat(cos(endAngle)) * arcRadius, y: center.y + CGFloat(sin(endAngle)) * arcRadius)
        let tangent = CGPoint(x: -CGFloat(sin(endAngle)), y: CGFloat(cos(endAngle)))
        let normal = CGPoint(x: CGFloat(cos(endAngle)), y: CGFloat(sin(endAngle)))
        var head = Path()
        head.move(to: CGPoint(x: end.x + tangent.x * 7, y: end.y + tangent.y * 7))
        head.addLine(to: CGPoint(x: end.x + normal.x * 5, y: end.y + normal.y * 5))
        head.addLine(to: CGPoint(x: end.x - normal.x * 5, y: end.y - normal.y * 5))
        head.closeSubpath()
        context.fill(head, with: .color(Theme.magenta.opacity(0.85)))

        // Tupfer
        var swab = context
        swab.translateBy(x: center.x, y: center.y - radius - 6)
        swab.rotate(by: .degrees(35))
        swab.fill(Path(roundedRect: CGRect(x: -2, y: -h * 0.42, width: 4, height: h * 0.42 - 6), cornerRadius: 2),
                  with: .color(swabWhite))
        let cotton = CGRect(x: -7, y: -12, width: 14, height: 17)
        swab.fill(Path(ellipseIn: cotton), with: .color(swabWhite))
        swab.stroke(Path(ellipseIn: cotton), with: .color(Theme.teal.opacity(0.55)), lineWidth: 1)
        swab.fill(Path(ellipseIn: CGRect(x: -4, y: 0, width: 8, height: 5)), with: .color(Theme.teal.opacity(0.35)))
    }
}

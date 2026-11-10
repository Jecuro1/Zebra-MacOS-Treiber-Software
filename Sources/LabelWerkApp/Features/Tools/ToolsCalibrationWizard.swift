import SwiftUI
import LabelWerkKit

// MARK: - Schritte & Ergebnis

private enum CalibrationStep: Int, CaseIterable, Identifiable, Comparable {
    case intro
    case openHead
    case insertMedia
    case closeHead
    case calibrate
    case result

    var id: Int { rawValue }

    static func < (lhs: CalibrationStep, rhs: CalibrationStep) -> Bool { lhs.rawValue < rhs.rawValue }

    var shortTitle: String {
        switch self {
        case .intro: return tr("Start")
        case .openHead: return tr("Öffnen")
        case .insertMedia: return tr("Einlegen")
        case .closeHead: return tr("Schließen")
        case .calibrate: return tr("Kalibrieren")
        case .result: return tr("Ergebnis")
        }
    }

    var next: CalibrationStep? { CalibrationStep(rawValue: rawValue + 1) }
    var previous: CalibrationStep? { CalibrationStep(rawValue: rawValue - 1) }
}

private enum CalibrationRunState: Int, Equatable, Comparable {
    case idle
    case sending
    case measuring
    case verifying
    case finished

    static func < (lhs: CalibrationRunState, rhs: CalibrationRunState) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct CalibrationOutcome: Equatable {
    var commandSent: Bool
    var verified: Bool
    var issues: [PrinterAlert]
    var measuredLengthDots: Int?
    var errorMessage: String?

    var succeeded: Bool { commandSent && issues.isEmpty }
}

// MARK: - Assistent

/// Geführte Medienkalibrierung: Druckkopf öffnen → Etiketten einlegen → schließen → `~JC` →
/// Status prüfen. Erkennt (bei bidirektionalen Verbindungen) den Zustand des Druckkopfs live und
/// vergleicht die vom Drucker gemessene Etikettenlänge mit dem eingestellten Format.
struct ToolsCalibrationWizard: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var step: CalibrationStep = .intro
    @State private var movingForward = true
    @State private var runState: CalibrationRunState = .idle
    @State private var outcome: CalibrationOutcome?
    @State private var detectedStep: CalibrationStep?
    @State private var celebration = 0
    @State private var simulationBusy = false
    @State private var testLabelBusy = false
    @State private var calibrationTask: Task<Void, Never>?
    @Namespace private var indicatorNamespace

    init(session: PrinterSession) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var isRunning: Bool { runState != .idle && runState != .finished }
    private var headIsOpen: Bool { session.alerts.contains { $0.kind == .headOpen } }
    private var mediaMissing: Bool { session.alerts.contains { $0.kind == .mediaOut } }

    private var calibrateSupported: Bool {
        PrinterAction.calibrate.payload(language: session.saved.language, resolution: session.resolution,
                                        widthDots: session.labelWidthDots, heightDots: session.labelHeightDots) != nil
    }

    private var tracking: MediaTracking { session.saved.settings.tracking ?? session.stock.tracking }
    private var mediaType: MediaType { session.saved.settings.mediaType ?? session.stock.mediaType ?? .directThermal }

    private var subtitle: String {
        if let printerModel = session.model {
            return tr("%@ · %@", session.displayName, printerModel.displayName)
        }
        return session.displayName
    }

    var body: some View {
        VStack(spacing: 18) {
            ToolsSheetHeader(title: tr("Kalibrier-Assistent"), subtitle: subtitle, systemImage: "ruler", tint: Theme.teal) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.labelWerkPlain)
                .keyboardShortcut(.cancelAction)
                .help(tr("Schließen"))
            }

            stepIndicator

            HStack(alignment: .center, spacing: 26) {
                ZStack {
                    CalibrationIllustration(
                        step: step,
                        calibrating: isRunning,
                        outcomeOK: step == .result ? outcome.map { $0.succeeded } : nil,
                        accent: session.accentColor,
                        reduceMotion: reduceMotion
                    )
                    CelebrationBurst(trigger: celebration, colors: [Theme.ready, Theme.teal, session.accentColor])
                }
                .frame(width: 320, height: 240)

                // Rollbar, damit lange Hinweise (Lösungen, Einlegetipps) nie abgeschnitten werden.
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        stepContent
                            .id(step)
                            .transition(stepTransition)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 4)
                    .padding(.trailing, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
            .frame(maxHeight: .infinity)

            liveStatusBar
            footer
        }
        .padding(24)
        .frame(width: 820, height: 600)
        .background {
            AnimatedBackground(style: .subtle)
                .ignoresSafeArea()
        }
        .task(id: step) {
            await observe(step)
        }
        .onDisappear {
            calibrationTask?.cancel()
            calibrationTask = nil
        }
    }

    // MARK: Schrittanzeige

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(CalibrationStep.allCases) { item in
                VStack(spacing: 6) {
                    ZStack {
                        if item == step {
                            Circle()
                                .fill(Theme.brandGradient)
                                .shadow(color: Theme.violet.opacity(0.45), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "current", in: indicatorNamespace)
                        } else {
                            Circle()
                                .fill(item < step ? Theme.ready.opacity(0.9) : Theme.subtleFill)
                        }
                        if item < step {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        } else {
                            Text(verbatim: "\(item.rawValue + 1)")
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundStyle(item == step ? Color.white : Color.secondary)
                        }
                    }
                    .frame(width: 26, height: 26)
                    Text(item.shortTitle)
                        .font(.system(size: 10.5, weight: item == step ? .semibold : .medium))
                        .foregroundStyle(item == step ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
                .frame(width: 74)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(item == step ? .isSelected : [])

                if item != CalibrationStep.allCases.last {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.separator)
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.ready, Theme.teal], startPoint: .leading, endPoint: .trailing))
                            .frame(maxWidth: item < step ? .infinity : 0)
                    }
                    .frame(height: 3)
                    .padding(.bottom, 20)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: step)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertion: Edge = movingForward ? .trailing : .leading
        let removal: Edge = movingForward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: insertion).combined(with: .opacity),
                           removal: .move(edge: removal).combined(with: .opacity))
    }

    // MARK: Inhalte

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .intro: introContent
        case .openHead: openHeadContent
        case .insertMedia: insertMediaContent
        case .closeHead: closeHeadContent
        case .calibrate: calibrateContent
        case .result: resultContent
        }
    }

    private func stepHeading(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Schritt %d von %d", step.rawValue + 1, CalibrationStep.allCases.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .textCase(.uppercase)
            Text(title)
                .font(Theme.Typography.title)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ text: String, systemImage: String, tint: Color = Theme.teal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var introContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(tr("Medien kalibrieren"),
                        tr("Der Drucker misst Etikettenlänge sowie Lücken oder Markierungen und stellt seine Sensoren darauf ein. Nötig nach jedem Rollenwechsel und bei Vorschubproblemen."))
            VStack(alignment: .leading, spacing: 2) {
                KeyValueRow(tr("Etikett"), "\(session.stock.name) · \(session.stock.sizeDescription)")
                KeyValueRow(tr("Erkennung"), tr(tracking.displayName))
                KeyValueRow(tr("Druckverfahren"), tr(mediaType.displayName))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .labelWerkGlass(cornerRadius: 12)
            tip(tr("Dauert etwa eine Minute und verbraucht einige Etiketten."), systemImage: "clock")
            if !calibrateSupported {
                tip(tr("Kalibrieren ist mit %@ nicht verfügbar.", session.saved.language.displayName),
                    systemImage: "nosign", tint: Theme.warning)
            } else {
                Button {
                    go(to: .calibrate)
                } label: {
                    Label(tr("Schritte überspringen und direkt kalibrieren"), systemImage: "forward.fill")
                }
                .buttonStyle(.labelWerkPlain)
            }
        }
    }

    private var openInstruction: String {
        switch session.model?.category ?? .desktop {
        case .desktop, .healthcare:
            return tr("Ziehe die beiden Entriegelungen an den Seiten nach vorne und klappe den Deckel ganz nach oben.")
        case .industrial, .printEngine:
            return tr("Öffne die Medienklappe und drehe den Druckkopfhebel, bis sich der Druckkopf anhebt.")
        case .mobile:
            return tr("Drücke die Entriegelung und öffne die Medienklappe vollständig.")
        }
    }

    private var openHeadContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(tr("Druckkopf öffnen"), openInstruction)
            detectionChip(for: .openHead,
                          waiting: tr("Warte auf geöffneten Druckkopf …"),
                          done: tr("Druckkopf geöffnet erkannt"))
            if let virtual = session.virtualPrinter {
                simulationButton(tr("Deckel öffnen (Simulation)"), systemImage: "arrow.up.circle") {
                    await virtual.setHeadOpen(true)
                }
            }
        }
    }

    private var trackingTip: String {
        switch tracking {
        case .gap:
            return tr("Lückenerkennung: Den beweglichen Sensor mittig unter die Etiketten schieben.")
        case .blackMark:
            return tr("Schwarze Markierung: Den Sensor genau unter die Markierungen auf der Rückseite schieben.")
        case .continuous:
            return tr("Endlosmaterial: Der Sensor erkennt nur, ob Material eingelegt ist – die Position ist unkritisch.")
        case .autoDetect:
            return tr("Automatische Erkennung: Den Sensor mittig ausrichten, der Drucker erkennt die Medienart selbst.")
        case .notch:
            return tr("Seitenkerben: Den Sensor genau unter die Kerben am Etikettenrand schieben.")
        }
    }

    private var insertMediaContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeading(tr("Etiketten einlegen"),
                        tr("Lege die Rolle mit den Etiketten nach oben ein und führe das Material unter den Führungen hindurch bis über die Druckwalze."))
            VStack(alignment: .leading, spacing: 8) {
                tip(trackingTip, systemImage: "dot.radiowaves.left.and.right")
                tip(tr("Führungen an die Rollenbreite anpassen – das Material muss gerade laufen."),
                    systemImage: "arrow.left.and.right")
                if mediaType == .thermalTransfer {
                    tip(tr("Thermotransfer: Farbband prüfen – die beschichtete Seite zeigt zu den Etiketten."),
                        systemImage: "film")
                }
            }
            if session.supportsStatus && session.connectionState.isConnected {
                statusChip(ok: !mediaMissing, okText: tr("Etiketten erkannt"),
                           problemText: tr("Noch keine Etiketten erkannt"))
            }
            if let virtual = session.virtualPrinter, mediaMissing {
                simulationButton(tr("Etiketten einlegen (Simulation)"), systemImage: "square.stack.3d.down.right") {
                    await virtual.setMediaOut(false)
                }
            }
        }
    }

    private var closeHeadContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(tr("Druckkopf schließen"),
                        tr("Klappe den Deckel zu und drücke ihn vorne mittig herunter, bis er auf beiden Seiten hörbar einrastet."))
            detectionChip(for: .closeHead,
                          waiting: tr("Warte auf geschlossenen Druckkopf …"),
                          done: tr("Druckkopf geschlossen erkannt"))
            if let virtual = session.virtualPrinter {
                simulationButton(tr("Deckel schließen (Simulation)"), systemImage: "arrow.down.circle") {
                    await virtual.setHeadOpen(false)
                }
            }
        }
    }

    private var calibrateContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(tr("Kalibrieren"),
                        tr("Der Drucker schiebt jetzt einige Etiketten vor und misst sie. Bitte währenddessen nicht in den Drucker greifen."))
            if !calibrateSupported {
                tip(tr("Kalibrieren ist mit %@ nicht verfügbar.", session.saved.language.displayName),
                    systemImage: "nosign", tint: Theme.warning)
            } else if headIsOpen && runState == .idle {
                statusChip(ok: false, okText: "", problemText: tr("Der Druckkopf ist noch offen – bitte zuerst schließen."))
            }
            VStack(alignment: .leading, spacing: 10) {
                progressRow(.sending, title: tr("Kalibrierbefehl senden"))
                progressRow(.measuring, title: tr("Drucker misst die Etiketten"))
                if session.supportsStatus {
                    progressRow(.verifying, title: tr("Ergebnis prüfen"))
                }
            }
            .padding(14)
            .labelWerkGlass(cornerRadius: 12)
            if isRunning {
                StripedProgressBar(progress: nil, tint: Theme.teal)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: runState)
    }

    private func progressRow(_ stage: CalibrationRunState, title: String) -> some View {
        let done = runState > stage
        let active = runState == stage
        return HStack(spacing: 10) {
            ZStack {
                if active {
                    ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                        .transition(.opacity)
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(done ? Theme.ready : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 20, height: 20)
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundStyle(done || active ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if let outcome {
            VStack(alignment: .leading, spacing: 12) {
                resultHeading(outcome)
                if outcome.commandSent && outcome.verified {
                    if outcome.issues.isEmpty {
                        lengthAnalysis(outcome)
                    } else {
                        issuesList(outcome.issues)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        printTestLabel()
                    } label: {
                        Label(tr("Testetikett drucken"), systemImage: "printer.dotmatrix.filled.and.paper")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(testLabelBusy || session.isBusy)
                    Button {
                        go(to: .calibrate)
                    } label: {
                        Label(tr("Erneut kalibrieren"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                }
                .padding(.top, 4)
            }
        } else {
            stepHeading(tr("Noch kein Ergebnis"), tr("Starte die Kalibrierung im vorherigen Schritt."))
        }
    }

    @ViewBuilder
    private func resultHeading(_ outcome: CalibrationOutcome) -> some View {
        if !outcome.commandSent {
            stepHeading(tr("Kalibrierung nicht gestartet"),
                        outcome.errorMessage ?? tr("Der Kalibrierbefehl konnte nicht gesendet werden."))
        } else if !outcome.verified {
            stepHeading(tr("Kalibrierbefehl gesendet"),
                        tr("Das Ergebnis lässt sich über diese Verbindung nicht abfragen. Drucke ein Testetikett, um Position und Länge zu kontrollieren."))
        } else if outcome.issues.isEmpty {
            stepHeading(tr("Kalibrierung erfolgreich"),
                        tr("Der Drucker hat die Medien vermessen und meldet keine Probleme."))
        } else {
            stepHeading(tr("Kalibrierung mit Hinweisen"),
                        tr("Der Drucker meldet nach der Kalibrierung noch folgende Punkte:"))
        }
    }

    @ViewBuilder
    private func lengthAnalysis(_ outcome: CalibrationOutcome) -> some View {
        if let dots = outcome.measuredLengthDots, dots > 0 {
            let measuredMM = session.resolution.mm(fromDots: dots)
            let expectedMM = session.stock.heightMM
            let deviation = abs(measuredMM - expectedMM) / max(expectedMM, 1)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    KeyValueRow(tr("Etikettenlänge laut Drucker"), tr("%.1f mm (%d Punkte)", measuredMM, dots))
                    KeyValueRow(tr("Eingestelltes Format"), tr("%.1f mm · %@", expectedMM, session.stock.name))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .labelWerkGlass(cornerRadius: 12)
                if session.stock.isContinuous {
                    tip(tr("Endlosmaterial: Die Länge wird durch den Druckauftrag bestimmt."), systemImage: "info.circle")
                } else if deviation <= 0.04 {
                    statusChip(ok: true, okText: tr("Passt zum eingestellten Etikettenformat"), problemText: "")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        statusChip(ok: false, okText: "",
                                   problemText: tr("Weicht um %.0f %% vom eingestellten Format ab", deviation * 100))
                        Button {
                            session.section = .stocks
                            dismiss()
                        } label: {
                            Label(tr("Etikettenformat anpassen …"), systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.labelWerkPlain)
                    }
                }
            }
        }
    }

    private func issuesList(_ issues: [PrinterAlert]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { alert in
                HStack(alignment: .top, spacing: 10) {
                    IconBadge(systemImage: alert.systemImage, tint: alert.severity.color, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(alert.title))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(tr(alert.recovery))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(12)
        .labelWerkGlass(cornerRadius: 12, tint: Theme.warning)
    }

    // MARK: Live-Erkennung & Status

    @ViewBuilder
    private func detectionChip(for target: CalibrationStep, waiting: String, done: String) -> some View {
        if session.supportsStatus && session.connectionState.isConnected {
            let isDone = detectedStep == target
            HStack(spacing: 10) {
                ZStack {
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ready)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        ProgressRing(progress: nil, size: 17, lineWidth: 2.5)
                            .transition(.opacity)
                    }
                }
                .frame(width: 20, height: 20)
                Text(isDone ? done : waiting)
                    .font(.system(size: 12.5, weight: .medium))
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill((isDone ? Theme.ready : Theme.accent).opacity(0.12))
            }
            .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: isDone)
        } else {
            tip(tr("Der Zustand des Druckkopfs kann über diese Verbindung nicht gelesen werden – fahre mit „Weiter“ fort."),
                systemImage: "info.circle")
        }
    }

    private func statusChip(ok: Bool, okText: String, problemText: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .contentTransition(.symbolEffect(.replace))
            Text(ok ? okText : problemText)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ok ? Theme.ready : Theme.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule().fill((ok ? Theme.ready : Theme.warning).opacity(0.12))
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: ok)
    }

    private var liveStatusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                StatusOrb(state: session.state, size: 9)
                Text(session.connectionState.displayName)
                    .contentTransition(.opacity)
            }
            if session.supportsStatus && session.connectionState.isConnected {
                statusChip(ok: !headIsOpen, okText: tr("Druckkopf geschlossen"), problemText: tr("Druckkopf offen"))
                statusChip(ok: !mediaMissing, okText: tr("Etiketten vorhanden"), problemText: tr("Keine Etiketten"))
            } else if !session.supportsStatus {
                Text(tr("Live-Status über diese Verbindung nicht verfügbar"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let updated = session.lastUpdated, session.supportsStatus {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative, options: .repeating,
                                      isActive: session.connectionState.isConnected && !reduceMotion)
                    Text(updated, style: .time)
                        .monospacedDigit()
                }
                .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .labelWerkGlass(cornerRadius: 12)
    }

    // MARK: Fußleiste

    private var footer: some View {
        HStack(spacing: 10) {
            if let previous = step.previous, step != .result, !isRunning {
                Button {
                    go(to: previous)
                } label: {
                    Label(tr("Zurück"), systemImage: "chevron.left")
                }
                .buttonStyle(.labelWerkSecondary)
                .transition(.opacity)
            }
            Spacer()
            primaryButton
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: step)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .intro:
            Button {
                go(to: .openHead)
            } label: {
                Label(tr("Los geht’s"), systemImage: "arrow.right")
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!calibrateSupported)
        case .openHead, .insertMedia, .closeHead:
            Button {
                if let next = step.next { go(to: next) }
            } label: {
                Label(tr("Weiter"), systemImage: "arrow.right")
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
        case .calibrate:
            Button {
                startCalibration()
            } label: {
                Label(isRunning ? tr("Kalibriert …") : tr("Kalibrierung starten"), systemImage: "ruler")
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || !calibrateSupported || (headIsOpen && session.supportsStatus))
        case .result:
            Button {
                dismiss()
            } label: {
                Label(tr("Fertig"), systemImage: "checkmark")
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Ablauf

    private func go(to target: CalibrationStep) {
        guard target != step else { return }
        movingForward = target > step
        detectedStep = nil
        if target == .calibrate {
            runState = .idle
        }
        // Richtung zuerst rendern, damit die Übergänge der alten Ansicht stimmen.
        Task { @MainActor in
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                step = target
            }
        }
    }

    /// Beobachtet den Druckerzustand auf den Handgriff-Schritten und geht bei Erkennung automatisch weiter.
    private func observe(_ current: CalibrationStep) async {
        guard session.supportsStatus else { return }
        guard current == .openHead || current == .insertMedia || current == .closeHead else { return }
        while !Task.isCancelled {
            await session.refreshStatus()
            guard !Task.isCancelled, step == current else { return }
            let reached = (current == .openHead && headIsOpen) || (current == .closeHead && !headIsOpen)
            if reached && session.connectionState.isConnected {
                withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
                    detectedStep = current
                }
                guard movingForward else { return }
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled, step == current, let next = current.next else { return }
                go(to: next)
                return
            }
            try? await Task.sleep(for: .seconds(1.2))
        }
    }

    private func simulationButton(_ title: String, systemImage: String,
                                  perform: @escaping () async -> Void) -> some View {
        Button {
            guard !simulationBusy else { return }
            simulationBusy = true
            Task {
                await perform()
                await session.refreshStatus()
                simulationBusy = false
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.labelWerkSecondary)
        .controlSize(.small)
        .disabled(simulationBusy)
        .help(tr("Nur beim Demo-Drucker: simuliert den Handgriff am Gerät."))
    }

    private func startCalibration() {
        guard !isRunning, calibrateSupported else { return }
        outcome = nil
        calibrationTask?.cancel()
        calibrationTask = Task { await runCalibration() }
    }

    private func setRunState(_ state: CalibrationRunState) {
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            runState = state
        }
    }

    /// Mindestwartezeit nach `~JC`, bevor ein `~HS`-Ergebnis als Messergebnis gilt.
    private static let minimumMeasuringTime: TimeInterval = 6
    /// Meldet der Drucker dieselbe Länge wie vorher, ist das Ende der Messung nicht erkennbar –
    /// dann länger beobachten, damit späte Meldungen (Papierende, Kalibrierfehler) erfasst werden.
    private static let unchangedSettleTime: TimeInterval = 10
    /// Spätestens nach dieser Zeit wird das zuletzt gelesene Ergebnis ausgewertet.
    private static let maximumMeasuringTime: TimeInterval = 20

    private func runCalibration() async {
        setRunState(.sending)
        let lengthBefore = session.status?.hostStatus?.labelLengthDots
        let sentAt = Date()
        // Während des Messens meldet der Drucker kurzzeitig z. B. „Etiketten leer“ – keine Alarme.
        session.muteAlertNotifications(for: Self.maximumMeasuringTime + 15)
        let sent = await session.perform(.calibrate)
        guard !Task.isCancelled else { return }
        guard sent else {
            finish(CalibrationOutcome(commandSent: false, verified: false, issues: [],
                                      measuredLengthDots: nil, errorMessage: session.lastError))
            return
        }
        setRunState(.measuring)
        guard session.supportsStatus else {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            finish(CalibrationOutcome(commandSent: true, verified: false, issues: [],
                                      measuredLengthDots: nil, errorMessage: nil))
            return
        }
        // Der Drucker schiebt jetzt mehrere Etiketten vor und misst sie (je nach Gerät 5–15 s). `~JC`
        // füllt weder Auftrags- noch Empfangspuffer, der Zustand „druckt“ zeigt das Ende also nicht an.
        // Daher: frühestens nach der Mindestzeit auswerten und erst, wenn zwei aufeinanderfolgende
        // frische Antworten übereinstimmen. Eine geänderte Länge belegt die neue Messung, bei
        // unveränderter Länge wird länger beobachtet.
        var previousLength: Int?
        var stableReads = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let elapsed = Date().timeIntervalSince(sentAt)
            if runState == .measuring && elapsed >= Self.minimumMeasuringTime {
                setRunState(.verifying)
            }
            await session.refreshStatus()
            guard !Task.isCancelled else { return }
            let fresh = (session.lastUpdated ?? .distantPast) > sentAt
            let length = session.status?.hostStatus?.labelLengthDots
            if fresh, session.state != .printing, let length {
                stableReads = length == previousLength ? stableReads + 1 : 1
                previousLength = length
            } else {
                stableReads = 0
                previousLength = nil
            }
            let lengthChanged = previousLength != nil && previousLength != lengthBefore
            let settleTime = lengthChanged ? Self.minimumMeasuringTime : Self.unchangedSettleTime
            if elapsed >= settleTime && stableReads >= 2 { break }
            if elapsed >= Self.maximumMeasuringTime { break }
        }
        guard !Task.isCancelled else { return }
        // Nur eine nach dem Befehl gelesene Antwort bei weiterhin bestehender Verbindung zählt als Ergebnis.
        let verified = (session.lastUpdated ?? .distantPast) > sentAt && session.connectionState.isConnected
        let issues = verified ? session.alerts.filter { $0.severity >= .warning } : []
        finish(CalibrationOutcome(commandSent: true, verified: verified, issues: issues,
                                  measuredLengthDots: verified ? session.status?.hostStatus?.labelLengthDots : nil,
                                  errorMessage: nil))
    }

    private func finish(_ result: CalibrationOutcome) {
        setRunState(.finished)
        outcome = result
        go(to: .result)
        if result.succeeded && result.verified && !reduceMotion {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                celebration += 1
            }
        }
    }

    private func printTestLabel() {
        testLabelBusy = true
        Task {
            await session.perform(.printTestLabel)
            testLabelBusy = false
        }
    }
}

// MARK: - Illustration

/// Seitenansicht eines Desktop-Druckers: Deckel klappt auf, Rolle fällt ein, Etikettenbahn läuft
/// zur Druckwalze, beim Kalibrieren leuchtet der Sensor und Etiketten laufen heraus.
private struct CalibrationIllustration: View {
    let step: CalibrationStep
    let calibrating: Bool
    let outcomeOK: Bool?
    let accent: Color
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var lidOpen: Bool { step == .openHead || step == .insertMedia }
    private var mediaLoaded: Bool { step >= .insertMedia }
    private var dark: Bool { colorScheme == .dark }

    private var ledColor: Color {
        if calibrating { return Theme.teal }
        if let outcomeOK { return outcomeOK ? Theme.ready : Theme.warning }
        return lidOpen ? Theme.warning : Theme.ready
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(Color.black.opacity(dark ? 0.4 : 0.16))
                .frame(width: 220, height: 14)
                .blur(radius: 7)
                .offset(x: 50, y: 206)

            roll
                .offset(x: 72, y: mediaLoaded ? 130 : 56)
                .opacity(mediaLoaded ? 1 : 0)

            base
                .offset(x: 50, y: 160)

            CalibrationLabelWeb(progress: mediaLoaded ? 1 : 0)
                .frame(width: 134, height: 6)
                .offset(x: 126, y: 155)

            if calibrating && !reduceMotion {
                CalibrationFeed()
                    .offset(x: 252, y: 154)
                    .transition(.opacity)
            }

            lid
                .frame(width: 200, height: 52)
                .rotationEffect(.degrees(lidOpen ? -36 : 0), anchor: .bottomLeading)
                .offset(x: 50, y: 110)

            if lidOpen || calibrating {
                sensor
                    .offset(x: 186, y: 140)
                    .transition(.opacity)
            }

            hint
            resultBadge
        }
        .frame(width: 320, height: 240, alignment: .topLeading)
        .animation(reduceMotion ? nil : .spring(response: 0.75, dampingFraction: 0.72), value: step)
        .animation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion), value: calibrating)
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: outcomeOK)
        .accessibilityElement()
        .accessibilityLabel(tr("Darstellung des Druckers: %@", step.shortTitle))
    }

    // MARK: Teile

    private var roll: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Theme.labelPaper, Color(white: 0.84)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            ForEach(1..<4, id: \.self) { ring in
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .padding(CGFloat(ring) * 6)
            }
            Circle()
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
            Circle()
                .fill(Color(white: 0.55))
                .frame(width: 20, height: 20)
            Circle()
                .fill(Color(white: 0.28))
                .frame(width: 8, height: 8)
        }
        .frame(width: 56, height: 56)
        .modifier(CalibrationSpin(active: calibrating && !reduceMotion))
    }

    private var base: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14,
                                           bottomTrailingRadius: 14, topTrailingRadius: 6, style: .continuous)
        return shape
            .fill(LinearGradient(colors: dark ? [Color(white: 0.28), Color(white: 0.12)]
                                              : [Color(white: 0.36), Color(white: 0.16)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(ledColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: ledColor, radius: 3)
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 16, height: 4)
                }
                .padding(10)
            }
            .frame(width: 200, height: 52)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    private var lid: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 3,
                                           bottomTrailingRadius: 3, topTrailingRadius: 34, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            shape
                .fill(LinearGradient(colors: dark ? [Color(white: 0.36), Color(white: 0.18)]
                                                  : [Color(white: 0.46), Color(white: 0.22)],
                                     startPoint: .top, endPoint: .bottom))
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(0.24), .clear],
                                     startPoint: .top, endPoint: .center))
            Capsule()
                .fill(LinearGradient(colors: [accent.opacity(0), accent, accent.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 150, height: 2)
                .shadow(color: accent.opacity(0.7), radius: 4)
                .padding(.bottom, 12)
                .padding(.trailing, 25)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(white: 0.08))
                .frame(width: 30, height: 6)
                .padding(.trailing, 22)
                .offset(y: 3)
        }
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var sensor: some View {
        ZStack {
            Capsule()
                .fill(calibrating ? Theme.teal : Color(white: 0.55))
                .frame(width: 12, height: 5)
                .shadow(color: calibrating ? Theme.teal : Color.clear, radius: 5)
                .offset(y: 16)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.teal)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: calibrating && !reduceMotion)
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var hint: some View {
        switch step {
        case .openHead:
            hintArrow("arrow.up")
                .offset(x: 238, y: 58)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        case .insertMedia:
            hintArrow("arrow.down")
                .offset(x: 86, y: 92)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        case .closeHead:
            hintArrow("arrow.down")
                .offset(x: 214, y: 66)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        case .intro, .calibrate, .result:
            EmptyView()
        }
    }

    private func hintArrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background {
                Circle()
                    .fill(Theme.brandGradient)
                    .shadow(color: Theme.violet.opacity(0.5), radius: 6, y: 2)
            }
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
    }

    @ViewBuilder
    private var resultBadge: some View {
        if let outcomeOK {
            ZStack {
                Circle()
                    .fill((outcomeOK ? Theme.ready : Theme.warning).gradient)
                    .shadow(color: (outcomeOK ? Theme.ready : Theme.warning).opacity(0.5), radius: 10, y: 3)
                Image(systemName: outcomeOK ? "checkmark" : "exclamationmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .offset(x: 256, y: 30)
            .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
    }
}

/// Etikettenbahn (Trägerband mit Etiketten), wird über `progress` von der Rolle zur Walze gezogen.
private struct CalibrationLabelWeb: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.9))
                HStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Theme.labelPaper)
                            .overlay {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                            }
                            .frame(width: 20)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(width: width, height: height, alignment: .leading)
            .mask(alignment: .leading) {
                Rectangle()
                    .frame(width: width * progress, height: height)
            }
        }
    }
}

/// Aus dem Drucker laufende Etiketten (Endlosschleife, nur solange sichtbar).
private struct CalibrationFeed: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.labelPaper)
                    .frame(width: 22, height: 7)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
        }
        .phaseAnimator([0.0, 1.0]) { content, phase in
            content.offset(x: -26 + 26 * phase)
        } animation: { phase in
            phase == 1.0 ? .linear(duration: 0.5) : nil
        }
        .frame(width: 46, height: 9, alignment: .leading)
        .clipped()
    }
}

/// Dreht die Rolle, solange kalibriert wird.
private struct CalibrationSpin: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .phaseAnimator([0.0, 360.0]) { view, angle in
                    view.rotationEffect(.degrees(angle))
                } animation: { angle in
                    angle == 360.0 ? .linear(duration: 0.9) : nil
                }
        } else {
            content
        }
    }
}

import AppKit
import SwiftUI
import LabelWerkKit

/// Werkzeuge eines Druckers – ersetzt „Open Printer Tools“ der Zebra Setup Utilities:
/// alle Gerätebefehle als animierte Karten, Kalibrier-Assistent, Konfiguration (`^HH`/`UQ`/SGD),
/// Einstellungs-Explorer (SGD) und Testseite über den macOS-Treiberpfad.
struct ToolsView: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var activeSheet: ToolsSheetKind?
    @State private var appeared = false
    @State private var unsupported: Set<PrinterAction> = []

    private let groups = ToolsActionGroup.makeAll()

    init(session: PrinterSession) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                ToolsHeroCard(session: session, unsupportedCount: unsupported.count, reduceMotion: reduceMotion)

                if !session.supportsStatus {
                    ToolsNotice(
                        title: tr("Verbindung kann nur senden"),
                        message: tr("Befehle werden übertragen, aber der Drucker kann über diese Verbindung nicht antworten. Konfiguration, Einstellungs-Explorer und Ergebnisprüfung sind daher nicht verfügbar."),
                        systemImage: "paperplane",
                        tint: Theme.warning
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                    groupSection(group, startIndex: startIndex(ofGroup: groupIndex))
                }

                diagnosticsSection
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $activeSheet) { kind in
            sheet(for: kind)
        }
        .onAppear {
            updateSupport()
            if !appeared { appeared = true }
        }
        .onChange(of: session.saved.language) { _, _ in
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { updateSupport() }
        }
        .onChange(of: session.saved.stockID) { _, _ in updateSupport() }
    }

    // MARK: Gerätebefehle

    private func startIndex(ofGroup index: Int) -> Int {
        groups.prefix(index).reduce(0) { $0 + $1.actions.count }
    }

    private func groupSection(_ group: ToolsActionGroup, startIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(group.title, subtitle: group.subtitle, systemImage: group.systemImage) {
                let available = group.actions.filter { !unsupported.contains($0) }.count
                Text(tr("%d von %d verfügbar", available, group.actions.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Metrics.cardSpacing)],
                      alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                ForEach(Array(group.actions.enumerated()), id: \.element) { offset, action in
                    ToolsActionCard(action: action, session: session, tint: group.tint,
                                    isSupported: !unsupported.contains(action),
                                    appearanceIndex: startIndex + offset, appeared: appeared)
                }
            }
        }
    }

    /// Ermittelt, welche Befehle für die eingestellte Druckersprache keine Daten liefern.
    private func updateSupport() {
        let language = session.saved.language
        let resolution = session.resolution
        let width = session.labelWidthDots
        let height = session.labelHeightDots
        var result: Set<PrinterAction> = []
        for action in PrinterAction.allCases
        where action.payload(language: language, resolution: resolution, widthDots: width, heightDots: height) == nil {
            result.insert(action)
        }
        unsupported = result
    }

    // MARK: Diagnose & Konfiguration

    /// Der Explorer schreibt direkt in die Geräteeinstellungen und gehört deshalb – wie in den
    /// App-Einstellungen beschrieben – zum Entwicklermodus.
    private var explorerAvailable: Bool { model.preferences.developerMode }

    /// Modell bekannt und ohne SGD (ältere Nicht-Link-OS-Drucker).
    private var modelLacksSGD: Bool { session.model.map { !$0.supports(.sgd) } ?? false }

    /// Wie `PrinterClient.configuration()`: `^HH` bei ZPL, `UQ` bei EPL, alle SGD-Einstellungen bei
    /// CPCL – Letzteres nur, wenn das Modell SGD versteht (unbekanntes Modell: versuchen).
    private var configurationLanguageSupported: Bool {
        switch session.saved.language {
        case .zpl, .epl: return true
        case .cpcl: return session.model?.supports(.sgd) ?? true
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(tr("Diagnose & Konfiguration"),
                          subtitle: tr("Geführte Kalibrierung, Druckerkonfiguration und sämtliche Einstellungen"),
                          systemImage: "stethoscope")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: Theme.Metrics.cardSpacing)],
                      alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                calibrationCard
                configurationCard
                explorerCard
                ToolsMacTestPageCard(session: session)
            }
        }
    }

    private var calibrationCard: some View {
        let supported = !unsupported.contains(.calibrate)
        return ToolsFeatureCard(
            title: tr("Kalibrier-Assistent"),
            message: tr("Schritt für Schritt: Druckkopf öffnen, Etiketten einlegen, schließen und kalibrieren – mit Live-Erkennung und Prüfung des Ergebnisses."),
            systemImage: "ruler",
            tint: Theme.teal,
            highlights: [
                tr("Erkennt geöffneten und geschlossenen Druckkopf"),
                tr("Vergleicht die gemessene Etikettenlänge mit dem Format"),
                tr("Konkrete Lösungen bei Problemen"),
            ]
        ) {
            Button {
                activeSheet = .calibration
            } label: {
                Label(tr("Assistent starten"), systemImage: "play.fill")
            }
            .buttonStyle(.labelWerkPrimary)
            .disabled(!supported)
            if !supported {
                Text(tr("Mit %@ nicht verfügbar", session.saved.language.displayName))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var configurationCard: some View {
        ToolsFeatureCard(
            title: tr("Konfiguration"),
            message: tr("Liest die vollständige Druckerkonfiguration (wie das Konfigurationsetikett) direkt in LabelWerk – durchsuchbar, kopierbar und als Text exportierbar."),
            systemImage: "list.bullet.rectangle.portrait",
            tint: Theme.printing,
            highlights: [
                tr("Ohne Etikettenverbrauch"),
                tr("Suche mit Hervorhebung"),
                tr("Export als Textdatei"),
            ]
        ) {
            Button {
                activeSheet = .configuration
            } label: {
                Label(tr("Konfiguration lesen"), systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.labelWerkPrimary)
            .disabled(!session.supportsStatus || !configurationLanguageSupported)
            if !session.supportsStatus {
                Text(tr("Nicht über diese Verbindung"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else if !configurationLanguageSupported {
                Text(tr("Mit %@ nicht verfügbar", session.saved.language.displayName))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var explorerCard: some View {
        ToolsFeatureCard(
            title: tr("Einstellungs-Explorer"),
            message: tr("Alle Set-Get-Do-Variablen des Druckers in einer sortierbaren Tabelle – nach Bereichen gruppiert, mit Validierung direkt bearbeitbar und als JSON exportierbar."),
            systemImage: "tablecells",
            tint: Theme.violet,
            highlights: [
                tr("Gruppiert nach device., media., print., ip., wlan. …"),
                tr("Bearbeiten mit Prüfung von Bereich und Auswahlwerten"),
                tr("JSON-Export"),
            ]
        ) {
            if !session.supportsStatus {
                Text(tr("Über diese Verbindung können keine Einstellungen gelesen werden."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if explorerAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        activeSheet = .explorer
                    } label: {
                        Label(tr("Explorer öffnen"), systemImage: "tablecells")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    if modelLacksSGD {
                        Text(tr("%@ meldet keine SGD-Unterstützung – eventuell liefert der Drucker keine Werte.",
                                session.model?.displayName ?? session.displayName))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(modelLacksSGD
                         ? tr("%@ unterstützt keine SGD-Befehle. Im Entwicklermodus lässt sich der Explorer trotzdem öffnen.",
                              session.model?.displayName ?? session.displayName)
                         : tr("Der Explorer ändert Geräteeinstellungen direkt und ist deshalb Teil des Entwicklermodus."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            model.preferences.developerMode = true
                        }
                    } label: {
                        Label(tr("Entwicklermodus aktivieren"), systemImage: "ladybug")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Blätter

    @ViewBuilder
    private func sheet(for kind: ToolsSheetKind) -> some View {
        switch kind {
        case .calibration:
            ToolsCalibrationWizard(session: session)
                .environment(model)
        case .configuration:
            ToolsConfigurationSheet(session: session)
                .environment(model)
        case .explorer:
            ToolsSettingsExplorer(session: session)
                .environment(model)
        }
    }
}

// MARK: - Blattarten

private enum ToolsSheetKind: String, Identifiable {
    case calibration
    case configuration
    case explorer

    var id: String { rawValue }
}

// MARK: - Kopfbereich

private struct ToolsHeroCard: View {
    let session: PrinterSession
    let unsupportedCount: Int
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    private var lastJob: JobRecord? {
        model.history.first { job in
            job.printerID == session.id && (job.kind == .action || job.kind == .testLabel)
        }
    }

    var body: some View {
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: session.accentColor) {
            HStack(alignment: .center, spacing: 18) {
                IconBadge(systemImage: "wrench.and.screwdriver.fill", tint: session.accentColor, size: 58)
                    .symbolEffect(.bounce, value: reduceMotion ? nil : lastJob?.id)

                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("Druckerwerkzeuge"))
                        .font(Theme.Typography.title)
                    Text(tr("Alle Gerätebefehle für %@ – mit Live-Rückmeldung, geführter Kalibrierung und vollem Zugriff auf die Einstellungen.",
                            session.displayName))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        StatusPill(state: session.state)
                        ToolsChip(text: session.saved.language.displayName,
                                  systemImage: "chevron.left.forwardslash.chevron.right", tint: Theme.violet)
                        ToolsChip(text: session.saved.descriptor.displayString,
                                  systemImage: session.saved.descriptor.systemImage, tint: Theme.teal)
                        if unsupportedCount > 0 {
                            ToolsChip(text: tr("%d Befehle nicht verfügbar", unsupportedCount),
                                      systemImage: "nosign", tint: Theme.offline)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                }

                Spacer(minLength: 12)

                if let job = lastJob {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(tr("Zuletzt ausgeführt"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 6) {
                            Image(systemName: job.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(job.success ? Theme.ready : Theme.error)
                                .contentTransition(.symbolEffect(.replace))
                            Text(job.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                        Text(job.date, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 220, alignment: .trailing)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: lastJob?.id)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: unsupportedCount)
        }
    }
}

// MARK: - Funktionskarte

private struct ToolsFeatureCard<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let highlights: [String]
    let actions: Actions

    init(title: String, message: String, systemImage: String, tint: Color, highlights: [String],
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.highlights = highlights
        self.actions = actions()
    }

    var body: some View {
        GlassCard(padding: 16, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    IconBadge(systemImage: systemImage, tint: tint, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(Theme.Typography.headline)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if !highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(highlights, id: \.self) { highlight in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(tint)
                                Text(highlight)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    actions
                }
            }
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        }
        .cardHoverEffect()
    }
}

// MARK: - Testseite über macOS

/// Druckt eine Testseite über die macOS-Warteschlange (CUPS → LabelWerk-Filter → Drucker) und
/// prüft so den kompletten Treiberpfad – wie „Testseite drucken“ im Windows-Treiber.
private struct ToolsMacTestPageCard: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var phase: ToolsRunPhase = .idle
    @State private var shakeCount = 0
    @State private var successCount = 0

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var buttonSymbol: String {
        switch phase {
        case .idle, .running: return "printer"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private var buttonTitle: String {
        switch phase {
        case .idle: return tr("Testseite drucken")
        case .running: return tr("Wird gesendet …")
        case .succeeded: return tr("Gesendet")
        case .failed: return tr("Fehlgeschlagen")
        }
    }

    var body: some View {
        if let queue = session.saved.cupsQueueName {
            ToolsFeatureCard(
                title: tr("Testseite über macOS drucken"),
                message: tr("Druckt über die macOS-Warteschlange „%@“ und prüft damit den kompletten Treiberpfad: CUPS, LabelWerk-Filter und Verbindung.",
                            queue),
                systemImage: "macwindow",
                tint: Theme.printing,
                highlights: [
                    tr("Genau wie aus jedem Mac-Programm gedruckt"),
                    tr("Wird im Auftragsverlauf protokolliert"),
                ]
            ) {
                Button {
                    run(queue: queue)
                } label: {
                    Label(buttonTitle, systemImage: buttonSymbol)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(phase == .running)
                .symbolEffect(.bounce, value: successCount)
                if phase == .running {
                    ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .modifier(ToolsShakeEffect(trigger: shakeCount))
        } else {
            ToolsFeatureCard(
                title: tr("macOS-Warteschlange"),
                message: tr("Für diesen Drucker ist noch keine macOS-Warteschlange eingerichtet. Damit druckst du aus jedem Programm – wie mit dem Windows-Treiber – und kannst hier den Treiberpfad testen."),
                systemImage: "macwindow.badge.plus",
                tint: Theme.printing,
                highlights: [
                    tr("Druckerwarteschlange mit LabelWerk-Treiber"),
                    tr("Standardwerte aus den Druckeinstellungen"),
                ]
            ) {
                Button {
                    model.selection = .driver
                } label: {
                    Label(tr("Warteschlange einrichten …"), systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.labelWerkSecondary)
            }
        }
    }

    private func run(queue: String) {
        guard phase != .running else { return }
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { phase = .running }
        Task {
            var failure: String?
            do {
                try await CUPSService.printTestPage(queue: queue)
            } catch {
                failure = PrinterSession.describe(error)
            }
            let ok = failure == nil
            model.record(JobRecord(printerID: session.id, printerName: session.displayName,
                                   title: tr("macOS-Testseite"), kind: .testLabel,
                                   labels: ok ? 1 : 0, bytes: 0, success: ok, message: failure,
                                   previewPNG: nil, payload: nil))
            if ok {
                model.toast(tr("Testseite gesendet"), message: tr("Über die Warteschlange „%@“.", queue), style: .success)
            } else {
                model.toast(tr("Testseite fehlgeschlagen"), message: failure, style: .error)
            }
            withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
                phase = ok ? .succeeded : .failed
            }
            if !reduceMotion {
                if ok {
                    successCount += 1
                } else {
                    withAnimation(.linear(duration: 0.45)) { shakeCount += 1 }
                }
            }
            try? await Task.sleep(for: .seconds(ok ? 2.4 : 3.6))
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { phase = .idle }
        }
    }
}

import SwiftUI
import LabelWerkKit

/// Übersicht eines Druckers: animierter Drucker, Zustand, Meldungen mit Lösungen, Kennzahlen,
/// Geräteinformationen, Statusverlauf, letzte Aufträge und (beim Demo-Drucker) Simulation.
struct DashboardView: View {
    @Bindable var session: PrinterSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    /// „Keine Meldungen“ nur mit einem gültigen Status, der wirklich „bereit“ bzw. „druckt“ meldet –
    /// nicht ohne Status (erste Abfragen fehlgeschlagen) oder mit unbekanntem Zustand.
    private var isAllGood: Bool {
        guard session.connectionState.isConnected, session.supportsStatus,
              let state = session.status?.state else { return false }
        return state == .ready || state == .printing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                HeroCard(session: session)

                if !session.alerts.isEmpty {
                    AlertsSection(session: session)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if isAllGood {
                    AllGoodBanner()
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

                MetricsSection(session: session)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
                        DeviceCard(session: session)
                        VStack(spacing: Theme.Metrics.cardSpacing) {
                            MediaCard(session: session)
                            ConnectionCard(session: session)
                        }
                    }
                    VStack(spacing: Theme.Metrics.cardSpacing) {
                        DeviceCard(session: session)
                        MediaCard(session: session)
                        ConnectionCard(session: session)
                    }
                }

                if session.supportsStatus && session.statusHistory.count > 1 {
                    StatusTimelineCard(samples: session.statusHistory)
                }

                if session.isVirtual {
                    SimulationCard(session: session)
                }

                RecentJobsCard(session: session)
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: session.alerts.map(\.kind))
        }
    }
}

// MARK: - Hero

private struct HeroCard: View {
    @Bindable var session: PrinterSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var labelAspect: CGFloat {
        let stock = session.stock
        return CGFloat(stock.heightMM / max(stock.widthMM, 1))
    }

    var body: some View {
        GlassCard(padding: 22, cornerRadius: Theme.Metrics.cornerLarge, tint: session.state.color) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    PrinterIllustration(
                        state: session.state,
                        isPrinting: session.state == .printing,
                        accent: session.accentColor,
                        category: session.model?.category ?? .desktop,
                        labelAspect: labelAspect,
                        printTrigger: session.labelsPrintedThisSession
                    )
                    CelebrationBurst(trigger: session.labelsPrintedThisSession,
                                     colors: [session.accentColor, Theme.teal, Theme.magenta])
                }
                .frame(width: 230, height: 250)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: session.state.systemImage)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(session.state.color)
                                .symbolEffect(.bounce, value: session.state)
                                .contentTransition(.symbolEffect(.replace))
                            Text(headline)
                                .font(Theme.Typography.hero)
                                .contentTransition(.opacity)
                        }
                        Text(subline)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }

                    HStack(spacing: 10) {
                        Label(session.stock.name, systemImage: "square.stack.3d.up")
                        Text("·").foregroundStyle(.tertiary)
                        Text(session.stock.sizeDescription)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    actions

                    if let updated = session.lastUpdated, session.supportsStatus {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .symbolEffect(.variableColor.iterative, options: .repeating,
                                              isActive: session.connectionState.isConnected && !reduceMotion)
                            Text(tr("Aktualisiert"))
                            Text(updated, style: .relative)
                            Text(tr("her"))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var headline: String {
        switch session.connectionState {
        case .connecting: return tr("Verbinde …")
        case .failed: return tr("Nicht erreichbar")
        case .disconnected: return tr("Getrennt")
        case .connected: return session.state.displayName
        }
    }

    private var subline: String {
        if let activity = session.activity { return activity }
        switch session.connectionState {
        case .failed(let message): return message
        case .disconnected: return tr("Verbinde LabelWerk mit dem Drucker, um Status und Werkzeuge zu nutzen.")
        case .connecting: return tr("Verbindung zu %@ wird aufgebaut.", session.saved.descriptor.displayString)
        case .connected:
            if !session.supportsStatus {
                return tr("Diese Verbindung sendet nur Druckdaten – Live-Status ist nicht verfügbar.")
            }
            if let alert = session.alerts.first { return tr(alert.recovery) }
            switch session.state {
            case .printing:
                let remaining = session.status?.hostStatus?.labelsRemainingInBatch ?? 0
                return remaining > 0 ? tr("Noch %d Etiketten im Auftrag.", remaining) : tr("Auftrag wird gedruckt.")
            case .paused: return tr("Der Drucker ist pausiert. Fortsetzen, um weiterzudrucken.")
            default: return tr("Bereit zum Drucken. Alles läuft rund.")
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if session.connectionState.isConnected {
            HStack(spacing: 8) {
                Button {
                    Task { await session.printTestLabel() }
                } label: {
                    Label(tr("Testetikett"), systemImage: "printer.dotmatrix.filled.and.paper")
                }
                .buttonStyle(.labelWerkPrimary)
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button {
                    Task { await session.perform(.feedLabel) }
                } label: {
                    Label(tr("Vorschub"), systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.labelWerkSecondary)

                Button {
                    Task { await session.perform(.calibrate) }
                } label: {
                    Label(tr("Kalibrieren"), systemImage: "ruler")
                }
                .buttonStyle(.labelWerkSecondary)

                // Nicht `state == .paused`: Ein Fehler (z. B. Druckkopf offen) hat als Zustand Vorrang.
                if session.isPaused {
                    Button {
                        Task { await session.perform(.resume) }
                    } label: {
                        Label(tr("Fortsetzen"), systemImage: "play.fill")
                    }
                    .buttonStyle(.labelWerkSecondary)
                } else {
                    Button {
                        Task { await session.perform(.pause) }
                    } label: {
                        Label(tr("Pause"), systemImage: "pause.fill")
                    }
                    .buttonStyle(.labelWerkSecondary)
                }
            }
            .disabled(session.isBusy)
        } else {
            HStack(spacing: 8) {
                Button {
                    Task { await session.connect() }
                } label: {
                    Label(session.connectionState == .connecting ? tr("Verbinde …") : tr("Verbinden"),
                          systemImage: "bolt.fill")
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(session.connectionState == .connecting)

                Button {
                    session.section = .preferences
                } label: {
                    Label(tr("Einstellungen"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.labelWerkSecondary)
            }
        }
    }
}

// MARK: - Meldungen

private struct AlertsSection: View {
    let session: PrinterSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(tr("Meldungen"), subtitle: tr("Was der Drucker gerade meldet – und was zu tun ist"),
                          systemImage: "exclamationmark.bubble") {
                Button {
                    Task { await session.refreshStatus() }
                } label: {
                    Label(tr("Erneut prüfen"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
            }
            ForEach(session.alerts) { alert in
                AlertCard(alert: alert, session: session)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.95))))
            }
        }
    }
}

private struct AlertCard: View {
    let alert: PrinterAlert
    let session: PrinterSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var appeared = false
    @State private var confirmCancelAll = false

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        GlassCard(padding: 14, tint: alert.severity.color) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: alert.systemImage, tint: alert.severity.color, size: 38)
                    .symbolEffect(.pulse, options: .repeating, isActive: alert.severity == .error && !reduceMotion)
                    .scaleEffect(appeared ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(alert.title))
                        .font(.system(size: 14, weight: .semibold))
                    Text(tr(alert.recovery))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                quickFix
            }
        }
        .onAppear {
            withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) { appeared = true }
        }
    }

    @ViewBuilder
    private var quickFix: some View {
        switch alert.kind {
        case .paused:
            Button(tr("Fortsetzen")) { Task { await session.perform(.resume) } }
                .buttonStyle(.labelWerkPrimary).controlSize(.small)
        case .needsCalibration, .blackMarkNotFound, .paperFeedError:
            Button(tr("Kalibrieren")) { Task { await session.perform(.calibrate) } }
                .buttonStyle(.labelWerkPrimary).controlSize(.small)
        case .offline:
            Button(tr("Neu verbinden")) { Task { await session.reconnect() } }
                .buttonStyle(.labelWerkPrimary).controlSize(.small)
        case .receiveBufferFull:
            // ~JA löscht alle Aufträge im Drucker – wie unter „Werkzeuge“ nur nach Rückfrage.
            Button(tr("Aufträge abbrechen")) {
                if model.preferences.confirmDestructiveActions {
                    confirmCancelAll = true
                } else {
                    Task { await session.perform(.cancelAll) }
                }
            }
            .buttonStyle(.labelWerkSecondary).controlSize(.small)
            .confirmationDialog(tr("Alle Aufträge abbrechen?"), isPresented: $confirmCancelAll) {
                Button(tr(PrinterAction.cancelAll.displayName), role: .destructive) {
                    Task { await session.perform(.cancelAll) }
                }
                Button(tr("Abbrechen"), role: .cancel) {}
            } message: {
                Text(tr(PrinterAction.cancelAll.detail))
            }
        default:
            EmptyView()
        }
    }
}

private struct AllGoodBanner: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var drawn = false

    var body: some View {
        GlassCard(padding: 12, tint: Theme.ready) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.ready.opacity(0.15)).frame(width: 30, height: 30)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.ready)
                        .scaleEffect(drawn ? 1 : 0.2)
                        .opacity(drawn ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Keine Meldungen"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(tr("Druckkopf geschlossen, Medien eingelegt, keine Fehler."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .onAppear {
            withAnimation(Motion.animation(Motion.bouncy.delay(0.1), reduceMotion: systemReduceMotion || appReduceMotion)) {
                drawn = true
            }
        }
    }
}

// MARK: - Kennzahlen

private struct MetricsSection: View {
    let session: PrinterSession

    var body: some View {
        let status = session.status
        let printedTrend = session.statusHistory.compactMap { $0.labelsPrinted.map(Double.init) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Metrics.cardSpacing)],
                  spacing: Theme.Metrics.cardSpacing) {
            MetricTile(title: tr("In dieser Sitzung"), value: session.labelsPrintedThisSession.formatted(),
                       unit: tr("Etiketten"), systemImage: "sparkles", tint: session.accentColor)
            if let total = status?.labelsPrinted {
                MetricTile(title: tr("Etiketten gesamt"), value: total.formatted(), systemImage: "square.stack.3d.up.fill",
                           tint: Theme.violet, trend: printedTrend.count > 2 ? printedTrend : nil)
            }
            if let meters = status?.odometerMeters {
                MetricTile(title: tr("Laufleistung"),
                           value: meters >= 1000 ? (meters / 1000).formatted(.number.precision(.fractionLength(2)))
                                                 : meters.formatted(.number.precision(.fractionLength(1))),
                           unit: meters >= 1000 ? "km" : "m", systemImage: "road.lanes", tint: Theme.teal)
            }
            if let battery = status?.batteryPercent {
                MetricTile(title: tr("Akku"), value: "\(battery)", unit: "%",
                           systemImage: battery > 20 ? "battery.75percent" : "battery.25percent",
                           tint: battery > 20 ? Theme.ready : Theme.error)
            }
            if let temperature = status?.headTemperatureC {
                MetricTile(title: tr("Druckkopf"), value: temperature.formatted(.number.precision(.fractionLength(0))),
                           unit: "°C", systemImage: "thermometer.medium", tint: Theme.warning)
            }
            GaugeTile(title: tr("Schwärzung"),
                      value: session.saved.settings.darkness.map { Double($0) / 30 },
                      text: session.saved.settings.darkness.map { "\($0)" } ?? tr("Drucker"),
                      symbol: "circle.lefthalf.filled")
            GaugeTile(title: tr("Geschwindigkeit"),
                      value: session.saved.settings.speed.map {
                          Double($0) / Double(session.model?.maxSpeed(session.resolution) ?? 14)
                      },
                      text: session.saved.settings.speed.map { tr("%d Zoll/s", $0) } ?? tr("Drucker"),
                      symbol: "speedometer")
        }
    }
}

private struct GaugeTile: View {
    let title: String
    let value: Double?
    let text: String
    let symbol: String

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 14) {
                RingGauge(value: value ?? 0, lineWidth: 7, label: nil, valueText: nil)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.brandGradient)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(Theme.Typography.metricSmall)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
        }
        .cardHoverEffect()
    }
}

// MARK: - Informationskarten

private struct DeviceCard: View {
    let session: PrinterSession

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Gerät"), systemImage: "info.circle") {
                    Button {
                        Task { await session.refreshIdentity() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("Geräteinformationen neu lesen"))
                }
                let identity = session.identity
                KeyValueRow(tr("Modell"), identity?.model ?? session.model?.displayName ?? "–")
                if let friendly = identity?.friendlyName, !friendly.isEmpty {
                    KeyValueRow(tr("Gerätename"), friendly)
                }
                KeyValueRow(tr("Seriennummer"), identity?.serialNumber ?? "–", monospaced: true, copyable: identity?.serialNumber != nil)
                KeyValueRow(tr("Firmware"), identity?.firmware ?? "–", monospaced: true, copyable: identity?.firmware != nil)
                KeyValueRow(tr("Auflösung"), "\((identity?.resolution ?? session.resolution).dpi) dpi")
                if let width = identity?.printWidthDots {
                    KeyValueRow(tr("Druckbreite"),
                                tr("%d Punkte (%.1f mm)", width, session.resolution.mm(fromDots: width)))
                }
                if let memory = identity?.memoryKB {
                    KeyValueRow(tr("Speicher"), ByteCountFormatter.string(fromByteCount: Int64(memory) * 1024, countStyle: .memory))
                }
                let languages = (identity?.languages.isEmpty == false ? identity!.languages : (session.model?.languages ?? []))
                if !languages.isEmpty {
                    KeyValueRow(tr("Sprachen"), languages.map(\.displayName).joined(separator: ", "))
                }
                if identity?.isLinkOS == true || session.model?.supports(.linkOS) == true {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                        Text(tr("Link-OS-fähig: erweiterte Einstellungen & Live-Werte verfügbar"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

private struct MediaCard: View {
    let session: PrinterSession

    var body: some View {
        let hostStatus = session.status?.hostStatus
        let settings = session.saved.settings
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Medien"), systemImage: "square.stack.3d.up") {
                    Button(tr("Ändern")) { session.section = .stocks }
                        .buttonStyle(.labelWerkPlain)
                }
                KeyValueRow(tr("Etikett"), session.stock.name)
                KeyValueRow(tr("Größe"), session.stock.sizeDescription)
                KeyValueRow(tr("Erkennung"), tr((settings.tracking ?? session.stock.tracking).displayName))
                if let hostStatus {
                    KeyValueRow(tr("Druckverfahren"), tr(hostStatus.thermalTransferMode ? MediaType.thermalTransfer.displayName
                                                                                          : MediaType.directThermal.displayName))
                    if let mode = hostStatus.printMode {
                        KeyValueRow(tr("Druckmodus"), tr(mode.displayName))
                    }
                    KeyValueRow(tr("Etikettenlänge (Drucker)"),
                                tr("%d Punkte (%.1f mm)", hostStatus.labelLengthDots,
                                   session.resolution.mm(fromDots: hostStatus.labelLengthDots)))
                } else {
                    KeyValueRow(tr("Druckverfahren"), tr((settings.mediaType ?? .directThermal).displayName))
                }
            }
        }
    }
}

private struct ConnectionCard: View {
    let session: PrinterSession
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Verbindung"), systemImage: session.saved.descriptor.systemImage)
                KeyValueRow(tr("Schnittstelle"), session.saved.descriptor.displayString, copyable: true)
                KeyValueRow(tr("Zustand"), session.connectionState.displayName)
                KeyValueRow(tr("Sprache"), session.saved.language.displayName)
                if let ip = session.identity?.ipAddress, !ip.isEmpty {
                    KeyValueRow(tr("IP-Adresse"), ip, monospaced: true, copyable: true)
                }
                if let mac = session.identity?.macAddress, !mac.isEmpty {
                    KeyValueRow(tr("MAC-Adresse"), mac, monospaced: true, copyable: true)
                }
                if let queue = session.saved.cupsQueueName {
                    KeyValueRow(tr("macOS-Warteschlange"), queue, copyable: true)
                } else {
                    Button {
                        model.selection = .driver
                    } label: {
                        Label(tr("Als macOS-Drucker einrichten …"), systemImage: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.labelWerkPlain)
                }
            }
        }
    }
}

// MARK: - Statusverlauf

private struct StatusTimelineCard: View {
    let samples: [StatusSample]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Statusverlauf"), subtitle: tr("Letzte Abfragen dieses Druckers"),
                              systemImage: "waveform.path.ecg")
                Canvas { context, size in
                    guard let first = samples.first?.date, let last = samples.last?.date else { return }
                    let span = max(last.timeIntervalSince(first), 1)
                    for (index, sample) in samples.enumerated() {
                        let next = index + 1 < samples.count ? samples[index + 1].date : last.addingTimeInterval(span / Double(max(samples.count, 1)))
                        let x0 = size.width * CGFloat(sample.date.timeIntervalSince(first) / (span * 1.02))
                        let x1 = size.width * CGFloat(next.timeIntervalSince(first) / (span * 1.02))
                        let rect = CGRect(x: x0, y: 0, width: max(1.5, x1 - x0 + 0.5), height: size.height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Theme.color(for: sample.state).opacity(0.85)))
                    }
                }
                .frame(height: 18)
                .clipShape(Capsule())
                HStack {
                    Text(samples.first?.date.formatted(date: .omitted, time: .standard) ?? "")
                    Spacer()
                    legend
                    Spacer()
                    Text(samples.last?.date.formatted(date: .omitted, time: .standard) ?? "")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var legend: some View {
        let states = Array(Set(samples.map(\.state))).sorted { $0.rawValue < $1.rawValue }
        return HStack(spacing: 10) {
            ForEach(states, id: \.self) { state in
                HStack(spacing: 4) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.displayName)
                }
            }
        }
    }
}

// MARK: - Simulation (Demo-Drucker)

private struct SimulationCard: View {
    let session: PrinterSession
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    private func isActive(_ kind: AlertKind) -> Bool { session.alerts.contains { $0.kind == kind } }

    var body: some View {
        // Ohne Verbindung zeigt die Karte keinen Status – die Schalter wären blind.
        let connected = session.connectionState.isConnected
        GlassCard(tint: Theme.magenta) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Simulation"), subtitle: tr("Der Demo-Drucker reagiert wie ein echter ZD421t – probiere Fehlerzustände aus."),
                              systemImage: "wand.and.stars") {
                    if !connected {
                        Button {
                            Task { await session.connect() }
                        } label: {
                            Label(tr("Verbinden"), systemImage: "bolt.fill")
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .controlSize(.small)
                        .disabled(session.connectionState == .connecting)
                    }
                }
                HStack(spacing: 10) {
                    simToggle(tr("Druckkopf offen"), "printer.fill", isActive(.headOpen)) { on in
                        await session.virtualPrinter?.setHeadOpen(on)
                    }
                    simToggle(tr("Etiketten leer"), "square.stack.3d.down.right", isActive(.mediaOut)) { on in
                        await session.virtualPrinter?.setMediaOut(on)
                    }
                    simToggle(tr("Farbband leer"), "film", isActive(.ribbonOut)) { on in
                        await session.virtualPrinter?.setRibbonOut(on)
                    }
                    simToggle(tr("Pausiert"), "pause.circle", isActive(.paused)) { on in
                        await session.virtualPrinter?.setPaused(on)
                    }
                }
                .disabled(!connected)
            }
        }
    }

    private func simToggle(_ title: String, _ symbol: String, _ active: Bool,
                           _ apply: @escaping (Bool) async -> Void) -> some View {
        Button {
            Task {
                await apply(!active)
                await session.refreshStatus()
            }
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(active ? LabelWerkButtonStyle.labelWerkDestructive : LabelWerkButtonStyle.labelWerkSecondary)
        .animation(Motion.animation(Motion.spring, reduceMotion: systemReduceMotion || appReduceMotion), value: active)
    }
}

// MARK: - Letzte Aufträge

private struct RecentJobsCard: View {
    let session: PrinterSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = Array(model.history.filter { $0.printerID == session.id }.prefix(5))
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Letzte Aufträge"), systemImage: "clock.arrow.circlepath") {
                    Button(tr("Alle anzeigen")) { model.selection = .history }
                        .buttonStyle(.labelWerkPlain)
                }
                if jobs.isEmpty {
                    Text(tr("Noch keine Aufträge für diesen Drucker."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(jobs) { job in
                        HStack(spacing: 10) {
                            Image(systemName: job.kind.systemImage)
                                .frame(width: 20)
                                .foregroundStyle(job.success ? Theme.accent : Theme.error)
                            Text(job.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            if job.labels > 0 {
                                Text(tr("%d Etiketten", job.labels))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Text(job.date, style: .relative)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .frame(width: 90, alignment: .trailing)
                            if job.isReprintable {
                                Button {
                                    Task { await session.reprint(job) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.labelWerkPlain)
                                .help(tr("Erneut drucken"))
                            }
                        }
                        .padding(.vertical, 2)
                        if job.id != jobs.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }
}

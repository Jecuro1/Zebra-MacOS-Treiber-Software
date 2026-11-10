import SwiftUI
import LabelWerkKit

/// RFID-Werkzeuge eines Druckers: Status des Kodierers, Tags lesen (EPC/TID/Benutzerspeicher),
/// Tags schreiben (Serien, Prüfung, bedruckte Etiketten) sowie Kalibrierung und Einstellungen.
struct RFIDView: View {
    let session: PrinterSession

    init(session: PrinterSession) {
        self.session = session
    }

    var body: some View {
        RFIDContent(session: session, workbench: RFIDWorkbenchRegistry.workbench(for: session))
    }
}

// MARK: - Inhalt

private struct RFIDContent: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(session: PrinterSession, workbench: RFIDWorkbench) {
        self.session = session
        self.workbench = workbench
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var isConnected: Bool { session.connectionState.isConnected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                RFIDStatusCard(session: session, workbench: workbench, reduceMotion: reduceMotion)

                if session.saved.language != .zpl {
                    RFIDNoticeCard(
                        title: tr("RFID benötigt ZPL"),
                        message: tr("Die RFID-Befehle (^RF, ^HV, ^HR) sind ZPL-Befehle. Dieser Drucker ist in LabelWerk auf %@ eingestellt.", session.saved.language.displayName),
                        systemImage: "character.cursor.ibeam",
                        tint: Theme.warning
                    ) {
                        Button(tr("Auf ZPL umstellen")) {
                            session.saved.language = .zpl
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .controlSize(.small)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                mainContent
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.status?.availability)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: isConnected)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.statusError)
        }
        .onAppear { workbench.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, newValue in workbench.reduceMotion = newValue }
        .task(id: isConnected) { await loadStatusIfNeeded() }
    }

    /// Liest den RFID-Status beim Erscheinen bzw. nach dem Verbinden (zwischengespeicherte Werte
    /// bis 30 Sekunden werden weiterverwendet).
    private func loadStatusIfNeeded() async {
        guard isConnected, !workbench.isBusy else { return }
        if workbench.status != nil, workbench.statusError == nil, let loaded = workbench.statusLoadedAt,
           Date().timeIntervalSince(loaded) < 30 {
            return
        }
        await workbench.refreshStatus(session: session)
    }

    @ViewBuilder
    private var mainContent: some View {
        if !isConnected {
            EmptyStateView(
                title: session.connectionState == .connecting ? tr("Verbinde …") : tr("Drucker nicht verbunden"),
                message: tr("Verbinde LabelWerk mit dem Drucker, um den RFID-Kodierer zu prüfen, Tags zu lesen und zu schreiben."),
                systemImage: "antenna.radiowaves.left.and.right.slash",
                actionTitle: session.connectionState == .connecting ? nil : tr("Verbinden"),
                action: { Task { await session.connect() } }
            )
            .frame(minHeight: 320)
            .transition(.opacity)
        } else {
            if let error = workbench.statusError {
                statusErrorCard(error)
            }
            if let status = workbench.status {
                switch status.availability {
                case .notDetected where !workbench.forceUnlocked:
                    // Nach einem Übertragungsfehler nicht „kein Kodierer“ behaupten – die Fehlerkarte genügt.
                    if workbench.statusError == nil {
                        RFIDUnavailableCard(session: session, workbench: workbench, reduceMotion: reduceMotion)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                default:
                    availabilityBanner(status)
                    tools
                }
            } else if workbench.statusError == nil {
                loadingCard
            }
        }
    }

    /// Die Statusabfrage scheiterte an der Verbindung (Zeitüberschreitung, E/A-Fehler, Drucker belegt).
    private func statusErrorCard(_ error: String) -> some View {
        RFIDNoticeCard(
            title: tr("RFID-Status konnte nicht gelesen werden"),
            message: workbench.status == nil
                ? tr("Der Drucker hat die Abfrage nicht beantwortet (%@). Bitte Verbindung prüfen und erneut versuchen.", error)
                : tr("Der Drucker hat die Abfrage nicht beantwortet (%@). Angezeigt werden die zuletzt gelesenen Werte.", error),
            systemImage: "exclamationmark.triangle.fill",
            tint: Theme.warning
        ) {
            Button {
                Task { await workbench.refreshStatus(session: session) }
            } label: {
                if workbench.isLoadingStatus {
                    ProgressRing(progress: nil, size: 12, lineWidth: 2)
                } else {
                    Label(tr("Erneut prüfen"), systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .disabled(workbench.isLoadingStatus || workbench.isBusy)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private func availabilityBanner(_ status: RFIDStatusValues) -> some View {
        switch status.availability {
        case .disabled:
            RFIDNoticeCard(
                title: tr("RFID ist abgeschaltet"),
                message: tr("Der Kodierer ist im Drucker deaktiviert (rfid.enable = off). Lese- und Schreibbefehle werden ignoriert, bis RFID wieder eingeschaltet ist. Manche Modelle übernehmen die Änderung erst nach einem Neustart."),
                systemImage: "pause.circle.fill",
                tint: Theme.paused
            ) {
                Button(tr("RFID einschalten")) {
                    Task { await workbench.setEnabled(true, session: session) }
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.small)
                .disabled(session.isBusy || workbench.isBusy)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .unverified:
            RFIDNoticeCard(
                title: tr("Kodierer nicht eindeutig erkannt"),
                message: tr("Der Drucker liefert RFID-Einstellungen, meldet aber keine Firmware des Kodierers. Ist kein RFID-Modul eingebaut, bleiben Lese- und Schreibversuche ohne Ergebnis."),
                systemImage: "questionmark.circle.fill",
                tint: Theme.warning
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .notDetected:
            RFIDNoticeCard(
                title: tr("Ohne erkannten Kodierer"),
                message: tr("Die Werkzeuge sind freigeschaltet, obwohl kein RFID-Modul gemeldet wurde. Antworten bleiben aus, wenn tatsächlich keines eingebaut ist."),
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.warning
            ) {
                Button(tr("Erneut prüfen")) {
                    workbench.forceUnlocked = false
                    Task { await workbench.refreshStatus(session: session) }
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                .disabled(workbench.isLoadingStatus || workbench.isBusy)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .available:
            EmptyView()
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            AnimatedTabBar(
                items: RFIDTab.allCases,
                selection: $workbench.tab,
                title: { $0.title },
                systemImage: { $0.systemImage }
            )

            ZStack(alignment: .top) {
                panel(workbench.tab)
                    .id(workbench.tab)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 12)),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.tab)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func panel(_ tab: RFIDTab) -> some View {
        switch tab {
        case .read:
            RFIDReadPanel(session: session, workbench: workbench, reduceMotion: reduceMotion)
        case .write:
            RFIDWritePanel(session: session, workbench: workbench, reduceMotion: reduceMotion)
        case .settings:
            RFIDSettingsPanel(session: session, workbench: workbench, reduceMotion: reduceMotion)
        }
    }

    private var loadingCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                ProgressRing(progress: nil, size: 22, lineWidth: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("RFID-Kodierer wird geprüft …"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(tr("LabelWerk liest Firmware, Tag-Typ, Position und Sendeleistung des Kodierers."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .shimmering(active: !reduceMotion)
        }
        .transition(.opacity)
    }
}

// MARK: - Statuskarte

private struct RFIDStatusTileModel: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String?
    let systemImage: String
    let tint: Color
}

/// Kopfkarte: Antennen-Illustration, Erkennung des Moduls, Kennwerte und Zähler.
private struct RFIDStatusCard: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench
    let reduceMotion: Bool

    init(session: PrinterSession, workbench: RFIDWorkbench, reduceMotion: Bool) {
        self.session = session
        self.workbench = workbench
        self.reduceMotion = reduceMotion
    }

    private var status: RFIDStatusValues? { workbench.status }

    private var tint: Color {
        if workbench.radioActivity.isActive { return workbench.radioActivity.tint }
        switch status?.availability {
        case .available?: return Theme.teal
        case .unverified?: return Theme.warning
        case .disabled?: return Theme.paused
        case .notDetected?: return Theme.offline
        case nil: return Theme.violet
        }
    }

    var body: some View {
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: tint) {
            HStack(alignment: .center, spacing: 24) {
                RFIDAntennaIllustration(activity: workbench.radioActivity,
                                        successTrigger: workbench.successPulse,
                                        failureTrigger: workbench.failurePulse,
                                        reduceMotion: reduceMotion)
                    .frame(width: 190, height: 172)

                VStack(alignment: .leading, spacing: 14) {
                    header
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if status != nil {
                        tiles
                        counters
                    } else if workbench.isLoadingStatus {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.subtleFill)
                            .frame(height: 96)
                            .shimmering(active: !reduceMotion)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: status)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(tr("RFID-Kodierer"))
                .font(Theme.Typography.title)
            availabilityCapsule
            Spacer(minLength: 8)
            if let loaded = workbench.statusLoadedAt {
                Text(tr("Gelesen um %@", loaded.formatted(date: .omitted, time: .standard)))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
            Button {
                Task { await workbench.refreshStatus(session: session) }
            } label: {
                if workbench.isLoadingStatus {
                    ProgressRing(progress: nil, size: 14, lineWidth: 2)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.labelWerkPlain)
            .disabled(!session.connectionState.isConnected || workbench.isLoadingStatus || workbench.isBusy)
            .help(tr("RFID-Status neu lesen"))
        }
    }

    @ViewBuilder
    private var availabilityCapsule: some View {
        if workbench.radioActivity.isActive {
            RFIDCapsule(text: workbench.radioActivity.displayName, systemImage: "dot.radiowaves.left.and.right",
                        tint: workbench.radioActivity.tint)
        } else if let status {
            switch status.availability {
            case .available:
                RFIDCapsule(text: tr("Bereit"), systemImage: "checkmark.seal.fill", tint: Theme.ready)
            case .unverified:
                RFIDCapsule(text: tr("Eingeschränkt erkannt"), systemImage: "questionmark.circle.fill", tint: Theme.warning)
            case .disabled:
                RFIDCapsule(text: tr("Abgeschaltet"), systemImage: "pause.circle.fill", tint: Theme.paused)
            case .notDetected:
                RFIDCapsule(text: tr("Nicht erkannt"), systemImage: "xmark.octagon.fill", tint: Theme.offline)
            }
        } else if workbench.isLoadingStatus {
            RFIDCapsule(text: tr("Wird geprüft …"), systemImage: "hourglass", tint: Theme.violet)
        } else if workbench.statusError != nil {
            RFIDCapsule(text: tr("Keine Antwort"), systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
        }
    }

    private var subtitle: String {
        if !session.connectionState.isConnected {
            return tr("Nicht verbunden – Status des Kodierers unbekannt.")
        }
        switch workbench.radioActivity {
        case .reading: return tr("Der Tag über der Antenne wird gelesen …")
        case .writing:
            if let run = workbench.writeRun {
                return tr("Kodiere Tag %d von %d …", min(run.completed + 1, run.total), run.total)
            }
            return tr("Tags werden kodiert …")
        case .calibrating: return tr("Kalibrierung läuft – der Drucker zieht Etiketten durch und misst das Lesefenster.")
        case .idle: break
        }
        guard let status else {
            return workbench.statusError == nil
                ? tr("Status des RFID-Kodierers wird gelesen …")
                : tr("Der Status des RFID-Kodierers konnte nicht gelesen werden.")
        }
        switch status.availability {
        case .available:
            return tr("UHF-Kodierer betriebsbereit. Tags lesen, beschreiben und den Kodierer kalibrieren.")
        case .unverified:
            return tr("RFID-Einstellungen vorhanden, aber keine Kodierer-Firmware gemeldet.")
        case .disabled:
            return tr("Der Kodierer ist abgeschaltet.")
        case .notDetected:
            return tr("Kein RFID-Kodierer gemeldet.")
        }
    }

    private var tileModels: [RFIDStatusTileModel] {
        guard let status else { return [] }
        let enabledText: String? = status.enabled.map { $0 ? tr("Eingeschaltet") : tr("Abgeschaltet") }
        return [
            RFIDStatusTileModel(id: "enable", title: tr("Modul"), value: enabledText,
                                systemImage: "power", tint: status.enabled == false ? Theme.paused : Theme.ready),
            RFIDStatusTileModel(id: "firmware", title: tr("Kodierer-Firmware"), value: status.firmware,
                                systemImage: "cpu", tint: Theme.violet),
            RFIDStatusTileModel(id: "type", title: tr("Tag-Typ"),
                                value: status.tagType.map { RFIDStatusValues.tagTypeName($0) },
                                systemImage: "tag", tint: Theme.teal),
            RFIDStatusTileModel(id: "position", title: tr("Programmierposition"), value: status.programPosition,
                                systemImage: "arrow.left.and.right", tint: Theme.indigo),
            RFIDStatusTileModel(id: "read", title: tr("Leseleistung"), value: status.readPower.map { String($0) },
                                systemImage: "wave.3.left", tint: Theme.teal),
            RFIDStatusTileModel(id: "write", title: tr("Schreibleistung"), value: status.writePower.map { String($0) },
                                systemImage: "wave.3.right", tint: Theme.magenta),
            RFIDStatusTileModel(id: "region", title: tr("Region"), value: status.region,
                                systemImage: "globe.europe.africa", tint: Theme.printing),
            RFIDStatusTileModel(id: "error", title: tr("Letzte Meldung"), value: status.errorResponse,
                                systemImage: "exclamationmark.bubble", tint: Theme.warning),
        ]
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(Array(tileModels.enumerated()), id: \.element.id) { index, tile in
                RFIDStatusTile(tile: tile)
                    .rfidAppear(index: index, reduceMotion: reduceMotion)
            }
        }
    }

    private var counters: some View {
        HStack(spacing: 14) {
            RingGauge(value: status?.successRate ?? 0, lineWidth: 6, colors: [Theme.ready, Theme.teal],
                      label: nil,
                      valueText: status?.successRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Erfolgsquote seit dem letzten Zurücksetzen"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    counter(title: tr("Gültig"), value: status?.validCount, tint: Theme.ready, symbol: "checkmark.circle.fill")
                    counter(title: tr("Ungültig (VOID)"), value: status?.voidCount, tint: Theme.error, symbol: "xmark.circle.fill")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func counter(title: String, value: Int?, tint: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : (value ?? 0))
            Text(value.map { $0.formatted() } ?? "–")
                .font(Theme.Typography.metricSmall)
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: value)
    }
}

private struct RFIDStatusTile: View {
    let tile: RFIDStatusTileModel

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(systemImage: tile.systemImage, tint: tile.value == nil ? Theme.offline : tile.tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(tile.value ?? "–")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(tile.value == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .help(tile.value ?? tr("Vom Drucker nicht gemeldet"))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Kein Kodierer

private struct RFIDUnavailableCard: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench
    let reduceMotion: Bool

    @State private var appeared = false

    init(session: PrinterSession, workbench: RFIDWorkbench, reduceMotion: Bool) {
        self.session = session
        self.workbench = workbench
        self.reduceMotion = reduceMotion
    }

    private var hints: [String] {
        [
            tr("Auf dem Konfigurationsetikett (Werkzeuge › Konfiguration drucken) prüfen, ob ein RFID-Leser aufgeführt ist."),
            tr("Das RFID-Modul ist bei diesem Modell eine Option – Geräte ohne Kodierer können keine Tags lesen oder schreiben."),
            tr("Ältere Firmware beantwortet die RFID-Statusabfrage eventuell nicht; Lesen und Schreiben per ZPL kann trotzdem funktionieren."),
        ]
    }

    var body: some View {
        GlassCard(padding: 26, cornerRadius: Theme.Metrics.cornerLarge) {
            VStack(spacing: 16) {
                IconBadge(systemImage: "antenna.radiowaves.left.and.right.slash", tint: Theme.offline, size: 62)
                    .symbolEffect(.bounce, value: reduceMotion ? false : appeared)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                VStack(spacing: 6) {
                    Text(tr("Kein RFID-Kodierer gefunden"))
                        .font(Theme.Typography.title)
                    Text(tr("%@ meldet keine RFID-Werte. Vermutlich ist kein Kodierer eingebaut oder die Firmware unterstützt die Abfrage nicht.", session.displayName))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "\(index + 1).circle.fill")
                                .foregroundStyle(Theme.accent)
                            Text(hint)
                                .font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .rfidAppear(index: index, reduceMotion: reduceMotion)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                HStack(spacing: 10) {
                    Button {
                        Task { await workbench.refreshStatus(session: session) }
                    } label: {
                        Label(tr("Erneut prüfen"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .disabled(workbench.isLoadingStatus)

                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            workbench.forceUnlocked = true
                        }
                    } label: {
                        Label(tr("Trotzdem verwenden"), systemImage: "lock.open")
                    }
                    .buttonStyle(.labelWerkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) { appeared = true }
        }
    }
}

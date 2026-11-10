import SwiftUI
import LabelWerkKit

/// „Sicherung & Wartung“: komplette Druckerkonfiguration sichern, wiederherstellen und auf andere
/// Drucker klonen (mit Wert-für-Wert-Vergleich), Gerätesprache umstellen, Druckkopf-Zähler mit
/// Reinigungserinnerung, bebilderte Reinigungsanleitung und Druckkopftest. Ersetzt Printer Profile
/// Manager und die entsprechenden Teile der Zebra Setup Utilities.
struct MaintenanceView: View {
    let session: PrinterSession
    let store: MaintenanceStore

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(MaintCareSettings.intervalKey) private var cleaningInterval: Double = MaintCareSettings.defaultInterval

    init(session: PrinterSession) {
        self.session = session
        self.store = MaintenanceStore.shared(for: session)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    /// Inhalt bleibt sichtbar, solange eine Übertragung läuft oder kurz neu verbunden wird.
    private var showsContent: Bool {
        switch session.connectionState {
        case .connected: return true
        case .connecting: return store.hasLoadedData || store.isBusy
        case .disconnected, .failed: return store.isBusy
        }
    }

    var body: some View {
        ZStack {
            if !session.supportsStatus {
                unsupported
                    .transition(.opacity)
            } else if showsContent {
                content
                    .transition(.opacity)
            } else {
                disconnected
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: showsContent)
        .task(id: session.connectionState.isConnected) {
            await store.loadInitialValues(session: session)
        }
    }

    // MARK: Inhalt

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                if session.connectionState == .connecting {
                    connectingBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                MaintPanePicker(
                    selection: Bindable(store).pane,
                    detail: { detail(for: $0) },
                    needsAttention: { needsAttention($0) },
                    reduceMotion: reduceMotion
                )
                .maintAppear(0, reduceMotion: reduceMotion)

                ZStack(alignment: .top) {
                    paneContent(store.pane)
                        .id(store.pane)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 14)),
                            removal: .opacity
                        ))
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: store.pane)
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: session.connectionState)
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: MaintPane) -> some View {
        switch pane {
        case .backup:
            MaintBackupPane(session: session, store: store, reduceMotion: reduceMotion)
        case .restore:
            MaintRestorePane(session: session, store: store, reduceMotion: reduceMotion)
        case .language:
            MaintLanguagePane(session: session, controller: store.language, reduceMotion: reduceMotion)
        case .care:
            MaintCarePane(session: session, store: store, reduceMotion: reduceMotion)
        }
    }

    private var connectingBanner: some View {
        GlassCard(padding: 12, tint: Theme.printing) {
            HStack(spacing: 10) {
                ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                Text(tr("Verbindung wird aufgebaut – Werte werden danach aktualisiert."))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Zusammenfassungen der Kacheln

    private func detail(for pane: MaintPane) -> String {
        switch pane {
        case .backup:
            let backup = store.backup
            if backup.isReading { return tr("Wird gelesen …") }
            if let savedAt = backup.savedAt {
                return tr("Gesichert %@", savedAt.formatted(.relative(presentation: .named)))
            }
            if backup.phase == .ready { return tr("%d Werte gelesen", backup.settings.count) }
            return tr("Konfiguration als Datei")
        case .restore:
            let restore = store.restore
            switch restore.phase {
            case .applying:
                return tr("Überträgt … %d %%", Int((restore.progress * 100).rounded()))
            case .loading, .comparing:
                return tr("Vergleicht …")
            case .finished:
                if let report = restore.report {
                    return report.isClean ? tr("%d Werte übertragen", report.sent) : tr("Mit Hinweisen beendet")
                }
                return tr("Abgeschlossen")
            default:
                return restore.source?.name ?? tr("Aus Datei oder von Drucker")
            }
        case .language:
            let language = store.language
            if let value = language.deviceValue {
                return MaintDeviceLanguage.option(for: value)?.title ?? value
            }
            switch language.phase {
            case .loading: return tr("Wird gelesen …")
            case .unavailable: return tr("Nicht gemeldet")
            default: return tr("Gerätesprache")
            }
        case .care:
            if let meters = store.care.reading?.sinceCleanMeters {
                return tr("%@ seit Reinigung", MaintFormat.length(meters))
            }
            return store.care.phase == .loading ? tr("Wird gelesen …") : tr("Zähler & Reinigung")
        }
    }

    private func needsAttention(_ pane: MaintPane) -> Bool {
        switch pane {
        case .backup:
            return false
        case .restore:
            if case .failed = store.restore.phase { return true }
            if let report = store.restore.report { return !report.isClean }
            return false
        case .language:
            guard let value = store.language.deviceValue else { return false }
            return !MaintDeviceLanguage.isCompatible(deviceValue: value, output: session.saved.language,
                                                     model: session.model)
        case .care:
            if session.alerts.contains(where: { $0.kind == .cleanPrinthead }) { return true }
            guard let meters = store.care.reading?.sinceCleanMeters else { return false }
            let assessment = MaintCleaningAssessment.assess(sinceCleanMeters: meters, intervalMeters: cleaningInterval,
                                                            printerRequests: false)
            return assessment.level >= .due
        }
    }

    // MARK: Leere Zustände

    @ViewBuilder
    private var disconnected: some View {
        switch session.connectionState {
        case .connecting:
            EmptyStateView(
                title: tr("Verbinde …"),
                message: tr("Verbindung zu %@ wird aufgebaut.", session.saved.descriptor.displayString),
                systemImage: "bolt.horizontal"
            )
        case .failed(let message):
            EmptyStateView(
                title: tr("Drucker nicht erreichbar"),
                message: tr("%@ – Sicherung, Wiederherstellung und Wartung brauchen eine aktive Verbindung.", message),
                systemImage: "bolt.slash",
                actionTitle: tr("Erneut verbinden")
            ) {
                Task { await session.connect() }
            }
        case .connected, .disconnected:
            EmptyStateView(
                title: tr("Nicht verbunden"),
                message: tr("Verbinde LabelWerk mit dem Drucker, um Einstellungen zu sichern, auf andere Drucker zu klonen oder den Druckkopf zu prüfen."),
                systemImage: "externaldrive.badge.timemachine",
                actionTitle: tr("Verbinden")
            ) {
                Task { await session.connect() }
            }
        }
    }

    private var unsupported: some View {
        EmptyStateView(
            title: tr("Nur mit Rückkanal möglich"),
            message: tr("Über „%@“ kann LabelWerk nur senden. Für Sicherung, Klonen und Wartungszähler muss der Drucker per USB, Netzwerk oder Bluetooth eingerichtet sein.",
                        session.saved.descriptor.displayString),
            systemImage: "arrow.left.arrow.right",
            actionTitle: tr("Drucker mit Rückkanal hinzufügen …")
        ) {
            model.isAddPrinterPresented = true
        }
    }
}

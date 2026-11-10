import AppKit
import SwiftUI
import LabelWerkKit

/// Treiber & Warteschlangen: Treiberstatus mit animiertem Druckweg, Installation/Update/Entfernen,
/// Diagnose, macOS-Warteschlangen (Standard, Testseite, Fortsetzen, Synchronisieren, Entfernen),
/// Einrichten von Warteschlangen für LabelWerk-Drucker und Hilfe zum Drucken aus jedem Programm.
struct DriverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var queues: [DriverQueueItem] = []
    @State private var queuesLoaded = false
    @State private var isLoadingQueues = false
    @State private var busyQueues: Set<String> = []
    @State private var busyPrinters: Set<UUID> = []
    @State private var queueToRemove: DriverQueueItem?
    @State private var pendingDowngrade: DriverDowngrade?
    @State private var queueLoadGeneration = 0
    @State private var confirmUninstall = false
    @State private var flowActive = false
    @State private var flowToken = 0
    @State private var hoveringPipeline = false
    @State private var celebration = 0
    @State private var isSyncingAll = false
    @State private var copiedCommand = false

    init() {}

    private var installer: DriverInstaller { DriverInstaller.shared }
    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                SectionHeader(tr("Treiber & Warteschlangen"),
                              subtitle: tr("Der LabelWerk-Treiber macht Zebra-Drucker in jedem Programm über den macOS-Druckdialog verfügbar."),
                              systemImage: "shippingbox")

                heroCard

                if installer.snapshot != nil && !installer.hasPayload {
                    payloadMissingCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // ViewThatFits misst die Idealbreite (ungebrochene Textzeilen). Die feste Idealbreite
                // lässt die Karten ab ausreichender Breite nebeneinander stehen; der Text bricht dann um.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
                        diagnosticsCard
                            .frame(maxWidth: .infinity, alignment: .top)
                        howItWorksCard
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .frame(minWidth: 0, idealWidth: 860, maxWidth: .infinity, alignment: .top)
                    VStack(spacing: Theme.Metrics.cardSpacing) {
                        diagnosticsCard
                        howItWorksCard
                    }
                }

                queuesSection

                if !printersWithoutQueue.isEmpty {
                    setupSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                usageHelpCard
            }
            .padding(Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: printersWithoutQueue.map(\.id))
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: installer.hasPayload)
        }
        .background { AnimatedBackground(style: .subtle).ignoresSafeArea() }
        .navigationTitle(tr("Treiber & Warteschlangen"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openPrintSettings()
                } label: {
                    Label(tr("Drucker & Scanner"), systemImage: "gearshape")
                }
                .help(tr("Systemeinstellungen „Drucker & Scanner“ öffnen"))
                Button {
                    Task { await reloadAll() }
                } label: {
                    Label(tr("Aktualisieren"), systemImage: "arrow.clockwise")
                }
                .help(tr("Treiberstatus und Warteschlangen neu lesen"))
                .disabled(installer.isRefreshing || installer.isBusy || isLoadingQueues)
            }
        }
        .task {
            await reloadAll()
            if installer.isInstalled { pulseFlow(3.5) }
        }
        .onChange(of: installer.successCount) { _, _ in
            if !reduceMotion { celebration += 1 }
            pulseFlow(5)
            Task { await loadQueues() }
        }
        .onChange(of: model.isInstallWizardPresented) { _, shown in
            // Der Assistent hat womöglich eine Warteschlange angelegt (ein Sheet löst hier kein
            // onAppear aus): Liste nach dem Schließen neu lesen.
            if !shown { Task { await loadQueues() } }
        }
        .confirmationDialog(tr("Treiber entfernen?"), isPresented: $confirmUninstall, titleVisibility: .visible) {
            if !labelWerkQueueNames.isEmpty {
                Button(tr("Treiber und %d Warteschlangen entfernen", labelWerkQueueNames.count), role: .destructive) {
                    uninstall(removingQueues: true)
                }
            }
            Button(tr("Nur Treiber entfernen"), role: .destructive) {
                uninstall(removingQueues: false)
            }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(labelWerkQueueNames.isEmpty
                 ? tr("CUPS-Filter und PPD-Dateien von LabelWerk werden entfernt. macOS fragt nach einem Administratorpasswort.")
                 : tr("CUPS-Filter und PPD-Dateien von LabelWerk werden entfernt. Warteschlangen, die den Treiber verwenden, funktionieren danach nicht mehr – sie können gleich mit entfernt werden."))
        }
        .confirmationDialog(
            tr("Warteschlange entfernen?"),
            isPresented: Binding(get: { queueToRemove != nil }, set: { if !$0 { queueToRemove = nil } }),
            titleVisibility: .visible,
            presenting: queueToRemove
        ) { item in
            Button(tr("Entfernen"), role: .destructive) { removeQueue(item) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { item in
            if let session = model.sessions.first(where: { $0.saved.descriptor == .cupsQueue(name: item.info.name) }) {
                Text(tr("„%@“ wird aus macOS entfernt. Der LabelWerk-Drucker „%@“ druckt über diese Warteschlange und kann danach auch in LabelWerk nicht mehr drucken, bis er neu hinzugefügt wird.",
                        item.info.name, session.displayName))
            } else {
                Text(tr("„%@“ wird aus macOS entfernt und steht in Programmen nicht mehr zur Verfügung. Der Drucker bleibt in LabelWerk erhalten.", item.info.name))
            }
        }
        .confirmationDialog(
            tr("Ältere Treiberversion installieren?"),
            isPresented: Binding(get: { pendingDowngrade != nil }, set: { if !$0 { pendingDowngrade = nil } }),
            titleVisibility: .visible,
            presenting: pendingDowngrade
        ) { downgrade in
            Button(tr("Version %@ installieren", downgrade.bundled), role: .destructive) {
                Task { await installer.install(allowDowngrade: true) }
            }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { downgrade in
            Text(tr("Installiert ist %@ – neuer als die Version %@ dieser App. Der neuere Treiber wird dabei ersetzt; Modelle und Verbesserungen, die erst mit %@ kamen, fehlen danach. Besser ist es, LabelWerk zu aktualisieren.",
                    downgrade.installed, downgrade.bundled, downgrade.installed))
        }
    }

    // MARK: - Status (Hero)

    private var heroCard: some View {
        GlassCard(padding: 22, cornerRadius: Theme.Metrics.cornerLarge, tint: statusTint) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    ZStack {
                        IconBadge(systemImage: statusSymbol, tint: statusTint, size: 62)
                            .symbolEffect(.bounce, value: reduceMotion ? -1 : statusKey)
                            .contentTransition(.symbolEffect(.replace))
                        CelebrationBurst(trigger: celebration, colors: [Theme.ready, Theme.teal, Theme.violet])
                            .frame(width: 220, height: 220)
                    }
                    .frame(width: 62, height: 62)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(statusTitle)
                            .font(Theme.Typography.title)
                            .contentTransition(.opacity)
                        Text(statusDetail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        DiscoveryFlowLayout(spacing: 6) {
                            if let installed = installer.installedVersion {
                                chip(tr("Installiert %@", installed), symbol: "checkmark.seal", tint: Theme.ready)
                            }
                            if let bundled = installer.bundledVersion {
                                chip(tr("Im App-Paket %@", bundled), symbol: "shippingbox", tint: Theme.violet)
                            }
                            if installer.isInstalled {
                                chip(tr("%d PPD-Dateien", installer.installedPPDCount), symbol: "doc.on.doc", tint: Theme.teal)
                            } else if installer.bundledPPDCount > 0 {
                                chip(tr("%d PPD-Dateien im Paket", installer.bundledPPDCount), symbol: "doc.on.doc", tint: Theme.teal)
                            }
                            if queuesLoaded {
                                chip(tr("%d LabelWerk-Warteschlangen", labelWerkQueueNames.count), symbol: "list.bullet", tint: Theme.indigo)
                            }
                        }
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 8)

                    heroActions
                }

                if let step = runningStep {
                    HStack(spacing: 12) {
                        ProgressRing(progress: nil, size: 22, lineWidth: 3)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step)
                                .font(.system(size: 12.5, weight: .medium))
                                .contentTransition(.opacity)
                            StripedProgressBar(progress: nil, tint: Theme.teal)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                resultBanner

                DriverPipelineDiagram(
                    stages: DriverPipelineStage.standard(installer: installer, printerName: pipelinePrinterName),
                    isActive: pipelineActive,
                    reduceMotion: reduceMotion
                )
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.subtleFill.opacity(0.7)))
                .onHover { inside in hoveringPipeline = inside }
                .help(tr("Datenfluss beim Drucken aus einem beliebigen Programm"))
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: installer.phase)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: installer.status)
    }

    @ViewBuilder
    private var heroActions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch installer.status {
            case .notInstalled:
                Button {
                    Task { await installer.install() }
                } label: {
                    Label(tr("Treiber installieren"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.large)
                .disabled(!installer.hasPayload || installer.isBusy)
            case .outdated(_, let bundled):
                Button {
                    Task { await installer.install() }
                } label: {
                    Label(tr("Auf %@ aktualisieren", bundled), systemImage: "arrow.triangle.2.circlepath.circle.fill")
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.large)
                .disabled(!installer.hasPayload || installer.isBusy)
            case .current:
                Button {
                    Task { await installer.install() }
                } label: {
                    Label(tr("Erneut installieren"), systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(!installer.hasPayload || installer.isBusy)
                .help(tr("Repariert Rechte und Dateien des Treibers"))
            case .newerInstalled(let installed, let bundled):
                // Erneut installieren hieße hier: auf die ältere Version dieser App zurückgehen.
                Button {
                    pendingDowngrade = DriverDowngrade(installed: installed, bundled: bundled)
                } label: {
                    Label(tr("Version %@ installieren …", bundled), systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(!installer.hasPayload || installer.isBusy)
                .help(tr("Ersetzt den neueren Treiber %@ durch die ältere Version %@ aus dieser App", installed, bundled))
            }
            if installer.isInstalled {
                Button {
                    confirmUninstall = true
                } label: {
                    Label(tr("Entfernen …"), systemImage: "trash")
                        .foregroundStyle(Theme.error)
                }
                .buttonStyle(.labelWerkPlain)
                .disabled(installer.isBusy)
            }
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        switch installer.phase {
        case .succeeded(let operation):
            banner(symbol: "checkmark.circle.fill", tint: Theme.ready,
                   title: operation == .uninstall ? tr("Treiber entfernt") : tr("Treiber ist einsatzbereit"),
                   message: operation == .uninstall
                       ? tr("Filter und PPD-Dateien wurden entfernt und der Druckdienst neu gestartet.")
                       : tr("Filter und PPD-Dateien sind installiert und der Druckdienst wurde neu gestartet. Richte jetzt unten Warteschlangen für deine Drucker ein."))
        case .failed(let operation, let message):
            banner(symbol: "xmark.octagon.fill", tint: Theme.error,
                   title: tr("%@ fehlgeschlagen", operation.title), message: message)
        case .cancelled:
            banner(symbol: "hand.raised.fill", tint: Theme.warning,
                   title: tr("Abgebrochen"), message: tr("Es wurden keine Änderungen vorgenommen."))
        case .idle, .running:
            EmptyView()
        }
    }

    private func banner(symbol: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: reduceMotion ? "" : title)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button {
                installer.dismissResult()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("Ausblenden"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
            .contentTransition(.numericText())
    }

    // MARK: - Treiberpaket fehlt

    private var payloadMissingCard: some View {
        GlassCard(padding: 18, tint: Theme.warning) {
            HStack(alignment: .top, spacing: 16) {
                IconBadge(systemImage: "hammer.fill", tint: Theme.warning, size: 42)
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Treiberpaket nicht im App-Bundle"))
                        .font(Theme.Typography.headline)
                    Text(tr("Diese LabelWerk-Version wurde ohne Treiber gestartet – typisch für einen Entwicklungs-Build über „swift run“. Das fertige App-Bundle enthält den Treiber unter „Contents/Resources/Driver“."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tr("So erstellst du das App-Bundle mit Treiber (im Projektordner):"))
                        .font(.system(size: 12.5, weight: .medium))
                    HStack(spacing: 10) {
                        Text(verbatim: "./Scripts/build_app.sh")
                            .font(Theme.Typography.code)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("./Scripts/build_app.sh", forType: .string)
                            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { copiedCommand = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { copiedCommand = false }
                            }
                        } label: {
                            Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.labelWerkPlain)
                        .help(tr("Kopieren"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
                    Text(tr("Das Skript baut App, CUPS-Filter und PPD-Dateien und bettet den Treiber in LabelWerk.app ein. Danach LabelWerk.app starten und den Treiber hier installieren."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Diagnose

    private var diagnosticsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Diagnose"),
                              subtitle: installer.lastRefresh.map { tr("Geprüft um %@", $0.formatted(date: .omitted, time: .shortened)) },
                              systemImage: "stethoscope") {
                    if installer.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity)
                    } else {
                        Button {
                            Task { await installer.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .disabled(installer.isBusy)
                        .help(tr("Erneut prüfen"))
                        .transition(.opacity)
                    }
                }
                if installer.checks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Treiber wird geprüft …"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(installer.checks.enumerated()), id: \.element.id) { index, check in
                            DriverCheckRow(check: check, index: index, reduceMotion: reduceMotion)
                        }
                    }
                }
            }
        }
    }

    private var howItWorksCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("So arbeitet der Treiber"), systemImage: "point.3.filled.connected.trianglepath.dotted")
                step(1, tr("Programm"), tr("Ein beliebiges Programm druckt über den macOS-Druckdialog – Seiten kommen als PDF bei CUPS an."))
                step(2, "CUPS", tr("macOS rastert die Seite in Graustufen in der Auflösung des Druckkopfs (203, 300 oder 600 dpi)."))
                step(3, "rastertolabelwerk", tr("Der LabelWerk-Filter rastert in Schwarz/Weiß, komprimiert und erzeugt ZPL, EPL oder CPCL mit deinen Einstellungen (Schwärzung, Tempo, Medien)."))
                step(4, tr("Drucker"), tr("Die Daten gehen per USB oder Netzwerk (Port 9100) an den Zebra-Drucker – ohne Umweg über Zebra-Software."))
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.brandGradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Warteschlangen

    private var queuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(tr("macOS-Warteschlangen"),
                          subtitle: tr("Drucker, die in allen Programmen im Druckdialog erscheinen"),
                          systemImage: "list.bullet.rectangle.portrait") {
                HStack(spacing: 6) {
                    Button {
                        model.isInstallWizardPresented = true
                    } label: {
                        Label(tr("Drucker installieren …"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .controlSize(.small)
                    .help(tr("Netzwerk- oder USB-Drucker als macOS-Drucker installieren – wie unter Windows (⌥⌘N)"))
                    if !linkedQueueSessions.isEmpty {
                        Button {
                            syncAll()
                        } label: {
                            Label(tr("Alle synchronisieren"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .controlSize(.small)
                        .disabled(isSyncingAll)
                        .help(tr("Druckeinstellungen aller verknüpften Drucker als Standard ihrer Warteschlange übernehmen"))
                    }
                    Button {
                        Task { await loadQueues() }
                    } label: {
                        Label(tr("Aktualisieren"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    .disabled(isLoadingQueues)
                }
            }

            if !queuesLoaded {
                GlassCard {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(tr("Warteschlangen werden gelesen …"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .shimmering(active: !reduceMotion)
            } else if queues.isEmpty {
                GlassCard(padding: 18) {
                    HStack(spacing: 14) {
                        IconBadge(systemImage: "tray", tint: Theme.offline, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("Keine Warteschlangen eingerichtet"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(installer.isInstalled
                                 ? tr("Richte unten für deine LabelWerk-Drucker eine Warteschlange ein – danach erscheinen sie in jedem Druckdialog.")
                                 : tr("Installiere zuerst den Treiber, dann lassen sich Warteschlangen für deine Drucker einrichten."))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            model.isInstallWizardPresented = true
                        } label: {
                            Label(tr("Netzwerkdrucker installieren …"), systemImage: "printer.filled.and.paper")
                        }
                        .buttonStyle(.labelWerkSecondary)
                    }
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(queues.enumerated()), id: \.element.id) { index, item in
                        let linked = linkedSession(for: item.info.name)
                        let syncAction: (() -> Void)? = linked == nil ? nil : {
                            if let linked { syncSettings(linked, queue: item.info.name) }
                        }
                        let resumeAction: (() -> Void)? = item.state == .disabled ? { resume(item) } : nil
                        DriverQueueRow(
                            item: item,
                            linkedSession: linked,
                            isBusy: busyQueues.contains(item.info.name),
                            appearIndex: index,
                            reduceMotion: reduceMotion,
                            onSetDefault: { setDefault(item) },
                            onTestPage: { printTestPage(item) },
                            onSync: syncAction,
                            onResume: resumeAction,
                            onRemove: { queueToRemove = item }
                        )
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                                removal: .opacity.combined(with: .scale(scale: 0.96))))
                    }
                }
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: queues)
            }
        }
    }

    private var setupSection: some View {
        let existing: Set<String>? = queuesLoaded ? Set(queues.map(\.info.name)) : nil
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("LabelWerk-Drucker ohne Warteschlange"),
                              subtitle: tr("Eine Warteschlange macht den Drucker mit seinen Einstellungen in allen Programmen verfügbar."),
                              systemImage: "plus.rectangle.on.rectangle")
                if !installer.isInstalled {
                    DiscoveryInlineNote(systemImage: "exclamationmark.triangle",
                                        text: tr("Zum Einrichten wird der LabelWerk-Treiber benötigt. Installiere ihn oben."))
                }
                VStack(spacing: 8) {
                    ForEach(printersWithoutQueue) { session in
                        DriverSetupRow(
                            session: session,
                            option: DriverSetupOption.option(for: session, existingQueues: existing),
                            driverInstalled: installer.isInstalled,
                            isBusy: busyPrinters.contains(session.id),
                            reduceMotion: reduceMotion,
                            onSetUp: { setUpQueue(for: session) },
                            onLink: { queue in link(session, to: queue) }
                        )
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)),
                                                removal: .opacity.combined(with: .move(edge: .trailing))))
                    }
                }
            }
        }
    }

    // MARK: - Hilfe

    private var usageHelpCard: some View {
        GlassCard(tint: Theme.teal) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Aus jedem Programm drucken"),
                              subtitle: tr("So gelingen Etiketten aus Vorschau, Pages, Word, Browsern oder Versandsoftware"),
                              systemImage: "doc.richtext")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    helpTile("printer", tr("Druckdialog"),
                             tr("⌘P drücken und die LabelWerk-Warteschlange als Drucker wählen."))
                    helpTile("rectangle.portrait", tr("Papiergröße = Etikett"),
                             tr("Als Papiergröße das eingelegte Etikettenformat wählen, z. B. „4 × 6 Zoll“ oder „100 × 150 mm“."))
                    helpTile("arrow.up.left.and.arrow.down.right", tr("Skalierung 100 %"),
                             tr("100 % statt „An Seite anpassen“ verwenden, damit Barcodes exakt und scannbar gedruckt werden."))
                    helpTile("slider.horizontal.3", tr("Einstellungen"),
                             tr("Schwärzung, Tempo und Medien stammen aus LabelWerk. „Synchronisieren“ überträgt Änderungen in die Warteschlange; im Druckdialog lassen sie sich pro Auftrag anpassen."))
                }
            }
        }
    }

    private func helpTile(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(systemImage: symbol, tint: Theme.teal, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Abgeleitete Werte

    private var runningStep: String? {
        if case .running(_, let step) = installer.phase { return step }
        return nil
    }

    private var statusKey: Int {
        switch installer.status {
        case .notInstalled: return installer.hasPayload ? 0 : 1
        case .current: return 2
        case .outdated: return 3
        case .newerInstalled: return 4
        }
    }

    private var statusTint: Color {
        switch installer.status {
        case .notInstalled: return installer.hasPayload ? Theme.violet : Theme.warning
        case .current: return Theme.ready
        case .outdated: return Theme.printing
        case .newerInstalled: return Theme.warning
        }
    }

    private var statusSymbol: String {
        switch installer.status {
        case .notInstalled: return installer.hasPayload ? "shippingbox" : "hammer"
        case .current: return "checkmark.seal.fill"
        case .outdated: return "arrow.down.circle.fill"
        case .newerInstalled: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTitle: String {
        if installer.snapshot == nil { return tr("Treiber wird geprüft …") }
        switch installer.status {
        case .notInstalled: return installer.hasPayload ? tr("Treiber nicht installiert") : tr("Treiberpaket fehlt")
        case .current: return tr("Treiber ist aktuell")
        case .outdated: return tr("Update verfügbar")
        case .newerInstalled: return tr("Neuere Version installiert")
        }
    }

    private var statusDetail: String {
        if installer.snapshot == nil { return tr("Installationszustand und Druckdienst werden gelesen.") }
        switch installer.status {
        case .notInstalled:
            return installer.hasPayload
                ? tr("Installiere den LabelWerk-Treiber, damit deine Zebra-Drucker in jedem Programm über den macOS-Druckdialog verfügbar sind – mit allen Einstellungen wie unter Windows.")
                : tr("Diese App enthält kein Treiberpaket. Erstelle das App-Bundle wie unten beschrieben.")
        case .current(let version):
            if let version {
                return tr("Version %@ – CUPS-Filter und %d PPD-Dateien sind installiert.", version, installer.installedPPDCount)
            }
            return tr("CUPS-Filter und %d PPD-Dateien sind installiert.", installer.installedPPDCount)
        case .outdated(let installed, let bundled):
            return tr("Installiert ist %@, diese App bringt %@ mit. Das Update übernimmt neue Modelle und Verbesserungen des Filters.",
                      installed ?? tr("eine unbekannte Version"), bundled)
        case .newerInstalled(let installed, let bundled):
            return tr("Installiert ist %@ – neuer als die Version %@ dieser App. Bitte LabelWerk aktualisieren.", installed, bundled)
        }
    }

    private var labelWerkQueueNames: [String] {
        queues.filter(\.isLabelWerk).map(\.info.name)
    }

    private var printersWithoutQueue: [PrinterSession] {
        let names = Set(queues.map(\.info.name))
        return model.sessions.filter { session in
            guard let queue = session.saved.cupsQueueName else { return true }
            return queuesLoaded && !names.contains(queue)
        }
    }

    private var linkedQueueSessions: [PrinterSession] {
        let names = Set(queues.map(\.info.name))
        return model.sessions.filter { session in
            guard let queue = session.saved.cupsQueueName else { return false }
            return names.contains(queue)
        }
    }

    private func linkedSession(for queue: String) -> PrinterSession? {
        model.sessions.first { $0.saved.cupsQueueName == queue }
    }

    private var pipelinePrinterName: String? {
        if let session = linkedQueueSessions.first { return session.displayName }
        return queues.first(where: \.isLabelWerk)?.info.name
    }

    private var pipelineActive: Bool {
        flowActive || installer.isBusy || hoveringPipeline || queues.contains { $0.state == .printing }
    }

    // MARK: - Aktionen

    private func reloadAll() async {
        await installer.refresh()
        await loadQueues()
    }

    private func loadQueues() async {
        // Mehrere Ladevorgänge können sich überholen (z. B. nach zwei kurz aufeinander folgenden
        // Aktionen): Nur der zuletzt gestartete übernimmt sein Ergebnis und beendet die Ladeanzeige.
        queueLoadGeneration += 1
        let generation = queueLoadGeneration
        isLoadingQueues = true
        async let stateMap = DriverQueueStatusReader.states()
        // Warteschlangen nur einmal lesen (`lpstat`/`lpoptions`) und daraus die LabelWerk-Kennzeichnung ableiten.
        let all = await CUPSService.queues()
        let labelWerkNames = await DriverQueueClassifier.labelWerkQueueNames(in: all)
        let states = await stateMap
        let items = all
            .map { DriverQueueItem(info: $0, isLabelWerk: labelWerkNames.contains($0.name), state: states[$0.name] ?? .unknown) }
            .sorted { lhs, rhs in
                if lhs.isLabelWerk != rhs.isLabelWerk { return lhs.isLabelWerk }
                if lhs.info.isDefault != rhs.info.isDefault { return lhs.info.isDefault }
                return lhs.info.name.localizedStandardCompare(rhs.info.name) == .orderedAscending
            }
        guard generation == queueLoadGeneration else { return }
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            queues = items
            queuesLoaded = true
            isLoadingQueues = false
        }
    }

    /// Lässt im Druckweg für einige Sekunden Datenpakete fließen.
    private func pulseFlow(_ seconds: Double) {
        guard !reduceMotion else { return }
        flowToken += 1
        let token = flowToken
        withAnimation(.easeInOut(duration: 0.4)) { flowActive = true }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard token == flowToken else { return }
            withAnimation(.easeInOut(duration: 0.6)) { flowActive = false }
        }
    }

    /// Führt eine Warteschlangen-Operation mit Fortschrittsanzeige, Hinweisen und Neuladen aus.
    private func performQueueAction(_ queue: String, title: String, success: String?,
                                    operation: @escaping () async throws -> Void,
                                    onSuccess: @escaping () -> Void = {}) {
        busyQueues.insert(queue)
        Task {
            do {
                try await operation()
                onSuccess()
                if let success {
                    model.toast(success, message: queue, style: .success)
                }
                pulseFlow(3)
            } catch {
                model.toast(tr("Fehler bei „%@“", title), message: PrinterSession.describe(error), style: .error)
            }
            busyQueues.remove(queue)
            await loadQueues()
        }
    }

    private func setDefault(_ item: DriverQueueItem) {
        let name = item.info.name
        performQueueAction(name, title: tr("Als Standard festlegen"), success: tr("Standarddrucker festgelegt")) {
            try await CUPSService.setDefaultPrinter(name)
        }
    }

    private func printTestPage(_ item: DriverQueueItem) {
        let name = item.info.name
        performQueueAction(name, title: tr("Testseite drucken"), success: tr("Testseite gesendet")) {
            try await CUPSService.printTestPage(queue: name)
        }
    }

    private func resume(_ item: DriverQueueItem) {
        let name = item.info.name
        performQueueAction(name, title: tr("Warteschlange fortsetzen"), success: tr("Warteschlange fortgesetzt")) {
            try await DriverQueueControl.resume(name)
        }
    }

    private func syncSettings(_ session: PrinterSession, queue: String) {
        let settings = session.saved.settings
        let stock = session.stock
        let language = session.saved.language
        performQueueAction(queue, title: tr("Einstellungen synchronisieren"), success: tr("Einstellungen übernommen")) {
            try await CUPSService.setDefaults(queue: queue, settings: settings, stock: stock, language: language)
        }
    }

    private func syncAll() {
        var targets: [DriverSyncTarget] = []
        for session in linkedQueueSessions {
            guard let queue = session.saved.cupsQueueName else { continue }
            targets.append(DriverSyncTarget(queue: queue, settings: session.saved.settings,
                                            stock: session.stock, language: session.saved.language))
        }
        guard !targets.isEmpty else { return }
        isSyncingAll = true
        for target in targets { busyQueues.insert(target.queue) }
        Task {
            var failures: [String] = []
            for target in targets {
                do {
                    try await CUPSService.setDefaults(queue: target.queue, settings: target.settings,
                                                      stock: target.stock, language: target.language)
                } catch {
                    failures.append(target.queue)
                }
                busyQueues.remove(target.queue)
            }
            if failures.isEmpty {
                model.toast(tr("Einstellungen synchronisiert"),
                            message: tr("%d Warteschlangen aktualisiert", targets.count), style: .success)
                pulseFlow(4)
            } else {
                model.toast(tr("Synchronisieren teilweise fehlgeschlagen"),
                            message: failures.joined(separator: ", "), style: .warning)
            }
            isSyncingAll = false
            await loadQueues()
        }
    }

    private func removeQueue(_ item: DriverQueueItem) {
        let name = item.info.name
        performQueueAction(name, title: tr("Warteschlange entfernen"), success: tr("Warteschlange entfernt"),
                           operation: { try await CUPSService.removeQueue(name) },
                           onSuccess: {
                               for session in model.sessions where session.saved.cupsQueueName == name {
                                   session.saved.cupsQueueName = nil
                               }
                           })
    }

    private func setUpQueue(for session: PrinterSession) {
        let saved = session.saved
        let names = queues.map(\.info.name)
        // CUPS unterscheidet bei Warteschlangennamen nicht zwischen Groß- und Kleinschreibung
        // („Lager“ = „lager“): `lpadmin -p` würde sonst die Warteschlange eines anderen Druckers umschreiben.
        let taken = Set(names.map { $0.lowercased() })
        var queueName = CUPSService.sanitizedQueueName(saved.name)
        // Eine vorhandene Warteschlange nur weiterverwenden, wenn sie genau die eigene ist.
        let isOwnQueue = saved.cupsQueueName == queueName && names.contains(queueName)
        if taken.contains(queueName.lowercased()) && !isOwnQueue {
            var index = 2
            while taken.contains("\(queueName)_\(index)".lowercased()) { index += 1 }
            queueName = "\(queueName)_\(index)"
        }
        let requestedName = queueName
        busyPrinters.insert(session.id)
        Task {
            do {
                let name = try await CUPSService.installQueue(for: saved, queueName: requestedName)
                withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
                    session.saved.cupsQueueName = name
                }
                if !reduceMotion { celebration += 1 }
                pulseFlow(4.5)
                if model.preferences.playSounds { SoundService.play(.success) }
                model.toast(tr("Warteschlange eingerichtet"),
                            message: tr("„%@“ steht jetzt in allen Programmen zur Verfügung.", name), style: .success)
            } catch {
                model.toast(tr("Warteschlange konnte nicht eingerichtet werden"),
                            message: PrinterSession.describe(error), style: .error)
            }
            busyPrinters.remove(session.id)
            await loadQueues()
        }
    }

    private func link(_ session: PrinterSession, to queue: String) {
        withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
            session.saved.cupsQueueName = queue
        }
        model.toast(tr("Verknüpft"), message: tr("„%@“ nutzt die Warteschlange „%@“.", session.displayName, queue), style: .success)
    }

    private func uninstall(removingQueues: Bool) {
        let names = removingQueues ? labelWerkQueueNames : []
        Task {
            let ok = await installer.uninstall(removingQueues: names)
            if ok {
                for session in model.sessions {
                    if let queue = session.saved.cupsQueueName, names.contains(queue) {
                        session.saved.cupsQueueName = nil
                    }
                }
            }
            await loadQueues()
        }
    }

    private func openPrintSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Rückfrage vor dem Installieren der älteren Treiberversion aus dem App-Paket.
private struct DriverDowngrade: Equatable {
    let installed: String
    let bundled: String
}

/// Werte einer Warteschlange für „Alle synchronisieren“.
private struct DriverSyncTarget {
    let queue: String
    let settings: PrintSettings
    let stock: LabelStock
    let language: PrinterLanguage
}

// MARK: - Diagnosezeile

private struct DriverCheckRow: View {
    let check: DriverCheck
    let index: Int
    let reduceMotion: Bool

    @State private var appeared = false

    private var tint: Color {
        switch check.outcome {
        case .passed: return Theme.ready
        case .failed: return Theme.error
        case .unknown: return Theme.offline
        }
    }

    private var symbol: String {
        switch check.outcome {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(appeared ? 1 : 0.3)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(check.detail)
                    .font(.system(size: 11.5, design: check.id == "raster" || check.id == "command" ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(Motion.bouncy.delay(Double(index) * 0.07)) { appeared = true }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: check)
    }
}

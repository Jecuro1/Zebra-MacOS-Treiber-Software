import SwiftUI
import LabelWerkKit

// MARK: - Darstellung & Reiter

/// Einsatzort des Suchbereichs: ganze Seite, Sheet „Drucker hinzufügen“ oder kompakt im Onboarding.
enum DiscoveryPanelStyle: Equatable {
    case page
    case sheet
    case compact
}

enum DiscoveryPanelTab: String, CaseIterable, Hashable, Identifiable {
    case search
    case manual
    case demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return tr("Suchen")
        case .manual: return tr("Manuell")
        case .demo: return tr("Demo-Drucker")
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "dot.radiowaves.left.and.right"
        case .manual: return "square.and.pencil"
        case .demo: return "sparkles"
        }
    }
}

// MARK: - Suchbereich

/// Gemeinsamer Suchbereich von `DiscoveryView`, `AddPrinterView` und Onboarding: ruhige Liste mit
/// einer Zeile je gefundenem Drucker (alle Quellen zusammengeführt, `DiscoveryFilter.overview`),
/// kleines Suchsymbol im Kopf – das Radar erscheint groß nur, solange gesucht und noch nichts gefunden
/// wurde –, eine leise Zeile mit Quellen und Netzen, manuelles Hinzufügen und Demo-Drucker.
struct DiscoveryPanel: View {
    let style: DiscoveryPanelStyle
    /// Nach manuellem Hinzufügen, Öffnen eines vorhandenen Druckers oder Demo (z. B. Sheet schließen).
    var onFinished: ((PrinterSession) -> Void)?
    /// Nur kompakt: Wunsch nach manuellem Hinzufügen (öffnet ein eigenes Fenster).
    var onRequestManual: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var tab: DiscoveryPanelTab
    @State private var controller = DiscoveryController()
    /// Editor „Durchsuchte Netze“.
    @State private var showNetworks = false
    /// Suche, die noch auf ihre Optionen wartet (macOS-Warteschlangen, Hostnamen) – abbrechbar.
    @State private var pendingStart: Task<Void, Never>?
    /// „Auch als macOS-Drucker installieren“ (Netzwerk und USB, gemerkt).
    @AppStorage(MacPrinterInstallToggle.storageKey) private var installMacPrinter = true

    init(style: DiscoveryPanelStyle,
         initialTab: DiscoveryPanelTab = .search,
         onFinished: ((PrinterSession) -> Void)? = nil,
         onRequestManual: (() -> Void)? = nil) {
        self.style = style
        self.onFinished = onFinished
        self.onRequestManual = onRequestManual
        _tab = State(initialValue: style == .compact ? .search : initialTab)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        Group {
            if style == .compact {
                compactContent
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    AnimatedTabBar(
                        items: DiscoveryPanelTab.allCases,
                        selection: $tab,
                        title: { $0.title },
                        systemImage: { $0.systemImage }
                    )
                    ZStack(alignment: .top) {
                        tabContent(tab)
                            .id(tab)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 14)),
                                removal: .opacity
                            ))
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: tab)
                }
            }
        }
        .onAppear {
            if controller.scanCount == 0 && !controller.isScanning && tab == .search {
                startSearch()
            }
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .search && controller.scanCount == 0 && !controller.isScanning {
                startSearch()
            }
        }
        .onChange(of: controller.scanCount) { _, _ in
            // Funde der Suche auch für die Seitenleiste („Neue Zebra-Drucker“) übernehmen.
            let sources = controller.lastSources
            model.networkDiscovery.absorb(controller.found, full: sources.contains(.zebra) && sources.contains(.network))
        }
        .onDisappear {
            cancelPendingStart()
            controller.stop()
        }
        .sheet(isPresented: $showNetworks) {
            DiscoveryNetworksSheet(onSearch: { startSearch() })
                .environment(model)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: DiscoveryPanelTab) -> some View {
        switch tab {
        case .search:
            searchContent
        case .manual:
            DiscoveryManualForm(discovered: overview.partition.new) { session in
                onFinished?(session)
            }
        case .demo:
            DiscoveryDemoPane { session in
                onFinished?(session)
            }
        }
    }

    // MARK: Suche (Seite & Sheet)

    private var searchContent: some View {
        let overview = self.overview
        let showsRadar = controller.isScanning && overview.devices.isEmpty && overview.macQueues.isEmpty
        return VStack(alignment: .leading, spacing: 18) {
            header(overview, showsIndicator: !showsRadar)
            sourcesLine(compact: false)

            if showsRadar {
                radarStage
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if !overview.devices.isEmpty || !overview.macQueues.isEmpty {
                VStack(alignment: .leading, spacing: 22) {
                    if !overview.devices.isEmpty {
                        DiscoveryDeviceList(devices: overview.devices, reduceMotion: reduceMotion,
                                            onInstall: installAction) { add($0) }
                    }
                    if !overview.macQueues.isEmpty {
                        macQueuesGroup(overview.macQueues)
                    }
                    footer(overview)
                }
                .transition(.opacity)
            } else if controller.scanCount > 0 {
                emptyResults
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: showsRadar)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: overview.devices.isEmpty)
    }

    /// Kopf: kleines Suchsymbol, „4 neue Zebra-Drucker“, leise „1 bereits hinzugefügt“, Suchknopf.
    private func header(_ overview: DiscoveryOverview, showsIndicator: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if showsIndicator {
                DiscoverySearchIndicator(isScanning: controller.isScanning, size: 36, reduceMotion: reduceMotion)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            statusText(overview, large: true)
            Spacer(minLength: 12)
            if controller.isScanning {
                remainingTime
                    .transition(.opacity)
            }
            scanButton
        }
    }

    /// Großes Radar – nur solange gesucht und noch nichts gefunden wurde.
    private var radarStage: some View {
        VStack(spacing: 14) {
            DiscoveryRadar(
                printers: [],
                isScanning: controller.isScanning,
                startedAt: controller.startedAt,
                duration: controller.duration,
                highlightedID: nil,
                reduceMotion: reduceMotion
            )
            .frame(width: style == .page ? 220 : 190, height: style == .page ? 220 : 190)
            Text(tr("Neue Zebra-Drucker erscheinen hier, sobald sie antworten."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// Kleine Gruppe „Vorhandene macOS-Drucker“: Zebra-/LabelWerk-Warteschlangen ohne gefundenes Gerät.
    private func macQueuesGroup(_ devices: [DiscoveredDevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Vorhandene macOS-Drucker"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .help(tr("Zebra-Drucker, die in macOS eingerichtet sind, aber bei dieser Suche nicht geantwortet haben."))
            DiscoveryDeviceList(devices: devices, compact: true, reduceMotion: reduceMotion) { add($0) }
        }
    }

    /// Fußzeile: „Auch als macOS-Drucker installieren“ als kleines Kästchen.
    @ViewBuilder
    private func footer(_ overview: DiscoveryOverview) -> some View {
        if overview.devices.contains(where: { PrinterInstallRequest.supports($0.preferred.descriptor) }) {
            HStack(spacing: 8) {
                MacPrinterInstallToggle(isOn: $installMacPrinter, compact: true)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        }
    }

    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                tip("power", tr("Ist der Drucker eingeschaltet und zeigt „Bereit“?"))
                tip("wifi", tr("Sind Mac und Drucker im selben Netzwerk bzw. WLAN?"))
                tip("point.3.connected.trianglepath.dotted", tr("Drucker in einem anderen Netz, z. B. über VPN? Unter „Netze …“ das Netz eintragen, etwa 10.62.13.0/24."))
                tip("cable.connector", tr("USB-Kabel direkt anschließen (ohne Hub) und kurz warten."))
                tip("antenna.radiowaves.left.and.right", tr("Für Bluetooth die Quellen „Bluetooth“ bzw. „Bluetooth LE“ aktivieren."))
            }
            HStack(spacing: 8) {
                Button {
                    tab = .manual
                } label: {
                    Label(tr("Manuell hinzufügen"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.labelWerkSecondary)
                Button {
                    tab = .demo
                } label: {
                    Label(tr("Demo-Drucker"), systemImage: "sparkles")
                }
                .buttonStyle(.labelWerkSecondary)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous).fill(Theme.subtleFill))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 16)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: Kompakt (Onboarding)

    private var compactContent: some View {
        let overview = self.overview
        let entries = overview.devices + overview.macQueues
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                DiscoverySearchIndicator(isScanning: controller.isScanning, size: 30, reduceMotion: reduceMotion)
                statusText(overview, large: false)
                Spacer(minLength: 4)
                scanButton
                    .controlSize(.small)
            }
            sourcesLine(compact: true)
            if entries.isEmpty {
                Text(controller.isScanning
                     ? tr("Neue Zebra-Drucker erscheinen hier, sobald sie antworten.")
                     : tr("Noch keine neuen Zebra-Drucker gefunden. Du kannst die Suche wiederholen, den Drucker manuell hinzufügen oder den Demo-Drucker verwenden."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                ScrollView {
                    DiscoveryDeviceList(devices: entries, compact: true, reduceMotion: reduceMotion) { add($0) }
                        .padding(.vertical, 1)
                }
                .frame(maxHeight: 180)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                let demoSession = model.sessions.first { $0.isVirtual }
                if model.preferences.showDemoPrinter || demoSession != nil {
                    Button {
                        let session = model.addDemoPrinter()
                        onFinished?(session)
                    } label: {
                        Label(demoSession == nil ? tr("Demo-Drucker verwenden") : tr("Demo-Drucker ist eingerichtet"),
                              systemImage: demoSession == nil ? "sparkles" : "checkmark.circle.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    .disabled(demoSession != nil)
                }
                if let onRequestManual {
                    Button(action: onRequestManual) {
                        Label(tr("Manuell hinzufügen …"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                MacPrinterInstallToggle(isOn: $installMacPrinter, compact: true)
                if !model.sessions.isEmpty {
                    Label(tr("%d eingerichtet", model.sessions.count), systemImage: "printer.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.ready)
                        .contentTransition(.numericText(value: Double(model.sessions.count)))
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: entries.map(\.id))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: model.sessions.count)
    }

    // MARK: Bausteine

    private func statusText(_ overview: DiscoveryOverview, large: Bool) -> some View {
        // Drucker zählen, nicht Treffer: Ein eingerichteter Drucker taucht oft mehrfach auf
        // (LabelWerk-Warteschlange, Etikettentypen, übernommene Warteschlange, Netzwerk, Bluetooth).
        let hiddenCount = overview.hiddenAddedPrinterCount()
        let title = headline(newCount: overview.devices.count)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(large ? Theme.Typography.headline : .system(size: 13, weight: .semibold, design: .rounded))
                .contentTransition(.numericText(value: Double(overview.devices.count)))
            // Leiser Hinweis: Schon eingerichtete Drucker werden nicht angezeigt (Dubletten).
            if hiddenCount > 0 {
                Text(tr("%d bereits hinzugefügt", hiddenCount))
                    .font(.system(size: large ? 11.5 : 10.5))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(value: Double(hiddenCount)))
                    .help(tr("Drucker, die schon in LabelWerk eingerichtet sind, werden in der Suche nicht angezeigt."))
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: title)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: hiddenCount)
    }

    /// Eine leise Zeile statt der Quellenschalter: „Gesucht über Zebra-Suche, Netzwerk, … · Netze …“;
    /// die Quellen lassen sich im Menü „Quellen“ ein- und ausschalten.
    private func sourcesLine(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Text(tr("Gesucht über %@", DiscoverySourceStyle.summary(controller.sources)))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(DiscoverySourceStyle.summary(controller.sources))
            Text(verbatim: "·").foregroundStyle(.tertiary)
            Menu {
                ForEach(DiscoverySourceStyle.ordered, id: \.self) { source in
                    Toggle(isOn: sourceBinding(source)) {
                        Label(DiscoverySourceStyle.title(source), systemImage: DiscoverySourceStyle.systemImage(source))
                    }
                    .help(DiscoverySourceStyle.detail(source))
                }
            } label: {
                Text(tr("Quellen …"))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Suchquellen wählen"))
            Text(verbatim: "·").foregroundStyle(.tertiary)
            Button {
                showNetworks = true
            } label: {
                Text(networkPlan.networks.isEmpty ? tr("Netze …") : tr("Netze (%d) …", networkPlan.networks.count))
            }
            .buttonStyle(.link)
            .help(networkPlan.networks.isEmpty
                  ? tr("Durchsuchte Netze anzeigen und eigene Netze eintragen (z. B. hinter einem VPN)")
                  : tr("Durchsuchte Netze: %@", DiscoveryNetworkText.summary(networkPlan)))
            Spacer(minLength: 0)
        }
        .font(.system(size: compact ? 11 : 11.5))
        .foregroundStyle(.secondary)
        .tint(Theme.accent)
    }

    private var scanButton: some View {
        Button {
            if controller.isScanning {
                cancelPendingStart()
                controller.stop()
            } else {
                startSearch()
            }
        } label: {
            Label(scanButtonTitle, systemImage: controller.isScanning ? "stop.fill" : "arrow.clockwise")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.labelWerkSecondary)
        .disabled(!controller.isScanning && controller.sources.isEmpty)
        .help(controller.sources.isEmpty ? tr("Mindestens eine Quelle auswählen") : "")
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: controller.isScanning)
    }

    private var scanButtonTitle: String {
        if controller.isScanning { return tr("Suche stoppen") }
        return controller.scanCount > 0 ? tr("Erneut suchen") : tr("Suche starten")
    }

    private var remainingTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = max(0, Int(ceil(controller.duration * (1 - controller.progress(at: timeline.date)))))
            Label(tr("noch %d s", remaining), systemImage: "timer")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    /// Überschrift: zählt Drucker (Geräte), nicht Treffer; schon eingerichtete sind ausgeblendet.
    private func headline(newCount count: Int) -> String {
        if count > 0 { return DiscoveryDeviceText.headline(newCount: count) }
        if controller.isScanning { return tr("Suche läuft …") }
        if controller.scanCount == 0 { return tr("Drucker in der Nähe finden") }
        return tr("Keine neuen Zebra-Drucker gefunden")
    }

    // MARK: Daten & Aktionen

    /// Treffer dieser Suche, ergänzt um die Funde der automatischen Suche (`NetworkDiscoveryService`,
    /// zuletzt gesehen in den letzten 35 Minuten), zu Geräten zusammengeführt und aufgeteilt
    /// (`DiscoveryFilter.overview`): je physischem Drucker ein Eintrag, nur als Zebra erkannte, noch
    /// nicht eingerichtete Drucker; macOS-Warteschlangen ohne gefundenes Gerät getrennt.
    ///
    /// Nur nach Kennung (`id`) entdoppelt, nicht über `DiscoveryRegistry`: Die Registry verwirft z. B.
    /// den Bonjour-Fund eines Druckers, der schon auf die Zebra-Suche geantwortet hat, samt seinem
    /// Dienstnamen – dann fände `DiscoveryFilter.groupDevices` die `dnssd://`-Warteschlange dieses
    /// Druckers nicht mehr. Das Zusammenführen übernimmt die Gruppierung.
    private var overview: DiscoveryOverview {
        var printers = controller.found
        var ids = Set(printers.map(\.id))
        for printer in model.networkDiscovery.recentPrinters where ids.insert(printer.id).inserted {
            printers.append(printer)
        }
        return model.networkDiscovery.overview(printers)
    }

    /// Netze der laufenden bzw. letzten Suche, sonst der automatischen Suche.
    private var networkPlan: DiscoveryPlan {
        controller.plan ?? model.networkDiscovery.plan
    }

    /// Startet die Suche mit den Netzen bekannter Drucker (auch aus den macOS-Warteschlangen) und den
    /// eigenen Netzen.
    ///
    /// Das Lesen der Warteschlangen kann dauern: Ein erneuter Aufruf, „Suche stoppen“ und das Schließen
    /// der Ansicht brechen einen noch nicht gestarteten Suchlauf ab – nie startet danach noch eine Suche,
    /// die niemand mehr sieht.
    private func startSearch() {
        pendingStart?.cancel()
        let service: NetworkDiscoveryService = model.networkDiscovery
        let controller = self.controller
        pendingStart = Task { @MainActor in
            let options = await service.preparedDiscoveryOptions()
            guard !Task.isCancelled else { return }
            controller.start(options: options)
        }
    }

    private func cancelPendingStart() {
        pendingStart?.cancel()
        pendingStart = nil
    }

    private func sourceBinding(_ source: DiscoverySource) -> Binding<Bool> {
        Binding(
            get: { controller.sources.contains(source) },
            set: { isOn in
                if isOn {
                    controller.sources.insert(source)
                } else {
                    controller.sources.remove(source)
                }
            }
        )
    }

    /// Kontextmenü „Drucker installieren …“: Installationsassistent mit diesem Drucker (nur auf der
    /// Seite – im Sheet „Drucker hinzufügen“ führt dessen eigener Knopf zum Assistenten).
    private var installAction: ((DiscoveredDevice) -> Void)? {
        guard style == .page else { return nil }
        let model = self.model
        return { device in model.openInstallWizard(for: device.preferred) }
    }

    /// „Hinzufügen“ eines Geräts über seine beste Verbindung (Netzwerk vor USB vor Bluetooth).
    private func add(_ device: DiscoveredDevice) {
        let printer = device.preferred
        // `AppModel.addPrinter(from:)` vergleicht exakt; hier zählt dasselbe Gerät (keine Dubletten).
        // Die Liste zeigt nur neue Zebra-Drucker – das greift nur, wenn sich der Stand gerade ändert.
        if let existing = device.members.lazy.compactMap({ model.networkDiscovery.addedSession(for: $0) }).first
            ?? model.sessions.first(where: { $0.saved.descriptor.refersToSameDevice(as: printer.descriptor) }) {
            if style == .page {
                model.toast(tr("Bereits eingerichtet"), message: existing.displayName, style: .info)
            }
            return
        }
        let previousSelection = model.selection
        let session = model.addPrinter(from: printer)
        if model.preferences.playSounds { SoundService.play(.success) }
        if MacPrinterInstallToggle.shouldInstall(isOn: installMacPrinter, descriptor: printer.descriptor) {
            PrinterInstallService.installInBackground(for: session, model: model)
        }
        if style == .page {
            // Auf der Suchseite bleiben, damit weitere Drucker hinzugefügt werden können.
            model.selection = previousSelection
            model.toast(tr("Drucker hinzugefügt"), message: session.displayName, style: .success)
        }
    }
}

// MARK: - Demo-Drucker

/// Vorstellung des simulierten Demo-Druckers mit animierter Druckerdarstellung.
struct DiscoveryDemoPane: View {
    let onFinished: (PrinterSession) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var printTrigger = 0
    /// Konfetti nur ohne „Bewegung reduzieren“ (die Komponente kennt nur die Systemeinstellung).
    @State private var burstTrigger = 0
    @State private var appeared = false

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var existing: PrinterSession? { model.sessions.first { $0.isVirtual } }

    var body: some View {
        GlassCard(padding: 24, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.magenta) {
            HStack(alignment: .center, spacing: 30) {
                ZStack {
                    PrinterIllustration(state: .ready, isPrinting: false,
                                        accent: DiscoveryAccentPalette.color(0.78),
                                        category: .desktop, labelAspect: 1.5, printTrigger: printTrigger)
                    CelebrationBurst(trigger: burstTrigger, colors: [Theme.magenta, Theme.violet, Theme.teal])
                }
                .frame(width: 210, height: 230)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Demo-Drucker ausprobieren"))
                            .font(Theme.Typography.title)
                        Text(tr("Ein vollständig simulierter Zebra ZD421t – ideal, um LabelWerk ohne echte Hardware kennenzulernen. Er verhält sich wie ein echter Drucker und lässt sich jederzeit wieder entfernen."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        feature("waveform.path.ecg", tr("Live-Status mit Meldungen wie „Etiketten leer“ oder „Druckkopf offen“"), index: 0)
                        feature("eye", tr("Gedruckte Etiketten werden als Vorschau im Verlauf gezeigt"), index: 1)
                        feature("wrench.and.screwdriver", tr("Alle Werkzeuge, Terminal, Dateien und Einstellungen nutzbar"), index: 2)
                        feature("wand.and.stars", tr("Fehlerzustände per Knopfdruck simulieren"), index: 3)
                    }
                    HStack(spacing: 10) {
                        if let existing {
                            Button {
                                model.selection = .printer(existing.id)
                                onFinished(existing)
                            } label: {
                                Label(tr("Demo-Drucker öffnen"), systemImage: "arrow.right.circle.fill")
                            }
                            .buttonStyle(.labelWerkPrimary)
                        } else {
                            Button {
                                celebrate()
                                let session = model.addDemoPrinter()
                                onFinished(session)
                            } label: {
                                Label(tr("Demo-Drucker hinzufügen"), systemImage: "sparkles")
                            }
                            .buttonStyle(.labelWerkPrimary)
                        }
                        if !reduceMotion {
                            Button {
                                celebrate()
                            } label: {
                                Label(tr("Probedruck ansehen"), systemImage: "printer.dotmatrix.filled.and.paper")
                            }
                            .buttonStyle(.labelWerkSecondary)
                            .transition(.opacity)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            appeared = true
            guard !reduceMotion else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                celebrate()
            }
        }
    }

    /// Probedruck der Darstellung samt Konfetti – nur ohne „Bewegung reduzieren“.
    private func celebrate() {
        guard !reduceMotion else { return }
        printTrigger += 1
        burstTrigger += 1
    }

    private func feature(_ symbol: String, _ text: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -12)
        .animation(reduceMotion ? nil : Motion.spring.delay(0.08 * Double(index) + 0.1), value: appeared)
    }
}

// MARK: - Seite „Drucker suchen“

/// Seite „Drucker suchen“ in der Seitenleiste – ruhig und schmal (höchstens 760 pt breit).
struct DiscoveryView: View {
    /// Größte Breite des Inhalts (wie die Systemeinstellungen).
    static let contentMaxWidth: CGFloat = 760

    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(tr("Drucker suchen"),
                              subtitle: tr("Zebra-Drucker im Netzwerk, per USB und Bluetooth finden und einrichten – auch in anderen Netzen und über VPN."),
                              systemImage: "dot.radiowaves.left.and.right") {
                    if !model.sessions.isEmpty {
                        Label(tr("%d Drucker eingerichtet", model.sessions.count), systemImage: "printer.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(model.sessions.count)))
                    }
                }
                DiscoveryPanel(style: .page)
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.vertical, 28)
            .frame(maxWidth: Self.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background { AnimatedBackground(style: .subtle).ignoresSafeArea() }
        .navigationTitle(tr("Drucker suchen"))
    }
}

// MARK: - Sheet „Drucker hinzufügen“

/// Sheet „Drucker hinzufügen“ (⇧⌘N, Seitenleiste, leere Zustände).
struct AddPrinterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var showInstallWizard = false
    private let initialTab: DiscoveryPanelTab

    init(initialTab: DiscoveryPanelTab = .search) {
        self.initialTab = initialTab
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconBadge(systemImage: "plus.viewfinder", tint: Theme.violet, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Drucker hinzufügen"))
                        .font(Theme.Typography.title)
                    Text(tr("Suchen, manuell einrichten oder den Demo-Drucker ausprobieren."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showInstallWizard = true
                } label: {
                    Label(tr("Drucker installieren …"), systemImage: "printer.filled.and.paper")
                }
                .buttonStyle(.labelWerkSecondary)
                .help(tr("Installationsassistent: Netzwerkdrucker wie unter Windows als macOS-Drucker einrichten"))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.labelWerkPlain)
                .keyboardShortcut(.cancelAction)
                .help(tr("Schließen (Esc)"))
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                DiscoveryPanel(style: .sheet, initialTab: initialTab, onFinished: { _ in close() })
                    .padding(.horizontal, Theme.Metrics.paddingLarge)
                    .padding(.bottom, Theme.Metrics.padding)
                    .frame(maxWidth: DiscoveryView.contentMaxWidth)
                    .frame(maxWidth: .infinity)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Label(tr("%d Drucker eingerichtet", model.sessions.count), systemImage: "printer")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(model.sessions.count)))
                    .animation(Motion.animation(Motion.spring,
                                                reduceMotion: systemReduceMotion || model.preferences.reduceMotion),
                               value: model.sessions.count)
                Spacer()
                Button(action: close) {
                    Text(tr("Fertig")).padding(.horizontal, 10)
                }
                .buttonStyle(.labelWerkPrimary)
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 800, idealWidth: 880, minHeight: 620, idealHeight: 720)
        .background { AnimatedBackground(style: .subtle).ignoresSafeArea() }
        .sheet(isPresented: $showInstallWizard) {
            NetworkPrinterInstallWizard { exit in
                // „Drucker öffnen“ bzw. „Treiber & Warteschlangen“: auch dieses Sheet schließen.
                if exit == .navigated { close() }
            }
            .environment(model)
        }
    }

    private func close() {
        model.isAddPrinterPresented = false
        dismiss()
    }
}

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

/// Gemeinsamer Suchbereich von `DiscoveryView`, `AddPrinterView` und Onboarding: Radar mit
/// Suchstrahl, Quellenschalter, live einfliegende Treffer, manuelles Hinzufügen und Demo-Drucker.
struct DiscoveryPanel: View {
    let style: DiscoveryPanelStyle
    /// Nach manuellem Hinzufügen, Öffnen eines vorhandenen Druckers oder Demo (z. B. Sheet schließen).
    var onFinished: ((PrinterSession) -> Void)?
    /// Nur kompakt: Wunsch nach manuellem Hinzufügen (öffnet ein eigenes Fenster).
    var onRequestManual: (() -> Void)?
    /// Seite & Sheet: Steuerung des umgebenden `ScrollView` (die Trefferkarten liegen darin), damit ein
    /// Klick auf einen Radarpunkt zur Karte scrollt. Kompakt nutzt einen eigenen `ScrollViewReader`.
    var scrollProxy: ScrollViewProxy?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var tab: DiscoveryPanelTab
    @State private var controller = DiscoveryController()
    @State private var highlightedID: String?
    @State private var highlightToken = 0
    /// Editor „Durchsuchte Netze“.
    @State private var showNetworks = false
    /// Suche, die noch auf ihre Optionen wartet (macOS-Warteschlangen, Hostnamen) – abbrechbar.
    @State private var pendingStart: Task<Void, Never>?
    /// „Auch als macOS-Drucker installieren“ (Netzwerk und USB, gemerkt).
    @AppStorage(MacPrinterInstallToggle.storageKey) private var installMacPrinter = true

    init(style: DiscoveryPanelStyle,
         initialTab: DiscoveryPanelTab = .search,
         scrollProxy: ScrollViewProxy? = nil,
         onFinished: ((PrinterSession) -> Void)? = nil,
         onRequestManual: (() -> Void)? = nil) {
        self.style = style
        self.onFinished = onFinished
        self.onRequestManual = onRequestManual
        self.scrollProxy = scrollProxy
        _tab = State(initialValue: style == .compact ? .search : initialTab)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        Group {
            if style == .compact {
                // Die kompakte Trefferliste hat ein eigenes ScrollView – dafür ein eigener Reader.
                ScrollViewReader { proxy in
                    compactContent(proxy)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
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
            // Funde der Suche auch für die Seitenleiste „Im Netzwerk“ übernehmen.
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
            DiscoveryManualForm(discovered: discoveryResults.new) { session in
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
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge,
                      tint: controller.isScanning ? Theme.teal : nil) {
                HStack(alignment: .center, spacing: 26) {
                    radar(scrollProxy)
                        .frame(width: style == .page ? 290 : 240, height: style == .page ? 290 : 240)
                    VStack(alignment: .leading, spacing: 16) {
                        statusText(large: true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("Suchen über"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            sourceToggles(compact: false)
                        }
                        HStack(spacing: 10) {
                            scanButton
                            if controller.isScanning {
                                remainingTime
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            results
        }
    }

    @ViewBuilder
    private var results: some View {
        let printers = discoveryResults.new
        if !printers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Neue Zebra-Drucker"),
                              subtitle: tr("Modelle werden automatisch aus dem Katalog zugeordnet."),
                              systemImage: "printer.fill")
                if printers.contains(where: { PrinterInstallRequest.supports($0.descriptor) }) {
                    MacPrinterInstallToggle(isOn: $installMacPrinter)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
                        .transition(.opacity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: style == .page ? 330 : 300), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(printers) { printer in
                        DiscoveryPrinterCard(
                            printer: printer,
                            isHighlighted: highlightedID == printer.id,
                            appearDelay: controller.appearanceDelays[printer.id] ?? 0,
                            reduceMotion: reduceMotion,
                            onAdd: { add(printer) }
                        )
                        .id(printer.id)
                        // Nach „Hinzufügen“ ist der Drucker eingerichtet und verlässt die Liste.
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .scale(scale: 0.92))
                        ))
                    }
                }
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: printers.map(\.id))
            }
            .transition(.opacity)
        } else if controller.isScanning {
            skeletons
                .transition(.opacity)
        } else if controller.scanCount > 0 {
            emptyResults
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private var skeletons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: style == .page ? 330 : 300), spacing: 14)], spacing: 14) {
            ForEach(0..<3, id: \.self) { index in
                GlassCard(padding: 14) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.subtleFill)
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(Theme.subtleFill).frame(width: 150, height: 10)
                            Capsule().fill(Theme.subtleFill).frame(width: 110, height: 8)
                            Capsule().fill(Theme.subtleFill).frame(width: 170, height: 8)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .shimmering(active: !reduceMotion)
                .opacity(1 - Double(index) * 0.25)
            }
        }
        .accessibilityHidden(true)
    }

    private var emptyResults: some View {
        GlassCard(padding: 20, tint: Theme.warning) {
            HStack(alignment: .top, spacing: 18) {
                IconBadge(systemImage: "magnifyingglass", tint: Theme.warning, size: 44)
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Keine neuen Zebra-Drucker gefunden"))
                        .font(Theme.Typography.headline)
                    VStack(alignment: .leading, spacing: 5) {
                        tip("power", tr("Ist der Drucker eingeschaltet und zeigt „Bereit“?"))
                        tip("wifi", tr("Sind Mac und Drucker im selben Netzwerk bzw. WLAN?"))
                        tip("point.3.connected.trianglepath.dotted", tr("Drucker in einem anderen Netz, z. B. über VPN? Unter „Netze …“ das Netz eintragen, etwa 10.62.13.0/24."))
                        tip("cable.connector", tr("USB-Kabel direkt anschließen (ohne Hub) und kurz warten."))
                        tip("antenna.radiowaves.left.and.right", tr("Für Bluetooth die Quellen „Bluetooth“ bzw. „Bluetooth LE“ aktivieren."))
                    }
                    HStack(spacing: 8) {
                        Button {
                            startSearch()
                        } label: {
                            Label(tr("Erneut suchen"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.labelWerkPrimary)
                        .disabled(controller.sources.isEmpty)
                        .help(controller.sources.isEmpty ? tr("Mindestens eine Quelle auswählen") : "")
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
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    // MARK: Kompakt (Onboarding)

    private func compactContent(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                radar(proxy)
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        statusText(large: false)
                        Spacer(minLength: 4)
                        scanButton
                            .controlSize(.small)
                    }
                    sourceToggles(compact: true)
                    if discoveryResults.new.isEmpty {
                        Text(controller.isScanning
                             ? tr("Neue Zebra-Drucker erscheinen hier, sobald sie antworten.")
                             : tr("Noch keine neuen Zebra-Drucker gefunden. Du kannst die Suche wiederholen, den Drucker manuell hinzufügen oder den Demo-Drucker verwenden."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(discoveryResults.new) { printer in
                                    DiscoveryPrinterCard(
                                        printer: printer,
                                        isHighlighted: highlightedID == printer.id,
                                        appearDelay: controller.appearanceDelays[printer.id] ?? 0,
                                        reduceMotion: reduceMotion,
                                        compact: true,
                                        onAdd: { add(printer) }
                                    )
                                    .id(printer.id)
                                    .transition(.opacity)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 150)
                        .transition(.opacity)
                    }
                }
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
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: discoveryResults.new.map(\.id))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: model.sessions.count)
    }

    // MARK: Bausteine

    private func radar(_ proxy: ScrollViewProxy?) -> some View {
        DiscoveryRadar(
            printers: discoveryResults.new,
            isScanning: controller.isScanning,
            startedAt: controller.startedAt,
            duration: controller.duration,
            highlightedID: highlightedID,
            reduceMotion: reduceMotion
        ) { printer in
            highlight(printer.id, proxy: proxy)
        }
    }

    private func statusText(large: Bool) -> some View {
        let results = discoveryResults
        // Drucker zählen, nicht Treffer: Ein eingerichteter Drucker taucht oft mehrfach auf
        // (LabelWerk-Warteschlange, Etikettentypen, übernommene Warteschlange, Netzwerk-Fund).
        let hiddenCount = results.hiddenAddedPrinterCount()
        return VStack(alignment: .leading, spacing: 4) {
            Text(headline(newCount: results.new.count))
                .font(large ? Theme.Typography.title : Theme.Typography.headline)
                .contentTransition(.opacity)
            Text(subline(isEmpty: results.new.isEmpty))
                .font(.system(size: large ? 13 : 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            // Leiser Hinweis: Schon eingerichtete Drucker werden nicht angezeigt (Dubletten).
            if hiddenCount > 0 {
                Label(tr("%d bereits hinzugefügt", hiddenCount), systemImage: "checkmark.circle")
                    .font(.system(size: large ? 11.5 : 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(value: Double(hiddenCount)))
                    .help(tr("Drucker, die schon in LabelWerk eingerichtet sind, werden in der Suche nicht angezeigt."))
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: headline(newCount: results.new.count))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: hiddenCount)
    }

    private func sourceToggles(compact: Bool) -> some View {
        let printers = discoveryResults.new
        return DiscoveryFlowLayout(spacing: compact ? 6 : 8) {
            ForEach(DiscoverySourceStyle.ordered, id: \.self) { source in
                DiscoverySourceToggle(source: source, isOn: sourceBinding(source),
                                      count: printers.filter { $0.source == source }.count, compact: compact,
                                      reduceMotion: reduceMotion)
            }
            DiscoveryNetworksChip(plan: networkPlan, compact: compact, reduceMotion: reduceMotion) {
                showNetworks = true
            }
        }
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
            Label(scanButtonTitle, systemImage: controller.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(controller.isScanning ? LabelWerkButtonStyle.labelWerkSecondary : LabelWerkButtonStyle.labelWerkPrimary)
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
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    /// Überschrift: zählt nur neue Zebra-Drucker (schon eingerichtete sind ausgeblendet).
    private func headline(newCount count: Int) -> String {
        if controller.isScanning {
            switch count {
            case 0: return tr("Suche läuft …")
            case 1: return tr("Suche läuft … 1 neuer Zebra-Drucker")
            default: return tr("Suche läuft … %d neue Zebra-Drucker", count)
            }
        }
        if controller.scanCount == 0 && count == 0 { return tr("Drucker in der Nähe finden") }
        switch count {
        case 0: return tr("Keine neuen Zebra-Drucker gefunden")
        case 1: return tr("1 neuer Zebra-Drucker gefunden")
        default: return tr("%d neue Zebra-Drucker gefunden", count)
        }
    }

    private func subline(isEmpty: Bool) -> String {
        if controller.isScanning {
            let names = DiscoverySourceStyle.ordered
                .filter { controller.sources.contains($0) }
                .map { DiscoverySourceStyle.title($0) }
                .joined(separator: ", ")
            if let plan = controller.plan, !plan.networks.isEmpty {
                return tr("Durchsucht: %@ – Netze: %@", names, DiscoveryNetworkText.summary(plan))
            }
            return tr("Durchsucht: %@", names)
        }
        if controller.scanCount == 0 {
            return tr("Bonjour, Zebra-Suche, USB, Netzwerk, macOS-Warteschlangen und Bluetooth werden gleichzeitig durchsucht.")
        }
        if isEmpty {
            return tr("Strom, Kabel und Netzwerk prüfen – oder den Drucker manuell hinzufügen.")
        }
        return tr("„Hinzufügen“ richtet den Drucker in LabelWerk ein. Ein Klick auf einen Punkt im Radar zeigt ihn an.")
    }

    // MARK: Daten & Aktionen

    /// Treffer dieser Suche, ergänzt um die Netzwerkdrucker der automatischen Suche
    /// (`NetworkDiscoveryService`, zuletzt gesehen in den letzten 35 Minuten) – zusammengeführt, damit
    /// jeder Drucker nur einmal erscheint – und aufgeteilt (`DiscoveryFilter`): angezeigt werden nur
    /// `new`, also als Zebra erkannte Drucker, die noch nicht in LabelWerk eingerichtet sind.
    private var discoveryResults: DiscoveryFilter.Partition {
        var registry = DiscoveryRegistry(controller.found)
        for printer in model.networkDiscovery.recentPrinters {
            registry.insert(printer)
        }
        return model.networkDiscovery.partition(registry.printers)
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

    /// Bereits eingerichteter Drucker desselben Geräts (gleiche Verbindung, Warteschlange, Adresse,
    /// Seriennummer … – `NetworkDiscoveryService.addedSession(for:)`).
    private func existingSession(for printer: DiscoveredPrinter) -> PrinterSession? {
        model.networkDiscovery.addedSession(for: printer)
            ?? model.sessions.first { $0.saved.descriptor.refersToSameDevice(as: printer.descriptor) }
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

    private func add(_ printer: DiscoveredPrinter) {
        // `AppModel.addPrinter(from:)` vergleicht exakt; hier zählt dasselbe Gerät (keine Dubletten).
        // Die Liste zeigt nur neue Zebra-Drucker – das greift nur, wenn sich der Stand gerade ändert.
        if let existing = existingSession(for: printer) {
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

    /// Hebt einen Treffer kurz hervor (Radar & Karte) und scrollt zu seiner Karte.
    private func highlight(_ id: String, proxy: ScrollViewProxy?) {
        highlightToken += 1
        let token = highlightToken
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
            highlightedID = id
        }
        if let proxy {
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard token == highlightToken else { return }
            withAnimation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion)) {
                highlightedID = nil
            }
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

/// Seite „Drucker suchen“ in der Seitenleiste.
struct DiscoveryView: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                    SectionHeader(tr("Drucker suchen"),
                                  subtitle: tr("Zebra-Drucker per Bonjour, Zebra-Suche, USB, Netzwerk-Scan, macOS-Warteschlange oder Bluetooth finden und einrichten – auch in anderen Netzen und über VPN."),
                                  systemImage: "dot.radiowaves.left.and.right") {
                        if !model.sessions.isEmpty {
                            Label(tr("%d Drucker eingerichtet", model.sessions.count), systemImage: "printer.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: Double(model.sessions.count)))
                        }
                    }
                    // Der Reader umschließt das ScrollView der Seite: Radarpunkte scrollen zu ihrer Karte.
                    DiscoveryPanel(style: .page, scrollProxy: proxy)
                }
                .padding(Theme.Metrics.paddingLarge)
                .frame(maxWidth: Theme.Metrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
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

            ScrollViewReader { proxy in
                ScrollView {
                    DiscoveryPanel(style: .sheet, initialTab: initialTab, scrollProxy: proxy,
                                   onFinished: { _ in close() })
                        .padding(.horizontal, Theme.Metrics.paddingLarge)
                        .padding(.bottom, Theme.Metrics.padding)
                }
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

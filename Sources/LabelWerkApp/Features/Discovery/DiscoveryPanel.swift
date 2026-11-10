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
    /// Nicht als Zebra erkanntes Netzwerkgerät, das erst nach Rückfrage hinzugefügt wird.
    @State private var pendingUnidentified: DiscoveredPrinter?
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
                controller.start()
            }
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .search && controller.scanCount == 0 && !controller.isScanning {
                controller.start()
            }
        }
        .onDisappear { controller.stop() }
        .confirmationDialog(
            tr("„%@“ wurde nicht als Zebra-Drucker erkannt", pendingUnidentified?.name ?? ""),
            isPresented: Binding(get: { pendingUnidentified != nil }, set: { if !$0 { pendingUnidentified = nil } }),
            titleVisibility: .visible,
            presenting: pendingUnidentified
        ) { printer in
            Button(tr("Trotzdem hinzufügen")) { add(printer, confirmed: true) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { _ in
            Text(DiscoveryMatcher.unidentifiedWarning)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: DiscoveryPanelTab) -> some View {
        switch tab {
        case .search:
            searchContent
        case .manual:
            DiscoveryManualForm(discovered: controller.found) { session in
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
        if !controller.found.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Gefundene Drucker"),
                              subtitle: tr("Modelle werden automatisch aus dem Katalog zugeordnet."),
                              systemImage: "printer.fill") {
                    let addedCount = addedIDs.count
                    if addedCount > 0 {
                        Label(tr("%d hinzugefügt", addedCount), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ready)
                            .contentTransition(.numericText(value: Double(addedCount)))
                    }
                }
                if controller.found.contains(where: { PrinterInstallRequest.supports($0.descriptor) }) {
                    MacPrinterInstallToggle(isOn: $installMacPrinter)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
                        .transition(.opacity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: style == .page ? 330 : 300), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(controller.found) { printer in
                        let openAction: (() -> Void)? = style == .page ? { open(printer) } : nil
                        DiscoveryPrinterCard(
                            printer: printer,
                            isAdded: addedIDs.contains(printer.id),
                            isHighlighted: highlightedID == printer.id,
                            appearDelay: controller.appearanceDelays[printer.id] ?? 0,
                            reduceMotion: reduceMotion,
                            onAdd: { add(printer) },
                            onOpen: openAction
                        )
                        .id(printer.id)
                        .transition(.opacity)
                    }
                }
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
                    Text(tr("Kein Drucker gefunden"))
                        .font(Theme.Typography.headline)
                    VStack(alignment: .leading, spacing: 5) {
                        tip("power", tr("Ist der Drucker eingeschaltet und zeigt „Bereit“?"))
                        tip("wifi", tr("Sind Mac und Drucker im selben Netzwerk bzw. WLAN?"))
                        tip("cable.connector", tr("USB-Kabel direkt anschließen (ohne Hub) und kurz warten."))
                        tip("antenna.radiowaves.left.and.right", tr("Für Bluetooth die Quellen „Bluetooth“ bzw. „Bluetooth LE“ aktivieren."))
                    }
                    HStack(spacing: 8) {
                        Button {
                            controller.start()
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
                    if controller.found.isEmpty {
                        Text(controller.isScanning
                             ? tr("Gefundene Drucker erscheinen hier, sobald sie antworten.")
                             : tr("Noch keine Drucker gefunden. Du kannst die Suche wiederholen, den Drucker manuell hinzufügen oder den Demo-Drucker verwenden."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(controller.found) { printer in
                                    DiscoveryPrinterCard(
                                        printer: printer,
                                        isAdded: addedIDs.contains(printer.id),
                                        isHighlighted: highlightedID == printer.id,
                                        appearDelay: controller.appearanceDelays[printer.id] ?? 0,
                                        reduceMotion: reduceMotion,
                                        compact: true,
                                        onAdd: { add(printer) },
                                        onOpen: nil
                                    )
                                    .id(printer.id)
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
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: controller.found.isEmpty)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: model.sessions.count)
    }

    // MARK: Bausteine

    private func radar(_ proxy: ScrollViewProxy?) -> some View {
        DiscoveryRadar(
            printers: controller.found,
            isScanning: controller.isScanning,
            startedAt: controller.startedAt,
            duration: controller.duration,
            addedIDs: addedIDs,
            highlightedID: highlightedID,
            reduceMotion: reduceMotion
        ) { printer in
            highlight(printer.id, proxy: proxy)
        }
    }

    private func statusText(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(large ? Theme.Typography.title : Theme.Typography.headline)
                .contentTransition(.opacity)
            Text(subline)
                .font(.system(size: large ? 13 : 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: headline)
    }

    private func sourceToggles(compact: Bool) -> some View {
        DiscoveryFlowLayout(spacing: compact ? 6 : 8) {
            ForEach(DiscoverySourceStyle.ordered, id: \.self) { source in
                DiscoverySourceToggle(source: source, isOn: sourceBinding(source),
                                      count: controller.count(for: source), compact: compact,
                                      reduceMotion: reduceMotion)
            }
        }
    }

    private var scanButton: some View {
        Button {
            if controller.isScanning {
                controller.stop()
            } else {
                controller.start()
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

    private var headline: String {
        let count = controller.found.count
        if controller.isScanning {
            return count == 0 ? tr("Suche läuft …") : tr("Suche läuft … %d gefunden", count)
        }
        if controller.scanCount == 0 { return tr("Drucker in der Nähe finden") }
        return count == 0 ? tr("Keine Drucker gefunden") : tr("%d Drucker gefunden", count)
    }

    private var subline: String {
        if controller.isScanning {
            let names = DiscoverySourceStyle.ordered
                .filter { controller.sources.contains($0) }
                .map { DiscoverySourceStyle.title($0) }
                .joined(separator: ", ")
            return tr("Durchsucht: %@", names)
        }
        if controller.scanCount == 0 {
            return tr("Bonjour, USB, Netzwerk, macOS-Warteschlangen und Bluetooth werden gleichzeitig durchsucht.")
        }
        if controller.found.isEmpty {
            return tr("Strom, Kabel und Netzwerk prüfen – oder den Drucker manuell hinzufügen.")
        }
        return tr("„Hinzufügen“ richtet den Drucker in LabelWerk ein. Ein Klick auf einen Punkt im Radar zeigt ihn an.")
    }

    // MARK: Daten & Aktionen

    /// IDs gefundener Drucker, die bereits eingerichtet sind. Verglichen wird über
    /// `ConnectionDescriptor.stableID` – ein anderer Bluetooth-Name oder USB-Anschluss ist dasselbe Gerät.
    private var addedIDs: Set<String> {
        let stableIDs = Set(model.sessions.map { $0.saved.descriptor.stableID })
        return Set(controller.found.filter { stableIDs.contains($0.descriptor.stableID) }.map(\.id))
    }

    private func existingSession(for printer: DiscoveredPrinter) -> PrinterSession? {
        model.sessions.first { $0.saved.descriptor.refersToSameDevice(as: printer.descriptor) }
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

    private func add(_ printer: DiscoveredPrinter, confirmed: Bool = false) {
        // `AppModel.addPrinter(from:)` vergleicht exakt; hier zählt dasselbe Gerät (keine Dubletten).
        if let existing = existingSession(for: printer) {
            if style == .page {
                model.toast(tr("Bereits eingerichtet"), message: existing.displayName, style: .info)
            }
            highlight(printer.id, proxy: scrollProxy)
            return
        }
        // Hinzufügen verbindet sofort und fragt den Status ab (`~HI`, `~HS` …). Ein nicht als Zebra
        // erkanntes Gerät könnte ein Bürodrucker sein, der das als Seiten ausdruckt – erst nachfragen.
        if !confirmed && DiscoveryMatcher.isUnidentified(printer) {
            pendingUnidentified = printer
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
        highlight(printer.id, proxy: nil)
    }

    private func open(_ printer: DiscoveredPrinter) {
        guard let session = existingSession(for: printer) else { return }
        model.selection = .printer(session.id)
        onFinished?(session)
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
                                  subtitle: tr("Zebra-Drucker per Bonjour, USB, Netzwerk-Scan, macOS-Warteschlange oder Bluetooth finden und einrichten."),
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

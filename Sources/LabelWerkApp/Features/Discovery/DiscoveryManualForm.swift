import SwiftUI
import LabelWerkKit

/// Manuelles Hinzufügen: Verbindung (Netzwerk mit Erreichbarkeitsprüfung, macOS-Warteschlange,
/// USB, Bluetooth), Modell aus dem Katalog (gruppiert, durchsuchbar, mit Kenndaten), Auflösung,
/// Sprache, Etikett, Name, Standort und Akzentfarbe – mit Live-Vorschau.
struct DiscoveryManualForm: View {
    /// Bereits gefundene Drucker (aus der Suche), z. B. für die USB-/Bluetooth-Auswahl.
    let discovered: [DiscoveredPrinter]
    /// Wird nach dem Hinzufügen (oder beim Öffnen eines bereits eingerichteten Druckers) aufgerufen.
    let onComplete: (PrinterSession) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var draft = DiscoveryManualDraft()
    @State private var reachability: DiscoveryReachability = .idle
    @State private var queues: [CUPSQueueInfo] = []
    @State private var isLoadingQueues = false
    @State private var queuesLoaded = false
    @State private var showAllQueues = false
    @State private var deviceScanner = DiscoveryController(sources: [.usb, .bluetooth, .ble], persistsSources: false)
    @State private var modelSearch = ""
    @State private var interfaces: [NetworkInterfaceInfo] = []
    @State private var didPrepare = false
    @State private var addPulse = 0
    /// „Auch als macOS-Drucker installieren“ (Netzwerk und USB, gemerkt).
    @AppStorage(MacPrinterInstallToggle.storageKey) private var installMacPrinter = true
    @Namespace private var namespace

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
            VStack(spacing: Theme.Metrics.cardSpacing) {
                connectionCard
                modelCard
            }
            .frame(minWidth: 360, maxWidth: .infinity)

            VStack(spacing: Theme.Metrics.cardSpacing) {
                previewCard
                settingsCard
                addArea
            }
            .frame(width: 300)
        }
        .onAppear(perform: handleAppear)
        // Bluetooth-Inquiry und BLE-Scan nicht im Hintergrund weiterlaufen lassen (Reiterwechsel, Sheet zu).
        .onDisappear { deviceScanner.stop() }
        .onChange(of: draft.connection) { _, connection in
            draft.deviceID = nil
            prepare(for: connection)
        }
        .task(id: probeKey) {
            await autoProbe()
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: draft.connection)
    }

    // MARK: - Verbindung

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Verbindung"), subtitle: tr("Wie ist der Drucker mit diesem Mac verbunden?"),
                              systemImage: "point.3.connected.trianglepath.dotted")
                AnimatedTabBar(
                    items: DiscoveryManualDraft.Connection.allCases,
                    selection: $draft.connection,
                    title: { $0.title },
                    systemImage: { $0.systemImage }
                )
                Group {
                    switch draft.connection {
                    case .network: networkFields
                    case .queue: queueFields
                    case .usb: usbFields
                    case .bluetooth: bluetoothFields
                    }
                }
                .id(draft.connection)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
    }

    private var networkFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField(tr("IP-Adresse oder Hostname"), text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(normalizeHost)
                Text(verbatim: ":")
                    .foregroundStyle(.secondary)
                TextField(tr("Port"), value: $draft.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .help(tr("Rohdatenport des Druckers (Standard 9100)"))
            }
            HStack(spacing: 10) {
                reachabilityBadge
                Spacer(minLength: 4)
                Button {
                    Task { await checkReachability() }
                } label: {
                    Label(tr("Verbindung prüfen"), systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                .disabled(reachability == .checking || !DiscoveryInput.isPlausibleHost(DiscoveryInput.split(draft.host).host))
            }
            if !interfaces.isEmpty {
                Label(tr("Dieser Mac: %@", interfaces.map { "\($0.address) (\($0.name))" }.joined(separator: ", ")),
                      systemImage: "laptopcomputer")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(tr("Zebra-Drucker empfangen Druckdaten auf Port 9100 (einige Modelle zusätzlich auf 6101). Die IP-Adresse steht auf dem Konfigurationsetikett des Druckers."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var reachabilityBadge: some View {
        switch reachability {
        case .idle:
            Label(tr("Noch nicht geprüft"), systemImage: "circle.dashed")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Verbindung wird geprüft …"))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .transition(.opacity)
        case .reachable(let milliseconds):
            Label(tr("Erreichbar · %d ms", milliseconds), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ready)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : milliseconds)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .unreachable(let message):
            Label(tr("Nicht erreichbar"), systemImage: "xmark.octagon.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.error)
                .help(message)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var queueFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingQueues && queues.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Warteschlangen werden gelesen …"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if queues.isEmpty {
                DiscoveryInlineNote(systemImage: "tray",
                                    text: tr("In macOS ist noch keine Druckerwarteschlange eingerichtet."))
            } else {
                ForEach(visibleQueues, id: \.name) { queue in
                    queueRow(queue)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !zebraQueues.isEmpty && !otherQueues.isEmpty {
                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            showAllQueues.toggle()
                        }
                    } label: {
                        Label(showAllQueues
                              ? tr("Nur Zebra-Warteschlangen anzeigen")
                              : tr("Alle Warteschlangen anzeigen (%d weitere)", otherQueues.count),
                              systemImage: showAllQueues ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.small)
                    .help(tr("Warteschlangen ohne erkennbaren Zebra-Drucker (z. B. Büro- oder Tintenstrahldrucker)"))
                }
                if let selected = selectedQueue, !selected.looksLikeZebra {
                    DiscoveryInlineNote(
                        systemImage: "exclamationmark.triangle.fill",
                        text: tr("„%@“ wurde nicht als Zebra-Drucker erkannt. LabelWerk sendet Etikettendaten (ZPL, EPL oder CPCL) als Rohdaten – ein Büro- oder Tintenstrahldrucker würde stattdessen Seiten voller Steuerzeichen drucken. Nur auswählen, wenn diese Warteschlange zu einem Zebra-Drucker führt.", selected.name),
                        tint: Theme.warning
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            HStack(spacing: 8) {
                Button {
                    Task { await loadQueues() }
                } label: {
                    Label(tr("Aktualisieren"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkPlain)
                .controlSize(.small)
                .disabled(isLoadingQueues)
                Spacer(minLength: 0)
            }
            DiscoveryInlineNote(systemImage: "info.circle",
                                text: tr("Über eine Warteschlange sendet LabelWerk Rohdaten an CUPS. Live-Status und Gerätewerkzeuge sind damit nicht verfügbar."))
        }
    }

    private func queueRow(_ queue: CUPSQueueInfo) -> some View {
        let isZebra = queue.looksLikeZebra
        let detail = DiscoveryMatcher.model(for: queue)?.displayName ?? queue.makeAndModel ?? queue.deviceURI
        let symbol = isZebra ? (queue.isDefault ? "star.circle.fill" : "printer") : "exclamationmark.triangle.fill"
        return DiscoveryOptionRow(
            title: queue.name,
            subtitle: isZebra ? detail : tr("Kein Zebra-Drucker erkannt · %@", detail),
            systemImage: symbol,
            tint: isZebra ? nil : Theme.warning,
            isSelected: draft.queueName == queue.name,
            namespace: namespace
        ) {
            selectQueue(queue)
        }
        .help(isZebra
              ? queue.deviceURI
              : tr("Diese Warteschlange gehört vermutlich nicht zu einem Zebra-Drucker. Etikettendaten würden dort als unlesbare Seiten gedruckt."))
    }

    private var usbFields: some View {
        deviceFields(devices: usbDevices,
                     sources: [.usb],
                     emptyText: tr("Kein USB-Drucker gefunden. Ist der Drucker eingeschaltet und das Kabel angeschlossen?"),
                     searchingText: tr("USB-Geräte werden gesucht …"))
    }

    private var bluetoothFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceFields(devices: bluetoothDevices,
                         sources: [.bluetooth, .ble],
                         emptyText: tr("Keine Bluetooth-Drucker in Reichweite gefunden. Bluetooth am Drucker aktivieren und ihn sichtbar machen."),
                         searchingText: tr("Bluetooth-Geräte werden gesucht …"))
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Oder Adresse eingeben"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(tr("z. B. AC:3F:A4:12:34:56"), text: $draft.bluetoothAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typography.code)
                        .onChange(of: draft.bluetoothAddress) { _, newValue in
                            if !newValue.isEmpty { draft.deviceID = nil }
                        }
                    if !draft.bluetoothAddress.isEmpty {
                        let valid = DiscoveryInput.normalizedBluetoothAddress(draft.bluetoothAddress) != nil
                        Image(systemName: valid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(valid ? Theme.ready : Theme.warning)
                            .contentTransition(.symbolEffect(.replace))
                            .help(valid ? tr("Gültige Adresse") : tr("Sechs Hex-Paare, getrennt durch Doppelpunkte oder Bindestriche"))
                    }
                }
                Text(tr("Die Bluetooth-Adresse steht auf dem Konfigurationsetikett (Taste „Feed“ beim Einschalten gedrückt halten)."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceFields(devices: [DiscoveredPrinter], sources: Set<DiscoverySource>,
                              emptyText: String, searchingText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if devices.isEmpty {
                if deviceScanner.isScanningAny(of: sources) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(searchingText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    DiscoveryInlineNote(systemImage: "magnifyingglass", text: emptyText)
                }
            } else {
                ForEach(devices) { device in
                    DiscoveryOptionRow(
                        title: device.name,
                        subtitle: DiscoveryMatcher.modelLine(for: device) ?? device.descriptor.displayString,
                        systemImage: device.descriptor.systemImage,
                        isSelected: draft.deviceID == device.id,
                        namespace: namespace
                    ) {
                        selectDevice(device)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            HStack(spacing: 8) {
                Button {
                    deviceScanner.start(sources: sources)
                } label: {
                    Label(deviceScanner.isScanningAny(of: sources) ? tr("Suche läuft …") : tr("Erneut suchen"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.labelWerkPlain)
                .controlSize(.small)
                .disabled(deviceScanner.isScanningAny(of: sources))
                if deviceScanner.isScanningAny(of: sources) && !devices.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: devices.map(\.id))
    }

    // MARK: - Modell

    private var modelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Modell"), subtitle: tr("Bestimmt Druckbreite, Auflösungen, Sprachen und passende Etiketten."),
                              systemImage: "printer")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(tr("Modell suchen (z. B. ZD421, ZT411, ZQ630)"), text: $modelSearch)
                        .textFieldStyle(.plain)
                    if !modelSearch.isEmpty {
                        Button {
                            modelSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
                .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: modelSearch.isEmpty)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                            if modelSearch.isEmpty {
                                genericModelRow
                            }
                            ForEach(groupedModels) { group in
                                Section {
                                    ForEach(group.models) { printerModel in
                                        modelRow(printerModel)
                                            .id(printerModel.id)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Text(tr(group.category.displayName))
                                        Text(group.models.count.formatted())
                                            .foregroundStyle(.tertiary)
                                        Spacer()
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial)
                                }
                            }
                            if groupedModels.isEmpty {
                                Text(tr("Kein Modell gefunden."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onAppear {
                        if let id = draft.modelID { proxy.scrollTo(id, anchor: .center) }
                    }
                }

                if let printerModel = selectedModel {
                    DiscoveryModelSpecs(printerModel: printerModel)
                        .id(printerModel.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: draft.modelID)
    }

    private var genericModelRow: some View {
        let isSelected = draft.modelID == nil
        return Button {
            selectModel(nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.square.dashed")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Unbekanntes Modell"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(tr("Allgemeine Werte – wird beim Verbinden automatisch erkannt"))
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brandGradient)
                        .matchedGeometryEffect(id: "modelSelection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ printerModel: PrinterModel) -> some View {
        let isSelected = draft.modelID == printerModel.id
        let dpis = printerModel.supportedResolutions.map { String($0.dpi) }.joined(separator: "/")
        return Button {
            selectModel(printerModel)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: printerModel.systemImage)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(printerModel.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: "\(printerModel.family) · \(dpis) dpi · \(Int(printerModel.printWidthMM)) mm")
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
                if printerModel.supports(.linkOS) {
                    Text(verbatim: "Link-OS")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Theme.teal.opacity(0.15)))
                        .foregroundStyle(isSelected ? Color.white : Theme.teal)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brandGradient)
                        .matchedGeometryEffect(id: "modelSelection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Vorschau

    private var previewCard: some View {
        let accent = DiscoveryAccentPalette.color(draft.accentHue)
        let aspect = labelAspect
        return GlassCard(padding: 14, tint: accent) {
            VStack(spacing: 10) {
                PrinterIllustration(state: .ready, isPrinting: false, accent: accent,
                                    category: selectedModel?.category ?? .desktop,
                                    labelAspect: aspect, printTrigger: addPulse)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    IconBadge(systemImage: selectedModel?.systemImage ?? "printer", tint: accent, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(effectiveName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        Text(previewSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: draft.accentHue)
    }

    private var previewSubtitle: String {
        let connection = currentDescriptor?.displayString ?? tr("Verbindung fehlt")
        if let printerModel = selectedModel {
            return "\(printerModel.name) · \(connection)"
        }
        return connection
    }

    // MARK: - Einstellungen

    private var settingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Einrichtung"), systemImage: "slider.horizontal.3")

                field(tr("Name")) {
                    TextField(tr("Name"), text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                }
                field(tr("Standort (optional)")) {
                    TextField(tr("z. B. Versand, Lager 2"), text: $draft.location)
                        .textFieldStyle(.roundedBorder)
                }
                field(tr("Auflösung")) {
                    Picker(tr("Auflösung"), selection: $draft.resolution) {
                        ForEach(resolutionOptions) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field(tr("Druckersprache")) {
                    Picker(tr("Druckersprache"), selection: $draft.language) {
                        ForEach(languageOptions) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field(tr("Etikett")) {
                    // Vorhandenes Format oder „Benutzerdefiniert …“ (z. B. 104 × 76,2 mm) – wird beim
                    // Hinzufügen ein eigenes Format und Standard-Papiergröße des macOS-Druckers.
                    LabelStockChooser(choice: stockChoiceBinding, entry: $draft.customSize,
                                      stocks: stockOptions, limits: stockLimits, reduceMotion: reduceMotion)
                }
                field(tr("Farbe")) {
                    DiscoveryFlowLayout(spacing: 5) {
                        ForEach(DiscoveryAccentPalette.hues, id: \.self) { hue in
                            accentSwatch(hue)
                        }
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func accentSwatch(_ hue: Double) -> some View {
        let isSelected = abs(draft.accentHue - hue) < 0.001
        return Button {
            withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
                draft.accentHue = hue
            }
        } label: {
            Circle()
                .fill(LinearGradient(colors: [DiscoveryAccentPalette.color(hue), DiscoveryAccentPalette.color(hue).opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 17, height: 17)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8))
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.75), lineWidth: 2)
                            .matchedGeometryEffect(id: "accentRing", in: namespace)
                    }
                }
                .scaleEffect(isSelected ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Akzentfarbe"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Hinzufügen

    private var addArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let existing = existingSession {
                DiscoveryInlineNote(systemImage: "checkmark.seal",
                                    text: tr("Dieser Drucker ist bereits als „%@“ eingerichtet.", existing.displayName))
                Button {
                    model.selection = .printer(existing.id)
                    onComplete(existing)
                } label: {
                    Label(tr("Drucker öffnen"), systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.large)
            } else {
                if draft.connection == .network || draft.connection == .usb {
                    MacPrinterInstallToggle(isOn: $installMacPrinter)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
                        .transition(.opacity)
                }
                Button(action: add) {
                    Label(tr("Drucker hinzufügen"), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.large)
                .disabled(currentDescriptor == nil || !isStockValid)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(tr("Drucker hinzufügen (⌘↩)"))
                if let message = validationMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: existingSession?.id)
    }

    // MARK: - Abgeleitete Werte

    private var selectedModel: PrinterModel? {
        draft.modelID.flatMap { model.catalog.model(id: $0) }
    }

    private var groupedModels: [DiscoveryModelGroup] {
        let needle = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PrinterCategory.allCases.compactMap { category -> DiscoveryModelGroup? in
            let models = model.catalog.models(in: category).filter { printerModel in
                needle.isEmpty
                    || printerModel.name.lowercased().contains(needle)
                    || printerModel.family.lowercased().contains(needle)
                    || printerModel.id.contains(needle)
            }
            return models.isEmpty ? nil : DiscoveryModelGroup(category: category, models: models)
        }
    }

    private var resolutionOptions: [Resolution] {
        let supported = selectedModel?.supportedResolutions ?? []
        return supported.isEmpty ? Resolution.allCases : supported
    }

    private var languageOptions: [PrinterLanguage] {
        let supported = selectedModel?.languages ?? []
        return supported.isEmpty ? PrinterLanguage.allCases : supported
    }

    private func stocks(for printerModel: PrinterModel?) -> [LabelStock] {
        let all = model.allStocks
        guard let printerModel else { return all }
        let fitting = all.filter {
            $0.widthMM <= printerModel.printWidthMM + 2 && $0.heightMM <= printerModel.maxLabelLengthMM
        }
        return fitting.isEmpty ? all : fitting
    }

    private var availableStocks: [LabelStock] { stocks(for: selectedModel) }

    /// Formate der Auswahl (passend zum Modell und das gewählte).
    private var stockOptions: [LabelStock] {
        var list = availableStocks
        if !list.contains(where: { $0.id == draft.stockID }), let stock = model.stock(id: draft.stockID) {
            list.append(stock)
        }
        return list
    }

    /// Erlaubte Größe für „Benutzerdefiniert …“ (Modell).
    private var stockLimits: LabelSizing.Limits { LabelSizing.Limits(model: selectedModel) }

    /// Eingegebene Größe, falls „Benutzerdefiniert …“ gewählt und gültig.
    private var customSize: (widthMM: Double, heightMM: Double)? {
        draft.usesCustomSize ? draft.customSize.size(in: stockLimits) : nil
    }

    /// Ist das Etikett gültig (vorhandenes Format oder gültige eigene Größe)?
    private var isStockValid: Bool {
        draft.usesCustomSize ? customSize != nil : model.stock(id: draft.stockID) != nil
    }

    /// Seitenverhältnis des Etiketts für die Vorschau.
    private var labelAspect: CGFloat {
        if let size = customSize { return CGFloat(size.heightMM / max(size.widthMM, 1)) }
        guard !draft.usesCustomSize, let stock = model.stock(id: draft.stockID) else { return 1.5 }
        return CGFloat(stock.heightMM / max(stock.widthMM, 1))
    }

    private var stockChoiceBinding: Binding<LabelStockChoice> {
        Binding(
            get: { draft.usesCustomSize ? .custom : .stock(draft.stockID) },
            set: { choice in
                withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                    switch choice {
                    case .custom:
                        if draft.customSize.isEmpty, let stock = model.stock(id: draft.stockID) {
                            // Mit dem bisherigen Format vorbelegen – meist ist nur noch anzupassen.
                            draft.customSize = LabelSizeEntry(widthMM: stock.widthMM, heightMM: stock.heightMM,
                                                              tracking: stock.tracking)
                        }
                        draft.usesCustomSize = true
                    case .stock(let id):
                        draft.usesCustomSize = false
                        draft.stockID = id
                    case .printer:
                        break
                    }
                }
            }
        )
    }

    private var knownDevices: [DiscoveredPrinter] {
        var seen = Set<String>()
        var result: [DiscoveredPrinter] = []
        for printer in discovered + deviceScanner.found where seen.insert(printer.id).inserted {
            result.append(printer)
        }
        return result
    }

    private var usbDevices: [DiscoveredPrinter] {
        knownDevices.filter { $0.descriptor.kind == .usb }
    }

    private var bluetoothDevices: [DiscoveredPrinter] {
        knownDevices.filter { $0.descriptor.kind == .bluetooth || $0.descriptor.kind == .ble }
    }

    private var selectedDevice: DiscoveredPrinter? {
        guard let id = draft.deviceID else { return nil }
        return knownDevices.first { $0.id == id }
    }

    private var currentDescriptor: ConnectionDescriptor? {
        switch draft.connection {
        case .network:
            let target = DiscoveryInput.split(draft.host)
            let port = target.port ?? draft.port
            guard DiscoveryInput.isPlausibleHost(target.host), (1...65535).contains(port) else { return nil }
            return .tcp(host: target.host, port: port)
        case .queue:
            guard let name = draft.queueName, queues.contains(where: { $0.name == name }) else { return nil }
            return .cupsQueue(name: name)
        case .usb:
            guard let device = selectedDevice, device.descriptor.kind == .usb else { return nil }
            return device.descriptor
        case .bluetooth:
            if let device = selectedDevice,
               device.descriptor.kind == .bluetooth || device.descriptor.kind == .ble {
                return device.descriptor
            }
            guard let address = DiscoveryInput.normalizedBluetoothAddress(draft.bluetoothAddress) else { return nil }
            return .bluetooth(address: address, name: nil)
        }
    }

    /// Bereits eingerichteter Drucker mit derselben Verbindung – verglichen über `stableID`, damit
    /// Name (Bluetooth) oder Anschluss/Produktname (USB) keine Dubletten erzeugen.
    private var existingSession: PrinterSession? {
        guard let descriptor = currentDescriptor else { return nil }
        return model.sessions.first { $0.saved.descriptor.refersToSameDevice(as: descriptor) }
    }

    private var zebraQueues: [CUPSQueueInfo] { queues.filter(\.looksLikeZebra) }

    private var otherQueues: [CUPSQueueInfo] { queues.filter { !$0.looksLikeZebra } }

    /// Zebra-/LabelWerk-Warteschlangen zuerst; andere nur auf Wunsch (oder wenn sie gewählt sind
    /// bzw. keine Zebra-Warteschlange erkannt wurde – z. B. Rohdaten-Warteschlange per IP).
    private var visibleQueues: [CUPSQueueInfo] {
        if zebraQueues.isEmpty || showAllQueues { return zebraQueues + otherQueues }
        return zebraQueues + otherQueues.filter { $0.name == draft.queueName }
    }

    private var selectedQueue: CUPSQueueInfo? {
        guard let name = draft.queueName else { return nil }
        return queues.first { $0.name == name }
    }

    private var validationMessage: String? {
        guard currentDescriptor == nil else {
            return isStockValid ? nil : tr("Bitte Breite und Höhe des Etiketts prüfen.")
        }
        switch draft.connection {
        case .network: return tr("Bitte IP-Adresse oder Hostnamen des Druckers eingeben.")
        case .queue: return tr("Bitte eine macOS-Warteschlange auswählen.")
        case .usb: return tr("Bitte einen gefundenen USB-Drucker auswählen.")
        case .bluetooth: return tr("Bitte ein Gerät auswählen oder eine gültige Bluetooth-Adresse eingeben.")
        }
    }

    private var suggestedName: String {
        let base: String
        if let printerModel = selectedModel {
            base = printerModel.displayName
        } else {
            switch draft.connection {
            case .network:
                let host = DiscoveryInput.split(draft.host).host
                base = host.isEmpty ? tr("Zebra-Drucker") : host
            case .queue:
                base = draft.queueName ?? tr("Zebra-Drucker")
            case .usb, .bluetooth:
                base = selectedDevice?.name ?? tr("Zebra-Drucker")
            }
        }
        return uniqueName(base)
    }

    private var effectiveName: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.nameEdited && !trimmed.isEmpty ? trimmed : suggestedName
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.nameEdited ? draft.name : suggestedName },
            set: { newValue in
                draft.name = newValue
                draft.nameEdited = true
            }
        )
    }

    private var probeKey: String {
        "\(draft.connection.rawValue)|\(draft.host)|\(draft.port)"
    }

    private func uniqueName(_ base: String) -> String {
        let existing = Set(model.sessions.map(\.displayName))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Aktionen

    private func handleAppear() {
        guard !didPrepare else {
            // Erneut sichtbar (die Gerätesuche wurde beim Verschwinden beendet): bei Bedarf fortsetzen.
            prepare(for: draft.connection)
            return
        }
        didPrepare = true
        draft.accentHue = AppModel.nextAccentHue(after: model.sessions.count)
        interfaces = SubnetScanner.localIPv4Interfaces()
        let initialStocks = availableStocks
        if !initialStocks.contains(where: { $0.id == draft.stockID }) {
            draft.stockID = initialStocks.first?.id ?? draft.stockID
        }
        prepare(for: draft.connection)
    }

    private func prepare(for connection: DiscoveryManualDraft.Connection) {
        switch connection {
        case .network:
            deviceScanner.stop()
        case .queue:
            deviceScanner.stop()
            if !queuesLoaded { Task { await loadQueues() } }
        case .usb:
            // Eine noch laufende Bluetooth-Suche wird durch die USB-Suche ersetzt (und umgekehrt).
            if usbDevices.isEmpty && !deviceScanner.isScanningAny(of: [.usb]) {
                deviceScanner.start(sources: [.usb])
            }
        case .bluetooth:
            if bluetoothDevices.isEmpty && !deviceScanner.isScanningAny(of: [.bluetooth, .ble]) {
                deviceScanner.start(sources: [.bluetooth, .ble])
            }
        }
    }

    private func normalizeHost() {
        let target = DiscoveryInput.split(draft.host)
        draft.host = target.host
        if let port = target.port { draft.port = port }
    }

    private func autoProbe() async {
        if reachability != .idle {
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { reachability = .idle }
        }
        guard draft.connection == .network else { return }
        let target = DiscoveryInput.split(draft.host)
        guard DiscoveryInput.isPlausibleHost(target.host) else { return }
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        await checkReachability()
    }

    private func checkReachability() async {
        let key = probeKey
        let target = DiscoveryInput.split(draft.host)
        let port = target.port ?? draft.port
        guard DiscoveryInput.isPlausibleHost(target.host), (1...65535).contains(port) else {
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                reachability = .unreachable(tr("Bitte eine gültige Adresse eingeben."))
            }
            return
        }
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { reachability = .checking }
        let result = await DiscoveryProbe.check(host: target.host, port: port)
        // Inzwischen geänderte Eingaben verwerfen das Ergebnis.
        guard key == probeKey else { return }
        withAnimation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion)) {
            reachability = result
        }
    }

    private func loadQueues() async {
        isLoadingQueues = true
        let loaded = await CUPSService.queues()
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            queues = loaded.sorted { lhs, rhs in
                if lhs.looksLikeZebra != rhs.looksLikeZebra { return lhs.looksLikeZebra }
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            isLoadingQueues = false
            queuesLoaded = true
        }
        if let selected = draft.queueName, !queues.contains(where: { $0.name == selected }) {
            draft.queueName = nil
        }
    }

    private func selectQueue(_ queue: CUPSQueueInfo) {
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            draft.queueName = queue.name
        }
        if draft.modelID == nil, let match = DiscoveryMatcher.model(for: queue) {
            let hint = CUPSQueueLister.modelHint(fromDeviceURI: queue.deviceURI) ?? queue.makeAndModel
            selectModel(match, resolutionHint: AppModel.resolution(fromHint: hint))
        }
    }

    private func selectDevice(_ device: DiscoveredPrinter) {
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            draft.deviceID = device.id
            if draft.connection == .bluetooth { draft.bluetoothAddress = "" }
        }
        if draft.modelID == nil, let match = DiscoveryMatcher.model(for: device) {
            selectModel(match, resolutionHint: AppModel.resolution(fromHint: device.modelHint))
        }
    }

    /// Wählt ein Modell und passt Auflösung, Sprache und Etikett an dessen Fähigkeiten an.
    private func selectModel(_ printerModel: PrinterModel?, resolutionHint: Resolution? = nil) {
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            draft.modelID = printerModel?.id
            let resolutions = printerModel?.supportedResolutions ?? Resolution.allCases
            if let resolutionHint, resolutions.contains(resolutionHint) {
                draft.resolution = resolutionHint
            } else if !resolutions.contains(draft.resolution) {
                draft.resolution = resolutions.contains(.dpi203) ? .dpi203 : (resolutions.first ?? .dpi203)
            }
            if let printerModel, !printerModel.languages.contains(draft.language) {
                draft.language = printerModel.defaultLanguage
            }
            let fitting = stocks(for: printerModel)
            if !fitting.contains(where: { $0.id == draft.stockID }) {
                if let printerModel, fitting.contains(where: { $0.id == printerModel.defaultStock }) {
                    draft.stockID = printerModel.defaultStock
                } else {
                    draft.stockID = fitting.first?.id ?? draft.stockID
                }
            }
        }
    }

    private func add() {
        guard let descriptor = currentDescriptor else { return }
        if let existing = existingSession {
            model.selection = .printer(existing.id)
            onComplete(existing)
            return
        }
        var stockID = draft.stockID
        if draft.usesCustomSize {
            // „Benutzerdefiniert …“ wird jetzt ein echtes Format (vorhandenes passendes oder neues eigenes).
            guard let size = customSize else { return }
            stockID = LabelStockLibrary.resolveStock(widthMM: size.widthMM, heightMM: size.heightMM,
                                                     tracking: draft.customSize.tracking, model: model).id
        }
        let saved = SavedPrinter(
            name: effectiveName,
            descriptor: descriptor,
            modelID: draft.modelID,
            resolution: draft.resolution,
            language: draft.language,
            stockID: stockID,
            accentHue: draft.accentHue,
            location: draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !reduceMotion { addPulse += 1 }
        let session = model.addPrinter(saved)
        if MacPrinterInstallToggle.shouldInstall(isOn: installMacPrinter, descriptor: descriptor) {
            PrinterInstallService.installInBackground(for: session, model: model)
        }
        onComplete(session)
    }
}

// MARK: - Modellgruppe

struct DiscoveryModelGroup: Identifiable {
    let category: PrinterCategory
    let models: [PrinterModel]
    var id: String { category.rawValue }
}

// MARK: - Kenndaten eines Modells

/// Kompakte Übersicht der Modell-Kenndaten (Druckbreite, Auflösung, Tempo, Länge, Schnittstellen …).
struct DiscoveryModelSpecs: View {
    let printerModel: PrinterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconBadge(systemImage: printerModel.systemImage, tint: Theme.violet, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(printerModel.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: "\(printerModel.family) · \(tr(printerModel.category.displayName))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                spec(tr("Druckbreite"), value: tr("%d mm", Int(printerModel.printWidthMM.rounded())), symbol: "arrow.left.and.right")
                spec(tr("Auflösung"),
                     value: printerModel.supportedResolutions.map { String($0.dpi) }.joined(separator: " / ") + " dpi",
                     symbol: "circle.grid.3x3")
                spec(tr("Tempo"), value: tr("bis %d Zoll/s", printerModel.maxSpeedIPS.values.max() ?? 4), symbol: "speedometer")
                spec(tr("Max. Länge"), value: tr("%d mm", Int(printerModel.maxLabelLengthMM.rounded())), symbol: "arrow.up.and.down")
            }
            DiscoveryFlowLayout(spacing: 5) {
                ForEach(printerModel.languages) { language in
                    chip(language.displayName, tint: Theme.violet)
                }
                ForEach(printerModel.connectivity) { connectivity in
                    chip(tr(connectivity.displayName), tint: Theme.teal)
                }
                ForEach(printerModel.mediaTypes) { mediaType in
                    chip(tr(mediaType.displayName), tint: Theme.printing)
                }
                ForEach(printerModel.features, id: \.self) { feature in
                    chip(DiscoveryFeatureText.title(feature), tint: Theme.magenta)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
    }

    private func spec(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Auswahlzeile & Hinweis

/// Auswählbare Zeile (Warteschlange, USB-/Bluetooth-Gerät) mit gleitender Auswahlfläche.
struct DiscoveryOptionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    /// Farbe des Symbols (nicht ausgewählt); `nil` = Akzentfarbe.
    let tint: Color?
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    init(title: String, subtitle: String, systemImage: String, tint: Color? = nil,
         isSelected: Bool, namespace: Namespace.ID, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.isSelected = isSelected
        self.namespace = namespace
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : (tint ?? Theme.accent))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(isSelected || hovering ? 1 : 0.35)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hovering ? Theme.subtleFill : Color.clear)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.brandGradient)
                            .matchedGeometryEffect(id: "optionSelection", in: namespace)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Kleiner Hinweis mit Symbol.
struct DiscoveryInlineNote: View {
    let systemImage: String
    let text: String
    /// Farbe von Symbol und Hintergrund; `nil` = Akzentfarbe auf neutralem Grund.
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? Theme.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint?.opacity(0.1) ?? Theme.subtleFill))
        .overlay {
            if let tint {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 1)
            }
        }
    }
}

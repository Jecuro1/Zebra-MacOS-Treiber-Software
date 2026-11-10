import SwiftUI
import LabelWerkKit

/// Netzwerkeinstellungen des Druckers: IPv4/DHCP, WLAN, Bluetooth – mit Live-Prüfung,
/// Änderungsübersicht und sicherem Übernehmen. Ersetzt „Configure Printer Connectivity“.
struct NetworkView: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var editor = NetConfigEditor()

    init(session: PrinterSession) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var hasBluetooth: Bool {
        let connectivity = session.model?.connectivity ?? []
        return connectivity.contains(.bluetooth) || connectivity.contains(.ble)
    }

    private var hasWLAN: Bool {
        if session.model?.connectivity.contains(.wifi) == true { return true }
        guard let original = editor.original else { return false }
        return original.wlanEnabled != nil || original.wlanSSID != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                NetConfigConnectionDiagram(session: session, editor: editor, reduceMotion: reduceMotion)

                if let outcome = editor.outcome {
                    NetConfigRestartCard(outcome: outcome, session: session, editor: editor,
                                         reduceMotion: reduceMotion, wantsBluetooth: hasBluetooth)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.97))))
                }

                content

                NetConfigActiveCard(editor: editor, reduceMotion: reduceMotion) {
                    Task { await editor.loadActive(session: session, reduceMotion: reduceMotion) }
                }
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Motion.spring, value: editor.loadPhase)
            .animation(reduceMotion ? nil : Motion.spring, value: editor.outcome)
        }
        .task {
            await editor.load(session: session, reduceMotion: reduceMotion, wantsBluetooth: hasBluetooth)
        }
        .onDisappear {
            editor.cancelBackgroundWork()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch editor.loadPhase {
        case .idle, .loading:
            NetConfigSkeleton(reduceMotion: reduceMotion)
                .transition(.opacity)
        case .failed(let message):
            NetConfigLoadError(message: message) {
                Task { await editor.load(session: session, reduceMotion: reduceMotion, wantsBluetooth: hasBluetooth) }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .loaded:
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                // Während der Übertragung keine Eingaben: Sie würden sonst als übertragen gelten.
                NetConfigIPv4Card(editor: editor, reduceMotion: reduceMotion)
                    .disabled(editor.isApplying)
                    .transferAppear(index: 0, reduceMotion: reduceMotion)
                if hasWLAN {
                    NetConfigWLANCard(editor: editor, reduceMotion: reduceMotion)
                        .disabled(editor.isApplying)
                        .transferAppear(index: 1, reduceMotion: reduceMotion)
                }
                if hasBluetooth {
                    NetConfigBluetoothCard(editor: editor, reduceMotion: reduceMotion)
                        .disabled(editor.isApplying)
                        .transferAppear(index: 2, reduceMotion: reduceMotion)
                }
                NetConfigChangesCard(session: session, editor: editor, hasBluetooth: hasBluetooth,
                                     hasWLAN: hasWLAN, reduceMotion: reduceMotion)
                    .transferAppear(index: 3, reduceMotion: reduceMotion)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Platzhalter & Fehler

private struct NetConfigSkeleton: View {
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: Theme.Metrics.cardSpacing) {
            ForEach(0..<2, id: \.self) { _ in
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.separator)
                                .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(Theme.separator).frame(width: 150, height: 11)
                                Capsule().fill(Theme.subtleFill).frame(width: 240, height: 8)
                            }
                            Spacer()
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                                  spacing: 12) {
                            ForEach(0..<4, id: \.self) { _ in TransferSkeletonField() }
                        }
                    }
                }
            }
        }
        .shimmering(active: !reduceMotion)
        .accessibilityLabel(tr("Netzwerkeinstellungen werden gelesen …"))
    }
}

private struct NetConfigLoadError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        GlassCard(tint: Theme.warning) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: "network.slash", tint: Theme.warning, size: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Netzwerkeinstellungen nicht verfügbar"))
                        .font(Theme.Typography.headline)
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: retry) {
                        Label(tr("Erneut lesen"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - IPv4

private struct NetConfigIPv4Card: View {
    @Bindable var editor: NetConfigEditor
    let reduceMotion: Bool

    private var twoColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
    }

    private var dhcpBinding: Binding<Bool> {
        Binding(
            get: { editor.draft.useDHCP },
            set: { newValue in
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    editor.draft.useDHCP = newValue
                    editor.prefillStaticFieldsIfNeeded()
                }
            }
        )
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("IPv4-Adresse"), subtitle: tr("Wie der Drucker seine Adresse im Netzwerk erhält"),
                              systemImage: "network")
                HStack(spacing: 12) {
                    IconBadge(systemImage: editor.draft.useDHCP ? "arrow.triangle.branch" : "pin.fill",
                              tint: editor.draft.useDHCP ? Theme.teal : Theme.violet, size: 34)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Adresse automatisch beziehen (DHCP)"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(editor.draft.useDHCP
                             ? tr("Der Router vergibt IP-Adresse, Subnetzmaske und Gateway.")
                             : tr("Feste Adresse – ideal, wenn der Drucker immer unter derselben IP erreichbar sein soll."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 8)
                    Toggle(tr("DHCP"), isOn: dhcpBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if editor.draft.useDHCP {
                    dhcpSummary
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    staticFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().opacity(0.5)

                LazyVGrid(columns: twoColumns, spacing: 12) {
                    NetConfigInputField(tr("DNS-Server (optional)"), text: $editor.draft.dnsServer,
                                   issue: editor.issue(.dnsServer, hasBluetooth: false, hasWLAN: false),
                                   shakeToken: editor.shakeToken(.dnsServer), placeholder: "8.8.8.8",
                                   reduceMotion: reduceMotion)
                    NetConfigInputField(tr("Hostname (optional)"), text: $editor.draft.hostname,
                                   issue: editor.issue(.hostname, hasBluetooth: false, hasWLAN: false),
                                   shakeToken: editor.shakeToken(.hostname), placeholder: tr("lager-zd421"),
                                   monospaced: false, reduceMotion: reduceMotion)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: editor.draft.useDHCP)
    }

    private var dhcpSummary: some View {
        let ip = editor.activeIP
        let mask = editor.active["interface.network.active.netmask"]
        let gateway = editor.active["interface.network.active.gateway"]
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.teal)
            if let ip {
                Text(tr("Aktuell zugewiesen: %@", ip))
                    .font(.system(size: 12.5, weight: .medium))
                if let mask, !mask.isEmpty {
                    Text(verbatim: "· \(mask)")
                        .font(Theme.Typography.codeSmall)
                        .foregroundStyle(.secondary)
                }
                if let gateway, !gateway.isEmpty, gateway != "0.0.0.0" {
                    Text(tr("· Gateway %@", gateway))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(tr("Die Adresse wird beim nächsten Start vom DHCP-Server bezogen."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.teal.opacity(0.08))
        }
    }

    private var staticFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: twoColumns, spacing: 12) {
                NetConfigInputField(tr("IP-Adresse"), text: $editor.draft.ipAddress,
                               issue: editor.issue(.ipAddress, hasBluetooth: false, hasWLAN: false),
                               shakeToken: editor.shakeToken(.ipAddress), placeholder: "192.168.1.50",
                               reduceMotion: reduceMotion)
                NetConfigInputField(tr("Subnetzmaske"), text: $editor.draft.subnetMask,
                               issue: editor.issue(.subnetMask, hasBluetooth: false, hasWLAN: false),
                               shakeToken: editor.shakeToken(.subnetMask), placeholder: "255.255.255.0",
                               reduceMotion: reduceMotion) {
                    Menu {
                        ForEach(NetConfigIPv4.commonMasks, id: \.prefix) { entry in
                            Button {
                                editor.draft.subnetMask = entry.mask
                            } label: {
                                Text(verbatim: "\(entry.mask)  /\(entry.prefix)")
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("Übliche Subnetzmasken"))
                }
                NetConfigInputField(tr("Gateway (Router)"), text: $editor.draft.gateway,
                               issue: editor.issue(.gateway, hasBluetooth: false, hasWLAN: false),
                               shakeToken: editor.shakeToken(.gateway), placeholder: "192.168.1.1",
                               reduceMotion: reduceMotion)
                subnetSummary
            }
        }
    }

    /// „Netz 192.168.1.0/24 · 254 Adressen“
    private var subnetSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Subnetz"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            if let ip = NetConfigIPv4.parse(editor.draft.ipAddress),
               let mask = NetConfigIPv4.parse(editor.draft.subnetMask), NetConfigIPv4.isValidMask(mask) {
                let prefix = NetConfigIPv4.prefixLength(mask)
                let hosts = max(0, (1 << (32 - prefix)) - 2)
                HStack(spacing: 6) {
                    Text(verbatim: "\(NetConfigIPv4.format(ip & mask))/\(prefix)")
                        .font(Theme.Typography.code)
                        .contentTransition(.numericText())
                    Text(tr("· %d Adressen", hosts))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
            } else {
                Text(verbatim: "–")
                    .font(Theme.Typography.code)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 7)
            }
        }
    }
}

// MARK: - WLAN

private struct NetConfigWLANCard: View {
    @Bindable var editor: NetConfigEditor
    let reduceMotion: Bool

    private var securityOptions: [NetConfigSecurity] {
        var options = NetConfigSecurity.selectable
        if case .other = editor.initial.wlanSecurity { options.append(editor.initial.wlanSecurity) }
        return options
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("WLAN"), subtitle: tr("Funknetz, mit dem sich der Drucker verbindet"),
                              systemImage: editor.draft.wlanEnabled ? "wifi" : "wifi.slash") {
                    Toggle(tr("WLAN"), isOn: $editor.draft.wlanEnabled.animation(reduceMotion ? nil : Motion.spring))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if editor.draft.wlanEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                            GridItem(.flexible(), spacing: 14, alignment: .top)], spacing: 12) {
                            NetConfigInputField(tr("WLAN-Name (SSID)"), text: $editor.draft.wlanSSID,
                                           issue: editor.issue(.ssid, hasBluetooth: false, hasWLAN: true),
                                           shakeToken: editor.shakeToken(.ssid), placeholder: tr("Name des Funknetzes"),
                                           monospaced: false, reduceMotion: reduceMotion)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tr("Sicherheit"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Picker(tr("Sicherheit"), selection: $editor.draft.wlanSecurity.animation(reduceMotion ? nil : Motion.snappy)) {
                                    ForEach(securityOptions, id: \.self) { option in
                                        Label(option.title, systemImage: option.systemImage).tag(option)
                                    }
                                }
                                .labelsHidden()
                                .padding(.vertical, 2)
                            }
                        }
                        if editor.draft.wlanSecurity.needsPassphrase {
                            NetConfigInputField(tr("WLAN-Passwort"), text: $editor.draft.wlanPassphrase,
                                           issue: editor.issue(.passphrase, hasBluetooth: false, hasWLAN: true),
                                           shakeToken: editor.shakeToken(.passphrase),
                                           placeholder: tr("Leer lassen, um das Passwort nicht zu ändern"),
                                           monospaced: false, isSecure: true, reduceMotion: reduceMotion)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            TransferNote(tr("Das Passwort wird nur gesendet – es wird weder vom Drucker gelesen noch in LabelWerk gespeichert."),
                                         style: .info)
                        }
                        if case .other = editor.draft.wlanSecurity {
                            TransferNote(tr("Dieser Sicherheitsmodus (z. B. Enterprise/EAP) bleibt unverändert. Zertifikate richtest du am Drucker oder mit Zebra-Werkzeugen ein."),
                                         style: .info)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(tr("WLAN ist ausgeschaltet. Einschalten, um den Drucker mit einem Funknetz zu verbinden."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: editor.draft.wlanEnabled)
        .animation(reduceMotion ? nil : Motion.snappy, value: editor.draft.wlanSecurity)
    }
}

// MARK: - Bluetooth

private struct NetConfigBluetoothCard: View {
    @Bindable var editor: NetConfigEditor
    let reduceMotion: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Bluetooth"), subtitle: tr("Name und Sichtbarkeit für die Kopplung mit Mac, iPhone oder Scanner"),
                              systemImage: "dot.radiowaves.left.and.right")
                if editor.originalBluetooth == nil {
                    TransferNote(tr("Die Bluetooth-Werte konnten nicht gelesen werden – der Drucker unterstützt diese Abfrage eventuell nicht."),
                                 style: .info)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        NetConfigInputField(tr("Gerätename"), text: $editor.draft.bluetoothName,
                                       issue: editor.issue(.bluetoothName, hasBluetooth: true, hasWLAN: false),
                                       shakeToken: editor.shakeToken(.bluetoothName), placeholder: tr("ZD421-Lager"),
                                       monospaced: false, reduceMotion: reduceMotion)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Sichtbarkeit"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Toggle(isOn: $editor.draft.bluetoothDiscoverable) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tr("Für andere Geräte sichtbar"))
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text(tr("Nur zum Koppeln nötig – danach ausschalten erhöht die Sicherheit."))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch)
                            .padding(.vertical, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TransferNote(tr("Bluetooth-Änderungen werden ohne Neustart übernommen."), style: .info)
                }
            }
        }
    }
}

// MARK: - Änderungen & Übernehmen

private struct NetConfigChangesCard: View {
    let session: PrinterSession
    @Bindable var editor: NetConfigEditor
    let hasBluetooth: Bool
    let hasWLAN: Bool
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        let changes = editor.changes
        let invalid = editor.invalidFields(hasBluetooth: hasBluetooth, hasWLAN: hasWLAN)
        GlassCard(tint: changes.isEmpty ? nil : (editor.needsRestart ? Theme.warning : Theme.accent)) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Ausstehende Änderungen"),
                              subtitle: changes.isEmpty ? tr("Noch nichts geändert")
                                                        : tr("%d Änderungen bereit zur Übertragung", changes.count),
                              systemImage: "list.bullet.clipboard") {
                    if !changes.isEmpty {
                        Button {
                            editor.discard(reduceMotion: reduceMotion)
                        } label: {
                            Label(tr("Verwerfen"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .disabled(editor.isApplying)
                    }
                }
                if changes.isEmpty {
                    Text(tr("Passe oben Werte an – hier erscheint eine Übersicht, bevor etwas an den Drucker gesendet wird."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                            changeRow(change)
                                .transferAppear(index: index, reduceMotion: reduceMotion)
                                .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                        removal: .opacity.combined(with: .scale(scale: 0.95))))
                        }
                    }
                    if editor.needsRestart {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.warning)
                                .symbolEffect(.pulse, options: .repeating, isActive: editor.isApplying && !reduceMotion)
                            Text(tr("Der Drucker übernimmt die Werte und startet neu (ca. 30 Sekunden). Die Verbindung wird dabei unterbrochen. Ändert sich die IP-Adresse, ist der Drucker danach nur noch unter der neuen Adresse erreichbar – LabelWerk bietet dann an, die Verbindung umzustellen."))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.warning.opacity(0.08))
                        }
                        .transition(.opacity)
                    }
                    HStack(spacing: 12) {
                        if !invalid.isEmpty {
                            TransferNote(invalid.count == 1 ? tr("Ein Feld ist ungültig.")
                                                            : tr("%d Felder sind ungültig.", invalid.count),
                                         style: .error)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 8)
                        if editor.isApplying {
                            HStack(spacing: 8) {
                                ProgressRing(progress: session.progress, size: 20, lineWidth: 3)
                                Text(tr("Wird übertragen …"))
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else {
                            HoldToConfirmButton(
                                title: editor.needsRestart ? tr("Übernehmen & neu starten") : tr("Übernehmen"),
                                systemImage: editor.needsRestart ? "arrow.triangle.2.circlepath" : "checkmark",
                                tint: editor.needsRestart ? Theme.warning : Theme.accent,
                                duration: editor.needsRestart ? 1.4 : 0.8
                            ) {
                                Task {
                                    await editor.apply(session: session, model: model, hasBluetooth: hasBluetooth,
                                                       hasWLAN: hasWLAN, reduceMotion: reduceMotion)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: changes)
        .animation(reduceMotion ? nil : Motion.snappy, value: editor.isApplying)
        .animation(reduceMotion ? nil : Motion.snappy, value: invalid)
    }

    private func changeRow(_ change: NetConfigChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: change.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(change.requiresRestart ? Theme.warning : Theme.accent)
                .frame(width: 22)
            Text(change.title)
                .font(.system(size: 12.5, weight: .medium))
                .frame(minWidth: 130, alignment: .leading)
            Text(verbatim: change.oldValue)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .strikethrough(true, color: Theme.error.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(verbatim: change.newValue)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !change.requiresRestart {
                TransferChip(tr("ohne Neustart"), systemImage: "bolt.fill", tint: Theme.accent)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.subtleFill)
        }
    }
}

// MARK: - Nach dem Übernehmen

private struct NetConfigRestartCard: View {
    let outcome: NetConfigOutcome
    let session: PrinterSession
    let editor: NetConfigEditor
    let reduceMotion: Bool
    let wantsBluetooth: Bool

    @Environment(AppModel.self) private var model
    /// Die erwartete Neustartzeit ist abgelaufen (beendet den Sekunden-Countdown).
    @State private var countdownOver = false

    private var isDone: Bool { outcome.reconnected || !outcome.restartExpected }
    private var expectedDuration: TimeInterval { session.isVirtual ? 3 : 30 }
    /// Die neue Adresse wurde noch nicht übernommen – ohne Zutun verbindet sich nichts.
    private var awaitsHostSwitch: Bool { outcome.suggestedHost != nil && !outcome.hostUpdated && !outcome.reconnected }

    private var tint: Color {
        if isDone { return Theme.ready }
        if outcome.reconnectFailed { return Theme.warning }
        return Theme.printing
    }

    private var title: String {
        if !outcome.restartExpected { return tr("Einstellungen übernommen") }
        if outcome.reconnected { return tr("Drucker wieder verbunden") }
        if outcome.reconnectFailed { return tr("Drucker antwortet nicht") }
        if countdownOver && outcome.reconnecting { return tr("Verbindung wird wiederhergestellt …") }
        if countdownOver && awaitsHostSwitch { return tr("Neue Adresse übernehmen") }
        return tr("Drucker startet neu …")
    }

    private var message: String {
        if !outcome.restartExpected { return tr("Die Änderungen sind sofort aktiv.") }
        if outcome.reconnected { return tr("Die neuen Netzwerkeinstellungen sind aktiv.") }
        if outcome.reconnectFailed {
            if outcome.switchedToDHCP {
                return tr("Unter der bisherigen Adresse meldet sich der Drucker nicht – per DHCP hat er vermutlich eine neue erhalten. Sie steht auf dem Konfigurationsetikett oder wird über die Druckersuche gefunden.")
            }
            return tr("Nach dem Neustart kam keine Verbindung zustande. Prüfe, ob der Drucker eingeschaltet und im Netzwerk erreichbar ist, und versuche es erneut.")
        }
        if awaitsHostSwitch {
            return tr("Der Drucker übernimmt die neue Adresse. Stelle die Verbindung um, damit LabelWerk ihn weiterhin erreicht.")
        }
        if outcome.switchedToDHCP {
            return tr("Der Drucker bezieht seine Adresse jetzt per DHCP. LabelWerk versucht es zuerst unter der bisherigen Adresse; hat er eine neue erhalten, findet ihn die Druckersuche.")
        }
        if outcome.reconnecting {
            return tr("Die Verbindung wird nach dem Neustart automatisch wiederhergestellt.")
        }
        return tr("Die automatische Wiederverbindung wurde unterbrochen. Verbinde dich erneut, sobald der Drucker bereit ist.")
    }

    var body: some View {
        GlassCard(padding: 18, cornerRadius: Theme.Metrics.cornerLarge, tint: tint) {
            HStack(alignment: .top, spacing: 16) {
                indicator
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(Theme.Typography.headline)
                        .contentTransition(.opacity)
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if let host = outcome.suggestedHost {
                        if outcome.hostUpdated {
                            TransferNote(tr("Die Verbindung verwendet jetzt %@.", host), style: .success)
                        } else if !outcome.reconnected {
                            Button {
                                editor.adoptSuggestedHost(session: session, reduceMotion: reduceMotion, wantsBluetooth: wantsBluetooth)
                            } label: {
                                Label(tr("Verbindung auf %@ umstellen", host), systemImage: "arrow.triangle.swap")
                            }
                            .buttonStyle(.labelWerkPrimary)
                        }
                    }
                    HStack(spacing: 8) {
                        if outcome.switchedToDHCP && !outcome.reconnected {
                            Button {
                                model.selection = .discover
                            } label: {
                                Label(tr("Drucker suchen"), systemImage: "dot.radiowaves.left.and.right")
                            }
                            .buttonStyle(outcome.reconnectFailed ? LabelWerkButtonStyle.labelWerkPrimary : LabelWerkButtonStyle.labelWerkSecondary)
                        }
                        if outcome.restartExpected && !outcome.reconnected && !awaitsHostSwitch {
                            Button {
                                editor.reconnectNow(session: session, reduceMotion: reduceMotion, wantsBluetooth: wantsBluetooth)
                            } label: {
                                Label(outcome.reconnectFailed ? tr("Erneut versuchen") : tr("Jetzt verbinden"),
                                      systemImage: outcome.reconnectFailed ? "arrow.clockwise" : "bolt.horizontal")
                            }
                            .buttonStyle(.labelWerkSecondary)
                            .disabled(session.connectionState == .connecting)
                        }
                        Button(tr("Schließen")) {
                            editor.dismissOutcome(reduceMotion: reduceMotion)
                        }
                        .buttonStyle(.labelWerkPlain)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: outcome)
        .animation(reduceMotion ? nil : Motion.spring, value: countdownOver)
        .task(id: outcome.appliedAt) {
            // Countdown nur bis zur erwarteten Neustartzeit – danach keine sekündlichen Aktualisierungen mehr.
            let remaining = expectedDuration - Date().timeIntervalSince(outcome.appliedAt)
            guard remaining > 0 else {
                countdownOver = true
                return
            }
            countdownOver = false
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            countdownOver = true
        }
        .onChange(of: session.connectionState) { oldValue, newValue in
            // Auch eine Wiederverbindung über die Statusüberwachung oder die Seitenleiste beendet das Warten.
            if newValue == .connected && oldValue != .connected {
                editor.connectionRestored(session: session, reduceMotion: reduceMotion, wantsBluetooth: wantsBluetooth)
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if isDone {
            IconBadge(systemImage: "checkmark", tint: Theme.ready, size: 50)
                .symbolEffect(.bounce, value: reduceMotion ? false : outcome.reconnected)
                .transition(.scale.combined(with: .opacity))
        } else if outcome.reconnectFailed {
            IconBadge(systemImage: "wifi.exclamationmark", tint: Theme.warning, size: 50)
                .symbolEffect(.bounce, value: reduceMotion ? false : outcome.reconnectFailed)
                .transition(.scale.combined(with: .opacity))
        } else if !countdownOver {
            TimelineView(.periodic(from: outcome.appliedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(outcome.appliedAt)
                let remaining = max(0, Int((expectedDuration - elapsed).rounded(.up)))
                RingGauge(value: min(1, max(0, elapsed / expectedDuration)), lineWidth: 6,
                          colors: [Theme.printing, Theme.teal],
                          valueText: remaining > 0 ? "\(remaining)" : nil)
            }
            .transition(.opacity)
        } else if outcome.reconnecting {
            ZStack {
                PulseRings(color: Theme.printing, active: !reduceMotion)
                ProgressRing(progress: nil, size: 30, lineWidth: 3.5)
            }
            .transition(.opacity)
        } else {
            IconBadge(systemImage: awaitsHostSwitch ? "arrow.triangle.swap" : "bolt.horizontal.circle",
                      tint: Theme.printing, size: 50)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

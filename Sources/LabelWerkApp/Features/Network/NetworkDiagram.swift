import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Verbindungsdiagramm

/// Mac ↔ Drucker mit animierter Verbindungslinie, Schnittstellensymbol, IP- und MAC-Adressen.
struct NetConfigConnectionDiagram: View {
    let session: PrinterSession
    let editor: NetConfigEditor
    let reduceMotion: Bool

    init(session: PrinterSession, editor: NetConfigEditor, reduceMotion: Bool) {
        self.session = session
        self.editor = editor
        self.reduceMotion = reduceMotion
    }

    private var linkState: NetConfigLinkState {
        switch session.connectionState {
        case .connected: return .live
        case .connecting: return .connecting
        case .disconnected, .failed: return .down
        }
    }

    private var tint: Color {
        switch linkState {
        case .live: return Theme.teal
        case .connecting: return Theme.warning
        case .down: return Theme.error
        }
    }

    private var printerIP: String? {
        if let ip = editor.activeIP { return ip }
        if let ip = session.identity?.ipAddress, !ip.isEmpty { return ip }
        if case .tcp(let host, _) = session.saved.descriptor { return host }
        return nil
    }

    private var printerMAC: String? {
        editor.activeMAC ?? session.identity?.macAddress.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Eigene Adresse – bevorzugt im selben Netz wie der Drucker.
    private var macAddress: String? {
        let interfaces = editor.localInterfaces
        if let ip = printerIP.flatMap(NetConfigIPv4.parse) {
            let match = interfaces.first { iface in
                guard let address = NetConfigIPv4.parse(iface.address), let mask = NetConfigIPv4.parse(iface.netmask) else { return false }
                return NetConfigIPv4.sameSubnet(address, ip, mask: mask)
            }
            if let match { return match.address }
        }
        return interfaces.first?.address
    }

    private var interfaceInfo: (symbol: String, title: String) {
        let descriptor = session.saved.descriptor
        switch descriptor.kind {
        case .tcp:
            if editor.activeSSID != nil, (editor.signalPercent ?? 0) > 0 { return ("wifi", tr("WLAN")) }
            return ("network", tr("Netzwerk"))
        case .usb: return ("cable.connector", tr("USB"))
        case .bluetooth, .ble: return ("dot.radiowaves.left.and.right", tr("Bluetooth"))
        case .cupsQueue: return ("printer", tr("macOS-Warteschlange"))
        case .virtual: return ("sparkles", tr("Simulation"))
        default: return ("point.3.connected.trianglepath.dotted", tr("Verbindung"))
        }
    }

    private var statusText: String {
        switch session.connectionState {
        case .connected: return tr("Verbunden über %@", session.saved.descriptor.displayString)
        case .connecting: return tr("Verbindung zu %@ wird aufgebaut …", session.saved.descriptor.displayString)
        case .disconnected: return tr("Nicht verbunden")
        case .failed(let message): return message
        }
    }

    var body: some View {
        let info = interfaceInfo
        GlassCard(padding: 22, cornerRadius: Theme.Metrics.cornerLarge, tint: tint) {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 0) {
                    endpoint(
                        icon: AnyView(
                            ZStack {
                                Circle()
                                    .fill(Theme.subtleFill)
                                Circle()
                                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
                                Image(systemName: "laptopcomputer")
                                    .font(.system(size: 30, weight: .regular))
                                    .foregroundStyle(Theme.brandGradient)
                            }
                        ),
                        title: tr("Dieser Mac"),
                        primary: macAddress,
                        secondary: nil
                    )
                    NetConfigLink(state: linkState, symbol: info.symbol, caption: info.title,
                                  detail: session.saved.descriptor.kind == .tcp ? session.saved.descriptor.displayString : nil,
                                  tint: tint, reduceMotion: reduceMotion)
                        .padding(.top, 11)
                        .frame(maxWidth: .infinity)
                    endpoint(
                        icon: AnyView(
                            IconBadge(systemImage: session.model?.systemImage ?? "printer", tint: session.accentColor, size: 62)
                                .overlay(alignment: .bottomTrailing) {
                                    StatusOrb(state: session.state, size: 14)
                                        .offset(x: 4, y: 4)
                                }
                        ),
                        title: session.displayName,
                        primary: printerIP,
                        secondary: printerMAC
                    )
                }
                HStack(spacing: 8) {
                    Image(systemName: linkState == .down ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill")
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: linkState == .connecting && !reduceMotion)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                    if linkState == .down {
                        Button {
                            Task { await session.connect() }
                        } label: {
                            Label(tr("Verbinden"), systemImage: "bolt.fill")
                        }
                        .buttonStyle(.labelWerkPrimary)
                        .controlSize(.small)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: linkState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Verbindungsdiagramm"))
    }

    private func endpoint(icon: AnyView, title: String, primary: String?, secondary: String?) -> some View {
        VStack(spacing: 6) {
            icon
                .frame(width: 66, height: 66)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: primary ?? "–")
                .font(Theme.Typography.code)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .contentTransition(.numericText())
            if let secondary {
                Text(verbatim: secondary)
                    .font(Theme.Typography.codeSmall)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 170)
    }
}

enum NetConfigLinkState: Equatable {
    case live, connecting, down
}

/// Verbindungslinie mit wandernden Datenpaketen (nur aktiv, solange verbunden und sichtbar).
private struct NetConfigLink: View {
    let state: NetConfigLinkState
    let symbol: String
    let caption: String
    let detail: String?
    let tint: Color
    let reduceMotion: Bool

    /// Im Hintergrundfenster anhalten – spart Energie.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: state == .down || reduceMotion || controlActiveState == .inactive)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        drawLink(context: context, size: size, time: t)
                    }
                }
                .frame(height: 44)
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                    Circle()
                        .strokeBorder(tint.opacity(0.55), lineWidth: 1.2)
                    Image(systemName: state == .down ? "xmark" : symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, options: .repeating,
                                      isActive: state == .connecting && !reduceMotion)
                }
                .frame(width: 44, height: 44)
                .shadow(color: tint.opacity(state == .live ? 0.45 : 0.15), radius: 8)
            }
            Text(caption)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            if let detail {
                Text(verbatim: detail)
                    .font(Theme.Typography.codeSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
    }

    private func drawLink(context: GraphicsContext, size: CGSize, time t: TimeInterval) {
        let y = size.height / 2
        var path = Path()
        path.move(to: CGPoint(x: 4, y: y))
        path.addLine(to: CGPoint(x: size.width - 4, y: y))
        let animated = state != .down && !reduceMotion
        let phase = animated ? CGFloat((t * 26).truncatingRemainder(dividingBy: 14)) : 0
        let dash: [CGFloat] = state == .down ? [5, 7] : [2, 12]
        context.stroke(path, with: .color(tint.opacity(state == .down ? 0.45 : 0.8)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dash, dashPhase: -phase))
        guard state == .live else { return }
        // Pakete in beide Richtungen
        let packets: [(speed: Double, offset: Double, forward: Bool)] = [
            (2.4, 0, true), (2.4, 0.5, true), (3.3, 0.2, false),
        ]
        for packet in packets {
            var progress = animated ? ((t / packet.speed) + packet.offset).truncatingRemainder(dividingBy: 1) : packet.offset
            if !packet.forward { progress = 1 - progress }
            let x = 8 + (size.width - 16) * CGFloat(progress)
            let fade = min(1, min(progress, 1 - progress) * 6)
            let core = CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: core.insetBy(dx: -5, dy: -5)), with: .color(tint.opacity(0.16 * fade)))
            context.fill(Path(ellipseIn: core), with: .color(tint.opacity(fade)))
        }
    }
}

// MARK: - Signalstärke

struct NetConfigSignalBars: View {
    let percent: Int

    init(percent: Int) {
        self.percent = percent
    }

    private var level: Int {
        switch percent {
        case 75...: return 4
        case 50..<75: return 3
        case 25..<50: return 2
        case 1..<25: return 1
        default: return 0
        }
    }

    private var tint: Color {
        switch level {
        case 3, 4: return Theme.ready
        case 2: return Theme.warning
        default: return Theme.error
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < level ? tint : Theme.separator)
                    .frame(width: 4.5, height: CGFloat(5 + index * 4))
            }
        }
        .animation(Motion.spring, value: level)
        .accessibilityElement()
        .accessibilityLabel(tr("Signalstärke"))
        .accessibilityValue(TransferFormat.percent(Double(percent) / 100))
    }
}

// MARK: - Eingabefeld

/// Eingabefeld mit Live-Prüfung: rot/orange umrandet, Symbol, Meldung und Schütteln bei Fehlern.
struct NetConfigInputField<Accessory: View>: View {
    let title: String
    @Binding var text: String
    let issue: NetConfigIssue
    let shakeToken: Int
    let placeholder: String
    let monospaced: Bool
    let isSecure: Bool
    let reduceMotion: Bool
    let accessory: Accessory

    @FocusState private var focused: Bool
    @State private var localShake = 0
    @State private var revealed = false

    init(_ title: String, text: Binding<String>, issue: NetConfigIssue, shakeToken: Int, placeholder: String,
         monospaced: Bool = true, isSecure: Bool = false, reduceMotion: Bool,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._text = text
        self.issue = issue
        self.shakeToken = shakeToken
        self.placeholder = placeholder
        self.monospaced = monospaced
        self.isSecure = isSecure
        self.reduceMotion = reduceMotion
        self.accessory = accessory()
    }

    private var borderColor: Color {
        switch issue {
        case .error: return Theme.error
        case .warning: return Theme.warning
        case .valid, .none: return focused ? Theme.accent.opacity(0.7) : Theme.cardStroke
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                inputField
                    .textFieldStyle(.plain)
                    .font(monospaced ? Theme.Typography.code : .system(size: 13))
                    .focused($focused)
                    .onSubmit { if issue.isError { shake() } }
                statusIcon
                if isSecure {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(revealed ? tr("Verbergen") : tr("Anzeigen"))
                }
                accessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(issue.isError ? Theme.error.opacity(0.07) : Theme.subtleFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: focused || issue.isError ? 1.5 : 1)
            }
            .modifier(TransferShakeEffect(trigger: shakeToken + localShake))
            if let message = issue.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(issue.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: issue)
        .animation(reduceMotion ? nil : Motion.snappy, value: focused)
        .onChange(of: focused) { _, isFocused in
            if !isFocused && issue.isError { shake() }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if isSecure && !revealed {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch issue {
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.error)
                .transition(.scale.combined(with: .opacity))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .transition(.scale.combined(with: .opacity))
        case .valid:
            if !text.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.ready)
                    .transition(.scale.combined(with: .opacity))
            }
        case .none:
            EmptyView()
        }
    }

    private func shake() {
        withAnimation(reduceMotion ? nil : .linear(duration: 0.45)) { localShake += 1 }
    }
}

extension NetConfigInputField where Accessory == EmptyView {
    init(_ title: String, text: Binding<String>, issue: NetConfigIssue, shakeToken: Int, placeholder: String,
         monospaced: Bool = true, isSecure: Bool = false, reduceMotion: Bool) {
        self.init(title, text: text, issue: issue, shakeToken: shakeToken, placeholder: placeholder,
                  monospaced: monospaced, isSecure: isSecure, reduceMotion: reduceMotion) { EmptyView() }
    }
}

// MARK: - Aktive Schnittstelle

/// Live-Werte der aktiven Schnittstelle (nur lesen).
struct NetConfigActiveCard: View {
    let editor: NetConfigEditor
    let reduceMotion: Bool
    let refresh: () -> Void

    init(editor: NetConfigEditor, reduceMotion: Bool, refresh: @escaping () -> Void) {
        self.editor = editor
        self.reduceMotion = reduceMotion
        self.refresh = refresh
    }

    private func value(_ key: String) -> String? {
        guard let raw = editor.active[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    private var protocolText: String? {
        guard let raw = value("interface.network.active.protocol") else { return nil }
        switch raw.lowercased() {
        case "dhcp": return tr("DHCP")
        case "permanent", "static", "manual": return tr("Statisch")
        case "bootp": return tr("BOOTP")
        case "all": return tr("Automatisch (alle Verfahren)")
        default: return raw
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Aktive Schnittstelle"), subtitle: tr("Live vom Drucker gelesen – so ist er gerade im Netz"),
                              systemImage: "antenna.radiowaves.left.and.right") {
                    Button(action: refresh) {
                        if editor.isLoadingActive {
                            ProgressRing(progress: nil, size: 14, lineWidth: 2)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.labelWerkPlain)
                    .disabled(editor.isLoadingActive)
                    .help(tr("Werte neu lesen"))
                }
                if editor.isLoadingActive && editor.active.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in
                            HStack {
                                Capsule().fill(Theme.separator).frame(width: 90, height: 9)
                                Spacer()
                                Capsule().fill(Theme.separator).frame(width: 120, height: 9)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .shimmering(active: true)
                    .transition(.opacity)
                } else if editor.active.isEmpty {
                    TransferNote(tr("Der Drucker liefert keine Live-Werte der Schnittstelle (nur bei Link-OS-Druckern verfügbar)."),
                                 style: .info)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        if let ip = value("interface.network.active.ip_addr") {
                            KeyValueRow(tr("IP-Adresse"), ip, monospaced: true, copyable: true)
                        }
                        if let mask = value("interface.network.active.netmask") {
                            KeyValueRow(tr("Subnetzmaske"), mask, monospaced: true, copyable: true)
                        }
                        if let gateway = value("interface.network.active.gateway") {
                            KeyValueRow(tr("Gateway"), gateway, monospaced: true, copyable: true)
                        }
                        if let mac = value("interface.network.active.mac_addr") {
                            KeyValueRow(tr("MAC-Adresse"), mac, monospaced: true, copyable: true)
                        }
                        if let protocolText {
                            KeyValueRow(tr("Adressvergabe"), protocolText)
                        }
                        if let ssid = editor.activeSSID {
                            KeyValueRow(tr("WLAN (SSID)"), ssid, copyable: true)
                        }
                        if let percent = editor.signalPercent {
                            HStack(spacing: 10) {
                                Text(tr("Signalstärke"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                NetConfigSignalBars(percent: percent)
                                Text(TransferFormat.percent(Double(percent) / 100))
                                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                    .contentTransition(.numericText())
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: editor.active)
        .animation(reduceMotion ? nil : Motion.snappy, value: editor.isLoadingActive)
    }
}

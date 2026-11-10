import AppKit
import Combine
import SwiftUI
import UserNotifications
import LabelWerkKit

// MARK: - Gemeinsame Bausteine

/// Gestaffeltes Einblenden (Deckkraft, Versatz, Skalierung).
struct OnboardingAppear: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 18)
            .scaleEffect(visible ? 1 : 0.96)
            .onAppear {
                guard !visible else { return }
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1 + Double(index) * 0.07)) {
                        visible = true
                    }
                }
            }
    }
}

extension View {
    func onboardingAppear(_ index: Int, reduceMotion: Bool) -> some View {
        modifier(OnboardingAppear(index: index, reduceMotion: reduceMotion))
    }
}

/// Kopf einer Assistentenseite: Symbol, Titel, Untertitel.
struct OnboardingPageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let reduceMotion: Bool
    /// Änderung lässt das Symbol kurz wackeln (z. B. Glocke).
    var wiggle: Int = 0

    var body: some View {
        VStack(spacing: 10) {
            IconBadge(systemImage: symbol, tint: tint, size: 58)
                .keyframeAnimator(initialValue: 0.0, trigger: wiggle) { content, angle in
                    content.rotationEffect(.degrees(angle), anchor: .top)
                } keyframes: { _ in
                    CubicKeyframe(16, duration: 0.09)
                    CubicKeyframe(-14, duration: 0.13)
                    CubicKeyframe(10, duration: 0.12)
                    CubicKeyframe(-6, duration: 0.11)
                    SpringKeyframe(0, duration: 0.35, spring: .bouncy)
                }
                .onboardingAppear(0, reduceMotion: reduceMotion)
            Text(title)
                .font(Theme.Typography.hero)
                .multilineTextAlignment(.center)
                .onboardingAppear(1, reduceMotion: reduceMotion)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 580)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingAppear(2, reduceMotion: reduceMotion)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Kleine Info-Kachel mit Symbol, Titel und Text.
struct OnboardingInfoTile: View {
    let symbol: String
    let title: String
    let text: String
    let tint: Color

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                IconBadge(systemImage: symbol, tint: tint, size: 30)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
        .cardHoverEffect()
    }
}

// MARK: - 1. Willkommen

/// Werte der Logo-Animation.
struct OnboardingLogoMotion {
    var scale: CGFloat = 1
    var glow: Double = 0
}

struct OnboardingWelcomePage: View {
    let reduceMotion: Bool

    @State private var printTrigger = 0
    @State private var logoTrigger = 0
    @State private var shimmer = false

    private struct Feature: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let text: String
        let tint: Color
    }

    private var features: [Feature] {
        [
            Feature(id: 0, symbol: "waveform.path.ecg", title: tr("Live-Status"),
                    text: tr("Zustand, Meldungen und Lösungsschritte in Echtzeit – auf Wunsch als Mitteilung."), tint: Theme.ready),
            Feature(id: 1, symbol: "pencil.and.ruler", title: tr("Designer"),
                    text: tr("ZPL-Editor mit Live-Vorschau, Vorlagen und Bild- oder PDF-Import."), tint: Theme.violet),
            Feature(id: 2, symbol: "shippingbox", title: tr("Treiber"),
                    text: tr("Drucken aus jedem Programm über den macOS-Druckdialog."), tint: Theme.teal),
            Feature(id: 3, symbol: "wrench.and.screwdriver", title: tr("Werkzeuge"),
                    text: tr("Kalibrieren, Konfiguration, Terminal, Dateien, Netzwerk und Firmware."), tint: Theme.printing),
            Feature(id: 4, symbol: "menubar.rectangle", title: tr("Menüleiste"),
                    text: tr("Alle Drucker im Blick – mit Schnellaktionen direkt in der Menüleiste."), tint: Theme.magenta),
        ]
    }

    var body: some View {
        VStack(spacing: 26) {
            HStack(alignment: .center, spacing: 34) {
                ZStack {
                    Circle()
                        .fill(Theme.brandAngularGradient)
                        .frame(width: 200, height: 200)
                        .blur(radius: 46)
                        .opacity(0.55)
                    PrinterIllustration(state: .ready, isPrinting: false, accent: Theme.violet,
                                        category: .desktop, labelAspect: 1.4, printTrigger: printTrigger)
                        .frame(width: 190, height: 210)
                        .onTapGesture {
                            if !reduceMotion { printTrigger += 1 }
                        }
                        .help(reduceMotion ? "" : tr("Klicken für einen Probedruck"))
                }
                .onboardingAppear(0, reduceMotion: reduceMotion)

                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Willkommen bei"))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .onboardingAppear(1, reduceMotion: reduceMotion)
                    Text(verbatim: "LabelWerk")
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.brandGradient)
                        .shimmering(active: shimmer && !reduceMotion)
                        .keyframeAnimator(initialValue: OnboardingLogoMotion(), trigger: logoTrigger) { content, value in
                            content
                                .scaleEffect(value.scale, anchor: .leading)
                                .shadow(color: Theme.violet.opacity(value.glow), radius: 22)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                CubicKeyframe(0.9, duration: 0.12)
                                SpringKeyframe(1.05, duration: 0.4, spring: .bouncy)
                                SpringKeyframe(1.0, duration: 0.45, spring: .smooth)
                            }
                            KeyframeTrack(\.glow) {
                                LinearKeyframe(0, duration: 0.15)
                                CubicKeyframe(0.75, duration: 0.4)
                                CubicKeyframe(0.2, duration: 0.9)
                            }
                        }
                        .onboardingAppear(2, reduceMotion: reduceMotion)
                    Text(tr("Der moderne Treiber und die Steuerzentrale für Zebra-Etikettendrucker auf dem Mac – mit allem, was du von Windows kennst, und vielem mehr."))
                        .font(.system(size: 14.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440, alignment: .leading)
                        .onboardingAppear(3, reduceMotion: reduceMotion)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(features) { feature in
                    OnboardingInfoTile(symbol: feature.symbol, title: feature.title, text: feature.text, tint: feature.tint)
                        .onboardingAppear(4 + feature.id, reduceMotion: reduceMotion)
                }
            }
        }
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(450))
            logoTrigger += 1
            shimmer = true
            try? await Task.sleep(for: .milliseconds(350))
            printTrigger += 1
            try? await Task.sleep(for: .seconds(1.6))
            shimmer = false
        }
    }
}

// MARK: - 2. Treiber

struct OnboardingDriverPage: View {
    let reduceMotion: Bool

    @State private var flowActive = false
    @State private var flowToken = 0
    @State private var successPop = 0

    private var installer: DriverInstaller { DriverInstaller.shared }

    var body: some View {
        VStack(spacing: 20) {
            OnboardingPageHeader(
                symbol: "shippingbox.fill",
                title: tr("Treiber für alle Programme"),
                subtitle: tr("Mit dem LabelWerk-Treiber erscheinen deine Zebra-Drucker in jedem Druckdialog – Etiketten aus Vorschau, Pages, Browsern oder Versandsoftware drucken, wie unter Windows."),
                tint: Theme.teal,
                reduceMotion: reduceMotion
            )

            GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: statusTint) {
                VStack(alignment: .leading, spacing: 16) {
                    DriverPipelineDiagram(
                        stages: DriverPipelineStage.standard(installer: installer),
                        isActive: flowActive || installer.isBusy,
                        compact: true,
                        reduceMotion: reduceMotion
                    )

                    Divider().opacity(0.4)

                    HStack(alignment: .center, spacing: 14) {
                        IconBadge(systemImage: statusSymbol, tint: statusTint, size: 42)
                            .symbolEffect(.bounce, value: successPop)
                            .keyframeAnimator(initialValue: 1.0, trigger: successPop) { content, scale in
                                content.scaleEffect(scale)
                            } keyframes: { _ in
                                SpringKeyframe(1.25, duration: 0.2, spring: .snappy)
                                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(Theme.Typography.headline)
                                .contentTransition(.opacity)
                            Text(statusDetail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentTransition(.opacity)
                        }
                        Spacer(minLength: 8)
                        actionButton
                    }

                    if let step = runningStep {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            StripedProgressBar(progress: nil, tint: Theme.teal)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let message = problemMessage {
                        DiscoveryInlineNote(systemImage: "exclamationmark.triangle", text: message)
                            .transition(.opacity)
                    }
                }
            }
            .onboardingAppear(3, reduceMotion: reduceMotion)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: installer.phase)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: installer.status)

            HStack(alignment: .top, spacing: 12) {
                OnboardingInfoTile(symbol: "point.3.connected.trianglepath.dotted", title: tr("CUPS-Integration"),
                                   text: tr("Ein CUPS-Filter und PPD-Dateien für alle unterstützten Zebra-Modelle unter /Library/Printers."),
                                   tint: Theme.teal)
                    .onboardingAppear(4, reduceMotion: reduceMotion)
                OnboardingInfoTile(symbol: "lock.shield", title: tr("Einmalig als Administrator"),
                                   text: tr("macOS fragt einmal nach einem Administratorpasswort. Es werden nur LabelWerk-Dateien angelegt."),
                                   tint: Theme.violet)
                    .onboardingAppear(5, reduceMotion: reduceMotion)
                OnboardingInfoTile(symbol: "hand.thumbsup", title: tr("Jederzeit änderbar"),
                                   text: tr("Designer, Werkzeuge und Direktdruck funktionieren auch ohne Treiber. Unter „Treiber & Warteschlangen“ lässt er sich später installieren oder entfernen."),
                                   tint: Theme.magenta)
                    .onboardingAppear(6, reduceMotion: reduceMotion)
            }
        }
        .task {
            await installer.refresh()
            if installer.isInstalled { pulseFlow(4) }
        }
        .onChange(of: installer.successCount) { _, _ in
            if !reduceMotion { successPop += 1 }
            pulseFlow(5)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if installer.isBusy {
            ProgressRing(progress: nil, size: 26, lineWidth: 3.5)
        } else {
            switch installer.status {
            case .notInstalled:
                if installer.hasPayload {
                    Button {
                        Task { await installer.install() }
                    } label: {
                        Label(tr("Jetzt installieren"), systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.labelWerkPrimary)
                }
            case .outdated:
                Button {
                    Task { await installer.install() }
                } label: {
                    Label(tr("Aktualisieren"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(!installer.hasPayload)
            case .current, .newerInstalled:
                Label(tr("Bereit"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ready)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var runningStep: String? {
        if case .running(_, let step) = installer.phase { return step }
        return nil
    }

    private var problemMessage: String? {
        switch installer.phase {
        case .failed(_, let message): return message
        case .cancelled: return tr("Installation abgebrochen – du kannst sie jederzeit wiederholen.")
        default: break
        }
        if installer.snapshot != nil && !installer.hasPayload && !installer.isInstalled {
            return tr("Diese App wurde ohne Treiberpaket gestartet (Entwicklungs-Build). Das App-Bundle aus „Scripts/build_app.sh“ enthält den Treiber. Du kannst trotzdem fortfahren.")
        }
        return nil
    }

    private var statusTint: Color {
        switch installer.status {
        case .notInstalled: return installer.hasPayload ? Theme.violet : Theme.warning
        case .current: return Theme.ready
        case .outdated: return Theme.printing
        case .newerInstalled: return Theme.ready
        }
    }

    private var statusSymbol: String {
        switch installer.status {
        case .notInstalled: return "shippingbox"
        case .current, .newerInstalled: return "checkmark.seal.fill"
        case .outdated: return "arrow.down.circle.fill"
        }
    }

    private var statusTitle: String {
        if installer.snapshot == nil { return tr("Treiber wird geprüft …") }
        switch installer.status {
        case .notInstalled: return installer.hasPayload ? tr("Noch nicht installiert") : tr("Treiberpaket fehlt in diesem Build")
        case .current(let version):
            return version.map { tr("Installiert – Version %@", $0) } ?? tr("Installiert")
        case .outdated(_, let bundled): return tr("Update auf %@ verfügbar", bundled)
        case .newerInstalled(let installed, _): return tr("Installiert – Version %@", installed)
        }
    }

    private var statusDetail: String {
        if installer.snapshot == nil { return tr("Einen Moment …") }
        switch installer.status {
        case .notInstalled:
            return installer.hasPayload
                ? tr("Die Installation dauert nur wenige Sekunden. Danach richtest du für jeden Drucker mit einem Klick eine macOS-Warteschlange ein.")
                : tr("Ohne Treiber stehen alle LabelWerk-Funktionen außer dem Drucken aus anderen Programmen zur Verfügung.")
        case .current, .newerInstalled:
            return tr("CUPS-Filter und %d PPD-Dateien sind installiert. Der Druckweg ist bereit.", installer.installedPPDCount)
        case .outdated(let installed, _):
            return tr("Installiert ist %@. Das Update bringt neue Modelle und Verbesserungen.", installed ?? tr("eine ältere Version"))
        }
    }

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
}

// MARK: - 3. Drucker

struct OnboardingPrintersPage: View {
    let reduceMotion: Bool
    let onManual: () -> Void

    @Environment(AppModel.self) private var model
    @State private var showInstallWizard = false

    var body: some View {
        VStack(spacing: 18) {
            OnboardingPageHeader(
                symbol: "printer.fill",
                title: tr("Drucker finden"),
                subtitle: tr("LabelWerk sucht gleichzeitig per Bonjour, USB, Netzwerk-Scan und in den macOS-Warteschlangen. Gefundene Drucker fügst du mit einem Klick hinzu."),
                tint: Theme.violet,
                reduceMotion: reduceMotion
            )

            GlassCard(padding: 18, cornerRadius: Theme.Metrics.cornerLarge) {
                DiscoveryPanel(style: .compact, onRequestManual: onManual)
            }
            .onboardingAppear(3, reduceMotion: reduceMotion)

            // Wie unter Windows: Netzwerkdrucker als macOS-Drucker installieren (eigener Assistent).
            PrinterSetupEntryCard {
                showInstallWizard = true
            }
            .onboardingAppear(4, reduceMotion: reduceMotion)

            if !model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Text(tr("Eingerichtet"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    DiscoveryFlowLayout(spacing: 8) {
                        ForEach(model.sessions) { session in
                            HStack(spacing: 7) {
                                StatusOrb(state: session.state, size: 8)
                                Image(systemName: session.model?.systemImage ?? "printer")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(session.accentColor)
                                Text(session.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.regularMaterial))
                            .overlay(Capsule().strokeBorder(session.accentColor.opacity(0.4), lineWidth: 1))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: model.sessions.map(\.id))
        .sheet(isPresented: $showInstallWizard) {
            NetworkPrinterInstallWizard()
                .environment(model)
        }
    }
}

// MARK: - 4. Mitteilungen

/// Berechtigungsstatus für Systemmitteilungen.
enum OnboardingNotificationStatus: Equatable {
    case checking, unavailable, notDetermined, authorized, denied
}

enum OnboardingNotificationProbe {
    /// `UNUserNotificationCenter` benötigt ein echtes App-Bundle (nicht bei `swift run`).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func status() async -> OnboardingNotificationStatus {
        guard isAvailable else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

struct OnboardingNotificationsPage: View {
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var status: OnboardingNotificationStatus = .checking
    @State private var bell = 0
    @State private var requesting = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 20) {
            OnboardingPageHeader(
                symbol: "bell.badge.fill",
                title: tr("Mitteilungen"),
                subtitle: tr("LabelWerk meldet sich, wenn ein Drucker Hilfe braucht – auch wenn das Fenster geschlossen ist. Mit konkreten Lösungsschritten."),
                tint: Theme.magenta,
                reduceMotion: reduceMotion,
                wiggle: bell
            )

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Beispiele"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    examplePreview(PrinterAlert.make(.mediaOut), index: 0)
                    examplePreview(PrinterAlert.make(.headOpen), index: 1)
                    examplePreview(PrinterAlert.make(.ribbonOut), index: 2)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onboardingAppear(3, reduceMotion: reduceMotion)

                GlassCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        permissionRow
                        Divider().opacity(0.4)
                        Toggle(isOn: $model.preferences.notificationsEnabled) {
                            settingLabel(tr("Mitteilungen bei Druckerfehlern"), tr("Etiketten leer, Druckkopf offen, Farbband leer …"))
                        }
                        Toggle(isOn: $model.preferences.playSounds) {
                            settingLabel(tr("Töne abspielen"), tr("Dezenter Ton nach dem Druck und bei Fehlern"))
                        }
                        Toggle(isOn: $model.preferences.showMenuBarExtra) {
                            settingLabel(tr("Symbol in der Menüleiste"), tr("Status aller Drucker und Schnellaktionen – LabelWerk läuft im Hintergrund weiter"))
                        }
                    }
                    .toggleStyle(.switch)
                }
                .frame(maxWidth: .infinity)
                .onboardingAppear(4, reduceMotion: reduceMotion)
            }
        }
        .task {
            status = await OnboardingNotificationProbe.status()
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(600))
                bell += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await OnboardingNotificationProbe.status() }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: status)
    }

    @ViewBuilder
    private var permissionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: permissionSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(permissionTint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(permissionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                Text(permissionDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            switch status {
            case .notDetermined:
                Button {
                    requestPermission()
                } label: {
                    Label(tr("Erlauben"), systemImage: "bell.fill")
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(requesting)
            case .denied:
                Button {
                    openNotificationSettings()
                } label: {
                    Label(tr("Systemeinstellungen"), systemImage: "gearshape")
                }
                .buttonStyle(.labelWerkSecondary)
            case .checking:
                ProgressView().controlSize(.small)
            case .authorized, .unavailable:
                EmptyView()
            }
        }
    }

    private var permissionSymbol: String {
        switch status {
        case .checking: return "bell"
        case .unavailable: return "bell.slash"
        case .notDetermined: return "bell.badge"
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "bell.slash.fill"
        }
    }

    private var permissionTint: Color {
        switch status {
        case .checking, .notDetermined: return Theme.accent
        case .unavailable: return Theme.offline
        case .authorized: return Theme.ready
        case .denied: return Theme.error
        }
    }

    private var permissionTitle: String {
        switch status {
        case .checking: return tr("Berechtigung wird geprüft …")
        case .unavailable: return tr("Im Entwicklungs-Build nicht verfügbar")
        case .notDetermined: return requesting ? tr("Bitte im Systemdialog bestätigen …") : tr("Noch nicht erlaubt")
        case .authorized: return tr("Mitteilungen erlaubt")
        case .denied: return tr("Mitteilungen abgelehnt")
        }
    }

    private var permissionDetail: String {
        switch status {
        case .checking: return tr("Einen Moment …")
        case .unavailable: return tr("Systemmitteilungen benötigen das fertige App-Bundle. Fehler erscheinen weiterhin als Hinweis im Fenster.")
        case .notDetermined: return tr("macOS fragt einmalig, ob LabelWerk Mitteilungen senden darf.")
        case .authorized: return tr("Du wirst bei Druckerfehlern benachrichtigt.")
        case .denied: return tr("In den Systemeinstellungen unter „Mitteilungen“ kannst du sie für LabelWerk aktivieren.")
        }
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func examplePreview(_ alert: PrinterAlert, index: Int) -> some View {
        let printerName = model.sessions.first?.displayName ?? "Zebra ZD421t"
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "printer.filled.and.paper")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: "LabelWerk")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: alert.systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(alert.severity.color)
                }
                Text(verbatim: "\(printerName): \(tr(alert.title))")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(tr(alert.recovery))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .onboardingAppear(4 + index, reduceMotion: reduceMotion)
    }

    private func requestPermission() {
        requesting = true
        if !reduceMotion { bell += 1 }
        NotificationService.shared.setUp()
        Task {
            // Der Systemdialog antwortet asynchron – kurz nachfragen, bis eine Entscheidung vorliegt.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                let current = await OnboardingNotificationProbe.status()
                if current != .notDetermined {
                    status = current
                    break
                }
            }
            requesting = false
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 5. Fertig

struct OnboardingDonePage: View {
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var burst = 0
    @State private var pop = 0

    private var installer: DriverInstaller { DriverInstaller.shared }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                CelebrationBurst(trigger: burst, colors: [Theme.violet, Theme.teal, Theme.magenta, Theme.ready])
                    .frame(width: 460, height: 320)
                Circle()
                    .fill(Theme.brandAngularGradient)
                    .frame(width: 150, height: 150)
                    .blur(radius: 40)
                    .opacity(0.6)
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 104, height: 104)
                    .overlay(Circle().fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                                          startPoint: .top, endPoint: .center)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
                    .shadow(color: Theme.violet.opacity(0.5), radius: 18, y: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: pop)
            }
            .frame(height: 150)
            .keyframeAnimator(initialValue: 1.0, trigger: pop) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(0.82, duration: 0.12)
                SpringKeyframe(1.12, duration: 0.3, spring: .bouncy)
                SpringKeyframe(1.0, duration: 0.5, spring: .smooth)
            }
            .onboardingAppear(0, reduceMotion: reduceMotion)

            VStack(spacing: 6) {
                Text(tr("Alles bereit!"))
                    .font(Theme.Typography.hero)
                Text(tr("LabelWerk ist eingerichtet. Alles Weitere findest du jederzeit in der Seitenleiste."))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .onboardingAppear(1, reduceMotion: reduceMotion)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .top)], spacing: 12) {
                summaryTile(symbol: "printer.fill", title: tr("Drucker"),
                            value: model.sessions.isEmpty ? tr("Noch keiner") : tr("%d eingerichtet", model.sessions.count),
                            detail: model.sessions.isEmpty
                                ? tr("Mit ⇧⌘N jederzeit hinzufügen")
                                : model.sessions.map(\.displayName).joined(separator: ", "),
                            ok: !model.sessions.isEmpty, index: 0)
                summaryTile(symbol: "shippingbox.fill", title: tr("Treiber"),
                            value: installer.isInstalled ? tr("Installiert") : tr("Nicht installiert"),
                            detail: installer.installedVersion.map { tr("Version %@", $0) } ?? tr("Unter „Treiber & Warteschlangen“"),
                            ok: installer.isInstalled, index: 1)
                summaryTile(symbol: "bell.badge.fill", title: tr("Mitteilungen"),
                            value: model.preferences.notificationsEnabled ? tr("Ein") : tr("Aus"),
                            detail: tr("Bei Druckerfehlern"),
                            ok: model.preferences.notificationsEnabled, index: 2)
                summaryTile(symbol: "menubar.rectangle", title: tr("Menüleiste"),
                            value: model.preferences.showMenuBarExtra ? tr("Ein") : tr("Aus"),
                            detail: tr("Status & Schnellaktionen"),
                            ok: model.preferences.showMenuBarExtra, index: 3)
            }

            HStack(spacing: 18) {
                shortcut("⇧⌘N", tr("Drucker hinzufügen"))
                shortcut("⌥⌘D", tr("Etiketten-Designer"))
                shortcut("⇧⌘T", tr("Testetikett"))
            }
            .onboardingAppear(8, reduceMotion: reduceMotion)
        }
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(350))
            pop += 1
            burst += 1
        }
    }

    private func summaryTile(symbol: String, title: String, value: String, detail: String, ok: Bool, index: Int) -> some View {
        GlassCard(padding: 14, tint: ok ? Theme.ready : nil) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(systemImage: symbol, tint: ok ? Theme.ready : Theme.offline, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .onboardingAppear(4 + index, reduceMotion: reduceMotion)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: keys)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

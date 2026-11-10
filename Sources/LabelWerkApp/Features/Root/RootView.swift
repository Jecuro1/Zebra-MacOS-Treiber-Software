import AppKit
import SwiftUI
import LabelWerkKit

/// Hauptfenster: Seitenleiste + Detailbereich, Hinweise, Onboarding.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        @Bindable var updates: UpdateController = model.updates
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: Theme.Metrics.sidebarWidth, max: 340)
        } detail: {
            DetailRouter()
        }
        .navigationSplitViewStyle(.balanced)
        .background(MainWindowRegistrar())
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                // „Update verfügbar“ (Update-Dienst) über den Hinweisen.
                if updates.showsBanner {
                    UpdateBanner()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.95))
                        ))
                }
                ToastOverlay()
            }
            .padding(Theme.Metrics.paddingLarge)
            .animation(Motion.animation(Motion.spring, reduceMotion: model.reducesMotion), value: updates.showsBanner)
        }
        .sheet(isPresented: $updates.isDetailsPresented) {
            UpdateDetailsSheet()
                .environment(model)
                .environment(\.appReduceMotion, model.preferences.reduceMotion)
        }
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environment(model)
        }
        .sheet(isPresented: $model.isAddPrinterPresented) {
            AddPrinterView()
                .environment(model)
        }
        .sheet(isPresented: $model.isInstallWizardPresented, onDismiss: {
            // Die Vorbelegung („Im Netzwerk“ › Hinzufügen) gilt nur für dieses eine Öffnen.
            model.installWizardPrefill = nil
        }) {
            NetworkPrinterInstallWizard(prefill: model.installWizardPrefill)
                .environment(model)
        }
        .preferredColorScheme(colorScheme(for: model.preferences.appearance))
        .tint(Theme.accent)
        .environment(\.appReduceMotion, model.preferences.reduceMotion)
        .task {
            // Die Mitteilungs-Berechtigung fragt das Onboarding gezielt an.
            if model.hasCompletedOnboarding { NotificationService.shared.setUp() }
            NotificationService.shared.onOpenPrinter = { id in
                model.selection = .printer(id)
                _ = MainWindow.bringToFront()
            }
            // Wirkt nur beim ersten Hauptfenster (siehe `AppModel.start()`).
            model.start()
            // Vom Installationspaket mit `--setup` geöffnet (wie ein Windows-Setup, das mit „Drucker
            // einrichten“ endet): direkt der Installationsassistent. Beim ersten Start kommt zuerst
            // der Willkommensassistent (mit Einstieg „Netzwerkdrucker installieren“) – der
            // Installationsassistent folgt nach dessen Ende, falls dort kein Drucker eingerichtet wurde.
            if PrinterSetupLaunch.consumeSetupRequest() {
                if model.isOnboardingPresented {
                    model.pendingInstallWizard = true
                } else {
                    model.isInstallWizardPresented = true
                }
            }
        }
        .onChange(of: model.isOnboardingPresented) { _, shown in
            guard !shown, model.pendingInstallWizard else { return }
            model.pendingInstallWizard = false
            // Im Willkommensassistenten schon Drucker eingerichtet: nicht noch einmal fragen.
            guard model.sessions.isEmpty else { return }
            Task { @MainActor in
                // Erst, wenn das Sheet des Willkommensassistenten geschlossen ist (nur ein Sheet zugleich).
                try? await Task.sleep(for: .milliseconds(450))
                guard !model.isOnboardingPresented, !model.isAddPrinterPresented else { return }
                model.isInstallWizardPresented = true
            }
        }
    }

    private func colorScheme(for appearance: AppearancePreference) -> ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Das Hauptfenster der App. Menüleiste und Benachrichtigungen holen es nach vorn, statt ein
/// weiteres zu öffnen (`openWindow` öffnet bei einer `WindowGroup` immer ein neues Fenster).
@MainActor
enum MainWindow {
    private static weak var window: NSWindow?

    static func register(_ window: NSWindow) {
        self.window = window
    }

    /// Holt das offene Hauptfenster nach vorn; `false`, wenn keins offen ist.
    static func bringToFront() -> Bool {
        guard let window else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        } else if !window.isVisible {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Meldet das Fenster, in dem `RootView` liegt, an `MainWindow`.
private struct MainWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrarView { RegistrarView() }
    func updateNSView(_ nsView: RegistrarView, context: Context) {}

    final class RegistrarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.register(window) }
        }
    }
}

/// Wählt die Detailansicht passend zur Seitenleisten-Auswahl.
struct DetailRouter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Group {
            switch model.selection {
            case .printer(let id):
                if let session = model.session(for: id) {
                    PrinterDetailView(session: session)
                        .id(id)
                } else {
                    noSelection
                }
            case .designer:
                DesignerView()
            case .history:
                HistoryView(printerID: nil)
            case .driver:
                DriverView()
            case .discover:
                DiscoveryView()
            case nil:
                noSelection
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .animation(Motion.animation(Motion.spring, reduceMotion: systemReduceMotion || model.preferences.reduceMotion),
                   value: model.selection)
    }

    private var noSelection: some View {
        EmptyStateView(
            title: tr("Kein Drucker ausgewählt"),
            message: tr("Wähle links einen Drucker oder füge einen neuen hinzu."),
            systemImage: "printer",
            actionTitle: tr("Drucker hinzufügen"),
            action: { model.isAddPrinterPresented = true }
        )
    }
}

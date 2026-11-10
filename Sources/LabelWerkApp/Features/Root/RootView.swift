import AppKit
import SwiftUI
import LabelWerkKit

/// Hauptfenster: Seitenleiste + Detailbereich, Hinweise, Onboarding.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: Theme.Metrics.sidebarWidth, max: 340)
        } detail: {
            DetailRouter()
        }
        .navigationSplitViewStyle(.balanced)
        .background(MainWindowRegistrar())
        .overlay(alignment: .bottomTrailing) {
            ToastOverlay()
                .padding(Theme.Metrics.paddingLarge)
        }
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environment(model)
        }
        .sheet(isPresented: $model.isAddPrinterPresented) {
            AddPrinterView()
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

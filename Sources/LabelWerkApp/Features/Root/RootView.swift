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
        .task {
            NotificationService.shared.setUp()
            NotificationService.shared.onOpenPrinter = { id in
                model.selection = .printer(id)
            }
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

/// Wählt die Detailansicht passend zur Seitenleisten-Auswahl.
struct DetailRouter: View {
    @Environment(AppModel.self) private var model

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
        .animation(Motion.spring, value: model.selection)
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

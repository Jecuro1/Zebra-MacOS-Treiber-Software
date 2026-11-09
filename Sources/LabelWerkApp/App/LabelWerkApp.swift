import AppKit
import SwiftUI
import LabelWerkKit

@main
struct LabelWerkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LabelWerk", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { appDelegate.model = model }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1320, height: 860)
        .commands { LabelWerkCommands(model: model) }

        Settings {
            AppSettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $model.preferences.showMenuBarExtra) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarIcon(state: model.aggregateState, alertCount: model.activeAlertCount)
        }
        .menuBarExtraStyle(.window)
    }
}

/// App-Delegate: Fenster nach Schließen weiter im Hintergrund (Menüleiste), sauberes Speichern.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Mit Menüleisten-Extra weiterlaufen, damit Statusmeldungen ankommen.
        MainActor.assumeIsolated { !(model?.preferences.showMenuBarExtra ?? false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.saveNow() }
    }
}

/// Symbol in der Menüleiste – spiegelt den schlechtesten Druckerzustand wider.
struct MenuBarIcon: View {
    let state: PrinterState
    let alertCount: Int

    var body: some View {
        let symbol: String = {
            switch state {
            case .error: return "exclamationmark.octagon.fill"
            case .warning, .paused: return "exclamationmark.triangle.fill"
            case .printing: return "printer.filled.and.paper"
            default: return "printer"
            }
        }()
        if alertCount > 0 {
            Label("\(alertCount)", systemImage: symbol)
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: symbol)
        }
    }
}

/// Menübefehle (Tastaturkürzel).
struct LabelWerkCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(tr("Drucker hinzufügen …")) { model.isAddPrinterPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(tr("Demo-Drucker hinzufügen")) { model.addDemoPrinter() }
        }
        CommandMenu(tr("Drucker")) {
            Button(tr("Testetikett drucken")) {
                if let session = model.selectedSession { Task { await session.printTestLabel() } }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.selectedSession == nil)

            Button(tr("Status aktualisieren")) {
                if let session = model.selectedSession { Task { await session.refresh() } }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.selectedSession == nil)

            Button(tr("Kalibrieren")) {
                if let session = model.selectedSession { Task { await session.perform(.calibrate) } }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.selectedSession == nil)

            Button(tr("Etikett vorschieben")) {
                if let session = model.selectedSession { Task { await session.perform(.feedLabel) } }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.selectedSession == nil)

            Divider()

            ForEach(Array(PrinterSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    if let session = model.selectedSession { session.section = section }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                .disabled(model.selectedSession == nil)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(tr("Etiketten-Designer")) { model.selection = .designer }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button(tr("Auftragsverlauf")) { model.selection = .history }
                .keyboardShortcut("y", modifiers: [.command, .option])
            Button(tr("Treiber & Warteschlangen")) { model.selection = .driver }
        }
    }
}

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
                .environment(\.appReduceMotion, model.preferences.reduceMotion)
        }

        MenuBarExtra(isInserted: $model.preferences.showMenuBarExtra) {
            MenuBarView()
                .environment(model)
                .environment(\.appReduceMotion, model.preferences.reduceMotion)
        } label: {
            MenuBarIcon(state: model.aggregateState, alertCount: model.activeAlertCount)
        }
        .menuBarExtraStyle(.window)
    }
}

/// App-Delegate: Fenster nach Schließen weiter im Hintergrund (Menüleiste), sauberes Speichern.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Schreiben in eine Pipe/einen Socket, dessen Gegenstelle beendet ist (z. B. `lp`, das
        // vorzeitig abbricht), soll einen Fehler liefern statt die App per SIGPIPE zu beenden.
        signal(SIGPIPE, SIG_IGN)
    }

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

/// „Nach Updates suchen …“ im App-Menü. Das Ergebnis (Details-Sheet bzw. Hinweise) erscheint im
/// Hauptfenster – ist keins offen (nur Einstellungen oder Menüleiste), wird es geöffnet, wie bei
/// „LabelWerk öffnen“ in der Menüleiste.
private struct CheckForUpdatesCommand: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(tr("Nach Updates suchen …")) {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            if !MainWindow.bringToFront() {
                openWindow(id: "main")
            }
            model.updates.checkNow(userInitiated: true)
        }
        .disabled(model.updates.isInstalling)
    }
}

/// Menübefehle (Tastaturkürzel).
struct LabelWerkCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // App-Menü unter „Über LabelWerk“: Update-Dienst (Details erscheinen im Hauptfenster).
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(model: model)
        }
        // Ersetzt „Neues Fenster“: Es gibt genau ein Hauptfenster (alle Fenster teilten sich sonst
        // dieselben Sheets wie „Drucker hinzufügen“). Die Menüleiste holt es nach vorn.
        CommandGroup(replacing: .newItem) {
            Button(tr("Drucker hinzufügen …")) { model.isAddPrinterPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                // Kürzel wirken auch hinter einem Sheet – nie ein zweites über einem offenen öffnen.
                .disabled(model.isInstallWizardPresented || model.isOnboardingPresented)
            // Wie „Drucker hinzufügen“ unter Windows: als macOS-Drucker mit LabelWerk-Treiber einrichten.
            Button(tr("Drucker installieren …")) { model.isInstallWizardPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.isOnboardingPresented || model.isAddPrinterPresented)
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

            // ⌘1 … ⌘9 folgen den sichtbaren Bereichen des gewählten Druckers (wie die Tab-Leiste).
            let sections = model.selectedSession?.availableSections ?? []
            if !sections.isEmpty {
                Divider()

                ForEach(Array(sections.prefix(9).enumerated()), id: \.element) { index, section in
                    Button(section.title) {
                        if let session = model.selectedSession, session.availableSections.contains(section) {
                            session.section = section
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }
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

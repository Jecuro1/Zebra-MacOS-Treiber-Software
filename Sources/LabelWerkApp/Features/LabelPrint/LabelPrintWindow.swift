import AppKit
import SwiftUI
import LabelWerkKit

/// Das Fenster „Etikettendruck“ – genau eins, unabhängig vom Hauptfenster (das bleibt das einzige
/// Hauptfenster, siehe `MainWindow`). Als AppKit-Fenster mit SwiftUI-Inhalt, damit es auch ohne offenes
/// Hauptfenster erscheint (LabelWerk läuft dann nur in der Menüleiste) und Dokumente, die macOS beim
/// Start übergibt („Mit LabelWerk drucken“, „Öffnen mit“), sofort anzeigt.
@MainActor
final class LabelPrintWindowController: NSObject, NSWindowDelegate {
    static let shared = LabelPrintWindowController()

    let store = LabelPrintStore()
    private var window: NSWindow?

    /// Öffnet Dateien und holt das Fenster nach vorn.
    func open(_ urls: [URL], model: AppModel) {
        show(model: model)
        store.open(urls)
    }

    /// Zeigt das Fenster (legt es beim ersten Mal an).
    func show(model: AppModel) {
        store.model = model
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let root = LabelPrintWindowRoot(store: store).environment(model)
        let hosting = NSHostingController(rootView: root)
        // Nur die Mindestgröße folgt dem SwiftUI-Inhalt; die Fenstergröße bestimmt der Benutzer.
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = tr("Etikettendruck")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 980, height: 640)
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private static let frameName = "LabelWerk.LabelPrintWindow"

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Dokumente freigeben; das Fenster selbst bleibt für das nächste Öffnen erhalten.
        store.closeDocuments()
    }
}

/// Wurzel des Fensters: Umgebung wie im Hauptfenster (Erscheinungsbild, „Bewegung reduzieren“,
/// Akzentfarbe) und Fenstertitel.
private struct LabelPrintWindowRoot: View {
    let store: LabelPrintStore
    @Environment(AppModel.self) private var model

    var body: some View {
        LabelPrintView(store: store)
            .frame(minWidth: 960, minHeight: 600)
            .preferredColorScheme(colorScheme)
            .tint(Theme.accent)
            .environment(\.appReduceMotion, model.preferences.reduceMotion)
            .background(LabelPrintWindowTitle(title: store.documents.isEmpty ? tr("Etikettendruck")
                                                  : tr("Etikettendruck – %@", store.title)))
    }

    private var colorScheme: ColorScheme? {
        switch model.preferences.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Setzt den Titel des umgebenden AppKit-Fensters (Fenstermenü, Mission Control).
private struct LabelPrintWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

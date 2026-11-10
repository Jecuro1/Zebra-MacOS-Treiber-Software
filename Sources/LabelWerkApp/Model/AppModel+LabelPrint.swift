import AppKit
import Foundation
import UniformTypeIdentifiers
import LabelWerkKit

/// Etikettendruck („Mit LabelWerk drucken“, „Datei drucken …“, Dateien auf LabelWerk ziehen bzw. mit
/// LabelWerk öffnen). Der Zustand liegt im Fenster-Controller (`LabelPrintWindowController.shared`),
/// damit `AppModel` dafür keine eigenen Felder braucht.
extension AppModel {
    /// Öffnet PDFs und Bilder im Fenster „Etikettendruck“ (holt es nach vorn). Andere Dateien werden
    /// mit einem Hinweis übergangen.
    func openForLabelPrint(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        let supported = files.filter(LabelPrintDocument.isSupported)
        let skipped = files.filter { !LabelPrintDocument.isSupported($0) }
        if !skipped.isEmpty {
            toast(tr("Nicht unterstütztes Format"),
                  message: tr("Etikettendruck öffnet PDF-Dateien und Bilder (PNG, JPEG, TIFF, HEIC). Übergangen: %@",
                              skipped.map(\.lastPathComponent).joined(separator: ", ")),
                  style: .warning)
        }
        guard !supported.isEmpty else { return }
        LabelPrintWindowController.shared.open(supported, model: self)
    }

    /// „Datei drucken …“: Auswahl im Öffnen-Dialog, dann Etikettendruck.
    func chooseFilesForLabelPrint() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = tr("Datei drucken")
        panel.message = tr("PDF oder Bild wählen – LabelWerk zeigt genau, wie das Etikett gedruckt wird.")
        panel.prompt = tr("Öffnen")
        panel.allowedContentTypes = LabelPrintDocument.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openForLabelPrint(panel.urls)
    }

    /// Zeigt das Fenster „Etikettendruck“ (leer, falls noch nichts geöffnet ist).
    func showLabelPrintWindow() {
        LabelPrintWindowController.shared.show(model: self)
    }

    /// Dateien aus einem Ziehen-und-Ablegen (z. B. auf das Hauptfenster). `true`, wenn Datei-URLs
    /// dabei sind (sie werden asynchron geladen und dann geöffnet).
    func handleLabelPrintDrop(_ providers: [NSItemProvider]) -> Bool {
        LabelPrintDrop.loadFileURLs(from: providers) { [weak self] urls in
            self?.openForLabelPrint(urls)
        }
    }
}

/// Liest Datei-URLs aus abgelegten Objekten (Finder, Mail-Anhänge …).
enum LabelPrintDrop {
    @discardableResult
    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let identifier = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(identifier) }
        guard !matching.isEmpty else { return false }
        let collector = URLCollector(expected: matching.count, completion: completion)
        for provider in matching {
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                collector.add(url)
            }
        }
        return true
    }

    /// Sammelt die asynchron geladenen URLs und meldet sie einmal gemeinsam (in Ablagereihenfolge
    /// des Ladens) auf dem Main Actor.
    private final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var urls: [URL] = []
        private let completion: @MainActor ([URL]) -> Void

        init(expected: Int, completion: @escaping @MainActor ([URL]) -> Void) {
            remaining = expected
            self.completion = completion
        }

        func add(_ url: URL?) {
            lock.lock()
            if let url { urls.append(url) }
            remaining -= 1
            let done = remaining == 0
            let result = urls
            lock.unlock()
            guard done else { return }
            let completion = self.completion
            Task { @MainActor in completion(result) }
        }
    }
}

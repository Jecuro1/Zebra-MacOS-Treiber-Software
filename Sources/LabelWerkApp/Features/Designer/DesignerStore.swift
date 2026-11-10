import Foundation
import Observation
import SwiftUI

/// Schlüssel in den Benutzereinstellungen für den Dokumenttitel.
private let designerTitleDefaultsKey = "designer.documentTitle"

/// Inhalt, der das Editordokument ersetzen soll. Ist das Dokument seit dem letzten Laden bzw.
/// Erzeugen verändert worden, wartet er auf die Bestätigung „Ersetzen / Anhängen / Abbrechen“.
struct DesignerReplacement: Identifiable {
    enum Origin {
        /// Vorlage aus dem Menü „Vorlagen“.
        case template
        /// ZPL-/Textdatei (Öffnen, Ablegen).
        case file
        /// Übernahme aus „Bild & PDF“ (danach wird in den Editor gewechselt).
        case image
    }

    let id = UUID()
    var zpl: String
    var title: String
    var systemImage: String
    var origin: Origin
    /// Hinweis im Editor nach dem Ersetzen (z. B. „Vorlage: Versandetikett“).
    var notice: String
}

/// Designer-Zustand, der das Verlassen des Bereichs überdauert. `DetailRouter` erzeugt
/// `DesignerView` bei jedem Wechsel in der Seitenleiste neu – Vorschau, geladenes Bild samt
/// Einstellungen, Arbeitsbereich und Titel bleiben hier erhalten (wie `AppModel.designerDocument`).
@Observable
@MainActor
final class DesignerStore {
    static let shared = DesignerStore()

    let preview = DesignerPreviewState()
    let image = DesignerImageState()
    var mode: DesignerMode = .zpl
    /// Titel für Auftragsverlauf und Dateinamen; bleibt auch zwischen Starts erhalten.
    var documentTitle: String = UserDefaults.standard.string(forKey: designerTitleDefaultsKey) ?? "" {
        didSet {
            guard documentTitle != oldValue else { return }
            UserDefaults.standard.set(documentTitle, forKey: designerTitleDefaultsKey)
        }
    }
    /// Wartet auf die Bestätigung im Dialog von `DesignerView`.
    var pendingReplacement: DesignerReplacement?
    /// Kurzer Hinweis in der Fußzeile des Editors.
    private(set) var notice: DesignerNotice?

    /// Zuletzt selbst erzeugter bzw. geladener Inhalt – solange das Dokument ihm entspricht, gehen
    /// beim Ersetzen keine Änderungen verloren.
    @ObservationIgnored private var lastGenerated: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    private init() {}

    /// `true`, solange das Dokument leer ist oder dem zuletzt erzeugten/geladenen Inhalt entspricht.
    func isUnmodified(_ document: String) -> Bool {
        document == lastGenerated || document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Merkt sich `document` als unverändert (z. B. nach dem Erzeugen der Startvorlage).
    func markGenerated(_ document: String) {
        lastGenerated = document
    }

    /// Ersetzt sofort, wenn dabei nichts verloren geht – sonst wird nachgefragt.
    /// - Returns: `true`, wenn das Dokument sofort ersetzt wurde.
    @discardableResult
    func request(_ replacement: DesignerReplacement, in model: AppModel) -> Bool {
        guard isUnmodified(model.designerDocument) else {
            pendingReplacement = replacement
            return false
        }
        apply(replacement, append: false, in: model)
        return true
    }

    /// Ersetzt das Dokument bzw. hängt den Inhalt als weiteres Etikett an.
    func apply(_ replacement: DesignerReplacement, append: Bool, in model: AppModel) {
        pendingReplacement = nil
        if append {
            model.designerDocument = DesignerZPLFormatter.append(format: replacement.zpl, to: model.designerDocument)
            showNotice(tr("Angehängt: %@", replacement.title), systemImage: replacement.systemImage)
        } else {
            model.designerDocument = replacement.zpl
            documentTitle = replacement.title
            showNotice(replacement.notice, systemImage: replacement.systemImage)
        }
        lastGenerated = model.designerDocument
    }

    /// Zeigt einen Hinweis für gut zwei Sekunden in der Fußzeile des Editors.
    func showNotice(_ text: String, systemImage: String) {
        noticeTask?.cancel()
        notice = DesignerNotice(text: text, systemImage: systemImage)
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

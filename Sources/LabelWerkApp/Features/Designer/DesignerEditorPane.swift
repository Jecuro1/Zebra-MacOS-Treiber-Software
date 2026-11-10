import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// ZPL-Editor mit Vorlagen, Bausteinen, Aufräumen, Öffnen/Sichern und Drag & Drop.
struct DesignerEditorPane: View {
    let target: DesignerTarget
    @Binding var documentTitle: String
    let reduceMotion: Bool
    let onPrint: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @State private var pendingTemplate: DesignerTemplate?
    @State private var lastGenerated = ""
    @State private var notice: DesignerNotice?
    @State private var noticeTask: Task<Void, Never>?
    @State private var formatCount = 0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            titleRow
            toolRow
            Divider().opacity(0.6)
            CodeEditor(text: $model.designerDocument, language: .zpl, onSubmit: { onPrint() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footer
        }
        .labelWerkGlass(cornerRadius: Theme.Metrics.corner)
        .overlay { dropOverlay }
        .animation(reduceMotion ? nil : Motion.snappy, value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            DesignerFiles.loadFileURL(from: providers) { url in openDocument(url) }
        }
        .onChange(of: model.designerDocument) { oldValue, newValue in
            detectDroppedPath(old: oldValue, new: newValue)
        }
        .confirmationDialog(tr("Vorlage übernehmen?"),
                            isPresented: Binding(get: { pendingTemplate != nil },
                                                 set: { if !$0 { pendingTemplate = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingTemplate) { template in
            Button(tr("Dokument ersetzen")) { applyTemplate(template, append: false) }
            Button(tr("Als weiteres Etikett anhängen")) { applyTemplate(template, append: true) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { template in
            Text(tr("„%@“ ersetzt den Inhalt des Editors – oder wird als zusätzliches Etikett angehängt.", template.title))
        }
        .onDisappear { noticeTask?.cancel() }
    }

    // MARK: Kopf

    private var titleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
            TextField(tr("Titel"), text: $documentTitle, prompt: Text(tr("Designer-Etikett")))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .help(tr("Titel für Auftragsverlauf und Dateinamen"))
            Spacer(minLength: 6)
            Button(action: openFile) {
                Image(systemName: "folder")
            }
            .buttonStyle(.labelWerkPlain)
            .keyboardShortcut("o", modifiers: [.command])
            .help(tr("ZPL-Datei öffnen … (⌘O)"))
            Button(action: saveFile) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.labelWerkPlain)
            .keyboardShortcut("s", modifiers: [.command])
            .help(tr("Als ZPL-Datei sichern … (⌘S)"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 4)
    }

    private var toolRow: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(DesignerTemplate.allCases) { template in
                    Button {
                        requestTemplate(template)
                    } label: {
                        Label(template.title, systemImage: template.systemImage)
                    }
                    .help(template.subtitle)
                }
            } label: {
                Label(tr("Vorlagen"), systemImage: "wand.and.stars")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(tr("Fertige Etiketten, berechnet für Größe und Auflösung des Ziels"))

            Menu {
                Section(tr("Text & Formen")) {
                    ForEach(DesignerSnippet.allCases.filter { !$0.isBarcode }) { snippet in
                        Button {
                            insert(snippet)
                        } label: {
                            Label(snippet.title, systemImage: snippet.systemImage)
                        }
                    }
                }
                Section(tr("Barcodes")) {
                    ForEach(DesignerSnippet.allCases.filter { $0.isBarcode }) { snippet in
                        Button {
                            insert(snippet)
                        } label: {
                            Label(snippet.title, systemImage: snippet.systemImage)
                        }
                    }
                }
                Section(tr("Grafik")) {
                    Button(action: chooseGraphic) {
                        Label(tr("Grafik aus Bild …"), systemImage: "photo")
                    }
                }
            } label: {
                Label(tr("Einfügen"), systemImage: "plus.square.on.square")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(tr("Element vor dem letzten ^XZ einfügen"))

            Menu {
                ForEach(DesignerZPLFormatter.Style.allCases) { style in
                    Button {
                        format(style)
                    } label: {
                        Label(style.title, systemImage: style.systemImage)
                    }
                }
            } label: {
                Label(tr("Aufräumen"), systemImage: "text.alignleft")
                    .symbolEffect(.bounce, value: formatCount)
            } primaryAction: {
                format(.perCommand)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(tr("Ein Befehl pro Zeile – bedeutungserhaltend"))

            Spacer(minLength: 4)

            Button {
                requestTemplate(.blank)
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("Neues, leeres Etikett"))
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    // MARK: Fuß

    private var footer: some View {
        let text = model.designerDocument
        let lines = DesignerZPLFormatter.lineCount(text)
        let formats = DesignerZPLFormatter.formatCount(text)
        return HStack(spacing: 12) {
            DesignerStat(systemImage: "list.number", text: tr("%d Zeilen", lines))
            DesignerStat(systemImage: "square.stack", text: tr("%d Formate", formats))
            DesignerStat(systemImage: "internaldrive", text: DesignerFormat.bytes(text.utf8.count))
            Spacer(minLength: 6)
            ZStack(alignment: .trailing) {
                if let notice {
                    DesignerNoticePill(notice: notice)
                        .id(notice.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                } else {
                    Text(tr("⌘↩ druckt · Datei hierher ziehen"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .animation(reduceMotion ? nil : Motion.spring, value: notice)
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            let shape = RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
            ZStack {
                shape.fill(Theme.violet.opacity(0.08))
                shape.strokeBorder(Theme.brandGradient, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.brandGradient)
                        .symbolEffect(.bounce, value: isDropTargeted)
                    Text(tr("Loslassen zum Öffnen"))
                        .font(Theme.Typography.headline)
                    Text(tr("ZPL- und Textdateien werden geöffnet, Bilder als Grafik eingefügt."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .labelWerkGlass(cornerRadius: 16)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Hinweise

    private func showNotice(_ text: String, systemImage: String) {
        noticeTask?.cancel()
        notice = DesignerNotice(text: text, systemImage: systemImage)
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: Vorlagen & Bausteine

    private func requestTemplate(_ template: DesignerTemplate) {
        let current = model.designerDocument
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == lastGenerated {
            applyTemplate(template, append: false)
        } else {
            pendingTemplate = template
        }
    }

    private func applyTemplate(_ template: DesignerTemplate, append: Bool) {
        let zpl = template.zpl(geometry: target.geometry)
        if append {
            model.designerDocument = DesignerZPLFormatter.append(format: zpl, to: model.designerDocument)
            showNotice(tr("Angehängt: %@", template.title), systemImage: template.systemImage)
        } else {
            model.designerDocument = zpl
            documentTitle = template.title
            showNotice(tr("Vorlage: %@", template.title), systemImage: template.systemImage)
        }
        lastGenerated = model.designerDocument
    }

    private func insert(_ snippet: DesignerSnippet) {
        let slot = DesignerZPLFormatter.fieldCount(model.designerDocument)
        let zpl = snippet.zpl(geometry: target.geometry, slot: slot)
        model.designerDocument = DesignerZPLFormatter.insert(zpl, into: model.designerDocument, geometry: target.geometry)
        showNotice(tr("Eingefügt: %@", snippet.title), systemImage: snippet.systemImage)
    }

    private func format(_ style: DesignerZPLFormatter.Style) {
        let formatted = DesignerZPLFormatter.format(model.designerDocument, style: style)
        guard formatted != model.designerDocument else {
            showNotice(tr("Bereits sauber formatiert"), systemImage: "checkmark")
            return
        }
        model.designerDocument = formatted
        formatCount += 1
        showNotice(tr("Formatiert: %@", style.title), systemImage: "wand.and.rays")
    }

    // MARK: Grafik

    private func chooseGraphic() {
        guard let url = DesignerFiles.chooseFile(title: tr("Bild als Grafik einfügen"), types: ImageImport.supportedTypes) else {
            return
        }
        insertGraphic(from: url)
    }

    private func insertGraphic(from url: URL) {
        let geometry = target.geometry
        let dpi = target.resolution.dpi
        let dither = model.preferences.imageDither
        let slot = DesignerZPLFormatter.fieldCount(model.designerDocument)
        showNotice(tr("Grafik wird gerastert …"), systemImage: "hourglass")
        Task {
            do {
                let graphic = try await Task.detached(priority: .userInitiated) {
                    try DesignerImageProcessing.graphicSnippet(url: url, dpi: dpi, geometry: geometry,
                                                               slot: slot, dither: dither)
                }.value
                model.designerDocument = DesignerZPLFormatter.insert(graphic.snippet, into: model.designerDocument,
                                                                     geometry: geometry)
                showNotice(tr("Grafik eingefügt (%d × %d Punkte)", graphic.width, graphic.height), systemImage: "photo")
            } catch {
                showNotice(tr("Grafik fehlgeschlagen"), systemImage: "exclamationmark.triangle")
                model.toast(tr("Grafik konnte nicht eingefügt werden"), message: PrinterSession.describe(error), style: .error)
            }
        }
    }

    // MARK: Dateien

    private func openFile() {
        guard let url = DesignerFiles.chooseFile(title: tr("ZPL-Datei öffnen"), types: DesignerFiles.zplTypes) else { return }
        openDocument(url)
    }

    /// Öffnet ZPL-/Textdateien; Bilder und PDFs werden als Grafik eingefügt.
    private func openDocument(_ url: URL) {
        if DesignerFiles.isImage(url) {
            insertGraphic(from: url)
            return
        }
        guard DesignerFiles.isDocument(url) else {
            model.toast(tr("Dateityp wird nicht unterstützt"), message: url.lastPathComponent, style: .warning)
            return
        }
        do {
            let text = try DesignerFiles.readText(url)
            model.designerDocument = text
            lastGenerated = text
            documentTitle = url.deletingPathExtension().lastPathComponent
            showNotice(tr("Geöffnet: %@", url.lastPathComponent), systemImage: "doc.text")
        } catch {
            model.toast(tr("Datei konnte nicht geöffnet werden"), message: PrinterSession.describe(error), style: .error)
        }
    }

    private func saveFile() {
        let title = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = DesignerFiles.safeFileName(title.isEmpty ? tr("Designer-Etikett") : title) + ".zpl"
        guard let url = DesignerFiles.chooseDestination(name: name, types: DesignerFiles.zplTypes,
                                                        title: tr("Als ZPL-Datei sichern")) else { return }
        do {
            try Data(model.designerDocument.utf8).write(to: url, options: .atomic)
            showNotice(tr("Gesichert: %@", url.lastPathComponent), systemImage: "checkmark.circle")
        } catch {
            model.toast(tr("Sichern fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }

    /// Legt man eine Datei direkt auf den Text, fügt die Textansicht ihren Pfad ein – dann
    /// stattdessen die Datei öffnen.
    private func detectDroppedPath(old: String, new: String) {
        guard let inserted = DesignerZPLFormatter.insertedText(old: old, new: new),
              let url = DesignerZPLFormatter.droppedFileURL(in: inserted) else { return }
        model.designerDocument = old
        openDocument(url)
    }
}

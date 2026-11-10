import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// ZPL-Arbeitsbereich: Editor links, Live-Vorschau rechts, Druckleiste unten.
struct DesignerZPLWorkspace: View {
    let target: DesignerTarget
    let session: PrinterSession?
    let preview: DesignerPreviewState
    @Binding var documentTitle: String
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var copies = 1
    @State private var printPhase: DesignerSendPhase = .idle
    @State private var printSuccessCount = 0
    @State private var copied = false

    private var effectiveTitle: String {
        let trimmed = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? tr("Designer-Etikett") : trimmed
    }

    var body: some View {
        let key = DesignerRenderKey(zpl: model.designerDocument, geometry: target.geometry)
        VStack(spacing: Theme.Metrics.spacing) {
            HSplitView {
                DesignerEditorPane(target: target, documentTitle: $documentTitle, reduceMotion: reduceMotion,
                                   onPrint: { printLabel() })
                    .frame(minWidth: 340, idealWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 6)
                DesignerPreviewPane(target: target, preview: preview, printTrigger: printSuccessCount,
                                    reduceMotion: reduceMotion)
                    .frame(minWidth: 380, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 6)
            }
            printBar
        }
        .task(id: key) {
            await preview.render(key, debounce: true)
        }
    }

    // MARK: Druckleiste

    private var printBar: some View {
        GlassCard(padding: 12, cornerRadius: Theme.Metrics.corner, tint: session?.accentColor) {
            HStack(spacing: 14) {
                destination
                Spacer(minLength: 8)
                if let session, session.saved.language != .zpl {
                    Label(tr("Drucker ist auf %@ eingestellt", session.saved.language.displayName),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                        .help(tr("ZPL wird nur von Druckern mit ZPL-Sprache verstanden. Ändere die Sprache in den Druckeinstellungen."))
                }
                Stepper(value: $copies, in: 1...9999) {
                    HStack(spacing: 4) {
                        Text(tr("Kopien"))
                            .foregroundStyle(.secondary)
                        Text(copies, format: .number)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(value: Double(copies)))
                            .animation(Motion.snappy, value: copies)
                    }
                    .font(.system(size: 12.5))
                }
                .fixedSize()

                Button(action: copyZPL) {
                    Label(copied ? tr("Kopiert") : tr("ZPL kopieren"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(model.designerDocument.isEmpty)

                Button(action: exportPNG) {
                    Label(tr("PNG …"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(preview.currentLabel == nil)
                .help(tr("Aktuelles Etikett pixelgenau als PNG exportieren"))

                DesignerSendButton(title: tr("Drucken"), systemImage: "printer.fill", phase: printPhase,
                                   reduceMotion: reduceMotion, action: { printLabel() })
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session == nil || printPhase == .sending)
                    .help(session == nil ? tr("Zuerst oben rechts einen Zieldrucker wählen")
                                         : tr("An %@ senden (⌘↩)", session?.displayName ?? ""))
            }
        }
    }

    private var destination: some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: session?.model?.systemImage ?? "printer", tint: session?.accentColor ?? Theme.offline, size: 32)
                .symbolEffect(.bounce, value: printSuccessCount)
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.displayName ?? tr("Kein Drucker ausgewählt"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(destinationDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
    }

    private var destinationDetail: String {
        let labels = max(preview.labels.count, DesignerZPLFormatter.formatCount(model.designerDocument))
        let bytes = DesignerFormat.bytes(model.designerDocument.utf8.count)
        guard let session else { return tr("Vorschau mit %d dpi · %@", target.resolution.dpi, bytes) }
        return tr("%@ · %d Etiketten × %d Kopien · %@", session.state.displayName, labels, copies, bytes)
    }

    // MARK: Aktionen

    private func printLabel() {
        guard printPhase != .sending else { return }
        guard let session else {
            model.toast(tr("Kein Drucker ausgewählt"),
                        message: tr("Wähle oben rechts einen Zieldrucker oder füge den Demo-Drucker hinzu."), style: .warning)
            return
        }
        let zpl = model.designerDocument
        guard DesignerZPLFormatter.formatCount(zpl) > 0 else {
            model.toast(tr("Kein Etikettenformat gefunden"),
                        message: tr("Das Dokument enthält kein Format zwischen ^XA und ^XZ."), style: .warning)
            return
        }
        let title = effectiveTitle
        let count = copies
        printPhase = .sending
        Task {
            let ok = await session.printZPL(zpl, title: title, copies: count)
            printPhase = ok ? .success : .failure
            if ok { printSuccessCount += 1 }
            try? await Task.sleep(for: .seconds(1.8))
            if printPhase != .sending { printPhase = .idle }
        }
    }

    private func copyZPL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.designerDocument, forType: .string)
        withAnimation(Motion.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.snappy) { copied = false }
        }
    }

    private func exportPNG() {
        guard let label = preview.currentLabel else { return }
        let suffix = preview.labels.count > 1 ? "-\(preview.labelIndex + 1)" : ""
        let name = DesignerFiles.safeFileName(effectiveTitle) + suffix + ".png"
        guard let url = DesignerFiles.chooseDestination(name: name, types: [.png],
                                                        title: tr("Etikett als PNG exportieren")) else { return }
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                PNGCodec.encode(SoftwareRasterizer.rasterize(label))
            }.value
            do {
                try data.write(to: url, options: .atomic)
                model.toast(tr("PNG exportiert"), message: url.lastPathComponent, style: .success)
            } catch {
                model.toast(tr("Export fehlgeschlagen"), message: error.localizedDescription, style: .error)
            }
        }
    }
}

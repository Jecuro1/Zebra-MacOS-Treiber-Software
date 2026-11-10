import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// „Etikettendruck“: links die Seiten des Dokuments, in der Mitte das Etikett genau so, wie es
/// gedruckt wird, rechts Drucker, Etikettentyp, Exemplare, Seiten und „Drucken“.
///
/// Geöffnet über „PDF ▾ › Mit LabelWerk drucken“ im Druckdialog jedes Programms, „Ablage › Datei
/// drucken …“ (⌘P), „Öffnen mit › LabelWerk“ oder durch Ablegen einer Datei auf LabelWerk.
struct LabelPrintView: View {
    @Bindable var store: LabelPrintStore

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var isDropTargeted = false

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        ZStack {
            AnimatedBackground(style: .subtle)
                .ignoresSafeArea()
            Group {
                if store.documents.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    content
                        .transition(.opacity.combined(with: .scale(scale: 0.99)))
                }
            }
            .animation(reduceMotion ? nil : Motion.spring, value: store.documents.isEmpty)
            if store.isLoading {
                loadingOverlay
                    .transition(.opacity)
            }
            if isDropTargeted {
                dropHighlight
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ToastOverlay()
                .padding(Theme.Metrics.paddingLarge)
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: isDropTargeted)
        .animation(reduceMotion ? nil : Motion.snappy, value: store.isLoading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            LabelPrintDrop.loadFileURLs(from: providers) { urls in model.openForLabelPrint(urls) }
        }
        .task(id: store.jobKey) {
            if let key = store.jobKey { await store.render(key) }
        }
    }

    // MARK: Inhalt

    private var content: some View {
        HStack(spacing: 0) {
            LabelPrintPageSidebar(store: store, reduceMotion: reduceMotion)
                .frame(width: 214)
            Divider().opacity(0.5)
            LabelPrintPreviewPane(store: store, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            LabelPrintOptionsPanel(store: store, reduceMotion: reduceMotion)
                .frame(width: 330)
        }
    }

    // MARK: Leer, Laden, Ablegen

    private var emptyState: some View {
        VStack(spacing: 22) {
            EmptyStateView(
                title: tr("Etikettendruck"),
                message: tr("Öffne ein PDF oder Bild – LabelWerk zeigt genau, wie das Etikett aus dem Drucker kommt, und druckt es mit dem gewählten Etikettentyp."),
                systemImage: "printer.dotmatrix.filled.and.paper",
                actionTitle: tr("Datei wählen …"),
                action: { model.chooseFilesForLabelPrint() }
            )
            .frame(maxHeight: 360)
            GlassCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(tr("Aus jedem Programm drucken"), systemImage: "sparkles")
                        .font(Theme.Typography.headline)
                    LabelPrintHintRow(number: 1, text: tr("Im Programm wie gewohnt „Drucken …“ wählen (⌘P)."))
                    LabelPrintHintRow(number: 2, text: tr("Unten links im Druckdialog auf „PDF ▾“ klicken."))
                    LabelPrintHintRow(number: 3, text: tr("„Mit LabelWerk drucken“ wählen – das Dokument erscheint hier mit genauer Vorschau."))
                    Text(tr("Oder eine Datei auf dieses Fenster ziehen."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressRing(progress: nil, size: 34, lineWidth: 4)
            Text(tr("Dokument wird geöffnet …"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .labelWerkGlass(cornerRadius: Theme.Metrics.cornerLarge)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.cornerLarge, style: .continuous)
            .strokeBorder(Theme.brandGradient, style: StrokeStyle(lineWidth: 3, dash: [12, 7]))
            .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerLarge, style: .continuous)
                .fill(Theme.violet.opacity(0.08)))
            .overlay {
                Label(tr("Ablegen zum Drucken"), systemImage: "arrow.down.doc")
                    .font(Theme.Typography.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .labelWerkGlass(cornerRadius: 12)
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// Nummerierter Schritt in der Anleitung des leeren Fensters.
private struct LabelPrintHintRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(number))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.brandGradient))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import AppKit
import SwiftUI
import LabelWerkKit

/// Seitenleiste des Etikettendrucks: Vorschaubilder aller Seiten (je Dokument), Mehrfachauswahl mit
/// ⌘ und ⇧ wie im Finder, „Alle Seiten“. Markierte Seiten druckt „Seiten: Auswahl“.
struct LabelPrintPageSidebar: View {
    @Bindable var store: LabelPrintStore
    let reduceMotion: Bool

    @State private var anchor: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.documents) { document in
                            Section {
                                ForEach(indices(of: document), id: \.self) { index in
                                    LabelPrintThumbnail(
                                        document: document,
                                        page: store.pages[index].page,
                                        number: index + 1,
                                        isSelected: store.selection.contains(index),
                                        isFocused: store.displayedPage == index,
                                        isInJob: store.pageMode == .all || store.selection.contains(index),
                                        isSkipped: store.rendered[index].map { $0.label == nil } ?? false,
                                        reduceMotion: reduceMotion
                                    )
                                    .id(index)
                                    .onTapGesture { click(index) }
                                }
                            } header: {
                                if store.documents.count > 1 {
                                    Text(document.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                        .background(.bar)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.focusedPage) { _, page in
                    guard let page else { return }
                    withAnimation(reduceMotion ? nil : Motion.snappy) { proxy.scrollTo(page) }
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .background(.ultraThinMaterial.opacity(0.6))
    }

    private func indices(of document: LabelPrintDocument) -> [Int] {
        store.pages.indices.filter { store.pages[$0].documentID == document.id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.title)
                .font(Theme.Typography.headline)
                .lineLimit(2)
                .help(store.title)
            Text(store.pages.count == 1 ? tr("1 Seite") : tr("%d Seiten", store.pages.count))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button(tr("Alle Seiten")) {
                withAnimation(reduceMotion ? nil : Motion.snappy) {
                    store.selection = Set(store.pages.indices)
                    store.pageMode = .all
                }
            }
            .buttonStyle(.labelWerkPlain)
            .controlSize(.small)
            Spacer(minLength: 0)
            Text(tr("%d markiert", store.selection.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(tr("Mehrere Seiten mit ⌘ oder ⇧ markieren; „Seiten: Auswahl“ druckt nur die markierten."))
    }

    /// Klick wie im Finder: ohne Taste eine Seite, ⌘ hinzufügen/entfernen, ⇧ Bereich ab der letzten.
    private func click(_ index: Int) {
        let flags = NSEvent.modifierFlags
        withAnimation(reduceMotion ? nil : Motion.snappy) {
            if flags.contains(.shift), let anchor {
                let range = min(anchor, index)...max(anchor, index)
                store.selection.formUnion(range)
            } else if flags.contains(.command) {
                if store.selection.contains(index), store.selection.count > 1 {
                    store.selection.remove(index)
                } else {
                    store.selection.insert(index)
                }
                anchor = index
            } else {
                store.selection = [index]
                anchor = index
            }
            if store.selection.count > 1, store.selection.count < store.pages.count {
                // Mehrere Seiten markiert: Diese sollen gedruckt werden.
                store.pageMode = .selection
            }
            store.focusedPage = index
        }
    }
}

/// Vorschaubild einer Seite (Originalseite, im Hintergrund gerendert).
private struct LabelPrintThumbnail: View {
    let document: LabelPrintDocument
    let page: Int
    let number: Int
    let isSelected: Bool
    let isFocused: Bool
    let isInJob: Bool
    let isSkipped: Bool
    let reduceMotion: Bool

    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .transition(.opacity)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white)
                            .aspectRatio(0.72, contentMode: .fit)
                            .shimmering()
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 3, y: 1.5)
                .opacity(isInJob ? 1 : 0.4)
                .saturation(isInJob ? 1 : 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .padding(4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isFocused ? Theme.accent.opacity(0.16) : (hovering ? Theme.subtleFill : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent : Color.clear, lineWidth: 2)
            )
            HStack(spacing: 4) {
                Text(String(number))
                    .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                    .monospacedDigit()
                if isSkipped {
                    Image(systemName: "forward.end")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help(tr("Leere Seite – wird übersprungen"))
                }
            }
            .foregroundStyle(isFocused ? Theme.accent : .secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.snappy, value: isSelected)
        .animation(reduceMotion ? nil : Motion.snappy, value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Seite %d", number))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: "\(document.id)-\(page)") {
            guard image == nil else { return }
            let document = self.document
            let page = self.page
            let rendered = await Task.detached(priority: .utility) {
                LabelPrintImageBox(image: document.thumbnail(at: page))
            }.value
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = rendered.image }
        }
    }
}

/// Hülle, um ein `CGImage` aus einer Hintergrundaufgabe zurückzugeben.
struct LabelPrintImageBox: @unchecked Sendable {
    let image: CGImage?
}

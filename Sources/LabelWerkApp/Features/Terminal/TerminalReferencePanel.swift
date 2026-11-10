import SwiftUI
import LabelWerkKit

// MARK: - Bausteine

/// Häufig benötigte Befehle als Schnellbausteine.
struct TerminalSnippet: Identifiable, Hashable {
    let code: String
    let title: String
    let mode: TerminalInputMode

    var id: String { code }

    static let all: [TerminalSnippet] = [
        TerminalSnippet(code: "~HS", title: tr("Host-Status"), mode: .zpl),
        TerminalSnippet(code: "~HI", title: tr("Kennung"), mode: .zpl),
        TerminalSnippet(code: "~HQES", title: tr("Fehler & Warnungen"), mode: .zpl),
        TerminalSnippet(code: "^XA^HH^XZ", title: tr("Konfiguration"), mode: .zpl),
        TerminalSnippet(code: "! U1 getvar \"device.languages\"", title: tr("Sprachen (SGD)"), mode: .sgd),
        TerminalSnippet(code: "{}{\"allconfig\":null}", title: tr("Alle Einstellungen (JSON)"), mode: .sgd),
        TerminalSnippet(code: "~WC", title: tr("Konfigurationsetikett"), mode: .zpl),
        TerminalSnippet(code: "~JC", title: tr("Kalibrieren"), mode: .zpl),
        TerminalSnippet(code: "^XA^HWE:*.*^XZ", title: tr("Dateien auf E:"), mode: .zpl),
    ]
}

/// Kapsel für einen Baustein: Klick fügt ein, Papierflieger sendet direkt.
struct TerminalSnippetChip: View {
    let snippet: TerminalSnippet
    let isDisabled: Bool
    let reduceMotion: Bool
    let onInsert: () -> Void
    let onSend: () -> Void

    @State private var hovering = false

    init(snippet: TerminalSnippet, isDisabled: Bool, reduceMotion: Bool,
         onInsert: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.snippet = snippet
        self.isDisabled = isDisabled
        self.reduceMotion = reduceMotion
        self.onInsert = onInsert
        self.onSend = onSend
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onInsert) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: snippet.code)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                    Text(snippet.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("In die Eingabe einfügen"))

            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1, height: 20)

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.accent : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(tr("Direkt senden"))
        }
        .fixedSize()
        .background {
            Capsule()
                .fill(hovering ? Theme.accent.opacity(0.12) : Theme.subtleFill)
        }
        .overlay {
            Capsule()
                .strokeBorder(hovering ? Theme.accent.opacity(0.4) : Theme.cardStroke, lineWidth: 1)
        }
        .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
    }
}

// MARK: - Befehlsreferenz

/// Seitenleiste mit durchsuchbarer ZPL-Befehlsreferenz und wichtigen SGD-Variablen.
/// Klick fügt die Syntax in die Eingabe ein.
struct TerminalReferencePanel: View {
    let reduceMotion: Bool
    let onInsert: (String, TerminalInputMode) -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case zpl
        case sgd

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zpl: return tr("ZPL-Befehle")
            case .sgd: return tr("SGD-Variablen")
            }
        }
    }

    @State private var query = ""
    @State private var tab: Tab = .zpl
    @Namespace private var tabNamespace

    init(reduceMotion: Bool, onInsert: @escaping (String, TerminalInputMode) -> Void) {
        self.reduceMotion = reduceMotion
        self.onInsert = onInsert
    }

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var zplEntries: [ZPLCommandReference.Entry] {
        let all = ZPLCommandReference.entries
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            entry.command.localizedCaseInsensitiveContains(needle)
                || entry.name.localizedCaseInsensitiveContains(needle)
                || entry.summary.localizedCaseInsensitiveContains(needle)
        }
    }

    private var sgdVariables: [String] {
        let all = SGD.commonVariables
        guard !needle.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private var resultCount: Int { tab == .zpl ? zplEntries.count : sgdVariables.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                Text(tr("Befehlsreferenz"))
                    .font(Theme.Typography.headline)
                Spacer(minLength: 4)
                Text(verbatim: "\(resultCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: resultCount)
            }

            tabPicker

            ToolsSearchField(text: $query,
                             prompt: tab == .zpl ? tr("Befehl oder Funktion suchen") : tr("Variable suchen"),
                             reduceMotion: reduceMotion)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    switch tab {
                    case .zpl:
                        ForEach(zplEntries, id: \.self) { entry in
                            TerminalReferenceRow(entry: entry, query: needle, reduceMotion: reduceMotion) {
                                onInsert(entry.syntax, .zpl)
                            }
                        }
                    case .sgd:
                        ForEach(sgdVariables, id: \.self) { name in
                            TerminalVariableRow(name: name, query: needle, reduceMotion: reduceMotion) {
                                onInsert("! U1 getvar \"\(name)\"", .sgd)
                            }
                        }
                    }
                    if resultCount == 0 {
                        Text(tr("Keine Treffer"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)

            Text(tr("Klicken fügt die Syntax in die Eingabe ein."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .labelWerkGlass(cornerRadius: 14)
    }

    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { tab = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tab == item ? Color.white : Color.primary.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if tab == item {
                                Capsule()
                                    .fill(Theme.brandGradient)
                                    .matchedGeometryEffect(id: "tab", in: tabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule().fill(Theme.subtleFill)
        }
    }
}

private struct TerminalReferenceRow: View {
    let entry: ZPLCommandReference.Entry
    let query: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ToolsHighlight.attributed(entry.command, query: query))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(ToolsHighlight.attributed(entry.name, query: query))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .opacity(hovering ? 1 : 0)
                }
                Text(ToolsHighlight.attributed(entry.summary, query: query))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: entry.syntax)
                    .font(Theme.Typography.codeSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.accent.opacity(0.1) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .help(entry.syntax)
    }
}

private struct TerminalVariableRow: View {
    let name: String
    let query: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: ToolsSGDCatalog.symbol(for: String(name.split(separator: ".").first ?? "")))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.teal)
                    .frame(width: 16)
                Text(ToolsHighlight.attributed(name, query: query))
                    .font(Theme.Typography.codeSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.accent.opacity(0.1) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .help(tr("Als getvar-Befehl einfügen"))
    }
}

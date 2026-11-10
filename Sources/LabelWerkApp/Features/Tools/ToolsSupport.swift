import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// Gemeinsame Bausteine der Bereiche „Werkzeuge“ und „Terminal“.

// MARK: - Ausführungszustand

/// Zustand einer Aktion (steuert Symbolwechsel, Farben und Schütteln).
enum ToolsRunPhase: Equatable {
    case idle
    case running
    case succeeded
    case failed
}

// MARK: - Schütteln

/// Horizontales Schütteln bei Fehlern. `trigger` innerhalb von
/// `withAnimation(.linear(duration: 0.45))` hochzählen.
struct ToolsShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    var travel: CGFloat

    init(trigger: Int, travel: CGFloat = 7) {
        self.animatableData = CGFloat(trigger)
        self.travel = travel
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Bei ganzzahligen Werten ist sin(4πn) = 0 → Ruhelage.
        let offset = travel * sin(animatableData * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - Suchfeld

/// Suchfeld im LabelWerk-Stil für Blätter und Seitenleisten ohne Symbolleiste.
struct ToolsSearchField: View {
    @Binding var text: String
    let prompt: String
    /// App-Einstellung „Bewegung reduzieren“ des Aufrufers; die Systemeinstellung wird zusätzlich gelesen.
    let preferenceReduceMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var focused: Bool

    init(text: Binding<String>, prompt: String, reduceMotion: Bool = false) {
        self._text = text
        self.prompt = prompt
        self.preferenceReduceMotion = reduceMotion
    }

    private var reduceMotion: Bool { systemReduceMotion || preferenceReduceMotion }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? Theme.accent : Color.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(tr("Suche leeren"))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.subtleFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.cardStroke, lineWidth: focused ? 1.5 : 1)
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: focused)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: text.isEmpty)
    }
}

// MARK: - Kopfzeile für Blätter

/// Einheitliche Kopfzeile der Werkzeug-Blätter (Symbol, Titel, Untertitel, Aktionen rechts).
struct ToolsSheetHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, systemImage: String, tint: Color,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(systemImage: systemImage, tint: tint, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

// MARK: - Kapsel

/// Kleine getönte Kapsel mit optionalem Symbol (Typen, Bereiche, Zustände).
struct ToolsChip: View {
    let text: String
    let systemImage: String?
    let tint: Color

    init(text: String, systemImage: String? = nil, tint: Color = Theme.accent) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(tint.opacity(0.13))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.8)
        }
    }
}

// MARK: - Hinweisbanner

/// Getönter Hinweis (z. B. „Diese Verbindung kann nur senden“).
struct ToolsNotice<Accessory: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let accessory: Accessory

    init(title: String, message: String, systemImage: String, tint: Color,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        GlassCard(padding: 12, tint: tint) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                accessory
            }
        }
    }
}

extension ToolsNotice where Accessory == EmptyView {
    init(title: String, message: String, systemImage: String, tint: Color) {
        self.init(title: title, message: message, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

// MARK: - Dateien & Zwischenablage

/// Sichern-Dialog, Zwischenablage und sichere Dateinamen.
enum ToolsFileExport {
    /// Zeigt einen Sichern-Dialog und schreibt `data`. Liefert die Ziel-URL (nil = abgebrochen).
    @MainActor
    static func save(_ data: Data, suggestedName: String, contentType: UTType) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Entfernt Zeichen, die in Dateinamen stören (/, :, Steuerzeichen).
    static func safeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        var result = ""
        for scalar in name.unicodeScalars {
            result.unicodeScalars.append(forbidden.contains(scalar) ? "-" : scalar)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "LabelWerk" : trimmed
    }
}

// MARK: - Suchtreffer hervorheben

enum ToolsHighlight {
    /// Liefert `text` mit hinterlegten Suchtreffern (Groß-/Kleinschreibung egal).
    static func attributed(_ text: String, query: String, tint: Color = Theme.accent) -> AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }
        let highlight: Color = tint.opacity(0.3)
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart..<result.endIndex]
                .range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = highlight
            searchStart = range.upperBound
        }
        return result
    }
}

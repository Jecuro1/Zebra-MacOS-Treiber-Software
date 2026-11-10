import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// Gemeinsame Bausteine der Bereiche „Dateien & Schriften“, „Netzwerk“ und „Firmware“:
// Ablagezone, Suchfeld, Schütteln, gestaffeltes Einblenden, Platzhalterzeilen, Formatierung.

// MARK: - Schütteln

/// Horizontales Schütteln für ungültige Eingaben. `trigger` innerhalb von
/// `withAnimation(.linear(duration: 0.45))` hochzählen – bei ganzzahligen Werten in Ruhelage.
struct TransferShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    var travel: CGFloat

    init(trigger: Int, travel: CGFloat = 6) {
        self.animatableData = CGFloat(trigger)
        self.travel = travel
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = travel * sin(animatableData * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - Gestaffeltes Einblenden

/// Blendet Zeilen nacheinander mit Feder ein (bei „Bewegung reduzieren“ sofort sichtbar).
private struct TransferAppearModifier: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion
        return content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .scaleEffect(visible ? 1 : 0.98, anchor: .top)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Motion.spring.delay(Double(min(index, 14)) * 0.035)) { shown = true }
                }
            }
    }
}

extension View {
    /// Gestaffeltes Einblenden in Listen (Index bestimmt die Verzögerung).
    func transferAppear(index: Int, reduceMotion: Bool) -> some View {
        modifier(TransferAppearModifier(index: index, reduceMotion: reduceMotion))
    }
}

// MARK: - Ablagezone

/// Gestrichelte Ablagefläche für Dateien (Drag & Drop aus dem Finder) mit Aktionsknöpfen.
struct TransferDropZone<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let isEnabled: Bool
    let onDrop: ([URL]) -> Bool
    let actions: Actions

    @State private var targeted = false
    @State private var dropCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, message: String, systemImage: String, tint: Color = Theme.accent,
         isEnabled: Bool = true, onDrop: @escaping ([URL]) -> Bool,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.isEnabled = isEnabled
        self.onDrop = onDrop
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(targeted ? 0.24 : 0.1))
                    .frame(width: 66, height: 66)
                    .scaleEffect(targeted && !reduceMotion ? 1.16 : 1)
                Circle()
                    .strokeBorder(tint.opacity(targeted ? 0.6 : 0.2), lineWidth: 1)
                    .frame(width: 66, height: 66)
                    .scaleEffect(targeted && !reduceMotion ? 1.4 : 1)
                    .opacity(targeted ? 0 : 1)
                Image(systemName: targeted ? "arrow.down.circle.fill" : systemImage)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: dropCount)
            }
            VStack(spacing: 4) {
                Text(targeted ? tr("Loslassen zum Hinzufügen") : title)
                    .font(Theme.Typography.headline)
                    .contentTransition(.opacity)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, 2)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background {
            shape.fill(tint.opacity(targeted ? 0.10 : 0.035))
        }
        .overlay {
            shape.strokeBorder(tint.opacity(targeted ? 0.9 : 0.35),
                               style: StrokeStyle(lineWidth: targeted ? 2 : 1.3, dash: [7, 6]))
        }
        .scaleEffect(targeted && !reduceMotion ? 1.008 : 1)
        .animation(reduceMotion ? nil : Motion.spring, value: targeted)
        .opacity(isEnabled ? 1 : 0.55)
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled, !urls.isEmpty else { return false }
            let accepted = onDrop(urls)
            if accepted { dropCount += 1 }
            return accepted
        } isTargeted: { inside in
            targeted = inside && isEnabled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Suchfeld

/// Kompaktes Suchfeld im LabelWerk-Stil.
struct TransferSearchField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var focused: Bool

    init(text: Binding<String>, prompt: String) {
        self._text = text
        self.prompt = prompt
    }

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
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.subtleFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.cardStroke, lineWidth: focused ? 1.5 : 1)
        }
        .animation(Motion.snappy, value: focused)
        .animation(Motion.snappy, value: text.isEmpty)
    }
}

// MARK: - Kleine Kapsel

/// Kapsel mit Symbol und kurzem Text (Prüfergebnisse, Hinweise, Kennzeichnungen).
struct TransferChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(_ text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(tint.opacity(0.13))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Platzhalterzeile

/// Grauer Platzhalter einer Listenzeile (zusammen mit `.shimmering()` beim Laden).
struct TransferSkeletonRow: View {
    let widthFactor: CGFloat

    init(widthFactor: CGFloat = 1) {
        self.widthFactor = widthFactor
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.separator)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(Theme.separator)
                    .frame(width: 170 * widthFactor, height: 10)
                Capsule()
                    .fill(Theme.subtleFill)
                    .frame(width: 96 * widthFactor, height: 8)
            }
            Spacer(minLength: 8)
            Capsule()
                .fill(Theme.separator)
                .frame(width: 54, height: 10)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .accessibilityHidden(true)
    }
}

/// Platzhalter für ein Eingabefeld (Titel + Feld).
struct TransferSkeletonField: View {
    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(Theme.separator)
                .frame(width: 90, height: 8)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.subtleFill)
                .frame(height: 30)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Formatierung

enum TransferFormat {
    /// Dateigröße, z. B. „1,2 MB“.
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .file)
    }

    static func bytes64(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    /// Übertragungsrate, z. B. „245 KB/s“.
    static func rate(_ bytesPerSecond: Double) -> String {
        tr("%@/s", bytes(Int(bytesPerSecond.rounded())))
    }

    /// Dauer als m:ss bzw. h:mm:ss.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Prozentwert 0…1, z. B. „42 %“.
    static func percent(_ fraction: Double) -> String {
        min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Öffnen-Dialog

@MainActor
enum TransferOpenPanel {
    /// Zeigt einen Öffnen-Dialog für genau eine Datei. `types == nil` erlaubt alle Dateien.
    static func pickFile(title: String, message: String?, prompt: String, types: [UTType]?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = title
        if let message { panel.message = message }
        panel.prompt = prompt
        if let types, !types.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Hinweiszeile

/// Einzeiliger Hinweis mit Symbol (Info, Warnung, Fehler, Erfolg).
struct TransferNote: View {
    enum Style: Equatable { case info, success, warning, error }

    let text: String
    let style: Style

    init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    private var tint: Color {
        switch style {
        case .info: return Theme.printing
        case .success: return Theme.ready
        case .warning: return Theme.warning
        case .error: return Theme.error
        }
    }

    private var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(style == .info ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

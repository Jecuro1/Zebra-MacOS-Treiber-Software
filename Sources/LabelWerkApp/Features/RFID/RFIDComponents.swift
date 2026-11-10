import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Gestaffeltes Einblenden

/// Blendet Elemente einer Gruppe nacheinander ein (Index bestimmt die Verzögerung).
struct RFIDAppearModifier: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Motion.spring.delay(Double(min(index, 12)) * 0.045)) { shown = true }
                }
            }
    }
}

extension View {
    /// Gestaffeltes Einblenden in RFID-Listen und -Rastern.
    func rfidAppear(index: Int, reduceMotion: Bool) -> some View {
        modifier(RFIDAppearModifier(index: index, reduceMotion: reduceMotion))
    }
}

// MARK: - Kopieren

enum RFIDPasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Kopierknopf mit Häkchen-Rückmeldung.
struct RFIDCopyButton: View {
    let text: String
    let title: String?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var copied = false

    init(text: String, title: String? = nil) {
        self.text = text
        self.title = title
    }

    var body: some View {
        Button {
            RFIDPasteboard.copy(text)
            let animation = Motion.animation(Motion.snappy, reduceMotion: systemReduceMotion || appReduceMotion)
            withAnimation(animation) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(animation) { copied = false }
            }
        } label: {
            if let title {
                Label(copied ? tr("Kopiert") : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? Theme.ready : Color.secondary)
            }
        }
        .buttonStyle(.labelWerkPlain)
        .help(tr("In die Zwischenablage kopieren"))
        .disabled(text.isEmpty)
    }
}

// MARK: - Hex-Anzeige

/// Hex-Daten in 16-Bit-Gruppen (je 4 Zeichen) als Kacheln, gestaffelt eingeblendet.
struct RFIDHexGroups: View {
    let hex: String
    var fontSize: CGFloat = 19
    var tint: Color = Theme.teal
    let reduceMotion: Bool

    private var groups: [String] {
        let characters = Array(hex)
        return stride(from: 0, to: characters.count, by: 4).map { start in
            String(characters[start..<min(start + 4, characters.count)])
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: fontSize * 3.5), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Text(verbatim: group)
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(index % 2 == 0 ? 0.16 : 0.08))
                    }
                    .rfidAppear(index: index, reduceMotion: reduceMotion)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RFIDHex.grouped(hex))
    }
}

// MARK: - Befehlsanzeige

/// Zeigt einen RFID-Befehl und erklärt seine Parameter (o, f, b, n, m).
struct RFIDCommandStrip: View {
    let command: String
    let parameters: [RFIDCommandParameter]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: command)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                    .contentTransition(.interpolate)
                Spacer(minLength: 4)
                RFIDCopyButton(text: command)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(parameters) { parameter in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: parameter.key + " = " + parameter.value)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .contentTransition(.numericText())
                        Text(parameter.meaning)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.subtleFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
    }
}

// MARK: - Speicherbank-Auswahl

/// Segmentierte Auswahl der Speicherbank mit gleitender Markierung.
struct RFIDBankPicker: View {
    @Binding var selection: RFIDMemoryBank
    let banks: [RFIDMemoryBank]
    let reduceMotion: Bool

    @Namespace private var namespace

    init(selection: Binding<RFIDMemoryBank>, banks: [RFIDMemoryBank], reduceMotion: Bool) {
        self._selection = selection
        self.banks = banks
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(banks) { bank in
                let isSelected = bank == selection
                Button {
                    withAnimation(Motion.animation(.spring(response: 0.35, dampingFraction: 0.8),
                                                   reduceMotion: reduceMotion)) {
                        selection = bank
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: bank.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                        Text(bank.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.brandGradient)
                                .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "bank", in: namespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(bank.detail)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - Hinweise

/// Hinweiskarte mit Symbol, Titel, Text und optionalen Aktionen.
struct RFIDNoticeCard<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let actions: Actions

    init(title: String, message: String, systemImage: String, tint: Color,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        GlassCard(padding: 14, tint: tint) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: systemImage, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                actions
            }
        }
    }
}

extension RFIDNoticeCard where Actions == EmptyView {
    init(title: String, message: String, systemImage: String, tint: Color) {
        self.init(title: title, message: message, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// Fehlerzeile mit Symbol (z. B. unter einem Formular).
struct RFIDInlineMessage: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = Theme.error

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(tint == Theme.error ? tint : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}

/// Aufklappbare Rohantwort des Druckers (Diagnose).
struct RFIDRawResponseView: View {
    let text: String
    @State private var expanded = false

    init(text: String) {
        self.text = text
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: text)
                    .font(Theme.Typography.codeSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                RFIDCopyButton(text: text)
            }
            .padding(8)
            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 4)
        } label: {
            Label(tr("Rohantwort des Druckers"), systemImage: "terminal")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Kleine Kapsel mit Symbol und Text (Status, Speicherbank …).
struct RFIDCapsule: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(tint.opacity(0.14))
                .overlay { Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1) }
        }
    }
}

import SwiftUI
import LabelWerkKit

/// Auswahl „Etikett“ im Installationsassistenten und beim manuellen Hinzufügen.
///
/// Oben steht die Größe, die der Drucker meldet – als „Vom Drucker: 104 × 76,2 mm“ bzw. als passendes
/// vorhandenes Format mit dem Zusatz „vom Drucker erkannt“ –, danach „Benutzerdefiniert …“ mit Breite
/// und Höhe in mm (deutsches Komma oder Punkt) und Medientyp, darunter die vorhandenen Formate.
/// „Vom Drucker übernehmen“ liest die Größe erneut. Die Auswahl selbst legt nichts an: Erst beim
/// Installieren bzw. Hinzufügen wird daraus ein echtes Format (`LabelStockLibrary.resolveStock`).
struct LabelStockChooser: View {
    @Binding var choice: LabelStockChoice
    @Binding var entry: LabelSizeEntry
    /// Vorhandene Formate zur Auswahl (passend zum Modell, einschließlich des gewählten).
    let stocks: [LabelStock]
    /// Vom Drucker gemeldete Größe (`nil` = nicht gemeldet).
    var detected: DetectedMedia?
    /// Vorhandenes Format zur gemeldeten Größe (± 0,6 mm).
    var detectedMatch: LabelStock?
    /// Erlaubte Größe für „Benutzerdefiniert …“ (Modell).
    let limits: LabelSizing.Limits
    var isReadingMedia = false
    /// Hinweis unter der Auswahl (z. B. „Der Drucker hat keine Etikettengröße gemeldet …“).
    var note: String?
    /// „Vom Drucker übernehmen“ (`nil` = Schaltfläche ausblenden, z. B. ohne Verbindung).
    var onReadFromPrinter: (() -> Void)?
    let reduceMotion: Bool

    init(choice: Binding<LabelStockChoice>, entry: Binding<LabelSizeEntry>, stocks: [LabelStock],
         detected: DetectedMedia? = nil, detectedMatch: LabelStock? = nil, limits: LabelSizing.Limits,
         isReadingMedia: Bool = false, note: String? = nil, onReadFromPrinter: (() -> Void)? = nil,
         reduceMotion: Bool) {
        _choice = choice
        _entry = entry
        self.stocks = stocks
        self.detected = detected
        self.detectedMatch = detectedMatch
        self.limits = limits
        self.isReadingMedia = isReadingMedia
        self.note = note
        self.onReadFromPrinter = onReadFromPrinter
        self.reduceMotion = reduceMotion
    }

    /// Formate der Liste (das vom Drucker erkannte steht schon oben).
    private var listed: [LabelStock] {
        stocks.filter { $0.id != detectedMatch?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(tr("Etikett"), selection: $choice) {
                if let detected {
                    if let match = detectedMatch {
                        Text(tr("%@ – vom Drucker erkannt", match.name)).tag(LabelStockChoice.stock(match.id))
                    } else {
                        Text(tr("Vom Drucker: %@", detected.sizeText)).tag(LabelStockChoice.printer)
                    }
                }
                Text(tr("Benutzerdefiniert …")).tag(LabelStockChoice.custom)
                let own = listed.filter(\.isCustom)
                if !own.isEmpty {
                    Section(tr("Eigene Formate")) {
                        ForEach(own) { stock in
                            Text(verbatim: stock.name).tag(LabelStockChoice.stock(stock.id))
                        }
                    }
                }
                Section(tr("Etikettenformate")) {
                    ForEach(listed.filter { !$0.isCustom }) { stock in
                        Text(verbatim: stock.name).tag(LabelStockChoice.stock(stock.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            detail
                .transition(.opacity)

            if let onReadFromPrinter {
                Button(action: onReadFromPrinter) {
                    HStack(spacing: 5) {
                        if isReadingMedia {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.doc")
                        }
                        Text(tr("Vom Drucker übernehmen"))
                    }
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                .disabled(isReadingMedia)
                .help(tr("Liest die im Drucker eingestellte Etikettengröße erneut und übernimmt sie."))
            }
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: choice)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: detected)
    }

    // MARK: Angaben unter der Auswahl

    @ViewBuilder
    private var detail: some View {
        switch choice {
        case .stock(let id):
            if let stock = stocks.first(where: { $0.id == id }) ?? detectedMatch.flatMap({ $0.id == id ? $0 : nil }) {
                VStack(alignment: .leading, spacing: 3) {
                    caption(stock.sizeDescription)
                    if id == detectedMatch?.id {
                        badge(tr("Vom Drucker erkannt"))
                    }
                }
            }
        case .printer:
            if let detected {
                VStack(alignment: .leading, spacing: 3) {
                    caption(Self.detectedCaption(detected))
                    badge(tr("Vom Drucker erkannt"))
                }
            }
        case .custom:
            customFields
        }
    }

    /// „Einzeletiketten · 832 × 610 Punkte bei 203 dpi“.
    static func detectedCaption(_ media: DetectedMedia) -> String {
        let dots = tr("%d × %d Punkte bei %d dpi", media.widthDots, media.lengthDots, media.resolution.dpi)
        guard let tracking = media.tracking else { return dots }
        return "\(tr(tracking.displayName)) · \(dots)"
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .contentTransition(.opacity)
    }

    private func badge(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.seal.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ready)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.ready.opacity(0.14)))
    }

    // MARK: Benutzerdefiniert

    private var customFields: some View {
        let widthIssues = entry.isEmpty ? [] : entry.widthIssues(in: limits)
        let heightIssues = entry.isEmpty ? [] : entry.heightIssues(in: limits)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                sizeField(tr("Breite"), text: $entry.widthText, invalid: !widthIssues.isEmpty)
                Text(verbatim: "×")
                    .foregroundStyle(.secondary)
                sizeField(tr("Höhe"), text: $entry.heightText, invalid: !heightIssues.isEmpty)
                Text(verbatim: "mm")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Picker(tr("Medientyp"), selection: $entry.tracking) {
                ForEach(PrintPrefsChoices.trackingOrder) { tracking in
                    Text(tr(tracking.displayName)).tag(tracking)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help(tr("Medientyp"))
            if entry.isEmpty {
                caption(rangeText)
            } else {
                ForEach(Array((widthIssues + heightIssues).enumerated()), id: \.offset) { _, issue in
                    Label(Self.message(for: issue), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.error)
                        .transition(.opacity)
                }
            }
        }
    }

    /// „Breite 10–106 mm, Höhe 5–991 mm“.
    private var rangeText: String {
        tr("Breite %@–%@ mm, Höhe %@–%@ mm",
           LabelSizing.format(limits.widthMM.lowerBound), LabelSizing.format(limits.widthMM.upperBound),
           LabelSizing.format(limits.heightMM.lowerBound), LabelSizing.format(limits.heightMM.upperBound))
    }

    private func sizeField(_ title: String, text: Binding<String>, invalid: Bool) -> some View {
        TextField(title, text: text, prompt: Text(title))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 66)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.error, lineWidth: 1)
                    .opacity(invalid ? 0.9 : 0)
                    .allowsHitTesting(false)
            }
            .help(rangeText)
            .accessibilityLabel(tr("%@ in mm", title))
    }

    /// Meldung zu einem Eingabefehler (``LabelSizing/Issue``), übersetzt.
    static func message(for issue: LabelSizing.Issue) -> String {
        switch issue {
        case .widthMissing: return tr("Breite in mm eingeben")
        case .heightMissing: return tr("Höhe in mm eingeben")
        case .widthTooSmall(let minimum): return tr("Breite mindestens %@ mm", LabelSizing.format(minimum))
        case .widthTooLarge(let maximum): return tr("Breite höchstens %@ mm", LabelSizing.format(maximum))
        case .heightTooSmall(let minimum): return tr("Höhe mindestens %@ mm", LabelSizing.format(minimum))
        case .heightTooLarge(let maximum): return tr("Höhe höchstens %@ mm", LabelSizing.format(maximum))
        }
    }
}

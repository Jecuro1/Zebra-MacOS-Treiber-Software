import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// MARK: - Datenmodell

/// Eine SGD-Variable als Tabellenzeile (alle Spalten als sortierbare Zeichenketten).
struct ToolsSGDRow: Identifiable, Hashable {
    let name: String
    var value: String
    let typeText: String
    let rangeText: String
    let accessText: String
    let archive: Bool?

    var id: String { name }

    init(name: String, setting: SGDSetting) {
        self.name = name
        self.value = setting.value
        self.typeText = setting.type ?? ""
        self.rangeText = setting.range ?? ""
        self.accessText = setting.access ?? ""
        self.archive = setting.archive
    }

    /// Bereich = Präfix vor dem ersten Punkt („device“, „media“, „ip“ …).
    var group: String {
        name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }

    /// Schreibbar, wenn der Zugriff „W“ enthält; ohne Angabe wird Schreiben angeboten.
    var isWritable: Bool {
        let access = accessText.uppercased()
        return access.isEmpty || access.contains("W")
    }

    var accessLabel: String {
        let access = accessText.uppercased()
        if access.isEmpty { return tr("Unbekannt") }
        if access.contains("R") && access.contains("W") { return tr("Lesen & Schreiben") }
        if access.contains("W") { return tr("Nur schreiben") }
        return tr("Nur lesen")
    }
}

/// Eingabeart einer SGD-Variable, abgeleitet aus Typ und Bereich (inkl. Prüfung).
enum ToolsSGDValueKind: Equatable {
    case choices([String])
    case integer(ClosedRange<Int>?)
    case decimal(ClosedRange<Double>?)
    case ipv4
    case text(ClosedRange<Int>?)

    init(type: String, range: String) {
        let kind = type.lowercased().trimmingCharacters(in: .whitespaces)
        let choices = range.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if kind.contains("enum") {
            self = choices.count > 1 ? .choices(choices) : .text(nil)
        } else if kind.hasPrefix("bool") {
            self = .choices(choices.count > 1 ? choices : ["on", "off"])
        } else if kind.contains("int") || kind.contains("unsigned") || kind == "long" {
            self = .integer(Self.numericRange(range).map { Self.intRange($0) })
        } else if kind.contains("double") || kind.contains("float") || kind.contains("decimal") {
            self = .decimal(Self.numericRange(range))
        } else if kind.hasPrefix("ip") {
            self = .ipv4
        } else if kind.contains("string") {
            self = .text(Self.numericRange(range).map { Self.intRange($0) }.map { max(0, $0.lowerBound)...max(0, $0.upperBound) })
        } else if choices.count > 1 {
            self = .choices(choices)
        } else if let numeric = Self.numericRange(range) {
            self = .integer(Self.intRange(numeric))
        } else {
            self = .text(nil)
        }
    }

    /// Ganzzahlbereich ohne Überlauf: `Int(Double)` bricht bei Werten außerhalb von `Int` ab (z. B.
    /// Bereich „0-18446744073709551615“ eines vorzeichenlosen 64-Bit-Zählers). Solche Grenzen werden
    /// auf `Int.min`/`Int.max` gekappt – größere Werte lassen sich ohnehin nicht als `Int` eingeben.
    static func intRange(_ range: ClosedRange<Double>) -> ClosedRange<Int> {
        intBound(range.lowerBound)...intBound(range.upperBound)
    }

    private static func intBound(_ value: Double) -> Int {
        let limit = 9.0e18
        if value.isNaN { return 0 }
        if value >= limit { return Int.max }
        if value <= -limit { return Int.min }
        return Int(value.rounded())
    }

    /// Liest Bereiche wie „0-30“, „-120-120“, „0.0-10.5“ oder „1..5“.
    static func numericRange(_ text: String) -> ClosedRange<Double>? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let pattern = "^(-?\\d+(?:\\.\\d+)?)\\s*(?:-|\\.\\.|to|bis)\\s*(-?\\d+(?:\\.\\d+)?)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 3,
              let lower = Double(ns.substring(with: match.range(at: 1))),
              let upper = Double(ns.substring(with: match.range(at: 2))),
              lower <= upper else { return nil }
        return lower...upper
    }

    /// Fehlermeldung für einen ungültigen Wert (nil = gültig).
    func validate(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.contains("\"") {
            return tr("Anführungszeichen sind in SGD-Werten nicht erlaubt.")
        }
        switch self {
        case .choices(let options):
            return options.contains(value) ? nil : tr("Bitte einen der erlaubten Werte wählen.")
        case .integer(let range):
            guard let number = Int(value) else { return tr("Bitte eine ganze Zahl eingeben.") }
            if let range, !range.contains(number) {
                return tr("Erlaubt sind Werte von %ld bis %ld.", range.lowerBound, range.upperBound)
            }
            return nil
        case .decimal(let range):
            guard let number = Double(value.replacingOccurrences(of: ",", with: ".")) else {
                return tr("Bitte eine Zahl eingeben.")
            }
            if let range, !range.contains(number) {
                return tr("Erlaubt sind Werte von %@ bis %@.",
                          Self.format(range.lowerBound), Self.format(range.upperBound))
            }
            return nil
        case .ipv4:
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let valid = parts.count == 4 && parts.allSatisfy { part in
                guard !part.isEmpty, part.count <= 3, let number = Int(part) else { return false }
                return (0...255).contains(number)
            }
            return valid ? nil : tr("Bitte eine gültige IPv4-Adresse eingeben (z. B. 192.168.1.20).")
        case .text(let length):
            if let length, !length.contains(value.count) {
                return tr("Erlaubt sind %ld bis %ld Zeichen.", length.lowerBound, length.upperBound)
            }
            return nil
        }
    }

    /// Normalisiert die Eingabe vor dem Senden (Leerraum, Dezimalkomma).
    func normalized(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if case .decimal = self { return value.replacingOccurrences(of: ",", with: ".") }
        return value
    }

    var hint: String {
        switch self {
        case .choices(let options): return tr("%d Auswahlwerte", options.count)
        case .integer(let range):
            if let range { return tr("Ganzzahl %ld … %ld", range.lowerBound, range.upperBound) }
            return tr("Ganzzahl")
        case .decimal(let range):
            if let range { return tr("Zahl %@ … %@", Self.format(range.lowerBound), Self.format(range.upperBound)) }
            return tr("Zahl")
        case .ipv4: return tr("IPv4-Adresse")
        case .text(let length):
            if let length { return tr("Text, %ld–%ld Zeichen", length.lowerBound, length.upperBound) }
            return tr("Text")
        }
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}

/// Symbole und Anzeige der SGD-Bereiche.
enum ToolsSGDCatalog {
    static func symbol(for group: String) -> String {
        switch group.lowercased() {
        case "device": return "cpu"
        case "media": return "square.stack.3d.up"
        case "print", "zpl", "apl", "ezpl": return "printer"
        case "ip", "internal_wired", "external_wired", "wired": return "network"
        case "wlan": return "wifi"
        case "bluetooth": return "antenna.radiowaves.left.and.right"
        case "odometer": return "gauge.with.dots.needle.67percent"
        case "head": return "thermometer.medium"
        case "power": return "battery.75percent"
        case "file": return "doc"
        case "usb": return "cable.connector"
        case "display": return "display"
        case "alerts": return "bell"
        case "rfid": return "wave.3.right"
        case "sensor": return "dot.radiowaves.left.and.right"
        case "weblink", "netmanage": return "globe"
        case "comm", "interface", "parallel_port", "serial": return "arrow.left.arrow.right"
        case "capture", "input": return "keyboard"
        case "cradle": return "battery.100.bolt"
        case "card": return "creditcard"
        default: return "slider.horizontal.3"
        }
    }
}

private struct SGDGroupInfo: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

/// Struktur des JSON-Exports.
private struct SGDExportEntry: Encodable {
    let value: String
    let type: String?
    let range: String?
    let access: String?
    let archive: Bool?
}

// MARK: - Explorer

/// Alle SGD-Einstellungen in einer sortierbaren, durchsuchbaren Tabelle mit Bereichsfilter,
/// Bearbeitung (mit Validierung) und JSON-Export – weit über „Send File“ der Setup Utilities hinaus.
struct ToolsSettingsExplorer: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var rows: [ToolsSGDRow] = []
    @State private var isLoading = true
    @State private var readAt: Date?
    @State private var query = ""
    @State private var groupFilter: String?
    @State private var onlyWritable = false
    @State private var sortOrder = [KeyPathComparator(\ToolsSGDRow.name)]
    @State private var selection: ToolsSGDRow.ID?
    @State private var editing: ToolsSGDRow.ID?
    @State private var flashed: ToolsSGDRow.ID?
    @Namespace private var groupNamespace

    init(session: PrinterSession) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var groups: [SGDGroupInfo] {
        Dictionary(grouping: rows, by: \.group)
            .map { SGDGroupInfo(name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleRows: [ToolsSGDRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if let groupFilter, row.group != groupFilter { return false }
            if onlyWritable && !row.isWritable { return false }
            if needle.isEmpty { return true }
            return row.name.localizedCaseInsensitiveContains(needle)
                || row.value.localizedCaseInsensitiveContains(needle)
        }
        .sorted(using: sortOrder)
    }

    private var selectedRow: ToolsSGDRow? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    private var subtitle: String {
        if let readAt {
            return tr("%@ · %d Variablen · gelesen um %@", session.displayName, rows.count,
                      readAt.formatted(date: .omitted, time: .standard))
        }
        return session.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolsSheetHeader(title: tr("Einstellungs-Explorer"), subtitle: subtitle,
                             systemImage: "tablecells", tint: Theme.violet) {
                headerActions
            }

            HStack(alignment: .top, spacing: 14) {
                groupSidebar
                    .frame(width: 210)
                VStack(alignment: .leading, spacing: 10) {
                    filterBar
                    tableArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let row = selectedRow {
                        detailBar(row)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: selection)
            }
        }
        .padding(22)
        .frame(minWidth: 960, idealWidth: 1080, minHeight: 620, idealHeight: 740)
        .task { await load() }
    }

    // MARK: Kopf & Filter

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await load() }
            } label: {
                Label(tr("Neu lesen"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(isLoading)

            Menu {
                Button(tr("Alle Variablen exportieren …")) { export(rows, suffix: nil) }
                Button(tr("Gefilterte Variablen exportieren …")) { export(visibleRows, suffix: groupFilter) }
                    .disabled(visibleRows.isEmpty)
            } label: {
                Label(tr("JSON exportieren"), systemImage: "curlybraces")
            }
            .menuStyle(.button)
            .buttonStyle(.labelWerkSecondary)
            .fixedSize()
            .disabled(rows.isEmpty)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.labelWerkPlain)
            .keyboardShortcut(.cancelAction)
            .help(tr("Schließen"))
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            ToolsSearchField(text: $query, prompt: tr("Variable oder Wert suchen"), reduceMotion: reduceMotion)
            Toggle(isOn: $onlyWritable.animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion))) {
                Label(tr("Nur änderbare"), systemImage: "pencil")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            Text(tr("%d angezeigt", visibleRows.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: visibleRows.count)
        }
    }

    private var groupSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                groupButton(name: nil, title: tr("Alle Bereiche"), count: rows.count, symbol: "square.grid.2x2")
                if !groups.isEmpty {
                    Divider()
                        .padding(.vertical, 6)
                }
                ForEach(groups) { info in
                    groupButton(name: info.name, title: info.name, count: info.count,
                                symbol: ToolsSGDCatalog.symbol(for: info.name))
                }
            }
            .padding(8)
        }
        .labelWerkGlass(cornerRadius: 12)
        .overlay {
            if isLoading && rows.isEmpty {
                ProgressRing(progress: nil, size: 22, lineWidth: 3)
            }
        }
    }

    private func groupButton(name: String?, title: String, count: Int, symbol: String) -> some View {
        let isSelected = groupFilter == name
        return Button {
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                groupFilter = name
                selection = nil
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Theme.accent)
                    .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "group", in: groupNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Tabelle

    @ViewBuilder
    private var tableArea: some View {
        if isLoading && rows.isEmpty {
            skeleton
        } else if rows.isEmpty {
            EmptyStateView(
                title: tr("Keine Einstellungen erhalten"),
                message: tr("Der Drucker hat keine SGD-Variablen geliefert. Ältere Modelle ohne Link-OS unterstützen diese Abfrage eventuell nicht."),
                systemImage: "tablecells",
                actionTitle: tr("Erneut lesen"),
                action: { Task { await load() } }
            )
        } else {
            table
        }
    }

    private var table: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(tr("Name"), value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isWritable ? "pencil.circle" : "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(row.isWritable ? Theme.accent : Color.secondary)
                        .frame(width: 14)
                    Text(ToolsHighlight.attributed(row.name, query: query))
                        .font(Theme.Typography.codeSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.name)
            }
            .width(min: 200, ideal: 290)

            TableColumn(tr("Wert"), value: \.value) { row in
                SGDValueCell(row: row, query: query, isFlashed: flashed == row.id, reduceMotion: reduceMotion,
                             isEditing: editingBinding(for: row.id),
                             onCommit: { newValue in await commit(row, newValue) })
            }
            .width(min: 150, ideal: 250)

            TableColumn(tr("Typ"), value: \.typeText) { row in
                Text(verbatim: row.typeText.isEmpty ? "–" : row.typeText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 80, max: 130)

            TableColumn(tr("Bereich"), value: \.rangeText) { row in
                Text(verbatim: row.rangeText.isEmpty ? "–" : row.rangeText)
                    .font(Theme.Typography.codeSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.rangeText)
            }
            .width(min: 90, ideal: 170)

            TableColumn(tr("Zugriff"), value: \.accessText) { row in
                accessBadge(row)
            }
            .width(min: 64, ideal: 76, max: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ToolsSGDRow.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button(tr("Wert kopieren")) { ToolsFileExport.copy(row.value) }
                Button(tr("Name kopieren")) { ToolsFileExport.copy(row.name) }
                Button(tr("getvar-Befehl kopieren")) { ToolsFileExport.copy(getvarCommand(row.name)) }
                Divider()
                Button(tr("Wert neu lesen")) { Task { await reread(row) } }
                if row.isWritable {
                    Button(tr("Bearbeiten …")) { beginEditing(row.id) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }), row.isWritable {
                beginEditing(id)
            }
        }
        .labelWerkGlass(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func accessBadge(_ row: ToolsSGDRow) -> some View {
        let label = row.accessText.isEmpty ? "?" : row.accessText.uppercased()
        let tint: Color = row.isWritable ? Theme.teal : Theme.offline
        return Text(verbatim: label)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(tint.opacity(0.14))
            }
            .help(row.accessLabel)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<14, id: \.self) { index in
                HStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.subtleFill.opacity(2.2))
                        .frame(width: CGFloat(140 + (index * 41) % 120), height: 11)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.subtleFill.opacity(2.2))
                        .frame(width: CGFloat(60 + (index * 29) % 120), height: 11)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.subtleFill.opacity(2.2))
                        .frame(width: 40, height: 11)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            Spacer(minLength: 0)
        }
        .shimmering(active: !reduceMotion)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .labelWerkGlass(cornerRadius: 12)
        .overlay {
            VStack(spacing: 10) {
                ProgressRing(progress: nil, size: 30)
                Text(tr("Druckereinstellungen werden gelesen …"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .labelWerkGlass(cornerRadius: 14)
        }
    }

    // MARK: Details

    private func detailBar(_ row: ToolsSGDRow) -> some View {
        let kind = ToolsSGDValueKind(type: row.typeText, range: row.rangeText)
        return HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: ToolsSGDCatalog.symbol(for: row.group), tint: Theme.violet, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(verbatim: row.value.isEmpty ? "–" : row.value)
                    .font(Theme.Typography.code)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .contentTransition(.opacity)
                HStack(spacing: 6) {
                    ToolsChip(text: kind.hint, systemImage: "textformat", tint: Theme.violet)
                    ToolsChip(text: row.accessLabel, systemImage: row.isWritable ? "pencil" : "lock.fill",
                              tint: row.isWritable ? Theme.teal : Theme.offline)
                    if row.archive == true {
                        ToolsChip(text: tr("Dauerhaft gespeichert"), systemImage: "externaldrive", tint: Theme.printing)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        ToolsFileExport.copy(row.value)
                    } label: {
                        Label(tr("Wert"), systemImage: "doc.on.doc")
                    }
                    .help(tr("Wert kopieren"))
                    Button {
                        ToolsFileExport.copy(getvarCommand(row.name))
                    } label: {
                        Label(tr("Befehl"), systemImage: "terminal")
                    }
                    .help(tr("getvar-Befehl kopieren"))
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                if row.isWritable {
                    Button {
                        beginEditing(row.id)
                    } label: {
                        Label(tr("Bearbeiten …"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .labelWerkGlass(cornerRadius: 12)
    }

    // MARK: Aktionen

    private func load() async {
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { isLoading = true }
        let settings = await session.allSettings()
        let newRows = settings.map { ToolsSGDRow(name: $0.key, setting: $0.value) }
            .sorted { $0.name < $1.name }
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            rows = newRows
            isLoading = false
            if !newRows.isEmpty { readAt = Date() }
            if let groupFilter, !newRows.contains(where: { $0.group == groupFilter }) {
                self.groupFilter = nil
            }
            if let selection, !newRows.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }

    private func editingBinding(for id: ToolsSGDRow.ID) -> Binding<Bool> {
        Binding(
            get: { editing == id },
            set: { isPresented in
                if isPresented {
                    editing = id
                } else if editing == id {
                    editing = nil
                }
            }
        )
    }

    private func beginEditing(_ id: ToolsSGDRow.ID) {
        selection = id
        editing = id
    }

    private func getvarCommand(_ name: String) -> String {
        "! U1 getvar \"\(name)\""
    }

    /// Setzt einen Wert, liest ihn zur Bestätigung zurück und hebt die Zeile hervor.
    private func commit(_ row: ToolsSGDRow, _ newValue: String) async -> Bool {
        let ok = await session.setvar(row.name, newValue)
        guard ok else { return false }
        let confirmed = await session.getvar(row.name) ?? newValue
        update(row.id, value: confirmed)
        editing = nil
        if confirmed == newValue {
            model.toast(tr("Wert übernommen"), message: "\(row.name) = \(confirmed)", style: .success)
        } else {
            model.toast(tr("Drucker meldet abweichenden Wert"),
                        message: tr("%@ ist jetzt „%@“ (gesendet: „%@“).", row.name, confirmed, newValue),
                        style: .warning)
        }
        return true
    }

    private func reread(_ row: ToolsSGDRow) async {
        guard let value = await session.getvar(row.name) else {
            model.toast(tr("Wert konnte nicht gelesen werden"), message: row.name, style: .warning)
            return
        }
        update(row.id, value: value)
    }

    private func update(_ id: ToolsSGDRow.ID, value: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            rows[index].value = value
            flashed = id
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard flashed == id else { return }
            withAnimation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion)) { flashed = nil }
        }
    }

    private func export(_ subset: [ToolsSGDRow], suffix: String?) {
        var dictionary: [String: SGDExportEntry] = [:]
        for row in subset {
            dictionary[row.name] = SGDExportEntry(
                value: row.value,
                type: row.typeText.isEmpty ? nil : row.typeText,
                range: row.rangeText.isEmpty ? nil : row.rangeText,
                access: row.accessText.isEmpty ? nil : row.accessText,
                archive: row.archive
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var baseName = tr("Einstellungen %@", session.displayName)
        if let suffix { baseName += " " + suffix }
        let fileName = ToolsFileExport.safeFileName(baseName) + ".json"
        do {
            let data = try encoder.encode(dictionary)
            if let url = try ToolsFileExport.save(data, suggestedName: fileName, contentType: .json) {
                model.toast(tr("Einstellungen exportiert"),
                            message: tr("%d Variablen · %@", subset.count, url.lastPathComponent), style: .success)
            }
        } catch {
            model.toast(tr("Export fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Wertzelle

private struct SGDValueCell: View {
    let row: ToolsSGDRow
    let query: String
    let isFlashed: Bool
    let reduceMotion: Bool
    @Binding var isEditing: Bool
    let onCommit: (String) async -> Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(ToolsHighlight.attributed(row.value.isEmpty ? "–" : row.value, query: query))
                .font(Theme.Typography.codeSmall)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer(minLength: 4)
            if row.isWritable {
                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .opacity(hovering || isEditing ? 1 : 0)
                .help(tr("Wert bearbeiten"))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isFlashed ? Theme.ready.opacity(0.3) : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(row.value)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            SGDValueEditor(row: row, reduceMotion: reduceMotion, onCommit: onCommit, onCancel: { isEditing = false })
        }
    }
}

// MARK: - Editor

private struct SGDValueEditor: View {
    let row: ToolsSGDRow
    let onCommit: (String) async -> Bool
    let onCancel: () -> Void
    /// Vom Explorer übergeben (App-Einstellung); die Systemeinstellung wird zusätzlich gelesen,
    /// weil das Popover nicht zwingend das `AppModel` der Umgebung erbt.
    private let preferenceReduceMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var draft: String
    @State private var saving = false
    @State private var failed = false
    @State private var shakeCount = 0
    @FocusState private var fieldFocused: Bool

    private let kind: ToolsSGDValueKind

    init(row: ToolsSGDRow, reduceMotion: Bool, onCommit: @escaping (String) async -> Bool,
         onCancel: @escaping () -> Void) {
        self.row = row
        self.preferenceReduceMotion = reduceMotion
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._draft = State(initialValue: row.value)
        var kind = ToolsSGDValueKind(type: row.typeText, range: row.rangeText)
        // Aktuellen Wert immer wählbar halten, auch wenn er nicht in der Auswahlliste steht.
        if case .choices(let options) = kind, !row.value.isEmpty, !options.contains(row.value) {
            kind = .choices([row.value] + options)
        }
        self.kind = kind
    }

    private var reduceMotion: Bool { systemReduceMotion || preferenceReduceMotion }
    private var validationMessage: String? { kind.validate(draft) }
    private var isUnchanged: Bool { kind.normalized(draft) == row.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconBadge(systemImage: ToolsSGDCatalog.symbol(for: row.group), tint: Theme.violet, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(kind.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            input

            if let validationMessage, !isUnchanged {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if failed {
                Label(tr("Der Drucker hat den Wert nicht übernommen."), systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Text(tr("Aktuell: %@", row.value.isEmpty ? "–" : row.value))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(tr("Abbrechen"), action: onCancel)
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    HStack(spacing: 6) {
                        if saving {
                            ProgressRing(progress: nil, size: 12, lineWidth: 2)
                        }
                        Text(tr("Übernehmen"))
                    }
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil || saving || isUnchanged)
            }
        }
        .padding(16)
        .frame(width: 360)
        .modifier(ToolsShakeEffect(trigger: shakeCount))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: validationMessage)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: failed)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var input: some View {
        switch kind {
        case .choices(let options):
            if options.count <= 3 {
                Picker(tr("Wert"), selection: $draft) {
                    ForEach(options, id: \.self) { option in
                        Text(verbatim: option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Picker(tr("Wert"), selection: $draft) {
                    ForEach(options, id: \.self) { option in
                        Text(verbatim: option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        case .integer(let range):
            HStack(spacing: 8) {
                valueField
                Stepper(tr("Wert ändern"),
                        onIncrement: { step(by: 1, in: range) },
                        onDecrement: { step(by: -1, in: range) })
                    .labelsHidden()
            }
        case .decimal, .ipv4, .text:
            valueField
        }
    }

    private var valueField: some View {
        TextField(tr("Wert"), text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(Theme.Typography.code)
            .focused($fieldFocused)
            .onSubmit(save)
    }

    private func step(by delta: Int, in range: ClosedRange<Int>?) {
        let current = Int(draft.trimmingCharacters(in: .whitespaces)) ?? (range?.lowerBound ?? 0)
        let (sum, overflow) = current.addingReportingOverflow(delta)
        var next = overflow ? current : sum
        if let range { next = next.clamped(to: range) }
        draft = String(next)
    }

    private func save() {
        guard validationMessage == nil, !saving, !isUnchanged else { return }
        saving = true
        failed = false
        let value = kind.normalized(draft)
        Task {
            let ok = await onCommit(value)
            saving = false
            if !ok {
                withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { failed = true }
                if !reduceMotion {
                    withAnimation(.linear(duration: 0.45)) { shakeCount += 1 }
                }
            }
        }
    }
}

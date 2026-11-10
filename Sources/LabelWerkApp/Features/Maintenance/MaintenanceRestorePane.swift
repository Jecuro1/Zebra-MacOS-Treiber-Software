import SwiftUI
import LabelWerkKit

/// Wiederherstellen & Klonen: Sicherung öffnen oder Konfiguration eines Druckers live lesen,
/// Wert-für-Wert mit dem Zieldrucker vergleichen, auswählen und mit Kontrolle übertragen.
struct MaintRestorePane: View {
    let session: PrinterSession
    let store: MaintenanceStore
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    private var restore: MaintRestoreController { store.restore }

    /// Drucker mit Rückkanal – mögliche Quellen und Ziele.
    private var candidates: [PrinterSession] {
        model.sessions.filter { $0.supportsStatus }
    }

    private var target: PrinterSession {
        if let id = restore.targetID, let found = model.session(for: id) { return found }
        return session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            MaintRestoreHeroCard(restore: restore, candidates: candidates, target: target, reduceMotion: reduceMotion)
                .maintAppear(1, reduceMotion: reduceMotion)

            if let document = restore.document {
                MaintRestoreSourceTargetCard(document: document, restore: restore, candidates: candidates,
                                             target: target, reduceMotion: reduceMotion)
                    .maintAppear(2, reduceMotion: reduceMotion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                stage(document: document)
            } else if restore.phase == .loading {
                MaintRestoreBusyCard(text: tr("Konfiguration wird gelesen …"), reduceMotion: reduceMotion)
                    .transition(.opacity)
            } else {
                MaintRestoreHowToCard(reduceMotion: reduceMotion)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            CelebrationBurst(trigger: restore.celebration, colors: [Theme.teal, Theme.ready, Theme.violet])
                .frame(height: 320)
                .allowsHitTesting(false)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: restore.phase)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: restore.document == nil)
    }

    @ViewBuilder
    private func stage(document: MaintBackupDocument) -> some View {
        switch restore.phase {
        case .empty:
            EmptyView()
        case .loading:
            MaintRestoreBusyCard(text: tr("Konfiguration wird gelesen …"), reduceMotion: reduceMotion)
                .transition(.opacity)
        case .comparing:
            MaintRestoreBusyCard(text: tr("Aktuelle Werte von „%@“ werden gelesen und verglichen …", target.displayName),
                                 reduceMotion: reduceMotion)
                .transition(.opacity)
        case .failed(let message):
            MaintRestoreErrorCard(message: message, target: target) {
                Task { await restore.compare(target: target) }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .ready:
            MaintDiffCard(restore: restore, target: target, reduceMotion: reduceMotion)
                .maintAppear(3, reduceMotion: reduceMotion)
                .transition(.opacity)
            MaintApplyCard(document: document, restore: restore, target: target, reduceMotion: reduceMotion)
                .maintAppear(4, reduceMotion: reduceMotion)
                .transition(.opacity)
        case .applying:
            MaintApplyProgressCard(restore: restore, target: target, reduceMotion: reduceMotion)
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
        case .finished:
            MaintApplyReportCard(restore: restore, target: target, reduceMotion: reduceMotion)
                .transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity))
        }
    }
}

// MARK: - Kopf

private struct MaintRestoreHeroCard: View {
    let restore: MaintRestoreController
    let candidates: [PrinterSession]
    let target: PrinterSession
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.teal) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 22) {
                    MaintFlowView(fromSymbol: "doc.badge.gearshape", toSymbol: target.model?.systemImage ?? "printer",
                                  tint: Theme.teal, active: restore.isBusy, reduceMotion: reduceMotion)
                        .frame(width: 220)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Wiederherstellen & Klonen"))
                            .font(Theme.Typography.title)
                        Text(tr("Öffne eine Sicherung oder lies die Konfiguration eines anderen Druckers. LabelWerk zeigt jeden Unterschied und überträgt nur, was du auswählst – auf diesen oder jeden anderen verbundenen Drucker."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await restore.openFile(target: target, model: model) }
                    } label: {
                        Label(tr("Sicherung öffnen …"), systemImage: "folder")
                    }
                    .buttonStyle(restore.document == nil ? LabelWerkButtonStyle.labelWerkPrimary
                                                         : LabelWerkButtonStyle.labelWerkSecondary)

                    Menu {
                        ForEach(candidates) { printer in
                            Button {
                                readConfiguration(of: printer)
                            } label: {
                                Label(printer.displayName, systemImage: printer.model?.systemImage ?? "printer")
                            }
                        }
                    } label: {
                        Label(tr("Konfiguration von Drucker lesen"), systemImage: "tray.and.arrow.down")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.labelWerkSecondary)
                    .fixedSize()
                    .disabled(!hasSecondPrinter)
                    .help(hasSecondPrinter
                          ? tr("Liest die aktuelle Konfiguration eines eingerichteten Druckers als Quelle – zum Klonen ohne Datei")
                          : tr("Zum Klonen wird ein zweiter eingerichteter Drucker mit Rückkanal (USB, Netzwerk oder Bluetooth) benötigt."))

                    Spacer(minLength: 8)

                    if restore.document != nil {
                        Button {
                            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { restore.clear() }
                        } label: {
                            Label(tr("Quelle entfernen"), systemImage: "xmark.circle")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .transition(.opacity)
                    }
                }
                .disabled(restore.isBusy)
            }
        }
    }

    /// Klonen braucht neben der Quelle mindestens einen weiteren Drucker mit Rückkanal.
    private var hasSecondPrinter: Bool { candidates.count > 1 }

    /// Ziel beim Klonen: das gewählte Ziel – außer es ist die Quelle selbst, dann ein anderer Drucker.
    /// `nil`, wenn es keinen anderen gibt (ein Vergleich mit sich selbst wäre sinnlos).
    private func cloneTarget(for source: PrinterSession) -> PrinterSession? {
        if source.id != target.id { return target }
        let others = candidates.filter { $0.id != source.id }
        return others.first(where: { $0.connectionState.isConnected }) ?? others.first
    }

    private func readConfiguration(of printer: PrinterSession) {
        guard let destination = cloneTarget(for: printer) else {
            model.toast(tr("Kein Zieldrucker"),
                        message: tr("Zum Klonen wird ein zweiter eingerichteter Drucker mit Rückkanal (USB, Netzwerk oder Bluetooth) benötigt."),
                        style: .warning)
            return
        }
        Task { await restore.loadFromPrinter(printer, target: destination, model: model) }
    }
}

// MARK: - Anleitung (ohne Quelle)

private struct MaintRestoreHowToCard: View {
    let reduceMotion: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("So funktioniert’s"),
                              subtitle: tr("Ideal, um mehrere Drucker identisch einzurichten oder nach einem Werksreset zurückzukehren"),
                              systemImage: "lightbulb")
                HStack(alignment: .top, spacing: 12) {
                    step(1, symbol: "doc.badge.gearshape", title: tr("Quelle wählen"),
                         text: tr("Eine .lwbackup-Datei öffnen oder die Konfiguration eines eingerichteten Druckers direkt lesen."))
                    step(2, symbol: "plus.forwardslash.minus", title: tr("Unterschiede prüfen"),
                         text: tr("Jeder Wert wird mit dem Zieldrucker verglichen. Vorausgewählt sind nur abweichende, beschreibbare Werte – Netzwerk, gerätespezifische Werte und eine unpassende Druckersprache bleiben aus."))
                    step(3, symbol: "checkmark.shield", title: tr("Übertragen & prüfen"),
                         text: tr("Gedrückt halten startet die Übertragung. Jeder Wert wird geschrieben und anschließend gegengelesen."))
                }
            }
        }
    }

    private func step(_ number: Int, symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconBadge(systemImage: symbol, tint: Theme.teal, size: 30)
                Text(verbatim: "\(number)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brandGradient)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
        .maintAppear(number + 1, reduceMotion: reduceMotion)
    }
}

// MARK: - Quelle & Ziel

private struct MaintRestoreSourceTargetCard: View {
    let document: MaintBackupDocument
    let restore: MaintRestoreController
    let candidates: [PrinterSession]
    let target: PrinterSession
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    sourceColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    arrow
                    targetColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                warnings
            }
        }
    }

    private var sourceTitle: String {
        switch restore.source {
        case .file(let name): return tr("Sicherung „%@“", name)
        case .printer(let name): return tr("Live gelesen von „%@“", name)
        case nil: return tr("Quelle")
        }
    }

    private var sourceSymbol: String {
        switch restore.source {
        case .file: return "doc.fill"
        case .printer, nil: return "printer"
        }
    }

    private func modelName(_ id: String?) -> String? {
        id.flatMap { model.catalog.model(id: $0)?.displayName }
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(sourceTitle, systemImage: sourceSymbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(document.printerName.isEmpty ? tr("Unbenannter Drucker") : document.printerName)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
            KeyValueRow(tr("Modell"), document.identity.model ?? modelName(document.modelID) ?? "–")
            KeyValueRow(tr("Seriennummer"), document.identity.serialNumber ?? "–", monospaced: true)
            KeyValueRow(tr("Firmware"), document.identity.firmware ?? "–", monospaced: true)
            KeyValueRow(tr("Erstellt"), document.createdAt.formatted(date: .abbreviated, time: .shortened))
            KeyValueRow(tr("Inhalt"), tr("%d Werte · %d Gruppen", document.entries.count, document.groups.count))
            if let files = document.files, !files.isEmpty {
                KeyValueRow(tr("Dateiliste"), tr("%d Dateien (nur Namen)", files.count))
            }
        }
    }

    private var arrow: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .symbolEffect(.bounce, value: reduceMotion ? UUID?.none : restore.targetID)
            MaintChip(restore.isSameDevice ? tr("Wiederherstellen") : tr("Klonen"),
                      systemImage: restore.isSameDevice ? "arrow.uturn.backward" : "square.on.square",
                      tint: restore.isSameDevice ? Theme.ready : Theme.teal)
                .contentTransition(.opacity)
                .help(restore.isSameDevice
                      ? tr("Gleiche Seriennummer: Die Sicherung stammt von diesem Drucker.")
                      : tr("Anderer Drucker: Gerätespezifische Werte (Name, Adressen) sind nicht vorausgewählt."))
        }
        .padding(.top, 30)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: restore.isSameDevice)
    }

    /// Mögliche Ziele – ohne den Drucker, dessen Konfiguration live gelesen wurde (außer er ist bereits Ziel).
    private var targetChoices: [PrinterSession] {
        candidates.filter { $0.id != restore.sourcePrinterID || $0.id == target.id }
    }

    private var targetBinding: Binding<UUID?> {
        Binding(
            get: { restore.targetID ?? target.id },
            set: { newValue in
                guard let id = newValue, let printer = model.session(for: id) else { return }
                Task { await restore.compare(target: printer) }
            }
        )
    }

    private var targetColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("Zieldrucker"), systemImage: "scope")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker(tr("Zieldrucker"), selection: targetBinding) {
                ForEach(targetChoices) { printer in
                    Text(printer.displayName).tag(UUID?.some(printer.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
            .disabled(restore.isBusy)
            HStack(spacing: 8) {
                StatusPill(state: target.state, text: target.connectionState.displayName)
                if !target.connectionState.isConnected && target.connectionState != .connecting {
                    Button(tr("Verbinden")) {
                        Task { await target.connect() }
                    }
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.small)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await restore.compare(target: target) }
                } label: {
                    Label(tr("Neu vergleichen"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.labelWerkPlain)
                .controlSize(.small)
                .disabled(restore.isBusy)
            }
            KeyValueRow(tr("Modell"), target.model?.displayName ?? target.identity?.model ?? "–")
            KeyValueRow(tr("Seriennummer"), target.identity?.serialNumber ?? "–", monospaced: true)
            KeyValueRow(tr("Firmware"), target.identity?.firmware ?? "–", monospaced: true)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        let targetModelID = target.saved.modelID
        if let sourceModelID = document.modelID, let targetModelID, sourceModelID != targetModelID {
            MaintNote(tr("Die Sicherung stammt von einem anderen Modell (%@). Werte, die der Zieldrucker nicht kennt, werden ausgelassen.",
                         modelName(sourceModelID) ?? sourceModelID),
                      style: .warning)
        }
        if document.resolution != target.resolution {
            MaintNote(tr("Andere Auflösung (%d dpi → %d dpi): Positions- und Längenwerte in Punkten passen eventuell nicht – bitte prüfen.",
                         document.resolution.dpi, target.resolution.dpi),
                      style: .warning)
        }
    }
}

// MARK: - Laden & Fehler

private struct MaintRestoreBusyCard: View {
    let text: String
    let reduceMotion: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<5, id: \.self) { index in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.separator)
                                .frame(width: 14, height: 14)
                            Capsule()
                                .fill(Theme.separator)
                                .frame(width: CGFloat(160 + (index * 37) % 90), height: 9)
                            Spacer()
                            Capsule()
                                .fill(Theme.subtleFill)
                                .frame(width: CGFloat(120 + (index * 53) % 80), height: 9)
                        }
                    }
                }
                .shimmering(active: !reduceMotion)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MaintRestoreErrorCard: View {
    let message: String
    let target: PrinterSession
    let retry: () -> Void

    var body: some View {
        GlassCard(tint: Theme.error) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: "exclamationmark.triangle.fill", tint: Theme.error, size: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Vergleich nicht möglich"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !target.connectionState.isConnected {
                    Button {
                        Task {
                            await target.connect()
                            retry()
                        }
                    } label: {
                        Label(tr("Verbinden"), systemImage: "bolt.fill")
                    }
                    .buttonStyle(.labelWerkSecondary)
                }
                Button(action: retry) {
                    Label(tr("Erneut versuchen"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkPrimary)
            }
        }
    }
}

// MARK: - Unterschiede

private struct MaintDiffCard: View {
    @Bindable var restore: MaintRestoreController
    let target: PrinterSession
    let reduceMotion: Bool

    var body: some View {
        let visible = restore.visibleRows
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Unterschiede"),
                              subtitle: tr("%d abweichend · %d ausgewählt · %d nicht übertragbar",
                                           restore.changedCount, restore.selectedRows.count, restore.blockedCount),
                              systemImage: "plus.forwardslash.minus") {
                    Button {
                        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                            restore.resetSelection(target: target)
                        }
                    } label: {
                        Label(tr("Vorauswahl"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("Abweichende, beschreibbare Werte ohne Netzwerk und ohne unpassende Druckersprache auswählen"))
                }

                filterBar

                if restore.selectedNetworkCount > 0 {
                    MaintNote(tr("%d Netzwerkwerte ausgewählt. Sie werden zuletzt geschrieben und wirken meist erst nach einem Neustart. Doppelte IP-Adressen im Netz vermeiden!",
                                 restore.selectedNetworkCount),
                              style: .warning)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if visible.isEmpty {
                    emptyRows
                        .transition(.opacity)
                } else {
                    VStack(spacing: 4) {
                        HStack {
                            Text(tr("Einstellung"))
                            Spacer()
                            Text(tr("Zieldrucker aktuell → aus der Sicherung"))
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                        .padding(.trailing, 10)
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(visible) { row in
                                    MaintDiffRow(row: row, isSelected: restore.isSelected(row)) {
                                        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                                            restore.toggle(row)
                                        }
                                    }
                                }
                            }
                            .padding(4)
                        }
                        .frame(height: min(400, max(120, CGFloat(visible.count) * 46 + 8)))
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: restore.filter)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: restore.groupFilter)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: restore.selectedNetworkCount)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker(tr("Anzeigen"), selection: $restore.filter) {
                    ForEach(MaintRestoreController.Filter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)

                Picker(selection: $restore.groupFilter) {
                    Text(tr("Alle Gruppen")).tag(String?.none)
                    Divider()
                    ForEach(restore.groupsInRows, id: \.self) { group in
                        Text(MaintSGDPolicy.displayName(group: group)).tag(String?.some(group))
                    }
                } label: {
                    Label(tr("Gruppe"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .frame(maxWidth: 230)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                TextField(tr("Name oder Wert suchen"), text: $restore.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer(minLength: 0)
                Button(tr("Alle sichtbaren auswählen")) {
                    withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                        restore.setVisibleSelection(true)
                    }
                }
                .buttonStyle(.labelWerkPlain)
                Button(tr("Sichtbare abwählen")) {
                    withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                        restore.setVisibleSelection(false)
                    }
                }
                .buttonStyle(.labelWerkPlain)
            }
        }
    }

    private var emptyRows: some View {
        let inSync = restore.filter == .changed && restore.changedCount == 0
        return VStack(spacing: 8) {
            Image(systemName: inSync ? "checkmark.seal.fill" : "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(inSync ? Theme.ready : Color.secondary)
                .symbolEffect(.bounce, value: reduceMotion ? false : inSync)
            Text(inSync ? tr("Keine Unterschiede – der Zieldrucker entspricht bereits der Sicherung.")
                        : tr("Keine passenden Einträge."))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

private struct MaintDiffRow: View {
    let row: MaintRestoreRow
    let isSelected: Bool
    let toggle: () -> Void

    @State private var hovering = false

    private var statusText: String {
        switch row.status {
        case .changed: return tr("Abweichend")
        case .unchanged: return tr("Bereits gleich")
        case .readOnly: return tr("Am Zieldrucker nur lesbar")
        case .missing: return tr("Am Zieldrucker nicht vorhanden")
        case .protected: return tr("Befehl oder Geheimnis – wird nie geschrieben")
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .changed: return Theme.accent
        case .unchanged: return Theme.ready
        case .readOnly, .missing, .protected: return Theme.offline
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: toggle) {
            HStack(spacing: 10) {
                MaintCheckbox(isOn: isSelected && row.isSelectable, isEnabled: row.isSelectable,
                              tint: row.isNetwork ? Theme.warning : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.name)
                            .font(Theme.Typography.code)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if row.isNetwork {
                            MaintChip(tr("Netzwerk"), systemImage: "network", tint: Theme.warning)
                        }
                        if row.isDeviceSpecific {
                            MaintChip(tr("gerätespezifisch"), systemImage: "tag", tint: Theme.magenta)
                        }
                    }
                    Text(statusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                MaintValueTransition(from: row.currentValue, to: row.backupValue, highlight: row.status == .changed)
                    .frame(maxWidth: 380, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(shape.fill(isSelected ? Theme.accent.opacity(0.08) : (hovering ? Theme.subtleFill : Color.clear)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!row.isSelectable)
        .onHover { hovering = $0 }
        .help(row.range.map { tr("Zulässig: %@", $0) } ?? statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Übertragen

private struct MaintApplyCard: View {
    let document: MaintBackupDocument
    @Bindable var restore: MaintRestoreController
    let target: PrinterSession
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    private var driverDetail: String {
        let stockName = model.stock(id: document.stockID)?.name ?? document.stock?.name ?? document.stockID
        return tr("Schwärzung, Geschwindigkeit & Co., Etikettenformat „%@“ und Ausgabesprache %@ für „%@“ in LabelWerk.",
                  stockName, document.language.displayName, target.displayName)
    }

    /// Schalter „dauerhaft speichern“: zeigt „aus“, solange der Drucker ^JUS nicht verstehen würde.
    private func saveBinding(available: Bool) -> Binding<Bool> {
        Binding(
            get: { available && restore.saveToPrinter },
            set: { restore.saveToPrinter = $0 }
        )
    }

    private func languageConflictText(_ value: String) -> String {
        let title = MaintDeviceLanguage.option(for: value)?.title ?? value
        let output = restore.effectiveOutput(for: target)
        let driverFixes = !restore.applyDriverSettings
            && (target.model?.supports(document.language) ?? true)
            && MaintDeviceLanguage.isCompatible(deviceValue: value, output: document.language, model: target.model)
        if driverFixes {
            return tr("Die Auswahl stellt „%@“ auf die Druckersprache „%@“ um, LabelWerk sendet aber %@ – Etiketten würden danach als Text oder gar nicht gedruckt. „Treibereinstellungen ebenfalls übernehmen“ einschalten (stellt LabelWerk auf %@ um) oder device.languages abwählen.",
                      target.displayName, title, output.displayName, document.language.displayName)
        }
        return tr("Die Auswahl stellt „%@“ auf die Druckersprache „%@“ um, LabelWerk sendet aber %@ – Etiketten würden danach als Text oder gar nicht gedruckt. device.languages abwählen oder die Ausgabesprache anpassen.",
                  target.displayName, title, output.displayName)
    }

    var body: some View {
        let count = restore.selectedRows.count
        let canApply = (count > 0 || restore.applyDriverSettings) && target.connectionState.isConnected
        let saveSkip = restore.predictedSaveSkip(for: target)
        let languageConflict = restore.languageConflict(for: target)
        GlassCard(padding: 18, tint: Theme.teal) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Übertragen"),
                              subtitle: tr("Werte werden nacheinander geschrieben und danach gegengelesen"),
                              systemImage: "arrow.up.doc")
                Toggle(isOn: $restore.applyDriverSettings) {
                    toggleLabel(tr("Treibereinstellungen ebenfalls übernehmen"), detail: driverDetail)
                }
                .toggleStyle(.switch)
                .disabled(document.driverSettings == nil && document.stockID.isEmpty)
                Toggle(isOn: saveBinding(available: saveSkip == nil)) {
                    toggleLabel(tr("Einstellungen dauerhaft speichern"),
                                detail: tr("Sendet danach „Einstellungen speichern“ (^JUS), damit die Werte einen Neustart überstehen."))
                }
                .toggleStyle(.switch)
                .disabled(saveSkip != nil)

                if let saveSkip, count > 0 {
                    MaintNote(saveSkip.explanation, style: .info)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let languageConflict {
                    MaintNote(languageConflictText(languageConflict), style: .warning)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !target.connectionState.isConnected {
                    MaintNote(tr("„%@“ ist nicht verbunden. Bitte zuerst verbinden.", target.displayName), style: .warning)
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count > 0 ? tr("%d Werte ausgewählt", count) : tr("Keine Werte ausgewählt"))
                            .font(.system(size: 14, weight: .semibold))
                            .contentTransition(.numericText(value: Double(count)))
                            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: count)
                        Text(tr("Ziel: %@", target.displayName))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    HoldToConfirmButton(
                        title: count > 0 ? tr("%d Werte übertragen", count) : tr("Treibereinstellungen übernehmen"),
                        systemImage: "arrow.up.circle.fill",
                        tint: Theme.teal,
                        duration: 1.0
                    ) {
                        Task { await restore.apply(target: target, model: model) }
                    }
                    .disabled(!canApply)
                    .allowsHitTesting(canApply)
                    .opacity(canApply ? 1 : 0.45)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: saveSkip)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: languageConflict)
    }

    private func toggleLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MaintApplyProgressCard: View {
    let restore: MaintRestoreController
    let target: PrinterSession
    let reduceMotion: Bool

    var body: some View {
        let done = restore.items.filter { $0.state.isFinal }.count
        GlassCard(padding: 18, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.teal) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    MaintFlowView(fromSymbol: "doc.badge.gearshape", toSymbol: target.model?.systemImage ?? "printer",
                                  tint: Theme.teal, active: true, reduceMotion: reduceMotion)
                        .frame(width: 200)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(restore.isVerifying ? tr("Werte werden gegengelesen …") : tr("Werte werden übertragen …"))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .contentTransition(.opacity)
                        Text(verbatim: restore.currentItem ?? " ")
                            .font(Theme.Typography.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        Text(tr("%d von %d", done, restore.items.count))
                            .font(Theme.Typography.metricSmall)
                            .contentTransition(.numericText(value: Double(done)))
                    }
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: done)
                    Spacer(minLength: 8)
                    Button {
                        restore.cancelApply()
                    } label: {
                        Label(restore.cancelRequested ? tr("Wird abgebrochen …") : tr("Abbrechen"),
                              systemImage: "stop.fill")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(restore.cancelRequested || restore.isVerifying)
                    .help(tr("Bricht nach dem aktuellen Wert ab"))
                }
                StripedProgressBar(progress: restore.progress, tint: Theme.teal)
                MaintApplyList(items: restore.items, current: restore.currentItem, reduceMotion: reduceMotion)
            }
        }
    }
}

private struct MaintApplyList: View {
    let items: [MaintApplyItem]
    let current: String?
    let reduceMotion: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        MaintApplyRow(item: item, isCurrent: item.name == current)
                            .id(item.name)
                        Divider().opacity(0.3)
                    }
                }
            }
            .frame(height: min(300, max(70, CGFloat(items.count) * 33)))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
            .onChange(of: current) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

private struct MaintApplyRow: View {
    let item: MaintApplyItem
    let isCurrent: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var note: (text: String, color: Color)? {
        switch item.state {
        case .mismatch(let reported):
            return (tr("Drucker meldet „%@“", reported), Theme.warning)
        case .failed(let message):
            return (message, Theme.error)
        case .skipped:
            return (tr("übersprungen"), Theme.offline)
        case .written:
            return (tr("gesendet"), Theme.teal)
        default:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            MaintApplyStateIcon(state: item.state)
            Text(verbatim: item.name)
                .font(Theme.Typography.codeSmall)
                .lineLimit(1)
            if item.isNetwork {
                MaintChip(tr("Netzwerk"), tint: Theme.warning)
            }
            Spacer(minLength: 8)
            if let note {
                Text(note.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(note.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .transition(.opacity)
            }
            Text(verbatim: item.value.isEmpty ? "\u{201E}\u{201C}" : item.value)
                .font(Theme.Typography.codeSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(isCurrent ? Theme.teal.opacity(0.12) : Color.clear, in: Rectangle())
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: item.state)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isCurrent)
    }
}

// MARK: - Ergebnis

private struct MaintApplyReportCard: View {
    let restore: MaintRestoreController
    let target: PrinterSession
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        if let report = restore.report {
            content(report)
                .onAppear {
                    if reduceMotion {
                        appeared = true
                    } else {
                        withAnimation(Motion.bouncy.delay(0.1)) { appeared = true }
                    }
                }
        }
    }

    private func content(_ report: MaintApplyReport) -> some View {
        let tint = report.isClean ? Theme.ready : Theme.warning
        return GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: tint) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    IconBadge(systemImage: report.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                              tint: tint, size: 56)
                        .scaleEffect(appeared ? 1 : 0.4)
                        .opacity(appeared ? 1 : 0)
                        .symbolEffect(.bounce, value: reduceMotion ? false : appeared)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline(report))
                            .font(Theme.Typography.title)
                        Text(tr("„%@“ → „%@“ · %@", report.sourceName, report.targetName,
                                report.date.formatted(date: .omitted, time: .shortened)))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 28) {
                    MaintStat(value: report.sent, title: tr("gesendet"), tint: Theme.teal)
                    MaintStat(value: report.verified, title: tr("bestätigt"), tint: Theme.ready)
                    MaintStat(value: report.mismatched, title: tr("abweichend"), tint: Theme.warning)
                    MaintStat(value: report.failed, title: tr("fehlgeschlagen"), tint: Theme.error)
                    MaintStat(value: report.skipped, title: tr("übersprungen"), tint: Theme.offline)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if report.unverified > 0 {
                        MaintNote(tr("%d Werte gesendet, aber nicht gegengelesen – der Drucker hat sie nach dem Schreiben nicht gemeldet. Bitte mit „Erneut vergleichen“ prüfen.",
                                     report.unverified),
                                  style: .warning)
                    }
                    if let saved = report.savedPermanently {
                        MaintNote(saved ? tr("Dauerhaft im Drucker gespeichert.")
                                        : tr("Dauerhaftes Speichern ist fehlgeschlagen – manche Werte gehen beim Ausschalten verloren."),
                                  style: saved ? .success : .warning)
                    } else if let skip = report.saveSkipped {
                        MaintNote(skip.explanation, style: .info)
                    } else if report.sent > 0 {
                        MaintNote(tr("Nicht dauerhaft gespeichert: Manche Werte gelten nur bis zum Ausschalten."), style: .info)
                    }
                    if report.driverApplied {
                        MaintNote(tr("Treibereinstellungen, Etikettenformat und Ausgabesprache wurden in LabelWerk übernommen."),
                                  style: .success)
                    }
                    if report.mismatched > 0 {
                        MaintNote(tr("Bei %d Werten meldet der Drucker einen anderen Wert – er hat sie angepasst oder unterstützt sie nicht.",
                                     report.mismatched),
                                  style: .warning)
                    }
                    if report.cancelled {
                        MaintNote(tr("Abgebrochen – nicht alle Werte wurden übertragen."), style: .warning)
                    }
                    if report.networkChanged {
                        HStack(spacing: 12) {
                            MaintNote(tr("Netzwerkänderungen werden erst nach einem Neustart des Druckers wirksam. Danach ist er ggf. unter einer neuen Adresse erreichbar."),
                                      style: .warning)
                            HoldToConfirmButton(title: tr("Drucker neu starten"), systemImage: "power", tint: Theme.warning) {
                                Task { await restore.restart(target: target, model: model) }
                            }
                        }
                    }
                }

                if !restore.items.isEmpty {
                    MaintApplyList(items: restore.items, current: nil, reduceMotion: reduceMotion)
                }

                HStack(spacing: 8) {
                    Button {
                        MaintFiles.copy(restore.reportText(report))
                        model.toast(tr("Bericht kopiert"), style: .success)
                    } label: {
                        Label(tr("Bericht kopieren"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    Button {
                        Task { await restore.compare(target: target) }
                    } label: {
                        Label(tr("Erneut vergleichen"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { restore.clear() }
                    } label: {
                        Label(tr("Fertig"), systemImage: "checkmark")
                    }
                    .buttonStyle(.labelWerkPrimary)
                }
            }
        }
    }

    private func headline(_ report: MaintApplyReport) -> String {
        if report.cancelled { return tr("Übertragung abgebrochen") }
        if report.isClean { return tr("Konfiguration übertragen") }
        if report.failed > 0 { return tr("Mit Fehlern übertragen") }
        return tr("Mit Hinweisen übertragen")
    }
}

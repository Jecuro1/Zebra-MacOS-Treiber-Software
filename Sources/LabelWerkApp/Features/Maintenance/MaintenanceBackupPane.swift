import SwiftUI
import LabelWerkKit

/// Sicherung: alle Einstellungen lesen, Gruppen wählen, als `.lwbackup` speichern oder direkt klonen.
struct MaintBackupPane: View {
    let session: PrinterSession
    let store: MaintenanceStore
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    private var backup: MaintBackupController { store.backup }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            MaintBackupHeroCard(session: session, backup: backup, reduceMotion: reduceMotion)
                .maintAppear(1, reduceMotion: reduceMotion)

            switch backup.phase {
            case .idle:
                MaintBackupIntroCard()
                    .maintAppear(2, reduceMotion: reduceMotion)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            case .reading:
                MaintBackupProgressCard(backup: backup, reduceMotion: reduceMotion)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
            case .failed(let message):
                MaintBackupErrorCard(message: message) {
                    Task { await backup.read(session: session) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            case .ready:
                VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                    MaintBackupGroupsCard(backup: backup, reduceMotion: reduceMotion)
                        .maintAppear(2, reduceMotion: reduceMotion)
                    MaintBackupExtrasCard(session: session, backup: backup)
                        .maintAppear(3, reduceMotion: reduceMotion)
                    MaintBackupPreviewCard(entries: backup.previewEntries, reduceMotion: reduceMotion)
                        .maintAppear(4, reduceMotion: reduceMotion)
                    MaintBackupActionsCard(session: session, store: store, reduceMotion: reduceMotion)
                        .maintAppear(5, reduceMotion: reduceMotion)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: backup.phase)
    }
}

// MARK: - Kopf

private struct MaintBackupHeroCard: View {
    let session: PrinterSession
    let backup: MaintBackupController
    let reduceMotion: Bool

    var body: some View {
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.violet) {
            HStack(alignment: .center, spacing: 22) {
                MaintFlowView(fromSymbol: session.model?.systemImage ?? "printer",
                              toSymbol: "externaldrive.badge.plus",
                              tint: Theme.violet, active: backup.isReading, reduceMotion: reduceMotion)
                    .frame(width: 220)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Konfiguration sichern"))
                        .font(Theme.Typography.title)
                    Text(tr("Liest sämtliche Einstellungen des Druckers und speichert sie als .lwbackup-Datei – zum Wiederherstellen nach einem Werksreset oder zum Klonen auf weitere Drucker."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let readAt = backup.readAt, backup.phase == .ready {
                        HStack(spacing: 6) {
                            MaintChip(tr("%d Werte", backup.settings.count), systemImage: "slider.horizontal.3",
                                      tint: Theme.violet)
                            MaintChip(tr("%d Gruppen", backup.groups.count), systemImage: "square.grid.2x2",
                                      tint: Theme.teal)
                            MaintChip(tr("%d Dateien", backup.files.count), systemImage: "externaldrive",
                                      tint: Theme.printing)
                            Text(tr("gelesen um %@", readAt.formatted(date: .omitted, time: .shortened)))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                Spacer(minLength: 8)
                readButton
            }
        }
    }

    @ViewBuilder
    private var readButton: some View {
        if backup.phase == .ready {
            Button {
                Task { await backup.read(session: session) }
            } label: {
                Label(tr("Neu lesen"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(session.isBusy)
        } else {
            Button {
                Task { await backup.read(session: session) }
            } label: {
                HStack(spacing: 6) {
                    if backup.isReading {
                        ProgressRing(progress: nil, size: 13, lineWidth: 2)
                    } else {
                        Image(systemName: "arrow.down.doc")
                    }
                    Text(backup.isReading ? tr("Wird gelesen …") : tr("Einstellungen lesen"))
                }
            }
            .buttonStyle(.labelWerkPrimary)
            .controlSize(.large)
            .disabled(backup.isReading)
        }
    }
}

// MARK: - Einführung

private struct MaintBackupIntroCard: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Was wird gesichert?"),
                              subtitle: tr("Du wählst nach dem Lesen, welche Gruppen in die Sicherung kommen"),
                              systemImage: "shippingbox")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    item(symbol: "printer", tint: Theme.violet, title: tr("Druckereinstellungen"),
                         text: tr("Gerät, Medien, Druck, Bedienverhalten und ZPL – alle Werte, die sich wieder schreiben lassen."))
                    item(symbol: "slider.horizontal.3", tint: Theme.teal, title: tr("Treibereinstellungen"),
                         text: tr("Schwärzung, Geschwindigkeit, Etikettenformat und Ausgabesprache von LabelWerk."))
                    item(symbol: "externaldrive", tint: Theme.printing, title: tr("Dateiliste"),
                         text: tr("Namen und Größen der Schriften, Grafiken und Formate auf dem Drucker (ohne Inhalte)."))
                }
                MaintNote(tr("Netzwerkwerte werden nur auf Wunsch gesichert. Zählerstände, Sensorwerte, Befehle und Passwörter landen nie in einer Sicherung."),
                          style: .info)
            }
        }
    }

    private func item(symbol: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(systemImage: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
    }
}

// MARK: - Fortschritt

private struct MaintBackupProgressCard: View {
    let backup: MaintBackupController
    let reduceMotion: Bool

    var body: some View {
        GlassCard(tint: Theme.violet) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Konfiguration wird gelesen"),
                              subtitle: tr("Große Konfigurationen brauchen einige Sekunden – bitte den Drucker nicht ausschalten."),
                              systemImage: "arrow.down.doc")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MaintBackupController.Step.allCases) { step in
                        MaintStepRow(title: step.title, systemImage: step.systemImage, state: state(of: step))
                    }
                }
                StripedProgressBar(progress: max(0.06, backup.stepProgress), tint: Theme.violet)
                    .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: backup.stepProgress)
            }
        }
    }

    private func state(of step: MaintBackupController.Step) -> MaintStepRow.StepState {
        if backup.completedSteps.contains(step) { return .done }
        if backup.activeStep == step { return .active }
        return .pending
    }
}

private struct MaintBackupErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        GlassCard(tint: Theme.error) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: "exclamationmark.triangle.fill", tint: Theme.error, size: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Einstellungen konnten nicht gelesen werden"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tr("Ältere Drucker ohne Link-OS unterstützen das Auslesen der Gesamtkonfiguration (allconfig) teilweise nicht."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: retry) {
                    Label(tr("Erneut versuchen"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkPrimary)
            }
        }
    }
}

// MARK: - Gruppen

private struct MaintBackupGroupsCard: View {
    let backup: MaintBackupController
    let reduceMotion: Bool

    var body: some View {
        let selectedGroups = backup.groups.filter { backup.isIncluded($0) }.count
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Was soll gesichert werden?"),
                              subtitle: tr("%d Werte aus %d Gruppen ausgewählt", backup.includedEntryCount, selectedGroups),
                              systemImage: "checklist") {
                    HStack(spacing: 4) {
                        Button(tr("Standard")) {
                            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                                backup.selectDefaults()
                            }
                        }
                        .buttonStyle(.labelWerkPlain)
                        Button(tr("Keine")) {
                            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                                backup.selectNone()
                            }
                        }
                        .buttonStyle(.labelWerkPlain)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach(backup.groups) { group in
                        MaintGroupTile(group: group, isOn: backup.isIncluded(group), reduceMotion: reduceMotion) {
                            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                                backup.setIncluded(!backup.isIncluded(group), group: group)
                            }
                        }
                    }
                }

                if backup.includesNetwork {
                    MaintNote(tr("Netzwerkwerte sind enthalten. Beim Wiederherstellen auf einem anderen Drucker drohen doppelte IP-Adressen; Änderungen können die Verbindung trennen. LabelWerk überträgt sie nur, wenn du sie ausdrücklich auswählst."),
                              style: .warning)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if backup.protectedCount + backup.readOnlyCount > 0 {
                    MaintNote(tr("Nie gesichert: %d Befehle bzw. Passwörter und %d nur lesbare Werte (Zähler, Sensoren, Gerätedaten).",
                                 backup.protectedCount, backup.readOnlyCount),
                              style: .info)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: backup.includesNetwork)
    }
}

private struct MaintGroupTile: View {
    let group: MaintGroupSummary
    let isOn: Bool
    let reduceMotion: Bool
    let toggle: () -> Void

    @State private var hovering = false

    private var isExcluded: Bool { group.kind == .excluded }

    private var subtitle: String {
        if isExcluded {
            if MaintSGDPolicy.readOnlyGroups.contains(group.id.lowercased()) {
                return tr("Zählerstände – nur lesbar")
            }
            return tr("Keine sicherbaren Werte")
        }
        return tr("%d von %d Werten sicherbar", group.restorable, group.total)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tint = isExcluded ? Theme.offline : group.kind.tint
        Button(action: toggle) {
            HStack(spacing: 10) {
                IconBadge(systemImage: MaintSGDPolicy.systemImage(group: group.id), tint: tint, size: 30)
                    .saturation(isExcluded ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(MaintSGDPolicy.displayName(group: group.id))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if group.kind == .network {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Text(verbatim: group.id + ".*")
                        .font(Theme.Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isExcluded {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    MaintCheckbox(isOn: isOn, tint: tint)
                }
            }
            .padding(10)
            .background(shape.fill(isOn ? tint.opacity(0.1) : Theme.subtleFill))
            .overlay(shape.strokeBorder(isOn ? tint.opacity(0.5) : Theme.cardStroke, lineWidth: 1))
            .scaleEffect(hovering && !isExcluded && !reduceMotion ? 1.015 : 1)
            .opacity(isExcluded ? 0.6 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(isExcluded)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isOn)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .help(isExcluded ? tr("Diese Gruppe wird nie gesichert.") : group.kind.badge)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Zusätzliche Inhalte

private struct MaintBackupExtrasCard: View {
    let session: PrinterSession
    @Bindable var backup: MaintBackupController

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Außerdem in der Sicherung"), systemImage: "plus.square.on.square")
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        KeyValueRow(tr("Drucker"), session.displayName)
                        KeyValueRow(tr("Modell"), session.model?.displayName ?? session.identity?.model ?? "–")
                        KeyValueRow(tr("Seriennummer"), session.identity?.serialNumber ?? "–", monospaced: true)
                        KeyValueRow(tr("Firmware"), session.identity?.firmware ?? "–", monospaced: true)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        KeyValueRow(tr("Etikettenformat"), session.stock.name)
                        KeyValueRow(tr("Ausgabesprache"), session.saved.language.displayName)
                        KeyValueRow(tr("Auflösung"), session.resolution.displayName)
                        KeyValueRow(tr("Treibereinstellungen"), tr("Schwärzung, Tempo, Versatz …"))
                    }
                    .frame(maxWidth: .infinity)
                }
                Divider().opacity(0.5)
                Toggle(isOn: $backup.includeFileList) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Dateiliste aufnehmen"))
                            .font(.system(size: 13, weight: .medium))
                        Text(backup.files.isEmpty
                             ? tr("Auf Laufwerk E: wurden keine Dateien gefunden.")
                             : tr("%d Dateien auf Laufwerk E: – nur Namen und Größen, keine Inhalte.", backup.files.count))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(backup.files.isEmpty)
            }
        }
    }
}

// MARK: - Vorschau

private struct MaintBackupPreviewCard: View {
    let entries: [MaintBackupEntry]
    let reduceMotion: Bool

    @State private var expanded = false
    @State private var search = ""

    private var filtered: [MaintBackupEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(needle) || $0.value.lowercased().contains(needle) }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        SectionHeader(tr("Inhalt ansehen"),
                                      subtitle: tr("%d Werte werden gespeichert", entries.count),
                                      systemImage: "doc.text.magnifyingglass")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(tr("Werte filtern"), text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filtered) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(verbatim: entry.name)
                                            .font(Theme.Typography.codeSmall)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(verbatim: entry.value.isEmpty ? "\u{201E}\u{201C}" : entry.value)
                                            .font(Theme.Typography.codeSmall)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: 320, alignment: .trailing)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    Divider().opacity(0.35)
                                }
                            }
                        }
                        .frame(height: 240)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

// MARK: - Aktionen

private struct MaintBackupActionsCard: View {
    let session: PrinterSession
    let store: MaintenanceStore
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model

    private var backup: MaintBackupController { store.backup }

    var body: some View {
        let groupCount = backup.groups.filter { backup.isIncluded($0) }.count
        let canSave = backup.includedEntryCount > 0
        let hasCloneTarget = Self.preferredTarget(for: session, in: model) != nil
        GlassCard(padding: 18, tint: Theme.violet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("%d Einstellungen aus %d Gruppen", backup.includedEntryCount, groupCount))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion),
                                       value: backup.includedEntryCount)
                        Text(tr("Dazu Treibereinstellungen, Etikettenformat „%@“ und Ausgabesprache %@.",
                                session.stock.name, session.saved.language.displayName))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        cloneDirectly()
                    } label: {
                        Label(tr("Auf anderen Drucker klonen …"), systemImage: "square.on.square")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(!canSave || store.restore.isBusy || !hasCloneTarget)
                    .help(hasCloneTarget
                          ? tr("Überträgt die gewählten Werte ohne Umweg über eine Datei auf einen anderen Drucker")
                          : tr("Zum Klonen wird ein zweiter eingerichteter Drucker mit Rückkanal (USB, Netzwerk oder Bluetooth) benötigt."))
                    Button {
                        backup.save(session: session, model: model)
                    } label: {
                        Label(tr("Sicherung speichern …"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .controlSize(.large)
                    .disabled(!canSave)
                }

                if let url = backup.savedURL, let savedAt = backup.savedAt {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ready)
                            .symbolEffect(.bounce, value: reduceMotion ? Date.distantPast : savedAt)
                        Text(tr("Gespeichert: „%@“ mit %d Werten", url.lastPathComponent, backup.savedEntryCount))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(savedAt, style: .relative)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Button {
                            MaintFiles.reveal(url)
                        } label: {
                            Label(tr("Im Finder zeigen"), systemImage: "folder")
                        }
                        .buttonStyle(.labelWerkPlain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ready.opacity(0.08)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: backup.savedAt)
    }

    /// Übernimmt die aktuelle Auswahl als Quelle in „Wiederherstellen & Klonen“ und vergleicht sofort
    /// mit dem naheliegendsten Zieldrucker.
    private func cloneDirectly() {
        let document = backup.makeDocument(session: session)
        guard !document.entries.isEmpty, !store.restore.isBusy else { return }
        guard let target = Self.preferredTarget(for: session, in: model) else {
            model.toast(tr("Kein Zieldrucker"),
                        message: tr("Zum Klonen wird ein zweiter eingerichteter Drucker mit Rückkanal (USB, Netzwerk oder Bluetooth) benötigt."),
                        style: .warning)
            return
        }
        store.restore.use(document: document, source: .printer(session.displayName), sourcePrinterID: session.id)
        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
            store.pane = .restore
        }
        Task { await store.restore.compare(target: target) }
    }

    /// Erster anderer verbundener Drucker mit Rückkanal, sonst irgendein anderer; `nil` ohne weiteren Drucker
    /// (ein Vergleich mit sich selbst wäre sinnlos).
    static func preferredTarget(for session: PrinterSession, in model: AppModel) -> PrinterSession? {
        let others = model.sessions.filter { $0.id != session.id && $0.supportsStatus }
        return others.first(where: { $0.connectionState.isConnected }) ?? others.first
    }
}

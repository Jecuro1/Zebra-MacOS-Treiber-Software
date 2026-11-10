import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// „Einstellungen & Kalibrierung“: ^HR-Kalibrierung mit Lesefenster, Programmierposition,
/// Sendeleistung, Modul/Tag-Typ, Zähler und alle RFID-SGD-Variablen mit Bearbeitung.
struct RFIDSettingsPanel: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench
    let reduceMotion: Bool

    @State private var positionDraft = ""
    @State private var readPowerDraft: Double = 0
    @State private var writePowerDraft: Double = 0
    @State private var confirmCalibration = false
    @State private var query = ""
    @State private var editingName: String?
    @State private var editingValue = ""
    @State private var editingError: String?

    init(session: PrinterSession, workbench: RFIDWorkbench, reduceMotion: Bool) {
        self.session = session
        self.workbench = workbench
        self.reduceMotion = reduceMotion
    }

    private var status: RFIDStatusValues? { workbench.status }
    private var isConnected: Bool { session.connectionState.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            calibrationCard
            HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
                positionCard
                powerCard
            }
            HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
                moduleCard
                countersCard
            }
            advancedCard
        }
        .onAppear { syncDrafts() }
        .onChange(of: workbench.status) { oldStatus, newStatus in
            syncChangedDrafts(from: oldStatus, to: newStatus)
        }
        // Erneut versuchen, sobald ein laufender Lese-, Kodier- oder Kalibrierauftrag endet.
        .task(id: workbench.isBusy) { await loadSettingsIfNeeded() }
    }

    private func loadSettingsIfNeeded() async {
        guard workbench.settingsLoadedAt == nil, !workbench.isBusy, isConnected else { return }
        await workbench.loadSettings(session: session)
    }

    /// Übernimmt alle Druckerwerte in die Entwürfe (beim Erscheinen).
    private func syncDrafts() {
        syncPositionDraft()
        syncPowerDrafts()
    }

    private func syncPositionDraft() {
        if let position = status?.programPosition { positionDraft = position }
    }

    /// Setzt nur die Leistungsregler zurück („Verwerfen“) – eine ungespeicherte Position bleibt.
    private func syncPowerDrafts() {
        if let read = status?.readPower { readPowerDraft = Double(read) }
        if let write = status?.writePower { writePowerDraft = Double(write) }
    }

    /// Nach einer Statusabfrage nur die Entwürfe überschreiben, deren Druckerwert sich tatsächlich
    /// geändert hat – sonst gingen ungespeicherte Eingaben bei jeder Aktualisierung verloren.
    private func syncChangedDrafts(from old: RFIDStatusValues?, to new: RFIDStatusValues?) {
        if new?.programPosition != old?.programPosition, let position = new?.programPosition {
            positionDraft = position
        }
        if new?.readPower != old?.readPower, let read = new?.readPower {
            readPowerDraft = Double(read)
        }
        if new?.writePower != old?.writePower, let write = new?.writePower {
            writePowerDraft = Double(write)
        }
    }

    // MARK: Kalibrierung

    private var calibrationCard: some View {
        GlassCard(tint: workbench.isCalibrating ? Theme.warning : nil) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("RFID-Kalibrierung"),
                              subtitle: tr("Ermittelt Programmierposition und Sendeleistung für das eingelegte Material (^HR)"),
                              systemImage: "scope") {
                    if let result = workbench.calibration, !workbench.isCalibrating {
                        HStack(spacing: 6) {
                            RFIDCopyButton(text: result.text, title: tr("Tabelle kopieren"))
                            Button {
                                save(result)
                            } label: {
                                Label(tr("Sichern …"), systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.labelWerkPlain)
                        }
                        .controlSize(.small)
                    }
                }

                Text(tr("RFID-Etiketten einlegen und die Kalibrierung starten. Der Drucker transportiert dabei mehrere Etiketten, liest den Tag an jeder Position, übernimmt die beste Position automatisch und sendet die Messtabelle an LabelWerk."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if workbench.isCalibrating {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressRing(progress: nil, size: 20, lineWidth: 3)
                            Text(tr("Kalibrierung läuft – bitte warten, bis der Drucker fertig ist …"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        StripedProgressBar(progress: nil, tint: Theme.warning)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 10) {
                        Button {
                            confirmCalibration = true
                        } label: {
                            Label(workbench.calibration == nil ? tr("Kalibrierung starten") : tr("Erneut kalibrieren"),
                                  systemImage: "scope")
                        }
                        .buttonStyle(.labelWerkPrimary)
                        .disabled(workbench.isBusy || !isConnected)
                        if let date = workbench.calibratedAt {
                            Text(tr("Zuletzt: %@", date.formatted(date: .omitted, time: .shortened)))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity)
                }

                if let error = workbench.calibrationError {
                    RFIDInlineMessage(text: error)
                        .transition(.opacity)
                }

                if let result = workbench.calibration {
                    RFIDCalibrationResultView(result: result, currentPosition: status?.programPosition,
                                              isBusy: workbench.isBusy || session.isBusy,
                                              reduceMotion: reduceMotion) { position in
                        positionDraft = position
                        Task { await workbench.apply(RFIDStatusValues.positionKey, value: position, session: session) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.isCalibrating)
        }
        .confirmationDialog(tr("RFID-Kalibrierung starten?"), isPresented: $confirmCalibration) {
            Button(tr("Kalibrieren")) {
                Task { await workbench.calibrate(session: session) }
            }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Der Drucker transportiert dabei mehrere Etiketten vor und zurück. Bitte RFID-Etiketten einlegen und die Kalibrierung nicht unterbrechen."))
        }
    }

    private func save(_ result: RFIDCalibrationResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = tr("RFID-Kalibrierung") + ".txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            session.app?.toast(tr("Kalibrierung gesichert"), message: url.lastPathComponent, style: .success)
        } catch {
            session.app?.toast(tr("Sichern fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }

    // MARK: Programmierposition

    private var assessment: RFIDProgramPosition.Assessment { RFIDProgramPosition.assess(positionDraft) }

    private var positionChanged: Bool {
        let draft = positionDraft.trimmingCharacters(in: .whitespaces).uppercased()
        return draft != (status?.programPosition ?? "").uppercased()
    }

    private func applyPosition() {
        guard assessment.isValid, positionChanged else { return }
        let value = positionDraft.trimmingCharacters(in: .whitespaces).uppercased()
        Task { await workbench.apply(RFIDStatusValues.positionKey, value: value, session: session) }
    }

    private var positionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Programmierposition"), subtitle: RFIDStatusValues.positionKey,
                              systemImage: "arrow.left.and.right")
                HStack(spacing: 8) {
                    TextField(tr("z. B. F0"), text: $positionDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typography.code)
                        .frame(width: 120)
                        .onSubmit { applyPosition() }
                    Button(tr("Übernehmen")) { applyPosition() }
                        .buttonStyle(.labelWerkPrimary)
                        .controlSize(.small)
                        .disabled(!assessment.isValid || !positionChanged || session.isBusy || !isConnected)
                    Spacer(minLength: 4)
                    if let current = status?.programPosition {
                        RFIDCapsule(text: tr("Aktuell: %@", current), systemImage: "mappin", tint: Theme.indigo)
                    }
                }
                RFIDInlineMessage(text: assessment.text,
                                  systemImage: assessment.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                  tint: assessment.isValid ? Theme.ready : Theme.error)
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: assessment)
                positionScale
                Text(tr("F = vorwärts ab Etikettenanfang in Millimetern, B = rückwärts (höchstens 30 mm). Manche Modelle erwarten stattdessen einen Zahlenwert. Nach einer Kalibrierung setzt der Drucker den besten Wert selbst."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Lineal von B30 bis F60 (bzw. weiter) mit Etikettenanfang und Markierung der Position.
    private var positionScale: some View {
        let offset = RFIDCalibrationResult.offset(of: positionDraft)
        let lower = -30.0
        let upper = max(60.0, Double(offset ?? 0) + 10)
        let span = upper - lower
        return VStack(spacing: 3) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let zeroX = width * CGFloat((0 - lower) / span)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.subtleFill)
                        .frame(height: 8)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.warning.opacity(0.45), Theme.warning.opacity(0.12)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: zeroX, height: 8)
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: 18)
                        .offset(x: zeroX - 0.75)
                    if let offset {
                        let x = width * CGFloat((Double(offset) - lower) / span)
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .shadow(color: Theme.violet.opacity(0.5), radius: 3)
                            .offset(x: x - 6, y: -13)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 34)
            HStack {
                Text(verbatim: "B30")
                Spacer()
                Text(tr("Etikettenanfang"))
                Spacer()
                Text(verbatim: "F\(Int(upper))")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: offset)
    }

    // MARK: Sendeleistung

    private var powerChanged: Bool {
        let readChanged = status?.readPower.map { $0 != Int(readPowerDraft) } ?? false
        let writeChanged = status?.writePower.map { $0 != Int(writePowerDraft) } ?? false
        return readChanged || writeChanged
    }

    private func applyPower() {
        let read = Int(readPowerDraft)
        let write = Int(writePowerDraft)
        let currentRead = status?.readPower
        let currentWrite = status?.writePower
        Task {
            if let currentRead, currentRead != read {
                await workbench.apply(RFIDStatusValues.readPowerKey, value: String(read), session: session)
            }
            if let currentWrite, currentWrite != write {
                await workbench.apply(RFIDStatusValues.writePowerKey, value: String(write), session: session)
            }
        }
    }

    private var powerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Sendeleistung"), subtitle: tr("0 – 30 · mehr Leistung = größere Reichweite"),
                              systemImage: "dot.radiowaves.left.and.right")
                RFIDPowerSlider(title: tr("Lesen"), value: $readPowerDraft, current: status?.readPower,
                                tint: Theme.teal, reduceMotion: reduceMotion)
                RFIDPowerSlider(title: tr("Schreiben"), value: $writePowerDraft, current: status?.writePower,
                                tint: Theme.magenta, reduceMotion: reduceMotion)
                Text(tr("Zu viel Leistung erfasst womöglich Nachbaretiketten, zu wenig führt zu VOID-Etiketten. Die Kalibrierung ermittelt passende Werte."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button(tr("Verwerfen")) { syncPowerDrafts() }
                        .buttonStyle(.labelWerkPlain)
                        .controlSize(.small)
                        .disabled(!powerChanged)
                    Button(tr("Übernehmen")) { applyPower() }
                        .buttonStyle(.labelWerkPrimary)
                        .controlSize(.small)
                        .disabled(!powerChanged || session.isBusy || !isConnected)
                }
                .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: powerChanged)
            }
        }
    }

    // MARK: Modul & Tag-Typ

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { workbench.status?.enabled ?? false },
            set: { newValue in
                Task { await workbench.setEnabled(newValue, session: session) }
            }
        )
    }

    private var moduleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Modul & Tag-Typ"), systemImage: "cpu")
                if status?.enabled != nil {
                    Toggle(isOn: enabledBinding) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tr("RFID aktiviert"))
                                .font(.system(size: 13, weight: .medium))
                            Text(tr("rfid.enable – je nach Modell erst nach einem Neustart wirksam"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(session.isBusy || !isConnected)
                }
                tagTypeRow
                KeyValueRow(tr("Kodierer-Firmware"), status?.firmware ?? "–", monospaced: true,
                            copyable: status?.firmware != nil)
                KeyValueRow(tr("Lesermodell"), status?.readerModel ?? "–")
                KeyValueRow(tr("Antennenanschluss"), status?.antenna ?? "–")
                KeyValueRow(tr("Region"), status?.region ?? "–")
            }
        }
    }

    @ViewBuilder
    private var tagTypeRow: some View {
        if let row = workbench.settingRow(named: RFIDStatusValues.tagTypeKey), row.isWritable, row.choices.count > 1 {
            Picker(selection: Binding(
                get: { row.value },
                set: { newValue in
                    guard newValue != row.value else { return }
                    Task { await workbench.apply(row.name, value: newValue, session: session) }
                }
            )) {
                ForEach(row.choices, id: \.self) { choice in
                    Text(RFIDStatusValues.tagTypeName(choice)).tag(choice)
                }
                if !row.choices.contains(row.value) {
                    Text(row.value).tag(row.value)
                }
            } label: {
                Text(tr("Tag-Typ"))
            }
            .pickerStyle(.menu)
            .disabled(session.isBusy || !isConnected)
        } else {
            KeyValueRow(tr("Tag-Typ"), status?.tagType.map { RFIDStatusValues.tagTypeName($0) } ?? "–")
            if workbench.isLoadingSettings {
                Text(tr("Auswahlwerte werden gelesen …"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Zähler

    private var countersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Zähler"), subtitle: tr("Rücksetzbare RFID-Zähler des Druckers"), systemImage: "number.circle")
                HStack(spacing: 18) {
                    counterBlock(title: tr("Gültig"), value: status?.validCount, tint: Theme.ready,
                                 symbol: "checkmark.circle.fill")
                    counterBlock(title: tr("Ungültig (VOID)"), value: status?.voidCount, tint: Theme.error,
                                 symbol: "xmark.circle.fill")
                    Spacer(minLength: 0)
                }
                Text(tr("„Ungültig“ zählt Etiketten, die der Drucker mit VOID markiert hat."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HoldToConfirmButton(title: tr("Zähler zurücksetzen"), systemImage: "arrow.counterclockwise",
                                    tint: Theme.warning) {
                    Task { await workbench.resetCounters(session: session) }
                }
                .disabled((status?.validCount == nil && status?.voidCount == nil) || !isConnected)
            }
        }
    }

    private func counterBlock(title: String, value: Int?, tint: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : (value ?? 0))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value.map { $0.formatted() } ?? "–")
                .font(Theme.Typography.metric)
                .contentTransition(.numericText())
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: value)
        }
    }

    // MARK: Alle RFID-Einstellungen

    private var filteredRows: [RFIDSettingRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return workbench.settingRows }
        return workbench.settingRows.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle)
        }
    }

    private var advancedSubtitle: String {
        if workbench.settingRows.isEmpty {
            return tr("Sämtliche rfid.*-Variablen des Druckers mit Bearbeitung")
        }
        return tr("%d Variablen · Doppelklick oder Stift zum Bearbeiten", workbench.settingRows.count)
    }

    private var advancedCard: some View {
        let rows = filteredRows
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Alle RFID-Einstellungen"), subtitle: advancedSubtitle, systemImage: "tablecells") {
                    HStack(spacing: 8) {
                        TextField(tr("Filtern"), text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Button {
                            Task { await workbench.loadSettings(session: session) }
                        } label: {
                            if workbench.isLoadingSettings {
                                ProgressRing(progress: nil, size: 14, lineWidth: 2)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.labelWerkPlain)
                        .disabled(workbench.isLoadingSettings || workbench.isBusy || !isConnected)
                        .help(tr("Neu lesen"))
                    }
                }

                if let editingError {
                    RFIDInlineMessage(text: editingError)
                        .transition(.opacity)
                }

                if let settingsError = workbench.settingsError {
                    RFIDInlineMessage(text: tr("Die Einstellungen konnten nicht gelesen werden (%@).", settingsError))
                        .transition(.opacity)
                }

                if workbench.isLoadingSettings && workbench.settingRows.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.subtleFill)
                                .frame(height: 24)
                        }
                    }
                    .shimmering(active: !reduceMotion)
                } else if workbench.settingRows.isEmpty {
                    // Nach einem Lesefehler genügt die Fehlermeldung oben.
                    if workbench.settingsError == nil {
                        Text(workbench.settingsLoadedAt == nil
                             ? tr("Noch nicht gelesen.")
                             : tr("Der Drucker hat keine RFID-Variablen geliefert. Ältere Modelle ohne Link-OS unterstützen die Abfrage aller Einstellungen eventuell nicht."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                } else if rows.isEmpty {
                    Text(tr("Keine Variable passt zum Filter."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            RFIDSettingRowView(
                                row: row,
                                isFlashed: workbench.flashedSetting == row.name,
                                isEditing: editingName == row.name,
                                editingValue: $editingValue,
                                isBusy: session.isBusy || !isConnected,
                                onEdit: { beginEditing(row) },
                                onCancel: { cancelEditing() },
                                onCommit: { commitEditing(row) }
                            )
                            .rfidAppear(index: index, reduceMotion: reduceMotion)
                        }
                    }
                }
            }
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: editingName)
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: workbench.settingsError)
        }
    }

    private func beginEditing(_ row: RFIDSettingRow) {
        editingError = nil
        editingValue = row.value
        editingName = row.name
    }

    private func cancelEditing() {
        editingName = nil
        editingError = nil
    }

    private func commitEditing(_ row: RFIDSettingRow) {
        let value = editingValue.trimmingCharacters(in: .whitespaces)
        if let message = row.validate(value) {
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                editingError = tr("%@: %@", row.name, message)
            }
            return
        }
        editingName = nil
        editingError = nil
        guard value != row.value else { return }
        Task { await workbench.apply(row.name, value: value, session: session) }
    }
}

// MARK: - Kalibrierergebnis

private struct RFIDCalibrationResultView: View {
    let result: RFIDCalibrationResult
    let currentPosition: String?
    let isBusy: Bool
    let reduceMotion: Bool
    let onApplyPosition: (String) -> Void

    init(result: RFIDCalibrationResult, currentPosition: String?, isBusy: Bool, reduceMotion: Bool,
         onApplyPosition: @escaping (String) -> Void) {
        self.result = result
        self.currentPosition = currentPosition
        self.isBusy = isBusy
        self.reduceMotion = reduceMotion
        self.onApplyPosition = onApplyPosition
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !result.samples.isEmpty {
                windowChart
            }
            if !result.isComplete {
                RFIDInlineMessage(text: tr("Die Tabelle ist möglicherweise unvollständig – der Drucker hat kein „end“ gesendet."),
                                  systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
            }
            table
        }
    }

    private func color(for sample: RFIDCalibrationSample) -> Color {
        guard sample.isHit else { return Theme.offline.opacity(0.35) }
        if let recommended = result.recommendedPosition,
           RFIDCalibrationResult.positionText(offset: sample.offset) == recommended {
            return Theme.violet
        }
        if let window = result.window, window.contains(sample.offset) { return Theme.teal }
        return Theme.teal.opacity(0.45)
    }

    private var windowChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tr("Lesefenster"))
                    .font(.system(size: 13, weight: .semibold))
                if let window = result.window {
                    Text(tr("%@ bis %@", RFIDCalibrationResult.positionText(offset: window.lowerBound),
                            RFIDCalibrationResult.positionText(offset: window.upperBound)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(tr("Keine Position mit Tag-Antwort"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.error)
                }
                Spacer()
                if let recommended = result.recommendedPosition {
                    RFIDCapsule(text: tr("Mitte: %@", recommended), systemImage: "scope", tint: Theme.violet)
                    Button(tr("Als Position übernehmen")) { onApplyPosition(recommended) }
                        .buttonStyle(.labelWerkSecondary)
                        .controlSize(.small)
                        .disabled(isBusy || recommended == currentPosition?.uppercased())
                }
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(result.samples.enumerated()), id: \.element.id) { index, sample in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: sample))
                        .frame(maxWidth: .infinity)
                        .frame(height: sample.isHit ? 34 : 12)
                        .help(sample.position + (sample.tagData.map { " · " + $0 } ?? ""))
                        .rfidAppear(index: index, reduceMotion: reduceMotion)
                }
            }
            .frame(height: 36, alignment: .bottom)
            HStack {
                Text(verbatim: result.samples.first?.position ?? "")
                Spacer()
                HStack(spacing: 12) {
                    legend(color: Theme.teal, text: tr("Tag gelesen"))
                    legend(color: Theme.violet, text: tr("Empfehlung"))
                    legend(color: Theme.offline.opacity(0.5), text: tr("Keine Antwort"))
                }
                Spacer()
                Text(verbatim: result.samples.last?.position ?? "")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
        }
    }

    private func lineColor(_ line: String) -> Color {
        let first = line.split(separator: ",").first.map { String($0) } ?? ""
        if let offset = RFIDCalibrationResult.offset(of: first) {
            let hit = result.samples.first { $0.offset == offset }?.isHit ?? false
            return hit ? Theme.teal : Color.secondary
        }
        let lower = line.lowercased()
        if lower == "start" || lower == "end" { return Theme.accent }
        return Color.primary
    }

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 10) {
                        Text(verbatim: String(index + 1))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)
                        Text(verbatim: line)
                            .foregroundStyle(lineColor(line))
                            .fixedSize()
                    }
                    .font(Theme.Typography.codeSmall)
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index % 2 == 0 ? Color.clear : Theme.subtleFill)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 240)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Sendeleistung

private struct RFIDPowerSlider: View {
    let title: String
    @Binding var value: Double
    let current: Int?
    let tint: Color
    let reduceMotion: Bool

    init(title: String, value: Binding<Double>, current: Int?, tint: Color, reduceMotion: Bool) {
        self.title = title
        self._value = value
        self.current = current
        self.tint = tint
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let current {
                    if current != Int(value) {
                        Text(tr("Drucker: %d", current))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                } else {
                    Text(tr("Nicht gemeldet"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(Int(value), format: .number)
                    .font(Theme.Typography.metricSmall)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: value))
                    .frame(minWidth: 30, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Slider(value: $value, in: 0...30, step: 1)
                    .tint(tint)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<5, id: \.self) { bar in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Double(bar) < value / 6 ? tint : Theme.subtleFill)
                            .frame(width: 4, height: CGFloat(5 + bar * 3))
                    }
                }
                .frame(height: 18, alignment: .bottom)
            }
        }
        .disabled(current == nil)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: Int(value))
    }
}

// MARK: - Tabellenzeile

private struct RFIDSettingRowView: View {
    let row: RFIDSettingRow
    let isFlashed: Bool
    let isEditing: Bool
    @Binding var editingValue: String
    let isBusy: Bool
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var hovering = false

    init(row: RFIDSettingRow, isFlashed: Bool, isEditing: Bool, editingValue: Binding<String>, isBusy: Bool,
         onEdit: @escaping () -> Void, onCancel: @escaping () -> Void, onCommit: @escaping () -> Void) {
        self.row = row
        self.isFlashed = isFlashed
        self.isEditing = isEditing
        self._editingValue = editingValue
        self.isBusy = isBusy
        self.onEdit = onEdit
        self.onCancel = onCancel
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.isWritable ? "pencil.circle" : "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.isWritable ? Theme.accent : Color.secondary)
                .frame(width: 14)
            Text(verbatim: row.name)
                .font(Theme.Typography.codeSmall)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 300, alignment: .leading)
                .help(row.name)
            if isEditing {
                editor
                Button(action: onCommit) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ready)
                }
                .buttonStyle(.labelWerkPlain)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
                .help(tr("Wert setzen"))
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.labelWerkPlain)
                .keyboardShortcut(.cancelAction)
                .help(tr("Abbrechen"))
            } else {
                Text(verbatim: row.value.isEmpty ? "–" : row.value)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                if let range = row.range, !range.isEmpty {
                    Text(verbatim: range)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .trailing)
                        .help(range)
                }
                if row.isWritable {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .opacity(hovering ? 1 : 0.3)
                    .disabled(isBusy)
                    .help(tr("Bearbeiten"))
                }
                RFIDCopyButton(text: row.value)
                    .opacity(hovering ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFlashed ? Theme.ready.opacity(0.18) : (hovering || isEditing ? Theme.subtleFill : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if row.isWritable && !isEditing && !isBusy { onEdit() }
        }
        .animation(Motion.animation(.easeOut(duration: 0.25), reduceMotion: systemReduceMotion || appReduceMotion),
                   value: isFlashed)
    }

    @ViewBuilder
    private var editor: some View {
        if !row.choices.isEmpty {
            Picker(selection: $editingValue) {
                ForEach(row.choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
                if !row.choices.contains(editingValue) {
                    Text(editingValue).tag(editingValue)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(tr("Wert"), text: $editingValue)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.codeSmall)
                .frame(maxWidth: .infinity)
                .onSubmit(onCommit)
        }
    }
}

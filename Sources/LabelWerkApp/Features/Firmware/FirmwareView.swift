import AppKit
import SwiftUI
import LabelWerkKit

/// Firmware-Update: aktuelle Version, Datei prüfen (Version, Modell, SHA-256), Sicherheits-Checkliste,
/// Übertragung mit Rate & Restzeit, Neustart-Countdown und automatische Wiederverbindung.
/// Ersetzt „Send Firmware“ der Zebra Setup Utilities.
@MainActor
struct FirmwareView: View {
    let session: PrinterSession
    let controller: FirmwareUpdateController

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(session: PrinterSession) {
        self.session = session
        self.controller = FirmwareUpdateController.shared(for: session)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                if controller.isBusy {
                    FirmwareBusyBanner(reduceMotion: reduceMotion)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                FirmwareCurrentCard(session: session, controller: controller, reduceMotion: reduceMotion)
                stage
                FirmwareHistoryCard(session: session)
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Motion.spring, value: controller.phase)
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch controller.phase {
        case .idle, .analyzing, .ready, .transferFailed:
            FirmwareFileCard(session: session, controller: controller, reduceMotion: reduceMotion)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            if let file = controller.file, !controller.isAnalyzing {
                FirmwareSafetyCard(session: session, controller: controller, file: file, reduceMotion: reduceMotion)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        case .transferring:
            FirmwareTransferCard(session: session, controller: controller, reduceMotion: reduceMotion)
                .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity),
                                        removal: .opacity))
        case .rebooting, .reconnecting, .completed, .reconnectFailed:
            FirmwarePostUpdateCard(session: session, controller: controller, reduceMotion: reduceMotion)
                .transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity))
        }
    }
}

// MARK: - Hinweisband

private struct FirmwareBusyBanner: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Firmware-Update läuft – Drucker nicht ausschalten"))
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                Text(tr("Verbindung nicht trennen und LabelWerk nicht beenden. Andere Bereiche kannst du öffnen – das Update läuft weiter. Der Mac bleibt so lange wach."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                .fill(LinearGradient(colors: [Theme.warning, Theme.error.opacity(0.88)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .shadow(color: Theme.warning.opacity(0.35), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Installierte Firmware

private struct FirmwareCurrentCard: View {
    let session: PrinterSession
    let controller: FirmwareUpdateController
    let reduceMotion: Bool

    @State private var refreshing = false

    private static let zebraSupport = URL(string: "https://www.zebra.com/us/en/support-downloads.html")

    var body: some View {
        let identity = session.identity
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.violet) {
            HStack(alignment: .center, spacing: 20) {
                FirmwareChipIllustration(active: controller.isBusy, reduceMotion: reduceMotion)
                    .frame(width: 100, height: 100)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Installierte Firmware"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: identity?.firmware ?? "–")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : Motion.spring, value: identity?.firmware)
                    HStack(spacing: 6) {
                        TransferChip(session.model?.displayName ?? identity?.model ?? tr("Unbekanntes Modell"),
                                     systemImage: "printer", tint: Theme.violet)
                        if let serial = identity?.serialNumber, !serial.isEmpty {
                            TransferChip(tr("SN %@", serial), systemImage: "number", tint: Theme.teal)
                        }
                        if identity?.isLinkOS == true || session.model?.supports(.linkOS) == true {
                            TransferChip(tr("Link-OS"), systemImage: "checkmark.seal.fill", tint: Theme.ready)
                        }
                    }
                    if identity?.firmware == nil {
                        Text(session.supportsStatus
                             ? tr("Die Version wird beim Verbinden gelesen.")
                             : tr("Über diese Verbindung kann die Version nicht gelesen werden (nur Senden)."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 10) {
                    Button {
                        Task {
                            refreshing = true
                            await session.refresh()
                            refreshing = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if refreshing {
                                ProgressRing(progress: nil, size: 13, lineWidth: 2)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(tr("Neu lesen"))
                        }
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .disabled(refreshing || controller.isBusy || !session.supportsStatus)
                    if let url = Self.zebraSupport {
                        Link(destination: url) {
                            Label(tr("Firmware bei Zebra laden"), systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                        }
                        .help(tr("Öffnet die Download-Seite von Zebra im Browser"))
                    }
                }
            }
        }
    }
}

// MARK: - Datei

private struct FirmwareFileCard: View {
    let session: PrinterSession
    @Bindable var controller: FirmwareUpdateController
    let reduceMotion: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(tr("Firmware-Datei"),
                              subtitle: tr("Datei von zebra.com wählen – LabelWerk prüft sie vor der Übertragung"),
                              systemImage: "doc.badge.gearshape") {
                    if controller.file != nil && controller.canChooseFile {
                        Button {
                            pick()
                        } label: {
                            Label(tr("Andere Datei …"), systemImage: "folder")
                        }
                        .buttonStyle(.labelWerkPlain)
                    }
                }

                if let error = controller.analysisError {
                    TransferNote(error, style: .error)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if case .transferFailed(let message) = controller.phase {
                    failureBanner(message)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if case .analyzing(let name) = controller.phase {
                    analyzingView(name)
                        .transition(.opacity)
                } else if let file = controller.file {
                    FirmwareFileDetails(session: session, controller: controller, file: file, reduceMotion: reduceMotion) {
                        controller.clearFile(reduceMotion: reduceMotion)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    TransferDropZone(
                        title: tr("Firmware-Datei hierher ziehen"),
                        message: tr("Zebra-Firmware (.zpl, .nrd, .hex) – Version, Modell und SHA-256-Prüfsumme werden automatisch geprüft."),
                        systemImage: "cpu",
                        tint: Theme.violet,
                        isEnabled: controller.canChooseFile,
                        onDrop: { urls in
                            guard let url = urls.first else { return false }
                            controller.load(url: url, reduceMotion: reduceMotion)
                            return true
                        }
                    ) {
                        Button {
                            pick()
                        } label: {
                            Label(tr("Datei wählen …"), systemImage: "folder")
                        }
                        .buttonStyle(.labelWerkPrimary)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: controller.file)
        .animation(reduceMotion ? nil : Motion.snappy, value: controller.analysisError)
    }

    private func pick() {
        guard let url = TransferOpenPanel.pickFile(
            title: tr("Firmware-Datei wählen"),
            message: tr("Firmware für %@ (.zpl, .nrd, .hex)", session.model?.displayName ?? session.displayName),
            prompt: tr("Prüfen"),
            types: nil
        ) else { return }
        controller.load(url: url, reduceMotion: reduceMotion)
    }

    private func analyzingView(_ name: String) -> some View {
        HStack(spacing: 14) {
            ProgressRing(progress: nil, size: 34, lineWidth: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Datei wird geprüft …"))
                    .font(Theme.Typography.headline)
                Text(verbatim: name)
                    .font(Theme.Typography.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(tr("SHA-256 berechnen, Version und Modell suchen"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                .fill(Theme.subtleFill)
        }
        .shimmering(active: true)
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: "xmark.octagon.fill", tint: Theme.error, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Übertragung fehlgeschlagen"))
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("Der Drucker hat die unvollständige Datei verworfen und arbeitet mit der bisherigen Firmware weiter. Verbindung prüfen und erneut übertragen."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(tr("Verstanden")) {
                controller.acknowledgeFailure(reduceMotion: reduceMotion)
            }
            .buttonStyle(.labelWerkSecondary)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.error.opacity(0.08))
        }
    }
}

private struct FirmwareFileDetails: View {
    let session: PrinterSession
    @Bindable var controller: FirmwareUpdateController
    let file: FirmwareFileInfo
    let reduceMotion: Bool
    let onRemove: () -> Void

    private var assessment: [FirmwareAssessmentItem] {
        FirmwareCompatibility.assess(file: file, installedFirmware: session.identity?.firmware,
                                     printerModelNames: [session.model?.name, session.identity?.model,
                                                         session.saved.name].compactMap { $0 },
                                     expectedChecksum: controller.expectedChecksum)
    }

    var body: some View {
        let items = assessment
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(systemImage: file.kind.systemImage, tint: file.kind == .other ? Theme.offline : Theme.violet, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: file.fileName)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(file.kind.title)
                        Text(verbatim: "·")
                        Text(TransferFormat.bytes(file.size))
                        if let modified = file.modified {
                            Text(verbatim: "·")
                            Text(modified, style: .date)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!controller.canChooseFile)
                .help(tr("Datei entfernen"))
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    facts
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity)
                    checks(items)
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    facts
                    checks(items)
                }
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                KeyValueRow(tr("Version in der Datei"), file.versionHint ?? "–", monospaced: true)
                if let source = file.versionSource {
                    KeyValueRow(tr("Gefunden in"), source)
                }
                KeyValueRow(tr("Installiert"), session.identity?.firmware ?? "–", monospaced: true)
                if !file.modelHints.isEmpty {
                    KeyValueRow(tr("Modelle in der Datei"), file.modelHints.joined(separator: ", "))
                }
                KeyValueRow("SHA-256", file.sha256, monospaced: true, copyable: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Erwartete Prüfsumme (optional)"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                    TextField(tr("SHA-256 von der Download-Seite einfügen"), text: $controller.expectedChecksum)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.codeSmall)
                    checksumBadge
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.subtleFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(checksumBorder, lineWidth: 1)
                }
            }
        }
    }

    private var checksumState: Bool? {
        let expected = FirmwareAnalyzer.normalizedChecksum(controller.expectedChecksum)
        guard expected.count == 64 else { return nil }
        return expected == file.sha256
    }

    private var checksumBorder: Color {
        switch checksumState {
        case .some(true): return Theme.ready
        case .some(false): return Theme.error
        case .none: return Theme.cardStroke
        }
    }

    @ViewBuilder
    private var checksumBadge: some View {
        switch checksumState {
        case .some(true):
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.ready)
                .symbolEffect(.bounce, value: checksumState)
                .transition(.scale.combined(with: .opacity))
        case .some(false):
            Image(systemName: "xmark.seal.fill")
                .foregroundStyle(Theme.error)
                .symbolEffect(.bounce, value: checksumState)
                .transition(.scale.combined(with: .opacity))
        case .none:
            EmptyView()
        }
    }

    private func checks(_ items: [FirmwareAssessmentItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Prüfergebnis"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.tint)
                    Text(item.text)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(item.tint.opacity(0.08))
                }
                .transferAppear(index: index, reduceMotion: reduceMotion)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: items)
    }
}

// MARK: - Sicherheit & Start

private struct FirmwareSafetyCard: View {
    let session: PrinterSession
    let controller: FirmwareUpdateController
    let file: FirmwareFileInfo
    let reduceMotion: Bool

    private var blocking: Bool {
        FirmwareCompatibility.assess(file: file, installedFirmware: session.identity?.firmware,
                                     printerModelNames: [],
                                     expectedChecksum: controller.expectedChecksum)
            .contains { $0.level == .blocking }
    }

    private var isConnected: Bool { session.connectionState.isConnected }

    private var canStart: Bool {
        isConnected && controller.checklistComplete && !blocking && !session.isBusy
    }

    private var hint: (text: String, style: TransferNote.Style) {
        if !isConnected { return (tr("Der Drucker ist nicht verbunden."), .error) }
        if blocking { return (tr("Die Prüfsumme stimmt nicht – Übertragung gesperrt."), .error) }
        if session.isBusy { return (tr("Der Drucker ist gerade beschäftigt."), .warning) }
        if !controller.checklistComplete {
            return (tr("%d von %d Punkten bestätigt.", controller.checklist.count, FirmwareChecklistItem.allCases.count), .info)
        }
        return (tr("Bereit – Schaltfläche gedrückt halten, um zu starten."), .success)
    }

    var body: some View {
        GlassCard(padding: 18, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.warning) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    IconBadge(systemImage: "bolt.trianglebadge.exclamationmark", tint: Theme.warning, size: 46)
                        .symbolEffect(.pulse, options: .repeating, isActive: !controller.checklistComplete && !reduceMotion)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Wichtig: Strom und Verbindung dürfen nicht unterbrochen werden"))
                            .font(Theme.Typography.headline)
                        Text(tr("Die Übertragung dauert je nach Verbindung einige Minuten. Danach installiert der Drucker die Firmware selbst und startet neu. Den Drucker in dieser Zeit nicht ausschalten, kein Kabel ziehen und den Mac nicht zuklappen – LabelWerk hält den Mac währenddessen wach."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(Array(FirmwareChecklistItem.allCases.enumerated()), id: \.element) { index, item in
                        checklistRow(item)
                            .transferAppear(index: index, reduceMotion: reduceMotion)
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    TransferNote(hint.text, style: hint.style)
                        .contentTransition(.opacity)
                    Spacer(minLength: 8)
                    if !isConnected {
                        Button {
                            Task { await session.connect() }
                        } label: {
                            Label(tr("Verbinden"), systemImage: "bolt.fill")
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .disabled(session.connectionState == .connecting)
                    }
                    HoldToConfirmButton(title: tr("Firmware installieren"), systemImage: "cpu",
                                        tint: Theme.warning, duration: 2.0) {
                        guard canStart else { return }
                        controller.start(session: session, reduceMotion: reduceMotion)
                    }
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.45)
                    .saturation(canStart ? 1 : 0.3)
                    .animation(reduceMotion ? nil : Motion.snappy, value: canStart)
                }
            }
        }
    }

    private func checklistRow(_ item: FirmwareChecklistItem) -> some View {
        let checked = controller.checklist.contains(item)
        return Button {
            withAnimation(reduceMotion ? nil : Motion.bouncy) { controller.toggle(item) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(checked ? Theme.ready : Color.clear)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(checked ? Theme.ready : Theme.separator, lineWidth: 1.5)
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                Image(systemName: item.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(checked ? Theme.ready : Color.secondary)
                    .frame(width: 22)
                    .symbolEffect(.bounce, value: checked)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Text(item.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(checked ? Theme.ready.opacity(0.09) : Theme.subtleFill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityHint(tr("Zum Bestätigen klicken"))
    }
}

// MARK: - Verlauf

private struct FirmwareHistoryCard: View {
    let session: PrinterSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = Array(model.history.filter { $0.printerID == session.id && $0.kind == .firmware }.prefix(5))
        if !jobs.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(tr("Frühere Firmware-Übertragungen"), systemImage: "clock.arrow.circlepath") {
                        Button(tr("Verlauf")) { model.selection = .history }
                            .buttonStyle(.labelWerkPlain)
                    }
                    ForEach(jobs) { job in
                        HStack(spacing: 10) {
                            Image(systemName: job.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(job.success ? Theme.ready : Theme.error)
                            Text(verbatim: job.title)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(TransferFormat.bytes(job.bytes))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(job.date, style: .relative)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .frame(width: 100, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                        .help(job.message ?? "")
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

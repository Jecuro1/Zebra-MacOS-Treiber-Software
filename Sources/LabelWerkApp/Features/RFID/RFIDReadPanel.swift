import SwiftUI
import LabelWerkKit

/// „Tag lesen“: Speicherbank wählen, über ^RFR/^HV lesen, Ergebnis dekodieren, Verlauf.
struct RFIDReadPanel: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench
    let reduceMotion: Bool

    init(session: PrinterSession, workbench: RFIDWorkbench, reduceMotion: Bool) {
        self.session = session
        self.workbench = workbench
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
                controls
                    .frame(minWidth: 320, idealWidth: 370, maxWidth: 390)
                result
                    .frame(maxWidth: .infinity)
            }
            history
        }
    }

    // MARK: Steuerung

    private var lengthBinding: Binding<Int> {
        Binding(
            get: { workbench.readLength(for: workbench.readBank) },
            set: { workbench.setReadLength($0, for: workbench.readBank) }
        )
    }

    private var controls: some View {
        let bank = workbench.readBank
        let length = workbench.readLength(for: bank)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Tag lesen"), subtitle: tr("Liest den Tag über der Antenne"), systemImage: "wave.3.right")

                RFIDBankPicker(selection: $workbench.readBank, banks: RFIDMemoryBank.readable, reduceMotion: reduceMotion)

                Text(bank.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: bank)

                Picker(selection: lengthBinding) {
                    ForEach(bank.lengthOptions, id: \.self) { bytes in
                        Text(tr("%d Bit · %d Bytes", bytes * 8, bytes)).tag(bytes)
                    }
                } label: {
                    Text(tr("Länge"))
                }
                .pickerStyle(.menu)

                RFIDCommandStrip(
                    command: RFIDCommand.rf(operation: "R", startWord: bank.startWord, byteCount: length, bank: bank),
                    parameters: RFIDCommand.parameters(operation: "R", startWord: bank.startWord, byteCount: length, bank: bank)
                )
                .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: length)

                Label {
                    Text(tr("Zum Lesen transportiert der Drucker ein Etikett zur Programmierposition und gibt es danach aus. Die Antwort kommt per ^HV zurück."))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.accent)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

                Button {
                    Task { await workbench.read(session: session) }
                } label: {
                    HStack(spacing: 8) {
                        if workbench.isReading {
                            ProgressRing(progress: nil, size: 14, lineWidth: 2)
                        } else {
                            Image(systemName: "wave.3.right")
                                .symbolEffect(.bounce, value: reduceMotion ? 0 : workbench.successPulse)
                        }
                        Text(workbench.isReading ? tr("Lese …") : tr("Tag lesen"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.large)
                .disabled(workbench.isBusy || !session.connectionState.isConnected)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(tr("Tag lesen (⌘↩)"))
            }
        }
    }

    // MARK: Ergebnis

    private var resultTint: Color? {
        if workbench.readError != nil { return Theme.error }
        if workbench.lastRead != nil { return Theme.teal }
        return nil
    }

    private var result: some View {
        GlassCard(tint: resultTint) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Ergebnis"), subtitle: resultSubtitle, systemImage: "doc.text.magnifyingglass") {
                    if let record = workbench.lastRead, workbench.readError == nil, !workbench.isReading {
                        RFIDCopyButton(text: record.hex, title: tr("Kopieren"))
                    }
                }
                ZStack(alignment: .topLeading) {
                    if workbench.isReading {
                        readingPlaceholder
                            .transition(.opacity)
                    } else if let error = workbench.readError {
                        errorView(error)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else if let record = workbench.lastRead {
                        RFIDReadResultView(session: session, workbench: workbench, record: record, reduceMotion: reduceMotion)
                            .id(record.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                                    removal: .opacity))
                    } else {
                        emptyPlaceholder
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.isReading)
                .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.lastRead?.id)

                if let raw = workbench.lastRawResponse, !workbench.isReading {
                    RFIDRawResponseView(text: raw)
                }
            }
        }
    }

    private var resultSubtitle: String {
        if let record = workbench.lastRead, workbench.readError == nil {
            return tr("%@ · %d Bit · %@", record.bank.title, record.bits,
                      record.date.formatted(date: .omitted, time: .standard))
        }
        return tr("Daten des zuletzt gelesenen Tags")
    }

    private var readingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressRing(progress: nil, size: 20, lineWidth: 3)
                Text(tr("Antenne sendet – warte auf die Antwort des Tags …"))
                    .font(.system(size: 13, weight: .medium))
            }
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.subtleFill)
                        .frame(height: 30)
                }
            }
            .shimmering(active: !reduceMotion)
        }
        .padding(.vertical, 4)
    }

    private var emptyPlaceholder: some View {
        let animated = !reduceMotion
        return HStack(spacing: 14) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.brandGradient)
                .phaseAnimator([false, true], trigger: workbench.readBank) { content, raised in
                    content
                        .scaleEffect(raised && animated ? 1.12 : 1)
                        .rotationEffect(.degrees(raised && animated ? -6 : 0))
                } animation: { _ in
                    .spring(response: 0.35, dampingFraction: 0.6)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Noch nichts gelesen"))
                    .font(.system(size: 13.5, weight: .semibold))
                Text(tr("RFID-Etiketten einlegen, Speicherbank wählen und „Tag lesen“ klicken. EPC-Daten werden automatisch dekodiert (z. B. SGTIN-96 → GTIN und Seriennummer), die TID verrät den Chiphersteller."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: "exclamationmark.triangle.fill", tint: Theme.error, size: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Lesen fehlgeschlagen"))
                    .font(.system(size: 13.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        Task { await workbench.read(session: session) }
                    } label: {
                        Label(tr("Erneut lesen"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    .disabled(workbench.isBusy)

                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            workbench.tab = .settings
                        }
                    } label: {
                        Label(tr("Kalibrieren …"), systemImage: "scope")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Verlauf

    private func historySubtitle(shown: Int) -> String {
        let total = max(workbench.readTotal, shown)
        if total == 0 { return tr("Gelesene Tags dieser Sitzung") }
        if total > shown {
            return tr("%d Lesevorgänge in dieser Sitzung · die letzten %d werden angezeigt", total, shown)
        }
        return tr("%d Lesevorgänge in dieser Sitzung", total)
    }

    private var history: some View {
        let records = workbench.readHistory
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Leseverlauf"), subtitle: historySubtitle(shown: records.count),
                              systemImage: "clock.arrow.circlepath") {
                    HStack(spacing: 6) {
                        RFIDCopyButton(text: historyText(records), title: tr("Alle kopieren"))
                        Button {
                            workbench.clearReadHistory()
                        } label: {
                            Label(tr("Leeren"), systemImage: "trash")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .disabled(records.isEmpty)
                    }
                    .controlSize(.small)
                }
                if records.isEmpty {
                    Text(tr("Noch keine Tags gelesen. Jeder Lesevorgang erscheint hier mit Zeit, Speicherbank und Daten."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(records) { record in
                            RFIDHistoryRow(record: record, isLatest: record.id == records.first?.id,
                                           useAsTemplate: { workbench.useAsWriteTemplate(record) })
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                                    removal: .opacity
                                ))
                        }
                    }
                    .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: records.map(\.id))
                }
            }
        }
    }

    private func historyText(_ records: [RFIDReadRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        return records.map { record in
            [formatter.string(from: record.date), record.bank.title, record.hex].joined(separator: ";")
        }
        .joined(separator: "\n")
    }
}

// MARK: - Ergebnisdarstellung

private struct RFIDReadResultView: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench
    let record: RFIDReadRecord
    let reduceMotion: Bool

    @State private var flash = false

    init(session: PrinterSession, workbench: RFIDWorkbench, record: RFIDReadRecord, reduceMotion: Bool) {
        self.session = session
        self.workbench = workbench
        self.record = record
        self.reduceMotion = reduceMotion
    }

    /// Vom Tag gemeldete EPC-Länge, falls sie von der gelesenen abweicht.
    private var reportedMismatch: Int? {
        guard record.bank == .epc, let bits = record.reportedEPCBits, bits > 0, bits != record.bits else { return nil }
        return bits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(systemImage: record.bank.systemImage, tint: Theme.teal, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.bank.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(tr("%d Bit · %d Bytes", record.bits, record.hex.count / 2))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let pc = record.pcWord {
                    RFIDCapsule(text: tr("PC %@", pc), systemImage: "ruler", tint: Theme.indigo)
                        .help(tr("Protocol-Control-Wort: enthält die EPC-Länge des Tags."))
                }
            }

            RFIDHexGroups(hex: record.hex, fontSize: 20, tint: Theme.teal, reduceMotion: reduceMotion)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.teal.opacity(flash ? 0.18 : 0.04))
                }

            if let bits = reportedMismatch {
                HStack(spacing: 8) {
                    RFIDInlineMessage(text: tr("Der Tag meldet %d Bit EPC – gelesen wurden %d Bit.", bits, record.bits),
                                      systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                    Spacer(minLength: 4)
                    if RFIDMemoryBank.epc.lengthOptions.contains(bits / 8) {
                        Button(tr("Mit %d Bit lesen", bits)) {
                            Task { await workbench.rereadEPC(byteCount: bits / 8, session: session) }
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .controlSize(.small)
                        .disabled(workbench.isBusy)
                    }
                }
            }

            if let decoded = record.decoded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.brandGradient)
                        Text(decoded.title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    ForEach(Array(decoded.items.enumerated()), id: \.element.id) { index, item in
                        KeyValueRow(item.label, item.value, monospaced: true, copyable: true)
                            .rfidAppear(index: index, reduceMotion: reduceMotion)
                    }
                }
                .padding(10)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if record.bank == .epc {
                HStack(spacing: 8) {
                    Button {
                        workbench.useAsWriteTemplate(record)
                    } label: {
                        Label(tr("Als Schreibvorlage übernehmen"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    RFIDCopyButton(text: RFIDHex.grouped(record.hex), title: tr("Gruppiert kopieren"))
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            flash = true
            withAnimation(.easeOut(duration: 1.1).delay(0.15)) { flash = false }
        }
    }
}

private struct RFIDHistoryRow: View {
    let record: RFIDReadRecord
    let isLatest: Bool
    let useAsTemplate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var hovering = false

    init(record: RFIDReadRecord, isLatest: Bool, useAsTemplate: @escaping () -> Void) {
        self.record = record
        self.isLatest = isLatest
        self.useAsTemplate = useAsTemplate
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.bank.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isLatest ? Theme.teal : Color.secondary)
                .frame(width: 20)
            Text(record.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(record.bank.title)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)
            Text(verbatim: RFIDHex.grouped(record.hex))
                .font(Theme.Typography.codeSmall)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let decoded = record.decoded {
                Text(decoded.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.subtleFill, in: Capsule())
            }
            if record.bank == .epc {
                Button(action: useAsTemplate) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.labelWerkPlain)
                .opacity(hovering ? 1 : 0.35)
                .help(tr("Als Schreibvorlage übernehmen"))
            }
            RFIDCopyButton(text: record.hex)
                .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isLatest ? Theme.teal.opacity(0.09) : (hovering ? Theme.subtleFill : Color.clear))
        }
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.15), reduceMotion: systemReduceMotion || appReduceMotion),
                   value: hovering)
    }
}

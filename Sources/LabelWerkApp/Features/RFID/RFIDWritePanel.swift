import SwiftUI
import LabelWerkKit

/// Schlüssel der Etikettenvorschau (neu rendern, sobald sich etwas davon ändert).
private struct RFIDPreviewKey: Hashable {
    let epc: String
    let print: RFIDPrintOptions
    let geometry: RFIDLabelGeometry
}

/// „Tag schreiben“: EPC eingeben bzw. erzeugen, Serien hochzählen, Etikett bedrucken,
/// kodieren mit Fortschritt und optionaler Prüfung (Read-back).
struct RFIDWritePanel: View {
    let session: PrinterSession
    @Bindable var workbench: RFIDWorkbench
    let reduceMotion: Bool

    @State private var showsSGTIN = false
    @State private var previewLabel: RenderedLabel?
    @State private var showsZPL = false

    init(session: PrinterSession, workbench: RFIDWorkbench, reduceMotion: Bool) {
        self.session = session
        self.workbench = workbench
        self.reduceMotion = reduceMotion
    }

    private var options: RFIDWriteOptions { workbench.writeOptions }
    private var hex: String { options.normalizedHex }
    private var isValid: Bool { options.issue == nil }

    private var geometry: RFIDLabelGeometry {
        RFIDLabelGeometry(widthDots: session.labelWidthDots, heightDots: session.labelHeightDots,
                          dotsPerMM: session.resolution.dotsPerMM)
    }

    private var previewKey: RFIDPreviewKey {
        RFIDPreviewKey(epc: isValid ? hex : "", print: options.print, geometry: geometry)
    }

    /// Letzter EPC der Serie (nil bei Überlauf bzw. ungültiger Eingabe).
    private var lastEPC: String? {
        guard isValid else { return nil }
        guard options.autoIncrement, options.count > 1 else { return hex }
        let offset = UInt64(max(0, options.count - 1)) * UInt64(max(1, options.step))
        return RFIDHex.increment(hex, by: offset)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                dataCard
                encodingCard
                printCard
            }
            .frame(minWidth: 380, idealWidth: 450, maxWidth: 480)

            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                runCard
                previewCard
                voidCard
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: previewKey) { await renderPreview() }
    }

    // MARK: EPC-Daten

    private var dataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("EPC-Daten"), subtitle: tr("Hex in 16-Bit-Wörtern – Standard 96 Bit = 24 Zeichen"),
                              systemImage: "number") {
                    templateMenu
                }

                TextField(tr("z. B. 3074 257B F719 4E40 0000 1A85"), text: $workbench.writeOptions.startHex)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.code)
                    .autocorrectionDisabled()
                    .popover(isPresented: $showsSGTIN, arrowEdge: .bottom) {
                        RFIDSGTINForm { generated in
                            workbench.writeOptions.startHex = RFIDHex.grouped(generated)
                            showsSGTIN = false
                        }
                    }

                validationRow

                if isValid {
                    RFIDHexGroups(hex: hex, fontSize: 14, tint: Theme.violet, reduceMotion: reduceMotion)
                        .id(hex.count)
                        .transition(.opacity)
                    if let decoded = RFIDEPCDecoder.decode(hex: hex) {
                        decodedSummary(decoded)
                    }
                }

                Divider().opacity(0.5)

                Toggle(isOn: $workbench.writeOptions.autoIncrement.animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion))) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("Automatisch hochzählen"))
                            .font(.system(size: 13, weight: .medium))
                        Text(tr("Jeder Tag erhält einen eigenen EPC (Seriennummer im niederwertigen Teil)."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if options.autoIncrement {
                    NumberStepperField(title: tr("Schrittweite"), value: $workbench.writeOptions.step, range: 1...100_000)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                NumberStepperField(title: tr("Anzahl Tags"), value: $workbench.writeOptions.count,
                                   range: 1...RFIDEncoder.maxCount, unit: tr("Stück"))

                seriesPreview
            }
        }
    }

    private var templateMenu: some View {
        Menu {
            Button(tr("Aus GTIN erzeugen (SGTIN-96) …")) { showsSGTIN = true }
            Divider()
            Button(tr("Zufällige 96 Bit")) {
                workbench.writeOptions.startHex = RFIDHex.grouped(RFIDHex.random(digits: 24))
            }
            Button(tr("Zufällige 128 Bit")) {
                workbench.writeOptions.startHex = RFIDHex.grouped(RFIDHex.random(digits: 32))
            }
            if let last = workbench.lastRead, last.bank == .epc {
                Divider()
                Button(tr("Zuletzt gelesenen EPC übernehmen")) {
                    workbench.writeOptions.startHex = RFIDHex.grouped(last.hex)
                }
            }
            Divider()
            Button(tr("Eingabe leeren")) { workbench.writeOptions.startHex = "" }
        } label: {
            Label(tr("Vorlagen"), systemImage: "wand.and.stars")
        }
        .menuStyle(.button)
        .buttonStyle(.labelWerkSecondary)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private var validationRow: some View {
        if let issue = options.issue {
            if hex.isEmpty {
                RFIDInlineMessage(text: issue.message, systemImage: "info.circle", tint: Theme.accent)
            } else {
                RFIDInlineMessage(text: issue.message)
                    .transition(.opacity)
            }
        } else {
            HStack(spacing: 10) {
                RFIDInlineMessage(text: tr("%d Bit · %d Bytes · %d Wörter", hex.count * 4, hex.count / 2, hex.count / 4),
                                  systemImage: "checkmark.circle.fill", tint: Theme.ready)
                Spacer(minLength: 4)
                lengthMeter
            }
            .transition(.opacity)
        }
    }

    /// Längenbalken bis 128 Bit mit Markierung bei 96 Bit.
    private var lengthMeter: some View {
        let bits = Double(hex.count * 4)
        let fraction = min(1, bits / 128)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtleFill)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.violet, Theme.teal], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, proxy.size.width * CGFloat(fraction)))
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1.5)
                    .offset(x: proxy.size.width * 0.75)
            }
        }
        .frame(width: 90, height: 6)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: hex.count)
        .help(tr("Markierung: 96 Bit"))
    }

    private func decodedSummary(_ decoded: RFIDDecodedInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.brandGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(decoded.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(decoded.items.prefix(2).map { $0.label + " " + $0.value }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var seriesPreview: some View {
        if isValid {
            if let last = lastEPC {
                VStack(alignment: .leading, spacing: 3) {
                    KeyValueRow(tr("Erster EPC"), RFIDHex.grouped(hex), monospaced: true)
                    if options.count > 1 {
                        KeyValueRow(tr("Letzter EPC"), RFIDHex.grouped(last), monospaced: true)
                    }
                }
                .padding(8)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                RFIDInlineMessage(text: tr("Beim Hochzählen läuft der EPC über. Bitte Startwert, Schrittweite oder Anzahl verringern."))
            }
        }
    }

    // MARK: Kodierung

    private var pcWordBinding: Binding<Bool> {
        Binding(
            get: { workbench.writeOptions.writesPCWord(byteCount: workbench.writeOptions.byteCount) },
            set: { workbench.writeOptions.writePCWordOverride = $0 }
        )
    }

    private var encodingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Kodierung"), subtitle: tr("^RS8 · ^RFW · optional ^RR und Read-back"),
                              systemImage: "gearshape.2")

                Toggle(isOn: $workbench.writeOptions.verify) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("Nach dem Schreiben prüfen"))
                            .font(.system(size: 13, weight: .medium))
                        Text(tr("Liest den EPC im selben Etikett zurück und vergleicht ihn – langsamer, dafür belegt."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: pcWordBinding) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("EPC-Länge (PC-Wort) mitschreiben"))
                            .font(.system(size: 13, weight: .medium))
                        Text(tr("Nötig, wenn der EPC nicht 96 Bit lang ist – sonst melden Lesegeräte weiter die alte Länge."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Stepper(value: $workbench.writeOptions.retries, in: 0...10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tr("Wiederholungen je Block (^RR)"))
                                .font(.system(size: 13, weight: .medium))
                            Text(tr("0 = Druckerstandard"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(options.retries, format: .number)
                            .font(Theme.Typography.metricSmall)
                            .contentTransition(.numericText(value: Double(options.retries)))
                            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: options.retries)
                    }
                }
            }
        }
    }

    // MARK: Druck

    private var printCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Etikett bedrucken"), subtitle: tr("Optional: Klartext, Barcode und eigener Text"),
                              systemImage: "printer") {
                    Toggle(isOn: $workbench.writeOptions.print.enabled.animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion))) {
                        Text(tr("Bedrucken"))
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                if options.print.enabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(tr("EPC als Klartext (gruppiert)"), isOn: $workbench.writeOptions.print.humanReadable)
                        Toggle(tr("EPC als Barcode (Code 128)"), isOn: $workbench.writeOptions.print.barcode)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(tr("Eigener Text (optional)"), text: $workbench.writeOptions.print.customText)
                                .textFieldStyle(.roundedBorder)
                            Text(tr("Platzhalter: {EPC} für den EPC, {NR} für die laufende Nummer."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(tr("Das Etikett wird nur kodiert und ohne Aufdruck ausgegeben."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Ablauf

    private var canStart: Bool {
        isValid && lastEPC != nil && session.connectionState.isConnected && !workbench.isBusy
    }

    private var runTint: Color? {
        guard let run = workbench.writeRun else { return nil }
        if run.isRunning { return Theme.violet }
        return run.failureCount > 0 || run.wasCancelled ? Theme.warning : Theme.ready
    }

    private var runCard: some View {
        GlassCard(tint: runTint) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Kodieren"), subtitle: runSubtitle, systemImage: "dot.radiowaves.forward") {
                    if let run = workbench.writeRun, !run.isRunning {
                        Button {
                            workbench.dismissWriteRun()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .help(tr("Protokoll schließen"))
                    }
                }

                if let run = workbench.writeRun {
                    RFIDWriteProgressView(run: run, reduceMotion: reduceMotion)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = workbench.writeError {
                    RFIDInlineMessage(text: error)
                        .transition(.opacity)
                }

                if workbench.isWriting, let notice = workbench.writeNotice {
                    RFIDInlineMessage(text: notice, systemImage: "pause.circle.fill", tint: Theme.warning)
                        .transition(.opacity)
                }

                if workbench.isWriting {
                    let blockwise = workbench.writeRun?.verify == false
                    Button {
                        workbench.cancelWrite()
                    } label: {
                        Label(tr("Nach diesem Tag anhalten"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.large)
                    .help(blockwise
                          ? tr("Formate, die noch im Drucker warten, werden verworfen (~JA). Das Etikett, das gerade kodiert wird, läuft noch durch.")
                          : tr("Der Auftrag hält nach dem Tag an, der gerade kodiert wird. Wartet dessen Format noch im angehaltenen Drucker, wird es verworfen."))
                } else {
                    Button {
                        workbench.startWrite(session: session)
                    } label: {
                        Label(options.count == 1 ? tr("Tag kodieren") : tr("%d Tags kodieren", options.count),
                              systemImage: "dot.radiowaves.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .controlSize(.large)
                    .disabled(!canStart)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(tr("Kodieren (⌘↩)"))
                }
            }
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: workbench.writeRun?.isRunning)
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: workbench.writeNotice)
        }
        .overlay {
            CelebrationBurst(trigger: workbench.celebration, colors: [Theme.ready, Theme.teal, Theme.violet])
        }
    }

    private var runSubtitle: String {
        guard let run = workbench.writeRun else {
            return options.verify
                ? tr("Mit Prüfung: jeder Tag wird zurückgelesen")
                : tr("Ohne Prüfung: schnellster Durchsatz")
        }
        if run.isRunning {
            return tr("Tag %d von %d …", min(run.completed + 1, run.total), run.total)
        }
        if run.wasCancelled {
            return tr("Angehalten nach %d von %d Tags", run.completed, run.total)
        }
        return run.verify
            ? tr("Fertig: %d von %d Tags erfolgreich", run.successCount, run.total)
            : tr("Fertig: %d von %d Tags an den Drucker gesendet", run.successCount, run.total)
    }

    // MARK: Vorschau

    private var firstZPL: String {
        guard isValid else { return "" }
        return RFIDEncoder.encodeFormat(epc: hex, number: 1, options: options, geometry: geometry)
    }

    private var previewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Vorschau"), subtitle: tr("Erstes Etikett · %@ · %@", session.stock.name, session.stock.sizeDescription),
                              systemImage: "eye")
                ZStack {
                    LabelSheet(widthMM: session.stock.widthMM, heightMM: session.stock.heightMM) {
                        ZStack {
                            if options.print.enabled, let label = previewLabel {
                                LabelCanvas(label: label)
                                    .transition(.opacity)
                            }
                            RFIDInlayMarker(active: workbench.isWriting, reduceMotion: reduceMotion)
                        }
                    }
                    .frame(maxWidth: 340, maxHeight: 250)
                    if !isValid {
                        Text(tr("Gültigen EPC eingeben, um die Vorschau zu sehen."))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion), value: previewLabel)

                DisclosureGroup(isExpanded: $showsZPL) {
                    VStack(alignment: .trailing, spacing: 6) {
                        CodeEditor(text: .constant(firstZPL), language: .zpl, isEditable: false, fontSize: 11.5)
                            .frame(height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        RFIDCopyButton(text: firstZPL, title: tr("ZPL kopieren"))
                            .controlSize(.small)
                    }
                    .padding(.top, 6)
                } label: {
                    Label(tr("ZPL des ersten Tags"), systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .disabled(!isValid)
            }
        }
    }

    private func renderPreview() async {
        let key = previewKey
        guard key.print.enabled, !key.epc.isEmpty else {
            if previewLabel != nil { previewLabel = nil }
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        if Task.isCancelled { return }
        let zpl = RFIDEncoder.previewFormat(epc: key.epc, number: 1, options: key.print, geometry: key.geometry)
        let geometry = key.geometry
        let rendered = await Task.detached(priority: .userInitiated) { () -> RenderedLabel? in
            ZPLInterpreter(dotsPerMM: geometry.dotsPerMM, defaultWidthDots: geometry.widthDots,
                           defaultHeightDots: geometry.heightDots).render(zpl).labels.first
        }.value
        if Task.isCancelled { return }
        previewLabel = rendered
    }

    // MARK: VOID

    private var voidCard: some View {
        GlassCard(tint: Theme.warning) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: "exclamationmark.triangle.fill", tint: Theme.warning, size: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Was passiert bei einem Fehler?"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(tr("Kann ein Tag nicht beschrieben werden, druckt der Drucker „VOID“ über das Etikett und markiert es damit als ungültig. Je nach Druckereinstellung versucht er es anschließend auf dem nächsten Etikett erneut. VOID-Etiketten aussortieren – der Zähler „Ungültig“ in der Statuskarte zählt sie mit."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tr("Häufige Ursachen: falsche Programmierposition, zu geringe Schreibleistung, gesperrter oder defekter Tag. Eine RFID-Kalibrierung behebt die meisten Fälle."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            workbench.tab = .settings
                        }
                    } label: {
                        Label(tr("Zur Kalibrierung"), systemImage: "scope")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Fortschritt

private struct RFIDWriteProgressView: View {
    let run: RFIDWriteRun
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressRing(progress: run.progress, size: 34, lineWidth: 4)
                    .overlay {
                        Text(run.progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                    }
                VStack(alignment: .leading, spacing: 4) {
                    StripedProgressBar(progress: run.isRunning ? max(0.02, run.progress) : run.progress,
                                       tint: run.failureCount > 0 ? Theme.warning : Theme.accent)
                    HStack(spacing: 14) {
                        Label {
                            Text(tr("%d erfolgreich", run.successCount))
                                .contentTransition(.numericText())
                        } icon: {
                            Image(systemName: run.verify ? "checkmark.seal.fill" : "paperplane.fill")
                                .foregroundStyle(run.verify ? Theme.ready : Theme.printing)
                        }
                        Label {
                            Text(tr("%d fehlerhaft", run.failureCount))
                                .contentTransition(.numericText())
                        } icon: {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(run.failureCount > 0 ? Theme.error : Color.secondary)
                                .symbolEffect(.bounce, value: reduceMotion ? 0 : run.failureCount)
                        }
                        if run.discardedTotal > 0 {
                            Label {
                                Text(tr("%d verworfen", run.discardedTotal))
                                    .contentTransition(.numericText())
                            } icon: {
                                Image(systemName: RFIDWriteState.discarded.systemImage)
                                    .foregroundStyle(RFIDWriteState.discarded.tint)
                            }
                            .help(tr("Beim Anhalten noch im Drucker wartend und dort verworfen – diese Tags wurden nicht kodiert."))
                            .transition(.opacity)
                        }
                        Spacer()
                        Text(tr("%d / %d", run.completed, run.total))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: run.completed)

            if !run.entries.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(run.entries.prefix(200)) { entry in
                            RFIDWriteEntryRow(entry: entry)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                    }
                    .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: run.completed)
                }
                .frame(maxHeight: 190)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct RFIDWriteEntryRow: View {
    let entry: RFIDWriteEntry

    /// Abweichend zurückgelesener EPC (nur bei `.mismatch` mit Daten).
    private var mismatchValue: String? {
        if case .mismatch(let value) = entry.state { return value }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "#\(entry.id)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(verbatim: RFIDHex.grouped(entry.hex))
                .font(Theme.Typography.codeSmall)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if let value = mismatchValue {
                Text(verbatim: RFIDHex.grouped(value))
                    .font(Theme.Typography.codeSmall)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tr("Zurückgelesen"))
            }
            Label(entry.state.title, systemImage: entry.state.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(entry.state.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

// MARK: - Inlay-Markierung der Vorschau

/// Gestrichelter Umriss des RFID-Inlays in der Etikettenmitte.
private struct RFIDInlayMarker: View {
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.62
            let height = min(proxy.size.height * 0.2, width * 0.3)
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active || reduceMotion)) { timeline in
                let energy = active && !reduceMotion
                    ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6)
                    : 0
                Canvas { context, size in
                    RFIDInlayPainter.draw(context: &context, size: size, energy: energy, tint: Theme.violet, dashed: true)
                }
            }
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .opacity(0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - SGTIN-96-Generator

/// Erzeugt einen GS1-konformen SGTIN-96 aus GTIN, Präfixlänge, Filter und Seriennummer.
struct RFIDSGTINForm: View {
    let onApply: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    @State private var gtin = ""
    @State private var prefixLength = 7
    @State private var filter = 1
    @State private var serial = "1"

    init(onApply: @escaping (String) -> Void) {
        self.onApply = onApply
    }

    private var outcome: (hex: String?, message: String?) {
        let trimmedGTIN = gtin.trimmingCharacters(in: .whitespaces)
        guard !trimmedGTIN.isEmpty else { return (nil, nil) }
        guard let serialValue = UInt64(serial.trimmingCharacters(in: .whitespaces)) else {
            return (nil, tr("Bitte eine Seriennummer aus Ziffern eingeben."))
        }
        do {
            let hex = try RFIDEPCDecoder.encodeSGTIN96(gtin: trimmedGTIN, companyPrefixLength: prefixLength,
                                                       filter: filter, serial: serialValue)
            return (hex, nil)
        } catch let error as RFIDSGTINError {
            return (nil, error.message)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    var body: some View {
        let result = outcome
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(tr("SGTIN-96 erzeugen"), subtitle: tr("GS1-konformer EPC aus GTIN und Seriennummer"),
                          systemImage: "barcode.viewfinder")

            TextField(tr("GTIN (8, 12, 13 oder 14 Ziffern)"), text: $gtin)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.code)

            Stepper(value: $prefixLength, in: 6...12) {
                Text(tr("Firmenpräfix: %d Stellen", prefixLength))
                    .font(.system(size: 12.5))
            }

            Picker(tr("Filter"), selection: $filter) {
                ForEach(0..<8, id: \.self) { value in
                    Text(verbatim: "\(value) · " + RFIDEPCDecoder.filterName(value)).tag(value)
                }
            }
            .pickerStyle(.menu)

            TextField(tr("Start-Seriennummer"), text: $serial)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.code)

            Group {
                if let hex = result.hex {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Ergebnis"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(verbatim: RFIDHex.grouped(hex))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                            .contentTransition(.interpolate)
                    }
                } else if let message = result.message {
                    RFIDInlineMessage(text: message)
                }
            }
            .animation(Motion.animation(.easeOut(duration: 0.2), reduceMotion: systemReduceMotion || appReduceMotion),
                       value: result.hex)

            Text(tr("Die Länge des Firmenpräfixes ergibt sich aus Ihrer GS1-Mitgliedschaft (meist 7 bis 10 Stellen). Beim Hochzählen ändert sich nur die Seriennummer."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(tr("Übernehmen")) {
                    if let hex = result.hex { onApply(hex) }
                }
                .buttonStyle(.labelWerkPrimary)
                .disabled(result.hex == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

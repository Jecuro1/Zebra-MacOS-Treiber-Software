import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// Dateien im Drucker: Laufwerke, Speicherbelegung, Schriften & Grafiken hochladen, Probedruck, Löschen.
/// Ersetzt „Download Fonts/Graphics“ der Zebra Setup Utilities.
struct FilesView: View {
    let session: PrinterSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var browser = FilesBrowserModel()
    @State private var fontUpload: FilesFontUpload?
    @State private var graphicUpload: FilesGraphicUpload?
    @State private var pendingDelete: PrinterFile?
    @State private var isPreparing = false

    init(session: PrinterSession) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                FilesOverviewCard(session: session, browser: browser, reduceMotion: reduceMotion) {
                    Task { await reload() }
                }
                uploadSection
                FilesListCard(
                    session: session,
                    browser: browser,
                    reduceMotion: reduceMotion,
                    requestDelete: requestDelete,
                    printSample: { file in Task { await printSample(file) } },
                    retry: { Task { await reload() } }
                )
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .task(id: browser.drive) {
            // Nacheinander, damit sich Verzeichnis- und Speicherabfrage nicht überschneiden.
            await browser.load(session: session, reduceMotion: reduceMotion)
            if browser.memory.isEmpty && !Task.isCancelled {
                await browser.loadMemory(session: session)
            }
        }
        .onChange(of: session.connectionState) { oldValue, newValue in
            // Nach einem Wiederverbinden neu laden (nicht, wenn gerade ohnehin geladen wird).
            if newValue == .connected && oldValue != .connected && !browser.isLoading {
                Task { await reload() }
            }
        }
        .confirmationDialog(tr("Datei löschen?"), isPresented: deleteDialogBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { file in
            Button(tr("Löschen"), role: .destructive) {
                Task { await browser.delete(file, session: session, model: model, reduceMotion: reduceMotion) }
            }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { file in
            Text(tr("„%@“ wird unwiderruflich aus dem Druckerspeicher entfernt. Etiketten, die diese Datei verwenden, drucken danach nicht mehr korrekt.",
                    FilesZPL.path(drive: file.drive, name: file.name)))
        }
    }

    // MARK: Hochladen

    @ViewBuilder
    private var uploadSection: some View {
        if let upload = fontUpload {
            FilesFontComposer(upload: upload, session: session, browser: browser, reduceMotion: reduceMotion) {
                closeComposer()
            }
            .id(upload.id)
            .transition(composerTransition)
        } else if let upload = graphicUpload {
            FilesGraphicComposer(upload: upload, session: session, browser: browser, reduceMotion: reduceMotion) {
                closeComposer()
            }
            .id(upload.id)
            .transition(composerTransition)
        } else {
            FilesUploadCard(
                isPreparing: isPreparing,
                onDrop: handleDrop,
                pickFont: pickFont,
                pickGraphic: pickGraphic
            )
            .transition(composerTransition)
        }
    }

    private var composerTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    private var defaultUploadDrive: FilesDrive {
        browser.drive.isWritable ? browser.drive : .flash
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        let ext = url.pathExtension.lowercased()
        if FilesFontInspector.fontExtensions.contains(ext) {
            Task { await openFont(url) }
            return true
        }
        if FilesGraphicImport.isImage(url) {
            Task { await openGraphic(url) }
            return true
        }
        model.toast(tr("Dateityp nicht unterstützt"),
                    message: tr("Ziehe eine TrueType-/OpenType-Schrift oder ein Bild (PNG, JPEG, TIFF, HEIC, PDF) hierher."),
                    style: .warning)
        return false
    }

    private func pickFont() {
        guard let url = TransferOpenPanel.pickFile(
            title: tr("Schriftart auswählen"),
            message: tr("TrueType- oder OpenType-Schrift, die im Drucker gespeichert werden soll."),
            prompt: tr("Auswählen"),
            types: FilesFontInspector.openPanelTypes
        ) else { return }
        Task { await openFont(url) }
    }

    private func pickGraphic() {
        guard let url = TransferOpenPanel.pickFile(
            title: tr("Grafik auswählen"),
            message: tr("Bild oder PDF – wird in Druckpunkte gerastert und als Grafik gespeichert."),
            prompt: tr("Auswählen"),
            types: ImageImport.supportedTypes
        ) else { return }
        Task { await openGraphic(url) }
    }

    private func openFont(_ url: URL) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let upload = try await FilesFontUpload.load(url: url, defaultDrive: defaultUploadDrive)
            withAnimation(reduceMotion ? nil : Motion.spring) {
                graphicUpload = nil
                fontUpload = upload
            }
        } catch {
            model.toast(tr("Schrift kann nicht verwendet werden"), message: PrinterSession.describe(error), style: .error)
        }
    }

    private func openGraphic(_ url: URL) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let upload = try await FilesGraphicUpload.load(
                url: url,
                dpi: session.resolution.dpi,
                labelWidth: session.labelWidthDots,
                labelHeight: session.labelHeightDots,
                maxWidth: session.model?.printWidthDots(session.resolution) ?? max(session.labelWidthDots, 832),
                algorithm: model.preferences.imageDither,
                drive: defaultUploadDrive
            )
            withAnimation(reduceMotion ? nil : Motion.spring) {
                fontUpload = nil
                graphicUpload = upload
            }
        } catch {
            model.toast(tr("Bild kann nicht verwendet werden"), message: PrinterSession.describe(error), style: .error)
        }
    }

    private func closeComposer() {
        withAnimation(reduceMotion ? nil : Motion.spring) {
            fontUpload = nil
            graphicUpload = nil
        }
    }

    // MARK: Liste

    private func reload() async {
        await browser.load(session: session, reduceMotion: reduceMotion)
        await browser.loadMemory(session: session)
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { presented in if !presented { pendingDelete = nil } }
        )
    }

    private func requestDelete(_ file: PrinterFile) {
        if model.preferences.confirmDestructiveActions {
            pendingDelete = file
        } else {
            Task { await browser.delete(file, session: session, model: model, reduceMotion: reduceMotion) }
        }
    }

    private func printSample(_ file: PrinterFile) async {
        let path = FilesZPL.path(drive: file.drive, name: file.name)
        let dpmm = session.resolution.dotsPerMM
        let zpl: String
        switch FilesCategory.of(file) {
        case .font:
            zpl = FilesZPL.fontSample(path: path, title: tr("Schriftprobe: %@", path),
                                      sample: tr("Etikettendruck mit LabelWerk – ÄÖÜ äöü ß € 0123456789"),
                                      widthDots: session.labelWidthDots, heightDots: session.labelHeightDots,
                                      dotsPerMM: dpmm)
        case .graphic:
            zpl = FilesZPL.graphicSample(path: path, graphicWidth: nil, graphicHeight: nil,
                                         caption: tr("Grafik %@", path),
                                         widthDots: session.labelWidthDots, heightDots: session.labelHeightDots,
                                         dotsPerMM: dpmm)
        case .format:
            zpl = FilesZPL.formatRecall(path: path)
        case .firmware, .other:
            return
        }
        await session.printZPL(zpl, title: tr("Probedruck %@", path))
    }
}

// MARK: - Übersicht

private struct FilesOverviewCard: View {
    let session: PrinterSession
    @Bindable var browser: FilesBrowserModel
    let reduceMotion: Bool
    let refresh: () -> Void

    var body: some View {
        let drive = browser.drive
        let memory = browser.memory[drive]
        GlassCard(padding: 20, cornerRadius: Theme.Metrics.cornerLarge, tint: drive.tint) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 20) {
                    gauge(memory: memory, drive: drive)
                        .frame(width: 108, height: 108)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(tr("Druckerspeicher"))
                                .font(Theme.Typography.title)
                            TransferChip(drive.title, systemImage: drive.systemImage, tint: drive.tint)
                                .id(drive)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                        Text(drive.explanation)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        Text(memoryLine(memory))
                            .font(.system(size: 12.5, weight: .medium))
                            .contentTransition(.numericText())
                        counts
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Button(action: refresh) {
                            HStack(spacing: 6) {
                                if browser.isLoading {
                                    ProgressRing(progress: nil, size: 13, lineWidth: 2)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(tr("Aktualisieren"))
                            }
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .disabled(browser.isLoading)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        if let refreshed = browser.lastRefresh {
                            Text(refreshed, style: .time)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                AnimatedTabBar(items: FilesDrive.allCases, selection: $browser.drive,
                               title: { $0.title }, systemImage: { $0.systemImage })
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: drive)
        .animation(reduceMotion ? nil : Motion.spring, value: browser.loadCount)
    }

    @ViewBuilder
    private func gauge(memory: FilesMemoryInfo?, drive: FilesDrive) -> some View {
        if let fraction = memory?.usedFraction {
            RingGauge(value: fraction, lineWidth: 10,
                      colors: fraction > 0.9 ? [Theme.warning, Theme.error] : [Theme.violet, Theme.teal],
                      label: tr("belegt"), valueText: TransferFormat.percent(fraction))
        } else {
            ZStack {
                Circle()
                    .stroke(Theme.subtleFill, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: browser.isLoading ? 0.25 : 1)
                    .stroke(drive.tint.opacity(0.35), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                IconBadge(systemImage: drive.systemImage, tint: drive.tint, size: 50)
                    .symbolEffect(.bounce, value: drive)
            }
            .padding(5)
        }
    }

    private func memoryLine(_ memory: FilesMemoryInfo?) -> String {
        let fileCount = browser.files.count
        if let free = memory?.free, let total = memory?.total {
            return tr("%@ frei von %@", TransferFormat.bytes64(free), TransferFormat.bytes64(total))
        }
        if let free = memory?.free {
            return tr("%@ frei", TransferFormat.bytes64(free))
        }
        if !browser.hasLoaded {
            return tr("Speicher wird gelesen …")
        }
        if fileCount == 0 {
            return tr("Keine Dateien gespeichert")
        }
        return tr("%@ durch %d Dateien belegt", TransferFormat.bytes(browser.totalBytes), fileCount)
    }

    private var counts: some View {
        HStack(spacing: 6) {
            ForEach(FilesCategory.allCases) { category in
                let count = browser.count(of: category)
                if count > 0 {
                    TransferChip(tr("%d %@", count, count == 1 ? category.singular : category.title),
                                 systemImage: category.systemImage, tint: category.tint)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
    }
}

// MARK: - Ablage

private struct FilesUploadCard: View {
    let isPreparing: Bool
    let onDrop: ([URL]) -> Bool
    let pickFont: () -> Void
    let pickGraphic: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Hochladen"),
                              subtitle: tr("Schriften und Logos dauerhaft im Drucker speichern – kleinere Druckaufträge, schnellerer Druck"),
                              systemImage: "square.and.arrow.up.on.square")
                TransferDropZone(
                    title: tr("Schrift oder Grafik hierher ziehen"),
                    message: tr("TrueType/OpenType (.ttf, .otf) oder Bilder (PNG, JPEG, TIFF, HEIC, PDF). Grafiken werden in Druckpunkte gerastert und als .GRF gespeichert."),
                    systemImage: "tray.and.arrow.down",
                    tint: Theme.violet,
                    isEnabled: !isPreparing,
                    onDrop: onDrop
                ) {
                    HStack(spacing: 10) {
                        Button(action: pickFont) {
                            Label(tr("Schriftart wählen …"), systemImage: "textformat")
                        }
                        .buttonStyle(.labelWerkPrimary)
                        Button(action: pickGraphic) {
                            Label(tr("Grafik wählen …"), systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.labelWerkSecondary)
                        if isPreparing {
                            ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .disabled(isPreparing)
                    .animation(Motion.snappy, value: isPreparing)
                }
            }
        }
    }
}

// MARK: - Dateiliste

private struct FilesListCard: View {
    let session: PrinterSession
    @Bindable var browser: FilesBrowserModel
    let reduceMotion: Bool
    let requestDelete: (PrinterFile) -> Void
    let printSample: (PrinterFile) -> Void
    let retry: () -> Void

    var body: some View {
        let groups = browser.filteredGroups
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Dateien"), subtitle: browser.drive.title, systemImage: "folder") {
                    Menu {
                        Picker(tr("Sortierung"), selection: $browser.sort) {
                            ForEach(FilesSortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(tr("Sortieren"), systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 12))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
                if !browser.files.isEmpty || !browser.search.isEmpty {
                    TransferSearchField(text: $browser.search, prompt: tr("Dateien durchsuchen"))
                }
                content(groups)
            }
        }
    }

    @ViewBuilder
    private func content(_ groups: [FilesGroup]) -> some View {
        if !browser.hasLoaded || (browser.isLoading && browser.files.isEmpty) {
            VStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    TransferSkeletonRow(widthFactor: [1, 0.8, 0.9, 0.7, 0.85][index])
                }
            }
            .shimmering(active: true)
            .transition(.opacity)
        } else if let error = browser.loadError, browser.files.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .symbolEffect(.bounce, value: browser.loadCount)
                Text(tr("Dateiliste nicht verfügbar"))
                    .font(Theme.Typography.headline)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: retry) {
                    Label(tr("Erneut versuchen"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.labelWerkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .transition(.opacity)
        } else if browser.files.isEmpty {
            EmptyStateView(
                title: tr("Keine Dateien"),
                message: browser.drive.isWritable
                    ? tr("Auf diesem Laufwerk sind keine Dateien gespeichert. Lade oben eine Schrift oder Grafik hoch.")
                    : tr("Auf diesem Laufwerk wurden keine Dateien gefunden."),
                systemImage: browser.drive.systemImage
            )
            .frame(minHeight: 280)
            .transition(.opacity)
        } else if groups.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(tr("Keine Treffer für „%@“", browser.search))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        groupHeader(group)
                        ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                            FilesRow(
                                file: file,
                                category: group.category,
                                isDeleting: browser.deleting.contains(file.id),
                                canDelete: (FilesDrive(code: file.drive) ?? browser.drive).isWritable,
                                canPrint: [.font, .graphic, .format].contains(group.category) && !session.isBusy,
                                fontHeight: session.resolution.dotsPerMM * 5,
                                onPrint: { printSample(file) },
                                onDelete: { requestDelete(file) }
                            )
                            .transferAppear(index: index, reduceMotion: reduceMotion)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading))
                                    .combined(with: .move(edge: .trailing))
                            ))
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .shimmering(active: browser.isLoading)
            .id(browser.drive)
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
            .animation(reduceMotion ? nil : Motion.spring, value: browser.files.map(\.id))
            .animation(reduceMotion ? nil : Motion.snappy, value: browser.sort)
        }
    }

    private func groupHeader(_ group: FilesGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.category.systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(group.category.tint)
            Text(group.category.title)
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: "\(group.files.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background {
                    Capsule().fill(Theme.subtleFill)
                }
                .contentTransition(.numericText())
            Spacer()
            Text(TransferFormat.bytes(group.totalBytes))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - Zeile

private struct FilesRow: View {
    let file: PrinterFile
    let category: FilesCategory
    let isDeleting: Bool
    let canDelete: Bool
    let canPrint: Bool
    let fontHeight: Int
    let onPrint: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var copied = false

    private var path: String { FilesZPL.path(drive: file.drive, name: file.name) }
    private var reference: String { FilesZPL.reference(path: path, category: category, fontHeight: fontHeight) }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: category.systemImage, tint: category.tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(category.singular)
                    Text(verbatim: "·")
                    Text(verbatim: path)
                        .font(Theme.Typography.codeSmall)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if canPrint {
                    Button(action: onPrint) {
                        Image(systemName: "printer.dotmatrix")
                    }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("Probedruck"))
                }
                if category != .firmware && category != .other {
                    Button(action: copyReference) {
                        Image(systemName: copied ? "checkmark" : "chevron.left.forwardslash.chevron.right")
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(copied ? Theme.ready : Color.primary)
                    }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("ZPL-Verweis kopieren"))
                }
                if canDelete {
                    if isDeleting {
                        ProgressRing(progress: nil, size: 16, lineWidth: 2)
                            .padding(.horizontal, 8)
                    } else {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .help(tr("Löschen"))
                    }
                }
            }
            .font(.system(size: 12))
            .opacity(hovering || isDeleting || copied ? 1 : 0.35)
            Text(TransferFormat.bytes(file.size))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Theme.subtleFill : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .opacity(isDeleting ? 0.55 : 1)
        .contextMenu {
            if canPrint {
                Button(tr("Probedruck"), action: onPrint)
            }
            if category != .firmware && category != .other {
                Button(tr("ZPL-Verweis kopieren"), action: copyReference)
            }
            Button(tr("Pfad kopieren")) { copy(path) }
            if canDelete {
                Divider()
                Button(tr("Löschen …"), role: .destructive, action: onDelete)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func copyReference() {
        copy(reference)
        withAnimation(Motion.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(Motion.snappy) { copied = false }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// „Bild & PDF“: Datei ablegen, auf das Etikett einpassen, Rasterung live vergleichen und
/// drucken, als ZPL übernehmen oder als Grafik im Drucker speichern.
struct DesignerImageWorkspace: View {
    let target: DesignerTarget
    let session: PrinterSession?
    @Bindable var state: DesignerImageState
    let reduceMotion: Bool
    let onAdopt: (String, String) -> Void

    @Environment(AppModel.self) private var model
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isUploadPresented = false
    @State private var printSuccessCount = 0
    @State private var isAdopting = false
    @Namespace private var pageNamespace

    /// Treibereinstellungen des Druckers mit der hier gewählten Rasterung.
    private var settings: PrintSettings {
        var settings = session?.saved.settings ?? .default
        settings.dither = state.dither
        settings.threshold = state.threshold
        return settings
    }

    private var key: DesignerImageKey? {
        guard let source = state.source, !source.pages.isEmpty else { return nil }
        return DesignerImageKey(
            sourceID: source.id,
            page: min(max(0, state.pageIndex), source.pages.count - 1),
            widthDots: target.widthDots,
            heightDots: target.heightDots,
            fitMode: state.fitMode,
            rotation: state.rotation,
            brightness: state.brightness,
            contrast: state.contrast,
            dither: state.dither,
            threshold: state.threshold,
            invert: state.invert,
            settings: settings,
            language: target.language,
            resolution: target.resolution,
            stock: target.stock,
            maxPrintWidthDots: target.maxPrintWidthDots
        )
    }

    var body: some View {
        let key = self.key
        HStack(alignment: .top, spacing: Theme.Metrics.cardSpacing) {
            previewColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(spacing: Theme.Metrics.cardSpacing) {
                    DesignerImageControls(state: state, reduceMotion: reduceMotion,
                                          defaultDither: model.preferences.imageDither)
                    outputCard
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .frame(width: 330)
            .disabled(state.source == nil)
            .opacity(state.source == nil ? 0.55 : 1)
        }
        .animation(reduceMotion ? nil : Motion.spring, value: state.source == nil)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            DesignerFiles.loadFileURL(from: providers) { url in handleFile(url) }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: ImageImport.supportedTypes) { result in
            switch result {
            case .success(let url):
                load(url)
            case .failure(let error):
                model.toast(tr("Datei konnte nicht geöffnet werden"), message: error.localizedDescription, style: .error)
            }
        }
        .task(id: key) {
            if let key { await state.process(key) }
        }
        .onChange(of: target.resolution) { _, newValue in
            // PDFs in der neuen Auflösung neu rendern (wichtig für „Originalgröße“).
            if let source = state.source, source.isPDF, source.renderedDPI != newValue.dpi {
                load(source.url)
            }
        }
    }

    // MARK: Vorschau

    /// ZStack, damit Ablagefläche und Vorschau beim Wechsel übereinander überblenden.
    private var previewColumn: some View {
        ZStack {
            previewContent
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let source = state.source {
            VStack(spacing: 0) {
                sourceHeader(source)
                Divider().opacity(0.6)
                comparison
                if source.pages.count > 1 {
                    Divider().opacity(0.6)
                    pageStrip(source)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Divider().opacity(0.6)
                statsLine(source)
            }
            .labelWerkGlass(cornerRadius: Theme.Metrics.corner)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                        .strokeBorder(Theme.brandGradient, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                        .background(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                            .fill(Theme.violet.opacity(0.07)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: isDropTargeted)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            DesignerDropZone(isTargeted: isDropTargeted, isLoading: state.isLoading, reduceMotion: reduceMotion) {
                isImporterPresented = true
            }
            .transition(.opacity)
        }
    }

    private func sourceHeader(_ source: DesignerImageSource) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: source.isPDF ? "doc.richtext" : "photo", tint: Theme.teal, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(source.isPDF
                     ? tr("PDF · %d Seiten · gerendert mit %d dpi", source.pages.count, source.renderedDPI)
                     : tr("Bild · %d × %d Pixel", source.pixelWidth, source.pixelHeight))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if state.isLoading || state.isProcessing {
                ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                    .transition(.scale.combined(with: .opacity))
            }
            Button {
                isImporterPresented = true
            } label: {
                Label(tr("Andere Datei …"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            Button {
                withAnimation(reduceMotion ? nil : Motion.spring) { state.clear() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("Datei schließen"))
        }
        .padding(12)
        .animation(reduceMotion ? nil : Motion.snappy, value: state.isProcessing)
    }

    private var comparison: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(40, geo.size.width - 56), height: max(40, geo.size.height - 56))
            let fit = DesignerCanvasMath.fitSize(widthDots: target.widthDots, heightDots: target.heightDots, in: available)
            LabelSheet(widthMM: target.widthMM, heightMM: target.heightMM) {
                DesignerSplitCompare(processed: state.processed, split: $state.split, reduceMotion: reduceMotion)
            }
            .frame(width: fit.width, height: fit.height)
            .keyframeAnimator(initialValue: DesignerPrintMotion(), trigger: reduceMotion ? 0 : printSuccessCount) { content, value in
                content
                    .scaleEffect(value.scale)
                    .offset(y: value.offset)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offset) {
                    CubicKeyframe(-14, duration: 0.16)
                    CubicKeyframe(320, duration: 0.38)
                    MoveKeyframe(-120)
                    SpringKeyframe(0, duration: 0.6, spring: .bouncy)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.03, duration: 0.16)
                    CubicKeyframe(0.86, duration: 0.38)
                    MoveKeyframe(0.94)
                    SpringKeyframe(1, duration: 0.6, spring: .bouncy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.22)
                    LinearKeyframe(0, duration: 0.32)
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.35)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(minHeight: 260)
        .clipped()
    }

    private func pageStrip(_ source: DesignerImageSource) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(source.thumbnails.indices, id: \.self) { index in
                        DesignerPageThumbnail(image: source.thumbnails[index], number: index + 1,
                                              isSelected: index == state.pageIndex,
                                              isIncluded: state.allPages || index == state.pageIndex,
                                              namespace: pageNamespace)
                            .id(index)
                            .onTapGesture {
                                withAnimation(reduceMotion ? nil : Motion.spring) { state.pageIndex = index }
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(height: 116)
            .onChange(of: state.pageIndex) { _, newValue in
                withAnimation(reduceMotion ? nil : Motion.snappy) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func statsLine(_ source: DesignerImageSource) -> some View {
        let pageCount = state.allPages ? source.pages.count : 1
        return HStack(spacing: 14) {
            DesignerStat(systemImage: "ruler", text: target.sizeText)
            DesignerStat(systemImage: "square.grid.3x3", text: tr("%d × %d Punkte", target.widthDots, target.heightDots))
            DesignerStat(systemImage: "printer.dotmatrix", text: tr("%d dpi", target.resolution.dpi))
            Spacer(minLength: 6)
            if let processed = state.processed {
                DesignerStat(systemImage: "circle.lefthalf.filled",
                             text: tr("Schwarzanteil %@", DesignerFormat.percent(processed.blackRatio)))
                if let bytes = processed.jobBytes {
                    DesignerStat(systemImage: "arrow.up.doc",
                                 text: tr("Auftrag ≈ %@", DesignerFormat.bytes(bytes * pageCount)))
                        .help(tr("Geschätzte Größe des Druckauftrags mit den aktuellen Treibereinstellungen"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Ausgabe

    private var outputCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Ausgabe"), subtitle: target.printerName ?? tr("Kein Drucker ausgewählt"),
                              systemImage: "printer.dotmatrix")

                if let source = state.source, source.pages.count > 1 {
                    DesignerChoiceBar(items: [false, true], selection: $state.allPages, reduceMotion: reduceMotion,
                                      title: { $0 ? tr("Alle %d Seiten", source.pages.count) : tr("Diese Seite") },
                                      systemImage: { $0 ? "doc.on.doc" : "doc" })
                }

                Stepper(value: $state.copies, in: 1...9999) {
                    HStack(spacing: 4) {
                        Text(tr("Kopien"))
                        Spacer(minLength: 4)
                        Text(state.copies, format: .number)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(value: Double(state.copies)))
                            .animation(Motion.snappy, value: state.copies)
                    }
                    .font(.system(size: 12.5))
                }

                if !driverHints.isEmpty {
                    Label(tr("Treibereinstellungen aktiv: %@", driverHints.joined(separator: ", ")),
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DesignerSendButton(title: tr("Drucken"), systemImage: "printer.fill", phase: state.printPhase,
                                   fullWidth: true, reduceMotion: reduceMotion, action: { printImages() })
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session == nil || state.processed == nil || state.printPhase == .sending)
                    .help(session == nil ? tr("Zuerst oben rechts einen Zieldrucker wählen") : tr("Drucken (⌘↩)"))

                Button {
                    adoptToDesigner()
                } label: {
                    Label(tr("Als ZPL in Designer übernehmen"), systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(state.processed == nil || isAdopting)

                Button {
                    isUploadPresented = true
                } label: {
                    Label(tr("Als Grafik auf Drucker speichern"), systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkSecondary)
                .disabled(session == nil || state.processed == nil)
                .help(tr("Grafik (.GRF) im Druckerspeicher ablegen – abrufbar mit ^XG"))
                .popover(isPresented: $isUploadPresented, arrowEdge: .leading) {
                    DesignerGraphicUploadForm(session: session, bitmap: state.processed?.bitmap,
                                              suggestedName: state.source?.name ?? "", reduceMotion: reduceMotion) {
                        isUploadPresented = false
                    }
                }

                Button(action: exportPNG) {
                    Label(tr("Gerastert als PNG exportieren …"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.labelWerkPlain)
                .disabled(state.processed == nil)
            }
        }
    }

    private var driverHints: [String] {
        guard let settings = session?.saved.settings else { return [] }
        var hints: [String] = []
        if settings.negative { hints.append(tr("Negativ")) }
        if settings.mirror { hints.append(tr("Spiegeln")) }
        if settings.rotate180 { hints.append(tr("180° drehen")) }
        return hints
    }

    // MARK: Aktionen

    private func handleFile(_ url: URL) {
        if DesignerFiles.isImage(url) {
            load(url)
        } else if DesignerFiles.isDocument(url) {
            // ZPL-Dateien direkt im Editor öffnen.
            do {
                let text = try DesignerFiles.readText(url)
                onAdopt(text, url.deletingPathExtension().lastPathComponent)
            } catch {
                model.toast(tr("Datei konnte nicht geöffnet werden"), message: PrinterSession.describe(error), style: .error)
            }
        } else {
            model.toast(tr("Dateityp wird nicht unterstützt"), message: url.lastPathComponent, style: .warning)
        }
    }

    private func load(_ url: URL) {
        let dpi = target.resolution.dpi
        let animation = reduceMotion ? nil : Motion.spring
        Task {
            do {
                try await state.load(url, dpi: dpi, animation: animation)
            } catch {
                model.toast(tr("Datei konnte nicht geladen werden"), message: PrinterSession.describe(error), style: .error)
            }
        }
    }

    private func printImages() {
        guard state.printPhase != .sending else { return }
        guard let session else {
            model.toast(tr("Kein Drucker ausgewählt"),
                        message: tr("Wähle oben rechts einen Zieldrucker oder füge den Demo-Drucker hinzu."), style: .warning)
            return
        }
        guard let key, let source = state.source else { return }
        let allPages = state.allPages
        let copies = state.copies
        let settings = self.settings
        let title = source.name
        state.printPhase = .sending
        Task {
            let images = await state.renderPages(for: key, allPages: allPages)
            var ok = false
            if !images.isEmpty {
                ok = await session.printImages(images, title: title, copies: copies, settings: settings)
            }
            state.printPhase = ok ? .success : .failure
            if ok { printSuccessCount += 1 }
            try? await Task.sleep(for: .seconds(1.8))
            if state.printPhase != .sending { state.printPhase = .idle }
        }
    }

    private func adoptToDesigner() {
        guard let key, let source = state.source else { return }
        let allPages = state.allPages
        let title = source.name
        isAdopting = true
        Task {
            let images = await state.renderPages(for: key, allPages: allPages)
            let zpl = await Task.detached(priority: .userInitiated) {
                DesignerImageProcessing.zplDocument(images: images, key: key, title: title)
            }.value
            isAdopting = false
            guard !images.isEmpty else { return }
            onAdopt(zpl, title)
        }
    }

    private func exportPNG() {
        guard let processed = state.processed else { return }
        let base = DesignerFiles.safeFileName(state.source?.name ?? tr("Etikett"))
        guard let url = DesignerFiles.chooseDestination(name: base + "-" + tr("gerastert") + ".png", types: [.png],
                                                        title: tr("Gerastertes Bild exportieren")) else { return }
        let bitmap = processed.bitmap
        Task {
            let data = await Task.detached(priority: .userInitiated) { PNGCodec.encode(bitmap) }.value
            do {
                try data.write(to: url, options: .atomic)
                model.toast(tr("PNG exportiert"), message: url.lastPathComponent, style: .success)
            } catch {
                model.toast(tr("Export fehlgeschlagen"), message: error.localizedDescription, style: .error)
            }
        }
    }
}

// MARK: - Vorher/Nachher

/// Original (links) und Rasterung (rechts) mit ziehbarem Teiler.
struct DesignerSplitCompare: View {
    let processed: DesignerProcessedImage?
    @Binding var split: CGFloat
    let reduceMotion: Bool

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let x = width * split
            ZStack(alignment: .topLeading) {
                if let processed {
                    BitmapPreview(bitmap: processed.bitmap)
                        .frame(width: width, height: height)
                    GrayImagePreview(image: processed.gray)
                        .frame(width: width, height: height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, x))
                        }
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: height)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .offset(x: x - 1)
                    handle
                        .position(x: x, y: height / 2)
                    caption(tr("Original"))
                        .padding(8)
                        .opacity(split > 0.16 ? 1 : 0)
                    caption(tr("Gerastert"))
                        .padding(8)
                        .frame(width: width, alignment: .trailing)
                        .opacity(split < 0.84 ? 1 : 0)
                } else {
                    Theme.labelPaper
                        .frame(width: width, height: height)
                        .shimmering()
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging { dragging = true }
                        split = (value.location.x / max(1, width)).clamped(to: 0...1)
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(reduceMotion ? nil : Motion.snappy, value: split > 0.16)
            .animation(reduceMotion ? nil : Motion.snappy, value: split < 0.84)
        }
        .accessibilityElement()
        .accessibilityLabel(tr("Vergleich Original und Rasterung"))
        .accessibilityValue(DesignerFormat.percent(Double(split)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(1, split + 0.1)
            case .decrement: split = max(0, split - 0.1)
            @unknown default: break
            }
        }
    }

    private var handle: some View {
        Circle()
            .fill(.regularMaterial)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 28, height: 28)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .scaleEffect(dragging ? 1.18 : 1)
            .animation(reduceMotion ? nil : Motion.bouncy, value: dragging)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Seitenleiste (PDF)

private struct DesignerPageThumbnail: View {
    let image: CGImage
    let number: Int
    let isSelected: Bool
    let isIncluded: Bool
    let namespace: Namespace.ID

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: 62, height: 74)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .opacity(isIncluded ? 1 : 0.55)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.brandGradient, lineWidth: 2.5)
                            .padding(-4)
                            .matchedGeometryEffect(id: "page", in: namespace)
                    }
                }
            Text(verbatim: String(number))
                .font(.system(size: 10.5, weight: isSelected ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
        }
        .padding(4)
        .scaleEffect(hovering ? 1.05 : 1)
        .animation(Motion.snappy, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityLabel(tr("Seite %d", number))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Grafik im Drucker speichern

private struct DesignerGraphicUploadForm: View {
    let session: PrinterSession?
    let bitmap: MonoBitmap?
    let suggestedName: String
    let reduceMotion: Bool
    let onDone: () -> Void

    @State private var name = ""
    @State private var drive = "E:"
    @State private var phase: DesignerSendPhase = .idle

    /// Objektnamen: 1–8 Zeichen A–Z/0–9.
    static func sanitize(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let folded = text.uppercased()
            .replacingOccurrences(of: "Ä", with: "AE")
            .replacingOccurrences(of: "Ö", with: "OE")
            .replacingOccurrences(of: "Ü", with: "UE")
            .replacingOccurrences(of: "ß", with: "SS")
        return String(folded.filter { allowed.contains($0) }.prefix(8))
    }

    private var recallCommand: String {
        "^FO0,0^XG\(drive)\(name.isEmpty ? "NAME" : name).GRF,1,1^FS"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(tr("Grafik im Drucker speichern"),
                          subtitle: tr("Wird als .GRF abgelegt und kann in jedem Etikett mit ^XG abgerufen werden."),
                          systemImage: "externaldrive.badge.plus")
            VStack(alignment: .leading, spacing: 4) {
                TextField(tr("Name"), text: $name, prompt: Text(verbatim: "LOGO"))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.code)
                    .onChange(of: name) { _, newValue in
                        let cleaned = Self.sanitize(newValue)
                        if cleaned != newValue { name = cleaned }
                    }
                Text(tr("1–8 Zeichen, A–Z und 0–9"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Picker(tr("Speicherort"), selection: $drive) {
                Text(tr("E: Flash – bleibt dauerhaft erhalten")).tag("E:")
                Text(tr("R: Arbeitsspeicher – bis zum Neustart")).tag("R:")
            }
            .pickerStyle(.radioGroup)
            if let bitmap {
                VStack(spacing: 2) {
                    KeyValueRow(tr("Größe"), tr("%d × %d Punkte", bitmap.width, bitmap.height))
                    KeyValueRow(tr("Speicherbedarf"), DesignerFormat.bytes(bitmap.data.count))
                    KeyValueRow(tr("Aufruf im Etikett"), recallCommand, monospaced: true, copyable: true)
                }
            }
            HStack {
                Spacer()
                Button(tr("Abbrechen"), action: onDone)
                    .buttonStyle(.labelWerkSecondary)
                    .keyboardShortcut(.cancelAction)
                DesignerSendButton(title: tr("Speichern"), systemImage: "arrow.down.to.line", phase: phase,
                                   reduceMotion: reduceMotion, action: { upload() })
                    .disabled(session == nil || bitmap == nil || name.isEmpty || phase == .sending)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            if name.isEmpty {
                let suggestion = Self.sanitize(suggestedName)
                name = suggestion.isEmpty ? "LOGO" : suggestion
            }
        }
    }

    private func upload() {
        guard let session, let bitmap, !name.isEmpty, phase != .sending else { return }
        let objectName = name
        let target = drive
        phase = .sending
        Task {
            let ok = await session.uploadGraphic(name: objectName, bitmap: bitmap, drive: target)
            phase = ok ? .success : .failure
            try? await Task.sleep(for: .seconds(1.3))
            if ok {
                onDone()
            } else {
                phase = .idle
            }
        }
    }
}

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// MARK: - Parameter

/// Alle Werte, die das Druckbild bestimmen (Auslöser für die Neuberechnung).
struct FilesGraphicParameters: Equatable, Sendable {
    var width: Int
    var height: Int
    var algorithm: DitherAlgorithm
    var threshold: Int
    var brightness: Double
    var contrast: Double
    var invert: Bool
}

enum FilesGraphicImport {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "heif", "pdf", "webp"]

    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }
}

// MARK: - Grafik-Upload

/// Ein Bild, das als 1-Bit-Grafik (.GRF) in den Drucker geladen wird.
@Observable
@MainActor
final class FilesGraphicUpload: Identifiable {
    let id = UUID()
    let url: URL
    /// Graustufen-Quelle (lange Seite höchstens 2400 Pixel).
    let source: GrayImage
    /// Pixelmaße der Originaldatei.
    let originalWidth: Int
    let originalHeight: Int
    let maxWidth: Int
    let maxHeight: Int

    var widthDots: Int
    var heightDots: Int
    var keepAspect = true
    var algorithm: DitherAlgorithm
    var threshold: Double = 128
    var brightness: Double = 0
    var contrast: Double = 0
    var invert = false
    var name = "LOGO"
    var drive: FilesDrive
    /// Position des Vergleichsreglers (0 = nur Druckbild, 1 = nur Original).
    var split: CGFloat = 0.5

    private(set) var preview: GrayImage?
    private(set) var bitmap: MonoBitmap?
    private(set) var isRendering = false
    private(set) var phase: FilesUploadPhase = .ready
    private(set) var successCount = 0
    @ObservationIgnored private var renderedParameters: FilesGraphicParameters?
    /// Zählt Rasterläufe; nur der jüngste darf `isRendering` zurücksetzen.
    @ObservationIgnored private var renderGeneration = 0

    private init(url: URL, source: GrayImage, originalWidth: Int, originalHeight: Int,
                 labelWidth: Int, labelHeight: Int, maxWidth: Int,
                 algorithm: DitherAlgorithm, drive: FilesDrive) {
        self.url = url
        self.source = source
        self.originalWidth = max(1, originalWidth)
        self.originalHeight = max(1, originalHeight)
        self.maxWidth = max(16, maxWidth)
        self.maxHeight = max(3000, labelHeight * 2)
        self.algorithm = algorithm
        self.drive = drive
        // Startgröße: Originalgröße, verkleinert auf 80 % × 60 % des Etiketts.
        let boxW = Double(max(16, Int(Double(labelWidth) * 0.8)))
        let boxH = Double(max(16, Int(Double(labelHeight) * 0.6)))
        let w = Double(max(1, originalWidth)), h = Double(max(1, originalHeight))
        let scale = min(1, min(boxW / w, boxH / h))
        self.widthDots = min(max(1, Int((w * scale).rounded())), max(16, maxWidth))
        self.heightDots = max(1, Int((h * scale).rounded()))
    }

    /// Lädt Bild oder PDF (erste Seite in Druckauflösung) und bereitet die Quelle vor.
    static func load(url: URL, dpi: Int, labelWidth: Int, labelHeight: Int, maxWidth: Int,
                     algorithm: DitherAlgorithm, drive: FilesDrive) async throws -> FilesGraphicUpload {
        let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (GrayImage, Int, Int) in
            guard let image = try ImageImport.pages(contentsOf: url, dpi: dpi, maxPages: 1).first else {
                throw ImageImport.ImportError.unreadable(url.lastPathComponent)
            }
            let longSide = Double(max(image.width, image.height, 1))
            let scale = min(1, 2400 / longSide)
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            let gray = ImageImport.grayImage(from: image, width: width, height: height, mode: .stretch)
            return (gray, image.width, image.height)
        }.value
        return FilesGraphicUpload(url: url, source: loaded.0, originalWidth: loaded.1, originalHeight: loaded.2,
                                  labelWidth: labelWidth, labelHeight: labelHeight, maxWidth: maxWidth,
                                  algorithm: algorithm, drive: drive)
    }

    // MARK: Abgeleitete Werte

    var parameters: FilesGraphicParameters {
        FilesGraphicParameters(width: widthDots, height: heightDots, algorithm: algorithm,
                               threshold: Int(threshold.rounded()), brightness: brightness,
                               contrast: contrast, invert: invert)
    }

    private var aspect: Double { Double(originalWidth) / Double(originalHeight) }

    var nameProblem: String? { FilesNaming.graphicNameProblem(name) }
    var fileName: String { name + ".GRF" }
    var path: String { FilesZPL.path(drive: drive.code, name: fileName) }
    /// Speicherbedarf im Drucker (unkomprimiert, 1 Bit je Punkt).
    var storedBytes: Int { ((widthDots + 7) / 8) * heightDots }
    var canUpload: Bool { nameProblem == nil && bitmap != nil && !phase.isUploading && !isRendering }

    var inkCoverage: Double? {
        guard let bitmap, bitmap.width > 0, bitmap.height > 0 else { return nil }
        return Double(bitmap.blackPixelCount) / Double(bitmap.width * bitmap.height)
    }

    // MARK: Größe

    func setWidth(_ value: Int) {
        widthDots = min(max(1, value), maxWidth)
        if keepAspect { heightDots = min(max(1, Int((Double(widthDots) / aspect).rounded())), maxHeight) }
        invalidateResult()
    }

    func setHeight(_ value: Int) {
        heightDots = min(max(1, value), maxHeight)
        if keepAspect { widthDots = min(max(1, Int((Double(heightDots) * aspect).rounded())), maxWidth) }
        invalidateResult()
    }

    /// Breite als Anteil der Etikettenbreite (Höhe folgt dem Seitenverhältnis).
    func fitWidth(fraction: Double, labelWidth: Int) {
        let target = max(1, Int((Double(labelWidth) * fraction).rounded()))
        let wasLocked = keepAspect
        keepAspect = true
        setWidth(target)
        keepAspect = wasLocked
    }

    func useOriginalSize() {
        let wasLocked = keepAspect
        keepAspect = true
        setWidth(originalWidth)
        keepAspect = wasLocked
    }

    func invalidateResult() {
        if case .failed = phase { phase = .ready }
        if case .done = phase { phase = .ready }
    }

    // MARK: Rastern

    func render(reduceMotion: Bool) async {
        renderGeneration += 1
        let generation = renderGeneration
        // Ein abgebrochener Lauf (z. B. Schwelle 128 → 129 → 128) darf die Anzeige nicht
        // im Zustand „wird berechnet“ zurücklassen: Der jüngste Lauf räumt immer auf.
        defer {
            if generation == renderGeneration, isRendering {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isRendering = false }
            }
        }
        let params = parameters
        if params == renderedParameters, bitmap != nil { return }
        // Geänderte Einstellungen machen ein früheres Übertragungsergebnis ungültig.
        if renderedParameters != nil, !phase.isUploading { invalidateResult() }
        let source = self.source
        if !isRendering { withAnimation(reduceMotion ? nil : Motion.snappy) { isRendering = true } }
        // Kurz warten: schnelle Reglerbewegungen fassen sich zu einer Berechnung zusammen.
        try? await Task.sleep(for: .milliseconds(70))
        guard !Task.isCancelled else { return }
        let output = await Task.detached(priority: .userInitiated) { () -> (GrayImage, MonoBitmap) in
            var gray = source.scaled(width: params.width, height: params.height)
            if params.brightness != 0 || params.contrast != 0 {
                gray = gray.adjusted(brightness: params.brightness, contrast: params.contrast)
            }
            var bitmap = Ditherer.dither(gray, algorithm: params.algorithm, threshold: params.threshold)
            if params.invert {
                bitmap = bitmap.inverted()
                gray = gray.inverted()
            }
            return (gray, bitmap)
        }.value
        guard !Task.isCancelled, generation == renderGeneration else { return }
        renderedParameters = params
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            preview = output.0
            bitmap = output.1
            isRendering = false
        }
    }

    // MARK: Übertragen

    func upload(session: PrinterSession, browser: FilesBrowserModel, reduceMotion: Bool) async {
        guard canUpload, let bitmap else { return }
        withAnimation(reduceMotion ? nil : Motion.spring) { phase = .uploading }
        session.stopMonitoring()
        let ok = await session.uploadGraphic(name: name, bitmap: bitmap, drive: drive.code)
        // Immer wieder aufnehmen: Die Überwachung verbindet auch eine fehlgeschlagene Sitzung neu.
        session.startMonitoring()
        withAnimation(reduceMotion ? nil : Motion.bouncy) {
            if ok {
                phase = .done(path)
                successCount += 1
            } else {
                phase = .failed(session.lastError ?? tr("Die Übertragung ist fehlgeschlagen."))
            }
        }
        if ok {
            if browser.drive == drive { await browser.load(session: session, reduceMotion: reduceMotion) }
            await browser.loadMemory(session: session, reduceMotion: reduceMotion)
        }
    }

    func printSample(session: PrinterSession) async {
        let zpl = FilesZPL.graphicSample(path: path,
                                         graphicWidth: bitmap?.width ?? widthDots,
                                         graphicHeight: bitmap?.height ?? heightDots,
                                         caption: tr("Grafik %@", path),
                                         widthDots: session.labelWidthDots,
                                         heightDots: session.labelHeightDots,
                                         dotsPerMM: session.resolution.dotsPerMM)
        await session.printZPL(zpl, title: tr("Grafikprobe %@", fileName))
    }
}

// MARK: - Ansicht

/// Karte zum Einpassen, Rastern und Übertragen einer Grafik mit Vorher/Nachher-Vergleich.
struct FilesGraphicComposer: View {
    @Bindable var upload: FilesGraphicUpload
    let session: PrinterSession
    let browser: FilesBrowserModel
    let reduceMotion: Bool
    let onClose: () -> Void

    init(upload: FilesGraphicUpload, session: PrinterSession, browser: FilesBrowserModel,
         reduceMotion: Bool, onClose: @escaping () -> Void) {
        self.upload = upload
        self.session = session
        self.browser = browser
        self.reduceMotion = reduceMotion
        self.onClose = onClose
    }

    var body: some View {
        GlassCard(padding: 18, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.teal) {
            VStack(alignment: .leading, spacing: 16) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        previewColumn
                            .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity)
                        controls
                            .frame(width: 310)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        previewColumn
                        controls
                    }
                }
            }
        }
        .task(id: upload.parameters) {
            await upload.render(reduceMotion: reduceMotion)
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                IconBadge(systemImage: upload.phase.isDone ? "checkmark" : "photo", tint: Theme.teal, size: 42)
                    .contentTransition(.symbolEffect(.replace))
                    .keyframeAnimator(initialValue: FilesBadgePop(), trigger: reduceMotion ? 0 : upload.successCount) { content, value in
                        content
                            .scaleEffect(value.scale)
                            .rotationEffect(.degrees(value.angle))
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.22, duration: 0.15)
                            SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                        }
                        KeyframeTrack(\.angle) {
                            CubicKeyframe(8, duration: 0.1)
                            CubicKeyframe(-6, duration: 0.14)
                            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                        }
                    }
                if !reduceMotion {
                    CelebrationBurst(trigger: upload.successCount, colors: [Theme.teal, Theme.violet, Theme.ready])
                        .frame(width: 220, height: 220)
                }
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Grafik übertragen"))
                    .font(Theme.Typography.headline)
                Text(tr("%@ · Original %d × %d Pixel", upload.url.lastPathComponent, upload.originalWidth, upload.originalHeight))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.labelWerkPlain)
            .disabled(upload.phase.isUploading)
            .help(tr("Schließen"))
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Vorschau

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.labelPaper)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                if let bitmap = upload.bitmap, let preview = upload.preview {
                    FilesCompareView(gray: preview, bitmap: bitmap, split: $upload.split, reduceMotion: reduceMotion)
                        .padding(14)
                        .transition(.opacity)
                } else {
                    ProgressRing(progress: nil, size: 30, lineWidth: 3.5)
                }
                if upload.isRendering && upload.bitmap != nil {
                    ProgressRing(progress: nil, size: 18, lineWidth: 2.5)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 220, maxHeight: 360)
            .animation(reduceMotion ? nil : Motion.snappy, value: upload.isRendering)

            HStack(spacing: 6) {
                TransferChip(tr("%d × %d Punkte", upload.widthDots, upload.heightDots), systemImage: "squareshape.split.2x2.dotted", tint: Theme.teal)
                    .contentTransition(.numericText())
                TransferChip(tr("%.1f × %.1f mm", session.resolution.mm(fromDots: upload.widthDots),
                                session.resolution.mm(fromDots: upload.heightDots)),
                             systemImage: "ruler", tint: Theme.printing)
                TransferChip(TransferFormat.bytes(upload.storedBytes), systemImage: "internaldrive", tint: Theme.violet)
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: upload.parameters)

            if let bitmap = upload.bitmap, bitmap.isBlank {
                TransferNote(tr("Das Druckbild ist leer – Schwelle oder Helligkeit anpassen."), style: .warning)
            } else if let coverage = upload.inkCoverage, coverage > 0.55 {
                TransferNote(tr("Sehr hoher Schwarzanteil (%@) – erhöht Verschleiß des Druckkopfs. „Umkehren“ oder eine hellere Einstellung prüfen.",
                                TransferFormat.percent(coverage)), style: .warning)
            }
            if upload.widthDots > session.labelWidthDots {
                TransferNote(tr("Breiter als das Etikett (%d Punkte) – beim Druck wird rechts abgeschnitten.", session.labelWidthDots), style: .info)
            }
        }
    }

    // MARK: Einstellungen

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Während der Übertragung fest: Das gesendete Druckbild soll dem angezeigten entsprechen.
            sizeSection
                .disabled(upload.phase.isUploading)
            Divider().opacity(0.5)
            ditherSection
                .disabled(upload.phase.isUploading)
            Divider().opacity(0.5)
            targetSection
            actionArea
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Größe im Druck"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            NumberStepperField(title: tr("Breite"),
                               value: Binding(get: { upload.widthDots }, set: { upload.setWidth($0) }),
                               range: 1...upload.maxWidth, step: 8, unit: tr("Punkte"))
            NumberStepperField(title: tr("Höhe"),
                               value: Binding(get: { upload.heightDots }, set: { upload.setHeight($0) }),
                               range: 1...upload.maxHeight, step: 8, unit: tr("Punkte"))
            HStack(spacing: 6) {
                Toggle(isOn: $upload.keepAspect) {
                    Label(tr("Seitenverhältnis"), systemImage: upload.keepAspect ? "link" : "link.badge.plus")
                        .font(.system(size: 12))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer(minLength: 4)
                Menu {
                    Button(tr("Originalgröße (1 Pixel = 1 Punkt)")) { upload.useOriginalSize() }
                    Button(tr("Ein Viertel der Etikettenbreite")) { upload.fitWidth(fraction: 0.25, labelWidth: session.labelWidthDots) }
                    Button(tr("Halbe Etikettenbreite")) { upload.fitWidth(fraction: 0.5, labelWidth: session.labelWidthDots) }
                    Button(tr("Volle Etikettenbreite")) { upload.fitWidth(fraction: 1, labelWidth: session.labelWidthDots) }
                } label: {
                    Label(tr("Schnellwahl"), systemImage: "wand.and.stars")
                        .font(.system(size: 12))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }

    private var ditherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Rasterung"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker(tr("Verfahren"), selection: $upload.algorithm) {
                ForEach(DitherAlgorithm.allCases) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            sliderRow(title: tr("Schwelle"), value: $upload.threshold, range: 1...254,
                      display: "\(Int(upload.threshold.rounded()))")
            sliderRow(title: tr("Helligkeit"), value: $upload.brightness, range: -0.6...0.6,
                      display: upload.brightness.formatted(.number.precision(.fractionLength(2))))
            sliderRow(title: tr("Kontrast"), value: $upload.contrast, range: -0.6...0.6,
                      display: upload.contrast.formatted(.number.precision(.fractionLength(2))))
            Toggle(tr("Umkehren (weiß auf schwarz)"), isOn: $upload.invert)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5))
        }
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
            Text(verbatim: display)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { upload.name },
            set: { newValue in
                let cleaned = FilesNaming.normalizedInput(FilesNaming.stripGraphicExtension(newValue), keepDot: false)
                upload.name = String(cleaned.prefix(8))
                upload.invalidateResult()
            }
        )
    }

    private var willOverwrite: Bool {
        browser.drive == upload.drive && browser.contains(name: upload.fileName)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Speichern als"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(Self.namePlaceholder, text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.code)
                    .disabled(upload.phase.isUploading)
                Text(verbatim: ".GRF")
                    .font(Theme.Typography.code)
                    .foregroundStyle(.secondary)
            }
            if let problem = upload.nameProblem {
                TransferNote(problem, style: .error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if willOverwrite {
                TransferNote(tr("Eine vorhandene Grafik mit diesem Namen wird ersetzt."), style: .warning)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Picker(tr("Ziel"), selection: $upload.drive) {
                ForEach(FilesDrive.writable) { drive in
                    Text(drive.shortTitle).tag(drive)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(upload.phase.isUploading)
            if let free = browser.memory[upload.drive]?.free, Int64(upload.storedBytes) > free {
                TransferNote(tr("Die Grafik ist größer als der freie Speicher auf diesem Laufwerk."), style: .error)
            }
            KeyValueRow(tr("ZPL-Verweis"), FilesZPL.reference(path: upload.path, category: .graphic, fontHeight: 0),
                        monospaced: true, copyable: true)
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: upload.nameProblem)
        .animation(reduceMotion ? nil : Motion.snappy, value: willOverwrite)
    }

    private static let namePlaceholder = "LOGO"

    @ViewBuilder
    private var actionArea: some View {
        switch upload.phase {
        case .uploading:
            HStack(spacing: 10) {
                ProgressRing(progress: session.progress, size: 22, lineWidth: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Grafik wird übertragen …"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(TransferFormat.bytes(upload.storedBytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        case .done(let path):
            VStack(alignment: .leading, spacing: 10) {
                TransferNote(tr("Gespeichert als %@", path), style: .success)
                HStack(spacing: 8) {
                    Button {
                        Task { await upload.printSample(session: session) }
                    } label: {
                        Label(tr("Probedruck"), systemImage: "printer.dotmatrix.filled.and.paper")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .disabled(session.isBusy)
                    Button {
                        Task { await upload.upload(session: session, browser: browser, reduceMotion: reduceMotion) }
                    } label: {
                        Label(tr("Erneut"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.labelWerkSecondary)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .ready, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let message) = upload.phase {
                    TransferNote(message, style: .error)
                }
                Button {
                    Task { await upload.upload(session: session, browser: browser, reduceMotion: reduceMotion) }
                } label: {
                    Label(tr("In den Drucker übertragen"), systemImage: "arrow.up.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.large)
                .disabled(!upload.canUpload || session.isBusy)
                .keyboardShortcut(.defaultAction)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Vorher/Nachher

/// Graustufenbild und Druckbild übereinander; ein Regler zeigt links das Original, rechts das Druckbild.
private struct FilesCompareView: View {
    let gray: GrayImage
    let bitmap: MonoBitmap
    @Binding var split: CGFloat
    let reduceMotion: Bool

    @State private var dragging = false

    var body: some View {
        let aspect = CGFloat(max(1, bitmap.width)) / CGFloat(max(1, bitmap.height))
        ZStack {
            BitmapPreview(bitmap: bitmap)
            GrayImagePreview(image: gray)
                .mask(alignment: .leading) {
                    GeometryReader { proxy in
                        Rectangle()
                            .frame(width: max(0, proxy.size.width * split))
                    }
                }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay {
            GeometryReader { proxy in
                let x = proxy.size.width * split
                ZStack {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2, height: proxy.size.height)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: dragging ? 30 : 24, height: dragging ? 30 : 24)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: Theme.accent.opacity(0.45), radius: 6, y: 2)
                }
                .position(x: x, y: proxy.size.height / 2)
                .animation(reduceMotion ? nil : Motion.snappy, value: dragging)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging = true
                                let width = max(1, proxy.size.width)
                                split = (value.location.x / width).clamped(to: 0...1)
                            }
                            .onEnded { _ in dragging = false }
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            compareTag(tr("Original"))
                .opacity(split > 0.12 ? 1 : 0)
                .animation(reduceMotion ? nil : Motion.snappy, value: split > 0.12)
                .padding(6)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            compareTag(tr("Druckbild"))
                .opacity(split < 0.88 ? 1 : 0)
                .animation(reduceMotion ? nil : Motion.snappy, value: split < 0.88)
                .padding(6)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Vergleich Original und Druckbild"))
        .accessibilityValue(TransferFormat.percent(Double(split)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(1, split + 0.1)
            case .decrement: split = max(0, split - 0.1)
            @unknown default: break
            }
        }
    }

    private func compareTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(Color.black.opacity(0.55))
            }
    }
}

import AppKit
import CoreText
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// MARK: - Upload-Zustand

/// Ablauf einer Übertragung (Schrift oder Grafik).
enum FilesUploadPhase: Equatable {
    case ready
    case uploading
    case done(String)
    case failed(String)

    var isUploading: Bool { self == .uploading }

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

// MARK: - Schriftanalyse

/// Geprüfte Metadaten einer Schriftdatei.
struct FilesFontInfo {
    enum Outline: Equatable { case trueType, postScript }

    let descriptor: CTFontDescriptor
    let familyName: String
    let fullName: String
    let styleName: String?
    let version: String?
    let glyphCount: Int
    let outline: Outline
    /// Zeichen aus „ÄÖÜäöüß€“, die der Schrift fehlen.
    let missingGermanCharacters: String
    let fileSize: Int

    /// SwiftUI-Schrift aus der Datei in der gewünschten Größe.
    func font(size: CGFloat) -> Font {
        Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}

enum FilesFontError: LocalizedError {
    case empty
    case collection
    case webFont
    case unknownFormat
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return tr("Die Datei ist leer.")
        case .collection:
            return tr("Schriftsammlungen (.ttc) werden vom Drucker nicht unterstützt. Bitte eine einzelne .ttf- oder .otf-Datei wählen.")
        case .webFont:
            return tr("Web-Schriften (WOFF/WOFF2) werden nicht unterstützt. Bitte eine .ttf- oder .otf-Datei wählen.")
        case .unknownFormat:
            return tr("Die Datei ist keine TrueType- oder OpenType-Schrift.")
        case .unreadable(let name):
            return tr("„%@“ konnte nicht als Schrift gelesen werden.", name)
        }
    }
}

enum FilesFontInspector {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2", "dfont", "tte"]

    static var openPanelTypes: [UTType] {
        [UTType.font] + ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
    }

    /// Prüft Kennung, Konturen und Zeichenvorrat der Schrift.
    static func inspect(url: URL, data: Data) throws -> FilesFontInfo {
        guard data.count >= 12 else { throw FilesFontError.empty }
        let magic = [UInt8](data.prefix(4))
        let outline: FilesFontInfo.Outline
        switch magic {
        case [0x00, 0x01, 0x00, 0x00], [0x74, 0x72, 0x75, 0x65]:   // 1.0 bzw. „true“
            outline = .trueType
        case [0x4F, 0x54, 0x54, 0x4F]:                               // „OTTO“
            outline = .postScript
        case [0x74, 0x74, 0x63, 0x66]:                               // „ttcf“
            throw FilesFontError.collection
        case [0x77, 0x4F, 0x46, 0x46], [0x77, 0x4F, 0x46, 0x32]:     // „wOFF“ / „wOF2“
            throw FilesFontError.webFont
        default:
            throw FilesFontError.unknownFormat
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first
        else { throw FilesFontError.unreadable(url.lastPathComponent) }

        let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
        let family = CTFontCopyFamilyName(font) as String
        let fullName = CTFontCopyFullName(font) as String
        let style = CTFontCopyName(font, kCTFontStyleNameKey).map { $0 as String }
        let version = CTFontCopyName(font, kCTFontVersionNameKey).map { $0 as String }
        let characterSet = CTFontCopyCharacterSet(font) as NSCharacterSet as CharacterSet
        let missing = String("ÄÖÜäöüß€".filter { character in
            !character.unicodeScalars.allSatisfy { characterSet.contains($0) }
        })
        return FilesFontInfo(descriptor: descriptor, familyName: family, fullName: fullName,
                             styleName: style, version: version, glyphCount: CTFontGetGlyphCount(font),
                             outline: outline, missingGermanCharacters: missing, fileSize: data.count)
    }
}

// MARK: - Schrift-Upload

/// Eine zum Hochladen vorbereitete Schrift (Name, Ziel, Probetext, Übertragung).
@Observable
@MainActor
final class FilesFontUpload: Identifiable {
    let id = UUID()
    let url: URL
    let data: Data
    let info: FilesFontInfo
    var name: String
    var drive: FilesDrive
    var sampleText: String = tr("Etikettendruck mit LabelWerk – ÄÖÜ äöü ß € 0123456789")
    private(set) var phase: FilesUploadPhase = .ready
    private(set) var successCount = 0

    init(url: URL, data: Data, info: FilesFontInfo, drive: FilesDrive) {
        self.url = url
        self.data = data
        self.info = info
        self.drive = drive
        self.name = FilesNaming.fontName(for: url, isOpenType: url.pathExtension.lowercased() == "otf")
    }

    static func load(url: URL, defaultDrive: FilesDrive) async throws -> FilesFontUpload {
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        let info = try FilesFontInspector.inspect(url: url, data: data)
        return FilesFontUpload(url: url, data: data, info: info, drive: defaultDrive)
    }

    var nameProblem: String? { FilesNaming.fontNameProblem(name) }
    var path: String { FilesZPL.path(drive: drive.code, name: name) }
    var canUpload: Bool { nameProblem == nil && !phase.isUploading }

    /// Hinweis für Namen mit mehr als 8 Zeichen (ältere Firmware).
    var longNameHint: String? {
        guard nameProblem == nil, let base = name.split(separator: ".").first, base.count > 8 else { return nil }
        return tr("Ältere Firmware akzeptiert nur 8 Zeichen vor der Endung.")
    }

    func upload(session: PrinterSession, browser: FilesBrowserModel, reduceMotion: Bool) async {
        guard canUpload else { return }
        withAnimation(reduceMotion ? nil : Motion.spring) { phase = .uploading }
        // Statusabfragen pausieren, damit sie die Binärdaten nicht unterbrechen.
        session.stopMonitoring()
        let ok = await session.uploadFont(name: name, data: data, drive: drive.code)
        if session.connectionState.isConnected { session.startMonitoring() }
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
            await browser.loadMemory(session: session)
        }
    }

    func resetPhase() {
        phase = .ready
    }

    func printSample(session: PrinterSession) async {
        let zpl = FilesZPL.fontSample(path: path,
                                      title: tr("Schriftprobe: %@ · %@", info.fullName, path),
                                      sample: sampleText,
                                      widthDots: session.labelWidthDots,
                                      heightDots: session.labelHeightDots,
                                      dotsPerMM: session.resolution.dotsPerMM)
        await session.printZPL(zpl, title: tr("Schriftprobe %@", name))
    }
}

// MARK: - Ansicht

/// Karte zum Prüfen, Benennen und Übertragen einer Schrift mit Live-Schriftprobe.
struct FilesFontComposer: View {
    @Bindable var upload: FilesFontUpload
    let session: PrinterSession
    let browser: FilesBrowserModel
    let reduceMotion: Bool
    let onClose: () -> Void

    @State private var appeared = false

    private static let namePlaceholder = "ARIAL.TTF"

    init(upload: FilesFontUpload, session: PrinterSession, browser: FilesBrowserModel,
         reduceMotion: Bool, onClose: @escaping () -> Void) {
        self.upload = upload
        self.session = session
        self.browser = browser
        self.reduceMotion = reduceMotion
        self.onClose = onClose
    }

    var body: some View {
        GlassCard(padding: 18, cornerRadius: Theme.Metrics.cornerLarge, tint: Theme.violet) {
            VStack(alignment: .leading, spacing: 16) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        specimen
                            .frame(minWidth: 340, idealWidth: 440, maxWidth: .infinity)
                        form
                            .frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        specimen
                        form
                    }
                }
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : Motion.spring.delay(0.05)) { appeared = true }
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                IconBadge(systemImage: upload.phase.isDone ? "checkmark" : "textformat", tint: Theme.violet, size: 42)
                    .contentTransition(.symbolEffect(.replace))
                    .keyframeAnimator(initialValue: FilesBadgePop(), trigger: upload.successCount) { content, value in
                        content
                            .scaleEffect(value.scale)
                            .rotationEffect(.degrees(value.angle))
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.22, duration: 0.15)
                            SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                        }
                        KeyframeTrack(\.angle) {
                            CubicKeyframe(-9, duration: 0.1)
                            CubicKeyframe(7, duration: 0.14)
                            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                        }
                    }
                CelebrationBurst(trigger: upload.successCount, colors: [Theme.violet, Theme.magenta, Theme.teal])
                    .frame(width: 220, height: 220)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Schriftart übertragen"))
                    .font(Theme.Typography.headline)
                Text(verbatim: upload.url.lastPathComponent)
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

    // MARK: Schriftprobe

    private var sampleSizes: [CGFloat] { [44, 28, 17] }

    private var specimen: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: upload.info.familyName)
                    .font(upload.info.font(size: 24))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let style = upload.info.styleName, !style.isEmpty {
                    Text(verbatim: style)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.labelInk.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(Theme.labelInk.opacity(0.12))
                .frame(height: 1)
            ForEach(Array(sampleSizes.enumerated()), id: \.offset) { index, size in
                Text(verbatim: upload.sampleText.isEmpty ? upload.info.fullName : upload.sampleText)
                    .font(upload.info.font(size: size))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : -16)
                    .animation(reduceMotion ? nil : Motion.spring.delay(0.08 * Double(index)), value: appeared)
            }
            Text(verbatim: "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 ÄÖÜ äöü ß € & @ % ? ! ( )")
                .font(upload.info.font(size: 15))
                .foregroundStyle(Theme.labelInk.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(Theme.labelInk.opacity(0.45))
                TextField(tr("Eigener Probetext"), text: $upload.sampleText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.labelInk)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.labelInk.opacity(0.05))
            }
            chips
        }
        .foregroundStyle(Theme.labelInk)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.labelPaper)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.6)
        }
        .environment(\.colorScheme, .light)
    }

    private var chips: some View {
        let info = upload.info
        return HStack(spacing: 6) {
            if info.outline == .trueType {
                TransferChip(tr("TrueType-Konturen"), systemImage: "checkmark.seal.fill", tint: Theme.ready)
            } else {
                TransferChip(tr("PostScript-Konturen (CFF)"), systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                    .help(tr("Viele Zebra-Firmwares unterstützen nur TrueType-Konturen. Bei Problemen eine .ttf-Version der Schrift verwenden."))
            }
            if info.missingGermanCharacters.isEmpty {
                TransferChip(tr("Umlaute & €"), systemImage: "checkmark", tint: Theme.ready)
            } else {
                TransferChip(tr("Fehlt: %@", info.missingGermanCharacters), systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
            }
            TransferChip(tr("%d Glyphen", info.glyphCount), systemImage: "character", tint: Theme.printing)
        }
    }

    // MARK: Formular

    private var nameBinding: Binding<String> {
        Binding(
            get: { upload.name },
            set: { newValue in
                upload.name = FilesNaming.normalizedInput(newValue, keepDot: true)
                if case .failed = upload.phase { upload.resetPhase() }
            }
        )
    }

    private var willOverwrite: Bool {
        browser.drive == upload.drive && browser.contains(name: upload.name)
    }

    private var freeBytes: Int64? { browser.memory[upload.drive]?.free }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Name im Drucker"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(Self.namePlaceholder, text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.code)
                    .disabled(upload.phase.isUploading)
                if let problem = upload.nameProblem {
                    TransferNote(problem, style: .error)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let hint = upload.longNameHint {
                    TransferNote(hint, style: .info)
                        .transition(.opacity)
                }
                if willOverwrite {
                    TransferNote(tr("Eine vorhandene Datei mit diesem Namen wird ersetzt."), style: .warning)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: upload.nameProblem)
            .animation(reduceMotion ? nil : Motion.snappy, value: willOverwrite)

            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Ziel"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker(tr("Ziel"), selection: $upload.drive) {
                    ForEach(FilesDrive.writable) { drive in
                        Text(drive.shortTitle).tag(drive)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(upload.phase.isUploading)
                if upload.drive == .ram {
                    TransferNote(tr("Im RAM gespeicherte Schriften gehen beim Ausschalten verloren."), style: .info)
                }
            }

            VStack(spacing: 0) {
                KeyValueRow(tr("Dateigröße"), TransferFormat.bytes(upload.info.fileSize))
                if let freeBytes {
                    KeyValueRow(tr("Frei auf dem Ziel"), TransferFormat.bytes64(freeBytes))
                }
                if let version = upload.info.version, !version.isEmpty {
                    KeyValueRow(tr("Version"), version)
                }
                KeyValueRow(tr("ZPL-Verweis"), FilesZPL.reference(path: upload.path, category: .font,
                                                                  fontHeight: session.resolution.dotsPerMM * 5),
                            monospaced: true, copyable: true)
            }
            if let freeBytes, Int64(upload.info.fileSize) > freeBytes {
                TransferNote(tr("Die Schrift ist größer als der freie Speicher auf diesem Laufwerk."), style: .error)
            }

            actionArea
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch upload.phase {
        case .uploading:
            HStack(spacing: 10) {
                ProgressRing(progress: session.progress, size: 22, lineWidth: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Schrift wird übertragen …"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(TransferFormat.bytes(upload.info.fileSize))
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

/// Werte für die „Erfolgs-Hüpf“-Animation der Symbole.
struct FilesBadgePop {
    var scale: CGFloat = 1
    var angle: Double = 0
}

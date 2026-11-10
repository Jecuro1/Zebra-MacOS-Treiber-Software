import CryptoKit
import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Dateiarten

enum FirmwareFileKind: String, Sendable, Equatable {
    case zpl, nrd, hex, other

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "zpl": self = .zpl
        case "nrd": self = .nrd
        case "hex": self = .hex
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .zpl: return tr("Zebra-Firmwarepaket (.zpl)")
        case .nrd: return tr("Firmware-Datei (.nrd)")
        case .hex: return tr("Hex-Firmware (.hex)")
        case .other: return tr("Unbekannter Dateityp")
        }
    }

    var systemImage: String {
        switch self {
        case .zpl: return "shippingbox.fill"
        case .nrd: return "lock.doc.fill"
        case .hex: return "number.square.fill"
        case .other: return "questionmark.folder.fill"
        }
    }
}

// MARK: - Version

/// Zebra-Firmwareversion wie „V84.20.18Z“ (Linie 84, Version 20.18).
struct FirmwareVersion: Equatable, Comparable, Sendable {
    let raw: String
    let components: [Int]

    /// Erste Linie (z. B. 84) – unterschiedliche Linien gehören zu unterschiedlichen Plattformen.
    var line: Int? { components.first }

    static let pattern = #"(?<![A-Za-z0-9])V\d{2,3}\.\d{1,2}\.\d{1,2}[A-Za-z]{0,2}"#

    init?(_ text: String?) {
        guard let text, let match = FirmwareAnalyzer.firstMatch(Self.pattern, in: text) else { return nil }
        raw = match
        components = match.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard components.count >= 3 else { return nil }
    }

    static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        for (a, b) in zip(lhs.components, rhs.components) where a != b { return a < b }
        if lhs.components.count != rhs.components.count { return lhs.components.count < rhs.components.count }
        return lhs.raw.uppercased() < rhs.raw.uppercased()
    }

    static func == (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        lhs.components == rhs.components
    }
}

// MARK: - Dateianalyse

/// Ergebnis der Prüfung einer Firmware-Datei.
struct FirmwareFileInfo: Equatable, Sendable {
    let url: URL
    let fileName: String
    let size: Int
    let sha256: String
    let kind: FirmwareFileKind
    let versionHint: String?
    /// Woher die Version stammt (Dateiname, „appl.name“, Inhalt).
    let versionSource: String?
    let modelHints: [String]
    let looksLikeLabelFormat: Bool
    let modified: Date?
}

enum FirmwareAnalyzerError: LocalizedError {
    case empty(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .empty(let name): return tr("„%@“ ist leer.", name)
        case .unreadable(let name): return tr("„%@“ konnte nicht gelesen werden.", name)
        }
    }
}

enum FirmwareAnalyzer {
    /// Nur der Anfang der Datei wird nach Versions- und Modellangaben durchsucht.
    static let scanLimit = 64 * 1024

    static let modelPattern = #"(?<![A-Za-z0-9])(Z[DTQRCMEB][0-9]{3}|G[KXT][0-9]{3}|QLn[0-9]{3}|ZM[0-9]{3}|ZE[0-9]{3}|T?LP[0-9]{4}|105SL|110Xi4|220Xi4|ZXP[0-9])(?![0-9])"#
    static let applNamePattern = #"appl\.name["']?\s*[:=]?\s*["']?\s*([A-Za-z0-9][A-Za-z0-9._-]{3,31})"#

    /// Liest die Datei vollständig, berechnet SHA-256 und sucht Versions- und Modellhinweise.
    static func analyze(url: URL) throws -> (FirmwareFileInfo, Data) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FirmwareAnalyzerError.unreadable(url.lastPathComponent)
        }
        guard !data.isEmpty else { throw FirmwareAnalyzerError.empty(url.lastPathComponent) }

        let digest = SHA256.hash(data: data)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        let head = data.prefix(scanLimit)
        let text = String(data: head, encoding: .isoLatin1) ?? String(decoding: head, as: UTF8.self)

        var version: String?
        var source: String?
        if let fromName = FirmwareVersion(url.lastPathComponent) {
            version = fromName.raw
            source = tr("Dateiname")
        } else if let appl = firstMatch(applNamePattern, in: text, group: 1), let parsed = FirmwareVersion(appl) {
            version = parsed.raw
            source = tr("Eintrag „appl.name“")
        } else if let fromContent = FirmwareVersion(text) {
            version = fromContent.raw
            source = tr("Dateiinhalt")
        }

        var models: [String] = []
        for token in allMatches(modelPattern, in: url.lastPathComponent + "\n" + text, group: 1) {
            let upper = token.uppercased()
            if !models.contains(upper) { models.append(upper) }
            if models.count >= 6 { break }
        }

        let looksLikeLabel = data.count < 512 * 1024 && version == nil
            && text.contains("^XA") && text.contains("^XZ") && !text.contains("~DY")
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let info = FirmwareFileInfo(url: url, fileName: url.lastPathComponent, size: data.count, sha256: sha,
                                    kind: FirmwareFileKind(fileExtension: url.pathExtension),
                                    versionHint: version, versionSource: source, modelHints: models,
                                    looksLikeLabelFormat: looksLikeLabel, modified: modified)
        return (info, data)
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), group < match.numberOfRanges,
              let swiftRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[swiftRange])
    }

    static func allMatches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard group < match.numberOfRanges, let swiftRange = Range(match.range(at: group), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    /// Modellkennung wie „ZD421“ aus „ZD421t“, „ZD421-203dpi“ oder „Zebra ZT411“.
    static func modelToken(_ text: String?) -> String? {
        guard let text else { return nil }
        return firstMatch(modelPattern, in: text, group: 1)?.uppercased()
    }

    /// Prüfsummen-Eingabe vereinheitlichen (Kleinbuchstaben, ohne Leer- und Trennzeichen).
    static func normalizedChecksum(_ text: String) -> String {
        text.lowercased().filter { $0.isHexDigit }
    }
}

// MARK: - Bewertung

struct FirmwareAssessmentItem: Identifiable, Equatable {
    enum Level: Int, Equatable, Comparable {
        case good, info, warning, blocking
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let level: Level
    let text: String

    var systemImage: String {
        switch level {
        case .good: return "checkmark.seal.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch level {
        case .good: return Theme.ready
        case .info: return Theme.printing
        case .warning: return Theme.warning
        case .blocking: return Theme.error
        }
    }
}

enum FirmwareCompatibility {
    /// Prüft Datei, Version, Modell und (optional) die erwartete Prüfsumme.
    static func assess(file: FirmwareFileInfo, installedFirmware: String?, printerModelNames: [String],
                       expectedChecksum: String) -> [FirmwareAssessmentItem] {
        var items: [FirmwareAssessmentItem] = []

        if file.looksLikeLabelFormat {
            items.append(.init(id: "label", level: .warning,
                               text: tr("Die Datei sieht wie ein Etikettenformat aus, nicht wie Firmware.")))
        }
        if file.kind == .other {
            items.append(.init(id: "kind", level: .warning,
                               text: tr("Unbekannter Dateityp – nur fortfahren, wenn die Datei direkt von Zebra stammt.")))
        } else if file.size < 64 * 1024 {
            items.append(.init(id: "size", level: .warning,
                               text: tr("Ungewöhnlich klein für eine Firmware (%@).", TransferFormat.bytes(file.size))))
        }

        let fileVersion = FirmwareVersion(file.versionHint)
        let installed = FirmwareVersion(installedFirmware)
        if let fileVersion {
            if let installed {
                if fileVersion.line != installed.line {
                    items.append(.init(id: "line", level: .warning,
                                       text: tr("Andere Firmware-Linie (V%d statt V%d) – prüfen, ob die Datei für dieses Modell bestimmt ist.",
                                                fileVersion.line ?? 0, installed.line ?? 0)))
                } else {
                    items.append(.init(id: "line", level: .good,
                                       text: tr("Passt zur installierten Firmware-Linie V%d.", installed.line ?? 0)))
                }
                if fileVersion > installed {
                    items.append(.init(id: "compare", level: .good,
                                       text: tr("Neuer als die installierte Version %@.", installed.raw)))
                } else if fileVersion == installed {
                    items.append(.init(id: "compare", level: .info,
                                       text: tr("Diese Version ist bereits installiert – die Übertragung installiert sie erneut.")))
                } else {
                    items.append(.init(id: "compare", level: .warning,
                                       text: tr("Älter als die installierte Version %@ (Downgrade).", installed.raw)))
                }
            } else {
                items.append(.init(id: "compare", level: .info,
                                   text: tr("Installierte Version unbekannt – Vergleich nicht möglich.")))
            }
        } else {
            items.append(.init(id: "version", level: .info,
                               text: tr("Keine Versionsangabe in der Datei gefunden.")))
        }

        let printerTokens = Set(printerModelNames.compactMap { FirmwareAnalyzer.modelToken($0) })
        if !file.modelHints.isEmpty {
            if let match = file.modelHints.first(where: { printerTokens.contains($0) }) {
                items.append(.init(id: "model", level: .good, text: tr("Für %@ gekennzeichnet.", match)))
            } else if !printerTokens.isEmpty {
                items.append(.init(id: "model", level: .warning,
                                   text: tr("Die Datei nennt andere Modelle: %@.", file.modelHints.joined(separator: ", "))))
            }
        }

        let expected = FirmwareAnalyzer.normalizedChecksum(expectedChecksum)
        if !expected.isEmpty {
            if expected == file.sha256 {
                items.append(.init(id: "checksum", level: .good, text: tr("SHA-256-Prüfsumme stimmt überein.")))
            } else if expected.count < 64 {
                items.append(.init(id: "checksum", level: .info,
                                   text: tr("Die erwartete Prüfsumme ist unvollständig (%d von 64 Zeichen).", expected.count)))
            } else {
                items.append(.init(id: "checksum", level: .blocking,
                                   text: tr("Prüfsumme stimmt nicht überein – die Datei ist beschädigt oder nicht die erwartete.")))
            }
        }
        return items.sorted { $0.level > $1.level }
    }
}

// MARK: - Checkliste

enum FirmwareChecklistItem: String, CaseIterable, Identifiable, Hashable {
    case power, idle, correctFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: return tr("Der Drucker hängt am Netzteil")
        case .idle: return tr("Es laufen keine Druckaufträge")
        case .correctFile: return tr("Die Firmware ist für dieses Modell bestimmt")
        }
    }

    var detail: String {
        switch self {
        case .power: return tr("Nicht im Akkubetrieb, Stromkabel gesichert – ein Ausfall kann den Drucker unbrauchbar machen.")
        case .idle: return tr("Niemand sonst druckt; der Drucker wird während des Updates nicht bedient.")
        case .correctFile: return tr("Heruntergeladen von zebra.com für genau dieses Modell.")
        }
    }

    var systemImage: String {
        switch self {
        case .power: return "powerplug.fill"
        case .idle: return "tray.fill"
        case .correctFile: return "checkmark.shield.fill"
        }
    }
}

// MARK: - Ablauf

enum FirmwarePhase: Equatable {
    case idle
    case analyzing(String)
    case ready
    case transferring
    case rebooting(start: Date, until: Date)
    case reconnecting(attempt: Int, of: Int)
    case completed(String?)
    case transferFailed(String)
    case reconnectFailed
}

struct FirmwareReconnectAttempt: Identifiable, Equatable {
    let id: Int
    let date: Date
    let success: Bool
    let message: String?
}

/// Steuert ein Firmware-Update eines Druckers. Eine Instanz je Drucker, damit Fortschritt und
/// Wiederverbindung weiterlaufen, auch wenn der Bereich gewechselt wird.
@Observable
@MainActor
final class FirmwareUpdateController {
    let printerID: UUID
    private(set) var phase: FirmwarePhase = .idle
    private(set) var file: FirmwareFileInfo?
    private(set) var analysisError: String?
    var expectedChecksum = ""
    private(set) var checklist: Set<FirmwareChecklistItem> = []
    private(set) var progress: Double = 0
    private(set) var bytesPerSecond: Double?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var previousFirmware: String?
    private(set) var reconnectLog: [FirmwareReconnectAttempt] = []
    /// Erhöht sich bei Erfolgen (Partikel-Animation).
    private(set) var celebration = 0

    @ObservationIgnored private var data: Data?
    @ObservationIgnored private var samples: [(date: Date, value: Double)] = []
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var samplerTask: Task<Void, Never>?
    @ObservationIgnored private var keepAwakeToken: NSObjectProtocol?

    private static var registry: [UUID: FirmwareUpdateController] = [:]

    static func shared(for session: PrinterSession) -> FirmwareUpdateController {
        if let existing = registry[session.id] { return existing }
        let controller = FirmwareUpdateController(printerID: session.id)
        registry[session.id] = controller
        return controller
    }

    private init(printerID: UUID) {
        self.printerID = printerID
    }

    // MARK: Zustand

    var isBusy: Bool {
        switch phase {
        case .transferring, .rebooting, .reconnecting: return true
        default: return false
        }
    }

    var isAnalyzing: Bool {
        if case .analyzing = phase { return true }
        return false
    }

    var canChooseFile: Bool { !isBusy && !isAnalyzing }
    var checklistComplete: Bool { checklist.count == FirmwareChecklistItem.allCases.count }
    var transferredBytes: Int { Int(Double(file?.size ?? 0) * min(1, max(0, progress))) }

    /// Verbleibende Zeit aus der geglätteten Übertragungsrate.
    var estimatedRemaining: TimeInterval? {
        guard let rate = bytesPerSecond, rate > 1, let size = file?.size else { return nil }
        return Double(size) * (1 - min(1, progress)) / rate
    }

    var transferDuration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    func toggle(_ item: FirmwareChecklistItem) {
        if checklist.contains(item) {
            checklist.remove(item)
        } else {
            checklist.insert(item)
        }
    }

    // MARK: Datei

    func load(url: URL, reduceMotion: Bool) {
        guard canChooseFile else { return }
        workTask?.cancel()
        let previousPhase = phase
        withAnimation(reduceMotion ? nil : Motion.spring) {
            analysisError = nil
            phase = .analyzing(url.lastPathComponent)
        }
        workTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FirmwareAnalyzer.analyze(url: url)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.data = result.1
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    self.file = result.0
                    self.checklist = []
                    self.expectedChecksum = ""
                    self.phase = .ready
                }
            } catch {
                guard let self else { return }
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    self.analysisError = PrinterSession.describe(error)
                    switch previousPhase {
                    case .ready, .transferFailed: self.phase = previousPhase
                    default: self.phase = self.file == nil ? .idle : .ready
                    }
                }
            }
        }
    }

    func clearFile(reduceMotion: Bool) {
        guard !isBusy else { return }
        workTask?.cancel()
        data = nil
        withAnimation(reduceMotion ? nil : Motion.spring) {
            file = nil
            analysisError = nil
            checklist = []
            expectedChecksum = ""
            progress = 0
            bytesPerSecond = nil
            reconnectLog = []
            phase = .idle
        }
    }

    // MARK: Übertragung

    func start(session: PrinterSession, reduceMotion: Bool) {
        guard let data, let file, !isBusy else { return }
        previousFirmware = session.identity?.firmware
        samples = []
        withAnimation(reduceMotion ? nil : Motion.spring) {
            progress = 0
            bytesPerSecond = nil
            reconnectLog = []
            startedAt = Date()
            finishedAt = nil
            phase = .transferring
        }
        beginKeepAwake()
        // Keine Statusabfragen zwischen die Firmwaredaten mischen.
        session.stopMonitoring()

        samplerTask?.cancel()
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.recordSample(session.progress)
            }
        }

        workTask = Task { [weak self] in
            let ok = await session.sendFirmware(data, fileName: file.fileName)
            guard let self else { return }
            self.samplerTask?.cancel()
            self.samplerTask = nil
            self.finishedAt = Date()
            if ok {
                withAnimation(reduceMotion ? nil : Motion.bouncy) {
                    self.progress = 1
                    self.celebration += 1
                }
                // Verbindung sauber trennen: der Drucker installiert jetzt und startet neu.
                await session.disconnect()
                // Kurz 100 % und die Erfolgsanimation zeigen, dann zum Neustart wechseln.
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 1400))
                self.waitForReboot(session: session, reduceMotion: reduceMotion)
            } else {
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    self.phase = .transferFailed(session.lastError ?? tr("Die Übertragung wurde abgebrochen."))
                }
                self.endKeepAwake()
                // Immer wieder aufnehmen: Die Überwachung verbindet auch eine fehlgeschlagene Sitzung neu.
                session.startMonitoring()
            }
        }
    }

    private func recordSample(_ value: Double?) {
        guard let value, let size = file?.size, size > 0 else { return }
        let now = Date()
        if value > progress { progress = min(1, value) }
        samples.append((date: now, value: value))
        samples.removeAll { now.timeIntervalSince($0.date) > 5 }
        guard let first = samples.first, samples.count >= 2 else { return }
        let elapsed = now.timeIntervalSince(first.date)
        let delta = value - first.value
        guard elapsed >= 0.5 else { return }
        if delta > 0 {
            let instant = delta * Double(size) / elapsed
            bytesPerSecond = bytesPerSecond.map { $0 * 0.65 + instant * 0.35 } ?? instant
        } else if elapsed >= 2, let current = bytesPerSecond {
            // Stillstand: Rate langsam abklingen lassen, damit die Restzeit ehrlich wächst.
            bytesPerSecond = current * 0.7
        }
    }

    private func waitForReboot(session: PrinterSession, reduceMotion: Bool) {
        let wait: TimeInterval = session.isVirtual ? 6 : 90
        let start = Date()
        withAnimation(reduceMotion ? nil : Motion.spring) {
            phase = .rebooting(start: start, until: start.addingTimeInterval(wait))
        }
        workTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            await self.reconnectLoop(session: session, reduceMotion: reduceMotion)
        }
    }

    /// Nicht länger warten – sofort mit den Verbindungsversuchen beginnen.
    func skipWaiting(session: PrinterSession, reduceMotion: Bool) {
        guard case .rebooting = phase else { return }
        workTask?.cancel()
        workTask = Task { [weak self] in
            await self?.reconnectLoop(session: session, reduceMotion: reduceMotion)
        }
    }

    func retryReconnect(session: PrinterSession, reduceMotion: Bool) {
        guard phase == .reconnectFailed else { return }
        beginKeepAwake()
        workTask?.cancel()
        workTask = Task { [weak self] in
            await self?.reconnectLoop(session: session, reduceMotion: reduceMotion)
        }
    }

    private func reconnectLoop(session: PrinterSession, reduceMotion: Bool) async {
        let maxAttempts = 10
        let offset = reconnectLog.count
        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Motion.snappy) {
                phase = .reconnecting(attempt: attempt, of: maxAttempts)
            }
            let started = Date()
            await session.reconnect()
            guard !Task.isCancelled else { return }
            let ok = session.connectionState.isConnected
            withAnimation(reduceMotion ? nil : Motion.spring) {
                reconnectLog.append(FirmwareReconnectAttempt(id: offset + attempt, date: started, success: ok,
                                                             message: ok ? nil : session.lastError))
            }
            if ok {
                await session.refreshIdentity()
                withAnimation(reduceMotion ? nil : Motion.bouncy) {
                    phase = .completed(session.identity?.firmware)
                }
                endKeepAwake()
                // Erst nach dem Einblenden der Erfolgsanzeige auslösen, damit Partikel & Hüpfer sichtbar sind.
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(reduceMotion ? nil : Motion.bouncy) { celebration += 1 }
                return
            }
            try? await Task.sleep(for: .seconds(attempt < 4 ? 6 : 12))
        }
        withAnimation(reduceMotion ? nil : Motion.spring) { phase = .reconnectFailed }
        endKeepAwake()
        // `reconnect()` hat die Statusüberwachung angehalten; sie versucht es im Hintergrund weiter.
        session.startMonitoring()
    }

    /// Nach einem Fehler erneut übertragen (Datei bleibt geladen).
    func acknowledgeFailure(reduceMotion: Bool) {
        guard case .transferFailed = phase else { return }
        withAnimation(reduceMotion ? nil : Motion.spring) {
            progress = 0
            bytesPerSecond = nil
            phase = .ready
        }
    }

    /// Abschluss: zurück zum Ausgangszustand.
    func finish(reduceMotion: Bool) {
        guard !isBusy else { return }
        endKeepAwake()
        clearFile(reduceMotion: reduceMotion)
    }

    // MARK: Ruhezustand verhindern

    private func beginKeepAwake() {
        guard keepAwakeToken == nil else { return }
        keepAwakeToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: tr("Firmware-Update läuft")
        )
    }

    private func endKeepAwake() {
        if let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        keepAwakeToken = nil
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// MARK: - Zustand je Drucker

/// Zustand von „Sicherung & Wartung“ je Drucker. Bleibt erhalten, wenn der Bereich gewechselt wird –
/// laufende Übertragungen (z. B. Klonen) laufen weiter und sind beim Zurückkehren sichtbar.
@MainActor
@Observable
final class MaintenanceStore {
    private static var registry: [UUID: MaintenanceStore] = [:]

    static func shared(for session: PrinterSession) -> MaintenanceStore {
        if let existing = registry[session.id] { return existing }
        let store = MaintenanceStore()
        registry[session.id] = store
        return store
    }

    var pane: MaintPane = .backup
    let backup = MaintBackupController()
    let restore = MaintRestoreController()
    let language = MaintLanguageController()
    let care = MaintCareController()

    var isBusy: Bool {
        backup.isReading || restore.isBusy || language.isApplying || care.isResetting || care.isPrintingTest
    }

    /// Es liegen bereits gelesene Werte vor (Inhalt bleibt beim kurzen Neuverbinden sichtbar).
    var hasLoadedData: Bool {
        backup.phase == .ready || restore.document != nil || care.phase == .loaded || language.phase == .loaded
    }

    /// Lädt nach dem (Neu-)Verbinden die schnellen Werte (Zähler, Gerätesprache) nacheinander –
    /// auch erneut, wenn sie zuvor (z. B. während des Verbindens) nicht lesbar waren.
    func loadInitialValues(session: PrinterSession) async {
        guard session.connectionState.isConnected, session.supportsStatus else { return }
        if care.phase == .idle || care.phase == .unavailable { await care.load(session: session) }
        if language.phase == .idle || language.phase == .unavailable { await language.load(session: session) }
    }
}

// MARK: - Dateien

enum MaintFiles {
    /// Dateityp `.lwbackup` (Inhalt JSON). Bewusst der Standardtyp der Endung und nicht „konform zu
    /// JSON“: Solange die App keinen eigenen Typ exportiert, ordnet macOS gespeicherten `.lwbackup`-Dateien
    /// genau diesen dynamischen Typ zu – ein abweichender (JSON-konformer) dynamischer Typ würde sie im
    /// Öffnen-Dialog ausgrauen. Exportiert die App später einen Typ für die Endung, liefert dieselbe
    /// Abfrage automatisch diesen.
    static var backupType: UTType {
        UTType(filenameExtension: MaintBackupDocument.fileExtension) ?? .data
    }

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    @MainActor
    static func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = tr("Sicherung speichern")
        panel.message = tr("Die Sicherung enthält die gewählten Druckereinstellungen und lässt sich auf diesen oder andere Drucker übertragen.")
        panel.prompt = tr("Sichern")
        panel.allowedContentTypes = [backupType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    static func chooseBackupFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = tr("Sicherung öffnen")
        panel.message = tr("LabelWerk-Sicherung (.lwbackup) wählen")
        panel.prompt = tr("Öffnen")
        panel.allowedContentTypes = [backupType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension MaintBackupIdentity {
    @MainActor
    init(session: PrinterSession) {
        let identity = session.identity
        self.init(model: identity?.model ?? session.model?.displayName,
                  serialNumber: identity?.serialNumber,
                  firmware: identity?.firmware,
                  friendlyName: identity?.friendlyName,
                  ipAddress: identity?.ipAddress,
                  macAddress: identity?.macAddress,
                  isLinkOS: identity?.isLinkOS)
    }
}

// MARK: - Sicherung

@MainActor
@Observable
final class MaintBackupController {
    enum Phase: Equatable {
        case idle, reading, ready
        case failed(String)
    }

    enum Step: Int, CaseIterable, Identifiable, Hashable {
        case settings, files, analysis

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .settings: return tr("Alle Einstellungen lesen (allconfig)")
            case .files: return tr("Dateiliste des Druckers lesen")
            case .analysis: return tr("Gruppen auswerten & Befehle aussortieren")
            }
        }

        var systemImage: String {
            switch self {
            case .settings: return "slider.horizontal.3"
            case .files: return "externaldrive"
            case .analysis: return "checklist"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var activeStep: Step?
    private(set) var completedSteps: Set<Step> = []
    private(set) var settings: [String: SGDSetting] = [:]
    private(set) var groups: [MaintGroupSummary] = []
    var includedGroups: Set<String> = []
    var includeFileList = true
    private(set) var files: [PrinterFile] = []
    private(set) var readAt: Date?
    private(set) var savedURL: URL?
    private(set) var savedAt: Date?
    private(set) var savedEntryCount = 0

    var isReading: Bool { phase == .reading }

    var stepProgress: Double {
        Double(completedSteps.count) / Double(Step.allCases.count)
    }

    var includedEntryCount: Int {
        groups.filter { includedGroups.contains($0.id) }.reduce(0) { $0 + $1.restorable }
    }

    var includesNetwork: Bool {
        groups.contains { $0.kind == .network && includedGroups.contains($0.id) }
    }

    var protectedCount: Int { groups.reduce(0) { $0 + $1.protected } }
    var readOnlyCount: Int { groups.reduce(0) { $0 + $1.readOnly } }

    func isIncluded(_ group: MaintGroupSummary) -> Bool {
        group.kind != .excluded && includedGroups.contains(group.id)
    }

    func setIncluded(_ on: Bool, group: MaintGroupSummary) {
        guard group.kind != .excluded else { return }
        if on { includedGroups.insert(group.id) } else { includedGroups.remove(group.id) }
    }

    /// Standardauswahl: alles außer Netzwerk und ausgeschlossenen Gruppen.
    func selectDefaults() {
        includedGroups = Set(groups.filter { $0.kind.includedByDefault }.map(\.id))
    }

    func selectNone() {
        includedGroups = []
    }

    /// Werte der gewählten Gruppen, die in die Sicherung gehen (für die Vorschau).
    var previewEntries: [MaintBackupEntry] {
        settings.values
            .filter { includedGroups.contains($0.group) && MaintSGDPolicy.isRestorable($0) }
            .map(MaintBackupEntry.init(setting:))
            .sorted { $0.name < $1.name }
    }

    func read(session: PrinterSession) async {
        guard phase != .reading else { return }
        phase = .reading
        completedSteps = []
        activeStep = .settings

        let all = await session.allSettings()
        guard !all.isEmpty else {
            activeStep = nil
            phase = .failed(session.lastError ?? tr("Der Drucker hat keine Einstellungen geliefert."))
            return
        }
        completedSteps.insert(.settings)

        activeStep = .files
        let fileList = await session.listFiles()
        completedSteps.insert(.files)

        activeStep = .analysis
        let summaries = MaintSGDPolicy.summarize(all)
        // Kurz verweilen, damit der letzte Schritt sichtbar abgehakt wird.
        try? await Task.sleep(for: .milliseconds(280))
        completedSteps.insert(.analysis)

        let knownGroups = Set(groups.map(\.id))
        let previousChoice = includedGroups
        settings = all
        files = fileList
        groups = summaries
        includedGroups = Set(summaries.compactMap { summary -> String? in
            guard summary.kind != .excluded else { return nil }
            if knownGroups.contains(summary.id) {
                return previousChoice.contains(summary.id) ? summary.id : nil
            }
            return summary.kind.includedByDefault ? summary.id : nil
        })
        readAt = Date()
        activeStep = nil
        phase = .ready
    }

    func makeDocument(session: PrinterSession) -> MaintBackupDocument {
        MaintBackupDocument.make(
            printerName: session.displayName,
            identity: MaintBackupIdentity(session: session),
            modelID: session.saved.modelID,
            resolution: session.resolution,
            language: session.saved.language,
            driverSettings: session.saved.settings,
            stock: session.stock,
            settings: settings,
            groups: includedGroups,
            files: includeFileList ? files : nil,
            appVersion: MaintFiles.appVersion
        )
    }

    @discardableResult
    func save(session: PrinterSession, model: AppModel) -> Bool {
        let document = makeDocument(session: session)
        guard !document.entries.isEmpty else {
            model.toast(tr("Nichts zu sichern"), message: tr("Bitte mindestens eine Gruppe mit Einstellungen auswählen."),
                        style: .warning)
            return false
        }
        let name = MaintBackupDocument.suggestedFileName(printerName: session.displayName, date: document.createdAt)
        guard let url = MaintFiles.chooseSaveURL(suggestedName: name) else { return false }
        do {
            try document.encoded().write(to: url, options: .atomic)
            savedURL = url
            savedAt = Date()
            savedEntryCount = document.entries.count
            model.toast(tr("Sicherung gespeichert"),
                        message: tr("%d Einstellungen in „%@“", document.entries.count, url.lastPathComponent),
                        style: .success)
            return true
        } catch {
            model.toast(tr("Sicherung fehlgeschlagen"), message: error.localizedDescription, style: .error)
            return false
        }
    }
}

// MARK: - Wiederherstellen & Klonen

struct MaintApplyItem: Identifiable, Hashable {
    enum State: Hashable {
        case pending
        case writing
        /// Gesendet, (noch) nicht bestätigt.
        case written
        /// Drucker meldet den neuen Wert.
        case verified
        /// Drucker meldet einen anderen Wert.
        case mismatch(String)
        case failed(String)
        case skipped

        /// Der Wert wurde an den Drucker gesendet.
        var wasSent: Bool {
            switch self {
            case .written, .verified, .mismatch: return true
            default: return false
            }
        }

        var isFinal: Bool {
            switch self {
            case .pending, .writing: return false
            default: return true
            }
        }
    }

    let name: String
    let value: String
    let previous: String?
    let isNetwork: Bool
    var state: State

    var id: String { name }
}

struct MaintApplyReport: Equatable {
    var targetName: String
    var sourceName: String
    var sent: Int
    var verified: Int
    var mismatched: Int
    var failed: Int
    var skipped: Int
    /// Gesendet, aber nicht gegengelesen (Kontrolle fehlgeschlagen oder Wert nicht gemeldet).
    var unverified: Int
    /// nil = nicht angefordert bzw. nicht gesendet (Grund dann in `saveSkipped`).
    var savedPermanently: Bool?
    var saveSkipped: MaintSaveSkip?
    var driverApplied: Bool
    var networkChanged: Bool
    /// `device.languages` des Ziels nach der Übertragung (gegengelesen, gesendet oder vorher gelesen).
    var deviceLanguage: String?
    var cancelled: Bool
    var date: Date

    /// Alles gesendet, bestätigt und (falls angefordert) gespeichert.
    var isClean: Bool {
        failed == 0 && mismatched == 0 && unverified == 0 && savedPermanently != false && !cancelled
    }
}

@MainActor
@Observable
final class MaintRestoreController {
    enum Phase: Equatable {
        case empty, loading, comparing, ready, applying, finished
        case failed(String)
    }

    enum Source: Equatable {
        case file(String)
        case printer(String)

        var name: String {
            switch self {
            case .file(let name), .printer(let name): return name
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable, Hashable {
        case changed, selected, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .changed: return tr("Abweichend")
            case .selected: return tr("Ausgewählt")
            case .all: return tr("Alle")
            }
        }
    }

    private(set) var phase: Phase = .empty
    private(set) var document: MaintBackupDocument?
    private(set) var source: Source?
    /// Drucker, dessen Konfiguration live gelesen wurde (nicht als Ziel anbieten).
    private(set) var sourcePrinterID: UUID?
    private(set) var targetID: UUID?
    private(set) var rows: [MaintRestoreRow] = []
    var selection: Set<String> = []
    var filter: Filter = .changed
    var groupFilter: String?
    var search = ""
    var applyDriverSettings = false
    var saveToPrinter = true
    private(set) var isSameDevice = false
    private(set) var items: [MaintApplyItem] = []
    private(set) var currentItem: String?
    private(set) var isVerifying = false
    private(set) var report: MaintApplyReport?
    private(set) var celebration = 0

    private(set) var cancelRequested = false
    @ObservationIgnored private var compareToken = 0

    var isBusy: Bool { phase == .loading || phase == .comparing || phase == .applying }

    var changedCount: Int { rows.filter { $0.status == .changed }.count }
    var selectableCount: Int { rows.filter(\.isSelectable).count }
    var blockedCount: Int { rows.filter { !$0.isSelectable }.count }

    var selectedRows: [MaintRestoreRow] {
        rows.filter { selection.contains($0.name) && $0.isSelectable }
    }

    var selectedNetworkCount: Int { selectedRows.filter(\.isNetwork).count }

    var groupsInRows: [String] {
        Array(Set(rows.map(\.group))).sorted()
    }

    var visibleRows: [MaintRestoreRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            switch filter {
            case .changed: if row.status != .changed { return false }
            case .selected: if !selection.contains(row.name) { return false }
            case .all: break
            }
            if let groupFilter, row.group != groupFilter { return false }
            if !needle.isEmpty {
                return row.name.lowercased().contains(needle)
                    || row.backupValue.lowercased().contains(needle)
                    || (row.currentValue?.lowercased().contains(needle) ?? false)
            }
            return true
        }
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(items.filter { $0.state.isFinal }.count) / Double(items.count)
    }

    func isSelected(_ row: MaintRestoreRow) -> Bool { selection.contains(row.name) }

    func toggle(_ row: MaintRestoreRow) {
        guard row.isSelectable, phase == .ready || phase == .finished else { return }
        if selection.contains(row.name) { selection.remove(row.name) } else { selection.insert(row.name) }
    }

    /// Wählt alle sichtbaren auswählbaren Zeilen aus bzw. ab.
    func setVisibleSelection(_ on: Bool) {
        let names = visibleRows.filter(\.isSelectable).map(\.name)
        if on { selection.formUnion(names) } else { selection.subtract(names) }
    }

    func resetSelection(target: PrinterSession) {
        selection = defaultSelection(for: target)
    }

    private func defaultSelection(for target: PrinterSession) -> Set<String> {
        MaintDiff.defaultSelection(rows, sameDevice: isSameDevice, targetOutput: effectiveOutput(for: target),
                                   model: target.model)
    }

    // MARK: Sprache & Speichern

    /// Ausgabesprache, mit der LabelWerk das Ziel nach der Übertragung anspricht
    /// (mit „Treibereinstellungen übernehmen“ die der Sicherung, sofern das Modell sie kann).
    func effectiveOutput(for target: PrinterSession) -> PrinterLanguage {
        if applyDriverSettings, let document, target.model?.supports(document.language) ?? true {
            return document.language
        }
        return target.saved.language
    }

    /// Ausgewählte Gerätesprache (`device.languages`), falls sie übertragen wird.
    var selectedLanguageRow: MaintRestoreRow? {
        selectedRows.first(where: { MaintDeviceLanguage.isLanguageSetting($0.name) })
    }

    /// Gewählter Wert für `device.languages`, den die Ausgabesprache von LabelWerk danach nicht versteht.
    func languageConflict(for target: PrinterSession) -> String? {
        guard let row = selectedLanguageRow else { return nil }
        let compatible = MaintDeviceLanguage.isCompatible(deviceValue: row.backupValue,
                                                          output: effectiveOutput(for: target), model: target.model)
        return compatible ? nil : row.backupValue
    }

    /// Grund, warum „dauerhaft speichern“ mit der aktuellen Auswahl nicht möglich wäre (nil = möglich).
    func predictedSaveSkip(for target: PrinterSession) -> MaintSaveSkip? {
        let currentLanguage = rows.first(where: { MaintDeviceLanguage.isLanguageSetting($0.name) })?.currentValue
        return MaintSaveSkip.evaluate(deviceLanguage: selectedLanguageRow?.backupValue ?? currentLanguage,
                                      output: target.saved.language, model: target.model)
    }

    /// `device.languages` nach dem Schreiben: gegengelesen, sonst gesendet, sonst vor dem Schreiben gelesen.
    private func deviceLanguageAfterApply(_ after: [String: SGDSetting]) -> String? {
        if let reported = after.first(where: { MaintDeviceLanguage.isLanguageSetting($0.key) }) {
            return reported.value.value
        }
        if let sent = items.first(where: { MaintDeviceLanguage.isLanguageSetting($0.name) && $0.state.wasSent }) {
            return sent.value
        }
        return rows.first(where: { MaintDeviceLanguage.isLanguageSetting($0.name) })?.currentValue
    }

    // MARK: Quelle

    /// Übernimmt eine Sicherung (Datei oder direkt gelesen) als Quelle. Aufrufer vergleichen
    /// anschließend sofort mit `compare(target:)`; während einer Übertragung wirkungslos.
    func use(document: MaintBackupDocument, source: Source, sourcePrinterID: UUID? = nil) {
        guard phase != .applying else { return }
        compareToken += 1
        phase = .comparing
        self.document = document
        self.source = source
        self.sourcePrinterID = sourcePrinterID
        rows = []
        selection = []
        items = []
        report = nil
        groupFilter = nil
        search = ""
        filter = .changed
        applyDriverSettings = false
    }

    func openFile(target: PrinterSession, model: AppModel) async {
        guard !isBusy, let url = MaintFiles.chooseBackupFile() else { return }
        do {
            let data = try Data(contentsOf: url)
            let document = try MaintBackupDocument.decode(data)
            use(document: document, source: .file(url.lastPathComponent))
            await compare(target: target)
        } catch {
            model.toast(tr("Sicherung konnte nicht geöffnet werden"), message: PrinterSession.describe(error), style: .error)
        }
    }

    /// Liest die aktuelle Konfiguration eines Druckers direkt als Quelle (Klonen ohne Datei).
    func loadFromPrinter(_ printer: PrinterSession, target: PrinterSession, model: AppModel) async {
        guard !isBusy else { return }
        let previousPhase = phase
        phase = .loading
        let all = await printer.allSettings()
        guard !all.isEmpty else {
            phase = previousPhase
            model.toast(tr("Konfiguration nicht lesbar"),
                        message: printer.lastError ?? tr("„%@“ hat keine Einstellungen geliefert.", printer.displayName),
                        style: .error)
            return
        }
        let groups = Set(MaintSGDPolicy.summarize(all).filter { $0.kind != .excluded }.map(\.id))
        let document = MaintBackupDocument.make(
            printerName: printer.displayName,
            identity: MaintBackupIdentity(session: printer),
            modelID: printer.saved.modelID,
            resolution: printer.resolution,
            language: printer.saved.language,
            driverSettings: printer.saved.settings,
            stock: printer.stock,
            settings: all,
            groups: groups,
            files: nil,
            appVersion: MaintFiles.appVersion
        )
        use(document: document, source: .printer(printer.displayName), sourcePrinterID: printer.id)
        await compare(target: target)
    }

    func clear() {
        guard phase != .applying else { return }
        compareToken += 1
        document = nil
        source = nil
        sourcePrinterID = nil
        rows = []
        selection = []
        items = []
        report = nil
        phase = .empty
    }

    // MARK: Vergleich

    func compare(target: PrinterSession) async {
        guard let document, phase != .applying else { return }
        compareToken += 1
        let token = compareToken
        targetID = target.id
        phase = .comparing
        let current = await target.allSettings()
        guard token == compareToken else { return }
        guard !current.isEmpty else {
            rows = []
            selection = []
            phase = .failed(target.lastError
                            ?? tr("Die aktuellen Werte von „%@“ konnten nicht gelesen werden.", target.displayName))
            return
        }
        isSameDevice = Self.sameDevice(document: document, target: target)
        rows = MaintDiff.rows(document: document, current: current)
        selection = defaultSelection(for: target)
        items = []
        report = nil
        phase = .ready
    }

    static func sameDevice(document: MaintBackupDocument, target: PrinterSession) -> Bool {
        guard let backupSerial = document.identity.serialNumber?.trimmingCharacters(in: .whitespaces),
              !backupSerial.isEmpty,
              let targetSerial = target.identity?.serialNumber?.trimmingCharacters(in: .whitespaces) else { return false }
        return backupSerial.caseInsensitiveCompare(targetSerial) == .orderedSame
    }

    // MARK: Übertragen

    func cancelApply() {
        cancelRequested = true
    }

    func apply(target: PrinterSession, model: AppModel) async {
        guard let document, phase == .ready || phase == .finished else { return }
        let chosen = MaintDiff.applyOrder(selectedRows)
        guard !chosen.isEmpty || applyDriverSettings else { return }

        cancelRequested = false
        report = nil
        items = chosen.map {
            MaintApplyItem(name: $0.name, value: $0.backupValue, previous: $0.currentValue,
                           isNetwork: $0.isNetwork, state: .pending)
        }
        phase = .applying

        // 1. Werte nacheinander schreiben.
        var aborted = false
        for index in items.indices {
            guard index < items.count else { break }
            if cancelRequested || aborted {
                items[index].state = .skipped
                continue
            }
            currentItem = items[index].name
            items[index].state = .writing
            let ok = await target.setvar(items[index].name, items[index].value)
            guard index < items.count else { break }
            if ok {
                items[index].state = .written
            } else {
                // `setvar` sendet ohne Antwort und scheitert nur an der Übertragung (nachdem der Client
                // bereits neu verbunden hat): Die Verbindung ist weg bzw. gestört. Den Rest überspringen,
                // statt für jeden Wert erneut auf den Verbindungsaufbau zu warten und Fehler zu melden.
                items[index].state = .failed(target.lastError ?? tr("Unbekannter Fehler"))
                aborted = true
            }
        }
        currentItem = nil

        // 2. Kontrolle: Werte erneut lesen und vergleichen (nicht nach einem Verbindungsfehler – die
        //    gesendeten Werte bleiben dann „nicht gegengelesen“, siehe „Erneut vergleichen“).
        var after: [String: SGDSetting] = [:]
        if items.contains(where: { $0.state == .written }) && !aborted && target.connectionState.isConnected {
            isVerifying = true
            try? await Task.sleep(for: .milliseconds(400))
            after = await target.allSettings()
            isVerifying = false
            for index in items.indices where items[index].state == .written {
                guard let reported = after[items[index].name]?.value else { continue }
                items[index].state = MaintDiff.valuesMatch(reported, items[index].value)
                    ? .verified : .mismatch(reported)
            }
        }

        // 3. Dauerhaft speichern – ^JUS ist ZPL: nur senden, wenn der Drucker (auch nach einem
        //    Wechsel von device.languages) ZPL versteht. Spricht LabelWerk ihn in EPL/CPCL an, geht
        //    der ZPL-Befehl direkt an den Drucker, statt über die Ausgabesprache zu scheitern.
        let sentCount = items.filter { $0.state.wasSent }.count
        let deviceLanguage = deviceLanguageAfterApply(after)
        var savedPermanently: Bool?
        var saveSkipped: MaintSaveSkip?
        if saveToPrinter && sentCount > 0 && (cancelRequested || aborted) {
            // Nach einem Abbruch nicht dauerhaft machen: ^JUS würde den halb übertragenen Stand (und alle
            // anderen vorläufigen Einstellungen des Druckers) festschreiben.
            saveSkipped = .interrupted
        } else if saveToPrinter && sentCount > 0 && target.connectionState.isConnected {
            let output = target.saved.language
            if let skip = MaintSaveSkip.evaluate(deviceLanguage: deviceLanguage, output: output, model: target.model) {
                saveSkipped = skip
            } else if PrinterAction.saveSettings.isSupported(language: output) {
                savedPermanently = await target.perform(.saveSettings)
            } else if let payload = PrinterAction.saveSettings.payload(language: PrinterLanguage.zpl) {
                savedPermanently = await target.sendData(payload, title: tr("Einstellungen dauerhaft speichern"),
                                                         kind: .action)
            }
        }

        // 4. Treibereinstellungen (zuletzt – ein Sprachwechsel baut die Verbindung neu auf).
        var driverApplied = false
        if applyDriverSettings && !cancelRequested {
            driverApplied = Self.applyDriverSettings(document, to: target, model: model)
        }

        if !after.isEmpty {
            rows = MaintDiff.rows(document: document, current: after)
            selection = defaultSelection(for: target)
        }

        let finished = MaintApplyReport(
            targetName: target.displayName,
            sourceName: source?.name ?? document.printerName,
            sent: sentCount,
            verified: items.filter { $0.state == .verified }.count,
            mismatched: items.filter { if case .mismatch = $0.state { return true } else { return false } }.count,
            failed: items.filter { if case .failed = $0.state { return true } else { return false } }.count,
            skipped: items.filter { $0.state == .skipped }.count,
            unverified: items.filter { $0.state == .written }.count,
            savedPermanently: savedPermanently,
            saveSkipped: saveSkipped,
            driverApplied: driverApplied,
            networkChanged: items.contains { $0.isNetwork && $0.state.wasSent },
            deviceLanguage: deviceLanguage,
            cancelled: cancelRequested || aborted,
            date: Date()
        )
        report = finished
        phase = .finished
        if finished.isClean { celebration += 1 }

        model.record(JobRecord(printerID: target.id, printerName: target.displayName,
                               title: tr("Konfiguration übernommen aus „%@“", finished.sourceName),
                               kind: .settings, labels: 0, bytes: 0, success: finished.failed == 0,
                               message: reportText(finished, includeItems: false)))
        let message = items.isEmpty
            ? tr("Treibereinstellungen für „%@“ übernommen.", target.displayName)
            : tr("%d von %d Werten auf „%@“ übernommen.", sentCount, items.count, target.displayName)
        model.toast(Self.toastTitle(finished), message: message, style: finished.isClean ? .success : .warning)
    }

    private static func toastTitle(_ report: MaintApplyReport) -> String {
        if report.cancelled { return tr("Übertragung abgebrochen") }
        if report.failed > 0 { return tr("Konfiguration teilweise übertragen") }
        if report.isClean { return tr("Konfiguration übertragen") }
        return tr("Konfiguration mit Hinweisen übertragen")
    }

    /// Startet das Ziel neu. Passt die Gerätesprache nicht zur Ausgabesprache (z. B. nach einem Wechsel
    /// von device.languages), geht der Neustart per SGD (`device.reset`), das jeder Modus versteht.
    func restart(target: PrinterSession, model: AppModel) async {
        let output = target.saved.language
        if let language = report?.deviceLanguage, !MaintDeviceLanguage.normalized(language).isEmpty,
           !MaintDeviceLanguage.isCompatible(deviceValue: language, output: output, model: target.model) {
            if await target.sendRaw(SGD.reset(), title: tr("Drucker neu starten")) {
                model.toast(tr("Drucker wird neu gestartet"), message: tr("Befehl wurde gesendet."), style: .success)
            }
        } else {
            await target.perform(.reset)
        }
    }

    /// Übernimmt Treibereinstellungen, Etikettenformat und Ausgabesprache der Sicherung.
    static func applyDriverSettings(_ document: MaintBackupDocument, to target: PrinterSession, model: AppModel) -> Bool {
        var saved = target.saved
        if let settings = document.driverSettings {
            saved.settings = settings.clamped()
        }
        if !document.stockID.isEmpty {
            if model.stock(id: document.stockID) != nil {
                saved.stockID = document.stockID
            } else if let stock = document.stock {
                model.addCustomStock(stock)
                saved.stockID = stock.id
            }
        }
        if target.model?.supports(document.language) ?? true {
            saved.language = document.language
        }
        if saved != target.saved {
            target.saved = saved
        }
        return true
    }

    /// Lesbarer Bericht – kurz für den Auftragsverlauf, mit allen Werten für die Zwischenablage.
    func reportText(_ report: MaintApplyReport, includeItems: Bool = true) -> String {
        var lines: [String] = [
            tr("Quelle: %@", report.sourceName),
            tr("Ziel: %@", report.targetName),
            tr("Gesendet: %d · bestätigt: %d · abweichend: %d · fehlgeschlagen: %d · übersprungen: %d",
               report.sent, report.verified, report.mismatched, report.failed, report.skipped),
        ]
        if report.unverified > 0 {
            lines.append(tr("Gesendet, aber nicht gegengelesen: %d", report.unverified))
        }
        if let saved = report.savedPermanently {
            lines.append(saved ? tr("Dauerhaft im Drucker gespeichert.") : tr("Dauerhaftes Speichern fehlgeschlagen."))
        } else if let skip = report.saveSkipped {
            lines.append(skip.explanation)
        }
        if report.driverApplied { lines.append(tr("Treibereinstellungen übernommen.")) }
        if report.cancelled { lines.append(tr("Vorgang abgebrochen.")) }
        guard includeItems else { return lines.joined(separator: "\n") }
        for item in items {
            let state: String
            switch item.state {
            case .pending: state = tr("ausstehend")
            case .writing: state = tr("wird geschrieben")
            case .written: state = tr("gesendet")
            case .verified: state = tr("bestätigt")
            case .mismatch(let reported): state = tr("Drucker meldet „%@“", reported)
            case .failed(let message): state = tr("Fehler: %@", message)
            case .skipped: state = tr("übersprungen")
            }
            lines.append("\(item.name) = \"\(item.value)\" – \(state)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Druckersprache

@MainActor
@Observable
final class MaintLanguageController {
    enum Phase: Equatable { case idle, loading, loaded, unavailable }

    private(set) var phase: Phase = .idle
    private(set) var deviceValue: String?
    var choice: String = ""
    var customValue = ""
    var isCustom = false
    private(set) var isApplying = false
    private(set) var changeCount = 0
    @ObservationIgnored private var isLoading = false

    var effectiveChoice: String {
        MaintDeviceLanguage.normalized(isCustom ? customValue : choice)
    }

    var hasPendingChange: Bool {
        let value = effectiveChoice
        guard !value.isEmpty else { return false }
        guard let deviceValue else { return true }
        return MaintDeviceLanguage.normalized(deviceValue) != value
    }

    /// Liest die Gerätesprache, falls noch nicht geschehen (nur bei bestehender Verbindung).
    func loadIfNeeded(session: PrinterSession) async {
        guard phase == .idle, session.connectionState.isConnected else { return }
        await load(session: session)
    }

    func load(session: PrinterSession) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if phase != .loaded { phase = .loading }
        let value = await session.getvar(MaintDeviceLanguage.sgdName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            deviceValue = value
            syncChoice(to: value)
            phase = .loaded
        } else {
            deviceValue = nil
            phase = .unavailable
        }
    }

    func select(_ option: MaintDeviceLanguageOption) {
        choice = option.value
        isCustom = false
    }

    func revert() {
        if let deviceValue { syncChoice(to: deviceValue) }
    }

    private func syncChoice(to value: String) {
        let key = MaintDeviceLanguage.normalized(value)
        if MaintDeviceLanguage.option(for: key) != nil {
            choice = key
            isCustom = false
        } else {
            customValue = key
            choice = ""
            isCustom = true
        }
    }

    @discardableResult
    func apply(session: PrinterSession, model: AppModel) async -> Bool {
        let value = effectiveChoice
        guard !value.isEmpty, !isApplying else { return false }
        isApplying = true
        defer { isApplying = false }
        guard await session.setvar(MaintDeviceLanguage.sgdName, value) else { return false }
        try? await Task.sleep(for: .milliseconds(800))
        let confirmed = await session.getvar(MaintDeviceLanguage.sgdName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let confirmed, !confirmed.isEmpty else {
            deviceValue = value
            changeCount += 1
            model.toast(tr("Druckersprache gesendet"),
                        message: tr("Der Drucker hat den neuen Wert nicht bestätigt. Prüfe ihn nach einem Neustart."),
                        style: .info)
            return true
        }
        deviceValue = confirmed
        syncChoice(to: confirmed)
        if MaintDiff.valuesMatch(confirmed, value) {
            changeCount += 1
            model.toast(tr("Druckersprache geändert"),
                        message: tr("Der Drucker erwartet jetzt „%@“.", confirmed), style: .success)
            return true
        }
        model.toast(tr("Druckersprache unverändert"),
                    message: tr("Der Drucker meldet weiterhin „%@“. Der Wert wird von diesem Modell evtl. nicht unterstützt.", confirmed),
                    style: .warning)
        return false
    }
}

// MARK: - Wartung

@MainActor
@Observable
final class MaintCareController {
    enum Phase: Equatable { case idle, loading, loaded, unavailable }

    private(set) var phase: Phase = .idle
    private(set) var reading: MaintOdometerReading?
    private(set) var loadedAt: Date?
    private(set) var isResetting = false
    private(set) var isPrintingTest = false
    private(set) var resetCelebration = 0
    private(set) var testPrintCount = 0
    var guideStep = 0
    @ObservationIgnored private var isLoading = false

    var isLoadingValues: Bool { phase == .loading }

    /// Liest die Zählerstände, falls noch nicht geschehen (nur bei bestehender Verbindung).
    func loadIfNeeded(session: PrinterSession) async {
        guard phase == .idle, session.connectionState.isConnected else { return }
        await load(session: session)
    }

    func load(session: PrinterSession) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if phase != .loaded { phase = .loading }
        let values = await session.getvars(MaintOdometer.keys)
        let reading = MaintOdometer.reading(from: values)
        self.reading = reading
        loadedAt = Date()
        phase = reading.isEmpty ? .unavailable : .loaded
    }

    func resetCleaningCounter(session: PrinterSession, model: AppModel) async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        guard await session.setvar(MaintOdometer.headCleanKey, "0") else { return }
        try? await Task.sleep(for: .milliseconds(500))
        await load(session: session)
        if let meters = reading?.sinceCleanMeters, meters < 0.5 {
            resetCelebration += 1
            model.toast(tr("Reinigungszähler zurückgesetzt"),
                        message: tr("Die nächste Erinnerung richtet sich nach der neuen Strecke."), style: .success)
        } else {
            model.toast(tr("Zähler nicht zurückgesetzt"),
                        message: tr("Der Drucker hat den Wert nicht übernommen. Bei manchen Modellen geht das nur am Bedienfeld."),
                        style: .warning)
        }
    }

    /// Das Testmuster ist ZPL und wird unverändert gesendet: nur für Modelle, die ZPL verstehen
    /// (unbekanntes Modell: zulassen).
    static func canPrintTestPattern(_ session: PrinterSession) -> Bool {
        session.model?.supports(PrinterLanguage.zpl) ?? true
    }

    func printTestPattern(session: PrinterSession) async {
        guard !isPrintingTest, Self.canPrintTestPattern(session) else { return }
        isPrintingTest = true
        defer { isPrintingTest = false }
        let layout = Self.testLayout(for: session)
        if await session.printZPL(MaintHeadTest.zpl(layout), title: tr("Druckkopftest")) {
            testPrintCount += 1
        }
    }

    static func testLayout(for session: PrinterSession, date: Date = Date()) -> MaintHeadTest.Layout {
        let modelName = session.model?.displayName ?? session.identity?.model ?? session.displayName
        let info = [modelName, "\(session.resolution.dpi) dpi",
                    date.formatted(date: .numeric, time: .shortened)].joined(separator: " · ")
        return MaintHeadTest.layout(
            widthDots: session.labelWidthDots,
            heightDots: session.labelHeightDots,
            resolution: session.resolution,
            title: tr("Druckkopftest"),
            info: info,
            footer: tr("Weiße Streifen im Balken oder Lücken im Raster: Druckkopf reinigen bzw. prüfen")
        )
    }
}

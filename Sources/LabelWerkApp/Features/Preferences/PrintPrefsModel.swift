import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Bereiche (Seitenleiste wie im Windows-Dialog)

/// Die acht Bereiche des Dialogs „Druckeinstellungen für …“ des Windows-Treibers ZDesigner.
enum PrintPrefsPane: String, CaseIterable, Identifiable, Hashable {
    case page
    case options
    case operation
    case graphics
    case commands
    case maintenance
    case units
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: return tr("Seite einrichten")
        case .options: return tr("Druckoptionen")
        case .operation: return tr("Bedienermodus")
        case .graphics: return tr("Grafik Optionen")
        case .commands: return tr("Kundenspezifische Befehle")
        case .maintenance: return tr("Wartung")
        case .units: return tr("Einheiten")
        case .about: return tr("Hilfe und Über")
        }
    }

    var subtitle: String {
        switch self {
        case .page: return tr("Etikettengröße, Medientyp, Ausrichtung und Endlosmaterial")
        case .options: return tr("Geschwindigkeit, Temperatur, Versatz und erweiterte Druckereinstellungen")
        case .operation: return tr("Verhalten nach dem Druck: Abreißen, Spenden, Schneiden, Aufwickeln")
        case .graphics: return tr("Rasterung von Graustufen und Kompression der Druckdaten")
        case .commands: return tr("Eigene Befehle am Anfang und Ende von Auftrag und Etikett")
        case .maintenance: return tr("Zurücksetzen, Kalibrieren, Übertragen und Profile")
        case .units: return tr("Maßeinheit für alle Längenangaben")
        case .about: return tr("Erklärungen zu allen Optionen, Treiber- und Druckerinformationen")
        }
    }

    var systemImage: String {
        switch self {
        case .page: return "doc.text"
        case .options: return "printer"
        case .operation: return "gearshape.2"
        case .graphics: return "photo"
        case .commands: return "chevron.left.forwardslash.chevron.right"
        case .maintenance: return "wrench.and.screwdriver"
        case .units: return "ruler"
        case .about: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .page: return Theme.violet
        case .options: return Theme.printing
        case .operation: return Theme.magenta
        case .graphics: return Theme.teal
        case .commands: return Theme.indigo
        case .maintenance: return Theme.warning
        case .units: return Theme.ready
        case .about: return Theme.offline
        }
    }
}

// MARK: - Entwurf

/// Alle Werte des Dialogs. Änderungen gelten erst nach „OK“ bzw. „Übernehmen“ (wie im Windows-Treiber).
struct PrintPrefsDraft: Equatable {
    var settings: PrintSettings
    /// Gewählte Vorlage; `nil` = „Benutzerdefiniert“ (eigene Breite/Höhe).
    var stockID: String?
    var widthMM: Double
    var heightMM: Double
    /// Lücke bzw. Markenhöhe der Vorlage (für eigene Formate übernommen).
    var gapMM: Double
    var language: PrinterLanguage

    @MainActor
    init(session: PrinterSession) {
        let stock = session.stock
        settings = session.saved.settings
        stockID = stock.id
        widthMM = stock.widthMM
        heightMM = stock.heightMM
        gapMM = stock.gapMM
        language = session.saved.language
    }
}

// MARK: - Einstellungen (Zeilen mit Stift-Menü)

/// Eine Einstellung des Dialogs – Grundlage für das Stift-Menü („Treiberwert verwenden“ /
/// „Druckerwert verwenden“ / „Vom Drucker lesen“), die Änderungsmarken und die Hilfe.
enum PrintPrefsSetting: String, CaseIterable, Hashable, Identifiable {
    // Seite einrichten
    case template, size, tracking, rotation, markOffset, mirror, negative, stopAtLast, stopOffset
    // Druckoptionen
    case speed, darkness, mediaType, labelTop, labelLeft, backfeed, pauseEvery, controlCharacters, rtcUpdate
    case calibrateBeforeJob, saveToPrinter, language, cancelJobs, cancelDelay
    // Bedienermodus
    case printMode, tearOff, cutEvery
    // Grafik Optionen
    case dither, threshold, compression, skipBlank
    // Kundenspezifische Befehle
    case startCommands, endCommands, labelStartCommands, labelEndCommands
    // Wartung (Medienvorschub)
    case powerUpAction, headCloseAction

    var id: String { rawValue }

    /// Beschriftung (wie im Windows-Dialog).
    var title: String {
        switch self {
        case .template: return tr("Vorlagen")
        case .size: return tr("Breite / Höhe")
        case .tracking: return tr("Medientyp")
        case .rotation: return tr("Drehung")
        case .markOffset: return tr("Markierung Versatz")
        case .mirror: return tr("Spiegeln")
        case .negative: return tr("Invers")
        case .stopAtLast: return tr("Bei letztem Element stoppen")
        case .stopOffset: return tr("Stoppversatz")
        case .speed: return tr("Geschwindigkeit")
        case .darkness: return tr("Temperatur")
        case .mediaType: return tr("Druckmodus")
        case .labelTop: return tr("Oben")
        case .labelLeft: return tr("Links")
        case .backfeed: return tr("Rückzug")
        case .pauseEvery: return tr("Pausieren")
        case .controlCharacters: return tr("Steuerzeichen")
        case .rtcUpdate: return tr("RTC aktualisieren")
        case .calibrateBeforeJob: return tr("Vor jedem Auftrag kalibrieren")
        case .saveToPrinter: return tr("Einstellungen im Drucker speichern")
        case .language: return tr("Druckersprache")
        case .cancelJobs: return tr("Alle aktuellen und nächsten Druckjobs löschen")
        case .cancelDelay: return tr("Verzögerung")
        case .printMode: return tr("Modus")
        case .tearOff: return tr("Versatz")
        case .cutEvery: return tr("Abschneider")
        case .dither: return tr("Rasterung")
        case .threshold: return tr("Schwelle")
        case .compression: return tr("Kompression")
        case .skipBlank: return tr("Leere Etiketten überspringen")
        case .startCommands: return tr("Auftragsbeginn")
        case .endCommands: return tr("Auftragsende")
        case .labelStartCommands: return tr("Etikettenbeginn")
        case .labelEndCommands: return tr("Etikettenende")
        case .powerUpAction: return tr("Aktion beim Einschalten")
        case .headCloseAction: return tr("Aktion nach dem Schließen des Druckkopfs")
        }
    }

    /// Eindeutige Bezeichnung für Listen (z. B. „Versatz oben“ statt „Oben“).
    var summaryTitle: String {
        switch self {
        case .labelTop: return tr("Versatz oben")
        case .labelLeft: return tr("Versatz links")
        case .tearOff: return tr("Abreißversatz")
        case .printMode: return tr("Bedienermodus")
        case .cancelJobs: return tr("Aufträge vor dem Drucken abbrechen")
        case .cancelDelay: return tr("Verzögerung nach dem Abbrechen")
        case .cutEvery: return tr("Schneiden alle N Etiketten")
        default: return title
        }
    }

    var pane: PrintPrefsPane {
        switch self {
        case .template, .size, .tracking, .rotation, .markOffset, .mirror, .negative, .stopAtLast, .stopOffset:
            return .page
        case .speed, .darkness, .mediaType, .labelTop, .labelLeft, .backfeed, .pauseEvery, .controlCharacters,
             .rtcUpdate, .calibrateBeforeJob, .saveToPrinter, .language, .cancelJobs, .cancelDelay:
            return .options
        case .printMode, .tearOff, .cutEvery:
            return .operation
        case .dither, .threshold, .compression, .skipBlank:
            return .graphics
        case .startCommands, .endCommands, .labelStartCommands, .labelEndCommands:
            return .commands
        case .powerUpAction, .headCloseAction:
            return .maintenance
        }
    }

    /// Kann der Drucker seinen eigenen Wert behalten (`nil` in `PrintSettings`)?
    var supportsPrinterValue: Bool {
        switch self {
        case .tracking, .markOffset, .speed, .darkness, .mediaType, .labelTop, .labelLeft, .backfeed, .rtcUpdate,
             .printMode, .tearOff, .powerUpAction, .headCloseAction:
            return true
        default:
            return false
        }
    }

    /// Hat die Einstellung einen Standardwert des Treibers (`PrintSettings.default`)? Vorlage, Größe
    /// und Druckersprache gehören zum Drucker bzw. Etikett und haben keinen.
    var hasDriverDefault: Bool {
        switch self {
        case .template, .size, .language: return false
        default: return true
        }
    }

    /// Meldet der Drucker diesen Wert per SGD (`PrinterClient.readPrintSettings`)?
    var isReadable: Bool {
        switch self {
        case .tracking, .speed, .darkness, .mediaType, .labelTop, .labelLeft, .printMode, .tearOff,
             .controlCharacters, .powerUpAction, .headCloseAction:
            return true
        default:
            return false
        }
    }

    /// Wird von „An den Drucker senden“ übertragen (`PrinterClient.applySettings`).
    var isAppliedToPrinter: Bool {
        switch self {
        case .tracking, .markOffset, .speed, .darkness, .mediaType, .labelTop, .labelLeft, .backfeed, .printMode,
             .tearOff, .controlCharacters, .powerUpAction, .headCloseAction:
            return true
        default:
            return false
        }
    }

    /// Steht der Wert auf „Druckerwert“?
    func usesPrinterValue(_ d: PrintPrefsDraft) -> Bool {
        let s = d.settings
        switch self {
        case .tracking: return s.tracking == nil
        case .markOffset: return s.markOffset == nil
        case .speed: return s.speed == nil
        case .darkness: return s.darkness == nil
        case .mediaType: return s.mediaType == nil
        case .labelTop: return s.labelTop == nil
        case .labelLeft: return s.labelLeft == nil
        case .backfeed: return s.backfeed == nil
        case .rtcUpdate: return s.rtcUpdate == nil
        case .printMode: return s.printMode == nil
        case .tearOff: return s.tearOffAdjust == nil
        case .powerUpAction: return s.powerUpAction == nil
        case .headCloseAction: return s.headCloseAction == nil
        default: return false
        }
    }

    /// „Druckerwert verwenden“: kein Befehl, der Drucker behält seine Einstellung.
    func usePrinterValue(_ d: inout PrintPrefsDraft) {
        switch self {
        case .tracking: d.settings.tracking = nil
        case .markOffset: d.settings.markOffset = nil
        case .speed: d.settings.speed = nil
        case .darkness: d.settings.darkness = nil
        case .mediaType: d.settings.mediaType = nil
        case .labelTop: d.settings.labelTop = nil
        case .labelLeft: d.settings.labelLeft = nil
        case .backfeed: d.settings.backfeed = nil
        case .rtcUpdate: d.settings.rtcUpdate = nil
        case .printMode: d.settings.printMode = nil
        case .tearOff: d.settings.tearOffAdjust = nil
        case .powerUpAction: d.settings.powerUpAction = nil
        case .headCloseAction: d.settings.headCloseAction = nil
        default: break
        }
    }

    /// „Treiberwert verwenden“: setzt einen Wert – bevorzugt den zuletzt vom Drucker gelesenen,
    /// sonst einen sinnvollen Standard für Modell und Vorlage.
    @MainActor
    func useDriverValue(_ d: inout PrintPrefsDraft, printer: PrintSettings?, session: PrinterSession) {
        guard usesPrinterValue(d) else { return }
        let maxSpeed = PrintPrefsChoices.maxSpeed(session)
        switch self {
        case .tracking:
            d.settings.tracking = printer?.tracking ?? PrintPrefsChoices.templateTracking(d, session: session)
        case .markOffset: d.settings.markOffset = 0
        case .speed: d.settings.speed = (printer?.speed ?? min(4, maxSpeed)).clamped(to: 1...max(1, maxSpeed))
        case .darkness: d.settings.darkness = printer?.darkness ?? 15
        case .mediaType:
            d.settings.mediaType = printer?.mediaType ?? PrintPrefsChoices.mediaTypes(session, current: nil).first
                ?? .directThermal
        case .labelTop: d.settings.labelTop = printer?.labelTop ?? 0
        case .labelLeft: d.settings.labelLeft = printer?.labelLeft ?? 0
        case .backfeed: d.settings.backfeed = .normal
        case .rtcUpdate: d.settings.rtcUpdate = .jobStart
        case .printMode: d.settings.printMode = printer?.printMode ?? .tearOff
        case .tearOff: d.settings.tearOffAdjust = printer?.tearOffAdjust ?? 0
        case .powerUpAction: d.settings.powerUpAction = printer?.powerUpAction ?? .calibrate
        case .headCloseAction: d.settings.headCloseAction = printer?.headCloseAction ?? .calibrate
        default: break
        }
    }

    /// Setzt reine Treiberwerte auf den Standard (`PrintSettings.default`) zurück.
    func resetToDefault(_ d: inout PrintPrefsDraft) {
        let base = PrintSettings.default
        switch self {
        case .rotation:
            d.settings.rotation = base.rotation
            d.settings.rotate180 = base.rotate180
        case .mirror: d.settings.mirror = base.mirror
        case .negative: d.settings.negative = base.negative
        case .stopAtLast: d.settings.stopAtLastElement = base.stopAtLastElement
        case .stopOffset: d.settings.stopOffset = base.stopOffset
        case .pauseEvery: d.settings.pauseEvery = base.pauseEvery
        case .controlCharacters: d.settings.controlCharacters = base.controlCharacters
        case .calibrateBeforeJob: d.settings.calibrateBeforeJob = base.calibrateBeforeJob
        case .saveToPrinter: d.settings.saveToPrinter = base.saveToPrinter
        case .cancelJobs: d.settings.cancelJobsBeforePrint = base.cancelJobsBeforePrint
        case .cancelDelay: d.settings.cancelDelayMs = base.cancelDelayMs
        case .cutEvery: d.settings.cutEvery = base.cutEvery
        case .dither: d.settings.dither = base.dither
        case .threshold: d.settings.threshold = base.threshold
        case .compression: d.settings.compression = base.compression
        case .skipBlank: d.settings.skipBlankLabels = base.skipBlankLabels
        case .startCommands: d.settings.startCommands = base.startCommands
        case .endCommands: d.settings.endCommands = base.endCommands
        case .labelStartCommands: d.settings.labelStartCommands = base.labelStartCommands
        case .labelEndCommands: d.settings.labelEndCommands = base.labelEndCommands
        default: usePrinterValue(&d)
        }
    }

    /// Hat der Drucker diesen Wert gemeldet (in einer Abfrage mit leerer Basis)?
    func isReported(in read: PrintSettings) -> Bool {
        switch self {
        case .tracking: return read.tracking != nil
        case .speed: return read.speed != nil
        case .darkness: return read.darkness != nil
        case .mediaType: return read.mediaType != nil
        case .labelTop: return read.labelTop != nil
        case .labelLeft: return read.labelLeft != nil
        case .printMode: return read.printMode != nil
        case .tearOff: return read.tearOffAdjust != nil
        case .powerUpAction: return read.powerUpAction != nil
        case .headCloseAction: return read.headCloseAction != nil
        case .controlCharacters: return true
        default: return false
        }
    }

    /// Übernimmt nur diesen Wert aus vom Drucker gelesenen Einstellungen.
    func copy(from read: PrintSettings, into d: inout PrintPrefsDraft) {
        switch self {
        case .tracking: d.settings.tracking = read.tracking
        case .speed: d.settings.speed = read.speed
        case .darkness: d.settings.darkness = read.darkness
        case .mediaType: d.settings.mediaType = read.mediaType
        case .labelTop: d.settings.labelTop = read.labelTop
        case .labelLeft: d.settings.labelLeft = read.labelLeft
        case .printMode: d.settings.printMode = read.printMode
        case .tearOff: d.settings.tearOffAdjust = read.tearOffAdjust
        case .powerUpAction: d.settings.powerUpAction = read.powerUpAction
        case .headCloseAction: d.settings.headCloseAction = read.headCloseAction
        case .controlCharacters: d.settings.controlCharacters = read.controlCharacters
        default: break
        }
    }

    /// Stimmt der Wert in beiden Entwürfen überein?
    func matches(_ a: PrintPrefsDraft, _ b: PrintPrefsDraft) -> Bool {
        let x = a.settings
        let y = b.settings
        switch self {
        case .template: return a.stockID == b.stockID
        case .size: return a.widthMM == b.widthMM && a.heightMM == b.heightMM && a.gapMM == b.gapMM
        case .tracking: return x.tracking == y.tracking
        case .rotation: return x.rotation == y.rotation && x.rotate180 == y.rotate180
        case .markOffset: return x.markOffset == y.markOffset
        case .mirror: return x.mirror == y.mirror
        case .negative: return x.negative == y.negative
        case .stopAtLast: return x.stopAtLastElement == y.stopAtLastElement
        case .stopOffset: return x.stopOffset == y.stopOffset
        case .speed: return x.speed == y.speed
        case .darkness: return x.darkness == y.darkness
        case .mediaType: return x.mediaType == y.mediaType
        case .labelTop: return x.labelTop == y.labelTop
        case .labelLeft: return x.labelLeft == y.labelLeft
        case .backfeed: return x.backfeed == y.backfeed
        case .pauseEvery: return x.pauseEvery == y.pauseEvery
        case .controlCharacters: return x.controlCharacters == y.controlCharacters
        case .rtcUpdate: return x.rtcUpdate == y.rtcUpdate
        case .calibrateBeforeJob: return x.calibrateBeforeJob == y.calibrateBeforeJob
        case .saveToPrinter: return x.saveToPrinter == y.saveToPrinter
        case .language: return a.language == b.language
        case .cancelJobs: return x.cancelJobsBeforePrint == y.cancelJobsBeforePrint
        case .cancelDelay: return x.cancelDelayMs == y.cancelDelayMs
        case .printMode: return x.printMode == y.printMode
        case .tearOff: return x.tearOffAdjust == y.tearOffAdjust
        case .cutEvery: return x.cutEvery == y.cutEvery
        case .dither: return x.dither == y.dither
        case .threshold: return x.threshold == y.threshold
        case .compression: return x.compression == y.compression
        case .skipBlank: return x.skipBlankLabels == y.skipBlankLabels
        case .startCommands: return x.startCommands == y.startCommands
        case .endCommands: return x.endCommands == y.endCommands
        case .labelStartCommands: return x.labelStartCommands == y.labelStartCommands
        case .labelEndCommands: return x.labelEndCommands == y.labelEndCommands
        case .powerUpAction: return x.powerUpAction == y.powerUpAction
        case .headCloseAction: return x.headCloseAction == y.headCloseAction
        }
    }

    /// Übernimmt genau die Felder dieser Einstellung (dieselben wie in `matches(_:_:)`) aus `s` nach `t`.
    func copyValue(from s: PrintPrefsDraft, into t: inout PrintPrefsDraft) {
        switch self {
        case .template, .size:
            // Vorlage und Größe gehören zusammen: „Benutzerdefiniert“ ohne eigene Maße gibt es nicht.
            t.stockID = s.stockID
            t.widthMM = s.widthMM
            t.heightMM = s.heightMM
            t.gapMM = s.gapMM
        case .tracking: t.settings.tracking = s.settings.tracking
        case .rotation:
            t.settings.rotation = s.settings.rotation
            t.settings.rotate180 = s.settings.rotate180
        case .markOffset: t.settings.markOffset = s.settings.markOffset
        case .mirror: t.settings.mirror = s.settings.mirror
        case .negative: t.settings.negative = s.settings.negative
        case .stopAtLast: t.settings.stopAtLastElement = s.settings.stopAtLastElement
        case .stopOffset: t.settings.stopOffset = s.settings.stopOffset
        case .speed: t.settings.speed = s.settings.speed
        case .darkness: t.settings.darkness = s.settings.darkness
        case .mediaType: t.settings.mediaType = s.settings.mediaType
        case .labelTop: t.settings.labelTop = s.settings.labelTop
        case .labelLeft: t.settings.labelLeft = s.settings.labelLeft
        case .backfeed: t.settings.backfeed = s.settings.backfeed
        case .pauseEvery: t.settings.pauseEvery = s.settings.pauseEvery
        case .controlCharacters: t.settings.controlCharacters = s.settings.controlCharacters
        case .rtcUpdate: t.settings.rtcUpdate = s.settings.rtcUpdate
        case .calibrateBeforeJob: t.settings.calibrateBeforeJob = s.settings.calibrateBeforeJob
        case .saveToPrinter: t.settings.saveToPrinter = s.settings.saveToPrinter
        case .language: t.language = s.language
        case .cancelJobs: t.settings.cancelJobsBeforePrint = s.settings.cancelJobsBeforePrint
        case .cancelDelay: t.settings.cancelDelayMs = s.settings.cancelDelayMs
        case .printMode: t.settings.printMode = s.settings.printMode
        case .tearOff: t.settings.tearOffAdjust = s.settings.tearOffAdjust
        case .cutEvery: t.settings.cutEvery = s.settings.cutEvery
        case .dither: t.settings.dither = s.settings.dither
        case .threshold: t.settings.threshold = s.settings.threshold
        case .compression: t.settings.compression = s.settings.compression
        case .skipBlank: t.settings.skipBlankLabels = s.settings.skipBlankLabels
        case .startCommands: t.settings.startCommands = s.settings.startCommands
        case .endCommands: t.settings.endCommands = s.settings.endCommands
        case .labelStartCommands: t.settings.labelStartCommands = s.settings.labelStartCommands
        case .labelEndCommands: t.settings.labelEndCommands = s.settings.labelEndCommands
        case .powerUpAction: t.settings.powerUpAction = s.settings.powerUpAction
        case .headCloseAction: t.settings.headCloseAction = s.settings.headCloseAction
        }
    }

    /// Vom Drucker gelesener Wert als Text (Anzeige hinter „Druckerwert“).
    func printerValueText(_ read: PrintSettings, length: PrintPrefsLength) -> String? {
        switch self {
        case .tracking: return read.tracking.map { tr($0.displayName) }
        case .speed: return read.speed.map { PrintPrefsChoices.speedText($0) }
        case .darkness: return read.darkness.map { String($0) }
        case .mediaType: return read.mediaType.map { tr($0.displayName) }
        case .labelTop: return read.labelTop.map { length.text(dots: $0) }
        case .labelLeft: return read.labelLeft.map { length.text(dots: $0) }
        case .printMode: return read.printMode.map { tr($0.displayName) }
        case .tearOff: return read.tearOffAdjust.map { length.text(dots: $0) }
        case .powerUpAction: return read.powerUpAction.map { tr($0.displayName) }
        case .headCloseAction: return read.headCloseAction.map { tr($0.displayName) }
        default: return nil
        }
    }

    static func changes(_ a: PrintPrefsDraft, _ b: PrintPrefsDraft) -> [PrintPrefsSetting] {
        allCases.filter { !$0.matches(a, b) }
    }
}

// MARK: - Auswahllisten

/// Auswahlwerte, gefiltert nach Modell (wie die PPD des Modells).
enum PrintPrefsChoices {
    /// Reihenfolge des Windows-Dialogs („Bedienermodus“ → „Modus“).
    static let printModeOrder: [PrintMode] = [
        .tearOff, .peelOff, .cutter, .delayedCut, .rewind, .linerlessPeel, .linerlessCut, .linerlessDelayedCut,
        .linerlessRewind, .linerlessTear, .applicator, .kiosk,
    ]

    /// Reihenfolge des Windows-Dialogs („Medientyp“).
    static let trackingOrder: [MediaTracking] = [.continuous, .gap, .blackMark, .notch, .autoDetect]

    /// Reihenfolge des Windows-Dialogs („Rückzug“).
    static let backfeedOrder: [BackfeedMode] = [.off, .beforePrinting, .afterPrinting, .normal]

    @MainActor
    static func maxSpeed(_ session: PrinterSession) -> Int {
        max(2, min(14, session.model?.maxSpeed(session.resolution) ?? 14))
    }

    /// Geschwindigkeiten in Zoll/s (2 … Modellmaximum, wie die mm/s-Liste des Windows-Treibers).
    @MainActor
    static func speeds(_ session: PrinterSession, current: Int?) -> [Int] {
        var values = Array(2...maxSpeed(session))
        if let current, !values.contains(current) { values.append(current) }
        return values.sorted()
    }

    /// „102 mm/s“ (25,4 mm je Zoll, gerundet wie die PPD).
    static func speedText(_ ips: Int) -> String {
        tr("%d mm/s", Int((Double(ips) * 25.4).rounded()))
    }

    static func temperatures(current: Int?) -> [Int] {
        var values = Array(1...30)
        if let current, !values.contains(current) { values.insert(current, at: 0) }
        return values
    }

    @MainActor
    static func mediaTypes(_ session: PrinterSession, current: MediaType?) -> [MediaType] {
        var types = session.model?.mediaTypes ?? MediaType.allCases
        if types.isEmpty { types = MediaType.allCases }
        if let current, !types.contains(current) { types.append(current) }
        // Windows-Reihenfolge: Thermotransfer vor Thermo-Direkt.
        return [MediaType.thermalTransfer, .directThermal].filter { types.contains($0) }
    }

    @MainActor
    static func printModes(_ session: PrinterSession, language: PrinterLanguage, current: PrintMode?) -> [PrintMode] {
        var modes = Set(session.model?.printModes ?? PrintMode.allCases.filter { !$0.isLinerless })
        if modes.isEmpty { modes = Set(PrintMode.allCases.filter { !$0.isLinerless }) }
        // Linerless-Modi nur per ZPL (SGD media.printmode) und nur mit Linerless-Ausstattung.
        if language == .zpl, session.model?.supports(.linerless) == true {
            modes.formUnion(PrintMode.allCases.filter(\.isLinerless))
        }
        if let current { modes.insert(current) }
        return printModeOrder.filter { modes.contains($0) }
    }

    /// Medientyp der gewählten Vorlage (für „Treiberwert verwenden“).
    @MainActor
    static func templateTracking(_ d: PrintPrefsDraft, session: PrinterSession) -> MediaTracking {
        if let id = d.stockID, let stock = session.app?.stock(id: id) ?? ModelCatalog.shared.stock(id: id) {
            return stock.tracking
        }
        return .gap
    }
}

// MARK: - Editor (je Drucker)

/// Bearbeitet die Druckeinstellungen eines Druckers. Eine Instanz je Drucker, damit nicht
/// gespeicherte Eingaben einen Bereichswechsel überstehen – gespeichert wird nur mit „OK“ bzw.
/// „Übernehmen“, „Abbrechen“ verwirft sie.
@Observable
@MainActor
final class PrintPrefsEditor {
    var draft: PrintPrefsDraft
    private(set) var original: PrintPrefsDraft
    var pane: PrintPrefsPane = .page
    /// Zuletzt vom Drucker gemeldete Werte (nur gemeldete Felder sind gesetzt).
    private(set) var printerValues: PrintSettings?
    private(set) var pulseTokens: [PrintPrefsSetting: Int] = [:]
    /// Einstellung, die gerade einzeln vom Drucker gelesen wird.
    private(set) var readingSetting: PrintPrefsSetting?
    private(set) var isReadingAll = false
    /// Zuletzt an den Drucker übertragene Werte (für den Abgleich-Hinweis, überdauert Neustarts).
    private(set) var sentBaseline: PrintSettings

    private static var registry: [UUID: PrintPrefsEditor] = [:]

    static func shared(for session: PrinterSession) -> PrintPrefsEditor {
        if let existing = registry[session.id] { return existing }
        let editor = PrintPrefsEditor(session: session)
        registry[session.id] = editor
        return editor
    }

    private init(session: PrinterSession) {
        let draft = PrintPrefsDraft(session: session)
        self.draft = draft
        self.original = draft
        self.sentBaseline = PrintPrefsSyncStore.baseline(for: session.id) ?? .default
    }

    var isDirty: Bool { draft != original }
    var changedSettings: [PrintPrefsSetting] { PrintPrefsSetting.changes(draft, original) }

    func isChanged(_ setting: PrintPrefsSetting) -> Bool { !setting.matches(draft, original) }

    func hasChanges(in pane: PrintPrefsPane) -> Bool {
        changedSettings.contains { $0.pane == pane }
    }

    /// Werte, die sich vom zuletzt an den Drucker gesendeten Stand unterscheiden.
    var unsentPrinterSettings: [PrintPrefsSetting] {
        var sent = draft
        sent.settings = sentBaseline
        return PrintPrefsSetting.allCases.filter { $0.isAppliedToPrinter && !$0.matches(draft, sent) }
    }

    /// Setzt den Entwurf auf den aktuell gespeicherten Stand des Druckers auf, wenn andere Teile der
    /// App ihn inzwischen geändert haben (z. B. Formatwechsel unter „Etiketten“, Druckersprache unter
    /// „Wartung“, Wiederherstellung einer Sicherung). Hier bearbeitete Einstellungen bleiben erhalten,
    /// alle anderen übernehmen den neuen gespeicherten Wert – „OK“ überschreibt so nur, was der
    /// Benutzer in diesem Dialog geändert hat.
    func rebase(on session: PrinterSession) {
        let fresh = PrintPrefsDraft(session: session)
        guard fresh != original else { return }
        var merged = fresh
        for setting in changedSettings {
            setting.copyValue(from: draft, into: &merged)
        }
        original = fresh
        draft = merged
    }

    // MARK: Bearbeiten

    func pulse<S: Sequence>(_ settings: S) where S.Element == PrintPrefsSetting {
        for setting in settings { pulseTokens[setting, default: 0] += 1 }
    }

    func revert() {
        let changed = changedSettings
        draft = original
        pulse(changed)
    }

    /// Vorlage wählen (`nil` = „Benutzerdefiniert“): übernimmt Breite, Höhe, Lücke und Medientyp.
    func selectTemplate(_ stock: LabelStock?) {
        guard let stock else {
            draft.stockID = nil
            return
        }
        draft.stockID = stock.id
        draft.widthMM = stock.widthMM
        draft.heightMM = stock.heightMM
        draft.gapMM = stock.gapMM
        if draft.settings.tracking != stock.tracking {
            draft.settings.tracking = stock.tracking
            pulse([.tracking])
        }
    }

    /// Breite bzw. Höhe von Hand ändern schaltet auf „Benutzerdefiniert“.
    func setSize(widthMM: Double? = nil, heightMM: Double? = nil) {
        var next = draft
        if let widthMM { next.widthMM = widthMM }
        if let heightMM { next.heightMM = heightMM }
        guard next.widthMM != draft.widthMM || next.heightMM != draft.heightMM else { return }
        next.stockID = nil
        draft = next
    }

    func useAllPrinterValues() {
        let before = draft
        for setting in PrintPrefsSetting.allCases where setting.supportsPrinterValue {
            setting.usePrinterValue(&draft)
        }
        draft.settings.controlCharacters = nil
        pulse(PrintPrefsSetting.changes(before, draft))
    }

    func resetToDefaults() {
        let before = draft
        draft.settings = .default
        pulse(PrintPrefsSetting.changes(before, draft))
    }

    /// Ersetzt die Einstellungen (Profil-Import).
    func replaceSettings(_ settings: PrintSettings) {
        let before = draft
        draft.settings = settings.clamped()
        pulse(PrintPrefsSetting.changes(before, draft))
    }

    // MARK: Speichern

    /// Speichert den Entwurf als Treiber-Standard des Druckers. Bei „Benutzerdefiniert“ wird ein
    /// eigenes Etikettenformat angelegt bzw. aktualisiert. Liefert `true`, wenn sich etwas geändert hat.
    @discardableResult
    func commit(session: PrinterSession, model: AppModel) -> Bool {
        // Nur die hier geänderten Werte schreiben – Änderungen von außen bleiben erhalten.
        rebase(on: session)
        guard isDirty else { return false }
        var next = draft
        next.settings = draft.settings.clamped()
        // Inzwischen gelöschte Vorlage → die Maße als eigenes Format speichern statt einer
        // Kennung, die auf kein Format mehr zeigt.
        if let id = next.stockID, model.stock(id: id) == nil { next.stockID = nil }
        let stockID = next.stockID ?? customStockID(for: next, session: session, model: model)
        next.stockID = stockID
        var saved = session.saved
        saved.settings = next.settings
        saved.stockID = stockID
        saved.language = next.language
        if saved != session.saved { session.saved = saved }
        if let stock = model.stock(id: stockID) {
            next.widthMM = stock.widthMM
            next.heightMM = stock.heightMM
            next.gapMM = stock.gapMM
        }
        draft = next
        original = next
        return true
    }

    /// Kennungspräfix der hier erzeugten eigenen Formate (``LabelStockLibrary/customStockPrefix``).
    static var customStockPrefix: String { LabelStockLibrary.customStockPrefix }

    /// „Benutzerdefiniert 104 × 76,2 mm“ (``LabelStockLibrary/customStockName(widthMM:heightMM:)``).
    static func customStockName(widthMM: Double, heightMM: Double) -> String {
        LabelStockLibrary.customStockName(widthMM: widthMM, heightMM: heightMM)
    }

    /// Eigenes Format für „Benutzerdefiniert“: gleiches eigenes Format wiederverwenden, sonst das
    /// zuletzt hier erzeugte Format dieses Druckers aktualisieren (solange es kein anderer nutzt), sonst
    /// ein neues anlegen – gemeinsame Logik mit Assistent und manuellem Hinzufügen (``LabelStockLibrary``).
    private func customStockID(for draft: PrintPrefsDraft, session: PrinterSession, model: AppModel) -> String {
        LabelStockLibrary.customStockID(widthMM: draft.widthMM, heightMM: draft.heightMM, gapMM: draft.gapMM,
                                        tracking: draft.settings.tracking ?? session.stock.tracking,
                                        mediaType: draft.settings.mediaType, currentStock: session.stock,
                                        ownerID: session.id, model: model)
    }

    // MARK: Drucker

    /// „Vom Drucker lesen“ für eine einzelne Einstellung.
    func read(_ setting: PrintPrefsSetting, session: PrinterSession) async {
        guard setting.isReadable, readingSetting == nil, !isReadingAll else { return }
        readingSetting = setting
        defer { readingSetting = nil }
        guard let values = await session.readPrintSettings(into: PrintSettings()) else { return }
        remember(values)
        guard setting.isReported(in: values) else {
            session.app?.toast(tr("Wert nicht verfügbar"),
                               message: tr("Der Drucker meldet „%@“ nicht.", setting.summaryTitle), style: .warning)
            return
        }
        setting.copy(from: values, into: &draft)
        pulse([setting])
    }

    /// Alle lesbaren Werte vom Drucker übernehmen.
    func readAll(session: PrinterSession) async {
        guard !isReadingAll, readingSetting == nil else { return }
        isReadingAll = true
        defer { isReadingAll = false }
        guard let values = await session.readPrintSettings(into: PrintSettings()) else { return }
        remember(values)
        let before = draft
        var reported: [PrintPrefsSetting] = []
        for setting in PrintPrefsSetting.allCases where setting.isReadable && setting != .controlCharacters {
            if setting.isReported(in: values) {
                setting.copy(from: values, into: &draft)
                reported.append(setting)
            }
        }
        // Eigene Steuerzeichen nur übernehmen, wenn der Drucker welche meldet.
        if values.controlCharacters != nil {
            draft.settings.controlCharacters = values.controlCharacters
            reported.append(.controlCharacters)
        }
        let changed = PrintPrefsSetting.changes(before, draft)
        pulse(changed)
        guard !reported.isEmpty else {
            session.app?.toast(tr("Keine verwertbaren Werte"),
                               message: tr("Die Antwort des Druckers enthielt keine bekannten Einstellungen."),
                               style: .warning)
            return
        }
        if changed.isEmpty {
            session.app?.toast(tr("Einstellungen sind aktuell"),
                               message: tr("%d Werte gelesen – keine Abweichung.", reported.count), style: .info)
        } else {
            session.app?.toast(tr("Vom Drucker übernommen"),
                               message: tr("%d von %d gelesenen Werten wurden geändert. Mit „OK“ oder „Übernehmen“ speichern.",
                                           changed.count, reported.count),
                               style: .success)
        }
    }

    private func remember(_ values: PrintSettings) {
        var merged = PrintPrefsDraft(settings: printerValues ?? PrintSettings())
        for setting in PrintPrefsSetting.allCases where setting.isReadable && setting.isReported(in: values) {
            setting.copy(from: values, into: &merged)
        }
        printerValues = merged.settings
    }

    /// Merkt sich den an den Drucker gesendeten Stand.
    func markSent(_ settings: PrintSettings, session: PrinterSession, knownPrinterIDs: Set<UUID>) {
        sentBaseline = settings
        PrintPrefsSyncStore.store(settings, for: session.id, knownPrinterIDs: knownPrinterIDs)
    }
}

extension PrintPrefsDraft {
    /// Entwurf nur aus Einstellungen (ohne Vorlage), z. B. für Vergleiche.
    init(settings: PrintSettings) {
        self.settings = settings
        stockID = nil
        widthMM = 0
        heightMM = 0
        gapMM = 0
        language = .zpl
    }
}

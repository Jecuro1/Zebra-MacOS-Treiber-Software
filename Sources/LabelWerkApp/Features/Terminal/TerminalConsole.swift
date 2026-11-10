import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Aufbereitete Antwort

/// Einmal berechnete Darstellungen einer Druckerantwort (Text mit sichtbaren Steuerzeichen,
/// Klartext, Hex-Dump) – große Antworten werden für die Anzeige begrenzt.
struct TerminalRendering: Equatable, Sendable {
    static let textLimit = 64 * 1024
    static let hexLimit = 16 * 1024

    let visual: AttributedString
    let plain: String
    let hex: String
    let byteCount: Int
    let lineCount: Int
    let isTextTruncated: Bool
    let isHexTruncated: Bool

    init(data: Data) {
        let decoded = TerminalFormatter.decode(data)
        let segmented = TerminalFormatter.segments(of: decoded, limit: Self.textLimit)
        let controlColor: Color = Theme.magenta
        var visual = AttributedString()
        for segment in segmented.segments {
            var piece = AttributedString(segment.text)
            if segment.isControl {
                piece.foregroundColor = controlColor
            }
            visual.append(piece)
        }
        self.visual = visual
        self.plain = decoded
        self.byteCount = data.count
        self.lineCount = segmented.lineCount
        self.isTextTruncated = segmented.isTruncated
        self.isHexTruncated = data.count > Self.hexLimit
        self.hex = TerminalFormatter.hexDump(data.prefix(Self.hexLimit))
    }
}

// MARK: - Protokolleintrag

struct TerminalEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case command(TerminalInputMode)
        case file(name: String)
    }

    enum Outcome: Equatable {
        case pending
        case response(Data, TerminalRendering)
        /// Innerhalb des Zeitlimits kam nichts zurück (bei vielen Befehlen normal).
        case silent
        /// Verbindung kann nicht antworten (z. B. macOS-Warteschlange).
        case sendOnly
        /// Datei vollständig übertragen.
        case sent
        case failed(String)
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Eingabe, wie sie angezeigt wird (bzw. Dateiname).
    let input: String
    /// Tatsächlich gesendeter Text, falls er von der Eingabe abweicht (SGD-Kurzformen).
    let expandedPayload: String?
    let bytesSent: Int
    let timeoutSeconds: Int
    var outcome: Outcome
    var duration: TimeInterval?

    init(kind: Kind, input: String, expandedPayload: String?, bytesSent: Int, timeoutSeconds: Int,
         outcome: Outcome = .pending, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.input = input
        self.expandedPayload = expandedPayload
        self.bytesSent = bytesSent
        self.timeoutSeconds = timeoutSeconds
        self.outcome = outcome
        self.duration = nil
    }

    var mode: TerminalInputMode? {
        if case .command(let mode) = kind { return mode }
        return nil
    }

    var isPending: Bool { outcome == .pending }

    /// Ungefährer Speicherbedarf (Eingabe, Rohantwort, Klartext und Hex-Dump) für das Speicherbudget.
    var retainedBytes: Int {
        var total = input.utf8.count + (expandedPayload?.utf8.count ?? 0)
        if case .response(let data, let rendering) = outcome {
            total += data.count + rendering.plain.utf8.count + rendering.hex.utf8.count
        }
        return total
    }
}

// MARK: - Konsole

/// Zustand des Terminals je Drucker (Protokoll, Entwurf, Modus). Bleibt beim Wechsel der Tabs
/// und während laufender Anfragen erhalten.
@Observable
@MainActor
final class TerminalConsole {
    private static var consoles: [UUID: TerminalConsole] = [:]

    /// Konsole für einen Drucker (wird bei Bedarf angelegt).
    static func console(for printerID: UUID) -> TerminalConsole {
        if let existing = consoles[printerID] { return existing }
        let console = TerminalConsole()
        consoles[printerID] = console
        return console
    }

    /// Gibt die Konsole eines entfernten Druckers frei (Protokoll samt Antworten).
    static func discard(printerID: UUID) {
        consoles[printerID] = nil
    }

    /// Gibt alle Konsolen frei, deren Drucker nicht mehr eingerichtet ist.
    static func discardAll(except printerIDs: Set<UUID>) {
        consoles = consoles.filter { printerIDs.contains($0.key) }
    }

    static let maxEntries = 400
    /// Obergrenze für den Speicher aller Einträge einer Konsole; älteste Einträge fallen zuerst weg.
    static let maxRetainedBytes = 24 * 1024 * 1024

    private(set) var entries: [TerminalEntry] = []
    var input: String = ""
    var mode: TerminalInputMode = .zpl
    private(set) var isSending = false
    /// Steigt bei jeder Änderung des Protokolls (für automatisches Scrollen).
    private(set) var revision = 0
    /// Sensible Eingaben (Passwörter …) nur für diese Sitzung.
    private(set) var volatileHistory: [String] = []

    private init() {}

    // MARK: Senden

    /// Sendet `text` und trägt die Antwort ins Protokoll ein. Liefert false, wenn nichts gesendet wurde.
    @discardableResult
    func submit(_ text: String, mode: TerminalInputMode, timeoutSeconds: Int,
                session: PrinterSession, reduceMotion: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return false }
        let prepared = TerminalComposer.prepare(text, mode: mode)
        guard !prepared.payload.isEmpty else { return false }
        let entry = TerminalEntry(kind: .command(mode), input: trimmed,
                                  expandedPayload: prepared.wasExpanded ? prepared.payload : nil,
                                  bytesSent: prepared.payload.utf8.count, timeoutSeconds: timeoutSeconds)
        append(entry, reduceMotion: reduceMotion)
        isSending = true
        let started = Date()
        let payload = prepared.payload
        Task { [weak self] in
            let response = await session.terminal(payload, timeout: .seconds(timeoutSeconds))
            let elapsed = Date().timeIntervalSince(started)
            let outcome: TerminalEntry.Outcome
            if let response {
                if response.isEmpty {
                    outcome = session.supportsStatus ? .silent : .sendOnly
                } else {
                    let rendering = await Task.detached(priority: .userInitiated) {
                        TerminalRendering(data: response)
                    }.value
                    outcome = .response(response, rendering)
                }
            } else {
                outcome = .failed(session.lastError ?? tr("Senden fehlgeschlagen."))
            }
            self?.finish(entry.id, outcome: outcome, duration: elapsed, reduceMotion: reduceMotion)
        }
        return true
    }

    /// Liest eine Datei und sendet sie unverändert an den Drucker.
    func sendFile(at url: URL, session: PrinterSession, model: AppModel, reduceMotion: Bool) {
        guard !isSending else { return }
        isSending = true
        Task { [weak self] in
            let name = url.lastPathComponent
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
            } catch {
                model.toast(tr("Datei konnte nicht gelesen werden"), message: error.localizedDescription, style: .error)
                self?.isSending = false
                return
            }
            guard let self else { return }
            let entry = TerminalEntry(kind: .file(name: name), input: name, expandedPayload: nil,
                                      bytesSent: data.count, timeoutSeconds: 0)
            self.append(entry, reduceMotion: reduceMotion)
            let started = Date()
            let ok = await session.sendData(data, title: name)
            let outcome: TerminalEntry.Outcome = ok ? .sent : .failed(session.lastError ?? tr("Übertragung fehlgeschlagen."))
            self.finish(entry.id, outcome: outcome, duration: Date().timeIntervalSince(started),
                        reduceMotion: reduceMotion)
        }
    }

    // MARK: Protokoll

    func append(_ entry: TerminalEntry, reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : Motion.spring) {
            entries.append(entry)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
            trimToBudget()
        }
        revision += 1
    }

    private func finish(_ id: UUID, outcome: TerminalEntry.Outcome, duration: TimeInterval, reduceMotion: Bool) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            withAnimation(reduceMotion ? nil : Motion.spring) {
                entries[index].outcome = outcome
                entries[index].duration = duration
                trimToBudget()
            }
        }
        isSending = false
        revision += 1
    }

    /// Entfernt die ältesten Einträge, bis das Speicherbudget eingehalten ist (der neueste bleibt immer).
    private func trimToBudget() {
        var total = entries.reduce(0) { $0 + $1.retainedBytes }
        guard total > Self.maxRetainedBytes else { return }
        var dropCount = 0
        while total > Self.maxRetainedBytes && dropCount < entries.count - 1 {
            total -= entries[dropCount].retainedBytes
            dropCount += 1
        }
        if dropCount > 0 { entries.removeFirst(dropCount) }
    }

    func clear(reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : Motion.spring) {
            entries.removeAll()
        }
        revision += 1
    }

    // MARK: Verlauf

    /// Merkt sich eine Eingabe: dauerhaft (für alle Drucker), außer sie ist sensibel oder zu groß –
    /// solche Einträge bleiben nur für diese Sitzung erhalten.
    func remember(_ text: String) {
        let item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty else { return }
        if TerminalHistory.isPersistable(item) {
            TerminalHistoryStore.shared.remember(item)
        } else {
            rememberVolatile(item)
        }
    }

    func rememberVolatile(_ item: String) {
        volatileHistory = TerminalHistory.adding(item, to: volatileHistory)
    }

    func clearVolatileHistory() {
        volatileHistory.removeAll()
    }

    // MARK: Export

    /// Lesbares Protokoll (Zeitstempel, Eingaben, Antworten mit sichtbaren Steuerzeichen).
    func transcriptText(printerName: String) -> String {
        let timeFormat = Date.FormatStyle.dateTime
            .year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .secondFraction(.fractional(3))
        var lines: [String] = [
            tr("LabelWerk – Terminalprotokoll für %@", printerName),
            tr("Erstellt: %@", Date().formatted(date: .abbreviated, time: .standard)),
            "",
        ]
        for entry in entries {
            let time = entry.date.formatted(timeFormat)
            switch entry.kind {
            case .command(let mode):
                lines.append("[\(time)] → (\(mode.title)) \(entry.input)")
            case .file(let name):
                lines.append("[\(time)] → " + tr("Datei „%@“ (%@)", name, TerminalFormatter.byteText(entry.bytesSent)))
            }
            if let expanded = entry.expandedPayload {
                lines.append("    " + tr("gesendet als: %@", TerminalFormatter.visibleString(expanded)))
            }
            switch entry.outcome {
            case .pending:
                lines.append("← " + tr("(Antwort steht noch aus)"))
            case .response(_, let rendering):
                lines.append("← " + TerminalFormatter.byteText(rendering.byteCount))
                lines.append(TerminalFormatter.visibleString(rendering.plain))
            case .silent:
                lines.append("← " + tr("(keine Antwort innerhalb von %d s)", entry.timeoutSeconds))
            case .sendOnly:
                lines.append("← " + tr("(nur gesendet – Verbindung liefert keine Antworten)"))
            case .sent:
                lines.append("← " + tr("(übertragen)"))
            case .failed(let message):
                lines.append("← " + tr("Fehler: %@", message))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Gespeicherter Eingabeverlauf

/// Dauerhafter Eingabeverlauf (gemeinsam für alle Drucker). Wird einmal aus den Benutzereinstellungen
/// gelesen und danach nur noch beim Ändern geschrieben – die Ansicht dekodiert nichts pro Tastendruck.
@Observable
@MainActor
final class TerminalHistoryStore {
    static let shared = TerminalHistoryStore()

    private(set) var items: [String]
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: TerminalHistory.storageKey) ?? "[]"
        let decoded = TerminalHistory.decode(raw)
        // Ältere Versionen haben auch sehr große Eingaben gespeichert – beim Laden aussortieren.
        let kept = Array(decoded.filter { TerminalHistory.isPersistable($0) }.prefix(TerminalHistory.limit))
        self.items = kept
        if kept.count != decoded.count {
            defaults.set(TerminalHistory.encode(kept), forKey: TerminalHistory.storageKey)
        }
    }

    func remember(_ item: String) {
        guard TerminalHistory.isPersistable(item) else { return }
        items = TerminalHistory.adding(item, to: items)
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        defaults.set(TerminalHistory.encode(items), forKey: TerminalHistory.storageKey)
    }
}

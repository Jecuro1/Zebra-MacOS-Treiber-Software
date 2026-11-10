import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Typen der Oberfläche

/// Unterbereiche der RFID-Seite.
enum RFIDTab: String, CaseIterable, Identifiable, Hashable {
    case read
    case write
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: return tr("Tag lesen")
        case .write: return tr("Tag schreiben")
        case .settings: return tr("Einstellungen & Kalibrierung")
        }
    }

    var systemImage: String {
        switch self {
        case .read: return "wave.3.right"
        case .write: return "square.and.pencil"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Was die Antenne gerade tut (steuert die Illustration).
enum RFIDRadioActivity: Equatable {
    case idle
    case reading
    case writing
    case calibrating

    var isActive: Bool { self != .idle }

    var tint: Color {
        switch self {
        case .idle: return Theme.ready
        case .reading: return Theme.teal
        case .writing: return Theme.violet
        case .calibrating: return Theme.warning
        }
    }

    var displayName: String {
        switch self {
        case .idle: return tr("Bereit")
        case .reading: return tr("Liest …")
        case .writing: return tr("Kodiert …")
        case .calibrating: return tr("Kalibriert …")
        }
    }
}

/// Ein Lesevorgang im Verlauf.
struct RFIDReadRecord: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let bank: RFIDMemoryBank
    let byteCount: Int
    let hex: String
    /// PC-Wort (nur EPC-Bank).
    let pcWord: String?
    let decoded: RFIDDecodedInfo?

    /// EPC-Länge laut PC-Wort.
    var reportedEPCBits: Int? { pcWord.flatMap { RFIDHex.epcBits(fromPCWord: $0) } }
    var bits: Int { hex.count * 4 }
}

/// Ergebnis eines einzelnen Tags im Kodierauftrag.
enum RFIDWriteState: Hashable {
    /// An den Drucker übertragen (ohne Prüfung).
    case sent
    /// Zurückgelesen und identisch.
    case verified
    /// Zurückgelesener Wert weicht ab bzw. fehlt (Tag vermutlich VOID).
    case mismatch(String?)
    /// Übertragung fehlgeschlagen.
    case failed
    /// Beim Anhalten noch im Drucker wartend und dort verworfen (~JA) – nicht kodiert.
    case discarded

    var isSuccess: Bool { self == .sent || self == .verified }

    var title: String {
        switch self {
        case .sent: return tr("Gesendet")
        case .verified: return tr("Geprüft")
        case .mismatch(let value): return value == nil ? tr("Keine Rückmeldung (VOID?)") : tr("Abweichung")
        case .failed: return tr("Fehlgeschlagen")
        case .discarded: return tr("Verworfen")
        }
    }

    var systemImage: String {
        switch self {
        case .sent: return "paperplane.fill"
        case .verified: return "checkmark.seal.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .discarded: return "xmark.bin"
        }
    }

    var tint: Color {
        switch self {
        case .sent: return Theme.printing
        case .verified: return Theme.ready
        case .mismatch: return Theme.warning
        case .failed: return Theme.error
        case .discarded: return Theme.offline
        }
    }
}

struct RFIDWriteEntry: Identifiable, Hashable {
    /// Laufende Nummer (1-basiert).
    let id: Int
    let hex: String
    var state: RFIDWriteState
    let date: Date
}

/// Fortschritt und Protokoll eines Kodierauftrags.
struct RFIDWriteRun: Equatable {
    let id: UUID
    let total: Int
    let verify: Bool
    let startedAt: Date
    var completed = 0
    /// Neueste zuerst; nur die letzten `RFIDWriteRun.visibleEntryLimit` Einträge (Anzeige).
    var entries: [RFIDWriteEntry] = []
    /// Zähler über den gesamten Auftrag – unabhängig von der gekürzten Liste `entries`.
    var successTotal = 0
    var failureTotal = 0
    /// Beim Anhalten im Drucker verworfene Tags – weder erfolgreich noch fehlerhaft, nicht erledigt.
    var discardedTotal = 0
    var isRunning = true
    var wasCancelled = false
    var finishedAt: Date?

    /// Höchstzahl der im Protokoll gehaltenen Einträge.
    static let visibleEntryLimit = 500

    var successCount: Int { successTotal }
    var failureCount: Int { failureTotal }
    var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    /// Zählt ein Ergebnis in die Summen ein (`sign` = 1) bzw. wieder heraus (`sign` = -1).
    mutating func tally(_ state: RFIDWriteState, sign: Int) {
        switch state {
        case .sent, .verified: successTotal += sign
        case .mismatch, .failed: failureTotal += sign
        case .discarded: discardedTotal += sign
        }
    }
}

/// Umfang der gesendeten Druckdaten eines Kodierauftrags (für den Verlauf). Die Daten selbst werden
/// bewusst nicht gespeichert: Sie enthalten die fortlaufenden EPCs dieses Auftrags – „Erneut drucken“
/// würde dieselben Seriennummern ein zweites Mal kodieren.
private struct RFIDSentLog {
    private(set) var formatCount = 0
    private(set) var bytes = 0

    var isEmpty: Bool { formatCount == 0 }

    mutating func append(_ text: String, formats: Int) {
        formatCount += formats
        bytes += text.utf8.count
    }
}

// MARK: - Arbeitsbereich

/// Zustand und Abläufe der RFID-Seite eines Druckers. Bleibt für die Laufzeit der App erhalten
/// (Leseverlauf, Kalibrierergebnis, laufender Kodierauftrag), auch wenn der Bereich gewechselt wird.
@Observable
@MainActor
final class RFIDWorkbench {
    let sessionID: UUID

    var tab: RFIDTab = .read

    // Status
    private(set) var status: RFIDStatusValues?
    private(set) var isLoadingStatus = false
    private(set) var statusLoadedAt: Date?
    /// Letzte Statusabfrage scheiterte an der Verbindung (nil nach erfolgreicher Abfrage).
    private(set) var statusError: String?
    /// Werkzeuge trotz nicht erkanntem Modul anzeigen.
    var forceUnlocked = false

    // Lesen
    var readBank: RFIDMemoryBank = .epc
    private(set) var readLengths: [RFIDMemoryBank: Int] = [:]
    private(set) var isReading = false
    private(set) var lastRead: RFIDReadRecord?
    private(set) var readError: String?
    private(set) var lastRawResponse: String?
    /// Neueste zuerst; höchstens `readHistoryLimit` Einträge.
    private(set) var readHistory: [RFIDReadRecord] = []
    /// Erfolgreiche Lesevorgänge seit dem letzten Leeren (auch über die gekürzte Liste hinaus).
    private(set) var readTotal = 0

    // Schreiben
    var writeOptions = RFIDWriteOptions()
    private(set) var writeRun: RFIDWriteRun?
    private(set) var writeError: String?
    /// Hinweis während eines Kodierauftrags, z. B. wenn der Drucker angehalten ist (nil = keiner).
    private(set) var writeNotice: String?
    private(set) var celebration = 0

    // Kalibrierung
    private(set) var calibration: RFIDCalibrationResult?
    private(set) var isCalibrating = false
    private(set) var calibrationError: String?
    private(set) var calibratedAt: Date?

    // Alle RFID-Einstellungen
    private(set) var settingRows: [RFIDSettingRow] = []
    private(set) var isLoadingSettings = false
    private(set) var settingsLoadedAt: Date?
    /// Letztes Lesen der Einstellungen scheiterte an der Verbindung.
    private(set) var settingsError: String?
    private(set) var flashedSetting: String?

    // Animationsauslöser
    private(set) var successPulse = 0
    private(set) var failurePulse = 0

    /// Wird von der Ansicht gesetzt („Bewegung reduzieren“ aus System und App).
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false
    /// Laufende Abläufe, die die Statusüberwachung pausiert haben.
    @ObservationIgnored private var monitoringPauses = 0
    /// Zuletzt vergebene Nummer für die Köpfe der ^HV-Antworten (Lesen und Kodieren mit Prüfung).
    @ObservationIgnored private var replySequence = 0

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    // MARK: Abgeleitete Werte

    var isWriting: Bool { writeRun?.isRunning == true }
    var isBusy: Bool { isReading || isWriting || isCalibrating }

    var radioActivity: RFIDRadioActivity {
        if isCalibrating { return .calibrating }
        if isWriting { return .writing }
        if isReading { return .reading }
        return .idle
    }

    func readLength(for bank: RFIDMemoryBank) -> Int {
        readLengths[bank] ?? bank.defaultLength
    }

    func setReadLength(_ byteCount: Int, for bank: RFIDMemoryBank) {
        readLengths[bank] = byteCount
    }

    private func animate(_ animation: Animation = Motion.spring, _ changes: () -> Void) {
        withAnimation(Motion.animation(animation, reduceMotion: reduceMotion), changes)
    }

    /// Sendet `input` und sammelt weitere Antwortteile, bis `isComplete` erfüllt ist oder `budget`
    /// (nach der ersten Antwort) verstrichen ist. Stille Abschnitte (leere Antworten) verlängern das
    /// Warten nur innerhalb des Budgets – beim Kalibrieren transportiert der Drucker zwischendurch
    /// Etiketten und schweigt dabei. Abgebrochen wird nur bei einem Verbindungsfehler.
    private func collect(session: PrinterSession, _ input: String, timeout: Duration, followUp: Duration,
                         budget: Duration, isComplete: (String) -> Bool) async -> Data? {
        guard var data = await session.terminal(input, timeout: timeout) else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        while !isComplete(RFIDResponseParser.text(data)) {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            guard let more = await session.terminal("", timeout: min(followUp, remaining)) else { break }
            data.append(more)
        }
        return data
    }

    // MARK: Statusüberwachung

    /// Pausiert die Statusabfragen (~HS) der Sitzung für lange Terminal-Dialoge (^HV, ^HR), damit
    /// sich Status- und RFID-Antworten auf derselben Verbindung nicht vermischen. Verbindet vorher
    /// bei Bedarf, weil ein Verbindungsaufbau die Überwachung selbst wieder startet.
    private func pauseMonitoring(_ session: PrinterSession) async {
        monitoringPauses += 1
        if !session.connectionState.isConnected { await session.connect() }
        session.stopMonitoring()
    }

    /// Nimmt die Statusabfragen wieder auf, sobald kein Ablauf mehr pausiert (nicht nach einer
    /// bewussten Trennung). Die Überwachung verbindet auch eine fehlgeschlagene Sitzung erneut.
    private func resumeMonitoring(_ session: PrinterSession) {
        monitoringPauses = max(0, monitoringPauses - 1)
        guard monitoringPauses == 0, session.connectionState != .disconnected else { return }
        session.startMonitoring()
    }

    /// Fragt während eines langen Auftrags (Überwachung pausiert) den Druckerstatus ab – nacheinander
    /// mit den RFID-Daten statt parallel dazu. So erscheinen Warnungen (Papier leer, Kopf offen) weiterhin.
    /// Hat ein erneuter Verbindungsaufbau die Überwachung zwischendurch wieder gestartet, wird sie
    /// erneut pausiert (der erste Abfragetakt folgt frühestens nach einer Sekunde).
    private func pollPrinterStatusIfDue(_ session: PrinterSession, lastPoll: inout Date) async {
        session.stopMonitoring()
        let interval = max(1, session.app?.preferences.pollInterval ?? 3)
        guard Date().timeIntervalSince(lastPoll) >= interval else { return }
        await session.refreshStatus()
        lastPoll = Date()
    }

    // MARK: Status

    func refreshStatus(session: PrinterSession) async {
        guard !isLoadingStatus else { return }
        animate { isLoadingStatus = true }
        let values = await session.getvars(RFIDStatusValues.keys)
        // Ein Übertragungsfehler liefert ebenfalls keine Werte – dann nicht „kein Kodierer“ melden,
        // sondern den Fehler zeigen und die zuletzt gelesenen Werte behalten.
        if values.isEmpty, let error = session.lastError {
            animate {
                statusError = error
                isLoadingStatus = false
            }
            return
        }
        animate {
            status = RFIDStatusValues(values: values)
            statusError = nil
            statusLoadedAt = Date()
            isLoadingStatus = false
        }
    }

    /// Schaltet das RFID-Modul ein bzw. aus (`rfid.enable`).
    func setEnabled(_ enabled: Bool, session: PrinterSession) async {
        guard !isBusy else { return }
        await apply(RFIDStatusValues.enableKey, value: enabled ? "on" : "off", session: session)
    }

    // MARK: Lesen

    func read(session: PrinterSession) async {
        guard !isBusy else { return }
        let bank = readBank
        let byteCount = readLength(for: bank)
        // Köpfe mit Auftragsnummer: Eine verspätete Antwort eines früheren Lesevorgangs (z. B. bei
        // angehaltenem Drucker) steht vor der neuen Antwort, gilt aber nicht als deren Ergebnis.
        replySequence += 1
        let request = replySequence
        let header = RFIDCommand.header(bank.responseHeader, request: request)
        let format = RFIDCommand.readFormat(bank: bank, byteCount: byteCount, includePCWord: bank == .epc,
                                            request: request)
        animate {
            isReading = true
            readError = nil
        }
        await pauseMonitoring(session)
        defer { resumeMonitoring(session) }
        let response = await collect(session: session, format, timeout: .seconds(4), followUp: .seconds(2),
                                     budget: .seconds(2)) { text in
            RFIDResponseParser.containsHeader(text, header: header)
        }
        guard let response else {
            finishRead(error: session.lastError ?? tr("Keine Verbindung zum Drucker. Bitte Verbindung prüfen und erneut versuchen."),
                       raw: nil)
            return
        }
        let text = RFIDResponseParser.text(response)
        let raw = RFIDResponseParser.compact(response)
        guard let hex = RFIDResponseParser.hexValue(in: text, header: header,
                                                    expectedDigits: byteCount * 2) else {
            let message: String
            if raw.isEmpty {
                message = tr("Keine Antwort innerhalb von 6 Sekunden. Ist ein RFID-Kodierer eingebaut und aktiviert, und arbeitet der Drucker im ZPL-Modus?")
            } else if RFIDResponseParser.containsHeader(text, header: header) {
                message = tr("Kein Tag erkannt. Liegt ein RFID-Etikett über der Antenne? Programmierposition und Sendeleistung prüfen oder kalibrieren.")
            } else {
                message = tr("Unerwartete Antwort des Druckers – Details siehe Rohantwort.")
            }
            finishRead(error: message, raw: raw.isEmpty ? nil : raw)
            return
        }
        let pcWord = bank == .epc
            ? RFIDResponseParser.hexValue(in: text, header: RFIDCommand.header(RFIDCommand.pcHeader, request: request),
                                          expectedDigits: 4)
            : nil
        let decoded: RFIDDecodedInfo?
        switch bank {
        case .epc: decoded = RFIDEPCDecoder.decode(hex: hex)
        case .tid: decoded = RFIDTIDDecoder.decode(hex: hex)
        case .user, .reserved:
            decoded = RFIDHex.printableASCII(hex).map {
                RFIDDecodedInfo(title: tr("Freie Daten"), items: [RFIDInfoItem(label: tr("Als Text"), value: $0)])
            }
        }
        let record = RFIDReadRecord(id: UUID(), date: Date(), bank: bank, byteCount: byteCount, hex: hex,
                                    pcWord: pcWord, decoded: decoded)
        animate {
            isReading = false
            lastRead = record
            lastRawResponse = raw
            readHistory.insert(record, at: 0)
            if readHistory.count > RFIDWorkbench.readHistoryLimit {
                readHistory.removeLast(readHistory.count - RFIDWorkbench.readHistoryLimit)
            }
            readTotal += 1
        }
        successPulse += 1
    }

    private func finishRead(error: String, raw: String?) {
        animate {
            isReading = false
            readError = error
            lastRawResponse = raw
        }
        failurePulse += 1
    }

    /// Liest erneut mit der vom Tag gemeldeten EPC-Länge.
    func rereadEPC(byteCount: Int, session: PrinterSession) async {
        readBank = .epc
        setReadLength(byteCount, for: .epc)
        await read(session: session)
    }

    func clearReadHistory() {
        animate {
            readHistory.removeAll()
            readTotal = 0
            lastRead = nil
            readError = nil
            lastRawResponse = nil
        }
    }

    /// Übernimmt einen gelesenen EPC als Startwert zum Schreiben.
    func useAsWriteTemplate(_ record: RFIDReadRecord) {
        animate {
            writeOptions.startHex = RFIDHex.grouped(record.hex)
            tab = .write
        }
    }

    // MARK: Schreiben

    func startWrite(session: PrinterSession) {
        guard !isBusy else { return }
        let options = writeOptions
        let values: [String]
        switch RFIDEncoder.plan(options) {
        case .success(let planned):
            values = planned
        case .failure(let error):
            animate { writeError = error.message }
            failurePulse += 1
            return
        }
        let geometry = RFIDLabelGeometry(widthDots: session.labelWidthDots, heightDots: session.labelHeightDots,
                                         dotsPerMM: session.resolution.dotsPerMM)
        cancelRequested = false
        animate {
            writeError = nil
            writeNotice = nil
            writeRun = RFIDWriteRun(id: UUID(), total: values.count, verify: options.verify, startedAt: Date())
        }
        writeTask = Task { [weak self] in
            guard let self else { return }
            await self.performWrite(values: values, options: options, geometry: geometry, session: session)
        }
    }

    /// Hält den Auftrag nach dem laufenden Tag an. Formate, die dann noch im Drucker warten, werden
    /// dort verworfen (~JA).
    func cancelWrite() {
        cancelRequested = true
    }

    func dismissWriteRun() {
        guard !isWriting else { return }
        animate {
            writeRun = nil
            writeError = nil
        }
    }

    /// Höchstzahl der im Leseverlauf gehaltenen Einträge.
    static let readHistoryLimit = 200

    /// Größe eines Blocks ohne Prüfung.
    private static let maxBlockSize = 25

    /// Ausgang des Wartens auf die Prüfantwort eines Tags.
    private enum VerifyWait {
        /// Kopf empfangen – mit zurückgelesenem EPC oder ohne Daten (`nil`).
        case answered(String?)
        /// Der Drucker hat das Format abgearbeitet, ohne zu antworten.
        case noAnswer
        /// Angehalten, während das Format noch im Drucker wartete – dort verworfen.
        case discarded
        /// Angehalten, ohne dass feststeht, ob der Drucker das Format noch kodiert.
        case unconfirmed
        case connectionLost
    }

    /// Ausgang des Wartens auf Platz im Empfangspuffer des Druckers.
    private enum BufferWait {
        case ready
        case cancelled
        case connectionLost
    }

    private func performWrite(values: [String], options: RFIDWriteOptions, geometry: RFIDLabelGeometry,
                              session: PrinterSession) async {
        var log = RFIDSentLog()
        // Über das Terminal gesendet und (mit Prüfung) zurückgelesen: Die regelmäßigen ~HS-Abfragen
        // pausieren und stattdessen zwischen den Tags bzw. Blöcken nacheinander abfragen.
        await pauseMonitoring(session)
        defer { resumeMonitoring(session) }
        var lastStatusPoll = Date()

        if options.verify {
            // Je Tag ein Format; ^HV liefert den zurückgelesenen EPC mit einem je Tag eindeutigen Kopf
            // (EPC#<nr>:). Das nächste Format geht erst hinaus, wenn die Antwort da ist oder der Drucker
            // das Format nachweislich ohne Antwort abgearbeitet hat: Eine verspätete Antwort gilt so nie
            // als Antwort des nächsten Tags, und ein angehaltener Drucker sammelt keine Formate an.
            let firstReply = replySequence + 1
            replySequence += values.count
            let digits = values.first?.count ?? 0
            var states: [Int: RFIDWriteState] = [:]
            /// Wertet die Prüfantworten in `data` aus: Antworten früherer Tags (z. B. nach einer
            /// VOID-Wiederholung) berichtigen deren Eintrag, die (letzte) Antwort von Tag `number` wird
            /// geliefert. Antworten anderer Aufträge tragen fremde Nummern und bleiben unbeachtet.
            func answer(for number: Int, in data: Data) -> RFIDVerification? {
                var own: RFIDVerification?
                let text = RFIDResponseParser.text(data)
                for reply in RFIDResponseParser.verifications(in: text, expectedDigits: digits) {
                    let tag = reply.number - firstReply + 1
                    if tag == number {
                        own = reply
                    } else if tag >= 1, tag < number, let previous = states[tag] {
                        let corrected = RFIDWorkbench.verifiedState(expected: values[tag - 1], readBack: reply.hex)
                        states[tag] = corrected
                        updateEntries([tag], from: previous, to: corrected)
                    }
                }
                return own
            }

            for (index, epc) in values.enumerated() {
                if cancelRequested || Task.isCancelled { break }
                let number = index + 1
                let format = RFIDEncoder.encodeFormat(epc: epc, number: number, options: options, geometry: geometry,
                                                      reply: firstReply + index)
                let state: RFIDWriteState
                if let data = await jobTerminal(session, format, timeout: .seconds(8)) {
                    log.append(format, formats: 1)
                    if let reply = answer(for: number, in: data) {
                        state = RFIDWorkbench.verifiedState(expected: epc, readBack: reply.hex)
                    } else {
                        switch await awaitVerification(of: number, session: session,
                                                       answer: { answer(for: number, in: $0) }) {
                        case .answered(let readBack):
                            state = RFIDWorkbench.verifiedState(expected: epc, readBack: readBack)
                        case .noAnswer:
                            state = .mismatch(nil)
                        case .discarded:
                            state = .discarded
                        case .unconfirmed:
                            state = .sent
                            animate {
                                writeError = tr("Tag %d ist noch nicht bestätigt: Der Drucker hat das Etikett begonnen und kodiert es ungeprüft zu Ende, sobald er weiterläuft.", number)
                            }
                        case .connectionLost:
                            state = .failed
                        }
                    }
                } else {
                    state = .failed
                }
                states[number] = state
                appendEntry(RFIDWriteEntry(id: number, hex: epc, state: state, date: Date()),
                            completed: state == .discarded ? index : number)
                if state == .failed {
                    animate { writeError = session.lastError ?? tr("Die Verbindung zum Drucker wurde unterbrochen.") }
                    break
                }
                await pollPrinterStatusIfDue(session, lastPoll: &lastStatusPoll)
            }
        } else {
            // Ohne Prüfung in Blöcken senden – im Takt des Druckers: Der nächste Block folgt erst, wenn
            // höchstens noch ein halber Block im Empfangspuffer wartet und der Drucker nicht angehalten
            // ist. So bleibt er ausgelastet, „Anhalten“ wirkt bis zum letzten Etikett, und beim Anhalten
            // verwirft ~JA die Formate, die noch im Drucker warten. Der Auftrag erscheint nur einmal im
            // Verlauf (Sammeleintrag in `finishWrite`).
            let chunkSize = min(RFIDWorkbench.maxBlockSize, max(1, Int((Double(values.count) / 10.0).rounded(.up))))
            let refillBelow = max(1, chunkSize / 2)
            var start = 0
            var stopped = false
            while start < values.count {
                if cancelRequested || Task.isCancelled { break }
                if start > 0 {
                    switch await awaitPrinterBuffer(below: refillBelow, session: session, waitingNotice: nil) {
                    case .ready:
                        break
                    case .cancelled:
                        stopped = true
                    case .connectionLost:
                        animate { writeError = session.lastError ?? tr("Die Verbindung zum Drucker wurde unterbrochen.") }
                        stopped = true
                    }
                    if stopped { break }
                }
                let end = min(values.count, start + chunkSize)
                let payload = (start..<end).map { position in
                    RFIDEncoder.encodeFormat(epc: values[position], number: position + 1, options: options,
                                             geometry: geometry)
                }
                .joined()
                // Kurze Antwortfrist: ohne ^HV antwortet der Drucker nicht, es geht nur ums Senden.
                let ok = await jobTerminal(session, payload, timeout: .milliseconds(50)) != nil
                if ok { log.append(payload, formats: end - start) }
                for position in start..<end {
                    appendEntry(RFIDWriteEntry(id: position + 1, hex: values[position], state: ok ? .sent : .failed,
                                               date: Date()),
                                completed: position + 1)
                }
                if !ok {
                    animate { writeError = session.lastError ?? tr("Die Daten konnten nicht gesendet werden.") }
                    stopped = true
                    break
                }
                start = end
                await pollPrinterStatusIfDue(session, lastPoll: &lastStatusPoll)
            }
            // Bis der Drucker alle Formate übernommen hat, läuft der Auftrag weiter – so lange lässt er
            // sich noch anhalten. (Ein Verbindungsfehler hier ändert nichts mehr am Gesendeten.)
            if !stopped, start == values.count, !cancelRequested {
                _ = await awaitPrinterBuffer(below: 1, session: session,
                                             waitingNotice: tr("Der Drucker kodiert die letzten Tags …"))
            }
            if cancelRequested, start > 0, writeError == nil {
                await discardQueuedFormats(sent: start, session: session)
            }
        }

        await finishWrite(options: options, geometry: geometry, values: values, log: log, session: session)
    }

    /// Ergebnis eines Tags mit Prüfung.
    private static func verifiedState(expected: String, readBack: String?) -> RFIDWriteState {
        readBack == expected ? .verified : .mismatch(readBack)
    }

    /// Grund, warum der Drucker gerade nicht arbeitet (`nil` = bereit).
    private static func stallReason(_ host: HostStatus) -> String? {
        if host.headOpen { return tr("Druckkopf offen") }
        if host.paperOut { return tr("Etiketten leer") }
        // Wie `StatusInterpreter`: „Farbband leer“ zählt nur im Thermotransfer-Modus.
        if host.ribbonOut && host.thermalTransferMode { return tr("Farbband leer") }
        if host.paused { return tr("Pausiert") }
        return nil
    }

    /// Terminal-Austausch während eines Kodierauftrags. Hat ein Verbindungsaufbau dabei die
    /// Statusüberwachung wieder gestartet, wird sie gleich wieder pausiert – ihre Abfragen würden
    /// noch ausstehende ^HV-Antworten verwerfen.
    private func jobTerminal(_ session: PrinterSession, _ input: String, timeout: Duration) async -> Data? {
        let data = await session.terminal(input, timeout: timeout)
        session.stopMonitoring()
        return data
    }

    private func setWriteNotice(_ text: String?) {
        guard writeNotice != text else { return }
        animate { writeNotice = text }
    }

    /// Wartet auf die Prüfantwort von Tag `number`, solange der Drucker dessen Format noch nicht
    /// abgearbeitet hat: Er ist angehalten (Pause, Kopf offen, Etiketten oder Farbband leer) oder hat
    /// noch Formate im Puffer bzw. in Arbeit. Den Status liefert ~HS über das Terminal – im selben
    /// Datenstrom wie die ^HV-Antworten, sodass keine Statusabfrage eine gerade eintreffende Antwort
    /// verwirft. Ohne Antwort gilt der Tag erst als fehlgeschlagen, wenn der Drucker zweimal in Folge
    /// untätig war. Wird währenddessen angehalten, solange das Format noch im Drucker steckt, wird es
    /// verworfen (~JA), statt später ungeprüft kodiert zu werden.
    private func awaitVerification(of number: Int, session: PrinterSession,
                                   answer: (Data) -> RFIDVerification?) async -> VerifyWait {
        guard session.supportsStatus else { return .noAnswer }
        defer { setWriteNotice(nil) }
        let statusQuery = ZPL.hostStatus().description
        var idlePolls = 0
        var lastSessionPoll = Date.distantPast
        while true {
            guard let data = await jobTerminal(session, statusQuery, timeout: .seconds(3)) else { return .connectionLost }
            if let reply = answer(data) { return .answered(reply.hex) }
            let host = try? HostStatusParser.parse(data)
            let stall = host.flatMap { RFIDWorkbench.stallReason($0) }
            if cancelRequested || Task.isCancelled, stall != nil || (host?.formatsInReceiveBuffer ?? 0) > 0 {
                // ~HS unmittelbar vor ~JA im selben Aufruf: zeigt, ob das Format noch wartete.
                guard let purge = await jobTerminal(session, statusQuery + ZPL.cancelAll().description,
                                                    timeout: .seconds(3)) else { return .connectionLost }
                if let reply = answer(purge) { return .answered(reply.hex) }
                let queued = (try? HostStatusParser.parse(purge))?.formatsInReceiveBuffer ?? 0
                return queued > 0 ? .discarded : .unconfirmed
            }
            let busy = host.map {
                $0.formatsInReceiveBuffer > 0 || $0.partialFormatInProgress || $0.labelsRemainingInBatch > 0
            } ?? false
            if let stall {
                idlePolls = 0
                setWriteNotice(tr("%@ – Tag %d wird kodiert und geprüft, sobald der Drucker weiterläuft.", stall, number))
                // Wartet das Format noch im Puffer des angehaltenen Druckers, kann während einer
                // Statusabfrage der Sitzung keine Antwort eintreffen – dann darf sie ihren Status
                // (Warnungen in Übersicht und Seitenleiste) aktualisieren.
                if (host?.formatsInReceiveBuffer ?? 0) > 0 {
                    await pollPrinterStatusIfDue(session, lastPoll: &lastSessionPoll)
                }
            } else if busy {
                idlePolls = 0
                setWriteNotice(tr("Warte auf die Rückmeldung von Tag %d …", number))
            } else {
                idlePolls += 1
                if idlePolls >= 2 { return .noAnswer }
            }
            // Bis zur nächsten Abfrage weiterlesen – die Antwort kann jederzeit eintreffen.
            guard let more = await jobTerminal(session, "", timeout: .seconds(2)) else { return .connectionLost }
            if let reply = answer(more) { return .answered(reply.hex) }
        }
    }

    /// Wartet, bis weniger als `limit` Formate im Empfangspuffer des Druckers liegen und er nicht
    /// angehalten ist. Ohne Rückkanal oder verständliche Statusantwort wird nicht gewartet.
    private func awaitPrinterBuffer(below limit: Int, session: PrinterSession,
                                    waitingNotice: String?) async -> BufferWait {
        guard session.supportsStatus else { return .ready }
        defer { setWriteNotice(nil) }
        var lastSessionPoll = Date.distantPast
        while true {
            if cancelRequested || Task.isCancelled { return .cancelled }
            guard let data = await jobTerminal(session, ZPL.hostStatus().description, timeout: .seconds(3)) else {
                return .connectionLost
            }
            guard let host = try? HostStatusParser.parse(data) else { return .ready }
            if let stall = RFIDWorkbench.stallReason(host) {
                setWriteNotice(tr("%@ – die Kodierung geht weiter, sobald der Drucker wieder bereit ist.", stall))
                // Ohne ^HV gibt es keine Antworten, die eine Statusabfrage der Sitzung verwerfen könnte.
                await pollPrinterStatusIfDue(session, lastPoll: &lastSessionPoll)
            } else if host.formatsInReceiveBuffer < limit {
                return .ready
            } else {
                setWriteNotice(waitingNotice)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Verwirft beim Anhalten die Formate, die noch im Drucker warten (~JA), und kennzeichnet die
    /// zugehörigen – zuletzt gesendeten – Tags als verworfen. Die Anzahl stammt aus ~HS im selben
    /// Aufruf unmittelbar vor ~JA. Ohne verständliche Statusantwort bleiben die Einträge, wie sie sind.
    private func discardQueuedFormats(sent: Int, session: PrinterSession) async {
        guard session.supportsStatus,
              let data = await jobTerminal(session, ZPL.hostStatus().description + ZPL.cancelAll().description,
                                           timeout: .seconds(3)),
              let queued = (try? HostStatusParser.parse(data))?.formatsInReceiveBuffer, queued > 0 else { return }
        let discarded = min(queued, sent)
        updateEntries(Array((sent - discarded + 1)...sent), from: .sent, to: .discarded)
        animate { writeRun?.completed = sent - discarded }
    }

    private func appendEntry(_ entry: RFIDWriteEntry, completed: Int) {
        animate(Motion.snappy) {
            writeRun?.entries.insert(entry, at: 0)
            if let count = writeRun?.entries.count, count > RFIDWriteRun.visibleEntryLimit {
                writeRun?.entries.removeLast(count - RFIDWriteRun.visibleEntryLimit)
            }
            writeRun?.tally(entry.state, sign: 1)
            writeRun?.completed = completed
        }
    }

    /// Berichtigt das Ergebnis bereits protokollierter Tags (verspätete Prüfantwort, beim Anhalten
    /// verworfene Formate) samt Summen.
    private func updateEntries(_ ids: [Int], from previous: RFIDWriteState, to state: RFIDWriteState) {
        guard previous != state, !ids.isEmpty else { return }
        animate(Motion.snappy) {
            for id in ids {
                if let index = writeRun?.entries.firstIndex(where: { $0.id == id }) {
                    writeRun?.entries[index].state = state
                }
                writeRun?.tally(previous, sign: -1)
                writeRun?.tally(state, sign: 1)
            }
        }
    }

    private func finishWrite(options: RFIDWriteOptions, geometry: RFIDLabelGeometry, values: [String],
                             log: RFIDSentLog, session: PrinterSession) async {
        let cancelled = cancelRequested
        animate {
            writeRun?.isRunning = false
            writeRun?.wasCancelled = cancelled
            writeRun?.finishedAt = Date()
            writeNotice = nil
        }
        writeTask = nil
        cancelRequested = false
        guard let run = writeRun else { return }

        let summary: String
        if run.verify {
            summary = tr("%d von %d Tags erfolgreich", run.successCount, run.total)
        } else if run.discardedTotal > 0 {
            summary = tr("%d von %d Tags ungeprüft kodiert, %d wartende im Drucker verworfen",
                         run.successCount, run.total, run.discardedTotal)
        } else {
            summary = tr("%d von %d Tags an den Drucker gesendet", run.successCount, run.total)
        }
        let succeeded = run.successCount > 0 && run.failureCount == 0 && !cancelled
        if succeeded {
            celebration += 1
            successPulse += 1
        } else if run.failureCount > 0 {
            failurePulse += 1
        }

        // Ein Sammeleintrag je Auftrag im Verlauf (beide Betriebsarten senden über das Terminal) – ohne
        // Druckdaten (siehe `RFIDSentLog`) und ohne die im Drucker verworfenen Tags.
        let labels = max(0, log.formatCount - run.discardedTotal)
        if !log.isEmpty {
            var preview: Data?
            if options.print.enabled, let first = values.first {
                let zpl = RFIDEncoder.previewFormat(epc: first, number: 1, options: options.print, geometry: geometry)
                preview = await PrinterSession.previewPNG(zpl: zpl, dotsPerMM: geometry.dotsPerMM)
            }
            session.app?.record(JobRecord(
                printerID: session.id,
                printerName: session.displayName,
                title: run.verify
                    ? tr("RFID-Kodierung mit Prüfung (%d Tags)", labels)
                    : tr("RFID-Kodierung (%d Tags)", labels),
                kind: .zpl,
                labels: labels,
                bytes: log.bytes,
                success: run.failureCount == 0 && run.completed > 0,
                message: summary,
                previewPNG: preview,
                payload: nil
            ))
        }

        if cancelled {
            session.app?.toast(tr("Kodierung angehalten"), message: summary, style: .warning)
        } else if run.failureCount > 0 {
            session.app?.toast(tr("Kodierung mit Fehlern beendet"), message: summary, style: .warning)
        } else {
            session.app?.toast(run.verify ? tr("Kodierung abgeschlossen") : tr("Kodierauftrag gesendet"),
                               message: summary, style: .success)
        }
        if succeeded, session.app?.preferences.playSounds == true {
            SoundService.play(.success)
        }
        // Zählerstände (gültig/VOID) aktualisieren.
        if session.connectionState.isConnected {
            await refreshStatus(session: session)
        }
    }

    // MARK: Kalibrierung

    func calibrate(session: PrinterSession) async {
        guard !isBusy else { return }
        animate {
            isCalibrating = true
            calibrationError = nil
        }
        await pauseMonitoring(session)
        defer { resumeMonitoring(session) }
        // ^HR-Antworten tragen keinen eigenen Kopf: Bereits eingetroffene, nicht abgeholte Daten (z. B.
        // der Rest einer abgebrochenen Kalibrierung) vorher abholen und verwerfen, damit sie nicht als
        // Teil der neuen Tabelle gelten.
        _ = await session.terminal("", timeout: .zero)
        // Bis zu 15 s bis zur ersten Antwort, danach bis zu 60 s weitere Teile bis „end“: Zwischen den
        // Messungen transportiert der Drucker Etiketten vor und zurück und sendet nichts.
        let response = await collect(session: session, RFIDCommand.calibrationFormat, timeout: .seconds(15),
                                     followUp: .seconds(5), budget: .seconds(60)) { text in
            RFIDCalibrationResult.containsEnd(text)
        }
        guard let response else {
            animate {
                isCalibrating = false
                calibrationError = session.lastError ?? tr("Keine Verbindung zum Drucker. Bitte Verbindung prüfen und erneut versuchen.")
            }
            failurePulse += 1
            return
        }
        let result = RFIDCalibrationResult.parse(RFIDResponseParser.text(response))
        guard !result.lines.isEmpty else {
            animate {
                isCalibrating = false
                calibrationError = tr("Der Drucker hat keine Kalibrierdaten gesendet. Sind RFID-Etiketten eingelegt und ist der Kodierer aktiviert?")
            }
            failurePulse += 1
            return
        }
        animate {
            isCalibrating = false
            calibration = result
            calibratedAt = Date()
        }
        successPulse += 1
        await refreshStatus(session: session)
        if result.isComplete {
            session.app?.toast(tr("RFID-Kalibrierung abgeschlossen"),
                               message: result.recommendedPosition.map { tr("Mitte des Lesefensters: %@", $0) },
                               style: .success)
        } else {
            session.app?.toast(tr("Kalibrierdaten möglicherweise unvollständig"),
                               message: tr("Der Drucker hat die Tabelle nicht mit „end“ abgeschlossen."),
                               style: .warning)
        }
    }

    // MARK: Einstellungen

    func loadSettings(session: PrinterSession) async {
        // Nicht parallel zu einem laufenden Terminal-Dialog (^HV, ^HR) auf derselben Verbindung.
        guard !isLoadingSettings, !isBusy else { return }
        animate { isLoadingSettings = true }
        // Die Liste aller Einstellungen ist eine lange Antwort – ~HS-Abfragen nicht dazwischenmischen.
        await pauseMonitoring(session)
        let all = await session.allSettings()
        resumeMonitoring(session)
        // Ein Übertragungsfehler liefert ebenfalls eine leere Liste: dann die bisherigen Zeilen behalten.
        if all.isEmpty, let error = session.lastError {
            animate {
                settingsError = error
                isLoadingSettings = false
            }
            return
        }
        let rows = all.compactMap { entry -> RFIDSettingRow? in
            let name = entry.value.name.isEmpty ? entry.key : entry.value.name
            guard RFIDSettingRow.isRFIDKey(name) else { return nil }
            return RFIDSettingRow(name: name, setting: entry.value)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        animate {
            settingRows = rows
            settingsError = nil
            settingsLoadedAt = Date()
            isLoadingSettings = false
        }
    }

    func settingRow(named name: String) -> RFIDSettingRow? {
        settingRows.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Setzt eine SGD-Variable, liest sie zur Bestätigung zurück und aktualisiert Tabelle & Status.
    /// Nicht während eines Terminal-Dialogs (^HV, ^HR): Die SGD-Abfragen würden dessen noch
    /// ausstehende Antworten verwerfen.
    @discardableResult
    func apply(_ name: String, value: String, session: PrinterSession) async -> Bool {
        guard !isBusy else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard await session.setvar(name, trimmed) else {
            failurePulse += 1
            return false
        }
        let confirmed = await session.getvar(name) ?? trimmed
        animate {
            if let index = settingRows.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                settingRows[index].value = confirmed
            }
            flashedSetting = name
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, self.flashedSetting == name else { return }
            self.animate { self.flashedSetting = nil }
        }
        if RFIDStatusValues.keys.contains(name.lowercased()) {
            await refreshStatus(session: session)
        }
        session.app?.toast(tr("Wert gesetzt"), message: tr("%@ = %@", name, confirmed), style: .success)
        return true
    }

    func resetCounters(session: PrinterSession) async {
        guard !isBusy else { return }
        let valid = await session.setvar(RFIDStatusValues.validKey, "0")
        // Nach einem Übertragungsfehler nicht gleich den nächsten Versuch (samt Verbindungsaufbau
        // und weiterer Fehlermeldung).
        var void = false
        if valid { void = await session.setvar(RFIDStatusValues.voidKey, "0") }
        await refreshStatus(session: session)
        if valid && void {
            session.app?.toast(tr("RFID-Zähler zurückgesetzt"), message: nil, style: .success)
        }
    }
}

// MARK: - Ablage je Drucker

/// Hält je Drucker einen Arbeitsbereich, damit Verlauf und laufende Aufträge einen
/// Bereichswechsel überstehen.
@MainActor
enum RFIDWorkbenchRegistry {
    private static var workbenches: [UUID: RFIDWorkbench] = [:]

    static func workbench(for session: PrinterSession) -> RFIDWorkbench {
        if let existing = workbenches[session.id] { return existing }
        if let app = session.app {
            let known = Set(app.sessions.map(\.id))
            workbenches = workbenches.filter { known.contains($0.key) }
        }
        let created = RFIDWorkbench(sessionID: session.id)
        workbenches[session.id] = created
        return created
    }
}

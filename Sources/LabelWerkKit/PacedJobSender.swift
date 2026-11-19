import Foundation
import LabelWerkCore
import LabelWerkStatus
import LabelWerkTransport

// MARK: - Optionen, Ereignisse, Ergebnis

/// Einstellungen für ``PacedJobSender``.
public struct PacedJobOptions: Sendable, Hashable {
    /// Abfrageabstand, solange gedruckt wird.
    public var pollInterval: Duration
    /// Abfrageabstand, solange der Drucker wegen eines Fehlers oder einer Pause wartet.
    public var waitPollInterval: Duration
    /// Wartezeit auf eine `~HS`-Antwort.
    public var statusTimeout: Duration
    /// Vorab `^XA^JZY^XZ` senden: Ein Etikett, das ein Fehler unterbricht, druckt der Drucker danach
    /// erneut.
    public var reprintAfterError: Bool
    /// Pausiert der Drucker nach einem behobenen Fehler (Papier/Farbband leer, Kopf offen), wird er mit
    /// `~PS` fortgesetzt. Eine Pause ohne vorherigen Fehler (Pause-Taste) bleibt bestehen.
    public var resumeAfterRecovery: Bool
    /// Wiederverbindungsversuche nach einem Verbindungsabbruch (je Abbruch).
    public var maxReconnectAttempts: Int
    /// Wartezeit vor dem ersten Wiederverbindungsversuch; verdoppelt sich je Versuch bis 30 s.
    public var reconnectDelay: Duration
    /// Aufeinanderfolgende unbeantwortete `~HS`-Abfragen während des Auftrags, ab denen die Verbindung
    /// als unterbrochen gilt.
    public var maxSilentPolls: Int

    public init(pollInterval: Duration = .milliseconds(250), waitPollInterval: Duration = .seconds(2),
                statusTimeout: Duration = .seconds(3), reprintAfterError: Bool = true,
                resumeAfterRecovery: Bool = true, maxReconnectAttempts: Int = 6,
                reconnectDelay: Duration = .seconds(2), maxSilentPolls: Int = 5) {
        self.pollInterval = pollInterval
        self.waitPollInterval = waitPollInterval
        self.statusTimeout = statusTimeout
        self.reprintAfterError = reprintAfterError
        self.resumeAfterRecovery = resumeAfterRecovery
        self.maxReconnectAttempts = max(0, maxReconnectAttempts)
        self.reconnectDelay = reconnectDelay
        self.maxSilentPolls = max(1, maxSilentPolls)
    }

    public static let standard = PacedJobOptions()
}

/// Warum ein Auftrag gerade nicht weitergedruckt wird.
public enum PacedJobWaitReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// Etiketten (Papier) leer.
    case mediaOut
    /// Farbband leer (nur im Thermotransfer-Modus).
    case ribbonOut
    /// Druckkopf offen.
    case headOpen
    /// Drucker pausiert.
    case paused
    /// Spendemodus: Das gedruckte Etikett muss entnommen werden.
    case labelWaitingToBePeeled
    /// Druckkopf zu heiß – der Drucker kühlt ab.
    case headTemperature

    /// Kurzbezeichnung, z. B. „Papier leer“.
    public var title: String {
        switch self {
        case .mediaOut: return "Papier leer"
        case .ribbonOut: return "Farbband leer"
        case .headOpen: return "Druckkopf offen"
        case .paused: return "Drucker pausiert"
        case .labelWaitingToBePeeled: return "Etikett entnehmen"
        case .headTemperature: return "Druckkopf zu heiß"
        }
    }

    /// Vollständige Meldung samt Handlungsanweisung (Deutsch), z. B. für `INFO:` im CUPS-Backend und
    /// `lwctl`.
    public var message: String {
        switch self {
        case .mediaOut:
            return "Papier leer – neue Etikettenrolle einlegen. Der Druck geht danach automatisch weiter."
        case .ribbonOut:
            return "Farbband leer – neues Farbband einlegen. Der Druck geht danach automatisch weiter."
        case .headOpen:
            return "Druckkopf offen – Druckkopf schließen. Der Druck geht danach automatisch weiter."
        case .paused:
            return "Drucker pausiert – zum Fortsetzen die Pause-Taste am Drucker drücken."
        case .labelWaitingToBePeeled:
            return "Etikett entnehmen – der Druck geht danach automatisch weiter."
        case .headTemperature:
            return "Druckkopf zu heiß – der Drucker kühlt ab und druckt danach automatisch weiter."
        }
    }

    /// `true` für Fehler, nach denen der Drucker das unterbrochene Etikett erneut druckt (`^JZY`) und
    /// nach deren Behebung eine Pause automatisch aufgehoben wird.
    public var isFault: Bool {
        self == .mediaOut || self == .ribbonOut || self == .headOpen
    }

    /// Grund aus `~HS`, der den Druck aufhält (`nil` = nichts hält ihn auf). Reihenfolge: Kopf offen,
    /// Papier leer, Farbband leer (nur Thermotransfer), Pause, Übertemperatur. Ein Etikett, das im
    /// Spendemodus auf Entnahme wartet, zählt nur, solange noch Etiketten ausstehen.
    public static func reason(for status: HostStatus) -> PacedJobWaitReason? {
        if status.headOpen { return .headOpen }
        if status.paperOut { return .mediaOut }
        if status.ribbonOut && status.thermalTransferMode { return .ribbonOut }
        if status.paused { return .paused }
        if status.overTemperature { return .headTemperature }
        if status.labelWaitingToBePeeled && status.labelsRemainingInBatch > 0 { return .labelWaitingToBePeeled }
        return nil
    }
}

/// Ereignisse während eines Auftrags (``PacedJobSender/send(_:characters:cancelPrefixLength:delayMilliseconds:onEvent:)``).
public enum PacedJobEvent: Sendable, Hashable {
    /// Der Auftrag beginnt: `total` Etiketten; `paced == false` bei Versand in einem Stück.
    case started(total: Int, paced: Bool)
    /// Fertig gedruckte Etiketten.
    case progress(printed: Int, total: Int)
    /// Der Drucker hält an (Papier leer …); der Auftrag wartet.
    case waiting(PacedJobWaitReason, printed: Int, total: Int)
    /// Der Drucker druckt wieder.
    case resumed(printed: Int, total: Int)
    /// Nach einem behobenen Fehler wurde die Pause des Druckers mit `~PS` aufgehoben.
    case resumeSent
    /// Kein Etikett-für-Etikett-Versand möglich (Grund); der Auftrag geht in einem Stück.
    case unpaced(String)
    /// Verbindung unterbrochen; Wiederverbindungsversuch `attempt`.
    case connectionLost(attempt: Int, message: String)
    /// Wieder verbunden.
    case reconnected
    /// Ein Teil wird nach einem Verbindungsabbruch erneut gesendet (`labels` Etiketten).
    case resending(labels: Int)
    /// Nach einem Verbindungsabbruch lässt sich nicht prüfen, ob der Drucker neu gestartet wurde (er
    /// meldet den Neustart-Merker nicht): Nichts wird automatisch wiederholt; bis zu `labels`
    /// Etiketten fehlen möglicherweise.
    case uncertain(labels: Int)
    /// Abgebrochen (`~JA` gesendet).
    case cancelled(printed: Int, total: Int)
    /// Alle Etiketten gedruckt (bzw. bei Versand in einem Stück: übergeben).
    case finished(printed: Int, total: Int)
}

/// Ergebnis eines Auftrags.
public struct PacedJobResult: Sendable, Hashable {
    /// Gedruckte (bei Versand in einem Stück: übergebene) Etiketten.
    public var printed: Int
    public var total: Int
    /// Etikett für Etikett gesendet und überwacht.
    public var paced: Bool
    /// Etiketten, die nach einem nicht prüfbaren Verbindungsabbruch möglicherweise fehlen
    /// (``PacedJobEvent/uncertain(labels:)``).
    public var uncertain: Int

    public init(printed: Int, total: Int, paced: Bool, uncertain: Int = 0) {
        self.printed = printed
        self.total = total
        self.paced = paced
        self.uncertain = uncertain
    }
}

// MARK: - Sender

/// Sendet einen ZPL-Auftrag Etikett für Etikett wie ein „normaler“ Drucker: Der Auftrag bleibt
/// bestehen, bis jedes Etikett gedruckt ist – auch wenn zwischendurch Papier oder Farbband ausgehen
/// oder der Druckkopf geöffnet wird. Danach geht er genau dort weiter, wo er stand.
///
/// Ablauf (ARCHITECTURE.md §7b „Etikett für Etikett drucken“):
/// 1. `~HS` prüft, ob der Drucker antwortet. Ohne Antwort, ohne Rückkanal (CUPS-Warteschlange) oder
///    bei EPL/CPCL geht der Auftrag wie bisher in einem Stück (``PacedJobEvent/unpaced(_:)``).
/// 2. Kopf (``PacedJobPlan/prologue``) samt `^XA^JZY^XZ` senden – mit „Aufträge vor dem Drucken
///    abbrechen“ wie ``PrinterClient/sendJob(_:cancelPrefixLength:delayMilliseconds:)`` in zwei Teilen.
/// 3. Je druckendem Format: warten, bis der Drucker leer und bereit ist (`formats in receive buffer`
///    = 0, `labels remaining` = 0, kein Fehler), dann senden. So liegt nie mehr als ein Format im
///    Drucker. Fortschritt aus `labels remaining` (auch bei `^PQ` > 1).
/// 4. Papier/Farbband leer, Kopf offen, Pause: ``PacedJobEvent/waiting(_:printed:total:)``, alle 2 s
///    prüfen; danach ``PacedJobEvent/resumed(printed:total:)``. Das unterbrochene Etikett druckt der
///    Drucker wegen `^JZY` selbst erneut. Pausiert er nach dem Fehler, folgt `~PS`.
/// 5. Abbruch (Task-Abbruch): `~JA` leert den Drucker, dann `CancellationError`.
/// 6. Vor dem ersten Etikett (Drucker bereit) speichert `~DG` den Neustart-Merker `R:LWAPP.GRF`
///    (1 Byte im RAM, beim Aus- und Einschalten weg); `^HW` prüft einmal, ob der Drucker ihn meldet.
/// 7. Verbindungsabbruch: neu verbinden (mit wachsendem Abstand). Meldet der Drucker danach Formate
///    oder Restetiketten, hat er seinen Puffer behalten: weiter warten. Ist er leer, entscheidet der
///    Merker (sobald der Drucker bereit ist): vorhanden → er hat inzwischen fertig gedruckt, nichts
///    wiederholen; fehlt → er wurde neu gestartet: Kopf samt `^JZY` und die zuletzt gemeldeten
///    restlichen Exemplare erneut senden (auch ohne vorherigen Fehler). Meldet er den Merker nicht,
///    wird nichts automatisch wiederholt (``PacedJobEvent/uncertain(labels:)``). Ein nur teilweise
///    gesendetes Format verwirft `~JX`, dann geht es erneut hinaus.
public struct PacedJobSender: Sendable {
    public let client: PrinterClient
    public var options: PacedJobOptions

    public init(client: PrinterClient, options: PacedJobOptions = .standard) {
        self.client = client
        self.options = options
    }

    /// Sendet `data` (fertig kodierter Auftrag, z. B. aus `JobEncoder`) und kehrt erst zurück, wenn
    /// alle Etiketten gedruckt sind.
    ///
    /// - Parameters:
    ///   - characters: Steuerzeichen des Auftrags (`PrintSettings.effectiveControlCharacters`);
    ///     `nil` = erkennen.
    ///   - cancelPrefixLength: Länge der `~JA`-Zeile am Anfang (`JobEncoder.cancelPrefixLength()`).
    ///   - delayMilliseconds: Wartezeit nach der `~JA`-Zeile (`cancelDelayMs`).
    ///   - onEvent: Fortschritt und Wartegründe (beliebiger Thread).
    /// - Throws: `CancellationError` nach einem Abbruch (`~JA` ist dann gesendet), Verbindungsfehler
    ///   nach erfolglosen Wiederverbindungsversuchen.
    @discardableResult
    public func send(_ data: Data, characters: ControlCharacters? = nil, cancelPrefixLength: Int? = nil,
                     delayMilliseconds: Int = 0,
                     onEvent: @escaping @Sendable (PacedJobEvent) -> Void = { _ in }) async throws -> PacedJobResult {
        let language = await client.language
        guard language == .zpl else {
            return try await sendWhole(data, total: 0, cancelPrefixLength: cancelPrefixLength,
                                       delayMilliseconds: delayMilliseconds,
                                       reason: "EPL und CPCL melden den Druckfortschritt nicht – der Auftrag wird in einem Stück gesendet.",
                                       onEvent: onEvent)
        }
        let plan = PacedJobPlan.split(data, characters: characters)
        guard client.supportsBidirectional else {
            return try await sendWhole(data, total: plan.totalLabels, cancelPrefixLength: cancelPrefixLength,
                                       delayMilliseconds: delayMilliseconds,
                                       reason: "Die Verbindung hat keinen Rückkanal – der Auftrag wird in einem Stück gesendet.",
                                       onEvent: onEvent)
        }
        guard !plan.segments.isEmpty else {
            return try await sendWhole(data, total: 0, cancelPrefixLength: cancelPrefixLength,
                                       delayMilliseconds: delayMilliseconds,
                                       reason: "Der Auftrag enthält keine Etiketten.", onEvent: onEvent)
        }
        let run = PacedJobRun(client: client, options: options, plan: plan, onEvent: onEvent)
        if try await run.probe() == nil {
            return try await sendWhole(data, total: plan.totalLabels, cancelPrefixLength: cancelPrefixLength,
                                       delayMilliseconds: delayMilliseconds,
                                       reason: "Der Drucker beantwortet keine Statusabfrage (~HS) – der Auftrag wird in einem Stück gesendet.",
                                       onEvent: onEvent)
        }
        return try await run.execute(cancelPrefixLength: cancelPrefixLength, delayMilliseconds: delayMilliseconds)
    }

    /// Versand in einem Stück (wie bisher).
    private func sendWhole(_ data: Data, total: Int, cancelPrefixLength: Int?, delayMilliseconds: Int,
                           reason: String, onEvent: @Sendable (PacedJobEvent) -> Void) async throws -> PacedJobResult {
        onEvent(.unpaced(reason))
        onEvent(.started(total: total, paced: false))
        try await client.sendJob(data, cancelPrefixLength: cancelPrefixLength, delayMilliseconds: delayMilliseconds)
        onEvent(.finished(printed: total, total: total))
        return PacedJobResult(printed: total, total: total, paced: false)
    }
}

// MARK: - Ablauf eines Auftrags

/// Zustand eines laufenden Auftrags (nur innerhalb eines Tasks benutzt).
private final class PacedJobRun {
    let client: PrinterClient
    let options: PacedJobOptions
    let plan: PacedJobPlan
    let onEvent: @Sendable (PacedJobEvent) -> Void
    let characters: ControlCharacters

    /// Vollständig gedruckte Etiketten früherer Segmente.
    private var completed = 0
    /// Zuletzt gemeldeter Fortschritt.
    private var reported = -1
    /// Aktueller Wartegrund (`nil` = druckt).
    private var waitingReason: PacedJobWaitReason?
    /// Seit dem letzten störungsfreien Status trat ein Fehler auf (Papier/Farbband leer, Kopf offen).
    private var faultSeen = false
    /// Letzter verstandener Status.
    private var lastStatus: HostStatus?
    /// Zuletzt gemeldete Restexemplare des Segments im Drucker.
    private var seenRemaining = 0

    /// Neustart-Merker dieses Senders (das CUPS-Backend nutzt `R:LWJOB.GRF`).
    static let markerPath = "R:LWAPP.GRF"
    /// Merker gespeichert (vor dem ersten Etikett).
    private var sessionArmed = false
    /// Der Drucker meldet den Merker per `^HW` (geprüft beim ersten Speichern).
    private var markerSupported = false
    /// Etiketten, deren Druck nach einem Verbindungsabbruch nicht prüfbar war.
    private var uncertain = 0
    /// Kopf (Prolog + `^JZY`) samt Aufteilung nach `~JA` – für einen Neustart des Druckers.
    private var head = Data()
    private var headSplit: Int?
    private var headDelay = 0

    init(client: PrinterClient, options: PacedJobOptions, plan: PacedJobPlan,
         onEvent: @escaping @Sendable (PacedJobEvent) -> Void) {
        self.client = client
        self.options = options
        self.plan = plan
        self.onEvent = onEvent
        self.characters = plan.characters
    }

    private var total: Int { plan.totalLabels }

    private func command(_ zpl: ZPLCommand) -> Data {
        Data(zpl.rendered(with: characters).utf8)
    }

    /// Erste Statusabfrage; `nil` = keine verständliche Antwort.
    func probe() async throws -> HostStatus? {
        let status = try await client.hostStatus(characters: characters, timeout: options.statusTimeout)
        lastStatus = status
        return status
    }

    func execute(cancelPrefixLength: Int?, delayMilliseconds: Int) async throws -> PacedJobResult {
        onEvent(.started(total: total, paced: true))
        do {
            var head = plan.prologue
            if options.reprintAfterError {
                head += command(ZPL.startFormat()) + command(ZPLCommand(.caret, "JZ", ["Y"])) + command(ZPL.endFormat())
                head += Data("\n".utf8)
            }
            let split = cancelPrefixLength.flatMap { $0 > 0 && $0 <= plan.prologue.count ? $0 : nil }
            self.head = head
            self.headSplit = split
            self.headDelay = delayMilliseconds
            try await withReconnect { [client] in
                try await client.sendJob(head, cancelPrefixLength: split, delayMilliseconds: delayMilliseconds)
            }
            report(0)
            for segment in plan.segments {
                try await printSegment(segment)
                completed += segment.quantity
                report(completed)
            }
            if !plan.epilogue.isEmpty {
                let epilogue = plan.epilogue
                try await withReconnect { [client] in try await client.send(epilogue) }
            }
            if sessionArmed {
                await client.deleteVolatileMarker(Self.markerPath, characters: characters)
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                await cancelOnPrinter()
                onEvent(.cancelled(printed: completedEstimate, total: total))
                throw CancellationError()
            }
            throw error
        }
        onEvent(.finished(printed: total, total: total))
        return PacedJobResult(printed: total, total: total, paced: true, uncertain: uncertain)
    }

    /// Zuletzt gemeldeter Stand (für den Abbruch).
    private var completedEstimate: Int { max(completed, reported) }

    // MARK: Segment

    private enum WaitOutcome {
        case done
        /// Verbindung verloren, nachdem das Segment gesendet war.
        case connectionLost(Error)
    }

    /// Wartet auf einen leeren, bereiten Drucker, sendet das Segment und wartet, bis es gedruckt ist.
    private func printSegment(_ segment: PacedJobPlan.Segment) async throws {
        // Erst senden, wenn der Drucker nichts anderes mehr druckt (auch keinen fremden Auftrag).
        try await awaitIdleBeforeSending()
        try await armIfNeeded()
        var pending: PacedJobPlan.Segment? = segment
        var inPrinter = segment
        var alreadyPrinted = 0
        seenRemaining = segment.quantity
        while true {
            if let toSend = pending {
                do {
                    try await client.send(toSend.data)
                    pending = nil
                    inPrinter = toSend
                    seenRemaining = toSend.quantity
                } catch where Self.isConnectionError(error) {
                    try await reconnect(after: error)
                    // Was ist angekommen? Teilformat verwerfen und neu senden; liegt das Format
                    // vollständig im Drucker, nicht doppelt senden. Wurde der Drucker neu gestartet,
                    // vorher den Kopf (Einstellungen, ^JZY, Merker) erneut senden.
                    let status = try await statusAfterReconnect()
                    if status?.partialFormatInProgress == true {
                        try await client.send(command(ZPLCommand(.tilde, "JX")))
                    } else if let status, status.formatsInReceiveBuffer > 0 || status.labelsRemainingInBatch > 0 {
                        pending = nil
                        inPrinter = toSend
                        seenRemaining = toSend.quantity
                        continue
                    } else if try await restartVerdict() == .restarted {
                        try await resendHead()
                    }
                    onEvent(.resending(labels: toSend.quantity))
                    continue
                }
            }
            switch try await awaitSegment(inPrinter, alreadyPrinted: alreadyPrinted) {
            case .done:
                return
            case .connectionLost(let error):
                try await reconnect(after: error)
                let status = try await statusAfterReconnect()
                if let status, status.formatsInReceiveBuffer > 0 || status.labelsRemainingInBatch > 0
                    || status.partialFormatInProgress {
                    continue   // Format noch im Drucker: weiter warten.
                }
                // Drucker leer: fertig gedruckt oder neu gestartet? Der Merker entscheidet, nicht der
                // letzte Wartegrund (eine Verbindung kann auch bei „Papier leer“ oder im Spendemodus
                // abbrechen, während der Drucker seinen Puffer behält und danach allein weiterdruckt).
                let remaining = min(inPrinter.quantity, max(1, seenRemaining))
                switch try await restartVerdict() {
                case .kept:
                    return
                case .unknown:
                    uncertain += remaining
                    onEvent(.uncertain(labels: remaining))
                    return
                case .restarted:
                    try await resendHead()
                    alreadyPrinted += inPrinter.quantity - remaining
                    let resend = inPrinter.withQuantity(remaining)
                    pending = resend
                    onEvent(.resending(labels: resend.quantity))
                }
            }
        }
    }

    // MARK: Neustart-Merker

    private enum RestartVerdict {
        /// Der Drucker hat seinen Puffer behalten.
        case kept
        /// Der Drucker wurde neu gestartet (Puffer und Einstellungen weg).
        case restarted
        /// Nicht prüfbar (der Drucker meldet den Merker nicht).
        case unknown
    }

    /// Vor dem ersten Etikett (der Drucker ist bereit): Merker speichern und einmal prüfen, ob der
    /// Drucker ihn per `^HW` meldet.
    private func armIfNeeded() async throws {
        guard !sessionArmed else { return }
        while true {
            do {
                try await client.storeVolatileMarker(Self.markerPath, characters: characters)
                let listed = try await client.volatileMarkerExists(Self.markerPath, characters: characters,
                                                                   timeout: options.statusTimeout)
                markerSupported = listed == true
                sessionArmed = true
                return
            } catch where Self.isConnectionError(error) {
                try await reconnect(after: error)
            }
        }
    }

    /// Nach dem Wiederverbinden mit leerem Drucker: neu gestartet? `^HW` bearbeitet der Drucker erst,
    /// wenn er bereit ist – Fehler und Pausen werden dafür abgewartet (mit Wartegründen wie sonst).
    private func restartVerdict() async throws -> RestartVerdict {
        guard markerSupported else { return .unknown }
        while true {
            switch try await awaitSegment(nil, alreadyPrinted: 0) {
            case .done:
                break
            case .connectionLost(let error):
                try await reconnect(after: error)
                continue
            }
            do {
                guard let listed = try await client.volatileMarkerExists(Self.markerPath, characters: characters,
                                                                         timeout: options.statusTimeout) else {
                    return .unknown
                }
                return listed ? .kept : .restarted
            } catch where Self.isConnectionError(error) {
                try await reconnect(after: error)
            }
        }
    }

    /// Nach einem Neustart des Druckers: Kopf (mit `~JA`-Pause) samt `^JZY` und den Merker erneut senden.
    private func resendHead() async throws {
        let head = self.head
        let split = headSplit
        let delay = headDelay
        let marker = Self.markerPath
        let characters = self.characters
        try await withReconnect { [client] in
            try await client.sendJob(head, cancelPrefixLength: split, delayMilliseconds: delay)
            try await client.storeVolatileMarker(marker, characters: characters)
        }
    }

    /// Wartet, bis der Drucker leer und bereit ist (vor dem Senden des nächsten Segments).
    private func awaitIdleBeforeSending() async throws {
        while true {
            switch try await awaitSegment(nil, alreadyPrinted: 0) {
            case .done: return
            case .connectionLost(let error): try await reconnect(after: error)
            }
        }
    }

    /// Fragt `~HS` ab, bis der Drucker leer und bereit ist; meldet Fortschritt (für `segment`) und
    /// Wartegründe. Mit `segment == nil` wird nur gewartet.
    private func awaitSegment(_ segment: PacedJobPlan.Segment?, alreadyPrinted: Int) async throws -> WaitOutcome {
        var silent = 0
        while true {
            try Task.checkCancellation()
            let status: HostStatus?
            do {
                status = try await client.hostStatus(characters: characters, timeout: options.statusTimeout)
            } catch where Self.isConnectionError(error) {
                return .connectionLost(error)
            }
            guard let status else {
                silent += 1
                if silent >= options.maxSilentPolls {
                    return .connectionLost(PrinterClientError.noResponse("Statusabfrage (~HS)"))
                }
                try await Task.sleep(for: options.pollInterval)
                continue
            }
            silent = 0
            lastStatus = status
            let busy = status.formatsInReceiveBuffer > 0 || status.labelsRemainingInBatch > 0
                || status.partialFormatInProgress
            if let segment {
                if status.formatsInReceiveBuffer > 0 {
                    seenRemaining = segment.quantity
                } else if status.labelsRemainingInBatch > 0 {
                    seenRemaining = min(segment.quantity, status.labelsRemainingInBatch)
                }
                let started = status.formatsInReceiveBuffer == 0 && !status.partialFormatInProgress
                let printedHere = started
                    ? max(0, segment.quantity - min(segment.quantity, status.labelsRemainingInBatch)) : 0
                report(completed + alreadyPrinted + printedHere)
            }
            if let reason = PacedJobWaitReason.reason(for: status) {
                if reason.isFault { faultSeen = true }
                if reason == .paused, faultSeen, options.resumeAfterRecovery {
                    // Fehler behoben, der Drucker steht aber noch pausiert: fortsetzen.
                    faultSeen = false
                    try await client.send(command(ZPL.resume()))
                    onEvent(.resumeSent)
                    try await Task.sleep(for: options.pollInterval)
                    continue
                }
                if waitingReason != reason {
                    waitingReason = reason
                    onEvent(.waiting(reason, printed: max(reported, completed), total: total))
                }
                try await Task.sleep(for: reason == .labelWaitingToBePeeled ? options.pollInterval : options.waitPollInterval)
                continue
            }
            faultSeen = false
            if waitingReason != nil {
                waitingReason = nil
                onEvent(.resumed(printed: max(reported, completed), total: total))
            }
            if !busy { return .done }
            try await Task.sleep(for: options.pollInterval)
        }
    }

    private func report(_ printed: Int) {
        let value = min(total, max(0, printed))
        guard value > reported else { return }
        reported = value
        onEvent(.progress(printed: value, total: total))
    }

    // MARK: Verbindung

    static func isConnectionError(_ error: Error) -> Bool {
        if error is TransportError { return true }
        if case PrinterClientError.transport = error { return true }
        if case PrinterClientError.noResponse = error { return true }
        return false
    }

    /// Führt `body` aus und wiederholt es nach einem Verbindungsabbruch (Kopf, Rest – beides darf
    /// doppelt ankommen, es druckt nichts).
    private func withReconnect(_ body: () async throws -> Void) async throws {
        while true {
            do {
                try await body()
                return
            } catch where Self.isConnectionError(error) {
                try await reconnect(after: error)
            }
        }
    }

    /// Verbindet neu (mit wachsendem Abstand); wirft den ursprünglichen Fehler nach
    /// ``PacedJobOptions/maxReconnectAttempts`` erfolglosen Versuchen.
    private func reconnect(after error: Error) async throws {
        var lastError = error
        var delay = options.reconnectDelay
        for attempt in 1...max(1, options.maxReconnectAttempts) {
            guard options.maxReconnectAttempts > 0 else { break }
            onEvent(.connectionLost(attempt: attempt, message: Self.describe(lastError)))
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
            do {
                await client.disconnect()
                try await client.connect()
                onEvent(.reconnected)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Status direkt nach dem Wiederverbinden (Verbindungsfehler hier gelten als erneuter Abbruch).
    private func statusAfterReconnect() async throws -> HostStatus? {
        while true {
            do {
                let status = try await client.hostStatus(characters: characters, timeout: options.statusTimeout)
                if let status { lastStatus = status }
                return status
            } catch where Self.isConnectionError(error) {
                try await reconnect(after: error)
            }
        }
    }

    /// `~JA`: leert den Drucker – in einem eigenen, nicht abgebrochenen Task.
    private func cancelOnPrinter() async {
        let client = self.client
        let data = command(ZPL.cancelAll())
        await Task {
            try? await client.send(data)
        }.value
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }
}

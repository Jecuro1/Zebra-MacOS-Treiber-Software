import Foundation
import LabelWerkRender

// MARK: - Druckwerk des virtuellen Druckers
//
// Ohne Druckzeit (Standard) druckt der virtuelle Drucker ein Format, sobald es vollständig
// empfangen ist und kein Fehler vorliegt. Mit ``VirtualPrinter/setPrintTime(_:)`` arbeitet er wie ein
// echter Drucker: Formate warten im Empfangspuffer, das erste wird Exemplar für Exemplar gedruckt
// (je Exemplar die Druckzeit). `~HS` meldet dann `formats in receive buffer` (noch nicht begonnene
// Formate) und `labels remaining in batch` (verbleibende Exemplare einschließlich des gerade
// gedruckten).
//
// Fehler während des Drucks (Papier oder Farbband leer, Kopf offen) unterbrechen das Exemplar, das
// gerade gedruckt wird: Mit `^JZY` (Standard der Firmware) wird es nach dem Beheben erneut gedruckt,
// mit `^JZN` ist es verloren (``VirtualPrinter/spoiledLabels``). Eine Pause dagegen lässt das
// laufende Exemplar fertig drucken und hält erst danach an.

extension VirtualPrinter {

    /// Ein empfangenes Format in der Druckwarteschlange.
    struct QueuedFormat: Sendable {
        var label: RenderedLabel
        /// Noch zu druckende Exemplare (einschließlich des gerade gedruckten).
        var remaining: Int
        /// Kennung je Exemplar im ``printLog`` (Inhalt der `^FD`-Felder bzw. Prüfsumme).
        var record: String
        /// Der Druck hat begonnen (zählt nicht mehr als „Format im Puffer“).
        var started = false
        /// Schon in ``renderedLabels`` eingetragen (je Format einmal).
        var listed = false
    }

    /// Fehlerzustände, die sich planen lassen.
    public enum Fault: String, Sendable, CaseIterable {
        /// Etiketten (Papier) leer.
        case mediaOut
        /// Farbband leer (wirkt nur im Thermotransfer-Modus).
        case ribbonOut
        /// Druckkopf geöffnet.
        case headOpen
        /// Pause (wie die Pause-Taste) – unterbricht kein Etikett.
        case paused
    }

    struct ScheduledFault: Sendable {
        var fault: Fault
        /// Exemplare, die vor dem Fehler noch fehlerfrei gedruckt werden.
        var labelsBeforeFault: Int
        var clearAfter: Duration?
        var pauseAfterRecovery: Bool
    }

    /// Höchstzahl der Einträge in ``printLog`` (die neuesten bleiben).
    public static let printLogLimit = 100_000

    // MARK: Öffentliche Simulation

    /// Druckzeit je Etikett; `nil` (Standard) druckt sofort. Mit Druckzeit verhält sich der Drucker
    /// wie ein echter: Formate liegen im Puffer, `~HS` meldet Formate und Restetiketten.
    public func setPrintTime(_ duration: Duration?) {
        if let duration, duration > .zero {
            printTime = duration
        } else {
            printTime = nil
            engineTask?.cancel()
            engineTask = nil
        }
        flushQueue()
    }

    /// Aktuelle Druckzeit je Etikett (`nil` = sofort).
    public var currentPrintTime: Duration? { printTime }

    /// Plant einen Fehler: Nach `afterLabels` weiteren fehlerfrei gedruckten Exemplaren tritt `fault`
    /// mitten im nächsten Exemplar auf. Mit `clearAfter` wird der Fehler nach dieser Zeit behoben
    /// (neue Rolle eingelegt, Kopf geschlossen); `pauseAfterRecovery` lässt den Drucker danach
    /// pausiert stehen, bis `~PS` bzw. die Pause-Taste ihn fortsetzt (wie viele Zebra-Modelle nach
    /// „Papier leer“). Ohne Druckzeit (``setPrintTime(_:)``) wirkt der Fehler ebenso, nur ohne Zeit.
    public func scheduleFault(_ fault: Fault, afterLabels: Int, clearAfter: Duration? = nil,
                              pauseAfterRecovery: Bool = false) {
        scheduledFault = ScheduledFault(fault: fault, labelsBeforeFault: max(0, afterLabels),
                                        clearAfter: clearAfter, pauseAfterRecovery: pauseAfterRecovery)
    }

    /// Verwirft einen noch nicht eingetretenen geplanten Fehler.
    public func cancelScheduledFault() {
        scheduledFault = nil
    }

    /// Setzt oder behebt einen Fehlerzustand (wie ``setMediaOut(_:)`` usw.).
    public func setFault(_ fault: Fault, _ on: Bool) {
        switch fault {
        case .mediaOut: setMediaOut(on)
        case .ribbonOut: setRibbonOut(on)
        case .headOpen: setHeadOpen(on)
        case .paused: setPaused(on)
        }
    }

    /// `^JZ`-Einstellung: Etikett nach einem Fehler erneut drucken.
    public var reprintsAfterError: Bool { reprintAfterError }

    /// Stellt `^JZ` ein (wie `^XA^JZY^XZ` bzw. `^XA^JZN^XZ`).
    public func setReprintAfterError(_ on: Bool) {
        reprintAfterError = on
    }

    /// Ein Eintrag je gedrucktem Exemplar, älteste zuerst (höchstens ``printLogLimit``): der Inhalt
    /// der `^FD`-Felder des Formats (mit „|“ verbunden), sonst eine Prüfsumme des Formats.
    public var printLog: [String] { printLogEntries }

    /// Exemplare, deren Druck ein Fehler unterbrochen hat und die wegen `^JZN` nicht erneut gedruckt
    /// wurden.
    public var spoiledLabels: Int { spoiledCount }

    /// Verwirft ``printLog`` und ``spoiledLabels``.
    public func clearPrintLog() {
        printLogEntries.removeAll()
        spoiledCount = 0
    }

    /// `true`, solange Formate auf den Druck warten oder gedruckt werden.
    public var isPrintingOrQueued: Bool { !queued.isEmpty }

    // MARK: Ablauf

    /// Druckt wartende Formate, sobald der Drucker bereit ist: ohne Druckzeit sofort, sonst startet
    /// das Druckwerk (sofern es nicht schon läuft).
    func flushQueue() {
        guard let printTime else {
            while canPrint, !queued.isEmpty {
                printNextCopy()
            }
            return
        }
        guard engineTask == nil, canPrint, !queued.isEmpty else { return }
        engineTask = Task { [weak self] in
            await self?.runEngine(printTime: printTime)
        }
    }

    /// Druckwerk im Zeitbetrieb: je Exemplar die Druckzeit, danach ist es gedruckt – sofern
    /// währenddessen kein Fehler aufgetreten ist.
    ///
    /// Wer das Druckwerk abbricht (``cancelAllFormats()``, ``setPrintTime(_:)``), setzt
    /// ``engineTask`` selbst zurück – ein abgebrochenes Druckwerk lässt es unverändert, damit es ein
    /// inzwischen neu gestartetes nicht austrägt.
    private func runEngine(printTime: Duration) async {
        while canPrint, !queued.isEmpty {
            queued[0].started = true
            try? await Task.sleep(for: printTime)
            if Task.isCancelled { return }
            guard !queued.isEmpty else { break }
            if hasPrintFault {
                // Fehler während des Exemplars: Druck unterbrochen.
                interruptCurrentCopy()
                break
            }
            // Eine Pause wirkt erst nach dem laufenden Exemplar.
            printNextCopy()
        }
        engineTask = nil
    }

    /// Fehler, die ein laufendes Exemplar unterbrechen (eine Pause gehört nicht dazu).
    var hasPrintFault: Bool {
        headOpen || mediaOut || (ribbonOut && isThermalTransfer)
    }

    /// Druckt ein Exemplar des ersten wartenden Formats – oder löst den geplanten Fehler aus.
    func printNextCopy() {
        guard !queued.isEmpty else { return }
        if var planned = scheduledFault {
            if planned.labelsBeforeFault <= 0 {
                scheduledFault = nil
                trigger(planned)
                queued[0].started = true
                interruptCurrentCopy()
                return
            }
            planned.labelsBeforeFault -= 1
            scheduledFault = planned
        }
        commitCopy()
    }

    /// Ein Exemplar des ersten Formats ist gedruckt.
    private func commitCopy() {
        var entry = queued[0]
        entry.started = true
        if !entry.listed {
            entry.listed = true
            printed.append(entry.label)
            if printed.count > Self.historyLimit { printed.removeFirst(printed.count - Self.historyLimit) }
        }
        advanceMedia(labels: 1, lengthDots: entry.label.heightDots)
        printLogEntries.append(entry.record)
        if printLogEntries.count > Self.printLogLimit {
            printLogEntries.removeFirst(printLogEntries.count - Self.printLogLimit)
        }
        entry.remaining -= 1
        if entry.remaining <= 0 {
            queued.removeFirst()
        } else {
            queued[0] = entry
        }
    }

    /// Ein Fehler hat das laufende Exemplar unterbrochen: mit `^JZY` bleibt es zum erneuten Druck
    /// stehen, mit `^JZN` ist es verloren (das Medium ist trotzdem vorgeschoben).
    private func interruptCurrentCopy() {
        guard !queued.isEmpty, !reprintAfterError else { return }
        spoiledCount += 1
        advanceMedia(labels: 1, lengthDots: queued[0].label.heightDots)
        queued[0].remaining -= 1
        if queued[0].remaining <= 0 { queued.removeFirst() }
    }

    private func trigger(_ planned: ScheduledFault) {
        switch planned.fault {
        case .mediaOut:
            mediaOut = true
            store.force("media.status", "out")
            calibrationNeeded = true
        case .ribbonOut:
            ribbonOut = true
        case .headOpen:
            headOpen = true
            store.force("head.latch", "open")
        case .paused:
            paused = true
        }
        guard let delay = planned.clearAfter else { return }
        faultRecoveryTask?.cancel()
        let fault = planned.fault
        let pause = planned.pauseAfterRecovery
        faultRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.recover(from: fault, pause: pause)
        }
    }

    private func recover(from fault: Fault, pause: Bool) {
        faultRecoveryTask = nil
        if pause { paused = true }
        setFault(fault, false)
    }

    /// `~JA`, Neustart: alle wartenden Formate verwerfen (auch das gerade gedruckte).
    func cancelAllFormats() {
        queued.removeAll()
        engineTask?.cancel()
        engineTask = nil
    }

    // MARK: Kennung je Exemplar

    /// Kennung eines Formats für ``printLog``: die `^FD`-Daten (mit „|“ verbunden, höchstens 200
    /// Zeichen), sonst eine FNV-1a-Prüfsumme des Formattexts.
    static func printRecord(forFormat text: String) -> String {
        var fields: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "^FD", options: .caseInsensitive) {
            let after = rest[start.upperBound...]
            let end = after.firstIndex(of: "^") ?? after.endIndex
            fields.append(String(after[..<end]))
            rest = after[end...]
            if fields.joined(separator: "|").count > 200 { break }
        }
        if !fields.isEmpty { return String(fields.joined(separator: "|").prefix(200)) }
        return "fnv:" + fnv1a(Array(text.utf8))
    }

    /// Kennung für Etiketten ohne Formattext (EPL, CPCL, Berichte).
    static func printRecord(for label: RenderedLabel) -> String {
        "label:\(label.widthDots)x\(label.heightDots)#\(label.elements.count)"
    }

    static func fnv1a(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

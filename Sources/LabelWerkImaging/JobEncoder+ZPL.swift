import Foundation
import LabelWerkCore

/// Erzeugt ZPL-Befehlszeilen mit den wirksamen Steuerzeichen (ARCHITECTURE.md §8,
/// „Steuerzeichen“): Formatpräfix statt `^`, Steuerpräfix statt `~`, Trennzeichen statt `,`
/// zwischen Parametern. Parameter selbst (z. B. Grafikdaten) bleiben unverändert.
struct ZPLDialect {
    let formatPrefix: String
    let controlPrefix: String
    let delimiter: String

    init(_ characters: ControlCharacters) {
        formatPrefix = characters.formatPrefixString
        controlPrefix = characters.controlPrefixString
        delimiter = characters.delimiterString
    }

    /// Formatbefehl, z. B. `format("LH", "0", "0")` → `^LH0,0`. Der erste Parameter folgt
    /// direkt auf den Code (wie bei `ZPLCommand`).
    func format(_ code: String, _ parameters: String...) -> String {
        formatPrefix + code + parameters.joined(separator: delimiter)
    }

    /// Steuerbefehl, z. B. `control("SD", "08")` → `~SD08`.
    func control(_ code: String, _ parameters: String...) -> String {
        controlPrefix + code + parameters.joined(separator: delimiter)
    }

    /// `^XA^ST{MM},{DD},{YYYY},{HH},{mm},{SS},M^XZ` für den Zeitpunkt `epochSeconds` in `timeZone`.
    func setClock(epochSeconds: Int64, timeZone: TimeZone) -> String {
        let c = ZPL.clockComponents(Date(timeIntervalSince1970: TimeInterval(epochSeconds)), timeZone: timeZone)
        func pad(_ value: Int, _ width: Int) -> String { JobEncoder.zeroPadded(value, width: width) }
        return format("XA")
            + format("ST", pad(c.month, 2), pad(c.day, 2), pad(c.year, 4), pad(c.hour, 2), pad(c.minute, 2),
                     pad(c.second, 2), "M")
            + format("XZ")
    }
}

/// Zeitpunkte, zu denen ein Auftrag die Echtzeituhr stellt (`^ST`, ``RTCUpdate``).
///
/// * Auftragsbeginn: immer, sobald ``RTCUpdate`` gesetzt ist.
/// * ``RTCUpdate/everyLabel``: zusätzlich vor jedem Etikett außer dem ersten.
/// * ``RTCUpdate/everyMinute``: zusätzlich vor jedem Etikett (auch dem ersten), wenn seit dem
///   letzten `^ST` mindestens 60 s vergangen sind.
///
/// Zeiten sind ganze Sekunden seit 1970 (abgerundet) – wie `time()` im C-Filter. Etikett k
/// (0-basiert, in Auftragsreihenfolge inklusive Sortierwiederholungen) sieht
/// `now() + k · timeStep` – mit fester Zeit wie `LW_FIXED_TIME` + `LW_TIME_STEP_SECONDS` im
/// C-Filter bzw. `now`/`time_step` der Python-Referenz.
struct RTCClock {
    let update: RTCUpdate?
    let now: @Sendable () -> Date
    let timeStep: Int64
    let timeZone: TimeZone
    let dialect: ZPLDialect
    private(set) var lastSet: Int64?

    init(update: RTCUpdate?, now: @escaping @Sendable () -> Date, timeStep: Int64 = 0, timeZone: TimeZone,
         dialect: ZPLDialect) {
        self.update = update
        self.now = now
        self.timeStep = timeStep
        self.timeZone = timeZone
        self.dialect = dialect
    }

    private func currentSeconds() -> Int64 {
        let seconds = now().timeIntervalSince1970.rounded(.down)
        guard seconds.isFinite else { return 0 }
        return Int64(max(min(seconds, 1e15), -1e15))
    }

    /// `^ST`-Zeile zu Auftragsbeginn (oder `nil`).
    mutating func jobStart() -> String? {
        guard update != nil else { return nil }
        return set(currentSeconds())
    }

    /// Zeit für Etikett `label` (0-basiert).
    private func labelSeconds(_ label: Int) -> Int64 {
        let (offset, overflow) = Int64(label).multipliedReportingOverflow(by: timeStep)
        return overflow ? currentSeconds() : currentSeconds() &+ offset
    }

    /// `^ST`-Zeile vor Etikett `label` (0-basiert, Auftragsreihenfolge) oder `nil`.
    mutating func beforeLabel(_ label: Int) -> String? {
        switch update {
        case .everyLabel?:
            return label == 0 ? nil : set(labelSeconds(label))
        case .everyMinute?:
            let seconds = labelSeconds(label)
            guard let last = lastSet, seconds - last >= JobEncoder.rtcMinuteInterval else { return nil }
            return set(seconds)
        case .jobStart?, nil:
            return nil
        }
    }

    private mutating func set(_ seconds: Int64) -> String {
        lastSet = seconds
        return dialect.setClock(epochSeconds: seconds, timeZone: timeZone)
    }
}

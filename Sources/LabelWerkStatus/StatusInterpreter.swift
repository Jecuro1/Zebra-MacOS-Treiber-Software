import Foundation

/// Leitet aus `~HS`, `~HQES` und SGD-Werten Meldungen, Gesamtzustand und Kennzahlen ab.
public enum StatusInterpreter {

    /// SGD-Namen, die der Interpreter auswertet.
    public enum SGDKey {
        public static let totalPrintLength = "odometer.total_print_length"
        public static let totalLabelCount = "odometer.total_label_count"
        public static let batteryPercent = "power.percent_full"
        /// Kopfverriegelung bei Mobildruckern („ok“/„open“).
        public static let headLatch = "head.latch"
        /// Medienstatus bei Mobildruckern („ok“/„out“).
        public static let mediaStatus = "media.status"
        /// Mögliche Namen für die Druckkopftemperatur (je nach Firmware), in Prüfreihenfolge.
        public static let headTemperatureCandidates = [
            "head.temperature", "print.head.temperature", "head.temp", "device.head_temperature",
        ]
    }

    /// Empfohlene SGD-Variablen für eine Statusabfrage.
    public static let statusVariables: [String] = [
        SGDKey.totalPrintLength, SGDKey.totalLabelCount, SGDKey.batteryPercent,
        SGDKey.headLatch, SGDKey.mediaStatus, SGDKey.headTemperatureCandidates[0],
    ]

    /// Erstellt die Momentaufnahme.
    ///
    /// Zustandsregeln (in dieser Reihenfolge):
    /// 1. keine Daten → `unknown`
    /// 2. mindestens eine Meldung mit Schweregrad `error` → `error`
    /// 3. pausiert (`~HS` Feld c, `~HQES` Pause-Bit) → `paused`
    /// 4. mindestens eine Warnung → `warning`
    /// 5. Restetiketten > 0 oder Formate im Empfangspuffer > 0 → `printing`
    /// 6. sonst → `ready`
    public static func snapshot(hostStatus: HostStatus?, query: HostQueryStatus?, sgd: [String: String] = [:],
                                now: Date = Date()) -> PrinterStatusSnapshot {
        let alerts = self.alerts(hostStatus: hostStatus, query: query, sgd: sgd)
        let state = self.state(alerts: alerts, hostStatus: hostStatus, query: query, hasSGD: !sgd.isEmpty)
        return PrinterStatusSnapshot(
            timestamp: now,
            state: state,
            alerts: alerts,
            hostStatus: hostStatus,
            queryStatus: query,
            odometerMeters: sgd[SGDKey.totalPrintLength].flatMap(meters(fromOdometer:)),
            labelsPrinted: sgd[SGDKey.totalLabelCount].flatMap(integer(fromSGD:)),
            headTemperatureC: SGDKey.headTemperatureCandidates.lazy.compactMap { sgd[$0] }
                .compactMap(celsius(fromSGD:)).first,
            batteryPercent: sgd[SGDKey.batteryPercent].flatMap(integer(fromSGD:)).map { min(100, max(0, $0)) },
            sgd: sgd
        )
    }

    // MARK: Meldungen

    /// Alle Meldungen ohne Duplikate, nach Schwere sortiert.
    ///
    /// SGD-Werte (`head.latch`, `media.status`) werden nur herangezogen, wenn weder `~HS`
    /// noch `~HQES` vorliegen (z. B. Mobildrucker im Line-Print-Modus).
    public static func alerts(hostStatus: HostStatus?, query: HostQueryStatus?, sgd: [String: String] = [:])
        -> [PrinterAlert] {
        var kinds = Set<AlertKind>()
        if let hostStatus { kinds.formUnion(alertKinds(for: hostStatus)) }
        if let query { kinds.formUnion(alertKinds(for: query)) }
        if hostStatus == nil, query == nil { kinds.formUnion(alertKinds(forSGD: sgd)) }
        return PrinterAlert.sorted(kinds.map(PrinterAlert.make))
    }

    /// Meldungen aus `~HS`.
    public static func alertKinds(for status: HostStatus) -> Set<AlertKind> {
        var kinds = Set<AlertKind>()
        if status.paperOut { kinds.insert(.mediaOut) }
        if status.paused { kinds.insert(.paused) }
        if status.receiveBufferFull { kinds.insert(.receiveBufferFull) }
        if status.corruptRAM { kinds.insert(.corruptRAM) }
        if status.underTemperature { kinds.insert(.underTemperature) }
        if status.overTemperature { kinds.insert(.overTemperature) }
        if status.headOpen { kinds.insert(.headOpen) }
        // Im Thermodirekt-Modus ist ein fehlendes Farbband kein Fehler.
        if status.ribbonOut && status.thermalTransferMode { kinds.insert(.ribbonOut) }
        if status.labelWaitingToBePeeled { kinds.insert(.labelWaitingToBePeeled) }
        return kinds
    }

    /// Meldungen aus `~HQES`. Kiosk-Sensorbits erzeugen keine Meldungen.
    public static func alertKinds(for query: HostQueryStatus) -> Set<AlertKind> {
        let errorMapping: [(PrinterErrorFlags, AlertKind)] = [
            (.mediaOut, .mediaOut),
            (.ribbonOut, .ribbonOut),
            (.headOpen, .headOpen),
            (.cutterFault, .cutterFault),
            (.printheadOverTemp, .headOverTemperature),
            (.motorOverTemp, .motorOverTemperature),
            (.badPrintheadElement, .badPrintheadElement),
            (.printheadDetectionError, .printheadDetectionError),
            (.invalidFirmwareConfig, .invalidFirmwareConfig),
            (.printheadThermistorOpen, .printheadDetectionError),
            (.clearPaperPathFailed, .paperFeedError),
            (.paperFeedError, .paperFeedError),
            (.presenterNotRunning, .paperFeedError),
            (.paperJamDuringRetract, .paperFeedError),
            (.blackMarkNotFound, .blackMarkNotFound),
            (.blackMarkCalibrateError, .blackMarkNotFound),
            (.retractTimeout, .paperFeedError),
            (.paused, .paused),
        ]
        let warningMapping: [(PrinterWarningFlags, AlertKind)] = [
            (.needCalibration, .needsCalibration),
            (.cleanPrinthead, .cleanPrinthead),
            (.replacePrinthead, .replacePrinthead),
            (.paperNearEnd, .mediaNearEnd),
        ]
        var kinds = Set<AlertKind>()
        for (flag, kind) in errorMapping where query.errors.contains(flag) { kinds.insert(kind) }
        for (flag, kind) in warningMapping where query.warnings.contains(flag) { kinds.insert(kind) }
        return kinds
    }

    /// Meldungen aus SGD-Werten (Mobildrucker).
    public static func alertKinds(forSGD sgd: [String: String]) -> Set<AlertKind> {
        var kinds = Set<AlertKind>()
        if let latch = sgd[SGDKey.headLatch].map(normalizedWord), latch == "open" {
            kinds.insert(.headOpen)
        }
        if let media = sgd[SGDKey.mediaStatus].map(normalizedWord), media == "out" || media.hasPrefix("out ") {
            kinds.insert(.mediaOut)
        }
        return kinds
    }

    /// Gesamtzustand gemäß den Regeln in ``snapshot(hostStatus:query:sgd:now:)``.
    static func state(alerts: [PrinterAlert], hostStatus: HostStatus?, query: HostQueryStatus?,
                      hasSGD: Bool) -> PrinterState {
        if hostStatus == nil, query == nil, !hasSGD { return .unknown }
        if alerts.contains(where: { $0.severity == .error }) { return .error }
        let paused = hostStatus?.paused == true
            || query?.errors.contains(.paused) == true
            || alerts.contains(where: { $0.kind == .paused })
        if paused { return .paused }
        if alerts.contains(where: { $0.severity == .warning }) { return .warning }
        if let hostStatus, hostStatus.labelsRemainingInBatch > 0 || hostStatus.formatsInReceiveBuffer > 0 {
            return .printing
        }
        return .ready
    }

    // MARK: SGD-Werte

    /// Wandelt eine Odometer-Angabe in Meter um.
    ///
    /// Beispiele: „7,342 INCHES“ → 186.4868, „18,649 CENTIMETERS“ → 186.49,
    /// „1520 INCHES, 3861 CENTIMETERS“ → 38.61 (metrische Angabe bevorzugt).
    /// Ohne Einheit ist der Wert mehrdeutig → `nil`.
    public static func meters(fromOdometer text: String) -> Double? {
        var metric: Double?
        var imperial: Double?
        var rest = Substring(text)
        while let (value, after) = StatusText.leadingNumber(String(rest)) {
            let unitStart = after.drop(while: { $0 == " " || $0 == "\t" })
            // Einheit: Buchstabenfolge oder ein einzelnes Zollzeichen (z. B. 250").
            let unit = unitStart.first == "\"" ? unitStart.prefix(1) : unitStart.prefix(while: { $0.isLetter })
            if let factor = unitFactor(String(unit).uppercased()) {
                if factor.isMetric { metric = metric ?? value * factor.meters }
                else { imperial = imperial ?? value * factor.meters }
            }
            rest = unitStart.dropFirst(unit.count)
            if rest.isEmpty { break }
        }
        guard let result = metric ?? imperial, result >= 0 else { return nil }
        return result
    }

    static func unitFactor(_ unit: String) -> (meters: Double, isMetric: Bool)? {
        switch unit {
        case "IN", "INCH", "INCHES", "\"", "ZOLL": return (0.0254, false)
        case "FT", "FOOT", "FEET": return (0.3048, false)
        case "MM", "MILLIMETER", "MILLIMETERS", "MILLIMETRE", "MILLIMETRES": return (0.001, true)
        case "CM", "CENTIMETER", "CENTIMETERS", "CENTIMETRE", "CENTIMETRES", "ZENTIMETER": return (0.01, true)
        case "M", "METER", "METERS", "METRE", "METRES": return (1, true)
        case "KM", "KILOMETER", "KILOMETERS", "KILOMETRE", "KILOMETRES": return (1000, true)
        default: return nil
        }
    }

    /// Ganzzahl aus einem SGD-Wert wie „1,234“, „85%“, „\"1234\"“ oder „1,234 LABELS“.
    public static func integer(fromSGD text: String) -> Int? {
        guard let (value, _) = StatusText.leadingNumber(text),
              value.rounded(.towardZero) == value,
              abs(value) < 9.0e15 else { return nil }
        return Int(value)
    }

    /// Temperatur in °C aus Angaben wie „28“, „28 C“, „28.5°C“ oder „82 F“.
    public static func celsius(fromSGD text: String) -> Double? {
        guard let (value, after) = StatusText.leadingNumber(text) else { return nil }
        let unit = after.drop(while: { $0 == " " || $0 == "°" || $0 == "º" }).prefix(1).uppercased()
        let celsius = unit == "F" ? (value - 32) * 5 / 9 : value
        guard celsius > -100, celsius < 400 else { return nil }
        return celsius
    }

    static func normalizedWord(_ text: String) -> String {
        StatusText.trim(text.replacingOccurrences(of: "\"", with: "")).lowercased()
    }
}

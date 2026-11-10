import Foundation

/// Momentaufnahme des Druckerstatus – Grundlage für Übersicht, Menüleiste und Benachrichtigungen.
public struct PrinterStatusSnapshot: Hashable, Codable, Sendable {
    /// Zeitpunkt der Abfrage.
    public var timestamp: Date
    /// Abgeleiteter Gesamtzustand.
    public var state: PrinterState
    /// Aktive Meldungen, nach Schwere sortiert (Fehler zuerst).
    public var alerts: [PrinterAlert]
    /// Rohdaten aus `~HS`, falls verfügbar.
    public var hostStatus: HostStatus?
    /// Rohdaten aus `~HQES`, falls verfügbar.
    public var queryStatus: HostQueryStatus?
    /// Gesamte Drucklänge in Metern (`odometer.total_print_length`).
    public var odometerMeters: Double?
    /// Insgesamt gedruckte Etiketten (`odometer.total_label_count`).
    public var labelsPrinted: Int?
    /// Druckkopftemperatur in °C, sofern der Drucker sie meldet.
    public var headTemperatureC: Double?
    /// Akkuladung in Prozent (`power.percent_full`, nur Mobildrucker).
    public var batteryPercent: Int?
    /// Alle abgefragten SGD-Werte (Name → Wert).
    public var sgd: [String: String]

    public init(
        timestamp: Date = Date(),
        state: PrinterState,
        alerts: [PrinterAlert] = [],
        hostStatus: HostStatus? = nil,
        queryStatus: HostQueryStatus? = nil,
        odometerMeters: Double? = nil,
        labelsPrinted: Int? = nil,
        headTemperatureC: Double? = nil,
        batteryPercent: Int? = nil,
        sgd: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.state = state
        self.alerts = PrinterAlert.sorted(alerts)
        self.hostStatus = hostStatus
        self.queryStatus = queryStatus
        self.odometerMeters = odometerMeters
        self.labelsPrinted = labelsPrinted
        self.headTemperatureC = headTemperatureC
        self.batteryPercent = batteryPercent
        self.sgd = sgd
    }

    /// Zustand „keine Verbindung“ mit passender Meldung.
    public static let offline = PrinterStatusSnapshot.offline(at: .distantPast)

    /// Zustand „keine Verbindung“ zu einem bestimmten Zeitpunkt.
    public static func offline(at date: Date) -> PrinterStatusSnapshot {
        PrinterStatusSnapshot(timestamp: date, state: .offline, alerts: [PrinterAlert.make(.offline)])
    }

    /// Druckbereit: Aufträge werden angenommen und gedruckt (Zustand bereit, druckend oder
    /// nur mit Warnungen). Pausiert, Fehler, offline und unbekannt sind nicht druckbereit.
    public var isReady: Bool {
        switch state {
        case .ready, .printing, .warning: return true
        case .paused, .error, .offline, .unknown: return false
        }
    }

    /// Dringlichste Meldung.
    public var mostSevereAlert: PrinterAlert? { alerts.first }

    /// Höchster vorkommender Schweregrad.
    public var highestSeverity: AlertSeverity? { alerts.map(\.severity).max() }

    /// Meldungen eines Schweregrads.
    public func alerts(withSeverity severity: AlertSeverity) -> [PrinterAlert] {
        alerts.filter { $0.severity == severity }
    }

    /// `true`, wenn eine Meldung dieser Art aktiv ist.
    public func hasAlert(_ kind: AlertKind) -> Bool {
        alerts.contains { $0.kind == kind }
    }
}

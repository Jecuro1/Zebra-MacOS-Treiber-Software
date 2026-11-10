import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("StatusInterpreter – Zustand, Meldungen, Kennzahlen")
struct StatusInterpreterTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ hs: HostStatus? = HostStatus(), _ query: HostQueryStatus? = nil,
                  sgd: [String: String] = [:]) -> PrinterStatusSnapshot {
        StatusInterpreter.snapshot(hostStatus: hs, query: query, sgd: sgd, now: Self.now)
    }

    @Test("Ohne Daten: unbekannt")
    func unknownWithoutData() {
        let s = snapshot(nil, nil)
        #expect(s.state == .unknown)
        #expect(s.alerts.isEmpty)
        #expect(!s.isReady)
        #expect(s.timestamp == Self.now)
    }

    @Test("Bereit")
    func ready() throws {
        let hs = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusReady))
        let query = try HostQueryParser.parse(TestSupport.data(Fixtures.hostQueryClean))
        let s = snapshot(hs, query)
        #expect(s.state == .ready)
        #expect(s.alerts.isEmpty)
        #expect(s.isReady)
        #expect(s.hostStatus == hs)
        #expect(s.queryStatus == query)
        #expect(s.mostSevereAlert == nil)
        #expect(s.highestSeverity == nil)
    }

    @Test("Medium leer → Fehler")
    func mediaOutIsError() {
        let s = snapshot(HostStatus(paperOut: true))
        #expect(s.state == .error)
        #expect(s.alerts.map(\.kind) == [.mediaOut])
        #expect(!s.isReady)
        #expect(s.hasAlert(.mediaOut))
    }

    @Test("Pause → pausiert (Info-Meldung)")
    func pausedState() {
        let s = snapshot(HostStatus(paused: true))
        #expect(s.state == .paused)
        #expect(s.alerts.map(\.kind) == [.paused])
        #expect(s.alerts.first?.severity == .info)
        #expect(!s.isReady)
    }

    @Test("Pause über ~HQES-Bit")
    func pausedViaQuery() {
        let s = snapshot(nil, HostQueryStatus(errors: .paused))
        #expect(s.state == .paused)
        #expect(s.hasAlert(.paused))
    }

    @Test("Pause hat Vorrang vor Warnungen")
    func pausedBeatsWarning() {
        let s = snapshot(HostStatus(paused: true), HostQueryStatus(warnings: .cleanPrinthead))
        #expect(s.state == .paused)
        #expect(s.alerts.map(\.kind) == [.cleanPrinthead, .paused])
    }

    @Test("Fehler hat Vorrang vor Pause")
    func errorBeatsPaused() {
        let s = snapshot(HostStatus(paused: true, headOpen: true))
        #expect(s.state == .error)
        #expect(s.alerts.map(\.kind) == [.headOpen, .paused])
    }

    @Test("Nur Warnungen → Warnung, aber druckbereit")
    func warningState() {
        let s = snapshot(HostStatus(), HostQueryStatus(warnings: [.cleanPrinthead, .paperNearEnd]))
        #expect(s.state == .warning)
        #expect(s.isReady)
        #expect(s.alerts.map(\.kind) == [.cleanPrinthead, .mediaNearEnd])
        #expect(s.highestSeverity == .warning)
    }

    @Test("Warnungen haben Vorrang vor „druckt“")
    func warningBeatsPrinting() {
        let s = snapshot(HostStatus(labelsRemainingInBatch: 3), HostQueryStatus(warnings: .needCalibration))
        #expect(s.state == .warning)
    }

    @Test("Druckt: Restetiketten oder Formate im Puffer")
    func printingState() throws {
        let hs = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusPrinting))
        #expect(snapshot(hs).state == .printing)
        #expect(snapshot(HostStatus(labelsRemainingInBatch: 1)).state == .printing)
        #expect(snapshot(HostStatus(formatsInReceiveBuffer: 1)).state == .printing)
        #expect(snapshot(HostStatus(labelsRemainingInBatch: 1)).isReady)
    }

    @Test("Info-Meldung „Etikett entnehmen“ ändert den Zustand nicht")
    func infoKeepsReady() {
        let s = snapshot(HostStatus(printMode: .peelOff, labelWaitingToBePeeled: true))
        #expect(s.state == .ready)
        #expect(s.alerts.map(\.kind) == [.labelWaitingToBePeeled])
    }

    @Test("Farbband leer nur im Thermotransfer-Modus")
    func ribbonOutOnlyInThermalTransfer() {
        #expect(snapshot(HostStatus(ribbonOut: true, thermalTransferMode: false)).alerts.isEmpty)
        #expect(snapshot(HostStatus(ribbonOut: true, thermalTransferMode: true)).alerts.map(\.kind) == [.ribbonOut])
        // ~HQES meldet Farbbandfehler nur, wenn er relevant ist – dort immer übernehmen.
        #expect(snapshot(nil, HostQueryStatus(errors: .ribbonOut)).state == .error)
    }

    @Test("Doppelte Quellen ergeben eine Meldung")
    func deduplicates() {
        let s = snapshot(HostStatus(paperOut: true, headOpen: true), HostQueryStatus(errors: [.mediaOut, .headOpen]))
        #expect(s.alerts.map(\.kind) == [.mediaOut, .headOpen])
    }

    @Test("Alle ~HS-Flags", arguments: [
        (HostStatus(paperOut: true), AlertKind.mediaOut),
        (HostStatus(paused: true), .paused),
        (HostStatus(receiveBufferFull: true), .receiveBufferFull),
        (HostStatus(corruptRAM: true), .corruptRAM),
        (HostStatus(underTemperature: true), .underTemperature),
        (HostStatus(overTemperature: true), .overTemperature),
        (HostStatus(headOpen: true), .headOpen),
        (HostStatus(ribbonOut: true, thermalTransferMode: true), .ribbonOut),
        (HostStatus(labelWaitingToBePeeled: true), .labelWaitingToBePeeled),
    ])
    func hostStatusFlagMapping(status: HostStatus, kind: AlertKind) {
        #expect(StatusInterpreter.alertKinds(for: status) == [kind])
    }

    @Test("Alle ~HQES-Fehlerbits", arguments: [
        (PrinterErrorFlags.mediaOut, AlertKind.mediaOut),
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
    ])
    func errorFlagMapping(flag: PrinterErrorFlags, kind: AlertKind) {
        #expect(StatusInterpreter.alertKinds(for: HostQueryStatus(errors: flag)) == [kind])
    }

    @Test("Alle ~HQES-Warnbits", arguments: [
        (PrinterWarningFlags.needCalibration, [AlertKind.needsCalibration]),
        (PrinterWarningFlags.cleanPrinthead, [AlertKind.cleanPrinthead]),
        (PrinterWarningFlags.replacePrinthead, [AlertKind.replacePrinthead]),
        (PrinterWarningFlags.paperNearEnd, [AlertKind.mediaNearEnd]),
        (PrinterWarningFlags.sensors, [AlertKind]()),
    ])
    func warningFlagMapping(flag: PrinterWarningFlags, kinds: [AlertKind]) {
        #expect(StatusInterpreter.alertKinds(for: HostQueryStatus(warnings: flag)) == Set(kinds))
    }

    @Test("Meldungen nach Schwere sortiert")
    func alertOrdering() {
        let hs = HostStatus(paperOut: true, paused: true, receiveBufferFull: true, headOpen: true,
                            labelWaitingToBePeeled: true)
        let query = HostQueryStatus(errors: [.cutterFault], warnings: [.cleanPrinthead, .needCalibration])
        let s = snapshot(hs, query)
        let severities = s.alerts.map(\.severity)
        #expect(severities == severities.sorted(by: >))
        #expect(s.alerts.map(\.kind) == [
            .mediaOut, .headOpen, .cutterFault,
            .receiveBufferFull, .needsCalibration, .cleanPrinthead,
            .paused, .labelWaitingToBePeeled,
        ])
        #expect(s.mostSevereAlert?.kind == .mediaOut)
        #expect(s.alerts(withSeverity: .info).map(\.kind) == [.paused, .labelWaitingToBePeeled])
    }

    @Test("Snapshot-Initialisierer sortiert Meldungen")
    func initializerSorts() {
        let s = PrinterStatusSnapshot(state: .error, alerts: [.make(.cleanPrinthead), .make(.headOpen)])
        #expect(s.alerts.map(\.kind) == [.headOpen, .cleanPrinthead])
    }

    @Test("SGD-Kennzahlen")
    func sgdMetrics() {
        let sgd = [
            "odometer.total_print_length": "7,342 INCHES",
            "odometer.total_label_count": "12,345",
            "power.percent_full": "85%",
            "head.temperature": "31 C",
            "device.friendly_name": "Lager-01",
        ]
        let s = snapshot(HostStatus(), nil, sgd: sgd)
        #expect(abs((s.odometerMeters ?? 0) - 186.4868) < 1e-9)
        #expect(s.labelsPrinted == 12_345)
        #expect(s.batteryPercent == 85)
        #expect(s.headTemperatureC == 31)
        #expect(s.sgd == sgd)
        #expect(s.state == .ready)
    }

    @Test("Akkustand wird auf 0…100 begrenzt")
    func batteryClamp() {
        #expect(snapshot(sgd: ["power.percent_full": "120"]).batteryPercent == 100)
        #expect(snapshot(sgd: ["power.percent_full": "-5"]).batteryPercent == 0)
        #expect(snapshot(sgd: ["power.percent_full": "?"]).batteryPercent == nil)
    }

    @Test("Odometer-Angaben", arguments: [
        ("7,342 INCHES", Optional(186.4868)),
        ("18,649 CENTIMETERS", 186.49),
        ("1520 INCHES, 3861 CENTIMETERS", 38.61),
        ("\"250 IN\"", 6.35),
        ("250\"", 6.35),
        ("1,234,567 cm", 12_345.67),
        ("12.5 M", 12.5),
        ("100 FEET", 30.48),
        ("500 MM", 0.5),
        ("7342", nil),
        ("", nil),
        ("UNKNOWN", nil),
        ("ODO - 10 INCHES", 0.254),
    ])
    func odometer(text: String, meters: Double?) {
        let result = StatusInterpreter.meters(fromOdometer: text)
        if let meters {
            #expect(result != nil)
            #expect(abs((result ?? 0) - meters) < 1e-9, "\(text) → \(String(describing: result))")
        } else {
            #expect(result == nil)
        }
    }

    @Test("Ganzzahlen aus SGD-Werten", arguments: [
        ("1234", Optional(1234)), ("1,234", 1234), ("\"98\"", 98), ("85%", 85), ("1,234 LABELS", 1234),
        ("12.5", nil), ("abc", nil), ("", nil),
    ])
    func sgdIntegers(text: String, expected: Int?) {
        #expect(StatusInterpreter.integer(fromSGD: text) == expected)
    }

    @Test("Temperaturen", arguments: [
        ("28", Optional(28.0)), ("28 C", 28), ("28.5°C", 28.5), ("82.4 F", 28), ("-5 C", -5), ("hot", nil),
        ("9999", nil),
    ])
    func temperatures(text: String, expected: Double?) {
        let result = StatusInterpreter.celsius(fromSGD: text)
        if let expected {
            #expect(abs((result ?? .nan) - expected) < 1e-9)
        } else {
            #expect(result == nil)
        }
    }

    @Test("Alternative SGD-Namen für die Kopftemperatur")
    func headTemperatureCandidates() {
        #expect(snapshot(sgd: ["head.temp": "40"]).headTemperatureC == 40)
        #expect(snapshot(sgd: ["head.temperature": "?", "print.head.temperature": "35 C"]).headTemperatureC == 35)
        #expect(snapshot(sgd: [:]).headTemperatureC == nil)
    }

    @Test("SGD-Fallback für Mobildrucker ohne ~HS/~HQES")
    func sgdFallbackAlerts() {
        let s = snapshot(nil, nil, sgd: ["head.latch": "\"open\"", "media.status": "OUT"])
        #expect(s.state == .error)
        #expect(s.alerts.map(\.kind) == [.mediaOut, .headOpen])
        let ok = snapshot(nil, nil, sgd: ["head.latch": "ok", "media.status": "ok"])
        #expect(ok.state == .ready)
        #expect(ok.alerts.isEmpty)
        // Mit ~HS haben dessen Flags Vorrang; SGD wird nicht zusätzlich ausgewertet.
        let withHS = snapshot(HostStatus(), nil, sgd: ["head.latch": "open"])
        #expect(withHS.alerts.isEmpty)
    }

    @Test("Offline-Momentaufnahme")
    func offlineSnapshot() {
        let s = PrinterStatusSnapshot.offline
        #expect(s.state == .offline)
        #expect(s.alerts.map(\.kind) == [.offline])
        #expect(!s.isReady)
        #expect(s.timestamp == .distantPast)
        #expect(PrinterStatusSnapshot.offline(at: Self.now).timestamp == Self.now)
    }

    @Test("isReady je Zustand", arguments: PrinterState.allCases)
    func readiness(state: PrinterState) {
        let expected = [PrinterState.ready, .printing, .warning].contains(state)
        #expect(PrinterStatusSnapshot(state: state).isReady == expected)
    }


    // MARK: Review-Regressionen

    @Test("Unbekannte ~HQES-Fehlerbits → Fehler, nie „Bereit“", arguments: [
        PrinterErrorFlags(rawValue: 0x0004_0000),           // Gruppe 1, oberhalb der bekannten Bits
        PrinterErrorFlags(rawValue: 0x8000_0000),           // höchstes Bit in Gruppe 1
        PrinterErrorFlags(group2: 0x1, group1: 0),           // Gruppe 2
        PrinterErrorFlags(group2: 0x1, group1: 0x0002_0000), // unbekannt + Pause → Fehler hat Vorrang
    ])
    func unknownErrorBits(flags: PrinterErrorFlags) {
        let s = snapshot(nil, HostQueryStatus(errors: flags))
        #expect(s.state == .error)
        #expect(!s.isReady)
        #expect(s.queryStatus?.errors.unknownFlags.isEmpty == false)
        // Keine fachfremde Meldung: höchstens die Pause-Info des bekannten Pause-Bits.
        #expect(s.alerts.allSatisfy { $0.kind == .paused })
        // Auch mit bereitem ~HS bleibt der Zustand „Fehler“.
        #expect(snapshot(HostStatus(), HostQueryStatus(errors: flags)).state == .error)
    }

    @Test("Unbekannte Fehlerbits aus der Druckerantwort (End-to-End)")
    func unknownErrorBitsFromResponse() throws {
        let query = try HostQueryParser.parse(TestSupport.data("ERRORS: 1 00000000 00040000\r\nWARNINGS: 0 00000000 00000000"))
        let s = snapshot(nil, query)
        #expect(s.state == .error)
        #expect(!s.isReady)
        #expect(query.errors.displayNames == ["Unbekannter Fehler 0x40000"])
        let group2 = try HostQueryParser.parse(TestSupport.data("ERRORS: 1 00000001 00000000"))
        #expect(snapshot(nil, group2).state == .error)
    }

    @Test("Bekannte und unbekannte Fehlerbits zusammen")
    func knownAndUnknownErrorBits() {
        let s = snapshot(nil, HostQueryStatus(errors: PrinterErrorFlags(rawValue: 0x0004_0001)))
        #expect(s.state == .error)
        #expect(s.alerts.map(\.kind) == [.mediaOut])
        // Unbekannte Warnbits und Kiosk-Sensoren bleiben ohne Einfluss auf den Fehlerzustand.
        let warningsOnly = snapshot(HostStatus(), HostQueryStatus(warnings: PrinterWarningFlags(rawValue: 0x1_0000_0FF0)))
        #expect(warningsOnly.state == .ready)
    }

    @Test("Nur SGD-Kennzahlen ohne ~HS/~HQES → unbekannt")
    func sgdMetricsAloneAreUnknown() {
        let s = snapshot(nil, nil, sgd: ["power.percent_full": "80", "odometer.total_label_count": "5"])
        #expect(s.state == .unknown)
        #expect(!s.isReady)
        #expect(s.alerts.isEmpty)
        // Die Kennzahlen werden trotzdem ausgewertet.
        #expect(s.batteryPercent == 80)
        #expect(s.labelsPrinted == 5)
        let allMetrics = snapshot(nil, nil, sgd: [
            "odometer.total_print_length": "7,342 INCHES", "head.temperature": "31 C",
            "device.friendly_name": "Lager-01",
        ])
        #expect(allMetrics.state == .unknown)
        #expect(allMetrics.headTemperatureC == 31)
    }

    @Test("SGD-Statuswerte mit Platzhalter zählen nicht als Statusquelle", arguments: [
        ["head.latch": "?"],
        ["media.status": ""],
        ["head.latch": "\"?\""],
        ["media.status": "null"],
        ["head.latch": " UNKNOWN ", "media.status": "n/a"],
        ["head.latch": "\"\"", "power.percent_full": "80"],
    ])
    func sgdPlaceholdersAreUnknown(sgd: [String: String]) {
        #expect(!StatusInterpreter.hasSGDStatus(sgd))
        let s = snapshot(nil, nil, sgd: sgd)
        #expect(s.state == .unknown)
        #expect(!s.isReady)
    }

    @Test("Echte SGD-Statuswerte zählen als Statusquelle", arguments: [
        (["head.latch": "ok"], PrinterState.ready),
        (["media.status": "\"ok\""], .ready),
        (["head.latch": "ok", "power.percent_full": "80"], .ready),
        (["head.latch": "open"], .error),
        (["media.status": "out", "head.latch": "?"], .error),
    ])
    func sgdStatusValues(sgd: [String: String], expected: PrinterState) {
        #expect(StatusInterpreter.hasSGDStatus(sgd))
        #expect(snapshot(nil, nil, sgd: sgd).state == expected)
    }
}

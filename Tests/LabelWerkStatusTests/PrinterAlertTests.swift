import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("Meldungen, Schweregrade, Zustände")
struct PrinterAlertTests {

    /// SF-Symbol-Namen, die in SF Symbols 5 (macOS 14) verfügbar sind.
    /// Schützt vor Tippfehlern, die erst zur Laufzeit als leeres Bild auffallen würden.
    static let knownSymbols: Set<String> = [
        "tray", "film", "lock.open.fill", "pause.circle.fill", "scissors", "thermometer.high",
        "flame.fill", "rectangle.dashed", "questionmark.square.dashed", "tray.full.fill",
        "thermometer.snowflake", "thermometer.sun.fill", "memorychip", "ruler", "sparkles",
        "wrench.and.screwdriver.fill", "gauge.with.dots.needle.33percent", "hand.tap.fill",
        "exclamationmark.arrow.circlepath", "viewfinder", "gearshape.fill", "wifi.slash",
        "textformat", "photo", "doc.text", "cpu", "doc",
    ]

    @Test("Jede Meldungsart hat vollständige deutsche Inhalte", arguments: AlertKind.allCases)
    func completeContent(kind: AlertKind) {
        let alert = PrinterAlert.make(kind)
        #expect(alert.kind == kind)
        #expect(alert.id == kind.rawValue)
        #expect(alert.severity == kind.defaultSeverity)
        #expect(alert.title.count >= 8)
        #expect(alert.recovery.count >= 60, "Handlungsanweisung zu knapp: \(alert.recovery)")
        #expect(alert.recovery.hasSuffix("."))
        #expect(Self.knownSymbols.contains(alert.systemImage), "Unbekanntes Symbol \(alert.systemImage)")
        // Deutsche Texte, keine englischen Platzhalter.
        #expect(!alert.title.lowercased().contains("todo"))
        #expect(!alert.recovery.lowercased().contains("please"))
    }

    @Test("Titel und Symbole sind eindeutig")
    func uniqueTitlesAndSymbols() {
        let alerts = AlertKind.allCases.map(PrinterAlert.make)
        #expect(Set(alerts.map(\.title)).count == alerts.count)
        #expect(Set(alerts.map(\.systemImage)).count == alerts.count)
    }

    @Test("Schweregrade", arguments: [
        (AlertKind.mediaOut, AlertSeverity.error), (.ribbonOut, .error), (.headOpen, .error),
        (.paused, .info), (.cutterFault, .error), (.headOverTemperature, .error),
        (.motorOverTemperature, .error), (.badPrintheadElement, .warning), (.printheadDetectionError, .error),
        (.receiveBufferFull, .warning), (.underTemperature, .warning), (.overTemperature, .error),
        (.corruptRAM, .warning), (.needsCalibration, .warning), (.cleanPrinthead, .warning),
        (.replacePrinthead, .warning), (.mediaNearEnd, .warning), (.labelWaitingToBePeeled, .info),
        (.paperFeedError, .error), (.blackMarkNotFound, .error), (.invalidFirmwareConfig, .error),
        (.offline, .error),
    ])
    func severities(kind: AlertKind, severity: AlertSeverity) {
        #expect(PrinterAlert.make(kind).severity == severity)
    }

    @Test("Alle 22 Meldungsarten laut Vertrag")
    func allKinds() {
        #expect(AlertKind.allCases.count == 22)
        #expect(AlertKind(rawValue: "mediaOut") == .mediaOut)
        #expect(AlertKind(rawValue: "offline") == .offline)
    }

    @Test("Schweregrade sind vergleichbar und als Zahl kodiert")
    func severityOrdering() throws {
        #expect(AlertSeverity.info < .warning)
        #expect(AlertSeverity.warning < .error)
        #expect(AlertSeverity.allCases.max() == .error)
        #expect(AlertSeverity.info.rawValue == 0 && AlertSeverity.error.rawValue == 2)
        let encoded = try JSONEncoder().encode([AlertSeverity.error, .info])
        #expect(String(decoding: encoded, as: UTF8.self) == "[2,0]")
    }

    @Test("Sortierung: Fehler zuerst, dann Vertragsreihenfolge")
    func sorting() {
        let unsorted = [AlertKind.labelWaitingToBePeeled, .cleanPrinthead, .paused, .offline, .headOpen, .mediaNearEnd]
            .map(PrinterAlert.make)
        let sorted = PrinterAlert.sorted(unsorted).map(\.kind)
        #expect(sorted == [.headOpen, .offline, .cleanPrinthead, .mediaNearEnd, .paused, .labelWaitingToBePeeled])
    }

    @Test("Eigene Meldungen über den Initialisierer")
    func customAlert() {
        let alert = PrinterAlert(kind: .paused, severity: .warning, title: "Pause", recovery: "Fortsetzen.",
                                 systemImage: "pause.circle.fill")
        #expect(alert.severity == .warning)
        #expect(alert.id == "paused")
        #expect(alert != PrinterAlert.make(.paused))
    }

    @Test("Zustände als Strings kodiert")
    func stateRawValues() {
        #expect(PrinterState.allCases.map(\.rawValue) == ["ready", "printing", "paused", "warning", "error", "offline", "unknown"])
    }
}

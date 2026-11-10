import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("Codable-Round-Trips")
struct CodableTests {

    @Test("HostStatus")
    func hostStatus() throws {
        let parsed = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusAllFlags))
        #expect(try TestSupport.roundTrip(parsed) == parsed)
        let rfid = HostStatus(printMode: nil, printModeCode: "9")
        #expect(try TestSupport.roundTrip(rfid) == rfid)
    }

    @Test("HostQueryStatus und Flags (als Zahl kodiert)")
    func hostQuery() throws {
        let status = HostQueryStatus(errors: [.mediaOut, .paused, PrinterErrorFlags(rawValue: 1 << 40)],
                                     warnings: [.cleanPrinthead, .sensor8])
        #expect(try TestSupport.roundTrip(status) == status)
        let flags = try JSONEncoder().encode(PrinterErrorFlags.headOpen)
        #expect(String(decoding: flags, as: UTF8.self) == "4")
        let warnings = try JSONDecoder().decode(PrinterWarningFlags.self, from: Data("10".utf8))
        #expect(warnings == [.cleanPrinthead, .paperNearEnd])
    }

    @Test("HostIdentification")
    func hostIdentification() throws {
        let id = HostIdentification(model: "ZT410-300dpi", firmware: "V75.19.15Z", dotsPerMM: 12, memoryKB: 8176, options: "C")
        #expect(try TestSupport.roundTrip(id) == id)
    }

    @Test("PrinterAlert aller Arten", arguments: AlertKind.allCases)
    func alert(kind: AlertKind) throws {
        let alert = PrinterAlert.make(kind)
        #expect(try TestSupport.roundTrip(alert) == alert)
    }

    @Test("Vollständige Momentaufnahme")
    func snapshot() throws {
        let hs = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusAllFlags))
        let query = try HostQueryParser.parse(TestSupport.data(Fixtures.hostQueryGuide))
        let snapshot = StatusInterpreter.snapshot(
            hostStatus: hs, query: query,
            sgd: ["odometer.total_print_length": "18,649 CENTIMETERS", "power.percent_full": "42",
                  "odometer.total_label_count": "9001", "head.temperature": "33.5"],
            now: Date(timeIntervalSince1970: 1_800_000_123.5))
        let decoded = try TestSupport.roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.state == .error)
        #expect(decoded.batteryPercent == 42)
        #expect(decoded.labelsPrinted == 9001)
        #expect(decoded.headTemperatureC == 33.5)
        #expect(try TestSupport.roundTrip(PrinterStatusSnapshot.offline) == .offline)
    }

    @Test("Zustände und Schweregrade")
    func enums() throws {
        for state in PrinterState.allCases { #expect(try TestSupport.roundTrip(state) == state) }
        for severity in AlertSeverity.allCases { #expect(try TestSupport.roundTrip(severity) == severity) }
        for kind in FileKind.allCases { #expect(try TestSupport.roundTrip(kind) == kind) }
        let encoded = try JSONEncoder().encode(PrinterState.printing)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"printing\"")
    }

    @Test("SGD, Konfiguration, Dateien")
    func valueTypes() throws {
        let settings = try SGDResponseParser.parseJSON(TestSupport.data(Fixtures.allConfigJSON))
        #expect(try TestSupport.roundTrip(settings) == settings)
        let entries = ConfigurationLabelParser.parse(Fixtures.configurationZD421)
        #expect(try TestSupport.roundTrip(entries) == entries)
        let listing = FileDirectoryParser.parseListing(Fixtures.directorySGD)
        #expect(try TestSupport.roundTrip(listing) == listing)
        let serial = HostStatus(communicationSettings: 126).serialPort
        #expect(try TestSupport.roundTrip(serial) == serial)
    }
}

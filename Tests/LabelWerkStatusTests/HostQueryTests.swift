import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("~HQES – Fehler- und Warnstatus")
struct HostQueryTests {

    @Test("Beispiel aus dem Programming Guide")
    func parsesGuideExample() throws {
        let status = try HostQueryParser.parse(TestSupport.data(Fixtures.hostQueryGuide))
        #expect(status.errors == [.mediaOut, .headOpen])
        #expect(status.errors.rawValue == 0x5)
        #expect(status.warnings == [.cleanPrinthead])
        #expect(status.hasErrors && status.hasWarnings)
    }

    @Test("Keine Fehler, keine Warnungen")
    func parsesCleanStatus() throws {
        let status = try HostQueryParser.parse(TestSupport.data(Fixtures.hostQueryClean))
        #expect(status == HostQueryStatus())
        #expect(!status.hasErrors && !status.hasWarnings)
    }

    @Test("Gruppe 2 (hoch) und Gruppe 1 (niedrig) werden zu 64 Bit kombiniert")
    func combinesGroups() throws {
        let text = "ERRORS: 1 0000000A 00000004\r\nWARNINGS: 1 80000000 00000001\r\n"
        let status = try HostQueryParser.parse(TestSupport.data(text))
        #expect(status.errors.rawValue == 0x0000_000A_0000_0004)
        #expect(status.errors.group2 == 0xA)
        #expect(status.errors.group1 == 0x4)
        #expect(status.errors.contains(.headOpen))
        #expect(status.warnings.rawValue == 0x8000_0000_0000_0001)
        #expect(status.warnings.group2 == 0x8000_0000)
        #expect(status.warnings.contains(.needCalibration))
        #expect(PrinterErrorFlags(group2: 0xA, group1: 0x4) == status.errors)
    }

    @Test("Jedes Fehlerbit", arguments: [
        ("00000001", PrinterErrorFlags.mediaOut),
        ("00000002", .ribbonOut),
        ("00000004", .headOpen),
        ("00000008", .cutterFault),
        ("00000010", .printheadOverTemp),
        ("00000020", .motorOverTemp),
        ("00000040", .badPrintheadElement),
        ("00000080", .printheadDetectionError),
        ("00000100", .invalidFirmwareConfig),
        ("00000200", .printheadThermistorOpen),
        ("00000400", .clearPaperPathFailed),
        ("00000800", .paperFeedError),
        ("00001000", .presenterNotRunning),
        ("00002000", .paperJamDuringRetract),
        ("00004000", .blackMarkNotFound),
        ("00008000", .blackMarkCalibrateError),
        ("00010000", .retractTimeout),
        ("00020000", .paused),
    ])
    func mapsErrorFlag(hex: String, flag: PrinterErrorFlags) throws {
        let text = "\u{02}\r\n  PRINTER STATUS\r\n   ERRORS:         1 00000000 \(hex)\r\n   WARNINGS:       0 00000000 00000000\r\n\u{03}"
        let status = try HostQueryParser.parse(TestSupport.data(text))
        #expect(status.errors == flag)
        #expect(status.warnings.isEmpty)
        #expect(status.errors.displayNames.count == 1)
    }

    @Test("Jedes Warnbit", arguments: [
        ("00000001", PrinterWarningFlags.needCalibration),
        ("00000002", .cleanPrinthead),
        ("00000004", .replacePrinthead),
        ("00000008", .paperNearEnd),
        ("00000010", .sensor1),
        ("00000020", .sensor2),
        ("00000040", .sensor3),
        ("00000080", .sensor4),
        ("00000100", .sensor5),
        ("00000200", .sensor6),
        ("00000400", .sensor7),
        ("00000800", .sensor8),
    ])
    func mapsWarningFlag(hex: String, flag: PrinterWarningFlags) throws {
        let text = "  PRINTER STATUS\r\n   ERRORS:         0 00000000 00000000\r\n   WARNINGS:       1 00000000 \(hex)\r\n"
        let status = try HostQueryParser.parse(TestSupport.data(text))
        #expect(status.warnings == flag)
        #expect(status.errors.isEmpty)
        #expect(status.warnings.displayNames.count == 1)
    }

    @Test("Bitwerte entsprechen der Spezifikation")
    func flagRawValues() {
        #expect(PrinterErrorFlags.known.map(\.flag.rawValue) == [
            0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800,
            0x1000, 0x2000, 0x4000, 0x8000, 0x10000, 0x20000,
        ])
        #expect(PrinterWarningFlags.known.map(\.flag.rawValue) == [
            0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800,
        ])
        #expect(PrinterWarningFlags.sensors.rawValue == 0xFF0)
    }

    @Test("Deutsche Bezeichnungen, unbekannte Bits als Hex")
    func displayNames() {
        let errors: PrinterErrorFlags = [.mediaOut, .ribbonOut, PrinterErrorFlags(rawValue: 0x1_0000_0000)]
        #expect(errors.displayNames == ["Medium leer", "Farbband leer", "Unbekannter Fehler 0x100000000"])
        let warnings: PrinterWarningFlags = [.paperNearEnd, PrinterWarningFlags(rawValue: 0x4000)]
        #expect(warnings.displayNames == ["Medium fast leer", "Unbekannte Warnung 0x4000"])
    }

    @Test("Unbekannte Bits bleiben erhalten")
    func preservesUnknownBits() throws {
        let text = "ERRORS: 1 00000001 80000001\nWARNINGS: 1 00000000 00010000\n"
        let status = try HostQueryParser.parse(TestSupport.data(text))
        #expect(status.errors.rawValue == 0x1_8000_0001)
        #expect(status.errors.contains(.mediaOut))
        #expect(status.warnings.rawValue == 0x10000)
    }

    @Test("Varianten: ohne Rahmung, LF, Kleinschreibung, Tabs, ohne Kennziffer", arguments: [
        "PRINTER STATUS\nERRORS: 1 00000000 00000005\nWARNINGS: 1 00000000 00000002\n",
        "  printer status\r\n  errors:\t1\t00000000\t00000005\r\n  warnings:\t1\t00000000\t00000002",
        "ERRORS: 00000000 00000005\r\nWARNINGS: 00000000 00000002\r\n",
        "\u{02}ERRORS:1 00000000 00000005\u{03}\u{02}WARNINGS:1 00000000 00000002\u{03}",
        "ERRORS: 1 00000005\r\nWARNINGS: 1 00000002\r\n",
        "ERRORS: 1 00000000 00000005 (MEDIA OUT, HEAD OPEN)\r\nWARNINGS: 1 00000000 00000002\r\n",
        "~HQES\r\nPRINTER STATUS\r\n  ERRORS: 1 00000000 00000005\r\n  WARNINGS: 1 00000000 00000002\r\n\0\0",
    ])
    func parsesVariants(text: String) throws {
        let status = try HostQueryParser.parse(TestSupport.data(text))
        #expect(status.errors == [.mediaOut, .headOpen])
        #expect(status.warnings == [.cleanPrinthead])
    }

    @Test("Unbeschriftete Zeilen: erst Fehler, dann Warnungen")
    func parsesUnlabeledLines() throws {
        let status = try HostQueryParser.parse(TestSupport.data(": 1 00000000 00000004\r\n: 1 00000000 00000008\r\n"))
        #expect(status.errors == .headOpen)
        #expect(status.warnings == .paperNearEnd)
    }

    @Test("Fremde Doppelpunktzeilen werden nicht als Flags gedeutet")
    func ignoresForeignColonLines() throws {
        let text = "TOTAL NONRESETTABLE ODOMETER: 1234 INCHES\r\nSERIAL: D2J214500123\r\nTIME: 10:22\r\n"
        #expect(TestSupport.parseError { try HostQueryParser.parse(TestSupport.data(text)) } == .missingSection("ERRORS"))
        let mixed = "ODOMETER: 1234 INCHES\r\n" + Fixtures.hostQueryGuide
        #expect(try HostQueryParser.parse(TestSupport.data(mixed)).errors == [.mediaOut, .headOpen])
    }

    @Test("Abgeschnittene Antwort ohne Warnzeile")
    func toleratesMissingWarnings() throws {
        let text = "\u{02}\r\n  PRINTER STATUS\r\n   ERRORS:         1 00000000 00000001\r\n   WARN"
        let status = try HostQueryParser.parse(TestSupport.data(text))
        #expect(status.errors == .mediaOut)
        #expect(status.warnings.isEmpty)
    }

    @Test("Nur Kennziffer 0 ist ohne Gruppen eindeutig")
    func indicatorOnly() throws {
        let clean = try HostQueryParser.parse(TestSupport.data("ERRORS: 0\r\nWARNINGS: 0\r\n"))
        #expect(clean == HostQueryStatus())
        let error = TestSupport.parseError { try HostQueryParser.parse(TestSupport.data("ERRORS: 1\r\n")) }
        #expect(error == .invalidField(name: "ERRORS", value: "1"))
    }

    @Test("Fehlende ERRORS-Zeile")
    func missingErrorsLine() {
        let error = TestSupport.parseError { try HostQueryParser.parse(TestSupport.data("  PRINTER STATUS\r\n")) }
        #expect(error == .missingSection("ERRORS"))
        let onlyWarnings = TestSupport.parseError {
            try HostQueryParser.parse(TestSupport.data("WARNINGS: 1 00000000 00000002"))
        }
        #expect(onlyWarnings == .missingSection("ERRORS"))
    }

    @Test("Leere Antwort")
    func emptyResponse() {
        #expect(TestSupport.parseError { try HostQueryParser.parse(Data()) } == .emptyResponse)
        #expect(TestSupport.parseError { try HostQueryParser.parse(TestSupport.data("\u{02}\r\n\u{03}")) } == .emptyResponse)
    }

    @Test("Ungültige Hexwerte", arguments: [
        "ERRORS: 1 0000ZZZZ 00000001",
        "ERRORS: 1 000000001 00000001",
        "ERRORS: 1 00000000 00000001 00000002",
        "ERRORS: XYZ",
    ])
    func invalidHex(text: String) {
        let error = TestSupport.parseError { try HostQueryParser.parse(TestSupport.data(text)) }
        if case .invalidField(let name, _) = error {
            #expect(name == "ERRORS")
        } else {
            Issue.record("invalidField erwartet, erhalten: \(String(describing: error))")
        }
    }

    @Test("Antwortformat und Round Trip")
    func responseTextRoundTrip() throws {
        let status = HostQueryStatus(errors: [.mediaOut, .headOpen], warnings: .cleanPrinthead)
        #expect(status.responseText == "\u{02}\r\n  PRINTER STATUS\r\n   ERRORS:         1 00000000 00000005\r\n   WARNINGS:       1 00000000 00000002\r\n\u{03}\r\n")
        #expect(try HostQueryParser.parse(status.responseData) == status)
        let wide = HostQueryStatus(errors: PrinterErrorFlags(rawValue: 0xDEAD_BEEF_0002_0001),
                                   warnings: PrinterWarningFlags(rawValue: 0x1_0000_0FFF))
        #expect(try HostQueryParser.parse(wide.responseData) == wide)
        #expect(HostQueryStatus().responseText.contains("ERRORS:         0 00000000 00000000"))
    }
}

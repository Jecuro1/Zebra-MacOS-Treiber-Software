import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("^HH – Konfiguration")
struct ConfigurationLabelParserTests {

    @Test("ZD421 mit Punktführern")
    func parsesZD421() throws {
        let entries = ConfigurationLabelParser.parse(Fixtures.configurationZD421)
        #expect(entries.count == 31)
        #expect(entries.first == ConfigurationEntry(name: "DARKNESS", value: "+10.0"))
        #expect(entries.value(named: "PRINT SPEED") == "4.0 IPS")
        #expect(entries.value(named: "TEAR OFF ADJUST") == "+000")
        #expect(entries.value(named: "PRINT MODE") == "TEAR OFF")
        #expect(entries.value(named: "MEDIA TYPE") == "GAP/NOTCH")
        #expect(entries.value(named: "PRINT METHOD") == "DIRECT-THERMAL")
        #expect(entries.value(named: "PRINT WIDTH") == "832")
        #expect(entries.value(named: "LABEL LENGTH") == "1218")
        #expect(entries.value(named: "MAXIMUM LENGTH") == "39.0IN   988MM")
        #expect(entries.value(named: "USB COMM.") == "CONNECTED")
        #expect(entries.value(named: "CONTROL CHAR") == "<~>  7EH")
        #expect(entries.value(named: "DELIM./CHAR") == "<,>  2CH")
        #expect(entries.value(named: "MODES DISABLED") == "")
        #expect(entries.value(named: "RESOLUTION") == "832 8/MM FULL")
        #expect(entries.value(named: "FIRMWARE") == "V84.20.18Z")
        #expect(entries.value(named: "XML SCHEMA") == "1.3")
        #expect(entries.value(named: "HARDWARE ID") == "6.5.0 0.814")
        #expect(entries.value(named: "R: RAM") == "4096k")
        #expect(entries.value(named: "E:  ONBOARD FLASH") == "61440k")
        #expect(entries.value(named: "HEAD USAGE") == "1,234 IN")
        #expect(entries.value(named: "SERIAL NUMBER") == "D2J214500123")
        // Kopfzeilen und Fließtext werden nicht als Einträge gedeutet.
        #expect(!entries.contains { $0.name.contains("CONFIGURATION") || $0.name.contains("Zebra") })
        #expect(!entries.contains { $0.name.contains("COPYRIGHTED") })
    }

    @Test("Ältere Firmware ohne Punktführer")
    func parsesLegacyColumns() {
        let entries = ConfigurationLabelParser.parse(Fixtures.configurationLegacy)
        #expect(entries == [
            ConfigurationEntry(name: "DARKNESS", value: "+15.0"),
            ConfigurationEntry(name: "PRINT SPEED", value: "4 IPS"),
            ConfigurationEntry(name: "PRINT MODE", value: "TEAR OFF"),
            ConfigurationEntry(name: "MAXIMUM LENGTH", value: "39.0IN   988MM"),
            ConfigurationEntry(name: "CONTROL CHAR", value: "<~>  7EH"),
            ConfigurationEntry(name: "FIRMWARE", value: "V60.13.0.14Z"),
        ])
    }

    @Test("Tab als Trenner und Punktführer ohne Leerzeichen")
    func separatorsVariants() {
        let entries = ConfigurationLabelParser.parse("+12.0\tDARKNESS\r\n5 IPS.......PRINT SPEED\r\n")
        #expect(entries == [
            ConfigurationEntry(name: "DARKNESS", value: "+12.0"),
            ConfigurationEntry(name: "PRINT SPEED", value: "5 IPS"),
        ])
    }

    @Test("Doppelte Bezeichnungen bleiben in Reihenfolge erhalten")
    func keepsDuplicates() {
        let text = "ENABLED.............  PROTOCOL\nDISABLED............  PROTOCOL\n"
        let entries = ConfigurationLabelParser.parse(text)
        #expect(entries.map(\.value) == ["ENABLED", "DISABLED"])
        #expect(entries.value(named: "protocol") == "ENABLED")
    }

    @Test("Lokalisierte Ausgabe (Großbuchstaben mit Umlauten)")
    func localizedLabels() {
        let entries = ConfigurationLabelParser.parse("+10.0...............  SCHWÄRZUNG\n4.0 IPS             DRUCKGESCHW.\n")
        #expect(entries.value(named: "Schwärzung") == "+10.0")
        #expect(entries.value(named: "DRUCKGESCHW.") == "4.0 IPS")
    }

    @Test("Rohdaten-Variante")
    func parsesData() {
        let entries = ConfigurationLabelParser.parse(data: TestSupport.data(Fixtures.configurationZD421))
        #expect(entries.count == 31)
    }

    @Test("Ohne Konfigurationszeilen: leeres Ergebnis", arguments: [
        "", "\u{02}\u{03}", "Zebra Technologies\nZTC ZD421-203dpi ZPL", "lowercase  text here", "....", "  \r\n  ",
    ])
    func noEntries(text: String) {
        #expect(ConfigurationLabelParser.parse(text).isEmpty)
    }
}

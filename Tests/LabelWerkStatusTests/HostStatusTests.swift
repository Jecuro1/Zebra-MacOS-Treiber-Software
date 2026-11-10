import Foundation
import Testing
import LabelWerkCore
@testable import LabelWerkStatus

@Suite("~HS – Host Status")
struct HostStatusTests {

    @Test("Bereiter Drucker: alle Felder der drei Zeilen")
    func parsesReadyPrinter() throws {
        let status = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusReady))
        // Zeile 1
        #expect(status.communicationSettings == 30)
        #expect(!status.paperOut)
        #expect(!status.paused)
        #expect(status.labelLengthDots == 1245)
        #expect(status.formatsInReceiveBuffer == 0)
        #expect(!status.receiveBufferFull)
        #expect(!status.diagnosticMode)
        #expect(!status.partialFormatInProgress)
        #expect(!status.corruptRAM)
        #expect(!status.underTemperature)
        #expect(!status.overTemperature)
        // Zeile 2
        #expect(status.functionSettings == 1)
        #expect(!status.headOpen)
        #expect(!status.ribbonOut)
        #expect(status.thermalTransferMode)
        #expect(status.printMode == .tearOff)
        #expect(status.printModeCode == "2")
        #expect(status.printWidthMode == 6)
        #expect(!status.labelWaitingToBePeeled)
        #expect(status.labelsRemainingInBatch == 0)
        #expect(status.formatWhileWritingGraphics)
        #expect(status.graphicsStoredInMemory == 0)
        // Zeile 3
        #expect(status.password == "1234")
        #expect(!status.staticRAMInstalled)
        // Abgeleitet
        #expect(status.mediaType == .thermalTransfer)
        #expect(!status.isBusy)
    }

    @Test("Alle Flags gesetzt")
    func parsesAllFlags() throws {
        let status = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusAllFlags))
        #expect(status.paperOut && status.paused && status.receiveBufferFull)
        #expect(status.diagnosticMode && status.partialFormatInProgress)
        #expect(status.corruptRAM && status.underTemperature && status.overTemperature)
        #expect(status.labelLengthDots == 812)
        #expect(status.formatsInReceiveBuffer == 3)
        #expect(status.functionSettings == 129)
        #expect(status.headOpen && status.ribbonOut && status.thermalTransferMode)
        #expect(status.printMode == .peelOff)
        #expect(status.labelWaitingToBePeeled)
        #expect(status.labelsRemainingInBatch == 42)
        #expect(status.graphicsStoredInMemory == 7)
        #expect(status.password == "9876")
        #expect(status.staticRAMInstalled)
        #expect(status.mediaIsContinuous)
        #expect(status.functionSettingsThermalTransfer)
        #expect(!status.sensorProfileActive)
        #expect(!status.communicationsDiagnosticsActive)
        #expect(status.isBusy)
    }

    @Test("Druckt: Restetiketten und Formate im Puffer")
    func parsesPrintingPrinter() throws {
        let status = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusPrinting))
        #expect(status.labelsRemainingInBatch == 5)
        #expect(status.formatsInReceiveBuffer == 2)
        #expect(!status.thermalTransferMode)
        #expect(status.mediaType == .directThermal)
        #expect(status.labelLengthDots == 1218)
    }

    @Test("Mobildrucker: verkürzte zweite Zeile, fehlende dritte Zeile")
    func parsesMobileVariant() throws {
        let status = try HostStatusParser.parse(TestSupport.data(Fixtures.hostStatusMobile))
        #expect(status.labelLengthDots == 400)
        #expect(status.printMode == .peelOff)
        #expect(status.labelWaitingToBePeeled)
        #expect(status.labelsRemainingInBatch == 0)
        #expect(status.graphicsStoredInMemory == 0)
        #expect(status.formatWhileWritingGraphics)
        #expect(status.password == "")
        #expect(!status.staticRAMInstalled)
    }

    @Test("Ohne STX/ETX, nur LF")
    func parsesWithoutFraming() throws {
        let text = "030,1,0,1245,000,0,0,0,000,0,0,0\n001,0,1,0,1,2,6,0,00000000,1,000\n1234,0\n"
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.paperOut)
        #expect(status.headOpen)
        #expect(status.password == "1234")
    }

    @Test("Nur CR als Zeilenende")
    func parsesCarriageReturnOnly() throws {
        let text = "030,0,1,1245,000,0,0,0,000,0,0,0\r001,0,0,0,1,0,6,0,00000000,1,000\r1234,0\r"
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.paused)
        #expect(status.printMode == .rewind)
    }

    @Test("Leerraum um Felder und Zeilen")
    func toleratesWhitespace() throws {
        let text = "  \u{02} 030 , 0 , 1 , 1245 , 000 , 0 , 0 , 0 , 000 , 0 , 0 , 0 \u{03} \r\n"
            + "\t\u{02}001, 0, 0, 0, 1, 3, 6, 0, 00000012, 1, 004\u{03}\r\n"
            + "\u{02} 1234 , 1 \u{03}\r\n"
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.paused)
        #expect(status.printMode == .cutter)
        #expect(status.labelsRemainingInBatch == 12)
        #expect(status.graphicsStoredInMemory == 4)
        #expect(status.password == "1234")
        #expect(status.staticRAMInstalled)
    }

    @Test("Vorangestellte Fremdzeilen (Echo, Restdaten) werden übersprungen")
    func skipsLeadingJunk() throws {
        let text = "~HS\r\nok\r\n\"203\"\r\n" + Fixtures.hostStatusReady
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.labelLengthDots == 1245)
        #expect(status.password == "1234")
    }

    @Test("Abgeschnittene dritte Zeile wird toleriert")
    func toleratesTruncatedThirdLine() throws {
        let text = "\u{02}030,0,0,1245,000,0,0,0,000,0,0,0\u{03}\r\n\u{02}001,0,0,0,1,2,6,0,00000000,1,000\u{03}\r\n\u{02}12"
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.password == "12")
        #expect(!status.staticRAMInstalled)
    }

    @Test("Folgedaten nach der dritten Zeile werden ignoriert")
    func ignoresTrailingData() throws {
        let text = Fixtures.hostStatusReady + "\u{02}ZD421-203dpi,V84.20.18Z,8,8192KB\u{03}garbage"
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.printMode == .tearOff)
        #expect(status.password == "1234")
    }

    @Test("Zusätzliche Felder neuerer Firmware werden ignoriert")
    func ignoresExtraFields() throws {
        let text = Fixtures.framed([
            "030,0,0,1245,000,0,0,0,000,0,0,0,9,9",
            "001,0,0,0,1,2,6,0,00000000,1,000,77",
            "1234,0,5",
        ])
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status == HostStatus(communicationSettings: 30, labelLengthDots: 1245, functionSettings: 1,
                                     thermalTransferMode: true, printMode: .tearOff, printWidthMode: 6))
    }

    @Test("Druckmodus-Codes", arguments: [
        ("0", PrintMode?.some(.rewind)), ("1", .peelOff), ("2", .tearOff), ("3", .cutter),
        ("4", .applicator), ("5", .delayedCut), ("6", .peelOff), ("7", .rewind), ("8", .cutter),
        ("9", nil), ("K", .kiosk), ("k", .kiosk), ("S", nil), ("A", .tearOff), ("X", nil),
    ])
    func mapsPrintModeCodes(code: String, expected: PrintMode?) throws {
        #expect(HostStatus.printMode(forCode: code) == expected)
        let text = Fixtures.framed([
            "030,0,0,1245,000,0,0,0,000,0,0,0",
            "001,0,0,0,1,\(code),6,0,00000000,1,000",
            "1234,0",
        ])
        let status = try HostStatusParser.parse(TestSupport.data(text))
        #expect(status.printMode == expected)
        #expect(status.printModeCode == code.uppercased())
    }

    @Test("Kanonische Codes je PrintMode sind umkehrbar", arguments: PrintMode.allCases)
    func printModeCodeRoundTrip(mode: PrintMode) {
        #expect(HostStatus.printMode(forCode: HostStatus.code(for: mode)) == mode)
    }

    @Test("Deutsche Bezeichnung des gemeldeten Druckmodus")
    func printModeDisplayNames() {
        #expect(HostStatus(printMode: .peelOff, printModeCode: "6").printModeDisplayName == "Linerless – Spenden")
        #expect(HostStatus(printMode: .cutter, printModeCode: "8").printModeDisplayName == "Teilschnitt")
        #expect(HostStatus(printMode: nil, printModeCode: "9").printModeDisplayName == "RFID")
        #expect(HostStatus(printMode: nil, printModeCode: "Q").printModeDisplayName == "Unbekannt (Q)")
        #expect(HostStatus(printMode: nil, printModeCode: "").printModeDisplayName == "Unbekannt")
        #expect(HostStatus(printMode: .tearOff).printModeDisplayName == "Abreißen")
    }

    @Test("Veralteter Rohcode nach Änderung von printMode wird nicht ausgegeben")
    func effectiveCodeFollowsPrintMode() throws {
        var status = HostStatus(printMode: .peelOff, printModeCode: "6")
        #expect(status.effectivePrintModeCode == "6")
        status.printMode = .cutter
        #expect(status.effectivePrintModeCode == "3")
        let reparsed = try HostStatusParser.parse(status.responseData)
        #expect(reparsed.printMode == .cutter)
    }

    @Test("Serielle Schnittstelle aus aaa", arguments: [
        (30, "9600 8N1"),         // 0b0_0001_1110: 8 Datenbits, 1 Stoppbit, 9600
        (31, "19200 8N1"),
        (22, "9600 7N1"),
        (14, "9600 8N2"),
        (126, "9600 8E1"),        // Parität aktiv + gerade
        (62, "9600 8O1"),         // Parität aktiv + ungerade
        (256, "28800 7N2"),       // a8 = 1, Code 1000
        (257, "38400 7N2"),       // Code 1001
        (258, "57600 7N2"),       // Code 1010
        (259, "14400 7N2"),       // Code 1011
        (0, "110 7N2"),
    ])
    func decodesSerialPort(bits: Int, summary: String) {
        #expect(HostStatus(communicationSettings: bits).serialPort.summary == summary)
    }

    @Test("Handshake-Bit a7")
    func decodesHandshake() {
        #expect(HostStatus(communicationSettings: 30).serialPort.handshake == .xonXoff)
        #expect(HostStatus(communicationSettings: 158).serialPort.handshake == .dtr)
    }

    @Test("Funktionsbits mmm")
    func decodesFunctionSettings() {
        let status = HostStatus(functionSettings: 0b1110_0001)
        #expect(status.mediaIsContinuous)
        #expect(status.sensorProfileActive)
        #expect(status.communicationsDiagnosticsActive)
        #expect(status.functionSettingsThermalTransfer)
        #expect(!HostStatus(functionSettings: 0).mediaIsContinuous)
    }

    @Test("Antwortformat entspricht exakt dem Drucker")
    func responseTextFormat() {
        let status = HostStatus(communicationSettings: 30, labelLengthDots: 1245, functionSettings: 1,
                                thermalTransferMode: true, printMode: .tearOff, printWidthMode: 6)
        #expect(status.responseText == Fixtures.hostStatusReady)
    }

    @Test("Round Trip responseText → Parser", arguments: [
        HostStatus(),
        HostStatus(paperOut: true, paused: true, labelLengthDots: 99_999, headOpen: true),
        HostStatus(printMode: nil, printModeCode: "9"),
        HostStatus(printMode: .peelOff, labelWaitingToBePeeled: true, printModeCode: "6"),
        HostStatus(labelsRemainingInBatch: 12_345_678, graphicsStoredInMemory: 123, password: "0000",
                   staticRAMInstalled: true),
        HostStatus(communicationSettings: 291, formatsInReceiveBuffer: 999, receiveBufferFull: true,
                   corruptRAM: true, underTemperature: true, overTemperature: true, functionSettings: 255,
                   ribbonOut: true, thermalTransferMode: true, printMode: .kiosk),
    ])
    func roundTrip(status: HostStatus) throws {
        #expect(try HostStatusParser.parse(status.responseData) == status)
    }

    // MARK: Fehlerfälle

    @Test("Leere Antwort", arguments: ["", "   ", "\u{02}\u{03}\r\n", "\0\0\0"])
    func emptyResponse(text: String) {
        #expect(TestSupport.parseError { try HostStatusParser.parse(TestSupport.data(text)) } == .emptyResponse)
    }

    @Test("Unbekanntes Format")
    func unrecognizedFormat() {
        let error = TestSupport.parseError { try HostStatusParser.parse(TestSupport.data("\u{02}ZD421-203dpi\u{03}")) }
        #expect(error == .unrecognizedFormat("Keine ~HS-Statuszeile gefunden"))
    }

    @Test("Zweite Zeile fehlt oder ist zu kurz", arguments: [
        "\u{02}030,0,0,1245,000,0,0,0,000,0,0,0\u{03}\r\n",
        "\u{02}030,0,0,1245,000,0,0,0,000,0,0,0\u{03}\r\n\u{02}001,0\u{03}",
        "\u{02}030,0,0,1245,000,0,0,0,000,0,0,0\u{03}\r\n\u{02}XYZ,0,0,0\u{03}",
    ])
    func missingSecondLine(text: String) {
        let error = TestSupport.parseError { try HostStatusParser.parse(TestSupport.data(text)) }
        #expect(error == .missingSection("~HS Zeile 2"))
    }

    @Test("Ungültiger Feldinhalt wirft invalidField")
    func invalidField() {
        let text = Fixtures.framed(["030,0,0,12A5,000,0,0,0,000,0,0,0", "001,0,0,0,1,2,6,0,00000000,1,000", "1234,0"])
        let error = TestSupport.parseError { try HostStatusParser.parse(TestSupport.data(text)) }
        #expect(error == .invalidField(name: "Zeile 1: dddd (Etikettenlänge)", value: "12A5"))
    }

    @Test("Überlange Zahl wirft statt überzulaufen")
    func overflowingNumber() {
        let text = Fixtures.framed(["030,0,0,1245,000,0,0,0,000,0,0,0",
                                    "001,0,0,0,1,2,6,0,99999999999999999999999,1,000", "1234,0"])
        let error = TestSupport.parseError { try HostStatusParser.parse(TestSupport.data(text)) }
        if case .invalidField = error {} else { Issue.record("invalidField erwartet, erhalten: \(String(describing: error))") }
    }

    @Test("Fehlermeldungen sind deutsch lokalisiert")
    func errorDescriptions() {
        #expect(StatusParseError.emptyResponse.errorDescription == "Der Drucker hat keine auswertbare Antwort gesendet.")
        #expect(StatusParseError.missingSection("X").errorDescription?.contains("„X“") == true)
        #expect(StatusParseError.invalidField(name: "a", value: "b").localizedDescription.contains("„b“"))
    }
}

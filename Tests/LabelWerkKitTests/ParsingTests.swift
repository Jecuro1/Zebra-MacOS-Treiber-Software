import Foundation
import Testing
@testable import LabelWerkKit

@Suite("Antwortende (ResponseFraming)")
struct ResponseFramingTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test("~HS erst nach drei ETX vollständig")
    func hostStatus() {
        let full = HostStatus().responseText
        #expect(ResponseFraming.hostStatusComplete(data(full)))
        let parts = full.components(separatedBy: "\u{03}")
        #expect(!ResponseFraming.hostStatusComplete(data(parts[0] + "\u{03}" + parts[1])))
    }

    @Test("~HQES nach abgeschlossener WARNINGS-Zeile")
    func hostQuery() {
        let full = HostQueryStatus(errors: [.headOpen], warnings: []).responseText
        #expect(ResponseFraming.hostQueryComplete(data(full)))
        #expect(!ResponseFraming.hostQueryComplete(data("\u{02}\r\n  PRINTER STATUS\r\n   ERRORS:         1 00000000 00000004\r\n")))
        #expect(!ResponseFraming.hostQueryComplete(data("   WARNINGS:       0 0000")))
        #expect(ResponseFraming.hostQueryComplete(data("   WARNINGS:       0 00000000 00000000\r")))
    }

    @Test("getvar mit schließendem Anführungszeichen")
    func quoted() {
        #expect(!ResponseFraming.quotedValueComplete(data("\"ZD4")))
        #expect(ResponseFraming.quotedValueComplete(data("\"ZD421t\"")))
        #expect(ResponseFraming.quotedValueComplete(data("\"?\"")))
    }

    @Test("JSON mit ausgeglichenen Klammern, Klammern in Zeichenketten zählen nicht")
    func json() {
        #expect(!ResponseFraming.jsonComplete(data("{\"a\":\"}")))
        #expect(!ResponseFraming.jsonComplete(data("{}")), "Leeres Echo-Objekt beendet die Antwort nicht")
        #expect(ResponseFraming.jsonComplete(data("{}{\"a\":\"x}\"}")))
        #expect(ResponseFraming.jsonComplete(data("{\"a\":{\"value\":\"1\"},\"b\":\"\\\"}\"}")))
        #expect(!ResponseFraming.jsonComplete(data("{\"a\":{\"value\":\"1\"}")))
    }

    @Test("Dateiliste per SGD")
    func directory() {
        #expect(!ResponseFraming.directoryComplete(data("\"Directory of E:\r\n* E:A.GRF 12\r\n")))
        #expect(ResponseFraming.directoryComplete(data("\"Directory of E:\r\n\r\n  100 bytes free\r\n\"")))
        #expect(ResponseFraming.etxComplete(data("\u{02}x\u{03}")))
    }
}

@Suite("Zerlegung des Datenstroms (VirtualPrinterStream)")
struct VirtualPrinterStreamTests {

    private func feedBytewise(_ text: String, epl: Bool = false) -> [VirtualPrinterStream.Event] {
        var stream = VirtualPrinterStream()
        stream.acceptsEPL = epl
        var events: [VirtualPrinterStream.Event] = []
        for byte in Array(text.utf8) {
            events += stream.feed(Data([byte]))
        }
        return events
    }

    private func feedAll(_ text: String, epl: Bool = false) -> [VirtualPrinterStream.Event] {
        var stream = VirtualPrinterStream()
        stream.acceptsEPL = epl
        return stream.feed(Data(text.utf8))
    }

    @Test("Byteweise und am Stück ergeben dieselben Ereignisse")
    func splitEquivalence() {
        let input = "~HS~HQES~SD08~TA-10\n^XA^FO1,1^FDx^FS^XZ\r\n! U1 setvar \"a.b\" \"c\"\r\n{}{\"a\":null}\n~DGR:X.GRF,2,1,FF00\n~JC"
        let expected: [VirtualPrinterStream.Event] = [
            .tilde(command: "HS", parameters: ""),
            .tilde(command: "HQ", parameters: "ES"),
            .tilde(command: "SD", parameters: "08"),
            .tilde(command: "TA", parameters: "-10"),
            .format(Array("^XA^FO1,1^FDx^FS^XZ".utf8)),
            .sgd("! U1 setvar \"a.b\" \"c\""),
            .json(Array("{\"a\":null}".utf8)),
            .downloadGraphic(path: "R:X.GRF", totalBytes: 2, bytesPerRow: 1, data: "FF00"),
            .tilde(command: "JC", parameters: ""),
        ]
        #expect(feedAll(input) == expected)
        #expect(feedBytewise(input) == expected)
    }

    @Test("Unvollständige Befehle bleiben im Puffer")
    func incomplete() {
        var stream = VirtualPrinterStream()
        #expect(stream.feed(Data("^XA^FO1,1".utf8)).isEmpty)
        #expect(stream.isInsideFormat)
        #expect(stream.feed(Data("^GB10,10,1^FS^X".utf8)).isEmpty)
        let events = stream.feed(Data("Z".utf8))
        #expect(events == [.format(Array("^XA^FO1,1^GB10,10,1^FS^XZ".utf8))])
        #expect(stream.pendingByteCount == 0)
        #expect(stream.feed(Data("~TA01".utf8)).isEmpty, "~TA kann noch eine dritte Ziffer bekommen")
        #expect(stream.feed(Data("0".utf8)) == [.tilde(command: "TA", parameters: "010")])
    }

    @Test("~JX verwirft das laufende Format")
    func cancelPartialFormat() {
        let events = feedAll("^XA^FO1,1^GB5,5,5^FS~JX^XA^FO2,2^GB5,5,5^FS^XZ")
        #expect(events == [.tilde(command: "JX", parameters: ""), .format(Array("^XA^FO2,2^GB5,5,5^FS^XZ".utf8))])
    }

    @Test("~DY binär und hexadezimal")
    func downloadObject() {
        var stream = VirtualPrinterStream()
        var data = Data("~DYE:FONT,B,T,5,,".utf8)
        data.append(Data([0x5E, 0x7E, 0x00, 0x0A, 0xFF]))
        data.append(Data("~HS".utf8))
        let events = stream.feed(data)
        #expect(events == [
            .downloadObject(path: "E:FONT", format: "B", fileExtension: "T", totalBytes: 5, bytesPerRow: 0,
                            data: [0x5E, 0x7E, 0x00, 0x0A, 0xFF]),
            .tilde(command: "HS", parameters: ""),
        ])
        let hex = feedBytewise("~DYR:LOGO,A,G,2,1,\r\nF0\r\n0F~HI")
        #expect(hex == [
            .downloadObject(path: "R:LOGO", format: "A", fileExtension: "G", totalBytes: 2, bytesPerRow: 1, data: [0xF0, 0x0F]),
            .tilde(command: "HI", parameters: ""),
        ])
    }

    @Test("CPCL-Block mit Binärgrafik, EPL-Zeilen nur im Hybridmodus")
    func legacyLanguages() {
        var cpcl = Data("! 0 200 200 40 1\r\nPAGE-WIDTH 16\r\nCG 2 2 0 0 ".utf8)
        cpcl.append(Data([0x0D, 0x0A, 0x50, 0x52]))
        cpcl.append(Data("\r\nPRINT\r\n".utf8))
        var stream = VirtualPrinterStream()
        let events = stream.feed(cpcl)
        #expect(events.count == 1)
        if case .cpcl(let bytes)? = events.first {
            #expect(bytes == Array(cpcl), "Block einschließlich PRINT und Zeilenende")
        } else {
            Issue.record("Kein CPCL-Block")
        }
        #expect(feedAll("N\nq100\nP1\n").isEmpty, "Ohne Hybridmodus wird Text ignoriert")
        let epl = feedBytewise("N\nq100\nP1\n", epl: true)
        #expect(epl == [.epl(Array("N".utf8)), .epl(Array("q100".utf8)), .epl(Array("P1".utf8))])
    }

    @Test("Text zwischen Befehlen wird ignoriert, Präfixe beenden ihn")
    func ignoredText() {
        #expect(feedAll("hallo welt~HS") == [.tilde(command: "HS", parameters: "")])
        #expect(feedAll("^JUS\n~HI") == [.tilde(command: "HI", parameters: "")])
    }
}

@Suite("Bilder einpassen (ImageLayout)")
struct ImageLayoutTests {

    @Test("contain: seitenverhältnistreu, zentriert, weißer Rand")
    func contain() {
        let image = GrayImage(width: 100, height: 50, fill: 0)
        let result = ImageLayout.fit(image, width: 200, height: 200, mode: .contain)
        #expect(result.width == 200 && result.height == 200)
        #expect(result[100, 100] == 0)
        #expect(result[100, 10] == 255)
        #expect(result[100, 60] == 0)
        #expect(ImageLayout.scaledSize(width: 100, height: 50, toFit: 200, 200, mode: .contain) == (200, 100))
    }

    @Test("cover: füllt die Fläche, Überstand wird abgeschnitten")
    func cover() {
        let image = GrayImage(width: 100, height: 50, fill: 0)
        let result = ImageLayout.fit(image, width: 200, height: 200, mode: .cover)
        #expect(result.pixels.allSatisfy { $0 == 0 })
        #expect(ImageLayout.scaledSize(width: 100, height: 50, toFit: 200, 200, mode: .cover) == (400, 200))
    }

    @Test("stretch und none")
    func stretchAndNone() {
        let image = KitTestSupport.gradientImage(width: 30, height: 10)
        let stretched = ImageLayout.fit(image, width: 60, height: 40, mode: .stretch)
        #expect(stretched.width == 60 && stretched.height == 40)
        let original = ImageLayout.fit(image, width: 50, height: 20, mode: .none, alignment: .topLeading)
        #expect(original.cropped(x: 0, y: 0, width: 30, height: 10) == image)
        #expect(original[40, 15] == 255)
    }

    @Test("Drehung fest und automatisch")
    func rotation() {
        let landscape = GrayImage(width: 300, height: 100, fill: 0)
        #expect(ImageLayout.automaticTurn(imageWidth: 300, imageHeight: 100, targetWidth: 400, targetHeight: 600) == .r90)
        #expect(ImageLayout.automaticTurn(imageWidth: 300, imageHeight: 100, targetWidth: 600, targetHeight: 400) == .r0)
        let rotated = ImageLayout.layout(landscape, width: 400, height: 600, mode: .contain, rotation: .automatic)
        #expect(rotated.width == 400 && rotated.height == 600)
        #expect(rotated[200, 300] == 0)
        #expect(rotated[10, 300] == 255, "Gedrehtes Bild: 200 breit, mittig")
        #expect(ImageLayout.Rotation(argument: "auto") == .automatic)
        #expect(ImageLayout.Rotation(argument: "270") == .fixed(.r270))
        #expect(ImageLayout.Rotation(argument: "45") == nil)
    }

    @Test("Etikettengröße mit Begrenzung auf die Kopfbreite")
    func labelSize() throws {
        let stock = try #require(ModelCatalog.shared.stock(id: "w4h6in"))
        let size = ImageLayout.labelSize(for: stock, resolution: .dpi203, maxPrintWidthDots: 800)
        #expect(size.width == 800)
        #expect(size.height == stock.heightDots(.dpi203))
        let laid = ImageLayout.layout(GrayImage(width: 10, height: 10), for: stock, resolution: .dpi203)
        #expect(laid.width == stock.widthDots(.dpi203))
    }
}

@Suite("Hilfsfunktionen des PrinterClient")
struct PrinterClientHelperTests {

    @Test("Objektnamen und Laufwerke")
    func names() throws {
        #expect(PrinterClient.objectName("Arial Narrow.ttf") == "ARIAL_NARROW")
        #expect(PrinterClient.objectName("E:logo.grf") == "LOGO")
        #expect(PrinterClient.objectName("/tmp/Firmen-Logo_2.png") == "FIRMEN-LOGO_2")
        #expect(PrinterClient.objectName("abcdefghijklmnopqrstuvwxyz") == "ABCDEFGHIJKLMNOP")
        #expect(try PrinterClient.normalizedDrive("e", allowWildcard: false) == "E:")
        #expect(try PrinterClient.normalizedDrive("R:", allowWildcard: false) == "R:")
        #expect(try PrinterClient.normalizedDrive("*", allowWildcard: true) == "*:")
        #expect(throws: PrinterClientError.self) { try PrinterClient.normalizedDrive("*", allowWildcard: false) }
        #expect(throws: PrinterClientError.self) { try PrinterClient.normalizedDrive("1:", allowWildcard: false) }
    }

    @Test("Schriftsignaturen")
    func fonts() {
        #expect(throws: Never.self) { try PrinterClient.validateFont(Data("OTTO".utf8) + Data(count: 20)) }
        #expect(throws: Never.self) { try PrinterClient.validateFont(Data([0, 1, 0, 0]) + Data(count: 20)) }
        #expect(throws: PrinterClientError.self) { try PrinterClient.validateFont(Data("PK\u{03}\u{04}".utf8) + Data(count: 20)) }
        #expect(throws: PrinterClientError.self) { try PrinterClient.validateFont(Data([0, 1, 0, 0])) }
    }

    @Test("Netzwerkänderungen: nur Abweichungen, DHCP-Modi bleiben")
    func networkChanges() {
        let configured = ["ip.ip_protocol": "all", "ip.addr": "192.168.1.5", "wlan.enable": "off"]
        var target = NetworkSettings(useDHCP: true, ipAddress: "192.168.1.5")
        #expect(PrinterClient.networkChanges(target, configured: configured).isEmpty)
        target.wlanEnabled = true
        #expect(PrinterClient.networkChanges(target, configured: configured).map(\.name) == ["wlan.enable"])
        target.useDHCP = false
        target.subnetMask = "255.255.255.0"
        target.gateway = "192.168.1.1"
        let names = PrinterClient.networkChanges(target, configured: configured).map(\.name)
        #expect(names == ["ip.ip_protocol", "ip.addr", "ip.netmask", "ip.gateway", "wlan.enable"])
        #expect(NetworkSettings.isValidIPv4("10.0.0.255"))
        #expect(!NetworkSettings.isValidIPv4("10.0.0"))
        #expect(!NetworkSettings.isValidIPv4("10.0.0.256"))
    }

    @Test("Fehlertexte sind deutsch und vollständig")
    func errorTexts() {
        let errors: [PrinterClientError] = [
            .notBidirectional("Status"), .noResponse("Status"), .invalidResponse("~HS", "x"),
            .unsupportedAction(.pause, .cpcl), .unsupportedOperation("x"), .emptyJob, .invalidArgument("x"),
            .invalidFont("x"), .invalidNetworkSettings("x"), .encodingFailed("x"), .transport(.timeout),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
        #expect(PrinterClientError.unsupportedAction(.pause, .cpcl).errorDescription == "„Pausieren“ ist in CPCL nicht verfügbar.")
    }

    @Test("EPL-Konfiguration (UQ) wird in Einträge zerlegt")
    func eplConfiguration() {
        let entries = PrinterClient.parseEPLConfiguration("UKQ1935HLU  V4.70.1A\r\nS/N: 42A00000\r\nq600 Q208,25\r\n")
        #expect(entries.first == ConfigurationEntry(name: "MODELL", value: "UKQ1935HLU  V4.70.1A"))
        #expect(entries.value(named: "S/N") == "42A00000")
        #expect(entries.count == 3)
    }
}

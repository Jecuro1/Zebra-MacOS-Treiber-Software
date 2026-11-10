import Foundation
import Testing
@testable import LabelWerkKit

@Suite("PrinterClient mit virtuellem Drucker")
struct PrinterClientTests {

    // MARK: - Status

    @Test("Status eines bereiten Druckers enthält SGD-Kennzahlen")
    func readyStatus() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let snapshot = try await client.status()
        #expect(snapshot.state == .ready)
        #expect(snapshot.alerts.isEmpty)
        #expect(snapshot.hostStatus != nil)
        #expect(snapshot.queryStatus != nil)
        #expect(snapshot.labelsPrinted == (await printer.labelsPrinted))
        #expect((snapshot.odometerMeters ?? 0) > 0)
        #expect(snapshot.headTemperatureC != nil)
        #expect(snapshot.batteryPercent == nil, "Der ZD421 hat keinen Akku")
    }

    @Test("Status in allen simulierten Fehlerzuständen", arguments: [
        ("paused", AlertKind.paused, PrinterState.paused),
        ("headOpen", AlertKind.headOpen, PrinterState.error),
        ("mediaOut", AlertKind.mediaOut, PrinterState.error),
        ("ribbonOut", AlertKind.ribbonOut, PrinterState.error),
    ])
    func toggledStates(name: String, kind: AlertKind, state: PrinterState) async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        switch name {
        case "paused": await printer.setPaused(true)
        case "headOpen": await printer.setHeadOpen(true)
        case "mediaOut": await printer.setMediaOut(true)
        default: await printer.setRibbonOut(true)
        }
        let snapshot = try await client.status()
        #expect(snapshot.state == state)
        #expect(snapshot.hasAlert(kind), "Meldung \(kind) fehlt: \(snapshot.alerts.map(\.kind))")
        switch name {
        case "paused": await printer.setPaused(false)
        case "headOpen": await printer.setHeadOpen(false)
        case "mediaOut": await printer.setMediaOut(false)
        default: await printer.setRibbonOut(false)
        }
        let recovered = try await client.status()
        #expect(!recovered.hasAlert(kind))
    }

    @Test("Mehrere Fehler gleichzeitig und Warnungen")
    func combinedAlerts() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        await printer.setHeadOpen(true)
        await printer.setMediaOut(true)
        await printer.setWarnings([.cleanPrinthead])
        let snapshot = try await client.status()
        #expect(snapshot.state == .error)
        #expect(snapshot.hasAlert(.headOpen))
        #expect(snapshot.hasAlert(.mediaOut))
        #expect(snapshot.hasAlert(.cleanPrinthead))
        #expect(snapshot.hasAlert(.needsCalibration))
        #expect(snapshot.alerts.first?.severity == .error, "Meldungen nach Schwere sortiert")
    }

    @Test("Farbband leer im Thermodirekt-Modus ist kein Fehler")
    func ribbonOutDirectThermal() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.send("^XA^MTD^XZ")
        await printer.setRibbonOut(true)
        let snapshot = try await client.status()
        #expect(snapshot.state == .ready)
        #expect(!snapshot.hasAlert(.ribbonOut))
    }

    @Test("Antworten in kleinen Stücken werden vollständig zusammengesetzt")
    func fragmentedResponses() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setMaximumReadChunk(5)
        let client = await KitTestSupport.makeClient(printer)
        await printer.setPaused(true)
        let snapshot = try await client.status()
        #expect(snapshot.state == .paused)
        #expect(snapshot.hostStatus?.paused == true)
        #expect(try await client.getvar("device.product_name") == "ZD421t")
        let values = try await client.getvars(["head.resolution.in_dpi", "device.unique_id"])
        #expect(values["head.resolution.in_dpi"] == "203")
    }

    @Test("Verbindungen ohne Rückkanal liefern den Zustand „unbekannt“")
    func unidirectional() async throws {
        let client = PrinterClient(connection: CUPSQueueConnection(queue: "LabelWerk_Test"))
        let snapshot = try await client.status()
        #expect(snapshot.state == .unknown)
        await #expect(throws: PrinterClientError.notBidirectional("Drucker identifizieren")) {
            try await client.identify()
        }
    }

    @Test("Keine Antwort führt zu noResponse")
    func silentPrinter() async throws {
        let silent = SilentConnection()
        let client = await KitTestSupport.makeClient(silent)
        await #expect(throws: PrinterClientError.noResponse("Statusabfrage")) { try await client.status() }
    }

    // MARK: - Identität

    @Test("identify() erkennt den ZD421t aus dem Katalog")
    func identify() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let identity = try await client.identify()
        #expect(identity.matchedModelID == "zd421t")
        #expect(identity.model == "ZD421t")
        #expect(identity.serialNumber == printer.serialNumber)
        #expect(identity.firmware?.hasPrefix("V84") == true)
        #expect(identity.resolution == .dpi203)
        #expect(identity.printWidthDots == KitTestSupport.zd421t.printWidthDots(.dpi203))
        #expect(identity.memoryKB == 8192)
        #expect(identity.languages.contains(.zpl))
        #expect(identity.languages.contains(.epl))
        #expect(identity.isLinkOS)
        #expect(identity.ipAddress?.hasPrefix("192.168.1.") == true)
        #expect(identity.macAddress?.hasPrefix("00:07:4d") == true)
        #expect(await client.lastIdentity == identity)
    }

    @Test("Variantenzuordnung d/t anhand des Druckverfahrens")
    func variantMatching() {
        #expect(PrinterClient.matchModel(candidates: ["ZD421-203dpi"], printMethod: "thermal trans")?.id == "zd421t")
        #expect(PrinterClient.matchModel(candidates: ["ZD421-203dpi"], printMethod: "direct thermal")?.id == "zd421d")
        #expect(PrinterClient.matchModel(candidates: ["ZD421t"], printMethod: "direct thermal")?.id == "zd421t")
        #expect(PrinterClient.matchModel(candidates: ["ZT410-300dpi"], printMethod: nil)?.id == "zt410")
        #expect(PrinterClient.matchModel(candidates: ["Unbekannt 9000"], printMethod: nil) == nil)
    }

    @Test("Sprachen aus device.languages")
    func languages() {
        #expect(PrinterClient.parseLanguages("epl_zpl") == [.zpl, .epl])
        #expect(PrinterClient.parseLanguages("hybrid_xml_zpl") == [.zpl])
        #expect(PrinterClient.parseLanguages("line_print") == [.cpcl])
        #expect(PrinterClient.parseLanguages(nil).isEmpty)
    }

    // MARK: - SGD

    @Test("getvars nutzt JSON bei Link-OS")
    func getvarsJSON() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        _ = try await client.getvar("appl.name")
        await printer.clearHistory()
        let values = try await client.getvars(["device.product_name", "head.resolution.in_dpi", "nicht.vorhanden", "ip"])
        #expect(values["device.product_name"] == "ZD421t")
        #expect(values["head.resolution.in_dpi"] == "203")
        #expect(values["nicht.vorhanden"] == nil)
        #expect(values["ip.port"] == "9100", "Zweig „ip“ liefert alle ip.*-Variablen")
        let sent = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(sent.hasPrefix("{}{"))
        #expect(!sent.contains("getvar"))
    }

    @Test("getvars fällt ohne JSON auf einzelne getvar zurück")
    func getvarsFallback() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setSupportsJSON(false)
        let client = await KitTestSupport.makeClient(printer)
        let values = try await client.getvars(["device.product_name", "head.resolution.in_dpi", "nicht.vorhanden"])
        #expect(values == ["device.product_name": "ZD421t", "head.resolution.in_dpi": "203"])
        let sent = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(sent.contains("! U1 getvar \"head.resolution.in_dpi\""))
        // Die Fähigkeit wird zwischengespeichert: keine weitere JSON-Probe.
        await printer.clearHistory()
        _ = try await client.getvars(["device.unique_id"])
        let again = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(!again.contains("{}{"))
        // Ohne JSON liefert allSettings die allcv-Liste.
        let settings = try await client.allSettings()
        #expect(settings.count >= 60)
        #expect(settings["media.printmode"]?.range?.contains("tear off") == true)
    }

    @Test("setvar, getvar, doCommand und Werte mit Anführungszeichen")
    func setGetDo() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.setvar("device.friendly_name", "Versand")
        #expect(try await client.getvar("device.friendly_name") == "Versand")
        #expect(try await client.getvar("gibt.es.nicht") == nil)
        try await client.setvar("device.location", "Halle \"B\"")
        #expect(await printer.sgdValue("device.location") == "Halle \"B\"")
        let listing = try await client.doCommand("file.dir", "E:")
        #expect(listing?.contains("bytes free") == true)
        await #expect(throws: PrinterClientError.invalidArgument("Der Name der SGD-Variablen ist leer.")) {
            try await client.getvar("  ")
        }
    }

    @Test("allSettings liefert allconfig mit Deskriptoren")
    func allSettings() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let settings = try await client.allSettings()
        #expect(settings.count >= 60)
        #expect(settings["ip.addr"]?.type == "ipv4-address")
        #expect(settings["device.product_name"]?.isWritable == false)
        #expect(settings["print.tone"]?.numericRange == 0...30)
    }

    @Test("configuration() wertet ^HH aus")
    func configuration() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let entries = try await client.configuration()
        #expect(entries.value(named: "DARKNESS") == "+15.0")
        #expect(entries.value(named: "SERIAL NUMBER") == printer.serialNumber)
        #expect(entries.count > 20)
    }

    // MARK: - Drucken

    @Test("printImages: Das gerenderte Etikett enthält genau die gerasterte Grafik", arguments: [
        GraphicCompression.z64, .acs, .hex,
    ])
    func printImages(compression: GraphicCompression) async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let image = KitTestSupport.gradientImage(width: 96, height: 64)
        let settings = PrintSettings(dither: .floydSteinberg, compression: compression)
        try await client.printImages([image], settings: settings, resolution: .dpi203, stock: nil, copies: 3)
        let labels = await printer.renderedLabels
        #expect(labels.count == 1)
        let label = try #require(labels.first)
        #expect(label.quantity == 3)
        #expect(label.widthDots == 96)
        #expect(label.heightDots == 64)
        #expect(label.elements.count == 1)
        guard case .graphic(let graphic) = try #require(label.elements.first) else {
            Issue.record("Kein Grafikelement")
            return
        }
        let expected = Ditherer.dither(image, algorithm: .floydSteinberg, threshold: 128)
        #expect(graphic.bitmap == expected)
        #expect(graphic.origin == LabelPoint(x: 0, y: 0))
        #expect(label.warnings.isEmpty, "Warnungen: \(label.warnings)")
    }

    @Test("printImages mit nicht durch 8 teilbarer Breite und mehreren Seiten")
    func printImagesPaddedWidth() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let first = KitTestSupport.gradientImage(width: 61, height: 20)
        let second = GrayImage(width: 61, height: 20, fill: 0)
        try await client.printImages([first, second], settings: .default, resolution: .dpi203, stock: nil, copies: 2)
        let labels = await printer.renderedLabels
        #expect(labels.count == 4, "Sortiert: Seitenfolge zweimal")
        guard case .graphic(let graphic)? = labels.first?.elements.first else {
            Issue.record("Kein Grafikelement")
            return
        }
        let expected = Ditherer.dither(first, algorithm: .threshold, threshold: 128)
        #expect(graphic.bitmap.width == 64)
        #expect(graphic.bitmap.cropped(x: 0, y: 0, width: 61, height: 20) == expected)
        #expect(graphic.bitmap.cropped(x: 61, y: 0, width: 3, height: 20).isBlank)
    }

    @Test("EPL-Auftrag wird im Hybridmodus epl_zpl als Grafik gedruckt")
    func printImagesEPL() async throws {
        let printer = try await KitTestSupport.makePrinter()
        #expect(await printer.sgdValue("device.languages") == "epl_zpl")
        let client = await KitTestSupport.makeClient(printer, language: .epl)
        let image = KitTestSupport.gradientImage(width: 64, height: 40)
        let settings = PrintSettings(darkness: 20, mediaType: .directThermal, printMode: .cutter, dither: .ordered)
        try await client.printImages([image], settings: settings, resolution: .dpi203, stock: nil, copies: 2)
        let label = try #require(await printer.renderedLabels.last)
        #expect(label.quantity == 2)
        #expect(label.widthDots == 64 && label.heightDots == 40)
        guard case .graphic(let graphic)? = label.elements.first else {
            Issue.record("Keine EPL-Grafik")
            return
        }
        #expect(graphic.bitmap == Ditherer.dither(image, algorithm: .ordered))
        #expect(await printer.sgdValue("ezpl.print_method") == "direct thermal")
        #expect(await printer.sgdValue("media.printmode") == "cutter")
        #expect(await printer.sgdValue("print.tone") == "20.0")
    }

    @Test("CPCL-Auftrag und SGD-Status auf einem Mobildrucker (ZQ520)")
    func mobilePrinterCPCL() async throws {
        let model = try #require(ModelCatalog.shared.model(id: "zq520"))
        let printer = try await KitTestSupport.makePrinter(model: model)
        let client = await KitTestSupport.makeClient(printer, language: .cpcl)
        let image = KitTestSupport.gradientImage(width: 80, height: 30)
        try await client.printImages([image], settings: PrintSettings(dither: .halftone), resolution: .dpi203, stock: nil)
        let label = try #require(await printer.renderedLabels.last)
        #expect(label.widthDots == 80)
        guard case .graphic(let graphic)? = label.elements.first else {
            Issue.record("Keine CPCL-Grafik")
            return
        }
        #expect(graphic.bitmap == Ditherer.dither(image, algorithm: .halftone))

        // Im CPCL-Modus kommt der Status nur über SGD (kein ~HS).
        await printer.clearHistory()
        await printer.setHeadOpen(true)
        let snapshot = try await client.status()
        #expect(snapshot.hostStatus == nil)
        #expect(snapshot.state == .error)
        #expect(snapshot.hasAlert(.headOpen))
        #expect(snapshot.batteryPercent == 87)
        let sent = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(!sent.contains("~HS"))
        let identity = try await client.identify()
        #expect(identity.matchedModelID == "zq520")
        #expect(identity.languages.contains(.cpcl))
    }

    @Test("printImages prüft Eingaben")
    func printImagesValidation() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        await #expect(throws: PrinterClientError.emptyJob) {
            try await client.printImages([], settings: .default, resolution: .dpi203, stock: nil)
        }
        await #expect(throws: PrinterClientError.self) {
            try await client.printImages([GrayImage(width: 0, height: 5)], settings: .default, resolution: .dpi203, stock: nil)
        }
    }

    @Test("printZPL und perform(.printTestLabel) erzeugen Etiketten")
    func printZPLAndTestLabel() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.printZPL("^XA^FO50,50^A0N,40^FDHallo Welt^FS^XZ")
        guard case .text(let text)? = await printer.renderedLabels.last?.elements.first else {
            Issue.record("Kein Text")
            return
        }
        #expect(text.text == "Hallo Welt")
        try await client.perform(.printTestLabel, resolution: .dpi203, widthDots: 812, heightDots: 1218)
        let testLabel = try #require(await printer.renderedLabels.last)
        #expect(testLabel.elements.count > 5)
        await #expect(throws: PrinterClientError.invalidArgument("Der ZPL-Code ist leer.")) {
            try await client.printZPL("  \n")
        }
    }

    @Test("perform: Pause, Fortsetzen, Kalibrieren; nicht unterstützte Aktionen")
    func performActions() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.perform(.pause)
        #expect(try await client.status().state == .paused)
        try await client.perform(.resume)
        #expect(try await client.status().state == .ready)
        let before = await printer.labelsPrinted
        try await client.perform(.feedLabel)
        #expect(await printer.labelsPrinted == before + 1)
        await client.setLanguage(.cpcl)
        await #expect(throws: PrinterClientError.unsupportedAction(.pause, .cpcl)) { try await client.perform(.pause) }
    }

    // MARK: - Einstellungen

    @Test("applySettings überträgt alle Werte und ist idempotent")
    func applySettings() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let settings = PrintSettings(darkness: 22, speed: 5, mediaType: .directThermal, tracking: .blackMark,
                                     printMode: .peelOff, labelTop: 12, labelLeft: -16, tearOffAdjust: 10,
                                     backfeed: .beforePrinting)
        try await client.applySettings(settings, permanently: true)
        let expected: [String: String] = [
            "print.tone": "22.0", "media.speed": "5.0", "ezpl.print_method": "direct thermal",
            "ezpl.media_type": "mark", "media.printmode": "peel off", "zpl.label_top": "12",
            "zpl.left_position": "-16", "ezpl.tear_off": "10",
        ]
        for (name, value) in expected {
            #expect(await printer.sgdValue(name) == value, "\(name)")
        }
        let first = await printer.sgdValues
        try await client.applySettings(settings, permanently: true)
        let second = await printer.sgdValues
        let ignored: Set<String> = ["rtc.time", "rtc.date", "device.uptime"]
        #expect(first.filter { !ignored.contains($0.key) } == second.filter { !ignored.contains($0.key) })
        let sent = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(sent.contains("~SD22\n~TA010\n~JSB\n^XA\n^MTD\n^MNM\n^MMP\n^PR5,5,5\n^LT12\n^LS-16\n^JUS\n^XZ\n"))
        #expect(await printer.renderedLabels.isEmpty, "Einstellungen drucken nichts")
        // Rückzug über den Steuerbefehl ~JS – ^JS wäre die Sensorwahl.
        #expect(!sent.contains("^JS"))
        #expect(await printer.backfeed == .beforePrinting)
        #expect(try await client.configuration().value(named: "BACKFEED") == "BEFORE")
    }

    @Test("Rückzug: ~JS{A|B|N|O} als Steuerbefehl vor dem Format, nie ^JS", arguments: BackfeedMode.allCases)
    func backfeedUsesControlCommand(_ mode: BackfeedMode) async throws {
        let payload = String(decoding: PrinterClient.settingsPayload(PrintSettings(backfeed: mode), permanently: false,
                                                                     language: .zpl), as: UTF8.self)
        #expect(payload == "~JS\(mode.zplCode)\n", "Ohne Formatbefehle entsteht kein leeres ^XA…^XZ")
        let saved = String(decoding: PrinterClient.settingsPayload(PrintSettings(backfeed: mode), permanently: true,
                                                                   language: .zpl), as: UTF8.self)
        #expect(saved == "~JS\(mode.zplCode)\n^XA\n^JUS\n^XZ\n")

        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await client.applySettings(PrintSettings(backfeed: mode), permanently: false)
        #expect(await printer.backfeed == mode)
    }

    @Test("applySettings ohne Werte sendet nichts; EPL- und CPCL-Befehle")
    func applySettingsLanguages() async throws {
        #expect(PrinterClient.settingsPayload(.default, permanently: false, language: .zpl).isEmpty)
        #expect(String(decoding: PrinterClient.settingsPayload(.default, permanently: true, language: .zpl), as: UTF8.self)
            == "^XA\n^JUS\n^XZ\n")
        let settings = PrintSettings(darkness: 20, speed: 4, mediaType: .directThermal, printMode: .cutter, labelLeft: 8)
        #expect(String(decoding: PrinterClient.settingsPayload(settings, permanently: true, language: .epl), as: UTF8.self)
            == "\nS4\nD10\nOD,C\nR8,0\n")
        let cpcl = String(decoding: PrinterClient.settingsPayload(settings, permanently: false, language: .cpcl), as: UTF8.self)
        #expect(cpcl.contains("! U1 setvar \"print.tone\" \"20\"\r\n"))
        #expect(cpcl.contains("! U1 setvar \"media.printmode\" \"C\"\r\n"), "dokumentierter Setzwert")

        // CPCL-Werte kommen per SGD im virtuellen Drucker an.
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer, language: .cpcl)
        try await client.applySettings(settings, permanently: false)
        #expect(await printer.sgdValue("print.tone") == "20.0")
        #expect(await printer.sgdValue("media.printmode") == "cutter")
        #expect(await printer.sgdValue("zpl.left_position") == "8")
    }

    // MARK: - Dateien

    @Test("uploadFont → listFiles → deleteFile")
    func fontRoundTrip() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        var font = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x80, 0x00, 0x03, 0x00, 0x20])
        font.append(Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try await client.uploadFont(name: "Arial Narrow.ttf", data: font, drive: "E:")
        var files = try await client.listFiles(drive: "E:")
        #expect(files.map(\.id) == ["E:ARIAL_NARROW.TTF"])
        #expect(files.first?.size == font.count)
        #expect(files.first?.kind == .font)
        #expect(await printer.fileData("E:ARIAL_NARROW.TTF") == font)
        try await client.deleteFile("E:ARIAL_NARROW.TTF")
        files = try await client.listFiles(drive: "E:")
        #expect(files.isEmpty)
        await #expect(throws: PrinterClientError.self) {
            try await client.uploadFont(name: "kaputt", data: Data("keine schrift".utf8))
        }
    }

    @Test("uploadGraphic, Abruf per ^XG und Dateiliste über SGD-Fallback")
    func graphicRoundTrip() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let bitmap = Ditherer.dither(KitTestSupport.gradientImage(width: 40, height: 24), algorithm: .ordered)
        try await client.uploadGraphic(name: "logo", bitmap: bitmap, drive: "R:")
        #expect(try await client.listFiles(drive: "R:").map(\.id) == ["R:LOGO.GRF"])
        #expect(try await client.listFiles(drive: "*").map(\.id) == ["R:LOGO.GRF"])
        try await client.printZPL("^XA^FO5,5^XGR:LOGO.GRF,1,1^FS^XZ")
        guard case .graphic(let graphic)? = await printer.renderedLabels.last?.elements.first else {
            Issue.record("Gespeicherte Grafik wurde nicht abgerufen")
            return
        }
        #expect(graphic.bitmap.cropped(x: 0, y: 0, width: 40, height: 24) == bitmap)
        await #expect(throws: PrinterClientError.self) { try await client.listFiles(drive: "EE") }

        // CPCL: Dateiliste über SGD file.dir
        await client.setLanguage(.cpcl)
        #expect(try await client.listFiles(drive: "R:").map(\.id) == ["R:LOGO.GRF"])
        try await client.deleteFile("R:LOGO.GRF")
        #expect(await printer.files.isEmpty)
    }

    // MARK: - Firmware

    @Test("Firmware wird in Blöcken übertragen, Fortschritt erreicht 1,0")
    func firmwareProgress() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let firmware = Data(repeating: 0x55, count: 100_000)
        let recorder = Recorder<Double>()
        try await client.sendFirmware(firmware, chunkSize: 16_384) { recorder.append($0) }
        let values = recorder.values
        #expect(values.first == 0)
        #expect(values.last == 1.0)
        #expect(values == values.sorted(), "Fortschritt steigt monoton")
        #expect(values.count == 1 + 7, "Startwert und sieben Blöcke")
        #expect(await printer.receivedData.count == firmware.count)
        await #expect(throws: PrinterClientError.self) { try await client.sendFirmware(Data()) { _ in } }
    }

    @Test("Firmware-Übertragung lässt sich abbrechen")
    func firmwareCancellation() async throws {
        let connection = SlowConnection()
        let client = PrinterClient(connection: connection)
        let recorder = Recorder<Double>()
        let task = Task {
            try await client.sendFirmware(Data(repeating: 1, count: 1_000_000), chunkSize: 1_000) { recorder.append($0) }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect((recorder.values.last ?? 1) < 1.0)
    }

    // MARK: - Terminal

    @Test("terminal() sendet unverändert und sammelt die Antwort")
    func terminal() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        let response = try await client.terminal("~HI", timeout: .seconds(1))
        #expect(String(decoding: response, as: UTF8.self).contains("ZD421-203dpi"))
        await printer.clearHistory()
        _ = try await client.terminal("~HS\\r\\n", timeout: .milliseconds(300))
        #expect(await printer.receivedData == Data("~HS\\r\\n".utf8), "Maskierungen werden nicht umgewandelt")
        let empty = try await client.terminal("", timeout: .milliseconds(100))
        #expect(empty.isEmpty)
    }

    // MARK: - Netzwerk

    @Test("Netzwerkeinstellungen lesen, ändern und nach Neustart übernehmen")
    func networkSettings() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        var settings = try await client.networkSettings()
        #expect(settings.useDHCP)
        #expect(settings.ipAddress.hasPrefix("192.168.1."))
        #expect(settings.wlanEnabled == false)
        #expect(settings.macAddress?.hasPrefix("00:07:4d") == true)

        settings.useDHCP = false
        settings.ipAddress = "10.0.0.50"
        settings.subnetMask = "255.255.0.0"
        settings.gateway = "10.0.0.1"
        settings.wlanEnabled = true
        settings.wlanSSID = "Lager"
        settings.wlanSecurity = "wpa2 psk"
        settings.wlanPassphrase = "geheim123"
        settings.hostname = "lager-zd421"
        try await client.applyNetworkSettings(settings)
        #expect(await printer.sgdValue("ip.ip_protocol") == "permanent")
        #expect(await printer.sgdValue("interface.network.active.ip_addr") == "10.0.0.50", "nach device.reset aktiv")
        #expect(await printer.sgdValue("wlan.essid") == "Lager")
        #expect(await printer.sgdValue("wlan.wpa.psk") == "geheim123")
        #expect(await printer.sgdValue("ip.dhcp.option12_value") == "lager-zd421")
        let reread = try await client.networkSettings()
        #expect(!reread.useDHCP)
        #expect(reread.ipAddress == "10.0.0.50")
        #expect(reread.wlanPassphrase == nil, "Passphrase wird nie gelesen")

        // Unveränderte Einstellungen: kein Schreiben, kein Neustart.
        await printer.clearHistory()
        var unchanged = reread
        unchanged.wlanPassphrase = nil
        try await client.applyNetworkSettings(unchanged)
        let sent = String(decoding: await printer.receivedData, as: UTF8.self)
        #expect(!sent.contains("setvar"))
        #expect(!sent.contains("device.reset"))

        var invalid = reread
        invalid.ipAddress = "300.1.1.1"
        await #expect(throws: PrinterClientError.self) { try await client.applyNetworkSettings(invalid) }
    }

    // MARK: - Nebenläufigkeit

    @Test("Gleichzeitige Aufrufe vermischen keine Antworten")
    func concurrentRequests() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                group.addTask {
                    switch index % 3 {
                    case 0: return try await client.status().state == .ready
                    case 1: return try await client.getvar("device.product_name") == "ZD421t"
                    default: return try await client.identify().matchedModelID == "zd421t"
                    }
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }
}

// MARK: - Testverbindungen

/// Verbindung, die nie antwortet.
actor SilentConnection: PrinterConnection {
    nonisolated let descriptor = ConnectionDescriptor.tcp(host: "192.0.2.1", port: 9100)
    private var opened = false
    var isOpen: Bool { opened }
    func open() async throws { opened = true }
    func close() async { opened = false }
    func write(_ data: Data) async throws {}
    func read(timeout: Duration) async throws -> Data {
        if timeout > .zero { try await Task.sleep(for: min(timeout, .milliseconds(50))) }
        return Data()
    }
}

/// Verbindung mit langsamem Schreiben (für Abbruchtests).
actor SlowConnection: PrinterConnection {
    nonisolated let descriptor = ConnectionDescriptor.tcp(host: "192.0.2.2", port: 9100)
    private var opened = false
    var isOpen: Bool { opened }
    func open() async throws { opened = true }
    func close() async { opened = false }
    func write(_ data: Data) async throws { try await Task.sleep(for: .milliseconds(5)) }
    func read(timeout: Duration) async throws -> Data { Data() }
}

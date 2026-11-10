import Foundation
import Testing
@testable import LabelWerkKit

@Suite("Virtueller Drucker – Antworten und Zustand")
struct VirtualPrinterTests {

    @Test("~HS liefert drei STX…ETX-Zeilen, die der Statusparser versteht")
    func hostStatus() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let text = try await KitTestSupport.exchange(printer, "~HS")
        #expect(text.filter { $0 == "\u{03}" }.count == 3)
        let status = try HostStatusParser.parse(Data(text.utf8))
        #expect(status.paused == false)
        #expect(status.paperOut == false)
        #expect(status.headOpen == false)
        #expect(status.thermalTransferMode, "ZD421t druckt standardmäßig im Thermotransfer")
        #expect(status.labelLengthDots > 0)
    }

    @Test("~HI nennt Modell, Firmware, dpmm und Speicher")
    func hostIdentification() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let text = try await KitTestSupport.exchange(printer, "~HI")
        let identification = try HostIdentificationParser.parse(Data(text.utf8))
        #expect(identification.model == "ZD421-203dpi")
        #expect(identification.firmware.hasPrefix("V84"))
        #expect(identification.dotsPerMM == 8)
        #expect(identification.memoryKB > 0)
    }

    @Test("~HQES meldet Fehler- und Warnbits")
    func hostQuery() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.setHeadOpen(true)
        await printer.setMediaOut(true)
        let query = try HostQueryParser.parse(Data(try await KitTestSupport.exchange(printer, "~HQES").utf8))
        #expect(query.errors.contains(.headOpen))
        #expect(query.errors.contains(.mediaOut))
        #expect(query.warnings.contains(.needCalibration), "Nach Medienende ist eine Kalibrierung nötig")
        await printer.setHeadOpen(false)
        await printer.setMediaOut(false)
        _ = try await KitTestSupport.exchange(printer, "~JC")
        let cleared = try HostQueryParser.parse(Data(try await KitTestSupport.exchange(printer, "~HQES").utf8))
        #expect(cleared.errors.isEmpty)
        #expect(cleared.warnings.isEmpty)
    }

    @Test("Befehle dürfen auf beliebig viele Schreibvorgänge verteilt sein")
    func splitWrites() async throws {
        let printer = try await KitTestSupport.makePrinter()
        // Ein Format mit eingebettetem ~HS, byteweise gesendet.
        let zpl = "^XA^FO10,10^GB100,50,3^FS~HS^PQ2^XZ! U1 getvar \"device.product_name\"\r\n{}{\"print.tone\":null}"
        var responses = Data()
        for byte in Array(zpl.utf8) {
            try await printer.write(Data([byte]))
            responses.append(try await printer.read(timeout: .zero))
        }
        let text = String(decoding: responses, as: UTF8.self)
        #expect(text.filter { $0 == "\u{03}" }.count == 3, "~HS innerhalb des Formats wurde beantwortet")
        #expect(text.contains("\"ZD421t\""))
        #expect(text.contains("{\"print.tone\":\"15.0\"}"))
        let labels = await printer.renderedLabels
        #expect(labels.count == 1)
        #expect(labels.first?.quantity == 2)
        if case .box(let box)? = labels.first?.elements.first {
            #expect(box.width == 100 && box.height == 50 && box.thickness == 3)
        } else {
            Issue.record("Rahmen fehlt")
        }
        #expect(await printer.labelsPrinted >= 2)
    }

    @Test("Binärdaten in ~DY und ^GFB werden exakt übersprungen, auch über Blockgrenzen")
    func binaryPayloads() async throws {
        let printer = try await KitTestSupport.makePrinter()
        // Schriftdaten mit Präfixzeichen und ^XZ darin.
        var font = Data([0x00, 0x01, 0x00, 0x00])
        font.append(Data("^XZ~HS^XA".utf8))
        font.append(Data((0..<200).map { UInt8($0 % 256) }))
        let upload = ZPL.downloadTrueTypeFont(name: "Test Font.ttf", drive: "E:", data: font)
        // GFB-Grafik mit Bytes 0x5E ('^') und 0x7E ('~').
        var format = Data("^XA^FO0,0^GFB,8,8,2,".utf8)
        format.append(Data([0x5E, 0x7E, 0xFF, 0x00, 0x5E, 0x5E, 0x7E, 0x7E]))
        format.append(Data("^FS^XZ".utf8))
        var all = upload
        all.append(format)
        // In 7-Byte-Blöcken senden.
        var offset = 0
        while offset < all.count {
            let end = min(offset + 7, all.count)
            try await printer.write(all.subdata(in: offset..<end))
            offset = end
        }
        let pending = try await printer.read(timeout: .zero)
        #expect(pending.isEmpty, "Kein ~HS aus Binärdaten beantwortet")
        let files = await printer.files
        #expect(files.map(\.id) == ["E:TEST_FONT.TTF"])
        #expect(await printer.fileData("E:TEST_FONT.TTF") == font)
        let labels = await printer.renderedLabels
        #expect(labels.count == 1)
        guard case .graphic(let graphic)? = labels.first?.elements.first else {
            Issue.record("Grafik fehlt")
            return
        }
        #expect(graphic.bitmap.data == [0x5E, 0x7E, 0xFF, 0x00, 0x5E, 0x5E, 0x7E, 0x7E])
    }

    @Test("SGD getvar/setvar/do mit Prüfung und Persistenz")
    func sgdCommands() async throws {
        let printer = try await KitTestSupport.makePrinter()
        #expect(try await KitTestSupport.exchange(printer, SGD.getvar("device.product_name")) == "\"ZD421t\"")
        #expect(try await KitTestSupport.exchange(printer, SGD.getvar("does.not.exist")) == "\"?\"")
        _ = try await KitTestSupport.exchange(printer, SGD.setvar("device.friendly_name", "Lager-1"))
        #expect(try await KitTestSupport.exchange(printer, SGD.getvar("device.friendly_name")) == "\"Lager-1\"")
        // Ungültige Werte werden ignoriert.
        _ = try await KitTestSupport.exchange(printer, SGD.setvar("print.tone", "99"))
        #expect(await printer.sgdValue("print.tone") == "15.0")
        _ = try await KitTestSupport.exchange(printer, SGD.setvar("media.printmode", "peel off"))
        #expect(await printer.sgdValue("media.printmode") == "peel off")
        // Nur-Lese-Variablen bleiben unverändert.
        _ = try await KitTestSupport.exchange(printer, SGD.setvar("device.product_name", "X"))
        #expect(await printer.sgdValue("device.product_name") == "ZD421t")
        // Zweig-Abfrage im allcv-Format.
        let branch = try await KitTestSupport.exchange(printer, SGD.getvar("ip"))
        let parsed = SGDResponseParser.parseAllCV(branch)
        #expect(parsed["ip.addr"] != nil)
        #expect(parsed["ip.port"]?.value == "9100")
        // do file.dir
        let directory = try await KitTestSupport.exchange(printer, SGD.fileDirectory("E:"))
        #expect(directory.contains("bytes free"))
    }

    @Test("SGD ohne Zeilenende wird beantwortet, sobald der Befehl vollständig ist")
    func sgdWithoutLineEnding() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let text = try await KitTestSupport.exchange(printer, "! U1 getvar \"head.resolution.in_dpi\"")
        #expect(text == "\"203\"")
    }

    @Test("JSON: Lesen, Setzen, Zweige und allconfig")
    func jsonSGD() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let response = try await KitTestSupport.exchange(printer, "{}{\"device.product_name\":null,\"print.tone\":\"20\",\"x.y\":null}")
        #expect(response == "{\"device.product_name\":\"ZD421t\",\"print.tone\":\"20.0\",\"x.y\":null}")
        #expect(await printer.sgdValue("print.tone") == "20.0")

        let all = try await KitTestSupport.exchange(printer, SGD.allConfigJSON)
        let settings = try SGDResponseParser.parseJSON(Data(all.utf8))
        #expect(settings.count >= 60, "Mindestens 60 Variablen, gefunden: \(settings.count)")
        let tone = try #require(settings["print.tone"])
        #expect(tone.value == "20.0")
        #expect(tone.type == "double")
        #expect(tone.range == "0.0-30.0")
        #expect(tone.access == "RW")
        #expect(settings["device.unique_id"]?.access == "R")
        #expect(settings["wlan.wpa.psk"]?.access == "W")
        #expect(settings["media.printmode"]?.choices.contains("peel off") == true)

        await printer.setSupportsJSON(false)
        #expect(try await KitTestSupport.exchange(printer, SGD.allConfigJSON).isEmpty)
    }

    @Test("^HH liefert eine auswertbare Konfiguration")
    func configurationReport() async throws {
        let printer = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(printer, "~SD22^XA^PR5^MMP^XZ")
        let text = try await KitTestSupport.exchange(printer, "^XA^HH^XZ")
        #expect(text.hasPrefix("\u{02}"))
        #expect(text.contains("\u{03}"))
        let entries = ConfigurationLabelParser.parse(text)
        #expect(entries.value(named: "DARKNESS") == "+22.0")
        #expect(entries.value(named: "PRINT SPEED") == "5.0 IPS")
        #expect(entries.value(named: "PRINT MODE") == "PEEL OFF")
        #expect(entries.value(named: "PRINT METHOD") == "THERMAL-TRANS")
        #expect(entries.value(named: "PRINT WIDTH") == String(KitTestSupport.zd421t.printWidthDots(.dpi203)))
        #expect(await printer.renderedLabels.isEmpty, "^HH druckt nichts")
    }

    @Test("~DG speichert Grafiken, ^XG ruft sie ab, ^HW listet, ^ID löscht")
    func storedGraphics() async throws {
        let printer = try await KitTestSupport.makePrinter()
        var bitmap = MonoBitmap(width: 16, height: 4)
        for x in 0..<16 { bitmap[x, x % 4] = true }
        _ = try await KitTestSupport.exchange(printer, ZPLGraphicEncoder.downloadGraphic(name: "LOGO", drive: "E:", bitmap: bitmap))
        #expect(await printer.files.map(\.id) == ["E:LOGO.GRF"])
        _ = try await KitTestSupport.exchange(printer, "^XA^FO20,30^XGE:LOGO.GRF,2,2^FS^XZ")
        let label = try #require(await printer.renderedLabels.last)
        guard case .graphic(let graphic)? = label.elements.first else {
            Issue.record("Grafik fehlt")
            return
        }
        #expect(graphic.bitmap == bitmap)
        #expect(graphic.magnificationX == 2)
        #expect(graphic.origin == LabelPoint(x: 20, y: 30))

        let listing = try await KitTestSupport.exchange(printer, ZPL.hostDirectory("E:*.*"))
        let files = FileDirectoryParser.parse(listing)
        #expect(files.map(\.id) == ["E:LOGO.GRF"])
        #expect(files.first?.size == 8)
        #expect(FileDirectoryParser.parseListing(listing).freeBytes["E:"] != nil)

        _ = try await KitTestSupport.exchange(printer, "^XA^IDE:*.GRF^XZ")
        #expect(await printer.files.isEmpty)
    }

    @Test("Pause und Fehler halten Etiketten zurück; danach werden sie gedruckt")
    func queueWhilePaused() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let before = await printer.labelsPrinted
        _ = try await KitTestSupport.exchange(printer, "~PP")
        _ = try await KitTestSupport.exchange(printer, "^XA^FO0,0^GB50,50,50^FS^PQ3^XZ")
        #expect(await printer.renderedLabels.isEmpty)
        #expect(await printer.pendingLabels.count == 1)
        let status = try HostStatusParser.parse(Data(try await KitTestSupport.exchange(printer, "~HS").utf8))
        #expect(status.paused)
        #expect(status.formatsInReceiveBuffer == 1)
        #expect(status.labelsRemainingInBatch == 3)
        _ = try await KitTestSupport.exchange(printer, "~PS")
        #expect(await printer.renderedLabels.count == 1)
        #expect(await printer.pendingLabels.isEmpty)
        #expect(await printer.labelsPrinted == before + 3)
        let odometer = try #require(await printer.sgdValue("odometer.total_label_count"))
        #expect(Int(odometer) == before + 3)
    }

    @Test("Druckbefehle ändern die Einstellungen, ^JUF lädt Werkseinstellungen")
    func formatSettings() async throws {
        let printer = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(printer, "~TA-10\n^XA^MTD^MNM^MMC^PR6,6,6^LT12^LS-20^PW600^LL400^XZ")
        #expect(await printer.sgdValue("ezpl.print_method") == "direct thermal")
        #expect(await printer.sgdValue("ezpl.media_type") == "mark")
        #expect(await printer.sgdValue("media.printmode") == "cutter")
        #expect(await printer.sgdValue("media.speed") == "6.0")
        #expect(await printer.sgdValue("zpl.label_top") == "12")
        #expect(await printer.sgdValue("zpl.left_position") == "-20")
        #expect(await printer.sgdValue("ezpl.tear_off") == "-10")
        #expect(await printer.sgdValue("ezpl.print_width") == "600")
        #expect(await printer.sgdValue("zpl.label_length") == "400")
        _ = try await KitTestSupport.exchange(printer, "^XA^JUF^XZ")
        #expect(await printer.sgdValue("ezpl.print_method") == "thermal trans")
        #expect(await printer.sgdValue("ezpl.print_width") == String(KitTestSupport.zd421t.printWidthDots(.dpi203)))
    }

    @Test("EPL-Etikett mit Linie, Rahmen und Text")
    func eplLabel() async throws {
        let printer = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(printer, "\nN\nq400\nQ200,24\nLO10,10,100,5\nX20,30,2,120,90\nA30,40,0,3,1,2,R,\"Hallo \\\"EPL\\\"\"\nB10,100,0,1,2,6,50,B,\"123\"\nP3\n")
        let label = try #require(await printer.renderedLabels.last)
        #expect(label.widthDots == 400 && label.heightDots == 200)
        #expect(label.quantity == 3)
        #expect(label.elements.count == 3)
        if case .box(let line)? = label.elements.first {
            #expect(line.origin == LabelPoint(x: 10, y: 10))
            #expect(line.width == 100 && line.height == 5 && line.thickness == 5)
        } else {
            Issue.record("Linie fehlt")
        }
        if case .text(let text)? = label.elements.last {
            #expect(text.text == "Hallo \"EPL\"")
            #expect(text.height == 40, "Schrift 3 (20 Punkte) doppelt hoch")
            #expect(text.reverse)
        } else {
            Issue.record("Text fehlt")
        }
        #expect(label.warnings.count == 1, "Barcode wird als Hinweis vermerkt")
    }

    @Test("CPCL-Block mit Rahmen, Linie und Text auf einem Mobildrucker")
    func cpclLabel() async throws {
        let model = try #require(ModelCatalog.shared.model(id: "zq520"))
        let printer = try await KitTestSupport.makePrinter(model: model)
        let block = CPCL.label(height: 300, quantity: 2) {
            CPCL.pageWidth(576)
            CPCL.box(x0: 10, y0: 10, x1: 200, y1: 100, thickness: 3)
            CPCL.line(x0: 10, y0: 150, x1: 300, y1: 150, thickness: 4)
            CPCL.text("Mobil", x: 20, y: 200)
        }
        _ = try await KitTestSupport.exchange(printer, block)
        let label = try #require(await printer.renderedLabels.last)
        #expect(label.widthDots == 576 && label.heightDots == 300 && label.quantity == 2)
        #expect(label.elements.count == 3)
        if case .text(let text)? = label.elements.last {
            #expect(text.text == "Mobil")
        } else {
            Issue.record("Text fehlt")
        }
        // Der ZD421 kennt kein CPCL: Block wird ignoriert.
        let desktop = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(desktop, block)
        #expect(await desktop.renderedLabels.isEmpty)
    }

    @Test("Simulationsvariablen schalten Fehlerzustände über SGD")
    func simulationVariables() async throws {
        let printer = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(printer, SGD.setvar("labelwerk.simulation.media_out", "on"))
        #expect(await printer.isMediaOut)
        #expect(try await KitTestSupport.exchange(printer, SGD.getvar("labelwerk.simulation.media_out")) == "\"on\"")
        _ = try await KitTestSupport.exchange(printer, "{}{\"labelwerk.simulation.media_out\":\"off\"}")
        #expect(await printer.isMediaOut == false)
        let all = try SGDResponseParser.parseJSON(Data(try await KitTestSupport.exchange(printer, SGD.allConfigJSON).utf8))
        #expect(!all.keys.contains { $0.hasPrefix("labelwerk.") }, "Nicht Teil von allconfig")
    }

    @Test("Zufällige Fremddaten blockieren den Drucker nicht")
    func garbageInput() async throws {
        let printer = try await KitTestSupport.makePrinter()
        var generator = SystemRandomNumberGenerator()
        let garbage = Data((0..<1_000_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            var offset = 0
            while offset < garbage.count {
                let end = min(offset + 16_384, garbage.count)
                try await printer.write(garbage.subdata(in: offset..<end))
                offset = end
            }
        }
        #expect(elapsed < .seconds(20), "Verarbeitung von 1 MB dauerte \(elapsed)")
        // Neue Sitzung: unvollständige Konstrukte verworfen, Drucker antwortet wieder.
        await printer.close()
        try await printer.open()
        let response = try await KitTestSupport.exchange(printer, "~HI")
        #expect(response.contains("ZD421-203dpi"))
    }

    @Test("Modell und Auflösung sind konfigurierbar")
    func configurableModel() async throws {
        let model = try #require(ModelCatalog.shared.model(id: "zt410"))
        let printer = try await KitTestSupport.makePrinter(model: model, resolution: .dpi300)
        let identification = try HostIdentificationParser.parse(Data(try await KitTestSupport.exchange(printer, "~HI").utf8))
        #expect(identification.model == "ZT410-300dpi")
        #expect(identification.dotsPerMM == 12)
        #expect(try await KitTestSupport.exchange(printer, SGD.getvar("head.resolution.in_dpi")) == "\"300\"")
        #expect(try await KitTestSupport.exchange(printer, SGD.getvar("ezpl.print_width"))
            == "\"\(model.printWidthDots(.dpi300))\"")

        let fromID = VirtualPrinter.make(forID: "zt410-600")
        #expect(fromID.model.id == "zt410")
        #expect(fromID.resolution == .dpi600)
        #expect(VirtualPrinter.make(forID: "demo").model.id == "zd421t")
    }

    @Test("Fabrik für .virtual liefert je Kennung denselben Drucker")
    func connectionFactory() async throws {
        VirtualPrinter.registerWithConnectionFactory()
        let first = try ConnectionFactory.make(.virtual(id: "factory-test"))
        let second = try ConnectionFactory.make(.virtual(id: "factory-test"))
        #expect(first === second)
        #expect((first as? VirtualPrinter)?.model.id == "zd421t")
    }

    @Test("^MD ist ein Versatz zur gespeicherten Schwärzung – nicht kumulativ, nach Neustart 0")
    func mediaDarknessIsRelativeOffset() async throws {
        let printer = try await KitTestSupport.makePrinter()
        #expect(await printer.sgdValue("print.tone") == "15.0")
        for _ in 0..<5 {
            _ = try await KitTestSupport.exchange(printer, "^XA^MD5^FO0,0^GB10,10,10^FS^XZ")
        }
        #expect(await printer.renderedLabels.count == 5)
        #expect(await printer.sgdValue("print.tone") == "15.0", "Gespeicherte Schwärzung bleibt unverändert")
        #expect(await printer.relativeDarkness == 5)
        #expect(await printer.effectiveDarkness == 20, "Jedes Etikett: 15 + 5, nicht 15 + 5·n")
        let diagnostics = try await KitTestSupport.exchange(printer, "~HD")
        #expect(diagnostics.contains("Darkness Adjust = 20.0"))

        // Ein neuer Wert ersetzt den alten; Bereich −30…30; Ergebnis 0…30.
        _ = try await KitTestSupport.exchange(printer, "^XA^MD-40^XZ")
        #expect(await printer.relativeDarkness == -30)
        #expect(await printer.effectiveDarkness == 0)
        _ = try await KitTestSupport.exchange(printer, "^XA^MD-3^XZ~SD25")
        #expect(await printer.sgdValue("print.tone") == "25.0")
        #expect(await printer.effectiveDarkness == 22, "~SD ändert die Basis, der Versatz bleibt")

        // Neustart: Versatz zurück auf 0 (Einschaltwert).
        _ = try await KitTestSupport.exchange(printer, "~JR")
        #expect(await printer.relativeDarkness == 0)
        #expect(await printer.effectiveDarkness == 25)
        #expect(await printer.sgdValue("print.tone") == "25.0")
    }

    @Test("^JS ist die Sensorwahl und ändert den Rückzug nicht; ~JS stellt ihn ein")
    func sensorSelectVersusBackfeed() async throws {
        let printer = try await KitTestSupport.makePrinter()
        #expect(await printer.backfeed == .normal)
        for code in ["A", "B", "N", "O", "R", "T"] {
            _ = try await KitTestSupport.exchange(printer, "^XA^JS\(code)^XZ")
            #expect(await printer.backfeed == .normal, "^JS\(code)")
        }
        let expected: [(String, BackfeedMode)] = [("A", .afterPrinting), ("B", .beforePrinting), ("O", .off), ("N", .normal)]
        for (code, mode) in expected {
            _ = try await KitTestSupport.exchange(printer, "~JS\(code)\n")
            #expect(await printer.backfeed == mode, "~JS\(code)")
        }
    }

    @Test("Neustart verwirft, was im selben Datenblock folgt")
    func restartDiscardsRestOfBlock() async throws {
        let printer = try await KitTestSupport.makePrinter()
        _ = try await KitTestSupport.exchange(printer, "~PP")
        #expect(await printer.isPaused)
        _ = try await KitTestSupport.exchange(printer, "~JR\n^XA^FO0,0^GB10,10,10^FS^XZ\n^XA^FO0,0^GB")
        #expect(await printer.restartCount == 1)
        #expect(await printer.isPaused == false, "Neustart beendet die Pause")
        #expect(await printer.renderedLabels.isEmpty, "Format nach ~JR ging beim Neustart verloren")
        // Auch das unvollständige Format ist verworfen: Ein neues Format wird normal gedruckt.
        _ = try await KitTestSupport.exchange(printer, "^XA^FO0,0^GB10,10,10^FS^XZ")
        #expect(await printer.renderedLabels.count == 1)

        _ = try await KitTestSupport.exchange(printer, SGD.do("device.reset") + "^XA^FO0,0^GB10,10,10^FS^XZ")
        #expect(await printer.restartCount == 2)
        #expect(await printer.renderedLabels.count == 1)
    }

    @Test("Geschlossene Verbindung weist Lesen und Schreiben ab und weckt wartende Leser")
    func closeWakesReaders() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let reader = Task { try await printer.read(timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        await printer.close()
        await #expect(throws: TransportError.notOpen) { try await reader.value }
        await #expect(throws: TransportError.notOpen) { try await printer.write(Data("~HS".utf8)) }
    }

    @Test("Abbruch eines wartenden Lesers wirft CancellationError")
    func cancelReader() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let reader = Task { try await printer.read(timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
    }
}

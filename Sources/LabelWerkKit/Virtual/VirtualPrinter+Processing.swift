import Foundation
import LabelWerkCore
import LabelWerkImaging
import LabelWerkRender
import LabelWerkStatus

extension VirtualPrinter {

    // MARK: - Verteilung

    func process(_ data: Data) {
        stream.acceptsEPL = model.supports(.epl) && (sgdEnabled ? store.acceptsEPL : true)
        let restartsBefore = restartCount
        for event in stream.feed(data) {
            handle(event)
            if restartCount != restartsBefore {
                // Neustart: Der Empfangspuffer geht verloren – was im selben Block folgt,
                // verarbeitet der Drucker nicht mehr.
                stream.reset()
                return
            }
        }
    }

    func handle(_ event: VirtualPrinterStream.Event) {
        switch event {
        case .tilde(let command, let parameters):
            handleTilde(command, parameters)
        case .downloadGraphic(let path, let total, let perRow, let data):
            storeGraphic(path: path, totalBytes: total, bytesPerRow: perRow, data: data)
        case .downloadObject(let path, let format, let ext, let total, let perRow, let data):
            storeObject(path: path, format: format, fileExtension: ext, totalBytes: total, bytesPerRow: perRow, data: data)
        case .format(let bytes):
            handleFormat(VirtualPrinterStream.decodeText(bytes))
        case .sgd(let line):
            if sgdEnabled { handleSGDLine(line) }
        case .json(let bytes):
            if jsonEnabled { handleJSON(bytes) }
        case .cpcl(let bytes):
            if model.supports(.cpcl) { handleCPCL(bytes) }
        case .epl(let line):
            handleEPL(line)
        }
    }

    // MARK: - Abgeleitete Werte

    var printWidthDots: Int {
        store.rawValue("ezpl.print_width").flatMap { Int($0) } ?? model.printWidthDots(resolution)
    }

    var labelLengthDots: Int {
        store.rawValue("zpl.label_length").flatMap { Int($0) } ?? resolution.dots(fromInches: 6)
    }

    var isThermalTransfer: Bool {
        store.rawValue("ezpl.print_method") == "thermal trans"
    }

    var currentPrintMode: PrintMode {
        store.rawValue("media.printmode").flatMap(SGDValueMapping.printMode(sgd:)) ?? .tearOff
    }

    /// Druckbereit (keine Pause, kein Fehler).
    var canPrint: Bool {
        !paused && !headOpen && !mediaOut && !(ribbonOut && isThermalTransfer)
    }

    /// Schwärzung, mit der Etiketten gedruckt werden: gespeicherte Schwärzung (`print.tone`,
    /// `~SD`) plus Versatz aus `^MD`, begrenzt auf 0…30.
    var effectiveDarkness: Double {
        let tone = store.rawValue("print.tone").flatMap { Double($0) } ?? 15
        return min(30, max(0, tone + relativeDarkness))
    }

    func intValue(_ name: String) -> Int {
        store.rawValue(name).flatMap { Double($0) }.map { Int($0.rounded()) } ?? 0
    }

    // MARK: - Statusantworten

    func hostStatus() -> HostStatus {
        let continuous = store.rawValue("ezpl.media_type")?.contains("continuous") == true
        var function = 0
        if isThermalTransfer { function |= 0x01 }
        if continuous { function |= 0x80 }
        return HostStatus(
            communicationSettings: 30,
            paperOut: mediaOut,
            paused: paused,
            labelLengthDots: labelLengthDots,
            formatsInReceiveBuffer: queued.filter { !$0.started }.count,
            receiveBufferFull: false,
            diagnosticMode: false,
            partialFormatInProgress: stream.isInsideFormat,
            corruptRAM: false,
            underTemperature: false,
            overTemperature: false,
            functionSettings: function,
            headOpen: headOpen,
            ribbonOut: ribbonOut && isThermalTransfer,
            thermalTransferMode: isThermalTransfer,
            printMode: currentPrintMode,
            printWidthMode: 0,
            labelWaitingToBePeeled: false,
            labelsRemainingInBatch: queued.reduce(0) { $0 + $1.remaining },
            formatWhileWritingGraphics: true,
            graphicsStoredInMemory: storedFiles.values.filter { $0.bitmap != nil }.count,
            password: "1234",
            staticRAMInstalled: false
        )
    }

    func hostQuery() -> HostQueryStatus {
        var errors: PrinterErrorFlags = []
        if mediaOut { errors.insert(.mediaOut) }
        if ribbonOut && isThermalTransfer { errors.insert(.ribbonOut) }
        if headOpen { errors.insert(.headOpen) }
        if paused { errors.insert(.paused) }
        var warnings = simulatedWarnings
        if calibrationNeeded { warnings.insert(.needCalibration) }
        return HostQueryStatus(errors: errors, warnings: warnings)
    }

    /// Modellbezeichnung wie in `~HI`, z. B. `ZD421-203dpi`.
    var hostModelName: String {
        var base = model.name
        if let last = base.last, "dtc".contains(last), base.dropLast().last?.isNumber == true { base.removeLast() }
        return "\(base)-\(resolution.dpi)dpi"
    }

    func hostIdentification() -> HostIdentification {
        HostIdentification(model: hostModelName, firmware: store.rawValue("appl.name") ?? identity.firmware,
                           dotsPerMM: resolution.dotsPerMM, memoryKB: Self.ramBytes / 1024)
    }

    // MARK: - Steuerbefehle

    func handleTilde(_ command: String, _ parameters: String) {
        switch command {
        case "HS": respond(hostStatus().responseText)
        case "HI": respond(hostIdentification().responseText + "\r\n")
        case "HQ": respondHostQuery(parameters)
        case "HM":
            let total = Self.ramBytes / 1024
            let free = max(0, (Self.ramBytes - usedBytes(on: "R:")) / 1024)
            respond("\u{02}\(total),\(total),\(free)\u{03}\r\n")
        case "HD": respond(headDiagnostics())
        case "HB":
            if model.supports(.battery) { respond("\u{02}07.80,24.00,25\u{03}\u{04}") }
        case "SD":
            if let value = Int(parameters) { store.update("print.tone", String(min(30, max(0, value)))) }
        case "TA":
            if let value = Int(parameters) { store.update("ezpl.tear_off", String(min(120, max(-120, value)))) }
        case "JC": calibrate()
        case "JL": feed(labels: 2)
        case "JG":
            calibrate()
            printSensorProfile()
        case "PH": feed(labels: 1)
        case "PP": paused = true
        case "PS":
            paused = false
            flushQueue()
        case "JA": cancelAllFormats()
        case "JR": restartDevice()
        case "WC": printReport(title: "PRINTER CONFIGURATION", lines: configurationEntries().map { "\($0.value)  \($0.name)" })
        case "WL": printReport(title: "NETWORK CONFIGURATION", lines: networkReportLines())
        case "JS":
            // ~JS{A|B|N|O|10–90}: Rückzugsfolge.
            switch parameters.uppercased().first {
            case "A": backfeed = .afterPrinting
            case "B": backfeed = .beforePrinting
            case "N": backfeed = .normal
            case "O": backfeed = .off
            default: break
            }
        default:
            // ~CC/~CT/~CD (Präfixwechsel) und weitere Befehle werden nicht nachgebildet.
            break
        }
    }

    private func respondHostQuery(_ type: String) {
        switch type {
        case "ES":
            respond(hostQuery().responseText)
        case "SN":
            respond("\u{02}\r\n  PRINTER INFO\r\n   SERIAL NUMBER:  \(serialNumber)\r\n\u{03}\r\n")
        case "HA":
            let mac = (store.rawValue("interface.network.active.mac_addr") ?? identity.wiredMAC)
                .replacingOccurrences(of: ":", with: "").uppercased()
            respond("\u{02}\r\n  MAC ADDRESS\r\n   \(mac)\r\n\u{03}\r\n")
        case "OD":
            let inches = Int(printLengthMM / 25.4)
            let cm = Int(printLengthMM / 10)
            respond("\u{02}\r\n  PRINT METERS\r\n   TOTAL NONRESETTABLE:  \(inches) \"\r\n"
                    + "   USER RESETTABLE CNTR1:  \(Int(headCleanMM / 25.4)) \"\r\n"
                    + "   TOTAL NONRESETTABLE:  \(cm) cm\r\n\u{03}\r\n")
        default:
            break
        }
    }

    private func headDiagnostics() -> String {
        let lines = [
            "Head Temp = \(store.rawValue("head.temperature") ?? "27")",
            "Ambient Temp = 24",
            "Head Test = Passed",
            "Darkness Adjust = \(effectiveDarkness)",
            "Print Speed = \(store.rawValue("media.speed") ?? "4.0")",
            "Slew Speed = \(store.rawValue("media.speed") ?? "4.0")",
            "Backfeed Speed = \(store.rawValue("media.speed") ?? "4.0")",
            "Static_pitch_length = \(labelLengthDots)",
            "Dynamic_pitch_length = \(labelLengthDots)",
            "Max_dynamic_pitch_length = \(labelLengthDots + 8)",
            "Min_dynamic_pitch_length = \(max(0, labelLengthDots - 8))",
            "COMMAND PFX = ^ : 5E",
            "CONTROL PFX = ~ : 7E",
            "DELIMITER   = , : 2C",
        ]
        return "\u{02}\r\n" + lines.map { $0 + "\r\n" }.joined() + "\u{03}\r\n"
    }

    // MARK: - Formate

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handleFormat(_ text: String) {
        let tokens = ZPLTokenizer.tokenize(text)
        var graphics: [String] = []
        var formats: [String] = []
        for token in tokens where token.prefix == "^" {
            let parameters = token.parameters.map { $0.trimmingCharacters(in: .whitespaces) }
            func parameter(_ index: Int) -> String { index < parameters.count ? parameters[index] : "" }
            let first = parameter(0).uppercased()
            switch token.command {
            case "MT":
                if first.hasPrefix("T") { store.update("ezpl.print_method", "thermal trans") }
                if first.hasPrefix("D") { store.update("ezpl.print_method", "direct thermal") }
            case "MN":
                applyMediaTracking(first)
            case "MM":
                if let code = first.first, let mode = PrintMode(zplCode: String(code)) {
                    store.update("media.printmode", SGDValueMapping.printMode(mode))
                }
            case "PR":
                if let speed = Self.zplSpeed(first) { store.update("media.speed", String(speed)) }
            case "LT":
                if let value = Int(first) { store.update("zpl.label_top", String(min(120, max(-120, value)))) }
            case "LS":
                if let value = Int(first) { store.update("zpl.left_position", String(min(9999, max(-9999, value)))) }
            case "PW":
                if let value = Int(first) {
                    store.update("ezpl.print_width", String(min(model.printWidthDots(resolution), max(2, value))))
                }
            case "LL":
                if let value = Int(first) {
                    store.update("zpl.label_length", String(min(model.maxLabelLengthDots(resolution), max(1, value))))
                }
            case "MD":
                // Versatz zur gespeicherten Schwärzung (nicht kumulativ): ersetzt einen früheren
                // ^MD-Wert, `print.tone` (~SD) bleibt unverändert.
                if let offset = Double(first), offset.isFinite {
                    relativeDarkness = min(30, max(-30, offset))
                }
            case "JZ":
                // ^JZ{Y|N}: Etikett nach einem Fehler (Papier/Farbband leer, Kopf offen) erneut drucken.
                reprintAfterError = !first.hasPrefix("N")
            case "JS":
                // ^JS{A|R|T} ist die Sensorwahl (automatisch, reflektiv, transmissiv) und wird
                // nicht nachgebildet. Den Rückzug stellt der Steuerbefehl ~JS ein.
                break
            case "PO":
                printInverted = first.hasPrefix("I")
            case "PM":
                printMirrored = first.hasPrefix("Y")
            case "JU":
                switch first {
                case "F": restoreFactoryDefaults()
                case "N": restoreNetworkDefaults()
                case "A":
                    restoreFactoryDefaults()
                    restoreNetworkDefaults()
                default: break // S (speichern) und R (zurückholen): alles ist sofort dauerhaft.
                }
            case "ST":
                setClock(parameters)
            case "MF":
                if let action = Self.feedAction(first) { store.update("ezpl.power_up_action", action) }
                if let action = Self.feedAction(parameter(1).uppercased()) { store.update("ezpl.head_close_action", action) }
            case "KN":
                let name = parameter(0)
                if !name.isEmpty { store.update("device.friendly_name", String(name.prefix(17))) }
            case "HH":
                respond(configurationReport())
            case "HW":
                respond(directoryReport(pattern: token.arguments))
            case "WD":
                printDirectoryLabel(pattern: token.arguments)
            case "ID":
                deleteFiles(matching: token.arguments)
            case "DF":
                defineFormat(name: token.arguments, text: text)
            case "HF":
                if let file = findFile(token.arguments, defaultExtension: ".ZPL"), let format = file.formatText {
                    respond("\u{02}" + format + "\u{03}\r\n")
                }
            case "HG":
                if let file = findFile(token.arguments, defaultExtension: ".GRF"), let bitmap = file.bitmap {
                    respond(ZPLGraphicEncoder.downloadGraphic(name: file.name, drive: file.drive, bitmap: bitmap) + "\r\n")
                }
            case "XG", "IM", "IL":
                graphics.append(parameter(0))
            case "XF":
                formats.append(parameter(0))
            default:
                break
            }
        }
        renderAndPrint(text, graphics: graphics, formats: formats)
    }

    private func applyMediaTracking(_ code: String) {
        switch code.first {
        case "Y", "W":
            store.update("ezpl.media_type", "gap/notch")
            store.update("media.sense_mode", "gap")
            store.update("media.type", "label")
        case "M":
            store.update("ezpl.media_type", "mark")
            store.update("media.sense_mode", "bar")
            store.update("media.type", "label")
        case "N":
            store.update("ezpl.media_type", "continuous")
            store.update("media.type", "journal")
        case "V":
            store.update("ezpl.media_type", "continuous variable")
            store.update("media.type", "journal")
        default:
            // „A“ (automatische Erkennung): Die Art ergibt sich erst beim Kalibrieren – bisherige
            // Einstellung bleibt.
            break
        }
    }

    /// `^STa,b,c,d,e,f,g` – Monat, Tag, Jahr, Stunde, Minute, Sekunde, Format (`A`/`P` = 12 Stunden
    /// vormittags/nachmittags, `M` = 24 Stunden). Fehlende Felder behalten den aktuellen Wert.
    func setClock(_ parameters: [String]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let current = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: clockDate)
        func number(_ index: Int, _ fallback: Int?) -> Int? {
            guard index < parameters.count, let value = Int(parameters[index]) else { return fallback }
            return value
        }
        var components = DateComponents()
        components.month = number(0, current.month)
        components.day = number(1, current.day)
        components.year = number(2, current.year)
        var hour = number(3, current.hour) ?? 0
        let format = parameters.count > 6 ? parameters[6].uppercased() : "M"
        if format == "P", hour < 12 { hour += 12 }
        if format == "A", hour == 12 { hour = 0 }
        components.hour = hour
        components.minute = number(4, current.minute)
        components.second = number(5, current.second)
        guard let date = calendar.date(from: components) else { return }
        clockOffset = date.timeIntervalSince(Date())
    }

    /// `rtc.date` (`MM-DD-YYYY`) bzw. `rtc.time` (`HH:MM:SS`) per SGD stellen.
    func setClock(sgdName name: String, value: String) -> Bool {
        let parts = value.split(whereSeparator: { $0 == "-" || $0 == ":" || $0 == "/" || $0 == "." })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: clockDate)
        if name == "rtc.date" {
            (c.month, c.day, c.year) = (Int(parts[0]), Int(parts[1]), Int(parts[2]))
        } else {
            (c.hour, c.minute, c.second) = (Int(parts[0]), Int(parts[1]), Int(parts[2]))
        }
        guard let date = calendar.date(from: c) else { return false }
        clockOffset = date.timeIntervalSince(Date())
        return true
    }

    /// `^PR`-Geschwindigkeit: Ziffern (Zoll/s) oder Buchstaben A–E.
    static func zplSpeed(_ code: String) -> Int? {
        switch code {
        case "A": return 2
        case "B": return 3
        case "C": return 4
        case "D": return 6
        case "E": return 8
        default: return Int(code)
        }
    }

    static func feedAction(_ code: String) -> String? {
        switch code.first {
        case "F": return "feed"
        case "C": return "calibrate"
        case "L": return "length"
        case "N": return "no motion"
        case "S": return "short cal"
        default: return nil
        }
    }

    /// Rendert ein Format (mit dauerhaften Einstellungen und benötigten gespeicherten Objekten)
    /// und druckt alle entstehenden Etiketten.
    func renderAndPrint(_ text: String, graphics: [String], formats: [String]) {
        var prefix = "^XA^LS\(intValue("zpl.left_position"))^LT\(intValue("zpl.label_top"))"
        prefix += "^PO\(printInverted ? "I" : "N")^PM\(printMirrored ? "Y" : "N")^XZ\n"
        for name in graphics {
            if let file = findFile(name, defaultExtension: ".GRF"), let bitmap = file.bitmap {
                prefix += ZPLGraphicEncoder.downloadGraphic(name: file.name, drive: file.drive, bitmap: bitmap) + "\n"
            }
        }
        for name in formats {
            if let file = findFile(name, defaultExtension: ".ZPL"), let format = file.formatText {
                prefix += format + "\n"
            }
        }
        let document = interpreter().render(prefix + text)
        let record = Self.printRecord(forFormat: text)
        for label in document.labels {
            printOrQueue(label, record: record)
        }
    }

    func interpreter() -> ZPLInterpreter {
        ZPLInterpreter(dotsPerMM: resolution.dotsPerMM, defaultWidthDots: printWidthDots,
                       defaultHeightDots: labelLengthDots)
    }

    // MARK: - Drucken

    /// Nimmt ein Etikett in die Druckwarteschlange und druckt, sobald der Drucker bereit ist – sofort
    /// (ohne Druckzeit) oder Exemplar für Exemplar mit der eingestellten Druckzeit (``setPrintTime(_:)``,
    /// `VirtualPrinter+Engine.swift`).
    func printOrQueue(_ label: RenderedLabel, record: String? = nil) {
        queued.append(QueuedFormat(label: label, remaining: max(1, label.quantity),
                                   record: record ?? Self.printRecord(for: label)))
        flushQueue()
    }

    /// Medienvorschub: erhöht Etikettenzähler und Odometer.
    func advanceMedia(labels: Int, lengthDots: Int) {
        let gapMM = store.rawValue("ezpl.media_type")?.contains("continuous") == true ? 0.0 : 3.0
        let millimetres = Double(labels) * (Double(max(0, lengthDots)) / resolution.exactDotsPerMM + gapMM)
        labelCount += labels
        printLengthMM += millimetres
        headCleanMM += millimetres
        headNewMM += millimetres
        updateCounters()
    }

    func updateCounters() {
        store.force("odometer.total_label_count", String(labelCount))
        store.force("odometer.total_print_length", identity.odometerText(mm: printLengthMM))
        store.force("odometer.headclean", identity.odometerText(mm: headCleanMM))
        store.force("odometer.headnew", identity.odometerText(mm: headNewMM))
    }

    /// Leeres Etikett vorschieben (`~PH`, Kalibrieren).
    func feed(labels: Int) {
        guard canPrint else { return }
        advanceMedia(labels: labels, lengthDots: labelLengthDots)
    }

    func calibrate() {
        guard !headOpen, !mediaOut else { return }
        feed(labels: 2)
        calibrationNeeded = false
    }

    // MARK: - Neustart & Werkseinstellungen

    /// Neustart (`~JR`, SGD `device.reset`): Pause, Warteschlange und `^MD`-Versatz enden, Dateien
    /// im RAM-Laufwerk `R:` sind weg (wie beim Aus- und Einschalten), Netzwerkeinstellungen werden
    /// übernommen. Nachfolgende Daten desselben Blocks verwirft ``process(_:)``;
    /// ``VirtualPrinterServer`` trennt die Verbindung.
    func restartDevice() {
        restartCount += 1
        paused = false
        cancelAllFormats()
        storedFiles = storedFiles.filter { $0.value.drive != "R:" }
        relativeDarkness = 0
        bootDate = Date()
        let protocolValue = store.rawValue("ip.ip_protocol") ?? "dhcp"
        if protocolValue == "permanent" {
            store.force("interface.network.active.ip_addr", store.rawValue("ip.addr") ?? identity.ipAddress)
            store.force("interface.network.active.netmask", store.rawValue("ip.netmask") ?? "255.255.255.0")
            store.force("interface.network.active.gateway", store.rawValue("ip.gateway") ?? identity.gateway)
            store.force("internal_wired.ip.addr", store.rawValue("ip.addr") ?? identity.ipAddress)
            store.force("interface.network.active.protocol", "permanent")
        } else {
            // DHCP: Der (simulierte) Server vergibt wieder die bisherige Adresse.
            store.force("interface.network.active.protocol", protocolValue)
        }
    }

    func restoreFactoryDefaults() {
        store.restoreDefaults(.general)
        store.restoreDefaults(.display)
        store.restoreDefaults(.power)
        printInverted = false
        printMirrored = false
        backfeed = .normal
        stream.acceptsEPL = model.supports(.epl) && store.acceptsEPL
    }

    func restoreNetworkDefaults() {
        store.restoreDefaults(.ip)
        store.restoreDefaults(.wlan)
    }

    // MARK: - Dateien

    /// Speicher je Laufwerk.
    static let ramBytes = 8 << 20
    static let flashBytes = 64 << 20

    static func capacity(of drive: String) -> Int {
        switch drive {
        case "R:": return ramBytes
        case "E:": return flashBytes
        case "B:", "A:": return 0
        default: return 0
        }
    }

    func usedBytes(on drive: String) -> Int {
        storedFiles.values.filter { $0.drive == drive }.reduce(0) { $0 + $1.data.count }
    }

    /// Zerlegt `E:LOGO.GRF` in Laufwerk und Name (Standardlaufwerk `R:`, Endung wie angegeben).
    static func splitPath(_ raw: String, defaultExtension: String) -> (drive: String, name: String) {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var drive = "R:"
        if let colon = name.firstIndex(of: ":"), name.distance(from: name.startIndex, to: colon) <= 1 {
            let prefix = name[..<colon]
            if !prefix.isEmpty { drive = prefix + ":" }
            name = String(name[name.index(after: colon)...])
        }
        if !name.contains("."), !defaultExtension.isEmpty { name += defaultExtension }
        return (drive, name)
    }

    func findFile(_ raw: String, defaultExtension: String) -> StoredFile? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let (drive, name) = Self.splitPath(trimmed, defaultExtension: defaultExtension)
        if let file = storedFiles[drive + name] { return file }
        // Ohne ausdrückliches Laufwerk sucht die Firmware auf allen Laufwerken.
        if !trimmed.contains(":") {
            for candidate in ["R:", "E:", "B:", "A:"] {
                if let file = storedFiles[candidate + name] { return file }
            }
        }
        return nil
    }

    /// Speichert eine Datei, sofern das Laufwerk existiert und genug Platz hat.
    func save(_ file: StoredFile) {
        let capacity = Self.capacity(of: file.drive)
        let existing = storedFiles[file.path]?.data.count ?? 0
        guard capacity > 0, usedBytes(on: file.drive) - existing + file.data.count <= capacity else { return }
        storedFiles[file.path] = file
    }

    func storeGraphic(path: String, totalBytes: Int, bytesPerRow: Int, data: String) {
        let (drive, name) = Self.splitPath(path, defaultExtension: ".GRF")
        guard totalBytes > 0, bytesPerRow > 0,
              let bitmap = try? ZPLGraphicEncoder.decodeGraphicField(format: "A", totalBytes: totalBytes,
                                                                      bytesPerRow: bytesPerRow, data: data) else { return }
        save(StoredFile(drive: drive, name: name, data: Data(bitmap.data.prefix(totalBytes)), bitmap: bitmap, formatText: nil))
    }

    func storeObject(path: String, format: String, fileExtension: String, totalBytes: Int, bytesPerRow: Int,
                     data: [UInt8]) {
        let extensionName: String
        switch fileExtension {
        case "T": extensionName = ".TTF"
        case "E": extensionName = ".TTE"
        case "G": extensionName = ".GRF"
        case "P": extensionName = ".PNG"
        case "B": extensionName = ".BMP"
        case "X": extensionName = ".PCX"
        case "O": extensionName = ".OTF"
        default: extensionName = fileExtension.isEmpty ? "" : "." + fileExtension
        }
        let (drive, name) = Self.splitPath(path, defaultExtension: extensionName)
        var bitmap: MonoBitmap?
        if name.hasSuffix(".GRF"), bytesPerRow > 0, data.count >= bytesPerRow {
            let rows = data.count / bytesPerRow
            bitmap = MonoBitmap(width: bytesPerRow * 8, height: rows, data: Array(data.prefix(rows * bytesPerRow)))
        }
        save(StoredFile(drive: drive, name: name, data: Data(data), bitmap: bitmap, formatText: nil))
    }

    func defineFormat(name: String, text: String) {
        let (drive, fileName) = Self.splitPath(name, defaultExtension: ".ZPL")
        save(StoredFile(drive: drive, name: fileName, data: Data(text.utf8), bitmap: nil, formatText: text))
    }

    /// Löscht Dateien (`E:LOGO.GRF`, `R:*.GRF`, `*:*.*`; ohne Laufwerk `R:`).
    func deleteFiles(matching pattern: String) {
        let (drivePattern, namePattern) = Self.splitPattern(pattern)
        for (key, file) in storedFiles where Self.matches(file, drive: drivePattern, name: namePattern) {
            storedFiles.removeValue(forKey: key)
        }
    }

    static func splitPattern(_ raw: String) -> (drive: String, name: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let colon = text.firstIndex(of: ":") else { return ("R:", text.isEmpty ? "*.*" : text) }
        let drive = String(text[..<colon]) + ":"
        let name = String(text[text.index(after: colon)...])
        return (drive, name.isEmpty ? "*.*" : name)
    }

    static func matches(_ file: StoredFile, drive: String, name: String) -> Bool {
        (drive == "*:" || drive == file.drive) && wildcard(file.name, matches: name)
    }

    /// Platzhaltervergleich (`*`, `?`), ohne Groß-/Kleinschreibung.
    static func wildcard(_ text: String, matches pattern: String) -> Bool {
        let t = Array(text.uppercased()), p = Array(pattern.uppercased())
        var ti = 0, pi = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                ti += 1
                pi += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Dateien zu einem Muster, nach Laufwerk und Name sortiert.
    func files(matching pattern: String) -> [StoredFile] {
        let (drive, name) = Self.splitPattern(pattern)
        return storedFiles.values.filter { Self.matches($0, drive: drive, name: name) }
            .sorted { ($0.drive, $0.name) < ($1.drive, $1.name) }
    }
}

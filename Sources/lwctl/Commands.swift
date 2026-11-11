import Foundation
import LabelWerkKit

/// Ausführung der Befehle.
enum Commands {

    static func execute(_ spec: CommandSpec, _ context: Context) async throws -> ExitCode {
        switch spec.name {
        case "help": return help(context)
        case "version": Console.out(LWCtl.versionText); return .success
        case "models": return try models(context)
        case "stocks": return try stocks(context)
        case "render": return try render(context)
        case "encode": return try encode(context)
        case "discover": return try await discover(context)
        case "virtual-printer": return try await virtualPrinter(context)
        case "install": return try await InstallCommands.install(context)
        case "queues": return try await InstallCommands.queues(context)
        case "uninstall-queue": return try await InstallCommands.uninstallQueue(context)
        default:
            let client = try await makeClient(context)
            do {
                let code = try await executePrinterCommand(spec.name, client, context)
                await client.disconnect()
                return code
            } catch {
                await client.disconnect()
                throw error
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func executePrinterCommand(_ name: String, _ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        switch name {
        case "status": return try await PrinterCommands.status(client, context)
        case "info": return try await PrinterCommands.info(client, context)
        case "send": return try await PrinterCommands.send(client, context)
        case "print": return try await PrinterCommands.print(client, context)
        case "action": return try await PrinterCommands.action(client, context)
        case "getvar": return try await PrinterCommands.getvar(client, context)
        case "setvar": return try await PrinterCommands.setvar(client, context)
        case "do": return try await PrinterCommands.doCommand(client, context)
        case "settings": return try await PrinterCommands.settings(client, context)
        case "config": return try await PrinterCommands.config(client, context)
        case "network": return try await PrinterCommands.network(client, context)
        case "files": return try await PrinterCommands.files(client, context)
        case "delete-file": return try await PrinterCommands.deleteFile(client, context)
        case "upload-font": return try await PrinterCommands.uploadFont(client, context)
        case "upload-graphic": return try await PrinterCommands.uploadGraphic(client, context)
        case "firmware": return try await PrinterCommands.firmware(client, context)
        case "terminal": return try await TerminalSession.run(client, context)
        case "test-label": return try await PrinterCommands.testLabel(client, context)
        default:
            throw CLIError.usage("Unbekannter Befehl „\(name)“.")
        }
    }

    // MARK: - Drucker

    /// Erzeugt den Client für `--printer` bzw. `LWCTL_PRINTER`.
    static func makeClient(_ context: Context) async throws -> PrinterClient {
        let environment = ProcessInfo.processInfo.environment["LWCTL_PRINTER"]
        guard let uri = (context.arguments.value("printer") ?? environment)?.trimmingCharacters(in: .whitespaces),
              !uri.isEmpty else {
            throw CLIError.usage("Kein Drucker angegeben. Verwenden Sie --printer <uri> (z. B. tcp://192.168.1.20) oder setzen Sie LWCTL_PRINTER.")
        }
        guard let descriptor = ConnectionDescriptor(uriString: uri) else {
            throw CLIError.usage("Ungültige Drucker-URI „\(uri)“. Beispiele: tcp://192.168.1.20:9100, usb://0a5f:0181, cups://Zebra_ZD421, virtual://demo")
        }
        let connection: any PrinterConnection
        do {
            connection = try ConnectionFactory.make(descriptor)
        } catch {
            throw CLIError.connection((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        let client = PrinterClient(connection: connection, language: context.language)
        if let timeout = context.timeout {
            var timeouts = PrinterClient.Timeouts.standard
            timeouts.response = timeout
            timeouts.bulk = max(timeouts.bulk, timeout)
            await client.setTimeouts(timeouts)
        }
        return client
    }

    // MARK: - Ohne Drucker

    static func help(_ context: Context) -> ExitCode {
        if let name = context.arguments.arguments.first {
            guard let spec = CommandCatalog.byName[name] else {
                Console.err("lwctl: Unbekannter Befehl „\(name)“.")
                return .usage
            }
            Console.out(CommandCatalog.help(for: spec), terminator: "")
        } else {
            Console.out(CommandCatalog.overview(), terminator: "")
        }
        return .success
    }

    static func models(_ context: Context) throws -> ExitCode {
        var models = ModelCatalog.shared.models
        if let raw = context.arguments.value("category") {
            guard let category = PrinterCategory.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
                throw CLIError.usage("Unbekannte Kategorie „\(raw)“ (erlaubt: \(PrinterCategory.allCases.map(\.rawValue).joined(separator: ", "))).")
            }
            models = models.filter { $0.category == category }
        }
        if let search = context.arguments.value("search")?.lowercased() {
            models = models.filter { $0.name.lowercased().contains(search) || $0.id.contains(search) || $0.family.lowercased().contains(search) }
        }
        models.sort { ($0.category.rawValue, $0.name) < ($1.category.rawValue, $1.name) }
        if context.json {
            try Console.json(models)
            return .success
        }
        Console.table(["ID", "MODELL", "KATEGORIE", "DPI", "BREITE", "SPRACHEN", "VERBINDUNGEN"], models.map { model in
            [model.id, model.displayName, model.category.displayName,
             model.resolutions.map(String.init).joined(separator: "/"),
             "\(germanNumber(model.printWidthMM, digits: 0)) mm",
             model.languages.map(\.displayName).joined(separator: ", "),
             model.connectivity.map(\.displayName).joined(separator: ", ")]
        })
        Console.out("\n\(models.count) Modelle")
        return .success
    }

    static func stocks(_ context: Context) throws -> ExitCode {
        var stocks = ModelCatalog.shared.stocks
        if let id = context.arguments.value("model") {
            guard let model = ModelCatalog.shared.model(id: id) else {
                throw CLIError.usage("Unbekanntes Modell „\(id)“. Liste: lwctl models")
            }
            stocks = ModelCatalog.shared.stocks(fitting: model)
        }
        if context.json {
            try Console.json(stocks)
            return .success
        }
        Console.table(["ID", "NAME", "GRÖSSE", "ERKENNUNG", "KATEGORIE"], stocks.map { stock in
            [stock.id, stock.name, stock.sizeDescription, stock.tracking.displayName, stock.category.displayName]
        })
        Console.out("\n\(stocks.count) Etikettenformate")
        return .success
    }

    static func render(_ context: Context) throws -> ExitCode {
        let arguments = context.arguments
        guard let output = arguments.value("output") else {
            throw CLIError.usage("Bitte eine Zieldatei angeben: lwctl render <zpl-datei> -o out.png")
        }
        let dotsPerMM = try arguments.int("dpmm") ?? 8
        guard let resolution = Resolution(dotsPerMM: dotsPerMM) else {
            throw CLIError.usage("„--dpmm“ muss 6, 8, 12 oder 24 sein.")
        }
        let width = try arguments.int("width", in: 1...32_000) ?? resolution.dots(fromInches: 4)
        let height = try arguments.int("height", in: 1...32_000) ?? resolution.dots(fromInches: 6)
        let source = try Files.read(arguments.arguments[0])
        let zpl = String(data: source, encoding: .utf8) ?? String(source.map { Character(Unicode.Scalar($0)) })
        let document = ZPLInterpreter(dotsPerMM: dotsPerMM, defaultWidthDots: width, defaultHeightDots: height).render(zpl)
        for warning in document.warnings {
            Console.err("Hinweis: \(warning.description)")
        }
        guard !document.labels.isEmpty else {
            throw CLIError.failure("Die Datei enthält kein druckendes Etikett (^XA … ^FS … ^XZ).")
        }
        for (index, label) in document.labels.enumerated() {
            let path = Files.numberedPath(output, index: index)
            let bitmap = SoftwareRasterizer.rasterize(label)
            try Files.write(PNGCodec.encode(bitmap), to: path)
            for warning in label.warnings {
                Console.err("Hinweis (Etikett \(index + 1)): \(warning.description)")
            }
            let mm = "\(germanNumber(resolution.mm(fromDots: label.widthDots))) × \(germanNumber(resolution.mm(fromDots: label.heightDots))) mm"
            Console.out("\(path): \(label.widthDots) × \(label.heightDots) Punkte (\(mm)), \(label.elements.count) Elemente"
                        + (label.quantity > 1 ? ", Menge \(label.quantity)" : ""))
        }
        return .success
    }

    static func encode(_ context: Context) throws -> ExitCode {
        let job = try ImageJob(context: context, identity: nil)
        let images = try job.loadImages(context.arguments.arguments)
        // An Etikett anpassen (§8 „F“): nur encode – bei print legt ImageLayout die Bilder ohnehin aufs Etikett.
        var settings = job.settings
        if let raw = context.arguments.value("fit-to-label") {
            guard let mode = LabelFitMode(cupsValue: raw) else {
                throw CLIError.usage("„--fit-to-label“ erwartet auto oder off, nicht „\(raw)“.")
            }
            settings.fitToLabel = mode
        }
        if let raw = context.arguments.value("label-size") {
            guard let size = EncodeSizes.labelSize(raw) else {
                throw CLIError.usage("„--label-size“ erwartet Breite×Höhe in mm oder Zoll, z. B. 104x76.2mm oder 4x6in "
                                     + "(Breite > 0, Höhe ≥ 0), nicht „\(raw)“.")
            }
            settings.setLabelSize(widthMM: size.widthMM, heightMM: size.heightMM)
        }
        var pageSizes: [PageSizePoints?]?
        if let raw = context.arguments.value("page-size") {
            guard job.keepsImageSize else {
                throw CLIError.usage("„--page-size“ beschreibt die Bilder unverändert und braucht „--no-layout“.")
            }
            guard let sizes = EncodeSizes.pageSizes(raw) else {
                throw CLIError.usage("„--page-size“ erwartet Breite×Höhe in Punkten, z. B. 595.28x841.89 "
                                     + "(mehrere durch Komma getrennt), nicht „\(raw)“.")
            }
            guard sizes.count == 1 || sizes.count == images.count else {
                throw CLIError.usage("„--page-size“: \(sizes.count) Seitengrößen für \(images.count) Bilder "
                                     + "(erlaubt: eine für alle oder genau eine je Bild).")
            }
            pageSizes = sizes.count == 1 ? Array(repeating: sizes[0], count: images.count) : sizes
        }
        var encoder = JobEncoder(language: context.language, resolution: job.resolution, settings: settings,
                                 stock: job.stock, maxPrintWidthDots: job.maxPrintWidthDots)
        if let seconds = try context.arguments.int("fixed-time") {
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            encoder.now = { date }
        }
        if let step = try context.arguments.int("time-step", in: 0...86_400) {
            encoder.timeStepSeconds = Int64(step)
        }
        if let identifier = context.arguments.value("time-zone") {
            guard let zone = TimeZone(identifier: identifier) ?? TimeZone(abbreviation: identifier) else {
                throw CLIError.usage("Unbekannte Zeitzone „\(identifier)“ (z. B. UTC, Europe/Berlin).")
            }
            encoder.timeZone = zone
        }
        let collate = !context.arguments.has("no-collate")
        let data: Data
        if let pageSizes {
            data = try encoder.encode(images: images, pageSizes: pageSizes, copies: job.copies, collate: collate)
        } else {
            data = try encoder.encode(images: images, copies: job.copies, collate: collate)
        }
        if let output = context.arguments.value("output"), output != "-" {
            try Files.write(data, to: output)
            let first = encoder.fitted(images[0], pageSize: pageSizes?[0])
            Console.err("\(output): \(data.count) Byte \(context.language.displayName), \(images.count) Etikett(en) "
                        + "\(first.width) × \(first.height) Punkte (\(job.stock.name), \(job.resolution.dpi) dpi)")
        } else {
            Console.write(data)
        }
        return .success
    }

    static func discover(_ context: Context) async throws -> ExitCode {
        var options = PrinterDiscovery.Options()
        if let hosts = context.arguments.value("hosts") {
            options.networkHosts = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let networks = context.arguments.value("networks") {
            for entry in DiscoveryNetworks.splitList(networks) {
                if case .failure = DiscoveryNetworks.parse(entry) {
                    throw CLIError.usage("Netz „\(entry)“ nicht verstanden (z. B. 10.62.13.0/24, 10.62.13.1-10.62.13.254, 10.62.13.*).")
                }
                options.extraNetworks.append(DiscoveryNetworkEntry(entry, origin: .user))
            }
        }
        var sources = Set(DiscoverySource.allCases)
        if let raw = context.arguments.value("sources") {
            sources = []
            for name in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                guard let source = DiscoverySource.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
                    throw CLIError.usage("Unbekannte Quelle „\(name)“ (erlaubt: \(DiscoverySource.allCases.map(\.rawValue).joined(separator: ", "))).")
                }
                sources.insert(source)
            }
        }
        let timeout = context.timeout ?? .seconds(6)
        if !context.json {
            Console.err("Suche nach Druckern (\(timeout.components.seconds) s) …")
        }
        var found: [DiscoveredPrinter] = []
        for await printer in PrinterDiscovery(options: options).discover(sources: sources, timeout: timeout) {
            try Task.checkCancellation()
            // Ein späterer, genauer erkannter Fund desselben Geräts kommt mit derselben Kennung.
            if let index = found.firstIndex(where: { $0.id == printer.id }) {
                found[index] = printer
            } else {
                found.append(printer)
            }
        }
        found.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        // Standard: nur sicher als Zebra erkannte Drucker (wie in der App); `--all` zeigt alles.
        let showAll = context.arguments.has("all")
        let hidden = showAll ? 0 : found.filter { !DiscoveryFilter.isIdentifiedZebra($0) }.count
        if !showAll { found = found.filter(DiscoveryFilter.isIdentifiedZebra) }
        if context.json {
            try Console.json(found)
            return .success
        }
        if found.isEmpty {
            Console.out("Keine Zebra-Drucker gefunden.")
        } else if !showAll {
            // Ein Eintrag je Gerät (wie in der App): Zebra-Suche, Bonjour, BLE, USB und Warteschlangen
            // desselben Druckers zusammengeführt; die Drucker-URI nennt die beste Verbindung.
            let devices = DiscoveryFilter.groupDevices(found)
            Console.table(["NAME", "MODELL", "ADRESSE", "SERIENNR.", "ERREICHBAR ÜBER", "DRUCKER-URI"], devices.map { device in
                [device.title, device.displayModel, device.address ?? "–", device.serialNumber ?? "–",
                 device.paths.map(\.displayName).joined(separator: ", "), device.preferred.descriptor.uriString]
            })
        } else {
            Console.table(["NAME", "DRUCKER-URI", "QUELLE", "MODELL"], found.map { printer in
                [printer.name, printer.descriptor.uriString, printer.source.displayName,
                 printer.modelHint.flatMap { ModelCatalog.shared.match(productName: $0)?.displayName ?? $0 } ?? "–"]
            })
        }
        if hidden > 0 {
            Console.err("\(hidden) nicht als Zebra-Drucker erkannte(s) Gerät(e) ausgeblendet – anzeigen mit --all.")
        }
        return .success
    }

    static func virtualPrinter(_ context: Context) async throws -> ExitCode {
        let arguments = context.arguments
        let port = try arguments.int("port", in: 0...65_535) ?? 9100
        let modelID = arguments.value("model") ?? VirtualPrinter.defaultModelID
        guard let model = ModelCatalog.shared.model(id: modelID) else {
            throw CLIError.usage("Unbekanntes Modell „\(modelID)“. Liste: lwctl models")
        }
        let resolution: Resolution
        if let dpi = try arguments.int("dpi") {
            guard let value = Resolution(dpi: dpi) else { throw CLIError.usage("„--dpi“ muss 152, 203, 300 oder 600 sein.") }
            guard model.supportedResolutions.contains(value) else {
                throw CLIError.usage("\(model.displayName) gibt es nicht mit \(dpi) dpi (verfügbar: \(model.resolutions.map(String.init).joined(separator: ", "))).")
            }
            resolution = value
        } else {
            resolution = model.supportedResolutions.contains(.dpi203) ? .dpi203 : (model.supportedResolutions.first ?? .dpi203)
        }
        let printer = VirtualPrinter(id: arguments.value("id") ?? "demo", model: model, resolution: resolution)
        let host = arguments.value("host")
        let serial = printer.serialNumber
        do {
            try await VirtualPrinterServer.run(port: port, host: host, printer: printer) { boundPort in
                Console.out("Virtueller Drucker \(model.displayName) (\(resolution.dpi) dpi, Seriennummer \(serial)) "
                            + "bereit auf \(host ?? "0.0.0.0"):\(boundPort)")
                Console.err("Beenden mit Ctrl+C. Verbinden z. B. mit: lwctl --printer tcp://127.0.0.1:\(boundPort) status")
            }
        } catch is CancellationError {
            let labels = await printer.labelsPrinted
            Console.err("Virtueller Drucker beendet (Zählerstand \(labels) Etiketten).")
            return .success
        }
        return .success
    }
}

// MARK: - Dateien

enum Files {
    /// Liest eine Datei bzw. die Standardeingabe (`-`).
    static func read(_ path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.failure("Die Datei „\(path)“ existiert nicht.")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CLIError.failure("Die Datei „\(path)“ kann nicht gelesen werden.")
        }
        return data
    }

    static func write(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw CLIError.failure("„\(path)“ kann nicht geschrieben werden: \(error.localizedDescription)")
        }
    }

    /// `out.png`, `out-2.png`, `out-3.png` …
    static func numberedPath(_ path: String, index: Int) -> String {
        guard index > 0 else { return path }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let base = ext.isEmpty ? path : String(path.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(base)-\(index + 1)" : "\(base)-\(index + 1).\(ext)"
    }

    /// Lädt ein PNG- oder PNM-Bild.
    static func image(_ path: String) throws -> GrayImage {
        let data = try read(path)
        do {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return try PNGCodec.decode(data) }
            if data.first == 0x50, data.count > 1, (0x31...0x36).contains(data[data.startIndex + 1]) {
                return try PNMCodec.decode(data)
            }
        } catch {
            throw CLIError.failure("„\(path)“ ist beschädigt: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
        throw CLIError.failure("„\(path)“ ist kein PNG- oder PNM-Bild.")
    }
}

// MARK: - Größenangaben von encode (An Etikett anpassen)

/// Zerlegt `--label-size` und `--page-size` von `lwctl encode`.
enum EncodeSizes {
    /// `104x76.2mm`, `104 × 76,2 mm`, `4x6in` (Standard mm; Breite > 0, Höhe ≥ 0 = frei; je ≤ 1000 mm).
    static func labelSize(_ raw: String) -> (widthMM: Double, heightMM: Double)? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        var factor = 1.0
        if text.hasSuffix("mm") {
            text.removeLast(2)
        } else if text.hasSuffix("in") {
            text.removeLast(2)
            factor = 25.4
        }
        guard let (width, height) = pair(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let widthMM = width * factor, heightMM = height * factor
        guard widthMM > 0, heightMM >= 0, widthMM <= 1000, heightMM <= 1000 else { return nil }
        return (widthMM, heightMM)
    }

    /// `595.28x841.89` bzw. mehrere durch Komma oder Semikolon getrennt (Punkte, Dezimalpunkt,
    /// optional `pt`); jede Seite 0 ≤ Wert ≤ 100 000 – 0 heißt „unbekannt“ (wie ein Rasterkopf ohne
    /// Seitengröße: keine Anpassung).
    static func pageSizes(_ raw: String) -> [PageSizePoints]? {
        let items = raw.split(whereSeparator: { $0 == "," || $0 == ";" })
        guard !items.isEmpty else { return nil }
        var sizes: [PageSizePoints] = []
        for item in items {
            var text = item.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
            if text.hasSuffix("pt") { text.removeLast(2) }
            guard let (width, height) = pair(text), width >= 0, height >= 0,
                  width <= LabelFit.maxPagePoints, height <= LabelFit.maxPagePoints else { return nil }
            sizes.append(PageSizePoints(width: width, height: height))
        }
        return sizes
    }

    /// `B x H` mit `x`, `X` oder `×` als Trenner.
    private static func pair(_ text: String) -> (Double, Double)? {
        let parts = text.replacingOccurrences(of: "×", with: "x").split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite else { return nil }
        return (width, height)
    }
}

// MARK: - Bildaufträge (print, encode)

/// Gemeinsame Auswertung der Bildoptionen.
struct ImageJob {
    let settings: PrintSettings
    let resolution: Resolution
    let model: PrinterModel?
    let stock: LabelStock
    let fit: ImageLayout.FitMode
    let rotation: ImageLayout.Rotation
    let copies: Int
    /// `--no-layout`: Bilder unverändert übernehmen (keine Drehung, kein Einpassen).
    let keepsImageSize: Bool
    /// Druckbreite in Punkten (`--max-width`, sonst die des Modells); `nil` = unbegrenzt.
    let maxPrintWidthDots: Int?

    init(context: Context, identity: PrinterIdentity?) throws {
        let arguments = context.arguments
        var settings = PrintSettings()
        if let raw = arguments.value("dither") {
            guard let dither = Self.dither(raw) else {
                throw CLIError.usage("Unbekanntes Rasterverfahren „\(raw)“ (erlaubt: \(DitherAlgorithm.allCases.map(\.rawValue).joined(separator: ", "))).")
            }
            settings.dither = dither
        }
        settings.threshold = try arguments.int("threshold", in: 1...254) ?? 128
        if let raw = arguments.value("compression") {
            guard let compression = GraphicCompression(cupsValue: raw) else {
                throw CLIError.usage("Unbekannte Kompression „\(raw)“ (erlaubt: z64, acs, hex).")
            }
            settings.compression = compression
        }
        settings.darkness = try arguments.int("darkness", in: 0...30)
        settings.speed = try arguments.int("speed", in: 1...14)
        settings.negative = arguments.has("negative")
        settings.mirror = arguments.has("mirror")
        settings.rotate180 = arguments.has("rotate180")
        settings.mediaType = try Self.choice(arguments, "media-type") { (value: MediaType) in value.cupsValue }
        settings.tracking = try Self.choice(arguments, "tracking") { (value: MediaTracking) in value.cupsValue }
        settings.printMode = try Self.choice(arguments, "print-mode") { (value: PrintMode) in value.cupsValue }
        settings.labelTop = try arguments.int("label-top", in: -120...120)
        settings.labelLeft = try arguments.int("label-left", in: -9999...9999)
        settings.tearOffAdjust = try arguments.int("tear-off", in: -120...120)
        settings.backfeed = try Self.choice(arguments, "backfeed") { (value: BackfeedMode) in value.cupsValue }
        settings.cutEvery = try arguments.int("cut-every", in: 0...9999) ?? 0
        settings.calibrateBeforeJob = arguments.has("calibrate")
        settings.saveToPrinter = arguments.has("save-settings")
        settings.skipBlankLabels = arguments.has("skip-blank")
        settings.startCommands = arguments.value("start-commands") ?? ""
        settings.endCommands = arguments.value("end-commands") ?? ""
        if let raw = arguments.value("rotation") {
            guard let rotation = PrintRotation(cupsValue: raw) else {
                throw CLIError.usage("„--rotation“ erwartet 0, 90, 180 oder 270.")
            }
            settings.rotation = rotation
        }
        settings.markOffset = try arguments.int("mark-offset", in: -80...283)
        settings.stopAtLastElement = arguments.has("stop-at-last")
        settings.stopOffset = try arguments.int("stop-offset", in: 0...32_000) ?? 0
        settings.pauseEvery = try arguments.int("pause-every", in: 0...9999) ?? 0
        settings.controlCharacters = try Self.controlCharacters(arguments)
        settings.rtcUpdate = try Self.choice(arguments, "rtc") { (value: RTCUpdate) in value.cupsValue }
        settings.cancelJobsBeforePrint = arguments.has("cancel-before")
        settings.cancelDelayMs = try arguments.int("cancel-delay", in: 0...10_000) ?? 1000
        settings.labelStartCommands = arguments.value("label-start-commands") ?? ""
        settings.labelEndCommands = arguments.value("label-end-commands") ?? ""
        settings.powerUpAction = try Self.feedAction(arguments, "power-up-action")
        settings.headCloseAction = try Self.feedAction(arguments, "head-close-action")
        self.settings = settings

        if let id = arguments.value("model") {
            guard let model = ModelCatalog.shared.model(id: id) else {
                throw CLIError.usage("Unbekanntes Modell „\(id)“. Liste: lwctl models")
            }
            self.model = model
        } else {
            self.model = identity?.matchedModel
        }
        if let dpi = try arguments.int("dpi") {
            guard let resolution = Resolution(dpi: dpi) else { throw CLIError.usage("„--dpi“ muss 152, 203, 300 oder 600 sein.") }
            self.resolution = resolution
        } else {
            resolution = identity?.resolution ?? .dpi203
        }
        if let id = arguments.value("stock") {
            guard let stock = ModelCatalog.shared.stock(id: id) else {
                throw CLIError.usage("Unbekanntes Etikettenformat „\(id)“. Liste: lwctl stocks")
            }
            self.stock = stock
        } else if let id = model?.defaultStock, let stock = ModelCatalog.shared.stock(id: id) {
            self.stock = stock
        } else {
            stock = ModelCatalog.shared.stock(id: "w4h6in")
                ?? LabelStock(id: "w4h6in", name: "4 × 6 Zoll", widthMM: 101.6, heightMM: 152.4, category: .shipping, isCustom: false)
        }
        if let raw = arguments.value("fit") {
            guard let fit = ImageLayout.FitMode(rawValue: raw.lowercased()) else {
                throw CLIError.usage("Unbekannter Einpassmodus „\(raw)“ (erlaubt: contain, cover, stretch, none).")
            }
            self.fit = fit
        } else {
            fit = .contain
        }
        if let raw = arguments.value("rotate") {
            guard let rotation = ImageLayout.Rotation(argument: raw) else {
                throw CLIError.usage("„--rotate“ erwartet 0, 90, 180, 270 oder auto.")
            }
            self.rotation = rotation
        } else {
            rotation = .fixed(.r0)
        }
        copies = try arguments.int("copies", in: 1...99_999) ?? 1
        keepsImageSize = arguments.has("no-layout")
        if keepsImageSize, arguments.value("fit") != nil || arguments.value("rotate") != nil {
            throw CLIError.usage("„--no-layout“ übernimmt die Bilder unverändert und schließt „--fit“ und „--rotate“ aus.")
        }
        if let width = try arguments.int("max-width", in: 1...100_000) {
            maxPrintWidthDots = width
        } else {
            maxPrintWidthDots = model?.printWidthDots(resolution)
        }
    }

    /// Liest einen Aufzählungswert: Name wie in der Hilfe (`thermalTransfer`), CUPS-Wert
    /// (`ThermalTransfer`) oder Bezeichner (`afterPrinting`) – ohne Beachtung von Groß-/Kleinschreibung,
    /// Binde- und Unterstrichen.
    static func choice<Value: CaseIterable & RawRepresentable>(
        _ arguments: ParsedArguments, _ name: String, cupsValue: (Value) -> String
    ) throws -> Value? where Value.RawValue == String {
        guard let raw = arguments.value(name) else { return nil }
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        }
        let key = normalized(raw)
        if let match = Value.allCases.first(where: { normalized($0.rawValue) == key || normalized(cupsValue($0)) == key }) {
            return match
        }
        let allowed = Value.allCases.map { cupsValue($0) }.joined(separator: ", ")
        throw CLIError.usage("Unbekannter Wert „\(raw)“ für „--\(name)“ (erlaubt: \(allowed)).")
    }

    /// `--control-chars standard|printer` mit `--format-prefix`, `--control-prefix`, `--delimiter`
    /// (je ein Zeichen oder dezimaler ASCII-Code 33…126). Wie bei den CUPS-Optionen gelten die
    /// Zeichen nur mit `printer`; fehlende Zeichen sind die Standardzeichen.
    static func controlCharacters(_ arguments: ParsedArguments) throws -> ControlCharacters? {
        let names = ["format-prefix", "control-prefix", "delimiter"]
        var mode = arguments.value("control-chars")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "standard"
        if mode == "intern" || mode == "internal" { mode = "printer" }
        guard mode == "printer" else {
            guard mode == "standard" || mode == "default" else {
                throw CLIError.usage("„--control-chars“ erwartet standard oder printer, nicht „\(mode)“.")
            }
            for name in names where arguments.value(name) != nil {
                Console.err("Hinweis: „--\(name)“ wirkt nur mit „--control-chars printer“ und wird ignoriert.")
            }
            return nil
        }
        func character(_ name: String, _ fallback: UInt8) throws -> UInt8 {
            guard let raw = arguments.value(name) else { return fallback }
            if let code = Int(raw.trimmingCharacters(in: .whitespaces)) {
                guard let byte = UInt8(exactly: code), ControlCharacters.validRange.contains(byte) else {
                    throw CLIError.usage("„--\(name)“: ASCII-Code \(code) liegt nicht zwischen 33 und 126.")
                }
                return byte
            }
            guard let byte = ControlCharacters.character(from: raw) else {
                throw CLIError.usage("„--\(name)“ erwartet ein druckbares ASCII-Zeichen oder einen Code 33…126, nicht „\(raw)“.")
            }
            return byte
        }
        return ControlCharacters(formatPrefix: try character("format-prefix", 0x5E),
                                 controlPrefix: try character("control-prefix", 0x7E),
                                 delimiter: try character("delimiter", 0x2C))
    }

    /// `--power-up-action`/`--head-close-action`: CUPS-Wert (`ShortCal`), Name (`shortCalibration`)
    /// oder ZPL-Code (`S`).
    static func feedAction(_ arguments: ParsedArguments, _ name: String) throws -> MediaFeedAction? {
        guard let raw = arguments.value(name) else { return nil }
        if raw.count == 1, let action = MediaFeedAction(zplCode: raw) { return action }
        return try choice(arguments, name) { (value: MediaFeedAction) in value.cupsValue }
    }

    static func dither(_ raw: String) -> DitherAlgorithm? {
        let lower = raw.lowercased().replacingOccurrences(of: "-", with: "")
        if let match = DitherAlgorithm.allCases.first(where: { $0.rawValue.lowercased() == lower || $0.cupsValue.lowercased() == lower }) {
            return match
        }
        switch lower {
        case "fs", "floyd": return .floydSteinberg
        case "bayer": return .ordered
        default: return nil
        }
    }

    /// Lädt, dreht und passt alle Bilder ein (mit `--no-layout`: lädt sie unverändert; zu breite
    /// Bilder schneidet dann erst der `JobEncoder` nach der Rasterung ab – wie der CUPS-Filter).
    ///
    /// Bei einer Treiberdrehung um 90° bzw. 270° (`--rotation`) ist die Seite – wie im
    /// Druckdialog – quer: Eingepasst wird in das Etikett mit vertauschter Breite und Höhe; der
    /// `JobEncoder` dreht die Seite danach auf das Etikett zurück.
    func loadImages(_ paths: [String]) throws -> [GrayImage] {
        let landscape = settings.effectiveRotation.isQuarterTurn
        var page = stock
        if landscape {
            page.widthMM = stock.heightMM
            page.heightMM = stock.widthMM
        }
        return try paths.map { path in
            let image = try Files.image(path)
            if keepsImageSize { return image }
            return ImageLayout.layout(image, for: page, resolution: resolution, mode: fit, rotation: rotation,
                                      maxPrintWidthDots: landscape ? nil : maxPrintWidthDots)
        }
    }
}

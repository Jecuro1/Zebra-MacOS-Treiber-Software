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
        let encoder = JobEncoder(language: context.language, resolution: job.resolution, settings: job.settings,
                                 stock: job.stock, maxPrintWidthDots: job.maxPrintWidthDots)
        let data = try encoder.encode(images: images, copies: job.copies, collate: !context.arguments.has("no-collate"))
        if let output = context.arguments.value("output"), output != "-" {
            try Files.write(data, to: output)
            Console.err("\(output): \(data.count) Byte \(context.language.displayName), \(images.count) Etikett(en) "
                        + "\(images[0].width) × \(images[0].height) Punkte (\(job.stock.name), \(job.resolution.dpi) dpi)")
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
            found.append(printer)
        }
        found.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        if context.json {
            try Console.json(found)
            return .success
        }
        if found.isEmpty {
            Console.out("Keine Drucker gefunden.")
            return .success
        }
        Console.table(["NAME", "DRUCKER-URI", "QUELLE", "MODELL"], found.map { printer in
            [printer.name, printer.descriptor.uriString, printer.source.displayName,
             printer.modelHint.flatMap { ModelCatalog.shared.match(productName: $0)?.displayName ?? $0 } ?? "–"]
        })
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
    func loadImages(_ paths: [String]) throws -> [GrayImage] {
        try paths.map { path in
            let image = try Files.image(path)
            if keepsImageSize { return image }
            return ImageLayout.layout(image, for: stock, resolution: resolution, mode: fit, rotation: rotation,
                                      maxPrintWidthDots: maxPrintWidthDots)
        }
    }
}

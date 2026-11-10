import Foundation
import LabelWerkKit

/// `install`, `queues` und `uninstall-queue`: Netzwerkdrucker als macOS-/CUPS-Drucker einrichten –
/// das Gegenstück zum Windows-Installationsprogramm für IT und Softwareverteilung.
///
/// `install` verbindet sich mit dem Drucker, erkennt Modell, Auflösung und Sprache
/// (``PrinterClient/identify()``), wählt die passende LabelWerk-PPD (wie die App: Modell-PPD, sonst
/// generische PPD) und legt die Warteschlange mit `lpadmin` an. Jeder ausgeführte Befehl wird
/// angezeigt; `--dry-run` zeigt ihn nur an.
enum InstallCommands {

    /// Standardordner der LabelWerk-PPDs: auf macOS laut ARCHITECTURE.md §10, unter Linux
    /// `/usr/share/ppd/labelwerk` (z. B. befüllt mit `Driver/ppd/generate_ppds.py --gzip -o …`).
    static var defaultPPDDirectory: String {
        #if os(macOS)
        return "/Library/Printers/PPDs/Contents/Resources"
        #else
        return "/usr/share/ppd/labelwerk"
        #endif
    }

    static let lpadminFallbacks = ["/usr/sbin/lpadmin"]
    static let lpFallbacks = ["/usr/bin/lp"]

    /// Testdokumente für `--test-page` (das erste vorhandene wird gedruckt): die Testseite von
    /// macOS bzw. die CUPS-Testseite unter Linux, sonst eine kurze Textdatei.
    static let testPageCandidates = [
        "/System/Library/Frameworks/Quartz.framework/Versions/A/Frameworks/QuartzComposer.framework/Versions/A/Resources/Test.pdf",
        "/usr/share/cups/data/testprint",
    ]

    // MARK: - install

    /// Geplante Einrichtung (zugleich die JSON-Ausgabe von `install --json`).
    struct InstallPlan: Encodable {
        /// Drucker-URI wie bei `--printer`, z. B. `tcp://192.168.1.50:9100`.
        var printer: String
        /// Geräte-URI der Warteschlange, z. B. `socket://192.168.1.50:9100`.
        var deviceURI: String
        var queue: String
        var description: String
        var location: String?
        /// `true`, wenn die Warteschlange schon eingerichtet ist und aktualisiert (bzw. mit
        /// `--replace` ersetzt) wird.
        var existing: Bool
        /// `true`, wenn ohne `--name` eine vorhandene LabelWerk-Warteschlange gewählt wurde, die
        /// schon auf dieses Gerät druckt (statt den Drucker ein zweites Mal einzurichten).
        var reused: Bool
        /// Standardwerte der vorhandenen Warteschlange, die erhalten bleiben (`Option=Wert`).
        var keptSettings: [String]
        /// `true`, wenn das Modell vom Drucker erkannt wurde (`--model auto`).
        var detected: Bool
        /// Produktname, den der Drucker meldet (nur bei Erkennung).
        var detectedProduct: String?
        var serialNumber: String?
        /// Katalogkennung des Modells (`nil` bei generischer PPD ohne bekanntes Modell).
        var model: String?
        var modelName: String?
        /// Auflösung der gewählten PPD in dpi.
        var resolution: Int
        /// Druckersprache der Warteschlange (`zpl`, `epl`, `cpcl`).
        var language: String
        var ppd: String
        var genericPPD: Bool
        var stock: String?
        var pageSize: String?
        var setDefault: Bool
        var testPage: Bool
        var dryRun: Bool
        /// Alle Befehle in Ausführungsreihenfolge (Programm und Argumente).
        var commands: [[String]]
        /// Hinweise (ohne `--json` auf stderr), z. B. zur generischen PPD.
        var warnings: [String]
        /// `true`, wenn alle Befehle erfolgreich ausgeführt wurden (im Probelauf immer `false`).
        var installed: Bool
    }

    /// Gefundene PPD-Datei.
    struct PPDChoice {
        var path: String
        /// Name ohne Endung, z. B. `LabelWerk-zd421t-203dpi`.
        var name: String
        var isGeneric: Bool { name.hasPrefix("LabelWerk-generic-") }

        /// Sprache und Auflösung einer generischen PPD aus ihrem Namen
        /// (`LabelWerk-generic-<sprache>-<dpi>dpi`).
        var genericParameters: (language: PrinterLanguage, resolution: Resolution)? {
            let parts = name.split(separator: "-")
            guard isGeneric, parts.count == 4, let language = PrinterLanguage(rawValue: String(parts[2])),
                  parts[3].hasSuffix("dpi"), let dpi = Int(parts[3].dropLast(3)), let resolution = Resolution(dpi: dpi)
            else { return nil }
            return (language, resolution)
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func install(_ context: Context) async throws -> ExitCode {
        let arguments = context.arguments
        var warnings: [String] = []
        /// Hinweis auf stderr – mit `--json` stattdessen im Ergebnis (`warnings`).
        func warn(_ text: String) {
            warnings.append(text)
            if !context.json { Console.err("Hinweis: \(text)") }
        }

        // 1. Drucker: nur Netzwerk (TCP, RAW-Port).
        let environment = ProcessInfo.processInfo.environment["LWCTL_PRINTER"]
        guard let uri = (arguments.value("printer") ?? environment)?.trimmingCharacters(in: .whitespaces), !uri.isEmpty else {
            throw CLIError.usage("Kein Drucker angegeben. Beispiel: lwctl install --printer tcp://192.168.1.50")
        }
        guard let descriptor = ConnectionDescriptor(uriString: uri), case .tcp(let host, let port) = descriptor,
              isValidHost(host) else {
            if let descriptor = ConnectionDescriptor(uriString: uri), descriptor.kind != .tcp {
                throw CLIError.usage("„lwctl install“ richtet Netzwerkdrucker ein (tcp://HOST[:PORT]), nicht „\(uri)“. "
                                     + "USB-Drucker ordnet macOS selbst zu: Systemeinstellungen › Drucker & Scanner.")
            }
            throw CLIError.usage("Ungültige Drucker-URI „\(uri)“. Beispiele: tcp://192.168.1.50, tcp://192.168.1.50:9100, tcp://etiketten-1.local")
        }

        // 2. Optionen prüfen – vor jeder Verbindung.
        let rawModel = arguments.value("model")?.trimmingCharacters(in: .whitespaces) ?? "auto"
        let modelArgument = rawModel.lowercased()
        let autoDetect = modelArgument == "auto" || modelArgument.isEmpty
        let forceGeneric = modelArgument == "generic"
        var explicitModel: PrinterModel?
        if !autoDetect, !forceGeneric {
            guard let model = ModelCatalog.shared.model(id: modelArgument) else {
                throw CLIError.usage("Unbekanntes Modell „\(rawModel)“ (erlaubt: auto, generic oder eine Kennung aus „lwctl models“).")
            }
            explicitModel = model
        }
        var explicitResolution: Resolution?
        if let dpi = try arguments.int("dpi") {
            guard let resolution = Resolution(dpi: dpi) else { throw CLIError.usage("„--dpi“ muss 152, 203, 300 oder 600 sein.") }
            explicitResolution = resolution
        }
        let explicitLanguage: PrinterLanguage? = arguments.value("language") != nil ? context.language : nil
        if let explicitModel {
            try check(explicitModel, resolution: explicitResolution, language: explicitLanguage)
        }
        var stock: LabelStock?
        if let id = arguments.value("stock") {
            guard let found = ModelCatalog.shared.stock(id: id) else {
                throw CLIError.usage("Unbekanntes Etikettenformat „\(id)“. Liste: lwctl stocks")
            }
            stock = found
        }
        if let stock, let explicitModel {
            try checkStock(stock, model: explicitModel, language: explicitLanguage ?? explicitModel.defaultLanguage)
        }
        let requestedName = arguments.value("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedName, requestedName.isEmpty {
            throw CLIError.usage("„--name“ darf nicht leer sein.")
        }
        let location = arguments.value("location")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ppdDirectory = arguments.value("ppd-dir") ?? defaultPPDDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ppdDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.failure("Der PPD-Ordner „\(ppdDirectory)“ existiert nicht. Ist der LabelWerk-Treiber installiert? "
                                   + "Einen anderen Ordner gibt --ppd-dir an.")
        }
        let dryRun = arguments.has("dry-run")
        let setDefault = arguments.has("default")
        let testPage = arguments.has("test-page")
        let replace = arguments.has("replace")

        // 3. Modell, Auflösung und Sprache vom Drucker erkennen (--model auto).
        var identity: PrinterIdentity?
        if autoDetect {
            if !context.json {
                Console.err("Verbinde mit \(descriptor.displayString) und erkenne das Modell …")
            }
            let client = try await Commands.makeClient(context)
            do {
                identity = try await client.identify()
                await client.disconnect()
            } catch {
                await client.disconnect()
                if error is CancellationError { throw error }
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                throw CLIError.connection("Der Drucker \(descriptor.displayString) wurde nicht erkannt: \(reason)\n"
                                          + "Tipp: Ohne Verbindung einrichten mit --model <id> (Liste: lwctl models) oder --model generic.")
            }
        }
        let model: PrinterModel? = forceGeneric ? nil : (explicitModel ?? identity?.matchedModel)
        if autoDetect, let model {
            try check(model, resolution: explicitResolution, language: explicitLanguage)
        }
        if autoDetect, model == nil {
            warn("„\(identity?.model ?? "unbekannt")“ ist nicht im Modellkatalog – es wird eine generische PPD verwendet.")
        }
        let resolution = explicitResolution ?? identity?.resolution ?? model.map(defaultResolution(of:)) ?? .dpi203
        let language = explicitLanguage ?? model?.defaultLanguage ?? identity?.languages.first ?? .zpl

        // 4. PPD wählen (wie die App: Modell-PPD, sonst generische PPD).
        let candidates = ppdCandidates(modelID: model?.id, resolution: resolution, language: language)
        guard let ppd = findPPD(candidates, in: ppdDirectory) else {
            throw CLIError.failure("Keine passende PPD-Datei in „\(ppdDirectory)“ gefunden (gesucht: "
                                   + candidates.map { "\($0).ppd.gz" }.joined(separator: ", ") + ").\n"
                                   + "Ist der LabelWerk-Treiber installiert? Einen anderen Ordner gibt --ppd-dir an.")
        }
        let generic = ppd.genericParameters
        let queueLanguage = generic?.language ?? language
        let queueResolution = generic?.resolution ?? resolution
        // Ausdrücklich gewählte Werte nie stillschweigend ersetzen: Eine 203-dpi-PPD für einen
        // 300-dpi-Druckkopf druckt alles auf rund zwei Drittel verkleinert.
        if let explicitResolution, queueResolution != explicitResolution {
            throw CLIError.failure("Keine PPD für \(model?.displayName ?? language.displayName) mit \(explicitResolution.dpi) dpi "
                                   + "in „\(ppdDirectory)“ (nächstliegend: \(ppd.name)). Etiketten würden falsch skaliert – "
                                   + "eine andere Auflösung mit --dpi wählen oder den LabelWerk-Treiber aktualisieren.")
        }
        if let explicitLanguage, queueLanguage != explicitLanguage {
            throw CLIError.failure("Keine PPD für \(explicitLanguage.displayName) mit \(queueResolution.dpi) dpi in „\(ppdDirectory)“ "
                                   + "(nächstliegend: \(ppd.name), \(queueLanguage.displayName)). Eine andere Sprache mit --language "
                                   + "wählen oder den LabelWerk-Treiber aktualisieren.")
        }
        if let model, generic != nil {
            warn("Keine PPD für \(model.displayName) mit \(resolution.dpi) dpi gefunden – "
                 + "es wird die generische PPD \(ppd.name) verwendet.")
        }
        if queueResolution != resolution || queueLanguage != language {
            let effect = queueResolution != resolution
                ? "Etiketten werden falsch skaliert gedruckt"
                : "der Drucker muss \(queueLanguage.displayName) verstehen"
            warn("Keine PPD für \(language.displayName) mit \(resolution.dpi) dpi – es wird \(ppd.name) "
                 + "(\(queueLanguage.displayName), \(queueResolution.dpi) dpi) verwendet; \(effect).")
        }
        // Erst jetzt bekannt bei Erkennung bzw. ohne Katalogmodell (Grenzen der generischen PPD).
        if let stock, explicitModel == nil {
            try checkStock(stock, model: model, language: queueLanguage)
        }

        // 5. Warteschlange: Name, Beschreibung, Geräte-URI.
        let modelLabel = model?.displayName
            ?? identity?.model.map { "Zebra \($0)" }
            ?? "Zebra-Etikettendrucker \(queueLanguage.displayName)"
        let deviceURI = "socket://\(host.contains(":") ? "[\(host)]" : host):\(port)"
        var queue: String
        var description: String
        if let requestedName {
            queue = sanitizedQueueName(requestedName)
            description = requestedName
            if queue != requestedName {
                warn("Warteschlangenname „\(requestedName)“ → „\(queue)“ (CUPS erlaubt keine Leer- und Sonderzeichen).")
            }
        } else {
            let base = model?.name ?? identity?.model ?? queueLanguage.rawValue.uppercased()
            queue = sanitizedQueueName("Zebra_\(base)_\(host)")
            description = "\(modelLabel) (\(host))"
        }

        // Vorhandene Warteschlangen (auch im Probelauf): Druckt schon eine LabelWerk-Warteschlange auf
        // dieses Gerät (etwa vom Assistenten der App), wird sie aktualisiert – sonst stünde derselbe
        // Drucker zweimal in jedem Druckdialog. Eine Warteschlange gleichen Namens (CUPS unterscheidet
        // keine Groß-/Kleinschreibung) wird nur aktualisiert, wenn sie LabelWerk-Warteschlange
        // desselben Geräts ist; jede andere nur mit --replace.
        let installedQueues = await CUPSQueues.list()
        var reused = false
        if requestedName == nil {
            let sameDevice = installedQueues.filter { CUPSQueues.isSameDevice($0.deviceURI, deviceURI) && isLabelWerkQueue($0) }
            if let same = sameDevice.first(where: { $0.name.caseInsensitiveCompare(queue) == .orderedSame }) ?? sameDevice.first {
                if same.name.caseInsensitiveCompare(queue) != .orderedSame {
                    warn("„\(same.name)“ druckt bereits auf \(deviceURI) – diese Warteschlange wird aktualisiert "
                         + "(eine weitere legt --name an).")
                }
                queue = same.name
                description = same.description ?? description
                reused = true
            }
        }
        let existing = installedQueues.first { $0.name.caseInsensitiveCompare(queue) == .orderedSame }
        var keptSettings: [String] = []
        if let existing {
            let isLabelWerk = isLabelWerkQueue(existing)
            if !(isLabelWerk && CUPSQueues.isSameDevice(existing.deviceURI, deviceURI)) {
                let driver = isLabelWerk ? "LabelWerk-Treiber" : (existing.makeAndModel ?? "anderer Treiber")
                guard replace else {
                    throw CLIError.failure("Die Warteschlange „\(existing.name)“ gibt es bereits (\(existing.deviceURI), \(driver)). "
                                           + "Einen anderen Namen mit --name wählen oder sie mit --replace ersetzen.")
                }
                warn("Die vorhandene Warteschlange „\(existing.name)“ (\(existing.deviceURI), \(driver)) wird ersetzt.")
            }
            queue = existing.name
            // „lpadmin -P“ setzt alle Standardwerte auf die der neuen PPD zurück. Die bisherigen
            // (Schwärzung, Geschwindigkeit, Etikett …) gehen deshalb mit „-o“ in denselben Aufruf –
            // wie beim Update im postinstall des Treibers. Werte, die die neue PPD nicht kennt,
            // verwirft lpadmin. Ausdrücklich gewählte Werte und die Auflösung (sie steckt in der PPD)
            // bleiben außen vor; eine fremde PPD liefert keine passenden Werte.
            if isLabelWerk {
                if let text = CUPSQueues.ppdText(ofQueue: existing.name), text.contains("*lwModel:") {
                    var excluded: Set<String> = ["Resolution"]
                    if stock != nil { excluded.formUnion(["PageSize", "PageRegion"]) }
                    if explicitLanguage != nil || generic != nil { excluded.insert("lwLanguage") }
                    keptSettings = CUPSQueues.ppdDefaults(text)
                        .filter { !excluded.contains($0.option) }
                        .map { "\($0.option)=\($0.value)" }
                } else {
                    warn("Die bisherigen Einstellungen von „\(existing.name)“ sind nicht lesbar "
                         + "(\(CUPSQueues.ppdPath(ofQueue: existing.name) ?? "PPD")) – es gelten die Standardwerte der neuen PPD.")
                }
            }
        }

        // 6. Befehle.
        let lpadmin = ToolRunner.locate("lpadmin", fallbacks: lpadminFallbacks)
        var queueArguments = ["-p", queue, "-E", "-v", deviceURI, "-P", ppd.path, "-D", description]
        if let location, !location.isEmpty { queueArguments += ["-L", location] }
        // Neue Warteschlangen werden nicht freigegeben; bei vorhandenen bleibt die Freigabe, wie sie ist.
        if existing == nil { queueArguments += ["-o", "printer-is-shared=false"] }
        for setting in keptSettings { queueArguments += ["-o", setting] }
        if let stock { queueArguments += ["-o", "PageSize=\(stock.ppdKeyword)"] }
        if let explicitLanguage, generic == nil { queueArguments += ["-o", "lwLanguage=\(explicitLanguage.cupsValue)"] }
        var commands: [[String]] = [[lpadmin] + queueArguments]
        if setDefault { commands.append([lpadmin, "-d", queue]) }
        var temporaryTestPage: String?
        if testPage {
            let document: String
            if let found = testPageCandidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }) {
                document = found
            } else {
                document = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LabelWerk-Testseite-\(UUID().uuidString.prefix(8)).txt").path
                temporaryTestPage = document
            }
            commands.append([ToolRunner.locate("lp", fallbacks: lpFallbacks), "-d", queue, "-t", "LabelWerk-Testseite", document])
        }

        var plan = InstallPlan(
            printer: descriptor.uriString, deviceURI: deviceURI, queue: queue, description: description,
            location: (location?.isEmpty ?? true) ? nil : location, existing: existing != nil, reused: reused,
            keptSettings: keptSettings, detected: autoDetect,
            detectedProduct: identity?.model, serialNumber: identity?.serialNumber,
            model: model?.id, modelName: model?.displayName, resolution: queueResolution.dpi,
            language: queueLanguage.rawValue, ppd: ppd.path, genericPPD: generic != nil,
            stock: stock?.id, pageSize: stock?.ppdKeyword, setDefault: setDefault, testPage: testPage,
            dryRun: dryRun, commands: commands, warnings: warnings, installed: false)

        if !context.json {
            Console.field("Drucker", descriptor.uriString)
            if let identity {
                var detected = identity.model ?? "unbekanntes Modell"
                if let serial = identity.serialNumber { detected += ", Seriennummer \(serial)" }
                if let firmware = identity.firmware { detected += ", Firmware \(firmware)" }
                Console.field("Erkannt", detected)
            }
            Console.field("Modell", model.map { "\($0.displayName) (\($0.id))" } ?? "generisch")
            Console.field("Auflösung", "\(queueResolution.dpi) dpi")
            Console.field("Sprache", queueLanguage.displayName)
            Console.field("PPD", ppd.path + (generic != nil ? " (generisch)" : ""))
            Console.field("Warteschlange", queue + (existing != nil ? " (vorhanden – wird aktualisiert)" : ""))
            Console.field("Beschreibung", description)
            Console.field("Standort", plan.location)
            Console.field("Etikett", stock.map { "\($0.name) (PageSize \($0.ppdKeyword))" })
            Console.field("Geräte-URI", deviceURI)
            Console.field("Beibehalten", keptSettings.isEmpty ? nil
                          : "\(keptSettings.count) Einstellungen der bisherigen Warteschlange (-o im Befehl unten)")
            Console.out()
        }

        // 7. Ausführen (bzw. im Probelauf nur anzeigen).
        defer {
            if let temporaryTestPage { try? FileManager.default.removeItem(atPath: temporaryTestPage) }
        }
        for (index, command) in commands.enumerated() {
            if !context.json { Console.out("$ " + shellLine(command)) }
            if dryRun { continue }
            if let temporaryTestPage, command.last == temporaryTestPage {
                let text = "LabelWerk – Testseite\n\nWarteschlange: \(queue)\nDrucker: \(deviceURI)\nPPD: \(ppd.name)\n"
                try Files.write(Data(text.utf8), to: temporaryTestPage)
            }
            let result = try await ToolRunner.run(command[0], Array(command.dropFirst()))
            guard result.status == 0 else {
                let hint: String?
                if index > 0 {
                    hint = "Die Warteschlange „\(queue)“ wurde eingerichtet; nur dieser Schritt ist fehlgeschlagen."
                } else if ToolRunner.isPermissionProblem(result.output) {
                    hint = "Tipp: Das Einrichten erfordert Administratorrechte – mit „sudo lwctl install …“ erneut ausführen."
                } else {
                    hint = nil
                }
                throw failure(command, result, hint: hint)
            }
            relay(result.output)
        }

        if dryRun {
            if !context.json {
                Console.out("\nProbelauf – es wurde nichts eingerichtet. Ohne --dry-run wird die Warteschlange "
                            + (existing != nil ? "aktualisiert." : "angelegt."))
            }
        } else {
            plan.installed = true
            if !context.json {
                Console.out("\nFertig: „\(queue)“ ist \(existing != nil ? "aktualisiert" : "eingerichtet") und steht in jedem Druckdialog bereit"
                            + " (macOS: Systemeinstellungen › Drucker & Scanner).")
                if setDefault { Console.out("„\(queue)“ ist jetzt der Standarddrucker.") }
                if testPage { Console.out("Die Testseite wurde an „\(queue)“ gesendet.") }
            }
        }
        if context.json { try Console.json(plan) }
        return .success
    }

    /// Prüft ausdrücklich gewählte Auflösung und Sprache gegen ein Katalogmodell.
    static func check(_ model: PrinterModel, resolution: Resolution?, language: PrinterLanguage?) throws {
        if let resolution, !model.supportedResolutions.contains(resolution) {
            throw CLIError.usage("\(model.displayName) gibt es nicht mit \(resolution.dpi) dpi "
                                 + "(verfügbar: \(model.resolutions.map(String.init).joined(separator: ", "))).")
        }
        if let language, !model.languages.contains(language) {
            throw CLIError.usage("\(model.displayName) unterstützt \(language.displayName) nicht "
                                 + "(verfügbar: \(model.languages.map(\.displayName).joined(separator: ", "))).")
        }
    }

    /// Passt das Etikett auf den Drucker? Die PPDs bieten nur passende Formate an (Breite höchstens
    /// Druckbreite + 2 mm, Länge höchstens die größte Etikettenlänge, dazu das Standardformat des
    /// Modells – wie `ModelCatalog.stocks(fitting:)` und `generate_ppds.py`); einen anderen
    /// `PageSize`-Wert verwirft lpadmin stillschweigend. Ohne Katalogmodell gelten die Grenzen der
    /// generischen PPD der Sprache (das größte Modell mit dieser Sprache).
    static func checkStock(_ stock: LabelStock, model: PrinterModel?, language: PrinterLanguage) throws {
        let width: Double
        let length: Double
        let printer: String
        if let model {
            if stock.id == model.defaultStock { return }
            width = model.printWidthMM
            length = model.maxLabelLengthMM
            printer = model.displayName
        } else {
            let models = ModelCatalog.shared.models.filter { $0.languages.contains(language) }
            guard let widest = models.map(\.printWidthMM).max(), let longest = models.map(\.maxLabelLengthMM).max() else { return }
            width = widest
            length = longest
            printer = "die generische \(language.displayName)-PPD"
        }
        guard stock.widthMM > width + 2 || stock.heightMM > length else { return }
        let list = model.map { "lwctl stocks --model \($0.id)" } ?? "lwctl stocks"
        throw CLIError.usage("„\(stock.name)“ (\(millimeters(stock.widthMM)) × \(millimeters(stock.heightMM)) mm) passt nicht auf \(printer) "
                             + "(Druckbreite \(millimeters(width)) mm, Etiketten bis \(millimeters(length)) mm lang). "
                             + "Passende Formate: \(list)")
    }

    /// Millimeter ohne überflüssige Nachkommastellen, z. B. `56` oder `53,5`.
    static func millimeters(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Standardauflösung eines Modells: 203 dpi, sonst die erste verfügbare.
    static func defaultResolution(of model: PrinterModel) -> Resolution {
        model.supportedResolutions.contains(.dpi203) ? .dpi203 : (model.supportedResolutions.first ?? .dpi203)
    }

    /// PPD-Namen in der Reihenfolge, in der auch die App sucht (`CUPSService.ppdURL`).
    static func ppdCandidates(modelID: String?, resolution: Resolution, language: PrinterLanguage) -> [String] {
        var names: [String] = []
        func add(_ name: String) {
            if !names.contains(name) { names.append(name) }
        }
        if let modelID { add("LabelWerk-\(modelID)-\(resolution.dpi)dpi") }
        add("LabelWerk-generic-\(language.rawValue)-\(resolution.dpi)dpi")
        add("LabelWerk-generic-\(language.rawValue)-203dpi")
        add("LabelWerk-generic-zpl-\(resolution.dpi)dpi")
        return names
    }

    /// Erste vorhandene PPD (`.ppd.gz` vor `.ppd`).
    static func findPPD(_ names: [String], in directory: String) -> PPDChoice? {
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        for name in names {
            for ext in ["ppd.gz", "ppd"] {
                let path = base.appendingPathComponent("\(name).\(ext)").path
                if FileManager.default.isReadableFile(atPath: path) { return PPDChoice(path: path, name: name) }
            }
        }
        return nil
    }

    /// Gültiger CUPS-Warteschlangenname – derselbe Algorithmus wie in der App
    /// (`CUPSService.sanitizedQueueName`): keine Leer-, Schräg- oder #-Zeichen, höchstens 127 Zeichen.
    static func sanitizedQueueName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        var result = ""
        for scalar in name.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_DE")).unicodeScalars {
            result.unicodeScalars.append(allowed.contains(scalar) ? scalar : "_")
        }
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((result.isEmpty ? "LabelWerk" : result).prefix(127))
    }

    /// Hostname, IPv4- oder IPv6-Adresse ohne Zeichen, die in einer Geräte-URI stören würden.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-._:".unicodeScalars.contains(scalar))
        }
    }

    // MARK: - queues

    /// Eine Warteschlange in der Ausgabe von `queues`.
    struct QueueEntry: Encodable {
        var name: String
        var deviceURI: String
        var isDefault: Bool
        var makeAndModel: String?
        /// `true`, wenn die Warteschlange den LabelWerk-Treiber verwendet.
        var labelWerk: Bool
    }

    static func queues(_ context: Context) async throws -> ExitCode {
        var entries = await CUPSQueues.list().map { queue in
            QueueEntry(name: queue.name, deviceURI: queue.deviceURI, isDefault: queue.info.isDefault,
                       makeAndModel: queue.makeAndModel, labelWerk: isLabelWerkQueue(queue))
        }
        if context.arguments.has("labelwerk") { entries = entries.filter(\.labelWerk) }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if context.json {
            try Console.json(entries)
            return .success
        }
        if entries.isEmpty {
            Console.out(context.arguments.has("labelwerk")
                        ? "Keine Warteschlange mit LabelWerk-Treiber eingerichtet. Einrichten: lwctl install --printer tcp://<adresse>"
                        : "Keine Druckerwarteschlangen gefunden (keine eingerichtet, oder der Druckdienst CUPS läuft nicht).")
            return .success
        }
        Console.table(["NAME", "LABELWERK", "STANDARD", "GERÄTE-URI", "TREIBER"], entries.map { entry in
            [entry.name, entry.labelWerk ? "✓" : "–", entry.isDefault ? "✓" : "", entry.deviceURI, entry.makeAndModel ?? "–"]
        })
        let labelWerk = entries.filter(\.labelWerk).count
        Console.out("\n\(entries.count) Warteschlange\(entries.count == 1 ? "" : "n"), davon \(labelWerk) mit LabelWerk-Treiber")
        return .success
    }

    /// Verwendet die Warteschlange den LabelWerk-Treiber? (Treiberbezeichnung bzw. `*lwModel` in
    /// der PPD der Warteschlange – wie die App.)
    static func isLabelWerkQueue(_ queue: CUPSQueues.Queue) -> Bool {
        if queue.makeAndModel?.localizedCaseInsensitiveContains("LabelWerk") == true { return true }
        return CUPSQueues.ppdText(ofQueue: queue.name)?.contains("*lwModel:") == true
    }

    // MARK: - uninstall-queue

    /// JSON-Ausgabe von `uninstall-queue --json`.
    struct RemovalResult: Encodable {
        var queue: String
        var command: [String]
        var dryRun: Bool
        var removed: Bool
    }

    static func uninstallQueue(_ context: Context) async throws -> ExitCode {
        let name = context.arguments.arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CLIError.usage("Bitte den Namen der Warteschlange angeben (Liste: lwctl queues).")
        }
        let dryRun = context.arguments.has("dry-run")
        // Läuft CUPS nicht, ist die Liste leer – dann entscheidet lpadmin.
        let known = await CUPSQueues.list()
        let match = known.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let match, !isLabelWerkQueue(match), !context.arguments.has("force") {
            throw CLIError.failure("Die Warteschlange „\(match.name)“ verwendet nicht den LabelWerk-Treiber. "
                                   + "Zum Entfernen trotzdem --force angeben.")
        }
        if match == nil, !known.isEmpty {
            if !dryRun {
                throw CLIError.failure("Die Warteschlange „\(name)“ ist nicht eingerichtet. Liste: lwctl queues")
            }
            Console.err("Hinweis: Die Warteschlange „\(name)“ ist derzeit nicht eingerichtet.")
        }
        let queue = match?.name ?? name
        let command = [ToolRunner.locate("lpadmin", fallbacks: lpadminFallbacks), "-x", queue]
        if !context.json { Console.out("$ " + shellLine(command)) }
        var removed = false
        if !dryRun {
            let result = try await ToolRunner.run(command[0], Array(command.dropFirst()))
            guard result.status == 0 else {
                throw failure(command, result, hint: ToolRunner.isPermissionProblem(result.output)
                    ? "Tipp: Das Entfernen erfordert Administratorrechte – mit „sudo lwctl uninstall-queue …“ erneut ausführen."
                    : nil)
            }
            relay(result.output)
            removed = true
        }
        if context.json {
            try Console.json(RemovalResult(queue: queue, command: command, dryRun: dryRun, removed: removed))
        } else {
            Console.out(dryRun ? "Probelauf – es wurde nichts entfernt." : "Warteschlange „\(queue)“ entfernt.")
        }
        return .success
    }

    // MARK: - Ausgabe

    /// Befehlszeile zum Kopieren in eine Shell (Argumente bei Bedarf in einfachen Anführungszeichen).
    static func shellLine(_ command: [String]) -> String {
        command.map(shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fehler eines Hilfsprogramms mit seiner Ausgabe (der Befehl selbst steht schon über `$ …`).
    static func failure(_ command: [String], _ result: ToolRunner.Result, hint: String?) -> CLIError {
        let tool = URL(fileURLWithPath: command[0]).lastPathComponent
        var message = "\(tool) ist fehlgeschlagen (Rückgabewert \(result.status))"
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        message += output.isEmpty ? "." : ":\n" + output
        if let hint { message += "\n" + hint }
        return .failure(message)
    }

    /// Gibt die Ausgabe eines Hilfsprogramms auf stderr weiter – ohne den Hinweis von CUPS, dass
    /// PPD-Treiber als veraltet gelten (macOS unterstützt sie weiterhin vollständig).
    static func relay(_ output: String) {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            if lower.contains("deprecated") || lower.contains("veraltet") { continue }
            Console.err("  \(text)")
        }
    }
}

// MARK: - Hilfsprogramme

/// Startet `lpadmin` und `lp`: gesucht zuerst in `$PATH` (wie die Shell), dann an den üblichen
/// Systempfaden.
enum ToolRunner {
    struct Result: Sendable {
        var status: Int32
        /// Standardausgabe und Fehlerausgabe in Reihenfolge.
        var output: String
    }

    static func locate(_ name: String, fallbacks: [String]) -> String {
        let fileManager = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return fallbacks.first { fileManager.isExecutableFile(atPath: $0) } ?? fallbacks.first ?? name
    }

    /// Prozess zum Beenden nach Zeitablauf (wird nur über `terminate()` angesprochen).
    private final class ProcessHandle: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Führt ein Programm aus (auf einem eigenen Thread) und wartet auf sein Ende.
    ///
    /// - Parameters:
    ///   - environment: Umgebung des Programms (Standard: die von lwctl).
    ///   - includeErrors: Fehlerausgabe mit in `output` (sonst verworfen).
    ///   - timeout: Sekunden bis zum Abbruch (Standard: unbegrenzt).
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    includeErrors: Bool = true, timeout: TimeInterval? = nil) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CLIError.failure("„\(executable)“ wurde nicht gefunden. Ist CUPS installiert?")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = includeErrors ? pipe : FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CLIError.failure(
                        "„\(executable)“ konnte nicht gestartet werden: \(error.localizedDescription)"))
                    return
                }
                if let timeout {
                    let handle = ProcessHandle(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if handle.process.isRunning { handle.process.terminate() }
                    }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Meldet `lpadmin` fehlende Rechte (englisch oder deutsch)?
    static func isPermissionProblem(_ output: String) -> Bool {
        let lower = output.lowercased()
        return ["forbidden", "not authorized", "unauthorized", "nicht autorisiert", "verboten", "permission denied"]
            .contains { lower.contains($0) }
    }
}

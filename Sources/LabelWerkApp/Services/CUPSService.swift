import Foundation
import LabelWerkKit

/// Verwaltung der macOS-Druckerwarteschlangen (CUPS) über `lpadmin`, `lpstat`, `lpoptions`, `lpinfo`.
///
/// Administratoren dürfen Warteschlangen auf macOS ohne Passwort anlegen (Gruppe `_lpadmin`).
/// Schlägt das mit „Forbidden“ fehl, wird automatisch mit Administratorrechten wiederholt.
enum CUPSService {
    static let lpadmin = "/usr/sbin/lpadmin"
    static let lpinfo = "/usr/sbin/lpinfo"
    static let lpoptions = "/usr/bin/lpoptions"
    static let lpstat = "/usr/bin/lpstat"
    static let cupsenable = "/usr/sbin/cupsenable"
    static let cupsaccept = "/usr/sbin/cupsaccept"

    /// Installationsorte gemäß ARCHITECTURE.md §10.
    static let driverRoot = URL(fileURLWithPath: "/Library/Printers/LabelWerk")
    static let ppdDirectory = URL(fileURLWithPath: "/Library/Printers/PPDs/Contents/Resources")

    enum CUPSError: LocalizedError {
        case driverNotInstalled
        case noPPD(String)
        case noDeviceURI
        case ambiguousUSBDevice
        case invalidQueueName
        case optionsNotApplied([String])

        var errorDescription: String? {
            switch self {
            case .driverNotInstalled:
                return tr("Der LabelWerk-Treiber ist nicht installiert. Bitte zuerst unter „Treiber“ installieren.")
            case .noPPD(let model):
                return tr("Für „%@“ wurde keine passende PPD-Datei gefunden.", model)
            case .noDeviceURI:
                return tr("Für diese Verbindung kann keine macOS-Warteschlange eingerichtet werden.")
            case .ambiguousUSBDevice:
                return tr("Mehrere Zebra-Drucker sind per USB angeschlossen, und dieser lässt sich keinem eindeutig zuordnen. Bitte nur den gewünschten Drucker anschließen und erneut versuchen.")
            case .invalidQueueName:
                return tr("Ungültiger Warteschlangenname.")
            case .optionsNotApplied(let names):
                return tr("Die Warteschlange hat diese Einstellungen nicht übernommen: %@", names.joined(separator: ", "))
            }
        }
    }

    // MARK: Abfragen

    /// Alle eingerichteten Warteschlangen.
    static func queues() async -> [CUPSQueueInfo] {
        await Task.detached(priority: .utility) { CUPSQueueLister.queues() }.value
    }

    /// Warteschlangen, die den LabelWerk-Treiber verwenden (anhand der PPD-Attribute).
    static func labelWerkQueues() async -> [CUPSQueueInfo] {
        let all = await queues()
        var result: [CUPSQueueInfo] = []
        for queue in all {
            let ppd = URL(fileURLWithPath: "/etc/cups/ppd/\(queue.name).ppd")
            if let text = try? String(contentsOf: ppd, encoding: .isoLatin1), text.contains("*lwModel:") {
                result.append(queue)
            } else if queue.makeAndModel?.contains("LabelWerk") == true {
                result.append(queue)
            }
        }
        return result
    }

    /// Von CUPS erkannte Geräte-URIs (z. B. USB-Drucker), gefiltert auf Zebra.
    static func zebraDeviceURIs() async -> [String] {
        guard let result = try? await ProcessRunner.run(lpinfo, ["-v"]) else { return [] }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let uri = String(parts[1])
                let lower = uri.lowercased()
                return (lower.contains("zebra") || lower.contains("ztc")) ? uri : nil
            }
    }

    /// Ist der Treiber installiert?
    static var isDriverInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: driverRoot.appendingPathComponent("Filter/rastertolabelwerk").path)
    }

    static var installedDriverVersion: String? {
        try? String(contentsOf: driverRoot.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pfad der PPD für Modell & Auflösung (fällt auf generische PPDs zurück).
    static func ppdURL(modelID: String?, resolution: Resolution, language: PrinterLanguage) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let modelID {
            candidates.append("LabelWerk-\(modelID)-\(resolution.dpi)dpi")
        }
        candidates.append("LabelWerk-generic-\(language.rawValue)-\(resolution.dpi)dpi")
        candidates.append("LabelWerk-generic-\(language.rawValue)-203dpi")
        candidates.append("LabelWerk-generic-zpl-\(resolution.dpi)dpi")
        for name in candidates {
            for ext in ["ppd.gz", "ppd"] {
                let url = ppdDirectory.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Geräte-URI für eine LabelWerk-Verbindung.
    ///
    /// - Throws: `CUPSError.ambiguousUSBDevice`, wenn mehrere Zebra-USB-Drucker angeschlossen sind
    ///   und keiner eindeutig zu Seriennummer bzw. Modell passt.
    static func deviceURI(for descriptor: ConnectionDescriptor) async throws -> String? {
        switch descriptor {
        case .tcp(let host, let port):
            return socketURI(host: host, port: port)
        case .usb(let usb):
            // Von CUPS gemeldete USB-URI (z. B. `usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=…`).
            let uris = await zebraDeviceURIs().filter { $0.hasPrefix("usb://") }
            return try matchUSBDeviceURI(uris, serialNumber: usb.serialNumber, productName: usb.productName)
        case .cupsQueue, .bluetooth, .ble, .virtual:
            return nil
        }
    }

    /// `socket://`-URI eines Netzwerkdruckers. IPv6-Adressen stehen in eckigen Klammern, eine
    /// Zonenangabe als `%25` (`socket://[fe80::1%25en0]:9100`) – sonst wäre die URI ungültig.
    static func socketURI(host: String, port: Int) -> String {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard bare.contains(":") else { return "socket://\(bare):\(port)" }
        let zoneEncoded = bare.replacingOccurrences(of: "%25", with: "%").replacingOccurrences(of: "%", with: "%25")
        return "socket://[\(zoneEncoded)]:\(port)"
    }

    /// Wählt die USB-URI dieses Druckers: über die Seriennummer, sonst über das Modell. Mit nur
    /// einem angeschlossenen Zebra-Drucker gilt dessen URI.
    static func matchUSBDeviceURI(_ uris: [String], serialNumber: String?, productName: String?) throws -> String? {
        guard !uris.isEmpty else { return nil }
        func decoded(_ uri: String) -> String { uri.removingPercentEncoding ?? uri }
        func querySerial(_ uri: String) -> String? {
            URLComponents(string: uri)?.queryItems?.first { $0.name.lowercased() == "serial" }?.value
        }
        if let serial = serialNumber?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
            let exact = uris.filter { querySerial($0)?.caseInsensitiveCompare(serial) == .orderedSame }
            if exact.count == 1 { return exact[0] }
            let loose = uris.filter { decoded($0).range(of: serial, options: .caseInsensitive) != nil }
            if loose.count == 1 { return loose[0] }
        }
        if uris.count == 1 { return uris[0] }
        if let product = productName?.trimmingCharacters(in: .whitespaces), !product.isEmpty {
            let matches = uris.filter { decoded($0).range(of: product, options: .caseInsensitive) != nil }
            if matches.count == 1 { return matches[0] }
        }
        throw CUPSError.ambiguousUSBDevice
    }

    /// Erzeugt einen gültigen CUPS-Warteschlangennamen (keine Leer-, Schräg- oder #-Zeichen).
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

    // MARK: Einrichten & Ändern

    /// Legt eine Warteschlange für den Drucker an und überträgt die Treiber-Standardwerte.
    @discardableResult
    static func installQueue(for printer: SavedPrinter, queueName: String? = nil) async throws -> String {
        guard isDriverInstalled else { throw CUPSError.driverNotInstalled }
        guard let uri = try await deviceURI(for: printer.descriptor) else { throw CUPSError.noDeviceURI }
        guard let ppd = ppdURL(modelID: printer.modelID, resolution: printer.resolution, language: printer.language) else {
            throw CUPSError.noPPD(printer.name)
        }
        // Eine vorhandene Warteschlange behält ihren Namen, auch wenn `sanitizedQueueName` ihn
        // umschreiben würde (z. B. „Büro_Zebra“) – sonst entstünde neben ihr eine zweite.
        let requested = queueName ?? printer.name
        let existing = await queues()
        let name = existing.contains { $0.name == requested } ? requested : sanitizedQueueName(requested)
        // `-R` wirkt sofort und nur auf vorhandene Warteschlangen: Veraltete Standards nur dann entfernen.
        let exists = existing.contains { $0.name == name }
        let plan = defaultsPlan(settings: printer.settings, language: printer.language, removingStale: exists,
                                resolution: printer.resolution)
        var args = ["-p", name, "-E", "-v", uri, "-P", ppd.path,
                    "-D", printer.name, "-o", "printer-is-shared=false"]
        if !printer.location.isEmpty { args += ["-L", printer.location] }
        if let stock = ModelCatalog.shared.stock(id: printer.stockID) {
            args += ["-o", "PageSize=\(stock.ppdKeyword)"]
        }
        args += plan.arguments
        try await runLpadmin(args)
        // Die Warteschlange steht; abweichende Optionen lassen sich unter „Druckeinstellungen“ erneut übertragen.
        let mismatched = await mismatchedOptions(queue: name, plan: plan)
        if !mismatched.isEmpty {
            NSLog("LabelWerk: Warteschlange %@ hat Optionen nicht übernommen: %@", name, mismatched.joined(separator: ", "))
        }
        return name
    }

    /// Überträgt Druckeinstellungen als Standardwerte der Warteschlange (wirkt für alle Programme)
    /// und prüft sie anschließend mit `lpoptions`.
    ///
    /// - Returns: Titel der Einstellungen, deren Wert nicht in der Auswahl der PPD liegt. Sie gelten
    ///   als Warteschlangen-Standard exakt; Druckdialoge bieten dafür nur den nächstliegenden Wert an.
    /// - Throws: `CUPSError.optionsNotApplied`, wenn die Warteschlange Werte nicht übernommen hat.
    @discardableResult
    static func setDefaults(queue: String, settings: PrintSettings, stock: LabelStock?,
                            language: PrinterLanguage?, resolution: Resolution? = nil) async throws -> [String] {
        let plan = defaultsPlan(settings: settings, language: language, removingStale: true, resolution: resolution)
        var args = ["-p", queue] + plan.arguments
        if let stock { args += ["-o", "PageSize=\(stock.ppdKeyword)"] }
        try await runLpadmin(args)
        let mismatched = await mismatchedOptions(queue: queue, plan: plan)
        guard mismatched.isEmpty else { throw CUPSError.optionsNotApplied(mismatched) }
        return plan.approximated.map(optionTitle)
    }

    // MARK: Standardwerte abbilden

    /// Auswahlwerte der ganzzahligen PPD-Optionen (Driver/ppd/README.md). `lpadmin -o name=wert`
    /// übernimmt nur PPD-Schlüsselwörter mit einem Wert aus ihrer Auswahl – andere Werte verwirft es
    /// stillschweigend.
    static let ppdIntegerChoices: [String: [Int]] = [
        CUPSOptionName.darkness: Array(1...30),
        CUPSOptionName.labelTop: Array(stride(from: -120, through: 120, by: 10)),
        CUPSOptionName.tearOff: Array(stride(from: -120, through: 120, by: 10)),
        CUPSOptionName.labelLeft: Array(stride(from: -200, through: 200, by: 10)),
        CUPSOptionName.threshold: [64, 96, 128, 160, 192],
        CUPSOptionName.cutEvery: [0, 1, 2, 5, 10, 25, 50, 100],
        CUPSOptionName.pauseEvery: [0, 1, 2, 5, 10, 25, 50, 100],
        CUPSOptionName.cancelDelay: [0, 250, 500, 1000, 2000, 3000, 5000, 10000],
    ]

    /// Ganzzahlige PPD-Optionen, deren Auswahl Millimeter in Punkten der Auflösung sind
    /// (Driver/ppd/generate_ppds.py: `MARK_OFFSET_MM`, `STOP_OFFSET_MM`).
    static let ppdMillimetreChoices: [String: (millimetres: [Int], range: ClosedRange<Int>)] = [
        CUPSOptionName.markOffset: ([-10, -5, -3, -2, -1, 0, 1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 35], -80...283),
        CUPSOptionName.stopOffset: ([0, 1, 2, 3, 5, 10], 0...32_000),
    ]

    /// Auswahl einer ganzzahligen PPD-Option für die Auflösung (`nil` = keine Ganzzahl-Option bzw.
    /// Auflösung unbekannt bei auflösungsabhängigen Optionen).
    static func ppdChoices(_ name: String, resolution: Resolution?) -> [Int]? {
        if let fixed = ppdIntegerChoices[name] { return fixed }
        guard let resolution, let spec = ppdMillimetreChoices[name] else { return nil }
        var seen = Set<Int>()
        return spec.millimetres.compactMap { mm -> Int? in
            let dots = resolution.dots(fromMM: Double(mm))
            guard spec.range.contains(dots), seen.insert(dots).inserted else { return nil }
            return dots
        }
    }

    /// Optionen ohne PPD-Eintrag (freie Base64url-Werte, eigene Steuerzeichen und das veraltete
    /// `lwRotate180`): nur als Warteschlangen-Standard möglich.
    static let queueOnlyOptions: Set<String> = Set(CUPSOptionName.nonPPD)

    /// `lpadmin`-Argumente für die Treiber-Standardwerte und die danach erwarteten Werte.
    struct DefaultsPlan: Equatable {
        var arguments: [String] = []
        /// Erwarteter Wert je Option (wie ihn `currentOptions` liefert).
        var expected: [String: String] = [:]
        /// Optionen, die als Warteschlangen-Standard (`name-default`) gesetzt werden.
        var queueDefaults: Set<String> = []
        /// Optionen, die nicht gesetzt sein dürfen (leere Start-/Endbefehle).
        var cleared: Set<String> = []
        /// Optionen außerhalb der PPD-Auswahl (Druckdialoge zeigen den nächstliegenden Wert).
        var approximated: [String] = []
    }

    /// Bildet Einstellungen auf `lpadmin`-Argumente ab:
    /// * PPD-Optionen mit einem Wert aus der PPD-Auswahl: `-o name=wert` (Standard in der PPD).
    /// * Ganzzahlen außerhalb der Auswahl: nächstliegende Wahl in der PPD **und** exakter Wert als
    ///   Warteschlangen-Standard `-o name-default=wert` – cupsd gibt ihn jedem Auftrag mit, der die
    ///   Option nicht selbst setzt, sodass er in `argv[5]` des Filters ankommt.
    /// * Start-/Endbefehle (keine PPD-Optionen): `-o name-default=…`, leer `-R name-default`.
    ///
    /// `removingStale` entfernt nicht mehr benötigte Warteschlangen-Standards (`-R` wirkt sofort und
    /// schlägt bei einer noch nicht vorhandenen Warteschlange fehl).
    ///
    /// `resolution` bestimmt die Auswahl der Millimeter-Optionen (`lwMarkOffset`, `lwStopOffset`); ohne
    /// Auflösung werden deren Zahlenwerte stets exakt als Warteschlangen-Standard gesetzt.
    static func defaultsPlan(settings: PrintSettings, language: PrinterLanguage?, removingStale: Bool,
                             resolution: Resolution? = nil) -> DefaultsPlan {
        var plan = DefaultsPlan()
        var options = settings.cupsOptions()
        if let language { options[CUPSOptionName.language] = language.cupsValue }
        for name in queueOnlyOptions.sorted() where options[name] == nil {
            if removingStale { plan.arguments += ["-R", "\(name)-default"] }
            plan.cleared.insert(name)
        }
        for (name, value) in options.sorted(by: { $0.key < $1.key }) {
            plan.expected[name] = value
            let dependsOnResolution = ppdMillimetreChoices[name] != nil
            if queueOnlyOptions.contains(name) {
                plan.arguments += ["-o", "\(name)-default=\(value)"]
                plan.queueDefaults.insert(name)
            } else if dependsOnResolution, resolution == nil, Int(value) != nil {
                // Auswahl der PPD unbekannt: exakter Wert als Warteschlangen-Standard.
                plan.arguments += ["-o", "\(name)-default=\(value)"]
                plan.queueDefaults.insert(name)
            } else if let choices = ppdChoices(name, resolution: resolution), !choices.isEmpty,
                      let number = Int(value), !choices.contains(number) {
                let nearest = choices.min { abs($0 - number) < abs($1 - number) } ?? number
                plan.arguments += ["-o", "\(name)=\(nearest)", "-o", "\(name)-default=\(value)"]
                plan.queueDefaults.insert(name)
                plan.approximated.append(name)
            } else {
                plan.arguments += ["-o", "\(name)=\(value)"]
                // Ein früher gesetzter exakter Wert würde die PPD-Wahl sonst überdecken.
                if removingStale, ppdIntegerChoices[name] != nil || dependsOnResolution {
                    plan.arguments += ["-R", "\(name)-default"]
                }
            }
        }
        return plan
    }

    /// Optionen, die laut `lpoptions` nicht den geplanten Wert haben. PPD-Optionen, die die PPD des
    /// Modells nicht kennt (z. B. `lwCutEvery` ohne Schneider), werden nicht geprüft.
    private static func mismatchedOptions(queue: String, plan: DefaultsPlan) async -> [String] {
        let current = await currentOptions(queue: queue)
        // `lpoptions` nicht verfügbar oder ohne Ausgabe: nicht prüfbar.
        guard !current.isEmpty else { return [] }
        var mismatched: [String] = []
        for (name, value) in plan.expected.sorted(by: { $0.key < $1.key }) {
            if let actual = current[name] {
                if actual != value { mismatched.append(name) }
            } else if plan.queueDefaults.contains(name) {
                mismatched.append(name)
            }
        }
        for name in plan.cleared.sorted() {
            if let actual = current[name], !actual.isEmpty,
               actual != "None", actual != CUPSOptionName.defaultValue {
                mismatched.append(name)
            }
        }
        return mismatched
    }

    /// Anzeigename einer Treiberoption (wie unter „Druckeinstellungen“).
    static func optionTitle(_ name: String) -> String {
        switch name {
        case CUPSOptionName.labelTop: return tr("Oberer Versatz (^LT)")
        case CUPSOptionName.labelLeft: return tr("Linker Versatz (^LS)")
        case CUPSOptionName.tearOff: return tr("Abreißposition (~TA)")
        case CUPSOptionName.threshold: return tr("Schwelle")
        case CUPSOptionName.cutEvery: return tr("Schneiden nach je")
        case CUPSOptionName.darkness: return tr("Temperatur")
        case CUPSOptionName.markOffset: return tr("Markierung Versatz")
        case CUPSOptionName.stopOffset: return tr("Stoppversatz")
        case CUPSOptionName.pauseEvery: return tr("Pausieren")
        case CUPSOptionName.cancelDelay: return tr("Verzögerung")
        default: return name
        }
    }

    static func removeQueue(_ name: String) async throws {
        try await runLpadmin(["-x", name])
    }

    static func setDefaultPrinter(_ name: String) async throws {
        try await runLpadmin(["-d", name])
    }

    /// Liest die aktuellen Optionen einer Warteschlange (`lpoptions -p <queue> -l`).
    static func currentOptions(queue: String) async -> [String: String] {
        guard let result = try? await ProcessRunner.run(lpoptions, ["-p", queue, "-l"]) else { return [:] }
        var options: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            // Format: "lwDarkness/Darkness: Default *15 16 …"
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyPart = line[..<colon]
            let key = String(keyPart.split(separator: "/").first ?? keyPart)
            let values = line[line.index(after: colon)...].split(separator: " ")
            if let marked = values.first(where: { $0.hasPrefix("*") }) {
                options[key] = String(marked.dropFirst())
            }
        }
        // Freie Werte (nicht in der PPD-Auswahl) stehen in `lpoptions -p <queue>`.
        if let plain = try? await ProcessRunner.run(lpoptions, ["-p", queue]) {
            for token in plain.stdout.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1)
                if pair.count == 2, String(pair[0]).hasPrefix("lw") {
                    options[String(pair[0])] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"\n"))
                }
            }
        }
        return options
    }

    /// Sendet eine Testseite über die macOS-Warteschlange (prüft den kompletten Treiberpfad).
    static func printTestPage(queue: String) async throws {
        let pdf = "/System/Library/Frameworks/Quartz.framework/Versions/A/Frameworks/QuartzComposer.framework/Versions/A/Resources/Test.pdf"
        if FileManager.default.fileExists(atPath: pdf) {
            try await ProcessRunner.runChecked("/usr/bin/lp", ["-d", queue, pdf])
        } else {
            // Fallback: Text über CUPS rendern lassen.
            try await ProcessRunner.runChecked("/usr/bin/lp", ["-d", queue], input: Data("LabelWerk – Testseite\n".utf8))
        }
    }

    // MARK: intern

    private static func runLpadmin(_ args: [String]) async throws {
        let result = try await ProcessRunner.run(lpadmin, args)
        if result.succeeded { return }
        let message = (result.stderr + result.stdout).lowercased()
        if message.contains("forbidden") || message.contains("not authorized") || message.contains("nicht autorisiert")
            || message.contains("verboten") || message.contains("unauthorized") {
            let script = ([lpadmin] + args).map(ProcessRunner.shellQuote).joined(separator: " ")
            try await ProcessRunner.runAsAdministrator(
                script, prompt: tr("LabelWerk möchte eine Druckerwarteschlange einrichten."))
            return
        }
        throw ProcessRunner.RunError.failed(command: "lpadmin", status: result.status,
                                           message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }
}

import Foundation
import LabelWerkKit

/// Verwaltung der macOS-Druckerwarteschlangen (CUPS) über `lpadmin`, `lpstat`, `lpoptions`, `lpinfo`.
///
/// Administratoren dürfen Warteschlangen auf macOS ohne Passwort anlegen (Gruppe `_lpadmin`).
/// Schlägt das mit „Forbidden“ fehl, wird – nur bei Aktionen des Benutzers – mit
/// Administratorrechten wiederholt; der automatische Abgleich (`QueueSyncService`) fragt nie nach
/// einem Passwort.
///
/// Etikettengröße (ARCHITECTURE.md §9 „Etikettengröße der Warteschlange“): Die Größe des Formats wird
/// Standard-Papiergröße der Warteschlange. Steht sie nicht in der Modell-PPD, erhält die Warteschlange
/// eine Kopie der PPD mit dieser benannten Seitengröße (`lpadmin -P`), dazu `lwLabelWidth`/
/// `lwLabelHeight` als Warteschlangen-Standard für „An Etikett anpassen“.
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
        /// `lpadmin` verweigert die Änderung und eine Passwortabfrage ist nicht erlaubt.
        case notAuthorized
        /// Die Warteschlange ist nicht (mehr) eingerichtet.
        case queueMissing(String)
        /// Die Warteschlange verwendet nicht den LabelWerk-Treiber (fremde PPD): LabelWerk ändert sie
        /// nur bei einer ausdrücklichen Neueinrichtung.
        case notLabelWerkQueue(String)

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
            case .notAuthorized:
                return tr("macOS erlaubt diesem Benutzer nicht, Drucker zu ändern. Ein Administrator kann die Einstellungen unter „Druckeinstellungen“ erneut übertragen.")
            case .queueMissing(let queue):
                return tr("Die macOS-Warteschlange „%@“ ist nicht eingerichtet.", queue)
            case .notLabelWerkQueue(let queue):
                return tr("Die Warteschlange „%@“ verwendet nicht den LabelWerk-Treiber – bitte unter „Treiber“ neu einrichten.", queue)
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

    /// Legt eine Warteschlange für den Drucker an und überträgt die Treiber-Standardwerte samt
    /// Etikettengröße.
    ///
    /// - Parameter stock: Etikettenformat des Druckers (auch eigene Formate aus `AppModel.customStocks`);
    ///   `nil` = Katalogformat `printer.stockID`.
    @discardableResult
    static func installQueue(for printer: SavedPrinter, queueName: String? = nil,
                             stock: LabelStock? = nil) async throws -> String {
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
        let configuration = QueueConfiguration(printer: printer,
                                               stock: stock ?? ModelCatalog.shared.stock(id: printer.stockID))
        let plan = configuration.plan(removingStale: exists)
        let queuePPD = try queuePPDFile(base: ppd, size: configuration.labelSize, queue: name)
        defer { queuePPD.cleanup() }
        var args = ["-p", name, "-E", "-v", uri, "-P", queuePPD.path,
                    "-D", printer.name, "-o", "printer-is-shared=false"]
        if !printer.location.isEmpty { args += ["-L", printer.location] }
        args += plan.arguments
        try await runLpadmin(args)
        // Die Warteschlange steht; abweichende Optionen gleicht der automatische Abgleich bzw.
        // „Druckeinstellungen“ erneut ab.
        let state = await queueState(name)
        let difference = QueueDefaults.difference(plan, current: state.options, pageSizeChoices: state.pageSizeChoices)
        if !difference.mismatchedOptions.isEmpty || difference.missingPageSize {
            NSLog("LabelWerk: Warteschlange %@ hat Optionen nicht übernommen: %@", name,
                  difference.mismatchedOptions.joined(separator: ", "))
        }
        return name
    }

    /// Überträgt Druckeinstellungen und Etikettengröße als Standardwerte der Warteschlange (wirkt für
    /// alle Programme) und prüft sie anschließend mit `lpoptions`. Fehlt die Größe in der PPD der
    /// Warteschlange, wird deren PPD durch eine ergänzte Kopie der Modell-PPD ersetzt.
    ///
    /// - Returns: Titel der Einstellungen, deren Wert nicht in der Auswahl der PPD liegt. Sie gelten
    ///   als Warteschlangen-Standard exakt; Druckdialoge bieten dafür nur den nächstliegenden Wert an.
    /// - Throws: `CUPSError.optionsNotApplied`, wenn die Warteschlange Werte nicht übernommen hat.
    @discardableResult
    static func setDefaults(queue: String, settings: PrintSettings, stock: LabelStock?,
                            language: PrinterLanguage?, resolution: Resolution? = nil,
                            modelID: String? = nil) async throws -> [String] {
        let configuration = QueueConfiguration(settings: settings, stock: stock, language: language,
                                               resolution: resolution, modelID: modelID)
        let outcome = try await apply(configuration, to: queue, force: true, allowAdminPrompt: true)
        return outcome.approximated.map(optionTitle)
    }

    // MARK: Übernahme fremder Warteschlangen

    /// Stellt eine vorhandene Warteschlange mit fremdem Treiber (z. B. „10.62.13.19“, in „Drucker &
    /// Scanner“ per IP-Adresse mit AirPrint angelegt) auf den LabelWerk-Treiber um – ARCHITECTURE.md §9
    /// „Übernahme von macOS-Warteschlangen“. Ob sie zu einem LabelWerk-Drucker gehört, entscheidet
    /// `QueueAdoption.decide` (LabelWerkCore); hier läuft nur `lpadmin`.
    ///
    /// Ein Aufruf: Geräte-URI `deviceURI` (Rohdatenport), Modell-PPD (bzw. ergänzte Kopie mit der
    /// Etikettengröße als benannter Standardgröße), Beschreibung `description` (Name im Druckdialog) und
    /// alle Standardwerte des Plans (`lwLabelWidth`/`lwLabelHeight`, `lwFitToLabel` …). Name, Standort,
    /// Freigabe und Zustand der Warteschlange bleiben.
    ///
    /// - Throws: `queueMissing`, `driverNotInstalled`, `noPPD`, `notAuthorized` (ohne Passwortabfrage),
    ///   `notLabelWerkQueue` (danach weiterhin fremder Treiber), Fehler von `lpadmin`.
    static func adoptQueue(_ queue: String, deviceURI: String, description: String,
                           configuration: QueueConfiguration, allowAdminPrompt: Bool) async throws {
        guard isDriverInstalled else { throw CUPSError.driverNotInstalled }
        guard !queue.isEmpty, !queue.contains("/"), !queue.hasPrefix(".") else { throw CUPSError.invalidQueueName }
        let before = await queueState(queue)
        guard before.isKnown else { throw CUPSError.queueMissing(queue) }
        guard let ppd = ppdURL(modelID: configuration.modelID, resolution: configuration.resolution ?? .dpi203,
                               language: configuration.language ?? .zpl) else {
            throw CUPSError.noPPD(configuration.modelID.flatMap { ModelCatalog.shared.model(id: $0)?.displayName } ?? queue)
        }
        // Die Warteschlange besteht: veraltete Warteschlangen-Standards (`-R`) dürfen entfernt werden.
        let plan = configuration.plan(removingStale: true)
        let queuePPD = try queuePPDFile(base: ppd, size: configuration.labelSize, queue: queue)
        defer { queuePPD.cleanup() }
        var args = ["-p", queue, "-v", deviceURI, "-P", queuePPD.path]
        let info = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !info.isEmpty { args += ["-D", info] }
        args += plan.arguments
        try await runLpadmin(args, allowAdminPrompt: allowAdminPrompt)

        let after = await queueState(queue)
        // `lpoptions` ohne Antwort: nicht prüfbar. Sonst muss die Warteschlange jetzt den LabelWerk-Treiber haben.
        guard !after.isKnown || after.isLabelWerk else { throw CUPSError.notLabelWerkQueue(queue) }
        let difference = QueueDefaults.difference(plan, current: after.options, pageSizeChoices: after.pageSizeChoices)
        if after.isKnown, !difference.mismatchedOptions.isEmpty || difference.missingPageSize {
            // Der automatische Abgleich bzw. „Druckeinstellungen“ gleicht erneut ab.
            NSLog("LabelWerk: übernommene Warteschlange %@ hat Optionen nicht übernommen: %@", queue,
                  difference.mismatchedOptions.joined(separator: ", "))
        }
    }

    // MARK: Abgleich (Soll ↔ Ist)

    /// Soll-Zustand einer Warteschlange aus den gespeicherten LabelWerk-Einstellungen.
    struct QueueConfiguration: Equatable {
        var settings: PrintSettings
        /// Etikettenformat (Größe = Standard-Papiergröße der Warteschlange); `nil` = unbekannt.
        var stock: LabelStock?
        var language: PrinterLanguage?
        /// Auflösung der PPD (Auswahl der Millimeter-Optionen; `nil` = exakte Werte als Standard).
        var resolution: Resolution?
        /// Modell für die Modell-PPD, falls die PPD der Warteschlange nicht lesbar ist.
        var modelID: String?

        init(settings: PrintSettings, stock: LabelStock?, language: PrinterLanguage?, resolution: Resolution?,
             modelID: String?) {
            self.settings = settings
            self.stock = stock
            self.language = language
            self.resolution = resolution
            self.modelID = modelID
        }

        init(printer: SavedPrinter, stock: LabelStock?) {
            self.init(settings: printer.settings, stock: stock, language: printer.language,
                      resolution: printer.resolution, modelID: printer.modelID)
        }

        /// Benannte Seitengröße der Warteschlange.
        var labelSize: QueueLabelSize? { stock.map(QueueLabelSize.init(stock:)) }

        /// Höchstgeschwindigkeit des Modells bei der Auflösung (Auswahl von `lwSpeed` in der PPD).
        var maxSpeed: Int? {
            guard let modelID, let model = ModelCatalog.shared.model(id: modelID) else { return nil }
            return model.maxSpeed(resolution ?? .dpi203)
        }

        /// `lpadmin`-Plan: Einstellungen mit `lwLabelWidth`/`lwLabelHeight` aus dem Format
        /// (Endlosmaterial: Länge 0) und `PageSize`.
        func plan(removingStale: Bool) -> QueueDefaults.Plan {
            QueueDefaults.plan(settings: settings.withLabelSize(of: stock), language: language,
                               removingStale: removingStale, resolution: resolution, labelSize: labelSize,
                               maxSpeed: maxSpeed)
        }
    }

    /// Stand einer vorhandenen Warteschlange laut `lpoptions` und ihrer PPD.
    struct QueueState: Equatable {
        /// Aktuelle Werte (markierte PPD-Wahl, darüber die Warteschlangen-Standards).
        var options: [String: String] = [:]
        /// Alle Seitengrößen der PPD der Warteschlange (`PageSize` in `lpoptions -l`).
        var pageSizeChoices: [String] = []
        /// Inhalt von `/etc/cups/ppd/<queue>.ppd` (falls lesbar).
        var ppdText: String?
        /// `printer-make-and-model` laut `lpoptions -p <queue>` (falls gemeldet).
        var makeAndModel: String?
        /// `lpoptions` hat geantwortet (die Warteschlange existiert).
        var isKnown: Bool { !options.isEmpty || !pageSizeChoices.isEmpty }
        /// Verwendet die Warteschlange den LabelWerk-Treiber? Nach der PPD (`*lwModel`), ist sie nicht
        /// lesbar, nach `printer-make-and-model` (wie ``DriverQueueClassifier``).
        var isLabelWerk: Bool {
            if let ppdText { return ppdText.contains("*lwModel:") }
            return makeAndModel?.contains("LabelWerk") == true
        }
    }

    /// Ergebnis eines Abgleichs.
    struct QueueApplyOutcome: Equatable {
        /// Es wurde `lpadmin` ausgeführt.
        var changed: Bool
        /// Die PPD der Warteschlange wurde ersetzt (ergänzte Etikettengröße).
        var replacedPPD: Bool
        /// Optionen außerhalb der PPD-Auswahl (exakt als Warteschlangen-Standard).
        var approximated: [String]
        /// Abweichungen vor dem Abgleich (leer, wenn nichts zu tun war).
        var difference: QueueDefaults.Difference
    }

    /// Liest den Stand einer Warteschlange (`lpoptions -p <queue> -l`, `lpoptions -p <queue>` und ihre PPD).
    static func queueState(_ queue: String) async -> QueueState {
        var state = QueueState()
        let environment = ["LC_ALL": "C", "LANG": "C"]
        if let list = try? await ProcessRunner.run(lpoptions, ["-p", queue, "-l"], environment: environment),
           list.succeeded {
            let parsed = LPOptionsList.parse(list.stdout)
            state.pageSizeChoices = parsed[QueueDefaults.pageSizeOption]?.choices ?? []
            var plain: [String: String] = [:]
            if let result = try? await ProcessRunner.run(lpoptions, ["-p", queue], environment: environment),
               result.succeeded {
                plain = CUPSQueueLister.parseLpoptions(result.stdout)
                state.makeAndModel = plain["printer-make-and-model"]
            }
            state.options = QueueDefaults.currentOptions(list: parsed, plain: plain)
        }
        state.ppdText = queuePPDText(queue)
        return state
    }

    /// Inhalt der PPD einer Warteschlange (`/etc/cups/ppd/<queue>.ppd`), falls lesbar.
    static func queuePPDText(_ queue: String) -> String? {
        guard !queue.isEmpty, !queue.contains("/"), !queue.hasPrefix(".") else { return nil }
        return try? PPDFiles.read("/etc/cups/ppd/\(queue).ppd")
    }

    /// Modell-PPD, aus der die PPD einer Warteschlange stammt (`*lwModel` + Auflösung), sonst die PPD
    /// für Modell, Auflösung und Sprache der Einstellungen.
    static func basePPD(queuePPD text: String?, configuration: QueueConfiguration) -> URL? {
        if let text, let stem = QueuePPD.baseStem(of: text), let url = installedPPD(stem: stem) {
            return url
        }
        return ppdURL(modelID: configuration.modelID, resolution: configuration.resolution ?? .dpi203,
                      language: configuration.language ?? .zpl)
    }

    /// Installierte Modell-PPD zu einem Namensstamm (`LabelWerk-zd421t-203dpi` → `.ppd.gz` bzw. `.ppd`).
    static func installedPPD(stem: String) -> URL? {
        for ext in ["ppd.gz", "ppd"] {
            let url = ppdDirectory.appendingPathComponent("\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Vergleicht Soll und Ist einer Warteschlange, ohne etwas zu ändern.
    static func check(_ configuration: QueueConfiguration, queue: String)
        async -> (plan: QueueDefaults.Plan, difference: QueueDefaults.Difference, state: QueueState) {
        let plan = configuration.plan(removingStale: true)
        let state = await queueState(queue)
        // Veraltete ergänzte Größen nur mit bekannter Modell-PPD der Warteschlange erkennen – nach der
        // installierten Datei (Treiber und App können verschiedene Versionen haben), sonst nach dem Katalog.
        let base = state.ppdText.flatMap { QueuePPD.baseStem(of: $0) }.flatMap { stem -> [String]? in
            PPDFiles.installedPageSizes(basePPD: installedPPD(stem: stem)?.path ?? stem)
        }
        let difference = QueueDefaults.difference(plan, current: state.options, pageSizeChoices: state.pageSizeChoices,
                                                  basePageSizes: base)
        return (plan, difference, state)
    }

    /// Bringt eine vorhandene Warteschlange auf den Soll-Zustand: Nur bei Abweichungen (oder mit
    /// `force`) läuft `lpadmin`; fehlt die Etikettengröße in ihrer PPD (oder enthält diese eine veraltete
    /// ergänzte Größe), wird die PPD durch die (ergänzte) Modell-PPD ersetzt – mit allen Standardwerten
    /// im selben Aufruf, denn `lpadmin -P` setzt sie auf die der neuen PPD zurück.
    ///
    /// - Parameter allowAdminPrompt: Bei fehlenden Rechten nach dem Administratorpasswort fragen
    ///   (nur bei Aktionen des Benutzers); sonst `CUPSError.notAuthorized`.
    /// Warteschlangen mit fremdem Treiber (PPD ohne `*lwModel`, z. B. Zebras eigene oder die
    /// CUPS-PPD „Zebra ZPL Label Printer“) bleiben unverändert: Nur eine ausdrückliche Einrichtung
    /// (``installQueue(for:queueName:stock:)``) stellt eine Warteschlange auf LabelWerk um.
    ///
    /// - Throws: `CUPSError.optionsNotApplied` (Abweichungen nach dem Abgleich), `noPPD`, `notAuthorized`,
    ///   `queueMissing`, `notLabelWerkQueue`, Fehler von `lpadmin`.
    @discardableResult
    static func apply(_ configuration: QueueConfiguration, to queue: String, force: Bool,
                      allowAdminPrompt: Bool) async throws -> QueueApplyOutcome {
        let (plan, difference, state) = await check(configuration, queue: queue)
        // `lpadmin -p` legte eine fehlende Warteschlange (ohne Geräte-URI) neu an.
        guard state.isKnown else { throw CUPSError.queueMissing(queue) }
        guard state.isLabelWerk else { throw CUPSError.notLabelWerkQueue(queue) }
        guard force || !difference.isEmpty else {
            return QueueApplyOutcome(changed: false, replacedPPD: false, approximated: plan.approximated,
                                     difference: difference)
        }
        var args = ["-p", queue]
        var queuePPD: QueuePPDFile?
        if difference.needsPPD {
            guard let base = basePPD(queuePPD: state.ppdText, configuration: configuration) else {
                throw CUPSError.noPPD(queue)
            }
            let file = try queuePPDFile(base: base, size: configuration.labelSize, queue: queue)
            queuePPD = file
            args += ["-P", file.path]
        }
        defer { queuePPD?.cleanup() }
        args += plan.arguments
        try await runLpadmin(args, allowAdminPrompt: allowAdminPrompt)

        let after = await queueState(queue)
        let remaining = QueueDefaults.difference(plan, current: after.options, pageSizeChoices: after.pageSizeChoices)
        // `lpoptions` nicht verfügbar oder ohne Ausgabe: nicht prüfbar.
        if after.isKnown {
            var failed = remaining.mismatchedOptions
            if remaining.missingPageSize, !failed.contains(QueueDefaults.pageSizeOption) {
                failed.append(QueueDefaults.pageSizeOption)
            }
            guard failed.isEmpty else { throw CUPSError.optionsNotApplied(failed.map(optionTitle)) }
        }
        return QueueApplyOutcome(changed: true, replacedPPD: queuePPD != nil, approximated: plan.approximated,
                                 difference: difference)
    }

    /// PPD für `lpadmin -P`: die Modell-PPD selbst, wenn sie die Größe enthält (oder keine bekannt ist),
    /// sonst eine ergänzte Kopie in einem temporären Ordner.
    struct QueuePPDFile {
        var path: String
        var temporary: URL?

        func cleanup() {
            if let temporary { PPDFiles.removeTemporary(temporary) }
        }
    }

    static func queuePPDFile(base: URL, size: QueueLabelSize?, queue: String) throws -> QueuePPDFile {
        guard let size, !PPDFiles.containsPageSize(size, basePPD: base.path) else {
            return QueuePPDFile(path: base.path, temporary: nil)
        }
        let text = try PPDFiles.patchedText(basePPD: base.path, size: size)
        let url = PPDFiles.temporaryPath(queue: queue, size: size)
        try PPDFiles.write(text, to: url)
        return QueuePPDFile(path: url.path, temporary: url)
    }

    // MARK: Standardwerte abbilden

    /// Bildet Einstellungen auf `lpadmin`-Argumente ab (``QueueDefaults/plan(settings:language:removingStale:resolution:labelSize:)``,
    /// unter Linux getestet).
    static func defaultsPlan(settings: PrintSettings, language: PrinterLanguage?, removingStale: Bool,
                             resolution: Resolution? = nil, labelSize: QueueLabelSize? = nil) -> QueueDefaults.Plan {
        QueueDefaults.plan(settings: settings, language: language, removingStale: removingStale,
                           resolution: resolution, labelSize: labelSize)
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
        case QueueDefaults.pageSizeOption: return tr("Etikettenformat")
        case CUPSOptionName.labelWidth, CUPSOptionName.labelHeight: return tr("Etikettengröße")
        case CUPSOptionName.fitToLabel: return tr("An Etikett anpassen")
        default: return name
        }
    }

    static func removeQueue(_ name: String) async throws {
        try await runLpadmin(["-x", name])
    }

    static func setDefaultPrinter(_ name: String) async throws {
        try await runLpadmin(["-d", name])
    }

    /// Liest die aktuellen Optionen einer Warteschlange (`lpoptions -p <queue> -l` und die freien
    /// Werte aus `lpoptions -p <queue>`).
    static func currentOptions(queue: String) async -> [String: String] {
        await queueState(queue).options
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

    private static func runLpadmin(_ args: [String], allowAdminPrompt: Bool = true) async throws {
        let result = try await ProcessRunner.run(lpadmin, args)
        if result.succeeded { return }
        let message = (result.stderr + result.stdout).lowercased()
        if message.contains("forbidden") || message.contains("not authorized") || message.contains("nicht autorisiert")
            || message.contains("verboten") || message.contains("unauthorized") {
            guard allowAdminPrompt else { throw CUPSError.notAuthorized }
            let script = ([lpadmin] + args).map(ProcessRunner.shellQuote).joined(separator: " ")
            try await ProcessRunner.runAsAdministrator(
                script, prompt: tr("LabelWerk möchte eine Druckerwarteschlange einrichten."))
            return
        }
        throw ProcessRunner.RunError.failed(command: "lpadmin", status: result.status,
                                           message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }
}

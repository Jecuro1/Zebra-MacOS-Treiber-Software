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
        case invalidQueueName

        var errorDescription: String? {
            switch self {
            case .driverNotInstalled:
                return tr("Der LabelWerk-Treiber ist nicht installiert. Bitte zuerst unter „Treiber“ installieren.")
            case .noPPD(let model):
                return tr("Für „%@“ wurde keine passende PPD-Datei gefunden.", model)
            case .noDeviceURI:
                return tr("Für diese Verbindung kann keine macOS-Warteschlange eingerichtet werden.")
            case .invalidQueueName:
                return tr("Ungültiger Warteschlangenname.")
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
    static func deviceURI(for descriptor: ConnectionDescriptor) async -> String? {
        switch descriptor {
        case .tcp(let host, let port):
            return "socket://\(host):\(port)"
        case .usb(let usb):
            // Von CUPS gemeldete USB-URI bevorzugen (enthält Seriennummer).
            let uris = await zebraDeviceURIs().filter { $0.hasPrefix("usb://") }
            if let serial = usb.serialNumber, let match = uris.first(where: { $0.contains(serial) }) {
                return match
            }
            return uris.first
        case .cupsQueue, .bluetooth, .ble, .virtual:
            return nil
        }
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
        guard let uri = await deviceURI(for: printer.descriptor) else { throw CUPSError.noDeviceURI }
        guard let ppd = ppdURL(modelID: printer.modelID, resolution: printer.resolution, language: printer.language) else {
            throw CUPSError.noPPD(printer.name)
        }
        let name = sanitizedQueueName(queueName ?? printer.name)
        var args = ["-p", name, "-E", "-v", uri, "-P", ppd.path,
                    "-D", printer.name, "-o", "printer-is-shared=false"]
        if !printer.location.isEmpty { args += ["-L", printer.location] }
        if let stock = ModelCatalog.shared.stock(id: printer.stockID) {
            args += ["-o", "PageSize=\(stock.ppdKeyword)"]
        }
        args += ["-o", "\(CUPSOptionName.language)=\(printer.language.cupsValue)"]
        for (key, value) in printer.settings.cupsOptions().sorted(by: { $0.key < $1.key }) {
            args += ["-o", "\(key)=\(value)"]
        }
        try await runLpadmin(args)
        return name
    }

    /// Überträgt Druckeinstellungen als Standardwerte der Warteschlange (wirkt für alle Programme).
    static func setDefaults(queue: String, settings: PrintSettings, stock: LabelStock?, language: PrinterLanguage?) async throws {
        var args = ["-p", queue]
        for (key, value) in settings.cupsOptions().sorted(by: { $0.key < $1.key }) {
            args += ["-o", "\(key)=\(value)"]
        }
        if let stock { args += ["-o", "PageSize=\(stock.ppdKeyword)"] }
        if let language { args += ["-o", "\(CUPSOptionName.language)=\(language.cupsValue)"] }
        // Leere Start-/Endbefehle explizit entfernen.
        if settings.startCommands.isEmpty { args += ["-R", CUPSOptionName.startCommands] }
        if settings.endCommands.isEmpty { args += ["-R", CUPSOptionName.endCommands] }
        try await runLpadmin(args)
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

import Foundation
import LabelWerkKit

/// Befehle, die einen Drucker benötigen.
enum PrinterCommands {

    // MARK: - Status & Identität

    static func status(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let snapshot = try await client.status()
        if context.json {
            try Console.json(snapshot)
        } else {
            Console.field("Drucker", client.connection.descriptor.displayString)
            Console.field("Zustand", snapshot.state.germanName)
            if snapshot.alerts.isEmpty {
                Console.field("Meldungen", snapshot.state == .unknown ? "keine Statusdaten (Verbindung ohne Rückkanal)" : "keine")
            } else {
                Console.out("Meldungen:")
                for alert in snapshot.alerts {
                    Console.out("  \(alert.severity.symbol) \(alert.title)")
                    Console.out("      \(alert.recovery)")
                }
            }
            if let host = snapshot.hostStatus {
                Console.field("Druckverfahren", host.thermalTransferMode ? "Thermotransfer" : "Thermodirekt")
                Console.field("Druckmodus", host.printModeDisplayName)
                Console.field("Etikettenlänge", "\(host.labelLengthDots) Punkte")
                if host.formatsInReceiveBuffer > 0 || host.labelsRemainingInBatch > 0 {
                    Console.field("Warteschlange", "\(host.formatsInReceiveBuffer) Formate, \(host.labelsRemainingInBatch) Etiketten")
                }
            }
            if let labels = snapshot.labelsPrinted { Console.field("Etiketten", String(labels)) }
            if let meters = snapshot.odometerMeters { Console.field("Odometer", "\(germanNumber(meters)) m") }
            if let temperature = snapshot.headTemperatureC { Console.field("Kopftemperatur", "\(germanNumber(temperature, digits: 0)) °C") }
            if let battery = snapshot.batteryPercent { Console.field("Akku", "\(battery) %") }
        }
        return snapshot.state == .error ? .printerError : .success
    }

    static func info(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let identity = try await client.identify()
        if context.json {
            try Console.json(identity)
            return .success
        }
        Console.field("Drucker", client.connection.descriptor.displayString)
        Console.field("Modell", identity.model)
        Console.field("Katalog", identity.matchedModel.map { "\($0.displayName) (\($0.id))" } ?? "nicht zugeordnet")
        Console.field("Name", identity.friendlyName)
        Console.field("Seriennummer", identity.serialNumber)
        Console.field("Firmware", identity.firmware)
        Console.field("Auflösung", identity.resolution.map { "\($0.dpi) dpi (\($0.dotsPerMM) Punkte/mm)" })
        Console.field("Druckbreite", identity.printWidthDots.map { "\($0) Punkte" })
        Console.field("Speicher", identity.memoryKB.map { "\($0) KB" })
        Console.field("Sprachen", identity.languages.map(\.displayName).joined(separator: ", "))
        Console.field("IP-Adresse", identity.ipAddress)
        Console.field("MAC-Adresse", identity.macAddress)
        Console.field("Link-OS", identity.isLinkOS ? "ja" : "nein")
        return .success
    }

    // MARK: - Senden & Drucken

    static func send(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let path = context.arguments.arguments[0]
        let data = try Files.read(path)
        guard !data.isEmpty else { throw CLIError.failure("„\(path)“ ist leer – nichts gesendet.") }
        try await client.send(data)
        Console.err("\(data.count) Byte gesendet.")
        return .success
    }

    static func print(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let arguments = context.arguments
        var identity: PrinterIdentity?
        if client.supportsBidirectional, arguments.value("dpi") == nil || arguments.value("model") == nil {
            // Auflösung und Modell vom Drucker übernehmen, sofern er antwortet.
            identity = try? await client.identify()
        }
        let job = try ImageJob(context: context, identity: identity)
        let images = try job.loadImages(arguments.arguments)
        try await client.printImages(images, settings: job.settings, resolution: job.resolution, stock: job.stock,
                                     copies: job.copies)
        let count = images.count * job.copies
        Console.out("\(count) Etikett\(count == 1 ? "" : "en") gesendet (\(job.stock.name), \(job.resolution.dpi) dpi, "
                    + "\(context.language.displayName), \(job.settings.dither.displayName)).")
        return .success
    }

    static func testLabel(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let arguments = context.arguments
        var identity: PrinterIdentity?
        if client.supportsBidirectional, arguments.value("dpi") == nil { identity = try? await client.identify() }
        let job = try ImageJob(context: context, identity: identity)
        let width = min(job.stock.widthDots(job.resolution), job.model?.printWidthDots(job.resolution) ?? Int.max)
        let height = job.stock.heightDots(job.resolution)
        let title = arguments.value("title") ?? "LabelWerk"
        let payload: Data
        switch context.language {
        case .zpl:
            payload = Data(TestLabel.zpl(widthDots: width, heightDots: height, resolution: job.resolution, title: title).utf8)
        case .epl:
            payload = EPL.encode(TestLabel.epl(widthDots: width, heightDots: height, resolution: job.resolution, title: title))
        case .cpcl:
            payload = Data(TestLabel.cpcl(widthDots: width, heightDots: height, resolution: job.resolution, title: title).utf8)
        }
        try await client.send(payload)
        Console.out("Testetikett gesendet (\(job.stock.name), \(job.resolution.dpi) dpi, \(context.language.displayName)).")
        return .success
    }

    static func action(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        if context.arguments.has("list") || context.arguments.arguments.isEmpty {
            Console.table(["NAME", "AKTION", "BESCHREIBUNG"], PrinterAction.allCases.map { action in
                [kebab(action.rawValue), action.displayName, action.detail]
            })
            return context.arguments.has("list") ? .success : .usage
        }
        let raw = context.arguments.arguments[0]
        guard let action = PrinterAction.allCases.first(where: {
            $0.rawValue.lowercased() == raw.lowercased() || kebab($0.rawValue) == raw.lowercased()
        }) else {
            throw CLIError.usage("Unbekannte Aktion „\(raw)“. Liste: lwctl action --list")
        }
        let job = try ImageJob(context: context, identity: nil)
        let width = min(job.stock.widthDots(job.resolution), job.model?.printWidthDots(job.resolution) ?? Int.max)
        try await client.perform(action, resolution: job.resolution, widthDots: width,
                                 heightDots: job.stock.heightDots(job.resolution))
        Console.out("„\(action.displayName)“ gesendet.")
        return .success
    }

    /// `printConfiguration` → `print-configuration`.
    static func kebab(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase {
                out += "-" + character.lowercased()
            } else {
                out.append(character)
            }
        }
        return out
    }

    // MARK: - SGD

    static func getvar(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let name = context.arguments.arguments[0]
        guard let value = try await client.getvar(name) else {
            throw CLIError.failure("Der Drucker kennt die Variable „\(name)“ nicht.")
        }
        if context.json {
            try Console.json([name: value])
        } else {
            Console.out(value)
        }
        return .success
    }

    static func setvar(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let name = context.arguments.arguments[0]
        let value = context.arguments.arguments[1]
        try await client.setvar(name, value)
        guard client.supportsBidirectional else {
            Console.out("\(name) gesendet.")
            return .success
        }
        // Übernahme prüfen (der Drucker ignoriert ungültige Werte stillschweigend).
        let current = try? await client.getvar(name)
        if let current {
            Console.out("\(name) = \(current)")
            if current.lowercased() != value.lowercased(), Double(current) != Double(value) {
                Console.err("Hinweis: Der Drucker meldet einen anderen Wert als gesendet – ungültige Werte werden ignoriert.")
            }
        } else {
            Console.out("\(name) gesendet.")
        }
        return .success
    }

    static func doCommand(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let arguments = context.arguments.arguments
        let response = try await client.doCommand(arguments[0], arguments.count > 1 ? arguments[1] : "")
        if let response, !response.isEmpty {
            Console.out(response)
        } else {
            Console.err("„\(arguments[0])“ ausgeführt.")
        }
        return .success
    }

    static func settings(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        var settings = try await client.allSettings()
        if let prefix = context.arguments.value("filter")?.lowercased() {
            settings = settings.filter { $0.key.lowercased().hasPrefix(prefix) }
        }
        if context.json {
            try Console.json(settings)
            return .success
        }
        let width = min(48, (settings.keys.map(\.count).max() ?? 10) + 1)
        for setting in settings.values.sorted(by: { $0.name < $1.name }) {
            let access = setting.access.map { " [\($0)]" } ?? ""
            Console.out(setting.name.padding(toLength: max(width, setting.name.count), withPad: " ", startingAt: 0)
                        + "= " + setting.value + access)
        }
        Console.err("\(settings.count) Einstellungen")
        return .success
    }

    static func config(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let entries = try await client.configuration()
        if context.json {
            try Console.json(entries)
            return .success
        }
        let width = min(32, (entries.map(\.name.count).max() ?? 10) + 2)
        for entry in entries {
            Console.out((entry.name + ":").padding(toLength: max(width, entry.name.count + 2), withPad: " ", startingAt: 0) + entry.value)
        }
        return .success
    }

    static func network(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let settings = try await client.networkSettings()
        if context.json {
            try Console.json(settings)
            return .success
        }
        Console.field("Adressvergabe", settings.useDHCP ? "DHCP" : "fest")
        Console.field("IP-Adresse", settings.ipAddress)
        Console.field("Subnetzmaske", settings.subnetMask)
        Console.field("Gateway", settings.gateway)
        Console.field("DNS-Server", settings.dnsServer)
        Console.field("Hostname", settings.hostname)
        Console.field("MAC-Adresse", settings.macAddress)
        if let wlan = settings.wlanEnabled {
            Console.field("WLAN", wlan ? "ein" : "aus")
            Console.field("SSID", settings.wlanSSID)
            Console.field("Sicherheit", settings.wlanSecurity)
        }
        return .success
    }

    // MARK: - Dateien

    static func files(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let drive = context.arguments.value("drive") ?? "E:"
        let files = try await client.listFiles(drive: drive)
        if context.json {
            try Console.json(files)
            return .success
        }
        if files.isEmpty {
            Console.out("Keine Dateien auf \(drive.uppercased()).")
            return .success
        }
        Console.table(["DATEI", "GRÖSSE", "ART"], files.map { [$0.id, "\($0.size) Byte", $0.kind.displayName] })
        return .success
    }

    static func deleteFile(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let path = context.arguments.arguments[0]
        try await client.deleteFile(path)
        Console.out("„\(path)“ gelöscht.")
        return .success
    }

    static func uploadFont(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let path = context.arguments.arguments[0]
        let data = try Files.read(path)
        let name = context.arguments.value("name") ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let drive = context.arguments.value("drive") ?? "E:"
        try await client.uploadFont(name: name, data: data, drive: drive)
        Console.out("Schrift übertragen: \(drive.uppercased().hasSuffix(":") ? drive.uppercased() : drive.uppercased() + ":")"
                    + "\(objectName(name)).TTF (\(data.count) Byte)")
        return .success
    }

    static func uploadGraphic(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let path = context.arguments.arguments[0]
        let image = try Files.image(path)
        let dither = try context.arguments.value("dither").map { raw -> DitherAlgorithm in
            guard let value = ImageJob.dither(raw) else { throw CLIError.usage("Unbekanntes Rasterverfahren „\(raw)“.") }
            return value
        } ?? .threshold
        let threshold = try context.arguments.int("threshold", in: 1...254) ?? 128
        let bitmap = Ditherer.dither(image, algorithm: dither, threshold: threshold)
        let name = context.arguments.value("name") ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let drive = context.arguments.value("drive") ?? "E:"
        try await client.uploadGraphic(name: name, bitmap: bitmap, drive: drive)
        Console.out("Grafik übertragen: \(objectName(name)).GRF (\(bitmap.width) × \(bitmap.height) Punkte) – "
                    + "abrufbar mit ^XG\(drive.uppercased().hasSuffix(":") ? drive.uppercased() : drive.uppercased() + ":")\(objectName(name)).GRF,1,1")
        return .success
    }

    /// Objektname wie im Drucker (Großbuchstaben, ohne Endung, höchstens 16 Zeichen).
    static func objectName(_ raw: String) -> String {
        var base = raw
        if let dot = base.lastIndex(of: "."), dot != base.startIndex { base = String(base[..<dot]) }
        let mapped = base.uppercased().unicodeScalars.map { scalar -> String in
            let allowed = (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
            return allowed ? String(scalar) : "_"
        }.joined()
        return String(mapped.prefix(16))
    }

    static func firmware(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        let path = context.arguments.arguments[0]
        let data = try Files.read(path)
        guard !data.isEmpty else { throw CLIError.failure("„\(path)“ ist leer.") }
        if !context.arguments.has("yes") {
            guard Console.stdinIsTerminal else {
                throw CLIError.usage("Firmware-Übertragung ohne Terminal: Bitte mit --yes bestätigen.")
            }
            Console.err("Firmware „\(URL(fileURLWithPath: path).lastPathComponent)“ (\(data.count) Byte) an "
                        + "\(client.connection.descriptor.displayString) übertragen? Der Drucker startet danach neu. [j/N] ",
                        terminator: "")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard ["j", "ja", "y", "yes"].contains(answer) else {
                Console.err("Abgebrochen – nichts übertragen.")
                return .success
            }
        }
        let chunk = try context.arguments.int("chunk-size", in: 256...1_048_576) ?? 16_384
        try await client.sendFirmware(data, chunkSize: chunk) { fraction in
            Console.progress("Firmware", fraction)
        }
        Console.out("Firmware übertragen (\(data.count) Byte). Der Drucker installiert sie jetzt und startet neu – bitte nicht ausschalten.")
        return .success
    }
}

import Foundation
import LabelWerkKit

/// Eingerichtete CUPS-Warteschlangen für `install`, `queues` und `uninstall-queue`.
///
/// Gelesen mit `lpstat` und `lpoptions`, gesucht wie `lpadmin` zuerst in `$PATH`
/// (``ToolRunner/locate(_:fallbacks:)``) – Liste und Änderung betreffen so dieselbe
/// CUPS-Installation. Ausgewertet wird wie in der App (``CUPSQueueLister``).
enum CUPSQueues {

    /// Eine eingerichtete Warteschlange.
    struct Queue: Sendable {
        var info: CUPSQueueInfo
        /// Beschreibung (`printer-info`), falls gesetzt.
        var description: String?

        var name: String { info.name }
        var deviceURI: String { info.deviceURI }
        var makeAndModel: String? { info.makeAndModel }
    }

    static let lpstatFallbacks = ["/usr/bin/lpstat"]
    static let lpoptionsFallbacks = ["/usr/bin/lpoptions"]

    /// Konfigurationsordner von CUPS: `$CUPS_SERVERROOT` (wie bei libcups), sonst `/etc/cups`.
    static var serverRoot: String {
        let configured = ProcessInfo.processInfo.environment["CUPS_SERVERROOT"] ?? ""
        return configured.isEmpty ? "/etc/cups" : configured
    }

    /// PPD einer Warteschlange (`<ServerRoot>/ppd/<name>.ppd`); `nil` bei unzulässigen Namen.
    static func ppdPath(ofQueue name: String) -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return "\(serverRoot)/ppd/\(name).ppd"
    }

    /// Inhalt der PPD einer Warteschlange; `nil`, wenn sie fehlt oder nicht lesbar ist.
    static func ppdText(ofQueue name: String) -> String? {
        guard let path = ppdPath(ofQueue: name), let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Alle Warteschlangen. Leer, wenn `lpstat` fehlt oder der Druckdienst nicht läuft – dann
    /// entscheidet `lpadmin` selbst.
    static func list() async -> [Queue] {
        // Englische, unübersetzte Ausgaben (stabile Auswertung).
        var environment = ProcessInfo.processInfo.environment
        for key in ["LC_ALL", "LANG", "LC_MESSAGES"] { environment[key] = "C" }

        let lpstat = ToolRunner.locate("lpstat", fallbacks: lpstatFallbacks)
        guard let devices = try? await ToolRunner.run(lpstat, ["-v"], environment: environment,
                                                      includeErrors: false, timeout: 15),
              devices.status == 0
        else { return [] }
        let entries = CUPSQueueLister.parseLpstatV(devices.output)
        guard !entries.isEmpty else { return [] }

        var defaultName: String?
        if let result = try? await ToolRunner.run(lpstat, ["-d"], environment: environment,
                                                  includeErrors: false, timeout: 10),
           result.status == 0 {
            defaultName = CUPSQueueLister.parseLpstatD(result.output)
        }

        let lpoptions = ToolRunner.locate("lpoptions", fallbacks: lpoptionsFallbacks)
        var queues: [Queue] = []
        for entry in entries where !queues.contains(where: { $0.name == entry.name }) {
            var options: [String: String] = [:]
            if let result = try? await ToolRunner.run(lpoptions, ["-p", entry.name], environment: environment,
                                                      includeErrors: false, timeout: 10),
               result.status == 0 {
                options = CUPSQueueLister.parseLpoptions(result.output)
            }
            let info = CUPSQueueInfo(name: entry.name, deviceURI: entry.uri, isDefault: entry.name == defaultName,
                                     makeAndModel: options["printer-make-and-model"].flatMap { $0.isEmpty ? nil : $0 })
            queues.append(Queue(info: info, description: options["printer-info"].flatMap { $0.isEmpty ? nil : $0 }))
        }
        return queues
    }

    // MARK: - Geräte-URIs

    /// Schema, Host (klein, ohne Klammern und abschließenden Punkt) und Port einer Geräte-URI –
    /// derselbe Algorithmus wie `PrinterSetupPlanning.endpoint(ofDeviceURI:)` in der App.
    static func endpoint(ofDeviceURI uri: String) -> (scheme: String, host: String, port: Int?)? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<range.lowerBound].lowercased()
        var rest = String(trimmed[range.upperBound...])
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<end])
        }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        var host: String
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let remainder = rest[rest.index(after: close)...]
            if remainder.hasPrefix(":") { port = Int(remainder.dropFirst()) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...])
        } else {
            host = rest
        }
        host = (host.removingPercentEncoding ?? host).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return (scheme, host, port)
    }

    /// Druckt eine Warteschlange mit `queueURI` auf dasselbe Gerät wie `deviceURI`? Gleiche URI
    /// (ohne Rücksicht auf Groß-/Kleinschreibung) oder bei `socket://` gleicher Host und Port
    /// (Standard 9100) – wie der exakte Treffer der App (`PrinterSetupPlanning.queueMatch`).
    static func isSameDevice(_ queueURI: String, _ deviceURI: String) -> Bool {
        func normalized(_ text: String) -> String {
            var value = (text.removingPercentEncoding ?? text).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        let lhs = normalized(queueURI)
        guard !lhs.isEmpty else { return false }
        if lhs == normalized(deviceURI) { return true }
        guard let a = endpoint(ofDeviceURI: queueURI), let b = endpoint(ofDeviceURI: deviceURI),
              a.scheme == "socket", b.scheme == "socket", a.host == b.host
        else { return false }
        return (a.port ?? ZebraIdentifiers.rawPort) == (b.port ?? ZebraIdentifiers.rawPort)
    }

    // MARK: - Standardwerte

    /// Standardwerte aller Optionen (`*OpenUI`) einer PPD in Dateireihenfolge, z. B.
    /// `("lwDarkness", "15")` – derselbe Algorithmus wie `queue_defaults` im postinstall des Treibers.
    static func ppdDefaults(_ text: String) -> [(option: String, value: String)] {
        var order: [String] = []
        var defaults: [String: String] = [:]
        // isNewline trennt auch „\r\n“ (in Swift ein einziges Zeichen) und „\r“.
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("*OpenUI"), let first = line.dropFirst(7).first, first == " " || first == "\t" {
                // „*OpenUI *PageSize/Media Size: PickOne“ → PageSize
                let field = line.dropFirst(7).drop { $0 == " " || $0 == "\t" }.prefix { $0 != " " && $0 != "\t" }
                guard field.hasPrefix("*") else { continue }
                var name = field.dropFirst()
                if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
                if let slash = name.firstIndex(of: "/") { name = name[..<slash] }
                if !name.isEmpty, !order.contains(String(name)) { order.append(String(name)) }
            } else if line.hasPrefix("*Default"), let colon = line.firstIndex(of: ":") {
                let key = line[line.index(line.startIndex, offsetBy: 8)..<colon]
                guard !key.isEmpty, !key.contains(where: { $0 == " " || $0 == "\t" }) else { continue }
                let value = line[line.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
                    .prefix { $0 != " " && $0 != "\t" }
                if defaults[String(key)] == nil { defaults[String(key)] = String(value) }
            }
        }
        return order.compactMap { name in
            guard let value = defaults[name], !value.isEmpty else { return nil }
            return (name, value)
        }
    }
}

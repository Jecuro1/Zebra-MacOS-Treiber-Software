import Foundation
import LabelWerkCore

extension VirtualPrinter {

    /// SGD-`do`-Befehle mit eigener Wirkung.
    static let doVariables: Set<String> = [
        "device.reset", "device.restore_defaults", "file.dir", "file.delete", "ezpl.manual_calibration",
        "device.printhead.test", "file.type",
    ]

    /// Präfix der Simulationsvariablen (nur im virtuellen Drucker): `head_open`, `media_out`,
    /// `ribbon_out`, `paused` mit den Werten `on`/`off`. Damit lassen sich Fehlerzustände auch
    /// über das Netzwerk herstellen (z. B. `lwctl setvar labelwerk.simulation.head_open on`).
    /// Sie erscheinen nicht in `allconfig`/`allcv`.
    static let simulationPrefix = "labelwerk.simulation."

    /// Wert einer Simulationsvariablen.
    func simulationValue(_ name: String) -> String? {
        guard name.hasPrefix(Self.simulationPrefix) else { return nil }
        switch name.dropFirst(Self.simulationPrefix.count) {
        case "head_open": return headOpen ? "on" : "off"
        case "media_out": return mediaOut ? "on" : "off"
        case "ribbon_out": return ribbonOut ? "on" : "off"
        case "paused": return paused ? "on" : "off"
        default: return nil
        }
    }

    /// Setzt eine Simulationsvariable; `false`, wenn Name oder Wert ungültig sind.
    func setSimulation(_ name: String, _ value: String) -> Bool {
        let lower = value.lowercased()
        let on: Bool
        if ["on", "yes", "true", "1"].contains(lower) {
            on = true
        } else if ["off", "no", "false", "0"].contains(lower) {
            on = false
        } else {
            return false
        }
        switch name.dropFirst(Self.simulationPrefix.count) {
        case "head_open": setHeadOpen(on)
        case "media_out": setMediaOut(on)
        case "ribbon_out": setRibbonOut(on)
        case "paused": setPaused(on)
        default: return false
        }
        return true
    }

    // MARK: - Klassische SGD-Zeilen

    /// `! U1 getvar "name"`, `! U1 setvar "name" "wert"`, `! U1 do "name" "wert"`.
    func handleSGDLine(_ line: String) {
        guard let command = Self.parseSGD(line) else { return }
        switch command.verb {
        case "getvar":
            guard let name = command.arguments.first else { return }
            respond(getvarResponse(name))
        case "setvar":
            guard command.arguments.count >= 2 else { return }
            assignVariable(command.arguments[0], command.arguments[1])
        case "do":
            guard let name = command.arguments.first else { return }
            if let output = performDo(name, command.arguments.count > 1 ? command.arguments[1] : "") {
                respond(output)
            }
        default:
            break
        }
    }

    /// Zerlegt eine SGD-Zeile in Befehlswort und Argumente (in Anführungszeichen oder ohne).
    static func parseSGD(_ line: String) -> (verb: String, arguments: [String])? {
        var scalars = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard scalars.first == "!" else { return nil }
        scalars = scalars.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let u = scalars.first, u == "U" || u == "u" else { return nil }
        scalars = scalars.dropFirst()
        if scalars.first == "1" { scalars = scalars.dropFirst() }
        scalars = scalars.drop { $0 == " " || $0 == "\t" }
        let verb = scalars.prefix { $0.isLetter }.lowercased()
        guard !verb.isEmpty else { return nil }
        var rest = scalars.dropFirst(verb.count)
        var arguments: [String] = []
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let first = rest.first else { break }
            if first == "\"" {
                let body = rest.dropFirst()
                if let end = body.firstIndex(of: "\"") {
                    arguments.append(String(body[..<end]))
                    rest = body[body.index(after: end)...]
                } else {
                    arguments.append(String(body))
                    break
                }
            } else {
                let token = rest.prefix { $0 != " " && $0 != "\t" }
                arguments.append(String(token))
                rest = rest.dropFirst(token.count)
            }
        }
        return (verb, arguments)
    }

    /// Antwort auf `getvar`: `"wert"`, bei Zweigen und `allcv` mehrzeiliger Text, sonst `"?"`.
    func getvarResponse(_ rawName: String) -> String {
        refreshDynamicValues()
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "allcv" { return allcvText(names: store.definitions.map(\.name)) }
        if let value = computedValue(name) ?? store.readableValue(name) {
            return "\"\(value)\""
        }
        if store.definition(name) != nil {
            // Nur-Schreib-Variable.
            return "\"\""
        }
        let branch = store.names(inBranch: name)
        if !branch.isEmpty { return allcvText(names: branch) }
        return "\"?\""
    }

    /// Werte, die nicht im Speicher stehen, sondern aus dem Zustand berechnet werden.
    func computedValue(_ name: String) -> String? {
        if let simulated = simulationValue(name) { return simulated }
        switch name {
        case "device.host_status":
            return hostStatus().responseText.replacingOccurrences(of: "\u{02}", with: "")
                .replacingOccurrences(of: "\u{03}\r\n", with: ", ").trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        case "device.host_identification":
            return hostIdentification().responseText.replacingOccurrences(of: "\u{02}", with: "")
                .replacingOccurrences(of: "\u{03}", with: "")
        default:
            return nil
        }
    }

    /// `allcv`-Text: `name : wert , Choices: …` je Zeile.
    func allcvText(names: [String]) -> String {
        var text = ""
        for name in names {
            guard let definition = store.definition(name) else { continue }
            let value = definition.access == .writeOnly ? "" : (store.rawValue(name) ?? "")
            let padded = name.padding(toLength: max(name.count, 40), withPad: " ", startingAt: 0)
            text += "\(padded) : \(value) , Choices: \(definition.kind.choicesText)\r\n"
        }
        return text
    }

    /// Setzt eine Variable wie per `setvar` (nur gültige Werte, nur beschreibbare Variablen).
    @discardableResult
    func assignVariable(_ rawName: String, _ value: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix(Self.simulationPrefix) { return setSimulation(name, value) }
        if Self.doVariables.contains(name) {
            _ = performDo(name, value)
            return true
        }
        guard store.assign(name, value) else { return false }
        switch name {
        case "device.languages":
            stream.acceptsEPL = model.supports(.epl) && store.acceptsEPL
        case "ezpl.print_width":
            if let width = Int(store.rawValue(name) ?? ""), width > model.printWidthDots(resolution) {
                store.force(name, String(model.printWidthDots(resolution)))
            }
        default:
            break
        }
        return true
    }

    /// Führt einen `do`-Befehl aus; liefert eine Antwort, falls der Drucker eine sendet.
    func performDo(_ rawName: String, _ value: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "device.reset":
            restartDevice()
            return nil
        case "device.restore_defaults":
            switch value.lowercased() {
            case "ip": store.restoreDefaults(.ip)
            case "wlan": store.restoreDefaults(.wlan)
            case "bluetooth": store.restoreDefaults(.bluetooth)
            case "display": store.restoreDefaults(.display)
            case "power": store.restoreDefaults(.power)
            case "all":
                store.restoreDefaults(.all)
                printInverted = false
                printMirrored = false
                backfeed = .normal
            default: break
            }
            return nil
        case "file.dir":
            return fileDirectoryText(drive: value)
        case "file.delete":
            deleteFiles(matching: value)
            return nil
        case "ezpl.manual_calibration":
            calibrate()
            return nil
        case "device.printhead.test":
            return "\"Printhead test passed\""
        case "file.type":
            guard let file = findFile(value, defaultExtension: "") else { return "\"?\"" }
            return "\"" + (String(data: file.data, encoding: .utf8) ?? "") + "\""
        default:
            // `do` auf eine normale Variable wirkt wie `setvar`.
            assignVariable(name, value)
            return nil
        }
    }

    // MARK: - JSON

    /// `{}{"a":null,"b":"wert"}`: `null` liest, andere Werte setzen; Antwort als JSON-Objekt in
    /// der Reihenfolge der Anfrage. `{"allconfig":null}` liefert alle Variablen mit Deskriptor.
    func handleJSON(_ bytes: [UInt8]) {
        guard let request = try? MiniJSON.parse(bytes), case .object(let pairs) = request else { return }
        refreshDynamicValues()
        var response: [(key: String, value: MiniJSON)] = []
        for (rawKey, value) in pairs {
            let key = rawKey.trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case .null:
                if key == "allconfig" {
                    response.append((rawKey, allconfigObject()))
                } else if let current = computedValue(key) ?? store.readableValue(key) {
                    response.append((rawKey, .string(current)))
                } else if store.definition(key) == nil, !store.names(inBranch: key).isEmpty {
                    for name in store.names(inBranch: key) {
                        response.append((name, store.readableValue(name).map(MiniJSON.string) ?? .null))
                    }
                } else {
                    response.append((rawKey, .null))
                }
            case .object, .array:
                response.append((rawKey, .null))
            default:
                let text = value.scalarText ?? ""
                if Self.doVariables.contains(key) {
                    let output = performDo(key, text)
                    response.append((rawKey, output.map { MiniJSON.string(Self.unquoted($0)) } ?? .null))
                } else {
                    assignVariable(key, text)
                    response.append((rawKey, store.readableValue(key).map(MiniJSON.string) ?? .null))
                }
            }
        }
        respond(MiniJSON.object(response).serialized)
    }

    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// `allconfig`: je Variable `{"value","type","range","clone","archive","access"}`.
    func allconfigObject() -> MiniJSON {
        var entries: [(key: String, value: MiniJSON)] = []
        for definition in store.definitions {
            let value = definition.access == .writeOnly ? "" : (store.rawValue(definition.name) ?? "")
            entries.append((definition.name, .object([
                ("value", .string(value)),
                ("type", .string(definition.kind.typeName)),
                ("range", .string(definition.kind.rangeText)),
                ("clone", .bool(definition.clone)),
                ("archive", .bool(definition.archive)),
                ("access", .string(definition.access.rawValue)),
            ])))
        }
        return .object(entries)
    }
}

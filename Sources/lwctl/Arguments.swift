import Foundation

/// Beschreibung einer Option.
struct OptionSpec: Sendable {
    /// Langer Name ohne `--`, z. B. `stock`.
    let long: String
    /// Optionaler Kurzname ohne `-`, z. B. `o`.
    let short: Character?
    /// Platzhalter des Werts (`<id>`); `nil` = Schalter ohne Wert.
    let value: String?
    /// Deutsche Beschreibung.
    let help: String

    init(_ long: String, short: Character? = nil, value: String? = nil, _ help: String) {
        self.long = long
        self.short = short
        self.value = value
        self.help = help
    }

    var takesValue: Bool { value != nil }

    /// Darstellung in der Hilfe, z. B. `-o, --output <datei>`.
    var signature: String {
        var text = short.map { "-\($0), " } ?? "    "
        text += "--\(long)"
        if let value { text += " <\(value)>" }
        return text
    }
}

/// Beschreibung eines Befehls.
struct CommandSpec: Sendable {
    let name: String
    /// Aufrufform, z. B. `print <bild…> [optionen]`.
    let usage: String
    /// Einzeilige Kurzbeschreibung.
    let summary: String
    /// Ausführliche Beschreibung (mehrzeilig).
    let details: String
    let options: [OptionSpec]
    /// Benötigt `--printer`.
    let needsPrinter: Bool
    let minimumArguments: Int
    /// `nil` = beliebig viele.
    let maximumArguments: Int?
    /// Beispiele.
    let examples: [String]
}

/// Ergebnis der Befehlszeilenauswertung.
struct ParsedArguments: Sendable {
    var command: String?
    var arguments: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }

    /// Ganzzahliger Optionswert mit Bereichsprüfung.
    func int(_ name: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw CLIError.usage("„--\(name)“ erwartet eine ganze Zahl, nicht „\(raw)“.")
        }
        if let range, !range.contains(value) {
            throw CLIError.usage("„--\(name)“ muss zwischen \(range.lowerBound) und \(range.upperBound) liegen.")
        }
        return value
    }

    /// Dezimalzahl (Komma oder Punkt).
    func double(_ name: String, in range: ClosedRange<Double>? = nil) throws -> Double? {
        guard let raw = values[name] else { return nil }
        guard let value = Double(raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
              value.isFinite else {
            throw CLIError.usage("„--\(name)“ erwartet eine Zahl, nicht „\(raw)“.")
        }
        if let range, !range.contains(value) {
            throw CLIError.usage("„--\(name)“ muss zwischen \(range.lowerBound) und \(range.upperBound) liegen.")
        }
        return value
    }
}

/// Handgeschriebene Auswertung der Befehlszeile (ohne Fremdabhängigkeiten).
///
/// * Globale Optionen dürfen vor und nach dem Befehl stehen, Befehlsoptionen nur danach.
/// * `--name wert`, `--name=wert`, `-n wert`; Schalter ohne Wert.
/// * `--` beendet die Optionen; `-` und negative Zahlen (`-10`) sind Argumente.
enum ArgumentParser {
    static func parse(_ tokens: [String], global: [OptionSpec], commands: [String: CommandSpec]) throws -> ParsedArguments {
        var result = ParsedArguments()
        var index = 0
        var optionsEnded = false
        func spec(long: String) -> OptionSpec? {
            if let match = global.first(where: { $0.long == long }) { return match }
            guard let command = result.command, let commandSpec = commands[command] else { return nil }
            return commandSpec.options.first { $0.long == long }
        }
        func spec(short: Character) -> OptionSpec? {
            if let match = global.first(where: { $0.short == short }) { return match }
            guard let command = result.command, let commandSpec = commands[command] else { return nil }
            return commandSpec.options.first { $0.short == short }
        }
        func unknown(_ token: String) -> CLIError {
            if let command = result.command {
                return CLIError.usage("Unbekannte Option „\(token)“ für „lwctl \(command)“. Hilfe: lwctl help \(command)")
            }
            return CLIError.usage("Unbekannte Option „\(token)“. Hilfe: lwctl help")
        }

        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if optionsEnded || token == "-" || !token.hasPrefix("-") || isNegativeNumber(token) {
                if result.command == nil {
                    result.command = token
                } else {
                    result.arguments.append(token)
                }
                continue
            }
            if token == "--" {
                optionsEnded = true
                continue
            }
            let option: OptionSpec
            var inlineValue: String?
            if token.hasPrefix("--") {
                var name = String(token.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    inlineValue = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                guard let found = spec(long: name) else { throw unknown(token) }
                option = found
            } else {
                let letters = Array(token.dropFirst())
                guard letters.count == 1, let found = spec(short: letters[0]) else { throw unknown(token) }
                option = found
            }
            if option.takesValue {
                if let inlineValue {
                    result.values[option.long] = inlineValue
                } else {
                    guard index < tokens.count else {
                        throw CLIError.usage("Die Option „--\(option.long)“ erwartet einen Wert (<\(option.value ?? "wert")>).")
                    }
                    result.values[option.long] = tokens[index]
                    index += 1
                }
            } else {
                if inlineValue != nil {
                    throw CLIError.usage("Die Option „--\(option.long)“ erwartet keinen Wert.")
                }
                result.flags.insert(option.long)
            }
        }
        return result
    }

    static func isNegativeNumber(_ token: String) -> Bool {
        guard token.count >= 2, token.hasPrefix("-") else { return false }
        return Double(token.dropFirst().replacingOccurrences(of: ",", with: ".")) != nil
    }
}

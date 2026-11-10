import Foundation
import LabelWerkKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Einstiegspunkt von `lwctl`.
@main
struct LWCtl {
    static func main() async {
        let code = await run(Array(CommandLine.arguments.dropFirst()))
        exit(code.rawValue)
    }

    /// Führt einen Aufruf aus und liefert den Rückgabewert (ohne den Prozess zu beenden).
    static func run(_ tokens: [String]) async -> ExitCode {
        VirtualPrinter.registerWithConnectionFactory()
        let parsed: ParsedArguments
        do {
            parsed = try ArgumentParser.parse(tokens, global: CommandCatalog.globalOptions, commands: CommandCatalog.byName)
        } catch {
            return report(error)
        }
        if parsed.has("version"), parsed.command == nil {
            Console.out(versionText)
            return .success
        }
        guard let name = parsed.command else {
            Console.out(CommandCatalog.overview(), terminator: "")
            return parsed.has("help") ? .success : .usage
        }
        guard let spec = CommandCatalog.byName[name] else {
            let suggestion = CommandCatalog.commands.map(\.name).first { $0.hasPrefix(name.prefix(3)) }
            var message = "Unbekannter Befehl „\(name)“."
            if let suggestion { message += " Meinten Sie „\(suggestion)“?" }
            Console.err("lwctl: \(message) Übersicht: lwctl help")
            return .usage
        }
        if parsed.has("help") {
            Console.out(CommandCatalog.help(for: spec), terminator: "")
            return .success
        }
        if parsed.arguments.count < spec.minimumArguments
            || (spec.maximumArguments.map { parsed.arguments.count > $0 } ?? false) {
            Console.err("lwctl: Falscher Aufruf. Verwendung: lwctl \(spec.usage)")
            return .usage
        }

        let context: Context
        do {
            context = try Context(arguments: parsed)
        } catch {
            return report(error)
        }

        let work = Task { try await Commands.execute(spec, context) }
        let interrupts = InterruptHandler()
        interrupts.install {
            work.cancel()
        }
        let result = await work.result
        interrupts.remove()
        switch result {
        case .success(let code):
            return code
        case .failure(let error):
            return report(error)
        }
    }

    static var versionText: String {
        #if os(macOS)
        let platform = "macOS"
        #elseif os(Linux)
        let platform = "Linux"
        #else
        let platform = "unbekannte Plattform"
        #endif
        return "lwctl \(LabelWerkKitInfo.version) (\(LabelWerkKitInfo.productName), \(platform))"
    }

    /// Gibt einen Fehler aus und liefert den passenden Rückgabewert.
    static func report(_ error: Error) -> ExitCode {
        if error is CancellationError {
            Console.err("lwctl: Abgebrochen.")
            return .interrupted
        }
        let code: ExitCode
        var message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        var suggestion = (error as? LocalizedError)?.recoverySuggestion
        switch error {
        case let error as CLIError:
            code = error.exitCode
            suggestion = nil
        case let error as PrinterClientError:
            switch error {
            case .transport, .noResponse: code = .connection
            default: code = .failure
            }
        case is TransportError:
            code = .connection
        default:
            code = .failure
        }
        if message.isEmpty { message = "Unbekannter Fehler." }
        Console.err("lwctl: \(message)")
        if let suggestion, !suggestion.isEmpty { Console.err("Tipp: \(suggestion)") }
        return code
    }
}

/// Gemeinsame Einstellungen eines Aufrufs.
struct Context: Sendable {
    let arguments: ParsedArguments
    let json: Bool
    let language: PrinterLanguage
    /// Wartezeit aus `--timeout` (sonst `nil`).
    let timeout: Duration?

    init(arguments: ParsedArguments) throws {
        self.arguments = arguments
        json = arguments.has("json")
        if let raw = arguments.value("language") {
            guard let language = PrinterLanguage(rawValue: raw.lowercased()) ?? PrinterLanguage(cupsValue: raw) else {
                throw CLIError.usage("Unbekannte Druckersprache „\(raw)“ (erlaubt: zpl, epl, cpcl).")
            }
            self.language = language
        } else {
            language = .zpl
        }
        if let seconds = try arguments.double("timeout", in: 0.05...3600) {
            timeout = .milliseconds(Int64(seconds * 1000))
        } else {
            timeout = nil
        }
    }
}

/// Fängt Ctrl+C ab: Der laufende Befehl wird abgebrochen; reagiert er nicht binnen einer
/// Sekunde (z. B. blockierende Eingabe), wird der Prozess mit 130 beendet.
final class InterruptHandler: @unchecked Sendable {
    private var source: DispatchSourceSignal?

    func install(_ action: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler {
            action()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                Console.err("")
                exit(ExitCode.interrupted.rawValue)
            }
        }
        source.resume()
        self.source = source
    }

    func remove() {
        source?.cancel()
        source = nil
        signal(SIGINT, SIG_DFL)
    }
}

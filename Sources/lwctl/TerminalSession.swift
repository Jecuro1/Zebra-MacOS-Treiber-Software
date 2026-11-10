import Foundation
import LabelWerkKit

/// Interaktives Terminal (`lwctl terminal`): liest Zeilen von der Standardeingabe, sendet sie
/// an den Drucker und zeigt die Antworten mit sichtbaren Steuerzeichen.
///
/// Funktioniert auch mit umgeleiteter Eingabe (`lwctl terminal < befehle.txt`); dann ohne
/// Eingabeaufforderung.
enum TerminalSession {

    enum LineEnding: String {
        case crlf, lf, keins

        var text: String {
            switch self {
            case .crlf: return "\r\n"
            case .lf: return "\n"
            case .keins: return ""
            }
        }
    }

    static let helpText = """
    Befehle des Terminals:
      :hilfe                        diese Hilfe
      :hex                          Antworten zusätzlich als Hexdump anzeigen (ein/aus)
      :zeilenende crlf|lf|keins     Zeilenende, das an jede Eingabe angehängt wird (Standard: crlf)
      :warte <sekunden>             Wartezeit auf Antworten (Standard: 2)
      :datei <pfad>                 Datei unverändert senden
      :ende                         Terminal beenden (auch Ctrl+D)
    Alles andere wird an den Drucker gesendet, z. B. ~HS, ^XA^HH^XZ, ! U1 getvar "device.friendly_name"
    """

    static func run(_ client: PrinterClient, _ context: Context) async throws -> ExitCode {
        try await client.connect()
        let interactive = Console.stdinIsTerminal
        var lineEnding = LineEnding.crlf
        var hex = false
        var wait = context.timeout ?? .seconds(2)
        if interactive {
            Console.err("LabelWerk-Terminal – \(client.connection.descriptor.displayString)")
            Console.err("„:hilfe“ zeigt die Befehle, „:ende“ oder Ctrl+D beendet.")
            if !client.supportsBidirectional {
                Console.err("Hinweis: Diese Verbindung kann keine Antworten empfangen.")
            }
        }
        while true {
            try Task.checkCancellation()
            if interactive { Console.out("lwctl> ", terminator: "") }
            guard let line = await readLine() else {
                if interactive { Console.out("") }
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":") {
                let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
                switch parts.first?.lowercased() ?? "" {
                case "ende", "exit", "quit", "q":
                    return .success
                case "hilfe", "help", "?":
                    Console.out(helpText)
                case "hex":
                    hex.toggle()
                    Console.err("Hexanzeige \(hex ? "ein" : "aus").")
                case "zeilenende":
                    if parts.count > 1, let value = LineEnding(rawValue: parts[1].lowercased()) {
                        lineEnding = value
                        Console.err("Zeilenende: \(value.rawValue).")
                    } else {
                        Console.err("Erwartet: :zeilenende crlf|lf|keins")
                    }
                case "warte":
                    if parts.count > 1, let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")), seconds > 0 {
                        wait = .milliseconds(Int64(seconds * 1000))
                        Console.err("Wartezeit: \(germanNumber(seconds)) s.")
                    } else {
                        Console.err("Erwartet: :warte <sekunden>")
                    }
                case "datei":
                    guard parts.count > 1 else {
                        Console.err("Erwartet: :datei <pfad>")
                        continue
                    }
                    do {
                        let data = try Files.read(parts[1])
                        try await client.send(data)
                        Console.err("\(data.count) Byte gesendet.")
                        show(try await client.terminal("", timeout: wait), hex: hex, interactive: interactive)
                    } catch let error as CLIError {
                        Console.err(error.errorDescription ?? "")
                    }
                default:
                    Console.err("Unbekannter Terminalbefehl „\(trimmed)“ – „:hilfe“ zeigt alle.")
                }
                continue
            }
            let payload = trimmed.isEmpty ? "" : line + lineEnding.text
            let response = try await client.terminal(payload, timeout: wait)
            show(response, hex: hex, interactive: interactive)
        }
        return .success
    }

    static func show(_ response: Data, hex: Bool, interactive: Bool) {
        if response.isEmpty {
            if interactive { Console.err("(keine Antwort)") }
            return
        }
        var text = Console.visible(response)
        if !text.hasSuffix("\n") { text += "\n" }
        Console.out(text, terminator: "")
        if hex { Console.out(Console.hexDump(response)) }
    }

    /// Liest eine Zeile auf einem eigenen Thread (blockiert nicht den Thread-Pool).
    static func readLine() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            Thread.detachNewThread {
                continuation.resume(returning: Swift.readLine(strippingNewline: true))
            }
        }
    }
}

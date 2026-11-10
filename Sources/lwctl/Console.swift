import Foundation
import LabelWerkKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Rückgabewerte von `lwctl`.
enum ExitCode: Int32 {
    /// Erfolg.
    case success = 0
    /// Allgemeiner Fehler (Datei, Druckerantwort, Kodierung …).
    case failure = 1
    /// Falscher Aufruf (unbekannter Befehl, fehlende oder ungültige Optionen).
    case usage = 2
    /// Verbindung zum Drucker fehlgeschlagen bzw. keine Antwort.
    case connection = 3
    /// Der Drucker meldet einen Fehlerzustand (`status`).
    case printerError = 4
    /// Durch Ctrl+C abgebrochen.
    case interrupted = 130
}

/// Fehler der Befehlszeile.
enum CLIError: Error, LocalizedError {
    /// Aufruffehler (Rückgabewert 2).
    case usage(String)
    /// Laufzeitfehler (Rückgabewert 1).
    case failure(String)
    /// Verbindungsfehler (Rückgabewert 3).
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .usage(let text), .failure(let text), .connection(let text): return text
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .usage: return .usage
        case .failure: return .failure
        case .connection: return .connection
        }
    }
}

/// Ungepufferte Ausgabe auf stdout/stderr (in Reihenfolge, auch bei Umleitung).
enum Console {
    static func out(_ text: String = "", terminator: String = "\n") {
        FileHandle.standardOutput.write(Data((text + terminator).utf8))
    }

    static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    static func err(_ text: String, terminator: String = "\n") {
        FileHandle.standardError.write(Data((text + terminator).utf8))
    }

    /// `true`, wenn stdin bzw. stdout ein Terminal ist.
    static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }
    static var stdoutIsTerminal: Bool { isatty(STDOUT_FILENO) == 1 }
    static var stderrIsTerminal: Bool { isatty(STDERR_FILENO) == 1 }

    /// JSON-Ausgabe (sortiert, eingerückt, Datum ISO 8601).
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(0x0A)
        write(data)
    }

    /// Tabelle mit Spaltenüberschriften (Spaltenbreite nach Inhalt).
    static func table(_ header: [String], _ rows: [[String]]) {
        var widths = header.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        out(line(header))
        out(line(widths.map { String(repeating: "─", count: $0) }))
        for row in rows { out(line(row)) }
    }

    /// Zeile `Bezeichnung: Wert` mit einheitlicher Einrückung.
    static func field(_ label: String, _ value: String?, width: Int = 16) {
        guard let value, !value.isEmpty else { return }
        out((label + ":").padding(toLength: width, withPad: " ", startingAt: 0) + value)
    }

    /// Fortschrittsbalken auf stderr (nur im Terminal).
    static func progress(_ label: String, _ fraction: Double) {
        let clamped = min(1, max(0, fraction))
        let width = 30
        let filled = Int((clamped * Double(width)).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let percent = Int((clamped * 100).rounded())
        if stderrIsTerminal {
            err("\r\(label) \(bar) \(percent) %", terminator: clamped >= 1 ? "\n" : "")
        } else if clamped >= 1 || percent % 25 == 0 {
            err("\(label) \(percent) %")
        }
    }

    /// Macht Steuerzeichen einer Druckerantwort sichtbar (`<STX>`, `<ETX>` …); Zeilenenden bleiben.
    static func visible(_ data: Data) -> String {
        let names: [UInt8: String] = [
            0x00: "<NUL>", 0x01: "<SOH>", 0x02: "<STX>", 0x03: "<ETX>", 0x04: "<EOT>", 0x05: "<ENQ>", 0x06: "<ACK>",
            0x07: "<BEL>", 0x08: "<BS>", 0x09: "\t", 0x0B: "<VT>", 0x0C: "<FF>", 0x15: "<NAK>", 0x1B: "<ESC>", 0x7F: "<DEL>",
        ]
        let text = String(decoding: data, as: UTF8.self)
        var out = ""
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out += "\n"
                previousWasCR = true
                continue
            }
            if scalar == "\n" {
                if !previousWasCR { out += "\n" }
                previousWasCR = false
                continue
            }
            previousWasCR = false
            if scalar.value < 0x20 || scalar.value == 0x7F {
                out += names[UInt8(scalar.value)] ?? String(format: "<%02X>", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Hexdump (16 Byte je Zeile mit ASCII-Spalte).
    static func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(Unicode.Scalar($0)) : "." })
            lines.append(String(format: "%08X  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + ascii)
            offset += 16
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Deutsche Bezeichnungen

extension PrinterState {
    var germanName: String {
        switch self {
        case .ready: return "Bereit"
        case .printing: return "Druckt"
        case .paused: return "Pausiert"
        case .warning: return "Warnung"
        case .error: return "Fehler"
        case .offline: return "Offline"
        case .unknown: return "Unbekannt"
        }
    }
}

extension AlertSeverity {
    var symbol: String {
        switch self {
        case .info: return "ℹ"
        case .warning: return "⚠"
        case .error: return "✖"
        }
    }
}

/// Zahl mit deutschem Dezimalkomma.
func germanNumber(_ value: Double, digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
}

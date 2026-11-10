import Foundation

/// Ein einzelner ZPL-Befehl aus dem Datenstrom.
///
/// * `prefix` ist das **logische** Präfix: `"^"` für Formatbefehle, `"~"` für Steuerbefehle –
///   auch wenn die Präfixzeichen per `^CC`/`^CT` umdefiniert wurden (das tatsächlich verwendete
///   Zeichen steht im Quelltext unter `range`).
/// * `command` ist in Großbuchstaben normalisiert und zwei Zeichen lang (`"FO"`, `"GF"`, `"B3"`).
///   Einzige Ausnahme ist `^A`: Der Schriftbezeichner gehört zu `arguments` (`^A0N,30` →
///   `command == "A"`, `arguments == "0N,30"`; `^A@N,…` → `arguments == "@N,…"`).
/// * `arguments` ist der Rohtext bis zum nächsten Präfix ohne CR/LF (bei Binärdaten von `^GF`
///   bzw. `~DY` unverändert und genau so lang wie angekündigt).
public struct ZPLToken: Hashable, Sendable {
    public var prefix: Character
    public var command: String
    public var arguments: String
    /// Quelltextbereich des gesamten Befehls (Präfix bis vor das nächste Präfix).
    public var range: Range<String.Index>?
    /// Parametertrennzeichen zum Zeitpunkt des Befehls (`^CD`, Standard `,`).
    public var delimiter: Character

    public init(prefix: Character, command: String, arguments: String = "",
                range: Range<String.Index>? = nil, delimiter: Character = ",") {
        self.prefix = prefix
        self.command = command
        self.arguments = arguments
        self.range = range
        self.delimiter = delimiter
    }

    /// Befehlsname mit logischem Präfix, z. B. `"^FO"` oder `"~DG"`.
    public var name: String { "\(prefix)\(command)" }

    /// Parameter, getrennt am aktuellen Trennzeichen (leere Parameter bleiben erhalten).
    public var parameters: [String] {
        if arguments.isEmpty { return [] }
        return arguments.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
    }
}

/// Zerlegt ZPL-II-Datenströme in Befehle.
///
/// Beachtet werden
/// * `^CC`/`~CC` (Präfix `^` ändern), `^CT`/`~CT` (Präfix `~` ändern), `^CD`/`~CD` (Trennzeichen ändern),
/// * Felddaten (`^FD`, `^FV`) und Kommentare (`^FX`) laufen bis zum nächsten Befehlspräfix –
///   im gültigen ZPL also bis `^FS`; Kommas sind Teil der Daten. Wie in der Firmware beendet jedes
///   Präfixzeichen die Daten (wörtliche `^`/`~` erfordern `^FH` oder geänderte Präfixe), damit ein
///   fehlendes `^FS` nicht den Rest des Datenstroms verschluckt,
/// * Binärdaten von `^GFB`/`^GFC` und `~DY…,B`/`~DY…,C` werden exakt in der angekündigten Länge
///   übernommen (dürfen also Präfixzeichen enthalten),
/// * CR und LF werden – wie von der Firmware – überall außerhalb von Binärdaten ignoriert;
///   Text zwischen Befehlen wird übersprungen.
///
/// Der Tokenizer wirft nie; jede Eingabe ergibt eine (ggf. leere) Befehlsliste.
public enum ZPLTokenizer {

    public static func tokenize(_ zpl: String) -> [ZPLToken] {
        var scanner = Scanner(zpl)
        return scanner.run()
    }

    // MARK: - Implementierung

    private struct Scanner {
        let source: String
        let scalars: String.UnicodeScalarView
        var index: String.UnicodeScalarView.Index
        var caret: Unicode.Scalar = "^"
        var tilde: Unicode.Scalar = "~"
        var delimiter: Unicode.Scalar = ","
        var tokens: [ZPLToken] = []

        init(_ source: String) {
            self.source = source
            self.scalars = source.unicodeScalars
            self.index = scalars.startIndex
        }

        mutating func run() -> [ZPLToken] {
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar == caret || scalar == tilde {
                    readCommand(isCaret: scalar == caret)
                } else {
                    scalars.formIndex(after: &index)
                }
            }
            return tokens
        }

        private func isPrefix(_ scalar: Unicode.Scalar) -> Bool { scalar == caret || scalar == tilde }

        private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool { scalar == "\r" || scalar == "\n" }

        /// Nächstes Zeichen ohne CR/LF, ohne den Index zu verändern.
        private func peekSkippingLineBreaks(from start: String.UnicodeScalarView.Index)
            -> (scalar: Unicode.Scalar, next: String.UnicodeScalarView.Index)? {
            var position = start
            while position < scalars.endIndex {
                let scalar = scalars[position]
                let next = scalars.index(after: position)
                if Self.isLineBreak(scalar) {
                    position = next
                    continue
                }
                return (scalar, next)
            }
            return nil
        }

        private static func uppercased(_ scalar: Unicode.Scalar) -> String {
            if scalar.value >= 0x61 && scalar.value <= 0x7A, let upper = Unicode.Scalar(scalar.value - 0x20) {
                return String(Character(upper))
            }
            return String(Character(scalar))
        }

        private mutating func readCommand(isCaret: Bool) {
            let start = index
            scalars.formIndex(after: &index)
            let logicalPrefix: Character = isCaret ? "^" : "~"

            // Befehlskennung: zwei Zeichen (bei ^A nur eines), CR/LF dazwischen werden ignoriert.
            var code = ""
            if let first = peekSkippingLineBreaks(from: index), !isPrefix(first.scalar) {
                code = Self.uppercased(first.scalar)
                index = first.next
                let isFontCommand = isCaret && code == "A"
                if !isFontCommand, let second = peekSkippingLineBreaks(from: index), !isPrefix(second.scalar) {
                    code += Self.uppercased(second.scalar)
                    index = second.next
                }
            }

            switch code {
            case "CC", "CT", "CD":
                readPrefixChange(code: code, logicalPrefix: logicalPrefix, start: start)
            case "GF" where isCaret:
                readCountedBinary(code: code, logicalPrefix: logicalPrefix, start: start,
                                  formatField: 0, countField: 1, headerFields: 4)
            case "DY" where !isCaret:
                readCountedBinary(code: code, logicalPrefix: logicalPrefix, start: start,
                                  formatField: 1, countField: 3, headerFields: 5)
            default:
                let arguments = readArguments()
                append(logicalPrefix, code, arguments, start)
            }
        }

        private mutating func append(_ prefix: Character, _ code: String, _ arguments: String,
                                     _ start: String.UnicodeScalarView.Index) {
            tokens.append(ZPLToken(prefix: prefix, command: code, arguments: arguments,
                                   range: start..<index, delimiter: Character(delimiter)))
        }

        /// Liest Argumente bis zum nächsten Präfix; CR/LF werden entfernt.
        private mutating func readArguments() -> String {
            var result = String.UnicodeScalarView()
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if isPrefix(scalar) { break }
                if !Self.isLineBreak(scalar) { result.append(scalar) }
                scalars.formIndex(after: &index)
            }
            return String(result)
        }

        /// `^CCx`, `^CTx`, `^CDx`: Das nächste Zeichen (ohne CR/LF) ist das neue Zeichen.
        private mutating func readPrefixChange(code: String, logicalPrefix: Character,
                                               start: String.UnicodeScalarView.Index) {
            guard let next = peekSkippingLineBreaks(from: index) else {
                append(logicalPrefix, code, "", start)
                return
            }
            let value = next.scalar
            index = next.next
            // Steuerzeichen und Leerraum sind als Präfix/Trennzeichen unbrauchbar und werden ignoriert.
            let usable = value.value > 0x20 && value.value != 0x7F
            if usable {
                switch code {
                case "CC": if value != tilde && value != delimiter { caret = value }
                case "CT": if value != caret && value != delimiter { tilde = value }
                default: if value != caret && value != tilde { delimiter = value }
                }
            }
            append(logicalPrefix, code, String(Character(value)), start)
            // Eventueller Rest bis zum nächsten Präfix gehört zu keinem Befehl.
            _ = readArguments()
        }

        /// Befehle mit Binärnutzlast: Der Kopf wird gelesen, bei Format `B`/`C` folgen genau
        /// `count` Zeichen (Bytes als ISO-Latin-1-Zeichen) ohne Präfix- und CR/LF-Behandlung.
        private mutating func readCountedBinary(code: String, logicalPrefix: Character,
                                                start: String.UnicodeScalarView.Index,
                                                formatField: Int, countField: Int, headerFields: Int) {
            // Kopf: `headerFields` Felder, jeweils mit dem Trennzeichen abgeschlossen.
            var header = String.UnicodeScalarView()
            var fields: [String] = []
            var current = String.UnicodeScalarView()
            let headerStart = index
            while index < scalars.endIndex, fields.count < headerFields {
                let scalar = scalars[index]
                if isPrefix(scalar) { break }
                scalars.formIndex(after: &index)
                if Self.isLineBreak(scalar) { continue }
                header.append(scalar)
                if scalar == delimiter {
                    fields.append(String(current))
                    current = String.UnicodeScalarView()
                } else {
                    current.append(scalar)
                }
            }
            let format = fields.count > formatField
                ? fields[formatField].trimmingCharacters(in: .whitespaces).uppercased() : ""
            let count = fields.count > countField
                ? Int(fields[countField].trimmingCharacters(in: .whitespaces)) : nil
            guard fields.count == headerFields, format == "B" || format == "C", let total = count, total >= 0 else {
                // Kein Binärformat: wie gewöhnliche Argumente behandeln.
                index = headerStart
                let arguments = readArguments()
                append(logicalPrefix, code, arguments, start)
                return
            }
            var payload = String.UnicodeScalarView()
            var remaining = total
            while remaining > 0, index < scalars.endIndex {
                payload.append(scalars[index])
                scalars.formIndex(after: &index)
                remaining -= 1
            }
            header.append(contentsOf: payload)
            append(logicalPrefix, code, String(header), start)
            // Nachlaufende Zeichen bis zum nächsten Präfix (z. B. Zeilenende) verwerfen.
            _ = readArguments()
        }
    }
}

import Foundation

/// Textwerkzeuge für ZPL-Dokumente: Aufräumen/Formatieren, Bausteine einfügen, Zählen.
///
/// Das Formatieren ist bedeutungserhaltend: ZPL ignoriert Zeilenumbrüche, Feldinhalte (`^FD`,
/// `^FV`) bleiben zeichengenau erhalten, geänderte Steuerzeichen (`^CC`/`~CC`, `^CT`/`~CT`) werden
/// berücksichtigt und SGD-Zeilen (`! U1 …`, `{}{…}`) bleiben unverändert in eigenen Zeilen.
enum DesignerZPLFormatter {
    enum Style: String, CaseIterable, Identifiable {
        /// Jeder Befehl in einer eigenen Zeile.
        case perCommand
        /// Jedes Feld (`^FO … ^FS`) in einer Zeile, übrige Befehle einzeln.
        case perField

        var id: String { rawValue }

        var title: String {
            switch self {
            case .perCommand: return tr("Ein Befehl pro Zeile")
            case .perField: return tr("Ein Feld pro Zeile")
            }
        }

        var systemImage: String {
            switch self {
            case .perCommand: return "list.bullet"
            case .perField: return "text.justify.left"
            }
        }
    }

    /// Dateiendungen, die als ZPL-Dokument geöffnet werden.
    static let openableExtensions: Set<String> = ["zpl", "zpl2", "txt", "prn", "lbl", "nlbl"]

    // MARK: Zerlegen

    private enum Piece {
        case command(String)
        case verbatim(String)
    }

    private static func isSGDLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.hasPrefix("! U1") || upper.hasPrefix("! U ") || upper.hasPrefix("!U1") || line.hasPrefix("{}")
    }

    private static func pieces(of zpl: String) -> [Piece] {
        var pieces: [Piece] = []
        var caret: Character = "^"
        var tilde: Character = "~"
        var current = ""
        var currentLength = 0
        var inCommand = false

        func finish() {
            defer {
                current = ""
                currentLength = 0
            }
            guard !current.isEmpty else { return }
            if inCommand {
                pieces.append(.command(current))
            } else {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { pieces.append(.verbatim(trimmed)) }
            }
        }

        // „\r\n“ ist in Swift ein einziges Zeichen (Graphem) – Zeilenenden zuerst vereinheitlichen.
        let normalized = zpl.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if isSGDLine(trimmedLine) {
                finish()
                inCommand = false
                pieces.append(.verbatim(trimmedLine))
                continue
            }
            for character in line {
                if character == caret || character == tilde {
                    finish()
                    inCommand = true
                }
                current.append(character)
                currentLength += 1
                // Steuerzeichenwechsel wirkt sofort auf die folgenden Zeichen.
                if inCommand && currentLength == 4 {
                    let chars = Array(current)
                    let code = String(chars[1...2]).uppercased()
                    if code == "CC" {
                        caret = chars[3]
                    } else if code == "CT" {
                        tilde = chars[3]
                    }
                }
            }
        }
        finish()
        return pieces
    }

    /// Zweistelliger Befehlscode in Großbuchstaben (z. B. `FO` für `^FO50,50`).
    static func code(of command: String) -> String {
        String(command.dropFirst().prefix(2)).uppercased()
    }

    private static func normalized(_ command: String) -> String {
        let code = code(of: command)
        if code == "FD" || code == "FV" { return command }
        return command.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Formatieren

    /// Formatiert das Dokument bedeutungserhaltend im gewünschten Stil.
    static func format(_ zpl: String, style: Style) -> String {
        var lines: [String] = []
        var fieldLine = ""
        var inField = false

        func flushField() {
            if !fieldLine.isEmpty { lines.append(fieldLine) }
            fieldLine = ""
            inField = false
        }

        for piece in pieces(of: zpl) {
            switch piece {
            case .verbatim(let text):
                flushField()
                lines.append(text)
            case .command(let raw):
                let command = normalized(raw)
                guard !command.isEmpty else { continue }
                let code = code(of: command)
                switch style {
                case .perCommand:
                    lines.append(command)
                    if code == "XZ" { lines.append("") }
                case .perField:
                    if code == "FO" || code == "FT" {
                        flushField()
                        fieldLine = command
                        inField = true
                    } else if inField && code != "XA" && code != "XZ" {
                        fieldLine += command
                        if code == "FS" { flushField() }
                    } else {
                        flushField()
                        lines.append(command)
                        if code == "XZ" { lines.append("") }
                    }
                }
            }
        }
        flushField()
        while lines.last == "" { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Einfügen

    /// Fügt einen Baustein vor dem letzten `^XZ` ein (bzw. erzeugt ein Grundgerüst).
    static func insert(_ snippet: String, into document: String, geometry: DesignerLabelGeometry) -> String {
        if document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var builder = DesignerZPLBuilder(geometry: geometry)
            builder.raw(snippet)
            return builder.document(title: tr("Neues Etikett") + " – LabelWerk")
        }
        if let range = document.range(of: "^XZ", options: [.backwards, .caseInsensitive]) {
            var prefix = String(document[..<range.lowerBound])
            while let last = prefix.last, last == " " || last == "\t" { prefix.removeLast() }
            if !prefix.isEmpty && !prefix.hasSuffix("\n") { prefix += "\n" }
            return prefix + snippet + "\n" + String(document[range.lowerBound...])
        }
        return document + (document.hasSuffix("\n") ? "" : "\n") + snippet + "\n"
    }

    /// Hängt ein weiteres Format (`^XA … ^XZ`) an das Dokument an.
    static func append(format: String, to document: String) -> String {
        let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return format }
        return trimmed + "\n\n" + format
    }

    // MARK: Kennzahlen

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.uppercased().components(separatedBy: needle).count - 1
    }

    /// Anzahl der Etikettenformate (`^XA`).
    static func formatCount(_ zpl: String) -> Int { occurrences(of: "^XA", in: zpl) }

    /// Anzahl der Felder (`^FO`/`^FT`) – staffelt die Position neuer Bausteine.
    static func fieldCount(_ zpl: String) -> Int {
        occurrences(of: "^FO", in: zpl) + occurrences(of: "^FT", in: zpl)
    }

    static func lineCount(_ zpl: String) -> Int {
        zpl.isEmpty ? 0 : zpl.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: Abgelegte Dateipfade

    /// Liefert den Text, der zwischen `old` und `new` eingefügt wurde (nur bei reinem Einfügen).
    static func insertedText(old: String, new: String) -> String? {
        let oldCount = old.utf8.count, newCount = new.utf8.count
        guard newCount > oldCount + 3, newCount - oldCount < 8192 else { return nil }
        let a = Array(old.utf8), b = Array(new.utf8)
        var prefix = 0
        while prefix < a.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix == a.count else { return nil }
        return String(decoding: b[prefix..<(b.count - suffix)], as: UTF8.self)
    }

    /// Erkennt einen in den Editor abgelegten Dateipfad einer ZPL-/Textdatei.
    static func droppedFileURL(in inserted: String) -> URL? {
        let candidate = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let parsed: URL?
        if candidate.hasPrefix("file://") {
            parsed = URL(string: candidate)
        } else if candidate.hasPrefix("/") {
            parsed = URL(fileURLWithPath: candidate)
        } else {
            parsed = nil
        }
        guard let url = parsed, openableExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

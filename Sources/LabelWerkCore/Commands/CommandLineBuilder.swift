import Foundation

/// Result Builder für zeilenorientierte Druckersprachen (EPL2, CPCL).
///
/// Jeder Ausdruck liefert eine oder mehrere Befehlszeilen (ohne Zeilenende). Unterstützt
/// einzelne Zeilen, Arrays, Optionale, `if`/`else`, `switch` und `for`-Schleifen.
///
/// ```swift
/// let epl = EPL.label {
///     EPL.labelWidth(812)
///     EPL.text("Hallo", x: 20, y: 20, font: "4")
///     if withBarcode { EPL.barcode("12345", x: 20, y: 80, type: .code128, height: 80) }
/// }
/// ```
@resultBuilder
public enum CommandLineBuilder {
    public static func buildExpression(_ line: String) -> [String] { [line] }

    public static func buildExpression(_ lines: [String]) -> [String] { lines }

    public static func buildExpression(_ line: String?) -> [String] { line.map { [$0] } ?? [] }

    public static func buildBlock(_ components: [String]...) -> [String] { components.flatMap { $0 } }

    public static func buildOptional(_ component: [String]?) -> [String] { component ?? [] }

    public static func buildEither(first component: [String]) -> [String] { component }

    public static func buildEither(second component: [String]) -> [String] { component }

    public static func buildArray(_ components: [[String]]) -> [String] { components.flatMap { $0 } }

    public static func buildLimitedAvailability(_ component: [String]) -> [String] { component }
}

// MARK: - Zeichensatz-Hilfen für EPL/CPCL

enum LegacyText {
    /// Ersetzt typografische Zeichen und Umlaute durch ASCII (ä → ae, × → x, „ → " …),
    /// entfernt verbleibende Akzente und ersetzt alles Übrige durch `?`.
    static func asciiTransliterated(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "ä": out += "ae"
            case "ö": out += "oe"
            case "ü": out += "ue"
            case "Ä": out += "Ae"
            case "Ö": out += "Oe"
            case "Ü": out += "Ue"
            case "ß": out += "ss"
            case "×": out += "x"
            case "·", "•": out += "-"
            case "–", "—", "−": out += "-"
            case "„", "“", "”", "«", "»": out += "\""
            case "‚", "‘", "’", "‹", "›": out += "'"
            case "…": out += "..."
            case "€": out += "EUR"
            case "°": out += "o"
            case "\u{00A0}", "\u{2009}", "\u{202F}": out += " "
            default:
                if character.isASCII {
                    out.append(character)
                } else {
                    let folded = String(character).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                    if !folded.isEmpty, folded.allSatisfy(\.isASCII) {
                        out += folded
                    } else {
                        out += "?"
                    }
                }
            }
        }
        return out
    }

    /// Entfernt Zeilenumbrüche und andere Steuerzeichen (würden zeilenorientierte Befehle beenden).
    static func singleLine(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\r" || scalar == "\n" || scalar == "\t" {
                out.append(" ")
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

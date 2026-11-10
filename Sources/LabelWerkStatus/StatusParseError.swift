import Foundation

/// Fehler beim Auswerten von Druckerantworten (`~HS`, `~HQES`, `~HI`, SGD-JSON).
///
/// Alle Parser dieses Moduls stürzen bei fehlerhaften Eingaben nie ab, sondern werfen
/// einen dieser Fehler (oder liefern – bei den nicht werfenden Parsern – leere Ergebnisse).
public enum StatusParseError: Error, Equatable, Hashable, Sendable, LocalizedError {
    /// Die Antwort war leer oder enthielt nur Steuer- bzw. Leerzeichen.
    case emptyResponse
    /// Ein erwarteter Abschnitt fehlt, z. B. die zweite `~HS`-Zeile oder die `ERRORS:`-Zeile.
    case missingSection(String)
    /// Ein Feld enthält einen Wert, der nicht dem erwarteten Format entspricht.
    case invalidField(name: String, value: String)
    /// Die Antwort hat ein unbekanntes Format (z. B. Antwort auf einen anderen Befehl).
    case unrecognizedFormat(String)
    /// Die SGD-JSON-Antwort ist syntaktisch ungültig.
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Der Drucker hat keine auswertbare Antwort gesendet."
        case .missingSection(let section):
            return "In der Druckerantwort fehlt der Abschnitt „\(section)“."
        case .invalidField(let name, let value):
            return "Ungültiger Wert „\(value)“ im Feld „\(name)“."
        case .unrecognizedFormat(let detail):
            return "Unbekanntes Antwortformat: \(detail)"
        case .invalidJSON(let detail):
            return "Ungültige JSON-Antwort: \(detail)"
        }
    }
}

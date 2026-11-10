import Foundation

/// Fehler beim Suchen, Laden und Installieren von Updates. Alle Texte sind deutsch und direkt
/// für die Oberfläche gedacht.
public enum UpdateError: Error, LocalizedError, Equatable, Sendable {
    /// Kein veröffentlichtes Update gefunden (HTTP 404): Entweder gibt es noch kein Release mit
    /// Update-Informationen, oder das Repository ist privat und es fehlt ein gültiger Zugriffstoken.
    case notPublished
    /// Zugriff verweigert (HTTP 401/403), meist ein ungültiger oder abgelaufener Zugriffstoken.
    case unauthorized
    /// GitHub begrenzt gerade die Anfragen (HTTP 429 bzw. 403 mit ausgeschöpftem Kontingent).
    case rateLimited
    /// Netzwerk- oder Serverfehler (Detailtext).
    case network(String)
    /// Die Update-Informationen sind unvollständig oder unzulässig (Detailtext).
    case invalidManifest(String)
    /// Die geladene Datei hat nicht die erwartete SHA-256-Prüfsumme.
    case checksumMismatch
    /// Die geladene Datei hat nicht die erwartete Größe.
    case sizeMismatch
    /// Das Update benötigt eine neuere macOS-Version (z. B. „15.0“).
    case systemTooOld(required: String)
    /// Die Installation (oder das Ablegen der Update-Datei) ist fehlgeschlagen (Detailtext).
    case installFailed(String)
    /// Vom Benutzer abgebrochen.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notPublished:
            return "Es wurde kein veröffentlichtes Update gefunden. Entweder gibt es noch keine "
                + "Update-Version, oder das Repository ist privat – dann ist unter „Einstellungen › Updates“ "
                + "ein Zugriffstoken nötig (oder er ist ungültig)."
        case .unauthorized:
            return "Der Zugriff auf die Updates wurde verweigert. Bitte den Zugriffstoken unter "
                + "„Einstellungen › Updates“ prüfen (Lesezugriff auf die Inhalte des Repositorys)."
        case .rateLimited:
            return "GitHub hat vorübergehend zu viele Anfragen gezählt. Bitte später erneut nach Updates suchen."
        case .network(let detail):
            return UpdateError.withDetail("Der Update-Server ist nicht erreichbar", detail)
        case .invalidManifest(let detail):
            return UpdateError.withDetail("Die Update-Informationen sind ungültig", detail)
        case .checksumMismatch:
            return "Die geladene Update-Datei ist beschädigt (die Prüfsumme stimmt nicht). Bitte erneut laden."
        case .sizeMismatch:
            return "Die geladene Update-Datei ist unvollständig (die Größe stimmt nicht). Bitte erneut laden."
        case .systemTooOld(let required):
            return "Dieses Update benötigt macOS \(required) oder neuer."
        case .installFailed(let detail):
            return UpdateError.withDetail("Das Update konnte nicht installiert werden", detail)
        case .cancelled:
            return "Das Update wurde abgebrochen."
        }
    }

    private static func withDetail(_ text: String, _ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text + "." : text + ": " + trimmed
    }
}

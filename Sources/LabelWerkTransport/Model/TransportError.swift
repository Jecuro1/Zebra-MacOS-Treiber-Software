import Foundation

/// Fehler der Transportschicht (alle Verbindungsarten).
///
/// Die Texte sind deutsch und direkt für die Oberfläche gedacht (`errorDescription`),
/// `recoverySuggestion` liefert eine konkrete Handlungsempfehlung.
public enum TransportError: Error, LocalizedError, Equatable {
    /// Die Verbindung ist nicht geöffnet (oder wurde lokal geschlossen).
    case notOpen
    /// Zeitüberschreitung beim Verbindungsaufbau oder beim Senden.
    case timeout
    /// Die Gegenstelle (Drucker) hat die Verbindung beendet.
    case closedByPeer
    /// Verbindungsaufbau fehlgeschlagen (Detailtext).
    case connectionFailed(String)
    /// Ein- oder Ausgabefehler während der Übertragung (Detailtext).
    case ioError(String)
    /// Diese Verbindungsart wird auf dieser Plattform bzw. mit diesem Gerät nicht unterstützt.
    case unsupported(String)
    /// Gerät, Warteschlange oder Dienst wurde nicht gefunden.
    case deviceNotFound(String)
    /// Zugriff verweigert (Berechtigung, exklusive Nutzung durch ein anderes Programm …).
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .notOpen:
            return "Die Verbindung zum Drucker ist nicht geöffnet."
        case .timeout:
            return "Der Drucker hat nicht rechtzeitig reagiert (Zeitüberschreitung)."
        case .closedByPeer:
            return "Der Drucker hat die Verbindung beendet."
        case .connectionFailed(let detail):
            return Self.compose("Verbindung zum Drucker fehlgeschlagen", detail)
        case .ioError(let detail):
            return Self.compose("Übertragungsfehler", detail)
        case .unsupported(let detail):
            return Self.compose("Nicht unterstützt", detail)
        case .deviceNotFound(let detail):
            return Self.compose("Gerät nicht gefunden", detail)
        case .permissionDenied(let detail):
            return Self.compose("Zugriff verweigert", detail)
        }
    }

    public var failureReason: String? {
        switch self {
        case .connectionFailed(let detail), .ioError(let detail), .unsupported(let detail),
             .deviceNotFound(let detail), .permissionDenied(let detail):
            return detail.isEmpty ? nil : detail
        case .notOpen, .timeout, .closedByPeer:
            return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notOpen:
            return "Stellen Sie die Verbindung erneut her."
        case .timeout:
            return "Prüfen Sie, ob der Drucker eingeschaltet, nicht pausiert und im Netzwerk bzw. per Kabel erreichbar ist."
        case .closedByPeer:
            return "Der Drucker wurde möglicherweise ausgeschaltet oder neu gestartet. Verbinden Sie sich erneut."
        case .connectionFailed:
            return "Prüfen Sie Adresse, Port (Standard 9100), Kabel bzw. WLAN und ob der Drucker eingeschaltet ist."
        case .ioError:
            return "Wiederholen Sie den Vorgang. Bleibt der Fehler bestehen, trennen Sie die Verbindung und stellen Sie sie neu her."
        case .unsupported:
            return "Wählen Sie eine andere Verbindungsart (z. B. Netzwerk oder CUPS-Warteschlange)."
        case .deviceNotFound:
            return "Prüfen Sie, ob der Drucker angeschlossen und eingeschaltet ist, und suchen Sie erneut nach Druckern."
        case .permissionDenied:
            return "Schließen Sie andere Programme, die den Drucker verwenden, und prüfen Sie die Berechtigungen in den Systemeinstellungen."
        }
    }

    private static func compose(_ title: String, _ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(title)." : "\(title): \(trimmed)"
    }
}

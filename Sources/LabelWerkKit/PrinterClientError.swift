import Foundation
import LabelWerkCore
import LabelWerkTransport

/// Fehler von ``PrinterClient``.
///
/// Fehler der Transportschicht werden als ``transport(_:)`` weitergereicht, Kodierungsfehler
/// (z. B. Z64-Kompression) als ``encodingFailed(_:)``. Abbrüche (`CancellationError`) werden
/// nicht umgewandelt. Alle Texte sind deutsch und direkt für die Oberfläche gedacht.
public enum PrinterClientError: Error, LocalizedError, Equatable, Sendable {
    /// Die Verbindung kann keine Antworten empfangen (z. B. CUPS-Warteschlange); die Operation
    /// benötigt aber eine Antwort des Druckers. Assoziierter Wert: Name der Operation.
    case notBidirectional(String)
    /// Der Drucker hat innerhalb der Frist nicht geantwortet. Assoziierter Wert: Operation.
    case noResponse(String)
    /// Die Antwort des Druckers ließ sich nicht auswerten (Operation, Detail).
    case invalidResponse(String, String)
    /// Die Aktion hat in der eingestellten Druckersprache keine Entsprechung.
    case unsupportedAction(PrinterAction, PrinterLanguage)
    /// Die Operation ist in der eingestellten Druckersprache bzw. mit diesem Drucker nicht möglich.
    case unsupportedOperation(String)
    /// Der Druckauftrag enthält keine Seiten.
    case emptyJob
    /// Ein Argument ist ungültig (Detailtext).
    case invalidArgument(String)
    /// Die Datei ist keine gültige TrueType-/OpenType-Schrift.
    case invalidFont(String)
    /// Ungültige Netzwerkeinstellungen (Detailtext).
    case invalidNetworkSettings(String)
    /// Der Druckauftrag konnte nicht erzeugt werden (Detailtext).
    case encodingFailed(String)
    /// Fehler der Transportschicht (Verbindung, Zeitüberschreitung, …).
    case transport(TransportError)

    public var errorDescription: String? {
        switch self {
        case .notBidirectional(let operation):
            return "„\(operation)“ ist über diese Verbindung nicht möglich, weil sie keine Antworten des Druckers empfangen kann."
        case .noResponse(let operation):
            return "Der Drucker hat auf „\(operation)“ nicht geantwortet."
        case .invalidResponse(let operation, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Die Antwort des Druckers auf „\(operation)“ ist unverständlich."
                : "Die Antwort des Druckers auf „\(operation)“ ist unverständlich: \(trimmed)"
        case .unsupportedAction(let action, let language):
            return "„\(action.displayName)“ ist in \(language.displayName) nicht verfügbar."
        case .unsupportedOperation(let detail):
            return "Nicht unterstützt: \(detail)"
        case .emptyJob:
            return "Der Druckauftrag enthält keine Etiketten."
        case .invalidArgument(let detail):
            return "Ungültige Angabe: \(detail)"
        case .invalidFont(let detail):
            return "Die Schriftdatei ist ungültig: \(detail)"
        case .invalidNetworkSettings(let detail):
            return "Ungültige Netzwerkeinstellungen: \(detail)"
        case .encodingFailed(let detail):
            return "Der Druckauftrag konnte nicht erzeugt werden: \(detail)"
        case .transport(let error):
            return error.errorDescription
        }
    }

    public var failureReason: String? {
        switch self {
        case .transport(let error): return error.failureReason
        default: return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notBidirectional:
            return "Verbinden Sie den Drucker direkt über Netzwerk, USB oder Bluetooth, um Status und Einstellungen abzufragen."
        case .noResponse:
            return "Prüfen Sie, ob der Drucker eingeschaltet und verbunden ist und die gewählte Druckersprache (ZPL, EPL, CPCL) stimmt."
        case .invalidResponse:
            return "Wiederholen Sie den Vorgang. Bleibt der Fehler bestehen, prüfen Sie die Firmware-Version des Druckers."
        case .unsupportedAction, .unsupportedOperation:
            return "Stellen Sie den Drucker auf ZPL um oder verwenden Sie eine passende Funktion."
        case .emptyJob:
            return "Wählen Sie mindestens ein Bild bzw. Etikett aus."
        case .invalidArgument:
            return "Korrigieren Sie die Eingabe und versuchen Sie es erneut."
        case .invalidFont:
            return "Wählen Sie eine TrueType- (.ttf) oder OpenType-Datei (.otf)."
        case .invalidNetworkSettings:
            return "Geben Sie IP-Adresse, Subnetzmaske und Gateway in der Form 192.168.1.20 an."
        case .encodingFailed:
            return "Wählen Sie eine andere Grafikkompression (z. B. Hex) und versuchen Sie es erneut."
        case .transport(let error):
            return error.recoverySuggestion
        }
    }
}

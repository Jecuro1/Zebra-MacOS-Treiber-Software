import Foundation

/// Gemeinsame Schnittstelle aller Druckerverbindungen (TCP, USB, Bluetooth, BLE, CUPS, virtuell).
///
/// Verträge, auf die sich höhere Schichten verlassen:
/// * `open()` ist idempotent: Eine bereits offene Verbindung bleibt unverändert.
/// * `close()` ist idempotent und bricht laufende Lesevorgänge zügig ab
///   (diese werfen dann `TransportError.notOpen`).
/// * `write(_:)` kehrt erst zurück, wenn alle Bytes an das Betriebssystem bzw. Gerät übergeben wurden.
/// * `read(timeout:)` wartet höchstens `timeout` auf Daten und liefert **sofort**, sobald Daten
///   vorliegen (alles, was zu diesem Zeitpunkt verfügbar ist). Eine leere Antwort bedeutet
///   „innerhalb der Frist nichts empfangen“. Hat die Gegenstelle die Verbindung beendet, wirft
///   der nächste Leseaufruf nach den letzten Daten `TransportError.closedByPeer`.
/// * Wird der aufrufende Task abgebrochen, werfen Lese- und Schreibaufrufe `CancellationError`.
public protocol PrinterConnection: AnyObject, Sendable {
    var descriptor: ConnectionDescriptor { get }
    var isOpen: Bool { get async }
    func open() async throws
    func close() async
    func write(_ data: Data) async throws
    /// Liefert die innerhalb von `timeout` empfangenen Daten (leer = nichts empfangen).
    func read(timeout: Duration) async throws -> Data
}

extension PrinterConnection {
    /// Sendet Text als UTF-8.
    public func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    /// Schreibt `data` und sammelt Antworten, bis `isComplete` true liefert, `timeout` abläuft
    /// oder nach erstem Empfang `idleTimeout` lang nichts mehr kommt.
    ///
    /// Genaue Semantik:
    /// * `timeout` begrenzt die gesamte Wartezeit auf Antworten (ab Ende des Schreibens).
    /// * Solange noch nichts empfangen wurde, wird bis zum Ablauf von `timeout` gewartet.
    /// * Nach dem ersten empfangenen Byte endet die Sammlung, sobald `idleTimeout` lang keine
    ///   weiteren Daten eintreffen (oder `timeout` erreicht ist – je nachdem, was früher eintritt).
    /// * `isComplete` wird nach jedem empfangenen Block mit allen bisher gesammelten Daten
    ///   aufgerufen; liefert es `true`, kehrt die Methode sofort zurück.
    /// * Kommt gar keine Antwort, ist das Ergebnis leer (kein Fehler).
    /// * Beendet der Drucker die Verbindung, nachdem bereits Daten empfangen wurden, wird das
    ///   bisher Empfangene geliefert; ohne empfangene Daten wird `closedByPeer` geworfen.
    /// * Vor dem Senden bereits gepufferte, unangeforderte Daten werden **nicht** verworfen
    ///   und zählen zur Antwort. Wer das vermeiden will, liest vorher mit `read(timeout: .zero)`.
    public func request(
        _ data: Data,
        timeout: Duration = .seconds(3),
        idleTimeout: Duration = .milliseconds(400),
        isComplete: @Sendable (Data) -> Bool = { _ in false }
    ) async throws -> Data {
        try await write(data)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        var response = Data()
        while true {
            try Task.checkCancellation()
            let remaining = max(clock.now.duration(to: deadline), .zero)
            let wait = response.isEmpty ? remaining : min(remaining, max(idleTimeout, .zero))
            let chunk: Data
            do {
                chunk = try await read(timeout: wait)
            } catch TransportError.closedByPeer where !response.isEmpty {
                return response
            }
            if chunk.isEmpty {
                // Leere Antwort: entweder Leerlauf nach erstem Empfang oder Frist abgelaufen.
                if !response.isEmpty || clock.now >= deadline { return response }
                continue
            }
            response.append(chunk)
            if isComplete(response) || clock.now >= deadline { return response }
        }
    }
}

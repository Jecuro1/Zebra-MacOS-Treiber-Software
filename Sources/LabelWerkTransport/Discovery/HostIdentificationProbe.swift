import Foundation

/// Kurzidentifikation eines ZPL-Druckers über `~HI` (Host Identification).
///
/// Antwortformat: `STX <Modell>,<Firmware>,<dpmm>,<Speicher>[,<Optionen>] ETX`,
/// z. B. `"\u{2}ZD421-203dpi,V84.20.18Z,8,8192KB\u{3}"`.
enum HostIdentificationProbe {
    struct Identification: Hashable, Sendable {
        var model: String
        var firmware: String?
        var dotsPerMM: Int?
        var memory: String?
        var options: String?
    }

    /// Befehl, der an den Drucker gesendet wird.
    static let command = Data("~HI\r\n".utf8)

    /// Wertet eine `~HI`-Antwort aus (mit oder ohne STX/ETX).
    static func parse(_ data: Data) -> Identification? {
        var bytes = [UInt8](data)
        if let start = bytes.firstIndex(of: 0x02) {
            bytes = Array(bytes[(start + 1)...])
        }
        if let end = bytes.firstIndex(of: 0x03) {
            bytes = Array(bytes[..<end])
        }
        let text = (String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let model = fields.first, !model.isEmpty,
              model.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F })
        else { return nil }
        func field(_ index: Int) -> String? {
            index < fields.count && !fields[index].isEmpty ? fields[index] : nil
        }
        return Identification(
            model: model,
            firmware: field(1),
            dotsPerMM: field(2).flatMap { Int($0) },
            memory: field(3),
            options: fields.count > 4 ? fields[4...].joined(separator: ",") : nil
        )
    }

    /// `true`, sobald die Antwort vollständig ist (ETX empfangen).
    @Sendable static func isComplete(_ data: Data) -> Bool {
        data.contains(0x03)
    }

    /// Öffnet kurz eine TCP-Verbindung, sendet `~HI` und wertet die Antwort aus.
    ///
    /// `~HI` ist druckbarer Text: Nur an Geräte senden, die bereits als Zebra erkannt sind (bzw.
    /// nach ausdrücklicher Freigabe durch den Benutzer) – ein fremder Drucker würde ihn ausdrucken.
    /// Die Entscheidung trifft `PrinterDiscovery.mayProbeWithHostIdentification(isZebra:options:)`.
    static func probe(host: String, port: Int, connectTimeout: Duration, responseTimeout: Duration) async -> Identification? {
        let connection = TCPConnection(host: host, port: port, connectTimeout: connectTimeout, writeTimeout: .seconds(2))
        do {
            try await connection.open()
            let response = try await connection.request(
                command,
                timeout: responseTimeout,
                idleTimeout: .milliseconds(300),
                isComplete: isComplete
            )
            await connection.close()
            return parse(response)
        } catch {
            await connection.close()
            return nil
        }
    }
}

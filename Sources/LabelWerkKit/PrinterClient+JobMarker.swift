import Foundation
import LabelWerkCore

// MARK: - Neustart-Merker
//
// Ob ein Drucker während eines Verbindungsabbruchs aus- und eingeschaltet wurde (und dabei seinen
// Empfangspuffer verloren hat), lässt sich nicht aus `~HS` ablesen: Ein leerer Puffer kann ebenso
// heißen, dass er inzwischen alles gedruckt hat. ``PacedJobSender`` (und das CUPS-Backend
// `labelwerk`) speichern deshalb zu Beginn eines Auftrags eine 1-Byte-Grafik im RAM-Laufwerk `R:`
// (`~DG`). Das RAM-Laufwerk ist nach einem Neustart leer: Fehlt die Datei nach dem Wiederverbinden
// (`^HW`), wurde der Drucker neu gestartet. Siehe ARCHITECTURE.md §7b.

extension PrinterClient {

    /// Speichert den Merker `path` (z. B. `R:LWAPP.GRF`, 1 Byte) mit den Steuerzeichen des Auftrags.
    func storeVolatileMarker(_ path: String, characters: ControlCharacters) async throws {
        try await guarded {
            try await self.transmit(VolatileMarker.storeCommand(path, characters: characters))
        }
    }

    /// Fragt per `^HW` ab, ob der Merker `path` existiert.
    ///
    /// `^HW` ist ein Format: Ein Drucker mit Fehler oder Pause bearbeitet es erst danach – nur
    /// abfragen, wenn er bereit ist.
    /// - Returns: `nil`, wenn keine Dateiliste kommt (Zeitablauf, Drucker ohne `^HW`).
    func volatileMarkerExists(_ path: String, characters: ControlCharacters, timeout: Duration?) async throws -> Bool? {
        try await guarded {
            let data = try await self.exchange(VolatileMarker.queryCommand(path, characters: characters),
                                               operation: "Neustart-Merker (^HW)", timeout: timeout,
                                               isComplete: VolatileMarker.replyComplete)
            return VolatileMarker.listed(path, in: data)
        }
    }

    /// Löscht den Merker (`^ID`) – ohne Fehlerbehandlung, am Auftragsende.
    func deleteVolatileMarker(_ path: String, characters: ControlCharacters) async {
        try? await guarded {
            try await self.transmit(VolatileMarker.deleteCommand(path, characters: characters))
        }
    }
}

/// Befehle und Antwortauswertung des Neustart-Merkers (wie `lwb_parse_directory` im Backend).
enum VolatileMarker {
    static func storeCommand(_ path: String, characters: ControlCharacters) -> String {
        ZPLCommand(.tilde, "DG", [path, "1", "1", "00"]).rendered(with: characters.clamped()) + "\n"
    }

    static func queryCommand(_ path: String, characters: ControlCharacters) -> String {
        let chars = characters.clamped()
        return ZPL.startFormat().rendered(with: chars) + ZPLCommand(.caret, "HW", [path]).rendered(with: chars)
            + ZPL.endFormat().rendered(with: chars) + "\n"
    }

    static func deleteCommand(_ path: String, characters: ControlCharacters) -> String {
        let chars = characters.clamped()
        return ZPL.startFormat().rendered(with: chars) + ZPL.deleteObject(path).rendered(with: chars)
            + ZPL.endFormat().rendered(with: chars) + "\n"
    }

    /// Rahmen STX … ETX in `data`.
    private static func frames(_ data: Data) -> [ArraySlice<UInt8>] {
        let bytes = [UInt8](data)
        var result: [ArraySlice<UInt8>] = []
        var index = 0
        while let start = bytes[index...].firstIndex(of: 0x02) {
            guard let end = bytes[(start + 1)...].firstIndex(of: 0x03) else { break }
            result.append(bytes[(start + 1)..<end])
            index = end + 1
        }
        return result
    }

    /// Ein Rahmen ist eine Dateiliste (`- DIR …` bzw. `… bytes free`), keine andere Antwort (`~HS`).
    private static func isDirectory(_ frame: ArraySlice<UInt8>) -> Bool {
        let text = String(decoding: frame, as: UTF8.self).uppercased()
        return text.contains("BYTES FREE") || text.contains("DIR")
    }

    /// Vollständig, sobald ein Dateilisten-Rahmen mit ETX endet.
    static func replyComplete(_ data: Data) -> Bool {
        frames(data).contains(where: isDirectory)
    }

    /// Nennt die erste Dateiliste in `data` die Datei `path` (Eintragszeile `*R:NAME  größe`)?
    /// `nil`, wenn `data` keine Dateiliste enthält.
    static func listed(_ path: String, in data: Data) -> Bool? {
        guard let frame = frames(data).first(where: isDirectory) else { return nil }
        let wanted = path.uppercased()
        let text = String(decoding: frame, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {   // „\r\n“ ist ein Zeichen
            var rest = line.drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == "*" else { continue }
            rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            let name = rest.prefix(while: { $0 != " " && $0 != "\t" })
            if name.uppercased() == wanted { return true }
        }
        return false
    }
}

import Foundation
@testable import LabelWerkStatus

/// Hilfsfunktionen für die Status-Tests.
enum TestSupport {
    /// Text als UTF-8-Daten.
    static func data(_ text: String) -> Data { Data(text.utf8) }

    /// Rohbytes.
    static func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    /// Fehler eines werfenden Aufrufs, oder `nil` bei Erfolg.
    static func parseError<T>(_ body: () throws -> T) -> StatusParseError? {
        do {
            _ = try body()
            return nil
        } catch let error as StatusParseError {
            return error
        } catch {
            return .unrecognizedFormat("Fremder Fehlertyp: \(error)")
        }
    }

    /// JSON-Round-Trip über `JSONEncoder`/`JSONDecoder`.
    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Deterministischer Zufallsgenerator für Robustheitstests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

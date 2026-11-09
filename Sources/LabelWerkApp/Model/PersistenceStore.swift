import Foundation

/// Lädt und speichert den App-Zustand als JSON in
/// `~/Library/Application Support/LabelWerk/state.json` (atomar, mit Sicherungskopie).
enum PersistenceStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LabelWerk", isDirectory: true)
    }

    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var backupURL: URL { directory.appendingPathComponent("state.backup.json") }

    static func load() -> PersistedState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in [stateURL, backupURL] {
            if let data = try? Data(contentsOf: url),
               let state = try? decoder.decode(PersistedState.self, from: data) {
                return state
            }
        }
        return PersistedState()
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: stateURL, to: backupURL)
            }
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("LabelWerk: Zustand konnte nicht gespeichert werden: \(error)")
        }
    }
}

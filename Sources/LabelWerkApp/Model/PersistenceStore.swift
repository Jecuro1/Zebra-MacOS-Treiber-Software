import Foundation

/// Lädt und speichert den App-Zustand als JSON in
/// `~/Library/Application Support/LabelWerk/state.json` (atomar, mit Sicherungskopie).
///
/// Große Daten liegen in eigenen Dateien, damit `state.json` klein bleibt: die Druckdaten des
/// Verlaufs („Erneut drucken“) unter `Payloads/<Auftrags-ID>.bin`, der Designer-Inhalt in
/// `designer.zpl`. Geschrieben wird im Hintergrund über `PersistenceWriter`.
enum PersistenceStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LabelWerk", isDirectory: true)
    }

    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var backupURL: URL { directory.appendingPathComponent("state.backup.json") }
    static var designerURL: URL { directory.appendingPathComponent("designer.zpl") }
    static var payloadDirectory: URL { directory.appendingPathComponent("Payloads", isDirectory: true) }

    // MARK: Laden

    static func load() -> PersistedState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: PersistedState?
        for url in [stateURL, backupURL] where FileManager.default.fileExists(atPath: url.path) {
            let report = PersistenceDecodeReport()
            decoder.userInfo[PersistenceDecodeReport.key] = report
            do {
                let data = try Data(contentsOf: url)
                let state = try decoder.decode(PersistedState.self, from: data)
                if !report.problems.isEmpty {
                    // Teilweise lesbar: Original sichern, bevor das nächste Speichern es ersetzt.
                    NSLog("LabelWerk: %@ enthielt ungültige Einträge: %@", url.lastPathComponent,
                          report.problems.joined(separator: "; "))
                    preserveCopy(of: url)
                }
                loaded = state
                break
            } catch {
                // Nicht wie „keine Datei“ behandeln: Die Datei bleibt erhalten und wird nicht überschrieben.
                NSLog("LabelWerk: %@ konnte nicht gelesen werden: %@", url.lastPathComponent, "\(error)")
                preserveCopy(of: url)
            }
        }
        var state = loaded ?? PersistedState()
        if let designer = try? String(contentsOf: designerURL, encoding: .utf8) {
            state.designerDocument = designer
        }
        return state
    }

    /// Gespeicherte Druckdaten eines Verlaufseintrags (nach dem Laden liegen sie in einer eigenen Datei).
    static func payload(for job: JobRecord) -> Data? {
        if let payload = job.payload { return payload }
        guard let name = job.payloadFile, isPlainFileName(name) else { return nil }
        return try? Data(contentsOf: payloadDirectory.appendingPathComponent(name))
    }

    // MARK: Speichern (nur über `PersistenceWriter`, nicht auf dem Main-Thread)

    static func save(_ state: PersistedState) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var state = state
            state.history = externalizingPayloads(state.history)
            // Der Designer-Inhalt wird separat gespeichert (`saveDesigner`).
            state.designerDocument = nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            if fm.fileExists(atPath: stateURL.path) {
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: stateURL, to: backupURL)
            }
            try data.write(to: stateURL, options: .atomic)
            removeUnreferencedPayloads(keeping: Set(state.history.compactMap(\.payloadFile)))
        } catch {
            NSLog("LabelWerk: Zustand konnte nicht gespeichert werden: %@", "\(error)")
        }
    }

    static func saveDesigner(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: designerURL, options: .atomic)
        } catch {
            NSLog("LabelWerk: Designer-Inhalt konnte nicht gespeichert werden: %@", "\(error)")
        }
    }

    // MARK: intern

    /// Lagert Druckdaten in eigene Dateien aus; bei einem Schreibfehler bleiben sie im Eintrag.
    private static func externalizingPayloads(_ jobs: [JobRecord]) -> [JobRecord] {
        let fm = FileManager.default
        guard jobs.contains(where: { $0.payload != nil }) else { return jobs }
        do {
            try fm.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        } catch {
            return jobs
        }
        return jobs.map { job in
            guard let payload = job.payload else { return job }
            let name = job.id.uuidString + ".bin"
            let url = payloadDirectory.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) {
                do {
                    try payload.write(to: url, options: .atomic)
                } catch {
                    return job
                }
            }
            var slim = job
            slim.payload = nil
            slim.payloadFile = name
            return slim
        }
    }

    private static func removeUnreferencedPayloads(keeping referenced: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: payloadDirectory.path) else { return }
        for name in names where name.hasSuffix(".bin") && !referenced.contains(name) {
            try? fm.removeItem(at: payloadDirectory.appendingPathComponent(name))
        }
    }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    /// Legt eine Kopie einer (teilweise) unlesbaren Zustandsdatei an, z. B.
    /// `state.unreadable-2026-11-10-142233.json`.
    private static func preserveCopy(of url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let target = directory.appendingPathComponent("\(base).unreadable-\(formatter.string(from: Date())).json")
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: url, to: target)
            }
        } catch {
            NSLog("LabelWerk: Sicherungskopie von %@ fehlgeschlagen: %@", url.lastPathComponent, "\(error)")
        }
    }
}

/// Schreibt den App-Zustand nacheinander auf einer Hintergrund-Warteschlange, damit Kodieren und
/// Schreiben (große Verläufe) die Oberfläche nicht blockieren. Zwischenstände werden
/// zusammengefasst: Je Datei wird nur der jeweils neueste Stand geschrieben.
final class PersistenceWriter: @unchecked Sendable {
    private enum Slot: Hashable { case state, designer }

    private let queue = DispatchQueue(label: "LabelWerk.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: [Slot: () -> Void] = [:]

    func save(_ state: PersistedState) {
        enqueue(.state) { PersistenceStore.save(state) }
    }

    func saveDesigner(_ text: String) {
        enqueue(.designer) { PersistenceStore.saveDesigner(text) }
    }

    /// Wartet, bis alle eingereihten Schreibvorgänge abgeschlossen sind (z. B. beim Beenden).
    func waitUntilIdle() {
        queue.sync {}
    }

    private func enqueue(_ slot: Slot, _ write: @escaping () -> Void) {
        lock.lock()
        let alreadyScheduled = pending[slot] != nil
        pending[slot] = write
        lock.unlock()
        guard !alreadyScheduled else { return }
        queue.async { [self] in
            lock.lock()
            let job = pending.removeValue(forKey: slot)
            lock.unlock()
            job?()
        }
    }
}

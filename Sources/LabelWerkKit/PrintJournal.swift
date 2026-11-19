import Foundation
import LabelWerkCore

// MARK: - Druckjournal („Nachdrucken“)
//
// Jeder fertige Auftrag landet als Ordner im Journal – vom CUPS-Backend `labelwerk` für Aufträge aus
// anderen Mac-Programmen (Standard `/Users/Shared/LabelWerk/Journal`, für Tests `LW_JOURNAL_DIR`), von der
// App für eigene Aufträge (`~/Library/Application Support/LabelWerk/Journal`). Gleiches Layout:
//
//     <journal>/<warteschlange>/<UTC yyyyMMdd-HHmmss>-<auftrag>/job.zpl    Kopf + alle Formate wie gesendet
//     <journal>/<warteschlange>/<UTC yyyyMMdd-HHmmss>-<auftrag>/meta.json
//
// `meta.json`: {"version":1,"queue","jobId","title","user","date" (ISO 8601),"printerURI",
// "labels":[{"index":1,"offset":N,"length":N,"quantity":N}],"prologueLength":N,"printed":N,
// "status":"completed|cancelled|failed"} – `offset`/`length` adressieren das Format in `job.zpl`,
// `quantity` ist seine `^PQ`-Menge; optional `"reprinted"` (Nachdrucke nach Papier-/Farbbandende). Die
// App schreibt zusätzlich `"printerID"` (UUID des Druckers). Ordner mit Punkt am Anfang (unfertige
// Einträge des Backends) werden übergangen.
// Aufbewahrung: je Warteschlange die neuesten 30 Aufträge und höchstens 50 MB; Aufträge über 20 MB
// werden nicht aufgenommen (ARCHITECTURE.md §7b „Druckjournal“).

/// Ein Auftrag im Druckjournal (Inhalt von `meta.json` samt Ordner).
public struct PrintJournalEntry: Sendable, Hashable, Identifiable {

    /// Wie der Auftrag endete.
    public enum Status: String, Codable, Sendable, Hashable {
        case completed, cancelled, failed
    }

    /// Wer den Auftrag gedruckt hat.
    public enum Source: String, Codable, Sendable, Hashable {
        /// macOS-Warteschlange (CUPS-Backend `labelwerk`, auch Aufträge aus anderen Programmen).
        case system
        /// LabelWerk selbst (direkt an den Drucker).
        case app
    }

    /// Ein druckendes Format in `job.zpl`.
    public struct Format: Codable, Sendable, Hashable {
        /// 1-basierte Nummer des Formats.
        public var index: Int
        /// Byte-Bereich in `job.zpl`.
        public var offset: Int
        public var length: Int
        /// `^PQ`-Menge (mindestens 1).
        public var quantity: Int

        public init(index: Int, offset: Int, length: Int, quantity: Int) {
            self.index = index
            self.offset = offset
            self.length = length
            self.quantity = quantity
        }
    }

    /// Ordner des Auftrags (eindeutig, dient als ID).
    public var directory: URL
    public var source: Source
    public var queue: String
    /// CUPS-Auftragsnummer bzw. Nummer der App (als Text, das Backend schreibt eine Zahl).
    public var jobID: String
    public var title: String
    public var user: String
    public var date: Date
    public var printerURI: String
    /// Drucker der App (nur bei ``Source/app``).
    public var printerID: UUID?
    public var formats: [Format]
    public var prologueLength: Int
    /// Gedruckte Etiketten (bei Abbruch/Fehler weniger als ``totalLabels``).
    public var printed: Int
    /// Nachdrucke nach Papier-/Farbbandende (zählen nicht zu ``printed``).
    public var reprinted: Int
    public var status: Status

    public var id: String { directory.standardizedFileURL.path }

    /// Etiketten des Auftrags (Summe der Mengen).
    public var totalLabels: Int { formats.reduce(0) { $0 + max(1, $1.quantity) } }

    /// Lädt `job.zpl` und zerlegt den Auftrag für Vorschau und Nachdruck.
    public func load() throws -> PrintJournalJob {
        let data = try Data(contentsOf: directory.appendingPathComponent(PrintJournal.jobFileName))
        return PrintJournalJob(entry: self, data: data)
    }
}

/// Ein geladener Auftrag aus dem Journal.
public struct PrintJournalJob: Sendable {
    public let entry: PrintJournalEntry
    /// Inhalt von `job.zpl`.
    public let data: Data
    /// Kopf und Formate (nach `meta.json`; passen die Angaben nicht zur Datei, neu zerlegt).
    public let plan: PacedJobPlan

    public init(entry: PrintJournalEntry, data: Data) {
        self.entry = entry
        self.data = data
        self.plan = Self.plan(for: entry, data: data)
    }

    /// Etiketten (Summe der Mengen).
    public var totalLabels: Int { plan.totalLabels }

    /// Ein Etikett (1-basiert) zum Anzeigen: Kopf + sein Format mit Menge 1.
    public func labelData(_ number: Int) -> Data? { plan.labelData(number) }

    /// Erstes Etikett jedes Formats (1-basiert) – für Vorschaubilder je Format.
    public var firstLabelOfFormats: [Int] {
        var result: [Int] = []
        var next = 1
        for segment in plan.segments {
            result.append(next)
            next += segment.quantity
        }
        return result
    }

    /// Auftrag zum Nachdrucken der Etiketten `labels` (1-basiert): Kopf ohne führende „Aufträge
    /// abbrechen“-Zeile (`~JA` würde einen laufenden Auftrag löschen) und die Formate mit passender
    /// Menge (``PacedJobPlan/reprintSegments(forLabels:)``). `nil`, wenn nichts Gültiges gewählt ist.
    public func reprintData(labels: [Int]) -> Data? {
        let segments = plan.reprintSegments(forLabels: labels)
        guard !segments.isEmpty else { return nil }
        var head = plan.prologue
        if let cancel = PrinterClient.cancelPrefixLength(of: head) { head = head.dropFirst(cancel) }
        return segments.reduce(Data(head)) { $0 + $1.data }
    }

    /// Kopf und Formate aus `meta.json`; ohne bzw. mit unpassenden Angaben aus der Datei neu zerlegt.
    static func plan(for entry: PrintJournalEntry, data: Data) -> PacedJobPlan {
        let whole = PacedJobPlan.split(data)
        let bytes = [UInt8](data)
        guard !entry.formats.isEmpty, entry.prologueLength >= 0, entry.prologueLength <= bytes.count else { return whole }
        var segments: [PacedJobPlan.Segment] = []
        for format in entry.formats.sorted(by: { $0.index < $1.index }) {
            guard format.offset >= 0, format.length > 0, format.offset + format.length <= bytes.count else { return whole }
            let slice = Data(bytes[format.offset..<(format.offset + format.length)])
            guard let segment = PacedJobPlan.segment(from: slice, characters: whole.characters) else { return whole }
            segments.append(segment)
        }
        return PacedJobPlan(prologue: Data(bytes[0..<entry.prologueLength]), segments: segments,
                            epilogue: Data(), characters: whole.characters)
    }
}

extension PacedJobPlan {
    /// Ein einzelnes druckendes Format (samt etwaiger Daten davor) als Segment; `nil`, wenn `data` kein
    /// druckendes Format enthält. Mehrere Formate werden zu einem Segment mit der Menge des letzten.
    static func segment(from data: Data, characters: ControlCharacters) -> Segment? {
        let plan = split(data, characters: characters)
        guard let last = plan.segments.last else { return nil }
        let leading = plan.prologue + plan.segments.dropLast().reduce(Data()) { $0 + $1.data }
        let range = last.quantityRange.map { ($0.lowerBound + leading.count)..<($0.upperBound + leading.count) }
        return Segment(data: leading + last.data + plan.epilogue, quantity: last.quantity, quantityRange: range)
    }
}

/// Druckjournal lesen und (für Aufträge der App) schreiben.
public enum PrintJournal {
    public static let jobFileName = "job.zpl"
    public static let metaFileName = "meta.json"
    /// Neueste Aufträge je Warteschlange, die erhalten bleiben.
    public static let maxJobsPerQueue = 30
    /// Höchstgröße je Warteschlange (ältere Aufträge werden gelöscht).
    public static let maxBytesPerQueue = 50 * 1024 * 1024
    /// Größere Aufträge werden nicht aufgenommen.
    public static let maxJobBytes = 20 * 1024 * 1024

    /// Journal des CUPS-Backends: `LW_JOURNAL_DIR` oder `/Users/Shared/LabelWerk/Journal`.
    public static func systemDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment["LW_JOURNAL_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Users/Shared/LabelWerk/Journal", isDirectory: true)
    }

    /// Journal der App: `<Application Support>/LabelWerk/Journal`.
    public static func appDirectory(applicationSupport: URL? = nil) -> URL {
        let base = applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LabelWerk", isDirectory: true).appendingPathComponent("Journal", isDirectory: true)
    }

    // MARK: Lesen

    /// Alle Aufträge unter `root` (alle Warteschlangen), neueste zuerst. Unlesbare Einträge werden
    /// übergangen.
    public static func entries(in root: URL, source: PrintJournalEntry.Source, queue: String? = nil) -> [PrintJournalEntry] {
        let fm = FileManager.default
        let queueDirs: [URL]
        if let queue {
            queueDirs = [root.appendingPathComponent(directoryComponent(forQueue: queue), isDirectory: true)]
        } else {
            queueDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        }
        var result: [PrintJournalEntry] = []
        for queueDir in queueDirs {
            let jobs = (try? fm.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for job in jobs {
                if let entry = entry(at: job, source: source) { result.append(entry) }
            }
        }
        return sorted(result)
    }

    /// Aufträge mehrerer Journale (z. B. System und App), neueste zuerst.
    public static func entries(in roots: [(url: URL, source: PrintJournalEntry.Source)]) -> [PrintJournalEntry] {
        sorted(roots.flatMap { entries(in: $0.url, source: $0.source) })
    }

    /// Liest `meta.json` eines Auftragsordners (`nil`, wenn er fehlt oder unlesbar ist).
    public static func entry(at directory: URL, source: PrintJournalEntry.Source) -> PrintJournalEntry? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(metaFileName)),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return PrintJournalEntry(directory: directory, source: source, queue: meta.queue, jobID: meta.jobId,
                                 title: meta.title, user: meta.user, date: meta.date, printerURI: meta.printerURI,
                                 printerID: meta.printerID.flatMap(UUID.init(uuidString:)),
                                 formats: meta.labels, prologueLength: meta.prologueLength,
                                 printed: meta.printed, reprinted: meta.reprinted, status: meta.status)
    }

    private static func sorted(_ entries: [PrintJournalEntry]) -> [PrintJournalEntry] {
        entries.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
    }

    // MARK: Schreiben (App)

    /// Nimmt einen fertigen Auftrag ins Journal unter `root` auf (Layout wie das CUPS-Backend) und
    /// räumt die Warteschlange danach auf (``prune(queueDirectory:)``). Aufträge ohne druckendes Format
    /// oder über ``maxJobBytes`` werden nicht aufgenommen (`nil`).
    @discardableResult
    public static func record(_ data: Data, characters: ControlCharacters? = nil, queue: String, jobID: String,
                              title: String, user: String, date: Date = Date(), printerURI: String,
                              printerID: UUID? = nil, printed: Int, reprinted: Int = 0,
                              status: PrintJournalEntry.Status, in root: URL) throws -> PrintJournalEntry? {
        guard data.count <= maxJobBytes else { return nil }
        let plan = PacedJobPlan.split(data, characters: characters)
        guard !plan.segments.isEmpty else { return nil }
        var formats: [PrintJournalEntry.Format] = []
        var offset = plan.prologue.count
        for (index, segment) in plan.segments.enumerated() {
            formats.append(.init(index: index + 1, offset: offset, length: segment.data.count, quantity: segment.quantity))
            offset += segment.data.count
        }
        let job = plan.prologue + plan.segments.reduce(Data()) { $0 + $1.data }
        let queueDir = root.appendingPathComponent(directoryComponent(forQueue: queue), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: queueDir, withIntermediateDirectories: true)
        var directory = queueDir.appendingPathComponent(directoryName(date: date, jobID: jobID), isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: directory.path) {
            suffix += 1
            directory = queueDir.appendingPathComponent(directoryName(date: date, jobID: "\(jobID).\(suffix)"), isDirectory: true)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let meta = Meta(version: 1, queue: queue, jobId: jobID, title: title, user: user, date: date,
                        printerURI: printerURI, labels: formats, prologueLength: plan.prologue.count,
                        printed: printed, reprinted: reprinted, status: status, printerID: printerID?.uuidString)
        do {
            try job.write(to: directory.appendingPathComponent(jobFileName), options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(meta).write(to: directory.appendingPathComponent(metaFileName), options: .atomic)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
        prune(queueDirectory: queueDir)
        return entry(at: directory, source: .app)
    }

    /// Behält die neuesten ``maxJobsPerQueue`` Aufträge und höchstens ``maxBytesPerQueue`` (der neueste
    /// bleibt immer); ältere Auftragsordner werden gelöscht. Ordner ohne `meta.json` zählen nach ihrem
    /// Namen (der mit dem Datum beginnt).
    public static func prune(queueDirectory: URL, maxJobs: Int = maxJobsPerQueue, maxBytes: Int = maxBytesPerQueue) {
        let fm = FileManager.default
        guard let jobs = try? fm.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        let dirs = jobs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var bytes = 0
        for (index, dir) in dirs.enumerated() {
            let size = directorySize(dir)
            bytes += size
            if index == 0 { continue }
            if index >= maxJobs || bytes > maxBytes {
                try? fm.removeItem(at: dir)
            }
        }
    }

    // MARK: Namen

    /// `<UTC yyyyMMdd-HHmmss>-<auftrag>`.
    public static func directoryName(date: Date, jobID: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return stamp + "-" + directoryComponent(forQueue: jobID)
    }

    /// Dateisystemtauglicher Name einer Warteschlange bzw. Auftragsnummer (Buchstaben, Ziffern, `-_.`;
    /// alles andere wird `_`).
    public static func directoryComponent(forQueue queue: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var name = String(queue.map { allowed.contains($0) ? $0 : "_" })
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "_" : String(name.prefix(120))
    }

    private static func directorySize(_ dir: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: meta.json

    /// Inhalt von `meta.json` – tolerant gelesen (fehlende Werte mit Standard, `jobId` als Zahl oder Text).
    struct Meta: Codable {
        var version: Int
        var queue: String
        var jobId: String
        var title: String
        var user: String
        var date: Date
        var printerURI: String
        var labels: [PrintJournalEntry.Format]
        var prologueLength: Int
        var printed: Int
        var reprinted: Int
        var status: PrintJournalEntry.Status
        var printerID: String?

        init(version: Int, queue: String, jobId: String, title: String, user: String, date: Date, printerURI: String,
             labels: [PrintJournalEntry.Format], prologueLength: Int, printed: Int, reprinted: Int,
             status: PrintJournalEntry.Status, printerID: String?) {
            self.version = version
            self.queue = queue
            self.jobId = jobId
            self.title = title
            self.user = user
            self.date = date
            self.printerURI = printerURI
            self.labels = labels
            self.prologueLength = prologueLength
            self.printed = printed
            self.reprinted = reprinted
            self.status = status
            self.printerID = printerID
        }

        private enum CodingKeys: String, CodingKey {
            case version, queue, jobId, title, user, date, printerURI, labels, prologueLength, printed, reprinted, status, printerID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            queue = (try? c.decodeIfPresent(String.self, forKey: .queue)) ?? ""
            if let number = try? c.decodeIfPresent(Int.self, forKey: .jobId) {
                jobId = String(number)
            } else {
                jobId = (try? c.decodeIfPresent(String.self, forKey: .jobId)) ?? ""
            }
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            user = (try? c.decodeIfPresent(String.self, forKey: .user)) ?? ""
            let dateText = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? nil
            guard let dateText, let parsed = Self.parseDate(dateText) else {
                throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "Datum fehlt oder ungültig")
            }
            date = parsed
            printerURI = (try? c.decodeIfPresent(String.self, forKey: .printerURI)) ?? ""
            labels = (try? c.decodeIfPresent([PrintJournalEntry.Format].self, forKey: .labels)) ?? []
            prologueLength = (try? c.decodeIfPresent(Int.self, forKey: .prologueLength)) ?? 0
            printed = (try? c.decodeIfPresent(Int.self, forKey: .printed)) ?? 0
            reprinted = (try? c.decodeIfPresent(Int.self, forKey: .reprinted)) ?? 0
            status = (try? c.decodeIfPresent(PrintJournalEntry.Status.self, forKey: .status)) ?? .completed
            printerID = (try? c.decodeIfPresent(String.self, forKey: .printerID)) ?? nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(queue, forKey: .queue)
            if let number = Int(jobId) { try c.encode(number, forKey: .jobId) } else { try c.encode(jobId, forKey: .jobId) }
            try c.encode(title, forKey: .title)
            try c.encode(user, forKey: .user)
            try c.encode(Self.formatDate(date), forKey: .date)
            try c.encode(printerURI, forKey: .printerURI)
            try c.encode(labels, forKey: .labels)
            try c.encode(prologueLength, forKey: .prologueLength)
            try c.encode(printed, forKey: .printed)
            try c.encode(reprinted, forKey: .reprinted)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(printerID, forKey: .printerID)
        }

        /// ISO 8601 mit oder ohne Sekundenbruchteile, mit `Z` oder Zeitzonenversatz.
        static func parseDate(_ text: String) -> Date? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text)
        }

        static func formatDate(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
    }
}

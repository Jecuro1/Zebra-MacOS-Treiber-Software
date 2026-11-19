import Foundation
import Testing
@testable import LabelWerkKit

/// Temporäres Verzeichnis je Test.
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lw-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Schreibt einen Auftragsordner wie das CUPS-Backend (Fixture).
private func writeBackendJob(root: URL, queue: String, dirName: String, job: String, meta: String) throws -> URL {
    let dir = root.appendingPathComponent(queue).appendingPathComponent(dirName)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(job.utf8).write(to: dir.appendingPathComponent("job.zpl"))
    try Data(meta.utf8).write(to: dir.appendingPathComponent("meta.json"))
    return dir
}

private let backendJob = "~JA\n~SD15\n^XA^FO10,10^A0N,30,30^FDA1^FS^PQ1^XZ\n^XA^FO10,10^A0N,30,30^FDB2^FS^PQ3^XZ\n"

/// Offsets passend zu `backendJob`.
private func backendMeta(jobId: String = "42", date: String = "2026-11-13T10:15:30Z", status: String = "completed",
                         labels: String? = nil) -> String {
    let prologue = "~JA\n~SD15\n".utf8.count
    let first = "^XA^FO10,10^A0N,30,30^FDA1^FS^PQ1^XZ".utf8.count
    let second = "\n^XA^FO10,10^A0N,30,30^FDB2^FS^PQ3^XZ".utf8.count
    let list = labels ?? """
    [{"index":1,"offset":\(prologue),"length":\(first),"quantity":1},\
    {"index":2,"offset":\(prologue + first),"length":\(second),"quantity":3}]
    """
    return """
    {"version":1,"queue":"Zebra_ZD421","jobId":\(jobId),"title":"Versand.pdf","user":"anna",
     "date":"\(date)","printerURI":"labelwerk://10.0.0.5:9100?reprint=2","labels":\(list),
     "prologueLength":\(prologue),"printed":4,"reprinted":1,"status":"\(status)","extra":"wird ignoriert"}
    """
}

@Suite("PrintJournal – Druckjournal lesen, schreiben, aufräumen")
struct PrintJournalTests {

    @Test("Auftrag des CUPS-Backends lesen: Metadaten, Etiketten, Nachdruck ohne ~JA")
    func readsBackendFixture() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "20261113-101530-42", job: backendJob,
                            meta: backendMeta())
        let entries = PrintJournal.entries(in: root, source: .system)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.queue == "Zebra_ZD421")
        #expect(entry.jobID == "42")
        #expect(entry.title == "Versand.pdf")
        #expect(entry.user == "anna")
        #expect(entry.status == .completed)
        #expect(entry.printed == 4)
        #expect(entry.reprinted == 1)
        #expect(entry.totalLabels == 4)
        #expect(entry.source == .system)
        #expect(entry.date == Date(timeIntervalSince1970: 1_794_564_930))

        let job = try entry.load()
        #expect(job.totalLabels == 4)
        #expect(job.firstLabelOfFormats == [1, 2])
        let label = String(decoding: try #require(job.labelData(3)), as: UTF8.self)
        #expect(label == "~JA\n~SD15\n\n^XA^FO10,10^A0N,30,30^FDB2^FS^PQ1^XZ")
        let reprint = String(decoding: try #require(job.reprintData(labels: [4, 1])), as: UTF8.self)
        #expect(reprint == "~SD15\n^XA^FO10,10^A0N,30,30^FDA1^FS^PQ1^XZ\n^XA^FO10,10^A0N,30,30^FDB2^FS^PQ1^XZ")
        #expect(job.reprintData(labels: [9]) == nil)
        // Nur eine Warteschlange lesen.
        #expect(PrintJournal.entries(in: root, source: .system, queue: "Zebra_ZD421").count == 1)
        #expect(PrintJournal.entries(in: root, source: .system, queue: "Andere").isEmpty)
    }

    @Test("Tolerant: jobId als Text, Datum mit Versatz/Bruchteilen, falsche Offsets → neu zerlegen, Müll übergehen")
    func tolerantReading() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBackendJob(root: root, queue: "Q", dirName: "a", job: backendJob,
                            meta: backendMeta(jobId: "\"7\"", date: "2026-11-13T11:15:30.250+01:00"))
        try writeBackendJob(root: root, queue: "Q", dirName: "b", job: backendJob,
                            meta: backendMeta(jobId: "8", labels: #"[{"index":1,"offset":5000,"length":10,"quantity":1}]"#))
        try writeBackendJob(root: root, queue: "Q", dirName: "c", job: backendJob, meta: "{kaputt")
        try writeBackendJob(root: root, queue: "Q", dirName: "d", job: backendJob, meta: #"{"queue":"Q"}"#)   // ohne Datum
        let entries = PrintJournal.entries(in: root, source: .system)
        #expect(entries.map(\.jobID).sorted() == ["7", "8"])
        let seven = try #require(entries.first { $0.jobID == "7" })
        #expect(abs(seven.date.timeIntervalSince1970 - 1_794_564_930.25) < 0.01)
        let eight = try #require(entries.first { $0.jobID == "8" })
        let job = try eight.load()
        #expect(job.totalLabels == 4)        // aus der Datei neu zerlegt
        #expect(job.plan.segments.map(\.quantity) == [1, 3])
    }

    @Test("Aufträge der App schreiben (gleiches Layout) und mit dem System-Journal zusammen lesen")
    func recordAndCombine() throws {
        let system = try makeTempDir()
        let app = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: system)
            try? FileManager.default.removeItem(at: app)
        }
        try writeBackendJob(root: system, queue: "Zebra_ZD421", dirName: "20261113-101530-42", job: backendJob,
                            meta: backendMeta())
        let printerID = UUID()
        let date = Date(timeIntervalSince1970: 1_794_568_530)   // eine Stunde später
        let data = Data(("~JA\n" + "^XA^FO0,0^FDX1^FS^XZ\n^XA^FO0,0^FDX2^FS^PQ2^XZ\n^XA^JUS^XZ\n").utf8)
        let written = try #require(try PrintJournal.record(data, queue: "Zebra ZD421/Lager", jobID: "17",
                                                           title: "Etiketten", user: "anna", date: date,
                                                           printerURI: "tcp://10.0.0.5:9100", printerID: printerID,
                                                           printed: 3, status: .completed, in: app))
        #expect(written.directory.lastPathComponent == "20261113-111530-17")
        #expect(written.directory.deletingLastPathComponent().lastPathComponent == "Zebra_ZD421_Lager")
        #expect(written.printerID == printerID)
        #expect(written.queue == "Zebra ZD421/Lager")
        #expect(written.formats.map(\.quantity) == [1, 2])
        let stored = try String(contentsOf: written.directory.appendingPathComponent("job.zpl"), encoding: .utf8)
        #expect(stored == "~JA\n^XA^FO0,0^FDX1^FS^XZ\n^XA^FO0,0^FDX2^FS^PQ2^XZ")
        let meta = try String(contentsOf: written.directory.appendingPathComponent("meta.json"), encoding: .utf8)
        #expect(meta.contains(#""jobId" : 17"#))
        #expect(meta.contains(#""date" : "2026-11-13T11:15:30Z""#))
        let job = try written.load()
        #expect(String(decoding: try #require(job.labelData(3)), as: UTF8.self) == "~JA\n\n^XA^FO0,0^FDX2^FS^PQ1^XZ")

        let combined = PrintJournal.entries(in: [(system, .system), (app, .app)])
        #expect(combined.map(\.source) == [.app, .system])
        // Zweiter Auftrag mit gleicher Sekunde und Nummer: eigener Ordner.
        let again = try #require(try PrintJournal.record(data, queue: "Zebra ZD421/Lager", jobID: "17", title: "E",
                                                         user: "anna", date: date, printerURI: "", printed: 3,
                                                         status: .cancelled, in: app))
        #expect(again.directory != written.directory)
        #expect(again.status == .cancelled)
    }

    @Test("Nicht aufgenommen: ohne druckendes Format, über 20 MB")
    func skipsUnsuitableJobs() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try PrintJournal.record(Data("~JA\n^XA^JUS^XZ".utf8), queue: "Q", jobID: "1", title: "", user: "",
                                        printerURI: "", printed: 0, status: .completed, in: root) == nil)
        var big = Data("^XA^FO0,0^FDX^FS^XZ\n".utf8)
        big.append(Data(repeating: 0x20, count: PrintJournal.maxJobBytes))
        #expect(try PrintJournal.record(big, queue: "Q", jobID: "2", title: "", user: "", printerURI: "",
                                        printed: 1, status: .completed, in: root) == nil)
        #expect(PrintJournal.entries(in: root, source: .app).isEmpty)
    }

    @Test("Aufräumen: höchstens 30 Aufträge und 50 MB je Warteschlange, der neueste bleibt")
    func pruning() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        for index in 0..<33 {
            try PrintJournal.record(Data("^XA^FO0,0^FDJ\(index)^FS^XZ".utf8), queue: "Q", jobID: "\(index)", title: "",
                                    user: "", date: start.addingTimeInterval(Double(index)), printerURI: "",
                                    printed: 1, status: .completed, in: root)
        }
        let entries = PrintJournal.entries(in: root, source: .app)
        #expect(entries.count == PrintJournal.maxJobsPerQueue)
        #expect(entries.first?.jobID == "32")
        #expect(entries.last?.jobID == "3")

        // Größengrenze (hier klein): nur die neuesten, die hineinpassen – mindestens der neueste.
        let queueDir = root.appendingPathComponent("Q")
        PrintJournal.prune(queueDirectory: queueDir, maxBytes: 1)
        #expect(PrintJournal.entries(in: root, source: .app).map(\.jobID) == ["32"])
    }

    @Test("Verzeichnisse: LW_JOURNAL_DIR, Standard, App, Ordnernamen")
    func directories() {
        #expect(PrintJournal.systemDirectory(environment: [:]).path == "/Users/Shared/LabelWerk/Journal")
        #expect(PrintJournal.systemDirectory(environment: ["LW_JOURNAL_DIR": "/tmp/j"]).path == "/tmp/j")
        #expect(PrintJournal.appDirectory(applicationSupport: URL(fileURLWithPath: "/x")).path == "/x/LabelWerk/Journal")
        #expect(PrintJournal.directoryComponent(forQueue: "../a b") == "_a_b")
        #expect(PrintJournal.directoryComponent(forQueue: "") == "_")
        #expect(PrintJournal.directoryName(date: Date(timeIntervalSince1970: 0), jobID: "5") == "19700101-000000-5")
    }
}

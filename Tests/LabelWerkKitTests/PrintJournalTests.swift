import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#endif
@testable import LabelWerkKit

/// Temporäres Verzeichnis je Test.
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lw-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Schreibt einen Auftragsordner wie das CUPS-Backend (Fixture).
@discardableResult
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
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "a", job: backendJob,
                            meta: backendMeta(jobId: "\"7\"", date: "2026-11-13T11:15:30.250+01:00"))
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "b", job: backendJob,
                            meta: backendMeta(jobId: "8", labels: #"[{"index":1,"offset":5000,"length":10,"quantity":1}]"#))
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "c", job: backendJob, meta: "{kaputt")
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "d", job: backendJob,
                            meta: #"{"queue":"Zebra_ZD421"}"#)   // ohne Datum
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

    @Test("Vorschaubild eines Etiketts aus dem Journal: gerendert, verkleinert, Seitenverhältnis")
    func thumbnail() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = "~SD15\n^XA^PW400^LL200^FO20,20^GB360,160,8^FS^PQ2^XZ\n"
        let data = Data(job.utf8)
        let entry = try #require(try PrintJournal.record(data, queue: "Q", jobID: "1", title: "", user: "",
                                                         printerURI: "", printed: 2, status: .completed, in: root))
        let label = try #require(try entry.load().labelData(2))
        let image = try #require(LabelThumbnail.render(label, dotsPerMM: 8, maxSide: 100))
        #expect(image.width == 100)
        #expect(image.height == 50)
        // Der Rahmen (^GB) ist dunkel, die Mitte hell.
        #expect(image.pixels[6 * image.width + 50] < 128)   // Rahmen bei y = 20…28 Punkt → 5…7 px
        #expect(image.pixels[25 * image.width + 50] > 200)
        #expect(LabelThumbnail.render(Data("~JA".utf8)) == nil)
        // Binärdaten (kein gültiges UTF-8) gehen als Latin-1 durch.
        #expect(LabelThumbnail.text(of: Data([0x5E, 0x58, 0x41, 0xFF])) == "^XA\u{FF}")
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

    @Test("Ordnernamen des Backends (lwb_journal_safe_name): Leerzeichen/UTF-8 bleiben, / \\ Steuerzeichen und Punkt am Anfang → _")
    func systemDirectoryNames() throws {
        #expect(PrintJournal.systemDirectoryComponent(forQueue: "Etiketten Lager Ä") == "Etiketten Lager Ä")
        #expect(PrintJournal.systemDirectoryComponent(forQueue: "..x") == "_.x")
        #expect(PrintJournal.systemDirectoryComponent(forQueue: "a/b") == "a_b")
        #expect(PrintJournal.systemDirectoryComponent(forQueue: "Zürich_ß") == "Zürich_ß")
        #expect(PrintJournal.systemDirectoryComponent(forQueue: "a\\b\tc\u{7F}") == "a_b_c_")
        #expect(PrintJournal.systemDirectoryComponent(forQueue: "") == "unbekannt")
        // Filter nach Warteschlange findet Einträge des Backends unter seinem Ordnernamen.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = backendMeta().replacingOccurrences(of: "\"queue\":\"Zebra_ZD421\"", with: "\"queue\":\"Zebra ZD421\"")
        try writeBackendJob(root: root, queue: "Zebra ZD421", dirName: "20261113-101530-42", job: backendJob, meta: meta)
        #expect(PrintJournal.entries(in: root, source: .system, queue: "Zebra ZD421").count == 1)
        #expect(PrintJournal.entries(in: root, source: .system).count == 1)
    }

    @Test("Kopien: printed zählt über alle, letztes gedrucktes Etikett liegt in der letzten Kopie")
    func copies() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = backendMeta().replacingOccurrences(of: "\"printed\":4", with: "\"printed\":6,\"copies\":2")
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "x", job: backendJob, meta: meta)
        let entry = try #require(PrintJournal.entries(in: root, source: .system).first)
        #expect(entry.copies == 2)
        #expect(entry.totalLabels == 4)
        #expect(entry.totalPrintedLabels == 8)
        let job = try entry.load()
        #expect(job.lastPrintedLabel == 2)          // 6 gedruckt: Kopie 1 ganz, Kopie 2 bis Etikett 2
        let plain = try #require(PrintJournal.entries(in: root, source: .system).first)
        #expect(plain.printed == 6)
        // Ohne "copies": 1; printed 0 → letztes Etikett des Auftrags.
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "y", job: backendJob,
                            meta: backendMeta(jobId: "43", date: "2026-11-14T10:15:30Z")
                                .replacingOccurrences(of: "\"printed\":4", with: "\"printed\":0"))
        let newest = try #require(PrintJournal.entries(in: root, source: .system).first)
        #expect(newest.copies == 1)
        #expect(try newest.load().lastPrintedLabel == 4)
    }

    @Test("System-Journal: symbolische Links, fremde Besitzer und Einträge unter fremdem Warteschlangennamen zählen nicht")
    func systemJournalTrust() throws {
        let root = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let fm = FileManager.default
        // Gültig.
        try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "ok", job: backendJob, meta: backendMeta(jobId: "1"))
        // Eintrag mit "queue":"Zebra_ZD421" in einem anderen Ordner (untergeschoben).
        try writeBackendJob(root: root, queue: "x", dirName: "forged", job: backendJob, meta: backendMeta(jobId: "2"))
        // Warteschlangenordner als symbolischer Link.
        try writeBackendJob(root: elsewhere, queue: "Zebra_ZD421", dirName: "linked", job: backendJob,
                            meta: backendMeta(jobId: "3"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Andere"),
                                  withDestinationURL: elsewhere.appendingPathComponent("Zebra_ZD421"))
        // Eintrag als symbolischer Link.
        try fm.createSymbolicLink(at: root.appendingPathComponent("Zebra_ZD421").appendingPathComponent("link"),
                                  withDestinationURL: elsewhere.appendingPathComponent("Zebra_ZD421").appendingPathComponent("linked"))
        if geteuid() == 0 {
            // Ordner eines anderen Benutzers (nur als root prüfbar).
            let foreign = try writeBackendJob(root: root, queue: "Zebra_ZD421", dirName: "foreign", job: backendJob,
                                              meta: backendMeta(jobId: "4"))
            try fm.setAttributes([.ownerAccountID: 4242], ofItemAtPath: foreign.path)
        }
        #expect(PrintJournal.entries(in: root, source: .system).map(\.jobID) == ["1"])
        // Das Journal der App prüft das nicht (eigener Ordner des Benutzers).
        #expect(PrintJournal.entries(in: root, source: .app).count >= 2)
    }
}

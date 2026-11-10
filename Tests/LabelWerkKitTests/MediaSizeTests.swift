import Foundation
import Testing
@testable import LabelWerkKit

/// Etikettengröße vom Drucker lesen (`PrinterClient.readMediaSize()`), PPD-Dateien lesen und für eine
/// Warteschlange ergänzen, Abgleich mit dem PPD-Generator.
@Suite("Etikettengröße: Drucker, PPD-Dateien, Generator")
struct MediaSizeTests {

    // MARK: - readMediaSize

    @Test("ZD421t mit 104 × 76,2 mm (wie in ZDesigner): SGD-Werte")
    func readFromSGD() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.loadMedia(widthDots: 832, lengthDots: 609, tracking: .gap)
        let client = await KitTestSupport.makeClient(printer)
        let media = try #require(await client.readMediaSize())
        #expect(media.widthDots == 832 && media.lengthDots == 609)
        #expect(media.resolution == .dpi203)
        #expect(media.widthMM == 104 && media.heightMM == 76.2)
        #expect(media.sizeText == "104 × 76,2 mm")
        #expect(media.tracking == .gap)
        #expect(media.mediaType == .thermalTransfer)
        #expect(media.lengthSource == .sgd)
        #expect(media.labelSize.keyword == "w295h216")
    }

    @Test("Schwarze Markierungen und Endlosmaterial mit Länge")
    func trackingKinds() async throws {
        let printer = try await KitTestSupport.makePrinter()
        let client = await KitTestSupport.makeClient(printer)
        await printer.loadMedia(lengthDots: 406, tracking: .blackMark)
        #expect(await client.readMediaSize()?.tracking == .blackMark)
        await printer.loadMedia(lengthDots: 1218, tracking: .continuous)
        let continuous = try #require(await client.readMediaSize())
        #expect(continuous.tracking == .continuous && continuous.heightMM == 152.4)
    }

    @Test("Ohne SGD: Länge aus ~HS, Breite vom erkannten Katalogmodell")
    func hostStatusFallback() async throws {
        let printer = try await KitTestSupport.makePrinter()
        await printer.loadMedia(widthDots: 832, lengthDots: 610, tracking: .gap)
        await printer.setSupportsSGD(false)
        // Ohne Identität: Auflösung aus ~HI, aber keine Breite → nil.
        let fresh = await KitTestSupport.makeClient(printer)
        #expect(await fresh.readMediaSize() == nil)
        // Nach identify() (~HI „ZD421-203dpi“ → Katalogmodell): Breite = Druckbreite des Modells.
        let client = await KitTestSupport.makeClient(printer)
        let identity = try await client.identify()
        let model = try #require(identity.matchedModel)
        let media = try #require(await client.readMediaSize())
        #expect(media.lengthSource == .hostStatus)
        #expect(media.lengthDots == 610 && media.heightMM == 76.2)
        #expect(media.widthDots == model.printWidthDots(.dpi203))
        #expect(media.widthMM == 104)
        #expect(media.tracking == nil && media.mediaType == nil)
    }

    @Test("EPL, CPCL und Verbindungen ohne Rückkanal: nil")
    func unsupported() async throws {
        let printer = try await KitTestSupport.makePrinter()
        for language in [PrinterLanguage.epl, .cpcl] {
            let client = await KitTestSupport.makeClient(printer, language: language)
            #expect(await client.readMediaSize() == nil)
        }
        let queue = await KitTestSupport.makeClient(CUPSQueueConnection(queue: "LabelWerkTest"))
        #expect(await queue.readMediaSize() == nil)
    }

    // MARK: - gzip & PPD-Dateien

    @Test("gzip entpacken (auch mehrteilig), Daten ohne gzip unverändert")
    func gunzip() throws {
        let plain = Data("Hallo LabelWerk\n".utf8)
        #expect(try Gzip.decompress(plain) == plain)
        // `printf 'Hallo LabelWerk\n' | gzip -9n | xxd -i`
        let member: [UInt8] = [
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0xf3, 0x48, 0xcc, 0xc9, 0xc9, 0x57,
            0xf0, 0x49, 0x4c, 0x4a, 0xcd, 0x09, 0x4f, 0x2d, 0xca, 0xe6, 0x02, 0x00, 0x2e, 0x37, 0xa2, 0xe8,
            0x10, 0x00, 0x00, 0x00,
        ]
        #expect(Gzip.isCompressed(Data(member)))
        #expect(try Gzip.decompress(Data(member)) == plain)
        #expect(try Gzip.decompress(Data(member + member)) == plain + plain)
        #expect(throws: (any Error).self) { try Gzip.decompress(Data(member.dropLast(6))) }
    }

    @Test("Generierte PPDs: Seitengrößen wie PPDPageSizes, ergänzte Kopie besteht cupstestppd")
    func generatorCrossCheck() async throws {
        guard let python = GeneratorSupport.python else {
            Issue.record("python3 fehlt – Abgleich mit Driver/ppd/generate_ppds.py nicht möglich")
            return
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lw-ppd-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: output) }
        let status = try GeneratorSupport.run(python, ["-I", GeneratorSupport.generator.path, "--output", output.path, "--gzip"])
        #expect(status == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".ppd.gz") }.sorted()
        #expect(files.count > 50, "Erwartet alle Modell- und generischen PPDs")
        let size = QueueLabelSize(widthMM: 104, heightMM: 76.2)
        var patchedSamples: [URL] = []
        for file in files {
            let path = output.appendingPathComponent(file).path
            let text = try PPDFiles.read(path)
            let target = try #require(PPDPageSizes.target(forPPDNamed: file), "\(file)")
            #expect(QueuePPD.pageSizeKeywords(in: text) == PPDPageSizes.keywords(forPPDNamed: file),
                    "Seitengrößen von \(file) weichen von PPDPageSizes ab")
            #expect(QueuePPD.defaultPageSize(in: text) == PPDPageSizes.defaultKeyword(for: target.target), "\(file)")
            #expect(QueuePPD.baseStem(of: text) == String(file.dropLast(7)), "\(file)")
            // Jede PPD lässt sich ergänzen; ergänzt wird nur, was fehlt.
            let patched = try QueuePPD.patched(text, adding: size)
            #expect(QueuePPD.defaultPageSize(in: patched) == size.keyword)
            #expect(PPDFiles.containsPageSize(size, basePPD: path) == QueuePPD.pageSizeKeywords(in: text).contains(size.keyword))
            if file == "LabelWerk-zd421t-203dpi.ppd.gz" || file.hasPrefix("LabelWerk-generic-") {
                let url = output.appendingPathComponent(file.replacingOccurrences(of: ".ppd.gz", with: "-patched.ppd"))
                try PPDFiles.write(patched, to: url)
                patchedSamples.append(url)
            }
        }
        #expect(!PPDFiles.containsPageSize(size, basePPD: output.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd.gz").path))
        // Treiber-Update: Der postinstall (awk) übernimmt die ergänzte Größe einer Warteschlange in die
        // neue Modell-PPD mit demselben Ergebnis wie QueuePPD.patched und setzt lwLabelWidth/lwLabelHeight.
        if let bash = GeneratorSupport.executable(["bash"]) {
            for url in patchedSamples {
                let base = output.appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: "-patched.ppd", with: ".ppd.gz"))
                let carried = output.appendingPathComponent(url.lastPathComponent + ".carried")
                let script = try PostinstallSupport.functions("patch_added_size", "label_size_defaults", "added_page_size")
                    + "\nset -euo pipefail\n"
                    + "added=\"$(added_page_size \"$1\")\"\n"
                    + "patch_added_size \"$1\" \"$2\" \"$3\" \"$added\"\n"
                    + "label_size_defaults \"$1\"\n"
                let result = try GeneratorSupport.capture(bash, ["-c", script, "postinstall", url.path, base.path, carried.path])
                #expect(result.status == 0, "\(url.lastPathComponent): \(result.output)")
                #expect(result.output == "lwLabelWidth-default=10400\nlwLabelHeight-default=7620\n", "\(result.output)")
                let expected = try QueuePPD.patched(try PPDFiles.read(base.path), adding: size)
                #expect(try PPDFiles.read(carried.path) == expected, "postinstall ≠ QueuePPD.patched für \(base.lastPathComponent)")
            }
        }
        // cupstestppd (falls vorhanden) wie generate_ppds.py --check: -I filters, Übersetzungen streng.
        guard let cupstestppd = GeneratorSupport.cupstestppd else { return }
        for url in patchedSamples {
            let result = try GeneratorSupport.capture(cupstestppd, ["-I", "filters", "-W", "translations", url.path],
                                                      environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                                                                    "SOFTWARE": "CUPS/2.3"])
            #expect(result.status == 0 && result.output.contains(": PASS"), "\(url.lastPathComponent): \(result.output)")
        }
    }

    @Test("Ergänzte Kopie einer Modell-PPD lesen und die Größe wiedererkennen")
    func patchedFileRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lw-ppdfile-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = QueueLabelSize(widthMM: 104, heightMM: 76.2)
        let base = directory.appendingPathComponent("LabelWerk-zd421t-203dpi.ppd")
        try PPDFiles.write(QueuePPDSample.text, to: base)
        #expect(!PPDFiles.containsPageSize(size, basePPD: base.path))
        // Die installierte Datei entscheidet, nicht der Katalog der App (Treiber und App können
        // verschiedene Versionen haben); ohne lesbare Datei gilt der Dateiname.
        let sampleSizes = QueuePPD.pageSizeKeywords(in: QueuePPDSample.text)
        #expect(PPDFiles.installedPageSizes(basePPD: base.path) == sampleSizes)
        let catalogOnly = ModelCatalog.shared.stocks.map(QueueLabelSize.init(stock:)).first {
            PPDPageSizes.keywords(forPPDNamed: base.path)?.contains($0.keyword) == true && !sampleSizes.contains($0.keyword)
        }
        #expect(catalogOnly != nil)
        if let catalogOnly {
            #expect(!PPDFiles.containsPageSize(catalogOnly, basePPD: base.path))
            let missing = directory.appendingPathComponent("fehlt/LabelWerk-zd421t-203dpi.ppd.gz").path
            #expect(PPDFiles.containsPageSize(catalogOnly, basePPD: missing))
        }
        let patched = try PPDFiles.patchedText(basePPD: base.path, size: size)
        #expect(PPDFiles.addedLabelSize(inQueuePPD: patched) == size)
        #expect(PPDFiles.defaultLabelSize(in: patched)?.keyword == "w295h216")
        #expect(PPDFiles.defaultLabelSize(in: QueuePPDSample.text)?.keyword == "w288h432")
        #expect(PPDFiles.addedLabelSize(inQueuePPD: QueuePPDSample.text) == nil)
        let temporary = PPDFiles.temporaryPath(queue: "Büro Zebra/1", size: size, directory: directory)
        #expect(temporary.lastPathComponent == "B_ro_Zebra_1-w295h216.ppd")
        try PPDFiles.write(patched, to: temporary)
        #expect(try PPDFiles.read(temporary.path) == patched)
        PPDFiles.removeTemporary(temporary)
        #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
        #expect(throws: PPDFiles.FileError.self) { try PPDFiles.read(directory.appendingPathComponent("fehlt.ppd").path) }
    }
}

/// Minimale LabelWerk-PPD (Aufbau wie `generate_ppds.py`) für Dateitests.
enum QueuePPDSample {
    static let text = """
    *PPD-Adobe: "4.3"
    *lwModel: "zd421t"
    *OpenUI *PageSize/Media Size: PickOne
    *DefaultPageSize: w288h432
    *PageSize w288h432/4 x 6 in (Shipping): "<</PageSize[288 432]/ImagingBBox null>>setpagedevice"
    *CloseUI: *PageSize
    *de.Translation PageSize/Etikettenformat: ""
    *de.PageSize w288h432/4 × 6 Zoll (Versand): ""
    *OpenUI *PageRegion/Media Size: PickOne
    *DefaultPageRegion: w288h432
    *PageRegion w288h432/4 x 6 in (Shipping): "<</PageSize[288 432]/ImagingBBox null>>setpagedevice"
    *CloseUI: *PageRegion
    *de.Translation PageRegion/Etikettenformat: ""
    *de.PageRegion w288h432/4 × 6 Zoll (Versand): ""
    *DefaultImageableArea: w288h432
    *ImageableArea w288h432/4 x 6 in (Shipping): "0 0 288 432"
    *DefaultPaperDimension: w288h432
    *PaperDimension w288h432/4 x 6 in (Shipping): "288 432"
    *DefaultResolution: 203dpi

    """
}

/// Funktionen aus dem postinstall des Treibers (Installer/pkg/scripts/driver/postinstall).
enum PostinstallSupport {
    static var script: URL {
        GeneratorSupport.repositoryRoot.appendingPathComponent("Installer/pkg/scripts/driver/postinstall")
    }

    /// Schneidet Funktionsdefinitionen („name() {“ … „}“ am Zeilenanfang) aus dem Skript aus.
    static func functions(_ names: String...) throws -> String {
        let lines = try String(contentsOf: script, encoding: .utf8).components(separatedBy: "\n")
        var parts: [String] = []
        for name in names {
            guard let start = lines.firstIndex(of: "\(name)() {"),
                  let end = lines[start...].firstIndex(of: "}") else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Funktion \(name) fehlt"])
            }
            parts.append(lines[start...end].joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

/// Python-Generator und cupstestppd für den Abgleich.
enum GeneratorSupport {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var generator: URL { repositoryRoot.appendingPathComponent("Driver/ppd/generate_ppds.py") }

    static func executable(_ names: [String]) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            for name in names {
                let candidate = "\(directory)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static let python: String? = executable(["python3", "python"])
    static let cupstestppd: String? = executable(["cupstestppd"])

    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        try capture(executable, arguments).status
    }

    static func capture(_ executable: String, _ arguments: [String],
                        environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for key in ["LC_MESSAGES", "LC_CTYPE", "LANGUAGE"] { env.removeValue(forKey: key) }
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

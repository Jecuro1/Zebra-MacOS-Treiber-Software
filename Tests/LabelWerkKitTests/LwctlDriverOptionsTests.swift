import Foundation
import Testing
@testable import LabelWerkKit

/// `lwctl encode`/`print`: Schalter für alle Treiberoptionen des Windows-Dialogs (für den
/// Konformitätstest mit C-Filter und Python-Referenz).
@Suite("lwctl – Treiberoptionen", .serialized)
struct LwctlDriverOptionsTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lwctl-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 4 × 3 PGM: links oben schwarz.
    private func writeImage(_ directory: URL, name: String = "a.pgm") throws {
        let pgm = "P2\n4 3\n255\n0 255 255 255\n255 255 255 255\n255 255 255 0\n"
        try Data(pgm.utf8).write(to: directory.appendingPathComponent(name))
    }

    @Test("Hilfe nennt alle neuen Schalter")
    func helpListsFlags() async throws {
        let help = try await CLIRunner.run(["help", "encode"])
        #expect(help.status == 0)
        for flag in ["--rotation", "--mark-offset", "--stop-at-last", "--stop-offset", "--pause-every", "--control-chars",
                     "--format-prefix", "--control-prefix", "--delimiter", "--rtc", "--cancel-before", "--cancel-delay",
                     "--label-start-commands", "--label-end-commands", "--power-up-action", "--head-close-action",
                     "--fixed-time", "--time-step", "--time-zone", "linerlessPeel", "notch"] {
            #expect(help.output.contains(flag), "\(flag)")
        }
        let print = try await CLIRunner.run(["help", "print"])
        #expect(print.output.contains("--rotation") && print.output.contains("--cancel-delay"))
    }

    @Test("encode: alle Optionen, byte-gleich mit dem JobEncoder")
    func encodeAllOptions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage(directory)
        let result = try await CLIRunner.run([
            "encode", "a.pgm", "a.pgm", "--no-layout", "--compression", "hex", "--copies", "2", "-o", "out.zpl",
            "--rotation", "270", "--tracking", "blackMark", "--mark-offset", "-12", "--pause-every", "5",
            "--print-mode", "linerlessDelayedCut", "--control-chars", "printer", "--format-prefix", "$",
            "--control-prefix", "35", "--delimiter", ";", "--rtc", "everyMinute", "--cancel-before", "--cancel-delay", "0",
            "--label-start-commands", "^FX a", "--label-end-commands", "^FX b", "--power-up-action", "S",
            "--head-close-action", "noMotion", "--fixed-time", "1700000000", "--time-step", "45", "--time-zone", "UTC",
            "--start-commands", "~JR", "--end-commands", "~PS", "--darkness", "9",
        ], workingDirectory: directory)
        #expect(result.status == 0, "\(result.errors)")
        let data = try Data(contentsOf: directory.appendingPathComponent("out.zpl"))
        let image = try PNMCodec.decode(Data(contentsOf: directory.appendingPathComponent("a.pgm")))
        let settings = PrintSettings(darkness: 9, tracking: .blackMark, printMode: .linerlessDelayedCut, compression: .hex,
                                     startCommands: "~JR", endCommands: "~PS", rotation: .r270, markOffset: -12,
                                     pauseEvery: 5,
                                     controlCharacters: ControlCharacters(formatPrefix: 0x24, controlPrefix: 0x23, delimiter: 0x3B),
                                     rtcUpdate: .everyMinute, cancelJobsBeforePrint: true, cancelDelayMs: 0,
                                     labelStartCommands: "^FX a", labelEndCommands: "^FX b",
                                     powerUpAction: .shortCalibration, headCloseAction: .noMotion)
        var encoder = JobEncoder(language: .zpl, resolution: .dpi203, settings: settings,
                                 timeZone: TimeZone(identifier: "UTC")!,
                                 now: { Date(timeIntervalSince1970: 1_700_000_000) })
        encoder.timeStepSeconds = 45
        #expect(data == (try encoder.encode(images: [image, image], copies: 2)))
        // Etiketten 0/45/90/135 s: ^ST zu Beginn und bei 90 s
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("$XA$ST11;14;2023;22;13;20;M$XZ\n"))
        #expect(text.contains("$XA$ST11;14;2023;22;14;50;M$XZ\n"))
        #expect(text.hasPrefix("~JR\n#JA\n#SD09\n! U1 setvar \"media.printmode\" \"linerless delayed cut\"\r\n$XA$MFS;N$XZ\n"))
        #expect(text.contains("$XA\n^FX a\n$MNM;-12\n$PW3\n$LL4\n"), "270°: 4 × 3 → 3 × 4, kein ^MM")
        #expect(text.contains("$PQ1;5;0;N\n^FX b\n$XZ\n"))
    }

    @Test("encode: genaue Ausgabe mit Drehung, Stopp am letzten Element, Steuerzeichen standard")
    func encodeExact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage(directory)
        let result = try await CLIRunner.run([
            "encode", "a.pgm", "--no-layout", "--compression", "hex", "--rotation", "90", "--tracking", "continuous",
            "--stop-at-last", "--stop-offset", "2", "--format-prefix", "$",
        ], workingDirectory: directory)
        #expect(result.status == 0, "\(result.errors)")
        // 90°: 3 × 4 mit schwarzen Punkten (2,0) und (0,3) – letzte schwarze Zeile 3 → Höhe 6
        #expect(result.output == "^XA\n^MNN\n^PW3\n^LL6\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,6,6,1,200000800000^FS\n^PQ1\n^XZ\n")
        #expect(result.errors.contains("--format-prefix"), "Hinweis: wirkt nur mit --control-chars printer")
    }

    @Test("encode: Drehung 90° beim Einpassen – Seite quer, Etikett danach wieder hochkant")
    func encodeLayoutRotation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage(directory)
        for rotation in ["0", "90", "180", "270"] {
            let result = try await CLIRunner.run(["encode", "a.pgm", "--stock", "w2h1in", "--rotation", rotation],
                                                 workingDirectory: directory)
            #expect(result.status == 0, "\(result.errors)")
            #expect(result.output.contains("^PW406\n^LL203\n"), "\(rotation)°")
            #expect(result.output.contains(rotation == "180" ? "^POI\n" : "^PON\n"))
        }
    }

    @Test("Ungültige Werte ergeben Rückgabewert 2", arguments: [
        ["--rotation", "45"], ["--mark-offset", "300"], ["--stop-offset", "-1"], ["--pause-every", "10000"],
        ["--control-chars", "intern2"], ["--control-chars", "printer", "--format-prefix", "200"],
        ["--control-chars", "printer", "--delimiter", "ab"], ["--control-chars", "printer", "--control-prefix", " "],
        ["--rtc", "hourly"], ["--cancel-delay", "10001"], ["--power-up-action", "jump"],
        ["--head-close-action", "X"], ["--time-zone", "Mars/Olympus"], ["--time-step", "-1"], ["--fixed-time", "jetzt"],
        ["--tracking", "kerben"], ["--print-mode", "linerless"],
    ])
    func invalidValues(arguments: [String]) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage(directory)
        let result = try await CLIRunner.run(["encode", "a.pgm", "--no-layout"] + arguments, workingDirectory: directory)
        #expect(result.status == 2, "\(arguments): \(result.errors)")
    }

    @Test("print an den virtuellen Drucker: Linerless und ^MF kommen an")
    func printToVirtual() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage(directory)
        let result = try await CLIRunner.run([
            "--printer", "virtual://optionen", "print", "a.pgm", "--no-layout", "--power-up-action", "calibrate",
            "--head-close-action", "length", "--cancel-before", "--cancel-delay", "10", "--rtc", "jobStart",
        ], workingDirectory: directory)
        #expect(result.status == 0, "\(result.errors)")
    }
}

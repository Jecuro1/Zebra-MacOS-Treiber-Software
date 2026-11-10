import Foundation
import Testing
import LabelWerkBarcode
import LabelWerkCore
import LabelWerkImaging
@testable import LabelWerkRender

/// Hilfsfunktionen der Render-Tests.
enum TestSupport {

    /// Interpretiert ZPL mit 8 Punkten/mm und 812 × 1218 Punkten Standardgröße.
    static func render(_ zpl: String, dotsPerMM: Int = 8, width: Int = 812, height: Int = 1218) -> LabelDocument {
        ZPLInterpreter(dotsPerMM: dotsPerMM, defaultWidthDots: width, defaultHeightDots: height).render(zpl)
    }

    /// Das einzige Etikett eines Datenstroms (Testfehler, falls nicht genau eines entsteht).
    static func label(_ zpl: String, dotsPerMM: Int = 8, width: Int = 812, height: Int = 1218,
                      sourceLocation: SourceLocation = #_sourceLocation) -> RenderedLabel {
        let document = render(zpl, dotsPerMM: dotsPerMM, width: width, height: height)
        #expect(document.labels.count == 1, "erwartet genau ein Etikett", sourceLocation: sourceLocation)
        return document.labels.first ?? RenderedLabel(widthDots: width, heightDots: height)
    }

    static func texts(_ label: RenderedLabel) -> [TextElement] {
        label.elements.compactMap { if case .text(let e) = $0 { return e } else { return nil } }
    }

    static func boxes(_ label: RenderedLabel) -> [BoxElement] {
        label.elements.compactMap { if case .box(let e) = $0 { return e } else { return nil } }
    }

    static func graphics(_ label: RenderedLabel) -> [GraphicElement] {
        label.elements.compactMap { if case .graphic(let e) = $0 { return e } else { return nil } }
    }

    static func linearBarcodes(_ label: RenderedLabel) -> [LinearBarcodeElement] {
        label.elements.compactMap { if case .linearBarcode(let e) = $0 { return e } else { return nil } }
    }

    static func matrixBarcodes(_ label: RenderedLabel) -> [MatrixBarcodeElement] {
        label.elements.compactMap { if case .matrixBarcode(let e) = $0 { return e } else { return nil } }
    }

    /// Bitmap aus Zeilenstrings, `#` = schwarz, `.` = weiß.
    static func bitmap(_ rows: [String]) -> MonoBitmap {
        let width = rows.first?.count ?? 0
        let characters = rows.map { Array($0) }
        return MonoBitmap(width: width, height: rows.count) { x, y in characters[y][x] == "#" }
    }

    /// Bitmap-Ausschnitt als Zeilenstrings.
    static func rows(_ bitmap: MonoBitmap, x: Int = 0, y: Int = 0, width: Int? = nil, height: Int? = nil) -> [String] {
        let w = width ?? bitmap.width, h = height ?? bitmap.height
        return (y..<(y + h)).map { row in
            String((x..<(x + w)).map { column in
                column >= 0 && column < bitmap.width && row >= 0 && row < bitmap.height && bitmap[column, row] ? "#" : "."
            })
        }
    }

    /// Umschließendes Rechteck aller schwarzen Punkte (`nil` bei leerer Bitmap).
    static func inkBounds(_ bitmap: MonoBitmap) -> (x: Int, y: Int, width: Int, height: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<bitmap.height where !bitmap.isRowBlank(y) {
            for x in 0..<bitmap.width where bitmap[x, y] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Anzahl schwarzer Punkte im Rechteck.
    static func blackCount(_ bitmap: MonoBitmap, x: Int, y: Int, width: Int, height: Int) -> Int {
        var count = 0
        for row in max(0, y)..<min(bitmap.height, y + height) {
            for column in max(0, x)..<min(bitmap.width, x + width) where bitmap[column, row] { count += 1 }
        }
        return count
    }

    // MARK: Externe Rückleser (zxing-cpp)

    /// Python-Interpreter mit zxing-cpp und Pillow: `LABELWERK_ZXING_PYTHON`, sonst die virtuelle
    /// Umgebung der Entwicklungsmaschine. Fehlt er, werden die Rückleser-Tests übersprungen.
    static let pythonPath = ProcessInfo.processInfo.environment["LABELWERK_ZXING_PYTHON"]
        ?? "/tmp/claude-0/-home-user-Zebra-MacOS-Treiber-Software/865082b1-4cb8-59eb-9b78-8386e46dc137/scratchpad/pyenv/bin/python"

    static var hasZXing: Bool { FileManager.default.isExecutableFile(atPath: pythonPath) }

    /// Eigenes temporäres Verzeichnis je Testlauf.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelWerkRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Dekodiert alle Barcodes einer Bitmap mit zxing-cpp; Ergebnis: Liste von (Format, Text).
    static func decode(_ bitmap: MonoBitmap) throws -> [(format: String, text: String)] {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("label.png")
        try PNGCodec.encode(bitmap).write(to: png)
        let script = """
        import sys, zxingcpp
        from PIL import Image
        image = Image.open(sys.argv[1]).convert("L")
        for result in zxingcpp.read_barcodes(image):
            print(getattr(result.format, "name", str(result.format)) + "\\t" + result.text.encode("unicode_escape").decode("ascii"))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-I", "-c", script, png.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), unescape(String(parts[1])))
        }
    }

    /// Kehrt Pythons `unicode_escape` für die Testdaten um (\\xNN, \\uNNNN, \\\\).
    private static func unescape(_ text: String) -> String {
        var result = ""
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            guard character == "\\", let kind = characters.popFirst() else {
                result.append(character)
                continue
            }
            let length: Int
            switch kind {
            case "x": length = 2
            case "u": length = 4
            case "U": length = 8
            case "\\": result.append("\\"); continue
            case "n": result.append("\n"); continue
            case "t": result.append("\t"); continue
            case "r": result.append("\r"); continue
            default: result.append("\\"); result.append(kind); continue
            }
            let digits = String(characters.prefix(length))
            characters = characters.dropFirst(length)
            if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: Zufall

    /// Deterministischer Zufallsgenerator (SplitMix64).
    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func element<T>(_ array: [T]) -> T { array[int(0...(array.count - 1))] }
    }
}

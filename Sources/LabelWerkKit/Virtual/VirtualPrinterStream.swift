import Foundation

/// Inkrementeller Zerleger des Datenstroms, den der virtuelle Drucker empfängt.
///
/// Befehle dürfen beliebig auf mehrere Schreibvorgänge verteilt sein – unvollständige Konstrukte
/// bleiben im Puffer, bis sie vollständig sind. Erkannt werden
/// * ZPL-Steuerbefehle (`~HS`, `~HQES`, `~SD08`, `~TA-10`, `~JC` …), auch innerhalb eines Formats,
/// * Downloads `~DG` (Hex/ACS/Z64), `~DY` (binär oder Hex, exakt in der angekündigten Länge),
///   `~DT`/`~DU`/`~DS`/`~DE` (Hex),
/// * ZPL-Formate `^XA … ^XZ` (Binärdaten von `^GFB`/`^GFC` werden exakt übersprungen),
/// * SGD-Zeilen `! U1 getvar|setvar|do …`,
/// * JSON-SGD `{}{…}` (Klammerausgleich, Zeichenketten beachtet),
/// * CPCL-Blöcke `! 0 …` bis `PRINT`/`END` (Binärdaten von `CG` werden übersprungen),
/// * EPL-Zeilen (nur wenn ``acceptsEPL`` gesetzt ist; `GW`-Binärdaten exakt).
///
/// Text zwischen Befehlen wird wie von der Firmware ignoriert. Ein laufendes Format wird beim
/// Weiterlesen ab der letzten Position fortgesetzt (keine erneute Vollsuche), damit auch große,
/// in vielen Blöcken übertragene Formate linear verarbeitet werden.
struct VirtualPrinterStream: Sendable {

    /// Ein vollständig empfangenes Konstrukt.
    enum Event: Equatable, Sendable {
        /// Steuerbefehl, `command` zweistellig in Großbuchstaben (`HS`, `HQ`, `SD` …).
        case tilde(command: String, parameters: String)
        /// `~DG{pfad},{gesamt},{bytes je Zeile},{daten}`.
        case downloadGraphic(path: String, totalBytes: Int, bytesPerRow: Int, data: String)
        /// `~DY` bzw. `~DT`/`~DU`/`~DS`/`~DE` mit dekodierten Rohbytes.
        case downloadObject(path: String, format: String, fileExtension: String, totalBytes: Int,
                            bytesPerRow: Int, data: [UInt8])
        /// Vollständiges Format einschließlich `^XA` und `^XZ`.
        case format([UInt8])
        /// SGD-Zeile ohne Zeilenende.
        case sgd(String)
        /// JSON-Objekt (ohne vorangestelltes `{}`).
        case json([UInt8])
        /// CPCL-Block vom Kopf bis einschließlich `PRINT`/`END`.
        case cpcl([UInt8])
        /// EPL-Zeile ohne Zeilenende (bei `GW` inklusive Binärdaten).
        case epl([UInt8])
    }

    /// EPL-Zeilen auswerten (Hybridmodus `epl_zpl`); sonst wird Text übersprungen.
    var acceptsEPL = false

    /// Größtes einzelnes Konstrukt (Schutz vor unbegrenztem Speicherbedarf).
    static let maximumConstructBytes = 64 << 20

    private var buffer: [UInt8] = []
    private var position = 0
    private var formatScan: FormatScan?
    /// Mindestlänge des Puffers, ab der ein erneuter Versuch lohnt.
    private var waitForLength: Int?

    private struct FormatScan: Sendable {
        var start: Int
        var cursor: Int
    }

    /// Fortsetzungspunkte unvollständiger Konstrukte, damit große, stückweise eintreffende Daten
    /// (Hex-Downloads, JSON, CPCL) nicht bei jedem Block erneut von vorn durchsucht werden.
    private struct HexScan: Sendable {
        var start: Int
        var index: Int
        var collected: [UInt8]
        var onlyHex: Bool
    }

    private struct JSONScan: Sendable {
        var start: Int
        var index: Int
        var depth: Int
        var inString: Bool
        var escaped: Bool
    }

    private struct CPCLScan: Sendable {
        var start: Int
        /// Beginn der nächsten noch nicht ausgewerteten Zeile.
        var index: Int
    }

    private var hexScan: HexScan?
    private var jsonScan: JSONScan?
    private var cpclScan: CPCLScan?

    /// Höchstlänge kurzer Konstrukte (SGD-Zeile, EPL-Zeile ohne Grafik, JSON-Anfrage); längere
    /// Daten ohne Abschluss gelten als Fremddaten und werden übersprungen.
    static let maximumLineBytes = 64 << 10
    static let maximumJSONBytes = 1 << 20
    /// Höchstlänge der Parameter unbekannter Steuerbefehle.
    static let maximumTildeParameterBytes = 256

    private enum Step {
        case advanced
        case needMore(Int)
    }

    private enum TildeResult {
        case complete(Event?, end: Int)
        case incomplete(Int)
    }

    /// Noch nicht vollständig verarbeitete Bytes.
    var pendingByteCount: Int { buffer.count - position }

    /// `true`, solange ein Format (`^XA` ohne `^XZ`) empfangen wird.
    var isInsideFormat: Bool { formatScan != nil }

    /// Verwirft alle unvollständigen Daten.
    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        position = 0
        formatScan = nil
        waitForLength = nil
        clearResumeState()
    }

    private mutating func clearResumeState() {
        hexScan = nil
        jsonScan = nil
        cpclScan = nil
    }

    /// Hängt Daten an und liefert alle dadurch vollständig gewordenen Konstrukte.
    mutating func feed(_ data: Data) -> [Event] {
        buffer.append(contentsOf: data)
        var events: [Event] = []
        if let need = waitForLength, buffer.count < need { return events }
        waitForLength = nil
        loop: while position < buffer.count {
            let before = position
            switch step(&events) {
            case .advanced:
                if position != before { clearResumeState() }
                continue
            case .needMore(let minimum):
                waitForLength = max(minimum, buffer.count + 1)
                break loop
            }
        }
        compact()
        return events
    }

    // MARK: - Hauptschleife

    private mutating func step(_ events: inout [Event]) -> Step {
        if formatScan != nil { return continueFormat(&events) }
        let byte = buffer[position]
        switch byte {
        case 0x00, 0x09, 0x0A, 0x0D, 0x20:
            position += 1
            return .advanced
        case Self.tilde:
            switch parseTilde(at: position) {
            case .complete(let event, let end):
                if let event { events.append(event) }
                position = end
                return .advanced
            case .incomplete(let minimum):
                return .needMore(minimum)
            }
        case Self.caret:
            guard position + 3 <= buffer.count else { return .needMore(position + 3) }
            if Self.upper(buffer[position + 1]) == 0x58, Self.upper(buffer[position + 2]) == 0x41 { // XA
                formatScan = FormatScan(start: position, cursor: position + 3)
                return continueFormat(&events)
            }
            // Einzelne ^-Befehle außerhalb eines Formats ignoriert die Firmware.
            position = skipToTerminator(from: position + 1)
            return .advanced
        case 0x21: // !
            return parseBang(&events)
        case 0x7B: // {
            return parseJSON(&events)
        default:
            if Self.isLetter(byte) { return parseLine(&events) }
            position += 1
            return .advanced
        }
    }

    // MARK: - Formate

    private mutating func continueFormat(_ events: inout [Event]) -> Step {
        guard var scan = formatScan else { return .advanced }
        while scan.cursor < buffer.count {
            let byte = buffer[scan.cursor]
            if byte == Self.caret {
                guard scan.cursor + 3 <= buffer.count else {
                    formatScan = scan
                    return .needMore(scan.cursor + 3)
                }
                let c1 = Self.upper(buffer[scan.cursor + 1])
                let c2 = Self.upper(buffer[scan.cursor + 2])
                if c1 == 0x58, c2 == 0x5A { // XZ
                    let end = scan.cursor + 3
                    events.append(.format(Array(buffer[scan.start..<end])))
                    position = end
                    formatScan = nil
                    return .advanced
                }
                if c1 == Self.caret || c1 == Self.tilde {
                    scan.cursor += 1
                    continue
                }
                if c1 == 0x47, c2 == 0x46 { // GF
                    switch binaryGraphicFieldEnd(at: scan.cursor) {
                    case .notBinary:
                        scan.cursor += 3
                    case .binary(let end):
                        guard end <= buffer.count else {
                            formatScan = scan
                            return .needMore(end)
                        }
                        scan.cursor = end
                    case .incompleteHeader:
                        formatScan = scan
                        return .needMore(buffer.count + 1)
                    }
                    continue
                }
                scan.cursor += 3
            } else if byte == Self.tilde {
                switch parseTilde(at: scan.cursor) {
                case .complete(let event, let end):
                    if case .tilde(let command, _)? = event, command == "JX" {
                        // ~JX verwirft das teilweise empfangene Format.
                        events.append(.tilde(command: "JX", parameters: ""))
                        position = end
                        formatScan = nil
                        return .advanced
                    }
                    if let event { events.append(event) }
                    scan.cursor = end
                case .incomplete(let minimum):
                    formatScan = scan
                    return .needMore(minimum)
                }
            } else {
                scan.cursor += 1
            }
            if scan.cursor - scan.start > Self.maximumConstructBytes {
                // Unbegrenzt langes Format ohne ^XZ: verwerfen, um Speicher zu schützen.
                position = scan.cursor
                formatScan = nil
                return .advanced
            }
        }
        formatScan = scan
        return .needMore(buffer.count + 1)
    }

    private enum GraphicFieldEnd {
        case notBinary
        case binary(Int)
        case incompleteHeader
    }

    /// `^GF{a},{b},{c},{d},{daten}`: bei Format `B`/`C` endet das Feld genau `b` Bytes nach dem
    /// vierten Komma.
    private func binaryGraphicFieldEnd(at start: Int) -> GraphicFieldEnd {
        var index = start + 3
        var fields: [String] = []
        var current: [UInt8] = []
        while index < buffer.count, index - start < 64 {
            let byte = buffer[index]
            if byte == Self.caret || byte == Self.tilde { return .notBinary }
            if byte == 0x2C {
                fields.append(String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll()
                if fields.count == 4 {
                    let format = fields[0].uppercased()
                    guard format == "B" || format == "C", let total = Int(fields[1]), total >= 0,
                          total <= Self.maximumConstructBytes else { return .notBinary }
                    return .binary(index + 1 + total)
                }
            } else {
                current.append(byte)
            }
            index += 1
        }
        return index - start >= 64 ? .notBinary : .incompleteHeader
    }

    // MARK: - Steuerbefehle

    /// Steuerbefehle ohne Parameter.
    static let parameterlessTilde: Set<String> = [
        "HS", "HI", "HM", "HD", "HB", "HU", "JC", "JG", "JL", "PH", "PP", "PS", "JA", "JX", "JR", "WC", "WL",
        "JB", "JD", "JE", "RO",
    ]

    private mutating func parseTilde(at start: Int) -> TildeResult {
        guard start + 3 <= buffer.count else { return .incomplete(start + 3) }
        let c1 = Self.upper(buffer[start + 1]), c2 = Self.upper(buffer[start + 2])
        guard Self.isLetter(c1) || Self.isDigit(c1) else {
            // „~“ ohne Befehlsnamen: Zeichen überspringen.
            return .complete(nil, end: start + 1)
        }
        let command = String(decoding: [c1, c2], as: UTF8.self)
        let first = start + 3
        if Self.parameterlessTilde.contains(command) {
            return .complete(.tilde(command: command, parameters: ""), end: first)
        }
        switch command {
        case "HQ", "SD":
            guard first + 2 <= buffer.count else { return .incomplete(first + 2) }
            let parameters = String(decoding: buffer[first..<first + 2], as: UTF8.self).uppercased()
            return .complete(.tilde(command: command, parameters: parameters), end: first + 2)
        case "TA":
            var index = first
            if index < buffer.count, buffer[index] == 0x2D || buffer[index] == 0x2B { index += 1 }
            var digits = 0
            while index < buffer.count, digits < 3, Self.isDigit(buffer[index]) {
                index += 1
                digits += 1
            }
            if digits < 3, index == buffer.count { return .incomplete(index + 1) }
            let parameters = String(decoding: buffer[first..<index], as: UTF8.self)
            return .complete(.tilde(command: command, parameters: parameters), end: index)
        case "CC", "CT", "CD":
            guard first + 1 <= buffer.count else { return .incomplete(first + 1) }
            let parameters = String(decoding: buffer[first..<first + 1], as: UTF8.self)
            return .complete(.tilde(command: command, parameters: parameters), end: first + 1)
        case "DG":
            return parseDownloadGraphic(at: start)
        case "DY":
            return parseDownloadObject(at: start)
        case "DT", "DU", "DS", "DE":
            return parseHexDownload(at: start, command: command)
        default:
            // Unbekannter Befehl: Parameter bis zum nächsten Präfix bzw. Zeilenende.
            var index = first
            while index < buffer.count, index - first < Self.maximumTildeParameterBytes {
                let byte = buffer[index]
                if byte == Self.caret || byte == Self.tilde || byte == 0x0D || byte == 0x0A { break }
                index += 1
            }
            if index == buffer.count, index - first < Self.maximumTildeParameterBytes { return .incomplete(index + 1) }
            let parameters = String(decoding: buffer[first..<index], as: UTF8.self)
            return .complete(.tilde(command: command, parameters: parameters), end: index)
        }
    }

    /// Liest `count` durch Komma abgeschlossene Kopffelder ab `start`.
    /// - Returns: Felder und Index hinter dem letzten Komma; `nil` bei Abbruch durch ein Präfix
    ///   (fehlerhafter Befehl); `.incomplete`, wenn der Kopf noch nicht vollständig ist.
    private enum HeaderResult {
        case fields([String], dataStart: Int)
        case malformed(end: Int)
        case incomplete
    }

    private func header(from start: Int, count: Int) -> HeaderResult {
        var index = start
        var fields: [String] = []
        var current: [UInt8] = []
        while index < buffer.count {
            let byte = buffer[index]
            if byte == Self.caret || byte == Self.tilde { return .malformed(end: index) }
            if byte == 0x2C {
                fields.append(String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll()
                if fields.count == count { return .fields(fields, dataStart: index + 1) }
            } else if byte != 0x0D && byte != 0x0A {
                current.append(byte)
            }
            index += 1
            if index - start > 512 { return .malformed(end: index) }
        }
        return .incomplete
    }

    /// Ende von ASCII-Hexdaten: nach `2 × total` Hexziffern (Leerraum zählt nicht) oder vor dem
    /// nächsten Präfix. `nil` = noch unvollständig.
    private mutating func hexDataEnd(from start: Int, total: Int) -> (end: Int, data: [UInt8])? {
        // Z64/B64: endet mit „:XXXX“ (CRC) bzw. vor dem nächsten Präfix.
        if start + 5 <= buffer.count {
            let marker = String(decoding: buffer[start..<start + 5], as: UTF8.self).uppercased()
            if marker == ":Z64:" || marker == ":B64:" {
                var cursor = start + 5
                if let scan = hexScan, scan.start == start { cursor = max(cursor, scan.index) }
                while cursor < buffer.count {
                    let byte = buffer[cursor]
                    if byte == Self.caret || byte == Self.tilde {
                        hexScan = nil
                        return (cursor, Array(buffer[start..<cursor]))
                    }
                    if byte == 0x3A { // ':' vor der Prüfsumme
                        guard cursor + 5 <= buffer.count else {
                            hexScan = HexScan(start: start, index: cursor, collected: [], onlyHex: false)
                            return nil
                        }
                        hexScan = nil
                        return (cursor + 5, Array(buffer[start..<cursor + 5]))
                    }
                    cursor += 1
                }
                hexScan = HexScan(start: start, index: cursor, collected: [], onlyHex: false)
                return nil
            }
        }
        let wanted = max(0, total) * 2
        var scan = hexScan.flatMap { $0.start == start ? $0 : nil }
            ?? HexScan(start: start, index: start, collected: [], onlyHex: true)
        while scan.index < buffer.count {
            let byte = buffer[scan.index]
            if byte == Self.caret || byte == Self.tilde {
                hexScan = nil
                return (scan.index, scan.collected)
            }
            if byte != 0x0D && byte != 0x0A && byte != 0x20 && byte != 0x09 {
                scan.collected.append(byte)
                if !Self.isHexDigit(byte) { scan.onlyHex = false }
                // Reine Hexdaten enden nach genau 2 × total Ziffern; komprimierte (ACS) erst vor
                // dem nächsten Befehl.
                if scan.onlyHex, wanted > 0, scan.collected.count >= wanted {
                    hexScan = nil
                    return (scan.index + 1, scan.collected)
                }
            }
            scan.index += 1
            if scan.index - start > Self.maximumConstructBytes {
                hexScan = nil
                return (scan.index, scan.collected)
            }
        }
        hexScan = scan
        return nil
    }

    private mutating func parseDownloadGraphic(at start: Int) -> TildeResult {
        switch header(from: start + 3, count: 3) {
        case .incomplete:
            return .incomplete(buffer.count + 1)
        case .malformed(let end):
            return .complete(.tilde(command: "DG", parameters: ""), end: end)
        case .fields(let fields, let dataStart):
            let total = Int(fields[1]) ?? 0
            let perRow = Int(fields[2]) ?? 0
            guard let (end, data) = hexDataEnd(from: dataStart, total: total) else { return .incomplete(buffer.count + 1) }
            return .complete(.downloadGraphic(path: fields[0], totalBytes: total, bytesPerRow: perRow,
                                              data: String(decoding: data, as: UTF8.self)), end: end)
        }
    }

    private mutating func parseDownloadObject(at start: Int) -> TildeResult {
        switch header(from: start + 3, count: 5) {
        case .incomplete:
            return .incomplete(buffer.count + 1)
        case .malformed(let end):
            return .complete(.tilde(command: "DY", parameters: ""), end: end)
        case .fields(let fields, let dataStart):
            let format = fields[1].uppercased()
            let ext = fields[2].uppercased()
            let total = max(0, Int(fields[3]) ?? 0)
            let perRow = Int(fields[4]) ?? 0
            guard total <= Self.maximumConstructBytes else {
                return .complete(.tilde(command: "DY", parameters: ""), end: dataStart)
            }
            if format == "B" || format == "C" {
                let end = dataStart + total
                guard end <= buffer.count else { return .incomplete(end) }
                return .complete(.downloadObject(path: fields[0], format: format, fileExtension: ext, totalBytes: total,
                                                 bytesPerRow: perRow, data: Array(buffer[dataStart..<end])), end: end)
            }
            guard let (end, data) = hexDataEnd(from: dataStart, total: total) else { return .incomplete(buffer.count + 1) }
            return .complete(.downloadObject(path: fields[0], format: format, fileExtension: ext, totalBytes: total,
                                             bytesPerRow: perRow, data: Self.decodeHex(data)), end: end)
        }
    }

    private mutating func parseHexDownload(at start: Int, command: String) -> TildeResult {
        switch header(from: start + 3, count: 2) {
        case .incomplete:
            return .incomplete(buffer.count + 1)
        case .malformed(let end):
            return .complete(.tilde(command: command, parameters: ""), end: end)
        case .fields(let fields, let dataStart):
            let total = max(0, Int(fields[1]) ?? 0)
            guard let (end, data) = hexDataEnd(from: dataStart, total: total) else { return .incomplete(buffer.count + 1) }
            return .complete(.downloadObject(path: fields[0], format: "A", fileExtension: "", totalBytes: total,
                                             bytesPerRow: 0, data: Self.decodeHex(data)), end: end)
        }
    }

    // MARK: - SGD und CPCL

    private mutating func parseBang(_ events: inout [Event]) -> Step {
        // Kopf der Zeile ansehen: „! U1 …“ (SGD) oder „! 0 …“, „! UTILITIES“, „! DF …“ (CPCL).
        var index = position + 1
        while index < buffer.count, buffer[index] == 0x20 || buffer[index] == 0x09 { index += 1 }
        guard index + 2 <= buffer.count else { return .needMore(index + 2) }
        let first = Self.upper(buffer[index])
        if first == 0x55 { // U
            let next = Self.upper(buffer[index + 1])
            if next == 0x31 || next == 0x20 || next == 0x09 { // „U1“ oder „U “ → SGD
                return parseSGDLine(&events)
            }
            if next == 0x54 { return parseCPCLBlock(&events) } // UTILITIES
        }
        if Self.isDigit(first) || first == 0x44 { // Ziffer (Etikett) oder DF (Format speichern)
            return parseCPCLBlock(&events)
        }
        // Unbekannte Zeile überspringen.
        guard let end = lineEnd(from: position, limit: Self.maximumLineBytes) else {
            if buffer.count - position > Self.maximumLineBytes {
                position += Self.maximumLineBytes
                return .advanced
            }
            return .needMore(buffer.count + 1)
        }
        position = end
        return .advanced
    }

    private mutating func parseSGDLine(_ events: inout [Event]) -> Step {
        // Ende: Zeilenende oder – falls früher – das letzte nötige Anführungszeichen (manche
        // Programme senden SGD-Befehle ohne Zeilenende).
        let candidates = [lineEnd(from: position, limit: Self.maximumLineBytes),
                          completeSGDCommandEnd(from: position)].compactMap { $0 }
        guard let end = candidates.min() else {
            if buffer.count - position > Self.maximumLineBytes {
                // Überlange Zeile ohne Abschluss: Fremddaten überspringen.
                position += Self.maximumLineBytes
                return .advanced
            }
            return .needMore(buffer.count + 1)
        }
        var line = Array(buffer[position..<end])
        while let last = line.last, last == 0x0D || last == 0x0A { line.removeLast() }
        events.append(.sgd(Self.decodeText(line)))
        position = end
        return .advanced
    }

    /// Ende eines SGD-Befehls, sobald alle nötigen Anführungszeichen vorhanden sind
    /// (`getvar`: Name; `setvar`/`do`: Name und Wert).
    private func completeSGDCommandEnd(from start: Int) -> Int? {
        // „!“, Leerraum, „U1“/„U“, Leerraum, Befehlswort.
        var index = start + 1
        func skipSpaces() { while index < buffer.count, buffer[index] == 0x20 || buffer[index] == 0x09 { index += 1 } }
        skipSpaces()
        guard index < buffer.count, Self.upper(buffer[index]) == 0x55 else { return nil }
        index += 1
        if index < buffer.count, buffer[index] == 0x31 { index += 1 }
        skipSpaces()
        var verb: [UInt8] = []
        while index < buffer.count, Self.isLetter(buffer[index]) {
            verb.append(Self.upper(buffer[index]))
            index += 1
        }
        let required: Int
        switch String(decoding: verb, as: UTF8.self) {
        case "GETVAR": required = 2
        case "SETVAR", "DO": required = 4
        default: return nil
        }
        var quotes = 0
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0D || byte == 0x0A { return nil }
            if byte == 0x22 {
                quotes += 1
                if quotes == required { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private mutating func parseCPCLBlock(_ events: inout [Event]) -> Step {
        var index: Int
        if let scan = cpclScan, scan.start == position {
            index = scan.index
        } else {
            // Kopfzeile überspringen.
            guard let headerEnd = lineEnd(from: position, limit: Self.maximumLineBytes) else {
                if buffer.count - position > Self.maximumLineBytes {
                    position += Self.maximumLineBytes
                    return .advanced
                }
                return .needMore(buffer.count + 1)
            }
            index = headerEnd
        }
        while true {
            while index < buffer.count, buffer[index] == 0x0D || buffer[index] == 0x0A { index += 1 }
            if index - position > Self.maximumConstructBytes {
                // Block ohne PRINT/END: verwerfen.
                position = index
                return .advanced
            }
            // Fortsetzung jeweils am Beginn der nächsten unvollständigen Zeile.
            cpclScan = CPCLScan(start: position, index: index)
            guard index < buffer.count else { return .needMore(buffer.count + 1) }
            if let binaryEnd = cpclGraphicEnd(at: index) {
                guard binaryEnd <= buffer.count else { return .needMore(binaryEnd) }
                index = binaryEnd
                continue
            }
            if cpclGraphicHeaderIncomplete(at: index) { return .needMore(buffer.count + 1) }
            guard let end = lineEnd(from: index, limit: Self.maximumLineBytes) else {
                if buffer.count - index > Self.maximumLineBytes {
                    index += Self.maximumLineBytes
                    continue
                }
                return .needMore(buffer.count + 1)
            }
            let line = Self.decodeText(Array(buffer[index..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            index = end
            if line == "PRINT" || line == "END" {
                events.append(.cpcl(Array(buffer[position..<end])))
                position = end
                cpclScan = nil
                return .advanced
            }
        }
    }

    /// `CG {bpr} {h} {x} {y} <binär>`: Ende der Binärdaten.
    private func cpclGraphicEnd(at start: Int) -> Int? {
        for keyword in ["CG ", "COMPRESSED-GRAPHICS "] {
            let pattern = Array(keyword.utf8)
            guard start + pattern.count <= buffer.count,
                  zip(buffer[start..<start + pattern.count], pattern).allSatisfy({ Self.upper($0) == $1 }) else { continue }
            var index = start + pattern.count
            var numbers: [Int] = []
            var current: [UInt8] = []
            while index < buffer.count, numbers.count < 4 {
                let byte = buffer[index]
                if Self.isDigit(byte) {
                    current.append(byte)
                } else if byte == 0x20, !current.isEmpty {
                    numbers.append(Int(String(decoding: current, as: UTF8.self)) ?? 0)
                    current.removeAll()
                } else if byte != 0x20 {
                    return nil
                }
                index += 1
            }
            guard numbers.count == 4 else { return nil }
            let length = numbers[0] * numbers[1]
            guard length >= 0, length <= Self.maximumConstructBytes else { return nil }
            return index + length
        }
        return nil
    }

    /// `true`, wenn bei `start` ein `CG`-Kopf beginnt, dessen Zahlen noch nicht vollständig sind.
    private func cpclGraphicHeaderIncomplete(at start: Int) -> Bool {
        let remaining = buffer.count - start
        for keyword in ["CG ", "COMPRESSED-GRAPHICS "] {
            let pattern = Array(keyword.utf8)
            let compare = min(remaining, pattern.count)
            guard zip(buffer[start..<start + compare], pattern).allSatisfy({ Self.upper($0) == $1 }) else { continue }
            if remaining < pattern.count { return true }
            // Kopf beginnt, aber cpclGraphicEnd fand keine vier Zahlen → noch unvollständig,
            // sofern danach nur Ziffern und Leerzeichen folgen.
            return buffer[(start + pattern.count)...].allSatisfy { Self.isDigit($0) || $0 == 0x20 }
        }
        return false
    }

    // MARK: - JSON

    private mutating func parseJSON(_ events: inout [Event]) -> Step {
        var scan = jsonScan.flatMap { $0.start == position ? $0 : nil }
            ?? JSONScan(start: position, index: position, depth: 0, inString: false, escaped: false)
        while scan.index < buffer.count {
            let byte = buffer[scan.index]
            if scan.inString {
                if scan.escaped {
                    scan.escaped = false
                } else if byte == 0x5C {
                    scan.escaped = true
                } else if byte == 0x22 {
                    scan.inString = false
                }
            } else if byte == 0x22 {
                scan.inString = true
            } else if byte == 0x7B {
                scan.depth += 1
            } else if byte == 0x7D {
                scan.depth -= 1
                if scan.depth == 0 {
                    let object = Array(buffer[position...scan.index])
                    position = scan.index + 1
                    jsonScan = nil
                    let compact = object.filter { ![0x20, 0x09, 0x0D, 0x0A].contains($0) }
                    if compact != [0x7B, 0x7D] { events.append(.json(object)) }
                    return .advanced
                }
            }
            scan.index += 1
            if scan.index - position > Self.maximumJSONBytes {
                // Keine gültige JSON-Anfrage: „{“ als Fremddaten überspringen.
                jsonScan = nil
                position += 1
                return .advanced
            }
        }
        jsonScan = scan
        return .needMore(buffer.count + 1)
    }

    // MARK: - EPL und Text

    private mutating func parseLine(_ events: inout [Event]) -> Step {
        guard acceptsEPL else {
            // Text außerhalb von Befehlen: bis zum nächsten Präfix bzw. Zeilenende überspringen.
            position = skipToTerminator(from: position)
            return .advanced
        }
        var dataEnd = position
        if position + 2 <= buffer.count, Self.upper(buffer[position]) == 0x47, Self.upper(buffer[position + 1]) == 0x57 {
            // GWx,y,bpr,h,<binär>
            switch header(from: position + 2, count: 4) {
            case .incomplete:
                return .needMore(buffer.count + 1)
            case .malformed:
                break
            case .fields(let fields, let start):
                let perRow = max(0, Int(fields[2]) ?? 0)
                let rows = max(0, Int(fields[3]) ?? 0)
                let length = perRow * rows
                guard length <= Self.maximumConstructBytes else { break }
                guard start + length <= buffer.count else { return .needMore(start + length) }
                dataEnd = start + length
            }
        } else if position + 2 > buffer.count {
            return .needMore(position + 2)
        }
        var index = dataEnd
        while index < buffer.count, buffer[index] != 0x0A, index - dataEnd < Self.maximumLineBytes { index += 1 }
        if index - dataEnd >= Self.maximumLineBytes {
            // Überlange Zeile: Fremddaten überspringen.
            position = index
            return .advanced
        }
        guard index < buffer.count else { return .needMore(buffer.count + 1) }
        var line = Array(buffer[position..<index])
        if line.last == 0x0D { line.removeLast() }
        events.append(.epl(line))
        position = index + 1
        return .advanced
    }

    // MARK: - Hilfen

    static let caret: UInt8 = 0x5E
    static let tilde: UInt8 = 0x7E

    /// Index hinter dem nächsten Zeilenende (CR, LF oder CR LF) innerhalb von `limit` Bytes;
    /// `nil`, wenn keins vorliegt.
    private func lineEnd(from start: Int, limit: Int = Int.max) -> Int? {
        var index = start
        let stop = start + min(limit, buffer.count - start)
        while index < stop {
            if buffer[index] == 0x0A { return index + 1 }
            if buffer[index] == 0x0D {
                if index + 1 < buffer.count, buffer[index + 1] == 0x0A { return index + 2 }
                return index + 1
            }
            index += 1
        }
        return nil
    }

    /// Index des nächsten `^`, `~`, CR oder LF (bzw. Pufferende).
    private func skipToTerminator(from start: Int) -> Int {
        var index = start
        while index < buffer.count {
            let byte = buffer[index]
            if byte == Self.caret || byte == Self.tilde || byte == 0x0D || byte == 0x0A { break }
            index += 1
        }
        return index
    }

    private mutating func compact() {
        guard position > 0 else { return }
        if position >= buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count < (1 << 20))
            if let wait = waitForLength { waitForLength = max(0, wait - position) }
            position = 0
            formatScan = nil
            clearResumeState()
            return
        }
        // Nur gelegentlich umkopieren (große Vorsprünge), sonst wäre jedes Anhängen O(n).
        guard position > (1 << 16), position * 2 > buffer.count else { return }
        buffer.removeFirst(position)
        if var scan = formatScan {
            scan.start -= position
            scan.cursor -= position
            formatScan = scan
        }
        if let wait = waitForLength { waitForLength = max(0, wait - position) }
        let shift = position
        if var scan = hexScan { scan.start -= shift; scan.index -= shift; hexScan = scan }
        if var scan = jsonScan { scan.start -= shift; scan.index -= shift; jsonScan = scan }
        if var scan = cpclScan { scan.start -= shift; scan.index -= shift; cpclScan = scan }
        position = 0
    }

    static func upper(_ byte: UInt8) -> UInt8 { byte >= 0x61 && byte <= 0x7A ? byte - 0x20 : byte }
    static func isLetter(_ byte: UInt8) -> Bool { (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) }
    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    static func decodeHex(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 2)
        var high: UInt8?
        for byte in bytes where isHexDigit(byte) {
            let value: UInt8 = isDigit(byte) ? byte - 0x30 : (upper(byte) - 0x41 + 10)
            if let h = high {
                out.append(h << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return out
    }

    /// UTF-8, sonst ISO-Latin-1 (jedes Byte ein Zeichen).
    static func decodeText(_ bytes: [UInt8]) -> String {
        if let text = String(data: Data(bytes), encoding: .utf8) { return text }
        var text = ""
        text.unicodeScalars.reserveCapacity(bytes.count)
        for byte in bytes { text.unicodeScalars.append(Unicode.Scalar(byte)) }
        return text
    }
}

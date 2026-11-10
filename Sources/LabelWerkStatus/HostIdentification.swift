import Foundation
import LabelWerkCore

/// Antwort auf `~HI` (Host Identification).
///
/// Format laut ZPL II Programming Guide: `<STX>XXXXXX,V1.0.0,dpm,000KB,X<ETX>` –
/// Modell, Firmware, Punkte pro Millimeter, Speicher und optionale Kennbuchstaben
/// (z. B. `C` für Schneidwerk).
public struct HostIdentification: Hashable, Sendable, Codable {
    /// Modellbezeichnung, z. B. `ZD421-203dpi`.
    public var model: String
    /// Firmware-Version, z. B. `V84.20.18Z`.
    public var firmware: String
    /// Druckkopfauflösung in Punkten pro Millimeter (6, 8, 12, 24; 0 = unbekannt).
    public var dotsPerMM: Int
    /// Speicher in KB (0 = unbekannt).
    public var memoryKB: Int
    /// Zusatzoptionen (Rest der Antwort, kommagetrennt), leer wenn keine.
    public var options: String

    public init(model: String, firmware: String, dotsPerMM: Int = 0, memoryKB: Int = 0, options: String = "") {
        self.model = model
        self.firmware = firmware
        self.dotsPerMM = dotsPerMM
        self.memoryKB = memoryKB
        self.options = options
    }

    /// Auflösung aus ``dotsPerMM`` (ersatzweise aus der Modellbezeichnung, z. B. „-300dpi“).
    public var resolution: Resolution? {
        Resolution(dotsPerMM: dotsPerMM) ?? HostIdentificationParser.dotsPerMM(fromModel: model).flatMap(Resolution.init(dotsPerMM:))
    }

    /// Einzelne Optionskennungen (z. B. `["C"]` für Schneidwerk).
    public var optionCodes: [String] {
        options.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    /// Modellbezeichnung ohne Auflösungszusatz, z. B. `ZD421` aus `ZD421-203dpi`.
    public var baseModel: String {
        let trimmed = StatusText.trim(model)
        guard trimmed.lowercased().hasSuffix("dpi"),
              let separator = trimmed.dropLast(3).lastIndex(where: { $0 == "-" || $0 == " " || $0 == "_" }) else {
            return trimmed
        }
        let candidate = StatusText.trim(trimmed[..<separator])
        return candidate.isEmpty ? trimmed : candidate
    }

    /// Antwort exakt im Druckerformat (`STX … ETX`).
    public var responseText: String {
        var parts = [model, firmware, String(dotsPerMM), "\(memoryKB)KB"]
        if !options.isEmpty { parts.append(options) }
        return "\u{02}" + parts.joined(separator: ",") + "\u{03}"
    }

    /// ``responseText`` als ASCII-Daten.
    public var responseData: Data { Data(responseText.utf8) }
}

/// Parser für `~HI`-Antworten.
///
/// Toleriert Rahmung, Zeilenenden, Leerraum, Speicherangaben in KB/MB/GB, fehlende Felder
/// (Auflösung wird dann aus „-203dpi“ im Modellnamen abgeleitet), kommalose Kennungen älterer
/// EPL-Firmware („UKQ1935HLU  V4.70.1A“) sowie Fremdzeilen im Empfangspuffer – etwa eine
/// liegengebliebene `~HS`-Antwort („030,1,0,1245,…“) aus einer abgelaufenen Statusabfrage.
/// Unter mehreren Kommazeilen wird die plausibelste gewählt (siehe ``identificationLine(in:)``).
public enum HostIdentificationParser {
    public static func parse(_ data: Data) throws -> HostIdentification {
        try parse(text: StatusText.decode(data))
    }

    /// Variante für bereits dekodierten Text.
    public static func parse(text: String) throws -> HostIdentification {
        let lines = StatusText.lines(text)
        guard !lines.isEmpty else { throw StatusParseError.emptyResponse }

        if let line = identificationLine(in: lines) {
            return try parseCommaSeparated(line)
        }
        for line in lines where !line.contains(",") {
            if let identification = parseWhitespaceSeparated(line) { return identification }
        }
        throw StatusParseError.unrecognizedFormat("Keine ~HI-Kennung gefunden")
    }

    /// Wählt unter den Zeilen mit Komma die erste mit der höchsten Plausibilität
    /// (``plausibility(ofCommaLine:)``); Zeilen ohne jedes ~HI-Merkmal werden übergangen.
    ///
    /// So werden vorangestellte Fremdzeilen – insbesondere `~HS`-Zeilen, deren Felder rein
    /// numerisch sind – nicht als Kennung gedeutet. `nil`, wenn keine Kommazeile infrage kommt.
    static func identificationLine(in lines: [String]) -> String? {
        var best: (line: String, score: Int)?
        for line in lines where line.contains(",") {
            let score = plausibility(ofCommaLine: line)
            if score > (best?.score ?? 0) { best = (line, score) }
        }
        return best?.line
    }

    /// Bewertet, wie sehr eine Kommazeile einer `~HI`-Kennung `Modell,Firmware,…` ähnelt:
    /// 2 Punkte für ein versionsartiges Firmware-Feld (``isVersionToken(_:)``, z. B. `V84.20.18Z`),
    /// 1 Punkt für ein Modellfeld mit mindestens einem Buchstaben (z. B. `ZD421-203dpi`).
    /// `~HS`-Zeilen („030,1,0,…“, „1234,0“) erhalten 0 Punkte.
    static func plausibility(ofCommaLine line: String) -> Int {
        let fields = StatusText.fields(line)
        var score = 0
        if fields.count > 1, isVersionToken(fields[1]) { score += 2 }
        if let model = fields.first, model.contains(where: { $0.isASCII && $0.isLetter }) { score += 1 }
        return score
    }

    static func parseCommaSeparated(_ line: String) throws -> HostIdentification {
        let fields = StatusText.fields(line)
        let model = fields[0]
        guard !model.isEmpty else {
            throw StatusParseError.invalidField(name: "Modell", value: line)
        }
        let firmware = fields.count > 1 ? fields[1] : ""
        var dotsPerMM = 0
        if fields.count > 2, !fields[2].isEmpty {
            guard let value = leadingInteger(fields[2]), value >= 0, value <= 64 else {
                throw StatusParseError.invalidField(name: "Punkte/mm", value: fields[2])
            }
            dotsPerMM = value
        }
        if dotsPerMM == 0 { dotsPerMM = Self.dotsPerMM(fromModel: model) ?? 0 }
        let memoryKB = fields.count > 3 ? (memoryKilobytes(fields[3]) ?? 0) : 0
        let options = fields.count > 4
            ? fields[4...].filter { !$0.isEmpty }.joined(separator: ",")
            : ""
        return HostIdentification(model: model, firmware: firmware, dotsPerMM: dotsPerMM,
                                  memoryKB: memoryKB, options: options)
    }

    /// Kommalose Variante: erstes Wort = Modell, erstes versionsartiges Wort = Firmware.
    static func parseWhitespaceSeparated(_ line: String) -> HostIdentification? {
        let tokens = StatusText.tokens(line)
        guard tokens.count >= 2 else { return nil }
        guard let firmware = tokens.dropFirst().first(where: isVersionToken) else { return nil }
        let model = tokens[0]
        let memory = tokens.dropFirst().lazy.compactMap { token -> Int? in
            let upper = token.uppercased()
            guard upper.hasSuffix("KB") || upper.hasSuffix("MB") || upper.hasSuffix("K") else { return nil }
            return memoryKilobytes(token)
        }.first ?? 0
        return HostIdentification(model: model, firmware: firmware,
                                  dotsPerMM: dotsPerMM(fromModel: model) ?? 0, memoryKB: memory)
    }

    /// „V4.70.1A“, „4.29“, „V84.20.18Z“.
    static func isVersionToken(_ token: String) -> Bool {
        var body = Substring(token)
        if body.first == "V" || body.first == "v" { body = body.dropFirst() }
        guard let first = body.first, first.isASCII, first.isNumber else { return false }
        return body.contains(".")
    }

    /// Speicherangabe wie „8192KB“, „512K“, „8MB“, „1GB“, „4096“ → KB.
    public static func memoryKilobytes(_ text: String) -> Int? {
        let upper = StatusText.trim(text).uppercased().replacingOccurrences(of: " ", with: "")
        guard let number = leadingInteger(upper) else { return nil }
        let unit = upper.drop(while: { $0.isNumber })
        switch unit {
        case "", "K", "KB", "KBYTES", "KIB": return number
        case "M", "MB", "MIB": return number.multipliedReportingOverflow(by: 1024).overflow ? nil : number * 1024
        case "G", "GB", "GIB": return number.multipliedReportingOverflow(by: 1_048_576).overflow ? nil : number * 1_048_576
        case "B", "BYTES": return number / 1024
        default: return nil
        }
    }

    /// Leitet dpmm aus Modellnamen wie „ZD421-203dpi“, „105SL-200DPI“, „ZT610-600dpi“ ab.
    public static func dotsPerMM(fromModel model: String) -> Int? {
        let lower = model.lowercased()
        guard let range = lower.range(of: "dpi") else { return nil }
        let digits = lower[..<range.lowerBound].reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let dpi = Int(String(digits.reversed())) else { return nil }
        switch dpi {
        case 150...160: return 6
        case 200...210: return 8
        case 290...310: return 12
        case 400...410: return 16
        case 590...610: return 24
        default: return nil
        }
    }

    static func leadingInteger(_ text: String) -> Int? {
        let digits = StatusText.trim(text).prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 12 else { return nil }
        return Int(digits)
    }
}

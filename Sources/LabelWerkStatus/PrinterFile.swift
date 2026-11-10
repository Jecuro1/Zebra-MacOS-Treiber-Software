import Foundation

// MARK: - Dateiart

/// Art einer Datei im Druckerspeicher, abgeleitet aus der Dateiendung.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    /// Schriften: `.TTF`, `.TTE`, `.OTF`, `.TTC`, `.FNT`.
    case font
    /// Grafiken: `.GRF`, `.PNG`, `.BMP`, `.PCX`, `.IMG`.
    case graphic
    /// Gespeicherte Formate/Vorlagen: `.ZPL`, `.WML`.
    case format
    /// Firmware-Pakete: `.ZHX`, `.HEX`.
    case firmware
    /// Alles andere (`.NRD`, `.DAT`, `.CSV`, ZBI-Programme …).
    case other

    static let fontExtensions: Set<String> = ["TTF", "TTE", "OTF", "TTC", "FNT"]
    static let graphicExtensions: Set<String> = ["GRF", "PNG", "BMP", "PCX", "IMG"]
    static let formatExtensions: Set<String> = ["ZPL", "WML"]
    static let firmwareExtensions: Set<String> = ["ZHX", "HEX"]

    /// Bestimmt die Art aus einer Endung (mit oder ohne Punkt, beliebige Schreibweise).
    public init(fileExtension: String) {
        var ext = StatusText.trim(fileExtension).uppercased()
        if ext.hasPrefix(".") { ext.removeFirst() }
        if Self.fontExtensions.contains(ext) { self = .font }
        else if Self.graphicExtensions.contains(ext) { self = .graphic }
        else if Self.formatExtensions.contains(ext) { self = .format }
        else if Self.firmwareExtensions.contains(ext) { self = .firmware }
        else { self = .other }
    }

    /// Bestimmt die Art aus einem Dateinamen (`LOGO.GRF`, `E:ARIAL.TTF`).
    public init(fileName: String) {
        let base = fileName.split(separator: ":").last.map(String.init) ?? fileName
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else {
            self = .other
            return
        }
        self.init(fileExtension: String(base[base.index(after: dot)...]))
    }

    /// Deutsche Bezeichnung.
    public var displayName: String {
        switch self {
        case .font: return "Schrift"
        case .graphic: return "Grafik"
        case .format: return "Format"
        case .firmware: return "Firmware"
        case .other: return "Sonstige"
        }
    }

    /// SF Symbol.
    public var systemImage: String {
        switch self {
        case .font: return "textformat"
        case .graphic: return "photo"
        case .format: return "doc.text"
        case .firmware: return "cpu"
        case .other: return "doc"
        }
    }
}

// MARK: - Datei

/// Eine Datei im Druckerspeicher (z. B. `E:LOGO.GRF`).
public struct PrinterFile: Hashable, Sendable, Codable, Identifiable {
    /// Alias, damit auch `PrinterFile.FileKind` verwendet werden kann.
    public typealias FileKind = LabelWerkStatus.FileKind

    /// Laufwerk inklusive Doppelpunkt, z. B. `E:` (Flash), `R:` (RAM), `Z:` (intern), `B:` (Karte).
    public var drive: String
    /// Dateiname ohne Laufwerk, z. B. `LOGO.GRF`.
    public var name: String
    /// Größe in Byte.
    public var size: Int
    /// Art der Datei.
    public var kind: FileKind

    /// Vollständiger Pfad, z. B. `E:LOGO.GRF`.
    public var id: String { drive + name }

    /// Erzeugt eine Datei; ohne Angabe wird ``kind`` aus der Endung abgeleitet.
    /// Das Laufwerk wird normalisiert (`e` → `E:`).
    public init(drive: String, name: String, size: Int, kind: FileKind? = nil) {
        self.drive = PrinterFile.normalizedDrive(drive)
        self.name = name
        self.size = max(0, size)
        self.kind = kind ?? FileKind(fileName: name)
    }

    /// Erzeugt eine Datei aus einem Pfad wie `E:LOGO.GRF`; `nil` ohne Laufwerk oder Namen.
    public init?(path: String, size: Int = 0) {
        let trimmed = StatusText.trim(path)
        guard let colon = trimmed.firstIndex(of: ":"),
              trimmed.distance(from: trimmed.startIndex, to: colon) == 1,
              trimmed.first?.isLetter == true else { return nil }
        let name = String(trimmed[trimmed.index(after: colon)...])
        guard !name.isEmpty else { return nil }
        self.init(drive: String(trimmed[..<colon]), name: name, size: size)
    }

    /// Vollständiger Pfad (identisch mit ``id``), z. B. für `^ID` oder `^XG`.
    public var path: String { id }

    /// Endung in Großbuchstaben ohne Punkt (leer, wenn keine).
    public var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].uppercased()
    }

    /// Name ohne Endung.
    public var baseName: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func normalizedDrive(_ drive: String) -> String {
        var value = StatusText.trim(drive).uppercased()
        if !value.isEmpty, !value.hasSuffix(":") { value += ":" }
        return value
    }
}

// MARK: - Verzeichnis

/// Vollständiges Ergebnis einer Verzeichnisabfrage.
public struct FileDirectoryListing: Hashable, Sendable, Codable {
    /// Dateien in Antwortreihenfolge, ohne Duplikate.
    public var files: [PrinterFile]
    /// Freier Speicher je Laufwerk in Byte (`"E:"` → 12345678).
    public var freeBytes: [String: Int]
    /// Speicherbezeichnung je Laufwerk (`"E:"` → `"ONBOARD FLASH"`).
    public var driveNames: [String: String]

    public init(files: [PrinterFile] = [], freeBytes: [String: Int] = [:], driveNames: [String: String] = [:]) {
        self.files = files
        self.freeBytes = freeBytes
        self.driveNames = driveNames
    }

    /// Belegter Speicher aller Dateien eines Laufwerks in Byte.
    public func usedBytes(drive: String) -> Int {
        let normalized = PrinterFile.normalizedDrive(drive)
        return files.filter { $0.drive == normalized }.reduce(0) { $0 + $1.size }
    }
}

/// Parser für Dateilisten aus `^HW` (Host Directory) und SGD `file.dir`.
///
/// Beispiel `^HW`:
/// ```
/// <STX>
/// - DIR E:*.*
/// *E:LOGO.GRF       1234
/// *E:ARIAL.TTF   45678
/// -     12345678 bytes free E:ONBOARD FLASH
/// <ETX>
/// ```
/// Ebenso verarbeitet werden `* E:NAME 123`, Zeilen ohne `*`, Zeilen ohne Laufwerk unter einer
/// Kopfzeile (`Directory of E:`), in Anführungszeichen gefasste SGD-Antworten und abgeschnittene
/// Antworten (unvollständige Zeilen ohne Größe am Ende werden verworfen, sofern kein `*` sie
/// als Dateieintrag kennzeichnet).
public enum FileDirectoryParser {
    public static func parse(_ text: String) -> [PrinterFile] {
        parseListing(text).files
    }

    /// Variante für Rohdaten.
    public static func parse(data: Data) -> [PrinterFile] {
        parse(StatusText.decode(data))
    }

    /// Dateien plus freier Speicher und Laufwerksbezeichnungen.
    public static func parseListing(_ text: String) -> FileDirectoryListing {
        var listing = FileDirectoryListing()
        var seen = Set<String>()
        var currentDrive: String?

        for rawLine in StatusText.lines(text) {
            let line = StatusText.trim(rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if lower.contains("bytes free") || lower.contains("byte free") || lower.contains("bytes frei") {
                parseFreeLine(line, currentDrive: currentDrive, into: &listing)
                continue
            }
            if line.hasPrefix("-") || lower.hasPrefix("directory") || lower.hasPrefix("dir ") {
                if lower.contains("dir"), let drive = firstDriveToken(in: line) { currentDrive = drive }
                continue
            }
            guard let file = parseFileLine(line, currentDrive: currentDrive), !seen.contains(file.id) else {
                continue
            }
            seen.insert(file.id)
            listing.files.append(file)
        }
        return listing
    }

    static func parseFreeLine(_ line: String, currentDrive: String?, into listing: inout FileDirectoryListing) {
        let body = line.drop(while: { $0 == "-" || $0 == " " })
        guard let (value, rest) = StatusText.leadingNumber(String(body)), value >= 0, value < 1e15 else { return }
        let tokens = StatusText.tokens(rest)
        var drive = currentDrive
        var driveName: String?
        if let index = tokens.firstIndex(where: { isDriveToken($0) || isDrivePrefixed($0) }) {
            let token = tokens[index]
            let colon = token.firstIndex(of: ":")!
            drive = PrinterFile.normalizedDrive(String(token[..<colon]))
            var nameParts = [String(token[token.index(after: colon)...])].filter { !$0.isEmpty }
            nameParts += tokens[(index + 1)...]
            let name = nameParts.joined(separator: " ")
            if !name.isEmpty { driveName = name }
        }
        guard let drive else { return }
        listing.freeBytes[drive] = Int(value)
        if let driveName { listing.driveNames[drive] = driveName }
    }

    static func parseFileLine(_ line: String, currentDrive: String?) -> PrinterFile? {
        let marked = line.hasPrefix("*")
        let tokens = StatusText.tokens(line.drop(while: { $0 == "*" }))
        guard !tokens.isEmpty else { return nil }

        var drive: String?
        var name: String
        var sizeIndex: Int
        if isDrivePrefixed(tokens[0]) {
            let colon = tokens[0].firstIndex(of: ":")!
            drive = String(tokens[0][..<colon])
            name = String(tokens[0][tokens[0].index(after: colon)...])
            sizeIndex = 1
        } else if isDriveToken(tokens[0]), tokens.count >= 2 {
            drive = String(tokens[0].dropLast())
            name = tokens[1]
            sizeIndex = 2
        } else if let currentDrive, marked || (tokens.count >= 2 && StatusText.integer(tokens[1]) != nil) {
            drive = currentDrive
            name = tokens[0]
            sizeIndex = 1
        } else {
            return nil
        }
        guard let drive, isValidFileName(name) else { return nil }

        var size = 0
        if sizeIndex < tokens.count, let value = StatusText.integer(tokens[sizeIndex].replacingOccurrences(of: ",", with: "")), value >= 0 {
            size = value
        } else if !marked {
            // Ohne „*“ und ohne Größe ist die Zeile kein sicherer Dateieintrag.
            return nil
        }
        return PrinterFile(drive: drive, name: name, size: size)
    }

    /// `E:` als eigenständiges Token.
    static func isDriveToken(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        return scalars.count == 2 && scalars[1] == ":" && isASCIILetter(scalars[0])
    }

    /// `E:NAME` (Laufwerk direkt gefolgt vom Namen).
    static func isDrivePrefixed(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        return scalars.count > 2 && scalars[1] == ":" && isASCIILetter(scalars[0])
    }

    static func firstDriveToken(in line: String) -> String? {
        for token in StatusText.tokens(line) where isDriveToken(token) || isDrivePrefixed(token) {
            return PrinterFile.normalizedDrive(String(token.prefix(1)))
        }
        return nil
    }

    static func isValidFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return !name.contains(where: { $0 == "*" || $0 == "?" || $0 == ":" || $0 == "\"" })
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
}

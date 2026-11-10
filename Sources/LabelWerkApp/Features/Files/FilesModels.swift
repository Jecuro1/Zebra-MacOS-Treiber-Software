import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Laufwerke

/// Speicherbereiche eines Zebra-Druckers.
enum FilesDrive: String, CaseIterable, Identifiable, Hashable {
    case flash = "E:"
    case ram = "R:"
    case card = "B:"
    case rom = "Z:"

    var id: String { rawValue }
    /// ZPL-Laufwerkskennung inkl. Doppelpunkt, z. B. „E:“.
    var code: String { rawValue }

    var title: String {
        switch self {
        case .flash: return tr("Flash (E:)")
        case .ram: return tr("RAM (R:)")
        case .card: return tr("Speicherkarte (B:)")
        case .rom: return tr("ROM (Z:)")
        }
    }

    var shortTitle: String {
        switch self {
        case .flash: return tr("Flash")
        case .ram: return tr("RAM")
        case .card: return tr("Karte")
        case .rom: return tr("ROM")
        }
    }

    var systemImage: String {
        switch self {
        case .flash: return "internaldrive"
        case .ram: return "memorychip"
        case .card: return "sdcard"
        case .rom: return "lock.shield"
        }
    }

    var tint: Color {
        switch self {
        case .flash: return Theme.violet
        case .ram: return Theme.teal
        case .card: return Theme.magenta
        case .rom: return Theme.offline
        }
    }

    var explanation: String {
        switch self {
        case .flash: return tr("Dauerhafter Speicher – Schriften, Grafiken und Formate bleiben nach dem Ausschalten erhalten.")
        case .ram: return tr("Flüchtiger Arbeitsspeicher – Inhalte gehen beim Ausschalten verloren.")
        case .card: return tr("Optionale Speichererweiterung (nur bei Druckern mit Karten- oder USB-Speicher).")
        case .rom: return tr("Fest eingebaute Schriften und Systemdateien – nur lesbar.")
        }
    }

    var isWritable: Bool { self != .rom }

    /// SGD-Namen für freien und gesamten Speicher (nur Flash und RAM).
    var memoryVariables: (free: String, size: String)? {
        switch self {
        case .flash: return ("memory.flash_free", "memory.flash_size")
        case .ram: return ("memory.ram_free", "memory.ram_size")
        case .card, .rom: return nil
        }
    }

    static let writable: [FilesDrive] = [.flash, .ram, .card]

    init?(code: String) {
        let normalized = code.uppercased().hasSuffix(":") ? code.uppercased() : code.uppercased() + ":"
        guard let match = FilesDrive.allCases.first(where: { $0.code == normalized }) else { return nil }
        self = match
    }
}

// MARK: - Dateiarten

/// Gruppierung der Dateien in der Liste.
enum FilesCategory: Int, CaseIterable, Identifiable, Hashable {
    case font, graphic, format, firmware, other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .font: return tr("Schriften")
        case .graphic: return tr("Grafiken")
        case .format: return tr("Formate")
        case .firmware: return tr("System & Firmware")
        case .other: return tr("Sonstige Dateien")
        }
    }

    var singular: String {
        switch self {
        case .font: return tr("Schrift")
        case .graphic: return tr("Grafik")
        case .format: return tr("Format")
        case .firmware: return tr("Systemdatei")
        case .other: return tr("Datei")
        }
    }

    var systemImage: String {
        switch self {
        case .font: return "textformat"
        case .graphic: return "photo"
        case .format: return "doc.text"
        case .firmware: return "cpu"
        case .other: return "doc"
        }
    }

    var tint: Color {
        switch self {
        case .font: return Theme.violet
        case .graphic: return Theme.teal
        case .format: return Theme.printing
        case .firmware: return Theme.warning
        case .other: return Theme.offline
        }
    }

    /// Einordnung einer Druckerdatei: zuerst die Art laut Verzeichnis, sonst die Dateiendung.
    static func of(_ file: PrinterFile) -> FilesCategory {
        switch file.kind {
        case .font: return .font
        case .graphic: return .graphic
        case .format: return .format
        case .firmware: return .firmware
        default: return of(fileName: file.name)
        }
    }

    static func of(fileName: String) -> FilesCategory {
        let ext = (fileName as NSString).pathExtension.uppercased()
        switch ext {
        case "TTF", "OTF", "TTE", "FNT": return .font
        case "GRF", "PNG", "BMP", "PCX": return .graphic
        case "ZPL", "ZPF", "FRM", "STO": return .format
        case "NRD", "HEX", "WML", "PRF", "SYS", "BIN": return .firmware
        default: return .other
        }
    }
}

// MARK: - Speicher

struct FilesMemoryInfo: Equatable {
    var total: Int64?
    var free: Int64?

    var used: Int64? {
        guard let total, let free else { return nil }
        return max(0, total - free)
    }

    var usedFraction: Double? {
        guard let total, total > 0, let used else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var isKnown: Bool { total != nil || free != nil }

    /// Liest Werte wie „65011712“, „62 MB“, „1,234,567 Bytes“ oder „8192 KB“.
    static func parseBytes(_ raw: String?) -> Int64? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        let numberPart = raw.prefix { $0.isWholeNumber || $0 == "." || $0 == "," }
        guard !numberPart.isEmpty else { return nil }
        let cleaned = numberPart.replacingOccurrences(of: ",", with: "")
        guard let number = Double(cleaned) else { return nil }
        let unit = raw.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        let factor: Double
        if unit.hasPrefix("g") {
            factor = 1_073_741_824
        } else if unit.hasPrefix("m") {
            factor = 1_048_576
        } else if unit.hasPrefix("k") {
            factor = 1024
        } else {
            factor = 1
        }
        return Int64(number * factor)
    }
}

// MARK: - Namen & ZPL

enum FilesNaming {
    /// Erlaubte Zeichen für Dateinamen im Drucker.
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    /// Wandelt einen beliebigen Namen in Großbuchstaben A–Z, 0–9, _ um (Umlaute werden umschrieben).
    static func sanitizedBase(_ raw: String, maxLength: Int) -> String {
        var text = raw.uppercased()
        let replacements: [(String, String)] = [("Ä", "AE"), ("Ö", "OE"), ("Ü", "UE"), ("ẞ", "SS"), ("ß", "SS")]
        for (from, to) in replacements { text = text.replacingOccurrences(of: from, with: to) }
        text = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        for character in text {
            if allowed.contains(character) {
                result.append(character)
            } else if character == " " || character == "-" || character == "." {
                if !result.isEmpty && result.last != "_" { result.append("_") }
            }
        }
        while result.hasSuffix("_") { result.removeLast() }
        return String(result.prefix(maxLength))
    }

    /// 8.3-Name für eine Schriftdatei, z. B. „ARIAL.TTF“. Auch OpenType-Schriften erhalten „.TTF“:
    /// `PrinterClient.uploadFont` überträgt jede Schrift mit `~DY…,B,T,…`, der Drucker legt sie
    /// daher immer als `NAME.TTF` ab.
    static func fontName(for url: URL) -> String {
        let base = sanitizedBase(url.deletingPathExtension().lastPathComponent, maxLength: 8)
        return (base.isEmpty ? "FONT" : base) + ".TTF"
    }

    /// Prüft einen Schriftnamen (1–16 Zeichen + .TTF). Liefert eine Fehlermeldung oder nil.
    static func fontNameProblem(_ name: String) -> String? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return tr("Name mit Endung angeben, z. B. ARIAL.TTF.") }
        let base = String(parts[0]), ext = String(parts[1])
        // Der Drucker speichert auch OpenType-Schriften als .TTF (siehe `fontName(for:)`).
        guard ext == "TTF" else { return tr("Die Endung muss .TTF lauten – auch OpenType-Schriften speichert der Drucker als .TTF.") }
        guard !base.isEmpty else { return tr("Der Name darf nicht leer sein.") }
        guard base.count <= 16 else { return tr("Höchstens 16 Zeichen vor der Endung.") }
        guard base.allSatisfy({ allowed.contains($0) }) else { return tr("Nur A–Z, 0–9 und _ verwenden.") }
        return nil
    }

    /// Grafiknamen haben höchstens 8 Zeichen (ohne „.GRF“).
    static func graphicNameProblem(_ name: String) -> String? {
        guard !name.isEmpty else { return tr("Der Name darf nicht leer sein.") }
        guard name.count <= 8 else { return tr("Höchstens 8 Zeichen.") }
        guard name.allSatisfy({ allowed.contains($0) }) else { return tr("Nur A–Z, 0–9 und _ verwenden.") }
        return nil
    }

    /// Normalisiert Eingaben im Namensfeld (Großbuchstaben, keine Leerzeichen).
    static func normalizedInput(_ raw: String, keepDot: Bool) -> String {
        var result = ""
        for character in raw.uppercased() {
            if allowed.contains(character) || (keepDot && character == ".") {
                result.append(character)
            } else if character == " " || character == "-" {
                result.append("_")
            }
        }
        return result
    }

    static func stripGraphicExtension(_ name: String) -> String {
        name.uppercased().hasSuffix(".GRF") ? String(name.dropLast(4)) : name
    }
}

/// Bausteine für Probedrucke und Verweise auf Druckerdateien.
enum FilesZPL {
    /// Vollständiger Pfad, z. B. „E:ARIAL.TTF“.
    static func path(drive: String, name: String) -> String {
        let upper = drive.uppercased()
        let normalized = upper.hasSuffix(":") ? upper : upper + ":"
        return normalized + name
    }

    /// Maskiert Felddaten für `^FH` (Unterstrich als Hex-Kennzeichen).
    static func escapeField(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "_": out += "_5F"
            case "^": out += "_5E"
            case "~": out += "_7E"
            case "\n", "\r", "\r\n", "\t": out += " "
            default: out.append(character)
            }
        }
        return out
    }

    /// ZPL-Verweis zum Kopieren (z. B. für den Designer).
    static func reference(path: String, category: FilesCategory, fontHeight: Int) -> String {
        let ext = (path as NSString).pathExtension.uppercased()
        switch category {
        case .font:
            return "^A@N,\(fontHeight),\(fontHeight),\(path)"
        case .graphic:
            return ext == "GRF" ? "^XG\(path),1,1^FS" : "^IM\(path)^FS"
        case .format:
            return "^XF\(path)^FS"
        case .firmware, .other:
            return path
        }
    }

    /// Probedruck einer TrueType-Schrift in mehreren Größen.
    static func fontSample(path: String, title: String, sample: String,
                           widthDots: Int, heightDots: Int, dotsPerMM: Int) -> String {
        let dpmm = max(6, dotsPerMM)
        let margin = max(16, dpmm * 3)
        let usable = max(120, widthDots - 2 * margin)
        let small = max(18, dpmm * 3)
        let limit = max(heightDots, margin * 2 + small * 4) - margin
        let sizes = [dpmm * 4, dpmm * 7, dpmm * 10].map { max(16, $0) }
        var lines = ["^XA", "^CI28", "^PW\(widthDots)", "^LH0,0"]
        var y = margin
        lines.append("^FO\(margin),\(y)^A0N,\(small),\(small)^FB\(usable),1,0,L,0^FH^FD\(escapeField(title))^FS")
        y += small + dpmm
        lines.append("^FO\(margin),\(y)^GB\(usable),2,2^FS")
        y += dpmm * 2
        let text = escapeField(sample.isEmpty ? "LabelWerk ÄÖÜ äöü ß 0123456789" : sample)
        for (index, size) in sizes.enumerated() {
            if index > 0 && y + size > limit { break }
            lines.append("^FO\(margin),\(y)^A@N,\(size),\(size),\(path)^FB\(usable),1,0,L,0^FH^FD\(text)^FS")
            y += size + dpmm * 2
        }
        if y + small <= limit {
            lines.append("^FO\(margin),\(y)^A@N,\(small),\(small),\(path)^FB\(usable),2,0,L,0^FH^FDABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 €@&%^FS")
        }
        lines.append("^XZ")
        return lines.joined(separator: "\n")
    }

    /// Probedruck einer gespeicherten Grafik (zentriert, mit Beschriftung).
    static func graphicSample(path: String, graphicWidth: Int?, graphicHeight: Int?, caption: String,
                              widthDots: Int, heightDots: Int, dotsPerMM: Int) -> String {
        let dpmm = max(6, dotsPerMM)
        let margin = max(16, dpmm * 3)
        let small = max(18, dpmm * 3)
        let x = graphicWidth.map { max(0, (widthDots - $0) / 2) } ?? margin
        let y = margin
        let ext = (path as NSString).pathExtension.uppercased()
        var lines = ["^XA", "^CI28", "^PW\(widthDots)", "^LH0,0"]
        if ext == "GRF" || ext.isEmpty {
            lines.append("^FO\(x),\(y)^XG\(path),1,1^FS")
        } else {
            lines.append("^FO\(x),\(y)^IM\(path)^FS")
        }
        let captionY = y + (graphicHeight ?? (dpmm * 20)) + dpmm * 2
        if captionY + small <= heightDots - dpmm {
            lines.append("^FO\(margin),\(captionY)^A0N,\(small),\(small)^FB\(max(120, widthDots - 2 * margin)),1,0,C,0^FH^FD\(escapeField(caption))^FS")
        }
        lines.append("^XZ")
        return lines.joined(separator: "\n")
    }

    /// Ruft ein gespeichertes Format ab und druckt es.
    static func formatRecall(path: String) -> String {
        "^XA\n^XF\(path)^FS\n^XZ"
    }
}

// MARK: - Sortierung

enum FilesSortOrder: String, CaseIterable, Identifiable {
    case name, sizeDescending, sizeAscending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return tr("Name")
        case .sizeDescending: return tr("Größte zuerst")
        case .sizeAscending: return tr("Kleinste zuerst")
        }
    }
}

// MARK: - Dateiliste

struct FilesGroup: Identifiable, Equatable {
    var category: FilesCategory
    var files: [PrinterFile]
    var id: FilesCategory { category }
    var totalBytes: Int { files.reduce(0) { $0 + max(0, $1.size) } }
}

/// Zustand der Dateiliste eines Druckers (Laden, Suchen, Löschen, Speicherbelegung).
@Observable
@MainActor
final class FilesBrowserModel {
    var drive: FilesDrive = .flash
    var search = ""
    var sort: FilesSortOrder = .name

    private(set) var files: [PrinterFile] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var lastRefresh: Date?
    private(set) var memory: [FilesDrive: FilesMemoryInfo] = [:]
    private(set) var deleting: Set<String> = []
    /// Erhöht sich nach jedem erfolgreichen Laden (für Animationen).
    private(set) var loadCount = 0
    /// Zählt Ladevorgänge; nur der jüngste darf den Zustand setzen.
    @ObservationIgnored private var loadGeneration = 0

    init() {}

    var filteredGroups: [FilesGroup] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = needle.isEmpty ? files : files.filter {
            $0.name.lowercased().contains(needle) || FilesCategory.of($0).title.lowercased().contains(needle)
        }
        let grouped = Dictionary(grouping: visible) { FilesCategory.of($0) }
        return FilesCategory.allCases.compactMap { category in
            guard let entries = grouped[category], !entries.isEmpty else { return nil }
            return FilesGroup(category: category, files: sorted(entries))
        }
    }

    var totalBytes: Int { files.reduce(0) { $0 + max(0, $1.size) } }

    func count(of category: FilesCategory) -> Int {
        files.filter { FilesCategory.of($0) == category }.count
    }

    func contains(name: String) -> Bool {
        files.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func sorted(_ entries: [PrinterFile]) -> [PrinterFile] {
        switch sort {
        case .name:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .sizeDescending:
            return entries.sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        case .sizeAscending:
            return entries.sorted { $0.size == $1.size ? $0.name < $1.name : $0.size < $1.size }
        }
    }

    // MARK: Laden

    func load(session: PrinterSession, reduceMotion: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let requested = drive
        withAnimation(reduceMotion ? nil : Motion.snappy) {
            isLoading = true
            loadError = nil
        }
        let result = await session.listFiles(drive: requested.code)
        // Ein neuerer Ladevorgang (z. B. nach Laufwerkswechsel) übernimmt den Zustand.
        guard generation == loadGeneration else { return }
        guard !Task.isCancelled, requested == drive else {
            // Abgebrochen (Ansicht verlassen): Ladeanzeige nicht hängen lassen.
            withAnimation(reduceMotion ? nil : Motion.snappy) { isLoading = false }
            return
        }
        var error: String?
        if !session.connectionState.isConnected {
            error = session.lastError ?? tr("Der Drucker ist nicht verbunden.")
        } else if result.isEmpty, let message = session.lastError {
            error = message
        }
        withAnimation(reduceMotion ? nil : Motion.spring) {
            files = result
            loadError = error
            isLoading = false
            hasLoaded = true
            lastRefresh = Date()
            loadCount += 1
        }
    }

    /// Liest freien/gesamten Speicher (Link-OS-SGD). Ohne Antwort bleibt die Anzeige leer.
    func loadMemory(session: PrinterSession, reduceMotion: Bool) async {
        guard session.supportsStatus, session.connectionState.isConnected else { return }
        let names = FilesDrive.allCases.compactMap(\.memoryVariables).flatMap { [$0.free, $0.size] }
        let values = await session.getvars(names)
        guard !values.isEmpty else { return }
        var result: [FilesDrive: FilesMemoryInfo] = [:]
        for drive in FilesDrive.allCases {
            guard let variables = drive.memoryVariables else { continue }
            let info = FilesMemoryInfo(total: FilesMemoryInfo.parseBytes(values[variables.size]),
                                       free: FilesMemoryInfo.parseBytes(values[variables.free]))
            if info.isKnown { result[drive] = info }
        }
        withAnimation(reduceMotion ? nil : Motion.spring) { memory = result }
    }

    // MARK: Löschen

    @discardableResult
    func delete(_ file: PrinterFile, session: PrinterSession, model: AppModel, reduceMotion: Bool) async -> Bool {
        guard !deleting.contains(file.id) else { return false }
        withAnimation(reduceMotion ? nil : Motion.snappy) { _ = deleting.insert(file.id) }
        let ok = await session.deleteFile(FilesZPL.path(drive: file.drive, name: file.name))
        withAnimation(reduceMotion ? nil : Motion.spring) {
            _ = deleting.remove(file.id)
            if ok { files.removeAll { $0.id == file.id } }
        }
        if ok {
            model.toast(tr("Datei gelöscht"), message: FilesZPL.path(drive: file.drive, name: file.name), style: .success)
            await loadMemory(session: session, reduceMotion: reduceMotion)
        }
        return ok
    }
}

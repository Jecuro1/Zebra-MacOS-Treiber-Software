import Foundation
import LabelWerkCore
import LabelWerkImaging
import LabelWerkStatus

extension PrinterClient {

    // MARK: - Dateien

    /// Dateien eines Laufwerks (`E:` Flash, `R:` RAM, `B:` Karte, `Z:` intern, `*` alle).
    ///
    /// ZPL/EPL: `^HW` (Antwort `STX…ETX`); antwortet der Drucker darauf nicht, wird SGD
    /// `file.dir` verwendet. CPCL: nur `file.dir`.
    public func listFiles(drive: String = "E:") async throws -> [PrinterFile] {
        try await guarded {
            let drive = try Self.normalizedDrive(drive, allowWildcard: true)
            if self.language != .cpcl {
                let data = try await self.exchange(ZPL.hostDirectory("\(drive)*.*"), operation: "Dateiliste (^HW)",
                                                   timeout: self.timeouts.bulk, isComplete: ResponseFraming.etxComplete)
                if !data.isEmpty {
                    return Self.files(FileDirectoryParser.parse(data: data), on: drive)
                }
            }
            let capabilities = try await self.resolveCapabilities(knownAlive: false)
            guard capabilities.sgd else { throw PrinterClientError.noResponse("Dateiliste lesen") }
            let data = try await self.exchange(SGD.fileDirectory(drive == "*:" ? "E:" : drive),
                                               operation: "Dateiliste (file.dir)", timeout: self.timeouts.bulk,
                                               isComplete: ResponseFraming.directoryComplete)
            guard !data.isEmpty else { throw PrinterClientError.noResponse("Dateiliste lesen") }
            return Self.files(FileDirectoryParser.parse(data: data), on: drive)
        }
    }

    /// Überträgt eine TrueType-/OpenType-Schrift (`~DY{laufwerk}{NAME},B,T,{länge},,<daten>`).
    ///
    /// Der Name wird wie im Drucker üblich normalisiert (Großbuchstaben, ohne Endung, höchstens
    /// 16 Zeichen); die Datei heißt danach z. B. `E:ARIAL.TTF`.
    ///
    /// - Throws: ``PrinterClientError/invalidFont(_:)``, wenn die Daten keine Schrift sind;
    ///   ``PrinterClientError/unsupportedOperation(_:)`` im CPCL-Modus.
    public func uploadFont(name: String, data: Data, drive: String = "E:") async throws {
        try await guarded {
            guard self.language != .cpcl else {
                throw PrinterClientError.unsupportedOperation("Schriften lassen sich nur im ZPL-Modus übertragen.")
            }
            let drive = try Self.normalizedDrive(drive, allowWildcard: false)
            try Self.validateFont(data)
            guard !Self.objectName(name).isEmpty else {
                throw PrinterClientError.invalidArgument("Der Name der Schrift ist leer.")
            }
            var payload = ZPL.downloadTrueTypeFont(name: Self.objectName(name), drive: drive, data: data)
            payload.append(0x0A)
            try await self.transmit(payload)
        }
    }

    /// Speichert eine Grafik im Drucker (`~DG{laufwerk}{NAME}.GRF,…`), abrufbar mit `^XG`.
    public func uploadGraphic(name: String, bitmap: MonoBitmap, drive: String = "E:") async throws {
        try await guarded {
            guard self.language != .cpcl else {
                throw PrinterClientError.unsupportedOperation("Grafiken lassen sich nur im ZPL-Modus speichern.")
            }
            guard bitmap.width > 0, bitmap.height > 0 else {
                throw PrinterClientError.invalidArgument("Die Grafik hat keine Fläche.")
            }
            let object = Self.objectName(name)
            guard !object.isEmpty else { throw PrinterClientError.invalidArgument("Der Name der Grafik ist leer.") }
            let drive = try Self.normalizedDrive(drive, allowWildcard: false)
            let command = ZPLGraphicEncoder.downloadGraphic(name: object, drive: drive, bitmap: bitmap) + "\n"
            try await self.transmit(command)
        }
    }

    /// Löscht eine Datei (`^ID`, CPCL: SGD `file.delete`). `path` z. B. `E:LOGO.GRF`; ohne
    /// Laufwerk wird `E:` angenommen. Platzhalter (`E:*.GRF`) sind erlaubt.
    public func deleteFile(_ path: String) async throws {
        try await guarded {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PrinterClientError.invalidArgument("Es wurde keine Datei angegeben.") }
            guard !trimmed.contains(where: { $0 == "^" || $0 == "~" || $0 == "\"" || $0.isNewline }) else {
                throw PrinterClientError.invalidArgument("Der Dateiname „\(trimmed)“ enthält unzulässige Zeichen.")
            }
            let full = Self.hasDrive(trimmed) ? trimmed.uppercased() : "E:" + trimmed.uppercased()
            switch self.language {
            case .zpl, .epl:
                try await self.transmit("^XA" + ZPL.deleteObject(full).description + "^XZ\n")
            case .cpcl:
                try await self.transmit(SGD.do("file.delete", full))
            }
        }
    }

    /// Überträgt eine Firmware-Datei in Blöcken.
    ///
    /// `progress` wird mit 0, nach jedem Block und zuletzt mit genau 1,0 aufgerufen. Wird der
    /// Task abgebrochen, endet die Übertragung nach dem laufenden Block (`CancellationError`) –
    /// der Drucker verwirft eine unvollständige Firmware und arbeitet mit der bisherigen weiter.
    /// Nach vollständiger Übertragung installiert der Drucker die Firmware und startet neu; die
    /// nächste Operation baut die Verbindung deshalb neu auf.
    public func sendFirmware(_ data: Data, chunkSize: Int = 16_384,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        try await guarded {
            guard !data.isEmpty else { throw PrinterClientError.invalidArgument("Die Firmware-Datei ist leer.") }
            guard chunkSize > 0 else {
                throw PrinterClientError.invalidArgument("Die Blockgröße muss größer als 0 sein.")
            }
            try Task.checkCancellation()
            try await self.prepareForWriting()
            progress(0)
            let total = data.count
            var offset = 0
            while offset < total {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, total)
                let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
                try await self.connection.write(chunk)
                offset = end
                progress(offset == total ? 1.0 : Double(offset) / Double(total))
            }
            // Der Drucker startet nach der Installation neu – Fähigkeiten neu ermitteln und vor der
            // nächsten Operation neu verbinden.
            self.printerWillRestart()
            self.lastIdentity = nil
        }
    }

    // MARK: - Hilfen

    /// `e`, `E`, `e:` → `E:`; `*` → `*:` (nur wenn erlaubt).
    static func normalizedDrive(_ drive: String, allowWildcard: Bool) throws -> String {
        var value = drive.trimmingCharacters(in: .whitespaces).uppercased()
        if value.hasSuffix(":") { value.removeLast() }
        if value.isEmpty { value = "E" }
        guard value.count == 1, let scalar = value.unicodeScalars.first else {
            throw PrinterClientError.invalidArgument("Ungültiges Laufwerk „\(drive)“ (erwartet z. B. E: oder R:).")
        }
        if scalar == "*" {
            guard allowWildcard else {
                throw PrinterClientError.invalidArgument("Für diese Operation muss ein einzelnes Laufwerk angegeben werden.")
            }
            return "*:"
        }
        guard scalar.value >= 0x41 && scalar.value <= 0x5A else {
            throw PrinterClientError.invalidArgument("Ungültiges Laufwerk „\(drive)“ (erwartet z. B. E: oder R:).")
        }
        return value + ":"
    }

    static func hasDrive(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        return scalars.count >= 2 && scalars[1] == ":"
            && ((scalars[0].value >= 0x41 && scalars[0].value <= 0x5A) || (scalars[0].value >= 0x61 && scalars[0].value <= 0x7A)
                || scalars[0] == "*")
    }

    static func files(_ files: [PrinterFile], on drive: String) -> [PrinterFile] {
        let filtered = drive == "*:" ? files : files.filter { $0.drive == drive }
        return filtered.sorted { ($0.drive, $0.name) < ($1.drive, $1.name) }
    }

    /// Objektname im Druckerformat: Großbuchstaben, ohne Laufwerk und Endung, nur `A–Z 0–9 _ -`,
    /// höchstens 16 Zeichen.
    static func objectName(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = base.firstIndex(of: ":") { base = String(base[base.index(after: colon)...]) }
        if let slash = base.lastIndex(of: "/") { base = String(base[base.index(after: slash)...]) }
        if let dot = base.lastIndex(of: "."), dot != base.startIndex { base = String(base[..<dot]) }
        var out = ""
        for scalar in base.uppercased().unicodeScalars {
            if (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty || scalar != " " {
                out.append("_")
            }
        }
        return String(out.prefix(16))
    }

    /// Prüft die Signatur einer TrueType-/OpenType-Datei.
    static func validateFont(_ data: Data) throws {
        guard data.count >= 12 else {
            throw PrinterClientError.invalidFont("Die Datei ist zu klein (\(data.count) Byte).")
        }
        let tag = [UInt8](data.prefix(4))
        let known: [[UInt8]] = [[0x00, 0x01, 0x00, 0x00], Array("OTTO".utf8), Array("true".utf8), Array("ttcf".utf8)]
        guard known.contains(tag) else {
            throw PrinterClientError.invalidFont("Unbekannte Dateisignatur – erwartet wird TrueType oder OpenType.")
        }
    }
}

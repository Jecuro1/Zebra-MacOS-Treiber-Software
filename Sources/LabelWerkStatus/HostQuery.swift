import Foundation

// MARK: - Fehlerflags (~HQES)

/// Fehlerflags aus `~HQES` (Gruppe 2 in den oberen, Gruppe 1 in den unteren 32 Bit).
///
/// Unbekannte Bits bleiben im ``rawValue`` erhalten.
public struct PrinterErrorFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Kombiniert die beiden 32-Bit-Gruppen der `~HQES`-Antwort.
    public init(group2: UInt32, group1: UInt32) {
        self.init(rawValue: UInt64(group2) << 32 | UInt64(group1))
    }

    public static let mediaOut = PrinterErrorFlags(rawValue: 0x1)
    public static let ribbonOut = PrinterErrorFlags(rawValue: 0x2)
    public static let headOpen = PrinterErrorFlags(rawValue: 0x4)
    public static let cutterFault = PrinterErrorFlags(rawValue: 0x8)
    public static let printheadOverTemp = PrinterErrorFlags(rawValue: 0x10)
    public static let motorOverTemp = PrinterErrorFlags(rawValue: 0x20)
    public static let badPrintheadElement = PrinterErrorFlags(rawValue: 0x40)
    public static let printheadDetectionError = PrinterErrorFlags(rawValue: 0x80)
    public static let invalidFirmwareConfig = PrinterErrorFlags(rawValue: 0x100)
    public static let printheadThermistorOpen = PrinterErrorFlags(rawValue: 0x200)
    /// Kiosk: Papierweg konnte nicht freigeräumt werden (Erweiterung, Bit 0x400).
    public static let clearPaperPathFailed = PrinterErrorFlags(rawValue: 0x400)
    public static let paperFeedError = PrinterErrorFlags(rawValue: 0x800)
    public static let presenterNotRunning = PrinterErrorFlags(rawValue: 0x1000)
    public static let paperJamDuringRetract = PrinterErrorFlags(rawValue: 0x2000)
    public static let blackMarkNotFound = PrinterErrorFlags(rawValue: 0x4000)
    public static let blackMarkCalibrateError = PrinterErrorFlags(rawValue: 0x8000)
    public static let retractTimeout = PrinterErrorFlags(rawValue: 0x10000)
    public static let paused = PrinterErrorFlags(rawValue: 0x20000)

    /// Gruppe 1 (untere 32 Bit).
    public var group1: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
    /// Gruppe 2 (obere 32 Bit).
    public var group2: UInt32 { UInt32(truncatingIfNeeded: rawValue >> 32) }

    /// Alle bekannten Einzelflags mit deutscher Bezeichnung, in Bitreihenfolge.
    public static let known: [(flag: PrinterErrorFlags, name: String)] = [
        (.mediaOut, "Medium leer"),
        (.ribbonOut, "Farbband leer"),
        (.headOpen, "Druckkopf offen"),
        (.cutterFault, "Schneidwerksfehler"),
        (.printheadOverTemp, "Druckkopf überhitzt"),
        (.motorOverTemp, "Motor überhitzt"),
        (.badPrintheadElement, "Defektes Druckkopfelement"),
        (.printheadDetectionError, "Druckkopf nicht erkannt"),
        (.invalidFirmwareConfig, "Ungültige Firmware-Konfiguration"),
        (.printheadThermistorOpen, "Druckkopf-Thermistor unterbrochen"),
        (.clearPaperPathFailed, "Papierweg nicht freigeräumt"),
        (.paperFeedError, "Papiervorschubfehler"),
        (.presenterNotRunning, "Präsenter läuft nicht"),
        (.paperJamDuringRetract, "Papierstau beim Rückzug"),
        (.blackMarkNotFound, "Schwarze Markierung nicht gefunden"),
        (.blackMarkCalibrateError, "Kalibrierung der schwarzen Markierung fehlgeschlagen"),
        (.retractTimeout, "Zeitüberschreitung beim Rückzug"),
        (.paused, "Pausiert"),
    ]

    /// Alle Bits, deren Bedeutung bekannt ist (Vereinigung von ``known``).
    public static let knownMask = PrinterErrorFlags(rawValue: known.reduce(UInt64(0)) { $0 | $1.flag.rawValue })

    /// Gesetzte Bits ohne bekannte Bedeutung (z. B. Gruppe 2 oder Flags neuerer Firmware).
    ///
    /// Der Drucker meldet damit einen Fehler, den LabelWerk nicht benennen kann; der
    /// ``StatusInterpreter`` wertet solche Bits als Fehlerzustand.
    public var unknownFlags: PrinterErrorFlags { subtracting(Self.knownMask) }

    /// Deutsche Bezeichnungen aller gesetzten Flags (unbekannte Bits als Hex-Wert).
    public var displayNames: [String] {
        var names = Self.known.filter { contains($0.flag) }.map(\.name)
        let unknown = unknownFlags.rawValue
        if unknown != 0 { names.append("Unbekannter Fehler 0x\(String(unknown, radix: 16, uppercase: true))") }
        return names
    }
}

// MARK: - Warnflags (~HQES)

/// Warnflags aus `~HQES` (Gruppe 2 in den oberen, Gruppe 1 in den unteren 32 Bit).
public struct PrinterWarningFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Kombiniert die beiden 32-Bit-Gruppen der `~HQES`-Antwort.
    public init(group2: UInt32, group1: UInt32) {
        self.init(rawValue: UInt64(group2) << 32 | UInt64(group1))
    }

    public static let needCalibration = PrinterWarningFlags(rawValue: 0x1)
    public static let cleanPrinthead = PrinterWarningFlags(rawValue: 0x2)
    public static let replacePrinthead = PrinterWarningFlags(rawValue: 0x4)
    public static let paperNearEnd = PrinterWarningFlags(rawValue: 0x8)
    /// Kiosk-Sensor 1: Papier vor dem Druckkopf.
    public static let sensor1 = PrinterWarningFlags(rawValue: 0x10)
    /// Kiosk-Sensor 2: Schwarze Markierung.
    public static let sensor2 = PrinterWarningFlags(rawValue: 0x20)
    /// Kiosk-Sensor 3: Papier hinter dem Druckkopf.
    public static let sensor3 = PrinterWarningFlags(rawValue: 0x40)
    /// Kiosk-Sensor 4: Schlaufe bereit.
    public static let sensor4 = PrinterWarningFlags(rawValue: 0x80)
    /// Kiosk-Sensor 5: Präsenter.
    public static let sensor5 = PrinterWarningFlags(rawValue: 0x100)
    /// Kiosk-Sensor 6: Rückzug bereit.
    public static let sensor6 = PrinterWarningFlags(rawValue: 0x200)
    /// Kiosk-Sensor 7: Im Rückzug.
    public static let sensor7 = PrinterWarningFlags(rawValue: 0x400)
    /// Kiosk-Sensor 8: Im Auffangbehälter.
    public static let sensor8 = PrinterWarningFlags(rawValue: 0x800)

    /// Gruppe 1 (untere 32 Bit).
    public var group1: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
    /// Gruppe 2 (obere 32 Bit).
    public var group2: UInt32 { UInt32(truncatingIfNeeded: rawValue >> 32) }

    /// Alle bekannten Einzelflags mit deutscher Bezeichnung, in Bitreihenfolge.
    public static let known: [(flag: PrinterWarningFlags, name: String)] = [
        (.needCalibration, "Kalibrierung erforderlich"),
        (.cleanPrinthead, "Druckkopf reinigen"),
        (.replacePrinthead, "Druckkopf ersetzen"),
        (.paperNearEnd, "Medium fast leer"),
        (.sensor1, "Sensor 1 (Papier vor Druckkopf)"),
        (.sensor2, "Sensor 2 (Schwarze Markierung)"),
        (.sensor3, "Sensor 3 (Papier hinter Druckkopf)"),
        (.sensor4, "Sensor 4 (Schlaufe bereit)"),
        (.sensor5, "Sensor 5 (Präsenter)"),
        (.sensor6, "Sensor 6 (Rückzug bereit)"),
        (.sensor7, "Sensor 7 (Im Rückzug)"),
        (.sensor8, "Sensor 8 (Im Auffangbehälter)"),
    ]

    /// Kiosk-Sensormeldungen (reine Zustandsinformation, keine Warnung im engeren Sinn).
    public static let sensors: PrinterWarningFlags = [
        .sensor1, .sensor2, .sensor3, .sensor4, .sensor5, .sensor6, .sensor7, .sensor8,
    ]

    /// Alle Bits, deren Bedeutung bekannt ist (Vereinigung von ``known``).
    public static let knownMask = PrinterWarningFlags(rawValue: known.reduce(UInt64(0)) { $0 | $1.flag.rawValue })

    /// Gesetzte Bits ohne bekannte Bedeutung.
    public var unknownFlags: PrinterWarningFlags { subtracting(Self.knownMask) }

    /// Deutsche Bezeichnungen aller gesetzten Flags (unbekannte Bits als Hex-Wert).
    public var displayNames: [String] {
        var names = Self.known.filter { contains($0.flag) }.map(\.name)
        let unknown = unknownFlags.rawValue
        if unknown != 0 { names.append("Unbekannte Warnung 0x\(String(unknown, radix: 16, uppercase: true))") }
        return names
    }
}

// MARK: - HostQueryStatus

/// Antwort auf `~HQES` (Host Query – Error/Warning Status).
///
/// ```
/// <STX>
///   PRINTER STATUS
///    ERRORS:         1 00000000 00000005
///    WARNINGS:       1 00000000 00000002
/// <ETX>
/// ```
/// Je Zeile: Kennziffer (1 = vorhanden), Gruppe 2, Gruppe 1 als achtstellige Hexzahlen.
public struct HostQueryStatus: Hashable, Sendable, Codable {
    public var errors: PrinterErrorFlags
    public var warnings: PrinterWarningFlags

    public init(errors: PrinterErrorFlags = [], warnings: PrinterWarningFlags = []) {
        self.errors = errors
        self.warnings = warnings
    }

    public var hasErrors: Bool { !errors.isEmpty }
    public var hasWarnings: Bool { !warnings.isEmpty }

    /// Antwort exakt im Druckerformat (mit `STX`/`ETX` und `CR LF`).
    public var responseText: String {
        func line(_ label: String, _ present: Bool, _ group2: UInt32, _ group1: UInt32) -> String {
            let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
            return "   \(padded)\(present ? 1 : 0) \(StatusFormat.hex8(group2)) \(StatusFormat.hex8(group1))\r\n"
        }
        return "\u{02}\r\n"
            + "  PRINTER STATUS\r\n"
            + line("ERRORS:", hasErrors, errors.group2, errors.group1)
            + line("WARNINGS:", hasWarnings, warnings.group2, warnings.group1)
            + "\u{03}\r\n"
    }

    /// ``responseText`` als ASCII-Daten.
    public var responseData: Data { Data(responseText.utf8) }
}

// MARK: - Parser

/// Parser für `~HQES`-Antworten.
///
/// Erkennt die Zeilen `ERRORS:` und `WARNINGS:` unabhängig von Einrückung, Groß-/Kleinschreibung,
/// Rahmung und Zeilenenden. Akzeptiert je Zeile `Kennziffer Gruppe2 Gruppe1`, `Gruppe2 Gruppe1`
/// oder nur `Gruppe1`. Fehlt die Warnzeile vollständig (Antwort vor `WARNINGS:` abgeschnitten),
/// bleiben die Warnungen leer.
///
/// Eine **innerhalb** einer Flagzeile abgeschnittene Antwort wird dagegen nie stillschweigend
/// als „keine Fehler“ gedeutet, sondern mit ``StatusParseError/invalidField(name:value:)``
/// abgelehnt, damit der Aufrufer die Abfrage wiederholen kann:
/// * Jede Hexgruppe muss genau ``groupDigits`` Stellen haben (eine gekürzte Gruppe wie
///   `0000000` hätte gerade die niederwertigen Bits – Medium leer, Kopf offen – verloren).
/// * Die Kennziffer muss `0` oder `1` sein; meldet sie `1` (Fehler bzw. Warnung vorhanden),
///   müssen die Gruppen mindestens ein gesetztes Bit enthalten. Umgekehrt gelten gesetzte Bits
///   auch bei Kennziffer `0` – die Bits sind die genauere Angabe.
///
/// Verbleibende Mehrdeutigkeit: Eine genau hinter Gruppe 2 abgeschnittene Zeile gleicht der
/// Kurzform `[Kennziffer] Gruppe1`. Mit Kennziffer `1` und leerer Gruppe 2 (Regelfall) wird
/// sie abgelehnt; ist Gruppe 2 belegt, werden deren Bits als Gruppe 1 gelesen (es bleibt bei
/// einem Fehlerzustand). Nur bei der kennzifferlosen Kurzform einer Firmware, die keine
/// Kennziffer sendet, ist eine solche Kürzung nicht erkennbar.
public enum HostQueryParser {
    /// Stellenzahl einer Hexgruppe laut ZPL-II-Handbuch (`hhhhhhhh`).
    public static let groupDigits = 8

    public static func parse(_ data: Data) throws -> HostQueryStatus {
        try parse(text: StatusText.decode(data))
    }

    /// Variante für bereits dekodierten Text.
    public static func parse(text: String) throws -> HostQueryStatus {
        let lines = StatusText.lines(text)
        guard !lines.isEmpty else { throw StatusParseError.emptyResponse }

        var errors: UInt64?
        var warnings: UInt64?
        var unlabeled: [[String]] = []

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = StatusText.trim(line[..<colon]).uppercased()
            let tokens = StatusText.tokens(line[line.index(after: colon)...])
            guard !tokens.isEmpty else { continue }
            if label.contains("ERR") || label.contains("FEHLER") {
                if errors == nil { errors = try flagValue(tokens: tokens, label: "ERRORS") }
            } else if label.contains("WARN") {
                if warnings == nil { warnings = try flagValue(tokens: tokens, label: "WARNINGS") }
            } else if isCanonicalFlagLine(tokens) {
                // Nur exakt aufgebaute Zeilen („[0|1] hhhhhhhh hhhhhhhh“) gelten als unbeschriftete
                // Flagzeilen – andere Doppelpunktzeilen (z. B. Odometer „1234 INCHES“) nicht.
                unlabeled.append(tokens)
            }
        }
        // Unbeschriftete Zeilen (exotische Firmware) in Reihenfolge: zuerst Fehler, dann Warnungen.
        // Ausgewertet werden nur die tatsächlich benötigten Zeilen; ein Widerspruch zur Kennziffer
        // wird dabei weitergereicht – ein Überspringen würde die Warnzeile zur Fehlerzeile machen.
        if errors == nil, !unlabeled.isEmpty {
            errors = try flagValue(tokens: unlabeled.removeFirst(), label: "ERRORS")
        }
        if warnings == nil, !unlabeled.isEmpty {
            warnings = try flagValue(tokens: unlabeled.removeFirst(), label: "WARNINGS")
        }

        guard let errors else {
            throw StatusParseError.missingSection("ERRORS")
        }
        return HostQueryStatus(errors: PrinterErrorFlags(rawValue: errors),
                               warnings: PrinterWarningFlags(rawValue: warnings ?? 0))
    }

    /// `true` für `[Kennziffer] hhhhhhhh [hhhhhhhh]` mit Kennziffer `0`/`1` und achtstelligen
    /// Hexgruppen.
    static func isCanonicalFlagLine(_ tokens: [String]) -> Bool {
        var groups = tokens
        if groups.count > 1, isIndicator(groups[0]) { groups.removeFirst() }
        return (1...2).contains(groups.count) && groups.allSatisfy(isCompleteGroup)
    }

    /// Wertet `[Kennziffer] [Gruppe2] Gruppe1` aus.
    ///
    /// Die Gruppen sind stets ``groupDigits``-stellig; ein einstelliges erstes Token ist daher
    /// immer die Kennziffer. Steht nur die Kennziffer da (abgeschnittene Antwort), ist nur `0`
    /// eindeutig. Kürzere Gruppen (abgeschnittene Antwort) und eine Kennziffer `1` ohne
    /// gesetztes Bit gelten als ungültig – sie würden sonst einen Drucker mit offenem Kopf
    /// oder leerem Medium als bereit ausweisen.
    static func flagValue(tokens: [String], label: String) throws -> UInt64 {
        let original = tokens.joined(separator: " ")
        var groups = tokens
        // Zusätzliche Wörter hinter den Gruppen (manche Firmware) ignorieren.
        if let firstNonHex = groups.firstIndex(where: { StatusText.hex($0) == nil }) {
            groups = Array(groups[..<firstNonHex])
        }
        guard !groups.isEmpty else {
            throw StatusParseError.invalidField(name: label, value: original)
        }
        var indicator: String?
        if groups[0].count == 1 {
            guard isIndicator(groups[0]) else {
                throw StatusParseError.invalidField(name: label, value: original)
            }
            indicator = groups.removeFirst()
        }
        let value: UInt64
        switch groups.count {
        case 0:
            guard indicator == "0" else {
                throw StatusParseError.invalidField(name: label, value: original)
            }
            return 0
        case 1, 2:
            guard groups.allSatisfy(isCompleteGroup) else {
                throw StatusParseError.invalidField(name: label, value: groups.joined(separator: " "))
            }
            // isCompleteGroup garantiert gültige Hexziffern.
            let parsed = groups.map { StatusText.hex($0) ?? 0 }
            value = parsed.count == 2 ? parsed[0] << 32 | parsed[1] : parsed[0]
        default:
            throw StatusParseError.invalidField(name: label, value: original)
        }
        // Kennziffer 1 = „vorhanden“: ohne gesetztes Bit ist die Zeile unvollständig oder
        // widersprüchlich. Lieber ablehnen (Aufrufer wiederholt) als „Bereit“ melden.
        if indicator == "1", value == 0 {
            throw StatusParseError.invalidField(name: label, value: original)
        }
        return value
    }

    /// Kennziffer `0` (nicht vorhanden) oder `1` (vorhanden).
    static func isIndicator(_ token: String) -> Bool {
        token == "0" || token == "1"
    }

    /// Vollständige Hexgruppe mit genau ``groupDigits`` Stellen.
    static func isCompleteGroup(_ token: String) -> Bool {
        token.unicodeScalars.count == groupDigits && StatusText.hex(token) != nil
    }
}

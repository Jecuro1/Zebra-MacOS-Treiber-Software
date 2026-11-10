import Foundation
import LabelWerkCore

// MARK: - HostStatus (~HS)

/// Antwort auf den ZPL-Befehl `~HS` (Host Status Return).
///
/// Der Drucker sendet drei Zeichenketten, jeweils als `STX … ETX CR LF`:
///
/// ```
/// <STX>aaa,b,c,dddd,eee,f,g,h,iii,j,k,l<ETX><CR><LF>
/// <STX>mmm,n,o,p,q,r,s,t,uuuuuuuu,v,www<ETX><CR><LF>
/// <STX>xxxx,y<ETX><CR><LF>
/// ```
///
/// Die Bedeutung der Felder entspricht dem ZPL II Programming Guide (Kapitel `~HS`).
public struct HostStatus: Hashable, Sendable, Codable {

    // MARK: Zeile 1 – aaa,b,c,dddd,eee,f,g,h,iii,j,k,l

    /// `aaa` – Bitmaske der seriellen Schnittstelle (dezimal), siehe ``serialPort``.
    public var communicationSettings: Int
    /// `b` – Medium (Papier/Etiketten) leer.
    public var paperOut: Bool
    /// `c` – Drucker ist pausiert.
    public var paused: Bool
    /// `dddd` – Etikettenlänge in Punkten.
    public var labelLengthDots: Int
    /// `eee` – Anzahl der Formate im Empfangspuffer.
    public var formatsInReceiveBuffer: Int
    /// `f` – Empfangspuffer voll.
    public var receiveBufferFull: Bool
    /// `g` – Kommunikations-Diagnosemodus aktiv.
    public var diagnosticMode: Bool
    /// `h` – Ein Format wird gerade teilweise empfangen.
    public var partialFormatInProgress: Bool
    /// `j` – RAM beschädigt (Konfigurationsdaten verloren).
    public var corruptRAM: Bool
    /// `k` – Druckkopf unter Betriebstemperatur.
    public var underTemperature: Bool
    /// `l` – Druckkopf über Betriebstemperatur.
    public var overTemperature: Bool

    // MARK: Zeile 2 – mmm,n,o,p,q,r,s,t,uuuuuuuu,v,www

    /// `mmm` – Bitmaske der Funktionseinstellungen (dezimal), siehe ``mediaIsContinuous`` usw.
    public var functionSettings: Int
    /// `o` – Druckkopf geöffnet.
    public var headOpen: Bool
    /// `p` – Farbband leer.
    public var ribbonOut: Bool
    /// `q` – Thermotransfer-Modus gewählt.
    public var thermalTransferMode: Bool
    /// `r` – Druckmodus (`nil`, wenn der Code keinem ``PrintMode`` entspricht, z. B. RFID).
    public var printMode: PrintMode?
    /// `s` – Druckbreitenmodus (laut Handbuch ungenutzt).
    public var printWidthMode: Int
    /// `t` – Ein Etikett wartet im Spendemodus auf Entnahme.
    public var labelWaitingToBePeeled: Bool
    /// `uuuuuuuu` – Noch zu druckende Etiketten im aktuellen Auftrag.
    public var labelsRemainingInBatch: Int
    /// `v` – Formatverarbeitung während des Grafikschreibens (laut Handbuch immer 1).
    public var formatWhileWritingGraphics: Bool
    /// `www` – Anzahl der im Speicher abgelegten Grafiken.
    public var graphicsStoredInMemory: Int

    // MARK: Zeile 3 – xxxx,y

    /// `xxxx` – Passwort (vierstellig).
    public var password: String
    /// `y` – Statisches RAM installiert.
    public var staticRAMInstalled: Bool

    // MARK: Erweiterungen

    /// Unveränderter Druckmodus-Code `r` aus der Antwort (z. B. `"2"`, `"6"`, `"9"`, `"K"`).
    ///
    /// Trägt Zusatzinformationen, die ``printMode`` nicht abbilden kann (Linerless-Varianten,
    /// Teilschnitt, RFID). Leer, wenn unbekannt.
    public var printModeCode: String

    public init(
        communicationSettings: Int = 0,
        paperOut: Bool = false,
        paused: Bool = false,
        labelLengthDots: Int = 0,
        formatsInReceiveBuffer: Int = 0,
        receiveBufferFull: Bool = false,
        diagnosticMode: Bool = false,
        partialFormatInProgress: Bool = false,
        corruptRAM: Bool = false,
        underTemperature: Bool = false,
        overTemperature: Bool = false,
        functionSettings: Int = 0,
        headOpen: Bool = false,
        ribbonOut: Bool = false,
        thermalTransferMode: Bool = false,
        printMode: PrintMode? = .tearOff,
        printWidthMode: Int = 0,
        labelWaitingToBePeeled: Bool = false,
        labelsRemainingInBatch: Int = 0,
        formatWhileWritingGraphics: Bool = true,
        graphicsStoredInMemory: Int = 0,
        password: String = "1234",
        staticRAMInstalled: Bool = false,
        printModeCode: String? = nil
    ) {
        self.communicationSettings = communicationSettings
        self.paperOut = paperOut
        self.paused = paused
        self.labelLengthDots = labelLengthDots
        self.formatsInReceiveBuffer = formatsInReceiveBuffer
        self.receiveBufferFull = receiveBufferFull
        self.diagnosticMode = diagnosticMode
        self.partialFormatInProgress = partialFormatInProgress
        self.corruptRAM = corruptRAM
        self.underTemperature = underTemperature
        self.overTemperature = overTemperature
        self.functionSettings = functionSettings
        self.headOpen = headOpen
        self.ribbonOut = ribbonOut
        self.thermalTransferMode = thermalTransferMode
        self.printMode = printMode
        self.printWidthMode = printWidthMode
        self.labelWaitingToBePeeled = labelWaitingToBePeeled
        self.labelsRemainingInBatch = labelsRemainingInBatch
        self.formatWhileWritingGraphics = formatWhileWritingGraphics
        self.graphicsStoredInMemory = graphicsStoredInMemory
        self.password = password
        self.staticRAMInstalled = staticRAMInstalled
        self.printModeCode = printModeCode ?? printMode.map(HostStatus.code(for:)) ?? ""
    }
}

// MARK: - Druckmodus-Codes

extension HostStatus {
    /// Bekannte Codes des Feldes `r` mit Zuordnung und deutscher Bezeichnung.
    static let printModeTable: [(code: String, mode: PrintMode?, name: String)] = [
        ("0", .rewind, "Aufwickeln"),
        ("1", .peelOff, "Spenden (Peel-Off)"),
        ("2", .tearOff, "Abreißen"),
        ("3", .cutter, "Schneiden"),
        ("4", .applicator, "Applikator"),
        ("5", .delayedCut, "Verzögert schneiden"),
        ("6", .peelOff, "Linerless – Spenden"),
        ("7", .rewind, "Linerless – Aufwickeln"),
        ("8", .cutter, "Teilschnitt"),
        ("9", nil, "RFID"),
        ("K", .kiosk, "Kiosk"),
        ("S", nil, "Stream"),
        ("A", .tearOff, "Linerless – Abreißen"),
    ]

    /// Ordnet einen `~HS`-Druckmoduscode einem ``PrintMode`` zu.
    ///
    /// Linerless-Varianten werden auf den gleichwertigen Grundmodus abgebildet
    /// (6 → Spenden, 7 → Aufwickeln, A → Abreißen), der Teilschnitt (8) auf Schneiden.
    /// RFID (9), Stream (S) und unbekannte Codes liefern `nil`.
    public static func printMode(forCode code: String) -> PrintMode? {
        let normalized = StatusText.trim(code).uppercased()
        return printModeTable.first { $0.code == normalized }?.mode
    }

    /// Kanonischer `~HS`-Code eines ``PrintMode`` (Umkehrung von ``printMode(forCode:)``).
    public static func code(for mode: PrintMode) -> String {
        switch mode {
        case .rewind: return "0"
        case .peelOff: return "1"
        case .tearOff: return "2"
        case .cutter: return "3"
        case .applicator: return "4"
        case .delayedCut: return "5"
        case .kiosk: return "K"
        }
    }

    /// Deutsche Bezeichnung des gemeldeten Druckmodus (inkl. Linerless-/RFID-Varianten).
    public var printModeDisplayName: String {
        let code = effectivePrintModeCode
        if let entry = Self.printModeTable.first(where: { $0.code == code }) { return entry.name }
        if let printMode { return printMode.displayName }
        return code.isEmpty ? "Unbekannt" : "Unbekannt (\(code))"
    }

    /// Der Code, der zu ``printMode`` passt: ``printModeCode``, sofern er denselben Modus
    /// beschreibt, sonst der kanonische Code von ``printMode``.
    var effectivePrintModeCode: String {
        let raw = StatusText.trim(printModeCode).uppercased()
        if let printMode {
            return Self.printMode(forCode: raw) == printMode ? raw : Self.code(for: printMode)
        }
        return raw
    }
}

// MARK: - Abgeleitete Werte

extension HostStatus {
    /// Einstellungen der seriellen Schnittstelle aus `aaa`.
    public struct SerialPortSettings: Hashable, Sendable, Codable {
        public enum Parity: String, Hashable, Sendable, Codable { case none, odd, even }
        public enum Handshake: String, Hashable, Sendable, Codable { case xonXoff, dtr }

        /// Baudrate oder `nil`, wenn der Code unbekannt ist.
        public var baudRate: Int?
        /// 7 oder 8 Datenbits.
        public var dataBits: Int
        /// 1 oder 2 Stoppbits.
        public var stopBits: Int
        public var parity: Parity
        public var handshake: Handshake

        /// Kurzform wie „9600 8N1“.
        public var summary: String {
            let parityLetter: String
            switch parity {
            case .none: parityLetter = "N"
            case .odd: parityLetter = "O"
            case .even: parityLetter = "E"
            }
            let baud = baudRate.map(String.init) ?? "?"
            return "\(baud) \(dataBits)\(parityLetter)\(stopBits)"
        }
    }

    /// Dekodierte serielle Schnittstelle (Bits a8 a7 … a0 von `aaa`).
    ///
    /// Bitbelegung: a7 Handshake (0 = Xon/Xoff, 1 = DTR), a6 Parität (0 = ungerade, 1 = gerade),
    /// a5 Parität aktiv, a4 Stoppbits (0 = 2, 1 = 1), a3 Datenbits (0 = 7, 1 = 8),
    /// a8 a2 a1 a0 Baudrate.
    public var serialPort: SerialPortSettings {
        let bits = communicationSettings
        let baudCode = (bits & 0b111) | ((bits >> 8) & 1) << 3
        let baudRates: [Int: Int] = [
            0: 110, 1: 300, 2: 600, 3: 1200, 4: 2400, 5: 4800, 6: 9600, 7: 19200,
            8: 28800, 9: 38400, 10: 57600, 11: 14400, 12: 115200,
        ]
        let parity: SerialPortSettings.Parity = bits & 0x20 == 0 ? .none : (bits & 0x40 == 0 ? .odd : .even)
        return SerialPortSettings(
            baudRate: baudRates[baudCode],
            dataBits: bits & 0x08 == 0 ? 7 : 8,
            stopBits: bits & 0x10 == 0 ? 2 : 1,
            parity: parity,
            handshake: bits & 0x80 == 0 ? .xonXoff : .dtr
        )
    }

    /// Bit m7: Endlosmaterial (sonst Etiketten mit Lücke/Stanzung).
    public var mediaIsContinuous: Bool { functionSettings & 0x80 != 0 }
    /// Bit m6: Sensorprofil aktiv.
    public var sensorProfileActive: Bool { functionSettings & 0x40 != 0 }
    /// Bit m5: Kommunikationsdiagnose aktiv.
    public var communicationsDiagnosticsActive: Bool { functionSettings & 0x20 != 0 }
    /// Bit m0: Druckverfahren laut Funktionseinstellungen (`true` = Thermotransfer).
    public var functionSettingsThermalTransfer: Bool { functionSettings & 0x01 != 0 }

    /// Medientyp, wie ihn der Drucker meldet.
    public var mediaType: MediaType { thermalTransferMode ? .thermalTransfer : .directThermal }

    /// `true`, wenn der Drucker gerade Daten verarbeitet oder Etiketten druckt.
    public var isBusy: Bool { labelsRemainingInBatch > 0 || formatsInReceiveBuffer > 0 || partialFormatInProgress }
}

// MARK: - Antwort erzeugen

extension HostStatus {
    /// Antwort exakt im Druckerformat (drei `STX…ETX CR LF`-Zeichenketten).
    ///
    /// Wird vom virtuellen Drucker verwendet und ist mit ``HostStatusParser`` umkehrbar.
    public var responseText: String {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        let line1 = [
            StatusFormat.padded(communicationSettings, 3), flag(paperOut), flag(paused),
            StatusFormat.padded(labelLengthDots, 4), StatusFormat.padded(formatsInReceiveBuffer, 3),
            flag(receiveBufferFull), flag(diagnosticMode), flag(partialFormatInProgress), "000",
            flag(corruptRAM), flag(underTemperature), flag(overTemperature),
        ].joined(separator: ",")
        let modeCode = effectivePrintModeCode.isEmpty ? "2" : effectivePrintModeCode
        let line2 = [
            StatusFormat.padded(functionSettings, 3), "0", flag(headOpen), flag(ribbonOut),
            flag(thermalTransferMode), modeCode, String(printWidthMode), flag(labelWaitingToBePeeled),
            StatusFormat.padded(labelsRemainingInBatch, 8), flag(formatWhileWritingGraphics),
            StatusFormat.padded(graphicsStoredInMemory, 3),
        ].joined(separator: ",")
        let sanitizedPassword = password.filter { $0 != "," && !$0.isNewline }
        let line3 = "\(sanitizedPassword),\(flag(staticRAMInstalled))"
        return [line1, line2, line3].map { "\u{02}\($0)\u{03}\r\n" }.joined()
    }

    /// ``responseText`` als ASCII-Daten.
    public var responseData: Data { Data(responseText.utf8) }
}

/// Formatierhilfen für erzeugte Antworten.
enum StatusFormat {
    /// Dezimalzahl mit führenden Nullen (negatives Vorzeichen bleibt erhalten).
    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value.magnitude)
        let padding = String(repeating: "0", count: max(0, width - digits.count))
        return (value < 0 ? "-" : "") + padding + digits
    }

    /// Achtstellige Hexzahl in Großbuchstaben.
    static func hex8(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}

// MARK: - Parser

/// Parser für `~HS`-Antworten.
///
/// Toleriert fehlende `STX`/`ETX`-Rahmung, reine `LF`- oder `CR`-Zeilenenden, Leerraum um Felder,
/// vorangestellte Fremdzeilen (z. B. Echo), überzählige Felder neuerer Firmware sowie eine
/// fehlende oder abgeschnittene dritte Zeile. Fehlende Felder am Zeilenende werden mit
/// neutralen Werten (0 bzw. `false`) belegt.
public enum HostStatusParser {
    /// Mindestanzahl Felder in Zeile 1 (`aaa`, Papier leer, Pause).
    static let minimumLine1Fields = 3
    /// Mindestanzahl Felder in Zeile 2 (`mmm`, `n`, Kopf offen).
    static let minimumLine2Fields = 3

    public static func parse(_ data: Data) throws -> HostStatus {
        try parse(text: StatusText.decode(data))
    }

    /// Variante für bereits dekodierten Text.
    public static func parse(text: String) throws -> HostStatus {
        let lines = StatusText.lines(text)
        guard !lines.isEmpty else { throw StatusParseError.emptyResponse }

        guard let firstIndex = lines.firstIndex(where: isLine1Candidate) else {
            throw StatusParseError.unrecognizedFormat("Keine ~HS-Statuszeile gefunden")
        }
        let line1 = FieldReader(fields: StatusText.fields(lines[firstIndex]), line: 1)
        guard firstIndex + 1 < lines.count else {
            throw StatusParseError.missingSection("~HS Zeile 2")
        }
        let line2 = FieldReader(fields: StatusText.fields(lines[firstIndex + 1]), line: 2)
        guard line2.fields.count >= minimumLine2Fields, StatusText.integer(line2.fields[0]) != nil else {
            throw StatusParseError.missingSection("~HS Zeile 2")
        }
        let line3: FieldReader? = firstIndex + 2 < lines.count
            ? FieldReader(fields: StatusText.fields(lines[firstIndex + 2]), line: 3)
            : nil

        var status = HostStatus(printMode: nil, password: "", printModeCode: "")
        status.communicationSettings = try line1.int(0, "aaa (Schnittstelle)")
        status.paperOut = try line1.flag(1, "b (Papier leer)")
        status.paused = try line1.flag(2, "c (Pause)")
        status.labelLengthDots = try line1.int(3, "dddd (Etikettenlänge)")
        status.formatsInReceiveBuffer = try line1.int(4, "eee (Formate im Puffer)")
        status.receiveBufferFull = try line1.flag(5, "f (Puffer voll)")
        status.diagnosticMode = try line1.flag(6, "g (Diagnosemodus)")
        status.partialFormatInProgress = try line1.flag(7, "h (Teilformat)")
        // Feld 8 (iii) ist unbenutzt.
        status.corruptRAM = try line1.flag(9, "j (RAM beschädigt)")
        status.underTemperature = try line1.flag(10, "k (Untertemperatur)")
        status.overTemperature = try line1.flag(11, "l (Übertemperatur)")

        status.functionSettings = try line2.int(0, "mmm (Funktionseinstellungen)")
        // Feld 1 (n) ist unbenutzt.
        status.headOpen = try line2.flag(2, "o (Kopf offen)")
        status.ribbonOut = try line2.flag(3, "p (Farbband leer)")
        status.thermalTransferMode = try line2.flag(4, "q (Thermotransfer)")
        let modeCode = line2.string(5).uppercased()
        status.printModeCode = modeCode
        status.printMode = modeCode.isEmpty ? nil : HostStatus.printMode(forCode: modeCode)
        status.printWidthMode = try line2.int(6, "s (Druckbreitenmodus)")
        status.labelWaitingToBePeeled = try line2.flag(7, "t (Etikett wartet)")
        status.labelsRemainingInBatch = try line2.int(8, "uuuuuuuu (Restetiketten)")
        status.formatWhileWritingGraphics = try line2.fields.count > 9
            ? line2.flag(9, "v (Format beim Grafikschreiben)")
            : true
        status.graphicsStoredInMemory = try line2.int(10, "www (Grafiken)")

        if let line3, looksLikeLine3(line3.fields) {
            status.password = line3.string(0)
            status.staticRAMInstalled = (try? line3.flag(1, "y (statisches RAM)")) ?? false
        }
        return status
    }

    /// Zeile 1 erkennt man an mindestens drei Feldern, deren erste drei Ganzzahlen sind.
    static func isLine1Candidate(_ line: String) -> Bool {
        let fields = StatusText.fields(line)
        guard fields.count >= minimumLine1Fields else { return false }
        return fields.prefix(3).allSatisfy { StatusText.integer($0) != nil }
    }

    /// Zeile 3 besteht aus Passwort und Flag; abgeschnittene Varianten werden toleriert,
    /// Fremdtext (z. B. Folgeantworten) nicht.
    static func looksLikeLine3(_ fields: [String]) -> Bool {
        guard let password = fields.first, !password.isEmpty, password.count <= 8 else { return false }
        return password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// Liest einzelne Felder einer kommagetrennten Statuszeile.
struct FieldReader {
    let fields: [String]
    let line: Int

    func string(_ index: Int) -> String {
        index < fields.count ? fields[index] : ""
    }

    /// Ganzzahl; fehlendes oder leeres Feld → 0, ungültiger Inhalt → Fehler.
    func int(_ index: Int, _ name: String) throws -> Int {
        let raw = string(index)
        if raw.isEmpty { return 0 }
        guard let value = StatusText.integer(raw) else {
            throw StatusParseError.invalidField(name: "Zeile \(line): \(name)", value: raw)
        }
        return value
    }

    /// Flag (`0` = aus, alles andere Numerische = an); fehlendes Feld → `false`.
    func flag(_ index: Int, _ name: String) throws -> Bool {
        try int(index, name) != 0
    }
}

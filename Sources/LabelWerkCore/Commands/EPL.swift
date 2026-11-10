import Foundation

/// Bausteine für EPL2 (Eltron Programming Language), z. B. für LP/TLP 2844 und GK/GX im EPL-Modus.
///
/// Jede Funktion liefert **eine Befehlszeile ohne Zeilenende**. Mit ``render(_:)``,
/// ``program(_:)`` oder ``label(quantity:copies:_:)`` werden Zeilen mit `\n` abgeschlossen.
///
/// Hinweis zum Zeichensatz: EPL kennt kein UTF-8. Programme mit Umlauten werden mit
/// ``encode(_:)`` als Windows-1252 übertragen (passend zu ``characterSet(bits:codePage:country:)``
/// mit Codepage `A`), oder Texte vorher mit ``transliterated(_:)`` auf ASCII abgebildet.
///
/// Grafiken (`GW`) erzeugt `EPLGraphicEncoder` in LabelWerkImaging.
public enum EPL {
    /// Zeilenende von EPL2.
    public static let lineEnding = "\n"

    // MARK: - Programm & Etikett

    /// Schließt jede Zeile mit `\n` ab.
    public static func render(_ lines: [String]) -> String {
        lines.map { $0 + lineEnding }.joined()
    }

    /// Baut ein Programm aus Zeilen (jede mit `\n` abgeschlossen).
    public static func program(@CommandLineBuilder _ content: () -> [String]) -> String {
        render(content())
    }

    /// Vollständiges Etikett: führender Zeilenvorschub (leert Restdaten), `N`, Inhalt, `P…`.
    public static func label(quantity: Int = 1, copies: Int? = nil,
                             @CommandLineBuilder _ content: () -> [String]) -> String {
        lineEnding + render([clearImageBuffer()] + content() + [print(quantity, copies: copies)])
    }

    // MARK: - Etikett-Setup

    /// `N` – Bildspeicher löschen (Beginn eines Etiketts).
    public static func clearImageBuffer() -> String { "N" }

    /// `q{punkte}` – Etikettenbreite.
    public static func labelWidth(_ dots: Int) -> String { "q\(clampInt(dots, 1, 9_999))" }

    /// Art der Etikettenerkennung für `Q`.
    public enum MediaSensing: Hashable, Sendable {
        /// Etiketten mit Lücke, Lückenlänge in Punkten. Eine Lücke `<= 0` bedeutet „keine Lücke“
        /// und wählt wie in EPL2 Endlosmaterial (`Q{länge},0`).
        case gap(Int)
        /// Schwarze Markierung (Höhe in Punkten) mit optionalem Versatz in Punkten.
        case blackMark(height: Int, offset: Int)
        /// Endlosmaterial.
        case continuous
    }

    /// Größte Lücken- bzw. Markenhöhe für `Q` in Punkten (alle Auflösungen).
    public static let maximumGapDots = 240

    /// Kleinste Lücken- bzw. Markenhöhe für `Q` laut EPL2-Handbuch: 16 Punkte bei 203 dpi
    /// (und darunter), 18 Punkte ab 300 dpi.
    public static func minimumGapDots(for resolution: Resolution) -> Int {
        resolution.dpi >= 300 ? 18 : 16
    }

    /// `Q{länge},{lücke}` / `Q{länge},B{marke}[,{versatz}]` / `Q{länge},0`.
    ///
    /// Lücke und Markenhöhe werden auf den gültigen Bereich der Auflösung begrenzt
    /// (``minimumGapDots(for:)`` … ``maximumGapDots``); `.gap` mit einer Lücke `<= 0` ergibt
    /// Endlosmaterial (`Q{länge},0`) statt still auf Lückenerkennung umzuschalten.
    ///
    /// - Parameter resolution: Auflösung des Druckers (bestimmt die Mindestlücke, Standard 203 dpi).
    public static func formLength(_ length: Int, sensing: MediaSensing, resolution: Resolution = .dpi203) -> String {
        let l = clampInt(length, 1, 65_535)
        let minimum = minimumGapDots(for: resolution)
        switch sensing {
        case .gap(let gap):
            guard gap > 0 else { return "Q\(l),0" }
            return "Q\(l),\(clampInt(gap, minimum, maximumGapDots))"
        case .blackMark(let height, let offset):
            let base = "Q\(l),B\(clampInt(height, minimum, maximumGapDots))"
            return offset == 0 ? base : base + ",\(clampInt(offset, -9_999, 9_999))"
        case .continuous:
            return "Q\(l),0"
        }
    }

    /// `Q{länge},{lücke}` – Etiketten mit Lücke; `gap <= 0` wählt Endlosmaterial (`Q{länge},0`).
    ///
    /// - Parameter resolution: Auflösung des Druckers (Mindestlücke 16 bzw. 18 Punkte ab 300 dpi).
    public static func formLength(_ length: Int, gap: Int, resolution: Resolution = .dpi203) -> String {
        formLength(length, sensing: .gap(gap), resolution: resolution)
    }

    /// `S{wert}` – Geschwindigkeitsstufe (1…6, modellabhängig).
    public static func speed(_ value: Int) -> String { "S\(clampInt(value, 1, 6))" }

    /// `D{wert}` – Schwärzung 0…15.
    public static func density(_ value: Int) -> String { "D\(clampInt(value, 0, 15))" }

    /// `ZT` (Kopfseite zuerst, Standard) bzw. `ZB` (um 180° gedreht).
    public static func printDirection(topFirst: Bool) -> String { topFirst ? "ZT" : "ZB" }

    /// Hardware-Optionen des `O`-Befehls.
    public enum HardwareOption: Hashable, Sendable {
        /// `C` – Abschneider am Ende jedes Etiketts.
        case cutter
        /// `C{n}` – nach je `n` Etiketten schneiden (1…255).
        case cutterEvery(Int)
        /// `Cb` – Stapeldruck, Schnitt gesteuert über `P`.
        case cutterBatch
        /// `D` – Thermodirekt-Modus.
        case directThermal
        /// `P` – Spendemodus mit Entnahmesensor.
        case peel
        /// `L` – Spendemodus „Tap to Print“ (Taste vor jedem Etikett).
        case tapToPrint
        /// `S` – Lückensensor invertieren.
        case reverseGapSensor

        var code: String {
            switch self {
            case .cutter: return "C"
            case .cutterEvery(let n): return "C\(clampInt(n, 1, 255))"
            case .cutterBatch: return "Cb"
            case .directThermal: return "D"
            case .peel: return "P"
            case .tapToPrint: return "L"
            case .reverseGapSensor: return "S"
            }
        }
    }

    /// `O[C[p1],D,P,L,S]` – Hardware-Optionen, durch Komma getrennt (z. B. `OD,P`).
    /// Ohne Optionen (`O`) werden alle Optionen deaktiviert.
    public static func options(_ options: [HardwareOption]) -> String {
        "O" + options.map(\.code).joined(separator: ",")
    }

    /// `R{x},{y}` – Bezugspunkt (verschiebt alle folgenden Koordinaten).
    public static func referencePoint(x: Int, y: Int) -> String {
        "R\(clampInt(x, 0, 9_999)),\(clampInt(y, 0, 9_999))"
    }

    /// `I{bits},{codepage},{land}` – Zeichensatz, z. B. `I8,A,049` (Windows-1252, Deutschland).
    ///
    /// - Parameters:
    ///   - bits: 8 oder 7.
    ///   - codePage: 8 Bit: `0`…`13` (DOS-Codepages) oder `A`…`F` (Windows 1252, 1250, 1251, 1253, 1254, 1255).
    ///   - country: KDU-Ländercode, dreistellig (z. B. `001` USA, `049` Deutschland).
    public static func characterSet(bits: Int = 8, codePage: String = "A", country: String = "049") -> String {
        "I\(bits == 7 ? 7 : 8),\(codePage),\(country)"
    }

    /// `JF` (Rückzug vor dem Druck aktiv) bzw. `JB` (deaktiviert).
    public static func topOfFormBackup(_ enabled: Bool) -> String { enabled ? "JF" : "JB" }

    // MARK: - Text & Barcodes

    /// Drehung von Text und Barcodes (`p3`).
    public enum Rotation: Int, Sendable, CaseIterable {
        case normal = 0
        case rotated90 = 1
        case rotated180 = 2
        case rotated270 = 3
    }

    /// `A{x},{y},{rot},{schrift},{h},{v},{N|R},"{daten}"` – Text.
    ///
    /// - Parameters:
    ///   - font: `1`…`5` (residente Schriften) oder `a`…`z` (geladene Schriften).
    ///   - horizontalMultiplier: 1…6 oder 8.
    ///   - verticalMultiplier: 1…9.
    ///   - reverse: Invertiert (weiß auf schwarz).
    public static func text(_ text: String, x: Int, y: Int, font: String = "3", rotation: Rotation = .normal,
                            horizontalMultiplier: Int = 1, verticalMultiplier: Int = 1,
                            reverse: Bool = false) -> String {
        var h = clampInt(horizontalMultiplier, 1, 8)
        if h == 7 { h = 6 }
        let v = clampInt(verticalMultiplier, 1, 9)
        return "A\(clampInt(x, 0, 9_999)),\(clampInt(y, 0, 9_999)),\(rotation.rawValue),\(font),\(h),\(v),\(reverse ? "R" : "N"),\(quoted(text))"
    }

    /// Barcode-Typen des `B`-Befehls (`p4`).
    public enum BarcodeType: String, Sendable, CaseIterable {
        case code128UCC = "0"
        case code128 = "1"
        case code128A = "1A"
        case code128B = "1B"
        case code128C = "1C"
        case ucc128 = "1E"
        case interleaved2of5 = "2"
        case interleaved2of5CheckDigit = "2C"
        case interleaved2of5HumanCheckDigit = "2D"
        case germanPostcode = "2G"
        case matrix2of5 = "2M"
        case upcInterleaved2of5 = "2U"
        case code39 = "3"
        case code39CheckDigit = "3C"
        case code93 = "9"
        case ean13 = "E30"
        case ean13Addon2 = "E32"
        case ean13Addon5 = "E35"
        case ean8 = "E80"
        case ean8Addon2 = "E82"
        case ean8Addon5 = "E85"
        case codabar = "K"
        case postnet = "P"
        case planet = "PL"
        case japanesePostnet = "J"
        case upcA = "UA0"
        case upcAAddon2 = "UA2"
        case upcAAddon5 = "UA5"
        case upcE = "UE0"
        case upcEAddon2 = "UE2"
        case upcEAddon5 = "UE5"
    }

    /// `B{x},{y},{rot},{typ},{schmal},{breit},{höhe},{B|N},"{daten}"` – Barcode.
    public static func barcode(_ data: String, x: Int, y: Int, type: BarcodeType, narrowBar: Int = 2,
                               wideBar: Int = 4, height: Int, rotation: Rotation = .normal,
                               humanReadable: Bool = true) -> String {
        "B\(clampInt(x, 0, 9_999)),\(clampInt(y, 0, 9_999)),\(rotation.rawValue),\(type.rawValue),"
            + "\(clampInt(narrowBar, 1, 10)),\(clampInt(wideBar, 2, 30)),\(clampInt(height, 1, 9_999)),"
            + "\(humanReadable ? "B" : "N"),\(quoted(data))"
    }

    // MARK: - Linien & Rahmen

    /// `LO{x},{y},{breite},{höhe}` – schwarze (gefüllte) Linie.
    public static func lineBlack(x: Int, y: Int, width: Int, height: Int) -> String {
        "LO" + rect(x, y, width, height)
    }

    /// `LE{x},{y},{breite},{höhe}` – Linie mit XOR (invertiert darunterliegende Inhalte).
    public static func lineXOR(x: Int, y: Int, width: Int, height: Int) -> String {
        "LE" + rect(x, y, width, height)
    }

    /// `LW{x},{y},{breite},{höhe}` – weiße Linie (löscht).
    public static func lineWhite(x: Int, y: Int, width: Int, height: Int) -> String {
        "LW" + rect(x, y, width, height)
    }

    /// `LS{x1},{y1},{stärke},{x2},{y2}` – diagonale Linie.
    public static func diagonalLine(x1: Int, y1: Int, thickness: Int, x2: Int, y2: Int) -> String {
        "LS\(clampInt(x1, 0, 9_999)),\(clampInt(y1, 0, 9_999)),\(clampInt(thickness, 1, 9_999)),\(clampInt(x2, 0, 9_999)),\(clampInt(y2, 0, 9_999))"
    }

    /// `X{x1},{y1},{stärke},{x2},{y2}` – Rahmen.
    public static func box(x1: Int, y1: Int, thickness: Int, x2: Int, y2: Int) -> String {
        "X\(clampInt(x1, 0, 9_999)),\(clampInt(y1, 0, 9_999)),\(clampInt(thickness, 1, 9_999)),\(clampInt(x2, 0, 9_999)),\(clampInt(y2, 0, 9_999))"
    }

    // MARK: - Drucken & Geräte

    /// `P{sätze}` bzw. `P{sätze},{kopien}` – Druck auslösen.
    public static func print(_ sets: Int = 1, copies: Int? = nil) -> String {
        let p1 = clampInt(sets, 1, 65_535)
        if let copies { return "P\(p1),\(clampInt(copies, 1, 65_535))" }
        return "P\(p1)"
    }

    /// `U` – Konfigurationsetikett drucken.
    public static func printConfiguration() -> String { "U" }

    /// `UQ` – Konfiguration an den Host senden.
    public static func queryConfiguration() -> String { "UQ" }

    /// `xa` – AutoSense: Etikettenlänge und Lücke messen (Kalibrierung).
    public static func autoSense() -> String { "xa" }

    /// `^@` – Drucker zurücksetzen (Neustart).
    public static func reset() -> String { "^@" }

    /// `^default` – Werkseinstellungen wiederherstellen.
    public static func factoryDefaults() -> String { "^default" }

    /// `GG{x},{y},"{name}"` – gespeicherte Grafik drucken.
    public static func printStoredGraphic(_ name: String, x: Int, y: Int) -> String {
        "GG\(clampInt(x, 0, 9_999)),\(clampInt(y, 0, 9_999)),\(quoted(name))"
    }

    /// `GK"{name}"` – gespeicherte Grafik löschen (`"*"` = alle).
    public static func deleteGraphic(_ name: String) -> String { "GK" + quoted(name) }

    /// `GI` – Grafikliste an den Host senden.
    public static func listGraphics() -> String { "GI" }

    // MARK: - Hilfen

    /// Setzt Text in Anführungszeichen: `"` → `\"`, `\` → `\\`, Steuerzeichen werden entfernt.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in LegacyText.singleLine(text).unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Bildet Text auf ASCII ab (ä → ae, × → x …) – für Drucker ohne passende Codepage.
    public static func transliterated(_ text: String) -> String { LegacyText.asciiTransliterated(text) }

    /// Kodiert ein EPL-Programm als Windows-1252 (Codepage `A`); nicht darstellbare Zeichen werden `?`.
    ///
    /// Der Text wird zuvor in die kanonisch zusammengesetzte Form (NFC) gebracht: Zerlegte
    /// Zeichen, wie sie macOS-Dateinamen und manche eingefügten Texte enthalten (`a` + U+0308),
    /// werden so zu `ä` (0xE4) statt zu `a?`.
    public static func encode(_ program: String) -> Data {
        let normalized = program.precomposedStringWithCanonicalMapping
        var out = Data()
        out.reserveCapacity(normalized.utf8.count)
        for scalar in normalized.unicodeScalars {
            if scalar.value < 0x80 || (0xA0...0xFF).contains(scalar.value) {
                out.append(UInt8(scalar.value))
            } else if let byte = windows1252Extras[scalar.value] {
                out.append(byte)
            } else {
                out.append(0x3F)
            }
        }
        return out
    }

    /// Zeichen im Bereich 0x80–0x9F von Windows-1252.
    private static let windows1252Extras: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
        0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
        0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
        0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    private static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> String {
        "\(clampInt(x, 0, 9_999)),\(clampInt(y, 0, 9_999)),\(clampInt(w, 1, 9_999)),\(clampInt(h, 1, 9_999))"
    }
}

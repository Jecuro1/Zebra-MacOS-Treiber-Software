import Foundation

/// Bausteine für ZPL II (Zebra Programming Language).
///
/// Alle Funktionen erzeugen exakt die Syntax des „ZPL II Programming Guide“. Werte außerhalb
/// des gültigen Bereichs werden auf den zulässigen Bereich begrenzt, damit der Drucker den
/// Befehl nicht stillschweigend verwirft.
///
/// Felddaten werden grundsätzlich über `^FH` (Hex-Indikator `_`) maskiert, damit die
/// Steuerzeichen `^` und `~`, der Indikator `_`, der Rückstrich `\` sowie Steuerzeichen
/// unterhalb von `0x20` den Druckauftrag nicht beschädigen. Mit `^CI28` (siehe
/// ``changeEncoding(utf8:)``) werden Umlaute und alle anderen Unicode-Zeichen als UTF-8
/// übertragen.
public enum ZPL {

    // MARK: - Format

    /// Baut ein vollständiges Format `^XA … ^XZ`.
    ///
    /// Die Ausgabe ist zeilenweise gegliedert: Ein Feld (`^FO`/`^FT` … `^FS`) steht in einer
    /// Zeile, alle anderen Befehle jeweils in einer eigenen Zeile; jede Zeile endet mit `\n`.
    public static func format(@ZPLFormatBuilder _ content: () -> [ZPLCommand]) -> String {
        render([startFormat()] + content() + [endFormat()])
    }

    /// Sammelt Befehle mit dem Result Builder, ohne `^XA`/`^XZ` hinzuzufügen.
    public static func commands(@ZPLFormatBuilder _ content: () -> [ZPLCommand]) -> [ZPLCommand] {
        content()
    }

    /// Wandelt eine Befehlsfolge in Text um (Zeilenaufbau wie bei ``format(_:)``).
    ///
    /// Mit `characters` werden die Befehle mit anderen Steuerzeichen erzeugt (siehe
    /// ``ZPLCommand/rendered(with:)``).
    public static func render(_ commands: [ZPLCommand], characters: ControlCharacters = .standard) -> String {
        var out = ""
        var inField = false
        for command in commands {
            if command.opensField, inField {
                // Ein neues Feld ohne vorheriges ^FS – trotzdem lesbar umbrechen.
                out += "\n"
            }
            out += command.rendered(with: characters)
            if command.opensField {
                inField = true
            } else if command.closesField {
                inField = false
                out += "\n"
            } else if !inField {
                out += "\n"
            }
        }
        if inField { out += "\n" }
        return out
    }

    /// `^XA` – Formatbeginn.
    public static func startFormat() -> ZPLCommand { ZPLCommand(.caret, "XA") }

    /// `^XZ` – Formatende.
    public static func endFormat() -> ZPLCommand { ZPLCommand(.caret, "XZ") }

    /// `^CI28` (UTF-8) bzw. `^CI0` (Druckerstandard, 7-Bit USA).
    public static func changeEncoding(utf8: Bool = true) -> ZPLCommand {
        ZPLCommand(.caret, "CI", [utf8 ? "28" : "0"])
    }

    /// `^CI{n}` – beliebiger internationaler Zeichensatz (0…36, z. B. 27 = Windows-1252).
    public static func changeInternationalFont(_ value: Int) -> ZPLCommand {
        ZPLCommand(.caret, "CI", [String(clampInt(value, 0, 36))])
    }

    /// `^FX` – Kommentar. `^` und `~` würden den Kommentar beenden und werden entfernt,
    /// Zeilenumbrüche werden durch Leerzeichen ersetzt.
    public static func comment(_ text: String) -> ZPLCommand {
        var cleaned = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "^", "~": continue
            case "\r", "\n", "\t": cleaned.append(" ")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                cleaned.unicodeScalars.append(scalar)
            }
        }
        return ZPLCommand(.caret, "FX", [cleaned])
    }

    // MARK: - Felder

    /// `^FOx,y` – Feldursprung (linke obere Ecke).
    public static func fieldOrigin(x: Int, y: Int) -> ZPLCommand {
        ZPLCommand(.caret, "FO", [String(max(0, x)), String(max(0, y))])
    }

    /// `^FTx,y` – Feldursprung an der Grundlinie (Typeset).
    public static func fieldTypeset(x: Int, y: Int) -> ZPLCommand {
        ZPLCommand(.caret, "FT", [String(max(0, x)), String(max(0, y))])
    }

    /// Schriftauswahl.
    ///
    /// * Einzeichen-Namen (`0`, `A`…`Z`, `1`…`9`): `^A{name}{o},{h},{w}`, z. B. `^A0N,30,20`.
    /// * Längere Namen (z. B. `E:ARIAL.TTF`): `^A@{o},{h},{w},{name}`.
    ///
    /// Ohne `width` wird die Breite weggelassen (proportional zur Höhe).
    public static func font(_ name: String = "0", orientation: FieldOrientation = .normal,
                            height: Int, width: Int? = nil) -> ZPLCommand {
        let h = String(clampInt(height, 1, 32_000))
        let w = width.map { String(clampInt($0, 1, 32_000)) }
        if name.count == 1 {
            var params = [orientation.rawValue, h]
            if let w { params.append(w) }
            return ZPLCommand(.caret, "A" + name.uppercased(), params)
        }
        return ZPLCommand(.caret, "A@", [orientation.rawValue, h, w ?? "", name])
    }

    /// `^CF{name},{h},{w}` – Standardschrift für folgende Felder.
    public static func defaultFont(_ name: String = "0", height: Int, width: Int? = nil) -> ZPLCommand {
        var params = [name.uppercased(), String(clampInt(height, 1, 32_000))]
        if let width { params.append(String(clampInt(width, 1, 32_000))) }
        return ZPLCommand(.caret, "CF", params)
    }

    /// `^FW{o}` – Standardausrichtung aller folgenden Felder.
    public static func fieldOrientationDefault(_ orientation: FieldOrientation) -> ZPLCommand {
        ZPLCommand(.caret, "FW", [orientation.rawValue])
    }

    /// `^FBa,b,c,d,e` – Textblock mit Umbruch.
    ///
    /// - Parameters:
    ///   - width: Blockbreite in Punkten.
    ///   - maxLines: Höchstzahl Zeilen (1…9999).
    ///   - lineSpacing: Zusätzlicher Zeilenabstand in Punkten (−9999…9999).
    ///   - justification: `L`, `C`, `R` oder `J` (Blocksatz).
    ///   - hangingIndent: Hängender Einzug der Folgezeilen in Punkten.
    public static func fieldBlock(width: Int, maxLines: Int = 1, lineSpacing: Int = 0,
                                  justification: String = "L", hangingIndent: Int = 0) -> ZPLCommand {
        let j = justification.uppercased()
        let validJ = ["L", "C", "R", "J"].contains(j) ? j : "L"
        return ZPLCommand(.caret, "FB", [
            String(clampInt(width, 0, 32_000)),
            String(clampInt(maxLines, 1, 9_999)),
            String(clampInt(lineSpacing, -9_999, 9_999)),
            validJ,
            String(clampInt(hangingIndent, 0, 9_999)),
        ])
    }

    /// `^FH` + `^FD…` – Felddaten mit Hex-Maskierung (Indikator `_`).
    ///
    /// Maskiert werden `^` → `_5E`, `~` → `_7E`, `_` → `_5F`, `\` → `_5C` sowie alle
    /// Steuerzeichen unterhalb von `0x20` und `0x7F` (z. B. Zeilenumbruch → `_0A`).
    public static func fieldData(_ text: String) -> [ZPLCommand] {
        [fieldHexIndicator(), ZPLCommand(.caret, "FD", [escapeFieldData(text)])]
    }

    /// Wie ``fieldData(_:)``, wandelt aber Zeilenumbrüche (`\n`, `\r\n`) in den
    /// `^FB`-Zeilenumbruch `\&` um. Nur zusammen mit ``fieldBlock(width:maxLines:lineSpacing:justification:hangingIndent:)``
    /// verwenden.
    public static func blockFieldData(_ text: String) -> [ZPLCommand] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let escaped = lines.map { escapeFieldData(String($0)) }.joined(separator: "\\&")
        return [fieldHexIndicator(), ZPLCommand(.caret, "FD", [escaped])]
    }

    /// `^FH` – aktiviert die Hex-Maskierung der folgenden Felddaten (Indikator `_`).
    public static func fieldHexIndicator() -> ZPLCommand { ZPLCommand(.caret, "FH") }

    /// Maskiert Text für `^FD` nach `^FH` (Indikator `_`).
    public static func escapeFieldData(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "^": out += "_5E"
            case "~": out += "_7E"
            case "_": out += "_5F"
            case "\\": out += "_5C"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "_" + hexByte(UInt8(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// `^FS` – Feldende.
    public static func fieldSeparator() -> ZPLCommand { ZPLCommand(.caret, "FS") }

    /// `^FR` – Feld invertiert drucken (weiß auf schwarz über dunklen Flächen).
    public static func fieldReverse() -> ZPLCommand { ZPLCommand(.caret, "FR") }

    /// `^FN{n}` – Feldnummer für gespeicherte Formate (`^DF`/`^XF`).
    public static func fieldNumber(_ number: Int) -> ZPLCommand {
        ZPLCommand(.caret, "FN", [String(clampInt(number, 0, 9_999))])
    }

    /// Vollständiges Textfeld: `^FOx,y` `^A…` `^FH` `^FD…` `^FS`.
    public static func text(_ text: String, x: Int, y: Int, height: Int, width: Int? = nil,
                            font: String = "0", orientation: FieldOrientation = .normal) -> [ZPLCommand] {
        [fieldOrigin(x: x, y: y), self.font(font, orientation: orientation, height: height, width: width)]
            + fieldData(text) + [fieldSeparator()]
    }

    /// Textfeld in einem Block mit Ausrichtung (`^FO` `^A` `^FB` [`^FR`] `^FH` `^FD` `^FS`).
    public static func blockText(_ text: String, x: Int, y: Int, width: Int, height: Int,
                                 maxLines: Int = 1, justification: String = "L", reversed: Bool = false,
                                 font: String = "0") -> [ZPLCommand] {
        var commands = [
            fieldOrigin(x: x, y: y),
            self.font(font, height: height, width: height),
            fieldBlock(width: width, maxLines: maxLines, justification: justification),
        ]
        if reversed { commands.append(fieldReverse()) }
        commands += blockFieldData(text)
        commands.append(fieldSeparator())
        return commands
    }

    // MARK: - Grafik

    /// `^GBw,h,t,c,r` – Rahmen/Linie/gefülltes Rechteck (gefüllt, wenn `thickness` ≥ kürzere Seite / 2).
    public static func graphicBox(width: Int, height: Int, thickness: Int = 1, color: String = "B",
                                  rounding: Int = 0) -> ZPLCommand {
        let t = clampInt(thickness, 1, 32_000)
        return ZPLCommand(.caret, "GB", [
            String(clampInt(width, t, 32_000)),
            String(clampInt(height, t, 32_000)),
            String(t),
            lineColor(color),
            String(clampInt(rounding, 0, 8)),
        ])
    }

    /// `^GCd,t,c` – Kreis.
    public static func graphicCircle(diameter: Int, thickness: Int = 1, color: String = "B") -> ZPLCommand {
        ZPLCommand(.caret, "GC", [
            String(clampInt(diameter, 3, 4_095)), String(clampInt(thickness, 1, 4_095)), lineColor(color),
        ])
    }

    /// `^GEw,h,t,c` – Ellipse.
    public static func graphicEllipse(width: Int, height: Int, thickness: Int = 1, color: String = "B") -> ZPLCommand {
        ZPLCommand(.caret, "GE", [
            String(clampInt(width, 3, 4_095)), String(clampInt(height, 3, 4_095)),
            String(clampInt(thickness, 1, 4_095)), lineColor(color),
        ])
    }

    /// `^GDw,h,t,c,o` – Diagonale; `orientation` `R` (/) oder `L` (\).
    public static func graphicDiagonal(width: Int, height: Int, thickness: Int = 1, color: String = "B",
                                       orientation: String = "R") -> ZPLCommand {
        let o = orientation.uppercased() == "L" ? "L" : "R"
        return ZPLCommand(.caret, "GD", [
            String(clampInt(width, 3, 32_000)), String(clampInt(height, 3, 32_000)),
            String(clampInt(thickness, 1, 32_000)), lineColor(color), o,
        ])
    }

    /// `^XG{name},{mx},{my}` – gespeicherte Grafik abrufen (z. B. `R:LOGO.GRF`).
    public static func recallGraphic(_ name: String, magnificationX: Int = 1, magnificationY: Int = 1) -> ZPLCommand {
        ZPLCommand(.caret, "XG", [name, String(clampInt(magnificationX, 1, 10)), String(clampInt(magnificationY, 1, 10))])
    }

    /// `^IM{name}` – gespeicherte Grafik direkt (ohne Skalierung) platzieren.
    public static func imageMove(_ name: String) -> ZPLCommand { ZPLCommand(.caret, "IM", [name]) }

    // MARK: - Barcodes

    /// `^BYw,r,h` – Barcode-Standardwerte (Modulbreite 1…10, Verhältnis 2,0…3,0, Höhe).
    public static func barcodeDefaults(moduleWidth: Int, ratio: Double = 3.0, height: Int = 10) -> ZPLCommand {
        let r = min(max(ratio.isFinite ? ratio : 3.0, 2.0), 3.0)
        return ZPLCommand(.caret, "BY", [
            String(clampInt(moduleWidth, 1, 10)), String(format: "%.1f", r), String(clampInt(height, 1, 32_000)),
        ])
    }

    /// Betriebsart von Code 128 (`^BC`, Parameter `m`).
    public enum Code128Mode: String, Sendable, CaseIterable {
        /// Keine Betriebsart – Zeichensatzwechsel über Aufrufcodes (`>9`, `>:`, `>;`).
        case none = "N"
        /// UCC-Case-Mode (19 Ziffern + Prüfziffer).
        case ucc = "U"
        /// Automatische Wahl der Zeichensätze A/B/C (kompakteste Kodierung).
        case automatic = "A"
        /// UCC/EAN-Mode (GS1-128).
        case uccEAN = "D"
    }

    /// `^BCo,h,f,g,e` – Code 128, z. B. `^BCN,100,Y,N,N`.
    public static func code128(orientation: FieldOrientation = .normal, height: Int,
                               printInterpretation: Bool = true, above: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "BC", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above), "N",
        ])
    }

    /// `^BCo,h,f,g,e,m` – Code 128 mit UCC-Prüfziffer und Betriebsart.
    public static func code128(orientation: FieldOrientation = .normal, height: Int,
                               printInterpretation: Bool = true, above: Bool = false,
                               checkDigit: Bool = false, mode: Code128Mode) -> ZPLCommand {
        ZPLCommand(.caret, "BC", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
            yn(checkDigit), mode.rawValue,
        ])
    }

    /// `^B3o,e,h,f,g` – Code 39 (optional mit Mod-43-Prüfziffer).
    public static func code39(orientation: FieldOrientation = .normal, checkDigit: Bool = false, height: Int,
                              printInterpretation: Bool = true, above: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "B3", [
            orientation.rawValue, yn(checkDigit), String(clampInt(height, 1, 32_000)),
            yn(printInterpretation), yn(above),
        ])
    }

    /// `^BAo,h,f,g,e` – Code 93 (`e` = Prüfziffer drucken).
    public static func code93(orientation: FieldOrientation = .normal, height: Int,
                              printInterpretation: Bool = true, above: Bool = false,
                              printCheckDigit: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "BA", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
            yn(printCheckDigit),
        ])
    }

    /// `^BEo,h,f,g` – EAN-13.
    public static func ean13(orientation: FieldOrientation = .normal, height: Int,
                             printInterpretation: Bool = true, above: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "BE", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
        ])
    }

    /// `^B8o,h,f,g` – EAN-8.
    public static func ean8(orientation: FieldOrientation = .normal, height: Int,
                            printInterpretation: Bool = true, above: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "B8", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
        ])
    }

    /// `^BUo,h,f,g,e` – UPC-A (`e` = Prüfziffer drucken).
    public static func upcA(orientation: FieldOrientation = .normal, height: Int,
                            printInterpretation: Bool = true, above: Bool = false,
                            printCheckDigit: Bool = true) -> ZPLCommand {
        ZPLCommand(.caret, "BU", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
            yn(printCheckDigit),
        ])
    }

    /// `^B9o,h,f,g,e` – UPC-E (`e` = Prüfziffer drucken).
    public static func upcE(orientation: FieldOrientation = .normal, height: Int,
                            printInterpretation: Bool = true, above: Bool = false,
                            printCheckDigit: Bool = true) -> ZPLCommand {
        ZPLCommand(.caret, "B9", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
            yn(printCheckDigit),
        ])
    }

    /// `^B2o,h,f,g,e` – Interleaved 2 of 5 (`e` = Mod-10-Prüfziffer berechnen).
    public static func interleaved2of5(orientation: FieldOrientation = .normal, height: Int,
                                       printInterpretation: Bool = true, above: Bool = false,
                                       checkDigit: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "B2", [
            orientation.rawValue, String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
            yn(checkDigit),
        ])
    }

    /// `^BKo,e,h,f,g,k,l` – Codabar mit Start-/Stoppzeichen (A, B, C, D).
    public static func codabar(orientation: FieldOrientation = .normal, height: Int,
                               printInterpretation: Bool = true, above: Bool = false,
                               start: Character = "A", stop: Character = "A") -> ZPLCommand {
        func guardChar(_ c: Character) -> String {
            let s = String(c).uppercased()
            return ["A", "B", "C", "D"].contains(s) ? s : "A"
        }
        return ZPLCommand(.caret, "BK", [
            orientation.rawValue, "N", String(clampInt(height, 1, 32_000)), yn(printInterpretation), yn(above),
            guardChar(start), guardChar(stop),
        ])
    }

    /// `^BQN,2,m,e` – QR-Code (Modell 2), Vergrößerung 1…10, Fehlerkorrektur `L`/`M`/`Q`/`H`.
    ///
    /// Die Felddaten müssen mit Fehlerkorrektur und Eingabemodus beginnen – dafür
    /// ``qrFieldData(_:errorCorrection:)`` verwenden.
    public static func qrCode(magnification: Int, errorCorrection: String = "M") -> ZPLCommand {
        ZPLCommand(.caret, "BQ", ["N", "2", String(clampInt(magnification, 1, 10)), qrLevel(errorCorrection)])
    }

    /// `^FH` + `^FD{ec}A,{daten}` – Felddaten eines QR-Codes (automatischer Eingabemodus).
    public static func qrFieldData(_ text: String, errorCorrection: String = "M") -> [ZPLCommand] {
        [fieldHexIndicator(), ZPLCommand(.caret, "FD", [qrLevel(errorCorrection) + "A," + escapeFieldData(text)])]
    }

    /// `^BXo,h,200` – DataMatrix ECC 200 mit Modulgröße `moduleSize` Punkte.
    public static func dataMatrix(moduleSize: Int, orientation: FieldOrientation = .normal) -> ZPLCommand {
        ZPLCommand(.caret, "BX", [orientation.rawValue, String(clampInt(moduleSize, 1, 32_000)), "200"])
    }

    /// `^B7o,h,s,c,r,t` – PDF417.
    ///
    /// - Parameters:
    ///   - rowHeight: Zeilenhöhe in Punkten.
    ///   - securityLevel: Fehlerkorrekturstufe 0…8 (0 = automatisch).
    ///   - columns: Datenspalten 1…30 (`nil` = automatisch).
    ///   - rows: Zeilen 3…90 (`nil` = automatisch).
    ///   - truncated: Verkürztes PDF417.
    public static func pdf417(orientation: FieldOrientation = .normal, rowHeight: Int, securityLevel: Int = 0,
                              columns: Int? = nil, rows: Int? = nil, truncated: Bool = false) -> ZPLCommand {
        ZPLCommand(.caret, "B7", [
            orientation.rawValue, String(clampInt(rowHeight, 1, 32_000)), String(clampInt(securityLevel, 0, 8)),
            columns.map { String(clampInt($0, 1, 30)) } ?? "",
            rows.map { String(clampInt($0, 3, 90)) } ?? "",
            yn(truncated),
        ])
    }

    // MARK: - Etikett & Drucker-Setup

    /// `^PW{dots}` – Druckbreite.
    public static func printWidth(_ dots: Int) -> ZPLCommand { ZPLCommand(.caret, "PW", [String(clampInt(dots, 2, 32_000))]) }

    /// `^LL{dots}` – Etikettenlänge.
    public static func labelLength(_ dots: Int) -> ZPLCommand { ZPLCommand(.caret, "LL", [String(clampInt(dots, 1, 32_000))]) }

    /// `^LHx,y` – Etikettenursprung.
    public static func labelHome(x: Int, y: Int) -> ZPLCommand {
        ZPLCommand(.caret, "LH", [String(clampInt(x, 0, 32_000)), String(clampInt(y, 0, 32_000))])
    }

    /// `^LT{dots}` – vertikaler Versatz (−120…120).
    public static func labelTop(_ dots: Int) -> ZPLCommand { ZPLCommand(.caret, "LT", [String(clampInt(dots, -120, 120))]) }

    /// `^LS{dots}` – horizontaler Versatz (−9999…9999).
    public static func labelShift(_ dots: Int) -> ZPLCommand { ZPLCommand(.caret, "LS", [String(clampInt(dots, -9_999, 9_999))]) }

    /// `^LRY`/`^LRN` – ganzes Etikett invertieren.
    public static func labelReverse(_ on: Bool) -> ZPLCommand { ZPLCommand(.caret, "LR", [yn(on)]) }

    /// `^PQq` bzw. `^PQq,p,r,o` – Druckmenge.
    ///
    /// Sind alle optionalen Werte Standard, wird nur `^PQ{q}` erzeugt; sonst die vollständige
    /// Form, z. B. `^PQ10,2,0,Y` (Pause/Schnitt nach je 2 Etiketten, ohne Pause).
    public static func printQuantity(_ q: Int, pauseCount: Int = 0, replicates: Int = 0,
                                     overridePause: Bool = false) -> ZPLCommand {
        let quantity = String(clampInt(q, 1, 99_999_999))
        if pauseCount == 0, replicates == 0, !overridePause {
            return ZPLCommand(.caret, "PQ", [quantity])
        }
        return ZPLCommand(.caret, "PQ", [
            quantity, String(clampInt(pauseCount, 0, 99_999_999)), String(clampInt(replicates, 0, 99_999_999)),
            yn(overridePause),
        ])
    }

    /// `^PRs,s,s` – Druck-, Vorschub- und Rückzugsgeschwindigkeit in Zoll/s (1…14).
    public static func printRate(_ ips: Int) -> ZPLCommand {
        let s = String(clampInt(ips, 1, 14))
        return ZPLCommand(.caret, "PR", [s, s, s])
    }

    /// `^PRp,s,b` – getrennte Geschwindigkeiten für Druck, Vorschub und Rückzug.
    public static func printRate(print: Int, slew: Int, backfeed: Int) -> ZPLCommand {
        ZPLCommand(.caret, "PR", [String(clampInt(print, 1, 14)), String(clampInt(slew, 1, 14)), String(clampInt(backfeed, 1, 14))])
    }

    /// `~SD{dd}` – Schwärzung 0…30, zweistellig (z. B. `~SD08`).
    public static func setDarkness(_ value: Int) -> ZPLCommand {
        ZPLCommand(.tilde, "SD", [twoDigits(clampInt(value, 0, 30))])
    }

    /// `^MD{n}` – relative Schwärzung −30…30 zur gespeicherten Einstellung.
    public static func mediaDarkness(relative: Int) -> ZPLCommand {
        ZPLCommand(.caret, "MD", [String(clampInt(relative, -30, 30))])
    }

    /// `^MT{D|T}` – Thermodirekt oder Thermotransfer.
    public static func mediaType(_ t: MediaType) -> ZPLCommand { ZPLCommand(.caret, "MT", [t.zplCode]) }

    /// `^MN{Y|M|N|A|W}` – Medienerkennung.
    public static func mediaTracking(_ t: MediaTracking) -> ZPLCommand { ZPLCommand(.caret, "MN", [t.zplCode]) }

    /// `^MN{code}` bzw. bei schwarzer Markierung mit Versatz `^MNM,{offset}` (−80…283 Punkte).
    /// Ein Versatz bei anderen Erkennungsarten wird ignoriert.
    public static func mediaTracking(_ t: MediaTracking, markOffset: Int?) -> ZPLCommand {
        guard t == .blackMark, let markOffset else { return mediaTracking(t) }
        return ZPLCommand(.caret, "MN", [t.zplCode, String(clampInt(markOffset, -80, 283))])
    }

    /// `^MM{T|P|C|D|R|A|K}` – Druckmodus.
    ///
    /// Linerless-Modi haben keinen `^MM`-Code (``PrintMode/usesSGD``); für sie liefert diese
    /// Funktion den Code des gleichwertigen klassischen Modus. Richtig gesetzt werden sie mit
    /// ``SGD/setPrintMode(_:)`` – siehe ``printModeCommand(_:)``.
    public static func printMode(_ m: PrintMode) -> ZPLCommand { ZPLCommand(.caret, "MM", [m.zplCode]) }

    /// `^MM{code}` für klassische Modi, `nil` für Linerless-Modi (die per SGD
    /// `media.printmode` gesetzt werden, ``SGD/setPrintMode(_:)``).
    public static func printModeCommand(_ m: PrintMode) -> ZPLCommand? {
        m.mmCode.map { ZPLCommand(.caret, "MM", [$0]) }
    }

    /// `~JS{A|B|N|O}` – Rückzugsfolge („Change Backfeed Sequence“). Achtung: `^JS` ist die Sensorwahl.
    public static func backfeed(_ b: BackfeedMode) -> ZPLCommand { ZPLCommand(.tilde, "JS", [b.zplCode]) }

    /// `^POI` (180° gedreht) bzw. `^PON` (normal).
    public static func printOrientation(inverted: Bool) -> ZPLCommand {
        ZPLCommand(.caret, "PO", [inverted ? "I" : "N"])
    }

    /// `^PMY` / `^PMN` – Spiegeln.
    public static func mirror(_ on: Bool) -> ZPLCommand { ZPLCommand(.caret, "PM", [yn(on)]) }

    /// `~TA{±ddd}` – Abreißposition −120…120 (`printf("%03d")`, z. B. `~TA010`, `~TA-10`).
    public static func tearOffAdjust(_ dots: Int) -> ZPLCommand {
        ZPLCommand(.tilde, "TA", [String(format: "%03d", clampInt(dots, -120, 120))])
    }

    /// Aktion beim Einschalten bzw. Schließen des Druckkopfs (`^MF`).
    public enum FeedAction: String, Sendable, CaseIterable {
        /// Ein Etikett vorschieben.
        case feed = "F"
        /// Vollständig kalibrieren.
        case calibrate = "C"
        /// Etikettenlänge messen.
        case length = "L"
        /// Keine Bewegung.
        case noMotion = "N"
        /// Kurzkalibrierung.
        case shortCalibration = "S"
    }

    /// `^MF{p},{h}` – Medienvorschub beim Einschalten (`p`) und nach dem Schließen des Kopfs (`h`).
    public static func mediaFeed(powerUp: FeedAction, headClose: FeedAction) -> ZPLCommand {
        ZPLCommand(.caret, "MF", [powerUp.rawValue, headClose.rawValue])
    }

    /// `^MF{p},{h}` mit den Werten aus ``PrintSettings`` (``MediaFeedAction``). Eigene
    /// Parameternamen, damit `mediaFeed(powerUp: .calibrate, …)` mit ``FeedAction`` eindeutig bleibt.
    public static func mediaFeed(powerUpAction: MediaFeedAction, headCloseAction: MediaFeedAction) -> ZPLCommand {
        ZPLCommand(.caret, "MF", [powerUpAction.zplCode, headCloseAction.zplCode])
    }

    /// `^ST{MM},{DD},{YYYY},{HH},{mm},{SS},M` – Echtzeituhr stellen (24-Stunden-Format, alle
    /// Felder mit Nullen aufgefüllt), Ortszeit in `timeZone`. Muss in `^XA … ^XZ` stehen (siehe
    /// ``realTimeClockFormat(_:timeZone:)``).
    public static func setRealTimeClock(_ date: Date, timeZone: TimeZone = .current) -> ZPLCommand {
        let c = clockComponents(date, timeZone: timeZone)
        return ZPLCommand(.caret, "ST", [
            pad(c.month, 2), pad(c.day, 2), pad(c.year, 4), pad(c.hour, 2), pad(c.minute, 2), pad(c.second, 2), "M",
        ])
    }

    /// `^XA^ST…^XZ` – vollständiges Format zum Stellen der Uhr.
    public static func realTimeClockFormat(_ date: Date, timeZone: TimeZone = .current) -> String {
        startFormat().description + setRealTimeClock(date, timeZone: timeZone).description + endFormat().description
    }

    /// Datum und Uhrzeit (gregorianisch) in `timeZone` als Zahlen.
    public static func clockComponents(_ date: Date, timeZone: TimeZone)
        -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Ganzzahl wie `printf("%0*d")` (Breite inklusive Vorzeichen).
    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : ""
        return sign + String(repeating: "0", count: max(0, width - sign.count - digits.count)) + digits
    }

    /// `^JUS` – aktuelle Einstellungen dauerhaft speichern.
    public static func saveSettings() -> ZPLCommand { ZPLCommand(.caret, "JU", ["S"]) }

    /// `^JUF` – Werkseinstellungen laden (dauerhaft erst nach ``saveSettings()``).
    public static func restoreFactoryDefaults() -> ZPLCommand { ZPLCommand(.caret, "JU", ["F"]) }

    /// `^JUN` – Netzwerk-Werkseinstellungen laden.
    public static func restoreNetworkDefaults() -> ZPLCommand { ZPLCommand(.caret, "JU", ["N"]) }

    /// `^JUR` – zuletzt gespeicherte Einstellungen wiederherstellen.
    public static func recallSavedSettings() -> ZPLCommand { ZPLCommand(.caret, "JU", ["R"]) }

    // MARK: - Gerätebefehle

    /// `~JC` – Medien- und Farbbandsensor kalibrieren.
    public static func calibrate() -> ZPLCommand { ZPLCommand(.tilde, "JC") }

    /// `~JL` – Etikettenlänge neu messen.
    public static func measureLabelLength() -> ZPLCommand { ZPLCommand(.tilde, "JL") }

    /// `~JG` – kalibrieren und Sensorprofil drucken.
    public static func sensorProfile() -> ZPLCommand { ZPLCommand(.tilde, "JG") }

    /// `~HS` – Host-Status (drei Zeilen).
    public static func hostStatus() -> ZPLCommand { ZPLCommand(.tilde, "HS") }

    /// `~HI` – Host-Identifikation (Modell, Firmware, dpmm, Speicher).
    public static func hostIdentification() -> ZPLCommand { ZPLCommand(.tilde, "HI") }

    /// `~HQES` – erweiterter Fehler-/Warnungsstatus.
    public static func hostQueryErrors() -> ZPLCommand { ZPLCommand(.tilde, "HQ", ["ES"]) }

    /// `~HM` – Speicherstatus (RAM).
    public static func hostMemoryStatus() -> ZPLCommand { ZPLCommand(.tilde, "HM") }

    /// `^HH` – Konfiguration an den Host senden. Muss in `^XA … ^XZ` stehen
    /// (siehe ``hostConfigurationFormat()``).
    public static func hostConfiguration() -> ZPLCommand { ZPLCommand(.caret, "HH") }

    /// `^XA^HH^XZ` – vollständige Abfrage der Konfiguration.
    public static func hostConfigurationFormat() -> String { "^XA^HH^XZ" }

    /// `~WC` – Konfigurationsetikett drucken.
    public static func printConfiguration() -> ZPLCommand { ZPLCommand(.tilde, "WC") }

    /// `~WL` – Netzwerkkonfigurationsetikett drucken.
    public static func printNetworkConfiguration() -> ZPLCommand { ZPLCommand(.tilde, "WL") }

    /// `~PH` – ein (leeres) Etikett vorschieben.
    public static func feed() -> ZPLCommand { ZPLCommand(.tilde, "PH") }

    /// `~PP` – Druck anhalten.
    public static func pause() -> ZPLCommand { ZPLCommand(.tilde, "PP") }

    /// `~PS` – Druck fortsetzen.
    public static func resume() -> ZPLCommand { ZPLCommand(.tilde, "PS") }

    /// `~JA` – alle Aufträge abbrechen: verwirft alle Formate im Empfangspuffer und bricht
    /// laufende Stapel ab; das Etikett, das gerade gedruckt wird, wird noch fertiggestellt.
    /// Das ist der Befehl, um einen laufenden Druck zu stoppen.
    public static func cancelAll() -> ZPLCommand { ZPLCommand(.tilde, "JA") }

    /// `~JX` – teilweise empfangenes Format verwerfen („Cancel Current Partially Input Format“):
    /// bricht nur ein Format ab, das gerade noch zum Drucker übertragen wird. Formate, die bereits
    /// gedruckt werden, und später gesendete Formate bleiben unberührt – einen laufenden Druck
    /// stoppt ``cancelAll()``.
    public static func cancelCurrent() -> ZPLCommand { ZPLCommand(.tilde, "JX") }

    /// `~JR` – Neustart (Power-On-Reset).
    public static func reset() -> ZPLCommand { ZPLCommand(.tilde, "JR") }

    // MARK: - Dateien

    /// `~DY{drive}{NAME},B,T,{len},,<binär>` – TrueType-Schrift herunterladen.
    ///
    /// Der Name wird in Großbuchstaben umgewandelt, eine Endung (`.TTF`) entfernt, ungültige
    /// Zeichen werden durch `_` ersetzt und die Länge auf 16 Zeichen begrenzt.
    public static func downloadTrueTypeFont(name: String, drive: String = "E:", data: Data) -> Data {
        let header = "~DY\(normalizedDrive(drive))\(objectName(name)),B,T,\(data.count),,"
        var out = Data(header.utf8)
        out.append(data)
        return out
    }

    /// `^ID{pfad}` – Objekt löschen, z. B. `^IDE:LOGO.GRF` (Platzhalter `*` erlaubt).
    public static func deleteObject(_ path: String) -> ZPLCommand { ZPLCommand(.caret, "ID", [path]) }

    /// `^XA^HW{muster}^XZ` – Dateiliste an den Host senden.
    public static func hostDirectory(_ pattern: String = "E:*.*") -> String { "^XA^HW\(pattern)^XZ" }

    /// `^XA^WD{muster}^XZ` – Dateiliste drucken.
    public static func printDirectory(_ pattern: String = "E:*.*") -> String { "^XA^WD\(pattern)^XZ" }

    /// `^DF{name}` – Format speichern (z. B. `E:VORLAGE.ZPL`).
    public static func downloadFormat(_ name: String) -> ZPLCommand { ZPLCommand(.caret, "DF", [name]) }

    /// `^XF{name}` – gespeichertes Format abrufen.
    public static func recallFormat(_ name: String) -> ZPLCommand { ZPLCommand(.caret, "XF", [name]) }

    // MARK: - Hilfsfunktionen

    /// Laufwerk normalisieren: `e` / `E` / `e:` → `E:`.
    static func normalizedDrive(_ drive: String) -> String {
        var d = drive.trimmingCharacters(in: .whitespaces).uppercased()
        if d.hasSuffix(":") { d.removeLast() }
        let letter = d.first.map(String.init) ?? "E"
        return letter + ":"
    }

    /// Objektname für Druckerdateien: Großbuchstaben, ohne Endung, nur `A–Z 0–9 _ -`, max. 16 Zeichen.
    static func objectName(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = base.firstIndex(of: ":") { base = String(base[base.index(after: colon)...]) }
        if let dot = base.lastIndex(of: "."), dot != base.startIndex { base = String(base[..<dot]) }
        var out = ""
        for scalar in base.uppercased().unicodeScalars {
            if (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("_")
            }
        }
        if out.isEmpty { out = "FONT" }
        return String(out.prefix(16))
    }

    static func yn(_ value: Bool) -> String { value ? "Y" : "N" }

    static func lineColor(_ color: String) -> String { color.uppercased() == "W" ? "W" : "B" }

    static func qrLevel(_ level: String) -> String {
        let l = level.uppercased()
        return ["L", "M", "Q", "H"].contains(l) ? l : "M"
    }

    static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }

    static func hexByte(_ byte: UInt8) -> String {
        let digits: [Character] = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}

/// Begrenzt `value` auf `low…high`.
@inline(__always)
func clampInt(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }

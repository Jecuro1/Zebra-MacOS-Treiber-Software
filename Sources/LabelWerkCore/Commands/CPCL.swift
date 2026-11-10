import Foundation

/// Bausteine für CPCL (Comtec Printer Control Language) der mobilen Zebra-Drucker
/// (QLn, ZQ, iMZ …).
///
/// Jede Funktion liefert eine Befehlszeile **ohne** Zeilenende (Ausnahme: ``qrCode(_:x:y:model:unitSize:errorCorrection:vertical:)``
/// liefert mehrere, intern mit `\r\n` getrennte Zeilen). ``render(_:)`` und
/// ``label(height:resolution:quantity:offset:form:_:)`` schließen jede Zeile mit `\r\n` ab.
public enum CPCL {
    /// Zeilenende von CPCL.
    public static let lineEnding = "\r\n"

    // MARK: - Etikett

    /// Schließt jede Zeile mit `\r\n` ab.
    public static func render(_ lines: [String]) -> String {
        lines.map { $0 + lineEnding }.joined()
    }

    /// Vollständiges Etikett: Kopfzeile, Inhalt, `FORM` (optional) und `PRINT`.
    public static func label(height: Int, resolution: Resolution = .dpi203, quantity: Int = 1, offset: Int = 0,
                             form: Bool = true, @CommandLineBuilder _ content: () -> [String]) -> String {
        var lines = [header(offset: offset, resolution: resolution, height: height, quantity: quantity)]
        lines += content()
        if form { lines.append(self.form()) }
        lines.append(print())
        return render(lines)
    }

    /// Wert der Auflösungsfelder in der Kopfzeile: `200` bei 203 dpi, sonst dpi.
    public static func resolutionValue(_ resolution: Resolution) -> Int {
        resolution == .dpi203 ? 200 : resolution.dpi
    }

    /// `! {versatz} {hres} {vres} {höhe} {menge}` – Kopfzeile, z. B. `! 0 200 200 406 1`.
    public static func header(offset: Int = 0, resolution: Resolution = .dpi203, height: Int, quantity: Int = 1) -> String {
        let r = resolutionValue(resolution)
        return "! \(clampInt(offset, 0, 65_535)) \(r) \(r) \(clampInt(height, 1, 65_535)) \(clampInt(quantity, 1, 1_024))"
    }

    /// `PAGE-WIDTH {punkte}`.
    public static func pageWidth(_ dots: Int) -> String { "PAGE-WIDTH \(clampInt(dots, 1, 65_535))" }

    /// `CONTRAST {0…3}` (0 = normal, 3 = sehr dunkel).
    public static func contrast(_ level: Int) -> String { "CONTRAST \(clampInt(level, 0, 3))" }

    /// `SPEED {0…5}`.
    public static func speed(_ level: Int) -> String { "SPEED \(clampInt(level, 0, 5))" }

    /// `TONE {−99…200}` – feine Schwärzungsregelung (Alternative zu `CONTRAST`).
    public static func tone(_ value: Int) -> String { "TONE \(clampInt(value, -99, 200))" }

    /// `FORM` – nach dem Druck zum nächsten Etikettenanfang vorschieben.
    public static func form() -> String { "FORM" }

    /// `PRINT` – Etikett drucken (beendet das Etikett).
    public static func print() -> String { "PRINT" }

    /// `JOURNAL` – Etikettenerkennung aus (Endlosmaterial/Belege).
    public static func journal() -> String { "JOURNAL" }

    /// `PREFEED {punkte}` – Vorschub vor dem Druck.
    public static func prefeed(_ dots: Int) -> String { "PREFEED \(clampInt(dots, 0, 65_535))" }

    /// `POSTFEED {punkte}` – Vorschub nach dem Druck.
    public static func postfeed(_ dots: Int) -> String { "POSTFEED \(clampInt(dots, 0, 65_535))" }

    /// `COUNTRY {name}` – Zeichensatz, z. B. `GERMANY`, `USA`, `FRANCE`, `CP850`.
    public static func country(_ name: String) -> String { "COUNTRY \(LegacyText.singleLine(name).uppercased())" }

    // MARK: - Text

    /// Drehung von Text (`TEXT`, `TEXT90`, `TEXT180`, `TEXT270`).
    public enum Rotation: String, Sendable, CaseIterable {
        case normal = "TEXT"
        case rotated90 = "TEXT90"
        case rotated180 = "TEXT180"
        case rotated270 = "TEXT270"
    }

    /// `TEXT {schrift} {größe} {x} {y} {daten}` – Text (Zeilenumbrüche werden zu Leerzeichen).
    public static func text(_ text: String, font: String = "7", size: Int = 0, x: Int, y: Int,
                            rotation: Rotation = .normal) -> String {
        "\(rotation.rawValue) \(font) \(clampInt(size, 0, 99)) \(clampInt(x, 0, 65_535)) \(clampInt(y, 0, 65_535)) \(LegacyText.singleLine(text))"
    }

    /// `SETMAG {b} {h}` – Vergrößerung residenter Schriften (1…16, `0 0` = zurücksetzen).
    public static func setMagnification(width: Int, height: Int) -> String {
        "SETMAG \(clampInt(width, 0, 16)) \(clampInt(height, 0, 16))"
    }

    /// `SETBOLD {0…5}` – Fettdruck.
    public static func setBold(_ value: Int) -> String { "SETBOLD \(clampInt(value, 0, 5))" }

    /// `SETSP {punkte}` – Zeichenabstand.
    public static func setSpacing(_ dots: Int) -> String { "SETSP \(clampInt(dots, 0, 999))" }

    /// `CENTER [bereich]` – folgende Felder zentrieren.
    public static func center(_ range: Int? = nil) -> String { justification("CENTER", range) }

    /// `LEFT [bereich]` – folgende Felder linksbündig.
    public static func left(_ range: Int? = nil) -> String { justification("LEFT", range) }

    /// `RIGHT [bereich]` – folgende Felder rechtsbündig.
    public static func right(_ range: Int? = nil) -> String { justification("RIGHT", range) }

    // MARK: - Barcodes

    /// Lineare Barcode-Typen.
    public enum BarcodeType: String, Sendable, CaseIterable {
        case code128 = "128"
        case ucc128 = "UCCEAN128"
        case code39 = "39"
        case code39CheckDigit = "39C"
        case fullASCIICode39 = "F39"
        case code93 = "93"
        case ean13 = "EAN13"
        case ean8 = "EAN8"
        case upcA = "UPCA"
        case upcE = "UPCE"
        case interleaved2of5 = "I2OF5"
        case interleaved2of5CheckDigit = "I2OF5C"
        case codabar = "CODABAR"
        case msi = "MSI"
        case postnet = "POSTNET"
    }

    /// `BARCODE {typ} {schmal} {verhältnis} {höhe} {x} {y} {daten}` (`VBARCODE` bei `vertical`).
    ///
    /// - Parameters:
    ///   - narrowBar: Breite des schmalen Elements in Punkten.
    ///   - ratio: Verhältniscode (0 = 1,5:1, 1 = 2,0:1, 2 = 2,5:1, 3 = 3,0:1, 4 = 3,5:1, 20…30 = 2,0…3,0:1).
    public static func barcode(_ data: String, type: BarcodeType, x: Int, y: Int, height: Int,
                               narrowBar: Int = 1, ratio: Int = 1, vertical: Bool = false) -> String {
        "\(vertical ? "VBARCODE" : "BARCODE") \(type.rawValue) \(clampInt(narrowBar, 1, 32)) \(clampInt(ratio, 0, 30)) "
            + "\(clampInt(height, 1, 65_535)) \(clampInt(x, 0, 65_535)) \(clampInt(y, 0, 65_535)) \(LegacyText.singleLine(data))"
    }

    /// `BARCODE-TEXT {schrift} {größe} {abstand}` – Klarschrift unter folgenden Barcodes.
    public static func barcodeText(font: String = "7", size: Int = 0, offset: Int = 5) -> String {
        "BARCODE-TEXT \(font) \(clampInt(size, 0, 99)) \(clampInt(offset, 0, 999))"
    }

    /// `BARCODE-TEXT OFF` – Klarschrift aus.
    public static func barcodeTextOff() -> String { "BARCODE-TEXT OFF" }

    /// QR-Code (drei Zeilen): `BARCODE QR {x} {y} M {modell} U {einheit}`, `{ec}A,{daten}`, `ENDQR`.
    ///
    /// - Parameters:
    ///   - unitSize: Modulgröße in Punkten (1…32).
    ///   - errorCorrection: `L`, `M`, `Q` oder `H`.
    public static func qrCode(_ data: String, x: Int, y: Int, model: Int = 2, unitSize: Int = 6,
                              errorCorrection: String = "M", vertical: Bool = false) -> String {
        let head = "\(vertical ? "VBARCODE" : "BARCODE") QR \(clampInt(x, 0, 65_535)) \(clampInt(y, 0, 65_535)) "
            + "M \(model == 1 ? 1 : 2) U \(clampInt(unitSize, 1, 32))"
        let body = ZPL.qrLevel(errorCorrection) + "A," + LegacyText.singleLine(data)
        return [head, body, "ENDQR"].joined(separator: lineEnding)
    }

    // MARK: - Grafik

    /// `BOX {x0} {y0} {x1} {y1} {stärke}` – Rahmen.
    public static func box(x0: Int, y0: Int, x1: Int, y1: Int, thickness: Int = 1) -> String {
        "BOX " + coordinates(x0, y0, x1, y1, thickness)
    }

    /// `LINE {x0} {y0} {x1} {y1} {stärke}` – Linie.
    public static func line(x0: Int, y0: Int, x1: Int, y1: Int, thickness: Int = 1) -> String {
        "LINE " + coordinates(x0, y0, x1, y1, thickness)
    }

    /// `INVERSE-LINE {x0} {y0} {x1} {y1} {stärke}` – invertiert zuvor gezeichnete Inhalte im Bereich.
    public static func inverseLine(x0: Int, y0: Int, x1: Int, y1: Int, thickness: Int = 1) -> String {
        "INVERSE-LINE " + coordinates(x0, y0, x1, y1, thickness)
    }

    // MARK: - Dienstprogramme

    /// `! UTILITIES` … `PRINT` – Block für dauerhafte Einstellungen (z. B. Sensormodus).
    public static func utilities(@CommandLineBuilder _ content: () -> [String]) -> String {
        render(["! UTILITIES"] + content() + [print()])
    }

    /// `GAP-SENSE` – Lückensensor verwenden (innerhalb von ``utilities(_:)``).
    public static func gapSense() -> String { "GAP-SENSE" }

    /// `BAR-SENSE` – Markensensor verwenden (innerhalb von ``utilities(_:)``).
    public static func barSense() -> String { "BAR-SENSE" }

    /// Entfernt Zeilenumbrüche und Steuerzeichen aus Text.
    public static func sanitized(_ text: String) -> String { LegacyText.singleLine(text) }

    /// Bildet Text auf ASCII ab (ä → ae, × → x …).
    public static func transliterated(_ text: String) -> String { LegacyText.asciiTransliterated(text) }

    // MARK: - Intern

    private static func justification(_ keyword: String, _ range: Int?) -> String {
        guard let range else { return keyword }
        return "\(keyword) \(clampInt(range, 0, 65_535))"
    }

    private static func coordinates(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ t: Int) -> String {
        "\(clampInt(x0, 0, 65_535)) \(clampInt(y0, 0, 65_535)) \(clampInt(x1, 0, 65_535)) \(clampInt(y1, 0, 65_535)) \(clampInt(t, 1, 65_535))"
    }
}

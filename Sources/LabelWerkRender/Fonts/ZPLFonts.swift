import Foundation

/// Darstellungsart einer ZPL-Schrift in der Vorschau.
enum ZPLFontStyle: Hashable, Sendable {
    /// Schrift 0 (CG Triumvirate Bold Condensed) – proportional, skalierbar.
    case scalableBold
    /// Sonstige skalierbare Schriften (`^A@`-Dateien, P–V, per `^CW` zugeordnete oder nicht
    /// residente Schriften) – proportional, angenähert durch DejaVu Sans.
    case scalable
    /// Residente Bitmap-Schriften A–H: feste Zellen, ganzzahlige Vergrößerung.
    case bitmap(ZPLBitmapFontCell)
    /// Symbolschrift GS (`^GS`): A = ®, B = ©, C = ™, D = UL-Zeichen, E = CSA-Zeichen.
    case symbol
}

/// Zellmaße einer residenten Bitmap-Schrift in Punkten (Vergrößerung 1).
struct ZPLBitmapFontCell: Hashable, Sendable {
    /// Zeichenmatrix Höhe × Breite.
    let height: Int
    let width: Int
    /// Zeichenzwischenraum.
    let gap: Int
    /// Abstand der Grundlinie von der Zelloberkante.
    let baseline: Int
    /// Nur Großbuchstaben (Schriften B und H); Kleinbuchstaben werden groß gedruckt.
    let uppercaseOnly: Bool
}

/// Schrifttabelle der residenten ZPL-Schriften und Größenauflösung von `^A`/`^CF`.
///
/// Quelle der Zellmaße: ZPL II Programming Guide, „Font Matrices“ (6/8 Punkte/mm). Für 12 und
/// 24 Punkte/mm haben nur E (OCR-B) und H (OCR-A) eigene Matrizen; deren Zwischenräume sind so
/// gewählt, dass der Normabstand von 2,54 mm (10 Zeichen/Zoll) entsteht.
enum ZPLFonts {

    /// Zelle einer residenten Bitmap-Schrift (`"A"`…`"H"`), sonst `nil`.
    static func bitmapCell(_ fontName: String, dotsPerMM: Int) -> ZPLBitmapFontCell? {
        guard fontName.count == 1, let name = fontName.first else { return nil }
        let high = dotsPerMM >= 12
        switch name {
        case "A": return ZPLBitmapFontCell(height: 9, width: 5, gap: 1, baseline: 7, uppercaseOnly: false)
        case "B": return ZPLBitmapFontCell(height: 11, width: 7, gap: 2, baseline: 11, uppercaseOnly: true)
        case "C", "D": return ZPLBitmapFontCell(height: 18, width: 10, gap: 2, baseline: 14, uppercaseOnly: false)
        case "E":
            return high
                ? ZPLBitmapFontCell(height: 42, width: 20, gap: 10, baseline: 32, uppercaseOnly: false)
                : ZPLBitmapFontCell(height: 28, width: 15, gap: 5, baseline: 23, uppercaseOnly: false)
        case "F": return ZPLBitmapFontCell(height: 26, width: 13, gap: 3, baseline: 21, uppercaseOnly: false)
        case "G": return ZPLBitmapFontCell(height: 60, width: 40, gap: 8, baseline: 48, uppercaseOnly: false)
        case "H":
            return high
                ? ZPLBitmapFontCell(height: 34, width: 22, gap: 8, baseline: 34, uppercaseOnly: true)
                : ZPLBitmapFontCell(height: 21, width: 13, gap: 6, baseline: 21, uppercaseOnly: true)
        default: return nil
        }
    }

    /// Standardgröße (Höhe × Breite) skalierbarer residenter Schriften ohne Größenangabe.
    static func scalableDefaultSize(_ fontName: String) -> (height: Int, width: Int)? {
        switch fontName {
        case "0": return (15, 12)
        case "P": return (20, 18)
        case "Q": return (28, 24)
        case "R": return (35, 31)
        case "S": return (40, 35)
        case "T": return (48, 42)
        case "U": return (59, 53)
        case "V": return (80, 71)
        case "GS": return (24, 24)
        default: return nil
        }
    }

    /// Ist der Schriftbezeichner ein residenter Font (0, A–H, P–V)?
    static func isResident(_ fontName: String) -> Bool {
        fontName == "0" || bitmapCell(fontName, dotsPerMM: 8) != nil || scalableDefaultSize(fontName) != nil
    }

    /// Darstellungsart eines Schriftbezeichners.
    static func style(of fontName: String, dotsPerMM: Int) -> ZPLFontStyle {
        if fontName == "0" { return .scalableBold }
        if fontName == "GS" { return .symbol }
        if let cell = bitmapCell(fontName, dotsPerMM: dotsPerMM) { return .bitmap(cell) }
        return .scalable
    }

    /// Löst Höhe/Breite einer Schriftanforderung auf (Punkte).
    ///
    /// * Bitmap-Schriften: Vergrößerung = angeforderte Größe ÷ Zellgröße, abgerundet, 1…10.
    ///   Fehlt eine der beiden Angaben, wird proportional vergrößert.
    /// * Skalierbare Schriften: 10…32 000 Punkte; fehlt die Breite, ist sie gleich der Höhe
    ///   (und umgekehrt). Ohne beide Angaben gilt die Standardgröße der Schrift.
    static func resolveSize(fontName: String, height: Int?, width: Int?, dotsPerMM: Int) -> (height: Int, width: Int) {
        let requestedHeight = height.flatMap { $0 > 0 ? $0 : nil }
        let requestedWidth = width.flatMap { $0 > 0 ? $0 : nil }
        if let cell = bitmapCell(fontName, dotsPerMM: dotsPerMM) {
            let heightMag = requestedHeight.map { min(10, max(1, $0 / cell.height)) }
            let widthMag = requestedWidth.map { min(10, max(1, $0 / cell.width)) }
            let h = heightMag ?? widthMag ?? 1
            let w = widthMag ?? heightMag ?? 1
            return (cell.height * h, cell.width * w)
        }
        let clamp: (Int) -> Int = { min(32_000, max(10, $0)) }
        switch (requestedHeight, requestedWidth) {
        case let (h?, w?): return (clamp(h), clamp(w))
        case let (h?, nil): return (clamp(h), clamp(h))
        case let (nil, w?): return (clamp(w), clamp(w))
        case (nil, nil):
            let size = scalableDefaultSize(fontName) ?? (15, 12)
            return size
        }
    }
}

/// Eine für Messung und Rasterung aufgelöste Schrift (Stil, Zielgröße, Skalierung der Mastervorlage).
struct TextFont: Sendable {
    let style: ZPLFontStyle
    let master: BitmapFont
    /// Zellhöhe bzw. Schrifthöhe in Punkten.
    let height: Int
    /// Zeichenbreite in Punkten (bei Bitmap-Schriften die Matrixbreite).
    let width: Int
    /// Abstand der Grundlinie von der Oberkante einer Zeile.
    let baseline: Int
    /// Skalierung Masterpixel → Punkte.
    let scaleX: Double
    let scaleY: Double
    /// Fester Zeichenvorschub (Bitmap- und Symbolschriften), sonst `nil` (proportional).
    let fixedAdvance: Double?
    let uppercaseOnly: Bool

    /// Horizontale Stauchung von DejaVu Sans Bold, um die Laufweite von CG Triumvirate Bold
    /// Condensed (Schrift 0) bei `w == h` zu treffen.
    static let condensedFactor = 0.72
    /// Stauchung von DejaVu Sans als Ersatz für typische TrueType-Schriften (Arial/Swiss 721).
    static let regularFactor = 0.88
    /// Grundlinie skalierbarer Schriften: 3/4 der Höhe (Zebra-Schrifttabelle, „3 × HEIGHT / 4“).
    static let scalableBaselineRatio = 0.75

    init(fontName: String, height: Int, width: Int, dotsPerMM: Int) {
        let h = max(1, height), w = max(1, width)
        let style = ZPLFonts.style(of: fontName, dotsPerMM: dotsPerMM)
        self.style = style
        self.height = h
        self.width = w
        switch style {
        case .bitmap(let cell):
            let master = BitmapFont.mono
            let heightMag = max(1, Int((Double(h) / Double(cell.height)).rounded()))
            let widthMag = max(1, Int((Double(w) / Double(cell.width)).rounded()))
            let monoAdvance = master.glyph(" ")?.advance ?? Double(master.emSize) * 0.602
            self.master = master
            self.baseline = cell.baseline * heightMag
            self.scaleY = Double(cell.baseline * heightMag) / Double(max(1, master.capHeight))
            self.scaleX = Double(cell.width * widthMag) / monoAdvance
            self.fixedAdvance = Double((cell.width + cell.gap) * widthMag)
            self.uppercaseOnly = cell.uppercaseOnly
        case .scalableBold, .scalable:
            let master = style == .scalableBold ? BitmapFont.sansBold : BitmapFont.sans
            let factor = style == .scalableBold ? Self.condensedFactor : Self.regularFactor
            self.master = master
            self.baseline = Int((Double(h) * Self.scalableBaselineRatio).rounded())
            self.scaleY = Double(h) / Double(master.emSize)
            self.scaleX = Double(w) / Double(master.emSize) * factor
            self.fixedAdvance = nil
            self.uppercaseOnly = false
        case .symbol:
            let master = BitmapFont.sans
            self.master = master
            self.baseline = Int((Double(h) * Self.scalableBaselineRatio).rounded())
            self.scaleY = Double(h) / Double(master.emSize)
            self.scaleX = Double(w) / Double(master.emSize)
            self.fixedAdvance = Double(w)
            self.uppercaseOnly = true
        }
    }

    /// Text so, wie die Schrift ihn druckt (Großbuchstabenschriften wandeln um).
    func printable(_ text: String) -> String {
        uppercaseOnly ? text.uppercased() : text
    }

    /// Vorschub eines Zeichens in Punkten.
    func advance(_ character: Character) -> Double {
        if let fixed = fixedAdvance { return fixed }
        return master.resolve(character).advance * scaleX
    }
}

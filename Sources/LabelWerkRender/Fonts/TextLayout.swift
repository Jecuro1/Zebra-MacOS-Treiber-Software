import Foundation

/// Satz eines Textfelds in **ungedrehten Feldkoordinaten** (Ursprung links oben im Feld).
///
/// Regeln:
/// * Ohne `^FB`: eine Zeile, Breite = Summe der Vorschübe (+ `^FP`-Zeichenabstand), Höhe = Schrifthöhe.
/// * Mit `^FB`: Umbruch an Leerzeichen; Wörter, die allein breiter als die Zeile sind, werden
///   zeichenweise umbrochen. `\&` erzwingt einen Zeilenumbruch, `\\` ergibt einen Backslash.
///   Der hängende Einzug gilt für alle Zeilen nach der ersten. Zeilenabstand =
///   Schrifthöhe + `lineSpacing`. Bei Blocksatz (`J`) werden die Wortabstände aller Zeilen außer
///   der letzten eines Absatzes gedehnt. Zeilen über `maxLines` hinaus überdrucken bei `^FB` die
///   letzte Zeile (Firmwareverhalten) bzw. entfallen bei `^TB`.
///   Feldgröße = `width × (maxLines × Höhe + (maxLines − 1) × lineSpacing)`.
/// * `^FP V`: Zeichen untereinander, `^FP R`: von rechts nach links.
struct TextLayout {

    /// Ein zu zeichnendes Zeichen: Stiftposition (links) auf der Grundlinie.
    struct PlacedCharacter {
        let character: Character
        let x: Double
        let baseline: Double
    }

    let font: TextFont
    /// Feldgröße (ungedreht) in Punkten.
    let width: Int
    let height: Int
    let characters: [PlacedCharacter]
    /// Grundlinie der letzten gedruckten Zeile (für `^FT`).
    let lastBaseline: Int
    /// Ende der letzten Zeile auf der Grundlinie (für `^FT` ohne Koordinaten).
    let endX: Double
    /// Anzahl der Zeilen, die nicht in `maxLines` passten.
    let overflowLines: Int
    /// Anzahl der gesetzten Zeilen (vor Begrenzung).
    let lineCount: Int

    /// Feldgröße eines Textelements (für `LabelElement.boundingBox`).
    static func fieldSize(of element: TextElement, dotsPerMM: Int = 8) -> (Int, Int) {
        let layout = TextLayout(element: element, dotsPerMM: dotsPerMM)
        return (layout.width, layout.height)
    }

    init(element: TextElement, dotsPerMM: Int) {
        let font = TextFont(fontName: element.fontName, height: element.height, width: element.width,
                            dotsPerMM: dotsPerMM)
        self.init(text: element.text, font: font, block: element.block, direction: element.direction,
                  characterGap: element.characterGap)
    }

    init(text rawText: String, font: TextFont, block: FieldBlock?, direction: TextDirection, characterGap: Int) {
        self.font = font
        let gap = Double(characterGap)
        let text = font.printable(rawText)

        if let block {
            let pitch = font.height + block.lineSpacing
            let maxLines = max(1, block.maxLines)
            let blockWidth = Double(max(0, block.width))
            let indent = Double(max(0, block.hangingIndent))
            var lines: [Line] = []
            for paragraph in Self.paragraphs(text) {
                Self.wrap(paragraph, font: font, gap: gap, lines: &lines) { lineIndex in
                    lineIndex == 0 ? blockWidth : blockWidth - indent
                }
            }
            var placed: [PlacedCharacter] = []
            var endX = 0.0
            for (index, line) in lines.enumerated() {
                let row: Int
                if index < maxLines {
                    row = index
                } else if block.truncatesOverflow {
                    break
                } else {
                    row = maxLines - 1
                }
                let lineIndent = index == 0 ? 0 : indent
                let available = blockWidth - lineIndent
                var x = lineIndent
                var extraPerSpace = 0.0
                switch block.justification {
                case .left: break
                case .center: x += (available - line.width) / 2
                case .right: x += available - line.width
                case .justified:
                    if !line.endsParagraph && line.innerSpaces > 0 && available > line.width {
                        extraPerSpace = (available - line.width) / Double(line.innerSpaces)
                    }
                }
                let baseline = Double(row * pitch + font.baseline)
                for character in line.characters {
                    if character != " " {
                        placed.append(PlacedCharacter(character: character, x: x, baseline: baseline))
                    }
                    x += font.advance(character) + gap
                    if character == " " { x += extraPerSpace }
                }
                endX = x
            }
            let printedLines = max(1, min(lines.count, maxLines))
            self.characters = placed
            self.width = max(0, block.width)
            self.height = max(1, maxLines * font.height + (maxLines - 1) * block.lineSpacing)
            self.lastBaseline = (printedLines - 1) * pitch + font.baseline
            self.endX = endX
            self.overflowLines = max(0, lines.count - maxLines)
            self.lineCount = lines.count
            return
        }

        let characters = Array(text)
        var placed: [PlacedCharacter] = []
        placed.reserveCapacity(characters.count)
        switch direction {
        case .horizontal, .reverse:
            let advances = characters.map { font.advance($0) + gap }
            let total = advances.reduce(0, +)
            var x = 0.0
            for (index, character) in characters.enumerated() {
                let penX = direction == .horizontal ? x : total - x - advances[index]
                if character != " " {
                    placed.append(PlacedCharacter(character: character, x: penX, baseline: Double(font.baseline)))
                }
                x += advances[index]
            }
            self.width = max(0, Int(total.rounded(.up)))
            self.height = font.height
            self.lastBaseline = font.baseline
            self.endX = total
        case .vertical:
            let pitch = Double(font.height) + gap
            var widest = 0.0
            for (index, character) in characters.enumerated() {
                widest = max(widest, font.advance(character))
                if character != " " {
                    placed.append(PlacedCharacter(character: character, x: 0,
                                                  baseline: Double(index) * pitch + Double(font.baseline)))
                }
            }
            let count = max(1, characters.count)
            self.width = max(0, Int(widest.rounded(.up)))
            self.height = max(1, Int((Double(count) * pitch - gap).rounded(.up)))
            self.lastBaseline = Int((Double(count - 1) * pitch).rounded()) + font.baseline
            self.endX = widest
        }
        self.characters = placed
        self.overflowLines = 0
        self.lineCount = 1
    }

    // MARK: Umbruch

    /// Eine gesetzte Zeile.
    struct Line {
        var characters: [Character]
        /// Breite ohne abschließende Leerzeichen.
        var width: Double
        /// Leerzeichen zwischen Wörtern (für Blocksatz).
        var innerSpaces: Int
        var endsParagraph: Bool
    }

    /// Zerlegt Blocktext an `\&` in Absätze; `\\` wird zu `\`.
    static func paragraphs(_ text: String) -> [[Character]] {
        var result: [[Character]] = []
        var current: [Character] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "&" {
                    result.append(current)
                    current = []
                    index += 2
                    continue
                }
                if next == "\\" {
                    current.append("\\")
                    index += 2
                    continue
                }
            }
            current.append(character)
            index += 1
        }
        result.append(current)
        return result
    }

    /// Greedy-Umbruch eines Absatzes; `available(lineIndex)` liefert die verfügbare Breite.
    private static func wrap(_ paragraph: [Character], font: TextFont, gap: Double, lines: inout [Line],
                             available: (Int) -> Double) {
        // Wörter und Leerzeichenfolgen trennen.
        var runs: [(isSpace: Bool, characters: [Character])] = []
        for character in paragraph {
            let isSpace = character == " "
            if let last = runs.last, last.isSpace == isSpace {
                runs[runs.count - 1].characters.append(character)
            } else {
                runs.append((isSpace, [character]))
            }
        }
        func width(_ characters: ArraySlice<Character>) -> Double {
            characters.reduce(0) { $0 + font.advance($1) + gap }
        }

        let firstLineOfParagraph = lines.count
        var current: [Character] = []
        var currentWidth = 0.0          // Breite inklusive aller Zeichen in `current`
        var innerSpaces = 0
        var pendingSpaces: [Character] = []

        func finishLine(endsParagraph: Bool) {
            var trimmed = current
            var trailing = 0
            while trimmed.last == " " {
                trimmed.removeLast()
                trailing += 1
            }
            lines.append(Line(characters: trimmed, width: width(trimmed[...]), innerSpaces: innerSpaces,
                              endsParagraph: endsParagraph))
            current = []
            currentWidth = 0
            innerSpaces = 0
        }

        for run in runs {
            if run.isSpace {
                if current.isEmpty && lines.count == firstLineOfParagraph {
                    // Führende Leerzeichen eines Absatzes bleiben erhalten.
                    current.append(contentsOf: run.characters)
                    currentWidth += width(run.characters[...])
                } else {
                    pendingSpaces.append(contentsOf: run.characters)
                }
                continue
            }
            let word = run.characters
            let wordWidth = width(word[...])
            let spaceWidth = width(pendingSpaces[...])
            let limit = available(lines.count)
            let isLineStart = current.allSatisfy { $0 == " " }
            if isLineStart || currentWidth + spaceWidth + wordWidth <= limit + 0.001 {
                if !isLineStart {
                    current.append(contentsOf: pendingSpaces)
                    currentWidth += spaceWidth
                    innerSpaces += pendingSpaces.count
                }
                pendingSpaces = []
                if currentWidth + wordWidth <= limit + 0.001 {
                    current.append(contentsOf: word)
                    currentWidth += wordWidth
                    continue
                }
            } else {
                finishLine(endsParagraph: false)
                pendingSpaces = []
                if wordWidth <= available(lines.count) + 0.001 {
                    current = word
                    currentWidth = wordWidth
                    continue
                }
            }
            // Wort passt nicht in eine (leere) Zeile: zeichenweise umbrechen.
            for character in word {
                let advance = font.advance(character) + gap
                let lineLimit = available(lines.count)
                let hasInk = current.contains { $0 != " " }
                if hasInk && currentWidth + advance > lineLimit + 0.001 {
                    finishLine(endsParagraph: false)
                }
                current.append(character)
                currentWidth += advance
            }
        }
        finishLine(endsParagraph: true)
    }
}

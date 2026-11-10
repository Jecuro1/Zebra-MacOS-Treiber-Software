import Foundation

/// Hilfsfunktionen zum Aufbau linearer Barcodes.
enum LinearSupport {

    /// Wandelt eine Folge abwechselnder Breiten (beginnend mit einem Balken) in Elemente um.
    static func elements(widths: [Int], startWithBar: Bool = true, isGuard: Bool = false) -> [LinearBarcode.Element] {
        var result: [LinearBarcode.Element] = []
        result.reserveCapacity(widths.count)
        var bar = startWithBar
        for width in widths {
            result.append(LinearBarcode.Element(isBar: bar, width: width, isGuard: isGuard))
            bar.toggle()
        }
        return result
    }

    /// Lauflängenkodierung einer Modulfolge. `guards[i]` markiert Module von Begrenzungszeichen.
    ///
    /// Ein neues Element beginnt, sobald Farbe **oder** Begrenzungs-Kennzeichen wechseln.
    static func elements(modules: [Bool], guards: [Bool]) -> [LinearBarcode.Element] {
        precondition(modules.count == guards.count)
        var result: [LinearBarcode.Element] = []
        var index = 0
        while index < modules.count {
            let color = modules[index]
            let guardFlag = guards[index]
            var end = index + 1
            while end < modules.count && modules[end] == color && guards[end] == guardFlag { end += 1 }
            result.append(LinearBarcode.Element(isBar: color, width: end - index, isGuard: guardFlag))
            index = end
        }
        return result
    }

    /// Hängt Elemente an und verschmilzt dabei gleichfarbige Nachbarn (Sicherheitsnetz).
    static func append(_ new: [LinearBarcode.Element], to elements: inout [LinearBarcode.Element]) {
        for element in new {
            if let last = elements.last, last.isBar == element.isBar, last.isGuard == element.isGuard {
                elements[elements.count - 1].width += element.width
            } else {
                elements.append(element)
            }
        }
    }

    /// Liefert die Ziffernwerte eines reinen Ziffern-Strings oder wirft `invalidCharacter`.
    static func digits(_ text: String) throws -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(text.count)
        for character in text {
            guard let ascii = character.asciiValue, ascii >= 0x30, ascii <= 0x39 else {
                throw BarcodeError.invalidCharacter(character)
            }
            result.append(Int(ascii - 0x30))
        }
        return result
    }

    /// Prüfziffer nach Modulo 10 mit den Gewichten 3/1, beginnend mit 3 an der Ziffer ganz rechts
    /// (EAN, UPC, GS1, Interleaved 2 of 5).
    static func mod10Weighted31(_ digits: [Int]) -> Int {
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            sum += digit * (offset % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// Zeichen für eine Ziffer 0…9.
    static func digitCharacter(_ value: Int) -> Character {
        Character(Unicode.Scalar(UInt8(0x30 + value)))
    }
}

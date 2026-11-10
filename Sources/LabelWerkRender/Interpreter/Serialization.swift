import Foundation

/// Seriennummern für `^SN` und `^SF`.
///
/// * `^SNv,n,z`: Der rechteste Ziffernblock von `v` wird je Etikett um `n` erhöht. Mit `z = Y`
///   bleibt seine Breite mit führenden Nullen erhalten (Überlauf läuft auf 0 um), sonst wird die
///   Zahl ohne Auffüllung geschrieben. Das erste Etikett zeigt `v` unverändert.
/// * `^SFa,b`: Maske `a` und Schrittweite `b` werden rechtsbündig an den Felddaten ausgerichtet.
///   Maskenzeichen: `D`/`d` dezimal, `H` hexadezimal (groß), `h` (klein), `O`/`o` oktal,
///   `A` Großbuchstaben, `a` Kleinbuchstaben, `N` 0–9 + A–Z, `n` 0–9 + a–z, `%` = nicht zählen.
///   Überträge wandern zur nächsten zählenden Stelle links.
enum Serializer {

    static func value(_ spec: SerialSpec, copy: Int) -> String {
        switch spec {
        case let .number(start, increment, leadingZeros):
            return number(start, increment: increment, leadingZeros: leadingZeros, copy: copy)
        case let .mask(base, mask, increment):
            return masked(base, mask: mask, increment: increment, copy: copy)
        }
    }

    static func number(_ start: String, increment: Int, leadingZeros: Bool, copy: Int) -> String {
        guard copy > 0 else { return start }
        let characters = Array(start)
        guard let last = characters.lastIndex(where: { $0.isASCII && $0.isNumber }) else { return start }
        var first = last
        while first > 0, characters[first - 1].isASCII, characters[first - 1].isNumber, last - first < 11 { first -= 1 }
        let digits = String(characters[first...last])
        let width = digits.count
        let base = Int(digits) ?? 0
        let (product, overflow) = increment.multipliedReportingOverflow(by: copy)
        var value = overflow ? base : base &+ product
        let text: String
        if leadingZeros {
            let modulus = Int(pow(10.0, Double(width)))
            value = ((value % modulus) + modulus) % modulus
            let plain = String(value)
            text = String(repeating: "0", count: max(0, width - plain.count)) + plain
        } else {
            text = String(max(0, value))
        }
        return String(characters[..<first]) + text + String(characters[(last + 1)...])
    }

    static func masked(_ base: String, mask: String, increment: String, copy: Int) -> String {
        var data = Array(base)
        let maskCharacters = Array(mask)
        guard !maskCharacters.isEmpty, copy > 0 else { return base }
        // Daten links auffüllen, falls die Maske länger ist.
        if data.count < maskCharacters.count {
            data = Array(repeating: "0", count: maskCharacters.count - data.count) + data
        }
        let offset = data.count - maskCharacters.count
        let steps = Array(increment)
        for _ in 0..<min(copy, 100_000) {
            var carry = 0
            var position = maskCharacters.count - 1
            var stepIndex = steps.count - 1
            while position >= 0 {
                let maskCharacter = maskCharacters[position]
                guard let alphabet = alphabet(for: maskCharacter) else {
                    position -= 1
                    stepIndex -= 1
                    continue
                }
                let stepCharacter: Character? = stepIndex >= 0 ? steps[stepIndex] : nil
                let step = stepCharacter.flatMap { alphabetIndex($0, in: alphabet) } ?? 0
                let current = alphabetIndex(data[offset + position], in: alphabet) ?? 0
                let sum = current + step + carry
                data[offset + position] = alphabet[sum % alphabet.count]
                carry = sum / alphabet.count
                position -= 1
                stepIndex -= 1
                if carry == 0 && stepIndex < 0 { break }
            }
        }
        return String(data)
    }

    private static let decimal = Array("0123456789")
    private static let hexUpper = Array("0123456789ABCDEF")
    private static let hexLower = Array("0123456789abcdef")
    private static let octal = Array("01234567")
    private static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    private static let alnumUpper = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let alnumLower = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    private static func alphabet(for mask: Character) -> [Character]? {
        switch mask {
        case "D", "d": return decimal
        case "H": return hexUpper
        case "h": return hexLower
        case "O", "o": return octal
        case "A": return upper
        case "a": return lower
        case "N": return alnumUpper
        case "n": return alnumLower
        default: return nil
        }
    }

    /// Position eines Zeichens im Zählalphabet; `nil`, wenn es dort nicht vorkommt.
    ///
    /// Schrittweiten werden auch in der jeweils anderen ASCII-Schreibweise akzeptiert. Alle
    /// Alphabete bestehen aus ASCII-Zeichen; andere Zeichen (z. B. ß, dessen Großschreibung
    /// „SS“ zwei Zeichen lang ist) zählen daher nie und werden nicht umgewandelt.
    static func alphabetIndex(_ character: Character, in alphabet: [Character]) -> Int? {
        if let index = alphabet.firstIndex(of: character) { return index }
        guard character.isASCII else { return nil }
        let upper = character.asciiUppercased
        let swapped = upper == character ? character.asciiLowercased : upper
        return swapped == character ? nil : alphabet.firstIndex(of: swapped)
    }
}

/// Uhrzeitfelder (`^FC`): ersetzt `%`-Codes (bzw. die gewählten Kennzeichen) durch Datum und Uhrzeit.
///
/// Unterstützt: `%a %A %b %B %d %H %I %j %m %M %p %S %y %Y %U %W %w` und `%%`. Zweit- und
/// Drittkennzeichen werden wie das primäre behandelt (Zeitversätze per `^SO` werden nicht nachgebildet).
/// Wochentags- und Monatsnamen sind englisch wie in der Druckerfirmware.
enum ClockFormatter {
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                                 "September", "October", "November", "December"]

    static func format(_ text: String, indicators: [Character], date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = parts.year ?? 2000, month = parts.month ?? 1, day = parts.day ?? 1
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0
        let weekday = (parts.weekday ?? 1) - 1   // 0 = Sonntag
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1

        func pad(_ value: Int, _ width: Int = 2) -> String {
            let plain = String(value)
            return String(repeating: "0", count: max(0, width - plain.count)) + plain
        }
        // Wochennummern nach strftime: %U (Sonntag als erster Tag), %W (Montag als erster Tag).
        let weekSunday = (dayOfYear - 1 + 7 - weekday) / 7
        let weekMonday = (dayOfYear - 1 + 7 - ((weekday + 6) % 7)) / 7

        var result = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard indicators.contains(character), index + 1 < characters.count else {
                result.append(character)
                index += 1
                continue
            }
            let code = characters[index + 1]
            index += 2
            switch code {
            case "a": result += String(weekdays[weekday].prefix(3))
            case "A": result += weekdays[weekday]
            case "b": result += String(months[month - 1].prefix(3))
            case "B": result += months[month - 1]
            case "d": result += pad(day)
            case "H": result += pad(hour)
            case "I": result += pad(hour % 12 == 0 ? 12 : hour % 12)
            case "j": result += pad(dayOfYear, 3)
            case "m": result += pad(month)
            case "M": result += pad(minute)
            case "p": result += hour < 12 ? "AM" : "PM"
            case "S": result += pad(second)
            case "y": result += pad(year % 100)
            case "Y": result += String(year)
            case "U": result += pad(weekSunday)
            case "W": result += pad(weekMonday)
            case "w": result += String(weekday)
            default:
                if code == character {
                    result.append(character)
                } else {
                    result.append(character)
                    result.append(code)
                }
            }
        }
        return result
    }
}

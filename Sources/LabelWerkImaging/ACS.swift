import Foundation

/// Zebra „Alternative Compression Scheme“ (ACS) für ASCII-Hex-Grafikdaten
/// (`^GF` Format A, `~DG`, `~DB`).
///
/// Die Daten sind ein Strom von Hex-Nibbles; eine Zeile umfasst `2 × bytesPerRow` Nibbles.
/// Zusätzlich zu den Hexziffern `0–9 A–F` (auch `a–f`) gelten:
///
/// * Wiederholungszähler vor einer Hexziffer: `G`–`Y` = 1–19, `g`–`z` = 20, 40, …, 400.
///   Zähler sind kombinierbar und addieren sich, z. B. `hB` = 40 × `B`, `vMB` = 327 × `B`.
/// * `,` füllt den Rest der aktuellen Zeile mit `0` (weiß).
/// * `!` füllt den Rest der aktuellen Zeile mit `F` (schwarz).
/// * `:` wiederholt die vorherige Zeile.
///
/// Steht `,`, `!` oder `:` genau am Zeilenanfang, betrifft es die komplette Zeile.
/// Die Zeilenlogik arbeitet nibbleweise; Wiederholungen dürfen Zeilengrenzen überschreiten.
public enum ACS {

    /// Kodiert eine Bitmap kompakt im ACS-Format.
    ///
    /// Je Zeile: identisch zur Vorzeile → `:`; sonst Lauflängen-Kodierung, wobei ein
    /// abschließender Lauf aus `0` bzw. `F` durch `,` bzw. `!` ersetzt wird.
    public static func encode(_ bitmap: MonoBitmap) -> String {
        let bpr = bitmap.bytesPerRow
        guard bpr > 0, bitmap.height > 0 else { return "" }
        let rowNibbles = bpr * 2
        var out = [UInt8]()
        out.reserveCapacity(bitmap.height * 8)
        var nibbles = [UInt8](repeating: 0, count: rowNibbles)

        bitmap.data.withUnsafeBufferPointer { data in
            for y in 0..<bitmap.height {
                let rowStart = y * bpr
                // Identische Vorzeile → ':'
                if y > 0 {
                    var same = true
                    for i in 0..<bpr where data[rowStart + i] != data[rowStart - bpr + i] {
                        same = false
                        break
                    }
                    if same {
                        out.append(UInt8(ascii: ":"))
                        continue
                    }
                }
                for i in 0..<bpr {
                    let b = data[rowStart + i]
                    nibbles[2 * i] = b >> 4
                    nibbles[2 * i + 1] = b & 0x0F
                }
                // Abschließenden Lauf bestimmen.
                let last = nibbles[rowNibbles - 1]
                var tailStart = rowNibbles - 1
                while tailStart > 0 && nibbles[tailStart - 1] == last { tailStart -= 1 }
                let tailLength = rowNibbles - tailStart
                var bodyEnd = rowNibbles
                var terminator: UInt8?
                if (last == 0 || last == 0x0F) && tailLength >= 2 {
                    bodyEnd = tailStart
                    terminator = last == 0 ? UInt8(ascii: ",") : UInt8(ascii: "!")
                }
                // Lauflängen im Rumpf.
                var i = 0
                while i < bodyEnd {
                    let value = nibbles[i]
                    var j = i + 1
                    while j < bodyEnd && nibbles[j] == value { j += 1 }
                    appendRun(value: value, count: j - i, to: &out)
                    i = j
                }
                if let terminator { out.append(terminator) }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Dekodiert ACS-Daten (bzw. reines Hex) in genau `totalBytes` Bytes.
    ///
    /// Fehlende Daten werden mit 0 aufgefüllt, überzählige ignoriert. Leerraum (Leerzeichen,
    /// Tabulator, CR, LF) wird überlesen. Ein Wiederholungszähler ohne folgende Hexziffer wird
    /// verworfen. `:` in der ersten Zeile ergibt eine leere Zeile; `:` mitten in einer Zeile
    /// übernimmt den Rest der Zeile aus der Vorzeile.
    ///
    /// - Throws: `ImagingError.invalidArgument` bei `bytesPerRow ≤ 0` oder `totalBytes < 0`,
    ///   `ImagingError.invalidGraphicData` bei unzulässigen Zeichen.
    public static func decode(_ string: String, bytesPerRow: Int, totalBytes: Int) throws -> [UInt8] {
        guard bytesPerRow > 0 else {
            throw ImagingError.invalidArgument("bytesPerRow muss größer als 0 sein (\(bytesPerRow)).")
        }
        guard totalBytes >= 0 else {
            throw ImagingError.invalidArgument("totalBytes darf nicht negativ sein (\(totalBytes)).")
        }
        var output = [UInt8](repeating: 0, count: totalBytes)
        guard totalBytes > 0 else { return output }
        let rowNibbles = bytesPerRow * 2
        let totalNibbles = totalBytes * 2
        var pos = 0
        var pending = 0

        try output.withUnsafeMutableBufferPointer { out in
            /// Schreibt `count` mal den Nibble `value` ab `pos`.
            func put(_ value: UInt8, _ count: Int) {
                var n = min(count, totalNibbles - pos)
                guard n > 0 else { return }
                // Bis zur Bytegrenze einzeln …
                if pos & 1 == 1 {
                    out[pos >> 1] = (out[pos >> 1] & 0xF0) | value
                    pos += 1
                    n -= 1
                }
                // … dann ganze Bytes …
                let fullBytes = n >> 1
                if fullBytes > 0 {
                    let byte = value << 4 | value
                    let start = pos >> 1
                    for k in start..<(start + fullBytes) { out[k] = byte }
                    pos += fullBytes * 2
                    n -= fullBytes * 2
                }
                // … und ein letzter halber.
                if n == 1 {
                    out[pos >> 1] = (out[pos >> 1] & 0x0F) | (value << 4)
                    pos += 1
                }
            }
            func nibble(at index: Int) -> UInt8 {
                let b = out[index >> 1]
                return index & 1 == 0 ? b >> 4 : b & 0x0F
            }

            for c in string.utf8 {
                if pos >= totalNibbles { break }
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    put(c &- UInt8(ascii: "0"), pending == 0 ? 1 : pending)
                    pending = 0
                case UInt8(ascii: "A")...UInt8(ascii: "F"):
                    put(c &- UInt8(ascii: "A") &+ 10, pending == 0 ? 1 : pending)
                    pending = 0
                case UInt8(ascii: "a")...UInt8(ascii: "f"):
                    put(c &- UInt8(ascii: "a") &+ 10, pending == 0 ? 1 : pending)
                    pending = 0
                case UInt8(ascii: "G")...UInt8(ascii: "Y"):
                    pending += Int(c - UInt8(ascii: "G")) + 1
                case UInt8(ascii: "g")...UInt8(ascii: "z"):
                    pending += (Int(c - UInt8(ascii: "g")) + 1) * 20
                case UInt8(ascii: ","), UInt8(ascii: "!"):
                    pending = 0
                    let rowEnd = (pos / rowNibbles + 1) * rowNibbles
                    put(c == UInt8(ascii: ",") ? 0 : 0x0F, rowEnd - pos)
                case UInt8(ascii: ":"):
                    pending = 0
                    let row = pos / rowNibbles
                    let rowEnd = min((row + 1) * rowNibbles, totalNibbles)
                    if row == 0 {
                        put(0, rowEnd - pos)
                    } else {
                        while pos < rowEnd {
                            put(nibble(at: pos - rowNibbles), 1)
                        }
                    }
                case 0x20, 0x09, 0x0A, 0x0D:
                    continue
                default:
                    throw ImagingError.invalidGraphicData(
                        "Unzulässiges Zeichen „\(Character(Unicode.Scalar(c)))“ in Hex/ACS-Daten.")
                }
            }
        }
        return output
    }

    // MARK: - Intern

    /// Zähler-Zeichen: Großbuchstaben G…Y (1…19), Kleinbuchstaben g…z (20…400).
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Hängt einen Lauf von `count` gleichen Nibbles an (Zähler maximal 419 je Gruppe).
    static func appendRun(value: UInt8, count: Int, to out: inout [UInt8]) {
        let digit = hexDigits[Int(value)]
        var remaining = count
        while remaining > 0 {
            let n = min(remaining, 419)
            if n <= 2 {
                for _ in 0..<n { out.append(digit) }
            } else {
                let twenties = n / 20, ones = n % 20
                if twenties > 0 { out.append(UInt8(ascii: "g") + UInt8(twenties - 1)) }
                if ones > 0 { out.append(UInt8(ascii: "G") + UInt8(ones - 1)) }
                out.append(digit)
            }
            remaining -= n
        }
    }
}

import Foundation

/// Ein einzelner ZPL-Befehl, z. B. `^FO50,50` oder `~JC`.
///
/// Die gerenderte Form (`description`) ist immer `prefix + code + parameters.joined(",")`.
/// Parameter, die laut ZPL-Syntax ohne Komma direkt an den Befehlscode anschließen
/// (z. B. die Ausrichtung in `^A0N,30,30` oder das Format in `^GFA,…`), werden als erstes
/// Element von `parameters` geführt – so ergibt `^A0` + `["N", "30", "30"]` genau `^A0N,30,30`.
///
/// Für `^FD` enthält `parameters` genau ein Element: die bereits maskierten Felddaten
/// (siehe ``ZPL/escapeFieldData(_:)``).
public struct ZPLCommand: Hashable, Sendable, CustomStringConvertible {
    /// Befehlspräfix: `^` für Formatbefehle, `~` für Steuerbefehle (sofort ausgeführt).
    public enum Prefix: Character, Sendable {
        case caret = "^"
        case tilde = "~"
    }

    public var prefix: Prefix
    /// Befehlscode ohne Präfix, z. B. `FO`, `A0`, `GF`, `HQ`.
    public var code: String
    /// Parameter; werden beim Rendern mit `,` verbunden und direkt an `code` angehängt.
    public var parameters: [String]

    public init(_ prefix: Prefix = .caret, _ code: String, _ parameters: [String] = []) {
        self.prefix = prefix
        self.code = code
        self.parameters = parameters
    }

    /// Kurzform für `^`-Befehle: `ZPLCommand("FO", ["50", "50"])`.
    public init(_ code: String, _ parameters: [String] = []) {
        self.init(.caret, code, parameters)
    }

    /// Gerenderte Form, z. B. `^FO50,50`.
    public var description: String {
        String(prefix.rawValue) + code + parameters.joined(separator: ",")
    }

    /// Gerenderte Form mit anderen Steuerzeichen (`^CC`/`^CT`/`^CD`): Formatpräfix statt `^`,
    /// Steuerpräfix statt `~`, Trennzeichen statt `,` zwischen den Parametern. Die Parameter
    /// selbst bleiben unverändert (z. B. Grafikdaten). Mit ``ControlCharacters/standard`` gleich
    /// ``description``.
    public func rendered(with characters: ControlCharacters) -> String {
        let prefixText = prefix == .caret ? characters.formatPrefixString : characters.controlPrefixString
        return prefixText + code + parameters.joined(separator: characters.delimiterString)
    }

    /// Zweistelliger Befehlsname inkl. Präfix in Großbuchstaben, z. B. `^FO`, `~JC`, `^A`.
    ///
    /// Bei `^A` (Schrift) gehört das folgende Zeichen zum Schriftnamen, daher wird nur `^A`
    /// geliefert. Nützlich für Auswertungen und Tests.
    public var mnemonic: String {
        let upper = code.uppercased()
        if upper.hasPrefix("A") { return String(prefix.rawValue) + "A" }
        return String(prefix.rawValue) + String(upper.prefix(2))
    }

    /// `true` für Befehle, die ein Feld eröffnen (`^FO`, `^FT`).
    var opensField: Bool { prefix == .caret && (code == "FO" || code == "FT") }

    /// `true` für den Feldtrenner `^FS`.
    var closesField: Bool { prefix == .caret && code == "FS" }
}

// MARK: - Result Builder

/// Result Builder für ZPL-Formate.
///
/// Unterstützt einzelne Befehle, Arrays von Befehlen (z. B. ``ZPL/text(_:x:y:height:width:font:orientation:)``),
/// optionale Befehle, `if`/`else`, `switch`, `for`-Schleifen und `#available`.
///
/// ```swift
/// let zpl = ZPL.format {
///     ZPL.changeEncoding()
///     ZPL.text("Hallo", x: 50, y: 50, height: 40)
///     if showBarcode {
///         ZPL.barcodeDefaults(moduleWidth: 2)
///         ZPL.fieldOrigin(x: 50, y: 120)
///         ZPL.code128(height: 80)
///         ZPL.fieldData("12345")
///         ZPL.fieldSeparator()
///     }
///     for (index, line) in lines.enumerated() {
///         ZPL.text(line, x: 50, y: 250 + index * 40, height: 30)
///     }
/// }
/// ```
@resultBuilder
public enum ZPLFormatBuilder {
    public static func buildExpression(_ command: ZPLCommand) -> [ZPLCommand] { [command] }

    public static func buildExpression(_ commands: [ZPLCommand]) -> [ZPLCommand] { commands }

    public static func buildExpression(_ command: ZPLCommand?) -> [ZPLCommand] {
        command.map { [$0] } ?? []
    }

    public static func buildExpression(_ commands: [ZPLCommand]?) -> [ZPLCommand] { commands ?? [] }

    public static func buildBlock(_ components: [ZPLCommand]...) -> [ZPLCommand] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [ZPLCommand]?) -> [ZPLCommand] { component ?? [] }

    public static func buildEither(first component: [ZPLCommand]) -> [ZPLCommand] { component }

    public static func buildEither(second component: [ZPLCommand]) -> [ZPLCommand] { component }

    public static func buildArray(_ components: [[ZPLCommand]]) -> [ZPLCommand] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ component: [ZPLCommand]) -> [ZPLCommand] { component }

    public static func buildFinalResult(_ component: [ZPLCommand]) -> [ZPLCommand] { component }
}

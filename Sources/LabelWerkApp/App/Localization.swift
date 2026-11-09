import Foundation

/// Übersetzt einen deutschen Quelltext in die aktuelle Sprache.
///
/// Deutsch ist die Entwicklungssprache: Der Schlüssel *ist* der deutsche Text. Fehlt eine
/// Übersetzung (z. B. beim Start über `swift run`), wird der deutsche Text angezeigt.
/// Übersetzungen liegen in `Installer/Resources/en.lproj/Localizable.strings` und werden mit
/// `Scripts/extract_strings.py` gepflegt. Schlüssel dürfen keine String-Interpolation enthalten –
/// für Platzhalter `tr("… %@ …", wert)` verwenden.
func tr(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Übersetzt einen Formatstring (`%@`, `%d`, `%.1f` …) und setzt die Argumente ein.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: tr(key), locale: Locale.current, arguments: arguments)
}

import Foundation

/// „Mit LabelWerk drucken“ im PDF-Menü des macOS-Druckdialogs (PDF-Dienst, „PDF Services“).
///
/// macOS listet jede ausführbare Datei in `~/Library/PDF Services` im Menü „PDF ▾“ jedes
/// Druckdialogs. Wählt man den Eintrag, erzeugt macOS aus dem Dokument eine PDF-Datei und ruft die
/// Datei mit `$1` = Titel, `$2` = CUPS-Optionen und `$3` = Pfad der vorübergehenden PDF-Datei auf;
/// die PDF-Datei löscht macOS, sobald das Skript endet. Unser Skript kopiert sie deshalb in den
/// Zwischenspeicher von LabelWerk (`~/Library/Caches/<Bundle-ID>/Incoming`) und öffnet die Kopie mit
/// `open -b <Bundle-ID>` – die App zeigt sie im Fenster „Etikettendruck“ (genaue Vorschau, Drucker
/// und Etikettentyp wählen, drucken).
///
/// Die App legt das Skript bei jedem Start still an bzw. aktualisiert es (nur für den angemeldeten
/// Benutzer, ohne Administratorrechte). Eine Datei gleichen Namens ohne die Kennzeile
/// ``marker`` stammt nicht von LabelWerk und bleibt unverändert. `Scripts/uninstall.sh` entfernt das
/// Skript zusammen mit der App; `Scripts/tests/test_installer_scripts.py` führt ``scriptTemplate``
/// (aus dieser Datei gelesen) mit einer Beispiel-PDF aus.
enum PDFServiceInstaller {
    /// Name im Menü „PDF ▾“ (= Dateiname).
    static let serviceName = "Mit LabelWerk drucken"
    /// Version des Skripts (Kopfzeile); bei Änderungen erhöhen.
    static let version = 1
    /// Kennzeile, an der LabelWerk (und `uninstall.sh`) das eigene Skript erkennt.
    static let marker = "# LabelWerk-PDF-Dienst"
    /// Bundle-ID, falls die App keine meldet (z. B. beim Start aus `swift run`).
    static let defaultBundleID = "com.labelwerk.app"
    /// Ordner (unter dem Zwischenspeicher der App), in den das Skript die PDF-Dateien kopiert.
    static let incomingFolderName = "Incoming"
    /// Kopien in `Incoming`, die älter sind, löscht die App beim Start.
    static let incomingLifetime: TimeInterval = 7 * 24 * 3600

    enum Outcome: Equatable {
        case installed
        case updated
        case unchanged
        /// Eine fremde Datei gleichen Namens (ohne ``marker``) – bleibt unverändert.
        case foreignFileKept
    }

    /// Bundle-ID für `open -b` und den Zwischenspeicher: die der App, falls sie nur aus
    /// Buchstaben, Ziffern, Punkt und Bindestrich besteht (steht im Skript in einfachen
    /// Anführungszeichen), sonst ``defaultBundleID``.
    static var bundleID: String {
        sanitizedBundleID(Bundle.main.bundleIdentifier)
    }

    static func sanitizedBundleID(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty, identifier.count <= 155,
              identifier.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
              })
        else { return defaultBundleID }
        return identifier
    }

    static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/Library/PDF Services`
    static var servicesDirectory: URL {
        homeDirectory.appendingPathComponent("Library/PDF Services", isDirectory: true)
    }

    /// `~/Library/PDF Services/Mit LabelWerk drucken`
    static var serviceURL: URL { servicesDirectory.appendingPathComponent(serviceName, isDirectory: false) }

    /// `~/Library/Caches/<Bundle-ID>/Incoming`
    static var incomingDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(incomingFolderName, isDirectory: true)
    }

    /// Liegt `url` im Eingangsordner des PDF-Dienstes (vorübergehende Kopie, darf gelöscht werden)?
    static func isIncomingCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == incomingDirectory.standardizedFileURL.path
    }

    /// Titel, den das Skript neben der Kopie ablegt (`<Name>.title`, der Titel aus `$1`), sonst `nil`.
    static func storedTitle(for url: URL) -> String? {
        let sidecar = url.deletingPathExtension().appendingPathExtension("title")
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Das Skript für `bundleID`.
    static func script(bundleID: String) -> String {
        scriptTemplate
            .replacingOccurrences(of: "@BUNDLE_ID@", with: sanitizedBundleID(bundleID))
            .replacingOccurrences(of: "@VERSION@", with: String(version))
    }

    // MARK: Installieren

    /// Legt das Skript an bzw. bringt es auf den aktuellen Stand (Inhalt und Rechte 0755). Blockiert
    /// kurz (Dateizugriffe) – aus einer Hintergrundaufgabe aufrufen.
    @discardableResult
    static func installIfNeeded(at url: URL = serviceURL, bundleID: String = bundleID) throws -> Outcome {
        let fileManager = FileManager.default
        let desired = script(bundleID: bundleID)
        var outcome = Outcome.installed
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            guard existing.contains(marker) else { return .foreignFileKept }
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            if existing == desired, permissions == 0o755 { return .unchanged }
            outcome = .updated
        } else if fileManager.fileExists(atPath: url.path) {
            // Vorhanden, aber nicht als Text lesbar (fremde Datei, Ordner …): nicht anfassen.
            return .foreignFileKept
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomar ersetzen: Ein gleichzeitig laufender Druckdialog sieht nie ein halbes Skript.
        try Data(desired.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return outcome
    }

    /// Löscht Kopien im Eingangsordner, die älter als ``incomingLifetime`` sind.
    static func cleanUpIncoming(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: incomingDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > incomingLifetime {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// Entfernt eine Kopie aus dem Eingangsordner samt Titel-Datei (nur dort; andere Dateien nie).
    static func removeIncomingCopy(_ url: URL) {
        guard isIncomingCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("title"))
    }

    // MARK: Skript

    /// POSIX-sh-Skript (keine Bash-Erweiterungen, alles in Anführungszeichen). `@BUNDLE_ID@` und
    /// `@VERSION@` ersetzt ``script(bundleID:)``. Der Test in `Scripts/tests` liest den Text zwischen
    /// `#"""` und `"""#` aus dieser Datei – darum steht er ohne Einrückung.
    static let scriptTemplate = #"""
#!/bin/sh
# LabelWerk-PDF-Dienst „Mit LabelWerk drucken“, Version @VERSION@
#
# Von LabelWerk angelegt und bei jedem Start aktualisiert – Änderungen hier werden überschrieben.
# macOS ruft das Skript im Druckdialog über „PDF ▾ › Mit LabelWerk drucken“ auf:
#   $1 Titel des Dokuments, $2 CUPS-Optionen, $3 Pfad der vorübergehenden PDF-Datei
#   (macOS löscht sie, sobald das Skript endet).
# Das Skript kopiert die PDF-Datei nach ~/Library/Caches/@BUNDLE_ID@/Incoming und öffnet die
# Kopie in LabelWerk („Etikettendruck“). LW_PDF_SERVICE_NO_OPEN=1 überspringt das Öffnen (Tests).

bundle_id='@BUNDLE_ID@'
title=${1-}
source_pdf=${3-}

if [ -z "$source_pdf" ] || [ ! -f "$source_pdf" ]; then
    echo "Mit LabelWerk drucken: keine PDF-Datei erhalten." >&2
    exit 1
fi
if [ -z "${HOME-}" ]; then
    echo "Mit LabelWerk drucken: HOME ist nicht gesetzt." >&2
    exit 1
fi

umask 077
incoming="$HOME/Library/Caches/$bundle_id/Incoming"
mkdir -p "$incoming" || exit 1

# Dateiname aus dem Titel: nur ASCII-Buchstaben, Ziffern, Leerzeichen, „.“, „_“ und „-“,
# höchstens 60 Zeichen (der vollständige Titel steht in der .title-Datei daneben).
name=$(printf '%s' "$title" | LC_ALL=C tr -c 'A-Za-z0-9 ._-' '_' | LC_ALL=C tr -s '_ ' | LC_ALL=C cut -c 1-60)
name=$(printf '%s' "$name" | LC_ALL=C sed -e 's/^[ ._-]*//' -e 's/[ ._-]*$//')
if [ -z "$name" ]; then
    name="Dokument"
fi
stamp=$(date '+%Y%m%d-%H%M%S')
base="$incoming/$stamp-$name"
counter=1
while [ -e "$base.pdf" ]; do
    counter=$((counter + 1))
    base="$incoming/$stamp-$name-$counter"
done

if ! cp "$source_pdf" "$base.pdf"; then
    echo "Mit LabelWerk drucken: Die PDF-Datei konnte nicht nach $incoming kopiert werden." >&2
    exit 1
fi
printf '%s\n' "$title" > "$base.title" 2>/dev/null || :

if [ "${LW_PDF_SERVICE_NO_OPEN-}" = "1" ]; then
    printf '%s\n' "$base.pdf"
    exit 0
fi
if ! /usr/bin/open -b "$bundle_id" "$base.pdf"; then
    echo "Mit LabelWerk drucken: LabelWerk konnte nicht geöffnet werden ($bundle_id)." >&2
    exit 1
fi
exit 0
"""#
}

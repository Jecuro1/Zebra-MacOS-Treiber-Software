# LabelWerk entwickeln

Dieses Dokument beschreibt, wie LabelWerk gebaut, getestet, lokalisiert, paketiert, signiert und
veröffentlicht wird. Die verbindlichen Schnittstellen stehen in [ARCHITECTURE.md](../ARCHITECTURE.md).

## Wegweiser

| Thema | Dokument |
|---|---|
| Module, öffentliche APIs, Auftragsformat (§8), Rasterung (§4.1), CUPS-Optionen (§9), Installationspfade (§10) | [ARCHITECTURE.md](../ARCHITECTURE.md) |
| App-Aufbau, Design-System, UI-Regeln | [docs/APP_ARCHITECTURE.md](APP_ARCHITECTURE.md) |
| CUPS-Filter (C): Optionen, Rasterformate, Tests | [Driver/filter/README.md](../Driver/filter/README.md) |
| PPD-Generator | [Driver/ppd/README.md](../Driver/ppd/README.md) |
| Installation, Einrichtung, Fehlersuche für Anwender | [docs/INSTALLATION.md](INSTALLATION.md) |

## Voraussetzungen

**macOS** (App, Universal-Filter, Paket): macOS 14 oder neuer mit **Xcode 16 oder neuer**
(empfohlen: aktuelles Xcode; `sudo xcode-select -s /Applications/Xcode.app`). Die
Befehlszeilenwerkzeuge allein genügen nicht – `swift build --arch arm64 --arch x86_64` benötigt
Xcode. Dazu Python 3 (im System enthalten), optional `brew install shellcheck`.

**Linux** (Kern, CLI, Filter, PPDs – so läuft auch die CI): Ubuntu 24.04 mit Swift 6.x von
[swift.org](https://www.swift.org/install/) und

```bash
sudo apt install build-essential libcups2-dev libcupsimage2-dev zlib1g-dev cups-client cups-ppdc \
                 python3 python3-yaml shellcheck
```

`Scripts/ci_linux.sh --install-deps setup` installiert Pakete und Swift-Toolchain (mit
Signaturprüfung) automatisch.

**Symbole neu zeichnen** (selten nötig): Python-Paket Pillow (`python3 -m pip install pillow`).

Es gibt keine externen Swift-Pakete; die Bibliotheken nutzen nur Foundation und die System-zlib,
der Filter nur libcups und zlib.

## Bauen und testen

Das `Makefile` im Wurzelverzeichnis fasst alle Befehle zusammen (`make` zeigt die Übersicht):

| Befehl | Wirkung |
|---|---|
| `make build` | `swift build` – Kernmodule, `lwctl`; auf macOS zusätzlich die App |
| `make test` | Katalogprüfung, `swift test`, Filtertests, PPD-Tests, Werkzeug-Tests |
| `make test-swift` | `swift test` (Swift Testing) |
| `make test-driver` | `make -C Driver/filter test`: C-Unit-Tests und End-to-End-Tests gegen den Python-Referenz-Encoder |
| `make test-ppd` | alle PPDs erzeugen, mit `cupstestppd` prüfen, Generator-Tests |
| `make test-scripts` | Tests von `extract_strings.py` und den Build-/Installationsskripten (`Scripts/tests`) |
| `make lint` | Shell-/Python-Syntax, ShellCheck, Workflow-YAML, Property-Listen, Lokalisierung, Katalog |
| `make ci` | kompletter CI-Lauf wie auf GitHub (`Scripts/ci_linux.sh` bzw. `Scripts/ci_macos.sh`) |
| `make driver` | Treiberbaum nach `build/driver-root` (unter Linux als Testaufbau mit `--host`) |
| `make app` / `make pkg` / `make notarize` | Release-Bausteine (siehe unten) |
| `make clean` / `make distclean` | Build-Ausgaben bzw. zusätzlich `.build/` entfernen |

Parallele Jobs begrenzen: `make test JOBS=2`. Einzelne Swift-Tests: `swift test --filter
LabelWerkImagingTests` oder `swift test --filter "Z64"`. Speicherfehler im Filter findet
`make -C Driver/filter asan` (AddressSanitizer + UBSan) bzw. `make -C Driver/filter valgrind`.

### App starten

* **Schnell:** `swift run LabelWerk` – startet die App ohne Bundle. Dann fehlen das eingebettete
  Treiberpaket, Systemmitteilungen und die englischen Texte (Anzeige auf Deutsch); alles andere
  funktioniert, inklusive Demo-Drucker.
* **Wie ausgeliefert:** `make app && open build/LabelWerk.app`. Für schnellere Durchläufe
  `make app APP_ARGS="--debug --skip-driver"` (Debug-Build nur für die eigene Architektur,
  vorhandenen Treiberbaum verwenden).

### Treiber lokal testen (macOS)

```bash
make install-dev                    # Filter + PPDs wie das Paket installieren (sudo), cupsd neu starten
sudo lpadmin -p LW-Test -E -v socket://192.168.1.50:9100 \
    -P /Library/Printers/PPDs/Contents/Resources/LabelWerk-zd421t-203dpi.ppd.gz
lp -d LW-Test -o lwDarkness=20 etikett.pdf
sudo cupsctl --debug-logging; sudo tail -f /var/log/cups/error_log
make uninstall-dev                  # Treiber wieder entfernen (App bleibt)
```

`install-dev` nutzt dieselben `preinstall`/`postinstall`-Skripte wie das Paket und verändert
keine bestehenden Systemordner. Ohne Drucker lässt sich ein Auftrag direkt prüfen: Der Filter
liest eine Rasterdatei und schreibt den Druckauftrag auf die Standardausgabe
(`Driver/filter/tests/run_e2e.py` zeigt, wie Rasterdaten mit `mkraster` erzeugt werden).

## Lokalisierung

Deutsch ist die Entwicklungssprache, Englisch die Übersetzung. Jeder sichtbare Text der App läuft
über `tr("Deutscher Text")` bzw. `tr("… %@ …", wert)`; der deutsche Text ist zugleich der
Schlüssel (`Bundle.main.localizedString`). **Keine String-Interpolation im Schlüssel** – sonst ist
der Text zur Laufzeit nicht übersetzbar.

```bash
make strings                                        # = python3 Scripts/extract_strings.py
python3 Scripts/extract_strings.py --list-todo      # noch nicht übersetzte Schlüssel
make strings-check                                  # = --check --strict (CI-Schritt „strings“)
```

`extract_strings.py` durchsucht `Sources/LabelWerkApp/**/*.swift` (Kommentare, Raw-, Mehrzeilen-
und Escape-Literale werden korrekt behandelt), nimmt zusätzlich die Texte aus Kernmodulen auf, die
die App dynamisch übersetzt (`displayName` der Aufzählungen, `PrinterAction.displayName/detail`,
Titel und Lösungsschritte aus `PrinterAlert`), schreibt `de.lproj/Localizable.strings` (Schlüssel =
Wert) und führt `en.lproj/Localizable.strings` zusammen:

* vorhandene Übersetzungen bleiben erhalten, neue Einträge stehen mit dem deutschen Text und der
  Markierung `/* TODO-EN */` am Zeilenende in der Datei – Übersetzung eintragen, Markierung
  löschen;
* nicht mehr verwendete Einträge wandern in den Abschnitt „Nicht mehr verwendet“ (`--prune`
  entfernt sie);
* Formatplatzhalter müssen in Anzahl und Typ übereinstimmen (`%@`, `%d`, `%ld`, `%.1f`); die
  Reihenfolge lässt sich mit `%1$@`, `%2$d` ändern. Falsche Platzhalter sind ein Fehler, weil sie
  zur Laufzeit abstürzen können. Ein Prozentzeichen in Formatstrings wird als `%%` geschrieben.

Stil der englischen Texte: knapp, macOS-typisch; Titel-Schreibweise für Befehle, Tasten und
Überschriften („Add Printer…“), Satz-Schreibweise für Beschreibungen; Auslassungspunkte ohne
Leerzeichen; Fachbegriffe und Marken unverändert (ZPL, EPL2, CPCL, SGD, Link-OS, dpi).

`InfoPlist.strings` (Anzeigename, Datenschutztexte) pflegt man von Hand; die deutschen Werte
müssen mit `Installer/Info.plist` übereinstimmen.

## Modellkatalog und PPDs

`Catalog/models.json` ist die einzige Quelle für Modelle und Etikettenformate. Änderungen in
`Catalog/build_catalog.py` vornehmen, dann `make catalog` (erzeugt `models.json` und das daraus
eingebettete `Sources/LabelWerkCore/Catalog/ModelCatalogData.swift`). Die PPD-Dateien entstehen
beim Paketbau automatisch aus dem Katalog (`Driver/ppd/generate_ppds.py`); `make test-ppd` prüft
sie mit `cupstestppd`.

## Symbole

`make icons` zeichnet das App-Symbol und das Druckersymbol prozedural mit Pillow und schreibt
`Installer/Resources/AppIcon.icns`, `Installer/Resources/LabelWerk.icns` (PNG-Einträge ic07–ic14
sowie ic04/ic05) und Vorschaubilder nach `Installer/Resources/icon-preview/`. Die Dateien sind
eingecheckt; neu zeichnen ist nur nach Änderungen an `Scripts/make_icons.py` nötig.

## Konfiguration und Versionen

Alle Release-Werte stehen an einer Stelle, in `Installer/config.env`, und lassen sich beim Aufruf
über die Umgebung überschreiben:

| Variable | Bedeutung |
|---|---|
| `APP_NAME` | Name der App und des Pakets (`LabelWerk`) |
| `BUNDLE_ID` | Bundle-Kennung (`com.labelwerk.app`); Paketkennungen: `<BUNDLE_ID>.pkg`, `.driver`, `.cli` |
| `VERSION` | Marketing-Version (`CFBundleShortVersionString`, `VERSION`-Datei des Treibers, `*FileVersion` der PPDs, Paketversion) |
| `BUILD` | fortlaufende Build-Nummer (`CFBundleVersion`) – bei jeder Veröffentlichung erhöhen |
| `COPYRIGHT_YEAR` | Jahr im Copyright-Hinweis (leer = aktuelles Jahr) |
| `TEAM_ID` | Apple-Team-ID (nur für die Notarisierung mit Apple-ID und Passwort) |
| `DEVELOPER_ID_APP` | Signaturidentität für App, `lwctl` und Filter; leer = ad hoc (`-`) |
| `DEVELOPER_ID_INSTALLER` | Signaturidentität für das Paket; leer = unsigniert |

Die Datei wird nicht mit `source` ausgeführt, sondern geparst und validiert
(`Installer/lib/common.sh`). Platzhalter wie `@VERSION@` in `Installer/Info.plist`,
`InfoPlist.strings`, `distribution.xml` und den Installer-Texten ersetzen die Skripte wörtlich.

## Release

1. `VERSION` und `BUILD` in `Installer/config.env` erhöhen und committen.
2. `make test` (bzw. `make ci`) – alles grün.
3. Signierte Bausteine bauen:

   ```bash
   export DEVELOPER_ID_APP="Developer ID Application: Beispiel GmbH (ABCDE12345)"
   export DEVELOPER_ID_INSTALLER="Developer ID Installer: Beispiel GmbH (ABCDE12345)"
   make pkg                      # baut Treiber, App (Universal) und dist/LabelWerk-<Version>.pkg
   ```

4. Notarisieren und Ticket anheften: `NOTARY_KEYCHAIN_PROFILE=labelwerk make notarize`.
5. Prüfen:

   ```bash
   pkgutil --check-signature dist/LabelWerk-1.0.0.pkg
   spctl --assess --type install --verbose=2 dist/LabelWerk-1.0.0.pkg
   xcrun stapler validate dist/LabelWerk-1.0.0.pkg
   sudo installer -pkg dist/LabelWerk-1.0.0.pkg -target /     # auf einem Testrechner
   ```

6. Tag setzen (`git tag v1.0.0 && git push --tags`) und `dist/LabelWerk-<Version>.pkg` samt
   `.sha256` veröffentlichen. Das dSYM-Bündel `build/LabelWerk.app.dSYM` für die Auswertung von
   Absturzberichten aufbewahren.

### Was die Skripte tun

| Skript | Aufgabe | Wichtige Optionen |
|---|---|---|
| `Scripts/build_driver.sh` | Universal-Filter (`make -C Driver/filter universal`), PPDs (`generate_ppds.py --gzip`), Symbol, `VERSION`, `uninstall.sh` in den Aufbau von ARCHITECTURE.md §10; Rechte setzen; Filter signieren | `--output`, `--host` (Testaufbau für das eigene System, auch Linux), `--no-sign`, `--dry-run` |
| `Scripts/build_app.sh` | `swift build -c release --arch arm64 --arch x86_64` für `LabelWerk` und `lwctl`; Bundle mit `Info.plist`, `AppIcon.icns`, `*.lproj`, `Helpers/lwctl`, `Resources/Driver`; dSYM sichern, Symbole entfernen; von innen nach außen signieren | `--debug`, `--skip-driver`, `--skip-build`, `--output`, `--dry-run` |
| `Scripts/make_pkg.sh` | Komponenten App (`/Applications`, nicht verschiebbar), Treiber (`/`, mit pre-/postinstall), lwctl (ohne Nutzlast); `productbuild` mit `Installer/pkg/distribution.xml` und deutsch/englischer Oberfläche; Inhalt prüfen; SHA-256 | `--skip-build`, `--unsigned`, `--output`, `--dry-run` |
| `Scripts/notarize.sh` | `xcrun notarytool submit --wait`, bei Ablehnung Prüfprotokoll, `stapler staple`, Gatekeeper-Prüfung | `--no-staple`, `--timeout`, `--dry-run`; Dateien `.pkg`, `.dmg`, `.zip`, `.app` |
| `Scripts/uninstall.sh` | Deinstallation (wird als `/Library/Printers/LabelWerk/uninstall.sh` mitinstalliert) | `--remove-queues`, `--keep-app`, `--purge-user-data`, `--yes`, `--dry-run`, `--root` |

Alle Skripte sind Bash mit `set -euo pipefail`, ShellCheck-sauber, geben deutsche Meldungen aus und
brechen außerhalb von macOS mit einer klaren Meldung ab – außer im Probelauf (`--dry-run`), der
jeden Befehl nur anzeigt. Gemeinsame Funktionen liegen in `Installer/lib/common.sh`.

### Paketaufbau

```
LabelWerk-<Version>.pkg            productbuild-Archiv (Installer/pkg/distribution.xml)
├── LabelWerkApp.pkg               LabelWerk.app → /Applications (BundleIsRelocatable = NO)
├── LabelWerkDriver.pkg            build/driver-root → /   (Besitzer root:wheel)
│   ├── preinstall                 alte Treiberversion und LabelWerk-PPDs entfernen
│   └── postinstall                Rechte festziehen, Quarantäne entfernen, cupsd neu starten,
│                                  vorhandene LabelWerk-Warteschlangen auf neue PPDs umstellen
└── LabelWerkCLI.pkg               ohne Nutzlast; postinstall legt /usr/local/bin/lwctl an
```

Die Oberfläche (Willkommen, Hinweise, Lizenz, Abschluss, Hintergrund hell/dunkel) liegt in
`Installer/pkg/Resources/{de,en}.lproj`. `postinstall` startet `cupsd` mit
`launchctl kickstart -k system/org.cups.cupsd` neu (Rückfall: `killall -HUP cupsd`); Fehler dabei
brechen die Installation nicht ab und landen in `/var/log/install.log`.

## Signieren und Notarisieren

### Zertifikate

Benötigt werden aus dem Apple Developer Program zwei Zertifikate, beide im Anmeldeschlüsselbund:
**Developer ID Application** (App, `lwctl`, Filter) und **Developer ID Installer** (Paket).
Vorhandene Identitäten zeigt `security find-identity -v -p codesigning` bzw.
`security find-identity -v` (Installer-Zertifikate).

### Wie signiert wird

* Von innen nach außen: Filter (in `Contents/Resources/Driver` und im Treiberbaum), dann
  `Contents/Helpers/lwctl`, zuletzt die App mit `Installer/LabelWerk.entitlements` – jeweils mit
  gehärteter Laufzeitumgebung (`--options runtime`) und sicherem Zeitstempel (`--timestamp`).
  Ohne `DEVELOPER_ID_APP` wird ad hoc (`-`) signiert – lauffähig auf dem eigenen Mac, aber nicht
  zur Weitergabe geeignet.
* Die Filter bekommen eigene Kennungen (`<BUNDLE_ID>.rastertolabelwerk` …), damit sie auch
  außerhalb der App eindeutig signiert sind.
* Das Paket wird von `productbuild --sign "$DEVELOPER_ID_INSTALLER" --timestamp` signiert.

### Berechtigungen und Sandbox

`Installer/LabelWerk.entitlements`: gehärtete Laufzeitumgebung **ohne App-Sandbox**, dazu
`com.apple.security.device.usb`, `…device.bluetooth`, `…network.client` und `…network.server`.
Die App kann nicht in der Sandbox laufen, weil sie

* Warteschlangen mit `lpadmin` anlegt und den Treiber mit Administratorrechten (`osascript … with
  administrator privileges`) nach `/Library/Printers` installiert,
* USB-Drucker direkt über IOKit-Bulk-Endpunkte anspricht, auch ohne CUPS-Warteschlange,
* Netzwerkdrucker per Subnetz-Scan, SNMP und rohen TCP-Sockets (Port 9100) findet und der
  Demo-Drucker als TCP-Server lauscht.

Ausnahmen der gehärteten Laufzeit (JIT, unsignierter ausführbarer Speicher, abgeschaltete
Bibliotheksprüfung) werden nicht benötigt und sind bewusst nicht gesetzt.

### Notarisierung

Einmalig ein Schlüsselbundprofil anlegen (empfohlen):

```bash
xcrun notarytool store-credentials labelwerk --apple-id dev@example.com --team-id ABCDE12345
NOTARY_KEYCHAIN_PROFILE=labelwerk Scripts/notarize.sh dist/LabelWerk-1.0.0.pkg
```

Alternativ ein App-Store-Connect-API-Schlüssel (`NOTARY_API_KEY_PATH`, `NOTARY_API_KEY_ID`,
optional `NOTARY_API_ISSUER`) oder Apple-ID mit app-spezifischem Passwort (`NOTARY_APPLE_ID`,
`NOTARY_PASSWORD`, `TEAM_ID`). Das Skript reicht ein und wartet, zeigt bei Ablehnung das
Prüfprotokoll, heftet das Ticket an (`stapler staple`), prüft mit `spctl` und aktualisiert die
SHA-256-Datei (das Anheften verändert die Datei).

## Continuous Integration

`.github/workflows/ci.yml` ruft ausschließlich `Scripts/ci_linux.sh` und `Scripts/ci_macos.sh`
auf; jeder Workflow-Schritt entspricht einem Skriptschritt und lässt sich lokal genauso ausführen.

| Job | Auslöser | Inhalt |
|---|---|---|
| `linux` (ubuntu-24.04) | jeder Push, jeder Pull Request, manuell | Swift 6.4.2 von swift.org (zwischengespeichert), Lint, Katalog, `swift build`/`swift test`, Filtertests, PPDs + `cupstestppd`, Werkzeug-Tests, Treiberbaum und Probeläufe der macOS-Skripte; Lokalisierung als Warnschritt |
| `macos` (macos-15, neuestes stabiles Xcode) | nur manuell (`workflow_dispatch`) und bei Pushes auf `main` und `claude/**` – macOS-Minuten sind knapp | Swift-Tests inkl. App, Universal-Filter + Tests, App-Bundle (ad hoc signiert), unsigniertes Paket, Paketprüfung, Probeinstallation mit Testdruck über CUPS und Deinstallation; Artefakte: App (ZIP, dSYM) und Paket |

```bash
Scripts/ci_linux.sh                         # alle Schritte
Scripts/ci_linux.sh build test-swift        # einzelne Schritte
Scripts/ci_linux.sh --keep-going            # weitermachen und am Ende zusammenfassen
Scripts/ci_macos.sh test-driver app pkg verify-pkg
Scripts/ci_macos.sh --allow-system-changes install-test e2e-print   # installiert systemweit!
```

Der macOS-Schritt `install-test` installiert das Paket auf dem CI-Rechner, prüft Besitzer und
Rechte, legt mit unserer PPD eine Warteschlange an (`cupsd` prüft dabei Filterpfad und Rechte) und
deinstalliert am Ende des Aufrufs immer wieder. `e2e-print` druckt ein PDF über CUPS,
`cgpdftoraster` und `rastertolabelwerk` an einen lokalen TCP-„Drucker“ und prüft das empfangene ZPL;
weil das von der CUPS-Konfiguration des Rechners abhängt, ist ein Fehlschlag dort nur eine Warnung
(`--strict-e2e` macht ihn zum Fehler).

Signierte Builds in der CI sind vorbereitet, aber nicht eingerichtet: Dazu die Zertifikate als
`.p12` in Repository-Secrets ablegen, in einem eigenen Schlüsselbund importieren
(`security create-keychain`, `security import … -T /usr/bin/codesign -T /usr/bin/productbuild`)
und `DEVELOPER_ID_APP`, `DEVELOPER_ID_INSTALLER` sowie die `NOTARY_*`-Variablen setzen.

## Konventionen

* Swift 6 mit strikter Nebenläufigkeit für alle Bibliotheken, öffentliche Werttypen `Sendable`;
  die App im Swift-5-Modus. Bibliotheken nutzen nur Foundation (+ `CZlib`) und bauen auf Linux;
  Apple-spezifischer Code nur hinter `#if os(macOS)` bzw. `#if canImport(…)`.
* Bezeichner auf Englisch, Kommentare und Dokumentation auf Deutsch.
* Tests mit Swift Testing (`@Test`, `#expect`) unter `Tests/<Modul>Tests/`; Testdaten im
  Quelltext eingebettet (das Paket deklariert keine Ressourcen). Python-Werkzeuge testen mit
  `unittest` (nur Standardbibliothek), Shell-Skripte mit ShellCheck und `Scripts/tests`.
* Keine Platzhalter oder halbfertigen Funktionen im Hauptzweig.

## Häufige Probleme beim Bauen

| Meldung | Abhilfe |
|---|---|
| `error: unable to find utility "xcbuild"` / `--arch` wird nicht unterstützt | Xcode statt nur der Befehlszeilenwerkzeuge auswählen: `sudo xcode-select -s /Applications/Xcode.app` |
| `resource fork, Finder information, or similar detritus not allowed` | erweiterte Attribute entfernen: `xattr -cr build/LabelWerk.app`, erneut bauen |
| `errSecInternalComponent` beim Signieren in SSH/CI | Schlüsselbund entsperren: `security unlock-keychain …` |
| Notarisierung „Invalid“ | Prüfprotokoll lesen (das Skript zeigt es an); meist fehlt eine Signatur mit Zeitstempel oder die gehärtete Laufzeit bei einer eingebetteten Binärdatei |
| `cupstestppd` meldet Warnungen zu Adobe-Standardnamen | erwartet und unkritisch; Fehler (`FAIL`) dagegen nicht |
| Filtertests unter Linux: `cups/raster.h` fehlt | `sudo apt install libcups2-dev libcupsimage2-dev zlib1g-dev` |

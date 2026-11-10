# LabelWerk

**Der moderne macOS-Treiber und die Steuerzentrale für Zebra®-Etikettendrucker.**

LabelWerk bringt alles, was unter Windows der ZDesigner-Treiber und die Zebra Setup Utilities
können, nativ auf den Mac – und geht deutlich darüber hinaus: eine animierte SwiftUI-Oberfläche
mit Live-Status, ein Etiketten-Designer mit Echtzeit-Vorschau, ein vollwertiges Terminal,
SGD-Explorer, Firmware-, Netzwerk- und Bluetooth-Verwaltung, Sicherung und Klonen von
Druckereinstellungen, Druckkopf-Wartung, RFID-Werkzeuge, Menüleisten-Überwachung mit Mitteilungen
und ein sauber integrierter CUPS-Treiber, mit dem jedes Mac-Programm direkt auf Zebra-Druckern
druckt. Dazu kommen ein Kommandozeilenwerkzeug (`lwctl`) und ein virtueller Demo-Drucker.

> Zebra ist eine Marke der Zebra Technologies Corp. LabelWerk ist ein unabhängiges Projekt und
> steht in keiner Verbindung zu Zebra Technologies.

---

## Funktionsumfang

| Bereich | Windows (ZDesigner + Setup Utilities) | LabelWerk |
|---|---|---|
| Drucken aus jeder App | ✔ Treiber | ✔ CUPS-Treiber (`rastertolabelwerk`), Universal Binary, 116 PPDs (69 Modelle × Auflösungen plus generische ZPL-, EPL- und CPCL-PPDs), automatische Treiberzuordnung per USB-Gerätekennung |
| Druckersprachen | ZPL, EPL | **ZPL II, EPL2 und CPCL** (Mobildrucker) |
| Dialog „Druckeinstellungen für ZD421 …“ | ✔ | ✔ **gleich aufgebaut, gleiche Begriffe:** Seitenleiste mit Seite einrichten, Druckoptionen, Bedienermodus, Grafik Optionen, Kundenspezifische Befehle, Wartung, Einheiten, Hilfe und Über; „Testseite drucken“; Stift-Menü je Wert (Treiberwert oder Druckerwert, dazu „Vom Drucker lesen“); „Druckvorschau“ mit Drucker und zwei Etiketten; OK, Abbrechen, Übernehmen, Hilfe. Gespeicherte Werte gelten auch als Standard der macOS-Warteschlange; im macOS-Druckdialog stehen dieselben Gruppen unter „Druckerfunktionen“ ([Gegenüberstellung](docs/INSTALLATION.md#druckeinstellungen-wie-unter-windows)) |
| Seite einrichten | Vorlage, Breite/Höhe, Medientyp, Drehung, Markierung Versatz, Spiegeln, Invers, Bei letztem Element stoppen | ✔ alle Werte, inkl. „Etiketten mit Seitenkerben“, Drehung 0°/90°/180°/270° und Stoppversatz |
| Druckoptionen | Geschwindigkeit (mm/s), Temperatur, Druckmodus, Versatz oben/links, Rückzug, Pausieren, Steuerzeichen, RTC aktualisieren, Aufträge vor dem Drucken abbrechen | ✔ alle mit denselben Werten (51 mm/s … Modellmaximum, Temperatur 1–30, Verzögerung 1000 ms); dazu Druckersprache, Kalibrieren vor dem Auftrag, Einstellungen im Drucker speichern (`^JUS`) |
| Bedienermodus | Abreißen, Spendemodus, Abschneider, Verzögerter Abschneider, Aufwickeln, Linerless (5 Modi), Applikator; Versatz; Schneiden alle N Etiketten | ✔ alle Modi des Modells (+ Kiosk; Linerless per SGD `media.printmode`), Abreißversatz, Abschneider mit „Schneiden alle N Etiketten“ |
| Wartung, Einheiten | Auf Standardeinstellungen zurücksetzen, Alle Einstellungen des Druckers verwenden, Medien kalibrieren, Echtzeituhr (RTC) synchronisieren; Millimeter/Zoll/Punkte | ✔ alles, dazu Werte vom Drucker lesen, an den Drucker senden, dauerhaft speichern, Aktion beim Einschalten/Schließen des Druckkopfs (`^MF`), Einstellungsprofile importieren/exportieren |
| Rasterung | 3 Verfahren | **6 Verfahren** (Schwellenwert, Bayer, Halbton, Floyd–Steinberg, Atkinson, Stucki) mit Live-Vorschau |
| Grafikkompression | – | **Z64 (Deflate), ACS, Hex** – bis zu 90 % kleinere Aufträge |
| Kopien | Bild wird n-mal gesendet | **`^PQ`**: Bild einmal senden, Drucker vervielfältigt |
| Etikettenformate | Stocks | 40+ Formate (inkl. DHL/DPD/GLS), eigene Formate, „vom Drucker übernehmen“ |
| Kundenspezifische Befehle | ✔ | ✔ am Auftragsbeginn/-ende **und** je Etikett, mit Syntaxhervorhebung und Bausteinen |
| Werkzeuge: Kalibrieren, Konfigurationsetikett, Reset, Werkseinstellungen … | ✔ | ✔ + Kalibrier-Assistent, Halten-zum-Bestätigen, Testseite über den kompletten macOS-Druckweg |
| Status | Statusfenster | **Live-Übersicht** mit animiertem Drucker, Meldungen mit Lösungsschritten, Kennzahlen, Verlauf, Menüleiste, Mitteilungen |
| Kommunikation mit dem Drucker | Terminal | **Terminal** für ZPL, SGD und JSON mit Hervorhebung, Autovervollständigung, ZPL-Referenz (rund 200 Befehle), Hex-Ansicht, Dateiversand und Export |
| Einstellungs-Explorer (SGD) | – | ✔ alle Link-OS-Einstellungen durchsuchen, filtern, mit Prüfung bearbeiten und als JSON exportieren |
| Schriften & Grafiken laden | ✔ | ✔ mit Schriftvorschau, Rasterungsvorschau, Probedruck, Speicherbelegung |
| Netzwerk, WLAN & Bluetooth konfigurieren | ✔ | ✔ IPv4/DHCP, WLAN und Bluetooth mit Live-Prüfung, Änderungsübersicht und sicherem Übernehmen |
| Firmware-Update | ✔ | ✔ Dateiprüfung (Version, Modell, SHA-256), Sicherheits-Checkliste, Fortschritt mit Rate und Restzeit, Neustart-Countdown, automatisches Neuverbinden |
| Sicherung, Wiederherstellung & Klonen | separates Werkzeug (Printer Profile Manager) | ✔ komplette Druckerkonfiguration als `.lwbackup` sichern, Wert-für-Wert-Vergleich mit dem Zieldrucker, auswählen und übertragen; Klonen direkt von Drucker zu Drucker (ohne gerätespezifische Werte wie Name oder IP-Adresse) |
| Gerätesprache umstellen | – | ✔ `device.languages` (ZPL, EPL & ZPL, EPL, Zeilendruck, XML & ZPL) setzen – abgestimmt auf die Ausgabesprache von LabelWerk, damit der Drucker danach keinen Befehlstext druckt |
| Druckkopf-Wartung | – | ✔ Zählerstände, Reinigungserinnerung mit einstellbarem Intervall, Druckkopftest mit maßstäblicher Vorschau, bebilderte Reinigungsanleitung |
| RFID | – | ✔ Tags lesen (EPC, TID, Benutzerspeicher) mit Dekodierung (SGTIN-96, SSCC-96, GID-96, Chiphersteller), Tags schreiben (Serien, SGTIN-96-Generator, Prüfung durch Rücklesen, bedruckte Etiketten), `^HR`-Kalibrierung, Programmierposition, Sendeleistung, alle RFID-Einstellungen |
| Etiketten-Designer | separates Produkt | ✔ integriert: ZPL-Editor + Echtzeit-Vorschau (Vektor & pixelgenau), Vorlagen, die sich an Etikettengröße und Auflösung anpassen, Bausteine, Barcodes, Bild/PDF → Etikett mit Rasterungsvergleich |
| Auftragsverlauf | – | ✔ mit Vorschau, Statistik, „Erneut drucken“, CSV-Export |
| Verbindungen | USB, Netzwerk | **USB, Netzwerk (TCP 9100), Bluetooth, Bluetooth LE, macOS-Warteschlangen** + automatische Suche (Bonjour, USB, Subnetz-Scan, CUPS, Bluetooth) |
| Ausprobieren ohne Drucker | – | ✔ **Demo-Drucker** – vollständig simulierter ZD421t in der App; mit `lwctl virtual-printer` auch als Netzwerkdrucker |
| Kommandozeile | – | ✔ `lwctl` (macOS & Linux): Status, Drucken, Rendern, SGD, Dateien, Firmware, Terminal, virtueller Drucker |

## Die App im Überblick

Jeder Drucker hat eigene Bereiche (⌘1 … ⌘9); angezeigt werden nur die, die zum Modell und zur
Verbindung passen (z. B. RFID nur bei Modellen mit RFID-Option, Netzwerk nur mit
Netzwerkschnittstelle):

* **Übersicht** – animierter Drucker, Live-Status, Meldungen mit Lösungsschritten, Kennzahlen,
  Schnellaktionen, Identität, letzte Aufträge
* **Druckeinstellungen** – der Dialog „Druckeinstellungen für …“ wie im Windows-Treiber ZDesigner
  (gleiche Bereiche, Begriffe und Werte, Stift-Menü je Wert, Druckvorschau, OK/Abbrechen/
  Übernehmen/Hilfe); gespeicherte Werte gelten für LabelWerk und als Standard der
  macOS-Warteschlange, außerdem an den Drucker senden oder dauerhaft speichern
* **Etiketten** – eingelegtes Format, Katalog und eigene Formate, Maße vom Drucker übernehmen
* **Werkzeuge** – Gerätebefehle, Kalibrier-Assistent, Konfiguration lesen und exportieren
  (`^HH`), SGD-Explorer, Testseite über macOS
* **Terminal** – ZPL-/SGD-/JSON-Konsole mit Referenz, Bausteinen und Hex-Ansicht
* **Dateien & Schriften** – Laufwerke, Speicherbelegung, Schriften (TTF) und Grafiken hochladen
* **Netzwerk** – IPv4/DHCP, WLAN, Bluetooth
* **Sicherung & Wartung** – Sicherung, Wiederherstellen & Klonen, Druckersprache,
  Druckkopf & Wartung
* **RFID** – Status des Kodierers; Tag lesen, Tag schreiben, Einstellungen & Kalibrierung
* **Firmware** – Datei prüfen und übertragen

Dazu kommen der **Etiketten-Designer**, der **Auftragsverlauf**, **Treiber & Warteschlangen**
(Treiber installieren, aktualisieren, reparieren; macOS-Warteschlangen anlegen, synchronisieren,
entfernen; Diagnose), die **Druckersuche** mit Radar, ein **Einrichtungsassistent** für den ersten
Start, das **Menüleisten-Fenster** und Systemmitteilungen. Die Oberfläche ist auf Deutsch und
Englisch verfügbar und respektiert „Bewegung reduzieren“.

## Schnellstart

1. `LabelWerk-<version>.pkg` doppelklicken und installieren (App, Treiber-Filter und PPDs).
2. Zum Abschluss öffnet sich LabelWerk automatisch – wie ein Windows-Setup, das mit „Drucker
   einrichten“ endet. Beim ersten Start begrüßt es Sie mit dem Willkommensassistenten; dessen Seite
   **„Drucker finden“** findet angeschlossene und Netzwerk-Drucker, die Karte
   **„Netzwerkdrucker installieren“** › **„Installieren …“** öffnet den Assistenten
   **„Drucker installieren“**. Wurde LabelWerk schon einmal eingerichtet, öffnet sich dieser direkt.
3. Drucker wählen, **„Installieren“** – fertig. Ab jetzt druckt jede App (Vorschau, Pages,
   Versand-Tools …) direkt auf das Etikett.

Ohne Drucker: **Ablage › Demo-Drucker hinzufügen** legt einen simulierten ZD421t an.

### Netzwerkdrucker (LAN) installieren

Wie mit einem Windows-Treiberinstallationsprogramm: Drucker finden oder IP-Adresse eingeben, das
Modell wird erkannt, „Installieren“ – danach ist der Drucker ein normaler macOS-Drucker
(**Systemeinstellungen › Drucker & Scanner** und Druckdialog jedes Programms) mit dem
LabelWerk-Treiber. Drei Wege:

1. **Installationsassistent nach dem Paket** – LabelWerk öffnet sich nach der Installation per
   Doppelklick von selbst (nicht bei `sudo installer …`/MDM und nicht bei einem Update, wenn schon
   LabelWerk-Drucker eingerichtet sind). Beim ersten Start kommt zuerst der Willkommensassistent:
   auf seiner Seite **„Drucker finden“** › **„Netzwerkdrucker installieren“** › **„Installieren …“**;
   später öffnet sich der Assistent direkt. Er führt durch Drucker wählen → Modell → Name &
   Optionen → Installieren; fehlt der Treiber, wird er mitinstalliert.
2. **In der App:** **Ablage › Drucker installieren …** – derselbe Assistent, jederzeit für weitere
   Drucker.
3. **Kommandozeile** für IT und Softwareverteilung:

   ```bash
   lwctl install --printer tcp://192.168.1.50                 # Modell erkennen, Warteschlange anlegen
   lwctl install -p tcp://192.168.1.51 --name Versand --location "Lager" --default --test-page
   lwctl install -p tcp://192.168.1.52 --model zt410 --dpi 300 --dry-run   # ohne Verbindung, nur anzeigen

   for ip in 192.168.1.50 192.168.1.51 192.168.1.52; do           # mehrere Drucker
       lwctl install -p "tcp://$ip" || echo "Fehler: $ip" >&2
   done
   ```

Alternativ ohne App: **Systemeinstellungen › Drucker & Scanner › „+“ › IP**, Adresse eingeben,
Protokoll **„HP Jetdirect – Socket“**, unter „Verwenden“ den Treiber
**„Zebra <Modell> (<dpi> dpi) - LabelWerk“** wählen.

Ausführlich: [docs/INSTALLATION.md](docs/INSTALLATION.md#netzwerkdrucker-lan-installieren)

## Projektaufbau

```
Package.swift                 SwiftPM: Kernmodule, CLI, App (nur macOS)
Catalog/                      Modell- & Etikettenkatalog (einzige Quelle: models.json)
Sources/
  LabelWerkCore/              Typen, Katalog, ZPL/EPL/CPCL/SGD-Befehle, Testetikett
  LabelWerkImaging/           Bitmaps, Rasterung, Z64/ACS/Hex, PNG, Job-Encoder
  LabelWerkBarcode/           Code 128/39/93, EAN/UPC, ITF, Codabar, QR, DataMatrix, PDF417
  LabelWerkRender/            ZPL-Interpreter, Software-Rasterizer, Befehlsreferenz
  LabelWerkStatus/            Statusparser (~HS, ~HQES, ~HI, SGD, ^HH), Meldungen
  LabelWerkTransport/         TCP, USB, Bluetooth, BLE, CUPS, Druckersuche
  LabelWerkKit/               PrinterClient, virtueller Drucker
  lwctl/                      Kommandozeilen-Werkzeug
  LabelWerkApp/               SwiftUI-App
    App/  Model/  Services/   Einstieg, Menübefehle, Lokalisierung; Zustand & Sitzungen; CUPS, Mitteilungen
    Design/                   Theme, Motion, Komponenten des Design-Systems
    Features/                 Dashboard, Preferences, Stocks, Tools, Terminal, Files, Network,
                              Maintenance, RFID, Firmware, Designer, History, Driver, Discovery,
                              Onboarding, MenuBar, Settings, Root
Tests/                        Swift-Testing-Tests je Kernmodul (<Modul>Tests)
Driver/filter/                CUPS-Filter in C (+ Tests, Python-Referenz-Encoder)
Driver/ppd/                   PPD-Generator
Installer/                    config.env, Info.plist, Berechtigungen, Symbole, Lokalisierung (de/en), Paket
Scripts/                      Bauen, Paket, Notarisierung, Symbole, Lokalisierung, CI (+ Tests)
.github/workflows/ci.yml      Continuous Integration (Linux und macOS)
```

Architektur und Schnittstellen: [ARCHITECTURE.md](ARCHITECTURE.md) ·
App-Aufbau: [docs/APP_ARCHITECTURE.md](docs/APP_ARCHITECTURE.md) ·
Entwicklung: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)

## Bauen

```bash
make test        # Katalogprüfung, Swift-Tests, Filter-Tests (C + End-to-End), PPD-Tests, Werkzeug-Tests
make app         # LabelWerk.app (macOS, Universal Binary)
make pkg         # Installationspaket dist/LabelWerk-<version>.pkg
make strings     # Lokalisierung aus den tr("…")-Aufrufen aktualisieren
```

Voraussetzungen: macOS 14+ mit Xcode 16 oder neuer (für App & Paket); Kern, Filter und CLI bauen
auch unter Linux (Swift 6, `libcups2-dev`, `zlib1g-dev`). `make` zeigt alle Ziele.

## Kommandozeile

`lwctl` steuert Drucker ohne App – auf macOS (installiert nach `/usr/local/bin/lwctl`) und Linux.
Den Drucker wählt `--printer` (bzw. `-p` oder die Umgebungsvariable `LWCTL_PRINTER`):
`tcp://host[:port]`, `usb://vid:pid[/seriennummer]`, `cups://warteschlange` oder `virtual://demo`.

```bash
lwctl discover                                        # Drucker suchen (Bonjour, Netzwerk, USB, Bluetooth, CUPS)
lwctl install -p tcp://192.168.1.50                   # als macOS-Drucker einrichten (Modell erkennen, lpadmin)
lwctl queues --labelwerk                              # eingerichtete Warteschlangen mit LabelWerk-Treiber
lwctl uninstall-queue Zebra_ZD421t_192.168.1.50       # Warteschlange entfernen
lwctl --printer tcp://192.168.1.50 status             # Zustand, Meldungen, Zähler (--json möglich)
lwctl -p tcp://192.168.1.50 print versand.png --stock w4h6in --dither atkinson
lwctl -p tcp://192.168.1.50 send etikett.zpl          # Rohdaten unverändert senden
lwctl -p tcp://192.168.1.50 action calibrate          # Gerätefunktion (Liste: action --list)
lwctl -p tcp://192.168.1.50 getvar device.friendly_name
lwctl -p tcp://192.168.1.50 settings --filter media.  # alle SGD-Einstellungen
lwctl -p tcp://192.168.1.50 terminal                  # interaktives Terminal
lwctl render etikett.zpl -o vorschau.png              # ZPL als PNG rendern
lwctl encode logo.png -o logo.zpl --stock w2h1in      # Auftrag erzeugen, ohne zu drucken
lwctl virtual-printer --port 9100                     # Demo-Drucker im Netzwerk bereitstellen
```

Weitere Befehle: `info`, `setvar`, `do`, `config`, `network`, `files`, `delete-file`,
`upload-font`, `upload-graphic`, `firmware`, `test-label`, `models`, `stocks`, `version`.
`lwctl help <befehl>` zeigt alle Optionen. Rückgabewerte: 0 Erfolg, 1 Fehler, 2 falscher Aufruf,
3 Verbindungsfehler (bei `install`: Drucker nicht erreichbar bzw. nicht erkannt), 4 Drucker meldet
Fehler (`status`), 130 abgebrochen. `install` und `uninstall-queue` zeigen jeden ausgeführten
`lpadmin`-Befehl an; `--dry-run` zeigt ihn nur an. `install` richtet einen Drucker nie doppelt ein:
Eine LabelWerk-Warteschlange desselben Druckers wird aktualisiert (ihre Einstellungen bleiben
erhalten), eine andere Warteschlange gleichen Namens nur mit `--replace` ersetzt.

## Continuous Integration

`.github/workflows/ci.yml` ruft nur `Scripts/ci_linux.sh` und `Scripts/ci_macos.sh` auf; jeder
Schritt lässt sich lokal genauso ausführen.

* **Linux** – bei jedem Push und Pull Request: Lint, Katalog, Swift-Build und Tests je Testziel,
  CUPS-Filter (C-Unit- und End-to-End-Tests), PPDs mit `cupstestppd`, Werkzeug-Tests, Treiberbaum
  und Probeläufe der macOS-Skripte; Lokalisierung als Warnschritt.
* **macOS** – nur manuell (`workflow_dispatch`), bei Pushes auf `main` und für Versions-Tags `v*`:
  Build inkl. App, Swift-Tests, Universal-Filter, App-Bundle, Installationspaket,
  Probeinstallation mit Testdruck über CUPS; App und Paket als Artefakte.

Details: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#continuous-integration)

## Drittanbieter

Die eingebaute Bitmap-Schrift des Software-Rasterizers basiert auf DejaVu Sans (Bitstream-Vera-
Lizenz, siehe Quelltext). Es werden keine externen Swift-Pakete verwendet; der Filter nutzt
`libcups` und `zlib` des Systems.

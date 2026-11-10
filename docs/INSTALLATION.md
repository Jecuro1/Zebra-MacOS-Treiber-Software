# LabelWerk installieren, einrichten und entfernen

Diese Anleitung beschreibt die Installation des Pakets `LabelWerk-<Version>.pkg`, das Installieren
von Netzwerkdruckern wie mit einem Windows-Treiberinstallationsprogramm, das Einrichten von
Zebra-Druckern (in der App, mit `lwctl` oder in den macOS-Systemeinstellungen), das Drucken aus
beliebigen Programmen, das Entfernen und die Fehlersuche.

## Voraussetzungen

* macOS 14 Sonoma oder neuer, Apple Silicon oder Intel (das Paket enthält Universal Binaries).
* Ein Zebra-Etikettendrucker mit ZPL II, EPL2 oder CPCL, angeschlossen per USB, Netzwerk
  (TCP-Port 9100), Bluetooth oder Bluetooth LE. Die unterstützten Modelle zeigt die App bei der
  Druckersuche; in der Kommandozeile listet `lwctl models` sie auf.
* Für die Installation ein Benutzerkonto mit Administratorrechten.

## Was installiert wird

Das Paket besteht aus drei Komponenten, die sich im Installer unter „Anpassen“ einzeln abwählen
lassen:

| Komponente | Ziel | Inhalt |
|---|---|---|
| **LabelWerk-App** | `/Applications/LabelWerk.app` | Steuerzentrale (Status, Druckeinstellungen, Etikettenformate, Werkzeuge, Terminal, Dateien, Netzwerk, Sicherung & Wartung, RFID, Firmware, Designer, Auftragsverlauf); enthält zusätzlich eine Kopie des Treibers, um ihn aus der App heraus zu installieren oder zu reparieren, und `lwctl` |
| **Druckertreiber (CUPS)** | `/Library/Printers/LabelWerk/Filter/rastertolabelwerk` | CUPS-Filter: Raster → ZPL/EPL/CPCL (root:wheel, 0755) |
| | `/Library/Printers/LabelWerk/Filter/commandtolabelwerk` | Befehlsfilter (Selbsttest, Kalibrieren aus dem Druckerdienstprogramm) |
| | `/Library/Printers/LabelWerk/Icons/LabelWerk.icns` | Druckersymbol |
| | `/Library/Printers/LabelWerk/VERSION`, `ppd-index.json`, `uninstall.sh` | Treiberversion, Modellübersicht, Deinstallation |
| | `/Library/Printers/PPDs/Contents/Resources/LabelWerk-<Modell>-<dpi>dpi.ppd.gz` | eine PPD-Datei je Modell und Auflösung |
| **Kommandozeilenwerkzeug** | `/usr/local/bin/lwctl` | symbolischer Link auf `LabelWerk.app/Contents/Helpers/lwctl` (setzt die App voraus; eine vorhandene fremde Datei wird nicht überschrieben) |

Nach der Installation des Treibers wird der Druckdienst `cupsd` neu gestartet, damit Filter und
PPD-Dateien sofort bekannt sind. Dabei werden keine anderen Druckertreiber und keine Ordner-Rechte
von `/Library/Printers` verändert.

## Installation

### Mit dem Installationsprogramm

1. `LabelWerk-<Version>.pkg` doppelklicken.
2. Einführung, wichtige Hinweise und Lizenz bestätigen.
3. Optional unter „Anpassen“ Komponenten abwählen (z. B. nur den Treiber für einen Druckserver).
4. „Installieren“ wählen und mit dem Administratorpasswort bestätigen.
5. Zum Abschluss öffnet sich LabelWerk automatisch – wie ein Windows-Setup, das mit „Drucker
   einrichten“ endet: beim ersten Start mit dem Willkommensassistenten, sonst direkt mit dem
   Einrichtungsassistenten „Drucker installieren“ (nicht bei einem Update). Weiter unter
   [Netzwerkdrucker (LAN) installieren](#netzwerkdrucker-lan-installieren).

### Im Terminal (z. B. für Softwareverteilung/MDM)

```bash
shasum -a 256 -c LabelWerk-1.0.0.pkg.sha256          # Prüfsumme kontrollieren
pkgutil --check-signature LabelWerk-1.0.0.pkg         # Signatur anzeigen
sudo installer -pkg LabelWerk-1.0.0.pkg -target /
```

Bei einer Installation über die Kommandozeile öffnet sich kein Fenster (`installer` setzt
`COMMAND_LINE_INSTALL`, das Paket startet die App dann nicht). Netzwerkdrucker richtet
anschließend `lwctl install` ein – siehe
[Kommandozeile: `lwctl install`](#3-kommandozeile-lwctl-install).

Installierte Version abfragen:

```bash
cat /Library/Printers/LabelWerk/VERSION
pkgutil --pkg-info com.labelwerk.app.driver
```

### Gatekeeper

Veröffentlichte Pakete sind mit einer *Developer ID* signiert und von Apple notarisiert; macOS
installiert sie ohne Rückfrage. Entwicklungs- und CI-Builds sind dagegen **unsigniert** bzw. nur
*ad hoc* signiert. macOS meldet dann „‚LabelWerk-….pkg‘ kann nicht geöffnet werden, da Apple nicht
überprüfen kann, ob es frei von Schadsoftware ist“. Nur bei Paketen aus vertrauenswürdiger Quelle:

* **Systemeinstellungen › Datenschutz & Sicherheit** öffnen, im Abschnitt „Sicherheit“ bei der
  Meldung zum Paket **„Dennoch öffnen“** wählen und mit dem Passwort bestätigen (ab macOS 15 ist
  das der einzige Weg; das frühere „Rechtsklick › Öffnen“ genügt nicht mehr), oder
* im Terminal installieren (`sudo installer -pkg …`) – das Installationsprogramm prüft dabei nicht
  über Gatekeeper.

Ob ein Paket bzw. die App die Prüfung besteht, zeigen:

```bash
spctl --assess --type install --verbose=2 LabelWerk-1.0.0.pkg
spctl --assess --type execute --verbose=2 /Applications/LabelWerk.app
xcrun stapler validate LabelWerk-1.0.0.pkg            # angeheftetes Notarisierungsticket
```

### Aktualisieren

Einfach das neuere Paket installieren. Vor der Installation entfernt das Paket die alte
Treiberversion vollständig (auch PPDs inzwischen entfallener Modelle). Bereits eingerichtete
LabelWerk-Warteschlangen bleiben erhalten und werden anschließend automatisch auf die neuen
PPD-Dateien umgestellt; die gewählten Standardoptionen (Schwärzung, Geschwindigkeit,
Etikettenformat …) übernimmt das Paket dabei aus der bisherigen PPD der Warteschlange. Nur ein
Wert, den die neue Treiberversion nicht mehr anbietet, fällt auf deren Standard zurück.

Unter **Treiber & Warteschlangen** zeigt die App, ob der installierte Treiber zur App passt, und
bietet **„Auf <Version> aktualisieren“** bzw. **„Erneut installieren“** (repariert Dateien und
Rechte) an. Ist bereits ein *neuerer* Treiber installiert als der, den die App mitbringt (etwa nach
einem Paket einer neueren LabelWerk-Version), ersetzt LabelWerk ihn nur nach ausdrücklicher
Bestätigung durch die ältere Version – besser ist es dann, die App zu aktualisieren.

## Netzwerkdrucker (LAN) installieren

So einfach wie unter Windows mit dem Installationsprogramm des Druckertreibers: Drucker finden oder
Adresse eingeben, das Modell wird erkannt, **„Installieren“** – danach ist der Zebra-Drucker ein
normaler macOS-Drucker. Er erscheint unter **Systemeinstellungen › Drucker & Scanner** und im
Druckdialog jedes Programms und druckt über den LabelWerk-Treiber (Treiber
„Zebra <Modell> (<dpi> dpi) - LabelWerk“, Verbindung `socket://<Adresse>:9100`).

Voraussetzungen: Der Drucker ist eingeschaltet, im selben Netz wie der Mac (oder über einen Router
erreichbar) und nimmt Aufträge auf dem RAW-Port 9100 an – bei Zebra-Druckern mit
Netzwerkschnittstelle die Werkseinstellung. Die IP-Adresse zeigt das Display bzw. Menü des
Druckers oder sein Konfigurationsetikett (Tastenkombination je nach Modell, siehe Handbuch); die
Suche in LabelWerk findet den Drucker meist auch ohne sie.

Es gibt drei gleichwertige Wege – alle legen eine macOS-Warteschlange mit dem LabelWerk-Treiber an:

### 1. Installationsassistent nach dem Paket

Nach einer Installation per Doppelklick auf das Paket öffnet sich LabelWerk automatisch:

* **Beim ersten Start** begrüßt LabelWerk Sie mit dem Willkommensassistenten (Treiber, Drucker,
  Mitteilungen). Auf seiner Seite **„Drucker finden“** öffnet die Karte **„Netzwerkdrucker
  installieren“** mit **„Installieren …“** den Einrichtungsassistenten **„Drucker installieren“**.
* **Wurde LabelWerk schon einmal eingerichtet** (Willkommensassistent abgeschlossen), öffnet sich
  direkt der Einrichtungsassistent **„Drucker installieren“**.

Der Einrichtungsassistent hat vier Schritte:

1. **Drucker wählen** – LabelWerk sucht im Netzwerk (Bonjour und Netzwerk-Scan). Ist der Drucker
   nicht dabei, seine IP-Adresse oder seinen Hostnamen eingeben (Port 9100).
2. **Modell** – LabelWerk fragt den Drucker ab und ordnet Modell, Auflösung und Druckersprache zu;
   bei Bedarf lässt sich das Modell von Hand wählen.
3. **Name & Optionen** – Name und Standort, wie sie in macOS erscheinen, Etikettenformat,
   optional als Standarddrucker und mit Testseite.
4. **Installieren** – LabelWerk legt die macOS-Warteschlange an. Fehlt der Treiber noch, wird er
   mitinstalliert (Administratorpasswort).

LabelWerk öffnet sich **nicht** bei einer Installation im Terminal oder per Softwareverteilung
bzw. MDM (`installer` setzt `COMMAND_LINE_INSTALL`), bei einem **Update** (sobald eine
macOS-Warteschlange mit dem LabelWerk-Treiber eingerichtet ist – die vorhandenen Drucker werden dann
nur auf den neuen Treiber umgestellt, ihre Einstellungen bleiben), wenn niemand am Bildschirm
angemeldet ist, wenn die Komponente „Druckertreiber“ abgewählt wurde oder bei einer Installation
auf ein anderes Volume. Den Grund vermerkt `/var/log/install.log` (Zeilen „LabelWerk postinstall:
…“). Von Hand öffnen: Weg 2 oder `open -a LabelWerk --args --setup`.

### 2. In der App: „Drucker installieren …“

Jederzeit später, etwa für weitere Drucker: LabelWerk öffnen und **Ablage › Drucker
installieren …** wählen – es folgen dieselben vier Schritte. Ein Netzwerkdrucker, der in LabelWerk
schon angelegt ist, wird unter **Treiber & Warteschlangen** mit **„Einrichten“** zum macOS-Drucker;
beim Hinzufügen eines Druckers erledigt das die Option **„Auch als macOS-Drucker installieren“**.

### 3. Kommandozeile: `lwctl install`

Für IT, Skripte und Softwareverteilung (MDM, Jamf, Munki …) – ohne Fenster und ohne Rückfrage:

```bash
lwctl install --printer tcp://192.168.1.50                      # Modell erkennen, Warteschlange anlegen
lwctl install -p tcp://192.168.1.51 --name Versand --location "Lager, Tor 3" \
    --stock w4h6in --default --test-page
lwctl install -p tcp://etiketten-3.local --model zt410 --dpi 300 --dry-run   # nur anzeigen
lwctl queues --labelwerk                                        # eingerichtete LabelWerk-Drucker
lwctl uninstall-queue Versand                                   # Warteschlange wieder entfernen
```

`lwctl install` verbindet sich mit dem Drucker, erkennt Modell, Auflösung und Druckersprache, wählt
die PPD `LabelWerk-<Modell>-<dpi>dpi.ppd.gz` (gibt es keine passende, wie in der App eine generische
PPD `LabelWerk-generic-<Sprache>-<dpi>dpi`) und ruft `lpadmin` auf. Jeder ausgeführte Befehl wird
angezeigt; `--dry-run` zeigt ihn nur an:

```text
$ /usr/sbin/lpadmin -p Zebra_ZD421t_192.168.1.50 -E -v socket://192.168.1.50:9100 -P /Library/Printers/PPDs/Contents/Resources/LabelWerk-zd421t-203dpi.ppd.gz -D 'Zebra ZD421t (192.168.1.50)' -o printer-is-shared=false
```

| Option | Bedeutung |
|---|---|
| `-p`, `--printer tcp://HOST[:PORT]` | Drucker (Port Standard 9100); alternativ die Umgebungsvariable `LWCTL_PRINTER` |
| `-m`, `--model auto\|<id>\|generic` | `auto` (Standard): vom Drucker erkennen. `<id>` aus `lwctl models`: ohne Verbindung einrichten (ausgeschalteter Drucker, Vorbereiten vieler Macs). `generic`: generische PPD |
| `--dpi 152\|203\|300\|600` | Auflösung (Standard: vom Drucker bzw. vom Modell) |
| `-l`, `--language zpl\|epl\|cpcl` | Druckersprache als Standard der Warteschlange (Standard: die des Modells) |
| `-n`, `--name NAME` | Name der Warteschlange (Standard: `Zebra_<Modell>_<Adresse>`); erscheint auch als Beschreibung. Eine vorhandene LabelWerk-Warteschlange desselben Druckers wird aktualisiert, andere nur mit `--replace` |
| `--replace` | vorhandene Warteschlange gleichen Namens ersetzen, auch wenn sie einen anderen Treiber oder ein anderes Gerät verwendet |
| `--location TEXT` | Standort |
| `-s`, `--stock ID` | Etikettenformat als Standard-Papiergröße; muss auf den Drucker passen (`lwctl stocks --model <id>`) |
| `--default` | als Standarddrucker festlegen |
| `--test-page` | danach eine Testseite über die neue Warteschlange drucken |
| `--ppd-dir DIR` | anderer PPD-Ordner (Standard: `/Library/Printers/PPDs/Contents/Resources`, unter Linux `/usr/share/ppd/labelwerk`) |
| `--dry-run` | nur anzeigen, nichts einrichten |
| `--json` | Ergebnis als JSON (Warteschlange, Modell, PPD, ausgeführte Befehle, vorhandene Warteschlange und beibehaltene Einstellungen, Hinweise) |

**Vorhandene Warteschlangen.** `lwctl install` prüft vorher – auch mit `--dry-run` –, welche
Warteschlangen es schon gibt (CUPS unterscheidet bei Namen keine Groß-/Kleinschreibung):

* Druckt schon eine LabelWerk-Warteschlange auf denselben Drucker (gleiche Adresse und gleicher
  Port), wird sie aktualisiert – ohne `--name` auch unter ihrem bisherigen Namen, etwa wenn der
  Drucker zuvor mit dem Assistenten der App eingerichtet wurde. So erscheint derselbe Drucker nie
  zweimal im Druckdialog; ein erneuter Lauf derselben Liste ist ungefährlich.
* Beim Aktualisieren bleiben die Einstellungen der Warteschlange erhalten: alle Standardwerte, die
  in LabelWerk oder unter **„Optionen & Zubehör“** gewählt wurden (Schwärzung, Geschwindigkeit,
  Etikettenformat, Medientyp, Druckmodus, Versatz …), Standort, Beschreibung und Freigabe. Neu
  gesetzt werden nur die Werte dieses Aufrufs (`--stock`, `--language`, `--location`, `--name`) und
  die Auflösung der gewählten PPD. Die veraltete Option `lwRotate180=True` älterer PPDs wird dabei
  (wie beim Update per Installationspaket) als `lwRotation=180` übernommen.
* Eine Warteschlange gleichen Namens, die einen anderen Treiber verwendet oder auf ein anderes Gerät
  druckt (etwa ein Bürodrucker „Versand“), wird **nicht** angetastet: `lwctl install` bricht mit
  Rückgabewert 1 ab. Einen anderen Namen wählen oder sie mit `--replace` bewusst ersetzen.

**Auflösung und Sprache.** Gibt es für die gewünschte Kombination keine PPD (etwa für einen
EPL-Drucker mit 300 dpi, der nicht im Modellkatalog steht – generische EPL-PPDs gibt es nur mit
203 dpi), nimmt `lwctl install` wie die App die nächstliegende generische PPD und meldet das als
Hinweis (Etiketten mit falscher Auflösung werden falsch skaliert gedruckt). Mit `--dpi` bzw. `--language`
ausdrücklich gewählte Werte werden dagegen nie ersetzt – dann endet der Aufruf mit einem Fehler.

Rückgabewerte: 0 eingerichtet, 1 Fehler (keine passende PPD, Warteschlange gleichen Namens
vorhanden, `lpadmin` fehlgeschlagen), 2 falscher Aufruf (ungültige Adresse, unbekanntes Modell,
Etikettenformat passt nicht auf den Drucker …), 3 Drucker nicht erreichbar bzw. nicht erkannt. Auf macOS genügt ein Administratorkonto; als Standardbenutzer (und unter Linux ohne
Mitgliedschaft in der Gruppe `lpadmin`) mit `sudo` ausführen. `lwctl queues` listet alle
Warteschlangen und markiert die mit LabelWerk-Treiber; `lwctl uninstall-queue` entfernt nur solche
(andere mit `--force`).

Mehrere Drucker in einem Durchgang, z. B. aus einer Liste mit Adresse, Name und Standort:

```bash
#!/bin/bash
# drucker.txt – je Zeile: Adresse Name Standort
#   192.168.1.50  Versand-1  Lager Tor 1
#   192.168.1.51  Versand-2  Lager Tor 2
while read -r ip name location; do
    [[ -z "$ip" || "$ip" == \#* ]] && continue
    lwctl install --printer "tcp://$ip" --name "$name" --location "$location" --stock w4h6in \
        || echo "Fehler bei $ip ($name)" >&2
done < drucker.txt
```

Oder kurz für eine Reihe von Adressen (Namen automatisch, Ergebnis je Drucker als JSON):

```bash
for ip in 192.168.1.50 192.168.1.51 192.168.1.52; do
    lwctl install -p "tcp://$ip" --json > "lwctl-install-$ip.json" || echo "Fehler: $ip" >&2
done
```

### Alternative: macOS-Systemeinstellungen

Ohne LabelWerk-App, nur mit dem installierten Treiber:

1. **Systemeinstellungen › Drucker & Scanner › „Drucker, Scanner oder Fax hinzufügen …“** („+“).
2. Reiter **„IP“** wählen und bei **Adresse** die IP-Adresse oder den Hostnamen eingeben.
3. **Protokoll:** **„HP Jetdirect – Socket“** (Port 9100). **Warteschlange** leer lassen, **Name**
   und **Standort** nach Wunsch.
4. **Verwenden:** „Software auswählen …“ und den Treiber **„Zebra <Modell> (<dpi> dpi) -
   LabelWerk“** wählen, z. B. „Zebra ZD421t (203 dpi) - LabelWerk“ (Suchbegriff „LabelWerk“).
5. **„Hinzufügen“**. Sprache, Medientyp und Druckmodus lassen sich danach unter **„Optionen &
   Zubehör“** ändern; **„Dienstprogramm öffnen“** startet LabelWerk.

Per Bonjour gefundene Zebra-Drucker (Reiter „Standard“) funktionieren ebenso, sofern unter
„Verwenden“ der LabelWerk-Treiber gewählt wird – nicht „AirPrint“ oder „Generischer
PostScript-Drucker“.

## Drucker einrichten

### In der App (empfohlen)

1. LabelWerk öffnen. Beim ersten Start sucht der Einrichtungsassistent gleichzeitig per Bonjour,
   USB, Netzwerk-Scan, in den vorhandenen macOS-Warteschlangen und – nach Freigabe – per Bluetooth.
   Später geht das jederzeit mit **Ablage › Drucker hinzufügen …** (⇧⌘N); **Ablage ›
   Demo-Drucker hinzufügen** legt einen simulierten ZD421t zum Ausprobieren an.
2. Den gefundenen Drucker mit **„Hinzufügen“** übernehmen. Modell, Auflösung und Druckersprache
   werden automatisch zugeordnet und beim Verbinden überprüft. Netzwerk-, USB- und
   Bluetooth-Drucker lassen sich auch manuell anlegen (IP-Adresse und Port 9100, USB-Gerät,
   Bluetooth-Adresse). Netzwerkgeräte mit offenem Port 9100, die sich bei der Suche weder per
   SNMP noch per `~HI` als Zebra-Drucker zu erkennen geben, sind mit **„Nicht als Zebra-Drucker
   erkannt“** markiert und lassen sich erst nach Bestätigung (**„Trotzdem hinzufügen“**)
   übernehmen: LabelWerk fragt den Status regelmäßig ab, und ein Büro- oder Tintenstrahldrucker
   würde diese Abfragen als Seiten voller Steuerzeichen drucken.
3. Unter **„Treiber & Warteschlangen“** den Treiber installieren, falls noch nicht geschehen, und
   beim Drucker **„Einrichten“** wählen. LabelWerk legt eine macOS-Warteschlange mit der passenden
   PPD-Datei und den Druckeinstellungen des Druckers an. Danach erscheint der Drucker in jedem
   Druckdialog.
4. Änderungen an den Druckeinstellungen in LabelWerk überträgt **„Einstellungen synchronisieren“**
   als Standard in die Warteschlange.

Ohne Warteschlange druckt und steuert LabelWerk den Drucker direkt (Testetiketten, Designer,
Werkzeuge, Terminal, Dateien, Netzwerk, Sicherung & Wartung, RFID, Firmware) – die Warteschlange
wird nur für das Drucken aus anderen Programmen benötigt. Umgekehrt lässt sich auch eine
vorhandene macOS-Warteschlange als Drucker in LabelWerk übernehmen; über sie kann LabelWerk
allerdings nur senden und keine Antworten lesen. Status, Dateien, Netzwerk, Sicherung & Wartung,
RFID und Firmware-Updates benötigen deshalb eine direkte Verbindung (USB, Netzwerk oder
Bluetooth).

### In den macOS-Systemeinstellungen

1. **Systemeinstellungen › Drucker & Scanner › „Drucker, Scanner oder Fax hinzufügen …“** öffnen.
2. **USB:** Der Drucker erscheint in der Liste. macOS wählt anhand der Gerätekennung (IEEE 1284)
   automatisch „Zebra <Modell> (<dpi> dpi) - LabelWerk“. Bei Modellen mit mehreren Varianten (z. B.
   ZD421d/t/c) unter „Verwenden“ die genaue Variante auswählen.
3. **Netzwerk:** Reiter „IP“ wählen, Adresse des Druckers eingeben, Protokoll
   **„HP Jetdirect – Socket“** (Port 9100), dann unter „Verwenden“ → „Software auswählen …“ das
   passende Modell „Zebra … - LabelWerk“ wählen – Schritt für Schritt unter
   [Netzwerkdrucker (LAN) installieren](#alternative-macos-systemeinstellungen).
4. Die Druckeroptionen (Druckersprache, Medientyp, Druckmodus …) lassen sich nachträglich unter
   **„Optionen & Zubehör“** ändern; **„Dienstprogramm öffnen“** startet LabelWerk.

### Im Terminal

Netzwerkdrucker richtet am einfachsten `lwctl install` ein (Modell, PPD und `lpadmin`-Aufruf
automatisch, siehe [oben](#3-kommandozeile-lwctl-install)). Von Hand mit `lpadmin`:

```bash
lpinfo -v | grep -i zebra                              # USB-Geräteadresse ermitteln
sudo lpadmin -p Versand -E \
    -v socket://192.168.1.50:9100 \
    -P /Library/Printers/PPDs/Contents/Resources/LabelWerk-zd421t-203dpi.ppd.gz \
    -o lwDarkness=20 -o lwSpeed=4 -o lwMediaTracking=Gap
lpoptions -p Versand -l                                # alle LabelWerk-Optionen anzeigen
```

`lpadmin` weist darauf hin, dass PPD-Treiber in CUPS als veraltet gelten; das ist nur ein Hinweis –
macOS unterstützt PPD-Treiber weiterhin vollständig.

## Drucken aus anderen Programmen

* **Papiergröße = Etikett:** Im Druckdialog als Papiergröße das eingelegte Etikettenformat wählen
  (z. B. „4 × 6 Zoll“ oder „100 × 150 mm“).
* **Skalierung 100 %** statt „An Seite anpassen“ – nur so werden Barcodes maßhaltig und scannbar.
* Weitere Einstellungen stehen im Druckdialog unter **„Druckerfunktionen“** und gelten nur für
  diesen Auftrag. Im Terminal:

```bash
lp -d Versand -o lwDarkness=25 etikett.pdf                    # PDF über den Treiber
lp -d Versand -n 10 -o lwDither=Atkinson foto.png             # 10 Kopien (der Drucker vervielfältigt per ^PQ)
lp -d Versand -o raw etikett.zpl                              # fertiges ZPL ohne Treiber senden
```

Die wichtigsten Optionen (vollständig in ARCHITECTURE.md §9):

| Option | Werte | Wirkung |
|---|---|---|
| `lwLanguage` | `ZPL`, `EPL`, `CPCL` | Druckersprache |
| `lwDarkness` | `Default`, `0` … `30` | Schwärzung (`~SD`) |
| `lwSpeed` | `Default`, `1` … `14` | Geschwindigkeit in Zoll/s (`^PR`) |
| `lwMediaType` | `Default`, `DirectThermal`, `ThermalTransfer` | Druckverfahren (`^MT`) |
| `lwMediaTracking` | `Default`, `Gap`, `BlackMark`, `Continuous`, `Auto` | Etikettenerkennung (`^MN`) |
| `lwPrintMode` | `Default`, `TearOff`, `PeelOff`, `Cutter`, … | Verhalten nach dem Druck (`^MM`) |
| `lwLabelTop`, `lwLabelLeft`, `lwTearOff` | Punkte | Position und Abreißkante (`^LT`, `^LS`, `~TA`) |
| `lwDither` | `Threshold`, `Ordered`, `Halftone`, `FloydSteinberg`, `Atkinson`, `Stucki` | Rasterverfahren |
| `lwCompression` | `Z64`, `ACS`, `Hex` | Grafikkompression |
| `lwMirror`, `lwNegative`, `lwSkipBlank` | `True`, `False` | Bildbearbeitung |
| `lwRotation` | `0`, `90`, `180`, `270` | Drehung im Uhrzeigersinn (ersetzt das veraltete `lwRotate180`) |

`Default` bedeutet: Der Drucker behält seinen eigenen Wert.

## Entfernen

### In der App

**Treiber & Warteschlangen › „Entfernen …“** – auf Wunsch zusammen mit allen Warteschlangen, die
den Treiber verwenden. Die App selbst kann danach in den Papierkorb bewegt werden.

### Im Terminal

```bash
sudo bash /Library/Printers/LabelWerk/uninstall.sh --dry-run          # nur anzeigen
sudo bash /Library/Printers/LabelWerk/uninstall.sh                    # Treiber, App, lwctl-Link
sudo bash /Library/Printers/LabelWerk/uninstall.sh --remove-queues    # zusätzlich Warteschlangen
```

| Option | Bedeutung |
|---|---|
| `--remove-queues` | auch alle Warteschlangen entfernen, die LabelWerk-PPDs verwenden (ohne die Option bleiben sie bestehen, drucken aber nicht mehr) |
| `--keep-app` | die App (samt `lwctl`-Link in `/usr/local/bin`) behalten und nur den Treiber entfernen |
| `--purge-user-data` | zusätzlich Einstellungen und Daten des Benutzers löschen (`~/Library/Application Support/LabelWerk`, Einstellungen, Caches) |
| `-y`, `--yes` | ohne Rückfrage |
| `-n`, `--dry-run` | nur anzeigen, was entfernt würde |
| `--no-restart` | `cupsd` danach nicht neu starten |

Das Skript liegt auch im Quelltext unter `Scripts/uninstall.sh` und arbeitet eigenständig.

### Von Hand

```bash
sudo rm -rf /Library/Printers/LabelWerk /Applications/LabelWerk.app
sudo rm -f /Library/Printers/PPDs/Contents/Resources/LabelWerk-*.ppd.gz /usr/local/bin/lwctl
sudo pkgutil --forget com.labelwerk.app.pkg; sudo pkgutil --forget com.labelwerk.app.driver
sudo launchctl kickstart -k system/org.cups.cupsd
```

## Fehlerbehebung

### Schnellcheck

Die App prüft unter **Treiber & Warteschlangen › Diagnose** Filter, PPD-Dateien, Treiberversion
und Druckdienst. **Werkzeuge › „Testseite über macOS drucken“** sendet eine Testseite über den
kompletten Druckweg (CUPS → LabelWerk-Filter → Drucker).

```bash
lpstat -t                                    # Druckdienst, Warteschlangen, Aufträge
lpstat -l -o Versand                         # offene Aufträge mit Zustand/Fehlermeldung
lpstat -W all -l -o Versand                  # auch abgebrochene und abgeschlossene Aufträge
cupsenable Versand && cupsaccept Versand     # angehaltene Warteschlange wieder aktivieren
```

### „Filter failed“ oder „… has insecure permissions“

CUPS startet einen Filter nur, wenn er `root:wheel` gehört und weder für die Gruppe noch für andere
schreibbar ist. So prüfen und reparieren:

```bash
ls -l /Library/Printers/LabelWerk/Filter
# erwartet: -rwxr-xr-x  1 root  wheel  …  rastertolabelwerk / commandtolabelwerk
sudo chown -R root:wheel /Library/Printers/LabelWerk
sudo chmod 755 /Library/Printers/LabelWerk/Filter/*
sudo xattr -dr com.apple.quarantine /Library/Printers/LabelWerk
sudo launchctl kickstart -k system/org.cups.cupsd
```

Alternativ das Paket erneut installieren oder in der App **„Erneut installieren“** wählen – beides
setzt Besitzer und Rechte neu.

### Protokolle des Druckdienstes

```bash
sudo cupsctl --debug-logging                             # ausführliche Protokolle einschalten
sudo tail -f /var/log/cups/error_log                     # Meldungen von cupsd und den Filtern
log stream --style compact --predicate \
    'process == "cupsd" OR process BEGINSWITH "rastertolabelwerk" OR process == "cgpdftoraster"'
sudo cupsctl --no-debug-logging                          # danach wieder ausschalten
```

Der Filter meldet sich mit Zeilen wie `INFO: …` (Fortschritt), `DEBUG: …` (wirksame Einstellungen,
Seitenformat), `WARNING: …` (übergangene Werte) und `ERROR: …` (Abbruchgrund). Zum Kontrollieren
von Etiketten ohne Drucker zeigt die App im **Auftragsverlauf** jeden eigenen Auftrag mit
Vorschau; `lwctl render etikett.zpl -o vorschau.png` wandelt ZPL in ein PNG um, und der
**Demo-Drucker** der App simuliert einen kompletten ZD421t.

### Etiketten falsch positioniert, leere Etiketten dazwischen

* Papiergröße im Druckdialog prüfen – sie muss dem eingelegten Etikett entsprechen.
* Drucker kalibrieren: App › Werkzeuge › **Kalibrier-Assistent** (oder `~JC`).
* Etikettenerkennung (`lwMediaTracking`) an das Material anpassen: Lücke, schwarze Markierung oder
  Endlosmaterial.
* Feinjustage über `lwLabelTop`/`lwLabelLeft` (Druckpunkte) bzw. in der App unter
  **Druckeinstellungen › Position**.

### Druck zu blass, zu dunkel oder Barcodes unlesbar

* Schwärzung (`lwDarkness`) anpassen; bei Thermotransfer passend zum Farbband.
* Geschwindigkeit (`lwSpeed`) reduzieren – langsamer druckt sauberer.
* Für Text, Linien und Barcodes das Rasterverfahren **Schwellenwert** verwenden, für Fotos
  Floyd–Steinberg, Atkinson oder Stucki.
* Skalierung im Druckdialog auf 100 % stellen.

### Drucker wird nicht gefunden

* **Netzwerk:** Mac und Drucker im selben Netz? Port 9100 erreichbar (`nc -vz 192.168.1.50 9100`)?
  LabelWerk benötigt die Freigabe unter **Systemeinstellungen › Datenschutz & Sicherheit › Lokales
  Netzwerk**.
* **USB:** Kabel direkt (ohne Hub) anschließen; `system_profiler SPUSBDataType | grep -A6 -i zebra`
  bzw. `lpinfo -v` zeigt, ob macOS das Gerät sieht. Meldet die App beim Einrichten der
  Warteschlange, dass sich ein USB-Drucker keinem Gerät eindeutig zuordnen lässt, sind mehrere
  Zebra-Drucker angeschlossen, die sich weder über die Seriennummer noch über das Modell
  unterscheiden lassen: nur den gewünschten Drucker anschließen und erneut einrichten.
* **Bluetooth:** Bluetooth am Drucker aktivieren und sichtbar machen; LabelWerk benötigt die
  Freigabe unter **Datenschutz & Sicherheit › Bluetooth**.

### Warum läuft die App ohne App-Sandbox?

LabelWerk ist mit gehärteter Laufzeitumgebung signiert und notarisiert, aber bewusst nicht
„sandboxed“: Das Einrichten von Warteschlangen (`lpadmin`) und das Installieren des Treibers nach
`/Library/Printers` erfordern Administratorrechte und Zugriff auf den Druckdienst, USB-Drucker
werden direkt über IOKit angesprochen, und Netzwerkdrucker über rohe TCP-Verbindungen (Port 9100)
und einen Subnetz-Scan gefunden – all das ist in der App-Sandbox nicht möglich. Die App fordert nur
die Berechtigungen an, die sie tatsächlich nutzt (USB, Bluetooth, Netzwerk).

### Angaben für eine Fehlermeldung

```bash
sw_vers; cat /Library/Printers/LabelWerk/VERSION; lwctl version
lpstat -l -p; lpoptions -p <Warteschlange> -l
sudo tail -n 200 /var/log/cups/error_log
```

# LabelWerk installieren, einrichten und entfernen

Diese Anleitung beschreibt die Installation des Pakets `LabelWerk-<Version>.pkg`, das Einrichten
von Zebra-Druckern (in der App oder in den macOS-Systemeinstellungen), das Drucken aus beliebigen
Programmen, das Entfernen und die Fehlersuche.

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
5. Zum Abschluss LabelWerk aus dem Ordner „Programme“ öffnen – der Einrichtungsassistent
   übernimmt den Rest.

### Im Terminal (z. B. für Softwareverteilung/MDM)

```bash
shasum -a 256 -c LabelWerk-1.0.0.pkg.sha256          # Prüfsumme kontrollieren
pkgutil --check-signature LabelWerk-1.0.0.pkg         # Signatur anzeigen
sudo installer -pkg LabelWerk-1.0.0.pkg -target /
```

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
Etikettenformat …) bleiben dabei bestehen.

Unter **Treiber & Warteschlangen** zeigt die App, ob der installierte Treiber zur App passt, und
bietet **„Auf <Version> aktualisieren“** bzw. **„Erneut installieren“** (repariert Dateien und
Rechte) an. Ist bereits ein *neuerer* Treiber installiert als der, den die App mitbringt (etwa nach
einem Paket einer neueren LabelWerk-Version), ersetzt LabelWerk ihn nur nach ausdrücklicher
Bestätigung durch die ältere Version – besser ist es dann, die App zu aktualisieren.

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
   passende Modell „Zebra … - LabelWerk“ wählen. Von Bonjour gefundene Drucker funktionieren
   ebenso, sofern dort die LabelWerk-PPD ausgewählt wird.
4. Die Druckeroptionen (Druckersprache, Medientyp, Druckmodus …) lassen sich nachträglich unter
   **„Optionen & Zubehör“** ändern; **„Dienstprogramm öffnen“** startet LabelWerk.

### Im Terminal

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
| `lwMirror`, `lwNegative`, `lwRotate180`, `lwSkipBlank` | `True`, `False` | Bildbearbeitung |

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
lpstat -l -o Versand                         # Aufträge mit Zustand/Fehlermeldung
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

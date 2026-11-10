# PPD-Generator (`Driver/ppd`)

`generate_ppds.py` erzeugt aus `Catalog/models.json` – der einzigen Quelle für Modelle und
Etikettenformate – die PPD-Dateien des LabelWerk-CUPS-Treibers:

* je Druckermodell **und** Auflösung eine PPD `LabelWerk-<id>-<dpi>dpi.ppd` (bzw. `.ppd.gz`),
* fünf generische PPDs für Drucker, die (noch) nicht im Katalog stehen:
  `LabelWerk-generic-zpl-203dpi`, `…-zpl-300dpi`, `…-zpl-600dpi`, `LabelWerk-generic-epl-203dpi`,
  `LabelWerk-generic-cpcl-203dpi`,
* ein Verzeichnis `index.json` aller erzeugten Dateien.

Verbindlich sind [ARCHITECTURE.md](../../ARCHITECTURE.md) §9 (CUPS-Optionen `lw*`) und §10
(Filter, Farbraum, Installationspfade). Das Skript braucht nur die Python-3-Standardbibliothek
(ab Python 3.7; die macOS Command Line Tools genügen).

## Aufruf

```bash
python3 Driver/ppd/generate_ppds.py                    # alle PPDs nach Driver/ppd/out
python3 Driver/ppd/generate_ppds.py --gzip --check     # .ppd.gz + Prüfung mit cupstestppd
python3 Driver/ppd/generate_ppds.py --model zd421t     # nur ein Modell (alle Auflösungen)
python3 Driver/ppd/generate_ppds.py --list             # nur auflisten, nichts schreiben
make -C Driver/ppd test                                # Tests
```

| Option | Bedeutung |
|---|---|
| `--output DIR`, `-o` | Ausgabeordner (Standard `Driver/ppd/out`, per `.gitignore` ausgeschlossen) |
| `--gzip` | Dateien als `.ppd.gz` schreiben (reproduzierbar: ohne Zeitstempel und Dateinamen) |
| `--check` | jede erzeugte Datei mit `cupstestppd -I filters` prüfen; jede Beanstandung → Exit-Status 1. Fehlt `cupstestppd`, wird die Prüfung mit Hinweis übersprungen. `cupstestppd` läuft unabhängig von der Systemsprache englisch |
| `--model ID` | nur dieses Modell (Katalog-ID, Groß-/Kleinschreibung egal, oder `generic-zpl`/`generic-epl`/`generic-cpcl`) |
| `--list` | Tabelle aller Ziele (Datei, Modell, dpi, Sprachen, NickName); Katalogfehler wie beim Schreiben (Exit-Status 2) |
| `--catalog PATH` | anderer Katalog (Standard `Catalog/models.json`) |
| `--file-version V` | Wert für `*FileVersion` (Standard `1.0.0`; der Paketbau übergibt die Treiberversion) |
| `--quiet`, `-q` | nur Fehler ausgeben |

Exit-Status: `0` erfolgreich, `1` `cupstestppd` hat Fehler gefunden, `2` Katalog-, Aufruf- oder
Schreibfehler. Katalogdaten, aus denen sich keine gültige PPD bilden lässt (z. B. ein Modellname
ohne ASCII-Umschrift wie `斑马`, ein IEEE-1284-Name mit `"`, ein Format ohne Namen), werden schon
beim Aufbau der Ziele erkannt – in jedem Modus, auch mit `--list`, mit derselben Meldung
`Fehler: LabelWerk-<id>-<dpi>dpi: …`, bevor etwas geschrieben wird.

Ein vollständiger Lauf entfernt veraltete `LabelWerk-*.ppd[.gz]` im Ausgabeordner (andere
Dateien bleiben unberührt). Mit `--model` bleiben die übrigen Dateien erhalten und `index.json`
wird ergänzt. Beim Wechsel zwischen `.ppd` und `.ppd.gz` wird die jeweils andere Variante
derselben Datei gelöscht, sodass nie beide nebeneinander liegen.

### `index.json`

```json
[
  {
    "file": "LabelWerk-zd421t-203dpi.ppd.gz",
    "modelId": "zd421t",
    "name": "ZD421t",
    "dpi": 203,
    "languages": ["zpl", "epl"],
    "nickName": "Zebra ZD421t (203 dpi) - LabelWerk",
    "ieee1284": "MANUFACTURER:Zebra Technologies ;COMMAND SET:ZPL,EPL2;MODEL:ZTC ZD421-203dpi ZPL;CLASS:PRINTER;"
  }
]
```

`languages` enthält die Rohwerte von `PrinterLanguage` (`zpl`, `epl`, `cpcl`), `ieee1284` den
geschriebenen `*1284DeviceID` (bei generischen PPDs `null`). Reihenfolge: Katalogreihenfolge,
Auflösung aufsteigend, danach die generischen PPDs.

## Aufbau der PPDs

**Kopf.** PPD 4.3, `*LanguageVersion: English`, `*LanguageEncoding: ISOLatin1`. Alle Grundtexte
sind reines ASCII. `*Manufacturer: "Zebra"`, `*NickName: "Zebra <Name> (<dpi> dpi) - LabelWerk"`,
`*ShortNickName` (höchstens 31 Zeichen), `*ModelName: "Zebra <Name> <dpi> dpi - LabelWerk"`,
`*PCFileName` als eindeutiger 8.3-Name aus einem Hash des Dateinamens (`LW1A2B3C.PPD`, stabil
unabhängig von `--model`), `*PSVersion`, `*LanguageLevel "3"`, `*ColorDevice: False`,
`*DefaultColorSpace: Gray`, `*TTRasterizer: Type42`, `*Throughput` (Etiketten/Minute bei
Höchstgeschwindigkeit mit dem Standardformat).

**Gerätezuordnung.** `*1284DeviceID: "MANUFACTURER:Zebra Technologies[ ];COMMAND SET:<Sprachen>;MODEL:<mdl>;CLASS:PRINTER;"`
– genau einer je Datei, mit denselben Schlüsselnamen in derselben Reihenfolge wie die Drucker
selbst. `MODEL` ist der `ZTC …`-Eintrag aus `ieee1284`, der zur Auflösung der Datei passt
(`ZTC ZD421-300dpi ZPL` in der 300-dpi-PPD), sonst der erste `ZTC …`-Eintrag ohne Auflösung, sonst
der erste sonstige Eintrag (`ZDesigner …` sind Windows-Treibernamen und werden übergangen). Für die
Baureihen in `IEEE1284_PLAIN_MODEL_FAMILIES` (G-Serie `GX`) gilt der `ZTC …`-Eintrag ohne Auflösung
zuerst (`ZTC GX420d`). Link-OS-Modelle (Ausstattung `linkOS`) schreiben den Hersteller wie das Gerät
mit Leerzeichen vor dem Semikolon (`Zebra Technologies ;`). Damit wählt macOS beim Anschließen per
USB und beim Hinzufügen per IP-Adresse (LPD/„HP Jetdirect – Socket“, Kennung per SNMP)
automatisch die PPD mit der richtigen Auflösung. Zusätzlich führt jede PPD neben
`*Product: "(Zebra <Name>)"` die passenden IEEE-1284-Namen als weitere `*Product`-Einträge
(`(ZTC ZD421-203dpi ZPL)`), über die macOS Bonjour-/IPP-Drucker zuordnet. Generische PPDs haben
keinen `*1284DeviceID`.

*Belege* (Stand November 2026):

* So melden die Drucker ihre Kennung – immer mit langen Schlüsselnamen:
  * ZD421 (203 dpi) per SNMP (HP-OID `1.3.6.1.4.1.11.2.3.9.1.1.7.0` und Zebra-OIDs
    `1.3.6.1.4.1.10642.1.3.0`/`.1.10.0`): `MANUFACTURER:Zebra Technologies ;COMMAND SET:ZPL;MODEL:ZTC ZD421-203dpi ZPL;CLASS:PRINTER;OPTIONS:XML;`
    – <https://gist.github.com/fproperzi/5269baf2e493046b05ff341029e8e5f5>
  * ZD611/ZD621 (203/300 dpi) mit Leerzeichen, GX420d/GX420t/GX430d/GX430t ohne Leerzeichen und
    mit Variantennamen (`MODEL:ZTC GX420d;`) – Treibertabelle von LPrint (Michael Sweet):
    <https://github.com/michaelrsweet/lprint/blob/master/lprint-zpl.h>
  * ZQ520 im CPCL-Modus (`^HZA`): `MANUFACTURER:Zebra Technologies ;COMMAND SET:CPCL;MODEL:ZTC ZQ520 (CPCL);…`
    – <https://developer.zebra.com/forum/25680>
  * LP 2844-Z per USB: `MANUFACTURER:Zebra Technologies;COMMAND SET:ZPL;MODEL:ZTC LP2844-Z-200dpi;CLASS:PRINTER;…`
    – <https://usb-ids.gowdy.us/read/UD/0a5f>
* CUPS ordnet PPDs mit `regex_device_id` in `scheduler/cups-driverd.cxx` zu: Aus der Kennung des
  Geräts entsteht `(MANUFACTURER:.*<wert>.*;).*(COMMAND SET:.*<wert>.*;)?.*(MODEL:.*<wert>.*;)` –
  die Schlüssel werden wörtlich übernommen („We assume that the device ID in the PPD and the device
  ID reported by the device itself use the same attribute names and order of attributes“). Die
  frühere Schreibweise `MFG:…;CMD:…;MDL:…;` passte deshalb auf keinen Zebra-Drucker.
  <https://github.com/apple/cups/blob/master/scheduler/cups-driverd.cxx>
  (`tests/test_generate.py` bildet den Vergleich nach.)
* Nicht belegt und deshalb unverändert: GK420/GC420 (vermutlich wie GX `ZTC GK420d`), Xi4, ZM, S4M,
  LP/TLP 28xx (der Katalog kennt `ZTC LP2844-Z-200dpi` nicht), Mobildrucker im CPCL-Modus
  (`ZTC ZQ520 (CPCL)` – eine PPD hat nur einen `*1284DeviceID`, gewählt ist die ZPL-Kennung). Diese
  Modelle ordnet macOS weiterhin über `*Product`/NickName zu oder sie werden in LabelWerk bzw. in
  den Systemeinstellungen gewählt.
* macOS wählt bei „AirPrint“/IPP Everywhere (Standard beim Hinzufügen per IP-Adresse, wenn der
  Drucker IPP kann) keinen PPD-Treiber, sondern den eigenen AirPrint-Treiber. Solche
  Warteschlangen stellt die App automatisch auf den LabelWerk-Treiber um (ARCHITECTURE.md §9
  „Übernahme von macOS-Warteschlangen“).

**CUPS (§10).**

```
*cupsVersion: 2.3
*cupsManualCopies: False            ← Kopien erzeugt der Filter per ^PQ
*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/LabelWerk/Filter/rastertolabelwerk"
*cupsFilter: "application/vnd.cups-command 0 /Library/Printers/LabelWerk/Filter/commandtolabelwerk"
*cupsCommands: "Clean PrintSelfTestPage ReportLevels AutoConfigure Calibrate"
*cupsSNMPSupplies: False            ← Thermodrucker melden keine Verbrauchsmaterialien
*cupsLanguages: "de"
*APPrinterIconPath: "/Library/Printers/LabelWerk/Icons/LabelWerk.icns"
*APPrinterUtilityPath: "/Applications/LabelWerk.app"
```

**Attribute für den Filter (§9).** `*lwModel` (Katalog-ID bzw. `generic-zpl` …),
`*lwMaxPrintWidthDots` (= `PrinterModel.printWidthDots`, z. B. 104 mm bei 203 dpi → `831`),
`*lwDefaultGapDots` (Lücke des Standardformats in Punkten, z. B. 3 mm → `24`). Alle Punktwerte
werden exakt wie in Swift gerundet (`Double.rounded()`, kaufmännisch – nicht Pythons `round`).

**Gruppen wie im Windows-Treiber.** Die Optionen sind wie die Seitenleiste des Dialogs
„Druckeinstellungen für ZD421 …“ des ZDesigner-Treibers gruppiert (macOS-Druckdialog →
„Druckerfunktionen“): „Seite einrichten“ (`PageSetup`), „Druckoptionen“ (`PrintOptions`),
„Bedienermodus“ (`OperationMode`), „Grafik Optionen“ (`Graphics`), „Erweitert“ (`Advanced`).
„Seite einrichten“ beginnt mit `PageSize`/`PageRegion`/`ImageableArea`/`PaperDimension` für alle
passenden Katalogformate und `*CustomPageSize` mit `*MaxMediaWidth`/`*MaxMediaHeight`,
`*HWMargins: 0 0 0 0`; „Erweitert“ endet mit `Resolution` (eine feste Wahl `<dpi>dpi` mit
`HWResolution`) und `ColorModel Gray` (`cupsColorSpace 18`, 8 Bit). Gruppen ohne Optionen (z. B.
„Bedienermodus“ der generischen CPCL-PPD) entfallen.

* Schlüsselwort je Format exakt wie `LabelStock.ppdKeyword`: `w<pt>h<pt>` mit
  `Int((mm / 25.4 * 72).rounded())` – die App setzt Warteschlangen mit
  `lpadmin -o PageSize=<stock.ppdKeyword>`.
* Passend heißt wie in `ModelCatalog.stocks(fitting:)`: Breite ≤ Druckbreite + 2 mm und
  Höhe ≤ maximale Etikettenlänge. Das Standardformat des Modells ist **immer** enthalten (auch
  wenn es die Regel knapp verfehlt, z. B. 2-Zoll-Etiketten auf ZQ610/ZQ310 mit 48 mm Druckbreite).
* Formate, die auf dasselbe Schlüsselwort fallen (gleiche Größe auf 1 pt genau, z. B. „Endlos 4
  Zoll“ und „4 × 6 Zoll“), werden zu einem Eintrag zusammengeführt; das Standardformat bzw. das
  erste im Katalog gibt den Namen.
* Maße mit drei Nachkommastellen, bildbarer Bereich = ganze Seite. Damit liefert
  `cupsRasterInterpretPPD` für jedes Format genau `LabelStock.widthDots/heightDots` als
  `cupsWidth`/`cupsHeight` (von den Tests für jedes Format und jede Auflösung geprüft).
* Eigene Größen: Breite 36 pt (0,5 Zoll) bis Druckbreite + 2 mm, Höhe 18 pt (0,25 Zoll) bis
  maximale Etikettenlänge.
* Anzeigenamen: englisch (ASCII) aus dem deutschen Katalognamen abgeleitet
  (`4 × 6 Zoll (Versand)` → `4 x 6 in (Shipping)`), deutsch unverändert aus dem Katalog.

**Optionen `lw*` (§9).** Leere PostScript-Codes (`""`), `*OrderDependency: 20… AnySetup`.

| Gruppe | Option (deutscher Titel) | Auswahl in der PPD | Standard |
|---|---|---|---|
| Seite einrichten | `lwFitToLabel` (An Etikett anpassen) | `Auto` (Automatisch) `Off` (Aus) – Seiten, deren Größe um mehr als 2 mm vom Etikett der Warteschlange (`lwLabelWidth`/`lwLabelHeight`) abweicht, legt der Filter auf das Etikett (ARCHITECTURE.md §8 „F“) | `Auto` |
| | `lwMediaTracking` (Medientyp) | `Default` `Continuous` (Endlosmaterial) `Gap` (Einzeletiketten) `BlackMark` (Etiketten mit schwarzen Markierungen) `Notch` (Etiketten mit Seitenkerben) `Auto` | `Default` |
| | `lwMarkOffset` (Markierung Versatz) | `Default` + −10 −5 −3 −2 −1 0 1 2 3 4 5 10 15 20 25 30 35 mm in Punkten der Auflösung, nur Werte in −80…283 Punkten (ZPL) | `Default` |
| | `lwRotation` (Drehung) | `0` „0° – Hochformat“, `90` „90° – Querformat“, `180` „180° – Hochformat“, `270` „270° – Querformat“ | `0` |
| | `lwMirror` (Spiegeln), `lwNegative` (Invers), `lwStopAtLast` (Bei letztem Element stoppen) | Boolean `False`/`True` | `False` |
| | `lwStopOffset` (Stoppversatz) | 0 1 2 3 5 10 mm in Punkten der Auflösung | `0` |
| Druckoptionen | `lwSpeed` (Geschwindigkeit) | `Default`, `2`…Modellmaximum (höchstens 14; wie Windows ab 51 mm/s – `1` nur als Auftragsoption), Text in mm/s: „102 mm/s (4 Zoll/s)“ | `Default` |
| | `lwDarkness` (Temperatur) | `Default`, `1`…`30` | `Default` |
| | `lwMediaType` (Druckmodus) | `Default` + `ThermalTransfer` (Thermotransfer) / `DirectThermal` (Thermo-Direkt) des Modells | `Default` |
| | `lwLabelTop` (Versatz oben) | `Default`, `-120`…`120` Punkte in 10er-Schritten, Text in mm | `Default` |
| | `lwLabelLeft` (Versatz links) | `Default`, `-200`…`200` Punkte in 10er-Schritten, Text in mm | `Default` |
| | `lwBackfeed` (Rückzug) | `Default` `Off` (Kein Rückzug) `Before` (Vor dem Drucken) `After` (Nach dem Drucken) `Normal` (Standard) | `Default` |
| | `lwPauseEvery` (Pausieren) | `0` (Keine Pause) `1 2 5 10 25 50 100` (ZPL; zählt je Seite und Kopiengruppe – ohne Wirkung bei sortierten Aufträgen mit mehreren Seiten) | `0` |
| | `lwControlChars` (Steuerzeichen) | `Standard`, `Printer` (Intern) (ZPL) | `Standard` |
| | `lwRTC` (RTC aktualisieren) | `Default` `JobStart` (Druckzeit starten) `EveryLabel` (Jedes Etikett) `EveryMinute` (Jede Minute) (ZPL) | `Default` |
| | `lwCancelBefore` (Aufträge vor dem Drucken abbrechen) | Boolean; `True` = „Alle aktuellen und nächsten Druckjobs löschen“ (ZPL, EPL) | `False` |
| | `lwCancelDelay` (Verzögerung) | `0 250 500 1000 2000 3000 5000 10000` ms (ZPL, EPL) | `1000` |
| Bedienermodus | `lwPrintMode` (Modus) | `Default` + Modi des Modells (Abreißen, Spendemodus, Abschneider, Verzögerter Abschneider, Aufwickeln, Applikator, Kiosk); Linerless ablösen/schneiden/verzögert schneiden/aufwickeln, Linerless-Abriss nur bei Modellen mit Ausstattung `linerless` und ZPL | `Default` |
| | `lwTearOff` (Versatz) | `Default`, `-120`…`120` Punkte in 10er-Schritten | `Default` |
| | `lwCutEvery` (Schneiden alle) | `0 1 2 5 10 25 50 100` – nur Modelle mit Schneider/verzögertem Schnitt (zählt wie `lwPauseEvery` je Seite und Kopiengruppe) | `0` |
| Grafik Optionen | `lwDither` | `Threshold` `Ordered` `Halftone` `FloydSteinberg` `Atkinson` `Stucki` | `Threshold` |
| | `lwThreshold` | `64 96 128 160 192` | `128` |
| | `lwCompression` | `Z64` `ACS` `Hex` | `Z64` |
| Erweitert | `lwLanguage` | Sprachen des Modells (`ZPL` `EPL` `CPCL`) | Standardsprache des Modells |
| | `lwCalibrate`, `lwSaveSettings`, `lwSkipBlank` | Boolean `False`/`True` | `False` |
| | `lwPowerUpAction`, `lwHeadCloseAction` | `Default` `Feed` `Calibrate` `Length` `NoMotion` `ShortCal` (ZPL; `^MF` nur, wenn beide gesetzt; die Aktion beim Einschalten wirkt erst beim nächsten Einschalten und nur mit `lwSaveSettings=True`) | `Default` |

Die Standardwerte entsprechen `PrintSettings.default`. Versatzwerte zeigen die Millimeter für die
Auflösung der Datei und die Punkte („+1,3 mm (+10 Punkte)“); Markierung Versatz und Stoppversatz
sind in mm gewählt und als Punkte der Auflösung gespeichert („+5 mm (40 Punkte)“).

Eine Option erscheint nur, wenn der Filter sie in einer Sprache des Modells auswertet (§8):
ZPL-only sind `lwLabelTop`, `lwLabelLeft`, `lwTearOff`, `lwBackfeed`, `lwCompression`,
`lwCutEvery`, `lwCalibrate`, `lwSaveSettings`, `lwMarkOffset`, `lwPauseEvery`, `lwControlChars`,
`lwRTC`, `lwPowerUpAction`, `lwHeadCloseAction`; `lwMediaType`, `lwPrintMode`, `lwCancelBefore`
und `lwCancelDelay` wirken in ZPL und EPL2 (EPL2 kennt nur Abreißen, Spenden, Schneiden).
`lwFitToLabel`, `lwRotation`, `lwStopAtLast` und `lwStopOffset` wirken in allen Sprachen. Reine EPL2-Modelle
(LP/TLP 2844, TLP 3842) und die generische CPCL-PPD zeigen deshalb nur die wirksamen Optionen.

**Keine PPD-Optionen** sind `lwStartCmd`/`lwEndCmd`/`lwLabelStartCmd`/`lwLabelEndCmd` (freie
Base64url-Zeichenketten), `lwFormatPrefix`/`lwControlPrefix`/`lwDelimiter` (freie ASCII-Codes
33…126 für „Steuerzeichen: Intern“), `lwLabelWidth`/`lwLabelHeight` (Etikettengröße der
Warteschlange in 1/100 mm für `lwFitToLabel`, aus dem Etikettenformat) und das veraltete
`lwRotate180` (ersetzt durch `lwRotation`; der Filter wertet es weiterhin aus). Ein Druckdialog kann freie Werte nicht darstellen; stünden
sie als Auswahl in der PPD, würde ein Dialog den Platzhalter mit jedem Auftrag senden und die
gesetzten Warteschlangenwerte überdecken. Ohne PPD-Eintrag gelangen sie als serverseitige Vorgaben
zuverlässig in `argv[5]` des Filters – gesetzt mit `lpadmin -p <queue> -o lwStartCmd-default=…`,
entfernt mit `-R lwStartCmd-default`. Dasselbe gilt für Ganzzahlen außerhalb der PPD-Auswahl
(z. B. `-o lwLabelTop-default=37`). Achtung: Die Kurzform `-o lwStartCmd=…` speichert CUPS nur für
PPD-Optionen mit gültiger Auswahl; andere Werte werden stillschweigend verworfen.

**Generische PPDs.** Vereinigung der Fähigkeiten aller Katalogmodelle der jeweiligen Sprache:
Druckbreite und Etikettenlänge = Maximum (ZPL: 216 mm, sodass jeder Drucker passt; EPL2/CPCL:
104 mm), Geschwindigkeit/Medientypen/Druckmodi von den Modellen mit dieser Sprache und
Auflösung, Standardformat = häufigstes Standardformat dieser Modelle (ZPL/EPL2: 4 × 6 Zoll,
CPCL: 3 × 2 Zoll). Die App greift laut `CUPSService.ppdURL` auf sie zurück, wenn es keine
Modell-PPD gibt.

**Übersetzungen.** Jede Gruppe, Option und Wahl (einschließlich Seitengrößen, eigener Größe
und ihrer Parameter) hat eine deutsche Übersetzung nach CUPS-Konvention:

```
*de.Translation lwDarkness/Temperatur: ""
*de.lwDarkness Default/Druckereinstellung: ""
*de.PageSize w288h432/4 × 6 Zoll (Versand): ""
*de.CustomPageSize True/Eigenes Format: ""
```

Übersetzungen sind **UTF-8**: CUPS verlangt das unabhängig von `*LanguageEncoding`
(`cupstestppd` meldet ISO-Latin-1-Umlaute als „Bad UTF-8 … translation string“, `ppdLocalize`
übernimmt die Bytes unverändert). Weil alle übrigen Zeilen reines ASCII sind, bleibt die Datei
für ISO-Latin-1-Leser gültig (die App liest PPDs mit `.isoLatin1`).

## Prüfung

`--check` ruft `cupstestppd -I filters` für jede Datei auf. `-I filters` ist nötig, weil die
Filterprogramme unter `/Library/Printers/LabelWerk` auf dem Build-Rechner fehlen; alle anderen
Prüfungen (einschließlich der Übersetzungen) sind streng. `cupstestppd` läuft dabei stets mit
`LANG=en_US.UTF-8` und `SOFTWARE=CUPS/2.3` (ohne `LC_ALL`/`LC_MESSAGES`/`LC_CTYPE`/`LANGUAGE`),
denn das Ergebnis wird an den englischen Meldungen erkannt – mit deutscher Systemsprache meldet
`cupstestppd` sonst „BESTANDEN“, und die libcups von macOS beachtet `LANG` nur bei gesetztem
`SOFTWARE`. Erwartete Warnungen – und die einzigen, die die Tests zulassen – sind Hinweise wie

```
WARN    Size "w288h432" should be the Adobe standard name "4x6.Fullbleed".
```

Die Schlüsselwörter `w<pt>h<pt>` sind Teil des Vertrags mit App und Filter und bleiben daher
bestehen; CUPS ordnet sie über ihre Maße trotzdem den PWG-Standardgrößen zu.

## Tests

```bash
python3 -m unittest discover -s Driver/ppd/tests -v     # oder: make -C Driver/ppd test
```

`tests/test_generate.py` erzeugt alle PPDs in einem temporären Ordner und prüft unter anderem:

* eine PPD je Modell × Auflösung plus die fünf generischen, eindeutige `*PCFileName`,
  `*NickName`, `*ModelName`; eindeutige Options-, Auswahl- und Seitengrößen-Schlüsselwörter;
* gültige Standardwerte (Seitengröße = Standardformat, Sprache = Standardsprache, Werte von
  `PrintSettings.default`), Geschwindigkeiten bis zum Modellmaximum, Einschränkungen je Modell;
* jede `lw*`-Option samt Auswahl **gegen ARCHITECTURE.md §9** (die Tabelle wird aus dem Dokument
  gelesen: „PPD: …“-Angaben inkl. Bereichen und „mm je Auflösung“, „nicht in der PPD“) und gegen
  `CUPSOptionName` in `PrintSettings.swift`;
* Gruppen, Reihenfolge und deutsche Begriffe wie im Windows-Treiber, Linerless-Modi genau für
  Modelle mit Ausstattung `linerless`;
* vollständige deutsche Übersetzungen, ASCII-Grundtexte, Zeilenlängen, gzip-Modus
  (reproduzierbar), `index.json`, `--model`/`--list`/`--check`/`--file-version`, Katalogfehler;
* mit `cupstestppd`: alle PPDs bestehen (auch bei deutscher Systemsprache); strenge Prüfung
  ohne `-I filters` gegen ein nachgebildetes Installationsverzeichnis (`-R`); `-vv` listet alle
  Optionen;
* mit C-Compiler und libcups (`tests/ppdcheck.c`): `ppdOpenFile` sieht dieselben Optionen,
  Auswahlen und Standardwerte ohne Konflikte, `ppdLocalize` liefert mit `LANG=de_DE.UTF-8` und
  `SOFTWARE` (macOS) die deutschen Texte – auch gegen eine englische Benutzerumgebung,
  `cupsRasterInterpretPPD` liefert je Format Auflösung, 8-Bit-Graustufen (`cupsColorSpace 18`)
  und exakt die Punktmaße aus Swift; eigene Größen funktionieren.

Die Tests brauchen keine root-Rechte. `cupstestppd` verlangt ohne `-I filters`, dass Filter,
Symbol und App root gehören (`st_uid == 0`); im nachgebildeten Wurzelverzeichnis gelingt das nur
als root. Als root muss die strenge Prüfung daher vollständig bestehen, sonst sind allein
„Bad permissions“-Meldungen zu Dateien zulässig, deren Rechte stimmen (0755 bzw. 0644) und die nur
nicht root gehören – fehlende Dateien und falsche Rechte bleiben Fehler. Als root prüft ein
weiterer Test genau diesen Fall, indem er die Dateien einem gewöhnlichen Benutzer überträgt.

Tests, deren Werkzeuge fehlen (`cupstestppd`, Compiler, `libcups2-dev`), werden übersprungen.

## Installation

Für den Paketbau (`Installer/`) empfohlen: `generate_ppds.py --gzip --check --file-version <Version>
--output <Nutzlast>/Library/Printers/PPDs/Contents/Resources` (bzw. `make -C Driver/ppd check
OUT=… VERSION=…`); installiert werden die Dateien mit root:wheel und 0644 (ARCHITECTURE.md §10).
`index.json` dient App und Paketbau als Verzeichnis und muss nicht mitinstalliert werden.

## Bekannte Einschränkungen

* Mehrere Varianten eines Modells (z. B. ZD421d/t/c) melden per USB denselben IEEE-1284-Namen
  (`ZTC ZD421-203dpi ZPL`); macOS wählt dann eine der Varianten-PPDs automatisch aus. Alle sind
  funktionsgleich, sie unterscheiden sich nur in den angebotenen Medientypen/Druckmodi – bei
  Bedarf in der App oder in den Systemeinstellungen die genaue Variante wählen.
* Der IEEE-1284-Herstellername ist für alle Modelle `Zebra Technologies`; sehr alte EPL-Geräte
  melden teils nur `Zebra` und werden dann über `*Product`/NickName statt über den
  Geräte-String zugeordnet.
* Die CUPS-eigene Wahl „Custom“ der (nie angezeigten) Option `PageRegion` bleibt unübersetzt;
  libcups ignoriert `*de.PageRegion Custom`. Die sichtbare Wahl in `PageSize` ist übersetzt.

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
| `--check` | jede erzeugte Datei mit `cupstestppd -I filters` prüfen; jede Beanstandung → Exit-Status 1. Fehlt `cupstestppd`, wird die Prüfung mit Hinweis übersprungen |
| `--model ID` | nur dieses Modell (Katalog-ID, Groß-/Kleinschreibung egal, oder `generic-zpl`/`generic-epl`/`generic-cpcl`) |
| `--list` | Tabelle aller Ziele (Datei, Modell, dpi, Sprachen, NickName) |
| `--catalog PATH` | anderer Katalog (Standard `Catalog/models.json`) |
| `--file-version V` | Wert für `*FileVersion` (Standard `1.0.0`; der Paketbau übergibt die Treiberversion) |
| `--quiet`, `-q` | nur Fehler ausgeben |

Exit-Status: `0` erfolgreich, `1` `cupstestppd` hat Fehler gefunden, `2` Katalog-, Aufruf- oder
Schreibfehler.

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
    "ieee1284": "MFG:Zebra Technologies;CMD:ZPL,EPL2;MDL:ZTC ZD421-203dpi ZPL;CLS:PRINTER;"
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

**Gerätezuordnung.** `*1284DeviceID: "MFG:Zebra Technologies;CMD:<Sprachen>;MDL:<mdl>;CLS:PRINTER;"`
– genau einer je Datei. `MDL` ist der `ZTC …`-Eintrag aus `ieee1284`, der zur Auflösung der
Datei passt (`ZTC ZD421-300dpi ZPL` in der 300-dpi-PPD), sonst der erste `ZTC …`-Eintrag ohne
Auflösung, sonst der erste sonstige Eintrag (`ZDesigner …` sind Windows-Treibernamen und werden
übergangen). Damit wählt macOS beim Anschließen automatisch die PPD mit der richtigen Auflösung.
Zusätzlich führt jede PPD neben `*Product: "(Zebra <Name>)"` die passenden IEEE-1284-Namen als
weitere `*Product`-Einträge (`(ZTC ZD421-203dpi ZPL)`), über die macOS Bonjour-/IPP-Drucker
zuordnet. Generische PPDs haben keinen `*1284DeviceID`.

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

**Gruppe „General“.** `PageSize`/`PageRegion`/`ImageableArea`/`PaperDimension` für alle
passenden Katalogformate, `*CustomPageSize` mit `*MaxMediaWidth`/`*MaxMediaHeight`,
`*HWMargins: 0 0 0 0`, `Resolution` (eine feste Wahl `<dpi>dpi` mit `HWResolution`) und
`ColorModel Gray` (`cupsColorSpace 18`, 8 Bit).

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

| Gruppe | Option | Auswahl in der PPD | Standard |
|---|---|---|---|
| Printer Settings / Druckereinstellungen | `lwLanguage` | Sprachen des Modells (`ZPL` `EPL` `CPCL`) | Standardsprache des Modells |
| | `lwDarkness` | `Default`, `0`…`30` | `Default` |
| | `lwSpeed` | `Default`, `1`…Modellmaximum der Auflösung (höchstens 14) | `Default` |
| | `lwPrintMode` | `Default` + Druckmodi des Modells | `Default` |
| | `lwCutEvery` | `0 1 2 5 10 25 50 100` – nur Modelle mit Schneider/verzögertem Schnitt | `0` |
| | `lwBackfeed` | `Default` `After` `Before` `Normal` `Off` | `Default` |
| Media / Medien | `lwMediaType` | `Default` + Medientypen des Modells | `Default` |
| | `lwMediaTracking` | `Default` `Gap` `BlackMark` `Continuous` `Auto` | `Default` |
| Label Position / Etikettenposition | `lwLabelTop`, `lwTearOff` | `Default`, `-120`…`120` in 10er-Schritten | `Default` |
| | `lwLabelLeft` | `Default`, `-200`…`200` in 10er-Schritten | `Default` |
| Image / Bild | `lwRotate180`, `lwMirror`, `lwNegative` | Boolean `False`/`True` | `False` |
| | `lwDither` | `Threshold` `Ordered` `Halftone` `FloydSteinberg` `Atkinson` `Stucki` | `Threshold` |
| | `lwThreshold` | `64 96 128 160 192` | `128` |
| Advanced / Erweitert | `lwCompression` | `Z64` `ACS` `Hex` | `Z64` |
| | `lwSkipBlank`, `lwCalibrate`, `lwSaveSettings` | Boolean `False`/`True` | `False` |

Die Standardwerte entsprechen `PrintSettings.default`. Versatzwerte zeigen zusätzlich die
Millimeter für die Auflösung der Datei („+10 Punkte (+1,3 mm)“).

Eine Option erscheint nur, wenn der Filter sie in einer Sprache des Modells auswertet (§8):
ZPL-only sind `lwLabelTop`, `lwLabelLeft`, `lwTearOff`, `lwBackfeed`, `lwCompression`,
`lwCutEvery`, `lwCalibrate`, `lwSaveSettings`; `lwMediaType` und `lwPrintMode` wirken in ZPL
und EPL2 (EPL2 kennt nur Abreißen, Spenden, Schneiden). Reine EPL2-Modelle (LP/TLP 2844, TLP 3842)
und die generische CPCL-PPD zeigen deshalb nur die wirksamen Optionen.

`lwStartCmd`/`lwEndCmd` sind **keine** PPD-Optionen: Ihre Werte sind freie Base64url-Zeichenketten,
die ein Druckdialog nicht darstellen kann. Stünden sie als Auswahl in der PPD, würde ein Dialog
den Platzhalter mit jedem Auftrag senden und die per `lpadmin -p <queue> -o lwStartCmd=…`
gesetzten Warteschlangenwerte überdecken. Ohne PPD-Eintrag gelangen sie über die
Warteschlangen-Optionen zuverlässig in `argv[5]` des Filters. Dasselbe Prinzip erlaubt auch
Ganzzahlen außerhalb der PPD-Auswahl (z. B. `lwLabelTop=37`).

**Generische PPDs.** Vereinigung der Fähigkeiten aller Katalogmodelle der jeweiligen Sprache:
Druckbreite und Etikettenlänge = Maximum (ZPL: 216 mm, sodass jeder Drucker passt; EPL2/CPCL:
104 mm), Geschwindigkeit/Medientypen/Druckmodi von den Modellen mit dieser Sprache und
Auflösung, Standardformat = häufigstes Standardformat dieser Modelle (ZPL/EPL2: 4 × 6 Zoll,
CPCL: 3 × 2 Zoll). Die App greift laut `CUPSService.ppdURL` auf sie zurück, wenn es keine
Modell-PPD gibt.

**Übersetzungen.** Jede Gruppe, Option und Wahl (einschließlich Seitengrößen, eigener Größe
und ihrer Parameter) hat eine deutsche Übersetzung nach CUPS-Konvention:

```
*de.Translation lwDarkness/Schwärzung: ""
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
Prüfungen (einschließlich der Übersetzungen) sind streng. Erwartete Warnungen – und die einzigen,
die die Tests zulassen – sind Hinweise wie

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
  gelesen) und gegen `CUPSOptionName` in `PrintSettings.swift`;
* vollständige deutsche Übersetzungen, ASCII-Grundtexte, Zeilenlängen, gzip-Modus
  (reproduzierbar), `index.json`, `--model`/`--list`/`--check`/`--file-version`, Katalogfehler;
* mit `cupstestppd`: alle PPDs bestehen; strenge Prüfung ohne `-I filters` gegen ein
  nachgebildetes Installationsverzeichnis (`-R`); `-vv` listet alle Optionen;
* mit C-Compiler und libcups (`tests/ppdcheck.c`): `ppdOpenFile` sieht dieselben Optionen,
  Auswahlen und Standardwerte ohne Konflikte, `ppdLocalize` liefert mit `LANG=de_DE.UTF-8` die
  deutschen Texte, `cupsRasterInterpretPPD` liefert je Format Auflösung, 8-Bit-Graustufen
  (`cupsColorSpace 18`) und exakt die Punktmaße aus Swift; eigene Größen funktionieren.

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

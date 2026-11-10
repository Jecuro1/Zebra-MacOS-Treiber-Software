# LabelWerk – CUPS-Filter

Dieses Verzeichnis enthält die beiden CUPS-Filter des LabelWerk-Treibers (C11, nur libcups + zlib):

| Programm | MIME-Typ | Aufgabe |
|---|---|---|
| `rastertolabelwerk` | `application/vnd.cups-raster` | CUPS-Raster → ZPL II / EPL2 / CPCL (Rasterung, Kompression, Kopien) |
| `commandtolabelwerk` | `application/vnd.cups-command` | Druckerbefehle für *Selbsttest drucken*, *Kalibrieren*, *Reinigen* … |

Das erzeugte Auftragsformat ist byte-genau in [ARCHITECTURE.md §8](../../ARCHITECTURE.md) festgelegt
und identisch mit `JobEncoder` aus `LabelWerkImaging` – ein Etikett aus der App und eines über
CUPS sind dieselben Bytes. Die Rasterung folgt bitgenau §4.1.

## Bauen und Testen

```bash
make -C Driver/filter            # Filter nach Driver/filter/build/
make -C Driver/filter test       # C-Unit-Tests + End-to-End-Tests (Python 3, nur Standardbibliothek)
make -C Driver/filter asan       # alles mit AddressSanitizer + UBSan (inkl. Leck-Prüfung) nach build/asan/
make -C Driver/filter valgrind   # Unit-Tests + Kurzlauf der End-to-End-Tests unter Valgrind
make -C Driver/filter universal  # nur macOS: Universal Binary (arm64 + x86_64, ab macOS 11) nach build/universal/
make -C Driver/filter install DESTDIR=/tmp/pkgroot
                                 # → $(DESTDIR)/Library/Printers/LabelWerk/Filter (0755);
                                 #   auf macOS werden die Universal Binaries installiert
make -C Driver/filter clean
```

Voraussetzungen: C11-Compiler, CUPS-Entwicklungsdateien (`libcups2-dev` bzw. macOS-SDK), zlib.
Compiler-Flags: `-O2 -Wall -Wextra -std=c11`; die PPD-API von libcups ist als „deprecated“ markiert,
ist aber weiterhin die Schnittstelle für Treiberfilter – daher `-Wno-deprecated-declarations`.
Einzelne End-to-End-Fälle: `python3 tests/run_e2e.py --bindir build --only kopien -v`.

## Aufbau

| Datei | Inhalt |
|---|---|
| `rastertolabelwerk.c` | Filter-Hauptprogramm: Raster lesen, Zeilen umrechnen, rastern, Auftrag schreiben, SIGTERM |
| `commandtolabelwerk.c` | Befehlsfilter (`#CUPS-COMMAND`-Dateien) |
| `lw_cups.c/.h` | libcups-Anbindung: argv[5], PPD (`ppdMarkDefaults` + `cupsMarkOptions`), Attribute, Kopien, Sortierung |
| `lw_options.c/.h` | Optionen aus §9: Zerlegung, Vorrang, Begrenzung (entspricht `PrintSettings`) |
| `lw_raster.c/.h` | Rasterzeile → 8-Bit-Luminanz (alle Bittiefen, Farbräume, chunky/banded) |
| `lw_dither.c/.h` | Schwelle, Bayer, Halbton, Floyd–Steinberg, Atkinson, Stucki – zeilenweise (Streaming) |
| `lw_encode.c/.h` | Hex, ACS, Base64, CRC-16/XMODEM, Z64, Base64url, UTF-8-Prüfung |
| `lw_job.c/.h` | ZPL-/EPL-/CPCL-Schreiber, Vorverarbeitung, Kopien/Sortierung (Zwischendatei) |
| `lw_bitmap.c/.h` | 1-Bit-Bitmaps: Abschneiden, Negativ, Spiegeln, 90°/180°/270°, Höhe ändern |
| `lw_util.c/.h` | CUPS-Meldungen, Puffer, Ausgabesenken |
| `tests/test_main.c` | C-Unit-Tests (eigener Mini-Testrahmen) |
| `tests/mkraster.c` | erzeugt CUPS-Rasterdateien mit beliebigen Kopfdaten und Mustern |
| `tests/reference_encoder.py` | unabhängige Python-Referenz für §4.1, §8 und §9 (als Modul importierbar) |
| `tests/run_e2e.py` | End-to-End-Tests: Filterausgabe byte-genau gegen die Referenz |
| `tests/ppd/lwtest.ppd` | Test-PPD mit allen `lw*`-Optionen und Attributen (besteht `cupstestppd`) |

## Optionen (ARCHITECTURE.md §9)

Vorrang: Wert aus `argv[5]` (Auftrags-/Warteschlangenoptionen, z. B. `lpadmin -p q -o lwLabelTop-default=37`)
**vor** markierter PPD-Auswahl **vor** PPD-Standard **vor** eingebautem Standard. Ungültige Werte
werden mit `WARNING:` gemeldet und übergangen (dann gilt die nächste Ebene). Optionsnamen und
Aufzählungswerte sind unabhängig von Groß-/Kleinschreibung; Ganzzahlen dürfen außerhalb der
PPD-Auswahl liegen (auch als `Custom.37`) und werden auf gültige Bereiche begrenzt.

| Option | Werte | Wirkung |
|---|---|---|
| `lwLanguage` | `ZPL` `EPL` `CPCL` | Ausgabesprache (Standard ZPL) |
| `lwDarkness` | `Default`, 0…30 | ZPL `~SD`, EPL `D` (⌈d/2⌉), CPCL `CONTRAST` (0…3) |
| `lwSpeed` | `Default`, 1…14 | ZPL `^PR`, EPL `S` (1…6), CPCL `SPEED` (0…5) |
| `lwMediaType` | `Default` `DirectThermal` `ThermalTransfer` | ZPL `^MT`, EPL `O[D]` |
| `lwMediaTracking` | `Default` `Gap` `BlackMark` `Continuous` `Auto` `Notch` | ZPL `^MN` (`Notch` = `^MNW`), EPL `Q` (Kerben wie Lücke), CPCL ohne `FORM` bei Endlos |
| `lwPrintMode` | `Default` `TearOff` `PeelOff` `Cutter` `DelayedCut` `Rewind` `Applicator` `Kiosk`, `LinerlessPeel` `LinerlessCut` `LinerlessDelayedCut` `LinerlessRewind` `LinerlessTear` | ZPL `^MM` bzw. Linerless: `! U1 setvar "media.printmode" "linerless …"` im Kopf, kein `^MM`; EPL `O…C/P` |
| `lwLabelTop` / `lwLabelLeft` / `lwTearOff` | `Default`, −120…120 / −9999…9999 / −120…120 | `^LT` / `^LS` / `~TA` |
| `lwBackfeed` | `Default` `After` `Before` `Normal` `Off` | `~JS` |
| `lwMirror` `lwNegative` `lwRotate180` | `True`/`False` (auch yes/no/on/off/1/0) | ZPL `^PM`/`^PO`, EPL `ZB`, sonst Bitmap |
| `lwDither` | `Threshold` `Ordered` `Halftone` `FloydSteinberg` `Atkinson` `Stucki` | Rasterverfahren |
| `lwThreshold` | 1…254 (Standard 128) | Schwelle bzw. Helligkeitsbezug |
| `lwCompression` | `Z64` `ACS` `Hex` | ZPL-Grafikdaten (`^GFA`) |
| `lwCutEvery` | 0…9999 | `^PQn,c,0,Y` |
| `lwCalibrate` `lwSaveSettings` `lwSkipBlank` | `True`/`False` | `~JC`, `^JUS` (erstes Etikett), leere Seiten überspringen |
| `lwStartCmd` `lwEndCmd` | Base64url (UTF-8, ohne Padding); `None`/`Default` = leer | Rohbefehle vor/nach dem Auftrag (ZPL, EPL) |
| `lwRotation` | `0` `90` `180` `270` | Drehung im Uhrzeigersinn: 90/270 dreht die Bitmap vor dem Abschneiden (alle Sprachen), 180 wie `lwRotate180`; `0` überlässt `lwRotate180` die Wahl |
| `lwMarkOffset` | `Default`, −80…283 Punkte | `^MNM,n` – nur mit `BlackMark` und nur ZPL |
| `lwStopAtLast` / `lwStopOffset` | `True`/`False` / 0…32000 Punkte | nur `Continuous`: Seitenhöhe = letzte schwarze Zeile + 1 + Versatz (mindestens 1; darüber hinaus weiße Zeilen) |
| `lwPauseEvery` | 0…9999 | `^PQn,p,0,N` (Vorrang vor `lwCutEvery`), nur ZPL |
| `lwControlChars` | `Standard` `Printer` | `Printer` („Intern“): `lwFormatPrefix`/`lwControlPrefix`/`lwDelimiter` (ASCII 33…126, ungültig/fehlend → `^`/`~`/`,`) ersetzen die Zeichen in allen selbst erzeugten ZPL-Befehlen – nicht in Grafikdaten, SGD-Zeile und Rohbefehlen; auch `commandtolabelwerk` (`~WC`, `~JC`) |
| `lwRTC` | `Default` `JobStart` `EveryLabel` `EveryMinute` | `^XA^STmm,dd,yyyy,hh,mm,ss,M^XZ` (Ortszeit) im Kopf, bei `EveryLabel` vor jedem weiteren Etikett, bei `EveryMinute` vor einem Etikett, sobald ≥ 60 s vergangen sind; nur ZPL |
| `lwCancelBefore` / `lwCancelDelay` | `True`/`False` / 0…10000 ms (Standard 1000) | `~JA` nach den Startbefehlen (ZPL; EPL wörtlich), danach Ausgabe leeren und warten |
| `lwLabelStartCmd` `lwLabelEndCmd` | Base64url wie `lwStartCmd` | Rohbefehle je Etikett: ZPL nach `^XA` bzw. vor `^XZ`, EPL nach `N` bzw. vor `P` (CPCL: keine) |
| `lwPowerUpAction` `lwHeadCloseAction` | `Default` `Feed` `Calibrate` `Length` `NoMotion` `ShortCal` | `^XA^MFa,b^XZ` im Kopf – nur wenn beide gesetzt, nur ZPL |

Reihenfolge des ZPL-Auftragskopfs: Startbefehle, `~JA`, `~SD`, `~TA`, `~JS`, `~JC`, SGD
`media.printmode` (Linerless), `^MF`, `^ST`. Je Etikett: (`^ST`), `^XA`, Etikettenanfang, `^MM`,
`^MN`, `^MT`, `^PR`, `^PW`, `^LL`, `^LH`, `^LT`, `^LS`, `^PO`, `^PM`, Grafik, `^PQ`, `^JUS`,
Etikettenende, `^XZ`. Vorverarbeitung: (0) Drehung 90/270, (1) Abschneiden, (1b) Bei letztem
Element stoppen, (2) Negativ, (3) leere Seite überspringen, (4) EPL/CPCL spiegeln, (5) 180°.

PPD-Attribute: `*lwModel` (Meldungen, Selbsttest), `*lwMaxPrintWidthDots` (breitere Seiten werden
rechts abgeschnitten – gerastert wird vorher über die volle Breite), `*lwDefaultGapDots`
(EPL-Lücke, Standard 24).

Kopien kommen aus `argv[4]` (`*cupsManualCopies: False`). Sortierung: Option `collate`
(bzw. `noCollate`), sonst `multiple-document-handling`, sonst PPD `*Collate`, sonst `true`.
Bei sortierten Kopien mehrseitiger Aufträge wird jede Seite einmal kodiert und in einer
Zwischendatei (`cupsTempFd`) abgelegt; der Speicherbedarf bleibt so unabhängig von Seiten- und
Kopienzahl auf eine Seite begrenzt (2400 × 32000 Punkte: ca. 19 MB mit Z64, 34 MB mit Hex).

## Umgebungsvariablen (Tests und Diagnose)

| Variable | Wirkung |
|---|---|
| `LW_FIXED_TIME=<Sekunden seit 1970>` | feste Uhrzeit für `^ST` statt der Systemzeit (Ortszeit nach `TZ`) |
| `LW_TIME_STEP_SECONDS=<n>` | nur mit `LW_FIXED_TIME`: Etikett k (0-basiert, Sortierwiederholungen zählen mit) sieht `LW_FIXED_TIME + k·n` – simulierte Uhr für `lwRTC=EveryMinute`; der Kopf sieht `LW_FIXED_TIME` |
| `LW_CANCEL_DELAY_SCALE=<Faktor ≥ 0>` | Faktor für die Wartezeit nach `~JA` (`lwCancelDelay`); `0` = nicht warten (die End-to-End- und Konformitätstests setzen 0) |

Unter CUPS sind sie nicht gesetzt; ungültige Werte werden mit `WARNING:` ignoriert. Dieselbe Uhr
bilden `lwctl encode --fixed-time/--time-step/--time-zone` und der Referenz-Encoder (`now`,
`time_step`) nach. Ein `SIGTERM` beendet die Wartezeit nach `~JA` sofort.

## Rasterdaten

Unterstützt werden 1, 2, 4, 8 und 16 Bit je Farbe in den Farbräumen W, SW, K, RGB, sRGB,
AdobeRGB, RGBA (auf Weiß komponiert), CMY/YMC, CMYK/YMCK/KCMY – jeweils chunky oder banded
(planar nur einkanalig). Umrechnung nach §4.1; 2/4 Bit werden linear auf 0…255 gestreckt, von
16 Bit wird das höherwertige Byte des Werts verwendet (libcups liefert 16-Bit-Werte in
Host-Byte-Reihenfolge). Andere Farbräume (CIELab, ICC, DeviceN) und mehrkanalig planare Daten
werden mit einer klaren `ERROR:`-Meldung abgelehnt (Exitcode 1).

## Meldungen und Abbruch

* `INFO:` Fortschritt je Seite und Zusammenfassung, `DEBUG:` wirksame Einstellungen und Seitenkopf,
  `WARNING:` übergangene Werte, abgeschnittene oder zu lange Seiten, `ERROR:` Abbruchgrund.
* `PAGE: <seite> <menge>` je ausgegebenem Etikett (für die Seitenabrechnung von CUPS).
* `SIGTERM`: Eine vollständig gelesene Seite wird noch ausgegeben, danach endet der Filter mit
  Exitcode 0 (keine weiteren Seiten, keine Sortierwiederholungen). ZPL-Formate werden nie
  unvollständig geschrieben. Ein Abbruch vor der ersten Seite – auch bevor der Rasterdatenstrom
  beginnt – erzeugt keinerlei Ausgabe: weder Auftragskopf (Startbefehle, `~SD`, `~TA`, `~JC`,
  also keine Kalibrierung) noch Endbefehle; Meldung `INFO:`, Exitcode 0.
* Seiten ohne Fläche werden übersprungen. libcups (≥ 2.3) beendet den Datenstrom an einem
  Seitenkopf mit Höhe 0 oder unstimmiger Zeilenlänge; vorher gelesene Seiten werden gedruckt.

## Befehlsfilter

| CUPS-Befehl | ZPL | EPL | CPCL |
|---|---|---|---|
| `PrintSelfTestPage` | `~WC` | `U` | eigenes Selbsttest-Etikett (Modell, Auflösung, Breite, Druckkopf-Testmuster) |
| `Calibrate` | `~JC` | `xa` | `! U1 do "ezpl.manual_calibration" ""` |
| `Clean` | – | – | – |
| `AutoConfigure`, `ReportLevels` | – | – | – |

Mit `lwControlChars=Printer` beginnen `~WC`/`~JC` mit `lwControlPrefix` statt `~`.

`Clean`, `AutoConfigure` und `ReportLevels` senden bewusst keine Daten (sicherer No-op ohne
Vorschub oder Kalibrierung) und melden per `INFO:`/`DEBUG:`, was zu tun ist. Unbekannte Befehle
werden mit `DEBUG:` übergangen.

## Tests

* **Unit-Tests** (`tests/test_main.c`): Kodierungen mit bekannten Werten und Rundreisen, alle
  Rasterverfahren gegen eine unabhängige Naivimplementierung, Rasterumrechnung aller Formate,
  Optionszerlegung und Vorrangregeln, ZPL/EPL/CPCL byte-genau, Kopien/Sortierung, Abbruch;
  Drehung 90/270 gegen eine Naivimplementierung, Stoppen/Stoppversatz, eigene Steuerzeichen
  (auch vertauscht `^`↔`~`), RTC mit fester und schrittweiser Uhr, `~JA` samt Wartehaken,
  Etikettenbefehle, `^MF`, Linerless, Kerben, Markenversatz.
* **End-to-End** (`tests/run_e2e.py`): fast 500 Fälle – alle Sprachen × Kompressionen ×
  Rasterverfahren, Negativ/Spiegeln/180°/leere Seiten/Abschneiden/Kopien/Sortierung/Start- und
  Endbefehle, sämtliche Auftragseinstellungen, Vorrangregeln mit PPD-Varianten, 36 Rasterformate
  mit je zwei Mustern (auch komprimiert, PWG und über stdin), Fehlerfälle, SIGTERM, eine Seite mit
  2400 × 32000 Punkten mit Speichermessung, alle Befehle des Befehlsfilters und `cupstestppd` für
  die Test-PPD; dazu jede Option der Windows-Druckeinstellungen je Sprache (RTC mit
  `LW_FIXED_TIME`/`LW_TIME_STEP_SECONDS`, auch mit Sommerzeit über `TZ`), PPD-Standardwerte und
  ungültige Werte der neuen Optionen sowie eine Zeitmessung der Wartezeit nach `~JA` (300 ms,
  Faktor, SIGTERM). Die Referenz prüft sich vorab selbst (`python3 tests/reference_encoder.py`).
* **Konformität** (`Scripts/tests/test_encoder_conformance.py`): Swift-`JobEncoder` (über
  `lwctl encode`), dieser Filter und die Referenz müssen für rund 650 Fälle byte-gleich sein.

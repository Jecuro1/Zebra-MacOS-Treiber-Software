# LabelWerk

**Der moderne macOS-Treiber und die Steuerzentrale für Zebra®-Etikettendrucker.**

LabelWerk bringt alles, was unter Windows der ZDesigner-Treiber und die Zebra Setup Utilities
können, nativ auf den Mac – und geht deutlich darüber hinaus: eine animierte SwiftUI-Oberfläche
mit Live-Status, ein Etiketten-Designer mit Echtzeit-Vorschau, ein vollwertiges Terminal,
Firmware- und Netzwerkverwaltung, Menüleisten-Überwachung mit Mitteilungen und ein sauber
integrierter CUPS-Treiber, mit dem jedes Mac-Programm direkt auf Zebra-Druckern druckt.

> Zebra ist eine Marke der Zebra Technologies Corp. LabelWerk ist ein unabhängiges Projekt und
> steht in keiner Verbindung zu Zebra Technologies.

---

## Funktionsumfang

| Bereich | Windows (ZDesigner + Setup Utilities) | LabelWerk |
|---|---|---|
| Drucken aus jeder App | ✔ Treiber | ✔ CUPS-Treiber (`rastertolabelwerk`), Universal Binary, PPDs für 70+ Modelle × Auflösungen, automatische Treiberzuordnung per USB-ID |
| Druckersprachen | ZPL, EPL | **ZPL II, EPL2 und CPCL** (Mobildrucker) |
| Schwärzung, Geschwindigkeit, Medientyp, Erkennung, Druckmodus, Rückzug | ✔ | ✔ inkl. „Druckerwert verwenden“, Live-Vorschau |
| Position (oben/links), Abreißkante | ✔ | ✔ mit animierter Etiketten-Skizze |
| Spiegeln, Negativ, 180° | ✔ | ✔ mit 3D-Vorschau |
| Rasterung | 3 Verfahren | **6 Verfahren** (Schwellenwert, Bayer, Halbton, Floyd–Steinberg, Atkinson, Stucki) mit Live-Vorschau |
| Grafikkompression | – | **Z64 (Deflate), ACS, Hex** – bis zu 90 % kleinere Aufträge |
| Kopien | Bild wird n-mal gesendet | **`^PQ`**: Bild einmal senden, Drucker vervielfältigt |
| Etikettenformate | Stocks | 40+ Formate (inkl. DHL/DPD/GLS), eigene Formate, „vom Drucker übernehmen“ |
| Eigene Befehle vor/nach dem Auftrag | ✔ | ✔ mit Syntaxhervorhebung |
| Werkzeuge: Kalibrieren, Konfigurationsetikett, Reset, Werkseinstellungen … | ✔ | ✔ + Kalibrier-Assistent, Halten-zum-Bestätigen |
| Status | Statusfenster | **Live-Übersicht** mit animiertem Drucker, Meldungen mit Lösungsschritten, Kennzahlen, Verlauf, Menüleiste, Mitteilungen |
| Kommunikation mit dem Drucker | Terminal | **Terminal** mit Hervorhebung, Autovervollständigung, ZPL-Referenz (120+ Befehle), Hex-Ansicht |
| Einstellungs-Explorer (SGD) | – | ✔ alle Link-OS-Einstellungen durchsuchen & bearbeiten |
| Schriften & Grafiken laden | ✔ | ✔ mit Schriftvorschau, Rasterungsvorschau, Probedruck |
| Netzwerk & WLAN konfigurieren | ✔ | ✔ mit Validierung und Änderungsübersicht |
| Firmware-Update | ✔ | ✔ mit Fortschritt, Prüfsumme, automatischem Neuverbinden |
| Etiketten-Designer | separates Produkt | ✔ integriert: ZPL-Editor + Echtzeit-Vorschau (Vektor & pixelgenau), Vorlagen, Barcodes, Bild/PDF → Etikett |
| Auftragsverlauf | – | ✔ mit Vorschau, Statistik, „Erneut drucken“, CSV-Export |
| Verbindungen | USB, Netzwerk | **USB, Netzwerk (TCP 9100), Bluetooth, Bluetooth LE, macOS-Warteschlangen** + automatische Suche (Bonjour, USB, Subnetz-Scan, CUPS) |
| Ausprobieren ohne Drucker | – | ✔ **Demo-Drucker** – vollständig simulierter ZD421t |
| Kommandozeile | – | ✔ `lwctl` (macOS & Linux) |

## Schnellstart

1. `LabelWerk-<version>.pkg` installieren (installiert App, Treiber-Filter und PPDs).
2. LabelWerk öffnen – der Einrichtungsassistent findet angeschlossene und Netzwerk-Drucker.
3. Drucker hinzufügen, optional als macOS-Drucker einrichten – fertig. Ab jetzt druckt jede App
   (Vorschau, Pages, Versand-Tools …) direkt auf das Etikett.

Ausführlich: [docs/INSTALLATION.md](docs/INSTALLATION.md)

## Projektaufbau

```
Package.swift                 SwiftPM: Kernmodule, CLI, App (nur macOS)
Catalog/                      Modell- & Etikettenkatalog (einzige Quelle)
Sources/
  LabelWerkCore/              Typen, Katalog, ZPL/EPL/CPCL/SGD-Befehle, Testetikett
  LabelWerkImaging/           Bitmaps, Rasterung, Z64/ACS/Hex, PNG, Job-Encoder
  LabelWerkBarcode/           Code 128/39/93, EAN/UPC, ITF, Codabar, QR, DataMatrix, PDF417
  LabelWerkRender/            ZPL-Interpreter, Software-Rasterizer, Befehlsreferenz
  LabelWerkStatus/            Statusparser (~HS, ~HQES, ~HI, SGD, ^HH), Meldungen
  LabelWerkTransport/         TCP, USB, Bluetooth, BLE, CUPS, Druckersuche
  LabelWerkKit/               PrinterClient, Virtueller Drucker
  lwctl/                      Kommandozeilen-Werkzeug
  LabelWerkApp/               SwiftUI-App
Driver/filter/                CUPS-Filter in C (+ Tests, Python-Referenz-Encoder)
Driver/ppd/                   PPD-Generator
Installer/, Scripts/          App-Bundle, .pkg, Notarisierung, Icons, Lokalisierung
```

Architektur und Schnittstellen: [ARCHITECTURE.md](ARCHITECTURE.md) ·
App-Aufbau: [docs/APP_ARCHITECTURE.md](docs/APP_ARCHITECTURE.md) ·
Entwicklung: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)

## Bauen

```bash
make test        # Swift-Tests, Filter-Tests (C + End-to-End), PPD-Tests
make app         # LabelWerk.app (macOS, Universal Binary)
make pkg         # Installationspaket dist/LabelWerk-<version>.pkg
```

Voraussetzungen: macOS 14+ mit Xcode 16 (für App & Paket); Kern, Filter und CLI bauen auch unter
Linux (Swift 6, `libcups2-dev`, `zlib1g-dev`).

## Kommandozeile

```bash
lwctl discover                         # Drucker suchen
lwctl --printer tcp://192.168.1.50 status
lwctl --printer tcp://192.168.1.50 print versand.png --stock w4h6in --dither atkinson
lwctl render etikett.zpl -o vorschau.png
lwctl virtual-printer --port 9100      # Demo-Drucker im Netzwerk bereitstellen
```

## Drittanbieter

Die eingebaute Bitmap-Schrift des Software-Rasterizers basiert auf DejaVu Sans (Bitstream-Vera-
Lizenz, siehe Quelltext). Es werden keine externen Swift-Pakete verwendet; der Filter nutzt
`libcups` und `zlib` des Systems.

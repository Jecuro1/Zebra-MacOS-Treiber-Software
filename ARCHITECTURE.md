# LabelWerk – Architektur & Schnittstellenvertrag

LabelWerk ist ein moderner macOS-Treiber samt Steuerzentrale für Zebra®-Etikettendrucker
(ZPL II, EPL2, CPCL). Funktionsumfang mindestens wie der Windows-ZDesigner-Treiber plus
Zebra Setup Utilities – mit nativer SwiftUI-Oberfläche, Animationen und Live-Status.

> Dieses Dokument ist **verbindlich**. Alle Module implementieren exakt die hier genannten
> öffentlichen Namen und Signaturen. Interne Details sind frei. Erweiterungen sind erlaubt,
> Umbenennungen nicht.

## 1. Überblick

```
┌──────────────────────── macOS ────────────────────────────────────────────┐
│  LabelWerk.app (SwiftUI)          CUPS (cupsd)                            │
│   ├─ Druckerverwaltung             ├─ PPD  /Library/Printers/PPDs/…       │
│   ├─ Live-Status / Menüleiste      ├─ cgpdftoraster (Apple)               │
│   ├─ Einstellungen → lpadmin -o    └─ rastertolabelwerk (unser C-Filter)  │
│   ├─ Werkzeuge, Terminal, Designer        │  ZPL / EPL / CPCL             │
│   └─ LabelWerkKit ──────────────┐         ▼                               │
│                                 └──► USB · TCP 9100 · Bluetooth · CUPS    │
└───────────────────────────────────────────────────────────────────────────┘
```

| Pfad | Inhalt |
|---|---|
| `Package.swift` | SwiftPM-Paket (Kern + CLI; App nur auf macOS) |
| `Catalog/models.json` | **Einzige Quelle** für Modelle & Etikettenformate (erzeugt von `Catalog/build_catalog.py`) |
| `Sources/LabelWerkCore` | Typen, Modellkatalog, Befehlsbausteine ZPL/EPL/CPCL/SGD, Aktionen, Testetikett |
| `Sources/LabelWerkImaging` | `GrayImage`, `MonoBitmap`, Dithering, Grafik-Encoder, PNG, `JobEncoder` |
| `Sources/LabelWerkBarcode` | 1D/2D-Barcode-Encoder |
| `Sources/LabelWerkRender` | ZPL-Parser, Interpreter → `LabelDocument`, Software-Rasterizer |
| `Sources/LabelWerkStatus` | Parser für `~HS`, `~HQES`, `~HI`, SGD, `^HH`, Dateilisten; Alarme |
| `Sources/LabelWerkTransport` | `PrinterConnection` (TCP, USB, Bluetooth, BLE, CUPS) & Discovery |
| `Sources/LabelWerkKit` | `PrinterClient` (High-Level-API) + Umbrella-Exports |
| `Sources/lwctl` | CLI (`lwctl discover/status/print/send/render/…`) |
| `Sources/LabelWerkApp` | SwiftUI-App (nur macOS) |
| `Driver/filter` | C-Filter `rastertolabelwerk`, `commandtolabelwerk`, Tests, Makefile |
| `Driver/ppd` | PPD-Generator (`generate_ppds.py`) |
| `Installer` | App-Bundle-, Paket-, Notarisierungs-Skripte, Info.plist, Lokalisierung, Icon |
| `.github/workflows` | CI (Linux: Kern/Filter/PPD; macOS: App, Universal-Filter, .pkg) |

Plattformziel: **macOS 14 Sonoma** und neuer (Apple Silicon & Intel, Universal Binary).
Liquid-Glass-Effekte werden ab macOS 26 automatisch genutzt (`#if compiler(>=6.2)` +
`if #available(macOS 26.0, *)`).

Sprache der Oberfläche & Doku: **Deutsch** (Entwicklungssprache), Englisch als Übersetzung.

## 2. Swift-Konventionen

* Swift 6 Sprachmodus für alle Bibliotheken (strikte Nebenläufigkeit). App: Swift 5-Modus.
* Bibliotheken dürfen **nur Foundation** (+ `CZlib`) importieren und müssen auf Linux bauen.
  Apple-only-Code (IOKit, IOBluetooth, CoreBluetooth, Network, AppKit, CoreGraphics) nur hinter
  `#if os(macOS)` bzw. `#if canImport(X)`.
* Öffentliche Werttypen: `Sendable`, wo sinnvoll `Hashable`/`Codable`.
* Tests mit **Swift Testing** (`import Testing`, `@Test`, `#expect`). Testdateien je Modul unter
  `Tests/<Modul>Tests/`. Platzhalterdateien `_Placeholder.swift` beim Implementieren löschen.
* Kommentare/Doku auf Deutsch, Bezeichner auf Englisch.
* Keine externen Abhängigkeiten (kein SwiftPM-Fremdpaket).

## 3. LabelWerkCore (bereits vorhanden: `Types/`, `Catalog/`)

Vorhandene Typen (nicht ändern, nur erweitern): `Resolution`, `PrinterLanguage`, `MediaType`,
`MediaTracking`, `PrintMode`, `DitherAlgorithm`, `GraphicCompression`, `BackfeedMode`,
`FieldOrientation`, `PrinterCategory`, `Connectivity`, `PrinterFeature`, `PrintSettings`
(inkl. `cupsOptions()` / `init(cupsOptions:)`), `CUPSOptionName`, `CUPSCommandEncoding`,
`LabelStock`, `PrinterModel`, `ModelCatalog`.

Zu implementieren:

```swift
/// Ein einzelner ZPL-Befehl, z. B. ^FO50,50 oder ~JC.
public struct ZPLCommand: Hashable, Sendable, CustomStringConvertible {
    public enum Prefix: Character, Sendable { case caret = "^", tilde = "~" }
    public var prefix: Prefix
    public var code: String          // zwei/drei Zeichen, z. B. "FO", "A0", "GFA"? -> "GF"
    public var parameters: [String]  // werden mit "," verbunden
    public init(_ prefix: Prefix = .caret, _ code: String, _ parameters: [String] = [])
    public var description: String   // gerenderte Form
}

@resultBuilder public enum ZPLFormatBuilder { … }   // baut [ZPLCommand]

public enum ZPL {
    // Format
    static func format(@ZPLFormatBuilder _ content: () -> [ZPLCommand]) -> String  // ^XA … ^XZ
    static func startFormat() -> ZPLCommand            // ^XA
    static func endFormat() -> ZPLCommand              // ^XZ
    static func changeEncoding(utf8: Bool = true) -> ZPLCommand   // ^CI28
    static func comment(_ text: String) -> ZPLCommand  // ^FX
    // Felder
    static func fieldOrigin(x: Int, y: Int) -> ZPLCommand            // ^FOx,y
    static func fieldTypeset(x: Int, y: Int) -> ZPLCommand           // ^FTx,y
    static func font(_ name: String = "0", orientation: FieldOrientation = .normal,
                     height: Int, width: Int? = nil) -> ZPLCommand    // ^A0N,h,w
    static func fieldBlock(width: Int, maxLines: Int = 1, lineSpacing: Int = 0,
                           justification: String = "L", hangingIndent: Int = 0) -> ZPLCommand // ^FB
    static func fieldData(_ text: String) -> [ZPLCommand]   // ^FH^FD… (maskiert ^ ~ \ als _5E _7E _5C) – liefert ^FH + ^FD
    static func fieldSeparator() -> ZPLCommand              // ^FS
    static func fieldReverse() -> ZPLCommand                // ^FR
    static func text(_ text: String, x: Int, y: Int, height: Int, width: Int? = nil,
                     font: String = "0", orientation: FieldOrientation = .normal) -> [ZPLCommand] // ^FO^A^FH^FD^FS
    // Grafik
    static func graphicBox(width: Int, height: Int, thickness: Int = 1, color: String = "B", rounding: Int = 0) -> ZPLCommand // ^GB
    static func graphicCircle(diameter: Int, thickness: Int = 1, color: String = "B") -> ZPLCommand  // ^GC
    static func graphicEllipse(width: Int, height: Int, thickness: Int = 1, color: String = "B") -> ZPLCommand // ^GE
    static func graphicDiagonal(width: Int, height: Int, thickness: Int = 1, color: String = "B", orientation: String = "R") -> ZPLCommand // ^GD
    // Barcodes
    static func barcodeDefaults(moduleWidth: Int, ratio: Double = 3.0, height: Int = 10) -> ZPLCommand // ^BY
    static func code128(orientation: FieldOrientation = .normal, height: Int, printInterpretation: Bool = true, above: Bool = false) -> ZPLCommand // ^BC
    static func code39(…) / ean13(…) / ean8(…) / upcA(…) / interleaved2of5(…) / qrCode(magnification: Int, errorCorrection: String = "M") / dataMatrix(moduleSize: Int) / pdf417(…)
    // Label-/Drucker-Setup
    static func printWidth(_ dots: Int) -> ZPLCommand        // ^PW
    static func labelLength(_ dots: Int) -> ZPLCommand       // ^LL
    static func labelHome(x: Int, y: Int) -> ZPLCommand      // ^LH
    static func labelTop(_ dots: Int) -> ZPLCommand          // ^LT
    static func labelShift(_ dots: Int) -> ZPLCommand        // ^LS
    static func printQuantity(_ q: Int, pauseCount: Int = 0, replicates: Int = 0, overridePause: Bool = false) -> ZPLCommand // ^PQ
    static func printRate(_ ips: Int) -> ZPLCommand          // ^PRs,s,s
    static func setDarkness(_ value: Int) -> ZPLCommand      // ~SD (zweistellig: ~SD08)
    static func mediaDarkness(relative: Int) -> ZPLCommand   // ^MD
    static func mediaType(_ t: MediaType) -> ZPLCommand      // ^MT
    static func mediaTracking(_ t: MediaTracking) -> ZPLCommand // ^MN
    static func printMode(_ m: PrintMode) -> ZPLCommand      // ^MM
    static func backfeed(_ b: BackfeedMode) -> ZPLCommand    // ~JS (Steuerbefehl; ^JS wäre die Sensorwahl)
    static func printOrientation(inverted: Bool) -> ZPLCommand // ^POI / ^PON
    static func mirror(_ on: Bool) -> ZPLCommand             // ^PMY / ^PMN
    static func tearOffAdjust(_ dots: Int) -> ZPLCommand     // ~TA (Format: ~TA%03d, z. B. ~TA010, ~TA-10)
    static func saveSettings() -> ZPLCommand                 // ^JUS
    // Gerätebefehle
    static func calibrate() -> ZPLCommand                    // ~JC
    static func sensorProfile() -> ZPLCommand                // ~JG
    static func hostStatus() -> ZPLCommand                   // ~HS
    static func hostIdentification() -> ZPLCommand           // ~HI
    static func hostQueryErrors() -> ZPLCommand              // ~HQES
    static func hostConfiguration() -> ZPLCommand            // ^XA^HH^XZ (als Format-String: siehe `PrinterAction`)
    static func printConfiguration() -> ZPLCommand           // ~WC
    static func feed() -> ZPLCommand                         // ~PH
    static func pause() -> ZPLCommand                        // ~PP
    static func resume() -> ZPLCommand                       // ~PS
    static func cancelAll() -> ZPLCommand                    // ~JA
    static func cancelCurrent() -> ZPLCommand                // ~JX
    static func reset() -> ZPLCommand                        // ~JR
    // Dateien
    static func downloadTrueTypeFont(name: String, drive: String = "E:", data: Data) -> Data // ~DY{drive}{NAME},B,T,{len},,<bin>
    static func deleteObject(_ path: String) -> ZPLCommand   // ^ID
    static func hostDirectory(_ pattern: String = "E:*.*") -> String   // ^XA^HW{pattern}^XZ (Antwort an Host)
    static func printDirectory(_ pattern: String = "E:*.*") -> String  // ^XA^WD{pattern}^XZ (druckt Liste)
}

public enum EPL { … }   // N, q, Q, S, D, ZT/ZB, O…, GW, A, B, LO, X, P, U (Konfig), xa (Autosense), ^@ (Reset)
public enum CPCL { … }  // ! 0 … , PAGE-WIDTH, CONTRAST, SPEED, TEXT, BARCODE, CG/EG, FORM, PRINT
public enum SGD {
    static func getvar(_ name: String) -> String          // ! U1 getvar "name"\r\n
    static func setvar(_ name: String, _ value: String) -> String // ! U1 setvar "name" "value"\r\n
    static func `do`(_ name: String, _ value: String = "") -> String // ! U1 do "name" "value"\r\n
    static func jsonGet(_ names: [String]) -> String      // {}{"a":null,"b":null}
    static let allConfigJSON: String                       // {}{"allconfig":null}
    static let commonVariables: [String]                   // wichtige SGD-Namen (siehe unten)
}

/// Gerätebefehle, wie sie die Werkzeug-Seite anbietet.
public enum PrinterAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case printConfiguration, printNetworkConfiguration, calibrate, sensorProfile, feedLabel,
         pause, resume, cancelAll, cancelCurrent, reset, restoreFactoryDefaults,
         restoreNetworkDefaults, saveSettings, printTestLabel, printDirectory, printFontList? (nicht nötig)
    public var id: String
    public var displayName: String      // Deutsch
    public var detail: String           // Deutsch, ein Satz
    public var systemImage: String      // SF Symbol
    public var isDestructive: Bool      // reset, Werkseinstellungen …
    public func payload(language: PrinterLanguage, resolution: Resolution = .dpi203,
                        widthDots: Int = 812, heightDots: Int = 1218) -> Data?  // nil = nicht unterstützt
}

public enum TestLabel {
    /// Hochwertiges Testetikett (Rahmen, Titel, Datum, Modell, Code128, QR, Schwärzungs-Skala, Lineal).
    static func zpl(widthDots: Int, heightDots: Int, resolution: Resolution, title: String = "LabelWerk", subtitle: String = "") -> String
    static func epl(widthDots: Int, heightDots: Int, resolution: Resolution, title: String = "LabelWerk") -> String
    static func cpcl(widthDots: Int, heightDots: Int, resolution: Resolution, title: String = "LabelWerk") -> String
}
```

`ZPLCommand.description`: `prefix + code + parameters.joined(",")`. Für `^FD` enthält
`parameters` genau ein Element (die bereits maskierten Daten).

### 3.1 Treiberoptionen wie im Windows-Dialog „Druckeinstellungen für ZD421 …“

Erweiterungen der vorhandenen Typen (quellkompatibel; neue `PrintSettings.init`-Parameter mit
Standardwerten **am Ende**):

```swift
extension MediaTracking { case notch }          // ^MNW, cupsValue "Notch"; EPL wie gap
// displayName (Windows „Medientyp“): continuous „Endlosmaterial“, gap „Einzeletiketten“,
// blackMark „Etiketten mit schwarzen Markierungen“, notch „Etiketten mit Seitenkerben“,
// autoDetect „Automatisch erkennen“
extension PrintMode {                           // Windows „Bedienermodus“
    case linerlessPeel, linerlessCut, linerlessDelayedCut, linerlessRewind, linerlessTear
    // cupsValue LinerlessPeel … LinerlessTear
    var sgdValue: String          // media.printmode wie getvar ihn meldet: "tear off" "peel off" "cutter"
                                  // "delayed cut" "rewind" "applicator" "kiosk" "linerless peel"
                                  // "linerless cut" "linerless delayed cut" "linerless rewind" "linerless tear"
    var sgdSetValue: String       // setvar-Wert laut Zebra-SGD-Referenz: "T" "P" "C" "D" "R" "A" "K",
                                  // Linerless "L" (ablösen), "U" (aufwickeln), "V" (abreißen); für
                                  // Linerless schneiden/verzögert schneiden ist kein Buchstabe dokumentiert
                                  // → "linerless cut" / "linerless delayed cut"
    init?(sgdValue: String)       // tolerant: Groß-/Kleinschreibung, "_"/"-" statt Leerzeichen; nimmt auch sgdSetValue an
    var isLinerless: Bool
    var usesSGD: Bool             // == isLinerless: kein ^MM, nur SGD media.printmode
    var mmCode: String?           // T P C D R A K; nil für Linerless
    var zplCode: String           // unverändert String; Linerless: Code des classicEquivalent
    var classicEquivalent: PrintMode   // linerlessPeel → peelOff, …Cut → cutter, …DelayedCut → delayedCut,
                                       // …Rewind → rewind, …Tear → tearOff
    var usesCutter: Bool          // cutter, delayedCut, kiosk, linerlessCut, linerlessDelayedCut
    init?(zplCode:)               // liefert nur klassische Modi
    // displayName: Abreißen, Spendemodus, Abschneider, Verzögerter Abschneider, Aufwickeln,
    // Applikator, Kiosk, Linerless ablösen, Linerless schneiden, Linerless verzögert schneiden,
    // Linerless aufwickeln, Linerless-Abriss
}
// MediaType.displayName: „Thermotransfer“ / „Thermo-Direkt“
// BackfeedMode.displayName: off „Kein Rückzug“, beforePrinting „Vor dem Drucken“,
//                           afterPrinting „Nach dem Drucken“, normal „Standard“

public enum PrintRotation: Int, Codable, CaseIterable, Sendable, Identifiable {
    case r0 = 0, r90 = 90, r180 = 180, r270 = 270   // im Uhrzeigersinn
    var cupsValue: String; init?(cupsValue:)         // "0" "90" "180" "270"
    var degrees: Int; var isQuarterTurn: Bool        // 90/270
    var displayName: String   // „0° – Hochformat“, „90° – Querformat“, „180° – Hochformat“, „270° – Querformat“
}
public enum RTCUpdate: String, Codable, CaseIterable, Sendable, Identifiable {
    case jobStart, everyLabel, everyMinute          // cupsValue JobStart EveryLabel EveryMinute
    // displayName „Druckzeit starten“, „Jedes Etikett“, „Jede Minute“
}
public enum MediaFeedAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case feed, calibrate, length, noMotion, shortCalibration
    var zplCode: String       // F C L N S (^MF)
    var cupsValue: String     // Feed Calibrate Length NoMotion ShortCal
    var sgdValue: String      // feed calibrate length "no motion" "short cal" (ezpl.power_up_action …)
}
public struct ControlCharacters: Codable, Hashable, Sendable {
    public var formatPrefix: UInt8 = 0x5E, controlPrefix: UInt8 = 0x7E, delimiter: UInt8 = 0x2C
    public static let standard: ControlCharacters
    public static let validRange: ClosedRange<UInt8>   // 33…126
    public func clamped() -> ControlCharacters           // ungültig → jeweiliges Standardzeichen
    public static func character(from text: String) -> UInt8?   // SGD-Wert "^" → 0x5E
}

extension PrintSettings {        // neue gespeicherte Eigenschaften (Standardwert)
    var rotation: PrintRotation = .r0
    var markOffset: Int? = nil              // Punkte −80…283, ^MNM,{n} (nur blackMark)
    var stopAtLastElement: Bool = false     // nur Endlosmaterial
    var stopOffset: Int = 0                 // Punkte 0…32000
    var pauseEvery: Int = 0                 // 0…9999, ^PQ{n},{p},0,N (Vorrang vor cutEvery)
    var controlCharacters: ControlCharacters? = nil   // nil = „Standard“, sonst „Intern“ (Zeichen des Druckers)
    var rtcUpdate: RTCUpdate? = nil
    var cancelJobsBeforePrint: Bool = false // ~JA
    var cancelDelayMs: Int = 1000           // 0…10000
    var labelStartCommands: String = ""     // je Etikett nach ^XA
    var labelEndCommands: String = ""       // je Etikett vor ^XZ
    var powerUpAction: MediaFeedAction? = nil, headCloseAction: MediaFeedAction? = nil  // ^MF (nur beide)
    var effectiveRotation: PrintRotation    // rotation != .r0 ? rotation : (rotate180 ? .r180 : .r0)
    var effectiveControlCharacters: ControlCharacters   // controlCharacters?.clamped() ?? .standard
    var hasMediaFeedActions: Bool
}

// An Etikett anpassen (macOS-Druckdialog schickt A4/Letter/„Andere“ statt der Etikettengröße, §8 „F“)
public enum LabelFitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, off                           // cupsValue "Auto" "Off"; displayName „Automatisch“ „Aus“
}
extension PrintSettings {        // neue gespeicherte Eigenschaften (Standardwert), init-Parameter am Ende
    var fitToLabel: LabelFitMode = .auto            // lwFitToLabel
    var labelWidthHundredthsMM: Int = 0             // lwLabelWidth, 1/100 mm, 0…100 000 (0 = unbekannt)
    var labelHeightHundredthsMM: Int = 0            // lwLabelHeight, 1/100 mm, 0…100 000 (0 = unbekannt/endlos)
    static let maxLabelSizeHundredthsMM = 100_000
    var labelSizeMM: (width: Double, height: Double)?           // nil, solange die Breite 0 ist
    mutating func setLabelSize(widthMM: Double, heightMM: Double) // auf 1/100 mm gerundet, ≤ 0/ungültig → 0
    func withLabelSize(of stock: LabelStock?) -> PrintSettings    // Endlosmaterial: Länge 0; nil → beide 0
}
```

`lwLabelWidth`/`lwLabelHeight` stammen aus dem Etikettenformat der Warteschlange (nicht aus einer
Benutzereingabe): Wer Warteschlangen-Standards schreibt (App, `lwctl install`, postinstall), setzt sie
vorher mit `withLabelSize(of:)`; `cupsOptions()` lässt den Wert 0 weg (wie leere Befehle), beide
stehen in `CUPSOptionName.nonPPD` (Warteschlangen-Standard `-o lwLabelWidth-default=10400`).

`rotate180` (`lwRotate180`) bleibt als veralteter Alias erhalten. `clamped()` begrenzt die neuen
Zahlen und ersetzt ungültige Steuerzeichen; `init(from:)` dekodiert fehlende/ungültige Werte mit
Standardwerten; `cupsOptions()`/`init(cupsOptions:)` bilden alle Felder ab (§9, Rundreise exakt).
`CUPSOptionName` kennt die neuen Namen (`all`) sowie `nonPPD` (Optionen ohne PPD-Eintrag).

Befehlsbausteine: `ZPL.mediaTracking(_:markOffset:)` (`^MNM,{n}`, sonst `^MN{code}`),
`ZPL.printModeCommand(_:) -> ZPLCommand?` (`nil` für Linerless),
`ZPL.mediaFeed(powerUpAction:headCloseAction:)` (`^MF{a},{b}`), `ZPL.setRealTimeClock(_:timeZone:)`
(`^ST{MM},{DD},{YYYY},{HH},{mm},{SS},M`), `ZPL.realTimeClockFormat(_:timeZone:)` (`^XA^ST…^XZ`),
`ZPLCommand.rendered(with: ControlCharacters)` und `ZPL.render(_:characters:)` (eigene Steuerzeichen),
`SGD.setPrintMode(_:)` (`! U1 setvar "media.printmode" "{sgdSetValue}"\r\n`),
`SGD.printSettingsVariables` (für `PrinterClient.readPrintSettings()`).

## 4. LabelWerkImaging

```swift
public struct GrayImage: Hashable, Sendable {        // 8 Bit Luminanz, 0 = schwarz, 255 = weiß
    public let width: Int, height: Int
    public var pixels: [UInt8]                        // zeilenweise, count == width*height
    public init(width: Int, height: Int, fill: UInt8 = 255)
    public init(width: Int, height: Int, pixels: [UInt8])
    public subscript(x: Int, y: Int) -> UInt8 { get set }
    public func rotated(_ turn: QuarterTurn) -> GrayImage
    public func mirrored() -> GrayImage
    public func inverted() -> GrayImage
    public func scaled(width: Int, height: Int) -> GrayImage          // Flächenmittel (Box) beim Verkleinern, bilinear beim Vergrößern
    public func cropped(x: Int, y: Int, width: Int, height: Int) -> GrayImage
    public func adjusted(brightness: Double = 0, contrast: Double = 0, gamma: Double = 1) -> GrayImage // brightness/contrast −1…1
    public func padded(toWidth: Int, height: Int, alignment: …) -> GrayImage  // optional
}
public enum QuarterTurn: Int, Sendable, CaseIterable { case r0 = 0, r90 = 90, r180 = 180, r270 = 270 }

public struct MonoBitmap: Hashable, Sendable {       // 1 Bit, MSB zuerst, 1 = schwarz (Punkt brennt)
    public let width: Int, height: Int
    public var bytesPerRow: Int { (width + 7) / 8 }
    public var data: [UInt8]                          // count == bytesPerRow*height, Füllbits = 0
    public init(width: Int, height: Int)
    public init(width: Int, height: Int, data: [UInt8])
    public subscript(x: Int, y: Int) -> Bool { get set }
    public var isBlank: Bool
    public func isRowBlank(_ y: Int) -> Bool
    public func rotated180() -> MonoBitmap
    public func rotated(_ turn: QuarterTurn) -> MonoBitmap
    public func mirrored() -> MonoBitmap
    public func inverted() -> MonoBitmap              // Füllbits bleiben 0
    public func cropped(x: Int, y: Int, width: Int, height: Int) -> MonoBitmap
    public func toGrayImage() -> GrayImage
    public var blackPixelCount: Int
}

public enum Ditherer {
    static func dither(_ image: GrayImage, algorithm: DitherAlgorithm, threshold: Int = 128) -> MonoBitmap
}

public enum CRC16 { static func xmodem<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 } // Poly 0x1021, Init 0
public enum Deflate {                                 // zlib-Format (RFC 1950), Level = Z_DEFAULT_COMPRESSION
    static func compress(_ data: Data) throws -> Data
    static func decompress(_ data: Data) throws -> Data
}
public enum Z64 {
    static func encode(_ data: Data) throws -> String        // ":Z64:" + base64(zlib(data)) + ":" + %04X(CRC16.xmodem(base64-ASCII))
    static func decode(_ string: String) throws -> Data       // akzeptiert mit/ohne CRC, prüft CRC wenn vorhanden
}
public enum ACS {                                     // Zebra Alternative Compression Scheme
    static func encode(_ bitmap: MonoBitmap) -> String
    static func decode(_ string: String, bytesPerRow: Int, totalBytes: Int) throws -> [UInt8]
}
public enum ZPLGraphicEncoder {
    static func graphicField(_ bitmap: MonoBitmap, compression: GraphicCompression) -> String
        // "^GFA,{total},{total},{bpr},{daten}"
    static func downloadGraphic(name: String, drive: String = "R:", bitmap: MonoBitmap) -> String
        // "~DG{drive}{NAME}.GRF,{total},{bpr},{hex}"
    static func decodeGraphicField(format: String, totalBytes: Int, bytesPerRow: Int, data: String) throws -> MonoBitmap
        // format A (ASCII-Hex inkl. ACS/Z64/:B64:) und B (binär als ISO-Latin-1-String)
}
public enum EPLGraphicEncoder  { static func gw(x: Int, y: Int, bitmap: MonoBitmap) -> Data }   // EPL: Bit 0 = schwarz!
public enum CPCLGraphicEncoder { static func cg(x: Int, y: Int, bitmap: MonoBitmap) -> Data
                                 static func eg(x: Int, y: Int, bitmap: MonoBitmap) -> String }
public enum PNGCodec {
    static func encode(_ image: GrayImage) -> Data              // 8-Bit Graustufen
    static func encode(_ bitmap: MonoBitmap) -> Data            // 1-Bit Graustufen
    static func decode(_ data: Data) throws -> GrayImage        // Farbtypen 0,2,3,4,6; Tiefe 1–16; Interlace optional; Alpha auf Weiß
}
public enum PNMCodec { static func decode(_ data: Data) throws -> GrayImage } // P1/P2/P4/P5 (für Tests/CLI)

/// Baut komplette Druckaufträge aus Bitmaps – identisches Byteformat wie der C-Filter (§8).
public struct JobEncoder: Sendable {
    public init(language: PrinterLanguage, resolution: Resolution, settings: PrintSettings,
                stock: LabelStock? = nil, maxPrintWidthDots: Int? = nil,
                timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() })
    public var timeZone: TimeZone                 // Ortszeit für ^ST
    public var now: @Sendable () -> Date          // Zeitquelle für ^ST (Tests: feste Zeit)
    public var timeStepSeconds: Int64             // Tests: Etikett k sieht now() + k·timeStepSeconds (Standard 0)
    public func encode(pages: [MonoBitmap], copies: Int = 1, collate: Bool = true) throws -> Data
    public func encode(images: [GrayImage], copies: Int = 1, collate: Bool = true) throws -> Data // dithert gemäß settings
    public func encode(images: [GrayImage], pageSizes: [PageSizePoints?], copies: Int = 1, collate: Bool = true) throws -> Data
        // wie oben, vorher je Bild Schritt F aus §8 (An Etikett anpassen) mit seiner Seitengröße
        // (pageSizes.count == images.count, sonst ImagingError.invalidArgument; nil = Etikettengröße)
    public func fitted(_ image: GrayImage, pageSize: PageSizePoints?) -> GrayImage   // nur Schritt F
    public func fitted(_ image: GrayImage, pageSize: PageSizePoints?, reference: inout LabelFit.Reference?) -> GrayImage
        // Schritt F Seite für Seite (Referenz von Seite zu Seite) – nacheinander = fitted(_:pageSizes:)
    public func dithered(_ image: GrayImage) -> MonoBitmap   // Rastern wie encode(images:) (settings.dither/threshold)
        // App „Etikettendruck“: fitted(…, reference:) → dithered → Vorschau mit preprocess, Druck mit
        // encode(pages:) – dieselben Bytes wie encode(images:pageSizes:)
    public func preprocess(_ page: MonoBitmap) -> MonoBitmap?     // Schritte (0)–(5) aus §8, z. B. für Vorschauen
    public func cancelPrefixLength() -> Int?      // Länge der ~JA-Zeile am Auftragsanfang (Aufrufer wartet danach)
}

/// Seitengröße in PostScript-Punkten (1/72 Zoll) – wie `cupsPageSize` im CUPS-Rasterkopf.
public struct PageSizePoints: Hashable, Sendable, Codable {
    public var width: Double; public var height: Double
    public static let a4: PageSizePoints       // 595,28 × 841,89
    public static let letter: PageSizePoints   // 612 × 792
}

/// Schritt F aus §8 („An Etikett anpassen“), byte-gleich zu `lw_fit` (C) und `fit_page` (Python).
public enum LabelFit {
    public static let contentLevel = 250            // Inhalt ⇔ L < 250
    public static let toleranceHundredthsMM = 200   // 2 mm
    public static let maxDots = 32_000
    public static let marginHundredthsMM = 150      // Sicherheitsrand je Seite (1,5 mm)
    public struct Plan: Hashable, Sendable {        // Etikett in Punkten (nil = frei) + Rand je Seite in Punkten
        public var width: Int?; public var height: Int?; public var marginX: Int; public var marginY: Int
    }
    public static func plan(settings: PrintSettings, pageSize: PageSizePoints?, xDPI: Int, yDPI: Int,
                            imageWidth: Int, imageHeight: Int) -> Plan?   // nil = keine Anpassung
    public static func hundredthsMM(fromPoints points: Double) -> Int?    // ⌊pt·2540/72 + 0,5⌋, nil wenn ungültig
    public static func margin(dpi: Int) -> Int                            // (150·dpi + 1270) / 2540
    public static func contentBounds(_ image: GrayImage) -> (x: Int, y: Int, width: Int, height: Int)?
    public static func rotation(contentWidth: Int, contentHeight: Int, plan: Plan) -> QuarterTurn  // F.3: r0/r90/r270
    public static func box(contentWidth: Int, contentHeight: Int, plan: Plan) -> (width: Int, height: Int)    // F.4
    public static func targetSize(contentWidth: Int, contentHeight: Int, plan: Plan) -> (width: Int, height: Int)
    public static func areaAverage(_ image: GrayImage, x: Int, y: Int, width: Int, height: Int,
                                   toWidth: Int, toHeight: Int) -> GrayImage   // Flächenmittel (auch vergrößern), nur Ganzzahlen
    public static func apply(_ image: GrayImage, plan: Plan) -> GrayImage
}
```


### 4.1 Rasterung – exakte Spezifikation (identisch in Swift **und** C)

Eingabe: Luminanz `L(x,y)` ∈ 0…255 (0 = schwarz), Schwelle `T` ∈ 1…254. Ausgabe schwarz = Punkt.
Alle Divisionen sind Ganzzahldivisionen mit Abschneiden Richtung 0 (C/Swift `/`).

* **threshold**: schwarz ⇔ `L < T`.
* **ordered**: `t = B[y%8][x%8]*4 + 2 + (T − 128)`; schwarz ⇔ `L < t`. `B` = Bayer 8×8:
  ```
   0 32  8 40  2 34 10 42 / 48 16 56 24 50 18 58 26 / 12 44  4 36 14 46  6 38 / 60 28 52 20 62 30 54 22
   3 35 11 43  1 33  9 41 / 51 19 59 27 49 17 57 25 / 15 47  7 39 13 45  5 37 / 63 31 55 23 61 29 53 21
  ```
* **halftone**: wie `ordered`, aber mit Clustered-Dot-Matrix `H`:
  ```
  24 10 12 26 35 47 49 37 /  8  0  2 14 45 59 61 51 / 22  6  4 16 43 57 63 53 / 30 20 18 28 33 41 55 39
  34 46 48 36 25 11 13 27 / 44 58 60 50  9  1  3 15 / 42 56 62 52 23  7  5 17 / 32 40 54 38 31 21 19 29
  ```
* **Fehlerdiffusion** (floydSteinberg, atkinson, stucki): Zeilen von oben nach unten, Pixel stets von
  links nach rechts (keine Serpentine). Fehlerpuffer `Int32`. `v = L + err(x,y)`;
  `out = v < T ? 0 : 255`; schwarz ⇔ `out == 0`; `e = v − out`. Jeder Anteil wird einzeln als
  `e * w / D` berechnet und zu dem Nachbarn addiert; Anteile außerhalb des Bildes entfallen.
  * floydSteinberg (D = 16): (x+1,y)=7, (x−1,y+1)=3, (x,y+1)=5, (x+1,y+1)=1
  * atkinson (D = 8): (x+1,y)=1, (x+2,y)=1, (x−1,y+1)=1, (x,y+1)=1, (x+1,y+1)=1, (x,y+2)=1
  * stucki (D = 42): (x+1,y)=8, (x+2,y)=4; (x−2,y+1)=2, (x−1,y+1)=4, (x,y+1)=8, (x+1,y+1)=4, (x+2,y+1)=2;
    (x−2,y+2)=1, (x−1,y+2)=2, (x,y+2)=4, (x+1,y+2)=2, (x+2,y+2)=1

Umrechnung beliebiger Rasterdaten in `L` (Filter): 8-Bit W/SW: `L = v`; 8-Bit K: `L = 255 − v`;
1-Bit K: Bit 1 → 0 sonst 255; 1-Bit W/SW: Bit 0 → 0 sonst 255; RGB/sRGB: `L = (299R + 587G + 114B) / 1000`;
CMYK: `L = 255 − min(255, K + (C + M + Y) / 3)`; 16-Bit: höherwertiges Byte (Big Endian) verwenden.

## 5. LabelWerkBarcode (unabhängig, nur Foundation)

```swift
public enum BarcodeSymbology: String, Codable, CaseIterable, Sendable {
    case code128, code39, code93, ean13, ean8, upcA, upcE, interleaved2of5, codabar, qr, dataMatrix, pdf417
}
public struct LinearBarcode: Hashable, Sendable {
    public struct Element: Hashable, Sendable { public var isBar: Bool; public var width: Int } // Breite in Moduleinheiten (bei 2-Breiten-Codes: 1 = schmal, 2 = breit)
    public var elements: [Element]                 // beginnt mit Balken, OHNE Ruhezonen
    public var humanReadable: String
    public var isTwoWidth: Bool                    // Code39, I2of5, Codabar
    public func widthsInDots(moduleWidth: Int, ratio: Double) -> [(isBar: Bool, dots: Int)]
    public func totalWidth(moduleWidth: Int, ratio: Double) -> Int
    public var modules: [Bool]                     // nur für Einbreiten-Codes sinnvoll
}
public struct BitMatrix: Hashable, Sendable {
    public let width: Int, height: Int
    public var bits: [Bool]                        // zeilenweise, true = dunkel, OHNE Ruhezone
    public init(width: Int, height: Int)
    public subscript(x: Int, y: Int) -> Bool { get set }
}
public enum QRErrorCorrection: String, Sendable, CaseIterable { case low = "L", medium = "M", quartile = "Q", high = "H" }
public enum Code128Mode: Sendable { case auto, subsetA, subsetB, subsetC, ucc /* GS1-128 */ }
public enum BarcodeError: Error, Equatable { case invalidCharacter(Character), invalidLength(Int), dataTooLong, unsupported(String) }

public enum BarcodeEncoder {
    static func code128(_ text: String, mode: Code128Mode = .auto) throws -> LinearBarcode
    static func code39(_ text: String, checkDigit: Bool = false, fullASCII: Bool = false) throws -> LinearBarcode
    static func code93(_ text: String) throws -> LinearBarcode
    static func ean13(_ digits: String) throws -> LinearBarcode     // 12 oder 13 Ziffern, Prüfziffer wird berechnet/validiert
    static func ean8(_ digits: String) throws -> LinearBarcode
    static func upcA(_ digits: String) throws -> LinearBarcode
    static func upcE(_ digits: String) throws -> LinearBarcode
    static func interleaved2of5(_ digits: String, checkDigit: Bool = false) throws -> LinearBarcode
    static func codabar(_ text: String, start: Character = "A", stop: Character = "A") throws -> LinearBarcode
    static func qr(_ text: String, errorCorrection: QRErrorCorrection = .medium) throws -> BitMatrix
    static func dataMatrix(_ text: String) throws -> BitMatrix      // ECC200, quadratische Symbole
    static func pdf417(_ text: String, columns: Int = 0, securityLevel: Int = 2) throws -> BitMatrix // columns 0 = automatisch
    static func encode(_ text: String, as symbology: BarcodeSymbology) throws -> Barcode  // vereinheitlicht
}
public enum Barcode: Hashable, Sendable { case linear(LinearBarcode), matrix(BitMatrix) }
public enum BarcodeRasterizer {   // für Tests & Software-Rendering
    static func render(_ barcode: LinearBarcode, moduleWidth: Int, ratio: Double, height: Int, quietZone: Int) -> (width: Int, height: Int, pixels: [Bool])
    static func render(_ matrix: BitMatrix, moduleSize: Int, quietZone: Int) -> (width: Int, height: Int, pixels: [Bool])
}
```

## 6. LabelWerkRender

```swift
public struct LabelPoint: Hashable, Sendable, Codable { public var x: Int; public var y: Int }
public struct FieldBlock: Hashable, Sendable { width, maxLines, lineSpacing, justification: TextJustification, hangingIndent }
public enum TextJustification: String, Sendable { case left = "L", center = "C", right = "R", justified = "J" }
public enum LineColor: String, Sendable { case black = "B", white = "W" }

public struct TextElement: Hashable, Sendable {
    public var origin: LabelPoint            // linke obere Ecke des Textfelds (bei ^FT: Grundlinie → in obere Ecke umgerechnet)
    public var fontName: String              // "0", "A"…"Z", "E:ARIAL.TTF"
    public var height: Int, width: Int       // Punkte
    public var orientation: FieldOrientation
    public var text: String
    public var reverse: Bool
    public var block: FieldBlock?
}
public struct BoxElement      { origin, width, height, thickness, color: LineColor, rounding: Int, reverse: Bool }
public struct EllipseElement  { origin, width, height, thickness, color, reverse }
public struct DiagonalElement { origin, width, height, thickness, color, leansRight: Bool, reverse }
public struct GraphicElement  { origin, bitmap: MonoBitmap, magnificationX: Int, magnificationY: Int, reverse }
public struct LinearBarcodeElement { origin, symbology, barcode: LinearBarcode, moduleWidth, ratio: Double, height, orientation, printInterpretation: Bool, interpretationAbove: Bool, text: String }
public struct MatrixBarcodeElement { origin, symbology, matrix: BitMatrix, moduleSize: Int, orientation, text: String }
public enum LabelElement: Hashable, Sendable {
    case text(TextElement), box(BoxElement), ellipse(EllipseElement), diagonal(DiagonalElement),
         graphic(GraphicElement), linearBarcode(LinearBarcodeElement), matrixBarcode(MatrixBarcodeElement)
    public var boundingBox: (x: Int, y: Int, width: Int, height: Int)   // ungefähr (Text: height×Zeichen×width)
}
public struct RenderWarning: Hashable, Sendable { public var command: String; public var message: String }
public struct RenderedLabel: Hashable, Sendable {
    public var widthDots: Int, heightDots: Int, dotsPerMM: Int
    public var elements: [LabelElement]       // in Zeichenreihenfolge
    public var quantity: Int                  // ^PQ
    public var inverted: Bool                 // ^POI
    public var mirrored: Bool                 // ^PMY
    public var warnings: [RenderWarning]
}
public struct LabelDocument: Hashable, Sendable { public var labels: [RenderedLabel]; public var storedGraphics: [String: MonoBitmap] }

public struct ZPLToken: Hashable, Sendable { public var prefix: Character; public var command: String; public var arguments: String; public var range: Range<String.Index>? }
public enum ZPLTokenizer { static func tokenize(_ zpl: String) -> [ZPLToken] }   // beachtet ^CC/~CC/^CT/~CT, ^FD…^FS, ^FX
public struct ZPLInterpreter {
    public init(dotsPerMM: Int = 8, defaultWidthDots: Int = 812, defaultHeightDots: Int = 1218)
    public func render(_ zpl: String) -> LabelDocument       // wirft nie; unbekannte Befehle → warnings
}
public enum SoftwareRasterizer {
    static func rasterize(_ label: RenderedLabel) -> MonoBitmap   // eingebauter Bitmap-Font für Text
}
public enum ZPLCommandReference {   // für Terminal-Autovervollständigung & Hilfe
    public struct Entry: Hashable, Sendable { public var command: String; public var name: String; public var syntax: String; public var summary: String }
    static let entries: [Entry]     // ≥ 120 Befehle mit deutscher Kurzbeschreibung
    static func lookup(_ command: String) -> Entry?
}
```

## 7. LabelWerkStatus

```swift
public struct HostStatus: Hashable, Sendable, Codable {          // ~HS (3 Zeilen STX…ETX CR LF)
    // Zeile 1: aaa,b,c,dddd,eee,f,g,h,iii,j,k,l
    public var communicationSettings: Int, paperOut: Bool, paused: Bool, labelLengthDots: Int,
               formatsInReceiveBuffer: Int, receiveBufferFull: Bool, diagnosticMode: Bool,
               partialFormatInProgress: Bool, corruptRAM: Bool, underTemperature: Bool, overTemperature: Bool
    // Zeile 2: mmm,n,o,p,q,r,s,t,uuuuuuuu,v,www
    public var functionSettings: Int, headOpen: Bool, ribbonOut: Bool, thermalTransferMode: Bool,
               printMode: PrintMode?, printWidthMode: Int, labelWaitingToBePeeled: Bool,
               labelsRemainingInBatch: Int, formatWhileWritingGraphics: Bool, graphicsStoredInMemory: Int
    // Zeile 3: xxxx,y
    public var password: String, staticRAMInstalled: Bool
}
public enum HostStatusParser { static func parse(_ data: Data) throws -> HostStatus }
public struct HostQueryStatus: Hashable, Sendable, Codable {    // ~HQES
    public var errors: PrinterErrorFlags, warnings: PrinterWarningFlags
}
public struct PrinterErrorFlags: OptionSet, Hashable, Sendable, Codable   // mediaOut=0x1, ribbonOut=0x2, headOpen=0x4, cutterFault=0x8, printheadOverTemp=0x10, motorOverTemp=0x20, badPrintheadElement=0x40, printheadDetectionError=0x80, invalidFirmwareConfig=0x100, printheadThermistorOpen=0x200, paperFeedError=0x800, presenterNotRunning=0x1000, paperJamDuringRetract=0x2000, blackMarkNotFound=0x4000, blackMarkCalibrateError=0x8000, retractTimeout=0x10000, paused=0x20000
public struct PrinterWarningFlags: OptionSet, …     // needCalibration=0x1, cleanPrinthead=0x2, replacePrinthead=0x4, paperNearEnd=0x8, sensor1…sensor8 = 0x10…0x800
public enum HostQueryParser { static func parse(_ data: Data) throws -> HostQueryStatus }
public struct HostIdentification: Hashable, Sendable, Codable { model: String, firmware: String, dotsPerMM: Int, memoryKB: Int, options: String }
public enum HostIdentificationParser { static func parse(_ data: Data) throws -> HostIdentification }  // "\u{2}ZD421-203dpi,V84.20.18Z,8,8192KB\u{3}"

public enum PrinterState: String, Codable, Sendable { case ready, printing, paused, warning, error, offline, unknown }
public enum AlertSeverity: Int, Codable, Sendable, Comparable { case info, warning, error }
public enum AlertKind: String, Codable, Sendable, CaseIterable {
    case mediaOut, ribbonOut, headOpen, paused, cutterFault, headOverTemperature, motorOverTemperature,
         badPrintheadElement, printheadDetectionError, receiveBufferFull, underTemperature, overTemperature,
         corruptRAM, needsCalibration, cleanPrinthead, replacePrinthead, mediaNearEnd, labelWaitingToBePeeled,
         paperFeedError, blackMarkNotFound, invalidFirmwareConfig, offline
}
public struct PrinterAlert: Hashable, Codable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: AlertKind, severity: AlertSeverity
    public var title: String           // Deutsch
    public var recovery: String        // Deutsch, konkrete Handlungsanweisung
    public var systemImage: String
    public static func make(_ kind: AlertKind) -> PrinterAlert
}
public struct PrinterStatusSnapshot: Hashable, Codable, Sendable {
    public var timestamp: Date
    public var state: PrinterState
    public var alerts: [PrinterAlert]                 // nach Schwere sortiert
    public var hostStatus: HostStatus?
    public var queryStatus: HostQueryStatus?
    public var odometerMeters: Double?, labelsPrinted: Int?, headTemperatureC: Double?, batteryPercent: Int?
    public var sgd: [String: String]
    public static let offline: PrinterStatusSnapshot
    public var isReady: Bool
}
public enum StatusInterpreter {
    static func snapshot(hostStatus: HostStatus?, query: HostQueryStatus?, sgd: [String: String] = [:], now: Date = Date()) -> PrinterStatusSnapshot
}
public struct SGDSetting: Hashable, Codable, Sendable { name, value, type: String?, range: String?, access: String?, archive: Bool? }
public enum SGDResponseParser {
    static func parseValue(_ data: Data) -> String?                    // "\"203\"" → 203, "?" → nil
    static func parseJSON(_ data: Data) throws -> [String: SGDSetting] // {}{…} / allconfig-Antworten
    static func parseAllCV(_ text: String) -> [String: SGDSetting]     // 'device.friendly_name : ZD421 , Choices: …'
}
public struct ConfigurationEntry: Hashable, Sendable, Codable { public var name: String; public var value: String }
public enum ConfigurationLabelParser { static func parse(_ text: String) -> [ConfigurationEntry] }   // ^HH-Ausgabe
public struct PrinterFile: Hashable, Sendable, Codable, Identifiable { drive: String, name: String, size: Int, var id: String { drive+name }, kind: FileKind (font, graphic, format, firmware, other) }
public enum FileDirectoryParser { static func parse(_ text: String) -> [PrinterFile] }   // ^HW-Antwort (und SGD file.dir)
```


## 7a. LabelWerkTransport

```swift
public struct USBDeviceIdentifier: Codable, Hashable, Sendable {
    public var vendorID: Int, productID: Int, serialNumber: String?, locationID: UInt32?, productName: String?
}
public enum ConnectionKind: String, Codable, Sendable, CaseIterable { case tcp, usb, bluetooth, ble, cupsQueue, virtual }
public enum ConnectionDescriptor: Codable, Hashable, Sendable {
    case tcp(host: String, port: Int)
    case usb(USBDeviceIdentifier)
    case bluetooth(address: String, name: String?)   // klassisch, RFCOMM/SPP
    case ble(identifier: String, name: String?)      // CoreBluetooth-Peripheral-UUID
    case cupsQueue(name: String)                     // nur Senden (lp -o raw)
    case virtual(id: String)                         // Virtueller Drucker (LabelWerkKit)
    public var kind: ConnectionKind
    public var displayString: String                 // z. B. "192.168.1.20:9100", "USB · ZD421"
    public var systemImage: String                   // SF Symbol
    public var supportsBidirectional: Bool           // cupsQueue → false
}
public protocol PrinterConnection: AnyObject, Sendable {
    var descriptor: ConnectionDescriptor { get }
    var isOpen: Bool { get async }
    func open() async throws
    func close() async
    func write(_ data: Data) async throws
    /// Liefert die innerhalb von `timeout` empfangenen Daten (leer = nichts empfangen).
    func read(timeout: Duration) async throws -> Data
}
extension PrinterConnection {
    public func write(_ string: String) async throws                      // UTF-8
    /// Schreibt `data` und sammelt Antworten, bis `isComplete` true liefert, `timeout` abläuft
    /// oder nach erstem Empfang `idleTimeout` lang nichts mehr kommt.
    public func request(_ data: Data, timeout: Duration = .seconds(3), idleTimeout: Duration = .milliseconds(400),
                        isComplete: @Sendable (Data) -> Bool = { _ in false }) async throws -> Data
}
public enum TransportError: Error, LocalizedError, Equatable {
    case notOpen, timeout, closedByPeer
    case connectionFailed(String), ioError(String), unsupported(String), deviceNotFound(String), permissionDenied(String)
}
public actor TCPConnection: PrinterConnection { public init(host: String, port: Int = 9100, connectTimeout: Duration = .seconds(5)) }  // POSIX-Sockets (macOS & Linux)
public actor CUPSQueueConnection: PrinterConnection { public init(queue: String) }  // write: `lp -d <queue> -o raw` via Process; read → leer
#if os(macOS)
public actor USBConnection: PrinterConnection { public init(device: USBDeviceIdentifier) }        // IOKit/IOUSBHost, Bulk-In/Out
public final class BluetoothClassicConnection: PrinterConnection { public init(address: String) } // IOBluetooth RFCOMM (SPP)
public final class BLEConnection: PrinterConnection { public init(identifier: String) }          // CoreBluetooth, Zebra Parser Service
//   Service 38EB4A80-C570-11E3-9507-0002A5D5C51B, Write 38EB4A82-…, Read/Notify 38EB4A81-…
#endif
public enum ConnectionFactory {
    public static func make(_ descriptor: ConnectionDescriptor) throws -> any PrinterConnection
    /// Wird von LabelWerkKit registriert, um `.virtual` zu bedienen.
    public static func registerVirtualFactory(_ factory: @escaping @Sendable (String) -> any PrinterConnection)
}

public enum DiscoverySource: String, Codable, Sendable, CaseIterable { case bonjour, zebra, usb, network, cups, bluetooth, ble }
public struct DiscoveredPrinter: Identifiable, Hashable, Codable, Sendable {
    public var id: String                    // stabil, aus dem Deskriptor abgeleitet
    public var name: String
    public var modelHint: String?            // z. B. "ZD421-203dpi" → ModelCatalog.match(productName:)
    public var descriptor: ConnectionDescriptor
    public var source: DiscoverySource
    public var details: [String: String]
}
public final class PrinterDiscovery: Sendable {
    public init()
    public init(options: Options)            // u. a. extraNetworks, includePrivateVPNNetworks, zebra…-Optionen
    /// Liefert gefundene Drucker (zusammengeführt, siehe DiscoveryRegistry) und endet nach `timeout`.
    /// Ein genauer erkannter späterer Fund desselben Geräts kommt mit derselben `id` erneut.
    public func discover(sources: Set<DiscoverySource> = Set(DiscoverySource.allCases),
                         timeout: Duration = .seconds(6)) -> AsyncStream<DiscoveredPrinter>
    public static func plan(options: Options, interfaces: [NetworkInterfaceInfo] = SubnetScanner.allIPv4Interfaces()) -> DiscoveryPlan
}
public struct NetworkInterfaceInfo: Hashable, Sendable {
    public var name: String, address: String, netmask: String
    public var isPointToPoint: Bool, supportsMulticast: Bool   // VPN-Tunnel (utun/ppp), IFF_MULTICAST
    public var broadcastAddress: String?                       // nil bei Punkt-zu-Punkt, /31, /32
}
public enum SubnetScanner {
    public static func localIPv4Interfaces() -> [NetworkInterfaceInfo]   // getifaddrs, ohne Loopback und VPN-Tunnel
    public static func allIPv4Interfaces() -> [NetworkInterfaceInfo]     // getifaddrs, ohne Loopback, mit VPN-Tunneln
    public static func hosts(in iface: NetworkInterfaceInfo, limit: Int = 1024) -> [String]
    public static func scan(hosts: [String], port: Int = 9100, timeout: Duration = .milliseconds(400), maxConcurrent: Int = 64) -> AsyncStream<String>
}
public enum ZebraDiscoveryPacket {                       // Zebra-Suche (UDP 4201), reine Paketlogik
    public static let port = 4201, multicastGroup = "224.0.1.55", defaultMulticastHops = 3
    public static let request: [UInt8]                   // 2E 2C 3A 01 00 00
    public struct Reply: Hashable, Sendable, Codable { productName, firmware, macAddress, serialNumber, ipAddress, systemName … }
    public static func parse(_ bytes: [UInt8]) -> Reply?
    public static func encode(_ reply: Reply, length: Int = 376) -> [UInt8]
    public static func makeDiscoveredPrinter(_ reply: Reply, host: String, port: Int = 9100) -> DiscoveredPrinter
}
public struct IPv4Range: Hashable, Sendable, Comparable { first, last; hostCount; hosts(limit:); broadcastAddress; description }
public struct DiscoveryNetworkEntry: Hashable, Sendable, Codable { text; origin: .local/.vpn/.knownPrinter/.user; label }
public struct DiscoveryPlan: Hashable, Sendable {      // was Netzwerk-Scan und Zebra-Suche durchsuchen
    public var networks: [DiscoveryNetwork], invalidEntries: [DiscoveryNetworkInvalidEntry]
    public var hosts: [String], remoteHosts: [String], broadcastTargets: [String]
    public func estimatedScanDuration(…) -> Duration
    public static func make(interfaces:entries:includePrivateVPNNetworks:localHostLimit:maxHostsPerEntry:) -> DiscoveryPlan
}
public enum DiscoveryNetworks {
    public static let maxHostsPerEntry = 4096
    public static func parse(_ text: String) -> Result<IPv4Range, DiscoveryNetworkError>
    public static func knownPrinterNetworks(_ hosts: [(host: String, label: String?)], resolved: [String: String] = [:]) -> [DiscoveryNetworkEntry]
    public static func host(ofDeviceURI uri: String) -> String?          // jedes Netzwerkschema, beliebiger Pfad
    public static func resolveHostnames(_ hosts: [String], resolver: IPv4Resolver? = nil) async -> [String: String]
    public static func isPrivate(_ address: UInt32) -> Bool
}
public struct DiscoveryRegistry: Sendable {            // Zusammenführen nach id, Seriennummer, Druckserver-Seriennr., MAC, Adresse
    public mutating func insert(_ printer: DiscoveredPrinter) -> Outcome   // .added / .updated / .duplicate
}
public struct CUPSQueueInfo: Hashable, Sendable, Codable { public var name: String; public var deviceURI: String; public var isDefault: Bool; public var makeAndModel: String? }
public enum CUPSQueueLister {
    public static func queues() -> [CUPSQueueInfo]                    // `lpstat -v` (+ `-d`), leer wenn lpstat fehlt
    public static func parseLpstatV(_ text: String) -> [(name: String, uri: String)]   // de/en-Ausgabe
    public static func modelHint(fromDeviceURI uri: String) -> String?  // usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=… → "ZTC ZD421-203dpi ZPL"
}
```

### Druckersuche im Netzwerk (Zebra-Suche, Netze, automatische Suche)

Ziel: wie die Zebra-Programme unter Windows (Zebra Setup Utilities, ZebraNet Bridge, Link-OS-SDK
`NetworkDiscoverer`) **alle** Zebra-Drucker des Netzes von selbst anzeigen – auch, wenn der Mac per VPN
(FortiClient & Co.) oder über einen Router mit dem Druckernetz verbunden ist.

**Zebra-Suche (`DiscoverySource.zebra`, `ZebraUDPDiscovery`, Paketformat `ZebraDiscoveryPacket`).**
Ein UDP-Socket (beliebiger lokaler Port, `SO_BROADCAST`, `IP_MULTICAST_TTL` = 3) sendet die sechs
Bytes `2E 2C 3A 01 00 00` an Port 4201

* als Broadcast an 255.255.255.255 und an die Directed-Broadcast-Adresse jedes Netzes des Suchplans
  (macOS sendet 255.255.255.255 nur über die Schnittstelle der Standardroute),
* an die Multicast-Gruppe 224.0.1.55 über jede multicastfähige Schnittstelle (`IP_MULTICAST_IF`),
* **einzeln an jede Adresse der entfernten Netze** (VPN, Netze bekannter Drucker, eigene Netze) – wie
  Link-OS `subnetSearch` („10.62.13.*“). Broadcast und Multicast enden am Router bzw. VPN-Tunnel; die
  Einzelabfrage erreicht die Drucker trotzdem.

Zwei Runden (800 ms Abstand), danach 2,5 s Wartezeit; Antworten werden je Absender einmal gemeldet.
Jeder Zebra-Druckserver antwortet von Port 4201 an den Absender mit einem Paket fester Länge (376 Byte):

| Offset | Länge | Inhalt |
|---:|---:|---|
| 0 | 3 | Kennung `3A 2C 2E` („:,.“) |
| 3 | 1 | Paketversion (3) |
| 4 | 8 | Produktnummer |
| 12 | 20 | Produktname, auf 20 Zeichen gekürzt („ZTC ZD620-300dpi ZPL“; externer Druckserver: „ZebraNet Wired PS“) |
| 32 | 7 | Datumscode |
| 39 | 10 | Firmware („V84.20.23Z“) |
| 49 | 5 | Firmenkürzel („ZBR“) |
| 54 | 6 | MAC-Adresse |
| 60 | 10 | Seriennummer des Druckservers |
| 70 | 2 | unbekannt (immer `01 00`) |
| 72 / 76 / 80 | je 4 | IP-Adresse / Subnetzmaske / Gateway |
| 84 | 25 | Systemname („ZEBRA-ZD620“, „ZBR4262077“) |

Texte enden am ersten NUL; nicht druckbare Felder gelten als leer. Adresse des Druckers ist der
**Absender** des Pakets (hinter NAT/VPN kann die gemeldete abweichen → `details["reportedAddress"]`).
Fehlen Produkt- und Systemname (abweichender Aufbau älterer Druckserver), identifiziert die Suche das
Gerät per SNMP bzw. `~HI` – gefahrlos, denn nur Zebra-Druckserver beantworten die Anfrage.
Ergebnis: `.tcp(host, 9100)`, `source = .zebra`, `details["identifiedBy"] = "zebra"`, außerdem
`name` (Systemname), `productName`/`printServer`, `firmware`, `printServerSerial` (Seriennummer des
**Druckservers** – nicht unbedingt die des Druckers, daher nie unter `serialNumber`), `macAddress`,
`subnetMask`, `gateway`.

Quellen (abgerufen 2026-11-10, drei unabhängige Beschreibungen mit denselben Offsets, zwei an echter
Hardware gemessen; Testdaten in `Tests/LabelWerkTransportTests/ZebraDiscoveryTests.swift`):
J. Runyon, „Zebra network discovery protocol“ (Mitschnitt eines ZebraNet-Druckservers,
<https://jfr.im/blog/2024/09/zebra-network-discovery-protocol/>); Zebra Print Service für Android
(Multicast 224.0.1.55:4201, Feldoffsets; <https://github.com/Thunderlight-Software/Zebra-Print-Service>,
`AddActivity.java`, `NetworkDevice.java`); monochrome-unicorn, Messung an ZD620 und ZD500R
(<https://github.com/TylerWhittaker/monochrome-unicorn>, `docs/printer-notes.md`); Port 4201 laut Zebra
ZDownloader User Guide und Zebra Print System Requirements (docs.zebra.com); Suchverfahren und
Bereichsangaben laut Link-OS-SDK `NetworkDiscoverer` (techdocs.zebra.com/link-os).

**Suchplan (`DiscoveryPlan`, `PrinterDiscovery.Options.extraNetworks`).** Durchsucht werden
1. die lokalen Subnetze (wie bisher bis 1024 Adressen um die eigene Adresse; Broadcast),
2. das /24 jedes VPN-Tunnels (Punkt-zu-Punkt-Schnittstelle) mit **privater** Adresse (RFC 1918) –
   öffentliche Tunneladressen nie (`includePrivateVPNNetworks`),
3. eigene Netze (`AppPreferences.extraDiscoveryNetworks`, `lwctl discover --networks`),
4. das /24 jedes bekannten Druckers: Adressen der eingerichteten Drucker (`.tcp`, gemeldete IP),
   Geräte-URIs ihrer macOS-Warteschlangen (eigene, übernommene, `.cupsQueue`) und aller
   Zebra-Warteschlangen in macOS (`DiscoveryNetworks.knownPrinterNetworks`, `host(ofDeviceURI:)`:
   jedes Netzwerkschema mit beliebigem Pfad, z. B. `lpd://10.62.13.19/PRT`,
   `ipp://host:631/printers/x` – nur der Host zählt; Loopback, USB, `dnssd://` nicht). Hostnamen löst
   die App vorher auf (`DiscoveryNetworks.resolveHostnames`, `getaddrinfo` `AF_INET` außerhalb des
   Main-Threads, je Name höchstens 2 s). Nur **private** Adressen (RFC 1918) bringen ihr /24 ein; von
   einer öffentlichen Adresse (Portweiterleitung, Druckserver in der Cloud) wird nur diese Adresse
   selbst geprüft – LabelWerk durchsucht nie von selbst ein fremdes öffentliches Netz.

Netze, deren Adressen ein früheres Netz schon abdeckt, werden zusammengefasst (Herkünfte und
Bezeichnungen kommen hinzu). Angaben (`DiscoveryNetworks.parse`, nachsichtig: Leerzeichen,
Gedankenstriche): CIDR „10.62.13.0/24“ (auch „10.62.13.19/24“, „/255.255.255.0“), Bereiche
„10.62.13.1-10.62.13.254“, „10.62.13.37-42“, „10.62.13.8-*“, Platzhalter „10.62.13.*“, „10.62.*“, drei
Oktette bzw. „.0“ (= /24), einzelne Adressen. Abgelehnt: Loopback, 0/8, Multicast/reserviert (ab 224),
verkehrte Bereiche, ungültige Präfixe. Je Eintrag höchstens **4096 Adressen**
(`DiscoveryNetworks.maxHostsPerEntry`); größere Netze werden auf die ersten 4096 begrenzt und in der
App gekennzeichnet („Großes Netz: Nur die ersten 4096 Adressen werden durchsucht.“). Der
Netzwerk-Scan (Port 9100) prüft dieselben Adressen, für Adressen außerhalb der lokalen Netze mit
längerer Frist (`remoteConnectTimeout`, 900 ms); identifiziert wird wie bisher per SNMP und `~HI` nur
bei positiver Zebra-Erkennung; nicht identifizierte Geräte zeigen App und `lwctl discover` nicht an
(siehe „Anzeigen“, `lwctl discover --all` führt sie mit auf).

**Zusammenführen (`DiscoveryRegistry`).** Gleiche `id`, dann gleiche Seriennummer des Druckers
(`serialNumber`), dann gleiche Seriennummer des Druckservers (`printServerSerial`), dann gleiche
MAC-Adresse (`macAddress`, normalisiert), dann (Netzwerk) gleiche Adresse ergeben einen Drucker; die
Nummernarten werden nie miteinander verglichen. Rangfolge der Erkennung: Zebra-Suche (3) > SNMP/`~HI`, Bonjour,
USB, CUPS, Bluetooth (2) > offener Port ohne Identifikation (1). Ein besserer späterer Fund ergänzt den
Eintrag (Kennung und Verbindung bleiben; allgemeine Namen wie „Zebra ZD421“ weichen keinem eigenen);
`PrinterDiscovery.discover` liefert ihn mit derselben `id` erneut, Verbraucher ersetzen ihn.

**Anzeigen (`DiscoveryFilter`, `Sources/LabelWerkTransport/Discovery/DiscoveryFilter.swift`).** Eine
gemeinsame Regel für „Drucker suchen“ (Liste, Zähler), die Seitenleiste „Neue Zebra-Drucker [N]“, die
macOS-Warteschlangen und USB-/Bluetooth-Geräte unter „Manuell“, den Installationsassistenten und
`lwctl discover`: `DiscoveryFilter.partition` teilt Treffer in `new` (angezeigt), `alreadyAdded` und
`unidentified` (beide ausgeblendet; die App nennt nur die Zahl „N bereits hinzugefügt“ – gezählt
werden eingerichtete **Drucker** (`Partition.addedIdentityIndices`/`hiddenAddedPrinterCount`), nicht
Treffer: Ein Drucker taucht oft mehrfach auf, etwa mit LabelWerk-Warteschlange, Etikettentyp-Warteschlangen
und Netzwerk-Fund).
* **Nur Zebra** (`isIdentifiedZebra`): Antwort auf die Zebra-Suche oder `~HI`; Netzwerk-Scan nur mit
  Zebra-`sysDescr`/Modellhinweis; Bonjour und BLE (melden ohnehin nur Zebra-Dienste); USB mit
  Hersteller-ID 0x0A5F; Warteschlange mit Zebra-/LabelWerk-Treiber, -URI oder -Namen
  (`CUPSQueueInfo.looksLikeZebra`); Bluetooth mit Zebra-Namen, Zebra-Seriennummer als Name
  („XXQLJ…“) oder Adressblock mobiler Zebra-Drucker (`ZebraIdentifiers.bluetoothOUIs`). Ein offener
  Port 9100 allein genügt nicht – solche Adressen lassen sich nur unter „Manuell“ eintragen.
* **Nie Dubletten** (`isAlreadyAdded`/`matchingIdentityIndex` gegen `AddedPrinterIdentity` je
  eingerichtetem Drucker, gebaut in `NetworkDiscoveryService.addedIdentities`): gleiche Verbindung
  (`stableID`); eine seiner Warteschlangen (eigene, übernommene `adoptedQueueNames`, Etikettentypen;
  ohne Groß-/Kleinschreibung); gleiche Drucker-Seriennummer (auch aus `usb://…?serial=`); gleiche
  MAC-Adresse; gleicher Bonjour-Name (`dnssd://`-Warteschlange); gleiche Adresse – Verbindung, vom
  Drucker gemeldete IP-Adresse und Ziele seiner Warteschlangen, soweit sie das Gerät selbst nennen
  (`QueueAdoption.deviceEndpoint`: keine Druckserver-Freigabe `ipp://server/printers/X`, keine benannte
  LPD-Warteschlange `lpd://ps/PORT2`), Hostnamen auch über ihre aufgelöste IPv4-Adresse. Ports müssen
  passen: gleich, unbekannt (IPP-Endpunkt bzw. LPD-Standardwarteschlange des Geräts, gemeldete IP) oder
  9100/6101 (beide Rohdatenports eines Zebra-Druckers); 9100 und 9101 sind zwei Anschlüsse eines
  Druckservers und damit verschiedene Drucker. Die gemeldete IP gilt deshalb nur für den Port der
  Verbindung, wenn diese über einen anderen Port als 9100/6101 läuft, und gar nicht, wenn sie der Host
  einer Druckserver-Warteschlange ist bzw. der Drucker nur über eine benannte LPD-Warteschlange
  erreicht wird. USB ohne gemeinsame Seriennummer: gleiches Produkt am
  gleichen Anschluss.
* **Ein Eintrag je Gerät** (`DiscoveryFilter.groupDevices`/`overview`,
  `Sources/LabelWerkTransport/Discovery/DiscoveryGrouping.swift` → `DiscoveryOverview` mit `devices`,
  `macQueues`, `added`; je Gerät `DiscoveredDevice`: Modell „Zebra ZD421t“, Titel, Adresse,
  Seriennummer, MAC, Wege Netzwerk/USB/Bluetooth/macOS-Drucker, Warteschlangennamen, `preferred` =
  beste Verbindung zum Hinzufügen). Funde aller Quellen werden per Union-Find zusammengefasst:
  1. immer bei gleicher Seriennummer des Druckers – auch wenn sie nur als Name auftritt
     (`nameSerialNumbers`: BLE-/Bluetooth-Name, Systemname der Zebra-Suche, `sysName`, Bonjour-Name,
     `dnssd://`-Warteschlange im Zebra-Format, `ZebraIdentifiers.looksLikeZebraSerialNumber`:
     „XX“ + 3 Buchstaben + ≥ 6 Ziffern bzw. 2 Zeichen + Buchstabe + Jahr + Woche 01–53 + 5 Ziffern,
     z. B. „D6J250301793“) –, gleicher Druckserver-Seriennummer (eigener Namensraum), MAC-Adresse,
     gleichem USB-Gerät bzw. gleicher Nicht-Netzwerk-Verbindung;
  2. bei gleicher Netzwerkadresse (wie oben, Ports passend, Hostnamen über `resolved`), außer die
     Gruppen nennen verschiedene Seriennummern bzw. MAC-Adressen (neu vergebene Adresse);
  3. bei gleichem eigenem Namen (Systemname, `sysName`, Bonjour-, Bluetooth-Name; nie allgemeine
     Namen wie „Zebra ZD421“, Adressen oder Seriennummern – `isGenericPrinterName`), außer die Gruppen
     widersprechen sich in Seriennummer, MAC oder (beide mit IP-Adresse) in der Adresse.
  Beste Verbindung: Netzwerk (Port 9100, IP-Adresse, Zebra-Suche) vor USB vor Bluetooth vor
  Bluetooth LE vor Warteschlange; sie erhält Titel, besten Modellhinweis (eindeutige Katalogzuordnung
  gewinnt, sonst Baureihe „ZD421“) und Seriennummer der übrigen Funde. Titel = eigener Name des
  Druckers, sonst das Modell – nie Seriennummer oder Adresse. Ein Gerät gilt als eingerichtet, sobald
  einer seiner Funde zu einem eingerichteten Drucker gehört (dann verschwindet auch sein BLE-Eintrag).
  Gruppen nur aus Zebra-Warteschlangen stehen unter „Vorhandene macOS-Drucker“. `lwctl discover`
  zeigt ebenfalls eine Zeile je Gerät (`--all` und `--json` die einzelnen Funde).

**Automatische Suche (App, `Services/NetworkDiscoveryService.swift`, `model.networkDiscovery`).**
5 s nach dem Start vollständig (Zebra-Suche, Bonjour, Netzwerk-Scan), danach alle 10 Minuten im
Hintergrund nur die Zebra-Suche (plus eine Einzelprüfung per Port 9100/SNMP/`~HI` der noch
sichtbaren Drucker, die diesmal nicht per UDP geantwortet haben, höchstens 64 Adressen – sonst fielen
nur per Netzwerk-Scan gefundene Drucker nach 35 Minuten aus der Liste); beim Aktivieren der App wieder vollständig, wenn die letzte
vollständige Suche älter als 10 Minuten ist; „Erneut suchen“ jederzeit. Abschaltbar:
`AppPreferences.automaticNetworkDiscovery` (Einstellungen › Allgemein › Druckersuche, Editor
„Netze …“). Ergebnisse fließen in „Drucker suchen“ (zusätzlich zu den Treffern der Seite) und – noch
nicht eingerichtete, als Zebra erkannte Drucker, die in den letzten 35 Minuten geantwortet haben –
als Zahl in die Seitenleiste (**„Neue Zebra-Drucker [N]“**, `newDevices`, eine Zeile, öffnet „Drucker
suchen“). „Schon eingerichtet“ entscheidet `DiscoveryFilter` (siehe „Anzeigen“). Das Kontextmenü
„Drucker installieren …“ einer Zeile in „Drucker suchen“ öffnet den Installationsassistenten
mit dem Fund selbst (`AppModel.openInstallWizard(for:)`, `InstallWizardPrefill.printer`): Der
Assistent übernimmt ihn als Suchtreffer (`DiscoveryController.inject(_:)`, übersteht neue Suchläufe,
ein schwächerer Fund desselben Geräts verdrängt ihn nicht) und wählt ihn aus – die Erkennung beginnt
mit den Angaben der Zebra-Suche (`zebraCheck = .confirmed`, Modell, Systemname), auch wenn SNMP hinter
dem VPN gesperrt ist. Der Hinweis „liegt nicht im Netz dieses Macs“ entfällt für Adressen in einem
Netz des Suchplans.

„Drucker suchen“ startet seine Suche erst, wenn die Optionen bereitstehen (macOS-Warteschlangen,
Hostnamen); erneutes Suchen, „Suche stoppen“ und das Schließen der Ansicht brechen einen solchen noch
wartenden Start ab.

**Berechtigungen (macOS).** Ab macOS 15 brauchen Broadcast, Multicast und Unicast ins **lokale** Netz
die Freigabe „Lokales Netzwerk“ (`NSLocalNetworkUsageDescription`, nennt UDP 4201). Laut Apple
TN3179 gelten Ziele hinter VPN-Tunneln nicht als lokales Netz, und die Berechtigung
`com.apple.developer.networking.multicast` ist **nur unter iOS** nötig („The multicast entitlement isn’t
required on macOS“) – sie wird nicht gesetzt (für Ad-hoc-Builds wäre sie ohnehin nicht erhältlich).
Ad-hoc signierte Builds: Die Freigabe hängt an der Code-Signatur und kann nach jedem neuen Build erneut
abgefragt werden bzw. verloren gehen (TN3179 „Build-time considerations“); wird Multicast oder Broadcast
verweigert, bleiben die Einzelabfragen der entfernten Netze (VPN) unberührt. Quelle:
<https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>.

## 7b. LabelWerkKit

```swift
public struct PrinterIdentity: Codable, Hashable, Sendable {
    public var model: String?              // Rohname aus ~HI / device.product_name
    public var matchedModelID: String?     // ModelCatalog-ID
    public var serialNumber: String?, firmware: String?, friendlyName: String?
    public var resolution: Resolution?, printWidthDots: Int?, memoryKB: Int?
    public var languages: [PrinterLanguage]
    public var ipAddress: String?, macAddress: String?
    public var isLinkOS: Bool
}
public struct NetworkSettings: Codable, Hashable, Sendable {
    public var useDHCP: Bool
    public var ipAddress: String, subnetMask: String, gateway: String
    public var dnsServer: String?, hostname: String?
    public var wlanEnabled: Bool?, wlanSSID: String?, wlanSecurity: String?
    public var wlanPassphrase: String?     // nur schreiben
    public var macAddress: String?         // nur lesen
}
public actor PrinterClient {
    public init(connection: any PrinterConnection, language: PrinterLanguage = .zpl)
    public nonisolated let connection: any PrinterConnection
    public var language: PrinterLanguage
    public func setLanguage(_ language: PrinterLanguage)
    public func connect() async throws                 // öffnet bei Bedarf
    public func disconnect() async
    public func identify() async throws -> PrinterIdentity
    public func status() async throws -> PrinterStatusSnapshot
    public func getvar(_ name: String) async throws -> String?
    public func getvars(_ names: [String]) async throws -> [String: String]   // JSON wenn möglich, sonst einzeln
    public func setvar(_ name: String, _ value: String) async throws
    public func doCommand(_ name: String, _ value: String = "") async throws -> String?
    public func allSettings() async throws -> [String: SGDSetting]
    public func configuration() async throws -> [ConfigurationEntry]          // ^HH
    public func perform(_ action: PrinterAction, resolution: Resolution = .dpi203, widthDots: Int = 812, heightDots: Int = 1218) async throws
    public func send(_ data: Data) async throws
    public func send(_ text: String) async throws
    public func printZPL(_ zpl: String) async throws
    public func printImages(_ images: [GrayImage], settings: PrintSettings, resolution: Resolution,
                            stock: LabelStock?, copies: Int = 1) async throws
        // mit cancelJobsBeforePrint: ~JA-Zeile senden, cancelDelayMs warten, Rest senden
    public func sendJob(_ data: Data, cancelPrefixLength: Int?, delayMilliseconds: Int) async throws
        // fertig kodierter Auftrag (App: PrinterSession.printImages/reprint): erst cancelPrefixLength
        // Bytes, delayMilliseconds warten, dann der Rest; nil/ungültig → in einem Stück
    public static func cancelPrefixLength(of data: Data) -> Int?   // 4 bei "<c>JA\n" am Anfang, sonst nil
    public func applySettings(_ settings: PrintSettings, permanently: Bool) async throws
        // ~SD, ~TA, ~JS, [SGD media.printmode bei Linerless], ^XA ^MT ^MN[M,offset] ^MM(klassisch) ^PR ^LT ^LS
        // ^MF(nur beide Aktionen) (+ ^JUS) ^XZ – mit den Steuerzeichen aus settings.controlCharacters
    public static func settingsPayload(_ settings: PrintSettings, permanently: Bool, language: PrinterLanguage) -> Data
    public func syncClock(now: Date = Date(), timeZone: TimeZone = .current) async throws
        // ZPL: ^XA^ST{MM},{DD},{YYYY},{HH},{mm},{SS},M^XZ; EPL/CPCL: SGD rtc.date (MM-DD-YYYY), rtc.time (HH:MM:SS)
    public static func clockPayload(now: Date, timeZone: TimeZone, language: PrinterLanguage) -> Data
    public func readPrintSettings(into base: PrintSettings = PrintSettings()) async throws -> PrintSettings
        // SGD: print.tone, media.speed, ezpl.media_type (sonst media.type journal → continuous,
        // media.sense_mode bar → blackMark / gap → gap), ezpl.print_method, media.printmode,
        // zpl.label_top, zpl.left_position, ezpl.tear_off, ezpl.power_up_action, ezpl.head_close_action,
        // zpl.caret/zpl.control_character/zpl.delimiter (alle Standard → nil); fehlende Werte → base
    public func listFiles(drive: String = "E:") async throws -> [PrinterFile]
    public func uploadFont(name: String, data: Data, drive: String = "E:") async throws
    public func uploadGraphic(name: String, bitmap: MonoBitmap, drive: String = "E:") async throws
    public func deleteFile(_ path: String) async throws
    public func sendFirmware(_ data: Data, chunkSize: Int = 16_384, progress: @escaping @Sendable (Double) -> Void) async throws
    public func terminal(_ input: String, timeout: Duration = .seconds(2)) async throws -> Data
    public func networkSettings() async throws -> NetworkSettings
    public func applyNetworkSettings(_ settings: NetworkSettings) async throws   // SGD + device.reset
}

/// Vollständig simulierter Drucker (Demo-Modus der App, Tests, `lwctl virtual-printer`).
public actor VirtualPrinter: PrinterConnection {
    public init(id: String = "demo", model: PrinterModel, resolution: Resolution = .dpi203)
    public var receivedData: Data { get }
    public var renderedLabels: [RenderedLabel] { get }   // aus empfangenem ZPL (LabelWerkRender)
    public func setPaused(_ on: Bool); func setHeadOpen(_ on: Bool); func setMediaOut(_ on: Bool); func setRibbonOut(_ on: Bool)
    public var clockDate: Date { get }                    // simulierte Echtzeituhr (^ST, SGD rtc.date/rtc.time)
    // Linerless-Modelle (Ausstattung linerless) akzeptieren die Linerless-Werte von media.printmode
    public var files: [PrinterFile] { get }
    public static func registerWithConnectionFactory()   // `.virtual(id:)` → VirtualPrinter (Standardmodell ZD421t)
}
public enum VirtualPrinterServer {
    public static func run(port: Int, printer: VirtualPrinter) async throws      // TCP-Server (POSIX), bis Abbruch
}
```

Antwortverhalten: `~HS` → 3 Zeilen `STX…ETX\r\n`; `~HI` → `STX…ETX`; `~HQES` → Block mit `PRINTER STATUS`, `ERRORS:`, `WARNINGS:`;
SGD `getvar` → `"wert"`; JSON `{}{…}` → JSON-Objekt; `^HH` → Konfigurationstext; `^WD` → Dateiliste.

### Etikett für Etikett drucken (`PacedJobSender`)

Druck aus der App bei „Bei Papier- oder Farbbandende anhalten und fortsetzen“ (`PrintSettings.resumeAfterError`,
Standard an) – dieselbe Logik wie das CUPS-Backend `labelwerk` (§10): Der Auftrag bleibt bestehen, bis
jedes Etikett gedruckt ist, wartet bei Papier/Farbband leer, offenem Kopf oder Pause und geht danach
genau dort weiter (das unterbrochene Etikett druckt der Drucker wegen `^JZY` selbst erneut).

```swift
public struct PacedJobPlan: Sendable, Hashable {          // Zerlegung eines ZPL-Auftrags
    public struct Segment { public var data: Data; public var quantity: Int    // ein druckendes Format (^PQ)
                            public func withQuantity(_ n: Int) -> Segment }   // ^PQ-Menge ersetzen
    public var prologue: Data          // alles vor dem ersten ^XA (~JA, Startbefehle, ~SD, ~TA, ~JS, ~JC, SGD)
    public var segments: [Segment]     // je druckendes Format samt allem seit dem vorigen Segment
    public var epilogue: Data          // Rest (Endbefehle, abschließende nicht druckende Formate)
    public var characters: ControlCharacters
    public var totalLabels: Int
    public static func split(_ data: Data, characters: ControlCharacters? = nil) -> PacedJobPlan
    public static func detectCharacters(in data: Data) -> ControlCharacters
}
public struct PacedJobOptions: Sendable, Hashable {        // .standard
    pollInterval 250 ms, waitPollInterval 2 s, statusTimeout 3 s, reprintAfterError true (^XA^JZY^XZ),
    resumeAfterRecovery true (~PS nach behobenem Fehler), maxReconnectAttempts 6, reconnectDelay 2 s
    (verdoppelt bis 30 s), maxSilentPolls 5
}
public enum PacedJobWaitReason: String { case mediaOut, ribbonOut, headOpen, paused, labelWaitingToBePeeled,
                                         headTemperature
    public var title: String; public var message: String; public var isFault: Bool
    public static func reason(for status: HostStatus) -> PacedJobWaitReason? }
public enum PacedJobEvent { case started(total:paced:), progress(printed:total:), waiting(_:printed:total:),
    resumed(printed:total:), resumeSent, unpaced(String), connectionLost(attempt:message:), reconnected,
    resending(labels:), cancelled(printed:total:), finished(printed:total:) }
public struct PacedJobResult { public var printed: Int; public var total: Int; public var paced: Bool }
public struct PacedJobSender: Sendable {
    public init(client: PrinterClient, options: PacedJobOptions = .standard)
    @discardableResult
    public func send(_ data: Data, characters: ControlCharacters? = nil, cancelPrefixLength: Int? = nil,
                     delayMilliseconds: Int = 0,
                     onEvent: @escaping @Sendable (PacedJobEvent) -> Void = { _ in }) async throws -> PacedJobResult
}
extension PrinterClient {
    public func hostStatus(characters: ControlCharacters = .standard, timeout: Duration? = nil) async throws -> HostStatus?
}
```

* **Zerlegen:** Formatpräfix/Steuerpräfix/Trennzeichen übergeben (`effectiveControlCharacters`) oder erkannt
  (`^XA` vorhanden → `^`, sonst das Zeichen vor `XA`, das auch vor `XZ` steht; Steuerpräfix aus `<c>JA` am
  Anfang bzw. `<c>HS|JA|SD|TA|JS|JC|DG|DY` am Zeilenanfang). Binärdaten von `^GFB`/`^GFC` und `~DY` (B/C)
  werden exakt übersprungen; in `^FD … ^FS` zählt nur `^FS`/`^XZ`. Druckend ist ein Format mit
  `^FD ^FV ^GF ^GB ^GC ^GD ^GE ^GS ^XG ^IM ^XF` und ohne `^DF`; Menge aus `^PQ` (ohne: 1). Nicht druckende
  Formate (`^XA^MF…^XZ`, `^XA^ST…^XZ`) gehören zum folgenden Segment. Die Teile ergeben aneinandergehängt
  genau den Auftrag.
* **Ablauf:** `~HS` (mit den Steuerzeichen des Auftrags) prüft den Rückkanal – ohne Antwort, ohne Rückkanal
  (CUPS-Warteschlange), bei EPL/CPCL oder ohne druckendes Format: Versand in einem Stück wie
  `sendJob` (`unpaced`). Sonst: Kopf + `^XA^JZY^XZ` (mit `~JA`-Teilung und `cancelDelayMs` wie `sendJob`),
  dann je Segment: warten, bis `formats in receive buffer` = 0, `labels remaining` = 0, kein Teilformat
  und kein Wartegrund → Segment senden → abfragen (250 ms), Fortschritt = fertige Segmente +
  (Menge − `labels remaining`), sobald das Format begonnen hat. So liegt nie mehr als ein Format im Drucker.
  Wartegründe (Reihenfolge): Kopf offen, Papier leer, Farbband leer (nur Thermotransfer), Pause,
  Übertemperatur, Etikett im Spendemodus (nur bei ausstehenden Etiketten); Abfrage dann alle 2 s.
  Pause nach einem Fehler dieses Auftrags → `~PS`; Pause ohne vorherigen Fehler → warten.
* **Abbruch** (Task-Abbruch): `~JA` in einem eigenen Task, Ereignis `cancelled`, dann `CancellationError`.
* **Neustart-Merker:** vor dem ersten Segment (Drucker bereit) `~DGR:LWAPP.GRF,1,1,00` (1 Byte im RAM,
  beim Aus- und Einschalten weg; das CUPS-Backend nutzt `R:LWJOB.GRF`) und einmal `^XA^HWR:LWAPP.GRF^XZ`
  (`PrinterClient.storeVolatileMarker`/`volatileMarkerExists`, Auswertung `VolatileMarker.listed` wie
  `lwb_parse_directory`); am Ende `^ID`.
* **Verbindungsabbruch** (`TransportError`, `PrinterClientError.transport`, 5 × keine `~HS`-Antwort):
  `disconnect()` + `connect()` mit wachsendem Abstand. Meldet der Drucker danach Formate/Restetiketten →
  Puffer behalten, weiter warten. Ist er leer, entscheidet der Merker (erst wenn der Drucker bereit ist –
  Fehler und Pausen werden mit den üblichen Ereignissen abgewartet), nie der letzte Wartegrund: vorhanden
  → er hat inzwischen fertig gedruckt, nichts wiederholen; fehlt → neu gestartet: Kopf (Prolog + `^JZY`,
  mit `~JA`-Pause) und Merker erneut, dann die zuletzt gemeldeten restlichen Exemplare (`withQuantity`) –
  auch ohne vorherigen Fehler; meldet der Drucker den Merker nicht → nichts wiederholen, Ereignis
  `uncertain(labels:)` und `PacedJobResult.uncertain`. Beim Senden abgebrochen: Teilformat → `~JX`; liegt
  das Format vollständig im Drucker → nicht erneut senden; sonst erneut (nach einem Neustart samt Kopf).
* **App:** `PrinterSession.transmitPrintJob` (für `printImages`, `printZPL`, `reprint`, Etikettendruck
  direkt) – Aufträge eines Druckers nacheinander, `printJob: PrintJobProgress?` für den Hinweis
  `PrintJobBanner` („Etikett 37 von 50“, „Papier leer – neue Etikettenrolle einlegen. Der Druck geht danach
  automatisch weiter.“, „Abbrechen“ → `cancelPrintJob()`, wirkt auch während des Verbindens; „Wartende
  verwerfen“ → `cancelWaitingPrintJobs()`), Mitteilung im Hintergrund, Verlauf mit den tatsächlich
  gedruckten Etiketten (bei `uncertain` mit Hinweis „bitte nachzählen“). Während eines Auftrags hält
  `ProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` den Mac wach (kein App Nap), damit
  die Statusabfrage beim Warten auf eine neue Rolle nicht einschläft. Ausgeschaltet bzw. ohne Rückkanal:
  `PrinterClient.sendJob` wie bisher.

`VirtualPrinter` simuliert dafür einen echten Drucker: `setPrintTime(_:)` (bzw. SGD
`labelwerk.simulation.print_time_ms`) druckt Exemplar für Exemplar mit Druckzeit – `~HS` meldet dann noch
nicht begonnene Formate (`formats in receive buffer`) und alle ausstehenden Exemplare (`labels remaining`);
ohne Druckzeit wird wie bisher sofort gedruckt. `scheduleFault(_:afterLabels:clearAfter:pauseAfterRecovery:)`
(`Fault`: `mediaOut`, `ribbonOut`, `headOpen`, `paused`) unterbricht nach N Exemplaren das nächste mitten im
Druck; `^JZY` (Standard der Firmware, `setReprintAfterError(_:)`, `reprintsAfterError`) druckt es danach
erneut, `^JZN` verliert es (`spoiledLabels`). Eine Pause lässt das laufende Exemplar fertig drucken.
`printLog` hat je gedrucktem Exemplar einen Eintrag (`^FD`-Inhalt bzw. Prüfsumme), `~JA` und Neustart
verwerfen alle wartenden Formate; ein Neustart (`restartDevice`, `~JR`) leert auch das RAM-Laufwerk `R:`.

## 7c. lwctl (CLI)

`lwctl <befehl> [optionen]`, globale Option `--printer <uri>` mit `tcp://host[:port]`, `usb://vid:pid[/serial]`,
`cups://queue`, `virtual://demo`. Befehle: `discover`, `status`, `info`, `send <datei|->`, `print <bild…>`
(PNG/PNM, `--stock`, `--dpi`, `--dither`, `--copies`, `--language`), `encode <bild> [-o datei]`
(nur erzeugen), `render <zpl-datei> -o out.png [--dpmm 8]`, `action <name>`, `getvar <name>`,
`setvar <name> <wert>`, `settings` (allconfig), `config` (^HH), `files`, `upload-font <ttf> [--name]`,
`upload-graphic <png> [--name]`, `firmware <datei>`, `terminal` (interaktiv), `models`, `stocks`,
`test-label`, `virtual-printer [--port 9100] [--model zd421t]`, `version`, `help`.

Treiberoptionen für `print` und `encode` (je eine `PrintSettings`-Eigenschaft, §9): `--darkness`,
`--speed`, `--media-type`, `--tracking gap|blackMark|continuous|auto|notch`, `--print-mode`
(inkl. `linerlessPeel` … `linerlessTear`), `--label-top`, `--label-left`, `--tear-off`, `--backfeed`,
`--negative`, `--mirror`, `--rotate180`, `--rotation 0|90|180|270`, `--mark-offset`, `--stop-at-last`,
`--stop-offset`, `--pause-every`, `--cut-every`, `--control-chars standard|printer` mit
`--format-prefix`/`--control-prefix`/`--delimiter` (Zeichen oder dezimaler Code 33…126; nur mit
`printer`), `--rtc jobStart|everyLabel|everyMinute`, `--cancel-before`, `--cancel-delay`,
`--label-start-commands`, `--label-end-commands`, `--power-up-action`/`--head-close-action`
(`feed|calibrate|length|noMotion|shortCal` oder ZPL-Code), `--calibrate`, `--save-settings`,
`--skip-blank`, `--start-commands`, `--end-commands`. Nur `encode`: `--no-collate`, `--max-width`,
`--fixed-time <s>` (feste Uhrzeit für `^ST`, Sekunden seit 1970), `--time-step <s>` (Etikett k sieht
die Zeit + k·s, wie `LW_TIME_STEP_SECONDS`), `--time-zone <id>` (Standard: `TZ` bzw. Systemzeitzone),
`--fit-to-label auto|off` (`lwFitToLabel`), `--label-size <B>x<H>[mm|in]` (`lwLabelWidth`/`lwLabelHeight`,
Höhe 0 = frei), `--page-size <B>x<H>[,<B>x<H>…]` (Seitengröße der Bilder in Punkten wie `cupsPageSize`;
eine Angabe für alle Bilder oder genau eine je Bild; nur mit `--no-layout`; ohne Angabe gilt jedes Bild
als etikettengroß, Schritt F entfällt).
Mit `--rotation 90|270` passt `print`/`encode` (ohne `--no-layout`) das Bild in das quer liegende
Etikett ein; der `JobEncoder` dreht die Seite danach zurück.

## 8. Druckauftragsformat (verbindlich für `JobEncoder` **und** C-Filter)

Eingang: Seiten als `MonoBitmap` (1 = schwarz). Wirksame Drehung `R = effectiveRotation`
(`rotation`, falls ≠ 0, sonst 180 bei `rotate180`, sonst 0). Reihenfolge der Bitmap-Vorverarbeitung
(alle Sprachen, Einstellungen zuvor mit `clamped()` begrenzt):

0. `R` = 90 bzw. 270 → Bitmap im Uhrzeigersinn drehen (neue Größe H × W): 90°: Punkt (x, y) →
   (H − 1 − y, x); 270°: (x, y) → (y, W − 1 − x).
1. Breite > `maxPrintWidthDots` → rechts abschneiden. Seiten ohne Fläche (Breite oder Höhe 0)
   werden danach übersprungen und zählen nicht für Kopien/Sortierung.
   1b. `stopAtLastElement` **und** `tracking == continuous` → Seitenhöhe = (letzte Zeile mit einem
   schwarzen Punkt, −1 bei leerer Seite) + 1 + `stopOffset`, mindestens 1; kürzer → unten
   abschneiden, länger → weiße Zeilen anfügen.
2. `negative` → invertieren.
3. `skipBlankLabels` und Seite leer → Seite überspringen.
4. Nur EPL/CPCL: `mirror` → spiegeln.
5. `R` = 180: ZPL `^POI`, EPL `ZB`, CPCL dreht die Bitmap um 180°.

ZPL spiegelt per `^PM`. Zeilenende ZPL: jeder Befehl in eigener Zeile, abgeschlossen mit `\n` (LF);
Grafikdaten in einer Zeile.

### F. An Etikett anpassen (`lwFitToLabel`, vor dem Rastern)

macOS-Programme schicken oft die Systempapiergröße (A4/Letter, „Andere 210 × 297 mm“ – das
Standardpapierformat der macOS-Systemeinstellungen gilt für alle Drucker, nicht je Warteschlange) oder
die Seitengröße des Dokuments statt der Etikettengröße der Warteschlange. Ein quer liegendes Etikett
legt macOS dabei („Automatisch drehen“ bzw. IPP-Querformat) um 90° **gegen** den Uhrzeigersinn
gedreht auf die Hochformatseite, bei „Skalierung 100 %“ oft kleiner als das Etikett. Schritt F legt
solche Seiten automatisch aufrecht und formatfüllend (abzüglich 1,5 mm Rand) auf das Etikett,
**bevor** gerastert wird (Graustufen `L`, 0 = schwarz); danach läuft alles wie gewohnt (Rastern über
die volle Breite, Schritte 0–5 mit Benutzer-Drehung `R`, Spiegeln, Negativ, Abschneiden auf die
Druckbreite, Bei letztem Element stoppen …), als hätte das Programm eine etikettengroße Seite
geschickt. Passt die Seitengröße (± 2 mm in beiden Richtungen, so wie sie ist), bleibt die Ausgabe
byte-gleich zu der ohne Schritt F. Alle Rechnungen sind Ganzzahlrechnungen (64 Bit, Division mit
Abschneiden, alle Werte ≥ 0), bis auf die Umrechnung der Seitengröße (IEEE-754 `double`, genau so).

Eingaben je Seite: Luminanz `L(x, y)` (`w × h` Punkte; Seiten ohne Fläche werden wie bisher ohne
Schritt F übersprungen), Seitengröße `pw × ph` in Punkten (Filter: `cupsPageSize[0/1]`, wenn beide
> 0, sonst `PageSize[0/1]`, wenn beide > 0, sonst unbekannt; Swift `PageSizePoints`, Python
`page_sizes`), Auflösung `xdpi`/`ydpi` (Filter `HWResolution[0/1]`; Swift/Python: die Auflösung des
Auftrags für beide), Einstellungen `lwFitToLabel`, `lwLabelWidth` (`lw`), `lwLabelHeight` (`lh`),
`lwMediaTracking`, wirksame Drehung `R`.

1. **Ziel bestimmen.** Schritt F entfällt, wenn `lwFitToLabel = Off`, `lw = 0` oder die
   Seitengröße unbekannt bzw. ungültig ist (nicht `0 < pw ≤ 100000` und `0 < ph ≤ 100000`).
   Etikettenlänge `le = (lwMediaTracking = Continuous) ? 0 : lh` – 0 heißt **frei** (Endlosmaterial:
   nur die Breite wird angepasst, die Länge folgt dem Inhalt). In Seitenrichtung: `R` = 90/270 →
   `(cw, ch) = (le, lw)` (die Seite liegt quer, Schritt 0 dreht sie später), sonst `(cw, ch) = (lw, le)`.
   Seite in 1/100 mm: `Pw = ⌊pw · 2540 / 72 + 0,5⌋` (genau so in `double`: `floor(pw * 2540.0 / 72.0 + 0.5)`),
   `Ph` ebenso. Schritt F entfällt, wenn keine feste Seite abweicht: weder `cw > 0 ∧ |Pw − cw| > 200`
   noch `ch > 0 ∧ |Ph − ch| > 200`. Etikett in Punkten: `W = (cw · xdpi + 1270) / 2540`,
   `H = (ch · ydpi + 1270) / 2540` (frei: kein Wert). Schritt F entfällt, wenn eine feste Seite
   `< 1` oder `> 32000` Punkte ergibt oder `xdpi`/`ydpi` nicht in 1…100000 liegt (der Filter wertet
   größere `HWResolution` als unbekannt). Sicherheitsrand je Seite (1,5 mm, gerundet):
   `mx = (150 · xdpi + 1270) / 2540` links und rechts, `my = (150 · ydpi + 1270) / 2540` oben und unten
   (152 dpi: 9, 203 dpi: 12, 300 dpi: 18, 600 dpi: 35 Punkte).
2. **Inhalt.** Ein Punkt ist Inhalt ⇔ `L < 250`. `x0`/`x1` = kleinste/größte Spalte, `y0`/`y1` =
   kleinste/größte Zeile mit Inhalt; `bw = x1 − x0 + 1`, `bh = y1 − y0 + 1`. Ohne Inhalt (leere Seite)
   wird das Ergebnis ein weißes Etikett `W × H` (`L = 255`; freie Seite = 1 Punkt) – weiter mit dem
   Rastern.
3. **Drehen.** Rahmen für einen Inhalt `u × v` (auch in Schritt 4):
   `BW = W − 2 · mx` (ist das `< 1`: `W`; freie Breite: `u`),
   `BH = H − 2 · my` (ist das `< 1`: `H`; freie Länge: `v`) – entlang einer freien Seite wird also nie
   vergrößert. Gilt die **Referenz** des Auftrags (siehe unten), übernimmt die Seite deren Drehung
   `t_R`. Sonst gilt die eigene Drehung: Gedreht wird nur, wenn
   **beide** Seiten fest sind (dann hängt der Rahmen `BW × BH` nicht vom Inhalt ab) und der gedrehte
   Inhalt mehr als 10 % größer würde: `s90 > 1,1 · s0` mit `s0 = min(BW / bw, BH / bh)` und
   `s90 = min(BW / bh, BH / bw)` (exakte Brüche). Das ist gleichwertig zu – und wird so gerechnet:
   * `10 · bh > 11 · bw ∧ 10 · BW > 11 · BH` (Inhalt hoch, Etikett quer) → **90° im Uhrzeigersinn**
     (macht die Drehung gegen den Uhrzeigersinn rückgängig, mit der macOS ein Querformat-Etikett auf
     eine Hochformatseite legt);
   * `10 · bw > 11 · bh ∧ 10 · BH > 11 · BW` (Inhalt quer, Etikett hoch) → **90° gegen den
     Uhrzeigersinn** (270°);
   * sonst keine Drehung.

   (Mit `q = bh / bw` und `a = BW / BH` gilt `s90 / s0 = min(q, a)` für `q > 1 ∧ a > 1`,
   `min(1/q, 1/a)` für `q < 1 ∧ a < 1` und `≤ 1` sonst.) Der Ausschnitt wird ganzzahlig gedreht zu
   `S` mit `rw × rh = bh × bw`: 90°: `S(bh − 1 − y, x) = L(x0 + x, y0 + y)`; 270°:
   `S(y, bw − 1 − x) = L(x0 + x, y0 + y)` (`0 ≤ x < bw`, `0 ≤ y < bh`). Ohne Drehung: `rw × rh = bw × bh`,
   `S(x, y) = L(x0 + x, y0 + y)`.
4. **Zielgröße** `tw × th` (vergrößern **und** verkleinern, Seitenverhältnis erhalten): Rahmen
   `BW × BH` aus Schritt 3 für `u × v = rw × rh`. Eigener Maßstab als Bruch `sp = np / dp`:
   `BW · rh ≤ BH · rw` → `(np, dp) = (BW, rw)`, andernfalls `(BH, rh)`. Maßstab `s = n / d`: der
   eigene; gilt die Referenz, deren Maßstab `sR = nR / dR`, sofern der Inhalt damit in den Rahmen
   passt (`sR ≤ sp`, gerechnet als `nR · dp ≤ np · dR`), sonst der eigene. Dann
   `tw = max(1, (2 · rw · n + d) / (2 · d))`, `th = max(1, (2 · rh · n + d) / (2 · d))`. Mit dem eigenen
   Maßstab füllt die begrenzende Seite den Rahmen genau (`tw = BW` bzw. `th = BH`), die andere ist
   kaufmännisch gerundet. Bei freier Länge ist `BH = rh` und damit `sp ≤ 1` (auch `sR ≤ 1`): Es wird
   nie vergrößert, die Länge folgt dem Inhalt; mit dem eigenen Maßstab wird ein Inhalt breiter als
   `BW` auf `BW` verkleinert, ein schmalerer bleibt unverändert. Bei freier Breite entsprechend.
5. **Skalieren (Flächenmittel, beide Richtungen).** Quellpunkt `x` deckt auf einer gemeinsamen
   Ganzzahlachse `[x · tw, (x + 1) · tw)`, Zielpunkt `X` deckt `[X · rw, (X + 1) · rw)` (senkrecht mit
   `th`/`rh` ebenso). Für jeden Zielpunkt `(X, Y)`:
   `Σ = Σx Σy ax(X, x) · ay(Y, y) · S(x, y)` über `0 ≤ x < rw`, `0 ≤ y < rh` mit
   `ax(X, x) = max(0, min((x + 1) · tw, (X + 1) · rw) − max(x · tw, X · rw))` und
   `ay(Y, y) = max(0, min((y + 1) · th, (Y + 1) · rh) − max(y · th, Y · rh))`;
   Wert `= (Σ + T / 2) / T` mit `T = rw · rh` (die Gewichte eines Zielpunkts ergeben zusammen genau
   `T`). Dieselbe Formel verkleinert (Flächenmittel) und vergrößert (Box-Abtastung: ein Zielpunkt
   überdeckt einen oder zwei Quellpunkte je Achse; ganzzahliger Faktor → reine Kopien, z. B.
   `[0, 255]` → `[0, 0, 255, 255]`, 2 → 3 Punkte → `[0, 128, 255]`); je Achse unabhängig. Bei
   `tw = rw ∧ th = rh` ist das genau die Kopie (Implementierungen dürfen dann kopieren). Die Summe
   ist trennbar (erst Zeilen, dann Spalten), darf aber erst am Ende einmal gerundet werden.
6. **Einsetzen.** Etikett `CW × CH` mit `CW = W` (frei: `tw`), `CH = H` (frei: `th`), weiß (255);
   das Bild kommt an `ox = (CW − tw) / 2`, `oy = (CH − th) / 2` (waagerecht **und** senkrecht
   mittig; da `tw ≤ BW` und `th ≤ BH`, bleibt bei fester Seite auf jeder Seite mindestens der Rand
   `mx` bzw. `my` frei, außer der Rand ist größer als das Etikett). Dieses Bild ersetzt die Seite.

**Referenz (einheitlich je Auftrag).** Jeder Encoder führt je Auftrag eine Referenz
`R = (W, H, mx, my, Pw, Ph, t_R, nR, dR)`, anfangs keine (Filter: `lw_fit_reference` im Auftrag, Swift:
`LabelFit.Reference` in `JobEncoder.fitted(_:pageSizes:)`, Python: `FitMemory` in `fit_images`). Sie
**gilt** für eine Seite mit Schritt F und Inhalt, wenn `W`, `H` (frei = frei), `mx` und `my` gleich sind
und `|Pw − Pw_R| ≤ 200 ∧ |Ph − Ph_R| ≤ 200` (gleiche Seitengröße auf ± 2 mm). Gilt sie nicht, entscheidet
die Seite selbst (eigene Drehung und eigener Maßstab) und wird danach die neue Referenz – mit ihrer
Drehung `t` und ihrem eigenen Maßstab `(np, dp)`. Seiten ohne Schritt F, leere Seiten und Seiten, die
der Filter mangels Speicher unverändert druckt, lassen `R` unverändert. Grund: macOS dreht und
verkleinert jede Seite eines Etikett-PDFs gleich, doch der Inhaltsrahmen einer einzelnen Seite zeigt
die Drehung nur, wenn ihr Inhalt das Etikett ausfüllt – ein Adressetikett mit kurzen Zeilen ist auch
nach der Drehung von macOS breiter als hoch und käme sonst quer und in anderer Größe heraus. So
entscheidet die erste angepasste Seite mit Inhalt für alle folgenden gleicher Größe: gleiche Drehung,
gleicher Maßstab (kleiner nur, wenn ein Inhalt sonst nicht in den Rahmen passt).

Folgen: Ein Etikett-PDF, das Vorschau oder Safari bei 100 % auf A4 oder Letter setzt – auch halb so
groß und gegen den Uhrzeigersinn gedreht mitten auf der Seite –, wird ohne den weißen Rand aufrecht,
seitenverhältnistreu und formatfüllend (1,5 mm Rand) gedruckt, alle Seiten gleich gedreht und gleich
groß; größerer Inhalt (z. B. eine ganze A4-Seite) wird verkleinert, kleinerer vergrößert (bei
Endlosmaterial nur verkleinert); eine leere Seite ergibt ein leeres Etikett (mit
`skipBlankLabels` übersprungen). `lwLabelWidth`/`lwLabelHeight` sind Warteschlangen-Standards aus
dem Etikettenformat (§9); ohne sie (ältere Warteschlangen, `lwctl encode` ohne `--label-size`) und mit
`lwFitToLabel=Off` bleibt alles wie bisher. Der Filter puffert nur in Schritt F eine ganze Seite
(`w · h` Bytes, höchstens 1 GiB) sowie bei einer Drehung den gedrehten Ausschnitt (`bw · bh` Bytes);
ist die Seite größer oder fehlt Speicher, druckt er sie mit `WARNING:` unverändert (die einzige
Stelle, an der Filter und `JobEncoder` absichtlich abweichen können). Er meldet jede angepasste Seite
mit `INFO:` (Größe, Etikett in Punkten, ggf. „um 90° im Uhrzeigersinn gedreht“ bzw. „um 90° gegen den
Uhrzeigersinn gedreht“).

Entscheidungen (gegenüber dem ersten Entwurf präzisiert): Bei Endlosmaterial
(`lwMediaTracking=Continuous`) bzw. `lwLabelHeight=0` ist die Länge frei – sonst würde ein langer
Beleg auf die Abschnittslänge des Formats geschrumpft; gedreht wird dann nie, der Rand gilt nur für
die feste Seite, und vergrößert wird nie (der Rahmen der freien Seite ist der Inhalt: eine Seitenzahl
oder ein Strich auf sonst leerer Seite würde sonst auf volle Breite und bis zu 4 m Länge vergrößert). Bei `R` = 90/270 gilt das Etikett quer (wie `lwctl print` die Seite für eine Drehung
quer einpasst); Schritt F dreht in Seitenrichtung, die Benutzer-Drehung `R` folgt danach in Schritt 0.
Die Inhaltsschwelle 250 ignoriert JPEG-/Scanner-Rauschen nahe Weiß; dunklere Punkte gehören zum
Inhalt, auch wenn das gewählte Rasterverfahren sie weiß drucken würde. Version 2 (Meldung „Etikett
halb so groß und gedreht auf A4“): Vergrößern ist erlaubt, weil Druckdialoge Etiketten oft mit
„Skalierung 100 %“ verkleinert liefern; der Rand von 1,5 mm fängt Seitenversatz und Schnitttoleranz
der Etiketten ab; die Drehschwelle 10 % verhindert, dass fast quadratische Inhalte kippen; die
Box-Abtastung braucht keine Gleitkommazahlen, ist in C, Swift und Python bitgleich und lässt Striche
und Barcodes bei ganzzahligen Faktoren scharf (nur Kantenpunkte werden bei krummen Faktoren grau und
danach wie gewohnt gerastert).

### ZPL

```
~JA\n                                 falls cancelJobsBeforePrint (Filter: Ausgabe leeren, cancelDelayMs warten)
{startCommands}\n                     falls nicht leer
~SD{dd}\n                             falls darkness (zweistellig, 0-gefüllt: ~SD08)
~TA{±ddd}\n                           falls tearOffAdjust (printf "%03d": ~TA010, ~TA-10)
~JS{A|B|N|O}\n                        falls backfeed (Steuerbefehl; ^JS ist die Sensorwahl)
~JC\n                                 falls calibrateBeforeJob
! U1 setvar "media.printmode" "{sgd}"\r\n   falls printMode linerless (sgdSetValue: L | linerless cut |
                                      linerless delayed cut | U | V; Zeilenende CR LF)
^XA^MF{a},{b}^XZ\n                    falls powerUpAction UND headCloseAction (F|C|L|N|S)
^XA^ST{MM},{DD},{YYYY},{HH},{mm},{SS},M^XZ\n   falls rtcUpdate (Ortszeit, 0-gefüllt, 24 h)
— je Etikett (k = 0, 1, … in Auftragsreihenfolge inkl. Sortierwiederholungen) —
^XA^ST…^XZ\n                         everyLabel und k > 0, bzw. everyMinute und ≥ 60 s seit dem letzten ^ST
^XA\n
{labelStartCommands}\n                falls nicht leer
^MM{T|P|C|D|R|A|K}\n                  falls printMode und nicht linerless
^MN{Y|M|N|A|W}\n                      falls tracking; blackMark mit markOffset: ^MNM,{offset}
^MT{D|T}\n                            falls mediaType
^PR{s},{s},{s}\n                      falls speed
^PW{breite}\n
^LL{höhe}\n
^LH0,0\n
^LT{top}\n                            falls labelTop
^LS{left}\n                           falls labelLeft
^PO{I|N}\n                            R == 180 ? I : N
^PM{Y|N}\n                            mirror ? Y : N
^FO0,0^GFA,{total},{total},{bpr},{daten}^FS\n
^PQ{n}\n                              ^PQ{n},{pauseEvery},0,N falls pauseEvery > 0 (Vorrang),
                                      sonst ^PQ{n},{cutEvery},0,Y falls cutEvery > 0
^JUS\n                                nur beim ersten Etikett, falls saveToPrinter
{labelEndCommands}\n                  falls nicht leer
^XZ\n
— Ende —
{endCommands}\n                       falls nicht leer
```

* `{daten}`: Hex = Großbuchstaben ohne Trenner; ACS = §4; Z64 = `:Z64:` + Base64 (Standardalphabet,
  mit Padding, ohne Zeilenumbrüche) von zlib-komprimierten Rohbytes (`compress2`, Level
  `Z_DEFAULT_COMPRESSION`) + `:` + CRC als 4 Großbuchstaben-Hex.
* Kopien: `collate == false` oder nur eine Seite → je Seite `^PQ{copies}`.
  `collate == true` und > 1 Seite → gesamte Seitenfolge `copies`-mal wiederholen, je `^PQ1`.
* Höhe `^LL` = Bitmaphöhe.
* **Pausieren/Schneiden alle N Etiketten** (`pauseEvery`, `cutEvery`): `^PQ` zählt Gruppen innerhalb
  der Menge **eines** Formats. Beide gelten deshalb je Seite und Kopiengruppe; bei sortierten
  Aufträgen mit mehreren Seiten (jedes Etikett `^PQ1,{p},0,…`) wird eine Gruppe von p ≥ 2 nie voll –
  der Drucker pausiert bzw. schneidet dann nicht zwischendurch (bewusst unverändert, in allen drei
  Encodern gleich; ohne Sortierung bzw. mit einer Seite wirkt der Wert wie im Windows-Treiber).
* **`^MF`** ist eine vorübergehende Einstellung: Die Aktion beim Schließen des Druckkopfs gilt sofort
  (bis zum Ausschalten), die Aktion beim Einschalten erst beim nächsten Einschalten – also nur, wenn
  die Einstellungen gespeichert werden (`saveToPrinter`/`lwSaveSettings` → `^JUS`, in der App auch
  „Dauerhaft speichern“). Die Encoder fügen dafür kein `^JUS` hinzu.
* **Echtzeituhr** (`rtcUpdate`): Zeit in ganzen Sekunden seit 1970 (abgerundet), als Ortszeit
  formatiert (Swift `JobEncoder.timeZone`, C/Python `localtime()` nach `TZ`). Auftragskopf: Zeit T0.
  Etikett k: Zeit Tk (laufende Uhr; zum Testen T0 + k·Schritt: Swift `now`/`timeStepSeconds`, C
  `LW_FIXED_TIME`/`LW_TIME_STEP_SECONDS`, Python `now`/`time_step`). `everyLabel`: `^ST` vor jedem
  Etikett mit k > 0; `everyMinute`: vor jedem Etikett (auch k = 0), sobald Tk − (Zeit des letzten `^ST`)
  ≥ 60; `jobStart`: nur im Kopf. Ein Etikett mit `^PQ{n}` zählt als **ein** Etikett.
* **Steuerzeichen „Intern“** (`controlCharacters` ≠ nil, Zeichen 33…126, ungültige → Standardzeichen):
  in **allen selbst erzeugten** Befehlen wird `^` durch `formatPrefix`, `~` durch `controlPrefix` und
  `,` durch `delimiter` ersetzt – auch in `~JA`, `~SD`, `~TA`, `~JS`, `~JC`, `^XA^MF…^XZ`,
  `^XA^ST…^XZ`, `^LH0,0`, `^PR`, `^PQ`, `^MNM,n` und im `^GFA`-Kopf
  (`{fp}FO0{d}0{fp}GFA{d}{total}{d}{total}{d}{bpr}{d}{daten}{fp}FS`). **Nicht** ersetzt werden
  Start-/End-/Etikettenbefehle, die SGD-Zeile und die Grafikdaten (z. B. `,`/`!`/`:` in ACS).
* **Aufträge abbrechen**: `~JA` steht am Auftragsanfang vor den Startbefehlen (ZPL-Handbuch: `~JA`
  löscht die Daten vor sich im Eingangspuffer – stünden die Startbefehle davor, gingen sie verloren).
  Der C-Filter leert danach die Ausgabe und wartet `cancelDelayMs`; `JobEncoder` schreibt nur die
  Zeile – `PrinterClient.printImages` bzw. `PrinterClient.sendJob` (App) sendet die `~JA`-Zeile
  (`cancelPrefixLength()` = Länge dieser Zeile, ZPL mit eigenem Steuerzeichen), wartet und sendet
  den Rest.
* Nur ZPL: `markOffset`, `pauseEvery`, Steuerzeichen, `rtcUpdate`, `^MF`, Linerless-SGD. EPL und CPCL
  ignorieren sie (Drehung 90/270 und „Bei letztem Element stoppen“ gelten für alle Sprachen).

### EPL2 (Zeilenende `\n`)

```
~JA\n                                 falls cancelJobsBeforePrint (wörtlich, ohne eigene Steuerzeichen; Filter wartet)
{startCommands}\n                     falls nicht leer
— je Etikett —
\nN\n                                  (führendes LF leert evtl. Restdaten)
{labelStartCommands}\n                falls nicht leer
q{breite}\n
Q{höhe},{lücke}\n                     tracking gap/notch/auto/nil: Lücke = stock.gapDots oder 24; blackMark: Q{höhe},B{lücke}; continuous: Q{höhe},0
S{speed}\n                            falls speed (begrenzt 1…6)
D{density}\n                          falls darkness (round(darkness/2), 0…15)
Z{B|T}\n                              R == 180 ? B : T
O{D}{C|P}\n                           falls mediaType/printMode gesetzt: "O" + (directThermal ? "D" : "") + (cutter ? "C" : peelOff ? "P" : "")
                                      (Linerless-Modi: weder C noch P)
GW0,0,{bpr},{höhe},<binär, Bit 0 = schwarz>\n
{labelEndCommands}\n                  falls nicht leer (vor P: das nächste N leert den Bildpuffer)
P{n}\n                                bzw. P1 bei Sortierung (wie ZPL)
— Ende —
{endCommands}\n                       falls nicht leer
```

### CPCL (Zeilenende `\r\n`)

```
— je Etikett —
! 0 {res} {res} {höhe} {n}\r\n          {res} = 200 bei 203 dpi, sonst dpi
PAGE-WIDTH {breite}\r\n
CONTRAST {0…3}\r\n                    falls darkness (darkness*3/30 gerundet)
SPEED {0…5}\r\n                       falls speed (min(speed,5))
CG {bpr} {höhe} 0 0 <binär, 1 = schwarz>\r\n
FORM\r\n                              außer bei continuous
PRINT\r\n
```

CPCL hat keinen Auftragskopf: Start-/Endbefehle, `~JA` (`cancelJobsBeforePrint`) und Befehle je
Etikett entfallen ebenso wie alle ZPL-Optionen.

## 9. CUPS-Optionen (PPD ↔ Filter ↔ App)

| Option | Werte | Bedeutung |
|---|---|---|
| `lwLanguage` | `ZPL` `EPL` `CPCL` | Ausgabesprache |
| `lwDarkness` | `Default`, `0`…`30` (PPD: 1…30) | `~SD` („Temperatur“) |
| `lwSpeed` | `Default`, `1`…`14` (PPD: 2 … Modellmaximum) | `^PR`; PPD wie Windows ab 51 mm/s (2 Zoll/s), `1` nur als Auftragsoption |
| `lwMediaType` | `Default` `DirectThermal` `ThermalTransfer` | `^MT` („Druckmodus“) |
| `lwMediaTracking` | `Default` `Gap` `BlackMark` `Continuous` `Auto` `Notch` | `^MN` („Medientyp“; `Notch` = `^MNW`, EPL wie `Gap`) |
| `lwPrintMode` | `Default` `TearOff` `PeelOff` `Cutter` `DelayedCut` `Rewind` `Applicator` `Kiosk` `LinerlessPeel` `LinerlessCut` `LinerlessDelayedCut` `LinerlessRewind` `LinerlessTear` | `^MM`; Linerless: kein `^MM`, SGD `media.printmode` im Auftragskopf mit dem dokumentierten Setzwert (`L`/`U`/`V`, für `LinerlessCut`/`LinerlessDelayedCut` das Wort; PPD: Linerless nur bei Modellen mit Linerless-Ausstattung) |
| `lwLabelTop` | `Default`, `-120`…`120` (PPD: Schritte von 10) | `^LT` |
| `lwLabelLeft` | `Default`, `-9999`…`9999` (PPD: −200…200, Schritte 10) | `^LS` |
| `lwTearOff` | `Default`, `-120`…`120` (PPD: Schritte von 10) | `~TA` |
| `lwBackfeed` | `Default` `After` `Before` `Normal` `Off` | `~JS` |
| `lwMirror` `lwNegative` | `False` `True` | |
| `lwRotate180` | `False` `True` (nicht in der PPD, veraltet) | wirkt nur bei `lwRotation=0` (dann wie `180`); Updates (postinstall, `lwctl install`) übernehmen den alten Warteschlangen-Standard `True` als `lwRotation=180` |
| `lwRotation` | `0` `90` `180` `270` | Drehung im Uhrzeigersinn: 90/270 in Software vor dem Abschneiden, 180 per `^POI`/`ZB`/CPCL-Bitmap |
| `lwMarkOffset` | `Default`, `-80`…`283` Punkte (PPD: -10 -5 -3 -2 -1 0 1 2 3 4 5 10 15 20 25 30 35 mm je Auflösung) | `^MNM,n` (nur `BlackMark`, nur ZPL); mm-Werte außerhalb des Bereichs entfallen |
| `lwStopAtLast` | `False` `True` | nur `Continuous`: Seitenhöhe = letzte schwarze Zeile + 1 + `lwStopOffset` |
| `lwStopOffset` | `0`…`32000` Punkte (PPD: 0 1 2 3 5 10 mm je Auflösung) | Abstand nach dem letzten Element |
| `lwPauseEvery` | `0`…`9999` (PPD: 0 1 2 5 10 25 50 100) | `^PQn,p,0,N` (Vorrang vor `lwCutEvery`; je Seite und Kopiengruppe, ohne Wirkung bei sortierten Aufträgen mit mehreren Seiten, §8) |
| `lwControlChars` | `Standard` `Printer` | `Printer` („Intern“): eigene Steuerzeichen aus `lwFormatPrefix`/`lwControlPrefix`/`lwDelimiter` |
| `lwFormatPrefix` `lwControlPrefix` `lwDelimiter` | `33`…`126` (dezimaler ASCII-Code, nicht in der PPD) | ersetzt `^` / `~` / `,`; fehlend oder ungültig → Standardzeichen |
| `lwRTC` | `Default` `JobStart` `EveryLabel` `EveryMinute` | `^ST` (Ortszeit) |
| `lwCancelBefore` | `False` `True` | `~JA` vor dem Auftrag (ZPL, EPL) |
| `lwCancelDelay` | `0`…`10000` ms (PPD: 0 250 500 1000 2000 3000 5000 10000) | Wartezeit des Filters nach `~JA` (Standard 1000) |
| `lwPowerUpAction` `lwHeadCloseAction` | `Default` `Feed` `Calibrate` `Length` `NoMotion` `ShortCal` | `^MFa,b` (nur wenn beide gesetzt); die Aktion beim Einschalten wirkt erst beim nächsten Einschalten und braucht `lwSaveSettings=True` (§8) |
| `lwDither` | `Threshold` `Ordered` `Halftone` `FloydSteinberg` `Atkinson` `Stucki` | |
| `lwThreshold` | `1`…`254` (PPD: 64 96 128 160 192) | |
| `lwCompression` | `Z64` `ACS` `Hex` | |
| `lwCutEvery` | `0`…`9999` (PPD: 0 1 2 5 10 25 50 100) | `^PQn,c,0,Y` (je Seite und Kopiengruppe wie `lwPauseEvery`) |
| `lwCalibrate` `lwSaveSettings` `lwSkipBlank` | `False` `True` | |
| `lwStartCmd` `lwEndCmd` | Base64url (UTF-8, ohne Padding) | Rohbefehle vor/nach dem Auftrag |
| `lwLabelStartCmd` `lwLabelEndCmd` | Base64url (UTF-8, ohne Padding) | Rohbefehle am Anfang/Ende jedes Etiketts |
| `lwFitToLabel` | `Auto` `Off` | „An Etikett anpassen“ (Standard `Auto`; der Wert „Default“ bedeutet `Auto`): Seiten, deren Größe um mehr als 2 mm vom Etikett abweicht (A4/Letter aus dem macOS-Druckdialog), legt der Treiber vor dem Rastern auf das Etikett – zugeschnitten auf den Inhalt, bei Bedarf um 90° gedreht, vergrößert oder verkleinert, mittig mit 1,5 mm Rand (§8 „F“) |
| `lwLabelWidth` `lwLabelHeight` | `0`…`100000` (1/100 mm, nicht in der PPD; `0` = unbekannt) | Etikettengröße der Warteschlange für `lwFitToLabel` (aus dem Etikettenformat; Endlosmaterial: Länge `0` = frei); ohne `lwLabelWidth` keine Anpassung |

Nicht in der PPD (frei wählbare Werte bzw. veraltet; nur als Warteschlangen-Standard per `lpadmin`
oder Auftragsoption): `lwStartCmd`, `lwEndCmd`, `lwLabelStartCmd`, `lwLabelEndCmd`, `lwFormatPrefix`,
`lwControlPrefix`, `lwDelimiter`, `lwRotate180`, `lwLabelWidth`, `lwLabelHeight`. Die PPD gruppiert die
übrigen Optionen wie der Windows-Treiber: „Seite einrichten“ (Seitengröße, `lwFitToLabel`,
`lwMediaTracking`, `lwMarkOffset`, `lwRotation`,
`lwMirror`, `lwNegative`, `lwStopAtLast`, `lwStopOffset`), „Druckoptionen“ (`lwSpeed`, `lwDarkness`,
`lwMediaType`, `lwLabelTop`, `lwLabelLeft`, `lwBackfeed`, `lwPauseEvery`, `lwControlChars`, `lwRTC`,
`lwCancelBefore`, `lwCancelDelay`), „Bedienermodus“ (`lwPrintMode`, `lwTearOff`, `lwCutEvery`),
„Grafik Optionen“ (`lwDither`, `lwThreshold`, `lwCompression`) und „Erweitert“ (`lwLanguage`,
`lwCalibrate`, `lwSaveSettings`, `lwSkipBlank`, `lwPowerUpAction`, `lwHeadCloseAction`, Auflösung,
Farbmodell).

Lesen der Optionen (Swift `PrintSettings(cupsOptions:)`, C-Filter, Python-Referenz gleich): Leerraum
` \t\r\n\v\f` am Rand zählt nicht, leere Werte gelten als nicht gesetzt; Aufzählungen, `Default`
und Wahrheitswerte ohne Beachtung der Groß-/Kleinschreibung (nur ASCII: `everylabel` = `EveryLabel`);
Ganzzahlen optional mit `Custom.`-Präfix und Vorzeichen, sonst nur Ziffern (`12 mm`, `1.5` ungültig);
`lwRotation` nur exakt `0`/`90`/`180`/`270` (`+90`, `090` ungültig → 0); `lwControlChars`: nur
`Printer` aktiviert `lwFormatPrefix`/`lwControlPrefix`/`lwDelimiter` (je fehlend, `Default` oder außerhalb
33…126 → Standardzeichen `^`/`~`/`,`); Zahlen außerhalb des Bereichs werden begrenzt (`lwMarkOffset`
−80…283, `lwStopOffset` 0…32000, `lwPauseEvery` 0…9999, `lwCancelDelay` 0…10000, `lwLabelWidth` und
`lwLabelHeight` je 0…100000); `lwFitToLabel` kennt nur `Auto`/`Off` (ungültig → nächste Ebene,
zuletzt `Auto`). `cupsOptions()` schreibt `lwRotation` und `lwRotate180` unverändert (Rundreise
exakt), `lwFormatPrefix`… nur bei `Printer`, leere Befehle (`lwLabelStartCmd`, `lwLabelEndCmd`) und
`lwLabelWidth`/`lwLabelHeight` = 0 gar nicht.

Vorrang im Filter: Wert aus `argv[5]` (Job-/Warteschlangen-Optionen) **vor** markierter PPD-Auswahl
**vor** PPD-Default. Ganzzahlen außerhalb der PPD-Auswahl sind erlaubt. Warteschlangen-Standardwerte
setzt die App als serverseitige Vorgaben mit `lpadmin -p <queue> -o lwLabelTop-default=37`
(entfernen: `-R lwLabelTop-default`); CUPS übergibt sie jedem Auftrag als `lwLabelTop=37` in
`argv[5]`. Die Kurzform `-o lwLabelTop=37` speichert CUPS nur für PPD-Optionen mit gültiger Auswahl
und verwirft andere Werte (z. B. `lwStartCmd`, Ganzzahlen außerhalb der Auswahl) stillschweigend.
`QueueDefaults.plan` setzt solche Ganzzahlen deshalb als nächstliegende PPD-Wahl plus exakten
Warteschlangen-Standard – auch `lwSpeed`, dessen Auswahl vom Modell abhängt (2 … Höchstwert bei der
Auflösung wie `ppd_speeds`; `1` und gespeicherte Werte über dem Höchstwert werden angenähert).
Boolesche Werte: `True/False/yes/no/on/off/1/0`.

Zusätzliche PPD-Attribute, die der Filter liest:
`*lwModel: "zd421t"`, `*lwMaxPrintWidthDots: "832"`, `*lwDefaultGapDots: "24"`.

### Etikettengröße der Warteschlange

Wie beim Windows-Treiber wird die Etikettengröße **einmal** festgelegt (Assistent, manuelles
Hinzufügen, „Druckeinstellungen“, `lwctl install --stock|--size`) und gilt dann für jedes Programm,
ohne Auswahl im macOS-Druckdialog. Dazu trägt jede LabelWerk-Warteschlange drei Dinge:

1. **Benannte Standard-Papiergröße.** Schlüsselwort `w<pt>h<pt>` wie `LabelStock.ppdKeyword`
   (`mm / 25,4 · 72`, kaufmännisch gerundet; 104 × 76,2 mm → `w295h216`), Texte „Label 104 x 76.2 mm“
   / „Etikett 104 × 76,2 mm“ (`QueueLabelSize`, Maße auf 0,01 mm, ohne Nullen am Ende). Ob die Größe
   schon in der Modell-PPD steht, entscheidet `PPDPageSizes` (LabelWerkCore) – exakt wie
   `page_sizes_for`/`build_generic_target` in `generate_ppds.py` (Breite ≤ Druckbreite + 2 mm, Länge ≤
   größte Etikettenlänge, Standardformat immer, gleiche Schlüsselwörter zusammengeführt; generische
   PPDs mit den größten Werten der Sprache). Ein Test vergleicht beide für jede erzeugte PPD.
   * Steht sie drin: `lpadmin -p <queue> -o PageSize=<schlüsselwort>`.
   * Sonst ergänzt `QueuePPD.patched` eine Kopie der installierten Modell-PPD (`.ppd.gz` wird über
     zlib gelesen, `PPDFiles`) mit der Syntax des Generators und installiert sie mit
     `lpadmin -p <queue> -P <kopie>` – `lpadmin -o PageSize=…` verwirft unbekannte Größen
     stillschweigend (`cupsMarkOptions`). Je Anker steht der Eintrag direkt nach der Standardzeile, die
     auf ihn zeigt (im Druckdialog oben):
     ```
     *lwModel: "zd421t"
     *% LabelWerk: Etikettengroesse dieser Warteschlange (von LabelWerk ergaenzt)
     *lwLabelPageSize: "w295h216"
     *DefaultPageSize: w295h216
     *PageSize w295h216/Label 104 x 76.2 mm: "<</PageSize[294.803 216]/ImagingBBox null>>setpagedevice"
     *de.Translation PageSize/Etikettenformat: ""   ← danach *de.PageSize w295h216/Etikett 104 × 76,2 mm: ""
     *DefaultPageRegion: w295h216                   ← danach *PageRegion w295h216/… (wie *PageSize)
     *de.Translation PageRegion/…                   ← danach *de.PageRegion w295h216/Etikett 104 × 76,2 mm: ""
     *DefaultImageableArea: w295h216                ← danach *ImageableArea w295h216/…: "0 0 294.803 216"
     *DefaultPaperDimension: w295h216               ← danach *PaperDimension w295h216/…: "294.803 216"
     ```
     Zahlen wie `format_number` (drei Nachkommastellen ohne Nullen am Ende), Texte wie
     `sanitize_text`. `*lwLabelPageSize` markiert die ergänzte Größe: Erneutes Ergänzen ersetzt sie,
     der Abgleich erkennt veraltete Größen, und der postinstall übernimmt sie beim Update. Die Kopie
     besteht `cupstestppd -W translations` (Test unter Linux, `ci_macos.sh` auf macOS).
2. **`lwLabelWidth`/`lwLabelHeight`** in 1/100 mm als Warteschlangen-Standard
   (`-o lwLabelWidth-default=10400 -o lwLabelHeight-default=7620`, nicht in der PPD, §9-Tabelle) für
   „An Etikett anpassen“ (§8 „F“). Endlosmaterial: keine Länge (`-R lwLabelHeight-default`).
3. **`lwFitToLabel`** (PPD-Option, Standard `Auto`; App: „Druckeinstellungen › Seite einrichten“).

`lpadmin -P` ersetzt die PPD und damit ihre `*Default…`-Werte: Jeder Aufruf mit `-P` setzt im selben
Aufruf alle Standardwerte erneut (`-o name=wert` schreibt lpadmin in die neue PPD). Die
Warteschlangen-Standards `name-default` (printers.conf) bleiben dagegen erhalten – cupsd
(`scheduler/ipp.c`, `add_printer`) kopiert nur die PPD und lässt `printer->options` unverändert.

**Wer setzt das?**
* App (`CUPSService`): `installQueue` (Assistent, manuelles Hinzufügen, „Treiber“) und `apply` mit dem
  Soll-Zustand `QueueConfiguration` (Einstellungen, Format, Sprache, Auflösung, Modell →
  `QueueDefaults.plan`). `QueueSyncService` hält jede verknüpfte Warteschlange (`SavedPrinter.cupsQueueName`)
  automatisch aktuell: sofort bei „OK“/„Übernehmen“ in „Druckeinstellungen“ (mit Passwortabfrage,
  falls nötig), 1,5 s nach jeder Änderung an `PrinterSession.saved` oder an eigenen Formaten (egal aus
  welchem Bereich der App; ein Fingerabdruck aus Warteschlange und Soll-Zustand verhindert doppelte
  Läufe) und einmal 2 s nach dem Start (auch für Warteschlangen älterer Versionen). Automatische
  Abgleiche vergleichen erst (`lpoptions -p <queue> -l` und `lpoptions -p <queue>`,
  `QueueDefaults.difference`) und rufen `lpadmin` nur bei Abweichungen auf, nie mit Passwortabfrage
  (Administratoren gehören zu `_lpadmin`); Fehler → ein Hinweis mit „Erneut versuchen“. In macOS
  entfernte Warteschlangen werden nicht neu angelegt (eine entfernte übernommene vergisst der Drucker).
  Abgeglichen werden die verknüpfte und die übernommenen Warteschlangen (`SavedPrinter.adoptedQueueNames`,
  „Übernahme von macOS-Warteschlangen“), aber nur mit LabelWerk-Treiber (PPD mit `*lwModel`, sonst
  `printer-make-and-model` mit „LabelWerk“). Eine fremde Warteschlange stellt nur die Übernahme um – also
  nur, wenn ihre Geräte-URI zum Gerät eines LabelWerk-Druckers führt; „OK“/„Übernehmen“ versucht sie
  dafür zuerst. Sonst (z. B. eine verknüpfte USB-Warteschlange mit Zebras eigener PPD) überspringen
  automatische Abgleiche sie still, „Druckeinstellungen“ meldet `notLabelWerkQueue`, und umstellen kann
  sie nur eine ausdrückliche Einrichtung (`installQueue`). Die Seitengrößen der Modell-PPD (fehlende bzw. veraltete
  Größe) stammen aus der installierten Datei (`PPDFiles.installedPageSizes`), nur ohne lesbare Datei
  aus dem Katalog der App (`PPDPageSizes`) – App und Treiber können verschiedene Versionen haben.
* `lwctl install`: `--stock <id>` oder `--size 104x76.2mm` (mm oder in) – Größe, `lwLabelWidth`/
  `lwLabelHeight`, ggf. die ergänzte Kopie. Ohne beides bleibt eine früher ergänzte Größe erhalten;
  fehlen `lwLabelWidth`/`lwLabelHeight` (neue Warteschlange, ältere Version), gelten die Maße der
  Standard-Seitengröße, die die Warteschlange danach hat.
* Treiber-Update (postinstall, `refresh_queues`): übernimmt eine ergänzte Größe mit `awk` in eine
  Kopie der neuen Modell-PPD (gleiches Ergebnis wie `QueuePPD.patched`, Test) und setzt fehlende
  `lwLabelWidth`/`lwLabelHeight` aus der Standard-Seitengröße der Warteschlange
  (`⌊pt · 2540 / 72 + 0,5⌋`); `lwFitToLabel` kommt als `Auto` aus der neuen PPD bzw. als übernommener Wert.

**Abgleich** (`QueueDefaults.difference`): Abweichend ist eine Option des Plans, deren Wert `lpoptions`
anders meldet – ohne Groß-/Kleinschreibung, denn cupsd speichert `-o lwRotate180-default=False` als
IPP-Wahrheitswert und meldet `lwRotate180=false` (PPD-Optionen, die die PPD der Warteschlange nicht kennt, zählen nicht; fehlende
Warteschlangen-Standards und `PageSize` schon), ein gesetzter Wert einer zu leerenden Option, eine
Seitengröße, die in `PageSize` von `lpoptions -l` fehlt (→ neue PPD), und eine ergänzte Größe, die
weder in der Modell-PPD steht noch gewünscht ist (→ neue PPD).

**Größe vom Drucker** (`PrinterClient.readMediaSize()`, nur ZPL mit Rückkanal): Breite = Druckbreite
`ezpl.print_width` (wie ZDesigner: 832 Punkte = 104 mm beim ZD421 mit 203 dpi), sonst die der
Identifikation bzw. des Katalogmodells; Länge = `zpl.label_length`, sonst Feld `dddd` von `~HS`;
Medientyp aus `ezpl.media_type` (bzw. `media.type`/`media.sense_mode`). Punkte → mm
(`LabelSizing.millimeters`): unter ganzen mm, Vielfachen von 0,05 Zoll und halben mm der Kandidat mit
der kleinsten Abweichung (8/12/24 Punkte je mm bzw. dpi/25,4), höchstens ein Punkt; bei Gleichstand
ganze mm vor Zoll vor halben mm (609 → 76,2; 832 → 104). Zuordnung zu einem Format
(`LabelSizing.matchingStock`): ± 0,6 mm je Maß mit passendem Medientyp, eigene Formate vor dem
Katalog, sonst ein neues eigenes Format „Benutzerdefiniert B × H mm“ (`LabelStockLibrary` in der App,
dieselbe Logik wie „Druckeinstellungen“).

**Auswahl „Etikett“ im Assistenten und beim manuellen Hinzufügen** (`LabelStockChoice`,
`LabelSizeEntry` in LabelWerkCore; Ansicht `LabelStockChooser`): über den Formaten stehen „Vom
Drucker: 104 × 76,2 mm“ (bzw. das passende vorhandene Format mit „vom Drucker erkannt“) und
„Benutzerdefiniert …“ (Breite/Höhe in mm mit Komma oder Punkt, Grenzen `LabelSizing.Limits` des
Modells, Medientyp). Die gemeldete Größe kommt aus der Erkennung (`PrinterDetection.media`) und wird
vorausgewählt, solange der Benutzer die Auswahl nicht geändert hat (`LabelStockChoice.preselection`);
ein schon in LabelWerk eingerichteter Drucker bringt sein Format als eigene Wahl mit. „Vom Drucker
übernehmen“ liest neu und gibt der Meldung wieder Vorrang. Die Auswahl legt nichts an: Erst
„Installieren“ bzw. „Drucker hinzufügen“ macht daraus ein echtes Format (`LabelStockLibrary.resolveStock`)
– vor dem Installationsauftrag, sodass die Warteschlange es als benannte Seitengröße erhält und ein
schon eingerichteter Drucker es übernimmt (`PrinterInstallService.register`).

**Name im Assistenten:** nie eine bloße Adresse. Heißt ein schon in LabelWerk eingerichteter Drucker
nur nach seiner Adresse (`QueueAdoption.isAddressName`: IPv4-/IPv6-Adresse, auch mit Port, oder der
Host der Verbindung – so benennen ihn die Netzwerksuche ohne erkanntes Modell und das manuelle
Hinzufügen), schlägt der Assistent `PrinterSetupPlanning.suggestedName` vor („Zebra ZD421t“, sonst
„Zebra-Drucker“) statt „10.62.13.19“; die Installation übernimmt den Namen dann auch in LabelWerk.
„Auch als macOS-Drucker installieren“ (`PrinterInstallRequest(saved:)`) benennt die Warteschlange in
diesem Fall nach dem Modell.

### Übernahme von macOS-Warteschlangen

Wer einen Zebra-Drucker unter „Systemeinstellungen › Drucker & Scanner“ per IP-Adresse hinzufügt,
erhält eine Warteschlange wie „10.62.13.19“ mit Apples AirPrint- bzw. einem allgemeinen Treiber –
ohne benannte Etikettengröße, `lwLabelWidth`/`lwLabelHeight` und Schritt F (§8). Führt sie zum Gerät
eines in LabelWerk eingerichteten Druckers, stellt die App sie automatisch und ohne Rückfrage auf den
LabelWerk-Treiber um. Warteschlangen anderer Geräte ändert LabelWerk nie (diese Regel ersetzt das
frühere „fremde Warteschlangen nie ändern“).

**Entscheidung** (`QueueAdoption.decide` in LabelWerkCore, unter Linux getestet) aus Name, Geräte-URI
(`lpstat -v`), `printer-make-and-model`, „hat LabelWerk-PPD“ (`*lwModel`, `DriverQueueClassifier`) und
den Netzwerkdruckern der App (`RegisteredPrinter`: Kennung, Host, Rohdatenport):
* Nur Netzwerk-URIs `socket`, `labelwerk`, `ipp`, `ipps`, `lpd`, `http`, `https`; `usb://`, `dnssd://` (nennt nur
  den Bonjour-Dienstnamen), `file:` und Backend-Hüllen wie `beh:/…` → `ignore`. Leerer Name → `ignore`.
* Nur URIs, die das **Gerät selbst** nennen (`QueueAdoption.deviceEndpoint`), sonst `ignore`: kein
  Loopback-Host (`localhost`, `*.localhost`, `127.0.0.0/8`, `::1`, `::ffff:127.x.x.x` – Tunnel, Proxy
  oder lokaler Druckserver); `socket://` mit jedem Pfad; `ipp`/`ipps`/`http`/`https` nur mit dem
  IPP-Endpunkt eines Druckers als Pfad (ohne Abfrage, ohne Groß-/Kleinschreibung: leer, `/`, `/ipp`
  oder `/ipp/…` wie `/ipp/print`); `lpd://` nur mit der Standardwarteschlange (Pfad leer bzw. `/`, so
  legt „Drucker & Scanner“ ohne Warteschlangenangabe an). Freigaben eines CUPS-, macOS- oder
  Windows-Druckservers (`ipp://server/printers/<name>`, `…/classes/<name>`,
  `http://server:631/printers/<name>/.printer`), benannte LPD-Warteschlangen (`lpd://box/PORT2` eines
  Druckservers mit mehreren Anschlüssen) und alle übrigen Pfade gehören zu anderen Geräten – sonst
  stellte ein über einen Druckserver erreichter Drucker alle Warteschlangen dieses Servers um.
* Host gleich ohne Groß-/Kleinschreibung, ohne Benutzerangabe, Port, Pfad und Abfrage, ohne eckige
  Klammern (IPv6; Zone `%25` dekodiert) und abschließende Punkte (`ZD421.local.`). Hostnamen werden
  nicht aufgelöst: Ein per Hostname eingerichteter Drucker passt nicht zu einer URI mit seiner
  IP-Adresse und umgekehrt.
* `socket://` (ebenso `labelwerk://`, das Backend auf demselben Rohdatenport, §10) nennt mit dem Port das
  Gerät (Druckserver mit mehreren Anschlüssen): Der Port muss dem
  des Druckers entsprechen (ohne Angabe 9100). Bei den übrigen Protokollen bezeichnet der Port nur den
  Dienst.
* Drucker der App: TCP-Verbindungen mit Host und Port; Verbindungen über eine macOS-Warteschlange
  (`cupsQueue`) mit Host und Port aus deren Geräte-URI (`QueueAdoption.registeredPrinter(id:queueDeviceURI:)`,
  `socket://` mit Port, sonst 9100) – nur wenn diese URI nach derselben Regel das Gerät selbst nennt
  (eine Warteschlange über einen Druckserver wie `ipp://server/printers/Zebra` liefert keinen Drucker:
  der Host ist der Server); USB, Bluetooth und der Demo-Drucker nie. Passen mehrere, gilt der
  erste in der Reihenfolge der Seitenleiste.
* LabelWerk-Treiber (oder „LabelWerk“ in `printer-make-and-model`) → `labelWerk` (nichts zu tun);
  sonst `adopt` mit der Geräte-URI `socket://<host>:<port>` des Druckers (`QueueAdoption.socketURI`,
  IPv6 in eckigen Klammern) – eine passende `socket://`- bzw. `labelwerk://`-URI bleibt unverändert; beim
  Umstellen wird daraus `labelwerk://`, wenn „Bei Papier- oder Farbbandende anhalten und fortsetzen“ an ist
  (§10 „Backend labelwerk“). Den Rohdatenport, über
  den auch LabelWerk selbst druckt, bietet jeder Zebra-Netzwerkdrucker.

**Umstellen** (`CUPSService.adoptQueue`, ein Aufruf):
`lpadmin -p <queue> -v <uri> -P <PPD> -D <Beschreibung>` + alle Argumente von `QueueDefaults.plan`
(mit `-R` veralteter Standards) – dieselbe Modell-PPD bzw. ergänzte Kopie mit der Etikettengröße als
benannter Standardgröße wie bei `installQueue`, `lwLabelWidth`/`lwLabelHeight`, `lwFitToLabel`
(Standard `Auto`) und alle übrigen gespeicherten Einstellungen des Druckers. Name, Standort, Freigabe und
Zustand der Warteschlange bleiben. Beschreibung (`printer-info`, so heißt sie im Druckdialog;
`QueueAdoption.queueDescription`): der Name des Druckers in LabelWerk – ist der nur eine Adresse, der
Modellname („Zebra ZD421t“); hat der Drucker schon eine andere vorhandene Warteschlange (deren
Beschreibung ebenso lautet), mit dem Warteschlangennamen in Klammern („Zebra ZD421t (10.62.13.19)“).
Danach muss die Warteschlange den LabelWerk-Treiber haben (sonst `notLabelWerkQueue`); abweichende
Optionen gleicht der nächste Abgleich nach.

**Merken:** Ohne (noch vorhandene) verknüpfte Warteschlange wird die übernommene `cupsQueueName` des
Druckers, sonst kommt sie zu `SavedPrinter.adoptedQueueNames` (tolerant dekodiert, Standard leer).
`QueueSyncService` hält beide auf dem Stand der Einstellungen (Fingerabdruck über alle Warteschlangen
des Druckers).

**Wann** (`QueueSyncService`): einmal 2 s nach dem Start (vor dem Abgleich), bei jedem Aktivieren der
App (`NSApplication.didBecomeActiveNotification`, nach 1 s zusammengefasst), wenn ein Drucker hinzukommt
oder seine Verbindung ändert (Beobachtung von `AppModel.sessions`, nur bei geänderten Netzwerk- bzw.
Warteschlangenverbindungen) und bei „OK“/„Übernehmen“ in „Druckeinstellungen“, wenn eine Warteschlange
des Druckers noch einen fremden Treiber hat. Eine Prüfung liest `lpstat -v` und `lpoptions -p`
(`CUPSService.queues`); `lpadmin` läuft nur für umzustellende Warteschlangen, nie zwei automatische
Prüfungen gleichzeitig. Alle `lpadmin`-Aufrufe laufen nacheinander, und `CUPSService.adoptQueue` liest
die Warteschlange unmittelbar davor erneut: Hat eine gleichzeitige Prüfung („OK“/„Übernehmen“,
„Erneut versuchen“ neben der beim Aktivieren) sie schon umgestellt, folgen weder ein zweites `lpadmin`
noch ein zweiter Hinweis. Automatisch ohne Passwortabfrage; Erfolg → **ein** Hinweis „macOS-Drucker „10.62.13.19“
nutzt jetzt den LabelWerk-Treiber.“ (bei mehreren einer für alle), Fehler → ein Hinweis mit „Erneut
versuchen“ (dann mit Passwortabfrage). Eine fehlgeschlagene Übernahme versucht die App erst wieder,
wenn sich Geräte-URI, Treiber oder Soll-Zustand ändern, oder nach einem Neustart.

macOS wählt beim Hinzufügen per USB bzw. per IP mit LPD/„HP Jetdirect – Socket“ selbst die
LabelWerk-PPD, wenn deren `*1284DeviceID` zur Gerätekennung passt (`Driver/ppd/README.md`
„Gerätezuordnung“); die Übernahme fängt die übrigen Fälle (AirPrint/IPP, allgemeiner Treiber) ab.

### Etikettentypen

Wer verschiedene Etiketten auf einem Drucker verwendet (z. B. Versandetiketten und Brillenetiketten),
legt unter „Druckeinstellungen › Etikettentypen“ je Etikett einen **Etikettentyp** an. Jeder Typ ist in
macOS ein eigener Drucker – „Zebra ZD421t – Brillenetikett“ –; im Druckdialog wählt man nur diesen Drucker,
Format und Einstellungen kommen aus LabelWerk.

**Modell** (`LabelType`, `LabelTypeOverrides` in LabelWerkCore, unter Linux getestet;
`SavedPrinter.labelTypes`, tolerant dekodiert, Standard leer):
* `id`, `name`, `stockID` (Format aus Katalog oder eigenen Formaten), `overrides`, `queueName` (Name der
  von LabelWerk angelegten Warteschlange, `nil` bis zum ersten Abgleich). Pflicht beim Dekodieren sind nur
  `id` und `stockID`; ein ungültiger Typ fällt aus der Liste, ein ungültiger Wert in `overrides` gilt als
  „wie Drucker“.
* `LabelTypeOverrides`: `rotation`, `darkness`, `speed`, `mediaTracking`, `mediaType`, `printMode`,
  `labelTop`, `labelLeft`, `tearOffAdjust`, `mirror`, `negative`, `fitToLabel` – je `nil` = „wie Drucker“
  (Typen wie in `PrintSettings`). `applied(to:)` setzt die gesetzten Werte und begrenzt (`clamped()`);
  eine Drehung setzt `rotate180` zurück.
* **Wirksame Einstellungen** (`LabelType.settings(printerSettings:printerStock:stock:)`, in der App
  `PrinterSession.effectiveSettings(for:)`): Einstellungen des Druckers → hat der Typ ein anderes Format,
  folgen Medientyp (`tracking`) und – falls das Format eines nennt – Druckmodus (`mediaType`) dem Format
  (wie die Wahl einer Vorlage; „Druckerwert“ bleibt, wenn beide Formate denselben Wert haben) → Abweichungen
  des Typs → `lwLabelWidth`/`lwLabelHeight` aus dem Format (Endlosmaterial ohne Länge).
  `effectiveSettings(for: nil)` sind die gespeicherten Einstellungen des Druckers mit der Größe seines
  Formats. Dieselben Werte gelten für die Warteschlange des Typs und für Drucke aus LabelWerk
  („Mit LabelWerk drucken“): `PrinterSession.stock(for:)` (gelöschtes Format → Format des Druckers),
  `queueName(for:)`.

**Warteschlange je Typ** (`QueueSyncService`, `CUPSService.ensureLabelTypeQueue`):
* **Name** (`LabelTypeQueueNaming.queueName`): `<Warteschlange des Druckers>_<Kürzel>`, z. B.
  `Zebra_ZD421t_Brillenetikett`. Ohne verknüpfte Warteschlange bzw. wenn sie nur eine Adresse ist
  („10.62.13.19“), dient der bereinigte Drucker- bzw. Modellname. Kürzel: Umlaute als `ae oe ue ss`, Akzente
  entfernt, nur `A–Z a–z 0–9 - .`, alles andere `_` (zusammengefasst, nicht am Rand); leer → `Etikettentyp`.
  Höchstens 127 Bytes (zuerst wird das Kürzel bis auf 8 Zeichen gekürzt, dann der Druckerteil), eindeutig
  ohne Groß-/Kleinschreibung gegenüber allen Warteschlangen und allen Typen (`_2`, `_3` …). Vergeben wird
  er beim ersten Anlegen und im Typ gemerkt; Umbenennen ändert nur die Beschreibung.
* **Beschreibung** (`printer-info`, `-D`; `LabelTypeQueueNaming.description`): „<Drucker> – <Typ>“ mit dem
  Namen des Druckers in LabelWerk, bei einem Adressnamen dem Modellnamen.
* **Anlegen** (fehlt sie): `lpadmin -p <name> -E -v <uri> -P <PPD> -o printer-is-shared=false -D … [-L …]`
  + alle Argumente von `QueueDefaults.plan` (ohne `-R`): Modell-PPD für Modell/Auflösung/Sprache des
  Druckers bzw. die ergänzte Kopie mit dem Format des Typs als benannter Standardgröße (`QueuePPD`),
  `lwLabelWidth`/`lwLabelHeight`, `lwFitToLabel` und alle Einstellungen mit den Abweichungen. Geräte-URI:
  die der Warteschlange des Druckers (verknüpfte, Verbindung über eine Warteschlange, übernommene – laut
  `lpstat -v`), sonst die der Verbindung (`labelwerk://host:port` bzw. `socket://host:port`, USB-URI) –
  `socket://` ↔ `labelwerk://` nach der Einstellung des Druckers (§10); Bluetooth und der Demo-Drucker
  erhalten keine.
* **Abgleich** (besteht sie, mit LabelWerk-Treiber): `CUPSService.apply` (Optionen, PPD wie oben, mit der
  Soll-Geräte-URI `deviceURI:` im selben `lpadmin`-Aufruf `-v …`), danach `lpadmin -p <name> -D …`, falls die
  Beschreibung (`printer-info` laut `lpoptions -p`) abweicht. Eine Warteschlange dieses Namens mit fremdem Treiber bleibt unverändert
  (`notLabelWerkQueue`).
* **Wann:** wie die Warteschlange des Druckers – 1,5 s nach jeder Änderung (der Fingerabdruck enthält je
  Typ Kennung, Beschreibung und Soll-Zustand sowie die Verbindung des Druckers; der vergebene Name zählt
  nicht), 2 s nach dem Start, bei „OK“/„Übernehmen“ –, dazu sofort beim Sichern eines Typs (mit
  Passwortabfrage, falls nötig) und beim Aktivieren der App für Typen, deren Warteschlange bestand und
  inzwischen fehlt. Anders als die Warteschlange des Druckers wird eine fehlende neu angelegt: Ein
  Etikettentyp *ist* ein macOS-Drucker – entfernen heißt, den Typ zu löschen. Namensvergabe, Anlegen und
  Merken des Namens laufen als ein Schritt in der Reihe aller `lpadmin`-Aufrufe (kein doppeltes Anlegen
  bei gleichzeitigen Abgleichen); ein während des Anlegens gelöschter Typ verliert die neue Warteschlange
  sofort wieder.
* **Entfernen:** Typ löschen bzw. Drucker aus LabelWerk entfernen → `lpadmin -x <queueName>`, nur für den
  gemerkten Namen und nur mit LabelWerk-Treiber. Andere Warteschlangen ändert die Funktion nie (für die
  Warteschlange des Druckers gelten weiter die Regeln oben und „Übernahme von macOS-Warteschlangen“).
  Umgekehrt schlagen Installationsassistent und „Auch als macOS-Drucker installieren“ die Warteschlange
  eines Typs nie als Warteschlange des Druckers vor (`PrinterInstallService.existingQueues(excluding:)` mit
  `AppModel.labelTypeQueueNames`), obwohl sie zum selben Gerät führt.
* **Zustand** je Typ (`QueueSyncService.labelTypeStatus`): wird geprüft, wird eingerichtet, bereit (Name),
  Fehler (Meldung, „Erneut versuchen“), nicht verfügbar (Grund: kein Treiber, keine passende Verbindung).
  Neu eingerichtete macOS-Drucker meldet ein Hinweis („macOS-Drucker „Zebra ZD421t – Brillenetikett“ ist
  eingerichtet.“), Fehler einer mit „Erneut versuchen“.

Ein eigenes Format, das ein Typ verwendet, gilt als geteilt (`LabelStockLibrary.customStockID` ändert es
nicht für einen anderen Drucker); wird es gelöscht, übernimmt der Typ das Format seines Druckers.

## 10. Treiber & Installation (macOS)

| Ziel | Inhalt |
|---|---|
| `/Library/Printers/LabelWerk/Filter/rastertolabelwerk` | CUPS-Filter (Universal, root:wheel 0755) |
| `/Library/Printers/LabelWerk/Filter/commandtolabelwerk` | CUPS-Befehlsfilter (Selbsttest, Reinigen, Kalibrieren) |
| `/Library/Printers/LabelWerk/Icons/LabelWerk.icns` | Druckersymbol |
| `/Library/Printers/LabelWerk/VERSION` | Treiberversion |
| `/Library/Printers/PPDs/Contents/Resources/LabelWerk-<model>-<dpi>dpi.ppd.gz` | PPD je Modell & Auflösung |
| `/usr/libexec/cups/backend/labelwerk` | CUPS-Backend `labelwerk://` (Universal, root:wheel 0755) – Druck geht nach Papier- oder Farbbandende weiter |
| `/Applications/LabelWerk.app` | App (Druckerdienstprogramm via `*APPrinterUtilityPath`) |

PPD-Eckdaten: `*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/LabelWerk/Filter/rastertolabelwerk"`,
`*cupsFilter: "application/vnd.cups-command 0 /Library/Printers/LabelWerk/Filter/commandtolabelwerk"`,
`*cupsCommands: "Clean PrintSelfTestPage ReportLevels AutoConfigure Calibrate"`,
`*ColorDevice: False`, `*cupsColorSpace` 8-Bit Graustufen (`*ColorModel Gray: "<</cupsColorSpace 18/cupsBitsPerColor 8/cupsColorOrder 0/cupsCompression 0>>setpagedevice"`),
`*cupsManualCopies: False` (Filter erzeugt `^PQ`), `*1284DeviceID` aus `ieee1284`,
`*APPrinterIconPath`, `*APPrinterUtilityPath: "/Applications/LabelWerk.app"`,
`*Manufacturer: "Zebra"`, `*NickName: "Zebra <Modell> (<dpi> dpi) – LabelWerk"`.

Der Filter verarbeitet alle Rasterformate robust (1/8/16 Bit, W/SW/K/RGB → Luminanz) und dithert selbst.

### Backend `labelwerk` (Druck geht nach Papier- oder Farbbandende weiter)

Mit dem CUPS-Backend `socket` ist ein Auftrag erledigt, sobald die Daten beim Drucker sind. Gehen dann
Etiketten oder Farbband aus, weiß macOS nichts davon: Was im Drucker lag, druckt er nach dem Einlegen
(mit `^JZN` ohne das unterbrochene Etikett) – oder gar nicht, wenn er zum Einlegen aus- und
eingeschaltet wurde; man muss nachzählen und den Rest neu drucken. Das Backend `labelwerk` verhält sich
wie ein normaler Drucker: Der Auftrag bleibt in der macOS-Warteschlange, bis jedes Etikett gedruckt ist,
die Warteschlange zeigt „Kein Papier“/„Farbband leer“/„Druckkopf offen“, und nach dem Einlegen geht es
genau dort weiter – jedes Etikett genau einmal.

**Quellen:** `Driver/backend/` – `labelwerk.c` (Ein-/Ausgabe, Ablauf), `lwb_core.c/.h` (reine Logik:
Zerlegung, `~HS`, URI; C-Unit-Tests `tests/test_backend.c`), Optionsauswertung aus `Driver/filter`
(`lw_cups`, `lw_options`: Steuerzeichen „Intern“ und Sprache aus `argv[5]` und PPD). `make -C Driver/backend
test` (auch `asan`, `valgrind`, `universal`, `install`); `Scripts/build_driver.sh` legt es nach
`usr/libexec/cups/backend/labelwerk` in den Treiberbaum (Universal, signiert), `ci_linux.sh`/`ci_macos.sh`
(`test-driver`, Paketprüfung) testen es.

**Rechte:** root:wheel **0755**. CUPS startet ein Backend, das für „andere“ ausführbar ist, als
unprivilegierten Benutzer (`_lp`); nur 0700 hieße Ausführung als root – unnötig, denn das Backend öffnet
nur eine TCP-Verbindung zum Drucker. Gruppe/andere dürfen nicht schreiben (sonst verweigert cupsd es).
CUPS sucht Backends nur in `ServerBin/backend` (`/usr/libexec/cups/backend`); `lpadmin -v labelwerk://…`
lehnt cupsd ab, solange die Datei fehlt – App und `lwctl` verwenden dann `socket://`.

**Geräte-URI:** `labelwerk://host[:port][?mode=stream]` (Port ohne Angabe 9100, IPv6 in `[ ]`, Zone `%25`).
Ohne Argumente (`lpinfo -v`) meldet es nur `network labelwerk "Unknown" "LabelWerk Zebra network printer …"`
(keine eigene Suche). `argv[0]`/`DEVICE_URI`, `argv[1…5]` wie jedes Backend; ohne `argv[6]` liest es die
Ausgabe des Filters von stdin (1 Kopie, der Filter erzeugt `^PQ`), mit Datei (Rohaufträge `lp -o raw`) druckt
es `argv[4]` Kopien.

**Ablauf (ZPL):**
1. TCP-Verbindung; `<~>HS` – antwortet der Drucker nicht (Zeitlimit 5 s), sendet das Backend wie `socket`
   am Stück (WARNING). Ebenso bei `lwLanguage` EPL/CPCL, `lwResumeOnError=False` in den Auftragsoptionen
   oder `?mode=stream`.
2. Auftragskopf (Rohdaten vor dem ersten Format) senden. Beginnt er mit `<~>JA` („Aufträge vor dem Drucken
   abbrechen“), geht zuerst nur die `~JA`-Zeile hinaus, dann wartet das Backend `lwCancelDelay` (Standard
   1000 ms, aus den Auftragsoptionen bzw. der PPD) – `~JA` löscht die Daten vor sich im Empfangspuffer.
   Dieselbe Teilung gilt beim erneuten Senden nach einem Neustart des Druckers.
   Vor dem ersten druckenden Format, sobald der Drucker bereit ist (also **nach** dem Kopf):
   `<^>XA<^>JZY<^>XZ` (das bei einem Fehler unterbrochene Etikett druckt der Drucker danach erneut) und der
   **Neustart-Merker** `<~>DGR:LWJOB.GRF,1,1,00` – 1 Byte im RAM-Laufwerk `R:`, das beim Aus- und
   Einschalten leer ist. `<^>XA<^>HWR:LWJOB.GRF<^>XZ` prüft einmal, ob der Drucker ihn meldet
   (`lwb_parse_directory`: Eintragszeile `*R:LWJOB.GRF …` in der ersten Dateiliste STX…ETX; andere
   Rahmen wie `~HS`-Antworten zählen nicht). Am Ende löscht `^ID` den Merker.
3. Zerlegung (`lwb_next_segment`) mit den Steuerzeichen des Auftrags (`lwControlChars=Printer` mit
   `lwFormatPrefix`/`lwControlPrefix`/`lwDelimiter`, sonst `^ ~ ,`; Wechsel per `^CC`/`~CC`, `^CT`/`~CT`,
   `^CD`/`~CD` im Datenstrom gelten ab dort): Rohdaten außerhalb von Formaten (Auftragskopf `~JA ~SD ~TA ~JS
   ~JC`, SGD) gehen sofort hinaus und werden für einen Neustart des Druckers gemerkt; Formate `^XA…^XZ`
   (samt Zeilenende) einzeln. Binärdaten von `^GFB` werden übersprungen (kein Fehltreffer auf „^XZ“). Ein
   Format **druckt**, wenn es `^FO ^FT ^FD ^FV ^GF ^GB ^GC ^GD ^GE ^XG ^XF` und kein `^DF` enthält; Menge aus
   `^PQ` (ohne: 1). Nicht druckende Formate (`^XA^ST…^XZ`, `^XA^MF…^XZ`, `^XA^JUS^XZ`) gehen sofort hinaus.
   Das erste Etikett geht los, sobald es vom Filter vollständig da ist (wie bei `socket`); während des
   Wartens liest das Backend ohne zu blockieren weiter (höchstens 64 MB im Speicher). Bis das Auftragsende
   gelesen ist, meldet es `Etikett n`, danach `Etikett n von N`. Eine Druckdatei (`argv[6]`, Kopien) liest
   es vorab ganz.
4. **Takt:** Vor jedem druckenden Format fragt es `~HS` ab (alle 200 ms), bis `formats in receive buffer` = 0,
   `labels remaining in batch` = 0 und kein Fehler – erst dann folgt das Format. So liegt nie mehr als ein
   Format im Drucker. Nach dem Senden zählt „leer“ erst nach zwei Abfragen (der Drucker hat das Format evtl.
   noch nicht gezählt). Am Ende wartet es ebenso, bis das letzte Etikett gedruckt ist.
5. **Fehler:** Papier leer → `STATE: +media-empty-error`, Farbband leer (nur bei Thermotransfer, Feld `q`)
   → `+marker-supply-empty-error`, Druckkopf offen → `+cover-open-error`, Pause → `+other-warning` (nicht
   `paused`: damit hielte cupsd die ganze Warteschlange an), je mit deutscher `INFO:`-Meldung
   („Kein Papier – neue Etikettenrolle einlegen. Der Druck geht danach automatisch weiter.“ …); Abfrage alle
   2 s, nach dem Beheben `STATE: -…`. Bleibt der Drucker nach einem dieser Fehler angehalten, setzt `~PS` ihn
   fort; eine Pause ohne vorherigen Fehler beendet der Benutzer.
6. **Fortschritt:** `INFO: Etikett 37 von 50` (bei `^PQ` > 1 aus `labels remaining`), am Ende
   `INFO: Alle 50 Etiketten gedruckt.` Kein `ATTR: job-impressions-completed` bzw. `PAGE:` – die Seiten
   zählt schon der Filter (`PAGE:`), doppelt gezählt hätte CUPS sonst.
7. **Verbindungsabbruch** (getaktet): neu verbinden (1, 2, 4 … höchstens 30 s, unbegrenzt;
   `STATE: +connecting-to-device`). Antwortet der Drucker nicht auf `~HS` mit den aktuellen Steuerzeichen,
   versucht das Backend die des Auftragsanfangs und `~` – antwortet er so, hat er nach einem Neustart
   wieder seine gespeicherten Zeichen (Wechsel per `^CC`/`~CT` im Auftrag sind weg). Ein gemeldetes
   Teilformat verwirft `~JX`. Dann entscheidet der **Zustand des Druckers**, nicht eine Vermutung, ob er
   neu gestartet wurde:
   * Formate oder Restetiketten im Puffer bzw. ein Teilformat → Puffer behalten;
   * Antwort nur mit den gespeicherten Steuerzeichen → neu gestartet;
   * sonst der Neustart-Merker: Bei Papier leer, Kopf offen oder Pause bearbeitet der Drucker `^HW` (ein
     Format) erst danach – das Backend wartet deshalb mit `STATE`-Meldungen wie beim Drucken, bis er bereit
     ist, und fragt dann `^HW`: vorhanden → behalten, fehlt → neu gestartet; meldet der Drucker den
     Merker gar nicht (Prüfung am Auftragsanfang ohne Treffer) → nicht prüfbar.

   Behalten: nichts erneut senden – was der Drucker inzwischen gedruckt hat (z. B. die Rolle wurde
   eingelegt, während das WLAN weg war), zählt, sobald `~HS` leer meldet. Neu gestartet: Steuerzeichen
   des Auftragsanfangs, Auftragskopf (mit `~JA`-Pause), Steuerzeichen des offenen Formats, `^JZY`, Merker
   und das offene Format mit den **restlichen** Etiketten (`^PQ` = zuletzt gemeldete Restetiketten) –
   ebenso, wenn der Drucker mitten in einer Menge ohne Fehler aus- und eingeschaltet wurde (wird er genau
   zwischen zwei Abfragen ausgeschaltet, kann ein Etikett doppelt kommen, nie eines fehlen). Beim Senden
   abgebrochen und das Format liegt nicht vollständig im Drucker: erneut senden (nach einem Neustart samt
   Kopf). Nicht prüfbar: nichts automatisch wiederholen, `WARNING: … Möglicherweise fehlen bis zu n
   Etikett(en); bitte nachzählen.` und am Ende statt „Alle … gedruckt“ eine WARNING mit der Zahl.
   Nie `CUPS_BACKEND_RETRY` nach dem ersten gesendeten Etikett (CUPS wiederholte sonst den ganzen
   Auftrag); nur bei erschöpften Versuchen vor jedem Senden (Testgrenze `LW_BACKEND_RECONNECT_LIMIT`).

   **Am Stück** (EPL/CPCL, `lwResumeOnError=False`, `?mode=stream`, Drucker ohne `~HS`, Rest nach einem
   Download): Bricht die Verbindung ab, nachdem Auftragsdaten gesendet wurden, endet der Auftrag mit
   `ERROR` und Exitcode 1 wie bei `socket` – was davon ankam, lässt sich nicht feststellen; alles erneut
   zu senden druckte das Angekommene doppelt. Nur ohne gesendete Daten wird neu verbunden.
8. **Abbrechen** (SIGTERM): `STATE`-Meldungen zurücksetzen, `<~>JA` leert den Druckerpuffer (auch einen
   wartenden Auftrag), Ende mit 0.
9. **Downloads** (`~DG ~DY ~DB ~DS ~DT ~DU ~DN`) und Binärdaten außerhalb von `^GFB` (Bytes < 0x09 bzw.
   0x0E…0x1F, z. B. Firmware): ab dort am Stück – nie eine `~HS`-Abfrage mitten in den Daten.

Zeiten für Tests: `LW_BACKEND_POLL_MS`, `LW_BACKEND_ERROR_POLL_MS`, `LW_BACKEND_REPLY_TIMEOUT_MS`,
`LW_BACKEND_STALL_MS` (30 s ohne Antwort → Verbindung neu), `LW_BACKEND_RECONNECT_MS`/`_MAX_MS`/`_LIMIT`,
`LW_BACKEND_CONNECT_TIMEOUT_MS`, `LW_BACKEND_CANCEL_DELAY_MS` (nach `~JX` bzw. dem `~JA` beim Abbruch),
`LW_BACKEND_SNDBUF` (Sendepuffer, für den Abbruch mitten im Senden).

**Tests:** `tests/run_backend_e2e.py` startet das echte Backend gegen einen nachgebildeten Zebra-Drucker
(`tests/fake_zebra.py`: TCP-Server mit `~HS`, Empfangspuffer, Druckzeit je Etikett, `^PQ`, `~JA` (verwirft
auch noch nicht bearbeitete Formate davor), `~PS`, `^JZY/N` – ohne `^JZY` geht das unterbrochene Etikett
verloren –, nicht druckende Formate erst nach einer Bearbeitungszeit und nicht bei Fehler/Pause, `~DG`/
`^HW`/`^ID` mit RAM-Laufwerk `R:`, Papier leer/Farbband leer/Kopf offen/Pause nach N Etiketten, behoben nach
M s, Aus- und Einschalten (auch ohne Fehler), nur die Netzverbindung weg, langsamer Empfang, stumm, ohne
`^HW`, anfangs nicht erreichbar) und prüft:
jedes Etikett genau einmal (auch `^PQ` > 1), nie mehr als ein druckendes Format im Drucker, Ende erst nach
dem letzten Etikett, `STATE` gesetzt und zurückgesetzt, Fortsetzen nach allen vier Fehlern, `~PS` nur nach
einem Fehler, Neustart des Druckers, Abbruch mit `~JA` (auch im Fehlerzustand), Senden am Stück (keine
`~HS`-Antwort, EPL, `lwResumeOnError=False`, `?mode=stream` – als Gegenprobe mit verlorenem Etikett),
eigene Steuerzeichen, Kopien aus einer Datei, Downloads, Versuchsgrenze (`CUPS_BACKEND_RETRY`); dazu
Verbindungsabbruch bei „Papier leer“ mit Einlegen während der Unterbrechung (nichts doppelt, auch `^PQ`),
Neustart mitten in einer Menge ohne Fehler (Rest erneut), Neustart nach `^CC`/`~CT` im Auftrag, Drucker ohne
`^HW` (WARNING statt Wiederholung), `~JA` im Kopf (Pause `lwCancelDelay`, `^JZY` danach und wirksam),
Abbruch mitten im Senden am Stück (Fehler, keine zweite Verbindung) und einen langsamen Filter (erstes
Etikett vor dem Auftragsende gedruckt, „Etikett 1“, später „Etikett 4 von 4“).

**Warteschlangen:** LabelWerk-Warteschlangen eines Netzwerkdruckers (Assistent, „Treiber“, übernommene,
Etikettentypen, `lwctl install`) erhalten `labelwerk://host:port`, sofern „Bei Papier- oder Farbbandende
anhalten und fortsetzen“ an ist (`PrintSettings.resumeAfterError`, Standard an, nur Treiber – keine
CUPS-Option, kein Befehl) und das Backend installiert ist; sonst `socket://host:port`. `QueueDeviceURI`
(LabelWerkCore, unter Linux getestet): `networkURI`, `target(for:resume:)` stellt nur `socket://` ↔
`labelwerk://` um (Pfad/Optionen der socket-URI entfallen), `arguments(…)` liefert dazu den
Warteschlangen-Standard `lwResumeOnError-default=False` bei „aus“ (bzw. `-R lwResumeOnError-default` bei
„an“). `CUPSService.apply` gleicht Geräte-URI und Markierung mit ab (auch ohne andere Abweichung),
`adoptQueue`/`ensureLabelTypeQueue`/`installQueue` setzen sie beim Anlegen; `QueueSyncService` gleicht
nach jeder Änderung, beim Start und nach einer Treiberinstallation aus der App
(`CUPSService.driverDidChangeNotification`) ab. `lwctl install`: `--no-resume`/`--resume` (ohne Angabe:
an bzw. die Wahl der vorhandenen Warteschlange). Das **postinstall** des Pakets stellt bei einem Update
LabelWerk-Warteschlangen (PPD mit `*lwModel`) mit `socket://` auf `labelwerk://` um – außer mit
`lwResumeOnError=False`; die Deinstallation entfernt das Backend. `socket://` und `labelwerk://` mit
gleichem Host und Port gelten überall als dasselbe Gerät (`QueueAdoption.rawSchemes`, Netzwerksuche,
Assistent, `lwctl install`). USB-Warteschlangen behalten `usb://` – das Backend spricht nur den
Rohdatenport; dort gilt weiter das Verhalten des CUPS-Backends `usb` (Fortsetzen nur bei Druck aus der App).

**macOS-Hinweis:** `/usr/libexec/cups` ist von SIP ausgenommen, damit Treiber Backends installieren können
(z. B. Gutenprint); `ci_macos.sh` prüft das installierte Backend im Paket (Universal, signiert, 0755).

## 11. App-Architektur (Kurzfassung, Details in `docs/APP_ARCHITECTURE.md`)

* `@Observable` Modelle (Observation-Framework, macOS 14): `AppModel` (global), `PrinterSession` (je Drucker).
* Navigation: `NavigationSplitView` – Seitenleiste mit Druckern und Bereichen
  (Übersicht, Einstellungen, Etiketten, Werkzeuge, Terminal, Designer, Dateien & Schriften,
  Netzwerk, Firmware, Verlauf, Treiber).
* Menüleisten-Extra mit Live-Status, Benachrichtigungen bei Fehlern.
* Druckersuche im Netzwerk: `NetworkDiscoveryService` (`Services/`, `model.networkDiscovery`) sucht
  automatisch (Start + alle 10 Minuten) und füllt die Seitenleiste „Im Netzwerk“; Editor „Netze …“
  in `Features/Discovery/DiscoveryNetworksSheet.swift` (§7a „Druckersuche im Netzwerk“).
* Update-Dienst: `UpdateController` (`Services/`, Oberfläche in `Features/Updates/`) auf dem Kern
  `LabelWerkKit/Update` – sucht, lädt und installiert Releases des Repositorys aus
  `LWUpdateRepository` (Info.plist); Ablauf in `docs/DEVELOPMENT.md` („Release und Updates“).
* Etikettendruck („Mit LabelWerk drucken“, `Features/LabelPrint/`): eigenes Fenster mit genauer Vorschau.
  Der PDF-Dienst `~/Library/PDF Services/Mit LabelWerk drucken` (POSIX-sh, `PDFServiceInstaller`, beim
  Start still angelegt bzw. aktualisiert; `$1` Titel, `$2` CUPS-Optionen, `$3` vorübergehende PDF) kopiert
  die PDF des Druckdialogs nach `~/Library/Caches/<Bundle-ID>/Incoming` und öffnet sie mit `open -b`;
  `CFBundleDocumentTypes` (PDF, Bilder, `LSHandlerRank` „Alternate“). Vorschau = Druck: jede Seite in
  Druckerauflösung → `JobEncoder.fitted(_:pageSize:reference:)` (Schritt F mit Referenz des Auftrags) →
  `dithered` → angezeigt nach `preprocess` (+ `^LS`/`^LT`/`^PM`/`^PO` des Druckers), gedruckt mit
  `encode(pages:)` – byte-gleich zu `encode(images:pageSizes:)`. Gesendet direkt über die Verbindung des
  Druckers, sonst als Rohauftrag (`lp -o raw`) über die Warteschlange des Etikettentyps.
* Persistenz: JSON in `~/Library/Application Support/LabelWerk/`.
* Lokalisierung: `tr("Deutscher Text")` → `Bundle.main` (`en.lproj/Localizable.strings`).

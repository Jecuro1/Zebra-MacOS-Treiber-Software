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
    public struct Plan: Hashable, Sendable { public var width: Int?; public var height: Int? }  // nil = frei
    public static func plan(settings: PrintSettings, pageSize: PageSizePoints?, xDPI: Int, yDPI: Int,
                            imageWidth: Int, imageHeight: Int) -> Plan?   // nil = keine Anpassung
    public static func hundredthsMM(fromPoints points: Double) -> Int?    // ⌊pt·2540/72 + 0,5⌋, nil wenn ungültig
    public static func contentBounds(_ image: GrayImage) -> (x: Int, y: Int, width: Int, height: Int)?
    public static func targetSize(contentWidth: Int, contentHeight: Int, plan: Plan) -> (width: Int, height: Int)
    public static func areaAverage(_ image: GrayImage, x: Int, y: Int, width: Int, height: Int,
                                   toWidth: Int, toHeight: Int) -> GrayImage   // Flächenmittel, nur Ganzzahlen
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

public enum DiscoverySource: String, Codable, Sendable, CaseIterable { case bonjour, usb, network, cups, bluetooth, ble }
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
    /// Liefert gefundene Drucker (dedupliziert nach `id`) und endet nach `timeout`.
    public func discover(sources: Set<DiscoverySource> = Set(DiscoverySource.allCases),
                         timeout: Duration = .seconds(6)) -> AsyncStream<DiscoveredPrinter>
}
public struct NetworkInterfaceInfo: Hashable, Sendable { public var name: String; public var address: String; public var netmask: String }
public enum SubnetScanner {
    public static func localIPv4Interfaces() -> [NetworkInterfaceInfo]   // getifaddrs, ohne Loopback
    public static func hosts(in iface: NetworkInterfaceInfo, limit: Int = 1024) -> [String]
    public static func scan(hosts: [String], port: Int = 9100, timeout: Duration = .milliseconds(400), maxConcurrent: Int = 64) -> AsyncStream<String>
}
public struct CUPSQueueInfo: Hashable, Sendable, Codable { public var name: String; public var deviceURI: String; public var isDefault: Bool; public var makeAndModel: String? }
public enum CUPSQueueLister {
    public static func queues() -> [CUPSQueueInfo]                    // `lpstat -v` (+ `-d`), leer wenn lpstat fehlt
    public static func parseLpstatV(_ text: String) -> [(name: String, uri: String)]   // de/en-Ausgabe
    public static func modelHint(fromDeviceURI uri: String) -> String?  // usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=… → "ZTC ZD421-203dpi ZPL"
}
```

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

macOS-Programme schicken oft die Systempapiergröße (A4/Letter, „Andere 210 × 297 mm“) oder die
Seitengröße des Dokuments statt der Etikettengröße der Warteschlange. Schritt F legt solche Seiten
automatisch auf das Etikett, **bevor** gerastert wird (Graustufen `L`, 0 = schwarz); danach läuft
alles wie gewohnt (Rastern über die volle Breite, Schritte 0–5, Abschneiden auf die Druckbreite …),
als hätte das Programm eine etikettengroße Seite geschickt. Passt die Seitengröße (± 2 mm), bleibt
die Ausgabe byte-gleich zu der ohne Schritt F. Alle Rechnungen sind Ganzzahlrechnungen (64 Bit,
Division mit Abschneiden), bis auf die Umrechnung der Seitengröße (IEEE-754 `double`, genau so).

Eingaben je Seite: Luminanz `L(x, y)` (`w × h` Punkte; Seiten ohne Fläche werden wie bisher ohne
Schritt F übersprungen), Seitengröße `pw × ph` in Punkten (Filter: `cupsPageSize[0/1]`, wenn beide
> 0, sonst `PageSize[0/1]`, wenn beide > 0, sonst unbekannt; Swift `PageSizePoints`, Python
`page_sizes`), Auflösung `xdpi`/`ydpi` (Filter `HWResolution[0/1]`; Swift/Python: die Auflösung des
Auftrags für beide), Einstellungen `lwFitToLabel`, `lwLabelWidth` (`lw`), `lwLabelHeight` (`lh`),
`lwMediaTracking`, wirksame Drehung `R`.

1. **Ziel bestimmen.** Schritt F entfällt, wenn `lwFitToLabel = Off`, `lw = 0` oder die
   Seitengröße unbekannt bzw. ungültig ist (nicht `0 < pw ≤ 100000` und `0 < ph ≤ 100000`).
   Etikettenlänge `le = (lwMediaTracking = Continuous) ? 0 : lh` – 0 heißt **frei** (Endlosmaterial:
   nur die Breite wird angepasst, lange Belege bleiben lang). In Seitenrichtung: `R` = 90/270 →
   `(cw, ch) = (le, lw)` (die Seite liegt quer, Schritt 0 dreht sie später), sonst `(cw, ch) = (lw, le)`.
   Seite in 1/100 mm: `Pw = ⌊pw · 2540 / 72 + 0,5⌋` (genau so in `double`: `floor(pw * 2540.0 / 72.0 + 0.5)`),
   `Ph` ebenso. Schritt F entfällt, wenn keine feste Seite abweicht: weder `cw > 0 ∧ |Pw − cw| > 200`
   noch `ch > 0 ∧ |Ph − ch| > 200`. Etikett in Punkten: `W = (cw · xdpi + 1270) / 2540`,
   `H = (ch · ydpi + 1270) / 2540` (frei: kein Wert). Schritt F entfällt, wenn eine feste Seite
   `< 1` oder `> 32000` Punkte ergibt oder `xdpi`/`ydpi` 0 ist.
2. **Inhalt.** Ein Punkt ist Inhalt ⇔ `L < 250`. `x0`/`x1` = kleinste/größte Spalte, `y0`/`y1` =
   kleinste/größte Zeile mit Inhalt; `bw = x1 − x0 + 1`, `bh = y1 − y0 + 1`. Ohne Inhalt (leere Seite)
   wird das Ergebnis ein weißes Etikett `W × H` (`L = 255`; freie Seite = 1 Punkt) – weiter mit dem
   Rastern.
3. **Zielgröße** `tw × th` (nie vergrößern): beide Seiten fest und `bw ≤ W ∧ bh ≤ H` → `bw × bh`.
   Beide fest, sonst: `W · bh ≤ H · bw` → `tw = W`, `th = max(1, (2 · bh · W + bw) / (2 · bw))`; andernfalls
   `th = H`, `tw = max(1, (2 · bw · H + bh) / (2 · bh))`. Nur `W` fest: `bw ≤ W` → `bw × bh`, sonst
   `tw = W`, `th` wie oben. Nur `H` fest: `bh ≤ H` → `bw × bh`, sonst `th = H`, `tw` wie oben.
4. **Verkleinern (Flächenmittel).** Für jeden Zielpunkt `(X, Y)`:
   `S = Σx Σy ax(X, x) · ay(Y, y) · L(x0 + x, y0 + y)` über `0 ≤ x < bw`, `0 ≤ y < bh` mit
   `ax(X, x) = max(0, min((x + 1) · tw, (X + 1) · bw) − max(x · tw, X · bw))` und
   `ay(Y, y) = max(0, min((y + 1) · th, (Y + 1) · bh) − max(y · th, Y · bh))`;
   Wert `= (S + T / 2) / T` mit `T = bw · bh`. Bei `tw = bw ∧ th = bh` ist das genau die Kopie des
   Ausschnitts (Implementierungen dürfen dann kopieren). Die Summe ist trennbar (erst Zeilen, dann
   Spalten), darf aber erst am Ende einmal gerundet werden.
5. **Einsetzen.** Etikett `CW × CH` mit `CW = W` (frei: `tw`), `CH = H` (frei: `th`), weiß (255);
   das Bild kommt an `ox = (CW − tw) / 2`, `oy = (CH − th) / 2` (waagerecht **und** senkrecht
   mittig). Dieses Bild ersetzt die Seite.

Folgen: Ein Etikett-PDF, das Vorschau bei 100 % auf A4 oder Letter setzt, wird in Originalgröße und
ohne den weißen Rand mittig gedruckt; größerer Inhalt (z. B. eine ganze A4-Seite) wird
seitenverhältnistreu verkleinert; eine leere Seite ergibt ein leeres Etikett (mit
`skipBlankLabels` übersprungen). `lwLabelWidth`/`lwLabelHeight` sind Warteschlangen-Standards aus
dem Etikettenformat (§9); ohne sie (ältere Warteschlangen, `lwctl encode` ohne `--label-size`) und mit
`lwFitToLabel=Off` bleibt alles wie bisher. Der Filter puffert nur in Schritt F eine ganze Seite
(`w · h` Bytes, höchstens 1 GiB); ist sie größer oder fehlt Speicher, druckt er sie mit `WARNING:`
unverändert (die einzige Stelle, an der Filter und `JobEncoder` absichtlich abweichen können).

Entscheidungen (gegenüber dem ersten Entwurf präzisiert): Bei Endlosmaterial
(`lwMediaTracking=Continuous`) bzw. `lwLabelHeight=0` ist die Länge frei – sonst würde ein langer
Beleg auf die Abschnittslänge des Formats geschrumpft. Bei `R` = 90/270 gilt das Etikett quer (wie
`lwctl print` die Seite für eine Drehung quer einpasst). Die Inhaltsschwelle 250 ignoriert
JPEG-/Scanner-Rauschen nahe Weiß; dunklere Punkte gehören zum Inhalt, auch wenn das gewählte
Rasterverfahren sie weiß drucken würde.

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
| `lwFitToLabel` | `Auto` `Off` | „An Etikett anpassen“ (Standard `Auto`; der Wert „Default“ bedeutet `Auto`): Seiten, deren Größe um mehr als 2 mm vom Etikett abweicht (A4/Letter aus dem macOS-Druckdialog), legt der Treiber vor dem Rastern auf das Etikett – zugeschnitten auf den Inhalt, nur verkleinert, mittig (§8 „F“) |
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
Boolesche Werte: `True/False/yes/no/on/off/1/0`.

Zusätzliche PPD-Attribute, die der Filter liest:
`*lwModel: "zd421t"`, `*lwMaxPrintWidthDots: "832"`, `*lwDefaultGapDots: "24"`.

## 10. Treiber & Installation (macOS)

| Ziel | Inhalt |
|---|---|
| `/Library/Printers/LabelWerk/Filter/rastertolabelwerk` | CUPS-Filter (Universal, root:wheel 0755) |
| `/Library/Printers/LabelWerk/Filter/commandtolabelwerk` | CUPS-Befehlsfilter (Selbsttest, Reinigen, Kalibrieren) |
| `/Library/Printers/LabelWerk/Icons/LabelWerk.icns` | Druckersymbol |
| `/Library/Printers/LabelWerk/VERSION` | Treiberversion |
| `/Library/Printers/PPDs/Contents/Resources/LabelWerk-<model>-<dpi>dpi.ppd.gz` | PPD je Modell & Auflösung |
| `/Applications/LabelWerk.app` | App (Druckerdienstprogramm via `*APPrinterUtilityPath`) |

PPD-Eckdaten: `*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/LabelWerk/Filter/rastertolabelwerk"`,
`*cupsFilter: "application/vnd.cups-command 0 /Library/Printers/LabelWerk/Filter/commandtolabelwerk"`,
`*cupsCommands: "Clean PrintSelfTestPage ReportLevels AutoConfigure Calibrate"`,
`*ColorDevice: False`, `*cupsColorSpace` 8-Bit Graustufen (`*ColorModel Gray: "<</cupsColorSpace 18/cupsBitsPerColor 8/cupsColorOrder 0/cupsCompression 0>>setpagedevice"`),
`*cupsManualCopies: False` (Filter erzeugt `^PQ`), `*1284DeviceID` aus `ieee1284`,
`*APPrinterIconPath`, `*APPrinterUtilityPath: "/Applications/LabelWerk.app"`,
`*Manufacturer: "Zebra"`, `*NickName: "Zebra <Modell> (<dpi> dpi) – LabelWerk"`.

Der Filter verarbeitet alle Rasterformate robust (1/8/16 Bit, W/SW/K/RGB → Luminanz) und dithert selbst.

## 11. App-Architektur (Kurzfassung, Details in `docs/APP_ARCHITECTURE.md`)

* `@Observable` Modelle (Observation-Framework, macOS 14): `AppModel` (global), `PrinterSession` (je Drucker).
* Navigation: `NavigationSplitView` – Seitenleiste mit Druckern und Bereichen
  (Übersicht, Einstellungen, Etiketten, Werkzeuge, Terminal, Designer, Dateien & Schriften,
  Netzwerk, Firmware, Verlauf, Treiber).
* Menüleisten-Extra mit Live-Status, Benachrichtigungen bei Fehlern.
* Persistenz: JSON in `~/Library/Application Support/LabelWerk/`.
* Lokalisierung: `tr("Deutscher Text")` → `Bundle.main` (`en.lproj/Localizable.strings`).

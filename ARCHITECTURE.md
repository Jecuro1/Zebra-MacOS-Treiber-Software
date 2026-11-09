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
    static func backfeed(_ b: BackfeedMode) -> ZPLCommand    // ^JS
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
    static func directoryListing(_ pattern: String = "E:*.*") -> String // ^XA^WD…^XZ
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
                stock: LabelStock? = nil, maxPrintWidthDots: Int? = nil)
    public func encode(pages: [MonoBitmap], copies: Int = 1, collate: Bool = true) throws -> Data
    public func encode(images: [GrayImage], copies: Int = 1, collate: Bool = true) throws -> Data // dithert gemäß settings
}
```

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
public enum FileDirectoryParser { static func parse(_ text: String) -> [PrinterFile] }   // ^WD-Ausgabe
```

## 8. Druckauftragsformat (verbindlich für `JobEncoder` **und** C-Filter)

Eingang: Seiten als `MonoBitmap` (1 = schwarz). Breite > `maxPrintWidthDots` → rechts abschneiden.
Reihenfolge der Bitmap-Vorverarbeitung: (1) abschneiden, (2) `negative` → invertieren,
(3) `skipBlankLabels` und Seite leer → Seite überspringen, (4) nur EPL/CPCL: `mirror` → spiegeln,
(5) nur CPCL: `rotate180` → um 180° drehen. ZPL dreht/spiegelt per `^PO`/`^PM`, EPL dreht per `ZB`.
Zeilenende ZPL: jeder Befehl in eigener Zeile, abgeschlossen mit `\n` (LF); Grafikdaten in einer Zeile.

### ZPL

```
{startCommands}\n                     falls nicht leer
~SD{dd}\n                             falls darkness (zweistellig, 0-gefüllt: ~SD08)
~TA{±ddd}\n                           falls tearOffAdjust (printf "%03d": ~TA010, ~TA-10)
~JC\n                                 falls calibrateBeforeJob
— je Etikett —
^XA\n
^MM{T|P|C|D|R|A|K}\n                  falls printMode
^MN{Y|M|N|A}\n                        falls tracking
^MT{D|T}\n                            falls mediaType
^PR{s},{s},{s}\n                      falls speed
^JS{A|B|N|O}\n                        falls backfeed
^PW{breite}\n
^LL{höhe}\n
^LH0,0\n
^LT{top}\n                            falls labelTop
^LS{left}\n                           falls labelLeft
^PO{I|N}\n                            rotate180 ? I : N
^PM{Y|N}\n                            mirror ? Y : N
^FO0,0^GFA,{total},{total},{bpr},{daten}^FS\n
^PQ{n}\n                              bzw. ^PQ{n},{cutEvery},0,Y falls cutEvery > 0
^JUS\n                                nur beim ersten Etikett, falls saveToPrinter
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

### EPL2 (Zeilenende `\n`)

```
{startCommands}\n
— je Etikett —
\nN\n                                  (führendes LF leert evtl. Restdaten)
q{breite}\n
Q{höhe},{lücke}\n                     tracking gap/auto/nil: Lücke = stock.gapDots oder 24; blackMark: Q{höhe},B{lücke}; continuous: Q{höhe},0
S{speed}\n                            falls speed (begrenzt 1…6)
D{density}\n                          falls darkness (round(darkness/2), 0…15)
Z{B|T}\n                              rotate180 ? B : T
O{D}{C|P}\n                           falls mediaType/printMode gesetzt: "O" + (directThermal ? "D" : "") + (cutter ? "C" : peelOff ? "P" : "")
GW0,0,{bpr},{höhe},<binär, Bit 0 = schwarz>\n
P{n}\n                                bzw. P1 bei Sortierung (wie ZPL)
— Ende —
{endCommands}\n
```

### CPCL (Zeilenende `\r\n`)

```
— je Etikett —
! 0 {dpi} {dpi} {höhe} {n}\r\n
PAGE-WIDTH {breite}\r\n
CONTRAST {0…3}\r\n                    falls darkness (darkness*3/30 gerundet)
SPEED {0…5}\r\n                       falls speed (min(speed,5))
CG {bpr} {höhe} 0 0 <binär, 1 = schwarz>\r\n
FORM\r\n                              außer bei continuous
PRINT\r\n
```

## 9. CUPS-Optionen (PPD ↔ Filter ↔ App)

| Option | Werte | Bedeutung |
|---|---|---|
| `lwLanguage` | `ZPL` `EPL` `CPCL` | Ausgabesprache |
| `lwDarkness` | `Default`, `0`…`30` | `~SD` |
| `lwSpeed` | `Default`, `1`…`14` (PPD: bis Modellmaximum) | `^PR` |
| `lwMediaType` | `Default` `DirectThermal` `ThermalTransfer` | `^MT` |
| `lwMediaTracking` | `Default` `Gap` `BlackMark` `Continuous` `Auto` | `^MN` |
| `lwPrintMode` | `Default` `TearOff` `PeelOff` `Cutter` `DelayedCut` `Rewind` `Applicator` `Kiosk` | `^MM` |
| `lwLabelTop` | `Default`, `-120`…`120` (PPD: Schritte von 10) | `^LT` |
| `lwLabelLeft` | `Default`, `-9999`…`9999` (PPD: −200…200, Schritte 10) | `^LS` |
| `lwTearOff` | `Default`, `-120`…`120` (PPD: Schritte von 10) | `~TA` |
| `lwBackfeed` | `Default` `After` `Before` `Normal` `Off` | `^JS` |
| `lwMirror` `lwNegative` `lwRotate180` | `False` `True` | |
| `lwDither` | `Threshold` `Ordered` `Halftone` `FloydSteinberg` `Atkinson` `Stucki` | |
| `lwThreshold` | `1`…`254` (PPD: 64 96 128 160 192) | |
| `lwCompression` | `Z64` `ACS` `Hex` | |
| `lwCutEvery` | `0`…`9999` (PPD: 0 1 2 5 10 25 50 100) | |
| `lwCalibrate` `lwSaveSettings` `lwSkipBlank` | `False` `True` | |
| `lwStartCmd` `lwEndCmd` | Base64url (UTF-8, ohne Padding) | Rohbefehle |

Vorrang im Filter: Wert aus `argv[5]` (Job-/Warteschlangen-Optionen) **vor** markierter PPD-Auswahl
**vor** PPD-Default. Ganzzahlen außerhalb der PPD-Auswahl sind erlaubt (die App setzt beliebige
Werte per `lpadmin -p <queue> -o lwLabelTop=37`). Boolesche Werte: `True/False/yes/no/on/off/1/0`.

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

## 11. App-Architektur (Kurzfassung, Details in `Sources/LabelWerkApp/README.md`)

* `@Observable` Modelle (Observation-Framework, macOS 14): `AppModel` (global), `PrinterSession` (je Drucker).
* Navigation: `NavigationSplitView` – Seitenleiste mit Druckern und Bereichen
  (Übersicht, Einstellungen, Etiketten, Werkzeuge, Terminal, Designer, Dateien & Schriften,
  Netzwerk, Firmware, Verlauf, Treiber).
* Menüleisten-Extra mit Live-Status, Benachrichtigungen bei Fehlern.
* Persistenz: JSON in `~/Library/Application Support/LabelWerk/`.
* Lokalisierung: `tr("Deutscher Text")` → `Bundle.main` (`en.lproj/Localizable.strings`).

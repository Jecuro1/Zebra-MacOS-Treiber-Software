// LabelWerkImaging – Bildverarbeitung und Grafikkodierung für Zebra-Etikettendrucker.
//
// Verarbeitungskette eines Druckauftrags (identisch zum CUPS-Filter `rastertolabelwerk`):
//
//   PNG/PNM/Renderer ──► GrayImage (8 Bit Luminanz, 0 = schwarz)
//        │  scaled / rotated / adjusted …
//        ▼
//   Ditherer (ARCHITECTURE.md §4.1, bitgenau) ──► MonoBitmap (1 Bit, 1 = schwarz, MSB zuerst)
//        │
//        ▼
//   JobEncoder (§8) ──► ZPL (^GFA Hex/ACS/Z64) · EPL2 (GW) · CPCL (CG)
//
// Bausteine:
// * `GrayImage`, `MonoBitmap`, `QuarterTurn`, `ImageAlignment` – Bildtypen und Geometrie.
// * `Ditherer` – Schwelle, Bayer, Halbton, Floyd–Steinberg, Atkinson, Stucki.
// * `CRC16`, `Deflate`, `Z64`, `ACS` – Prüfsummen und Kompressionsverfahren.
// * `ZPLGraphicEncoder`, `EPLGraphicEncoder`, `CPCLGraphicEncoder` – Grafikbefehle.
// * `PNGCodec`, `PNMCodec` – Bildformate ohne Fremdbibliotheken (nur System-zlib).
// * `JobEncoder` – komplette, byte-genaue Druckaufträge.
// * `ImagingError` – deutschsprachige Fehlermeldungen aller Bausteine.
//
// Alle öffentlichen Typen sind Werttypen und `Sendable`; das Modul nutzt ausschließlich
// Foundation und zlib und baut auf macOS wie Linux.

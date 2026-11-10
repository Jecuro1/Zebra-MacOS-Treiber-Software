// LabelWerkRender – ZPL-II-Interpretation und Software-Rasterung.
//
// Verarbeitungskette:
//
//   ZPL-Text ──► ZPLTokenizer ──► [ZPLToken]
//                                    │
//                                    ▼
//                             ZPLInterpreter ──► LabelDocument (RenderedLabel je Format,
//                                    │            Displayliste aus LabelElement, Hinweise)
//                                    ▼
//                           SoftwareRasterizer ──► MonoBitmap (wie gedruckt, inkl. ^PO/^PM)
//
// Bausteine:
// * `ZPLTokenizer` / `ZPLToken` – Befehlszerlegung mit ^CC/^CT/^CD, Felddaten, Binärnutzlasten.
// * `ZPLInterpreter` – Formatzustand, Felder, Schriften (0, A–H, P–V, ^A@, ^CW), Feldblöcke,
//   Barcodes (LabelWerkBarcode), Grafiken (^GB/^GC/^GE/^GD/^GF/~DG/~DY/^XG/^IM), gespeicherte
//   Formate (^DF/^XF/^FN), Serialisierung (^SN/^SF), Uhrzeitfelder (^FC).
// * `LabelElement` & Co. – öffentliche Displayliste für Vorschau (App), Designer und Tests.
// * `SoftwareRasterizer` – pixelgenaue Rasterung mit eingebetteten Bitmap-Schriften
//   (aus DejaVu Sans/Sans Bold/Sans Mono, erzeugt von `.fontgen/generate_font.py`; das
//   Verzeichnis beginnt mit einem Punkt, damit SwiftPM die Python-Datei nicht als
//   unbehandelte Zieldatei meldet).
// * `ZPLCommandReference` – deutschsprachige Befehlsreferenz für Terminal und Editor.
//
// Das Modul nutzt nur Foundation sowie LabelWerkCore, LabelWerkImaging und LabelWerkBarcode
// und baut auf macOS wie Linux. Alle öffentlichen Typen sind Werttypen und `Sendable`.

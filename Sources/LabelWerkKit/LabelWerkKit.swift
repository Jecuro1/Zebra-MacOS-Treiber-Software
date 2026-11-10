import Foundation

/// Allgemeine Angaben zu LabelWerkKit.
///
/// LabelWerkKit bündelt die Kernmodule (siehe `Exports.swift`) und ergänzt sie um
/// * ``PrinterClient`` – die High-Level-Schnittstelle zu einem Drucker (Status, Identität,
///   SGD, Druck, Dateien, Firmware, Netzwerk),
/// * ``VirtualPrinter`` und ``VirtualPrinterServer`` – einen vollständig simulierten
///   Link-OS-Drucker für Demo-Modus, Tests und `lwctl virtual-printer`,
/// * ``ImageLayout`` – das Einpassen beliebiger Bilder in ein Etikettenformat.
public enum LabelWerkKitInfo {
    /// Produktversion (identisch mit `VERSION` in `Installer/config.env`).
    public static let version = "1.1.0"

    /// Produktname.
    public static let productName = "LabelWerk"
}

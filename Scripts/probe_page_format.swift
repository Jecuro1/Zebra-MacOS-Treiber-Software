// Prüft, welches Papierformat macOS-Programme für eine Druckerwarteschlange vorschlagen.
//
// Aufruf (nur macOS):  swift Scripts/probe_page_format.swift <Warteschlange> [<erwarteter PPD-Name>]
//
// Gibt zwei Werte aus, wie sie Programme (Vorschau, Safari, TextEdit …) erhalten:
//   1. „neu“:       NSPrintInfo() frisch angelegt, wenn die Warteschlange der Standarddrucker ist
//                   (so starten Programme ihren Druckdialog),
//   2. „gewechselt“: PMSessionDefaultPageFormat nach Wahl der Warteschlange im Druckdialog.
// Mit erwartetem PPD-Namen (z. B. w295h216) endet das Skript mit Exitcode 1, wenn einer der beiden
// Werte abweicht – so prüft die macOS-CI, dass der Druckdialog das Etikett der App vorauswählt.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Aufruf: probe_page_format.swift <Warteschlange> [<PPD-Name>]\n".utf8))
    exit(2)
}
let queue = arguments[1]
let expected = arguments.count >= 3 ? arguments[2] : nil

guard let printer = NSPrinter(name: queue) else {
    FileHandle.standardError.write(Data("Warteschlange „\(queue)“ nicht gefunden.\n".utf8))
    exit(2)
}

/// PPD-Papiername und Größe (Punkte) eines Seitenformats.
func describe(_ info: NSPrintInfo) -> (ppdName: String, text: String) {
    var ppdName = "?"
    let format = OpaquePointer(info.pmPageFormat())
    var paper: PMPaper?
    if PMGetPageFormatPaper(format, &paper) == noErr, let paper {
        var name: Unmanaged<CFString>?
        if PMPaperGetPPDPaperName(paper, &name) == noErr, let name {
            ppdName = name.takeUnretainedValue() as String
        }
    }
    let size = info.paperSize
    let mm = String(format: "%.1f × %.1f mm", size.width / 72 * 25.4, size.height / 72 * 25.4)
    return (ppdName, "\(info.paperName?.rawValue ?? "-") [PPD \(ppdName)] \(mm)")
}

// 1. Frisches NSPrintInfo (Standarddrucker = Warteschlange, per lpoptions -d gesetzt).
let fresh = NSPrintInfo()
fresh.printer = printer
let first = describe(fresh)
print("neu:        \(first.text)")

// 2. Seitenformat, das macOS beim Wechsel auf diesen Drucker vorgibt.
let switched = NSPrintInfo()
switched.printer = printer
let session = OpaquePointer(switched.pmPrintSession())
let format = OpaquePointer(switched.pmPageFormat())
var status: OSStatus = -1
if let pm = PMPrinterCreateFromPrinterID(queue as CFString) {
    status = PMSessionSetCurrentPMPrinter(session, pm)
}
if status == noErr {
    status = PMSessionDefaultPageFormat(session, format)
}
switched.updateFromPMPageFormat()
let second = describe(switched)
print("gewechselt: \(second.text) (Status \(status))")

if let expected {
    let ok = first.ppdName == expected && second.ppdName == expected
    print(ok ? "OK: Druckdialog schlägt \(expected) vor." : "FEHLER: erwartet \(expected).")
    exit(ok ? 0 : 1)
}

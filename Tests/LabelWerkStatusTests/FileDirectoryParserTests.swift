import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("^HW / file.dir – Dateilisten")
struct FileDirectoryParserTests {

    @Test("Onboard-Flash E:")
    func parsesFlashListing() throws {
        let files = FileDirectoryParser.parse(Fixtures.directoryFlash)
        #expect(files == [
            PrinterFile(drive: "E:", name: "LOGO.GRF", size: 1234, kind: .graphic),
            PrinterFile(drive: "E:", name: "ARIAL.TTF", size: 45678, kind: .font),
        ])
        #expect(files.map(\.id) == ["E:LOGO.GRF", "E:ARIAL.TTF"])
        let listing = FileDirectoryParser.parseListing(Fixtures.directoryFlash)
        #expect(listing.freeBytes == ["E:": 12_345_678])
        #expect(listing.driveNames == ["E:": "ONBOARD FLASH"])
        #expect(listing.usedBytes(drive: "e") == 46_912)
    }

    @Test("Beispiel aus dem Programming Guide (RAM R:)")
    func parsesGuideListing() {
        let listing = FileDirectoryParser.parseListing(Fixtures.directoryGuideRAM)
        #expect(listing.files.count == 6)
        #expect(listing.files.allSatisfy { $0.drive == "R:" })
        #expect(listing.files.filter { $0.kind == .font }.count == 5)
        #expect(listing.files.last == PrinterFile(drive: "R:", name: "ZEBRA.GRF", size: 8420))
        #expect(listing.freeBytes["R:"] == 794_292)
        #expect(listing.driveNames["R:"] == "RAM")
    }

    @Test("SGD file.dir mit mehreren Laufwerken")
    func parsesSGDListing() {
        let listing = FileDirectoryParser.parseListing(Fixtures.directorySGD)
        #expect(listing.files.map(\.id) == ["E:FORMAT.ZPL", "E:SHIPPING.ZPL", "E:TT0003M_.TTF", "Z:UTF8.DAT", "Z:ARIAL.TTF"])
        #expect(listing.files.map(\.kind) == [.format, .format, .font, .other, .font])
        #expect(listing.files[2].size == 52_345)
        #expect(listing.freeBytes == ["E:": 6_574_080, "Z:": 0])
        #expect(listing.driveNames == ["E:": "ONBOARD FLASH", "Z:": "ROM"])
    }

    @Test("Einträge ohne Laufwerk unter „Directory of“")
    func parsesPlainListing() {
        let listing = FileDirectoryParser.parseListing(Fixtures.directoryPlain)
        #expect(listing.files == [
            PrinterFile(drive: "E:", name: "LOGO.PNG", size: 2048),
            PrinterFile(drive: "E:", name: "INVOICE.ZPL", size: 730),
            PrinterFile(drive: "E:", name: "LABEL.NRD", size: 64),
        ])
        #expect(listing.files.map(\.kind) == [.graphic, .format, .other])
        #expect(listing.freeBytes == ["E:": 123_456])
        #expect(listing.driveNames.isEmpty)
    }

    @Test("Laufwerk als eigenes Token, Größen mit Tausendertrennzeichen, Zusatzspalten")
    func parsesTokenVariants() {
        let text = "* E: LOGO.GRF 1,234\r\n* B:DATA.CSV 99 RW\r\nR:FONT.FNT 4096\r\n"
        #expect(FileDirectoryParser.parse(text) == [
            PrinterFile(drive: "E:", name: "LOGO.GRF", size: 1234),
            PrinterFile(drive: "B:", name: "DATA.CSV", size: 99),
            PrinterFile(drive: "R:", name: "FONT.FNT", size: 4096),
        ])
    }

    @Test("Duplikate werden entfernt")
    func deduplicates() {
        let text = Fixtures.directoryFlash + "\r\n" + Fixtures.directoryFlash
        #expect(FileDirectoryParser.parse(text).count == 2)
    }

    @Test("Abgeschnittene Antwort")
    func truncated() {
        let marked = "- DIR E:*.*\r\n*E:LOGO.GRF       1234\r\n*E:ARIAL.TT"
        #expect(FileDirectoryParser.parse(marked) == [
            PrinterFile(drive: "E:", name: "LOGO.GRF", size: 1234),
            PrinterFile(drive: "E:", name: "ARIAL.TT", size: 0),
        ])
        let unmarked = "E:LOGO.GRF 1234\r\nE:ARIAL.TT"
        #expect(FileDirectoryParser.parse(unmarked).map(\.name) == ["LOGO.GRF"])
    }

    @Test("Muster und Fremdtext sind keine Dateien", arguments: [
        "", "\u{02}\u{03}", "- DIR E:*.*", "*E:*.* 0", "hello world", "E: 1234", "* 1234", "*E:BAD?NAME 1",
        "Some text without drive 123",
    ])
    func noFiles(text: String) {
        #expect(FileDirectoryParser.parse(text).isEmpty)
    }

    @Test("Rohdaten-Variante")
    func parsesData() {
        #expect(FileDirectoryParser.parse(data: TestSupport.data(Fixtures.directoryFlash)).count == 2)
    }

    // MARK: PrinterFile / FileKind

    @Test("Dateiart aus der Endung", arguments: [
        ("ARIAL.TTF", FileKind.font), ("SWISS.TTE", .font), ("NOTO.OTF", .font), ("CJK.TTC", .font),
        ("ZEBRA.FNT", .font), ("logo.grf", .graphic), ("PHOTO.PNG", .graphic), ("ICON.BMP", .graphic),
        ("OLD.PCX", .graphic), ("PIC.IMG", .graphic), ("SHIP.ZPL", .format), ("FORM.WML", .format),
        ("V84.ZHX", .firmware), ("BOOT.HEX", .firmware), ("CERT.NRD", .other), ("UTF8.DAT", .other),
        ("DATA.CSV", .other), ("PROGRAM.BAS", .other), ("NOEXT", .other), (".HIDDEN", .other),
        ("E:LOGO.GRF", .graphic), ("ARCHIVE.TAR.ZPL", .format),
    ])
    func fileKinds(name: String, kind: FileKind) {
        #expect(FileKind(fileName: name) == kind)
    }

    @Test("Endungen mit Punkt und Leerraum")
    func extensionVariants() {
        #expect(FileKind(fileExtension: ".ttf") == .font)
        #expect(FileKind(fileExtension: " GRF ") == .graphic)
        #expect(FileKind(fileExtension: "") == .other)
    }

    @Test("Bezeichnungen und Symbole")
    func kindPresentation() {
        #expect(FileKind.allCases.map(\.displayName) == ["Schrift", "Grafik", "Format", "Firmware", "Sonstige"])
        #expect(Set(FileKind.allCases.map(\.systemImage)).count == FileKind.allCases.count)
        #expect(FileKind.allCases.allSatisfy { PrinterAlertTests.knownSymbols.contains($0.systemImage) })
    }

    @Test("PrinterFile: Pfad, Endung, Normalisierung")
    func printerFileProperties() throws {
        let file = PrinterFile(drive: "e", name: "LOGO.GRF", size: 1234)
        #expect(file.drive == "E:")
        #expect(file.id == "E:LOGO.GRF")
        #expect(file.path == "E:LOGO.GRF")
        #expect(file.fileExtension == "GRF")
        #expect(file.baseName == "LOGO")
        #expect(file.kind == .graphic)
        #expect(PrinterFile(drive: "R:", name: "X", size: -5).size == 0)
        let parsed = try #require(PrinterFile(path: "e:arial.ttf", size: 99))
        #expect(parsed == PrinterFile(drive: "E:", name: "arial.ttf", size: 99))
        #expect(PrinterFile(path: "LOGO.GRF") == nil)
        #expect(PrinterFile(path: "E:") == nil)
        #expect(PrinterFile(path: "EE:LOGO.GRF") == nil)
        #expect(PrinterFile(drive: "E:", name: "README", size: 1).fileExtension == "")
        #expect(PrinterFile(drive: "E:", name: "README", size: 1).baseName == "README")
        // Explizite Art hat Vorrang vor der Endung.
        #expect(PrinterFile(drive: "E:", name: "LOGO.GRF", size: 1, kind: .other).kind == .other)
        // Alias PrinterFile.FileKind
        let alias: PrinterFile.FileKind = .font
        #expect(alias == FileKind.font)
    }
}

import Foundation
import Testing
import LabelWerkImaging
@testable import LabelWerkRender

/// Schreibt Beispieletiketten als PNG, wenn `LABELWERK_RENDER_DUMP` auf ein Verzeichnis zeigt
/// (zur visuellen Kontrolle bei der Entwicklung; ohne Variable passiert nichts).
@Suite("Visuelle Kontrollausgabe")
struct VisualSmokeTests {
    @Test("Beispieletiketten als PNG ablegen (nur mit LABELWERK_RENDER_DUMP)")
    func dumpSamples() throws {
        guard let directory = ProcessInfo.processInfo.environment["LABELWERK_RENDER_DUMP"] else { return }
        for (name, zpl) in Samples.all {
            let document = TestSupport.render(zpl)
            for (index, label) in document.labels.enumerated() {
                let bitmap = SoftwareRasterizer.rasterize(label)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(index).png")
                try PNGCodec.encode(bitmap).write(to: url)
            }
            for warning in document.allWarnings { print("[\(name)] \(warning)") }
        }
    }
}

/// Beispiel-ZPL für Tests und Kontrollausgaben.
enum Samples {
    static let shipping = """
    ^XA
    ^CI28
    ^PW812
    ^LL1218
    ^FX Kopfbereich ^FS
    ^FO30,30^GB752,1158,4,B,2^FS
    ^FO50,50^A0N,48,48^FDLabelWerk Versand GmbH^FS
    ^FO50,105^A0N,28,28^FDMusterstraße 12, 80331 München^FS
    ^FO30,150^GB752,0,3^FS
    ^FO50,175^ADN,36,20^FDAN:^FS
    ^FO50,220^A0N,40,40^FB700,3,8,L,0^FDJürgen Müller\\&Hauptstraße 5\\&10115 Berlin^FS
    ^FO30,380^GB752,0,3^FS
    ^BY3,3,160
    ^FO80,410^BCN,160,Y,N,N^FD>;00345678901234567890^FS
    ^FO30,640^GB752,0,3^FS
    ^FO60,670^BQN,2,6^FDQA,https://labelwerk.example/track/0034567890^FS
    ^FO420,690^A0N,32,32^FDGewicht: 2,5 kg^FS
    ^FO420,740^A0N,32,32^FDPakete: 1/1^FS
    ^FO420,800^GB320,140,140^FS
    ^FO440,830^A0N,80,80^FR^FDEXPRESS^FS
    ^FT60,1150^A0N,30,30^FDSendung 0034567890^FS
    ^FO700,980^A0R,40,40^FDRotiert^FS
    ^PQ1
    ^XZ
    """

    static let fonts = """
    ^XA
    ^FO20,20^AAN,18,10^FDFont A: Hello 123^FS
    ^FO20,50^ABN,22,14^FDFont B: HELLO 123^FS
    ^FO20,90^ADN,36,20^FDFont D: Hello 123^FS
    ^FO20,140^AEN,28,15^FDFont E: OCR-B 123^FS
    ^FO20,180^AFN,26,13^FDFont F: Hello^FS
    ^FO20,220^AGN,60,40^FDFont G^FS
    ^FO20,300^AHN,21,13^FDFONT H OCR-A^FS
    ^FO20,340^A0N,20,20^FDFont 0 small: Äpfel, Öl, Übermut, Straße, 25 €^FS
    ^FO20,380^A0N,60,60^FDFont 0 large: Äöüß€^FS
    ^FO20,460^A0N,120,80^FDGroß 120^FS
    ^FO20,600^A@N,40,40,E:ARIAL.TTF^FDTrueType-Ersatz (A@)^FS
    ^FO20,660^GSN,60,60^FDABCDE^FS
    ^FO20,740^A0B,40,40^FDRotation B^FS
    ^FO100,740^A0I,40,40^FDRotation I^FS
    ^FO500,740^A0R,40,40^FDRotation R^FS
    ^XZ
    """

    static let graphics = """
    ^XA
    ^FO20,20^GB200,100,5^FS
    ^FO240,20^GB200,100,10,B,8^FS
    ^FO460,20^GB200,100,100^FS
    ^FO480,40^GB160,60,20,W^FS
    ^FO20,140^GC120,6^FS
    ^FO160,140^GE200,100,4^FS
    ^FO380,140^GD200,100,6,B,R^FS
    ^FO600,140^GD150,100,6,B,L^FS
    ^FO20,280^GB300,80,80^FS
    ^FO40,290^A0N,60,60^FR^FDREVERSE^FS
    ^FO400,280^BY2^BEN,80,Y,N^FD400638133393^FS
    ^FO20,420^BY2^B3N,N,80,Y,N^FDLABEL-39^FS
    ^FO400,420^BY2^BUN,80,Y,N,Y^FD03600029145^FS
    ^FO20,560^BY3^BXN,6,200^FDLabelWerk Data Matrix^FS
    ^FO260,560^BY2^B7N,6,3,4^FDLabelWerk PDF417 Test 1234567890^FS
    ^FO20,800^BY2^B2N,80,Y,N,N^FD1234567890^FS
    ^FO400,800^BY2^B8N,80,Y,N^FD5512345^FS
    ^FO20,960^BY2^B9N,80,Y,N,Y^FD1230000045^FS
    ^FO400,960^BY2^BKN,N,80,Y,N,A,B^FD123456^FS
    ^XZ
    """

    static let all: [(String, String)] = [("shipping", shipping), ("fonts", fonts), ("graphics", graphics)]
}

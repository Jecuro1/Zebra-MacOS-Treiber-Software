import Foundation

/// Realistische Druckerantworten als Testdaten (eingebettet, da das Paket keine Ressourcen deklariert).
enum Fixtures {
    static let stx = "\u{02}"
    static let etx = "\u{03}"

    /// Rahmt Zeilen wie der Drucker: `STX zeile ETX CR LF`.
    static func framed(_ lines: [String]) -> String {
        lines.map { "\(stx)\($0)\(etx)\r\n" }.joined()
    }

    // MARK: ~HS

    /// Bereiter Drucker, 9600 8N1, Thermotransfer, Abreißen (Aufbau wie im ZPL II Programming Guide).
    static let hostStatusReady = framed([
        "030,0,0,1245,000,0,0,0,000,0,0,0",
        "001,0,0,0,1,2,6,0,00000000,1,000",
        "1234,0",
    ])

    /// Alle Flags gesetzt.
    static let hostStatusAllFlags = framed([
        "030,1,1,0812,003,1,1,1,000,1,1,1",
        "129,0,1,1,1,1,0,1,00000042,1,007",
        "9876,1",
    ])

    /// Drucker druckt einen Auftrag (5 Etiketten übrig, 2 Formate im Puffer).
    static let hostStatusPrinting = framed([
        "030,0,0,1218,002,0,0,0,000,0,0,0",
        "000,0,0,0,0,2,0,0,00000005,1,000",
        "1234,0",
    ])

    /// Mobildrucker (ZQ520 im ZPL-Modus): Spenden, verkürzte zweite Zeile, keine dritte Zeile.
    static let hostStatusMobile = "\(stx)000,0,0,0400,000,0,0,0,000,0,0,0\(etx)\r\n\(stx)000,0,0,0,0,1,0,1\(etx)\r\n"

    // MARK: ~HQES

    /// Beispiel aus dem ZPL II Programming Guide: Medium leer + Kopf offen, Druckkopf reinigen.
    static let hostQueryGuide = "\(stx)\r\n  PRINTER STATUS\r\n   ERRORS:         1 00000000 00000005\r\n   WARNINGS:       1 00000000 00000002\r\n\(etx)\r\n"

    /// Keine Fehler, keine Warnungen.
    static let hostQueryClean = "\(stx)\r\n  PRINTER STATUS\r\n   ERRORS:         0 00000000 00000000\r\n   WARNINGS:       0 00000000 00000000\r\n\(etx)\r\n"

    // MARK: ~HI

    static let hostIdentificationZD421 = "\(stx)ZD421-203dpi,V84.20.18Z,8,8192KB\(etx)"
    static let hostIdentificationZT410Cutter = "\(stx)ZT410-300dpi,V75.19.15Z,12,8176KB,C\(etx)\r\n"
    static let hostIdentificationLegacy = "\(stx)105SL-200DPI,V60.13.0.14Z,8,4096KB\(etx)"

    // MARK: ^HH

    /// `^HH`-Ausgabe eines ZD421 (gekürzt, Originalformatierung mit Punktführern).
    static let configurationZD421 = """
    \(stx)\r
      PRINTER CONFIGURATION\r
    \r
    Zebra Technologies\r
    ZTC ZD421-203dpi ZPL\r
    D2J214500123\r
    \r
    +10.0...............  DARKNESS\r
    MEDIUM..............  DARKNESS SWITCH\r
    4.0 IPS.............  PRINT SPEED\r
    +000................  TEAR OFF ADJUST\r
    TEAR OFF............  PRINT MODE\r
    GAP/NOTCH...........  MEDIA TYPE\r
    WEB.................  SENSOR SELECT\r
    DIRECT-THERMAL......  PRINT METHOD\r
    832.................  PRINT WIDTH\r
    1218................  LABEL LENGTH\r
    39.0IN   988MM......  MAXIMUM LENGTH\r
    CONNECTED...........  USB COMM.\r
    9600................  BAUD\r
    8 BITS..............  DATA BITS\r
    NONE................  PARITY\r
    <~>  7EH............  CONTROL CHAR\r
    <^>  5EH............  COMMAND CHAR\r
    <,>  2CH............  DELIM./CHAR\r
    ZPL II..............  ZPL MODE\r
    DEFAULT.............  BACKFEED\r
    +000................  LABEL TOP\r
    +0000...............  LEFT POSITION\r
    ........  MODES DISABLED\r
     832 8/MM FULL......  RESOLUTION\r
    V84.20.18Z <-.......  FIRMWARE\r
    1.3.................  XML SCHEMA\r
    6.5.0 0.814.........  HARDWARE ID\r
    4096k...........R:  RAM\r
    61440k..........E:  ONBOARD FLASH\r
    1,234 IN............  HEAD USAGE\r
    D2J214500123........  SERIAL NUMBER\r
    FIRMWARE IN THIS PRINTER IS COPYRIGHTED\r
    \(etx)
    """

    /// Ältere Firmware ohne Punktführer (Spalten durch Leerzeichen getrennt).
    static let configurationLegacy = """
      PRINTER CONFIGURATION
    Zebra Technologies
    ZTC 105SL-200dpi
     +15.0               DARKNESS
     4 IPS               PRINT SPEED
     TEAR OFF            PRINT MODE
     39.0IN   988MM      MAXIMUM LENGTH
     <~>  7EH            CONTROL CHAR
     V60.13.0.14Z        FIRMWARE
    """

    // MARK: ^HW / file.dir

    /// Beispiel aus der Aufgabenstellung (Onboard-Flash E:).
    static let directoryFlash = "\(stx)\r\n- DIR E:*.*\r\n*E:LOGO.GRF       1234\r\n*E:ARIAL.TTF   45678\r\n-     12345678 bytes free E:ONBOARD FLASH\r\n\(etx)"

    /// Beispiel aus dem ZPL II Programming Guide (`^HWR:*.*`).
    static let directoryGuideRAM = """
    \(stx)
    - DIR R:*.*
    *R:ARIALN1.FNT 49140
    *R:ARIALN2.FNT 49140
    *R:ARIALN3.FNT 49140
    *R:ARIALN4.FNT 49140
    *R:ARIALN.FNT 49140
    *R:ZEBRA.GRF 8420
    -794292 bytes free R:RAM
    \(etx)
    """

    /// SGD `file.dir` (Antwort in Anführungszeichen, mehrere Laufwerke, `* `-Präfix mit Leerzeichen).
    static let directorySGD = """
    "
    - DIR E:*.*
    * E:FORMAT.ZPL      512
    * E:SHIPPING.ZPL    1024
    * E:TT0003M_.TTF    52345
    -   6574080 bytes free E:ONBOARD FLASH

    - DIR Z:*.*
    * Z:UTF8.DAT        3290
    * Z:ARIAL.TTF       98765
    -         0 bytes free Z:ROM
    "
    """

    /// Kopfzeile „Directory of“ mit Einträgen ohne Laufwerk.
    static let directoryPlain = """
    Directory of E:
    LOGO.PNG          2048
    INVOICE.ZPL       730
    LABEL.NRD         64
    123456 bytes free
    """

    // MARK: SGD

    /// `{}{"allconfig":null}`-Antwort (Ausschnitt).
    static let allConfigJSON = """
    {"allconfig":{"device.friendly_name":{"value":"Lager-01","type":"string","range":"0-17","clone":false,"archive":true,"access":"RW"},\
    "media.speed":{"value":"4.0","type":"double","range":"2.0-8.0","clone":true,"archive":true,"access":"RW"},\
    "ip.dhcp.enable":{"value":"on","type":"bool","range":"on,off","clone":true,"archive":true,"access":"RW"},\
    "device.unique_id":{"value":"D2J214500123","type":"string","range":"0-128","clone":false,"archive":false,"access":"R"},\
    "print.tone":{"value":"10.0","type":"double","range":"0.0-30.0","clone":true,"archive":true,"access":"RW"}}}
    """

    /// `! U1 getvar "allcv"`-Ausgabe (Ausschnitt).
    static let allCV = """
    "appl.name : V84.20.18Z , Choices:\r
    device.friendly_name : Lager-01 , Choices: A string of 0 - 17 characters\r
    device.languages : zpl , Choices: epl_zpl,zpl,line_print,hybrid_xml_zpl\r
    ezpl.media_type : direct thermal , Choices: direct thermal,thermal trans\r
    media.speed : 4.0 , Choices: 2.0-8.0\r
    ip.addr : "192.168.1.20" , Choices: \r
    zpl.label_length : 1218 , Choices: 1-32000\r
    odometer.total_print_length : 7,342 INCHES , Choices: \r
    "
    """
}

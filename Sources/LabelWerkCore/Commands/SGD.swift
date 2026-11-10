import Foundation

/// Set-Get-Do-Befehle (SGD) der Link-OS-Drucker – in ZPL-, EPL- und CPCL-Modus verfügbar.
///
/// * Klassische Form: `! U1 getvar "name"\r\n`, `! U1 setvar "name" "wert"\r\n`,
///   `! U1 do "name" "wert"\r\n`. Die Antwort auf `getvar` ist der Wert in Anführungszeichen.
/// * JSON-Form (Link-OS): `{}{"name":null}` liest, `{}{"name":"wert"}` setzt; die Antwort ist
///   ein JSON-Objekt.
///
/// Bereinigung und Anführungszeichen in ``getvar(_:)``, ``setvar(_:_:)`` und ``do(_:_:)``:
///
/// * Steuerzeichen (Zeilenumbrüche, Tabulatoren, `DEL` …) würden den Befehl beenden und werden
///   aus Namen und Werten **immer** entfernt – in beiden Syntaxformen.
/// * Ein `"` lässt sich in der klassischen Syntax nicht darstellen: Sie kennt keine Maskierung,
///   der Drucker beendet den Wert am inneren `"` und übernähme still einen abgeschnittenen Wert
///   (z. B. bei einer WLAN-Passphrase). Enthält Name oder Wert ein `"`, liefern die Funktionen
///   deshalb die gleichwertige, JSON-maskierte Link-OS-Form (`{}{"name":null}` bzw.
///   `{}{"name":"wert"}`, ohne Zeilenende). ``requiresJSON(_:_:)`` sagt vorab, ob das der Fall
///   ist – wichtig für den Aufrufer, weil der Drucker dann **mit einem JSON-Objekt antwortet**
///   (auch auf das Setzen: neuer bzw. bei Fehlschlag alter Wert) statt mit `"wert"` bzw. gar nicht.
///   Drucker ohne Link-OS führen die JSON-Form nicht als SGD-Befehl aus; dort ist ein `"`
///   grundsätzlich nicht übertragbar – gespeichert wird dann nichts statt eines verfälschten Werts.
public enum SGD {

    // MARK: - Befehle

    /// `! U1 getvar "name"\r\n`
    ///
    /// Enthält der Name ein `"`, wird stattdessen `{}{"name":null}` erzeugt (siehe Typ-Dokumentation).
    public static func getvar(_ name: String) -> String {
        let name = sanitized(name)
        if requiresJSON(name) { return jsonGet([name]) }
        return "! U1 getvar \(quote(name))\r\n"
    }

    /// `! U1 setvar "name" "wert"\r\n`
    ///
    /// Enthält Name oder Wert ein `"`, wird stattdessen `{}{"name":"wert"}` erzeugt
    /// (JSON-maskiert, ohne Zeilenende; siehe Typ-Dokumentation). Steuerzeichen werden in beiden
    /// Formen entfernt.
    public static func setvar(_ name: String, _ value: String) -> String {
        let name = sanitized(name)
        let value = sanitized(value)
        if requiresJSON(name, value) { return jsonSet([(name: name, value: value)]) }
        return "! U1 setvar \(quote(name)) \(quote(value))\r\n"
    }

    /// `! U1 do "name" "wert"\r\n` (ohne Wert: `""`).
    ///
    /// Enthält Name oder Wert ein `"`, wird stattdessen `{}{"name":"wert"}` erzeugt. Zebra
    /// dokumentiert die JSON-Form nur für `getvar`/`setvar`; Link-OS behandelt sie als `setvar`.
    /// Reine `do`-Variablen führt der Drucker in dieser Form unter Umständen nicht aus – das ist
    /// gewollt: Ein nicht ausgeführter Befehl ist sicherer als einer mit verfälschtem Wert (bei
    /// `file.delete` würde ein gekürzter Name sonst eine andere Datei treffen).
    public static func `do`(_ name: String, _ value: String = "") -> String {
        let name = sanitized(name)
        let value = sanitized(value)
        if requiresJSON(name, value) { return jsonSet([(name: name, value: value)]) }
        return "! U1 do \(quote(name)) \(quote(value))\r\n"
    }

    /// `true`, wenn Name oder Wert ein `"` enthalten und ``getvar(_:)``, ``setvar(_:_:)`` bzw.
    /// ``do(_:_:)`` deshalb die JSON-Form erzeugen. Der Drucker antwortet dann mit einem
    /// JSON-Objekt (auszuwerten mit `SGDResponseParser.parseJSON`), auch auf `setvar`.
    public static func requiresJSON(_ name: String, _ value: String = "") -> Bool {
        name.unicodeScalars.contains("\"") || value.unicodeScalars.contains("\"")
    }

    /// JSON-Abfrage mehrerer Variablen: `{}{"a":null,"b":null}` (Reihenfolge wie übergeben,
    /// doppelte Namen werden nur einmal abgefragt).
    public static func jsonGet(_ names: [String]) -> String {
        var seen = Set<String>()
        let members = names.filter { seen.insert($0).inserted }.map { "\(jsonString($0)):null" }
        return "{}{" + members.joined(separator: ",") + "}"
    }

    /// JSON-Zuweisung: `{}{"a":"1","b":"2"}` (Reihenfolge wie übergeben). Werte werden
    /// JSON-konform maskiert – damit lassen sich auch Werte mit `"` setzen.
    public static func jsonSet(_ values: [(name: String, value: String)]) -> String {
        "{}{" + values.map { "\(jsonString($0.name)):\(jsonString($0.value))" }.joined(separator: ",") + "}"
    }

    /// JSON-Zuweisung aus einem Wörterbuch (Schlüssel alphabetisch sortiert, damit die Ausgabe stabil ist).
    public static func jsonSet(_ values: [String: String]) -> String {
        jsonSet(values.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) })
    }

    /// `{}{"allconfig":null}` – alle Einstellungen mit Wert, Typ, Bereich und Zugriff (Link-OS).
    public static let allConfigJSON: String = "{}{\"allconfig\":null}"

    /// `! U1 getvar "allcv"\r\n` – alle Variablen als Text (auch ältere Firmware).
    public static let allVariables: String = getvar("allcv")

    /// Bereiche für `device.restore_defaults`.
    public enum RestoreScope: String, Sendable, CaseIterable, Codable {
        case ip
        case wlan
        case bluetooth
        case display
        case power
        case all

        /// Deutscher Anzeigename.
        public var displayName: String {
            switch self {
            case .ip: return "Netzwerk (IP)"
            case .wlan: return "WLAN"
            case .bluetooth: return "Bluetooth"
            case .display: return "Display"
            case .power: return "Energie"
            case .all: return "Alle Einstellungen"
            }
        }
    }

    /// `! U1 do "device.restore_defaults" "{bereich}"\r\n`
    public static func restoreDefaults(_ scope: RestoreScope) -> String {
        `do`(Variable.restoreDefaults, scope.rawValue)
    }

    /// `! U1 do "device.reset" ""\r\n` – Neustart.
    public static func reset() -> String { `do`(Variable.reset) }

    /// `! U1 do "file.dir" "E:"\r\n` – Dateiliste eines Laufwerks an den Host senden.
    public static func fileDirectory(_ drive: String = "E:") -> String {
        `do`(Variable.fileDirectory, ZPL.normalizedDrive(drive))
    }

    /// `! U1 do "ezpl.manual_calibration" ""\r\n` – manuelle Kalibrierung (Desktop-Drucker).
    public static func manualCalibration() -> String { `do`(Variable.manualCalibration) }

    /// `! U1 setvar "media.printmode" "{wert}"\r\n` – Druckmodus per SGD (für Linerless-Modi die
    /// einzige Möglichkeit, siehe ``PrintMode/usesSGD``) mit dem dokumentierten Setzwert
    /// ``PrintMode/sgdSetValue``, z. B. `"L"` (Linerless ablösen) oder `"linerless cut"`.
    public static func setPrintMode(_ mode: PrintMode) -> String {
        setvar(Variable.printMode, mode.sgdSetValue)
    }

    // MARK: - Variablennamen

    /// Wichtige Link-OS-Variablennamen.
    public enum Variable {
        // Gerät
        /// Anzeigename des Druckers, z. B. „Lager-1“.
        public static let friendlyName = "device.friendly_name"
        /// Produktname, z. B. „ZD421“.
        public static let productName = "device.product_name"
        /// Seriennummer.
        public static let serial = "device.unique_id"
        /// Firmware-Version, z. B. „V84.20.18Z“.
        public static let firmware = "appl.name"
        /// Unterstützte/aktive Befehlssprachen (`zpl`, `epl_zpl`, `hybrid_xml_zpl`, `line_print` …).
        public static let languages = "device.languages"
        /// Betriebszeit seit dem Einschalten.
        public static let uptime = "device.uptime"
        /// Host-Status wie `~HS`.
        public static let hostStatus = "device.host_status"
        /// Host-Identifikation wie `~HI`.
        public static let hostIdentification = "device.host_identification"
        /// Sprache des Displays.
        public static let displayLanguage = "display.language"
        /// Datum der Echtzeituhr.
        public static let rtcDate = "rtc.date"
        /// Uhrzeit der Echtzeituhr.
        public static let rtcTime = "rtc.time"

        // Druck & Medien
        /// Auflösung in dpi.
        public static let resolution = "head.resolution.in_dpi"
        /// Druckbreite in Punkten.
        public static let printWidth = "ezpl.print_width"
        /// Maximale Etikettenlänge.
        public static let labelLengthMax = "ezpl.label_length_max"
        /// Medienerkennung (`continuous`, `gap/notch`, `mark`).
        public static let mediaType = "ezpl.media_type"
        /// Druckverfahren (`direct thermal`, `thermal trans`).
        public static let printMethod = "ezpl.print_method"
        /// Druckmodus (`tear off`, `peel off`, `cutter`, `rewind` …).
        public static let printMode = "media.printmode"
        /// Schwärzung 0,0…30,0.
        public static let tone = "print.tone"
        /// Druckgeschwindigkeit in Zoll/s.
        public static let speed = "media.speed"
        /// Abreißposition.
        public static let tearOff = "ezpl.tear_off"
        /// Linker Versatz (`^LS`).
        public static let leftPosition = "zpl.left_position"
        /// Sensormodus (`gap`, `bar`).
        public static let senseMode = "media.sense_mode"
        /// Medienstatus (`ok`, `out`).
        public static let mediaStatus = "media.status"
        /// Druckkopfverriegelung (`ok`, `open`).
        public static let headLatch = "head.latch"
        /// Aktion beim Einschalten (`calibrate`, `feed`, `length`, `no motion`, `short cal`).
        public static let powerUpAction = "ezpl.power_up_action"
        /// Aktion nach dem Schließen des Druckkopfs.
        public static let headCloseAction = "ezpl.head_close_action"
        /// ZPL-Modus (`zpl II`, `zpl`).
        public static let zplMode = "zpl.zpl_mode"
        /// Vertikaler Versatz (`^LT`).
        public static let labelTop = "zpl.label_top"
        /// Formatpräfix (`^CC`, Standard `^`).
        public static let caret = "zpl.caret"
        /// Steuerpräfix (`^CT`, Standard `~`).
        public static let controlCharacter = "zpl.control_character"
        /// Trennzeichen (`^CD`, Standard `,`).
        public static let delimiter = "zpl.delimiter"
        /// Medienart (`label`, `journal` – Journal = Endlosmaterial bei Mobildruckern).
        public static let mediaKind = "media.type"

        // Zähler
        /// Gesamte Drucklänge (z. B. „8560 INCHES, 21744 CENTIMETERS“).
        public static let odometer = "odometer.total_print_length"
        /// Gesamtzahl gedruckter Etiketten.
        public static let labelCount = "odometer.total_label_count"
        /// Drucklänge seit der letzten Kopfreinigung.
        public static let headCleaned = "odometer.headclean"
        /// Drucklänge seit dem letzten Kopftausch.
        public static let headNew = "odometer.headnew"

        // Netzwerk
        /// IP-Adresse (Einstellung).
        public static let ip = "ip.addr"
        /// Subnetzmaske (Einstellung).
        public static let netmask = "ip.netmask"
        /// Standard-Gateway (Einstellung).
        public static let gateway = "ip.gateway"
        /// Adressvergabe (`dhcp`, `permanent`, `all`, `bootp` …).
        public static let ipProtocol = "ip.ip_protocol"
        /// DNS-Server.
        public static let dnsServers = "ip.dns.servers"
        /// Raw-Port (Standard 9100).
        public static let port = "ip.port"
        /// Aktive IP-Adresse der aktiven Schnittstelle.
        public static let activeIP = "interface.network.active.ip_addr"
        /// Aktive Subnetzmaske.
        public static let activeNetmask = "interface.network.active.netmask"
        /// Aktives Gateway.
        public static let activeGateway = "interface.network.active.gateway"
        /// Adressvergabe der aktiven Schnittstelle.
        public static let activeProtocol = "interface.network.active.protocol"
        /// MAC-Adresse der aktiven Schnittstelle.
        public static let mac = "interface.network.active.mac_addr"
        /// IP-Adresse der kabelgebundenen Schnittstelle.
        public static let wiredIP = "internal_wired.ip.addr"
        /// MAC-Adresse der kabelgebundenen Schnittstelle.
        public static let wiredMAC = "internal_wired.mac_addr"

        // WLAN
        /// WLAN ein/aus (`on`, `off`).
        public static let wlanEnabled = "wlan.enable"
        /// SSID.
        public static let wlanESSID = "wlan.essid"
        /// Sicherheitsmodus (z. B. `wpa_psk`).
        public static let wlanSecurity = "wlan.security"
        /// WPA-Passphrase bzw. PSK (nur schreiben).
        public static let wlanPSK = "wlan.wpa.psk"
        /// WLAN-IP-Adresse.
        public static let wlanIP = "wlan.ip.addr"
        /// WLAN-Adressvergabe.
        public static let wlanProtocol = "wlan.ip.protocol"
        /// WLAN-MAC-Adresse.
        public static let wlanMAC = "wlan.mac_addr"
        /// Signalstärke in Prozent.
        public static let wlanSignalStrength = "wlan.signal_strength"
        /// Signalqualität in Prozent.
        public static let wlanSignalQuality = "wlan.signal_quality"

        // Bluetooth
        /// Bluetooth ein/aus.
        public static let btEnabled = "bluetooth.enable"
        /// Bluetooth-Name.
        public static let btName = "bluetooth.friendly_name"
        /// Bluetooth-Adresse.
        public static let btAddress = "bluetooth.address"
        /// Sichtbarkeit.
        public static let btDiscoverable = "bluetooth.discoverable"
        /// Controller-Modus (`both`, `classic`, `le`).
        public static let btLEMode = "bluetooth.le.controller_mode"

        // Energie
        /// Akkuladung in Prozent.
        public static let battery = "power.percent_full"
        /// Akkuzustand (`good`, `replace` …).
        public static let batteryHealth = "power.health"

        // Do-Befehle
        /// Neustart (`do`).
        public static let reset = "device.reset"
        /// Standardwerte wiederherstellen (`do`, Wert: `ip`, `wlan`, `bluetooth`, `display`, `power`, `all`).
        public static let restoreDefaults = "device.restore_defaults"
        /// Dateiliste eines Laufwerks (`do`, Wert: `E:`).
        public static let fileDirectory = "file.dir"
        /// Manuelle Medienkalibrierung (`do`).
        public static let manualCalibration = "ezpl.manual_calibration"
    }

    /// Lesbare Variablen, die für Dashboard, Identität, Netzwerk und Zähler gemeinsam abgefragt
    /// werden (ohne reine Schreib- und `do`-Variablen).
    public static let commonVariables: [String] = [
        Variable.friendlyName, Variable.productName, Variable.serial, Variable.firmware, Variable.languages,
        Variable.uptime,
        Variable.resolution, Variable.printWidth, Variable.labelLengthMax, Variable.mediaType, Variable.printMethod,
        Variable.printMode, Variable.tone, Variable.speed, Variable.tearOff, Variable.leftPosition,
        Variable.senseMode, Variable.mediaStatus, Variable.headLatch,
        Variable.odometer, Variable.labelCount, Variable.headCleaned, Variable.headNew,
        Variable.ip, Variable.netmask, Variable.gateway, Variable.ipProtocol, Variable.dnsServers, Variable.port,
        Variable.activeIP, Variable.mac, Variable.wiredIP, Variable.wiredMAC,
        Variable.wlanEnabled, Variable.wlanESSID, Variable.wlanSecurity, Variable.wlanIP, Variable.wlanMAC,
        Variable.wlanSignalStrength,
        Variable.btEnabled, Variable.btName, Variable.btAddress,
        Variable.battery, Variable.batteryHealth,
    ]

    /// Variablen, aus denen sich die Druckeinstellungen des Druckers ablesen lassen
    /// (`PrinterClient.readPrintSettings()`): Schwärzung, Geschwindigkeit, Medienerkennung,
    /// Druckverfahren, Druckmodus, Versatz, Abreißposition, Einschalt-/Kopfschließ-Aktion,
    /// Steuerzeichen.
    public static let printSettingsVariables: [String] = [
        Variable.tone, Variable.speed, Variable.mediaType, Variable.printMethod, Variable.printMode,
        Variable.labelTop, Variable.leftPosition, Variable.tearOff, Variable.powerUpAction, Variable.headCloseAction,
        Variable.caret, Variable.controlCharacter, Variable.delimiter, Variable.senseMode, Variable.mediaKind,
    ]

    // MARK: - Hilfen

    /// Entfernt Zeilenumbrüche und alle übrigen Steuerzeichen (C0 und `DEL`), die einen
    /// SGD-Befehl vorzeitig beenden würden.
    static func sanitized(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars where scalar.value >= 0x20 && scalar.value != 0x7F {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Setzt einen Namen/Wert für die klassische Syntax in Anführungszeichen; Steuerzeichen werden
    /// entfernt. Darf nur für Text ohne `"` verwendet werden (siehe ``requiresJSON(_:_:)``).
    static func quote(_ text: String) -> String {
        "\"" + sanitized(text) + "\""
    }

    /// JSON-Zeichenkette mit Anführungszeichen und Maskierung (RFC 8259).
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + ZPL.hexByte(UInt8(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

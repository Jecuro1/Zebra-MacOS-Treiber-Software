import Foundation
import Testing
@testable import LabelWerkCore

@Suite("SGD")
struct SGDTests {
    @Test("getvar / setvar / do – exakte Syntax mit CR LF")
    func classicCommands() {
        #expect(SGD.getvar("device.friendly_name") == "! U1 getvar \"device.friendly_name\"\r\n")
        #expect(SGD.setvar("print.tone", "15") == "! U1 setvar \"print.tone\" \"15\"\r\n")
        #expect(SGD.setvar("wlan.essid", "Büro WLAN") == "! U1 setvar \"wlan.essid\" \"Büro WLAN\"\r\n")
        #expect(SGD.do("device.reset") == "! U1 do \"device.reset\" \"\"\r\n")
        #expect(SGD.do("file.dir", "E:") == "! U1 do \"file.dir\" \"E:\"\r\n")
    }

    @Test("Zeilenumbrüche und Steuerzeichen werden entfernt")
    func sanitizing() {
        #expect(SGD.setvar("device.friendly_name", "a\r\nb\tc") == "! U1 setvar \"device.friendly_name\" \"abc\"\r\n")
        #expect(SGD.getvar("x\ny") == "! U1 getvar \"xy\"\r\n")
    }

    @Test("Anführungszeichen: JSON-Form statt abgeschnittener klassischer Befehle")
    func quotesSwitchToJSON() throws {
        // Regression: früher entstand `! U1 setvar "device.friendly_name" "a"b"` – der Drucker
        // hätte still nur `a` gespeichert.
        #expect(SGD.setvar("device.friendly_name", "a\"b") == "{}{\"device.friendly_name\":\"a\\\"b\"}")
        #expect(SGD.do("file.delete", "E:A\"B.ZPL") == "{}{\"file.delete\":\"E:A\\\"B.ZPL\"}")
        #expect(SGD.getvar("we\"ird") == "{}{\"we\\\"ird\":null}")

        // Kein klassischer Befehl darf mehr als die vier bzw. zwei Begrenzungs-Anführungszeichen enthalten.
        for command in [SGD.setvar("wlan.essid", "\""), SGD.setvar("a\"", "b"), SGD.do("x", "\"\""),
                        SGD.getvar("\"")] {
            #expect(command.hasPrefix("{}{"), "\(command)")
            #expect(!command.hasSuffix("\r\n"))
        }

        // Steuerzeichen werden auch in der JSON-Form entfernt, das `"` bleibt erhalten.
        let psk = "Pass\"wort\r\n\tmit\u{7F}Ä😀"
        let command = SGD.setvar(SGD.Variable.wlanPSK, psk)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(command.dropFirst(2).utf8)) as? [String: String])
        #expect(object == [SGD.Variable.wlanPSK: "Pass\"wortmitÄ😀"])

        // Ohne `"` bleibt es bei der klassischen Syntax.
        #expect(SGD.setvar("wlan.wpa.psk", "geheim'123\\") == "! U1 setvar \"wlan.wpa.psk\" \"geheim'123\\\"\r\n")
        #expect(SGD.do("device.reset") == "! U1 do \"device.reset\" \"\"\r\n")
    }

    @Test("requiresJSON stimmt mit der erzeugten Form überein")
    func requiresJSON() {
        #expect(!SGD.requiresJSON("device.friendly_name"))
        #expect(!SGD.requiresJSON("device.friendly_name", "Lager 1 – Büro"))
        #expect(SGD.requiresJSON("device.friendly_name", "a\"b"))
        #expect(SGD.requiresJSON("a\"b"))
        #expect(SGD.requiresJSON("a\"b", ""))
        let samples: [(String, String)] = [("print.tone", "15"), ("wlan.essid", "My \"Net\""), ("x\"y", "z"),
                                           ("device.reset", ""), ("a", "\r\n")]
        for (name, value) in samples {
            let json = SGD.requiresJSON(name, value)
            #expect(SGD.setvar(name, value).hasPrefix("{}{") == json, "setvar \(name)")
            #expect(SGD.do(name, value).hasPrefix("{}{") == json, "do \(name)")
            #expect(SGD.getvar(name).hasPrefix("{}{") == SGD.requiresJSON(name), "getvar \(name)")
        }
    }

    @Test("JSON-Abfrage")
    func jsonGet() throws {
        #expect(SGD.jsonGet(["a", "b"]) == "{}{\"a\":null,\"b\":null}")
        #expect(SGD.jsonGet(["a", "b", "a"]) == "{}{\"a\":null,\"b\":null}")
        #expect(SGD.jsonGet([]) == "{}{}")
        #expect(SGD.jsonGet(["we\"ird\\name"]) == "{}{\"we\\\"ird\\\\name\":null}")

        let json = SGD.jsonGet(SGD.commonVariables)
        #expect(json.hasPrefix("{}{"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.dropFirst(2).utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(SGD.commonVariables))
    }

    @Test("JSON-Zuweisung mit Maskierung")
    func jsonSet() throws {
        #expect(SGD.jsonSet([(name: "wlan.essid", value: "My \"Net\"")]) == "{}{\"wlan.essid\":\"My \\\"Net\\\"\"}")
        #expect(SGD.jsonSet(["b": "2", "a": "1"]) == "{}{\"a\":\"1\",\"b\":\"2\"}")
        #expect(SGD.jsonSet([:]) == "{}{}")

        let tricky = "Pass\"wort\\mit\nZeile\tTab\u{1}Ä😀"
        let json = SGD.jsonSet([(name: SGD.Variable.wlanPSK, value: tricky)])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.dropFirst(2).utf8)) as? [String: String])
        #expect(object[SGD.Variable.wlanPSK] == tricky)
    }

    @Test("Konstanten")
    func constants() {
        #expect(SGD.allConfigJSON == "{}{\"allconfig\":null}")
        #expect(SGD.allVariables == "! U1 getvar \"allcv\"\r\n")
    }

    @Test("Do-Hilfen")
    func doHelpers() {
        #expect(SGD.reset() == "! U1 do \"device.reset\" \"\"\r\n")
        #expect(SGD.restoreDefaults(.ip) == "! U1 do \"device.restore_defaults\" \"ip\"\r\n")
        #expect(SGD.restoreDefaults(.wlan) == "! U1 do \"device.restore_defaults\" \"wlan\"\r\n")
        #expect(SGD.restoreDefaults(.all) == "! U1 do \"device.restore_defaults\" \"all\"\r\n")
        #expect(SGD.fileDirectory() == "! U1 do \"file.dir\" \"E:\"\r\n")
        #expect(SGD.fileDirectory("r") == "! U1 do \"file.dir\" \"R:\"\r\n")
        #expect(SGD.manualCalibration() == "! U1 do \"ezpl.manual_calibration\" \"\"\r\n")
        #expect(SGD.RestoreScope.allCases.map(\.rawValue) == ["ip", "wlan", "bluetooth", "display", "power", "all"])
        #expect(SGD.RestoreScope.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("Link-OS-Variablennamen")
    func variableNames() {
        #expect(SGD.Variable.friendlyName == "device.friendly_name")
        #expect(SGD.Variable.productName == "device.product_name")
        #expect(SGD.Variable.serial == "device.unique_id")
        #expect(SGD.Variable.firmware == "appl.name")
        #expect(SGD.Variable.resolution == "head.resolution.in_dpi")
        #expect(SGD.Variable.printWidth == "ezpl.print_width")
        #expect(SGD.Variable.mediaType == "ezpl.media_type")
        #expect(SGD.Variable.printMethod == "ezpl.print_method")
        #expect(SGD.Variable.printMode == "media.printmode")
        #expect(SGD.Variable.tone == "print.tone")
        #expect(SGD.Variable.speed == "media.speed")
        #expect(SGD.Variable.odometer == "odometer.total_print_length")
        #expect(SGD.Variable.labelCount == "odometer.total_label_count")
        #expect(SGD.Variable.headCleaned == "odometer.headclean")
        #expect(SGD.Variable.languages == "device.languages")
        #expect(SGD.Variable.ip == "ip.addr")
        #expect(SGD.Variable.netmask == "ip.netmask")
        #expect(SGD.Variable.gateway == "ip.gateway")
        #expect(SGD.Variable.ipProtocol == "ip.ip_protocol")
        #expect(SGD.Variable.activeIP == "interface.network.active.ip_addr")
        #expect(SGD.Variable.mac == "interface.network.active.mac_addr")
        #expect(SGD.Variable.wlanESSID == "wlan.essid")
        #expect(SGD.Variable.wlanSecurity == "wlan.security")
        #expect(SGD.Variable.wlanEnabled == "wlan.enable")
        #expect(SGD.Variable.btName == "bluetooth.friendly_name")
        #expect(SGD.Variable.btAddress == "bluetooth.address")
        #expect(SGD.Variable.battery == "power.percent_full")
        #expect(SGD.Variable.reset == "device.reset")
        #expect(SGD.Variable.restoreDefaults == "device.restore_defaults")
        #expect(SGD.Variable.fileDirectory == "file.dir")
    }

    @Test("Gemeinsame Variablen: vollständig, eindeutig, nur lesbar")
    func commonVariables() {
        let names = SGD.commonVariables
        #expect(names.count >= 40)
        #expect(Set(names).count == names.count)
        let pattern = /^[a-z0-9_]+(\.[a-z0-9_]+)+$/
        #expect(names.allSatisfy { $0.wholeMatch(of: pattern) != nil })
        for required in [SGD.Variable.friendlyName, SGD.Variable.productName, SGD.Variable.serial,
                         SGD.Variable.firmware, SGD.Variable.resolution, SGD.Variable.ip, SGD.Variable.mac,
                         SGD.Variable.odometer, SGD.Variable.battery] {
            #expect(names.contains(required))
        }
        for writeOnly in [SGD.Variable.wlanPSK, SGD.Variable.reset, SGD.Variable.restoreDefaults,
                          SGD.Variable.fileDirectory, SGD.Variable.manualCalibration] {
            #expect(!names.contains(writeOnly))
        }
    }
}

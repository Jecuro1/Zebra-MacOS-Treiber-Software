import Foundation
import Testing
@testable import LabelWerkStatus

@Suite("SGD – getvar, JSON, allcv")
struct SGDResponseParserTests {

    // MARK: getvar

    @Test("getvar-Werte", arguments: [
        ("\"203\"", Optional("203")),
        ("\"ZD421\"\r\n", "ZD421"),
        ("\"8\"\0\0\0", "8"),
        ("\0\"on\"\0", "on"),
        ("203\r\n", "203"),
        ("\"\"", ""),
        ("\"?\"", nil),
        ("?", nil),
        ("  ?  \r\n", nil),
        ("", nil),
        ("\r\n", nil),
        ("\"abc", "abc"),
        ("\"Lager \\\"Nord\\\"\"", "Lager \\\"Nord\\\""),
        ("\u{02}\"direct thermal\"\u{03}", "direct thermal"),
        ("\" leading and trailing \"", " leading and trailing "),
    ])
    func parsesValues(raw: String, expected: String?) {
        #expect(SGDResponseParser.parseValue(TestSupport.data(raw)) == expected)
    }

    @Test("Mehrzeilige Werte behalten ihre Zeilenumbrüche")
    func multilineValue() {
        let raw = "\"\r\n- DIR E:*.*\r\n* E:LOGO.GRF 1234\r\n\""
        #expect(SGDResponseParser.parseValue(TestSupport.data(raw)) == "\n- DIR E:*.*\n* E:LOGO.GRF 1234\n")
    }

    @Test("Ungültiges UTF-8 wird als ISO-8859-1 gelesen")
    func latin1Fallback() {
        let bytes: [UInt8] = [0x22, 0x4B, 0xFC, 0x68, 0x6C, 0x72, 0x61, 0x75, 0x6D, 0x22] // "Kühlraum" in Latin-1
        #expect(SGDResponseParser.parseValue(TestSupport.data(bytes)) == "Kühlraum")
    }

    // MARK: JSON

    @Test("Einfache JSON-Antwort")
    func plainJSON() throws {
        let json = #"{"device.friendly_name":"ZD421","media.speed":"4.0","zpl.label_length":"1218"}"#
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result.count == 3)
        #expect(result["device.friendly_name"] == SGDSetting(name: "device.friendly_name", value: "ZD421"))
        #expect(result["media.speed"]?.value == "4.0")
        #expect(result["zpl.label_length"]?.type == nil)
    }

    @Test("Echo der Anfrage {}{…} und Zeilenende")
    func echoPrefix() throws {
        let json = "{}{\"device.friendly_name\":\"ZD421\"}\r\n"
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result == ["device.friendly_name": SGDSetting(name: "device.friendly_name", value: "ZD421")])
    }

    @Test("allconfig mit Deskriptoren")
    func allConfig() throws {
        let result = try SGDResponseParser.parseJSON(TestSupport.data(Fixtures.allConfigJSON))
        #expect(result.count == 5)
        let name = try #require(result["device.friendly_name"])
        #expect(name == SGDSetting(name: "device.friendly_name", value: "Lager-01", type: "string", range: "0-17",
                                   access: "RW", archive: true, clone: false))
        #expect(name.isWritable)
        #expect(name.numericRange == 0...17)
        #expect(name.group == "device")
        let speed = try #require(result["media.speed"])
        #expect(speed.value == "4.0")
        #expect(speed.type == "double")
        #expect(speed.numericRange == 2...8)
        let dhcp = try #require(result["ip.dhcp.enable"])
        #expect(dhcp.choices == ["on", "off"])
        #expect(dhcp.numericRange == nil)
        let uid = try #require(result["device.unique_id"])
        #expect(!uid.isWritable)
        #expect(uid.archive == false)
    }

    @Test("allconfig ohne Container und mit Leerraum")
    func allConfigUnwrapped() throws {
        let json = """
        {
          "media.type" : { "value" : "label", "type" : "enum", "range" : "continuous,gap/notch,mark,auto",
                           "clone" : true, "archive" : true, "access" : "RW" },
          "print.tone" : { "value" : 10.0, "type" : "double", "range" : "0.0-30.0", "archive" : "yes" }
        }
        """
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result["media.type"]?.choices == ["continuous", "gap/notch", "mark", "auto"])
        #expect(result["print.tone"]?.value == "10.0")
        #expect(result["print.tone"]?.archive == true)
        #expect(result["print.tone"]?.access == nil)
    }

    @Test("Verschachtelte Zweige werden zu Punktnamen")
    func nestedBranches() throws {
        let json = #"{"device":{"friendly_name":"Lager-01","languages":"zpl"},"ip":{"dhcp":{"enable":"on"}}}"#
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(Set(result.keys) == ["device.friendly_name", "device.languages", "ip.dhcp.enable"])
        #expect(result["ip.dhcp.enable"]?.value == "on")
    }

    @Test("null, \"?\", Zahlen, Wahrheitswerte und Arrays")
    func valueKinds() throws {
        let json = #"{"a.null":null,"a.unknown":"?","a.int":42,"a.neg":-1.5e3,"a.true":true,"a.false":false,"a.list":["x",1,null],"a.empty":""}"#
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result["a.null"] == nil)
        #expect(result["a.unknown"] == nil)
        #expect(result["a.int"]?.value == "42")
        #expect(result["a.neg"]?.value == "-1.5e3")
        #expect(result["a.true"]?.value == "true")
        #expect(result["a.false"]?.value == "false")
        #expect(result["a.list"]?.value == "x,1")
        #expect(result["a.empty"]?.value == "")
    }

    @Test("Deskriptor mit null-Wert bleibt als leerer Wert erhalten")
    func descriptorWithNull() throws {
        let json = #"{"wlan.wep.key1":{"value":null,"type":"string","range":"0-26","access":"W"}}"#
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result["wlan.wep.key1"] == SGDSetting(name: "wlan.wep.key1", value: "", type: "string", range: "0-26",
                                                     access: "W"))
    }

    @Test("Escape-Sequenzen und Unicode")
    func escapes() throws {
        let json = #"{"a.b":"Lager \"Süd\"\\n\/x\t","c.d":"K\u00fchlraum \ud83d\udce6","e.f":"\u20AC"}"#
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result["a.b"]?.value == "Lager \"Süd\"\\n/x\t")
        #expect(result["c.d"]?.value == "Kühlraum 📦")
        #expect(result["e.f"]?.value == "€")
    }

    @Test("Mehrere Antworten hintereinander werden zusammengeführt")
    func mergesObjects() throws {
        let json = "{\"a.b\":\"1\"}\r\n{\"c.d\":\"2\"}\r\n"
        let result = try SGDResponseParser.parseJSON(TestSupport.data(json))
        #expect(result.count == 2)
    }

    @Test("Fremddaten nach dem Objekt werden ignoriert")
    func trailingGarbage() throws {
        let result = try SGDResponseParser.parseJSON(TestSupport.data("\"203\"{\"a.b\":\"1\"} ok \u{03}"))
        #expect(result["a.b"]?.value == "1")
    }

    @Test("Leeres Objekt")
    func emptyObject() throws {
        #expect(try SGDResponseParser.parseJSON(TestSupport.data("{}")).isEmpty)
        #expect(try SGDResponseParser.parseJSON(TestSupport.data("{}{}")).isEmpty)
    }

    @Test("Ungültiges JSON wirft invalidJSON", arguments: [
        "{\"a\":}",
        "{\"a\":\"b\"",
        "{\"a\" \"b\"}",
        "{a:1}",
        "{\"a\":tru}",
        "{\"a\":\"\\x\"}",
        "{\"a\":\"\\u12\"}",
        "{\"a\":01.}",
        "{\"a\":[1,2}",
        "{\"a\":\"unterminated}",
        "no json here",
        "[1,2,3]",
    ])
    func invalidJSON(text: String) {
        let error = TestSupport.parseError { try SGDResponseParser.parseJSON(TestSupport.data(text)) }
        if case .invalidJSON = error {} else { Issue.record("invalidJSON erwartet für \(text): \(String(describing: error))") }
    }

    @Test("Leere Antwort")
    func emptyResponse() {
        #expect(TestSupport.parseError { try SGDResponseParser.parseJSON(Data()) } == .emptyResponse)
        #expect(TestSupport.parseError { try SGDResponseParser.parseJSON(TestSupport.data(" \r\n\0")) } == .emptyResponse)
    }

    @Test("Tiefe Verschachtelung führt zu Fehler statt Absturz")
    func deepNesting() {
        let deep = String(repeating: "{\"a\":", count: 10_000) + "1" + String(repeating: "}", count: 10_000)
        let error = TestSupport.parseError { try SGDResponseParser.parseJSON(TestSupport.data(deep)) }
        // Abbruch nach 64 Ebenen: 65 × „{"a":“ (je 5 Zeichen) gelesen.
        #expect(error == .invalidJSON("Verschachtelung zu tief (Position 325)"))
        let arrays = "{\"a\":" + String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000) + "}"
        let arrayError = TestSupport.parseError { try SGDResponseParser.parseJSON(TestSupport.data(arrays)) }
        if case .invalidJSON = arrayError {} else { Issue.record("invalidJSON erwartet") }
    }

    // MARK: allcv

    @Test("allcv-Textausgabe")
    func allCV() throws {
        let result = SGDResponseParser.parseAllCV(Fixtures.allCV)
        #expect(result.count == 8)
        #expect(result["appl.name"] == SGDSetting(name: "appl.name", value: "V84.20.18Z"))
        let name = try #require(result["device.friendly_name"])
        #expect(name.value == "Lager-01")
        #expect(name.range == "A string of 0 - 17 characters")
        #expect(result["device.languages"]?.value == "zpl")
        #expect(result["device.languages"]?.choices == ["epl_zpl", "zpl", "line_print", "hybrid_xml_zpl"])
        #expect(result["ezpl.media_type"]?.value == "direct thermal")
        #expect(result["media.speed"]?.range == "2.0-8.0")
        #expect(result["media.speed"]?.numericRange == 2...8)
        #expect(result["ip.addr"]?.value == "192.168.1.20")
        #expect(result["ip.addr"]?.range == nil)
        #expect(result["odometer.total_print_length"]?.value == "7,342 INCHES")
    }

    @Test("allcv: Werte mit Kommas, fehlende Choices, Fremdzeilen")
    func allCVEdgeCases() {
        let text = """
        device.languages : epl_zpl,zpl , Choices: epl_zpl,zpl
        bluetooth.address : 00:07:4D:12:34:56
        PRINTER CONFIGURATION
        not a setting : value
        wlan.essid : ? , Choices: A string of 0 - 32 characters
        : orphan
        """
        let result = SGDResponseParser.parseAllCV(text)
        #expect(result["device.languages"]?.value == "epl_zpl,zpl")
        #expect(result["bluetooth.address"]?.value == "00:07:4D:12:34:56")
        #expect(result["bluetooth.address"]?.range == nil)
        #expect(result["wlan.essid"] == nil)
        #expect(result.count == 2)
    }

    @Test("allcv: leerer oder kaputter Text ergibt leeres Ergebnis")
    func allCVEmpty() {
        #expect(SGDResponseParser.parseAllCV("").isEmpty)
        #expect(SGDResponseParser.parseAllCV("\"\"").isEmpty)
        #expect(SGDResponseParser.parseAllCV("\u{02}\u{03}::::,,,,").isEmpty)
    }

    // MARK: SGDSetting

    @Test("Numerische Bereiche", arguments: [
        ("0-17", Optional(0.0...17.0)), ("1.0-8.0", 1...8), ("-30 - 30", -30...30), ("-10--5", -10 ... -5),
        ("on,off", nil), ("A string of 0 - 17 characters", nil), ("17-0", nil), ("", nil),
    ])
    func numericRanges(range: String, expected: ClosedRange<Double>?) {
        #expect(SGDSetting(name: "a.b", value: "", range: range).numericRange == expected)
    }

    @Test("Schreibzugriff")
    func writable() {
        #expect(SGDSetting(name: "a.b", value: "").isWritable)
        #expect(SGDSetting(name: "a.b", value: "", access: "RW").isWritable)
        #expect(SGDSetting(name: "a.b", value: "", access: "w").isWritable)
        #expect(!SGDSetting(name: "a.b", value: "", access: "R").isWritable)
    }
}

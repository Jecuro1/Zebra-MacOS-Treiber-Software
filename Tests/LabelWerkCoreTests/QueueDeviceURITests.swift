import Foundation
import Testing
@testable import LabelWerkCore

/// Geräte-URI der Warteschlangen: Backend `labelwerk://` bzw. `socket://` nach
/// „Bei Papier- oder Farbbandende anhalten und fortsetzen“ (ARCHITECTURE.md §10 „Backend labelwerk“).
struct QueueDeviceURITests {

    @Test func networkURI() {
        #expect(QueueDeviceURI.networkURI(host: "10.62.13.19", port: 9100, resume: true) == "labelwerk://10.62.13.19:9100")
        #expect(QueueDeviceURI.networkURI(host: "10.62.13.19", port: 9100, resume: false) == "socket://10.62.13.19:9100")
        #expect(QueueDeviceURI.networkURI(host: "fe80::1%en0", port: 6101, resume: true)
                == "labelwerk://[fe80::1%25en0]:6101")
        #expect(QueueDeviceURI.networkURI(host: "[2001:db8::7]", port: 9100, resume: false) == "socket://[2001:db8::7]:9100")
        #expect(QueueDeviceURI.networkURI(host: "zd421.local", port: 9100, resume: true) == "labelwerk://zd421.local:9100")
    }

    @Test func targetSwitchesOnlyRawSchemes() {
        #expect(QueueDeviceURI.target(for: "socket://10.62.13.19:9100", resume: true) == "labelwerk://10.62.13.19:9100")
        #expect(QueueDeviceURI.target(for: " socket://zd421.local ", resume: true) == "labelwerk://zd421.local")
        #expect(QueueDeviceURI.target(for: "socket://[fe80::1%25en0]:6101/?waiteof=false", resume: true)
                == "labelwerk://[fe80::1%25en0]:6101")
        #expect(QueueDeviceURI.target(for: "SOCKET://10.0.0.5:9100", resume: true) == "labelwerk://10.0.0.5:9100")
        #expect(QueueDeviceURI.target(for: "labelwerk://10.62.13.19:9100", resume: false) == "socket://10.62.13.19:9100")
        #expect(QueueDeviceURI.target(for: "labelwerk://10.62.13.19:9100?mode=stream", resume: false)
                == "socket://10.62.13.19:9100")
        // Schon passend
        #expect(QueueDeviceURI.target(for: "labelwerk://10.62.13.19:9100", resume: true) == nil)
        #expect(QueueDeviceURI.target(for: "socket://10.62.13.19:9100", resume: false) == nil)
        // Andere Schemata nie
        for uri in ["usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D2J", "ipp://10.62.13.19/ipp/print",
                    "lpd://10.62.13.19/", "dnssd://Zebra._pdl-datastream._tcp.local./", "beh:/1/3/5/socket://10.0.0.5",
                    "file:/dev/null", "socket://", ""] {
            #expect(QueueDeviceURI.target(for: uri, resume: true) == nil, "\(uri)")
            #expect(QueueDeviceURI.target(for: uri, resume: false) == nil, "\(uri)")
        }
        #expect(QueueDeviceURI.usesBackend("LabelWerk://h:1"))
        #expect(!QueueDeviceURI.usesBackend("socket://h:1"))
    }

    @Test func lpadminArgumentsForTheSetting() {
        func args(_ uri: String?, _ option: String?, resume: Bool, backend: Bool = true, desired: String? = nil) -> [String] {
            QueueDeviceURI.arguments(currentURI: uri, currentOption: option, resumeAfterError: resume,
                                     backendInstalled: backend, desiredURI: desired)
        }
        // An (Standard): socket → labelwerk, keine Markierung.
        #expect(args("socket://10.0.0.5:9100", nil, resume: true) == ["-v", "labelwerk://10.0.0.5:9100"])
        #expect(args("labelwerk://10.0.0.5:9100", nil, resume: true) == [])
        // An, aber Markierung noch gesetzt (vorher aus): entfernen.
        #expect(args("labelwerk://10.0.0.5:9100", "false", resume: true) == ["-R", "lwResumeOnError-default"])
        // Aus: zurück auf socket und merken.
        #expect(args("labelwerk://10.0.0.5:9100", nil, resume: false)
                == ["-v", "socket://10.0.0.5:9100", "-o", "lwResumeOnError-default=False"])
        #expect(args("socket://10.0.0.5:9100", "False", resume: false) == [])
        #expect(args("socket://10.0.0.5:9100", "off", resume: false) == [])
        // Ohne Backend bleibt (bzw. wird) socket://, die Einstellung bleibt „an“ (keine Markierung).
        #expect(args("socket://10.0.0.5:9100", nil, resume: true, backend: false) == [])
        #expect(args("labelwerk://10.0.0.5:9100", nil, resume: true, backend: false) == ["-v", "socket://10.0.0.5:9100"])
        // USB: nur die Markierung.
        #expect(args("usb://Zebra/ZD421?serial=1", nil, resume: false) == ["-o", "lwResumeOnError-default=False"])
        #expect(args("usb://Zebra/ZD421?serial=1", nil, resume: true) == [])
        // Unbekannte URI (lpoptions ohne device-uri)
        #expect(args(nil, nil, resume: true) == [])
        // Feste Soll-URI (Etikettentyp: die des Druckers), umgestellt nach der Einstellung.
        #expect(args("socket://10.0.0.5:9100", nil, resume: true, desired: "socket://10.0.0.6:9100")
                == ["-v", "labelwerk://10.0.0.6:9100"])
        #expect(args("labelwerk://10.0.0.6:9100", nil, resume: true, desired: "socket://10.0.0.6:9100") == [])
        #expect(args("labelwerk://10.0.0.6:9100", nil, resume: true, desired: "usb://Zebra/ZD421")
                == ["-v", "usb://Zebra/ZD421"])
    }

    @Test func reprintQueueDefault() {
        func args(_ option: String?, _ count: Int) -> [String] {
            QueueDeviceURI.reprintArguments(currentOption: option, reprintAfterError: count)
        }
        // Standard 1: nichts setzen, einen früheren Wert entfernen.
        #expect(args(nil, 1) == [])
        #expect(args("3", 1) == ["-R", "lwReprintAfterError-default"])
        #expect(args("1", 1) == ["-R", "lwReprintAfterError-default"])
        // Andere Werte: setzen, wenn sie nicht schon genau so gesetzt sind.
        #expect(args(nil, 0) == ["-o", "lwReprintAfterError-default=0"])
        #expect(args(nil, 3) == ["-o", "lwReprintAfterError-default=3"])
        #expect(args("3", 3) == [])
        #expect(args(" 3 ", 3) == [])
        #expect(args("2", 3) == ["-o", "lwReprintAfterError-default=3"])
        #expect(args("0", 0) == [])
        // Begrenzt auf 0…99.
        #expect(args(nil, 250) == ["-o", "lwReprintAfterError-default=99"])
        #expect(args(nil, -4) == ["-o", "lwReprintAfterError-default=0"])
        #expect(args("99", 120) == [])

        // Zusammen mit Geräte-URI und lwResumeOnError (Reihenfolge: -v, Fortsetzen, Nachdruck).
        #expect(QueueDeviceURI.arguments(currentURI: "socket://10.0.0.5:9100", currentOption: nil, resumeAfterError: true,
                                         backendInstalled: true, currentReprintOption: nil, reprintAfterError: 2)
                == ["-v", "labelwerk://10.0.0.5:9100", "-o", "lwReprintAfterError-default=2"])
        #expect(QueueDeviceURI.arguments(currentURI: "labelwerk://10.0.0.5:9100", currentOption: nil, resumeAfterError: true,
                                         backendInstalled: true, currentReprintOption: "2", reprintAfterError: 2) == [])
        #expect(QueueDeviceURI.arguments(currentURI: "labelwerk://10.0.0.5:9100", currentOption: "False",
                                         resumeAfterError: true, backendInstalled: true,
                                         currentReprintOption: "0", reprintAfterError: 1)
                == ["-R", "lwResumeOnError-default", "-R", "lwReprintAfterError-default"])
        // Fortsetzen aus: die Zahl bleibt trotzdem in der Warteschlange (gilt beim Wiedereinschalten).
        #expect(QueueDeviceURI.arguments(currentURI: "socket://10.0.0.5:9100", currentOption: "False",
                                         resumeAfterError: false, backendInstalled: true,
                                         currentReprintOption: nil, reprintAfterError: 3)
                == ["-o", "lwReprintAfterError-default=3"])
        // Ohne Angabe (ältere Aufrufer): Standard 1, nichts zu tun.
        #expect(QueueDeviceURI.arguments(currentURI: "labelwerk://10.0.0.5:9100", currentOption: nil,
                                         resumeAfterError: true, backendInstalled: true) == [])
        #expect(QueueDeviceURI.reprintOption == "lwReprintAfterError")
    }

    /// Wie das Backend den Wert liest (`lwb_parse_reprint_count`): ungültig oder fehlend = 1.
    @Test func reprintOptionValues() {
        let cases: [(String?, Int)] = [
            (nil, 1), ("", 1), ("  ", 1), ("viele", 1), ("-2", 1), ("2x", 1), ("+", 1),
            ("0", 0), ("1", 1), (" 7 ", 7), ("+3", 3), ("007", 7), ("99", 99), ("100", 99), ("123456789012345", 99),
            ("Custom.12", 12), ("custom.0", 0),
            ("none", 0), ("Off", 0), ("FALSE", 0), ("no", 0), ("Keins", 0),
        ]
        for (value, expected) in cases {
            #expect(QueueDeviceURI.reprintCount(optionValue: value) == expected, "\(String(describing: value))")
        }
    }

    @Test func resumeOptionValues() {
        for value in ["False", "false", "NO", "off", "0", " false "] {
            #expect(QueueDeviceURI.isResumeDisabled(optionValue: value), "\(value)")
        }
        for value in [nil, "", "True", "true", "yes", "1", "Default"] as [String?] {
            #expect(!QueueDeviceURI.isResumeDisabled(optionValue: value), "\(String(describing: value))")
        }
    }

    @Test func adoptionTreatsBackendLikeSocket() {
        let zd421 = QueueAdoption.RegisteredPrinter(id: "zd421", host: "10.62.13.19", port: 9100)
        let alt = QueueAdoption.RegisteredPrinter(id: "alt", host: "10.62.13.20", port: 6101)
        func decide(_ uri: String, isLabelWerk: Bool = false) -> QueueAdoption.Decision {
            QueueAdoption.decide(queueName: "Q", deviceURI: uri, makeAndModel: nil, isLabelWerk: isLabelWerk,
                                 printers: [zd421, alt])
        }
        #expect(decide("labelwerk://10.62.13.19:9100", isLabelWerk: true) == .labelWerk(printerID: "zd421"))
        #expect(decide("labelwerk://10.62.13.19", isLabelWerk: true) == .labelWerk(printerID: "zd421"))
        // Der Port nennt das Gerät – wie bei socket://.
        #expect(decide("labelwerk://10.62.13.19:9101", isLabelWerk: true) == .ignore)
        #expect(decide("labelwerk://10.62.13.20:6101", isLabelWerk: true) == .labelWerk(printerID: "alt"))
        // Fremder Treiber mit labelwerk://: URI bleibt (Umstellung entscheidet QueueDeviceURI).
        #expect(decide("labelwerk://10.62.13.19:9100") == .adopt(printerID: "zd421", deviceURI: "labelwerk://10.62.13.19:9100"))
        #expect(decide("labelwerk://localhost:9100", isLabelWerk: true) == .ignore)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "labelwerk://10.62.13.20:6101")
                == QueueAdoption.RegisteredPrinter(id: "q", host: "10.62.13.20", port: 6101))
        #expect(QueueAdoption.deviceEndpoint(ofDeviceURI: "labelwerk://10.62.13.19:9100/?mode=stream")
                == QueueAdoption.Endpoint(scheme: "labelwerk", host: "10.62.13.19", port: 9100))
    }

    @Test func settingDecodesTolerantlyAndDefaultsToOn() throws {
        #expect(PrintSettings.default.resumeAfterError)
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: Data("{}".utf8))
        #expect(decoded.resumeAfterError)
        var settings = PrintSettings()
        settings.resumeAfterError = false
        let roundTrip = try JSONDecoder().decode(PrintSettings.self, from: JSONEncoder().encode(settings))
        #expect(!roundTrip.resumeAfterError)
        let invalid = try JSONDecoder().decode(PrintSettings.self, from: Data(#"{"resumeAfterError":"x"}"#.utf8))
        #expect(invalid.resumeAfterError)
        // Nur Treiber: keine CUPS-Option, kein Einfluss auf den Auftrag.
        #expect(settings.cupsOptions() == PrintSettings().cupsOptions())
    }
}

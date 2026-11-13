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

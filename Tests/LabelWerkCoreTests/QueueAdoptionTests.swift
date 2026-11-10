import Testing
@testable import LabelWerkCore

/// Übernahme fremder macOS-Warteschlangen (ARCHITECTURE.md §9 „Übernahme von macOS-Warteschlangen“).
struct QueueAdoptionTests {
    let zd421 = QueueAdoption.RegisteredPrinter(id: "zd421", host: "10.62.13.19", port: 9100)
    let lager = QueueAdoption.RegisteredPrinter(id: "lager", host: "ZD621-Lager.local", port: 9100)

    private func decide(_ uri: String, name: String = "10.62.13.19", makeAndModel: String? = nil,
                        isLabelWerk: Bool = false,
                        printers: [QueueAdoption.RegisteredPrinter]? = nil) -> QueueAdoption.Decision {
        QueueAdoption.decide(queueName: name, deviceURI: uri, makeAndModel: makeAndModel, isLabelWerk: isLabelWerk,
                             printers: printers ?? [zd421, lager])
    }

    @Test func adoptsQueueAddedInSystemSettingsByIP() {
        // „Drucker & Scanner › IP“ mit AirPrint/IPP, LPD, IPP und HP Jetdirect.
        #expect(decide("ipp://10.62.13.19/ipp/print", makeAndModel: "Zebra ZD421-203dpi ZPL")
                == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19:9100"))
        #expect(decide("ipps://10.62.13.19:631/ipp/print", makeAndModel: "AirPrint")
                == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19:9100"))
        #expect(decide("lpd://10.62.13.19/", makeAndModel: "Generic PostScript Printer")
                == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19:9100"))
        #expect(decide("http://10.62.13.19:631/ipp") == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19:9100"))
        #expect(decide("https://10.62.13.19/ipp/print") == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19:9100"))
    }

    @Test func keepsSocketURIOfTheSameDevice() {
        #expect(decide("socket://10.62.13.19") == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19"))
        #expect(decide(" socket://10.62.13.19:9100 ")
                == .adopt(printerID: "zd421", deviceURI: "socket://10.62.13.19:9100"))
        // Anderer Port: anderes Gerät an einem Druckserver mit mehreren Anschlüssen.
        #expect(decide("socket://10.62.13.19:9101") == .ignore)
        let alternatePort = QueueAdoption.RegisteredPrinter(id: "alt", host: "10.62.13.19", port: 6101)
        #expect(decide("socket://10.62.13.19:6101", printers: [alternatePort])
                == .adopt(printerID: "alt", deviceURI: "socket://10.62.13.19:6101"))
        #expect(decide("socket://10.62.13.19", printers: [alternatePort]) == .ignore)
        // Bei IPP & Co. nennt der Port nur den Dienst: Ziel ist der Rohdatenport des Druckers.
        #expect(decide("ipp://10.62.13.19/ipp/print", printers: [alternatePort])
                == .adopt(printerID: "alt", deviceURI: "socket://10.62.13.19:6101"))
    }

    @Test func comparesHostsCaseInsensitivelyWithoutDecoration() {
        #expect(decide("ipp://zd621-lager.LOCAL.:631/ipp/print", name: "ZD621")
                == .adopt(printerID: "lager", deviceURI: "socket://ZD621-Lager.local:9100"))
        #expect(decide("lpd://admin@ZD621-LAGER.local", name: "ZD621")
                == .adopt(printerID: "lager", deviceURI: "socket://ZD621-Lager.local:9100"))
        #expect(decide("IPP://zd621-lager.local/IPP/Print?waitjob=false", name: "ZD621")
                == .adopt(printerID: "lager", deviceURI: "socket://ZD621-Lager.local:9100"))
        let v6 = QueueAdoption.RegisteredPrinter(id: "v6", host: "fe80::1%en0", port: 9100)
        #expect(decide("ipp://[FE80::1%25en0]:631/ipp/print", name: "v6", printers: [v6])
                == .adopt(printerID: "v6", deviceURI: "socket://[fe80::1%25en0]:9100"))
        let bracketed = QueueAdoption.RegisteredPrinter(id: "b", host: "[2001:db8::7]", port: 9100)
        #expect(decide("socket://[2001:DB8::7]:9100", name: "b", printers: [bracketed])
                == .adopt(printerID: "b", deviceURI: "socket://[2001:DB8::7]:9100"))
    }

    @Test func neverTouchesOtherHostsOrNonNetworkQueues() {
        #expect(decide("ipp://10.62.13.190/ipp/print") == .ignore)
        #expect(decide("ipp://10.62.13.1/ipp/print") == .ignore)
        #expect(decide("socket://office-laser.local:9100", makeAndModel: "HP LaserJet") == .ignore)
        #expect(decide("usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D4J12345") == .ignore)
        #expect(decide("dnssd://Zebra%20ZD421._ipp._tcp.local./?uuid=1234") == .ignore)
        #expect(decide("file:///dev/null") == .ignore)
        #expect(decide("beh:/1/3/5/socket://10.62.13.19:9100") == .ignore)
        #expect(decide("") == .ignore)
        #expect(decide("ipp://10.62.13.19/ipp/print", name: "  ") == .ignore)
        #expect(decide("ipp://10.62.13.19/ipp/print", printers: []) == .ignore)
    }

    @Test func neverTouchesQueuesOfAPrintServerOrLoopback() {
        // Ein in LabelWerk über einen Druckserver erreichter Drucker: alle anderen Warteschlangen
        // dieses Servers gehören zu anderen Geräten.
        let server = QueueAdoption.RegisteredPrinter(id: "zebra", host: "printserver.firma.local")
        let windows = QueueAdoption.RegisteredPrinter(id: "zebra", host: "winsrv")
        let box = QueueAdoption.RegisteredPrinter(id: "zebra", host: "10.62.13.19")
        for (uri, printer) in [
            ("ipp://printserver.firma.local/printers/HP_LaserJet", server),
            ("ipp://printserver.firma.local/printers/Zebra_ZD421", server),
            ("ipps://printserver.firma.local:631/classes/Etiketten", server),
            ("http://winsrv:631/printers/Kyocera/.printer", windows),
            ("https://winsrv/printers/Kyocera/.printer", windows),
            ("ipp://winsrv/printers/Kyocera", windows),
            ("lpd://winsrv/Kyocera", windows),
            ("lpd://10.62.13.19/PORT2", box),
            ("lpd://10.62.13.19/queue", box),
            ("ipp://10.62.13.19/printer", box),
            ("ipp://10.62.13.19/ipps", box),
        ] {
            #expect(decide(uri, name: "Q", makeAndModel: "HP LaserJet Pro M404 Postscript", printers: [printer])
                    == .ignore, "\(uri)")
        }
        // Loopback: Tunnel, Proxy oder lokaler Druckserver – nie das Gerät selbst.
        for host in ["localhost", "LOCALHOST.", "printer.localhost", "127.0.0.1", "127.1.2.3", "[::1]",
                     "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]"] {
            let printer = QueueAdoption.RegisteredPrinter(id: "local", host: host)
            #expect(decide("socket://\(host):9100", name: "Q", printers: [printer]) == .ignore, "\(host)")
            #expect(decide("ipp://\(host)/ipp/print", name: "Q", printers: [printer]) == .ignore, "\(host)")
            #expect(decide("ipp://\(host):631/printers/Zebra", name: "Q", printers: [printer]) == .ignore, "\(host)")
        }
    }

    @Test func deviceEndpoints() {
        func device(_ uri: String) -> Bool { QueueAdoption.deviceEndpoint(ofDeviceURI: uri) != nil }
        #expect(device("socket://10.62.13.19"))
        #expect(device("socket://10.62.13.19:9100?waiteof=false"))
        #expect(device("ipp://10.62.13.19"))
        #expect(device("ipp://10.62.13.19/"))
        #expect(device("ipp://10.62.13.19/ipp"))
        #expect(device("ipp://10.62.13.19/ipp/"))
        #expect(device("ipps://10.62.13.19:631/ipp/print"))
        #expect(device("http://10.62.13.19:631/ipp?x=/printers/y"))
        #expect(device("lpd://10.62.13.19"))
        #expect(device("lpd://10.62.13.19/"))
        #expect(device("lpd://10.62.13.19/?banner=on"))
        #expect(!device("ipp://10.62.13.19/printers/Zebra"))
        #expect(!device("ipp://10.62.13.19/ippprint"))
        #expect(!device("lpd://10.62.13.19/raw"))
        #expect(!device("usb://Zebra%20Technologies/ZTC%20ZD421"))
        #expect(!device("dnssd://Zebra._ipp._tcp.local./"))
        #expect(!device("socket://localhost:9100"))
        #expect(QueueAdoption.path(ofDeviceURI: "ipp://h:631/ipp/print?x=/y#z") == "/ipp/print")
        #expect(QueueAdoption.path(ofDeviceURI: "socket://h:9100") == "")
        #expect(QueueAdoption.path(ofDeviceURI: "lpd://h/?x=1") == "/")
        #expect(QueueAdoption.path(ofDeviceURI: "/dev/null") == "")
        #expect(QueueAdoption.isLoopbackHost("::1%lo0"))
        #expect(!QueueAdoption.isLoopbackHost("128.0.0.1"))
        #expect(!QueueAdoption.isLoopbackHost("fe80::1"))
        #expect(!QueueAdoption.isLoopbackHost("::"))
        #expect(!QueueAdoption.isLoopbackHost("localhost-printer.local"))
        #expect(!QueueAdoption.isLoopbackHost(""))
    }

    @Test func labelWerkQueuesNeedNoAdoption() {
        #expect(decide("socket://10.62.13.19:9100", isLabelWerk: true) == .labelWerk(printerID: "zd421"))
        #expect(decide("ipp://10.62.13.19/ipp/print", makeAndModel: "Zebra ZD421t (203 dpi) - LabelWerk")
                == .labelWerk(printerID: "zd421"))
        // Eine LabelWerk-Warteschlange eines anderen Hosts gehört zu keinem Drucker.
        #expect(decide("socket://10.0.0.5:9100", isLabelWerk: true) == .ignore)
    }

    @Test func firstMatchingPrinterWins() {
        let duplicate = QueueAdoption.RegisteredPrinter(id: "dup", host: "10.62.13.19")
        #expect(decide("lpd://10.62.13.19/", printers: [duplicate, zd421])
                == .adopt(printerID: "dup", deviceURI: "socket://10.62.13.19:9100"))
    }

    @Test func endpointParsing() {
        #expect(QueueAdoption.endpoint(ofDeviceURI: "socket://10.62.13.19:9100")
                == QueueAdoption.Endpoint(scheme: "socket", host: "10.62.13.19", port: 9100))
        #expect(QueueAdoption.endpoint(ofDeviceURI: "IPP://Printer.Local.:631/ipp/print?waitjob=false")
                == QueueAdoption.Endpoint(scheme: "ipp", host: "printer.local", port: 631))
        #expect(QueueAdoption.endpoint(ofDeviceURI: "lpd://user@[::1]/q")
                == QueueAdoption.Endpoint(scheme: "lpd", host: "::1", port: nil))
        #expect(QueueAdoption.endpoint(ofDeviceURI: "ipp://[::1/ipp") == nil)
        #expect(QueueAdoption.endpoint(ofDeviceURI: "socket://") == nil)
        #expect(QueueAdoption.endpoint(ofDeviceURI: "/dev/null") == nil)
        #expect(QueueAdoption.normalizedHost(" ZD421.local. ") == "zd421.local")
        #expect(QueueAdoption.normalizedHost("[]") == nil)
    }

    @Test func printersConnectedThroughAQueueUseItsHost() {
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "socket://10.62.13.19:6101")
                == QueueAdoption.RegisteredPrinter(id: "q", host: "10.62.13.19", port: 6101))
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "socket://10.62.13.19")
                == QueueAdoption.RegisteredPrinter(id: "q", host: "10.62.13.19", port: 9100))
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "ipp://ZD421.local:631/ipp/print")
                == QueueAdoption.RegisteredPrinter(id: "q", host: "zd421.local", port: 9100))
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "usb://Zebra%20Technologies/ZTC%20ZD421") == nil)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "dnssd://Zebra._ipp._tcp.local./") == nil)
        // Über die Freigabe eines Druckservers: dessen Host ist nicht der Drucker.
        #expect(QueueAdoption.registeredPrinter(id: "q",
                                                queueDeviceURI: "ipp://printserver.firma.local/printers/Zebra_ZD421") == nil)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "http://winsrv:631/printers/Zebra/.printer") == nil)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "lpd://winsrv/Zebra") == nil)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "ipp://localhost:631/printers/Zebra") == nil)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "socket://127.0.0.1:9100") == nil)
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "ipps://ZD421.local/ipp/print")
                == QueueAdoption.RegisteredPrinter(id: "q", host: "zd421.local", port: 9100))
        #expect(QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "lpd://10.62.13.19")
                == QueueAdoption.RegisteredPrinter(id: "q", host: "10.62.13.19", port: 9100))
        // Eine zweite Warteschlange desselben Geräts wird dann übernommen.
        let viaQueue = QueueAdoption.registeredPrinter(id: "q", queueDeviceURI: "lpd://10.62.13.19/")!
        #expect(decide("ipp://10.62.13.19/ipp/print", printers: [viaQueue])
                == .adopt(printerID: "q", deviceURI: "socket://10.62.13.19:9100"))
    }

    @Test func addressNames() {
        #expect(QueueAdoption.isAddressName("10.62.13.19"))
        #expect(QueueAdoption.isAddressName(" 10.62.13.19:9100 "))
        #expect(QueueAdoption.isAddressName("fe80::1%en0"))
        #expect(QueueAdoption.isAddressName("[2001:db8::7]:9100"))
        #expect(QueueAdoption.isAddressName("ZD421-Lager.local", host: "zd421-lager.local."))
        #expect(QueueAdoption.isAddressName("zd421-lager.local:9100", host: "ZD421-Lager.local"))
        #expect(!QueueAdoption.isAddressName("ZD421-Lager.local"))
        #expect(!QueueAdoption.isAddressName("Zebra ZD421t"))
        #expect(!QueueAdoption.isAddressName("Zebra ZD421t", host: "10.62.13.19"))
        #expect(!QueueAdoption.isAddressName("Lager/10.62.13.19", host: "10.62.13.19"))
        #expect(!QueueAdoption.isAddressName("10.62.13"))
        #expect(!QueueAdoption.isAddressName("10.62.13.256"))
        #expect(!QueueAdoption.isAddressName("Kasse:1"))
        #expect(!QueueAdoption.isAddressName(""))
    }

    @Test func descriptionOfAdoptedQueues() {
        func description(_ name: String, model: String? = "Zebra ZD421t", queue: String = "10.62.13.19",
                         other: Bool = false) -> String {
            QueueAdoption.queueDescription(printerName: name, modelName: model, host: "10.62.13.19", queueName: queue,
                                           printerHasOtherQueue: other)
        }
        // Der Druckdialog zeigt den Namen aus LabelWerk statt der Adresse.
        #expect(description("Zebra ZD421t") == "Zebra ZD421t")
        #expect(description("Versand") == "Versand")
        // Heißt der Drucker selbst nur „10.62.13.19“, gilt das Modell.
        #expect(description("10.62.13.19") == "Zebra ZD421t")
        #expect(description(" ") == "Zebra ZD421t")
        #expect(description("10.62.13.19", model: nil) == "10.62.13.19")
        #expect(description("", model: nil) == "10.62.13.19")
        // Neben der eigenen LabelWerk-Warteschlange (gleicher Name im Druckdialog) unterscheidbar.
        #expect(description("Zebra ZD421t", other: true) == "Zebra ZD421t (10.62.13.19)")
        #expect(description("Zebra ZD421t", queue: "zebra zd421t", other: true) == "Zebra ZD421t")
    }

    @Test func socketURIs() {
        #expect(QueueAdoption.socketURI(host: "10.62.13.19", port: 9100) == "socket://10.62.13.19:9100")
        #expect(QueueAdoption.socketURI(host: "fe80::1%en0", port: 9100) == "socket://[fe80::1%25en0]:9100")
        #expect(QueueAdoption.socketURI(host: "[fe80::1%25en0]", port: 9100) == "socket://[fe80::1%25en0]:9100")
        #expect(QueueAdoption.socketURI(host: "zd421.local", port: 6101) == "socket://zd421.local:6101")
    }
}

import Foundation
import Testing
@testable import LabelWerkCore

/// SF Symbols, die in SF Symbols 5 (macOS 14) sicher vorhanden sind.
private let knownSFSymbols: Set<String> = [
    "list.bullet.rectangle.portrait", "network", "ruler", "waveform.path.ecg", "arrow.down.to.line",
    "pause.circle", "play.circle", "xmark.bin", "xmark.circle", "power", "arrow.counterclockwise.circle",
    "wifi.exclamationmark", "square.and.arrow.down", "checkmark.seal", "folder", "doc.text", "playpause",
    "wrench.and.screwdriver",
]

private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

@Suite("Gerätebefehle (PrinterAction)")
struct PrinterActionTests {
    @Test("Alle Fälle mit Metadaten")
    func metadata() {
        #expect(PrinterAction.allCases.count == 15)
        #expect(Set(PrinterAction.allCases.map(\.id)).count == 15)
        for action in PrinterAction.allCases {
            #expect(action.id == action.rawValue)
            #expect(!action.displayName.isEmpty)
            #expect(action.detail.hasSuffix("."), "\(action)")
            #expect(action.detail.count > 20)
            #expect(knownSFSymbols.contains(action.systemImage), "\(action.systemImage)")
            #expect(knownSFSymbols.contains(action.group.systemImage))
        }
        #expect(Set(PrinterAction.allCases.map(\.displayName)).count == 15)
    }

    @Test("Destruktive Aktionen")
    func destructive() {
        let destructive = Set(PrinterAction.allCases.filter(\.isDestructive))
        #expect(destructive == [.reset, .restoreFactoryDefaults, .restoreNetworkDefaults, .cancelAll])
        #expect(Set(PrinterAction.allCases.filter(\.restartsPrinter)) == [.reset, .restoreNetworkDefaults])
        #expect(PrinterAction.printTestLabel.consumesMedia)
        #expect(!PrinterAction.pause.consumesMedia)
    }

    @Test("Gruppen decken alle Aktionen genau einmal ab")
    func groups() {
        let grouped = PrinterAction.Group.allCases.flatMap(\.actions)
        #expect(grouped.count == PrinterAction.allCases.count)
        #expect(Set(grouped) == Set(PrinterAction.allCases))
        #expect(PrinterAction.Group.allCases.allSatisfy { !$0.displayName.isEmpty && $0.id == $0.rawValue })
    }

    @Test("~JX wird nicht als Abbruch des laufenden Drucks beschrieben")
    func cancelCurrentDescribesJX() {
        // Regression: ~JX verwirft laut ZPL-II-Handbuch nur ein teilweise empfangenes Format und
        // berührt laufende Drucke nicht – der Text versprach früher „Aktuellen Auftrag abbrechen“.
        let action = PrinterAction.cancelCurrent
        #expect(String(decoding: action.payload(language: .zpl) ?? Data(), as: UTF8.self) == "~JX\n")
        #expect(action.displayName == "Unvollständiges Format verwerfen")
        #expect(action.detail.contains("teilweise empfangenes Format"))
        #expect(!action.displayName.contains("Auftrag abbrechen"))
        #expect(!action.detail.contains("gerade gedruckt"))
        // Der Hinweis nennt die Aktion, die einen laufenden Druck tatsächlich stoppt (~JA).
        #expect(action.detail.contains("„\(PrinterAction.cancelAll.displayName)“"))
        #expect(String(decoding: PrinterAction.cancelAll.payload(language: .zpl) ?? Data(), as: UTF8.self) == "~JA\n")
        #expect(PrinterAction.cancelAll.detail.contains("laufenden Druck"))
        #expect(action.systemImage != "stop.circle")
    }

    @Test("Codable-Rundreise")
    func codable() throws {
        let data = try JSONEncoder().encode(PrinterAction.allCases)
        let decoded = try JSONDecoder().decode([PrinterAction].self, from: data)
        #expect(decoded == PrinterAction.allCases)
        #expect(String(decoding: try JSONEncoder().encode(PrinterAction.calibrate), as: UTF8.self) == "\"calibrate\"")
    }

    @Test("ZPL-Befehle")
    func zplPayloads() {
        let expected: [PrinterAction: String] = [
            .printConfiguration: "~WC\n",
            .printNetworkConfiguration: "~WL\n",
            .calibrate: "~JC\n",
            .sensorProfile: "~JG\n",
            .feedLabel: "~PH\n",
            .pause: "~PP\n",
            .resume: "~PS\n",
            .cancelAll: "~JA\n",
            .cancelCurrent: "~JX\n",
            .reset: "~JR\n",
            .restoreFactoryDefaults: "^XA^JUF^XZ\n^XA^JUS^XZ\n",
            .restoreNetworkDefaults: "^XA^JUN^XZ\n^XA^JUS^XZ\n~JR\n",
            .saveSettings: "^XA^JUS^XZ\n",
            .printDirectory: "^XA^WDE:*.*^XZ\n",
        ]
        for (action, zpl) in expected {
            #expect(text(action.payload(language: .zpl)) == zpl, "\(action)")
        }
        let label = text(PrinterAction.printTestLabel.payload(language: .zpl, resolution: .dpi300, widthDots: 1200, heightDots: 900))
        #expect(label?.hasPrefix("^XA\n") == true)
        #expect(label?.hasSuffix("^XZ\n") == true)
        #expect(label?.contains("^PW1200\n^LL900\n") == true)
        #expect(label?.contains("300 dpi") == true)
    }

    @Test("EPL-Befehle")
    func eplPayloads() throws {
        #expect(text(PrinterAction.printConfiguration.payload(language: .epl)) == "U\n")
        #expect(text(PrinterAction.calibrate.payload(language: .epl)) == "xa\n")
        #expect(text(PrinterAction.feedLabel.payload(language: .epl)) == "\nN\nP1\n")
        #expect(text(PrinterAction.reset.payload(language: .epl)) == "^@\n")
        #expect(text(PrinterAction.restoreFactoryDefaults.payload(language: .epl)) == "^default\n")
        for action in [PrinterAction.printNetworkConfiguration, .sensorProfile, .pause, .resume, .cancelAll,
                       .cancelCurrent, .restoreNetworkDefaults, .saveSettings, .printDirectory] {
            #expect(action.payload(language: .epl) == nil, "\(action)")
        }
        let label = try #require(PrinterAction.printTestLabel.payload(language: .epl, widthDots: 812, heightDots: 1218))
        #expect(label.allSatisfy { $0 < 0x80 })
        #expect(text(label)?.hasPrefix("\nN\nq812\n") == true)
        #expect(text(label)?.hasSuffix("P1\n") == true)
    }

    @Test("CPCL-Befehle")
    func cpclPayloads() {
        #expect(text(PrinterAction.feedLabel.payload(language: .cpcl, widthDots: 576, heightDots: 400))
            == "! 0 200 200 400 1\r\nPAGE-WIDTH 576\r\nFORM\r\nPRINT\r\n")
        #expect(text(PrinterAction.reset.payload(language: .cpcl)) == "! U1 do \"device.reset\" \"\"\r\n")
        #expect(text(PrinterAction.restoreFactoryDefaults.payload(language: .cpcl))
            == "! U1 do \"device.restore_defaults\" \"all\"\r\n")
        #expect(text(PrinterAction.restoreNetworkDefaults.payload(language: .cpcl))
            == "! U1 do \"device.restore_defaults\" \"ip\"\r\n! U1 do \"device.restore_defaults\" \"wlan\"\r\n! U1 do \"device.reset\" \"\"\r\n")
        for action in [PrinterAction.printConfiguration, .printNetworkConfiguration, .calibrate, .sensorProfile,
                       .pause, .resume, .cancelAll, .cancelCurrent, .saveSettings, .printDirectory] {
            #expect(action.payload(language: .cpcl) == nil, "\(action)")
        }
        let label = text(PrinterAction.printTestLabel.payload(language: .cpcl, resolution: .dpi203, widthDots: 576, heightDots: 406))
        #expect(label?.hasPrefix("! 0 200 200 406 1\r\nPAGE-WIDTH 576\r\n") == true)
        #expect(label?.hasSuffix("FORM\r\nPRINT\r\n") == true)
    }

    @Test("isSupported und supportedLanguages stimmen mit payload überein")
    func supportMatchesPayload() {
        for action in PrinterAction.allCases {
            for language in PrinterLanguage.allCases {
                let hasPayload = action.payload(language: language, widthDots: 400, heightDots: 200) != nil
                #expect(action.isSupported(language: language) == hasPayload, "\(action) \(language)")
            }
            #expect(action.supportedLanguages.contains(.zpl))
        }
        #expect(PrinterAction.printTestLabel.supportedLanguages == PrinterLanguage.allCases)
    }

    @Test("Ungültige Maße werden abgefangen")
    func invalidSizes() {
        for language in PrinterLanguage.allCases {
            let data = PrinterAction.printTestLabel.payload(language: language, widthDots: -5, heightDots: 0)
            #expect(data != nil)
        }
    }
}

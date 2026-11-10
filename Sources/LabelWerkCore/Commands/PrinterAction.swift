import Foundation

/// Gerätebefehle, wie sie die Werkzeug-Seite anbietet (entspricht „Befehle senden“ /
/// „Drucker-Werkzeuge“ des Windows-Treibers und der Zebra Setup Utilities).
public enum PrinterAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case printConfiguration
    case printNetworkConfiguration
    case calibrate
    case sensorProfile
    case feedLabel
    case pause
    case resume
    case cancelAll
    case cancelCurrent
    case reset
    case restoreFactoryDefaults
    case restoreNetworkDefaults
    case saveSettings
    case printTestLabel
    case printDirectory

    public var id: String { rawValue }

    /// Gruppierung für die Oberfläche.
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        /// Berichte und Testdrucke.
        case reports
        /// Medien und Sensoren.
        case media
        /// Auftragssteuerung.
        case control
        /// Wartung und Werkseinstellungen.
        case maintenance

        public var id: String { rawValue }

        /// Deutscher Anzeigename.
        public var displayName: String {
            switch self {
            case .reports: return "Berichte & Testdrucke"
            case .media: return "Medien & Sensoren"
            case .control: return "Auftragssteuerung"
            case .maintenance: return "Wartung"
            }
        }

        /// SF Symbol der Gruppe.
        public var systemImage: String {
            switch self {
            case .reports: return "doc.text"
            case .media: return "ruler"
            case .control: return "playpause"
            case .maintenance: return "wrench.and.screwdriver"
            }
        }

        /// Aktionen dieser Gruppe in Anzeigereihenfolge.
        public var actions: [PrinterAction] { PrinterAction.allCases.filter { $0.group == self } }
    }

    /// Gruppe der Aktion.
    public var group: Group {
        switch self {
        case .printConfiguration, .printNetworkConfiguration, .printTestLabel, .printDirectory: return .reports
        case .calibrate, .sensorProfile, .feedLabel: return .media
        case .pause, .resume, .cancelAll, .cancelCurrent: return .control
        case .reset, .restoreFactoryDefaults, .restoreNetworkDefaults, .saveSettings: return .maintenance
        }
    }

    /// Deutscher Anzeigename.
    public var displayName: String {
        switch self {
        case .printConfiguration: return "Konfiguration drucken"
        case .printNetworkConfiguration: return "Netzwerkkonfiguration drucken"
        case .calibrate: return "Medien kalibrieren"
        case .sensorProfile: return "Sensorprofil drucken"
        case .feedLabel: return "Etikett vorschieben"
        case .pause: return "Pausieren"
        case .resume: return "Fortsetzen"
        case .cancelAll: return "Alle Aufträge abbrechen"
        case .cancelCurrent: return "Unvollständiges Format verwerfen"
        case .reset: return "Drucker neu starten"
        case .restoreFactoryDefaults: return "Werkseinstellungen wiederherstellen"
        case .restoreNetworkDefaults: return "Netzwerkeinstellungen zurücksetzen"
        case .saveSettings: return "Einstellungen dauerhaft speichern"
        case .printTestLabel: return "Testetikett drucken"
        case .printDirectory: return "Dateiliste drucken"
        }
    }

    /// Deutsche Kurzbeschreibung (ein Satz).
    public var detail: String {
        switch self {
        case .printConfiguration:
            return "Druckt ein Etikett mit allen aktuellen Einstellungen, Zählerständen und der Firmware-Version."
        case .printNetworkConfiguration:
            return "Druckt die Netzwerkeinstellungen mit IP-Adresse, WLAN-Status und MAC-Adresse."
        case .calibrate:
            return "Misst Etikettenlänge und Lücke neu und stellt Medien- und Farbbandsensor ein."
        case .sensorProfile:
            return "Kalibriert die Sensoren und druckt das Sensorprofil zur Fehlersuche bei der Etikettenerkennung."
        case .feedLabel:
            return "Schiebt ein leeres Etikett bis zur nächsten Abreißposition vor."
        case .pause:
            return "Hält den Druck nach dem aktuellen Etikett an, bis er fortgesetzt wird."
        case .resume:
            return "Setzt einen angehaltenen Druck fort."
        case .cancelAll:
            return "Stoppt den laufenden Druck nach dem aktuellen Etikett und löscht alle Aufträge im Speicher des Druckers."
        case .cancelCurrent:
            // ~JX wirkt laut ZPL-II-Handbuch nur auf ein Format, das noch übertragen wird – nicht
            // auf laufende Drucke. Der Text muss das sagen und auf „Alle Aufträge abbrechen“ verweisen.
            return "Verwirft ein nur teilweise empfangenes Format; einen laufenden Druck stoppt „Alle Aufträge abbrechen“."
        case .reset:
            return "Startet den Drucker neu, als würde er aus- und wieder eingeschaltet."
        case .restoreFactoryDefaults:
            return "Setzt alle Druckereinstellungen dauerhaft auf den Auslieferungszustand zurück."
        case .restoreNetworkDefaults:
            return "Setzt IP-, WLAN- und Netzwerkeinstellungen zurück; der Drucker startet anschließend neu."
        case .saveSettings:
            return "Speichert die aktuellen Einstellungen, damit sie auch nach dem Ausschalten erhalten bleiben."
        case .printTestLabel:
            return "Druckt ein Testetikett mit Rahmen, Barcodes, Schwärzungsskala und Millimeterlineal."
        case .printDirectory:
            return "Druckt eine Liste aller Schriften, Grafiken und Formate im Druckerspeicher."
        }
    }

    /// SF Symbol (SF Symbols 5, macOS 14).
    public var systemImage: String {
        switch self {
        case .printConfiguration: return "list.bullet.rectangle.portrait"
        case .printNetworkConfiguration: return "network"
        case .calibrate: return "ruler"
        case .sensorProfile: return "waveform.path.ecg"
        case .feedLabel: return "arrow.down.to.line"
        case .pause: return "pause.circle"
        case .resume: return "play.circle"
        case .cancelAll: return "xmark.bin"
        case .cancelCurrent: return "xmark.circle"
        case .reset: return "power"
        case .restoreFactoryDefaults: return "arrow.counterclockwise.circle"
        case .restoreNetworkDefaults: return "wifi.exclamationmark"
        case .saveSettings: return "square.and.arrow.down"
        case .printTestLabel: return "checkmark.seal"
        case .printDirectory: return "folder"
        }
    }

    /// `true`, wenn die Aktion Daten oder Einstellungen verwirft bzw. die Verbindung trennt
    /// (die Oberfläche fragt dann nach einer Bestätigung).
    public var isDestructive: Bool {
        switch self {
        case .reset, .restoreFactoryDefaults, .restoreNetworkDefaults, .cancelAll: return true
        default: return false
        }
    }

    /// `true`, wenn der Drucker nach der Aktion neu startet (Verbindung geht verloren).
    public var restartsPrinter: Bool {
        switch self {
        case .reset, .restoreNetworkDefaults: return true
        default: return false
        }
    }

    /// `true`, wenn die Aktion Etikettenmaterial verbraucht.
    public var consumesMedia: Bool {
        switch self {
        case .printConfiguration, .printNetworkConfiguration, .calibrate, .sensorProfile, .feedLabel,
             .printTestLabel, .printDirectory:
            return true
        default:
            return false
        }
    }

    /// Sprachen, für die es einen Befehl gibt.
    public var supportedLanguages: [PrinterLanguage] {
        PrinterLanguage.allCases.filter { isSupported(language: $0) }
    }

    /// `true`, wenn ``payload(language:resolution:widthDots:heightDots:)`` für die Sprache Daten liefert.
    public func isSupported(language: PrinterLanguage) -> Bool {
        switch language {
        case .zpl:
            return true
        case .epl:
            switch self {
            case .printConfiguration, .calibrate, .feedLabel, .reset, .restoreFactoryDefaults, .printTestLabel:
                return true
            default:
                return false
            }
        case .cpcl:
            switch self {
            case .feedLabel, .reset, .restoreFactoryDefaults, .restoreNetworkDefaults, .printTestLabel:
                return true
            default:
                return false
            }
        }
    }

    /// Befehlsdaten für die Druckersprache; `nil`, wenn die Sprache keine Entsprechung kennt.
    ///
    /// - Parameters:
    ///   - resolution: Auflösung (für das Testetikett und CPCL-Kopfzeilen).
    ///   - widthDots: Etikettenbreite in Punkten (Testetikett, EPL `q`, CPCL `PAGE-WIDTH`).
    ///   - heightDots: Etikettenlänge in Punkten (Testetikett, CPCL-Vorschub).
    public func payload(language: PrinterLanguage, resolution: Resolution = .dpi203,
                        widthDots: Int = 812, heightDots: Int = 1218) -> Data? {
        let width = max(16, widthDots)
        let height = max(16, heightDots)
        switch language {
        case .zpl:
            return Data(zplPayload(resolution: resolution, width: width, height: height).utf8)
        case .epl:
            return eplPayload(resolution: resolution, width: width, height: height).map(EPL.encode)
        case .cpcl:
            return cpclPayload(resolution: resolution, width: width, height: height).map { Data($0.utf8) }
        }
    }

    // MARK: - ZPL

    private func zplPayload(resolution: Resolution, width: Int, height: Int) -> String {
        func line(_ command: ZPLCommand) -> String { command.description + "\n" }
        switch self {
        case .printConfiguration: return line(ZPL.printConfiguration())
        case .printNetworkConfiguration: return line(ZPL.printNetworkConfiguration())
        case .calibrate: return line(ZPL.calibrate())
        case .sensorProfile: return line(ZPL.sensorProfile())
        case .feedLabel: return line(ZPL.feed())
        case .pause: return line(ZPL.pause())
        case .resume: return line(ZPL.resume())
        case .cancelAll: return line(ZPL.cancelAll())
        case .cancelCurrent: return line(ZPL.cancelCurrent())
        case .reset: return line(ZPL.reset())
        case .restoreFactoryDefaults:
            // ^JUF lädt die Werkseinstellungen, ^JUS macht sie dauerhaft.
            return "^XA^JUF^XZ\n^XA^JUS^XZ\n"
        case .restoreNetworkDefaults:
            // ^JUN lädt die Netzwerk-Werkseinstellungen, ^JUS speichert, ~JR aktiviert sie.
            return "^XA^JUN^XZ\n^XA^JUS^XZ\n~JR\n"
        case .saveSettings: return "^XA^JUS^XZ\n"
        case .printTestLabel:
            return TestLabel.zpl(widthDots: width, heightDots: height, resolution: resolution)
        case .printDirectory: return ZPL.printDirectory("E:*.*") + "\n"
        }
    }

    // MARK: - EPL

    private func eplPayload(resolution: Resolution, width: Int, height: Int) -> String? {
        switch self {
        case .printConfiguration: return EPL.render([EPL.printConfiguration()])
        case .calibrate: return EPL.render([EPL.autoSense()])
        case .feedLabel:
            // EPL kennt keinen Vorschubbefehl – ein leeres Etikett erfüllt denselben Zweck.
            return EPL.label { }
        case .reset: return EPL.render([EPL.reset()])
        case .restoreFactoryDefaults: return EPL.render([EPL.factoryDefaults()])
        case .printTestLabel:
            return TestLabel.epl(widthDots: width, heightDots: height, resolution: resolution)
        case .printNetworkConfiguration, .sensorProfile, .pause, .resume, .cancelAll, .cancelCurrent,
             .restoreNetworkDefaults, .saveSettings, .printDirectory:
            // EPL speichert Einstellungen automatisch und kennt keine entsprechenden Befehle.
            return nil
        }
    }

    // MARK: - CPCL

    private func cpclPayload(resolution: Resolution, width: Int, height: Int) -> String? {
        switch self {
        case .feedLabel:
            // Leeres Etikett mit FORM: schiebt bis zum nächsten Etikettenanfang vor.
            return CPCL.label(height: height, resolution: resolution) { CPCL.pageWidth(width) }
        case .reset:
            return SGD.reset()
        case .restoreFactoryDefaults:
            return SGD.restoreDefaults(.all)
        case .restoreNetworkDefaults:
            return SGD.restoreDefaults(.ip) + SGD.restoreDefaults(.wlan) + SGD.reset()
        case .printTestLabel:
            return TestLabel.cpcl(widthDots: width, heightDots: height, resolution: resolution)
        case .printConfiguration, .printNetworkConfiguration, .calibrate, .sensorProfile, .pause, .resume,
             .cancelAll, .cancelCurrent, .saveSettings, .printDirectory:
            return nil
        }
    }
}

import Foundation

// MARK: - Zustand

/// Gesamtzustand eines Druckers, wie ihn Oberfläche und Menüleiste anzeigen.
public enum PrinterState: String, Codable, Sendable, CaseIterable {
    /// Bereit, keine Meldungen.
    case ready
    /// Druckt bzw. verarbeitet Formate.
    case printing
    /// Pausiert (Taste oder `~PP`).
    case paused
    /// Druckbereit, aber mit Warnungen (z. B. Druckkopf reinigen).
    case warning
    /// Mindestens ein Fehler verhindert das Drucken.
    case error
    /// Keine Verbindung.
    case offline
    /// Noch kein Status bekannt.
    case unknown
}

// MARK: - Schweregrad

/// Schweregrad einer Meldung; Vergleich nach Dringlichkeit (`info < warning < error`).
public enum AlertSeverity: Int, Codable, Sendable, Comparable, CaseIterable {
    case info
    case warning
    case error

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Art der Meldung

/// Alle Meldungen, die LabelWerk aus Druckerantworten ableitet.
public enum AlertKind: String, Codable, Sendable, CaseIterable {
    case mediaOut
    case ribbonOut
    case headOpen
    case paused
    case cutterFault
    case headOverTemperature
    case motorOverTemperature
    case badPrintheadElement
    case printheadDetectionError
    case receiveBufferFull
    case underTemperature
    case overTemperature
    case corruptRAM
    case needsCalibration
    case cleanPrinthead
    case replacePrinthead
    case mediaNearEnd
    case labelWaitingToBePeeled
    case paperFeedError
    case blackMarkNotFound
    case invalidFirmwareConfig
    case offline

    /// Schweregrad, mit dem ``PrinterAlert/make(_:)`` die Meldung erzeugt.
    public var defaultSeverity: AlertSeverity { PrinterAlert.catalog(self).severity }

    /// Position in ``allCases`` – stabiler Sortierschlüssel bei gleichem Schweregrad.
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

// MARK: - Meldung

/// Eine Druckermeldung mit deutschem Titel, konkreter Handlungsanweisung und SF-Symbol.
public struct PrinterAlert: Hashable, Codable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: AlertKind
    public var severity: AlertSeverity
    /// Kurzer Titel (Deutsch).
    public var title: String
    /// Konkrete Handlungsanweisung (Deutsch).
    public var recovery: String
    /// Name eines SF Symbols (verfügbar ab SF Symbols 5 / macOS 14).
    public var systemImage: String

    public init(kind: AlertKind, severity: AlertSeverity, title: String, recovery: String, systemImage: String) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.recovery = recovery
        self.systemImage = systemImage
    }

    /// Erzeugt die Standardmeldung für eine Meldungsart.
    public static func make(_ kind: AlertKind) -> PrinterAlert {
        let entry = catalog(kind)
        return PrinterAlert(kind: kind, severity: entry.severity, title: entry.title,
                            recovery: entry.recovery, systemImage: entry.systemImage)
    }

    /// Sortiert nach Schweregrad (Fehler zuerst), bei Gleichstand in ``AlertKind``-Reihenfolge.
    public static func sorted(_ alerts: [PrinterAlert]) -> [PrinterAlert] {
        alerts.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.kind.sortIndex < rhs.kind.sortIndex
        }
    }

    /// Inhalte aller Meldungen.
    static func catalog(_ kind: AlertKind)
        -> (severity: AlertSeverity, title: String, recovery: String, systemImage: String) {
        switch kind {
        case .mediaOut:
            return (.error, "Etiketten leer",
                    "Abdeckung öffnen, eine neue Etikettenrolle einlegen und das Material unter den Führungen "
                    + "bis über die Abreißkante ziehen. Abdeckung schließen und die Vorschubtaste (FEED) drücken; "
                    + "bei anderem Material anschließend kalibrieren.",
                    "tray")
        case .ribbonOut:
            return (.error, "Farbband leer",
                    "Druckkopf öffnen, die leere Farbbandrolle entnehmen und eine neue Rolle mit der beschichteten "
                    + "Seite zum Etikett einlegen; den Anfang an der Aufwickelspindel befestigen. Druckkopf schließen. "
                    + "Für Druck ohne Farbband in den Einstellungen „Thermodirekt“ wählen.",
                    "film")
        case .headOpen:
            return (.error, "Druckkopf offen",
                    "Druckkopf bzw. Abdeckung schließen und hörbar einrasten lassen. Dabei prüfen, dass Etiketten "
                    + "und Farbband glatt unter dem Druckkopf liegen.",
                    "lock.open.fill")
        case .paused:
            return (.info, "Drucker pausiert",
                    "Die Pause-Taste am Drucker drücken oder in LabelWerk „Fortsetzen“ wählen. "
                    + "Wartende Aufträge werden danach automatisch gedruckt.",
                    "pause.circle.fill")
        case .cutterFault:
            return (.error, "Schneidwerk blockiert",
                    "Drucker ausschalten, das Schneidwerk auf eingeklemmtes Material prüfen und Reste vorsichtig "
                    + "entfernen, ohne die Klinge zu berühren. Klebereste mit Isopropanol entfernen und den Drucker "
                    + "wieder einschalten.",
                    "scissors")
        case .headOverTemperature:
            return (.error, "Druckkopf überhitzt",
                    "Der Druck wird angehalten, bis der Druckkopf abgekühlt ist. Drucker einige Minuten ruhen lassen "
                    + "und danach Schwärzung oder Druckgeschwindigkeit reduzieren.",
                    "thermometer.high")
        case .motorOverTemperature:
            return (.error, "Motor überhitzt",
                    "Drucker ausschalten und mindestens 10 Minuten abkühlen lassen. Lüftungsschlitze freihalten und "
                    + "bei Dauerbetrieb die Druckgeschwindigkeit senken.",
                    "flame.fill")
        case .badPrintheadElement:
            return (.warning, "Defektes Druckkopfelement",
                    "Einzelne Heizpunkte drucken nicht (weiße Linien in Vorschubrichtung). Druckkopf mit einem "
                    + "Reinigungsstift reinigen; bleiben die Linien, den Druckkopf ersetzen. Barcodes bis dahin im "
                    + "Leiterformat (um 90° gedreht) drucken.",
                    "rectangle.dashed")
        case .printheadDetectionError:
            return (.error, "Druckkopf nicht erkannt",
                    "Drucker ausschalten, Druckkopfkabel und -stecker auf festen Sitz prüfen und den Druckkopf "
                    + "korrekt einrasten lassen. Drucker wieder einschalten; bleibt der Fehler, den Service "
                    + "kontaktieren.",
                    "questionmark.square.dashed")
        case .receiveBufferFull:
            return (.warning, "Empfangspuffer voll",
                    "Der Drucker nimmt vorübergehend keine Daten an. Warten, bis laufende Aufträge gedruckt sind, "
                    + "oder „Aufträge abbrechen“ wählen und große Grafiken komprimiert (Z64) senden.",
                    "tray.full.fill")
        case .underTemperature:
            return (.warning, "Druckkopf zu kalt",
                    "Der Drucker ist kälter als seine Betriebstemperatur. In eine wärmere Umgebung (über 5 °C) "
                    + "bringen und vor dem Drucken einige Minuten akklimatisieren lassen.",
                    "thermometer.snowflake")
        case .overTemperature:
            return (.error, "Druckkopf zu heiß",
                    "Die Druckkopftemperatur liegt über dem Betriebsbereich. Drucker abkühlen lassen, die Schwärzung "
                    + "(Darkness) reduzieren und für ausreichende Belüftung sorgen.",
                    "thermometer.sun.fill")
        case .corruptRAM:
            return (.warning, "Konfiguration verloren",
                    "Der Drucker hat seine gespeicherte Konfiguration verloren und Standardwerte geladen. "
                    + "Einstellungen in LabelWerk prüfen, erneut übertragen und mit „Einstellungen speichern“ "
                    + "dauerhaft sichern.",
                    "memorychip")
        case .needsCalibration:
            return (.warning, "Kalibrierung erforderlich",
                    "Etiketten korrekt einlegen und in LabelWerk „Kalibrieren“ wählen oder die Kalibrierung am "
                    + "Bedienfeld starten. Danach eine Testseite drucken.",
                    "ruler")
        case .cleanPrinthead:
            return (.warning, "Druckkopf reinigen",
                    "Drucker ausschalten, Druckkopf öffnen und die Heizzeile mit einem Reinigungsstift oder einem mit "
                    + "Isopropanol (mind. 99 %) befeuchteten Tuch von der Mitte nach außen abwischen. "
                    + "Eine Minute trocknen lassen und schließen.",
                    "sparkles")
        case .replacePrinthead:
            return (.warning, "Druckkopf ersetzen",
                    "Der Druckkopf hat das Ende seiner Lebensdauer erreicht. Einen zu Modell und Auflösung passenden "
                    + "Ersatzdruckkopf einbauen und danach den Druckkopfzähler zurücksetzen.",
                    "wrench.and.screwdriver.fill")
        case .mediaNearEnd:
            return (.warning, "Etiketten fast leer",
                    "Eine neue Etikettenrolle bereitlegen und nach dem aktuellen Auftrag einlegen.",
                    "gauge.with.dots.needle.33percent")
        case .labelWaitingToBePeeled:
            return (.info, "Etikett entnehmen",
                    "Im Spendemodus wartet ein Etikett an der Spendekante. Etikett abnehmen – "
                    + "der nächste Druck startet danach automatisch.",
                    "hand.tap.fill")
        case .paperFeedError:
            return (.error, "Papiervorschubfehler",
                    "Papierweg auf Stau oder schräg eingelegtes Material prüfen, Material neu einlegen, die "
                    + "Führungen an die Etikettenbreite anpassen und anschließend kalibrieren.",
                    "exclamationmark.arrow.circlepath")
        case .blackMarkNotFound:
            return (.error, "Schwarze Markierung nicht gefunden",
                    "Prüfen, ob das Material schwarze Markierungen auf der Rückseite hat und der Sensor darüber "
                    + "steht. Andernfalls die Medienerkennung auf „Etiketten mit Lücke“ umstellen und kalibrieren.",
                    "viewfinder")
        case .invalidFirmwareConfig:
            return (.error, "Ungültige Firmware-Konfiguration",
                    "Drucker aus- und wieder einschalten. Bleibt der Fehler bestehen, die passende Firmware in "
                    + "LabelWerk unter „Firmware“ erneut übertragen.",
                    "gearshape.fill")
        case .offline:
            return (.error, "Drucker nicht erreichbar",
                    "Prüfen, ob der Drucker eingeschaltet und verbunden ist (USB-Kabel, Netzwerk oder "
                    + "Bluetooth-Kopplung), und danach „Neu verbinden“ wählen.",
                    "wifi.slash")
        }
    }
}

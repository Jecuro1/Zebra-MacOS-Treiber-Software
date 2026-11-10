import Foundation

/// Standardwerte einer LabelWerk-Warteschlange: Abbildung der Einstellungen auf `lpadmin`-Argumente
/// (``plan(settings:language:removingStale:resolution:labelSize:)``) und Vergleich mit dem Stand,
/// den `lpoptions` meldet (``difference(_:current:pageSizeChoices:)``) – gemeinsam für App und
/// `lwctl`, unter Linux getestet. ARCHITECTURE.md §9.
public enum QueueDefaults {

    // MARK: Optionen der Etikettengröße

    /// Etikettenbreite der Warteschlange in 1/100 mm (0 = unbekannt), Warteschlangen-Standard
    /// `lwLabelWidth-default` – der Filter passt Seiten anderer Größe an dieses Etikett an (§8).
    public static let labelWidthOption = CUPSOptionName.labelWidth
    /// Etikettenhöhe der Warteschlange in 1/100 mm (0 = unbekannt), `lwLabelHeight-default`.
    public static let labelHeightOption = CUPSOptionName.labelHeight
    /// PPD-Option „An Etikett anpassen“ (`Auto` | `Off`).
    public static let fitToLabelOption = CUPSOptionName.fitToLabel
    /// Standard-PPD-Option der Seitengröße.
    public static let pageSizeOption = "PageSize"

    // MARK: Auswahlwerte der PPD

    /// Auswahlwerte der ganzzahligen PPD-Optionen (Driver/ppd/README.md). `lpadmin -o name=wert`
    /// übernimmt nur PPD-Schlüsselwörter mit einem Wert aus ihrer Auswahl – andere Werte verwirft es
    /// stillschweigend.
    public static let ppdIntegerChoices: [String: [Int]] = [
        CUPSOptionName.darkness: Array(1...30),
        CUPSOptionName.labelTop: Array(stride(from: -120, through: 120, by: 10)),
        CUPSOptionName.tearOff: Array(stride(from: -120, through: 120, by: 10)),
        CUPSOptionName.labelLeft: Array(stride(from: -200, through: 200, by: 10)),
        CUPSOptionName.threshold: [64, 96, 128, 160, 192],
        CUPSOptionName.cutEvery: [0, 1, 2, 5, 10, 25, 50, 100],
        CUPSOptionName.pauseEvery: [0, 1, 2, 5, 10, 25, 50, 100],
        CUPSOptionName.cancelDelay: [0, 250, 500, 1000, 2000, 3000, 5000, 10000],
    ]

    /// Ganzzahlige PPD-Optionen, deren Auswahl Millimeter in Punkten der Auflösung sind
    /// (Driver/ppd/generate_ppds.py: `MARK_OFFSET_MM`, `STOP_OFFSET_MM`).
    public static let ppdMillimetreChoices: [String: (millimetres: [Int], range: ClosedRange<Int>)] = [
        CUPSOptionName.markOffset: ([-10, -5, -3, -2, -1, 0, 1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 35], -80...283),
        CUPSOptionName.stopOffset: ([0, 1, 2, 3, 5, 10], 0...32_000),
    ]

    /// Auswahl einer ganzzahligen PPD-Option für die Auflösung (`nil` = keine Ganzzahl-Option bzw.
    /// Auflösung unbekannt bei auflösungsabhängigen Optionen).
    public static func ppdChoices(_ name: String, resolution: Resolution?) -> [Int]? {
        if let fixed = ppdIntegerChoices[name] { return fixed }
        guard let resolution, let spec = ppdMillimetreChoices[name] else { return nil }
        var seen = Set<Int>()
        return spec.millimetres.compactMap { mm -> Int? in
            let dots = resolution.dots(fromMM: Double(mm))
            guard spec.range.contains(dots), seen.insert(dots).inserted else { return nil }
            return dots
        }
    }

    /// Optionen ohne PPD-Eintrag (freie Base64url-Werte, eigene Steuerzeichen, das veraltete
    /// `lwRotate180` und die Etikettengröße `lwLabelWidth`/`lwLabelHeight`): nur als
    /// Warteschlangen-Standard (`-o name-default=…`) möglich.
    public static var queueOnlyOptions: Set<String> {
        Set(CUPSOptionName.nonPPD).union([labelWidthOption, labelHeightOption])
    }

    // MARK: Plan

    /// `lpadmin`-Argumente für die Standardwerte und die danach erwarteten Werte.
    public struct Plan: Equatable, Sendable {
        public var arguments: [String] = []
        /// Erwarteter Wert je Option (wie ihn `lpoptions` liefert); enthält `PageSize`, wenn eine
        /// Etikettengröße angegeben ist.
        public var expected: [String: String] = [:]
        /// Optionen, die als Warteschlangen-Standard (`name-default`) gesetzt werden.
        public var queueDefaults: Set<String> = []
        /// Optionen, die nicht gesetzt sein dürfen (leere Start-/Endbefehle, unbekannte Größe).
        public var cleared: Set<String> = []
        /// Optionen außerhalb der PPD-Auswahl (Druckdialoge zeigen den nächstliegenden Wert).
        public var approximated: [String] = []

        public init() {}
    }

    /// Bildet Einstellungen auf `lpadmin`-Argumente ab:
    /// * PPD-Optionen mit einem Wert aus der PPD-Auswahl: `-o name=wert` (Standard in der PPD).
    /// * Ganzzahlen außerhalb der Auswahl: nächstliegende Wahl in der PPD **und** exakter Wert als
    ///   Warteschlangen-Standard `-o name-default=wert` – cupsd gibt ihn jedem Auftrag mit, der die
    ///   Option nicht selbst setzt, sodass er in `argv[5]` des Filters ankommt.
    /// * Optionen ohne PPD-Eintrag (``queueOnlyOptions``): `-o name-default=…`, nicht gesetzt
    ///   `-R name-default`.
    /// * Etikettengröße (`labelSize`): `-o PageSize=<schlüsselwort>`. `lwLabelWidth`/`lwLabelHeight`
    ///   (1/100 mm) kommen aus den Einstellungen (``PrintSettings/withLabelSize(of:)``: Endlosmaterial
    ///   mit Länge 0); enthalten diese keine Größe, gilt die von `labelSize`. Ohne beides werden die
    ///   Warteschlangen-Standards entfernt (unbekannt).
    ///
    /// `removingStale` entfernt nicht mehr benötigte Warteschlangen-Standards (`-R` wirkt sofort und
    /// schlägt bei einer noch nicht vorhandenen Warteschlange fehl).
    ///
    /// `resolution` bestimmt die Auswahl der Millimeter-Optionen (`lwMarkOffset`, `lwStopOffset`); ohne
    /// Auflösung werden deren Zahlenwerte stets exakt als Warteschlangen-Standard gesetzt.
    public static func plan(settings: PrintSettings, language: PrinterLanguage?, removingStale: Bool,
                            resolution: Resolution? = nil, labelSize: QueueLabelSize? = nil) -> Plan {
        var plan = Plan()
        var effective = settings
        if let labelSize, effective.labelWidthHundredthsMM <= 0 {
            effective.setLabelSize(widthMM: labelSize.widthMM, heightMM: labelSize.heightMM)
        }
        var options = effective.cupsOptions()
        if let language { options[CUPSOptionName.language] = language.cupsValue }
        let queueOnly = queueOnlyOptions
        for name in queueOnly.sorted() where options[name] == nil {
            if removingStale { plan.arguments += ["-R", "\(name)-default"] }
            plan.cleared.insert(name)
        }
        for (name, value) in options.sorted(by: { $0.key < $1.key }) {
            plan.expected[name] = value
            let dependsOnResolution = ppdMillimetreChoices[name] != nil
            if queueOnly.contains(name) {
                plan.arguments += ["-o", "\(name)-default=\(value)"]
                plan.queueDefaults.insert(name)
            } else if dependsOnResolution, resolution == nil, Int(value) != nil {
                // Auswahl der PPD unbekannt: exakter Wert als Warteschlangen-Standard.
                plan.arguments += ["-o", "\(name)-default=\(value)"]
                plan.queueDefaults.insert(name)
            } else if let choices = ppdChoices(name, resolution: resolution), !choices.isEmpty,
                      let number = Int(value), !choices.contains(number) {
                let nearest = choices.min { abs($0 - number) < abs($1 - number) } ?? number
                plan.arguments += ["-o", "\(name)=\(nearest)", "-o", "\(name)-default=\(value)"]
                plan.queueDefaults.insert(name)
                plan.approximated.append(name)
            } else {
                plan.arguments += ["-o", "\(name)=\(value)"]
                // Ein früher gesetzter exakter Wert würde die PPD-Wahl sonst überdecken.
                if removingStale, ppdIntegerChoices[name] != nil || dependsOnResolution {
                    plan.arguments += ["-R", "\(name)-default"]
                }
            }
        }
        if let labelSize {
            plan.arguments += ["-o", "\(pageSizeOption)=\(labelSize.keyword)"]
            plan.expected[pageSizeOption] = labelSize.keyword
        }
        return plan
    }

    // MARK: Vergleich

    /// Unterschied zwischen Plan und aktuellem Stand einer Warteschlange.
    public struct Difference: Equatable, Sendable {
        /// Optionen, deren Wert vom Plan abweicht (sortiert).
        public var mismatchedOptions: [String] = []
        /// Die Seitengröße des Plans fehlt in der PPD der Warteschlange – sie braucht eine
        /// (ergänzte) PPD.
        public var missingPageSize = false
        /// Die PPD enthält Seitengrößen, die weder in der Modell-PPD stehen noch gewünscht sind
        /// (eine früher ergänzte, inzwischen andere Größe) – sie braucht eine neue PPD.
        public var stalePageSizes: [String] = []

        public init() {}

        /// Muss `lpadmin -P` die PPD ersetzen?
        public var needsPPD: Bool { missingPageSize || !stalePageSizes.isEmpty }
        /// Stimmt alles?
        public var isEmpty: Bool { mismatchedOptions.isEmpty && !needsPPD }
    }

    /// Vergleicht den Plan mit dem Stand laut `lpoptions`.
    ///
    /// - Parameters:
    ///   - current: aktuelle Werte (markierte PPD-Wahl aus `lpoptions -p <queue> -l`, ergänzt um die
    ///     freien Werte aus `lpoptions -p <queue>`).
    ///   - pageSizeChoices: alle Seitengrößen der Warteschlangen-PPD (`PageSize` in
    ///     `lpoptions -l`); leer = unbekannt (dann wird nur der Wert verglichen).
    ///   - basePageSizes: Seitengrößen der Modell-PPD (``PPDPageSizes``); `nil` = unbekannt (dann
    ///     werden keine veralteten Größen gemeldet).
    ///
    /// PPD-Optionen, die die PPD der Warteschlange nicht kennt (z. B. `lwCutEvery` ohne Schneider,
    /// neue Optionen bei einer PPD älterer Treiber), werden nicht gemeldet; Warteschlangen-Standards
    /// müssen vorhanden sein. Liefert `lpoptions` gar nichts (`current` leer), gelten die
    /// Warteschlangen-Standards und die Seitengröße als abweichend (Stand unbekannt).
    public static func difference(_ plan: Plan, current: [String: String], pageSizeChoices: [String] = [],
                                  basePageSizes: [String]? = nil) -> Difference {
        var difference = Difference()
        var mismatched: [String] = []
        for (name, value) in plan.expected.sorted(by: { $0.key < $1.key }) {
            if let actual = current[name] {
                if actual != value { mismatched.append(name) }
            } else if plan.queueDefaults.contains(name) || name == pageSizeOption {
                mismatched.append(name)
            }
        }
        for name in plan.cleared.sorted() {
            if let actual = current[name], !actual.isEmpty, actual != "None", actual != CUPSOptionName.defaultValue {
                mismatched.append(name)
            }
        }
        difference.mismatchedOptions = mismatched
        if let wanted = plan.expected[pageSizeOption] {
            if !pageSizeChoices.isEmpty {
                difference.missingPageSize = !pageSizeChoices.contains(wanted)
            } else {
                difference.missingPageSize = current[pageSizeOption] != wanted
            }
            if let basePageSizes, !pageSizeChoices.isEmpty {
                let base = Set(basePageSizes)
                difference.stalePageSizes = pageSizeChoices.filter { !base.contains($0) && $0 != wanted && !$0.hasPrefix("Custom") }
            }
        }
        return difference
    }

    /// Aktueller Stand aus `lpoptions -p <queue> -l` (markierte Werte) und `lpoptions -p <queue>`
    /// (freie Werte `lw…=…`, bereits mit ``CUPSQueueLister``-Regeln zerlegt): PPD-Wahl, darüber
    /// die Warteschlangen-Standards.
    public static func currentOptions(list: [String: LPOptionsList.Option], plain: [String: String]) -> [String: String] {
        var options: [String: String] = [:]
        for (name, option) in list {
            if let selected = option.selected { options[name] = selected }
        }
        for (name, value) in plain where name.hasPrefix("lw") {
            options[name] = value
        }
        return options
    }
}

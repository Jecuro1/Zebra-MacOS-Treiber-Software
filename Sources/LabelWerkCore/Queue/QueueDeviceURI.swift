import Foundation

/// Geräte-URI der LabelWerk-Warteschlangen eines Netzwerkdruckers (ARCHITECTURE.md §10 „Backend
/// labelwerk“): `labelwerk://host:port` – das Backend schickt einen Auftrag Etikett für Etikett und hält
/// ihn bei Papier- oder Farbbandende, offenem Druckkopf oder Pause in der Warteschlange, bis der Fehler
/// behoben ist – oder `socket://host:port` (CUPS-Standard: Auftrag erledigt, sobald die Daten beim
/// Drucker sind), wenn „Bei Papier- oder Farbbandende anhalten und fortsetzen“
/// (``PrintSettings/resumeAfterError``) aus ist oder das Backend fehlt (älterer Treiber).
///
/// Nur `socket://` und `labelwerk://` werden umgestellt; USB-, IPP-, LPD- und alle anderen URIs bleiben
/// unverändert (das Backend kann nur den Rohdatenport). Unter Linux getestet.
public enum QueueDeviceURI {

    /// Schema des LabelWerk-Backends.
    public static let backendScheme = "labelwerk"
    /// Installationsort des Backends (CUPS sucht Backends nur in `ServerBin/backend`).
    public static let backendPath = "/usr/libexec/cups/backend/labelwerk"
    /// Warteschlangen-Standard (`-o lwResumeOnError-default=False`), der ein abgeschaltetes Fortsetzen
    /// festhält: Das postinstall eines Treiber-Updates stellt solche `socket://`-Warteschlangen nicht
    /// auf `labelwerk://` um, und das Backend sendet bei diesem Wert am Stück. Bei „an“ ist er nicht
    /// gesetzt.
    public static let resumeOption = "lwResumeOnError"

    /// URI eines Netzwerkdruckers: `labelwerk://host:port` mit `resume`, sonst `socket://host:port`.
    /// IPv6 in eckigen Klammern, Zone als `%25`.
    public static func networkURI(host: String, port: Int, resume: Bool) -> String {
        let socket = QueueAdoption.socketURI(host: host, port: port)
        return resume ? backendScheme + socket.dropFirst("socket".count) : socket
    }

    /// Schema einer URI in Kleinbuchstaben (`nil` ohne `://`).
    public static func scheme(of uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else { return nil }
        return trimmed[..<range.lowerBound].lowercased()
    }

    /// Verwendet die URI das LabelWerk-Backend?
    public static func usesBackend(_ uri: String) -> Bool {
        scheme(of: uri) == backendScheme
    }

    /// Soll-URI einer vorhandenen Warteschlange, `nil` = nichts zu ändern:
    /// * `socket://host:port[/…][?…]` und `resume` → `labelwerk://host:port` (Pfad und Optionen der
    ///   socket-URI wie `?waiteof=false` entfallen, Port ohne Angabe bleibt ohne – beide nehmen 9100);
    /// * `labelwerk://host:port[…]` ohne `resume` → `socket://host:port`;
    /// * alles andere (USB, IPP, Hüllen wie `beh:/…`, schon passende URIs) → `nil`.
    ///
    /// `resume` ist ``PrintSettings/resumeAfterError`` **und** „Backend installiert“: Ohne Backend
    /// könnte CUPS eine `labelwerk://`-Warteschlange nicht drucken (und `lpadmin -v` lehnt das Schema ab).
    public static func target(for current: String, resume: Bool) -> String? {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: trimmed), let range = trimmed.range(of: "://") else { return nil }
        let rest = trimmed[range.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty else { return nil }
        switch (scheme, resume) {
        case ("socket", true): return "\(backendScheme)://\(authority)"
        case (backendScheme, false): return "socket://\(authority)"
        default: return nil
        }
    }

    /// Wert des Warteschlangen-Standards ``resumeOption`` laut `lpoptions`: `true`, wenn er das
    /// Fortsetzen abschaltet (`False`/`no`/`off`/`0`, ohne Groß-/Kleinschreibung).
    public static func isResumeDisabled(optionValue value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["false", "no", "off", "0"].contains(value)
    }

    /// `lpadmin`-Argumente, damit eine Warteschlange zu ``PrintSettings/resumeAfterError`` passt:
    /// Geräte-URI (``target(for:resume:)`` bzw. `desiredURI`) und der Warteschlangen-Standard
    /// ``resumeOption`` (`-o lwResumeOnError-default=False` bei „aus“, `-R lwResumeOnError-default`,
    /// wenn er bei „an“ noch gesetzt ist). Leer, wenn alles passt.
    ///
    /// - Parameters:
    ///   - currentURI: `device-uri` der Warteschlange (`nil` = unbekannt: URI bleibt).
    ///   - currentOption: Wert von ``resumeOption`` laut `lpoptions` (`nil` = nicht gesetzt).
    ///   - resumeAfterError: Einstellung des Druckers.
    ///   - backendInstalled: `/usr/libexec/cups/backend/labelwerk` ist vorhanden.
    ///   - desiredURI: feste Soll-URI (Etikettentypen: die des Druckers), wird ebenso umgestellt.
    public static func arguments(currentURI: String?, currentOption: String?, resumeAfterError: Bool,
                                 backendInstalled: Bool, desiredURI: String? = nil) -> [String] {
        let resume = resumeAfterError && backendInstalled
        var args: [String] = []
        if let desiredURI, !desiredURI.isEmpty {
            let wanted = target(for: desiredURI, resume: resume) ?? desiredURI
            if let currentURI, !currentURI.isEmpty, currentURI != wanted { args += ["-v", wanted] }
        } else if let currentURI, let wanted = target(for: currentURI, resume: resume) {
            args += ["-v", wanted]
        }
        let disabled = isResumeDisabled(optionValue: currentOption)
        if !resumeAfterError, !disabled {
            args += ["-o", "\(resumeOption)-default=False"]
        } else if resumeAfterError, currentOption != nil {
            args += ["-R", "\(resumeOption)-default"]
        }
        return args
    }
}

import Foundation
import LabelWerkCore
import LabelWerkStatus
import LabelWerkTransport

extension PrinterClient {

    // MARK: - Status

    /// Aktueller Druckerstatus.
    ///
    /// Kombiniert `~HS` und `~HQES` (ZPL/EPL) mit SGD-Kennzahlen (Odometer, Etikettenzähler,
    /// Akku, Kopfverriegelung, Medienstatus) bei Druckern mit SGD; die SGD-Fähigkeit wird
    /// einmalig erkannt und zwischengespeichert. Im CPCL-Modus (Line-Print) werden nur SGD-Werte
    /// abgefragt, weil der Drucker ZPL-Befehle dort als Text drucken würde.
    ///
    /// Verbindungen ohne Rückkanal (CUPS) liefern eine Momentaufnahme mit Zustand `unknown`.
    ///
    /// - Throws: ``PrinterClientError/noResponse(_:)``, wenn der Drucker auf keine der Abfragen
    ///   antwortet.
    public func status() async throws -> PrinterStatusSnapshot {
        guard supportsBidirectional else {
            return StatusInterpreter.snapshot(hostStatus: nil, query: nil, sgd: [:])
        }
        return try await guarded { try await self.collectStatus() }
    }

    func collectStatus() async throws -> PrinterStatusSnapshot {
        var hostStatus: HostStatus?
        var query: HostQueryStatus?
        var printerAnswered = false

        if language != .cpcl {
            let hs = try await exchange(ZPL.hostStatus().description, operation: "Statusabfrage (~HS)",
                                        isComplete: ResponseFraming.hostStatusComplete)
            if !hs.isEmpty {
                printerAnswered = true
                hostStatus = try? HostStatusParser.parse(hs)
                let hq = try await exchange(ZPL.hostQueryErrors().description, operation: "Fehlerabfrage (~HQES)",
                                            isComplete: ResponseFraming.hostQueryComplete)
                if !hq.isEmpty { query = try? HostQueryParser.parse(hq) }
            }
        }

        var sgd: [String: String] = [:]
        // Ohne Antwort auf ~HS nur dann SGD versuchen, wenn bekannt ist, dass der Drucker SGD
        // beherrscht (CPCL) oder es noch unbekannt ist – nicht bei bekannten Druckern ohne SGD.
        let capabilities = try await resolveCapabilities(knownAlive: printerAnswered)
        if capabilities.sgd {
            sgd = try await fetchVariables(StatusInterpreter.statusVariables)
        }

        if hostStatus == nil, query == nil, sgd.isEmpty {
            if printerAnswered {
                throw PrinterClientError.invalidResponse("Statusabfrage (~HS)", "Unbekanntes Antwortformat.")
            }
            throw PrinterClientError.noResponse("Statusabfrage")
        }
        return StatusInterpreter.snapshot(hostStatus: hostStatus, query: query, sgd: sgd)
    }

    // MARK: - Identität

    /// SGD-Variablen, die ``identify()`` abfragt.
    static let identityVariables: [String] = [
        SGD.Variable.productName, SGD.Variable.serial, SGD.Variable.firmware, SGD.Variable.friendlyName,
        SGD.Variable.resolution, SGD.Variable.printWidth, SGD.Variable.languages, SGD.Variable.printMethod,
        "appl.link_os_version",
        SGD.Variable.activeIP, SGD.Variable.ip, SGD.Variable.wlanIP,
        SGD.Variable.mac, SGD.Variable.wiredMAC, SGD.Variable.wlanMAC,
    ]

    /// Ermittelt Modell, Seriennummer, Firmware, Auflösung, Sprachen und Netzwerkadresse
    /// (`~HI` plus SGD) und ordnet das Modell dem ``ModelCatalog`` zu.
    ///
    /// - Throws: ``PrinterClientError/notBidirectional(_:)`` bei Verbindungen ohne Rückkanal,
    ///   ``PrinterClientError/noResponse(_:)``, wenn weder `~HI` noch SGD beantwortet werden.
    public func identify() async throws -> PrinterIdentity {
        try await guarded {
            guard self.supportsBidirectional else { throw PrinterClientError.notBidirectional("Drucker identifizieren") }
            let identity = try await self.collectIdentity()
            self.lastIdentity = identity
            return identity
        }
    }

    func collectIdentity() async throws -> PrinterIdentity {
        var hostID: HostIdentification?
        if language != .cpcl {
            let hi = try await exchange(ZPL.hostIdentification().description, operation: "Identifikation (~HI)",
                                        isComplete: ResponseFraming.etxComplete)
            if !hi.isEmpty { hostID = try? HostIdentificationParser.parse(hi) }
        }
        let capabilities = try await resolveCapabilities(knownAlive: hostID != nil)
        var sgd: [String: String] = [:]
        if capabilities.sgd {
            sgd = try await fetchVariables(Self.identityVariables)
        }
        guard hostID != nil || !sgd.isEmpty else {
            throw PrinterClientError.noResponse("Drucker identifizieren")
        }
        return Self.makeIdentity(hostID: hostID, sgd: sgd, linkOS: capabilities.linkOS, fallbackLanguage: language,
                                 descriptor: connection.descriptor)
    }

    /// Setzt die Identität aus `~HI` und SGD-Werten zusammen.
    static func makeIdentity(hostID: HostIdentification?, sgd: [String: String], linkOS: Bool,
                             fallbackLanguage: PrinterLanguage, descriptor: ConnectionDescriptor) -> PrinterIdentity {
        func value(_ key: String) -> String? {
            guard let raw = sgd[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  raw != "?" else { return nil }
            return raw
        }
        func address(_ key: String) -> String? {
            guard let raw = value(key), raw != "0.0.0.0" else { return nil }
            return raw
        }

        var identity = PrinterIdentity()
        identity.model = value(SGD.Variable.productName) ?? hostID.map { $0.model.trimmingCharacters(in: .whitespaces) }
        identity.serialNumber = value(SGD.Variable.serial)
        identity.firmware = value(SGD.Variable.firmware) ?? hostID.map(\.firmware).flatMap { $0.isEmpty ? nil : $0 }
        identity.friendlyName = value(SGD.Variable.friendlyName)
        identity.resolution = value(SGD.Variable.resolution).flatMap { Int($0) }.flatMap(Resolution.init(dpi:))
            ?? hostID?.resolution
        identity.printWidthDots = value(SGD.Variable.printWidth).flatMap { Int($0) }
        identity.memoryKB = hostID.flatMap { $0.memoryKB > 0 ? $0.memoryKB : nil }
        identity.isLinkOS = linkOS || value("appl.link_os_version") != nil
        identity.ipAddress = address(SGD.Variable.activeIP) ?? address(SGD.Variable.ip) ?? address(SGD.Variable.wlanIP)
        if identity.ipAddress == nil, case .tcp(let host, _) = descriptor, NetworkSettings.isValidIPv4(host) {
            identity.ipAddress = host
        }
        identity.macAddress = value(SGD.Variable.mac) ?? value(SGD.Variable.wiredMAC) ?? value(SGD.Variable.wlanMAC)

        let candidates = [value(SGD.Variable.productName), hostID?.model, hostID?.baseModel].compactMap { $0 }
        let matched = matchModel(candidates: candidates, printMethod: value(SGD.Variable.printMethod))
        identity.matchedModelID = matched?.id

        var languages = parseLanguages(value(SGD.Variable.languages))
        if let matched {
            for language in matched.languages where !languages.contains(language) { languages.append(language) }
        }
        if languages.isEmpty { languages = [fallbackLanguage] }
        identity.languages = languages
        return identity
    }

    /// Ordnet Produktnamen dem Katalog zu und löst die Varianten „d“ (Thermodirekt) und „t“
    /// (Thermotransfer) desselben Grundmodells auf.
    ///
    /// Ein Name wie „ZD421-203dpi“ (aus `~HI`) nennt die Variante nicht. Dann entscheidet das
    /// Druckverfahren (`ezpl.print_method`): Thermotransfer ist nur mit der t-Variante möglich.
    /// Im Thermodirekt-Modus (oder ohne Angabe) wird die Thermodirekt-Variante gewählt, sofern es
    /// sie gibt.
    static func matchModel(candidates: [String], printMethod: String?) -> PrinterModel? {
        let catalog = ModelCatalog.shared
        for candidate in candidates {
            guard let match = catalog.match(productName: candidate) else { continue }
            // Modelle ohne Varianten und ausdrücklich genannte Varianten („ZD421t“) gelten direkt.
            guard let base = baseName(of: match), !normalize(candidate).contains(normalize(match.name)) else {
                return match
            }
            let siblings = catalog.models.filter { baseName(of: $0) == base && $0.family == match.family }
            let method = printMethod?.lowercased() ?? ""
            if method.contains("trans"), let transfer = siblings.first(where: { variantSuffix(of: $0) == "t" }) {
                return transfer
            }
            if !method.contains("trans"), let direct = siblings.first(where: { variantSuffix(of: $0) == "d" }) {
                return direct
            }
            return match
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Variantenbuchstabe `d`/`t`/`c` am Ende eines Modellnamens hinter einer Ziffer.
    private static func variantSuffix(of model: PrinterModel) -> Character? {
        let name = model.name.lowercased()
        guard let last = name.last, "dtc".contains(last), name.dropLast().last?.isNumber == true else { return nil }
        return last
    }

    private static func baseName(of model: PrinterModel) -> String? {
        guard variantSuffix(of: model) != nil else { return nil }
        return normalize(String(model.name.dropLast()))
    }

    /// Sprachen aus `device.languages` (`zpl`, `epl_zpl`, `hybrid_xml_zpl`, `line_print` …).
    static func parseLanguages(_ raw: String?) -> [PrinterLanguage] {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return [] }
        var result: [PrinterLanguage] = []
        func add(_ language: PrinterLanguage) { if !result.contains(language) { result.append(language) } }
        if raw.contains("zpl") { add(.zpl) }
        if raw.contains("epl") { add(.epl) }
        if raw.contains("line_print") || raw.contains("cpcl") { add(.cpcl) }
        return result
    }
}

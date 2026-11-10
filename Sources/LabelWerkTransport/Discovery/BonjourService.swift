import Foundation

/// Ein aufgelöster Bonjour/DNS-SD-Dienst (aus Network.framework oder `avahi-browse`).
struct BonjourService: Hashable, Sendable {
    var name: String
    var type: String
    var domain: String
    /// Aufgelöste Adresse (bevorzugt IPv4) oder Hostname.
    var host: String
    /// Port des Dienstes (z. B. 9100, 515, 631).
    var port: Int
    var txt: [String: String]

    /// TXT-Wert ohne Beachtung der Groß-/Kleinschreibung des Schlüssels.
    func txtValue(_ key: String) -> String? {
        if let value = txt[key], !value.isEmpty { return value }
        let lower = key.lowercased()
        return txt.first { $0.key.lowercased() == lower && !$0.value.isEmpty }?.value
    }

    /// Modellhinweis aus `usb_MDL`, `product`, `ty` oder dem Dienstnamen.
    var modelHint: String? {
        if let model = txtValue("usb_MDL") { return model }
        if let product = txtValue("product") {
            let trimmed = product.trimmingCharacters(in: CharacterSet(charactersIn: "() ").union(.whitespaces))
            if !trimmed.isEmpty { return trimmed }
        }
        if let type = txtValue("ty") { return type }
        return nil
    }

    /// `true`, wenn TXT-Einträge oder der Name auf einen Zebra-Drucker hindeuten.
    var looksLikeZebra: Bool {
        let candidates = [txtValue("usb_MFG"), txtValue("usb_MDL"), txtValue("product"), txtValue("ty"), name]
        return candidates.compactMap { $0 }.contains(where: ZebraIdentifiers.looksLikeZebra)
    }

    /// Umwandlung in einen gefundenen Drucker. Für LPD/IPP-Dienste wird der Rohdatenport 9100
    /// verwendet, über den Zebra-Drucker ZPL/SGD bidirektional sprechen.
    func makeDiscoveredPrinter() -> DiscoveredPrinter {
        let isRaw = type.hasPrefix("_pdl-datastream.")
        let rawPort = isRaw && (1...65535).contains(port) ? port : ZebraIdentifiers.rawPort
        var details: [String: String] = [
            "serviceName": name,
            "serviceType": type,
            "host": host,
            "port": String(rawPort),
            "servicePort": String(port),
        ]
        if let note = txtValue("note") { details["location"] = note }
        if let adminURL = txtValue("adminurl") { details["adminURL"] = adminURL }
        if let product = modelHint { details["productName"] = product }
        return DiscoveredPrinter(
            name: name,
            modelHint: modelHint,
            descriptor: .tcp(host: host, port: rawPort),
            source: .bonjour,
            details: details
        )
    }
}

/// Liest die maschinenlesbare Ausgabe von `avahi-browse -p -r -t -k <typ>` (Linux).
enum AvahiBrowseParser {
    /// Nur aufgelöste Einträge (Zeilen mit `=`); IPv4 wird bei Duplikaten bevorzugt.
    static func parse(_ text: String) -> [BonjourService] {
        var services: [BonjourService] = []
        var protocols: [Int: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: ";", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9, fields[0] == "=" else { continue }
            let name = unescape(fields[3])
            let type = unescape(fields[4])
            let domain = unescape(fields[5])
            let address = unescape(fields[7])
            guard let port = Int(fields[8]), !address.isEmpty else { continue }
            let txt = fields.count > 9 ? parseTXT(fields[9]) : [:]
            let service = BonjourService(name: name, type: type, domain: domain, host: address, port: port, txt: txt)
            if let index = services.firstIndex(where: { $0.name == name && $0.type == type && $0.domain == domain }) {
                // IPv4 ersetzt IPv6.
                if protocols[index] != "IPv4", fields[2] == "IPv4" {
                    services[index] = service
                    protocols[index] = "IPv4"
                }
            } else {
                protocols[services.count] = fields[2]
                services.append(service)
            }
        }
        return services
    }

    /// Avahi maskiert Sonderzeichen als `\DDD` (dezimal) bzw. `\x`.
    static func unescape(_ text: String) -> String {
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "\\"), index + 1 < source.count {
                if index + 3 < source.count,
                   source[(index + 1)...(index + 3)].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                   let value = Int(String(decoding: source[(index + 1)...(index + 3)], as: UTF8.self)),
                   value <= 255 {
                    bytes.append(UInt8(value))
                    index += 4
                    continue
                }
                bytes.append(source[index + 1])
                index += 2
                continue
            }
            bytes.append(byte)
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `"a=1" "b=zwei drei"` → `["a": "1", "b": "zwei drei"]`. Maskierungen (`\"`, `\\`,
    /// `\DDD`) innerhalb der Anführungszeichen werden aufgelöst.
    static func parseTXT(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var inside = false
        var escaped = false
        for character in text {
            if !inside {
                if character == "\"" { inside = true }
                continue
            }
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                let entry = unescape(current)
                if let equals = entry.firstIndex(of: "=") {
                    result[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
                } else if !entry.isEmpty {
                    result[entry] = ""
                }
                current = ""
                inside = false
            } else {
                current.append(character)
            }
        }
        return result
    }
}

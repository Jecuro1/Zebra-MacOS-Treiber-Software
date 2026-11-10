import Foundation
import LabelWerkCore
import LabelWerkRender
import LabelWerkStatus

extension VirtualPrinter {

    // MARK: - Konfiguration (^HH, ~WC)

    /// Einträge der Konfiguration in der Reihenfolge des Konfigurationsetiketts.
    func configurationEntries() -> [ConfigurationEntry] {
        refreshDynamicValues()
        func value(_ name: String, _ fallback: String = "") -> String { store.rawValue(name) ?? fallback }
        let tone = Double(value("print.tone", "15")) ?? 15
        let speed = Double(value("media.speed", "4")) ?? 4
        let tearOff = intValue("ezpl.tear_off")
        let top = intValue("zpl.label_top")
        let left = intValue("zpl.left_position")
        let mediaType: String
        switch value("ezpl.media_type") {
        case "continuous", "continuous variable": mediaType = "CONTINUOUS"
        case "mark": mediaType = "MARK"
        default: mediaType = "GAP/NOTCH"
        }
        let backfeedText: String
        switch backfeed {
        case .afterPrinting: backfeedText = "AFTER"
        case .beforePrinting: backfeedText = "BEFORE"
        case .normal: backfeedText = "DEFAULT"
        case .off: backfeedText = "OFF"
        }
        let maxLength = model.maxLabelLengthMM
        var entries: [ConfigurationEntry] = [
            ConfigurationEntry(name: "DARKNESS", value: String(format: "+%.1f", tone)),
            ConfigurationEntry(name: "PRINT SPEED", value: String(format: "%.1f IPS", speed)),
            ConfigurationEntry(name: "TEAR OFF ADJUST", value: Self.signed(tearOff, digits: 3)),
            ConfigurationEntry(name: "PRINT MODE", value: value("media.printmode", "tear off").uppercased()),
            ConfigurationEntry(name: "MEDIA TYPE", value: mediaType),
            ConfigurationEntry(name: "SENSOR SELECT", value: value("media.sense_mode") == "bar" ? "REFLECTIVE" : "TRANSMISSIVE"),
            ConfigurationEntry(name: "PRINT METHOD", value: isThermalTransfer ? "THERMAL-TRANS" : "DIRECT-THERMAL"),
            ConfigurationEntry(name: "PRINT WIDTH", value: String(printWidthDots)),
            ConfigurationEntry(name: "LABEL LENGTH", value: String(labelLengthDots)),
            ConfigurationEntry(name: "MAXIMUM LENGTH",
                               value: String(format: "%.1fIN %dMM", maxLength / 25.4, Int(maxLength.rounded()))),
            ConfigurationEntry(name: "USB COMM.", value: "CONNECTED"),
            ConfigurationEntry(name: "CONTROL CHAR", value: "<~> 7EH"),
            ConfigurationEntry(name: "COMMAND CHAR", value: "<^> 5EH"),
            ConfigurationEntry(name: "DELIM. CHAR", value: "<,> 2CH"),
            ConfigurationEntry(name: "ZPL MODE", value: value("zpl.zpl_mode", "zpl II").uppercased()),
            ConfigurationEntry(name: "MEDIA POWER UP", value: value("ezpl.power_up_action", "feed").uppercased()),
            ConfigurationEntry(name: "HEAD CLOSE", value: value("ezpl.head_close_action", "feed").uppercased()),
            ConfigurationEntry(name: "BACKFEED", value: backfeedText),
            ConfigurationEntry(name: "LABEL TOP", value: Self.signed(top, digits: 3)),
            ConfigurationEntry(name: "LEFT POSITION", value: Self.signed(left, digits: 4)),
            ConfigurationEntry(name: "HEAD RESOLUTION", value: "\(resolution.dotsPerMM)/MM FULL"),
            ConfigurationEntry(name: "FIRMWARE", value: value("appl.name") + " <-"),
            ConfigurationEntry(name: "R: RAM", value: "\(Self.ramBytes / 1024)k"),
            ConfigurationEntry(name: "E: ONBOARD FLASH", value: "\(Self.flashBytes / 1024)k"),
            ConfigurationEntry(name: "NONRESET CNTR", value: "\(Int(printLengthMM / 25.4)) IN"),
            ConfigurationEntry(name: "RESET CNTR1", value: "\(Int(headCleanMM / 25.4)) IN"),
            ConfigurationEntry(name: "NONRESET CNTR", value: "\(Int(printLengthMM / 10)) CM"),
            ConfigurationEntry(name: "LABELS PRINTED", value: String(labelCount)),
            ConfigurationEntry(name: "SERIAL NUMBER", value: serialNumber),
        ]
        if let link = store.rawValue("appl.link_os_version") {
            entries.insert(ConfigurationEntry(name: "LINK-OS VERSION", value: link), at: 22)
        }
        if store.definition("ip.addr") != nil {
            entries += [
                ConfigurationEntry(name: "IP PROTOCOL", value: value("ip.ip_protocol").uppercased()),
                ConfigurationEntry(name: "IP ADDRESS", value: value("interface.network.active.ip_addr")),
                ConfigurationEntry(name: "SUBNET", value: value("interface.network.active.netmask")),
                ConfigurationEntry(name: "GATEWAY", value: value("interface.network.active.gateway")),
                ConfigurationEntry(name: "MAC ADDRESS",
                                   value: value("interface.network.active.mac_addr").replacingOccurrences(of: ":", with: "")
                                       .uppercased()),
            ]
        }
        return entries
    }

    /// `^HH`-Antwort: `STX`, Kopf, Einträge im Format `WERT.....  NAME`, `ETX`.
    func configurationReport() -> String {
        var text = "\u{02}\r\n  PRINTER CONFIGURATION\r\n\r\n  Zebra Technologies\r\n"
        text += "  ZTC \(hostModelName) ZPL\r\n  \(serialNumber)\r\n\r\n"
        for entry in configurationEntries() {
            text += "  " + Self.dotLeader(entry.value) + "  " + entry.name + "\r\n"
        }
        text += "  FIRMWARE IN THIS PRINTER IS COPYRIGHTED\r\n\u{03}\r\n"
        return text
    }

    /// `WERT` mit Punkten auf 20 Zeichen aufgefüllt (mindestens zwei Punkte).
    static func dotLeader(_ value: String) -> String {
        value + String(repeating: ".", count: max(2, 20 - value.count))
    }

    static func signed(_ value: Int, digits: Int) -> String {
        let magnitude = String(value.magnitude)
        let padded = String(repeating: "0", count: max(0, digits - magnitude.count)) + magnitude
        return (value < 0 ? "-" : "+") + padded
    }

    func networkReportLines() -> [String] {
        func value(_ name: String) -> String { store.rawValue(name) ?? "" }
        var lines = [
            "PRIMARY NETWORK: WIRED",
            "IP PROTOCOL: \(value("ip.ip_protocol").uppercased())",
            "IP ADDRESS: \(value("interface.network.active.ip_addr"))",
            "SUBNET: \(value("interface.network.active.netmask"))",
            "GATEWAY: \(value("interface.network.active.gateway"))",
            "MAC ADDRESS: \(value("internal_wired.mac_addr").uppercased())",
            "BASE RAW PORT: \(value("ip.port"))",
        ]
        if store.definition("wlan.enable") != nil {
            lines += [
                "WIRELESS: \(value("wlan.enable").uppercased())",
                "ESSID: \(value("wlan.essid"))",
                "SECURITY: \(value("wlan.security").uppercased())",
                "WLAN MAC: \(value("wlan.mac_addr").uppercased())",
            ]
        }
        if store.definition("bluetooth.enable") != nil {
            lines += [
                "BLUETOOTH: \(value("bluetooth.enable").uppercased())",
                "BT ADDRESS: \(value("bluetooth.address"))",
            ]
        }
        return lines
    }

    // MARK: - Dateiliste (^HW, ^WD, file.dir)

    /// `^HW`-Antwort für ein Muster (`E:*.*`, `*:*.*`; ohne Laufwerk `R:`).
    func directoryReport(pattern raw: String) -> String {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "R:*.*" : raw
        let (drive, _) = Self.splitPattern(pattern)
        var text = "\u{02}\r\n- DIR \(pattern.uppercased())\r\n"
        for file in files(matching: pattern) {
            let name = file.path.padding(toLength: max(file.path.count, 16), withPad: " ", startingAt: 0)
            text += "*\(name) \(String(repeating: " ", count: max(0, 8 - String(file.data.count).count)))\(file.data.count)\r\n"
        }
        text += "\r\n"
        let drives = drive == "*:" ? ["R:", "E:"] : [drive]
        for listed in drives where Self.capacity(of: listed) > 0 {
            let free = Self.capacity(of: listed) - usedBytes(on: listed)
            text += "-  \(String(repeating: " ", count: max(0, 10 - String(free).count)))\(free) bytes free \(listed)\(Self.driveName(listed))\r\n"
        }
        text += "\u{03}\r\n"
        return text
    }

    static func driveName(_ drive: String) -> String {
        switch drive {
        case "R:": return "RAM"
        case "E:": return "ONBOARD FLASH"
        default: return "MEMORY"
        }
    }

    /// Antwort auf SGD `do "file.dir"` (in Anführungszeichen).
    func fileDirectoryText(drive raw: String) -> String {
        var drive = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if drive.isEmpty { drive = "E:" }
        if !drive.hasSuffix(":") { drive += ":" }
        var text = "\"Directory of \(drive)\r\n\r\n"
        for file in files(matching: drive + "*.*") {
            text += "* \(file.path)  \(file.data.count)\r\n"
        }
        let free = max(0, Self.capacity(of: drive) - usedBytes(on: drive))
        text += "\r\n  \(free) bytes free\r\n\""
        return text
    }

    // MARK: - Gedruckte Berichte

    /// Druckt einen Textbericht als Etikett (Konfiguration, Dateiliste …).
    func printReport(title: String, lines: [String]) {
        let dotsPerMM = resolution.dotsPerMM
        let titleHeight = 4 * dotsPerMM
        let lineHeight = 3 * dotsPerMM
        let margin = 2 * dotsPerMM
        let height = max(labelLengthDots, margin * 3 + titleHeight + lines.count * (lineHeight + dotsPerMM / 2))
        var commands: [ZPLCommand] = [ZPL.startFormat(), ZPL.changeEncoding(), ZPL.printWidth(printWidthDots),
                                      ZPL.labelLength(height)]
        commands += ZPL.text(title, x: margin, y: margin, height: titleHeight)
        var y = margin * 2 + titleHeight
        for line in lines {
            commands += ZPL.text(line, x: margin, y: y, height: lineHeight)
            y += lineHeight + dotsPerMM / 2
        }
        commands.append(ZPL.endFormat())
        for label in interpreter().render(ZPL.render(commands)).labels {
            printOrQueue(label)
        }
    }

    func printDirectoryLabel(pattern raw: String) {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "R:*.*" : raw
        var lines = files(matching: pattern).map { "\($0.path)  \($0.data.count)" }
        if lines.isEmpty { lines = ["(keine Dateien)"] }
        printReport(title: "DIRECTORY \(pattern.uppercased())", lines: lines)
    }

    /// Sensorprofil (`~JG`): Rahmen mit simuliertem Signalverlauf von Lücken- und Medienwerten.
    func printSensorProfile() {
        let width = printWidthDots
        let height = 30 * resolution.dotsPerMM
        var commands: [ZPLCommand] = [ZPL.startFormat(), ZPL.printWidth(width), ZPL.labelLength(height)]
        commands += ZPL.text("SENSOR PROFILE", x: 16, y: 16, height: 4 * resolution.dotsPerMM)
        let baseY = height - 24
        let columns = max(8, width / 16)
        for column in 0..<columns {
            // Lücken (alle 8 Spalten) als hohe Ausschläge, Etiketten als niedriger Pegel.
            let isGap = column % 8 == 7
            let bar = isGap ? height / 2 : height / 8
            commands.append(ZPL.fieldOrigin(x: column * 16, y: baseY - bar))
            commands.append(ZPL.graphicBox(width: 8, height: bar, thickness: 8))
            commands.append(ZPL.fieldSeparator())
        }
        commands.append(ZPL.endFormat())
        for label in interpreter().render(ZPL.render(commands)).labels {
            printOrQueue(label)
        }
    }

    // MARK: - Veränderliche Werte

    /// Aktualisiert berechnete SGD-Werte (Uhrzeit, Laufzeit, Zähler, Kopf-/Medienstatus).
    func refreshDynamicValues() {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        store.force("rtc.date", String(format: "%02d-%02d-%04d", parts.month ?? 1, parts.day ?? 1, parts.year ?? 2026))
        store.force("rtc.time", String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0))
        let uptime = max(0, Int(now.timeIntervalSince(bootDate)))
        store.force("device.uptime", String(format: "%d days %02d:%02d:%02d", uptime / 86_400, (uptime % 86_400) / 3600,
                                            (uptime % 3600) / 60, uptime % 60))
        store.force("head.latch", headOpen ? "open" : "ok")
        store.force("media.status", mediaOut ? "out" : "ok")
        updateCounters()
    }
}

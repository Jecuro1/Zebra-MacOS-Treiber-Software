import Foundation
import LabelWerkKit

/// Eintrag der Seitenleiste.
enum SidebarItem: Hashable {
    case printer(UUID)
    case designer
    case history
    case driver
    case discover
}

/// Bereiche innerhalb eines Druckers (animierte Tab-Leiste in `PrinterDetailView`).
enum PrinterSection: String, CaseIterable, Identifiable, Codable {
    case overview
    case preferences
    case stocks
    case tools
    case terminal
    case files
    case network
    case maintenance
    case rfid
    case firmware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return tr("Übersicht")
        case .preferences: return tr("Druckeinstellungen")
        case .stocks: return tr("Etiketten")
        case .tools: return tr("Werkzeuge")
        case .terminal: return tr("Terminal")
        case .files: return tr("Dateien & Schriften")
        case .network: return tr("Netzwerk")
        case .maintenance: return tr("Sicherung & Wartung")
        case .rfid: return tr("RFID")
        case .firmware: return tr("Firmware")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .preferences: return "slider.horizontal.3"
        case .stocks: return "square.stack.3d.up"
        case .tools: return "wrench.and.screwdriver"
        case .terminal: return "terminal"
        case .files: return "externaldrive"
        case .network: return "network"
        case .maintenance: return "externaldrive.badge.timemachine"
        case .rfid: return "antenna.radiowaves.left.and.right"
        case .firmware: return "cpu"
        }
    }

    /// Bereiche, die für einen Drucker sinnvoll sind (z. B. Netzwerk nur mit Netzwerkschnittstelle).
    static func available(for model: PrinterModel?, descriptor: ConnectionDescriptor, developerMode: Bool) -> [PrinterSection] {
        var sections: [PrinterSection] = [.overview, .preferences, .stocks, .tools, .terminal]
        if descriptor.supportsBidirectional { sections.append(.files) }
        let hasNetwork = model.map { $0.connectivity.contains(.ethernet) || $0.connectivity.contains(.wifi) } ?? true
        if hasNetwork && descriptor.supportsBidirectional { sections.append(.network) }
        if descriptor.supportsBidirectional { sections.append(.maintenance) }
        if descriptor.supportsBidirectional, model?.supports(.rfid) ?? false { sections.append(.rfid) }
        // Firmware braucht eine direkte Verbindung (über eine macOS-Warteschlange nicht möglich).
        if descriptor.supportsBidirectional { sections.append(.firmware) }
        return sections
    }
}

import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Wege (Anzeige)

/// Bezeichnungen der Wege, über die ein gefundener Drucker erreichbar ist (`DiscoveredDevice.Path`).
enum DiscoveryPathStyle {
    static func title(_ path: DiscoveredDevice.Path) -> String {
        switch path {
        case .network: return tr("Netzwerk")
        case .usb: return tr("USB")
        case .bluetooth: return tr("Bluetooth")
        case .macPrinter: return tr("macOS-Drucker")
        }
    }

    static func systemImage(_ path: DiscoveredDevice.Path) -> String {
        path.systemImage
    }

    /// Was hinter dem Weg steht: Adressen, Bluetooth-Namen, Warteschlangennamen.
    static func detail(_ path: DiscoveredDevice.Path, of device: DiscoveredDevice) -> String {
        if path == .macPrinter { return device.queueNames.joined(separator: ", ") }
        var texts: [String] = []
        for member in device.members(on: path) where !texts.contains(member.descriptor.displayString) {
            texts.append(member.descriptor.displayString)
        }
        return texts.joined(separator: ", ")
    }

    /// Hilfetext „Erreichbar über Netzwerk: 10.62.13.19:9100“.
    static func help(_ path: DiscoveredDevice.Path, of device: DiscoveredDevice) -> String {
        let detail = detail(path, of: device)
        return detail.isEmpty ? title(path) : tr("Erreichbar über %@: %@", title(path), detail)
    }
}

// MARK: - Liste

/// Ruhige Liste gefundener Drucker wie in den Systemeinstellungen: eine Zeile je Gerät, feine Trenner,
/// abgerundeter Rahmen.
struct DiscoveryDeviceList: View {
    let devices: [DiscoveredDevice]
    var compact: Bool = false
    var actionTitle: String = tr("Hinzufügen")
    let reduceMotion: Bool
    /// Kontextmenü „Drucker installieren …“ (Installationsassistent; nur Netzwerkdrucker).
    var onInstall: ((DiscoveredDevice) -> Void)?
    let onAdd: (DiscoveredDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 {
                    Divider()
                        .padding(.leading, compact ? 50 : 58)
                }
                DiscoveryDeviceRow(device: device, compact: compact, actionTitle: actionTitle,
                                   reduceMotion: reduceMotion,
                                   onInstall: onInstall.map { install -> () -> Void in { install(device) } }) {
                    onAdd(device)
                }
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                ))
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous).strokeBorder(Theme.cardStroke))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: devices.map(\.id))
    }
}

// MARK: - Zeile

/// Eine Zeile je physischem Drucker (etwa 52 pt): Symbol, „Zebra ZD421t“, darunter
/// „10.62.13.19 · Seriennr. D6J250301793“, kleine Symbole der Wege (mit Hilfetext), Info-Knopf für
/// Details und „Hinzufügen“.
struct DiscoveryDeviceRow: View {
    let device: DiscoveredDevice
    var compact: Bool = false
    var actionTitle: String = tr("Hinzufügen")
    let reduceMotion: Bool
    var onInstall: (() -> Void)?
    let onAdd: () -> Void

    @State private var hovering = false
    @State private var showDetails = false

    private var catalogModel: PrinterModel? { DiscoveryMatcher.model(for: device.preferred) }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(device.title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DiscoveryDeviceText.subtitle(for: device))
                    .font(.system(size: compact ? 10.5 : 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            pathIcons
            Button {
                showDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(hovering || showDetails ? Color.primary.opacity(0.8) : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Details"))
            .accessibilityLabel(tr("Details"))
            .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                DiscoveryDeviceDetails(device: device)
            }
            Button(action: onAdd) {
                Text(actionTitle)
                    .padding(.horizontal, compact ? 0 : 2)
            }
            // Ruhig wie in den Systemeinstellungen: kein Markenverlauf in jeder Zeile.
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .help(addHelp)
        }
        .padding(.horizontal, compact ? 10 : 14)
        .frame(minHeight: compact ? 44 : 52)
        .background(hovering ? Theme.subtleFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { hovering = inside }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(actionTitle, action: onAdd)
        if let onInstall, PrinterInstallRequest.supports(device.preferred.descriptor) {
            Button(tr("Drucker installieren …"), action: onInstall)
        }
        Button(tr("Details")) { showDetails = true }
        if let address = device.address {
            Divider()
            Button(tr("Adresse kopieren")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            }
        }
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.accent.opacity(0.12))
            .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
            .overlay {
                Image(systemName: catalogModel?.systemImage ?? "printer")
                    .font(.system(size: compact ? 13 : 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)
    }

    private var pathIcons: some View {
        HStack(spacing: 7) {
            ForEach(device.paths, id: \.self) { path in
                Image(systemName: DiscoveryPathStyle.systemImage(path))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help(DiscoveryPathStyle.help(path, of: device))
                    .accessibilityLabel(DiscoveryPathStyle.help(path, of: device))
            }
        }
    }

    private var accessibilityText: String {
        device.title + ", " + DiscoveryDeviceText.subtitle(for: device)
    }

    private var addHelp: String {
        if device.preferred.descriptor.supportsBidirectional {
            return tr("In LabelWerk einrichten über %@", device.preferred.descriptor.displayString)
        }
        return tr("Über diese Verbindung kann LabelWerk drucken, aber keinen Live-Status abfragen.")
    }
}

// MARK: - Texte

enum DiscoveryDeviceText {
    /// „10.62.13.19 · Seriennr. D6J250301793“; mit eigenem Namen zuerst das Modell; reine
    /// macOS-Drucker nennen ihre Warteschlangen.
    static func subtitle(for device: DiscoveredDevice) -> String {
        var parts: [String] = []
        if device.isMacQueueOnly, !device.queueNames.isEmpty {
            parts.append(device.queueNames.joined(separator: ", "))
        }
        if device.hasCustomName || (device.isMacQueueOnly && device.modelName != nil) {
            parts.append(device.displayModel)
        }
        if let address = device.address { parts.append(address) }
        if let serial = device.serialNumber { parts.append(tr("Seriennr. %@", serial)) }
        if parts.isEmpty { parts.append(device.preferred.descriptor.displayString) }
        return parts.joined(separator: " · ")
    }

    /// Kopfzeile „4 neue Zebra-Drucker“.
    static func headline(newCount count: Int) -> String {
        count == 1 ? tr("1 neuer Zebra-Drucker") : tr("%d neue Zebra-Drucker", count)
    }
}

// MARK: - Details

/// Details eines Geräts (Popover am Info-Knopf): Modell, Adresse, Seriennummer, Wege und die
/// einzelnen Funde der Suche.
struct DiscoveryDeviceDetails: View {
    let device: DiscoveredDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.title)
                        .font(Theme.Typography.headline)
                    if device.hasCustomName {
                        Text(device.displayModel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    KeyValueRow(tr("Modell"), device.modelName.map { _ in device.displayModel } ?? tr("Modell wird beim Verbinden erkannt"))
                    if let address = device.address {
                        KeyValueRow(tr("Adresse"), address, monospaced: true, copyable: true)
                    }
                    if let serial = device.serialNumber {
                        KeyValueRow(tr("Seriennummer"), serial, monospaced: true, copyable: true)
                    }
                    if let mac = device.macAddress {
                        KeyValueRow(tr("MAC-Adresse"), mac, monospaced: true, copyable: true)
                    }
                    if let firmware = firstDetail("firmware") {
                        KeyValueRow(tr("Firmware"), firmware, monospaced: true)
                    }
                    KeyValueRow(tr("Verbindung"), device.preferred.descriptor.displayString, monospaced: true)
                    ForEach(device.paths, id: \.self) { path in
                        KeyValueRow(DiscoveryPathStyle.title(path), DiscoveryPathStyle.detail(path, of: device))
                    }
                }
                Text(tr("Gefunden über"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(device.members) { member in
                        HStack(spacing: 8) {
                            Image(systemName: DiscoverySourceStyle.systemImage(member.source))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(DiscoverySourceStyle.tint(member.source))
                                .frame(width: 14)
                            Text(DiscoverySourceStyle.title(member.source))
                                .font(.system(size: 11.5, weight: .medium))
                            Text(member.descriptor.displayString)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .help(DiscoveryDetailText.title(for: "identifiedBy") + ": "
                              + DiscoveryDetailText.value(for: "identifiedBy", raw: member.details["identifiedBy"] ?? member.source.rawValue))
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
    }

    private func firstDetail(_ key: String) -> String? {
        device.members.lazy.compactMap { $0.details[key] }.first { !$0.isEmpty }
    }
}

// MARK: - Suchanzeige im Kopf

/// Kleines, ruhiges Suchsymbol im Kopf von „Drucker suchen“: Markenkreis mit Funkwellen; während der
/// Suche sanfte Wellen (ohne „Bewegung reduzieren“).
struct DiscoverySearchIndicator: View {
    let isScanning: Bool
    var size: CGFloat = 36
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if isScanning && !reduceMotion {
                PulseRings(color: Theme.teal, active: true)
                    .frame(width: size * 1.6, height: size * 1.6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            Circle()
                .fill(Theme.brandGradient)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .frame(width: size, height: size)
                .shadow(color: Theme.violet.opacity(isScanning ? 0.35 : 0.15), radius: isScanning ? 8 : 4, y: 1)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isScanning && !reduceMotion)
        }
        .frame(width: size, height: size)
        .animation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion), value: isScanning)
        .accessibilityLabel(isScanning ? tr("Suche läuft") : tr("Suchradar"))
    }
}

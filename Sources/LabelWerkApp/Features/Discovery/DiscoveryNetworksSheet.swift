import SwiftUI
import LabelWerkKit

// MARK: - Texte zu den durchsuchten Netzen

/// Bezeichnungen, Symbole und Hinweise für die Netze der Druckersuche (`DiscoveryPlan`).
enum DiscoveryNetworkText {
    static func title(_ origin: DiscoveryNetworkEntry.Origin) -> String {
        switch origin {
        case .local: return tr("Lokales Netz")
        case .vpn: return tr("VPN")
        case .knownPrinter: return tr("Bekannter Drucker")
        case .user: return tr("Eigenes Netz")
        }
    }

    static func systemImage(_ origin: DiscoveryNetworkEntry.Origin) -> String {
        switch origin {
        case .local: return "wifi"
        case .vpn: return "lock.shield"
        case .knownPrinter: return "printer"
        case .user: return "person.crop.circle"
        }
    }

    static func tint(_ origin: DiscoveryNetworkEntry.Origin) -> Color {
        switch origin {
        case .local: return Theme.teal
        case .vpn: return Theme.violet
        case .knownPrinter: return Theme.printing
        case .user: return Theme.paused
        }
    }

    static func hostCount(_ count: Int) -> String {
        count == 1 ? tr("1 Adresse") : tr("%d Adressen", count)
    }

    /// „Lokales Netz · en0“, „Eigenes Netz · Bekannter Drucker · ZD421t“.
    static func subtitle(_ network: DiscoveryNetwork) -> String {
        let origins = network.origins.map(title).joined(separator: " · ")
        return network.labels.isEmpty ? origins : "\(origins) · \(network.labels.joined(separator: ", "))"
    }

    static func error(_ error: DiscoveryNetworkError) -> String {
        switch error {
        case .empty: return tr("Bitte ein Netz eingeben.")
        case .invalidSyntax: return tr("Nicht verstanden – z. B. 10.62.13.0/24 oder 10.62.13.1-10.62.13.254.")
        case .invalidPrefix: return tr("Ungültige Netzmaske bzw. Präfixlänge (0–32).")
        case .reversedRange: return tr("Das Ende des Bereichs liegt vor dem Anfang.")
        case .reservedAddress: return tr("Loopback-, Multicast- und reservierte Adressen werden nicht durchsucht.")
        }
    }

    /// Warnung bei Netzen über 4096 Adressen.
    static var cappedWarning: String {
        tr("Großes Netz: Nur die ersten %d Adressen werden durchsucht.", DiscoveryNetworks.maxHostsPerEntry)
    }

    /// „192.168.1.0/24, 10.62.13.0/24“ – für Hilfetexte.
    static func summary(_ plan: DiscoveryPlan) -> String {
        plan.networks.map(\.range.description).joined(separator: ", ")
    }
}

// MARK: - Editor „Durchsuchte Netze“

/// Sheet „Durchsuchte Netze“: was die Suche durchsucht (lokal, VPN, Netze bekannter Drucker) und
/// eigene Netze („10.62.13.0/24“, „10.62.13.1-10.62.13.254“ …) – für Drucker hinter Routern und VPN.
struct DiscoveryNetworksSheet: View {
    /// „Jetzt suchen“ (z. B. die Suche der Seite „Drucker suchen“ neu starten).
    var onSearch: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var draft = ""
    @State private var prefilled = false
    @FocusState private var fieldFocused: Bool

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
    private var service: NetworkDiscoveryService { model.networkDiscovery }
    private var userEntries: [String] { model.preferences.extraDiscoveryNetworks }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                    searchedCard
                    userCard
                    GlassCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(tr("Automatisch suchen – 5 Sekunden nach dem Start und danach alle 10 Minuten"),
                                   isOn: $model.preferences.automaticNetworkDiscovery)
                            Text(tr("Gefundene Zebra-Drucker, die noch nicht eingerichtet sind, zeigt die Seitenleiste unter „Neue Zebra-Drucker“."))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Theme.Metrics.paddingLarge)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640, height: 620)
        .background { AnimatedBackground(style: .subtle).ignoresSafeArea() }
        .onAppear {
            service.updatePlan()
            prefillSuggestion()
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: userEntries)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: service.plan)
    }

    // MARK: Kopf & Fuß

    private var header: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: "point.3.connected.trianglepath.dotted", tint: Theme.teal, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Durchsuchte Netze"))
                    .font(Theme.Typography.title)
                Text(tr("Wie die Zebra-Programme unter Windows sucht LabelWerk alle Zebra-Drucker in diesen Netzen – auch hinter Routern und VPN."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let last = service.lastFullSearch {
                Label(tr("Zuletzt gesucht: %@", last.formatted(.relative(presentation: .named))), systemImage: "clock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let onSearch {
                    onSearch()
                } else {
                    service.searchNow()
                }
                dismiss()
            } label: {
                Label(tr("Jetzt suchen"), systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.labelWerkSecondary)
            Button {
                dismiss()
            } label: {
                Text(tr("Fertig")).padding(.horizontal, 10)
            }
            .buttonStyle(.labelWerkPrimary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.vertical, 14)
    }

    // MARK: Durchsuchte Netze

    private var searchedCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(tr("Diese Netze werden durchsucht"),
                              subtitle: tr("Lokale Netze per Broadcast, alle anderen Adresse für Adresse (Zebra-Suche über UDP 4201 und Port 9100)."),
                              systemImage: "scope")
                if service.plan.networks.isEmpty {
                    Label(tr("Keine Netzwerkverbindung – es wird kein Netz durchsucht."), systemImage: "wifi.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(service.plan.networks) { network in
                            networkRow(network)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    Text(tr("%@ insgesamt", DiscoveryNetworkText.hostCount(service.plan.totalHostCount)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(service.plan.totalHostCount)))
                }
            }
        }
    }

    private func networkRow(_ network: DiscoveryNetwork) -> some View {
        let tint = DiscoveryNetworkText.tint(network.origin)
        return HStack(spacing: 10) {
            Image(systemName: DiscoveryNetworkText.systemImage(network.origin))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(network.range.description)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(DiscoveryNetworkText.subtitle(network))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if network.isCapped {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .help(DiscoveryNetworkText.cappedWarning)
            }
            Text(DiscoveryNetworkText.hostCount(network.searchedHostCount))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous).fill(Theme.subtleFill))
    }

    // MARK: Eigene Netze

    private var userCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(tr("Eigene Netze"),
                              subtitle: tr("Für Drucker in einem anderen Netz, z. B. über VPN (FortiClient) oder hinter einem Router."),
                              systemImage: "plus.rectangle.on.rectangle")
                if !userEntries.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(userEntries, id: \.self) { entry in
                            userRow(entry)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField(tr("z. B. 10.62.13.0/24, 10.62.13.1-10.62.13.254 oder 10.62.13.*"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($fieldFocused)
                        .onSubmit(addDraft)
                    Button(action: addDraft) {
                        Label(tr("Hinzufügen"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .disabled(validDraftEntries.isEmpty)
                }
                draftPreview
                if !service.suggestedNetworks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Vorschläge aus bekannten Druckern"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        DiscoveryFlowLayout(spacing: 6) {
                            ForEach(service.suggestedNetworks, id: \.text) { suggestion in
                                Button {
                                    add([suggestion.text])
                                } label: {
                                    Label(suggestionTitle(suggestion), systemImage: "plus")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Theme.subtleFill))
                                        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help(tr("Netz dauerhaft eintragen (wird ohnehin durchsucht, solange der Drucker eingerichtet ist)"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func userRow(_ entry: String) -> some View {
        let parsed = DiscoveryNetworks.parse(entry)
        return HStack(spacing: 10) {
            switch parsed {
            case .success(let range):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.ready)
                VStack(alignment: .leading, spacing: 1) {
                    Text(range.description)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    if range.hostCount > DiscoveryNetworks.maxHostsPerEntry {
                        Text(DiscoveryNetworkText.cappedWarning)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    } else if entry.trimmingCharacters(in: .whitespaces) != range.description {
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Text(DiscoveryNetworkText.hostCount(min(range.hostCount, DiscoveryNetworks.maxHostsPerEntry)))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            case .failure(let error):
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Theme.error)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(DiscoveryNetworkText.error(error))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.error)
                }
                Spacer(minLength: 6)
            }
            Button {
                remove(entry)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Netz entfernen"))
            .accessibilityLabel(tr("Netz entfernen"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous).fill(Theme.subtleFill))
    }

    /// Prüfung der Eingabe, während getippt wird.
    @ViewBuilder
    private var draftPreview: some View {
        let items = DiscoveryNetworks.splitList(draft)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { item in
                    switch DiscoveryNetworks.parse(item) {
                    case .success(let range):
                        let capped = range.hostCount > DiscoveryNetworks.maxHostsPerEntry
                        let detail = capped ? DiscoveryNetworkText.cappedWarning : DiscoveryNetworkText.hostCount(range.hostCount)
                        let text: String = range.description + " · " + detail
                        Label(text, systemImage: "checkmark.circle")
                            .foregroundStyle(capped ? Theme.warning : Theme.ready)
                    case .failure(let error):
                        Label(tr("„%@“: %@", item, DiscoveryNetworkText.error(error)), systemImage: "exclamationmark.circle")
                            .foregroundStyle(Theme.error)
                    }
                }
            }
            .font(.system(size: 11.5))
            .transition(.opacity)
        }
    }

    // MARK: Aktionen

    private var validDraftEntries: [String] {
        DiscoveryNetworks.splitList(draft).filter {
            if case .success = DiscoveryNetworks.parse($0) { return true }
            return false
        }
    }

    private func addDraft() {
        let items = DiscoveryNetworks.splitList(draft)
        let valid = validDraftEntries
        guard !valid.isEmpty else { return }
        add(valid)
        // Nicht verstandene Angaben bleiben zum Korrigieren stehen.
        draft = items.filter { !valid.contains($0) }.joined(separator: ", ")
    }

    private func add(_ entries: [String]) {
        model.preferences.extraDiscoveryNetworks = DiscoveryNetworks.normalizedUserEntries(userEntries + entries)
    }

    private func remove(_ entry: String) {
        model.preferences.extraDiscoveryNetworks.removeAll { $0 == entry }
    }

    /// Erster Vorschlag aus den Netzen bekannter Drucker als Vorbelegung des Eingabefelds.
    private func prefillSuggestion() {
        guard !prefilled else { return }
        prefilled = true
        if draft.isEmpty, let first = service.suggestedNetworks.first {
            draft = first.text
        }
    }

    private func suggestionTitle(_ suggestion: DiscoveryNetworkEntry) -> String {
        guard let label = suggestion.label, !label.isEmpty else { return suggestion.text }
        return "\(suggestion.text) · \(label)"
    }
}

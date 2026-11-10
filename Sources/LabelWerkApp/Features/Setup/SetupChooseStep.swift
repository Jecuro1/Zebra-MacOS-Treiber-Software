import SwiftUI
import LabelWerkKit

/// Schritt 1 „Drucker wählen“: live gefundene Drucker im Netzwerk (Bonjour, Subnetz-Scan auf
/// Port 9100) und per USB sowie die Eingabe einer IP-Adresse bzw. eines Hostnamens.
struct SetupChooseStep: View {
    @Bindable var wizard: PrinterSetupWizardModel
    let reduceMotion: Bool

    @Namespace private var namespace
    @FocusState private var hostFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchHeader

                if let failure = wizard.connectionFailure {
                    failureCard(failure)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }

                printerList

                manualCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.candidates.map(\.id))
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.connectionFailure)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: wizard.candidate)
        .onChange(of: hostFocused) { _, focused in
            if focused && !wizard.manualHost.isEmpty { wizard.candidate = .manual }
        }
    }

    // MARK: Suche

    private var searchHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                PulseRings(color: Theme.teal, active: wizard.discovery.isScanning)
                    .frame(width: 46, height: 46)
                    .opacity(wizard.discovery.isScanning ? 1 : 0)
                IconBadge(systemImage: "dot.radiowaves.left.and.right", tint: Theme.teal, size: 30)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(searchTitle)
                    .font(Theme.Typography.headline)
                    .contentTransition(.opacity)
                Text(searchSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                wizard.rescan()
            } label: {
                Label(wizard.discovery.isScanning ? tr("Suche läuft …") : tr("Erneut suchen"),
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .disabled(wizard.discovery.isScanning)
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.discovery.isScanning)
    }

    private var searchTitle: String {
        let count = wizard.candidates.count
        if wizard.discovery.isScanning {
            return count == 0 ? tr("Drucker im Netzwerk werden gesucht …") : tr("Suche läuft … %d gefunden", count)
        }
        return count == 0 ? tr("Kein Drucker gefunden") : tr("%d Drucker gefunden", count)
    }

    private var searchSubtitle: String {
        if wizard.discovery.isScanning || !wizard.candidates.isEmpty {
            return tr("Bonjour, Netzwerk-Scan (Port 9100) und USB – Drucker auswählen und „Weiter“ wählen.")
        }
        return tr("Adresse unten eingeben – sie steht auf dem Konfigurationsetikett des Druckers.")
    }

    @ViewBuilder
    private var printerList: some View {
        let printers = wizard.candidates
        if printers.isEmpty {
            if wizard.discovery.isScanning {
                VStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { index in
                        skeletonRow
                            .opacity(1 - Double(index) * 0.35)
                    }
                }
                .accessibilityHidden(true)
                .transition(.opacity)
            } else {
                DiscoveryInlineNote(
                    systemImage: "magnifyingglass",
                    text: tr("Im Netzwerk wurde kein Zebra-Drucker gefunden. Ist er eingeschaltet und im selben Netzwerk? Drucker hinter einem Router (anderes Subnetz) findet die Suche nicht – dann die IP-Adresse unten eingeben.")
                )
                .transition(.opacity)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(printers) { printer in
                    SetupPrinterRow(
                        printer: printer,
                        info: wizard.info(for: printer),
                        isSelected: wizard.candidate == .discovered(printer.id),
                        namespace: namespace,
                        reduceMotion: reduceMotion
                    ) {
                        hostFocused = false
                        wizard.select(printer)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.subtleFill)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.subtleFill).frame(width: 160, height: 10)
                Capsule().fill(Theme.subtleFill).frame(width: 230, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .shimmering(active: !reduceMotion)
    }

    // MARK: Manuelle Adresse

    private var manualCard: some View {
        let isActive = wizard.candidate == .manual
        return GlassCard(padding: 14, tint: isActive ? Theme.violet : nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.accent : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(tr("Adresse eingeben"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    reachabilityBadge
                }
                HStack(spacing: 6) {
                    TextField(tr("IP-Adresse oder Hostname, z. B. 192.168.1.50"), text: $wizard.manualHost)
                        .textFieldStyle(.roundedBorder)
                        .focused($hostFocused)
                        .onSubmit { wizard.normalizeManualHost() }
                    Text(verbatim: ":")
                        .foregroundStyle(.secondary)
                    TextField(tr("Port"), value: $wizard.manualPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .help(tr("Rohdatenport des Druckers (Standard 9100)"))
                    Button {
                        wizard.checkManual()
                    } label: {
                        Label(tr("Verbindung prüfen"), systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.labelWerkSecondary)
                    .controlSize(.small)
                    .disabled(wizard.manualTarget == nil || wizard.manualReachability == .checking)
                }
                if let note = wizard.subnetNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                if !wizard.interfaces.isEmpty {
                    Label(tr("Dieser Mac: %@", wizard.interfaces.map { "\($0.address) (\($0.name))" }.joined(separator: ", ")),
                          systemImage: "laptopcomputer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: wizard.manualReachability)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: wizard.subnetNote)
    }

    @ViewBuilder
    private var reachabilityBadge: some View {
        switch wizard.manualReachability {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Verbindung wird geprüft …"))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .transition(.opacity)
        case .reachable(let milliseconds):
            Label(tr("Erreichbar · %d ms", milliseconds), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ready)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : milliseconds)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .unreachable(let message):
            Label(tr("Nicht erreichbar"), systemImage: "xmark.octagon.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.error)
                .help(message)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    // MARK: Fehler

    private func failureCard(_ failure: PrinterInstallFailure) -> some View {
        GlassCard(padding: 14, tint: Theme.error) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: "wifi.exclamationmark", tint: Theme.error, size: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.title)
                        .font(Theme.Typography.headline)
                    Text(failure.message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(failure.hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button {
                            wizard.continueFromChoose()
                        } label: {
                            Label(tr("Erneut prüfen"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.labelWerkSecondary)
                        .controlSize(.small)
                        .disabled(wizard.isDetecting)
                        Button {
                            wizard.continueWithoutConnection()
                        } label: {
                            Label(tr("Trotzdem fortfahren"), systemImage: "arrow.right")
                        }
                        .buttonStyle(.labelWerkPlain)
                        .controlSize(.small)
                        .help(tr("Der macOS-Drucker wird trotzdem eingerichtet und druckt, sobald der Drucker erreichbar ist. Das Modell muss dann von Hand gewählt werden."))
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Zeile eines gefundenen Druckers

struct SetupPrinterRow: View {
    let printer: DiscoveredPrinter
    let info: PrinterSetupCandidateInfo
    let isSelected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBadge(systemImage: info.systemImage, tint: DiscoverySourceStyle.tint(printer.source), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(printer.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if info.hasMacQueue {
                            chip(tr("macOS-Drucker vorhanden"), symbol: "checkmark.circle.fill", tint: Theme.ready)
                        } else if info.isInLabelWerk {
                            chip(tr("In LabelWerk"), symbol: "checkmark", tint: Theme.teal)
                        }
                    }
                    Text(info.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if info.isUnidentified {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(isSelected ? Color.white : Theme.warning)
                        .help(DiscoveryMatcher.unidentifiedWarning)
                }
                Label(DiscoverySourceStyle.title(printer.source), systemImage: DiscoverySourceStyle.systemImage(printer.source))
                    .font(.system(size: 10.5, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(isSelected ? Color.white : DiscoverySourceStyle.tint(printer.source))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(isSelected ? Color.white.opacity(0.2) : DiscoverySourceStyle.tint(printer.source).opacity(0.13)))
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(isSelected || hovering ? 1 : 0.35)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hovering ? Theme.subtleFill : Color.clear)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.brandGradient)
                            .shadow(color: Theme.violet.opacity(0.35), radius: 8, y: 3)
                            .matchedGeometryEffect(id: "setupPrinterSelection", in: namespace)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.25) : Theme.cardStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        [printer.name, info.subtitle].joined(separator: ", ")
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9.5, weight: .bold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isSelected ? Color.white : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : tint.opacity(0.14)))
    }
}

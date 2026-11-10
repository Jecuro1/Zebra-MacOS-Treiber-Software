import SwiftUI
import LabelWerkKit

/// Eine macOS-Druckerwarteschlange mit Zustand und LabelWerk-Kennzeichnung.
struct DriverQueueItem: Identifiable, Equatable {
    var info: CUPSQueueInfo
    var isLabelWerk: Bool
    var state: DriverQueueState
    var id: String { info.name }
}

// MARK: - Zeile: Warteschlange

/// Zeile einer Warteschlange mit Zustand, Standard-Markierung, Verknüpfung und Aktionen.
struct DriverQueueRow: View {
    let item: DriverQueueItem
    let linkedSession: PrinterSession?
    let isBusy: Bool
    let appearIndex: Int
    let reduceMotion: Bool
    let onSetDefault: () -> Void
    let onTestPage: () -> Void
    var onSync: (() -> Void)?
    var onResume: (() -> Void)?
    let onRemove: () -> Void

    @State private var appeared = false
    @State private var testPulse = 0

    private var tint: Color {
        linkedSession?.accentColor ?? (item.isLabelWerk ? Theme.violet : Theme.offline)
    }

    var body: some View {
        GlassCard(padding: 14, tint: item.info.isDefault ? Theme.accent : nil) {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(systemImage: item.isLabelWerk ? "printer.fill" : "printer", tint: tint, size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        if item.info.isDefault {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(Theme.paused))
                                .offset(x: 5, y: 5)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .symbolEffect(.bounce, value: testPulse)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.info.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        if item.info.isDefault {
                            badge(tr("Standard"), tint: Theme.paused)
                        }
                        if item.isLabelWerk {
                            badge("LabelWerk", tint: Theme.violet)
                        }
                    }
                    Text(item.info.makeAndModel ?? item.info.deviceURI)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 10) {
                        Label(item.info.deviceURI, systemImage: "link")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let linkedSession {
                            Label(tr("Verknüpft mit „%@“", linkedSession.displayName), systemImage: "checkmark.circle")
                                .foregroundStyle(Theme.ready)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                stateBadge

                actions
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -16)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(Motion.spring.delay(min(Double(appearIndex), 8) * 0.05)) { appeared = true }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: item)
    }

    private var stateBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: item.state.systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: item.state == .printing && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
            Text(item.state.displayName)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(item.state.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(item.state.color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(item.state.color.opacity(0.3), lineWidth: 1))
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26)
                    .transition(.scale.combined(with: .opacity))
            }
            if let onResume {
                Button(action: onResume) {
                    Label(tr("Fortsetzen"), systemImage: "play.fill")
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                .help(tr("Angehaltene Warteschlange wieder aktivieren"))
            }
            Button {
                if !reduceMotion { testPulse += 1 }
                onTestPage()
            } label: {
                Label(tr("Testseite"), systemImage: "doc.text.image")
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .help(tr("Testseite über den macOS-Druckweg senden (prüft den kompletten Treiber)"))

            if !item.info.isDefault {
                Button(action: onSetDefault) {
                    Image(systemName: "star")
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Als Standarddrucker festlegen"))
                .accessibilityLabel(tr("Als Standard"))
            }
            if let onSync {
                Button(action: onSync) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.labelWerkPlain)
                .help(tr("Einstellungen synchronisieren: Druckeinstellungen aus LabelWerk als Standard der Warteschlange übernehmen"))
                .accessibilityLabel(tr("Einstellungen synchronisieren"))
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.error)
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("Warteschlange entfernen …"))
            .accessibilityLabel(tr("Entfernen"))
        }
        .disabled(isBusy)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isBusy)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
    }
}

// MARK: - Zeile: Drucker ohne Warteschlange

/// Was für einen LabelWerk-Drucker ohne Warteschlange möglich ist.
enum DriverSetupOption: Equatable {
    /// Warteschlange anlegen (TCP/USB).
    case install
    /// Warteschlange fehlt (wurde entfernt) – neu anlegen.
    case reinstall(String)
    /// Der Drucker druckt bereits über eine Warteschlange – nur verknüpfen.
    case link(String)
    /// Keine Warteschlange möglich (Bluetooth, BLE, Demo).
    case unavailable(String)

    /// - Parameter existingQueues: Namen der vorhandenen Warteschlangen; `nil`, solange sie noch nicht gelesen sind.
    @MainActor
    static func option(for session: PrinterSession, existingQueues: Set<String>?) -> DriverSetupOption {
        switch session.saved.descriptor {
        case .cupsQueue(let name):
            // Eine entfernte Warteschlange lässt sich nicht verknüpfen – und der Drucker druckt so auch nicht mehr.
            if let existingQueues, !existingQueues.contains(name) {
                return .unavailable(tr("Die Warteschlange „%@“ existiert nicht mehr – den Drucker in LabelWerk neu einrichten.", name))
            }
            return .link(name)
        case .tcp, .usb:
            if let queue = session.saved.cupsQueueName, let existingQueues, !existingQueues.contains(queue) {
                return .reinstall(queue)
            }
            return .install
        case .bluetooth, .ble:
            return .unavailable(tr("Bluetooth-Drucker können in macOS nicht als Warteschlange eingerichtet werden – LabelWerk druckt direkt."))
        case .virtual:
            return .unavailable(tr("Der Demo-Drucker ist nur in LabelWerk verfügbar."))
        }
    }
}

/// Zeile eines eingerichteten Druckers ohne macOS-Warteschlange.
struct DriverSetupRow: View {
    let session: PrinterSession
    let option: DriverSetupOption
    let driverInstalled: Bool
    let isBusy: Bool
    let reduceMotion: Bool
    let onSetUp: () -> Void
    let onLink: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: session.model?.systemImage ?? "printer", tint: session.accentColor, size: 34)
                .saturation(isUnavailable ? 0.3 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
        .opacity(isUnavailable ? 0.75 : 1)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: isBusy)
    }

    private var isUnavailable: Bool {
        if case .unavailable = option { return true }
        return false
    }

    private var subtitle: String {
        let base = "\(session.model?.displayName ?? tr("Unbekanntes Modell")) · \(session.saved.descriptor.displayString)"
        switch option {
        case .install:
            return base
        case .reinstall(let queue):
            return tr("Warteschlange „%@“ wurde entfernt", queue) + " · " + base
        case .link(let queue):
            return tr("Druckt bereits über die Warteschlange „%@“", queue)
        case .unavailable(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Wird eingerichtet …"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        } else {
            switch option {
            case .install, .reinstall:
                Button(action: onSetUp) {
                    Label(option == .install ? tr("Einrichten") : tr("Neu einrichten"), systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.labelWerkPrimary)
                .controlSize(.small)
                .disabled(!driverInstalled)
                .help(driverInstalled
                      ? tr("Legt eine macOS-Warteschlange mit dem LabelWerk-Treiber und den Einstellungen dieses Druckers an")
                      : tr("Zuerst den Treiber installieren"))
                .transition(.opacity)
            case .link(let queue):
                Button {
                    onLink(queue)
                } label: {
                    Label(tr("Verknüpfen"), systemImage: "link")
                }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                .transition(.opacity)
            case .unavailable:
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
                    .help(subtitle)
            }
        }
    }
}

import SwiftUI
import LabelWerkKit

// MARK: - „Auch als macOS-Drucker installieren“

/// Schalter für die Hinzufügen-Abläufe (Suche, manuell): Der Drucker wird nach dem Hinzufügen
/// zusätzlich als macOS-Drucker mit dem LabelWerk-Treiber eingerichtet (Netzwerk und USB).
struct MacPrinterInstallToggle: View {
    @Binding var isOn: Bool
    var compact: Bool = false

    /// Schlüssel der gemerkten Wahl (`@AppStorage`, Standard: ein).
    static let storageKey = "LabelWerk.setup.installMacPrinterOnAdd"

    private var installer: DriverInstaller { DriverInstaller.shared }

    /// Treiber installiert oder aus dem App-Paket installierbar?
    @MainActor
    static var isAvailable: Bool {
        DriverInstaller.shared.isInstalled || DriverInstaller.shared.hasPayload
    }

    /// Soll nach dem Hinzufügen eines Druckers mit dieser Verbindung installiert werden?
    @MainActor
    static func shouldInstall(isOn: Bool, descriptor: ConnectionDescriptor) -> Bool {
        isOn && isAvailable && PrinterInstallRequest.supports(descriptor)
    }

    private var effective: Binding<Bool> {
        Binding(
            get: { isOn && Self.isAvailable },
            set: { isOn = $0 }
        )
    }

    private var detail: String {
        if !Self.isAvailable {
            return tr("Treiber nicht verfügbar – der Drucker wird nur in LabelWerk eingerichtet.")
        }
        if installer.isInstalled {
            return tr("Netzwerk- und USB-Drucker erscheinen danach in jedem Druckdialog.")
        }
        return tr("Der LabelWerk-Treiber wird dabei installiert (Administratorpasswort).")
    }

    var body: some View {
        Group {
            if compact {
                Toggle(isOn: effective) {
                    Text(tr("Auch als macOS-Drucker installieren"))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help(detail)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    IconBadge(systemImage: "printer.filled.and.paper", tint: Theme.teal, size: 26)
                        .saturation(effective.wrappedValue ? 1 : 0.3)
                        .opacity(effective.wrappedValue ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("Auch als macOS-Drucker installieren"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(tr("Auch als macOS-Drucker installieren"), isOn: effective)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .disabled(!Self.isAvailable)
        .task { @MainActor in
            if installer.snapshot == nil { await installer.refresh() }
        }
    }
}

// MARK: - Einstieg „Drucker installieren“

/// Hinweiskarte mit Einstieg in den Installationsassistenten (Onboarding, leere Zustände).
struct PrinterSetupEntryCard: View {
    let action: () -> Void

    var body: some View {
        GlassCard(padding: 14, tint: Theme.violet) {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(systemImage: "printer.filled.and.paper", tint: Theme.violet, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Netzwerkdrucker installieren"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(tr("Wie unter Windows: Drucker finden, Modell erkennen, installieren – danach druckt jedes Programm direkt auf den Zebra-Drucker."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: action) {
                    Label(tr("Installieren …"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.labelWerkPrimary)
                .help(tr("Installationsassistent öffnen (⌥⌘N)"))
            }
        }
        .cardHoverEffect()
    }
}

// MARK: - Start mit „--setup“

/// Das Installationspaket öffnet die App nach der Installation mit `--setup`: Dann erscheint
/// (nach abgeschlossenem Erststart-Assistenten) sofort der Installationsassistent.
@MainActor
enum PrinterSetupLaunch {
    static let argument = "--setup"
    private static var handled = false

    /// `true` genau einmal je Programmstart, wenn die App mit `--setup` gestartet wurde.
    static func consumeSetupRequest() -> Bool {
        guard !handled else { return false }
        handled = true
        return ProcessInfo.processInfo.arguments.contains(argument)
    }
}

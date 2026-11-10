import AppKit
import SwiftUI
import LabelWerkKit

/// Seitenleiste: Drucker mit Live-Status, gefundene Zebra-Drucker im Netzwerk und globale Bereiche.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var printerToRemove: PrinterSession?
    @State private var printerToRename: PrinterSession?
    @State private var renameDraft = ""

    var body: some View {
        @Bindable var model = model
        let networkPrinters = model.networkDiscovery.newPrinters
        List(selection: $model.selection) {
            Section(tr("Drucker")) {
                if model.sessions.isEmpty && model.preferences.showDemoPrinter {
                    Button {
                        model.addDemoPrinter()
                    } label: {
                        Label(tr("Demo-Drucker ausprobieren"), systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { session in
                    PrinterSidebarRow(session: session)
                        .tag(SidebarItem.printer(session.id))
                        .contextMenu { contextMenu(for: session) }
                }
                .onMove { source, destination in
                    model.movePrinters(fromOffsets: source, toOffset: destination)
                }
            }

            // Wie unter Windows: Zebra-Drucker im Netzwerk, die noch nicht eingerichtet sind
            // (automatische Suche, `NetworkDiscoveryService`).
            if !networkPrinters.isEmpty {
                Section {
                    ForEach(networkPrinters) { printer in
                        NetworkPrinterSidebarRow(printer: printer) {
                            model.openInstallWizard(for: printer)
                        }
                        .contextMenu { networkContextMenu(for: printer) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(tr("Im Netzwerk"))
                        if model.networkDiscovery.isSearching {
                            ProgressView()
                                .controlSize(.mini)
                                .transition(.opacity)
                        }
                    }
                }
            }

            Section(tr("Werkzeuge")) {
                Label(tr("Etiketten-Designer"), systemImage: "pencil.and.ruler")
                    .tag(SidebarItem.designer)
                Label(tr("Drucker suchen"), systemImage: "dot.radiowaves.left.and.right")
                    .tag(SidebarItem.discover)
                Label(tr("Auftragsverlauf"), systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                Label(tr("Treiber & Warteschlangen"), systemImage: "shippingbox")
                    .tag(SidebarItem.driver)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    model.isInstallWizardPresented = true
                } label: {
                    Label(tr("Netzwerkdrucker installieren …"), systemImage: "printer.filled.and.paper")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkSecondary)
                .help(tr("Drucker im Netzwerk finden und als macOS-Drucker mit dem LabelWerk-Treiber installieren (⌥⌘N)"))
                Button {
                    model.isAddPrinterPresented = true
                } label: {
                    Label(tr("Drucker hinzufügen"), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labelWerkPrimary)
            }
            .padding(12)
        }
        .confirmationDialog(
            tr("Drucker entfernen?"),
            isPresented: Binding(get: { printerToRemove != nil }, set: { if !$0 { printerToRemove = nil } }),
            presenting: printerToRemove
        ) { session in
            Button(tr("Entfernen"), role: .destructive) { model.removePrinter(session.id) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: { session in
            Text(tr("„%@“ wird aus LabelWerk entfernt. Eine eingerichtete macOS-Warteschlange bleibt erhalten.", session.displayName))
        }
        .alert(
            tr("Drucker umbenennen"),
            isPresented: Binding(get: { printerToRename != nil }, set: { if !$0 { printerToRename = nil } }),
            presenting: printerToRename
        ) { session in
            TextField(tr("Name"), text: $renameDraft)
            Button(tr("Umbenennen")) {
                let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { session.saved.name = name }
            }
            Button(tr("Abbrechen"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func contextMenu(for session: PrinterSession) -> some View {
        if session.connectionState.isConnected {
            Button(tr("Trennen")) { Task { await session.disconnect() } }
        } else {
            Button(tr("Verbinden")) { Task { await session.connect() } }
        }
        Button(tr("Testetikett drucken")) { Task { await session.printTestLabel() } }
        Button(tr("Etikett vorschieben")) { Task { await session.perform(.feedLabel) } }
        Divider()
        Button(session.saved.isFavorite ? tr("Aus Favoriten entfernen") : tr("Zu Favoriten")) {
            session.saved.isFavorite.toggle()
        }
        Button(tr("Umbenennen …")) {
            renameDraft = session.displayName
            printerToRename = session
        }
        Divider()
        Button(tr("Entfernen …"), role: .destructive) { printerToRemove = session }
    }

    @ViewBuilder
    private func networkContextMenu(for printer: DiscoveredPrinter) -> some View {
        Button(tr("Hinzufügen …")) { model.openInstallWizard(for: printer) }
        Button(tr("Nur in LabelWerk hinzufügen")) { model.addPrinter(from: printer) }
        Divider()
        Button(tr("In „Drucker suchen“ anzeigen")) { model.selection = .discover }
        if let host = NetworkPrinterSidebarRow.host(of: printer) {
            Button(tr("Adresse kopieren")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(host, forType: .string)
            }
        }
    }
}

/// Zeile eines gefundenen, noch nicht eingerichteten Zebra-Druckers („Im Netzwerk“): Name, Modell und
/// Adresse, „Hinzufügen“ öffnet den Installationsassistenten mit dieser Adresse.
struct NetworkPrinterSidebarRow: View {
    let printer: DiscoveredPrinter
    let onAdd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var hovering = false

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        let tint = DiscoverySourceStyle.tint(printer.source)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: DiscoveryMatcher.model(for: printer)?.systemImage ?? "printer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white, Theme.accent)
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(printer.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(action: onAdd) {
                Text(tr("Hinzufügen"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white : Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(hovering ? Theme.accent : Theme.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
            .help(tr("Drucker einrichten – der Installationsassistent öffnet sich mit dieser Adresse"))
        }
        .padding(.vertical, 3)
        .help(DiscoveryDetailText.title(for: "identifiedBy") + ": "
              + DiscoveryDetailText.value(for: "identifiedBy", raw: printer.details["identifiedBy"] ?? ""))
    }

    /// „ZD621 · 10.62.13.20“.
    private var subtitle: String {
        let model = DiscoveryMatcher.model(for: printer)?.displayName
            ?? printer.modelHint.flatMap(ZebraIdentifiers.shortModelName(from:))
        return [model, Self.host(of: printer)].compactMap { $0 }.joined(separator: " · ")
    }

    static func host(of printer: DiscoveredPrinter) -> String? {
        guard case .tcp(let host, _) = printer.descriptor else { return nil }
        return host
    }
}

/// Zeile eines Druckers in der Seitenleiste.
struct PrinterSidebarRow: View {
    let session: PrinterSession
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [session.accentColor, session.accentColor.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: session.model?.systemImage ?? "printer")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.bounce, value: session.labelsPrintedThisSession)
                    }
                StatusOrb(state: session.state, size: 9)
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if session.saved.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if session.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.scale.combined(with: .opacity))
            } else if let first = session.alerts.first, first.severity >= .warning {
                Image(systemName: first.systemImage)
                    .foregroundStyle(first.severity.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 3)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: session.state)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: session.isBusy)
    }

    private var subtitle: String {
        if let activity = session.activity { return activity }
        if let alert = session.alerts.first, alert.severity >= .warning { return tr(alert.title) }
        return "\(session.state.displayName) · \(session.saved.descriptor.displayString)"
    }
}

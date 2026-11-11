import AppKit
import SwiftUI
import LabelWerkKit

/// Seitenleiste: Drucker mit Live-Status, Hinweis auf neue Zebra-Drucker und globale Bereiche.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var printerToRemove: PrinterSession?
    @State private var printerToRename: PrinterSession?
    @State private var renameDraft = ""

    var body: some View {
        @Bindable var model = model
        let newPrinterCount = model.networkDiscovery.newDevices.count
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
                // Wie unter Windows findet LabelWerk Zebra-Drucker von selbst (`NetworkDiscoveryService`) –
                // hier nur eine Zeile mit ihrer Zahl; die Liste zeigt „Drucker suchen“.
                if newPrinterCount > 0 {
                    NewPrintersSidebarRow(count: newPrinterCount, isSearching: model.networkDiscovery.isSearching) {
                        model.selection = .discover
                    }
                    .transition(.opacity)
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
}

/// Eine Zeile „Neue Zebra-Drucker [4]“ (nur bei mindestens einem neuen Drucker): öffnet „Drucker suchen“
/// mit der Liste. Gezählt werden Geräte, nicht Suchtreffer (`NetworkDiscoveryService.newDevices`).
struct NewPrintersSidebarRow: View {
    let count: Int
    let isSearching: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isSearching && !reduceMotion)
                    }
                Text(tr("Neue Zebra-Drucker"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: count)
        .help(tr("Gefundene Zebra-Drucker in „Drucker suchen“ anzeigen und hinzufügen"))
        .accessibilityLabel(count == 1 ? tr("1 neuer Zebra-Drucker") : tr("%d neue Zebra-Drucker", count))
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

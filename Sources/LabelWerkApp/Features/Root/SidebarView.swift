import SwiftUI
import LabelWerkKit

/// Seitenleiste: Drucker mit Live-Status und globale Bereiche.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var printerToRemove: PrinterSession?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section(tr("Drucker")) {
                if model.sessions.isEmpty {
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
            Button {
                model.isAddPrinterPresented = true
            } label: {
                Label(tr("Drucker hinzufügen"), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.labelWerkPrimary)
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
        Divider()
        Button(tr("Entfernen …"), role: .destructive) { printerToRemove = session }
    }
}

/// Zeile eines Druckers in der Seitenleiste.
struct PrinterSidebarRow: View {
    let session: PrinterSession

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
                    .symbolEffect(.pulse, options: .repeating)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 3)
        .animation(Motion.spring, value: session.state)
        .animation(Motion.spring, value: session.isBusy)
    }

    private var subtitle: String {
        if let activity = session.activity { return activity }
        if let alert = session.alerts.first, alert.severity >= .warning { return alert.title }
        return "\(session.state.displayName) · \(session.saved.descriptor.displayString)"
    }
}

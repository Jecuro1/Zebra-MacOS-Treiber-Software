import AppKit
import SwiftUI
import LabelWerkKit

/// Fenster des Menüleisten-Extras: Live-Status aller Drucker und Schnellaktionen.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if model.sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "printer")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.brandGradient)
                    Text(tr("Noch kein Drucker eingerichtet"))
                        .font(.system(size: 13, weight: .semibold))
                    Button(tr("Drucker hinzufügen …")) {
                        openMain()
                        model.isAddPrinterPresented = true
                    }
                    .buttonStyle(.labelWerkPrimary)
                    .controlSize(.small)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.sessions) { session in
                            MenuBarPrinterRow(session: session) {
                                model.selection = .printer(session.id)
                                openMain()
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 420)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 360)
        .background(AnimatedBackground(style: .subtle))
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: "printer.filled.and.paper", tint: Theme.violet, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("LabelWerk")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            StatusOrb(state: model.aggregateState, size: 11)
        }
        .padding(12)
    }

    private var summary: String {
        let count = model.sessions.count
        let alerts = model.activeAlertCount
        if alerts > 0 { return tr("%d Meldungen bei %d Druckern", alerts, count) }
        if count == 0 { return tr("Keine Drucker") }
        let ready = model.sessions.filter { $0.state == .ready || $0.state == .printing }.count
        return tr("%d von %d Druckern bereit", ready, count)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                openMain()
            } label: {
                Label(tr("LabelWerk öffnen"), systemImage: "macwindow")
            }
            .buttonStyle(.labelWerkPlain)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("Einstellungen"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("LabelWerk beenden"))
        }
        .padding(8)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarPrinterRow: View {
    let session: PrinterSession
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusOrb(state: session.state, size: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(session.alerts.first.map { $0.severity.color } ?? .secondary)
                        .lineLimit(2)
                }
                Spacer()
                if session.isBusy {
                    ProgressRing(progress: session.progress, size: 16, lineWidth: 2.5)
                }
                Button(action: open) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("Im Hauptfenster öffnen"))
            }
            if hovering || !session.alerts.isEmpty {
                HStack(spacing: 6) {
                    quickButton(tr("Vorschub"), "arrow.down.to.line") { await session.perform(.feedLabel) }
                    quickButton(tr("Test"), "checkmark.seal") { await session.printTestLabel() }
                    if session.state == .paused {
                        quickButton(tr("Fortsetzen"), "play.fill") { await session.perform(.resume) }
                    } else {
                        quickButton(tr("Pause"), "pause.fill") { await session.perform(.pause) }
                    }
                    quickButton(tr("Kalibrieren"), "ruler") { await session.perform(.calibrate) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .labelWerkGlass(cornerRadius: 12, tint: session.alerts.first?.severity.color)
        .onHover { inside in withAnimation(Motion.snappy) { hovering = inside } }
    }

    private var detail: String {
        if let activity = session.activity { return activity }
        if let alert = session.alerts.first { return alert.title }
        return "\(session.state.displayName) · \(session.saved.descriptor.displayString)"
    }

    private func quickButton(_ title: String, _ symbol: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.labelWerkSecondary)
        .controlSize(.small)
        .disabled(!session.connectionState.isConnected || session.isBusy)
    }
}

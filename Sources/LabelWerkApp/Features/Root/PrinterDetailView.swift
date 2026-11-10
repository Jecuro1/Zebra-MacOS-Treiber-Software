import SwiftUI
import LabelWerkKit

/// Detailansicht eines Druckers: Kopfbereich, animierte Tab-Leiste und der gewählte Bereich.
struct PrinterDetailView: View {
    @Bindable var session: PrinterSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            PrinterHeaderView(session: session)
                .padding(.horizontal, Theme.Metrics.paddingLarge)
                .padding(.top, Theme.Metrics.padding)

            AnimatedTabBar(
                items: session.availableSections,
                selection: $session.section,
                title: { $0.title },
                systemImage: { $0.systemImage }
            )
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.vertical, 12)

            ZStack {
                sectionContent(session.section)
                    .id(session.section)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 14)),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: session.section)
        }
        .background {
            AnimatedBackground(style: .state(session.state))
                .ignoresSafeArea()
        }
        .navigationTitle(session.displayName)
        .navigationSubtitle(session.model?.displayName ?? session.saved.descriptor.displayString)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.refresh() }
                } label: {
                    Label(tr("Aktualisieren"), systemImage: "arrow.clockwise")
                }
                .help(tr("Status aktualisieren (⌘R)"))

                Button {
                    Task { await session.printTestLabel() }
                } label: {
                    Label(tr("Testetikett"), systemImage: "printer.dotmatrix.filled.and.paper")
                }
                .help(tr("Testetikett drucken (⇧⌘T)"))
            }
        }
        .onAppear {
            if let pending = model.pendingSection {
                session.section = pending
                model.pendingSection = nil
            }
            if !session.availableSections.contains(session.section) {
                session.section = .overview
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: PrinterSection) -> some View {
        switch section {
        case .overview: DashboardView(session: session)
        case .preferences: PrintPreferencesView(session: session)
        case .stocks: StocksView(session: session)
        case .tools: ToolsView(session: session)
        case .terminal: TerminalView(session: session)
        case .files: FilesView(session: session)
        case .network: NetworkView(session: session)
        case .maintenance: MaintenanceView(session: session)
        case .rfid: RFIDView(session: session)
        case .firmware: FirmwareView(session: session)
        }
    }
}

/// Kopfbereich mit Name, Modell, Verbindung, Status und Verbindungsknopf.
struct PrinterHeaderView: View {
    @Bindable var session: PrinterSession
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconBadge(systemImage: session.model?.systemImage ?? "printer", tint: session.accentColor, size: 46)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if isRenaming {
                        TextField(tr("Name"), text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.Typography.title)
                            .frame(maxWidth: 320)
                            .onSubmit(commitRename)
                            .onExitCommand { isRenaming = false }
                    } else {
                        Text(session.displayName)
                            .font(Theme.Typography.title)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                draftName = session.displayName
                                isRenaming = true
                            }
                            .help(tr("Doppelklicken zum Umbenennen"))
                    }
                    StatusPill(state: session.state)
                }
                HStack(spacing: 8) {
                    Label(session.model?.displayName ?? tr("Unbekanntes Modell"), systemImage: "tag")
                    Text("·").foregroundStyle(.tertiary)
                    Label(session.saved.descriptor.displayString, systemImage: session.saved.descriptor.systemImage)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(session.resolution.dpi) dpi · \(session.saved.language.displayName)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }

            Spacer()

            if let activity = session.activity {
                HStack(spacing: 8) {
                    ProgressRing(progress: session.progress, size: 22, lineWidth: 3)
                    Text(activity)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            connectButton
        }
        .animation(Motion.spring, value: session.activity)
    }

    @ViewBuilder
    private var connectButton: some View {
        switch session.connectionState {
        case .connected:
            Button {
                Task { await session.disconnect() }
            } label: {
                Label(tr("Trennen"), systemImage: "bolt.slash")
            }
            .buttonStyle(.labelWerkSecondary)
        case .connecting:
            Button {} label: {
                Label(tr("Verbinde …"), systemImage: "bolt.horizontal")
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(true)
        case .disconnected, .failed:
            Button {
                Task { await session.connect() }
            } label: {
                Label(tr("Verbinden"), systemImage: "bolt.fill")
            }
            .buttonStyle(.labelWerkPrimary)
        }
    }

    private func commitRename() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.saved.name = name }
        isRenaming = false
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

/// Druckeinstellungen eines Druckers – das Gegenstück zu „Druckeinstellungen“ des Windows-Treibers
/// (Optionen, Erweitertes Setup, Dithering, Benutzerdefinierte Befehle), hier auf einer Seite mit
/// Live-Vorschauen. Bearbeitet `session.saved.settings` (wird automatisch gespeichert) und überträgt
/// die Werte auf Wunsch an den Drucker bzw. als Standard der macOS-Warteschlange.
struct PrintPreferencesView: View {
    @Bindable var session: PrinterSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Zuletzt an den Drucker übertragene bzw. von ihm gelesene Werte (für den Abgleich-Hinweis).
    /// Wird je Drucker in `PrintPrefsSyncStore` gesichert und übersteht so Bereichswechsel und Neustarts.
    @State private var baseline: PrintSettings?
    @State private var pulseTokens: [PrintPrefsField: Int] = [:]
    /// Sichtbarer Abschnitt (über `scrollPosition`); `nil` am Anfang, damit der Kopfbereich sichtbar bleibt.
    @State private var visibleSection: PrintPrefsSection?
    @State private var appeared = false
    @State private var isApplying = false
    @State private var isReading = false
    @State private var isUpdatingCUPS = false
    @State private var confirmPermanent = false
    @State private var confirmReset = false
    @State private var showQueueHint = false
    @State private var successTrigger = 0
    @Namespace private var jumpNamespace

    init(session: PrinterSession) {
        self._session = Bindable(session)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    private var pendingFields: [PrintPrefsField] {
        guard let baseline else { return [] }
        return PrintPrefsField.differences(session.saved.settings, baseline)
    }

    private var overriddenCount: Int {
        PrintPrefsField.allCases.filter { $0.isOverridden(in: session.saved.settings) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                header
                    .modifier(PrintPrefsAppear(index: 0, appeared: appeared, reduceMotion: reduceMotion))

                VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
                    PrintPrefsQualityCard(settings: $session.saved.settings, session: session,
                                          pulse: pulseTokens, reduceMotion: reduceMotion)
                        .modifier(PrintPrefsAppear(index: 1, appeared: appeared, reduceMotion: reduceMotion))
                        .id(PrintPrefsSection.quality)
                    PrintPrefsMediaCard(settings: $session.saved.settings, session: session,
                                        pulse: pulseTokens, reduceMotion: reduceMotion)
                        .modifier(PrintPrefsAppear(index: 2, appeared: appeared, reduceMotion: reduceMotion))
                        .id(PrintPrefsSection.media)
                    PrintPrefsPositionCard(settings: $session.saved.settings, session: session,
                                           pulse: pulseTokens, reduceMotion: reduceMotion)
                        .modifier(PrintPrefsAppear(index: 3, appeared: appeared, reduceMotion: reduceMotion))
                        .id(PrintPrefsSection.position)
                    PrintPrefsImageCard(settings: $session.saved.settings, session: session,
                                        reduceMotion: reduceMotion)
                        .modifier(PrintPrefsAppear(index: 4, appeared: appeared, reduceMotion: reduceMotion))
                        .id(PrintPrefsSection.image)
                    PrintPrefsAdvancedCard(settings: $session.saved.settings, session: session,
                                           reduceMotion: reduceMotion)
                        .modifier(PrintPrefsAppear(index: 5, appeared: appeared, reduceMotion: reduceMotion))
                        .id(PrintPrefsSection.advanced)
                }
                .scrollTargetLayout()
            }
            .padding(.horizontal, Theme.Metrics.paddingLarge)
            .padding(.top, 6)
            .padding(.bottom, Theme.Metrics.paddingLarge)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $visibleSection)
        .safeAreaInset(edge: .top, spacing: 0) {
            jumpBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .sensoryFeedback(.success, trigger: successTrigger)
        .onAppear {
            if baseline == nil {
                // Unbekannter Stand: Jeder eigene Wert gilt als „noch nicht gesendet“.
                baseline = PrintPrefsSyncStore.baseline(for: session.id) ?? .default
            }
            appeared = true
        }
        .onChange(of: baseline) { _, newValue in
            guard let newValue else { return }
            PrintPrefsSyncStore.store(newValue, for: session.id,
                                      knownPrinterIDs: Set(model.sessions.map { $0.id }))
        }
        .confirmationDialog(tr("Einstellungen dauerhaft im Drucker speichern?"), isPresented: $confirmPermanent,
                            titleVisibility: .visible) {
            Button(tr("Dauerhaft speichern")) { send(permanently: true) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Die Werte werden übertragen und mit ^JUS im Drucker gespeichert. Sie gelten dann auch nach dem Ausschalten und für andere Computer."))
        }
        .confirmationDialog(tr("Alle Druckeinstellungen zurücksetzen?"), isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button(tr("Zurücksetzen"), role: .destructive) { resetToDefaults() }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Alle Werte stehen danach wieder auf „Druckerwert“, Rasterung und Kompression auf Standard. Der Drucker selbst wird nicht verändert."))
        }
        .alert(tr("Keine macOS-Warteschlange eingerichtet"), isPresented: $showQueueHint) {
            if !session.isVirtual {
                Button(tr("Zum Treiber")) { model.selection = .driver }
            }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(session.isVirtual
                 ? tr("Der Demo-Drucker ist nur in LabelWerk verfügbar und hat keine macOS-Warteschlange.")
                 : tr("Damit alle Programme (Vorschau, Safari, Office …) diese Einstellungen verwenden, richte unter „Treiber“ eine macOS-Warteschlange für diesen Drucker ein."))
        }
    }

    // MARK: - Kopfbereich

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(tr("Druckeinstellungen"),
                          subtitle: tr("Treiber-Standardwerte für „%@“ – gelten für Aufträge aus LabelWerk und für die macOS-Warteschlange.", session.displayName),
                          systemImage: "slider.horizontal.3")
            PrintPrefsFlowLayout(spacing: 8, lineSpacing: 8) {
                summaryChip(symbol: session.model?.systemImage ?? "printer",
                            text: session.model?.displayName ?? tr("Unbekanntes Modell"))
                Button {
                    session.section = .stocks
                } label: {
                    summaryChip(symbol: "square.stack.3d.up", text: session.stock.name, showsChevron: true)
                }
                .buttonStyle(.plain)
                .help(tr("Etikettenformat ändern"))
                summaryChip(symbol: "circle.grid.3x3", text: session.resolution.displayName)
                summaryChip(symbol: PrintPrefsSymbols.symbol(for: session.saved.language),
                            text: session.saved.language.displayName)
                summaryChip(symbol: "slider.horizontal.3",
                            text: tr("%d eigene Werte · %d Druckerwerte", overriddenCount,
                                     PrintPrefsField.allCases.count - overriddenCount))
                if let queue = session.saved.cupsQueueName {
                    summaryChip(symbol: "printer.dotmatrix", text: tr("macOS: %@", queue))
                }
            }
        }
    }

    private func summaryChip(symbol: String, text: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.brandGradient)
            Text(text)
                .lineLimit(1)
                .contentTransition(.numericText())
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.subtleFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
        .animation(reduceMotion ? nil : Motion.snappy, value: text)
    }

    // MARK: - Sprungleiste

    private var jumpBar: some View {
        HStack(spacing: 2) {
            ForEach(PrintPrefsSection.allCases) { section in
                jumpChip(section)
            }
        }
        .padding(4)
        .labelWerkGlass(cornerRadius: 14)
        .animation(reduceMotion ? nil : Motion.spring, value: visibleSection)
        .animation(reduceMotion ? nil : Motion.snappy, value: pendingFields)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func jumpChip(_ section: PrintPrefsSection) -> some View {
        let isActive = (visibleSection ?? .quality) == section
        let hasPending = pendingFields.contains { Self.section(of: $0) == section }
        return Button {
            withAnimation(reduceMotion ? nil : Motion.spring) { visibleSection = section }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.bounce, value: isActive)
                Text(section.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                if hasPending {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.75))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                if isActive {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "jump", in: jumpNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(hasPending ? tr("Enthält Änderungen, die noch nicht an den Drucker gesendet wurden") : section.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    static func section(of field: PrintPrefsField) -> PrintPrefsSection {
        switch field {
        case .darkness, .speed: return .quality
        case .mediaType, .tracking, .printMode, .backfeed: return .media
        case .labelTop, .labelLeft, .tearOff: return .position
        }
    }

    // MARK: - Aktionsleiste

    /// Drei Stufen: volle Beschriftung → nur Symbole → zusätzlich gekürzter Hinweistext.
    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                syncIndicator
                    .fixedSize()
                Spacer(minLength: 8)
                actionButtons(compact: false)
            }
            HStack(spacing: 12) {
                syncIndicator
                    .fixedSize()
                Spacer(minLength: 8)
                actionButtons(compact: true)
            }
            HStack(spacing: 12) {
                syncIndicator
                Spacer(minLength: 8)
                actionButtons(compact: true)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .labelWerkGlass(cornerRadius: 16)
        .padding(.horizontal, Theme.Metrics.paddingLarge)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: Theme.Metrics.contentMaxWidth + Theme.Metrics.paddingLarge * 2)
        .frame(maxWidth: .infinity)
    }

    private var syncIndicator: some View {
        let pending = pendingFields
        let connected = session.connectionState.isConnected
        return HStack(spacing: 10) {
            Image(systemName: pending.isEmpty ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(pending.isEmpty ? Theme.ready : Theme.warning)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: pending.count)
            VStack(alignment: .leading, spacing: 1) {
                Text(pending.isEmpty ? tr("Mit dem Drucker abgeglichen") : tr("Änderungen noch nicht an den Drucker gesendet"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Group {
                    if !pending.isEmpty {
                        Text(pending.map(\.title).joined(separator: ", "))
                    } else if !connected {
                        Text(tr("Drucker nicht verbunden – Werte werden lokal gespeichert"))
                    } else {
                        Text(tr("Änderungen werden automatisch für neue Aufträge gespeichert"))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: pending)
        .accessibilityElement(children: .combine)
    }

    private func actionButtons(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    importProfile()
                } label: {
                    Label(tr("Profil importieren …"), systemImage: "square.and.arrow.down")
                }
                Button {
                    exportProfile()
                } label: {
                    Label(tr("Profil exportieren …"), systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label(tr("Auf Standard zurücksetzen …"), systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Profil importieren/exportieren, zurücksetzen"))

            Button {
                readFromPrinter()
            } label: {
                barLabel(tr("Vom Drucker lesen"), symbol: "arrow.down.circle", busy: isReading, compact: compact)
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(!session.supportsStatus || isReading)
            .help(session.supportsStatus
                  ? tr("Aktuelle Werte aus dem Drucker übernehmen")
                  : tr("Diese Verbindung kann keine Werte lesen (nur Senden)."))

            Button {
                applyAsMacDefault()
            } label: {
                barLabel(tr("Als macOS-Standard"), symbol: "macwindow.badge.plus", busy: isUpdatingCUPS, compact: compact)
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(isUpdatingCUPS)
            .help(tr("Als Standardwerte der macOS-Warteschlange übernehmen – gilt für alle Programme"))

            Button {
                confirmPermanent = true
            } label: {
                barLabel(tr("Dauerhaft speichern"), symbol: "externaldrive.badge.checkmark", busy: false, compact: compact)
            }
            .buttonStyle(.labelWerkSecondary)
            .disabled(isApplying || session.isBusy)
            .help(tr("An den Drucker senden und dort dauerhaft speichern (^JUS)"))

            Button {
                send(permanently: false)
            } label: {
                barLabel(tr("An Drucker senden"), symbol: "paperplane.fill", busy: isApplying, compact: false)
            }
            .buttonStyle(.labelWerkPrimary)
            .disabled(isApplying || session.isBusy)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(tr("Einstellungen jetzt an den Drucker übertragen (⌘↩)"))
            .overlay {
                CelebrationBurst(trigger: successTrigger, colors: [Theme.violet, Theme.teal, Theme.ready])
                    .frame(width: 220, height: 160)
                    .allowsHitTesting(false)
            }
        }
    }

    private func barLabel(_ title: String, symbol: String, busy: Bool, compact: Bool) -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressRing(progress: nil, size: 13, lineWidth: 2)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: symbol)
                    .transition(.scale.combined(with: .opacity))
            }
            if !compact {
                Text(title)
                    .lineLimit(1)
            }
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: busy)
    }

    // MARK: - Aktionen

    private func send(permanently: Bool) {
        guard !isApplying else { return }
        isApplying = true
        let snapshot = session.saved.settings
        Task {
            let ok = await session.applySettings(snapshot, permanently: permanently)
            isApplying = false
            if ok {
                withAnimation(reduceMotion ? nil : Motion.spring) { baseline = snapshot }
                successTrigger += 1
            }
        }
    }

    private func applyAsMacDefault() {
        guard let queue = session.saved.cupsQueueName, !queue.isEmpty else {
            showQueueHint = true
            return
        }
        guard !isUpdatingCUPS else { return }
        isUpdatingCUPS = true
        let settings = session.saved.settings
        let stock = session.stock
        let language = session.saved.language
        Task {
            do {
                try await CUPSService.setDefaults(queue: queue, settings: settings,
                                                  stock: stock.isCustom ? nil : stock, language: language)
                let message = stock.isCustom
                    ? tr("Alle Programme drucken auf „%@“ mit diesen Einstellungen. Eigene Etikettenformate im Druckdialog als Papiergröße wählen.", queue)
                    : tr("Alle Programme drucken auf „%@“ jetzt mit diesen Einstellungen.", queue)
                model.toast(tr("macOS-Standard aktualisiert"), message: message, style: .success)
            } catch {
                model.toast(tr("macOS-Standard konnte nicht gesetzt werden"),
                            message: PrinterSession.describe(error), style: .error)
            }
            isUpdatingCUPS = false
        }
    }

    private func readFromPrinter() {
        guard !isReading else { return }
        isReading = true
        Task {
            let values = await session.getvars(PrintPrefsPrinterValues.variables)
            isReading = false
            guard !values.isEmpty else {
                model.toast(tr("Keine Werte gelesen"),
                            message: tr("Der Drucker hat keine Einstellungen gemeldet. Ist er verbunden und unterstützt er SGD-Befehle?"),
                            style: .warning)
                return
            }
            let maxSpeed = session.model?.maxSpeed(session.resolution) ?? 14
            let outcome = PrintPrefsPrinterValues.merge(values, into: session.saved.settings, maxSpeed: maxSpeed)
            guard outcome.readCount > 0 else {
                model.toast(tr("Keine verwertbaren Werte"),
                            message: tr("Die Antwort des Druckers enthielt keine bekannten Einstellungen."), style: .warning)
                return
            }
            // Nur die gemeldeten Felder gelten als abgeglichen; alles andere (z. B. Rückzug, den kein
            // SGD-Befehl meldet) behält seinen bisherigen Abgleichstand.
            var synced = baseline ?? .default
            for field in outcome.read {
                field.copy(from: outcome.settings, into: &synced)
            }
            withAnimation(reduceMotion ? nil : Motion.spring) {
                session.saved.settings = outcome.settings
                baseline = synced
            }
            for field in outcome.changed {
                pulseTokens[field, default: 0] += 1
            }
            if let first = outcome.changed.map({ Self.section(of: $0) }).min(by: { Self.order($0) < Self.order($1) }) {
                withAnimation(reduceMotion ? nil : Motion.spring) { visibleSection = first }
            }
            if outcome.changed.isEmpty {
                model.toast(tr("Einstellungen sind aktuell"),
                            message: tr("%d Werte gelesen – keine Abweichung.", outcome.readCount), style: .info)
            } else {
                model.toast(tr("Vom Drucker übernommen"),
                            message: tr("%d von %d gelesenen Werten wurden aktualisiert.", outcome.changed.count, outcome.readCount),
                            style: .success)
            }
        }
    }

    private static func order(_ section: PrintPrefsSection) -> Int {
        PrintPrefsSection.allCases.firstIndex(of: section) ?? 0
    }

    private func resetToDefaults() {
        let previous = session.saved.settings
        withAnimation(reduceMotion ? nil : Motion.spring) {
            session.saved.settings = .default
        }
        for field in PrintPrefsField.differences(previous, .default) {
            pulseTokens[field, default: 0] += 1
        }
        model.toast(tr("Auf Standard zurückgesetzt"),
                    message: tr("Alle Werte stehen wieder auf „Druckerwert“."), style: .info)
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = tr("Einstellungsprofil exportieren")
        panel.nameFieldStringValue = Self.fileName(for: session.displayName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profile = PrintPrefsProfile(settings: session.saved.settings, printerName: session.displayName,
                                        modelID: session.saved.modelID, language: session.saved.language,
                                        stockID: session.saved.stockID)
        do {
            try profile.encoded().write(to: url, options: .atomic)
            model.toast(tr("Profil exportiert"), message: url.lastPathComponent, style: .success)
        } catch {
            model.toast(tr("Export fehlgeschlagen"), message: error.localizedDescription, style: .error)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = tr("Einstellungsprofil importieren")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profile: PrintPrefsProfile
        do {
            profile = try PrintPrefsProfile.decode(Data(contentsOf: url))
        } catch {
            model.toast(tr("Import fehlgeschlagen"),
                        message: tr("„%@“ ist kein gültiges LabelWerk-Einstellungsprofil.", url.lastPathComponent),
                        style: .error)
            return
        }
        let previous = session.saved.settings
        let imported = profile.settings.clamped()
        var notes: [String] = [url.lastPathComponent]
        withAnimation(reduceMotion ? nil : Motion.spring) {
            session.saved.settings = imported
        }
        for field in PrintPrefsField.differences(previous, imported) {
            pulseTokens[field, default: 0] += 1
        }
        if let stockID = profile.stockID, stockID != session.saved.stockID, let stock = model.stock(id: stockID) {
            session.saved.stockID = stockID
            notes.append(tr("Etikett: %@", stock.name))
        }
        if let language = profile.language, language != session.saved.language {
            if session.model?.supports(language) ?? true {
                session.saved.language = language
                notes.append(tr("Sprache: %@", language.displayName))
            } else {
                notes.append(tr("Sprache %@ wird von diesem Modell nicht unterstützt", language.displayName))
            }
        }
        model.toast(tr("Profil importiert"), message: notes.joined(separator: " · "), style: .success)
    }

    static func fileName(for printerName: String) -> String {
        let cleaned = printerName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tr("%@ – Druckeinstellungen.json", cleaned.isEmpty ? "LabelWerk" : cleaned)
    }
}

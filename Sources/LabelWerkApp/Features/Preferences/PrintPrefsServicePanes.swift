import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LabelWerkKit

// MARK: - Wartung

/// „Wartung“: Zurücksetzen, Kalibrieren (inkl. Echtzeituhr und Medienvorschub), Übertragen an den
/// Drucker bzw. die macOS-Warteschlange und Einstellungsprofile.
@MainActor
struct PrintPrefsMaintenancePane: View {
    let context: PrintPrefsContext
    @Environment(AppModel.self) private var model

    @State private var isCalibrating = false
    @State private var isSyncingClock = false
    @State private var isSending = false
    @State private var isUpdatingCUPS = false
    @State private var confirmPermanent = false
    @State private var successTrigger = 0

    init(context: PrintPrefsContext) {
        self.context = context
    }

    private var editor: PrintPrefsEditor { context.editor }
    private var session: PrinterSession { context.session }

    var body: some View {
        let unsent = editor.unsentPrinterSettings
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Zurücksetzen"), systemImage: "arrow.counterclockwise") {
                PrintPrefsActionRow(title: tr("Auf Standardeinstellungen zurücksetzen"),
                                    detail: tr("Alle Werte auf den Auslieferungszustand des Treibers – gespeichert wird erst mit „OK“ oder „Übernehmen“."),
                                    systemImage: "arrow.uturn.backward", tint: Theme.indigo,
                                    buttonTitle: tr("Zurücksetzen")) {
                    withAnimation(context.animation) { editor.resetToDefaults() }
                    model.toast(tr("Auf Standard zurückgesetzt"),
                                message: tr("Mit „OK“ oder „Übernehmen“ speichern, mit „Abbrechen“ verwerfen."), style: .info)
                }
                PrintPrefsActionRow(title: tr("Alle Einstellungen des Druckers verwenden"),
                                    detail: tr("Der Treiber sendet keine eigenen Werte – der Drucker behält Geschwindigkeit, Temperatur, Medientyp, Modus und Versätze."),
                                    systemImage: "printer", tint: Theme.teal,
                                    buttonTitle: tr("Festlegen")) {
                    withAnimation(context.animation) { editor.useAllPrinterValues() }
                    model.toast(tr("Druckerwerte festgelegt"),
                                message: tr("Mit „OK“ oder „Übernehmen“ speichern, mit „Abbrechen“ verwerfen."), style: .info)
                }
                PrintPrefsActionRow(title: tr("Werte vom Drucker übernehmen"),
                                    detail: session.supportsStatus
                                        ? tr("Liest die aktuellen Einstellungen des Druckers und trägt sie als Treiberwerte ein.")
                                        : tr("Diese Verbindung kann keine Werte lesen (nur Senden)."),
                                    systemImage: "arrow.down.circle", tint: Theme.printing,
                                    buttonTitle: tr("Lesen"), isBusy: editor.isReadingAll,
                                    isEnabled: session.supportsStatus) {
                    Task { await editor.readAll(session: session) }
                }
            }

            PrintPrefsGroup(tr("Kalibrieren"), systemImage: "ruler") {
                PrintPrefsActionRow(title: tr("Medien kalibrieren"),
                                    detail: tr("Misst Etikettenlänge und Sensoren neu (~JC) – nach jedem Rollenwechsel empfohlen."),
                                    systemImage: "ruler", tint: Theme.violet,
                                    buttonTitle: tr("Kalibrieren"), isBusy: isCalibrating) {
                    calibrate()
                }
                PrintPrefsActionRow(title: tr("Echtzeituhr (RTC) synchronisieren"),
                                    detail: tr("Stellt die Uhr des Druckers auf die Uhrzeit dieses Mac."),
                                    systemImage: "clock.arrow.2.circlepath", tint: Theme.magenta,
                                    buttonTitle: tr("Sync"), isBusy: isSyncingClock) {
                    syncClock()
                }
                Divider().opacity(0.5).padding(.vertical, 4)
                PrintPrefsRow(.powerUpAction, context: context, note: mediaFeedNote) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.powerUpAction, fallback: .calibrate),
                                         options: MediaFeedAction.allCases, width: 220) { tr($0.displayName) }
                }
                PrintPrefsRow(.headCloseAction, context: context) {
                    PrintPrefsMenuPicker(selection: context.binding(\.settings.headCloseAction, fallback: .calibrate),
                                         options: MediaFeedAction.allCases, width: 220) { tr($0.displayName) }
                }
            }

            PrintPrefsGroup(tr("Drucker"), systemImage: "paperplane") {
                HStack(spacing: 10) {
                    Image(systemName: unsent.isEmpty ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(unsent.isEmpty ? Theme.ready : Theme.warning)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: unsent.count)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(unsent.isEmpty ? tr("Mit dem Drucker abgeglichen") : tr("Noch nicht an den Drucker gesendet"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(unsent.isEmpty
                             ? tr("Die Werte werden außerdem mit jedem Auftrag gesendet.")
                             : unsent.map(\.summaryTitle).joined(separator: ", "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .animation(context.animation, value: unsent)
                PrintPrefsActionRow(title: tr("An den Drucker senden"),
                                    detail: tr("Überträgt Geschwindigkeit, Temperatur, Medien, Modus und Versätze sofort."),
                                    systemImage: "paperplane.fill", tint: Theme.printing,
                                    buttonTitle: tr("Senden"), isBusy: isSending,
                                    isEnabled: !session.isBusy) {
                    afterCommittingTextEditing { send(permanently: false) }
                }
                .overlay(alignment: .trailing) {
                    CelebrationBurst(trigger: successTrigger, colors: [Theme.violet, Theme.teal, Theme.ready])
                        .frame(width: 180, height: 120)
                        .allowsHitTesting(false)
                }
                PrintPrefsActionRow(title: tr("Dauerhaft im Drucker speichern"),
                                    detail: tr("Sendet die Werte und speichert sie mit ^JUS – sie gelten auch nach dem Ausschalten und für andere Computer."),
                                    systemImage: "externaldrive.badge.checkmark", tint: Theme.violet,
                                    buttonTitle: tr("Speichern …"), isEnabled: !session.isBusy && !isSending) {
                    afterCommittingTextEditing { confirmPermanent = true }
                }
                PrintPrefsActionRow(title: tr("macOS-Warteschlange"),
                                    detail: queueDetail,
                                    systemImage: "macwindow.badge.plus", tint: Theme.teal,
                                    buttonTitle: session.saved.cupsQueueName == nil ? tr("Zum Treiber") : tr("Erneut übertragen"),
                                    isBusy: isUpdatingCUPS, isEnabled: !session.isVirtual) {
                    updateQueue()
                }
            }

            PrintPrefsGroup(tr("Profil"), systemImage: "doc.badge.gearshape") {
                PrintPrefsActionRow(title: tr("Einstellungsprofil importieren"),
                                    detail: tr("Übernimmt Werte aus einer LabelWerk-Profildatei (JSON) in diesen Dialog."),
                                    systemImage: "square.and.arrow.down", tint: Theme.indigo,
                                    buttonTitle: tr("Importieren …")) {
                    importProfile()
                }
                PrintPrefsActionRow(title: tr("Einstellungsprofil exportieren"),
                                    detail: tr("Sichert die Werte dieses Dialogs als JSON – z. B. für andere Macs oder Drucker."),
                                    systemImage: "square.and.arrow.up", tint: Theme.indigo,
                                    buttonTitle: tr("Exportieren …")) {
                    afterCommittingTextEditing { exportProfile() }
                }
            }
        }
        .confirmationDialog(tr("Einstellungen dauerhaft im Drucker speichern?"), isPresented: $confirmPermanent,
                            titleVisibility: .visible) {
            Button(tr("Dauerhaft speichern")) { send(permanently: true) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Die Werte werden übertragen und mit ^JUS im Drucker gespeichert. Sie gelten dann auch nach dem Ausschalten und für andere Computer."))
        }
    }

    private var mediaFeedNote: String? {
        let s = editor.draft.settings
        if (s.powerUpAction == nil) != (s.headCloseAction == nil) {
            return tr("^MF wird nur gesendet, wenn beide Aktionen festgelegt sind.")
        }
        return context.isZPL ? nil : tr("Wirkt nur bei ZPL.")
    }

    private var queueDetail: String {
        if session.isVirtual {
            return tr("Der Demo-Drucker ist nur in LabelWerk verfügbar und hat keine macOS-Warteschlange.")
        }
        guard let queue = session.saved.cupsQueueName else {
            return tr("Keine Warteschlange eingerichtet – unter „Treiber“ anlegen, damit alle Programme diese Einstellungen nutzen.")
        }
        return editor.isDirty
            ? tr("„%@“ – nicht gespeicherte Änderungen werden mit „OK“ oder „Übernehmen“ übertragen.", queue)
            : tr("„%@“ erhält die gespeicherten Werte mit „OK“ und „Übernehmen“ als Standard.", queue)
    }

    // MARK: Aktionen

    private func calibrate() {
        guard !isCalibrating else { return }
        isCalibrating = true
        // Während der Kalibrierung kann der Drucker kurz „Etiketten leer“ melden.
        session.muteAlertNotifications(for: 20)
        Task {
            await session.perform(.calibrate)
            isCalibrating = false
        }
    }

    private func syncClock() {
        guard !isSyncingClock else { return }
        isSyncingClock = true
        Task {
            await session.syncClock()
            isSyncingClock = false
        }
    }

    private func send(permanently: Bool) {
        guard !isSending else { return }
        isSending = true
        let snapshot = editor.draft.settings.clamped()
        Task {
            let ok = await session.applySettings(snapshot, permanently: permanently)
            isSending = false
            if ok {
                withAnimation(context.animation) {
                    editor.markSent(snapshot, session: session, knownPrinterIDs: Set(model.sessions.map { $0.id }))
                }
                successTrigger += 1
            }
        }
    }

    private func updateQueue() {
        guard let queue = session.saved.cupsQueueName, !queue.isEmpty else {
            model.selection = .driver
            return
        }
        guard !isUpdatingCUPS else { return }
        isUpdatingCUPS = true
        Task {
            await PrintPrefsQueueDefaults.apply(queue: queue, session: session, model: model)
            isUpdatingCUPS = false
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = tr("Einstellungsprofil exportieren")
        panel.nameFieldStringValue = PrintPrefsProfile.fileName(for: session.displayName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let draft = editor.draft
        let profile = PrintPrefsProfile(settings: draft.settings.clamped(), printerName: session.displayName,
                                        modelID: session.saved.modelID, language: draft.language,
                                        stockID: draft.stockID)
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
        var notes: [String] = [url.lastPathComponent]
        withAnimation(context.animation) {
            editor.replaceSettings(profile.settings)
            if let stockID = profile.stockID, stockID != editor.draft.stockID, let stock = model.stock(id: stockID) {
                editor.selectTemplate(stock)
                editor.draft.settings.tracking = profile.settings.tracking
                notes.append(tr("Etikett: %@", stock.name))
            }
            if let language = profile.language, language != editor.draft.language {
                if session.model?.supports(language) ?? true {
                    editor.draft.language = language
                    notes.append(tr("Sprache: %@", language.displayName))
                } else {
                    notes.append(tr("Sprache %@ wird von diesem Modell nicht unterstützt", language.displayName))
                }
            }
        }
        model.toast(tr("Profil importiert"),
                    message: notes.joined(separator: " · ") + " – " + tr("Mit „OK“ oder „Übernehmen“ speichern."),
                    style: .success)
    }
}

// MARK: - Standardwerte der macOS-Warteschlange

/// Überträgt die gespeicherten Treiber-Standardwerte als Standard der macOS-Warteschlange
/// (`CUPSService.setDefaults`) und meldet das Ergebnis als Hinweis.
@MainActor
enum PrintPrefsQueueDefaults {
    @discardableResult
    static func apply(queue: String, session: PrinterSession, model: AppModel) async -> Bool {
        let settings = session.saved.settings
        let stock = session.stock
        let language = session.saved.language
        do {
            let approximated = try await CUPSService.setDefaults(queue: queue, settings: settings,
                                                                 stock: stock.isCustom ? nil : stock,
                                                                 language: language, resolution: session.resolution)
            var message = stock.isCustom
                ? tr("Alle Programme drucken auf „%@“ mit diesen Einstellungen. Eigene Etikettenformate im Druckdialog als Papiergröße wählen.", queue)
                : tr("Alle Programme drucken auf „%@“ jetzt mit diesen Einstellungen.", queue)
            if !approximated.isEmpty {
                // Exakte Werte gelten als Warteschlangen-Standard; der Druckdialog kennt nur die PPD-Auswahl.
                message += " " + tr("Im macOS-Druckdialog steht für %@ nur der nächstliegende Wert zur Auswahl.",
                                    approximated.joined(separator: ", "))
            }
            model.toast(tr("macOS-Standard aktualisiert"), message: message, style: .success)
            return true
        } catch {
            model.toast(tr("macOS-Standard konnte nicht gesetzt werden"),
                        message: PrinterSession.describe(error), style: .error)
            return false
        }
    }
}

// MARK: - Einheiten

/// „Einheiten“: Standard-Maßeinheit für alle Längen (Millimeter, Zoll, Punkte).
@MainActor
struct PrintPrefsUnitsPane: View {
    let context: PrintPrefsContext
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    init(context: PrintPrefsContext) {
        self.context = context
    }

    var body: some View {
        @Bindable var model = model
        let resolution = context.session.resolution
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Einheiten"), systemImage: "ruler") {
                HStack(alignment: .top, spacing: 12) {
                    Text(tr("Standard-Maßeinheiten"))
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 196, alignment: .leading)
                    Picker("", selection: $model.preferences.measurementUnit) {
                        ForEach(MeasurementUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                Divider().opacity(0.5).padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Beispiel bei %d dpi", resolution.dpi))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(spacing: 8) {
                        ForEach(MeasurementUnit.allCases) { unit in
                            let length = PrintPrefsLength(unit: unit, resolution: resolution)
                            let isSelected = unit == model.preferences.measurementUnit
                            VStack(spacing: 2) {
                                Text(length.size(widthMM: 101.6, heightMM: 152.4))
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                                Text(unit.displayName)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Theme.accent.opacity(0.12) : Theme.subtleFill)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Theme.cardStroke, lineWidth: 1)
                            }
                        }
                    }
                    .animation(context.animation, value: model.preferences.measurementUnit)
                    PrintPrefsHint(tr("Gespeichert wird unabhängig von der Anzeige: Etikettengrößen in Millimetern, Versätze in Druckpunkten."))
                }
                Divider().opacity(0.5).padding(.vertical, 4)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        openURL(url)
                    }
                } label: {
                    Label(tr("Regionale Systemeinstellungen öffnen"), systemImage: "globe")
                }
                .buttonStyle(.link)
                .help(tr("Sprache & Region in den Systemeinstellungen (Zahlenformat, Maßsystem)"))
            }
        }
    }
}

// MARK: - Hilfe und Über

/// „Hilfe und Über“: Zugang zur Hilfe sowie Treiber-, App- und Druckerinformationen.
@MainActor
struct PrintPrefsAboutPane: View {
    let context: PrintPrefsContext
    let onShowHelp: () -> Void

    init(context: PrintPrefsContext, onShowHelp: @escaping () -> Void) {
        self.context = context
        self.onShowHelp = onShowHelp
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        let session = context.session
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            PrintPrefsGroup(tr("Hilfe"), systemImage: "questionmark.circle") {
                PrintPrefsActionRow(title: tr("Hilfe zu den Druckeinstellungen"),
                                    detail: tr("Erklärt jede Option dieses Dialogs – mit Hinweisen, welche Befehle der Treiber sendet."),
                                    systemImage: "book", tint: Theme.violet, buttonTitle: tr("Hilfe öffnen")) {
                    onShowHelp()
                }
            }
            PrintPrefsGroup(tr("Über"), systemImage: "info.circle") {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "printer.dotmatrix.filled.and.paper", tint: Theme.violet, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "LabelWerk")
                            .font(Theme.Typography.title)
                        Text(tr("Treiber und Steuerzentrale für Zebra-Etikettendrucker"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)
                KeyValueRow(tr("App-Version"), appVersion, monospaced: true)
                KeyValueRow(tr("Treiberversion"), CUPSService.installedDriverVersion ?? tr("Nicht installiert"),
                            monospaced: true)
                KeyValueRow(tr("Drucker"), session.displayName)
                KeyValueRow(tr("Modell"), session.model?.displayName ?? tr("Unbekanntes Modell"))
                KeyValueRow(tr("Auflösung"), session.resolution.displayName)
                KeyValueRow(tr("Druckersprache"), session.saved.language.displayName)
                if let firmware = session.identity?.firmware {
                    KeyValueRow(tr("Firmware"), firmware, monospaced: true, copyable: true)
                }
                if let serial = session.identity?.serialNumber {
                    KeyValueRow(tr("Seriennummer"), serial, monospaced: true, copyable: true)
                }
                KeyValueRow(tr("macOS-Warteschlange"), session.saved.cupsQueueName ?? tr("Keine"))
            }
        }
    }
}

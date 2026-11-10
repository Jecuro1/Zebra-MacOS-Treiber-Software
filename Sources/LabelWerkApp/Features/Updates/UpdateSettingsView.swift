import AppKit
import SwiftUI
import LabelWerkKit

/// Einstellungen › Updates: installierte Version, automatische Suche und automatisches Laden,
/// „Jetzt suchen“ mit Status sowie der Zugriffstoken für ein privates Repository.
struct UpdateSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    @State private var tokenDraft = ""
    @State private var tokenFeedback: TokenFeedback?
    @State private var confirmRemoveToken = false

    private struct TokenFeedback: Equatable {
        var text: String
        var isError: Bool
    }

    /// Seite zum Anlegen eines fine-grained Tokens auf GitHub.
    private static let newTokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new")

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        @Bindable var model = model
        let updates: UpdateController = model.updates
        Form {
            Section(tr("Version")) {
                LabeledContent(tr("Installierte Version")) {
                    Text(updates.currentVersion?.description ?? tr("Unbekannt"))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                if let repository = updates.repository {
                    LabeledContent(tr("Update-Quelle")) {
                        HStack(spacing: 6) {
                            Text(verbatim: repository)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let url = updates.releasesPageURL {
                                Button {
                                    openURL(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(tr("Alle Versionen auf GitHub öffnen"))
                                .accessibilityLabel(tr("Alle Versionen auf GitHub öffnen"))
                            }
                        }
                    }
                }
                if let reason = updates.disabledReason {
                    note(reason, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                } else if !updates.runsFromInstalledLocation {
                    note(tr("LabelWerk läuft nicht aus dem Ordner „Programme“. Updates werden als „%@“ installiert und von dort gestartet.",
                            UpdateController.installedAppURL.path),
                         systemImage: "info.circle.fill", tint: Theme.printing)
                }
            }

            Section(tr("Automatisch")) {
                Toggle(tr("Automatisch nach Updates suchen"), isOn: $model.preferences.autoCheckUpdates)
                Toggle(tr("Updates automatisch laden"), isOn: $model.preferences.autoDownloadUpdates)
                Text(tr("LabelWerk sucht kurz nach dem Start und danach alle 6 Stunden. Installiert wird erst, wenn du „Jetzt installieren“ wählst – macOS fragt dann nach dem Administratorpasswort, und LabelWerk startet von selbst neu."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!updates.isEnabled)

            Section(tr("Status")) {
                statusRow(updates)
                if updates.update != nil {
                    HStack(spacing: 8) {
                        Button(tr("Details …")) { showDetails(updates) }
                            .buttonStyle(.labelWerkSecondary)
                        Spacer()
                        Button(updates.installButtonTitle) { updates.downloadAndInstall() }
                            .buttonStyle(.labelWerkPrimary)
                            .disabled(!updates.canInstall)
                    }
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let skipped = model.preferences.skippedUpdateTag {
                    LabeledContent(tr("Übersprungene Version")) {
                        HStack(spacing: 8) {
                            Text(verbatim: skipped)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button(tr("Wieder anbieten")) { updates.unskip() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: updates.phaseKey)

            Section(tr("Zugriff auf privates Repository")) {
                Text(tr("Nur nötig, solange das GitHub-Repository privat ist. Dafür auf GitHub einen „Fine-grained personal access token“ nur für dieses Repository mit der Berechtigung „Contents: Read-only“ anlegen und hier einfügen. Der Token liegt ausschließlich im Schlüsselbund dieses Macs."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(tr("Zugriffstoken")) {
                    Label(updates.hasToken ? tr("Im Schlüsselbund gespeichert") : tr("Keiner gespeichert"),
                          systemImage: updates.hasToken ? "key.fill" : "key")
                        .foregroundStyle(updates.hasToken ? Theme.ready : Color.secondary)
                        .contentTransition(.opacity)
                }
                SecureField(tr("Token einfügen (github_pat_…)"), text: $tokenDraft)
                    .onSubmit { saveToken(updates) }
                HStack(spacing: 8) {
                    if let url = Self.newTokenURL {
                        Button(tr("Token auf GitHub anlegen …")) { openURL(url) }
                            .buttonStyle(.link)
                    }
                    Spacer()
                    Button(tr("Entfernen"), role: .destructive) { confirmRemoveToken = true }
                        .disabled(!updates.hasToken)
                    // Kein Standard-Tastenkürzel: ↩ im Eingabefeld speichert bereits (`onSubmit`).
                    Button(tr("Speichern")) { saveToken(updates) }
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let tokenFeedback {
                    Label(tokenFeedback.text,
                          systemImage: tokenFeedback.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokenFeedback.isError ? Theme.error : Theme.ready)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .disabled(!updates.isEnabled)
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: tokenFeedback)
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .onChange(of: model.preferences.autoDownloadUpdates) { _, _ in updates.preferencesDidChange() }
        .onChange(of: model.preferences.autoCheckUpdates) { _, _ in updates.preferencesDidChange() }
        .confirmationDialog(tr("Zugriffstoken entfernen?"), isPresented: $confirmRemoveToken) {
            Button(tr("Entfernen"), role: .destructive) { removeToken(updates) }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Ohne Token findet LabelWerk keine Updates, solange das Repository privat ist."))
        }
    }

    // MARK: Teile

    private func statusRow(_ updates: UpdateController) -> some View {
        HStack(alignment: .center, spacing: 10) {
            UpdateStatusSymbol(updates: updates, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(updates.statusText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(updates.failureMessage != nil ? Theme.error : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                if updates.update != nil, updates.failureMessage == nil, !updates.isDownloading, !updates.isInstalling,
                   let update = updates.update {
                    Text(UpdateController.facts(of: update))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                if let lastCheck = updates.lastCheck {
                    Text(tr("Zuletzt gesucht: %@", lastCheck.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                if let error = updates.lastCheckError, updates.update != nil {
                    // Ein bekanntes Update bleibt bestehen – die letzte Suche ist trotzdem fehlgeschlagen.
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(tr("Jetzt suchen")) { updates.checkNow(userInitiated: true, feedback: .inline) }
                .disabled(!updates.isEnabled || updates.isChecking || updates.isInstalling)
        }
    }

    private func note(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    // MARK: Aktionen

    /// Details im Hauptfenster (Sheet) – das Fenster kommt dafür nach vorn.
    private func showDetails(_ updates: UpdateController) {
        NSApp.activate(ignoringOtherApps: true)
        if !MainWindow.bringToFront() {
            openWindow(id: "main")
        }
        updates.showDetails()
    }

    private func saveToken(_ updates: UpdateController) {
        let draft = tokenDraft
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try updates.saveToken(draft)
            tokenDraft = ""
            tokenFeedback = TokenFeedback(text: tr("Gespeichert. LabelWerk sucht jetzt mit dem Token nach Updates."),
                                          isError: false)
        } catch {
            tokenFeedback = TokenFeedback(text: error.localizedDescription, isError: true)
        }
    }

    private func removeToken(_ updates: UpdateController) {
        do {
            try updates.removeToken()
            tokenFeedback = TokenFeedback(text: tr("Der Token wurde aus dem Schlüsselbund entfernt."), isError: false)
        } catch {
            tokenFeedback = TokenFeedback(text: error.localizedDescription, isError: true)
        }
    }
}

import AppKit
import SwiftUI
import LabelWerkKit

/// App-Einstellungen (⌘,).
struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

    private enum Tab: Hashable { case general, printing, advanced, updates, about }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label(tr("Allgemein"), systemImage: "gearshape") }
                .tag(Tab.general)
            PrintingSettings()
                .tabItem { Label(tr("Drucken"), systemImage: "printer") }
                .tag(Tab.printing)
            AdvancedSettings()
                .tabItem { Label(tr("Erweitert"), systemImage: "wrench.and.screwdriver") }
                .tag(Tab.advanced)
            UpdateSettingsView()
                .tabItem { Label(tr("Updates"), systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
            AboutView()
                .tabItem { Label(tr("Über"), systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 560)
        .environment(model)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(tr("Darstellung")) {
                Picker(tr("Erscheinungsbild"), selection: $model.preferences.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(tr("Bewegung zusätzlich reduzieren"), isOn: $model.preferences.reduceMotion)
                Toggle(tr("Symbol in der Menüleiste anzeigen"), isOn: $model.preferences.showMenuBarExtra)
            }
            Section(tr("Verbindung & Status")) {
                Toggle(tr("Beim Start automatisch verbinden"), isOn: $model.preferences.autoConnect)
                VStack(alignment: .leading) {
                    HStack {
                        Text(tr("Statusabfrage alle"))
                        Spacer()
                        Text(tr("%.0f s", model.preferences.pollInterval))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.preferences.pollInterval, in: 1...30, step: 1)
                }
                Toggle(tr("Demo-Drucker anbieten"), isOn: $model.preferences.showDemoPrinter)
            }
            Section(tr("Benachrichtigungen")) {
                Toggle(tr("Mitteilungen bei Druckerfehlern"), isOn: $model.preferences.notificationsEnabled)
                Toggle(tr("Töne abspielen"), isOn: $model.preferences.playSounds)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
    }
}

private struct PrintingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(tr("Bilder & Fotos")) {
                Picker(tr("Standard-Rasterung"), selection: $model.preferences.imageDither) {
                    ForEach(DitherAlgorithm.allCases) { Text(tr($0.displayName)).tag($0) }
                }
                Text(tr("Gilt für Bilder und PDFs im Designer. Für Text und Barcodes empfiehlt sich „Schwellenwert“."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Section(tr("Sicherheit")) {
                Toggle(tr("Vor zerstörerischen Aktionen nachfragen"), isOn: $model.preferences.confirmDestructiveActions)
                Text(tr("Betrifft z. B. Werkseinstellungen, Netzwerk-Reset und Firmware-Updates."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section(tr("Entwickler")) {
                Toggle(tr("Entwicklermodus (Rohdaten, SGD-Explorer, Hex-Ansichten)"), isOn: $model.preferences.developerMode)
            }
            Section(tr("Daten")) {
                LabeledContent(tr("Datenordner")) {
                    Button(tr("Im Finder zeigen")) {
                        try? FileManager.default.createDirectory(at: PersistenceStore.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([PersistenceStore.stateURL])
                    }
                }
                LabeledContent(tr("Verlauf")) {
                    Button(tr("Verlauf leeren"), role: .destructive) { model.clearHistory() }
                        .disabled(model.history.isEmpty)
                }
                LabeledContent(tr("Einführung")) {
                    Button(tr("Erneut anzeigen")) {
                        model.hasCompletedOnboarding = false
                        model.isOnboardingPresented = true
                    }
                }
            }
            Section(tr("Zurücksetzen")) {
                Button(tr("Alle Einstellungen zurücksetzen …"), role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
        .confirmationDialog(tr("Alle App-Einstellungen zurücksetzen?"), isPresented: $confirmReset) {
            Button(tr("Zurücksetzen"), role: .destructive) { model.preferences = AppPreferences() }
            Button(tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("Drucker, Etikettenformate und Verlauf bleiben erhalten."))
        }
    }
}

private struct AboutView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    @State private var appeared = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 14) {
            IconBadge(systemImage: "printer.filled.and.paper", tint: Theme.violet, size: 76)
                .scaleEffect(appeared ? 1 : 0.7)
                .rotationEffect(.degrees(appeared ? 0 : -12))
            Text("LabelWerk")
                .font(Theme.Typography.hero)
                .foregroundStyle(Theme.brandGradient)
            Text(tr("Version %@", version))
                .foregroundStyle(.secondary)
            Text(tr("Moderner Treiber und Steuerzentrale für Zebra®-Etikettendrucker auf dem Mac."))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(tr("Zebra ist eine Marke der Zebra Technologies Corp. LabelWerk ist ein unabhängiges Projekt und steht in keiner Verbindung zu Zebra Technologies."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 360)
        .onAppear {
            withAnimation(Motion.animation(.spring(response: 0.7, dampingFraction: 0.6),
                                           reduceMotion: systemReduceMotion || appReduceMotion)) {
                appeared = true
            }
        }
    }
}

import SwiftUI
import LabelWerkKit

/// Schritt 3 „Name & Optionen“: Name und Standort in macOS, Standarddrucker, Testseite,
/// Überwachung in LabelWerk und – falls vorhanden – Umgang mit einem bestehenden macOS-Drucker.
struct SetupOptionsStep: View {
    @Bindable var wizard: PrinterSetupWizardModel
    let reduceMotion: Bool

    @Namespace private var namespace

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    nameCard
                    optionsCard
                    if !wizard.queueMatches.isEmpty {
                        existingQueueCard
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(spacing: 12) {
                    previewCard
                    driverNote
                }
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 236)
        }
        .padding(.horizontal, 22)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.queueMatches)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.reuseQueueName)
    }

    // MARK: Name

    private var nameCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                field(tr("Name in macOS")) {
                    TextField(tr("Name"), text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                }
                field(tr("Standort (optional)")) {
                    TextField(tr("z. B. Lager, Versand, Empfang"), text: $wizard.location)
                        .textFieldStyle(.roundedBorder)
                }
                Label(tr("Warteschlange: %@", wizard.queueNamePreview), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
                    .help(tr("Interner Name in macOS (CUPS), z. B. für das Terminal: lp -d <Name>"))
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { wizard.nameEdited ? wizard.name : wizard.suggestedName },
            set: { newValue in
                wizard.name = newValue
                wizard.nameEdited = true
            }
        )
    }

    // MARK: Optionen

    private var optionsCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                optionRow(
                    isOn: $wizard.setAsDefault,
                    symbol: "star.fill", tint: Theme.paused,
                    title: tr("Als Standarddrucker"),
                    detail: tr("Druckdialoge schlagen diesen Drucker vor. Steht in den Systemeinstellungen „Zuletzt verwendeter Drucker“, gilt dieser stattdessen.")
                )
                Divider().opacity(0.4)
                optionRow(
                    isOn: $wizard.printTestPage,
                    symbol: "doc.text.fill", tint: Theme.printing,
                    title: tr("Testseite drucken"),
                    detail: tr("Prüft den kompletten Druckweg über macOS – wie „Testseite drucken“ unter Windows.")
                )
                Divider().opacity(0.4)
                if let session = wizard.sessionForCurrentDevice {
                    optionRow(
                        isOn: .constant(true),
                        symbol: "waveform.path.ecg", tint: Theme.ready,
                        title: tr("In LabelWerk überwachen"),
                        detail: tr("Bereits eingerichtet als „%@“ – der macOS-Drucker wird damit verknüpft.", session.displayName)
                    )
                    .disabled(true)
                } else {
                    optionRow(
                        isOn: $wizard.monitorInLabelWerk,
                        symbol: "waveform.path.ecg", tint: Theme.ready,
                        title: tr("In LabelWerk überwachen"),
                        detail: tr("Live-Status, Mitteilungen bei Fehlern, Werkzeuge und Designer für diesen Drucker.")
                    )
                    // Nicht bestätigte Geräte: Die Überwachung ist aus; einschalten nur bewusst.
                    if wizard.detection?.zebraCheck != .confirmed {
                        DiscoveryInlineNote(
                            systemImage: "exclamationmark.triangle.fill",
                            text: DiscoveryMatcher.unidentifiedWarning,
                            tint: Theme.warning
                        )
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func optionRow(isOn: Binding<Bool>, symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(systemImage: symbol, tint: tint, size: 28)
                .opacity(isOn.wrappedValue ? 1 : 0.55)
                .saturation(isOn.wrappedValue ? 1 : 0.3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 5)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isOn.wrappedValue)
    }

    // MARK: Vorhandene Warteschlangen

    private var existingQueueCard: some View {
        GlassCard(padding: 14, tint: Theme.teal) {
            VStack(alignment: .leading, spacing: 8) {
                Label(tr("Für diesen Drucker gibt es schon einen macOS-Drucker"), systemImage: "info.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.teal)
                ForEach(wizard.queueMatches) { match in
                    choiceRow(
                        isSelected: wizard.reuseQueueName == match.info.name,
                        title: tr("„%@“ aktualisieren", match.info.name),
                        detail: detail(for: match)
                    ) {
                        wizard.reuseQueueName = match.info.name
                    }
                }
                choiceRow(
                    isSelected: wizard.reuseQueueName == nil,
                    title: tr("Zusätzlichen macOS-Drucker anlegen"),
                    detail: tr("Der vorhandene bleibt unverändert – im Druckdialog gibt es den Drucker dann zweimal.")
                ) {
                    wizard.reuseQueueName = nil
                }
            }
        }
    }

    private func detail(for match: ExistingQueueMatch) -> String {
        if match.isLabelWerk {
            return tr("Verwendet bereits den LabelWerk-Treiber – Name, Modell und Einstellungen werden erneuert.")
        }
        let driver = match.info.makeAndModel ?? match.info.deviceURI
        if match.match == .sameHost {
            return tr("Gleiche Adresse über ein anderes Protokoll (%@) – wird auf den LabelWerk-Treiber umgestellt.", match.info.deviceURI)
        }
        return tr("Verwendet einen anderen Treiber (%@) – wird auf den LabelWerk-Treiber umgestellt.", driver)
    }

    private func choiceRow(isSelected: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.accent.opacity(0.1))
                        .matchedGeometryEffect(id: "setupQueueChoice", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Vorschau

    private var previewCard: some View {
        let accent = DiscoveryAccentPalette.color(wizard.accentHue)
        let stock = wizard.selectedStock
        let aspect = stock.map { CGFloat($0.heightMM / max($0.widthMM, 1)) } ?? 1.5
        return GlassCard(padding: 14, tint: accent) {
            VStack(spacing: 10) {
                PrinterIllustration(state: .ready, isPrinting: false, accent: accent,
                                    category: wizard.selectedModel?.category ?? .desktop,
                                    labelAspect: aspect)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    Text(wizard.effectiveName)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    Text(wizard.selectedModel?.displayName ?? tr("Allgemeiner Zebra-Drucker"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    KeyValueRow(tr("Verbindung"), wizard.currentDescriptor?.displayString ?? "–")
                    KeyValueRow(tr("Auflösung"), wizard.resolution.displayName)
                    KeyValueRow(tr("Etikett"), wizard.stockSummary)
                }
                if stock != nil {
                    // Die Größe wird Standard-Papiergröße des macOS-Druckers – kein Einstellen im Druckdialog.
                    Text(tr("Alle Programme drucken auf dieses Etikett – im Druckdialog muss nichts eingestellt werden."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var driverNote: some View {
        if wizard.driverInstalled {
            Label(tr("LabelWerk-Treiber installiert"), systemImage: "checkmark.seal.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ready)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if wizard.driverInstallable {
            DiscoveryInlineNote(
                systemImage: "lock.shield",
                text: tr("Der LabelWerk-Treiber wird bei der Installation mit eingerichtet – macOS fragt dafür einmal nach einem Administratorpasswort.")
            )
        } else {
            DiscoveryInlineNote(
                systemImage: "exclamationmark.triangle.fill",
                text: tr("Der LabelWerk-Treiber fehlt, und diese App enthält kein Treiberpaket. Bitte LabelWerk mit dem Installationspaket installieren."),
                tint: Theme.error
            )
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

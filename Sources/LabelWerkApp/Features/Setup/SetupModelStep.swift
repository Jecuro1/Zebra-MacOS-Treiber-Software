import SwiftUI
import LabelWerkKit

/// Schritt 2 „Modell“: erkanntes Modell mit Sicherheit der Erkennung, Auswahl aus dem Katalog
/// (durchsuchbar), Auflösung, Druckersprache und passendes Etikett.
struct SetupModelStep: View {
    @Bindable var wizard: PrinterSetupWizardModel
    let reduceMotion: Bool

    @Namespace private var namespace

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                detectionCard
                catalogCard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 12) {
                settingsCard
                if let printerModel = wizard.selectedModel {
                    specsCard(printerModel)
                        .id(printerModel.id)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 262)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.modelID)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: wizard.isDetecting)
    }

    // MARK: Erkennung

    private var detectionCard: some View {
        GlassCard(padding: 14, tint: detectionTint) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RingGauge(value: wizard.isDetecting ? 0 : confidence, lineWidth: 5,
                              colors: ringColors)
                    Image(systemName: detectionSymbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(detectionTint)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeating, isActive: wizard.isDetecting && !reduceMotion)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(detectionTitle)
                            .font(Theme.Typography.headline)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        if !wizard.isDetecting && confidence > 0 {
                            Text(tr("%d %% sicher", Int((confidence * 100).rounded())))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(detectionTint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(detectionTint.opacity(0.15)))
                                .contentTransition(.numericText(value: confidence))
                        }
                    }
                    Text(detectionDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if !wizard.isDetecting, !facts.isEmpty {
                        DiscoveryFlowLayout(spacing: 5) {
                            ForEach(facts, id: \.self) { fact in
                                Text(fact)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.subtleFill))
                            }
                        }
                        .transition(.opacity)
                    }
                }
                Spacer(minLength: 4)
                detectionAction
            }
        }
    }

    @ViewBuilder
    private var detectionAction: some View {
        if wizard.isDetecting {
            EmptyView()
        } else if let detection = wizard.detection, detection.queryWithheld, detection.reachable {
            Button {
                wizard.queryUnverifiedPrinter()
            } label: {
                Label(tr("Beim Drucker abfragen"), systemImage: "questionmark.bubble")
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .help(DiscoveryMatcher.unidentifiedWarning)
        } else if wizard.modelChosenManually, wizard.detectedModel != nil {
            Button {
                wizard.restoreDetectedModel()
            } label: {
                Label(tr("Erkanntes Modell"), systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.labelWerkSecondary)
            .controlSize(.small)
            .help(tr("Das automatisch erkannte Modell wieder verwenden"))
        } else if let detection = wizard.detection, detection.reachable {
            Button {
                wizard.redetect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.labelWerkPlain)
            .help(tr("Modell erneut erkennen"))
            .accessibilityLabel(tr("Modell erneut erkennen"))
        }
    }

    private var confidence: Double {
        if wizard.modelChosenManually { return 1 }
        guard let detection = wizard.detection, detection.modelID != nil, wizard.modelID == detection.modelID else { return 0 }
        return detection.source.confidence
    }

    private var ringColors: [Color] {
        if wizard.modelChosenManually { return [Theme.violet, Theme.indigo] }
        return confidence >= 0.85 ? [Theme.ready, Theme.teal] : [Theme.teal, Theme.violet]
    }

    private var detectionTint: Color {
        if wizard.isDetecting { return Theme.violet }
        if wizard.modelChosenManually { return Theme.violet }
        if confidence > 0 { return confidence >= 0.85 ? Theme.ready : Theme.teal }
        if case .notZebra = wizard.detection?.zebraCheck { return Theme.error }
        return Theme.warning
    }

    private var detectionSymbol: String {
        if wizard.isDetecting { return "magnifyingglass" }
        if wizard.modelChosenManually { return "hand.point.up.left.fill" }
        if confidence > 0 { return "checkmark.seal.fill" }
        if case .notZebra = wizard.detection?.zebraCheck { return "exclamationmark.octagon.fill" }
        return "questionmark"
    }

    private var detectionTitle: String {
        if wizard.isDetecting { return tr("Modell wird erkannt …") }
        if let printerModel = wizard.selectedModel, confidence > 0 { return printerModel.displayName }
        if wizard.modelChosenManually { return tr("Allgemeiner Zebra-Drucker") }
        if case .notZebra = wizard.detection?.zebraCheck { return tr("Kein Zebra-Drucker erkannt") }
        return tr("Modell nicht erkannt")
    }

    private var detectionDetail: String {
        if wizard.isDetecting {
            return tr("LabelWerk fragt den Drucker nach Modell, Auflösung und Sprachen.")
        }
        guard let detection = wizard.detection else {
            return tr("Bitte das Modell unten wählen.")
        }
        if wizard.modelChosenManually {
            if let detected = wizard.detectedModel {
                return tr("Von Hand gewählt – erkannt wurde %@.", detected.displayName)
            }
            return tr("Von Hand gewählt.")
        }
        if confidence > 0 {
            if let raw = detection.rawModel, let printerModel = wizard.selectedModel,
               raw.caseInsensitiveCompare(printerModel.name) != .orderedSame,
               raw.caseInsensitiveCompare(printerModel.displayName) != .orderedSame {
                return tr("%@ · meldet sich als „%@“", detection.source.title, raw)
            }
            return detection.source.title
        }
        if case .notZebra(let description) = detection.zebraCheck {
            return tr("Das Gerät meldet sich als „%@“. Der LabelWerk-Treiber ist nur für Zebra-Drucker gedacht.", description)
        }
        if detection.queryWithheld {
            return tr("Das Gerät hat sich bei der Suche nicht als Zebra-Drucker zu erkennen gegeben. Modell unten wählen – oder beim Drucker abfragen, wenn es sicher ein Zebra-Drucker ist.")
        }
        if let error = detection.identifyError {
            return tr("Der Drucker hat nicht geantwortet (%@). Bitte das Modell unten wählen.", error)
        }
        if !detection.reachable {
            return tr("Der Drucker ist gerade nicht erreichbar. Bitte das Modell unten wählen – unsicher? „Allgemeiner Zebra-Drucker“ passt zu allen ZPL-Druckern.")
        }
        return tr("Bitte das Modell unten wählen. Unsicher? „Allgemeiner Zebra-Drucker“ passt zu allen ZPL-Druckern.")
    }

    /// Kurze Fakten aus der Erkennung (Firmware, Seriennummer, Auflösung, Antwortzeit).
    private var facts: [String] {
        guard let detection = wizard.detection else { return [] }
        var result: [String] = []
        if let resolution = detection.resolution { result.append(resolution.displayName) }
        if let firmware = detection.firmware { result.append(tr("Firmware %@", firmware)) }
        if let serial = detection.serialNumber { result.append(tr("Seriennr. %@", serial)) }
        if let name = detection.friendlyName { result.append(name) }
        if let latency = detection.latencyMS { result.append(tr("%d ms", latency)) }
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0).inserted }.prefix(4))
    }

    // MARK: Katalog

    private var catalogCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(tr("Modell suchen (z. B. ZD421, ZT411, ZQ630)"), text: $wizard.modelSearch)
                        .textFieldStyle(.plain)
                    if !wizard.modelSearch.isEmpty {
                        Button {
                            wizard.modelSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Suche leeren"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                            if wizard.modelSearch.isEmpty {
                                genericRow
                            }
                            ForEach(wizard.modelGroups) { group in
                                Section {
                                    ForEach(group.models) { printerModel in
                                        modelRow(printerModel)
                                            .id(printerModel.id)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Text(tr(group.category.displayName))
                                        Text(group.models.count.formatted())
                                            .foregroundStyle(.tertiary)
                                        Spacer()
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial)
                                }
                            }
                            if wizard.modelGroups.isEmpty {
                                Text(tr("Kein Modell gefunden."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onAppear {
                        if let id = wizard.modelID { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: wizard.detection?.modelID) { _, newID in
                        guard let newID, !wizard.modelChosenManually else { return }
                        withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var genericRow: some View {
        let isSelected = wizard.modelID == nil
        return Button {
            wizard.chooseModel(nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "printer")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Allgemeiner Zebra-Drucker"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(tr("Allgemeiner Treiber für %@ – passt, wenn das Modell fehlt", wizard.language.displayName))
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brandGradient)
                        .matchedGeometryEffect(id: "setupModelSelection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func modelRow(_ printerModel: PrinterModel) -> some View {
        let isSelected = wizard.modelID == printerModel.id
        let isDetected = wizard.detection?.modelID == printerModel.id
        let dpis = printerModel.supportedResolutions.map { String($0.dpi) }.joined(separator: "/")
        return Button {
            wizard.chooseModel(printerModel)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: printerModel.systemImage)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(printerModel.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: "\(printerModel.family) · \(dpis) dpi · \(Int(printerModel.printWidthMM)) mm")
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
                if isDetected {
                    Label(tr("Erkannt"), systemImage: "sparkles")
                        .font(.system(size: 9.5, weight: .bold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Theme.ready.opacity(0.15)))
                        .foregroundStyle(isSelected ? Color.white : Theme.ready)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brandGradient)
                        .matchedGeometryEffect(id: "setupModelSelection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Einstellungen

    private var settingsCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                field(tr("Auflösung")) {
                    Picker(tr("Auflösung"), selection: $wizard.resolution) {
                        ForEach(wizard.resolutionOptions) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field(tr("Druckersprache")) {
                    Picker(tr("Druckersprache"), selection: $wizard.language) {
                        ForEach(wizard.languageOptions) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field(tr("Etikett")) {
                    // Größe vom Drucker (wie in ZDesigner) oder von Hand – die Warteschlange erhält
                    // sie als benannte Standard-Papiergröße.
                    LabelStockChooser(choice: stockChoiceBinding, entry: $wizard.customEntry,
                                      stocks: wizard.stockOptions, detected: wizard.detectedMedia,
                                      detectedMatch: wizard.detectedMatch, limits: wizard.stockLimits,
                                      isReadingMedia: wizard.isReadingMedia, note: wizard.mediaNote,
                                      onReadFromPrinter: readFromPrinterAction,
                                      reduceMotion: reduceMotion)
                }
            }
        }
    }

    /// „Vom Drucker übernehmen“ – nur, wenn der Drucker gefragt werden darf (ZPL, erreichbar).
    private var readFromPrinterAction: (() -> Void)? {
        guard wizard.canReadMedia else { return nil }
        let wizard = self.wizard
        return { wizard.rereadMedia() }
    }

    private var stockChoiceBinding: Binding<LabelStockChoice> {
        let wizard = self.wizard
        return Binding(get: { wizard.stockChoice }, set: { wizard.selectStockChoice($0) })
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func specsCard(_ printerModel: PrinterModel) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    IconBadge(systemImage: printerModel.systemImage, tint: Theme.violet, size: 24)
                    Text(printerModel.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 4)
                KeyValueRow(tr("Druckbreite"), tr("%d mm", Int(printerModel.printWidthMM.rounded())))
                KeyValueRow(tr("Tempo"), tr("bis %d Zoll/s", printerModel.maxSpeed(wizard.resolution)))
                KeyValueRow(tr("Max. Länge"), tr("%d mm", Int(printerModel.maxLabelLengthMM.rounded())))
            }
        }
    }
}

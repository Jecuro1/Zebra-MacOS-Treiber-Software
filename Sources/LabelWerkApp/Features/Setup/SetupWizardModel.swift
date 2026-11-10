import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Schritte

/// Schritte des Installationsassistenten (wie „Drucker hinzufügen“ unter Windows).
enum PrinterSetupStep: Int, CaseIterable, Identifiable, Hashable {
    case choose
    case model
    case options
    case install

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .choose: return tr("Drucker wählen")
        case .model: return tr("Modell")
        case .options: return tr("Name & Optionen")
        case .install: return tr("Installieren")
        }
    }

    var subtitle: String {
        switch self {
        case .choose: return tr("Drucker im Netzwerk auswählen oder seine Adresse eingeben.")
        case .model: return tr("Das Modell bestimmt Treiber, Druckbreite und passende Etiketten.")
        case .options: return tr("So erscheint der Drucker in macOS und in jedem Druckdialog.")
        case .install: return tr("LabelWerk richtet den Drucker als macOS-Drucker ein.")
        }
    }

    var systemImage: String {
        switch self {
        case .choose: return "dot.radiowaves.left.and.right"
        case .model: return "printer"
        case .options: return "slider.horizontal.3"
        case .install: return "arrow.down.circle"
        }
    }
}

/// Auswahl im ersten Schritt.
enum PrinterSetupCandidate: Hashable {
    /// Gefundener Drucker (`DiscoveredPrinter.id`).
    case discovered(String)
    /// Manuell eingegebene Adresse.
    case manual
}

/// Anzeige-Infos zu einem gefundenen Drucker.
struct PrinterSetupCandidateInfo: Equatable {
    var subtitle: String
    var systemImage: String
    var isInLabelWerk: Bool
    var hasMacQueue: Bool
    var isUnidentified: Bool
}

/// Wie der Assistent verlassen wurde (für umgebende Sheets).
enum PrinterSetupExit: Equatable {
    case cancelled
    case finished
    /// „Drucker öffnen“ bzw. „Treiber & Warteschlangen“: Das umgebende Sheet sollte sich auch schließen.
    case navigated
}

// MARK: - Zustand

/// Zustand des Installationsassistenten: Suche, Erkennung, Modell, Optionen und Installation.
@Observable
@MainActor
final class PrinterSetupWizardModel {
    // MARK: Navigation

    private(set) var step: PrinterSetupStep = .choose
    /// Richtung des letzten Seitenwechsels (für die Übergangsanimation).
    private(set) var forward = true

    // MARK: Schritt 1 – Drucker wählen

    let discovery: DiscoveryController
    var candidate: PrinterSetupCandidate? {
        didSet {
            guard candidate != oldValue else { return }
            connectionFailure = nil
        }
    }
    var manualHost = "" {
        didSet {
            guard manualHost != oldValue else { return }
            manualReachability = .idle
            if !manualHost.trimmingCharacters(in: .whitespaces).isEmpty { candidate = .manual }
        }
    }
    var manualPort = ZebraIdentifiers.rawPort {
        didSet {
            guard manualPort != oldValue else { return }
            manualReachability = .idle
        }
    }
    private(set) var manualReachability: DiscoveryReachability = .idle
    private(set) var interfaces: [NetworkInterfaceInfo] = []
    /// Bereits eingerichtete macOS-Warteschlangen (für „macOS-Drucker vorhanden“).
    private(set) var macQueues: [CUPSQueueInfo] = []
    private(set) var isDetecting = false
    private(set) var detection: PrinterDetection?
    /// Erreichbarkeitsfehler (bleibt auf Schritt 1).
    private(set) var connectionFailure: PrinterInstallFailure?
    /// Der Benutzer fährt ohne erreichbaren Drucker fort.
    private(set) var continuesOffline = false

    // MARK: Schritt 2 – Modell

    private(set) var modelID: String?
    private(set) var modelChosenManually = false
    var resolution: Resolution = .dpi203
    var language: PrinterLanguage = .zpl
    /// Zuletzt gewähltes vorhandenes Format (bei „Vom Drucker“/„Benutzerdefiniert …“ der Rückfall).
    private(set) var stockID: String = "w4h6in"
    /// Auswahl „Etikett“: vorhandenes Format, „Vom Drucker“ oder „Benutzerdefiniert …“
    /// (``LabelStockChoice``). Ändern über ``selectStockChoice(_:)``.
    private(set) var stockChoice: LabelStockChoice = .stock("w4h6in")
    /// Eingabe „Benutzerdefiniert …“ (Breite, Höhe, Medientyp).
    var customEntry = LabelSizeEntry()
    /// Vom Drucker gemeldete Etikettengröße (`PrinterDetection.media` bzw. „Vom Drucker übernehmen“).
    private(set) var detectedMedia: DetectedMedia?
    private(set) var isReadingMedia = false
    /// Hinweis unter der Etikettenauswahl (z. B. keine Größe gemeldet).
    private(set) var mediaNote: String?
    /// Der Benutzer hat die Etikettenauswahl selbst geändert – dann gilt die gemeldete Größe nicht
    /// mehr automatisch (bis „Vom Drucker übernehmen“). Ein bereits in LabelWerk eingerichteter
    /// Drucker bringt seine Auswahl mit.
    private(set) var stockChoiceTouched = false
    var modelSearch = ""

    // MARK: Schritt 3 – Name & Optionen

    var name = ""
    var nameEdited = false
    var location = ""
    var setAsDefault = false
    var printTestPage = false
    var monitorInLabelWerk = true
    private(set) var accentHue: Double = 0.72
    private(set) var queueMatches: [ExistingQueueMatch] = []
    /// Vorhandene Warteschlange, die aktualisiert wird (nil = neue anlegen).
    var reuseQueueName: String?
    private(set) var isLoadingQueueMatches = false
    private(set) var queueMatchesLoaded = false

    // MARK: Schritt 4 – Installation

    let service: PrinterInstallService
    /// Für den Erfolgsbildschirm (Konfetti, Symbol).
    private(set) var celebration = 0
    private(set) var lastRequest: PrinterInstallRequest?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var mediaGeneration = 0
    @ObservationIgnored private var detectionGeneration = 0
    @ObservationIgnored private var matchGeneration = 0
    @ObservationIgnored private var started = false
    /// `stableID` des Geräts, zu dem Modell, Name und Standort gehören.
    @ObservationIgnored private var preparedDeviceID: String?

    init() {
        discovery = DiscoveryController(sources: [.bonjour, .network, .usb], persistsSources: false)
        service = PrinterInstallService()
    }

    // MARK: Start & Ende

    func start(app: AppModel) {
        self.app = app
        guard !started else { return }
        started = true
        accentHue = AppModel.nextAccentHue(after: app.sessions.count)
        interfaces = SubnetScanner.localIPv4Interfaces()
        discovery.start()
        Task { [weak self] in
            if DriverInstaller.shared.snapshot == nil { await DriverInstaller.shared.refresh() }
            await self?.reloadMacQueues()
        }
    }

    func stop() {
        discovery.stop()
        detectTask?.cancel()
        probeTask?.cancel()
        mediaTask?.cancel()
        detectTask = nil
        probeTask = nil
        mediaTask = nil
        isDetecting = false
        isReadingMedia = false
    }

    func rescan() {
        discovery.start()
        Task { [weak self] in await self?.reloadMacQueues() }
    }

    private func reloadMacQueues() async {
        let queues = await CUPSService.queues()
        animate(Motion.spring) { macQueues = queues }
    }

    // MARK: Navigation

    func go(to target: PrinterSetupStep) {
        guard target != step else { return }
        // Erst die Richtung setzen (die alte Seite übernimmt ihren Abgang), dann die Seite wechseln.
        forward = target.rawValue > step.rawValue
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.animate(.spring(response: 0.5, dampingFraction: 0.86)) {
                self.step = target
            }
            if target == .options { self.loadQueueMatches() }
        }
    }

    func goBack() {
        guard !service.isRunning else { return }
        switch step {
        case .choose: return
        case .model: go(to: .choose)
        case .options: go(to: .model)
        case .install: go(to: .options)
        }
    }

    // MARK: Schritt 1

    /// Gefundene Drucker: Netzwerk zuerst (identifizierte vor nicht identifizierten), dann USB.
    var candidates: [DiscoveredPrinter] {
        discovery.found
            .filter { PrinterInstallRequest.supports($0.descriptor) }
            .sorted { lhs, rhs in
                let left = rank(lhs)
                let right = rank(rhs)
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func rank(_ printer: DiscoveredPrinter) -> Int {
        switch printer.descriptor.kind {
        case .tcp: return DiscoveryMatcher.isUnidentified(printer) ? 1 : 0
        case .usb: return 2
        default: return 3
        }
    }

    var selectedPrinter: DiscoveredPrinter? {
        guard case .discovered(let id) = candidate else { return nil }
        return discovery.found.first { $0.id == id }
    }

    /// Host und Port der manuellen Eingabe (nil = ungültig).
    var manualTarget: (host: String, port: Int)? {
        let target = DiscoveryInput.split(manualHost)
        let port = target.port ?? manualPort
        guard DiscoveryInput.isPlausibleHost(target.host), (1...65535).contains(port) else { return nil }
        return (target.host, port)
    }

    var currentDescriptor: ConnectionDescriptor? {
        switch candidate {
        case .discovered:
            return selectedPrinter?.descriptor
        case .manual:
            guard let target = manualTarget else { return nil }
            return .tcp(host: target.host, port: target.port)
        case nil:
            return nil
        }
    }

    var canContinueFromChoose: Bool { currentDescriptor != nil && !isDetecting }

    /// Hinweis, wenn die eingegebene IP-Adresse nicht im Subnetz dieses Macs liegt.
    var subnetNote: String? {
        guard let target = manualTarget,
              PrinterSetupPlanning.isInLocalSubnet(host: target.host, interfaces: interfaces) == false else { return nil }
        return tr("%@ liegt nicht im Netz dieses Macs. Das funktioniert nur, wenn ein Router zwischen den Netzen vermittelt – sonst die IP-Adresse am Drucker prüfen.", target.host)
    }

    func info(for printer: DiscoveredPrinter) -> PrinterSetupCandidateInfo {
        let modelLine = DiscoveryMatcher.modelLine(for: printer)
        let address = printer.descriptor.displayString
        let unidentified = DiscoveryMatcher.isUnidentified(printer)
        let subtitle: String
        if let modelLine {
            subtitle = "\(modelLine) · \(address)"
        } else if unidentified {
            subtitle = tr("Nicht als Zebra-Drucker erkannt · %@", address)
        } else {
            subtitle = address
        }
        return PrinterSetupCandidateInfo(
            subtitle: subtitle,
            systemImage: DiscoveryMatcher.model(for: printer)?.systemImage ?? printer.descriptor.systemImage,
            isInLabelWerk: existingSession(for: printer.descriptor) != nil,
            hasMacQueue: hasMacQueue(for: printer),
            isUnidentified: unidentified
        )
    }

    /// Gibt es schon eine macOS-Warteschlange mit derselben Netzwerkadresse bzw. demselben
    /// Bonjour-Dienst? (USB nur über `lpinfo` prüfbar.)
    private func hasMacQueue(for printer: DiscoveredPrinter) -> Bool {
        guard case .tcp(let host, let port) = printer.descriptor else { return false }
        let uri = CUPSService.socketURI(host: host, port: port)
        let serviceName = printer.details["serviceName"]
        return macQueues.contains {
            PrinterSetupPlanning.queueMatch(queueURI: $0.deviceURI, deviceURI: uri, serviceName: serviceName) == .exact
        }
    }

    /// Bonjour-Name des gewählten Druckers (erkennt Warteschlangen, die „Drucker & Scanner“ über
    /// den Bonjour-Eintrag angelegt hat).
    private var selectedServiceName: String? {
        PrinterSetupPlanning.nonEmpty(selectedPrinter?.details["serviceName"])
    }

    func existingSession(for descriptor: ConnectionDescriptor) -> PrinterSession? {
        app?.sessions.first { $0.saved.descriptor.refersToSameDevice(as: descriptor) }
    }

    func select(_ printer: DiscoveredPrinter) {
        animate(Motion.snappy) { candidate = .discovered(printer.id) }
    }

    func normalizeManualHost() {
        let target = DiscoveryInput.split(manualHost)
        manualHost = target.host
        if let port = target.port { manualPort = port }
    }

    /// „Verbindung prüfen“ der manuellen Adresse.
    func checkManual() {
        guard let target = manualTarget else {
            animate(Motion.snappy) { manualReachability = .unreachable(tr("Bitte eine gültige Adresse eingeben.")) }
            return
        }
        candidate = .manual
        probeTask?.cancel()
        let key = "\(target.host):\(target.port)"
        animate(Motion.snappy) { manualReachability = .checking }
        probeTask = Task { [weak self] in
            let result = await PrinterInstallService.probeReachability(host: target.host, port: target.port)
            guard let self, !Task.isCancelled, let current = self.manualTarget,
                  "\(current.host):\(current.port)" == key else { return }
            self.animate(Motion.bouncy) { self.manualReachability = result }
        }
    }

    /// „Weiter“: prüft den Drucker, erkennt das Modell und wechselt zum Modellschritt.
    func continueFromChoose() {
        if candidate == .manual { normalizeManualHost() }
        continuesOffline = false
        detect(allowUnverifiedQuery: false, advance: true)
    }

    /// „Trotzdem fortfahren“ ohne erreichbaren Drucker (wird eingerichtet und druckt später).
    func continueWithoutConnection() {
        guard let descriptor = currentDescriptor else { return }
        detectTask?.cancel()
        isDetecting = false
        var offline = PrinterSetupPlanning.detection(from: selectedPrinter, descriptor: descriptor)
        offline.connectionError = connectionFailure?.message
        continuesOffline = true
        connectionFailure = nil
        apply(offline)
        go(to: .model)
    }

    /// Fragt ein nicht bestätigtes Netzwerkgerät nach Zustimmung doch nach seinem Modell (`~HI`/SGD).
    func queryUnverifiedPrinter() {
        detect(allowUnverifiedQuery: true, advance: false)
    }

    /// Erkennung erneut ausführen (Modellschritt).
    func redetect() {
        detect(allowUnverifiedQuery: false, advance: false)
    }

    private func detect(allowUnverifiedQuery: Bool, advance: Bool) {
        guard let descriptor = currentDescriptor, let app else { return }
        detectTask?.cancel()
        detectionGeneration += 1
        let generation = detectionGeneration
        let discovered = selectedPrinter
        animate(Motion.snappy) {
            isDetecting = true
            connectionFailure = nil
        }
        detectTask = Task { [weak self] in
            let result = await PrinterInstallService.detect(descriptor: descriptor, discovered: discovered,
                                                           allowUnverifiedQuery: allowUnverifiedQuery, model: app)
            guard let self, generation == self.detectionGeneration, !Task.isCancelled else { return }
            self.finishDetection(result, advance: advance)
        }
    }

    private func finishDetection(_ result: PrinterDetection, advance: Bool) {
        if !result.reachable, case .tcp(let host, let port) = result.descriptor {
            animate(Motion.spring) {
                isDetecting = false
                connectionFailure = .unreachable(host: host, port: port, detail: result.connectionError)
            }
            if step != .choose { go(to: .choose) }
            return
        }
        animate(Motion.spring) {
            isDetecting = false
            apply(result)
        }
        if advance { go(to: .model) }
    }

    /// Übernimmt eine Erkennung: Modell (sofern nicht von Hand gewählt), Auflösung, Sprache, Etikett, Standort.
    private func apply(_ result: PrinterDetection) {
        let deviceID = result.descriptor.stableID
        let deviceChanged = preparedDeviceID != deviceID
        let session = existingSession(for: result.descriptor)
        if deviceChanged {
            // Anderer Drucker als zuvor: Eingaben der vorigen Auswahl verwerfen. Eine noch laufende
            // Suche nach vorhandenen Warteschlangen gehört zum vorigen Drucker – ihr Ergebnis verwerfen,
            // sonst würde dessen macOS-Drucker zum Aktualisieren vorgeschlagen.
            preparedDeviceID = deviceID
            modelChosenManually = false
            nameEdited = false
            name = ""
            location = ""
            matchGeneration += 1
            isLoadingQueueMatches = false
            reuseQueueName = nil
            queueMatches = []
            queueMatchesLoaded = false
            // Etikettengröße des vorigen Druckers verwerfen.
            mediaGeneration += 1
            mediaTask?.cancel()
            isReadingMedia = false
            mediaNote = nil
            detectedMedia = nil
            customEntry = LabelSizeEntry()
            // „Benutzerdefiniert …“/„Vom Drucker“ verlieren ihre Daten: zurück zum letzten echten Etikett.
            if stockChoice.stockID == nil { setStockChoice(.stock(stockID)) }
            // Die vom Drucker gemeldete Größe hat Vorrang, auch bei einem schon in LabelWerk
            // eingerichteten Drucker (dort stand womöglich nur die nächstliegende Vorlage).
            stockChoiceTouched = false
            if let session {
                // Bereits in LabelWerk eingerichtet: dessen Etikett (solange der Drucker keine Größe
                // meldet), Auflösung und Sprache übernehmen, damit der macOS-Drucker dieselben
                // Standardwerte erhält wie in LabelWerk.
                setStockChoice(.stock(session.saved.stockID))
                resolution = session.saved.resolution
                language = session.saved.language
                if result.modelID == nil, let known = session.saved.modelID {
                    // Das Modell wurde in LabelWerk gewählt (nicht erkannt).
                    modelID = known
                    modelChosenManually = true
                }
            }
        }
        // „In LabelWerk überwachen“ nur für bestätigte Zebra-Drucker vorschlagen: LabelWerk fragt
        // überwachte Drucker sofort und danach regelmäßig ab – ein Bürodrucker an Port 9100 würde
        // jede Abfrage als Seite voller Steuerzeichen drucken. Eine eigene Wahl bleibt erhalten,
        // solange sich die Einstufung des Geräts nicht ändert.
        let previousCheck = deviceChanged ? nil : detection?.zebraCheck
        if result.zebraCheck != previousCheck {
            monitorInLabelWerk = result.zebraCheck == .confirmed
        }
        detection = result
        // Größe vom Drucker (ZPL): eine erneute Erkennung ohne Meldung behält die vorige.
        if let media = result.media { detectedMedia = media }
        if !modelChosenManually { modelID = result.modelID }
        var preferredLanguages = result.languages
        if deviceChanged, let session,
           preferredLanguages.isEmpty || preferredLanguages.contains(session.saved.language) {
            // Die in LabelWerk gewählte Sprache behalten, sofern der Drucker sie beherrscht.
            preferredLanguages = [session.saved.language]
        }
        adjustSettings(preferredResolution: result.resolution, preferredLanguages: preferredLanguages)
        if location.isEmpty, let place = result.location { location = place }
        if let session, !nameEdited {
            // Bereits in LabelWerk: denselben Namen vorschlagen.
            name = session.displayName
            nameEdited = true
            if location.isEmpty { location = session.saved.location }
        }
    }

    // MARK: Schritt 2

    var selectedModel: PrinterModel? { modelID.flatMap { ModelCatalog.shared.model(id: $0) } }
    var detectedModel: PrinterModel? { detection?.modelID.flatMap { ModelCatalog.shared.model(id: $0) } }

    var allStocks: [LabelStock] { app?.allStocks ?? ModelCatalog.shared.stocks }
    var availableStocks: [LabelStock] { PrinterSetupPlanning.fittingStocks(for: selectedModel, in: allStocks) }

    var resolutionOptions: [Resolution] {
        let supported = selectedModel?.supportedResolutions ?? []
        return supported.isEmpty ? Resolution.allCases : supported
    }

    var languageOptions: [PrinterLanguage] {
        let supported = selectedModel?.languages ?? []
        return supported.isEmpty ? PrinterLanguage.allCases : supported
    }

    // MARK: Schritt 2 – Etikett

    /// Erlaubte Größe für „Benutzerdefiniert …“: Breite 10 mm … Druckbreite + 2 mm, Höhe 5 mm …
    /// größte Etikettenlänge des Modells.
    var stockLimits: LabelSizing.Limits { LabelSizing.Limits(model: selectedModel) }

    /// Vorhandenes Format zur gemeldeten Größe (eigene vor Katalog, ± 0,6 mm).
    var detectedMatch: LabelStock? {
        guard let media = detectedMedia, let app else { return nil }
        return LabelStockLibrary.matchingStock(for: media, model: app)
    }

    /// Formate der Auswahl: passend zum Modell, dazu das gewählte und das vom Drucker erkannte.
    var stockOptions: [LabelStock] {
        var list = availableStocks
        for id in [stockChoice.stockID, detectedMatch?.id].compactMap({ $0 }) where !list.contains(where: { $0.id == id }) {
            if let stock = allStocks.first(where: { $0.id == id }) { list.append(stock) }
        }
        return list
    }

    /// Das Etikett, das installiert wird – bei „Vom Drucker“ und „Benutzerdefiniert …“ eine Vorschau,
    /// die erst beim Installieren ein echtes Format wird (`nil` = Eingabe ungültig).
    var selectedStock: LabelStock? {
        switch stockChoice {
        case .stock(let id):
            return allStocks.first { $0.id == id }
        case .printer:
            guard let media = detectedMedia else { return nil }
            return detectedMatch ?? LabelStock(id: "detected", name: tr("Vom Drucker: %@", media.sizeText),
                                               widthMM: media.widthMM, heightMM: media.heightMM,
                                               tracking: media.tracking ?? .gap, mediaType: media.mediaType)
        case .custom:
            guard let size = customEntry.size(in: stockLimits) else { return nil }
            return LabelStock(id: "custom-entry",
                              name: LabelStockLibrary.customStockName(widthMM: size.widthMM, heightMM: size.heightMM),
                              widthMM: size.widthMM, heightMM: size.heightMM, tracking: customEntry.tracking)
        }
    }

    /// „Benutzerdefiniert 104 × 76,2 mm“, „4 × 6 Zoll · 101,6 × 152,4 mm · vom Drucker erkannt“ (Zusammenfassung).
    var stockSummary: String {
        guard let stock = selectedStock else { return "–" }
        let size = LabelSizing.sizeText(widthMM: stock.widthMM, heightMM: stock.heightMM)
        var text = stock.name.contains(size) ? stock.name : "\(stock.name) · \(size)"
        if let id = stockChoice.stockID, id == detectedMatch?.id {
            text += " · " + tr("vom Drucker erkannt")
        }
        return text
    }

    /// Darf die Etikettengröße beim Drucker (erneut) gelesen werden? Nur bei erreichbaren, als Zebra
    /// bestätigten bzw. bereits abgefragten Druckern über Netzwerk oder USB, die ZPL sprechen.
    var canReadMedia: Bool {
        guard let detection, detection.reachable, !continuesOffline, !detection.queryWithheld,
              detection.mayQueryPrinter || detection.source == .printer else { return false }
        switch detection.descriptor.kind {
        case .tcp, .usb: break
        default: return false
        }
        return languageOptions.contains(.zpl)
    }

    /// Auswahl im Etikett-Menü (Benutzer).
    func selectStockChoice(_ choice: LabelStockChoice) {
        guard choice != stockChoice else { return }
        stockChoiceTouched = true
        if choice == .custom, customEntry.isEmpty {
            // Mit der gemeldeten bzw. bisherigen Größe vorbelegen – meist ist nur noch anzupassen.
            if let media = detectedMedia {
                customEntry = LabelSizeEntry(widthMM: media.widthMM, heightMM: media.heightMM,
                                             tracking: media.tracking ?? .gap)
            } else if let stock = selectedStock {
                customEntry = LabelSizeEntry(widthMM: stock.widthMM, heightMM: stock.heightMM, tracking: stock.tracking)
            }
        }
        animate(Motion.snappy) { setStockChoice(choice) }
    }

    /// „Vom Drucker übernehmen“: liest die eingestellte Etikettengröße erneut und wählt sie aus.
    func rereadMedia() {
        guard canReadMedia, let descriptor = detection?.descriptor, let app else { return }
        mediaTask?.cancel()
        mediaGeneration += 1
        let generation = mediaGeneration
        animate(Motion.snappy) {
            isReadingMedia = true
            mediaNote = nil
        }
        mediaTask = Task { [weak self] in
            let media = await PrinterInstallService.readMediaSize(descriptor: descriptor, model: app)
            guard let self, generation == self.mediaGeneration, !Task.isCancelled else { return }
            self.animate(Motion.spring) {
                self.isReadingMedia = false
                if let media {
                    self.detectedMedia = media
                    self.stockChoiceTouched = false
                    self.applyMediaPreselection()
                } else {
                    self.mediaNote = tr("Der Drucker hat keine Etikettengröße gemeldet. Bitte unter „Benutzerdefiniert …“ eingeben.")
                }
            }
        }
    }

    private func setStockChoice(_ choice: LabelStockChoice) {
        stockChoice = choice
        if let id = choice.stockID { stockID = id }
    }

    /// Wählt die gemeldete Größe, solange der Benutzer die Auswahl nicht geändert hat.
    private func applyMediaPreselection() {
        let choice = LabelStockChoice.preselection(current: stockChoice, touched: stockChoiceTouched,
                                                   hasDetectedSize: detectedMedia != nil,
                                                   matchingStockID: detectedMatch?.id, fallbackStockID: stockID)
        // Ersetzt die gemeldete Größe das in LabelWerk gespeicherte Etikett, darauf hinweisen.
        if !stockChoiceTouched, detectedMedia != nil, choice != stockChoice,
           let session = detection.flatMap({ existingSession(for: $0.descriptor) }),
           choice != .stock(session.saved.stockID), stockChoice == .stock(session.saved.stockID),
           let saved = allStocks.first(where: { $0.id == session.saved.stockID }) {
            mediaNote = tr("In LabelWerk war bisher „%@“ eingestellt.", saved.name)
        }
        setStockChoice(choice)
    }

    /// Macht „Vom Drucker“ bzw. „Benutzerdefiniert …“ vor dem Installationsauftrag zu einem echten
    /// Format (vorhandenes passendes oder neues eigenes, `LabelStockLibrary.resolveStock`).
    /// - Returns: `false`, wenn die Auswahl ungültig ist.
    private func materializeStockChoice() -> Bool {
        guard let app else { return false }
        switch stockChoice {
        case .stock:
            return true
        case .printer:
            guard let media = detectedMedia else { return false }
            setStockChoice(.stock(LabelStockLibrary.resolveStock(for: media, model: app).id))
        case .custom:
            guard let size = customEntry.size(in: stockLimits) else { return false }
            let stock = LabelStockLibrary.resolveStock(widthMM: size.widthMM, heightMM: size.heightMM,
                                                       tracking: customEntry.tracking,
                                                       mediaType: detectedMedia?.mediaType, model: app)
            setStockChoice(.stock(stock.id))
        }
        return true
    }

    func chooseModel(_ printerModel: PrinterModel?) {
        animate(Motion.spring) {
            modelID = printerModel?.id
            modelChosenManually = printerModel?.id != detection?.modelID || detection?.modelID == nil
            adjustSettings(preferredResolution: detection?.modelID == printerModel?.id ? detection?.resolution : nil,
                           preferredLanguages: detection?.modelID == printerModel?.id ? (detection?.languages ?? []) : [])
        }
    }

    func restoreDetectedModel() {
        guard let detected = detection?.modelID else { return }
        animate(Motion.spring) {
            modelID = detected
            modelChosenManually = false
            adjustSettings(preferredResolution: detection?.resolution, preferredLanguages: detection?.languages ?? [])
        }
    }

    private func adjustSettings(preferredResolution: Resolution?, preferredLanguages: [PrinterLanguage]) {
        let printerModel = selectedModel
        resolution = PrinterSetupPlanning.resolution(preferred: preferredResolution, current: resolution, model: printerModel)
        language = PrinterSetupPlanning.language(preferred: preferredLanguages, current: language, model: printerModel)
        stockID = PrinterSetupPlanning.preferredStockID(current: stockID, model: printerModel, stocks: allStocks)
        if stockChoice.stockID != nil, stockChoice != .stock(stockID) {
            // Das gewählte Format passt nicht zum Modell: auf das passende wechseln.
            setStockChoice(.stock(stockID))
        }
        applyMediaPreselection()
    }

    /// Modellgruppen für die Katalogauswahl (gefiltert nach `modelSearch`).
    var modelGroups: [DiscoveryModelGroup] {
        let needle = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PrinterCategory.allCases.compactMap { category -> DiscoveryModelGroup? in
            let models = ModelCatalog.shared.models(in: category).filter { printerModel in
                needle.isEmpty
                    || printerModel.name.lowercased().contains(needle)
                    || printerModel.family.lowercased().contains(needle)
                    || printerModel.id.contains(needle)
            }
            return models.isEmpty ? nil : DiscoveryModelGroup(category: category, models: models)
        }
    }

    // MARK: Schritt 3

    private var takenNames: [String] {
        let own = currentDescriptor.flatMap { existingSession(for: $0) }?.id
        return (app?.sessions ?? []).filter { $0.id != own }.map(\.displayName)
    }

    var suggestedName: String {
        let modelName = selectedModel?.displayName
            ?? detection?.rawModel.flatMap(ZebraIdentifiers.shortModelName(from:)).map { "Zebra \($0)" }
        return PrinterSetupPlanning.suggestedName(modelName: modelName, location: location,
                                                  fallback: tr("Zebra-Drucker"), taken: takenNames)
    }

    var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return nameEdited && !trimmed.isEmpty ? trimmed : suggestedName
    }

    /// Name der Warteschlange, die angelegt bzw. aktualisiert wird.
    var queueNamePreview: String {
        if let reuse = reuseQueueName { return reuse }
        let base = CUPSService.sanitizedQueueName(effectiveName)
        return PrinterSetupPlanning.uniqueQueueName(base, taken: macQueues.map(\.name))
    }

    var sessionForCurrentDevice: PrinterSession? {
        currentDescriptor.flatMap { existingSession(for: $0) }
    }

    var driverInstalled: Bool { DriverInstaller.shared.isInstalled }
    var driverInstallable: Bool { DriverInstaller.shared.hasPayload }

    /// Installieren erst, wenn feststeht, ob es schon einen macOS-Drucker für dieses Gerät gibt
    /// (sonst entstünde womöglich ein doppelter).
    var canInstall: Bool {
        currentDescriptor != nil && !effectiveName.isEmpty && (driverInstalled || driverInstallable)
            && !service.isRunning && !isDetecting && !isLoadingQueueMatches && selectedStock != nil
    }

    func loadQueueMatches() {
        guard let descriptor = currentDescriptor else { return }
        matchGeneration += 1
        let generation = matchGeneration
        let serviceName = selectedServiceName
        isLoadingQueueMatches = true
        Task { [weak self] in
            let matches = await PrinterInstallService.existingQueues(for: descriptor, serviceName: serviceName)
            guard let self, generation == self.matchGeneration else { return }
            self.animate(Motion.spring) {
                let previous = self.queueMatches.map(\.id)
                self.queueMatches = matches
                self.isLoadingQueueMatches = false
                self.queueMatchesLoaded = true
                // Vorschlag: die eigene LabelWerk-Warteschlange aktualisieren statt eine zweite anzulegen.
                if matches.map(\.id) != previous {
                    self.reuseQueueName = matches.first { $0.isLabelWerk && $0.match == .exact }?.info.name
                        ?? self.sessionForCurrentDevice?.saved.cupsQueueName.flatMap { name in
                            matches.contains { $0.info.name == name } ? name : nil
                        }
                }
            }
        }
    }

    // MARK: Schritt 4

    func makeRequest() -> PrinterInstallRequest? {
        guard let descriptor = currentDescriptor else { return nil }
        var request = PrinterInstallRequest(descriptor: descriptor, name: effectiveName)
        request.serviceName = selectedServiceName
        request.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        request.modelID = modelID
        request.resolution = resolution
        request.language = language
        request.stockID = stockID
        if let session = sessionForCurrentDevice { request.settings = session.saved.settings }
        request.accentHue = accentHue
        if let reuse = reuseQueueName {
            request.queuePolicy = .reuse(reuse)
        } else if queueMatchesLoaded && !queueMatches.isEmpty {
            // Ausdrücklich „Zusätzlichen macOS-Drucker anlegen“ gewählt.
            request.queuePolicy = .createNew
        } else {
            // Vorhandene Warteschlangen noch unbekannt: eine eigene LabelWerk-Warteschlange
            // desselben Geräts wird aktualisiert statt verdoppelt.
            request.queuePolicy = .automatic
        }
        request.setAsDefault = setAsDefault
        request.printTestPage = printTestPage
        request.registerInLabelWerk = monitorInLabelWerk
        request.requireReachable = !continuesOffline
        return request
    }

    /// Pendant zu `service.steps`, solange die Installation noch nicht begonnen hat.
    var displayedSteps: [PrinterInstallStep] {
        if !service.steps.isEmpty { return service.steps }
        guard let request = lastRequest ?? makeRequest() else { return [] }
        return PrinterInstallService.plannedSteps(for: request).map { PrinterInstallStep(kind: $0, state: .pending) }
    }

    func startInstall() {
        // „Vom Drucker“ bzw. „Benutzerdefiniert …“ wird vor dem Auftrag ein echtes Format: Die
        // Warteschlange erhält es als benannte Standard-Papiergröße, LabelWerk speichert es am Drucker.
        guard canInstall, materializeStockChoice(), let request = makeRequest() else { return }
        lastRequest = request
        go(to: .install)
        run(request)
    }

    func retryInstall() {
        guard let request = lastRequest, !service.isRunning else { return }
        run(request)
    }

    private func run(_ request: PrinterInstallRequest) {
        guard let app else { return }
        installTask?.cancel()
        installTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.service.install(request, model: app)
            guard result != nil else { return }
            // Drucker eingerichtet (z. B. im Willkommensassistenten): Ein vom Installationspaket
            // angeforderter Assistent muss danach nicht mehr erscheinen.
            app.pendingInstallWizard = false
            await self.reloadMacQueues()
            if app.preferences.playSounds { SoundService.play(.success) }
            // Erst nach dem Einblenden des Erfolgsbildschirms auslösen (er reagiert auf Änderungen).
            try? await Task.sleep(for: .milliseconds(280))
            if !app.reducesMotion { self.celebration += 1 }
        }
    }

    /// „Weiteren Drucker installieren“: zurück zum ersten Schritt mit frischer Suche.
    func installAnother() {
        guard !service.isRunning else { return }
        detectTask?.cancel()
        probeTask?.cancel()
        mediaTask?.cancel()
        detectionGeneration += 1
        mediaGeneration += 1
        isReadingMedia = false
        mediaNote = nil
        detectedMedia = nil
        customEntry = LabelSizeEntry()
        stockChoiceTouched = false
        service.reset()
        candidate = nil
        manualHost = ""
        manualPort = ZebraIdentifiers.rawPort
        manualReachability = .idle
        detection = nil
        connectionFailure = nil
        continuesOffline = false
        isDetecting = false
        modelID = nil
        modelChosenManually = false
        modelSearch = ""
        name = ""
        nameEdited = false
        location = ""
        setAsDefault = false
        printTestPage = false
        monitorInLabelWerk = true
        matchGeneration += 1
        isLoadingQueueMatches = false
        queueMatches = []
        queueMatchesLoaded = false
        reuseQueueName = nil
        lastRequest = nil
        preparedDeviceID = nil
        if let app { accentHue = AppModel.nextAccentHue(after: app.sessions.count) }
        go(to: .choose)
        rescan()
    }

    // MARK: Hilfen

    private func animate(_ animation: Animation, _ changes: () -> Void) {
        if let app {
            app.animate(animation, changes)
        } else {
            changes()
        }
    }
}

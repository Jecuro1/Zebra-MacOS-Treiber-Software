import Foundation
import Observation
import SwiftUI
import LabelWerkKit

// MARK: - Auftrag

/// Was „Als macOS-Drucker installieren“ einrichten soll.
struct PrinterInstallRequest: Equatable {
    /// Wie mit einer vorhandenen Warteschlange für dasselbe Gerät verfahren wird.
    enum QueuePolicy: Equatable {
        /// Eine LabelWerk-Warteschlange mit derselben Geräte-URI wird aktualisiert, sonst eine neue angelegt.
        case automatic
        /// Diese vorhandene Warteschlange aktualisieren (Treiber, Optionen, Name in macOS).
        case reuse(String)
        /// Immer eine zusätzliche Warteschlange anlegen.
        case createNew
    }

    var descriptor: ConnectionDescriptor
    /// Bonjour-Name des Druckers (falls per Bonjour gefunden): erkennt Warteschlangen, die
    /// „Drucker & Scanner“ über den Bonjour-Eintrag angelegt hat (`dnssd://…`).
    var serviceName: String?
    /// Name des Druckers in macOS (Beschreibung der Warteschlange) und in LabelWerk.
    var name: String
    var location: String = ""
    var modelID: String?
    var resolution: Resolution = .dpi203
    var language: PrinterLanguage = .zpl
    var stockID: String = "w4h6in"
    var settings: PrintSettings = .default
    /// Akzentfarbe für einen neu angelegten LabelWerk-Drucker (nil = nächste freie).
    var accentHue: Double?
    var queuePolicy: QueuePolicy = .automatic
    var setAsDefault = false
    var printTestPage = false
    /// Drucker in LabelWerk aufnehmen (Live-Status, Werkzeuge), falls er dort noch fehlt.
    var registerInLabelWerk = true
    /// Ein nicht erreichbarer Drucker bricht die Installation ab (sonst nur Hinweis).
    var requireReachable = true

    /// Auftrag für einen bereits in LabelWerk eingerichteten Drucker (Hinzufügen mit
    /// „Auch als macOS-Drucker installieren“).
    init(saved: SavedPrinter) {
        self.descriptor = saved.descriptor
        // Heißt der Drucker nur nach seiner Adresse („10.62.13.19“), heißt der macOS-Drucker nach dem
        // Modell („Zebra ZD421t“) – nie nach der IP-Adresse.
        self.name = PrinterSetupPlanning.existingName(saved.name, descriptor: saved.descriptor)
            ?? saved.modelID.flatMap { ModelCatalog.shared.model(id: $0)?.displayName }
            ?? saved.name
        self.location = saved.location
        self.modelID = saved.modelID
        self.resolution = saved.resolution
        self.language = saved.language
        self.stockID = saved.stockID
        self.settings = saved.settings
        self.accentHue = saved.accentHue
        self.requireReachable = false
    }

    init(descriptor: ConnectionDescriptor, name: String) {
        self.descriptor = descriptor
        self.name = name
    }

    /// Kann für diese Verbindung eine macOS-Warteschlange eingerichtet werden?
    static func supports(_ descriptor: ConnectionDescriptor) -> Bool {
        switch descriptor.kind {
        case .tcp, .usb: return true
        case .bluetooth, .ble, .cupsQueue, .virtual: return false
        }
    }
}

// MARK: - Schritte

enum PrinterInstallStepKind: String, CaseIterable, Identifiable {
    case driver, connection, queue, defaultPrinter, testPage, register

    var id: String { rawValue }

    var title: String {
        switch self {
        case .driver: return tr("Treiber bereitstellen")
        case .connection: return tr("Drucker prüfen")
        case .queue: return tr("macOS-Drucker anlegen")
        case .defaultPrinter: return tr("Als Standarddrucker festlegen")
        case .testPage: return tr("Testseite drucken")
        case .register: return tr("In LabelWerk übernehmen")
        }
    }

    var systemImage: String {
        switch self {
        case .driver: return "shippingbox"
        case .connection: return "network"
        case .queue: return "printer"
        case .defaultPrinter: return "star"
        case .testPage: return "doc.text"
        case .register: return "waveform.path.ecg"
        }
    }
}

enum PrinterInstallStepState: Equatable {
    case pending
    case running(String?)
    case done(String?)
    /// Erledigt, aber mit Einschränkung (z. B. Testseite fehlgeschlagen).
    case warning(String)
    case skipped(String?)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .pending, .running: return false
        case .done, .warning, .skipped, .failed: return true
        }
    }
}

struct PrinterInstallStep: Identifiable, Equatable {
    let kind: PrinterInstallStepKind
    var state: PrinterInstallStepState
    var id: String { kind.rawValue }
}

// MARK: - Fehler

/// Verständlicher Fehler eines Installationsschritts mit Lösungsweg.
struct PrinterInstallFailure: Equatable {
    enum Recovery: Hashable {
        /// Erneut versuchen.
        case retry
        /// Adresse/Verbindung korrigieren (zurück zur Auswahl).
        case editConnection
        /// Modell ändern bzw. allgemeinen Treiber verwenden.
        case chooseModel
        /// Treiber unter „Treiber & Warteschlangen“ (neu) installieren.
        case openDriver
        /// Systemeinstellungen „Drucker & Scanner“ öffnen.
        case openPrinterSettings
    }

    var step: PrinterInstallStepKind
    var title: String
    var message: String
    /// Lösungsschritte.
    var hint: String
    var recoveries: [Recovery] = [.retry]
    /// Der Administrator-Passwortdialog wurde abgebrochen (kein echter Fehler).
    var isCancellation = false

    static func unreachable(host: String, port: Int, detail: String?) -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .connection,
            title: tr("Drucker nicht erreichbar"),
            message: detail.map { tr("%@:%d antwortet nicht – %@", host, port, $0) } ?? tr("%@:%d antwortet nicht.", host, port),
            hint: tr("Prüfen: Ist der Drucker eingeschaltet und bereit? Stimmt die IP-Adresse (Konfigurationsetikett)? Sind Mac und Drucker im selben Netzwerk bzw. WLAN? Blockiert eine Firewall oder ein Gast-WLAN Port %d?", port),
            recoveries: [.retry, .editConnection]
        )
    }

    static func administratorCancelled(step: PrinterInstallStepKind) -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: step,
            title: tr("Abgebrochen"),
            message: tr("Die Eingabe des Administratorpassworts wurde abgebrochen. Es wurde nichts verändert."),
            hint: tr("Zum Installieren fragt macOS einmalig nach dem Passwort eines Administrators dieses Macs. „Erneut versuchen“ öffnet die Abfrage wieder."),
            recoveries: [.retry],
            isCancellation: true
        )
    }

    static func driverPackageMissing() -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .driver,
            title: tr("Treiberpaket fehlt"),
            message: tr("Der LabelWerk-Treiber ist nicht installiert, und diese App enthält kein Treiberpaket."),
            hint: tr("LabelWerk mit dem Installationspaket (LabelWerk-….pkg) installieren – es richtet App und Treiber gemeinsam ein. Danach den Assistenten erneut starten."),
            recoveries: [.openDriver]
        )
    }

    static func driverInstallFailed(_ message: String) -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .driver,
            title: tr("Treiber konnte nicht installiert werden"),
            message: message,
            hint: tr("Unter „Treiber & Warteschlangen“ zeigt die Diagnose, was fehlt. Hilft das nicht, das LabelWerk-Installationspaket erneut ausführen."),
            recoveries: [.retry, .openDriver]
        )
    }

    static func missingPPD(model: String) -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .queue,
            title: tr("Keine passende Treiberdatei"),
            message: tr("Für „%@“ wurde keine PPD-Datei gefunden – auch keine allgemeine.", model),
            hint: tr("Den Treiber unter „Treiber & Warteschlangen“ erneut installieren (repariert fehlende PPD-Dateien) oder ein anderes Modell bzw. „Allgemeiner Zebra-Drucker“ wählen."),
            recoveries: [.chooseModel, .openDriver]
        )
    }

    static func usbNotVisible() -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .connection,
            title: tr("USB-Drucker nicht gefunden"),
            message: tr("macOS meldet keinen angeschlossenen Zebra-Drucker an USB."),
            hint: tr("Drucker einschalten, das USB-Kabel direkt am Mac anschließen (ohne Hub) und einige Sekunden warten. Dann erneut versuchen."),
            recoveries: [.retry, .editConnection]
        )
    }

    static func ambiguousUSB() -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .connection,
            title: tr("Mehrere USB-Drucker"),
            message: tr("Mehrere Zebra-Drucker sind per USB angeschlossen, und dieser lässt sich keinem eindeutig zuordnen."),
            hint: tr("Nur den gewünschten Drucker angeschlossen lassen und erneut versuchen."),
            recoveries: [.retry]
        )
    }

    static func unsupportedConnection() -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .connection,
            title: tr("Verbindung nicht unterstützt"),
            message: tr("Für diese Verbindung kann keine macOS-Warteschlange eingerichtet werden."),
            hint: tr("macOS-Drucker lassen sich für Netzwerk- (TCP/IP) und USB-Drucker einrichten."),
            recoveries: [.editConnection]
        )
    }

    static func queueFailed(_ message: String) -> PrinterInstallFailure {
        PrinterInstallFailure(
            step: .queue,
            title: tr("macOS-Drucker konnte nicht angelegt werden"),
            message: message,
            hint: tr("Erneut versuchen. Bleibt der Fehler, unter „Treiber & Warteschlangen“ die Diagnose prüfen oder den Drucker in den Systemeinstellungen „Drucker & Scanner“ entfernen und neu installieren."),
            recoveries: [.retry, .openDriver, .openPrinterSettings]
        )
    }
}

// MARK: - Ergebnis

struct PrinterInstallResult: Equatable {
    /// Name der Warteschlange (CUPS).
    var queueName: String
    /// Name in macOS (Druckdialog, Systemeinstellungen).
    var displayName: String
    /// LabelWerk-Drucker, der die Warteschlange verwendet (nil = nicht übernommen).
    var sessionID: UUID?
    /// Eine vorhandene Warteschlange wurde aktualisiert.
    var reusedQueue: Bool
    /// Allgemeine PPD statt einer modellspezifischen.
    var usesGenericDriver: Bool
    var isDefault: Bool
    var testPageSent: Bool
    /// Hinweise zu Schritten, die nicht vollständig gelungen sind.
    var warnings: [String]
}

/// Vorhandene macOS-Warteschlange für dasselbe Gerät.
struct ExistingQueueMatch: Identifiable, Equatable {
    var info: CUPSQueueInfo
    var isLabelWerk: Bool
    var match: PrinterSetupPlanning.QueueMatch
    var id: String { info.name }
}

// MARK: - Dienst

/// Richtet einen Zebra-Drucker als normalen macOS-Drucker ein – wie der Windows-Druckerinstaller:
/// Treiber bereitstellen, Drucker prüfen, Warteschlange mit LabelWerk-Treiber anlegen (bzw. eine
/// vorhandene aktualisieren), optional Standarddrucker und Testseite, zuletzt in LabelWerk
/// übernehmen. Jeder Schritt ist für die Fortschrittsanzeige beobachtbar.
@Observable
@MainActor
final class PrinterInstallService {
    enum Phase: Equatable {
        case idle, running, succeeded, failed
    }

    private(set) var steps: [PrinterInstallStep] = []
    private(set) var phase: Phase = .idle
    private(set) var failure: PrinterInstallFailure?
    private(set) var result: PrinterInstallResult?

    @ObservationIgnored private weak var model: AppModel?

    /// Laufende Treiberinstallation aller Dienste: Werden mehrere Drucker kurz nacheinander
    /// hinzugefügt, fragt macOS nur einmal nach dem Passwort, und alle warten auf dasselbe Ergebnis.
    private static var driverInstallTask: Task<Bool, Never>?

    init() {}

    var isRunning: Bool { phase == .running }

    /// Setzt Fortschritt und Ergebnis zurück (z. B. für „Weiteren Drucker installieren“).
    func reset() {
        guard phase != .running else { return }
        steps = []
        phase = .idle
        failure = nil
        result = nil
    }

    /// Schritte, die für einen Auftrag angezeigt werden.
    static func plannedSteps(for request: PrinterInstallRequest) -> [PrinterInstallStepKind] {
        var kinds: [PrinterInstallStepKind] = [.driver, .connection, .queue]
        if request.setAsDefault { kinds.append(.defaultPrinter) }
        if request.printTestPage { kinds.append(.testPage) }
        kinds.append(.register)
        return kinds
    }

    // MARK: Installation

    /// Führt alle Schritte aus. Liefert das Ergebnis oder nil (dann beschreibt `failure` den Fehler).
    @discardableResult
    func install(_ request: PrinterInstallRequest, model: AppModel) async -> PrinterInstallResult? {
        guard phase != .running else { return nil }
        self.model = model
        failure = nil
        result = nil
        steps = Self.plannedSteps(for: request).map { PrinterInstallStep(kind: $0, state: .pending) }
        phase = .running
        var warnings: [String] = []

        guard PrinterInstallRequest.supports(request.descriptor) else {
            return fail(.unsupportedConnection())
        }

        // a) Treiber
        if let failure = await ensureDriver() { return fail(failure) }

        // b) Drucker prüfen
        let connection = await checkConnection(request, model: model)
        switch connection {
        case .failure(let failure): return fail(failure)
        case .success(let warning): if let warning { warnings.append(warning) }
        }

        // c) Warteschlange
        let queue: QueueOutcome
        switch await createQueue(request) {
        case .failure(let failure): return fail(failure)
        case .success(let outcome): queue = outcome
        }
        if queue.usesGenericDriver, request.modelID != nil {
            warnings.append(tr("Für dieses Modell ist keine eigene PPD installiert – der allgemeine Treiber wird verwendet."))
        }

        // d) Standarddrucker & Testseite (Fehler sind hier nur Hinweise – der Drucker ist eingerichtet)
        var isDefault = false
        if request.setAsDefault {
            update(.defaultPrinter, .running(nil))
            do {
                try await CUPSService.setDefaultPrinter(queue.name)
                isDefault = true
                update(.defaultPrinter, .done(tr("Neue Druckaufträge gehen standardmäßig an diesen Drucker.")))
            } catch {
                let message = Self.describe(error)
                warnings.append(tr("Standarddrucker nicht festgelegt: %@", message))
                update(.defaultPrinter, .warning(message))
            }
        }
        var testPageSent = false
        if request.printTestPage {
            update(.testPage, .running(tr("Seite wird über den macOS-Druckweg gesendet …")))
            do {
                try await CUPSService.printTestPage(queue: queue.name)
                testPageSent = true
                update(.testPage, .done(tr("Gesendet – das Etikett sollte gleich herauskommen.")))
            } catch {
                let message = Self.describe(error)
                warnings.append(tr("Testseite nicht gedruckt: %@", message))
                update(.testPage, .warning(message))
            }
        }

        // e) In LabelWerk übernehmen
        let sessionID = register(request, queueName: queue.name, model: model)

        let outcome = PrinterInstallResult(
            queueName: queue.name,
            displayName: request.name,
            sessionID: sessionID,
            reusedQueue: queue.reused,
            usesGenericDriver: queue.usesGenericDriver,
            isDefault: isDefault,
            testPageSent: testPageSent,
            warnings: warnings
        )
        model.animate(Motion.spring) {
            result = outcome
            phase = .succeeded
        }
        return outcome
    }

    // MARK: a) Treiber

    private func ensureDriver() async -> PrinterInstallFailure? {
        let installer = DriverInstaller.shared
        update(.driver, .running(tr("Treiber wird geprüft …")))
        if installer.snapshot == nil { await installer.refresh() }
        // Läuft bereits eine Installation (z. B. aus einem anderen Fenster), auf sie warten.
        var waited = false
        while installer.isBusy {
            waited = true
            try? await Task.sleep(for: .milliseconds(300))
        }
        if CUPSService.isDriverInstalled {
            let detail = installer.installedVersion.map { tr("LabelWerk-Treiber %@ ist installiert.", $0) }
                ?? tr("LabelWerk-Treiber ist installiert.")
            update(.driver, .done(detail))
            return nil
        }
        guard installer.hasPayload else {
            update(.driver, .failed(tr("Treiberpaket fehlt")))
            return .driverPackageMissing()
        }
        // Wurde die Passwortabfrage der Installation, auf die hier gewartet wurde, abgebrochen, gilt
        // das auch für diesen Drucker – sonst würde jeder weitere wartende Drucker erneut fragen.
        if waited, Self.isAdministratorCancellation(installer.phase) {
            update(.driver, .failed(tr("Abgebrochen")))
            return .administratorCancelled(step: .driver)
        }
        update(.driver, .running(tr("Treiber wird installiert – macOS fragt nach einem Administratorpasswort …")))
        let ok: Bool
        if let running = Self.driverInstallTask {
            ok = await running.value
        } else {
            let task = Task { @MainActor in await installer.install() }
            Self.driverInstallTask = task
            ok = await task.value
            Self.driverInstallTask = nil
        }
        if ok && CUPSService.isDriverInstalled {
            update(.driver, .done(installer.installedVersion.map { tr("LabelWerk-Treiber %@ wurde installiert.", $0) }
                                  ?? tr("LabelWerk-Treiber wurde installiert.")))
            return nil
        }
        if Self.isAdministratorCancellation(installer.phase) {
            update(.driver, .failed(tr("Abgebrochen")))
            return .administratorCancelled(step: .driver)
        }
        switch installer.phase {
        case .failed(_, let message):
            update(.driver, .failed(message))
            return .driverInstallFailed(message)
        default:
            let message = tr("Der CUPS-Filter wurde nach der Installation nicht gefunden.")
            update(.driver, .failed(message))
            return .driverInstallFailed(message)
        }
    }

    /// Endete die letzte Treiberinstallation mit einer abgebrochenen Passwortabfrage?
    private static func isAdministratorCancellation(_ phase: DriverInstaller.Phase) -> Bool {
        switch phase {
        case .cancelled(let operation):
            return operation != .uninstall
        case .failed(let operation, let message):
            return operation != .uninstall && PrinterSetupPlanning.isAdministratorCancellation(message)
        default:
            return false
        }
    }

    // MARK: b) Drucker prüfen

    private enum ConnectionOutcome {
        case success(warning: String?)
        case failure(PrinterInstallFailure)
    }

    private func checkConnection(_ request: PrinterInstallRequest, model: AppModel) async -> ConnectionOutcome {
        let session = model.sessions.first { $0.saved.descriptor.refersToSameDevice(as: request.descriptor) }
        switch request.descriptor {
        case .tcp(let host, let port):
            if let session, session.connectionState.isConnected {
                update(.connection, .done(tr("Verbunden mit %@", request.descriptor.displayString)))
                return .success(warning: nil)
            }
            update(.connection, .running(tr("Verbindung zu %@ wird geprüft …", request.descriptor.displayString)))
            let probe = await Self.probeReachability(host: host, port: port)
            switch probe {
            case .reachable(let milliseconds):
                update(.connection, .done(tr("Erreichbar · %d ms", milliseconds)))
                return .success(warning: nil)
            case .unreachable(let message):
                if request.requireReachable {
                    update(.connection, .failed(message))
                    return .failure(.unreachable(host: host, port: port, detail: message))
                }
                let warning = tr("%@ ist gerade nicht erreichbar – der macOS-Drucker wird trotzdem eingerichtet und druckt, sobald der Drucker eingeschaltet ist.", request.descriptor.displayString)
                update(.connection, .warning(warning))
                return .success(warning: warning)
            case .idle, .checking:
                update(.connection, .done(nil))
                return .success(warning: nil)
            }
        case .usb:
            update(.connection, .running(tr("USB-Drucker wird gesucht …")))
            do {
                guard try await CUPSService.deviceURI(for: request.descriptor) != nil else {
                    update(.connection, .failed(tr("Nicht gefunden")))
                    return .failure(.usbNotVisible())
                }
                update(.connection, .done(tr("Angeschlossen: %@", request.descriptor.displayString)))
                return .success(warning: nil)
            } catch CUPSService.CUPSError.ambiguousUSBDevice {
                update(.connection, .failed(tr("Nicht eindeutig")))
                return .failure(.ambiguousUSB())
            } catch {
                let message = Self.describe(error)
                update(.connection, .failed(message))
                return .failure(.usbNotVisible())
            }
        case .bluetooth, .ble, .cupsQueue, .virtual:
            update(.connection, .failed(tr("Nicht unterstützt")))
            return .failure(.unsupportedConnection())
        }
    }

    // MARK: c) Warteschlange

    private struct QueueOutcome {
        var name: String
        var reused: Bool
        var usesGenericDriver: Bool
    }

    private enum QueueResult {
        case success(QueueOutcome)
        case failure(PrinterInstallFailure)
    }

    private func createQueue(_ request: PrinterInstallRequest) async -> QueueResult {
        update(.queue, .running(tr("Treiberdatei wird ausgewählt …")))
        guard let ppd = CUPSService.ppdURL(modelID: request.modelID, resolution: request.resolution,
                                           language: request.language) else {
            let modelName = request.modelID.flatMap { ModelCatalog.shared.model(id: $0)?.displayName } ?? request.name
            update(.queue, .failed(tr("Keine PPD-Datei gefunden")))
            return .failure(.missingPPD(model: modelName))
        }
        let generic = PrinterSetupPlanning.isGenericPPD(ppd.lastPathComponent)

        update(.queue, .running(tr("Vorhandene macOS-Drucker werden geprüft …")))
        let queues = await CUPSService.queues()
        let matches = await Self.existingQueues(for: request.descriptor, among: queues, serviceName: request.serviceName)
        let names = queues.map(\.name)
        let base = CUPSService.sanitizedQueueName(request.name)
        var queueName: String
        switch request.queuePolicy {
        case .reuse(let existing) where matches.contains(where: { $0.info.name == existing }):
            // Nur eine Warteschlange, die wirklich zu diesem Gerät führt – nie den macOS-Drucker
            // eines anderen Geräts umleiten.
            queueName = existing
        case .automatic:
            if let own = matches.first(where: { $0.isLabelWerk && $0.match == .exact }) {
                queueName = own.info.name
            } else {
                queueName = PrinterSetupPlanning.uniqueQueueName(base, taken: names)
            }
        case .reuse, .createNew:
            queueName = PrinterSetupPlanning.uniqueQueueName(base, taken: names)
        }
        let reused = names.contains(queueName)

        let saved = SavedPrinter(
            name: request.name,
            descriptor: request.descriptor,
            modelID: request.modelID,
            resolution: request.resolution,
            language: request.language,
            stockID: request.stockID,
            settings: request.settings,
            location: request.location.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        update(.queue, .running(reused
            ? tr("„%@“ wird mit dem LabelWerk-Treiber aktualisiert …", queueName)
            : tr("„%@“ wird angelegt – macOS fragt ggf. nach einem Administratorpasswort …", queueName)))
        let installed: String
        do {
            // Eigene Formate (z. B. „Vom Drucker: 104 × 76,2 mm“) kennt nur das AppModel: die Größe wird
            // benannte Standard-Papiergröße der Warteschlange (CUPSService ergänzt sie in der PPD).
            installed = try await CUPSService.installQueue(for: saved, queueName: queueName,
                                                           stock: model?.stock(id: request.stockID))
        } catch {
            let message = Self.describe(error)
            if PrinterSetupPlanning.isAdministratorCancellation(message) {
                update(.queue, .failed(tr("Abgebrochen")))
                return .failure(.administratorCancelled(step: .queue))
            }
            update(.queue, .failed(message))
            return .failure(Self.queueFailure(for: error, message: message, modelName: request.name))
        }
        // Prüfen, ob CUPS die Warteschlange wirklich kennt (lpadmin meldet nicht jeden Fehler).
        let after = await CUPSService.queues()
        guard after.contains(where: { $0.name == installed }) else {
            let message = tr("Die Warteschlange „%@“ ist nach dem Anlegen nicht vorhanden.", installed)
            update(.queue, .failed(message))
            return .failure(.queueFailed(message))
        }
        let driverText = generic
            ? tr("Allgemeiner Treiber (%@, %d dpi)", request.language.displayName, request.resolution.dpi)
            : tr("Treiber für %@ (%d dpi)",
                 request.modelID.flatMap { ModelCatalog.shared.model(id: $0)?.displayName } ?? request.name,
                 request.resolution.dpi)
        update(.queue, generic && request.modelID != nil
               ? .warning(tr("„%@“ eingerichtet · %@", installed, driverText))
               : .done(tr("„%@“ eingerichtet · %@", installed, driverText)))
        return .success(QueueOutcome(name: installed, reused: reused, usesGenericDriver: generic))
    }

    private static func queueFailure(for error: Error, message: String, modelName: String) -> PrinterInstallFailure {
        if let cups = error as? CUPSService.CUPSError {
            switch cups {
            case .driverNotInstalled:
                return .driverInstallFailed(message)
            case .noPPD:
                return .missingPPD(model: modelName)
            case .noDeviceURI:
                return .unsupportedConnection()
            case .ambiguousUSBDevice:
                return .ambiguousUSB()
            case .invalidQueueName, .optionsNotApplied, .notAuthorized, .queueMissing, .notLabelWerkQueue:
                return .queueFailed(message)
            }
        }
        return .queueFailed(message)
    }

    // MARK: e) In LabelWerk übernehmen

    private func register(_ request: PrinterInstallRequest, queueName: String, model: AppModel) -> UUID? {
        update(.register, .running(nil))
        if let session = model.sessions.first(where: { $0.saved.descriptor.refersToSameDevice(as: request.descriptor) }) {
            var saved = session.saved
            saved.cupsQueueName = queueName
            // Hieß der Drucker nur nach seiner Adresse („10.62.13.19“), übernimmt er den Namen des
            // macOS-Druckers („Zebra ZD421t“).
            if PrinterSetupPlanning.existingName(saved.name, descriptor: saved.descriptor) == nil,
               let name = PrinterSetupPlanning.nonEmpty(request.name) {
                saved.name = name
            }
            // Modell, Auflösung und Sprache der eben eingerichteten Warteschlange (PPD, `lwLanguage`)
            // gelten auch in LabelWerk – sonst glich `QueueSyncService` sie auf die alten Werte zurück.
            if let modelID = request.modelID { saved.modelID = modelID }
            saved.resolution = request.resolution
            saved.language = request.language
            if saved.location.isEmpty, !request.location.isEmpty { saved.location = request.location }
            // Im Assistenten gewähltes Etikett (z. B. „Vom Drucker: 104 × 76,2 mm“) gilt auch in
            // LabelWerk – sonst glich `QueueSyncService` die Warteschlange auf das alte Format zurück.
            if model.stock(id: request.stockID) != nil { saved.stockID = request.stockID }
            session.saved = saved
            update(.register, .done(tr("„%@“ verwendet jetzt diesen macOS-Drucker.", session.displayName)))
            return session.id
        }
        guard request.registerInLabelWerk else {
            update(.register, .skipped(tr("Nicht gewünscht – nur als macOS-Drucker eingerichtet.")))
            return nil
        }
        var saved = SavedPrinter(
            name: request.name,
            descriptor: request.descriptor,
            modelID: request.modelID,
            resolution: request.resolution,
            language: request.language,
            stockID: request.stockID,
            settings: request.settings,
            accentHue: request.accentHue ?? AppModel.nextAccentHue(after: model.sessions.count),
            location: request.location.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saved.cupsQueueName = queueName
        let session = model.addPrinter(saved)
        update(.register, .done(tr("Live-Status, Werkzeuge und Mitteilungen sind aktiv.")))
        return session.id
    }

    // MARK: Zustand

    private func update(_ kind: PrinterInstallStepKind, _ state: PrinterInstallStepState) {
        guard let index = steps.firstIndex(where: { $0.kind == kind }) else { return }
        let apply = { self.steps[index].state = state }
        if let model {
            model.animate(Motion.spring, apply)
        } else {
            apply()
        }
    }

    private func fail(_ failure: PrinterInstallFailure) -> PrinterInstallResult? {
        // Noch offene Schritte bleiben „ausstehend“; ein laufender gilt als fehlgeschlagen.
        if let index = steps.firstIndex(where: { if case .running = $0.state { return true } else { return false } }) {
            steps[index].state = .failed(failure.title)
        }
        let apply = {
            self.failure = failure
            self.phase = .failed
        }
        if let model {
            model.animate(Motion.spring, apply)
        } else {
            apply()
        }
        return nil
    }

    // MARK: Erkennung (Assistent)

    /// Prüft die Erreichbarkeit (TCP, kurzes Zeitlimit).
    static func probeReachability(host: String, port: Int) async -> DiscoveryReachability {
        await DiscoveryProbe.check(host: host, port: port)
    }

    /// Erkennt Modell, Auflösung und Sprachen eines Druckers.
    ///
    /// Netzwerkgeräte, die nicht nachweislich Zebra-Drucker sind, erhalten nur eine gefahrlose
    /// SNMP-Abfrage; `~HI`/SGD gehen an sie erst nach ausdrücklicher Zustimmung
    /// (`allowUnverifiedQuery`) – ein Bürodrucker an Port 9100 würde die Abfrage sonst als Seite
    /// drucken. Bereits verbundene LabelWerk-Drucker liefern ihre bekannte Identität.
    static func detect(descriptor: ConnectionDescriptor, discovered: DiscoveredPrinter?,
                       allowUnverifiedQuery: Bool, model: AppModel) async -> PrinterDetection {
        var detection = PrinterSetupPlanning.detection(from: discovered, descriptor: descriptor)
        let session = model.sessions.first { $0.saved.descriptor.refersToSameDevice(as: descriptor) }
        if let session, session.connectionState.isConnected, let identity = session.identity {
            detection.reachable = true
            PrinterSetupPlanning.apply(identity: identity, to: &detection)
            if detection.modelID == nil, let known = session.saved.modelID {
                detection.modelID = known
                detection.source = .printer
            }
            detection.media = await readMediaSize(of: session)
            return detection
        }

        switch descriptor {
        case .tcp(let host, let port):
            switch await probeReachability(host: host, port: port) {
            case .reachable(let milliseconds):
                detection.reachable = true
                detection.latencyMS = milliseconds
            case .unreachable(let message):
                detection.reachable = false
                detection.connectionError = message
                return detection
            case .idle, .checking:
                break
            }
            if detection.zebraCheck == .unverified {
                await identifySafely(host: host, port: port, into: &detection)
            }
        case .usb:
            detection.reachable = true
        case .bluetooth, .ble, .cupsQueue, .virtual:
            return detection
        }

        guard detection.mayQueryPrinter || (allowUnverifiedQuery && detection.zebraCheck == .unverified) else {
            detection.queryWithheld = detection.zebraCheck == .unverified
            return detection
        }
        do {
            let (identity, media) = try await queryIdentity(descriptor: descriptor)
            PrinterSetupPlanning.apply(identity: identity, to: &detection)
            detection.media = media
        } catch is CancellationError {
            return detection
        } catch {
            detection.identifyError = describe(error)
        }
        return detection
    }

    /// Gefahrlose Identifikation eines einzelnen Netzwerkgeräts über die Suche (SNMP; `~HI` nur,
    /// wenn SNMP es eindeutig als Zebra meldet).
    private static func identifySafely(host: String, port: Int, into detection: inout PrinterDetection) async {
        var options = PrinterDiscovery.Options()
        // Die SNMP-Abfrage der Suche nimmt nur numerische Adressen an: Hostnamen (z. B.
        // „zebra-lager.firma.local“) vorher auflösen, sonst bliebe ein Zebra-Drucker unbestätigt.
        let address = await numericAddress(for: host)
        options.networkHosts = [address ?? host]
        options.networkPorts = [port]
        options.connectTimeout = .seconds(2)
        options.includeNonZebraNetworkDevices = true
        options.includeUnidentifiedNetworkDevices = true
        let discovery = PrinterDiscovery(options: options)
        var found: DiscoveredPrinter?
        for await printer in discovery.discover(sources: [.network], timeout: .seconds(5)) {
            found = printer
        }
        guard let found else { return }
        let hinted = PrinterSetupPlanning.detection(from: found, descriptor: detection.descriptor)
        detection.zebraCheck = hinted.zebraCheck
        if hinted.modelID != nil || detection.modelID == nil {
            detection.modelID = hinted.modelID ?? detection.modelID
            detection.source = hinted.modelID != nil ? hinted.source : detection.source
        }
        detection.rawModel = hinted.rawModel ?? detection.rawModel
        detection.resolution = hinted.resolution ?? detection.resolution
        detection.firmware = hinted.firmware ?? detection.firmware
        detection.friendlyName = hinted.friendlyName ?? detection.friendlyName
        if detection.languages.isEmpty { detection.languages = hinted.languages }
    }

    /// Numerische Adresse eines Hostnamens (IPv4 bevorzugt), nil = nicht auflösbar. Läuft außerhalb
    /// des Main-Threads – eine DNS-Anfrage kann dauern.
    private static func numericAddress(for host: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
            defer { freeaddrinfo(list) }
            var chosen = first
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                if entry.pointee.ai_family == AF_INET {
                    chosen = entry
                    break
                }
                cursor = entry.pointee.ai_next
            }
            guard let address = chosen.pointee.ai_addr else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, chosen.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return buffer.withUnsafeBufferPointer { pointer in
                pointer.baseAddress.map { String(cString: $0) }
            }
        }.value
    }

    /// Fragt Modell, Auflösung und Sprachen beim Drucker ab (`~HI` + SGD), dazu bei ZPL-Druckern die
    /// eingestellte Etikettengröße (`readMediaSize`, Breite = Druckbreite wie in ZDesigner) – in
    /// derselben Verbindung, zusammen höchstens 15 Sekunden.
    private static func queryIdentity(descriptor: ConnectionDescriptor) async throws
        -> (identity: PrinterIdentity, media: DetectedMedia?) {
        let connection: any PrinterConnection
        if case .tcp(let host, let port) = descriptor {
            connection = TCPConnection(host: host, port: port, connectTimeout: .seconds(4))
        } else {
            connection = try ConnectionFactory.make(descriptor)
        }
        let client = PrinterClient(connection: connection, language: .zpl)
        return try await withThrowingTaskGroup(of: (identity: PrinterIdentity, media: DetectedMedia?)?.self) { group in
            group.addTask {
                defer { Task { await client.disconnect() } }
                try await client.connect()
                let identity = try await client.identify()
                // EPL/CPCL-Drucker melden keine Größe (readMediaSize liefert nur bei ZPL einen Wert).
                let media = identity.languages.isEmpty || identity.languages.contains(.zpl)
                    ? await client.readMediaSize() : nil
                await client.disconnect()
                return (identity, media)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else {
                // Zeitlimit: Abfrage abbrechen und die Verbindung direkt schließen. Das lässt die
                // laufende Anfrage sofort scheitern – `client.disconnect()` müsste dagegen erst auf
                // die Sperre warten, die `identify()` bis zu seinem Ende hält.
                group.cancelAll()
                await connection.close()
                throw PrinterClientError.noResponse(tr("Drucker identifizieren"))
            }
            return result
        }
    }

    // MARK: Etikettengröße vom Drucker

    /// Liest die eingestellte Etikettengröße eines Druckers erneut („Vom Drucker übernehmen“ im
    /// Assistenten bzw. beim manuellen Hinzufügen): über die Verbindung eines eingerichteten,
    /// verbundenen Druckers, sonst über eine eigene kurze Verbindung (höchstens 10 Sekunden).
    ///
    /// Nur aufrufen, wenn beim Gerät nachgefragt werden darf (`PrinterDetection.mayQueryPrinter`
    /// oder ausdrückliche Zustimmung) – die Abfrage geht als ZPL/SGD an Port 9100.
    /// - Returns: `nil` bei EPL/CPCL, ohne Antwort oder ohne eingestellte Etikettenlänge.
    static func readMediaSize(descriptor: ConnectionDescriptor, model: AppModel) async -> DetectedMedia? {
        if let session = model.sessions.first(where: { $0.saved.descriptor.refersToSameDevice(as: descriptor) }),
           session.connectionState.isConnected {
            return await readMediaSize(of: session)
        }
        let connection: any PrinterConnection
        switch descriptor {
        case .tcp(let host, let port):
            connection = TCPConnection(host: host, port: port, connectTimeout: .seconds(4))
        case .usb:
            guard let made = try? ConnectionFactory.make(descriptor) else { return nil }
            connection = made
        case .bluetooth, .ble, .cupsQueue, .virtual:
            return nil
        }
        let client = PrinterClient(connection: connection, language: .zpl)
        return await withTaskGroup(of: DetectedMedia??.self) { group in
            group.addTask {
                defer { Task { await client.disconnect() } }
                guard (try? await client.connect()) != nil else { return .some(nil) }
                let media = await client.readMediaSize()
                await client.disconnect()
                return .some(media)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            defer { group.cancelAll() }
            let first = await group.next() ?? nil
            guard let result = first else {
                // Zeitlimit: Verbindung direkt schließen (siehe queryIdentity).
                group.cancelAll()
                await connection.close()
                return nil
            }
            return result
        }
    }

    /// Etikettengröße über die Verbindung eines verbundenen Druckers (still, ohne Hinweis bei Fehlern).
    static func readMediaSize(of session: PrinterSession) async -> DetectedMedia? {
        guard session.saved.language == .zpl else { return nil }
        return await session.withClient(tr("Etikettengröße wird gelesen …"), quiet: true) { client in
            await client.readMediaSize()
        } ?? nil
    }

    /// Vorhandene Warteschlangen, die zu diesem Gerät führen (LabelWerk-Treiber zuerst).
    /// `serviceName` (Bonjour-Name) erkennt zusätzlich `dnssd://`-Warteschlangen des Geräts.
    static func existingQueues(for descriptor: ConnectionDescriptor,
                               among queues: [CUPSQueueInfo]? = nil,
                               serviceName: String? = nil) async -> [ExistingQueueMatch] {
        guard let uri = try? await CUPSService.deviceURI(for: descriptor) else { return [] }
        let all: [CUPSQueueInfo]
        if let queues {
            all = queues
        } else {
            all = await CUPSService.queues()
        }
        let candidates = all.compactMap { info -> (CUPSQueueInfo, PrinterSetupPlanning.QueueMatch)? in
            guard let match = PrinterSetupPlanning.queueMatch(queueURI: info.deviceURI, deviceURI: uri,
                                                              serviceName: serviceName) else { return nil }
            return (info, match)
        }
        guard !candidates.isEmpty else { return [] }
        let labelWerk = await DriverQueueClassifier.labelWerkQueueNames(in: candidates.map { $0.0 })
        return candidates
            .map { ExistingQueueMatch(info: $0.0, isLabelWerk: labelWerk.contains($0.0.name), match: $0.1) }
            .sorted { lhs, rhs in
                if lhs.match != rhs.match { return lhs.match == .exact }
                if lhs.isLabelWerk != rhs.isLabelWerk { return lhs.isLabelWerk }
                return lhs.info.name.localizedStandardCompare(rhs.info.name) == .orderedAscending
            }
    }

    // MARK: Hinzufügen mit „Auch als macOS-Drucker installieren“

    /// Richtet für einen gerade hinzugefügten Drucker im Hintergrund die macOS-Warteschlange ein
    /// (vorhandene LabelWerk-Warteschlange desselben Geräts wird aktualisiert). Fortschritt und
    /// Ergebnis erscheinen als Hinweise – das Sheet darf sich währenddessen schließen.
    static func installInBackground(for session: PrinterSession, model: AppModel) {
        guard supports(session.saved.descriptor) else { return }
        let service = PrinterInstallService()
        Task { @MainActor in
            // Verbindungsaufbau abwarten: Er ermittelt Modell und Auflösung, falls noch unbekannt.
            await session.connect()
            guard model.sessions.contains(where: { $0.id == session.id }) else { return }
            let request = PrinterInstallRequest(saved: session.saved)
            model.toast(tr("macOS-Drucker wird eingerichtet …"), message: session.displayName, style: .info)
            if let result = await service.install(request, model: model) {
                let message = result.warnings.isEmpty
                    ? tr("„%@“ erscheint jetzt in jedem Druckdialog und in „Drucker & Scanner“.", result.displayName)
                    : result.warnings.joined(separator: " ")
                model.toast(tr("Als macOS-Drucker installiert"), message: message,
                            style: result.warnings.isEmpty ? .success : .warning)
                if model.preferences.playSounds { SoundService.play(.success) }
            } else if let failure = service.failure {
                model.toast(failure.isCancellation ? tr("macOS-Drucker nicht eingerichtet") : failure.title,
                            message: failure.isCancellation
                                ? tr("Die Passwortabfrage wurde abgebrochen. Unter „Treiber & Warteschlangen“ lässt sich die Warteschlange jederzeit einrichten.")
                                : "\(failure.message) \(failure.hint)",
                            style: failure.isCancellation ? .warning : .error)
            }
        }
    }

    static func supports(_ descriptor: ConnectionDescriptor) -> Bool {
        PrinterInstallRequest.supports(descriptor)
    }

    /// Lesbare Fehlermeldung (LocalizedError bevorzugt).
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }
}

import Foundation
import LabelWerkKit

/// Etikettendruck („Mit LabelWerk drucken“): Ziel und Versand eines fertig kodierten Auftrags.
///
/// Gesendet werden genau die Bytes, aus denen die Vorschau stammt (`LabelPrintPipeline`) – direkt über
/// die Verbindung des Druckers. Ist er nicht erreichbar, gehen dieselben Bytes als Rohauftrag
/// (`lp -o raw`, `CUPSQueueConnection`) an die macOS-Warteschlange des Etikettentyps bzw. des Druckers:
/// CUPS hält den Auftrag, bis der Drucker wieder da ist, und der Ausdruck entspricht trotzdem genau der
/// Vorschau (ein Rohauftrag läuft nicht noch einmal durch den Treiber).
extension PrinterSession {
    /// Wie gedruckt wurde.
    enum LabelPrintRoute: Equatable {
        /// Über die Verbindung des Druckers (Netzwerk, USB, Bluetooth …).
        case direct
        /// Als Rohauftrag an diese macOS-Warteschlange (Drucker gerade nicht direkt erreichbar).
        case queue(String)
    }

    enum LabelPrintOutcome: Equatable {
        case printed(LabelPrintRoute)
        case failed(String)
    }

    /// Ziel für einen Druck mit `type` (`nil` = Standard des Druckers): Einstellungen, Format und
    /// Druckbreite – dieselben, die die macOS-Warteschlange des Typs erhält.
    func labelPrintTarget(for type: LabelType?) -> LabelPrintTarget {
        LabelPrintTarget(printerID: id, labelTypeID: type?.id, language: saved.language, resolution: resolution,
                         settings: effectiveSettings(for: type), stock: stock(for: type),
                         maxPrintWidthDots: model?.printWidthDots(resolution))
    }

    /// macOS-Warteschlangen, über die ein Rohauftrag dieses Druckers ankommt: die des Typs, die
    /// verknüpfte und die übernommenen (alle führen zum selben Gerät).
    func labelPrintFallbackQueues(for type: LabelType?) -> [String] {
        var names: [String] = []
        for candidate in [queueName(for: type), saved.cupsQueueName] + saved.adoptedQueueNames.map(Optional.some) {
            guard let name = candidate?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// Sendet einen kodierten Etikettendruck-Auftrag (`LabelPrintPipeline.encode`) und schreibt den
    /// Verlauf. Direkt, sobald der Drucker verbunden ist; scheitert schon der Verbindungsaufbau, als
    /// Rohauftrag über eine macOS-Warteschlange. Scheitert das Senden mittendrin, wird nicht über die
    /// Warteschlange wiederholt (sonst kämen Etiketten doppelt).
    func printLabelJob(_ data: Data, target: LabelPrintTarget, type: LabelType?, title: String, labels: Int,
                       preview: GrayImage?) async -> LabelPrintOutcome {
        let encoder = target.encoder
        let cancelPrefix = encoder.cancelPrefixLength()
        let delay = target.settings.clamped().cancelDelayMs
        if connectionState != .connected { await connect() }

        var outcome: LabelPrintOutcome
        if connectionState == .connected {
            let ok = await withClient(tr("Etiketten werden gedruckt …"), quiet: true) { client in
                try await client.sendJob(data, cancelPrefixLength: cancelPrefix, delayMilliseconds: delay)
            } != nil
            outcome = ok ? .printed(.direct) : .failed(lastError ?? tr("Der Drucker hat den Auftrag nicht angenommen."))
        } else {
            outcome = .failed(lastError ?? tr("Der Drucker ist nicht erreichbar."))
            for queue in labelPrintFallbackQueues(for: type) {
                do {
                    try await Self.sendRaw(data, queue: queue, title: title, language: saved.language,
                                           cancelPrefix: cancelPrefix, delay: delay)
                    outcome = .printed(.queue(queue))
                    break
                } catch {
                    outcome = .failed(Self.describe(error))
                }
            }
        }

        let ok: Bool
        let message: String?
        switch outcome {
        case .printed(.direct):
            ok = true
            message = nil
        case .printed(.queue(let queue)):
            ok = true
            message = tr("Über die macOS-Warteschlange „%@“ gesendet (Drucker nicht direkt erreichbar).", queue)
        case .failed(let error):
            ok = false
            message = error
        }
        var thumbnail: Data?
        if ok, let preview { thumbnail = await Self.previewPNG(image: preview) }
        let stored = data.count <= JobRecord.maxStoredPayload ? data : nil
        app?.record(JobRecord(printerID: id, printerName: displayName, title: title, kind: .image,
                              labels: ok ? labels : 0, bytes: data.count, success: ok, message: message,
                              previewPNG: thumbnail, payload: ok ? stored : nil))
        if ok, app?.preferences.playSounds == true { SoundService.play(.printed) }
        return outcome
    }

    /// Rohauftrag über eine macOS-Warteschlange (`lp -d <queue> -o raw`), mit „Aufträge vor dem Drucken
    /// abbrechen“ wie beim direkten Druck in zwei Teilen.
    private static func sendRaw(_ data: Data, queue: String, title: String, language: PrinterLanguage,
                                cancelPrefix: Int?, delay: Int) async throws {
        let connection = CUPSQueueConnection(queue: queue, jobTitle: title)
        let client = PrinterClient(connection: connection, language: language)
        do {
            try await client.connect()
            try await client.sendJob(data, cancelPrefixLength: cancelPrefix, delayMilliseconds: delay)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }
}

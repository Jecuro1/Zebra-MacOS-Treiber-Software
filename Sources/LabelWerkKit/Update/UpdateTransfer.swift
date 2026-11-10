import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Weiterleitungsregeln für Update-Anfragen.
///
/// * Nur HTTPS-Ziele (keine Herabstufung auf HTTP).
/// * Der `Authorization`-Kopf (Zugriffstoken) bleibt nur erhalten, wenn das Ziel
///   `api.github.com` oder `github.com` ist – Weiterleitungen auf andere Hosts (z. B. die
///   signierten Download-Adressen unter `*.githubusercontent.com`) erhalten ihn nie.
enum UpdateRedirectPolicy {

    /// Hosts, an die der Zugriffstoken gesendet werden darf.
    static let tokenHosts: Set<String> = ["api.github.com", "github.com"]

    /// Höchstzahl an Weiterleitungen je Anfrage.
    static let maximumRedirects = 10

    /// `true`, wenn der Token an `url` gesendet werden darf.
    static func mayCarryToken(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return tokenHosts.contains(host)
    }

    /// Anfrage für die Weiterleitung von `original` nach `proposed` (z. B. von URLSession
    /// vorgeschlagen) bzw. `nil`, wenn die Weiterleitung nicht erlaubt ist.
    static func redirect(from original: URLRequest, to proposed: URLRequest) -> URLRequest? {
        guard let target = proposed.url, target.scheme?.lowercased() == "https", target.host != nil else {
            return nil
        }
        var request = proposed
        // Kopfzeilen der ursprünglichen Anfrage übernehmen (URLSession übernimmt sie nicht überall).
        for (name, value) in original.allHTTPHeaderFields ?? [:]
        where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !mayCarryToken(target) {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Anfrage für die Weiterleitung von `original` nach `location`.
    static func redirect(from original: URLRequest, to location: URL) -> URLRequest? {
        var proposed = URLRequest(url: location)
        proposed.httpMethod = "GET"
        proposed.cachePolicy = original.cachePolicy
        proposed.timeoutInterval = original.timeoutInterval
        return redirect(from: original, to: proposed)
    }
}

/// Ergebnis einer einzelnen HTTP-Anfrage (ohne Weiterleitungen).
struct UpdateHTTPResult: Sendable {
    var response: HTTPURLResponse
    /// Antwortinhalt im Speicher (bei Dateiübertragungen nur für Antworten außerhalb 2xx).
    var body: Data
    /// In die Zieldatei geschriebene Bytes (nur Dateiübertragungen).
    var bytesWritten: Int
}

/// Session-Delegate einer einzelnen Übertragung: sammelt die Antwort im Speicher oder schreibt
/// sie in eine Datei, meldet Fortschritt, wendet die ``UpdateRedirectPolicy`` an und lässt sich
/// abbrechen. Je Übertragung wird eine eigene Session mit diesem Delegate angelegt.
final class UpdateTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// Wohin der Antwortinhalt (bei Status 2xx) geschrieben wird.
    enum Sink {
        /// Im Speicher sammeln, höchstens `limit` Bytes.
        case memory(limit: Int)
        /// In `file` schreiben (höchstens `expectedSize` Bytes) und Fortschritt melden.
        case file(URL, expectedSize: Int, progress: @Sendable (Double) -> Void)
    }

    /// Antworten außerhalb 2xx werden nur bis zu dieser Größe gesammelt.
    private static let errorBodyLimit = 64 * 1024

    private let sink: Sink
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UpdateHTTPResult, any Error>?
    private var task: URLSessionTask?
    private var cancelled = false
    private var failure: UpdateError?
    private var body = Data()
    private var fileHandle: FileHandle?
    private var written = 0
    private var lastReported = -1.0

    init(sink: Sink) {
        self.sink = sink
    }

    /// Startet `task`; das Ergebnis kommt über `continuation`.
    func start(_ task: URLSessionTask, continuation: CheckedContinuation<UpdateHTTPResult, any Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: UpdateError.cancelled)
            return
        }
        self.continuation = continuation
        self.task = task
        lock.unlock()
        task.resume()
    }

    /// Bricht die Übertragung ab (auch vor dem Start).
    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        completionHandler(UpdateRedirectPolicy.redirect(from: original, to: request))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let status = (dataTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var report: (@Sendable (Double) -> Void, Double)?
        lock.lock()
        let failed = receive(data, status: status, report: &report)
        lock.unlock()
        // Abbrechen und Fortschritt melden erst nach dem Freigeben der Sperre.
        if failed {
            dataTask.cancel()
        } else if let (progress, fraction) = report {
            progress(fraction)
        }
    }

    /// Verarbeitet empfangene Daten (unter der Sperre). Liefert `true`, wenn die Übertragung
    /// abgebrochen werden muss (`failure` ist dann gesetzt).
    private func receive(_ data: Data, status: Int, report: inout (@Sendable (Double) -> Void, Double)?) -> Bool {
        guard failure == nil, !cancelled else { return false }
        switch sink {
        case .memory(let limit):
            guard body.count + data.count <= limit else {
                failure = (200..<300).contains(status)
                    ? .invalidManifest("Die Antwort des Servers ist zu groß")
                    : .network("Die Antwort des Servers ist zu groß (HTTP \(status))")
                return true
            }
            body.append(data)
        case .file(let url, let expectedSize, let progress):
            guard (200..<300).contains(status) else {
                if body.count < UpdateTransferDelegate.errorBodyLimit {
                    body.append(data.prefix(UpdateTransferDelegate.errorBodyLimit - body.count))
                }
                return false
            }
            guard written + data.count <= expectedSize else {
                failure = .sizeMismatch
                return true
            }
            do {
                if fileHandle == nil {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    fileHandle = try FileHandle(forWritingTo: url)
                }
                try fileHandle?.write(contentsOf: data)
            } catch {
                failure = .installFailed("Die Update-Datei konnte nicht gespeichert werden (\(error.localizedDescription))")
                return true
            }
            written += data.count
            let fraction = expectedSize > 0 ? min(1, Double(written) / Double(expectedSize)) : 0
            if fraction >= 1 || fraction - lastReported >= 0.005 {
                lastReported = fraction
                report = (progress, fraction)
            }
        }
        return false
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        try? fileHandle?.close()
        fileHandle = nil
        let outcome: Result<UpdateHTTPResult, any Error>
        if let failure {
            outcome = .failure(failure)
        } else if cancelled {
            outcome = .failure(UpdateError.cancelled)
        } else if let error {
            outcome = .failure(UpdateTransferDelegate.map(error))
        } else if let response = task.response as? HTTPURLResponse {
            outcome = .success(UpdateHTTPResult(response: response, body: body, bytesWritten: written))
        } else {
            outcome = .failure(UpdateError.network("Keine gültige Antwort des Servers"))
        }
        lock.unlock()
        continuation?.resume(with: outcome)
    }

    /// Übersetzt Fehler von URLSession in ``UpdateError``.
    static func map(_ error: any Error) -> UpdateError {
        if let update = error as? UpdateError { return update }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .network("Keine Internetverbindung")
            case .timedOut:
                return .network("Zeitüberschreitung")
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return .network("Server nicht erreichbar")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                return .network("Keine sichere Verbindung möglich")
            case .httpTooManyRedirects, .redirectToNonExistentLocation:
                return .network("Zu viele oder ungültige Weiterleitungen")
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return .cancelled }
        return .network(error.localizedDescription)
    }
}

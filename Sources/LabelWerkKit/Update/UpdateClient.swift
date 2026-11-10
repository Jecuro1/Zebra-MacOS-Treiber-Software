import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Sucht und lädt LabelWerk-Updates aus den GitHub-Releases eines Repositorys.
///
/// **Ohne Token** (öffentliches Repository):
/// `GET https://github.com/<repo>/releases/latest/download/labelwerk-update.json` (mit
/// Weiterleitungen), danach das Paket von der Adresse aus den Update-Informationen.
///
/// **Mit Token** (privates Repository): `GET https://api.github.com/repos/<repo>/releases/latest`
/// (`Authorization: Bearer …`, `Accept: application/vnd.github+json`,
/// `X-GitHub-Api-Version: 2022-11-28`), dann beide Assets über ihre API-Adresse mit
/// `Accept: application/octet-stream`.
///
/// Der Token geht nur an `api.github.com`/`github.com`; Weiterleitungen auf andere Hosts (die
/// signierten Download-Adressen) erhalten ihn nie (``UpdateRedirectPolicy``). Geladene Pakete
/// werden erst nach Prüfung von Größe und SHA-256 an ihren Platz gelegt.
///
/// Die übergebene Session liefert nur die Konfiguration (Proxy, Zeitlimits, Protokollklassen);
/// für Weiterleitungsregeln, Fortschritt und Abbruch legt der Client je Anfrage eine eigene
/// Session mit eigenem Delegate an. Ohne Zwischenspeicher (immer der aktuelle Stand).
public actor UpdateClient {

    /// Größte zulässige Update-Information (1 MiB).
    static let manifestLimit = 1 << 20
    /// Größte zulässige Release-Beschreibung der REST-API (8 MiB).
    static let releaseLimit = 8 << 20

    /// Quelle der Updates.
    public nonisolated let source: UpdateSource
    private let configuration: URLSessionConfiguration

    public init(source: UpdateSource, session: URLSession = .shared) {
        self.source = source
        let configuration = (session.configuration.copy() as? URLSessionConfiguration) ?? session.configuration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration
    }

    // MARK: - Suchen

    /// Sucht nach einer neueren Version als `current`.
    /// - Returns: das Update oder `nil`, wenn `current` aktuell (oder neuer) ist.
    /// - Throws: ``UpdateError`` – u. a. ``UpdateError/notPublished`` (kein Release bzw. privates
    ///   Repository ohne Token), ``UpdateError/systemTooOld(required:)``, wenn das neuere Update
    ///   eine neuere macOS-Version voraussetzt.
    public func checkForUpdate(current: AppVersion,
                               systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion)
        async throws -> AvailableUpdate? {
        let latest = try await fetchLatest()
        guard latest.manifest.appVersion > current else { return nil }
        guard latest.manifest.isSupported(on: systemVersion) else {
            throw UpdateError.systemTooOld(required: latest.manifest.minimumSystemVersion)
        }
        return AvailableUpdate(manifest: latest.manifest, current: current, assetURL: latest.assetURL)
    }

    /// Update-Informationen des neuesten Releases (ohne Versionsvergleich).
    public func latestManifest() async throws -> UpdateManifest {
        try await fetchLatest().manifest
    }

    // MARK: - Laden

    /// Lädt das Paket von `update` nach `directory` (wird bei Bedarf angelegt).
    ///
    /// Die Datei entsteht zunächst als versteckte Teildatei im selben Ordner; erst wenn Größe und
    /// SHA-256 stimmen, wird sie atomar als `<directory>/<pkg.name>` abgelegt (eine vorhandene
    /// Datei gleichen Namens wird ersetzt). Liegt dort bereits eine geprüfte Datei, wird nicht
    /// erneut geladen.
    /// - Parameter progress: Fortschritt 0…1 (auf einem beliebigen Thread).
    /// - Returns: Adresse der geprüften Paketdatei.
    public func download(_ update: AvailableUpdate, to directory: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let manifest = update.manifest
        try manifest.validate()
        let pkg = manifest.pkg
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.installFailed("Der Ordner „\(directory.path)“ kann nicht angelegt werden")
        }
        let destination = directory.appendingPathComponent(pkg.name, isDirectory: false)
        if (try? UpdateClient.verifyPackage(at: destination, matches: pkg)) != nil {
            progress(1)
            return destination
        }

        let request: URLRequest
        if let assetURL = update.assetURL {
            guard let token = source.effectiveToken else { throw UpdateError.unauthorized }
            request = try apiRequest(UpdateClient.validatedAssetURL(assetURL), token: token,
                                     accept: "application/octet-stream")
        } else {
            guard UpdateManifest.isAllowedPackageURL(pkg.url) else {
                throw UpdateError.invalidManifest("Paketadresse „\(pkg.url.absoluteString)“ ist nicht erlaubt")
            }
            request = makeRequest(pkg.url, accept: "application/octet-stream")
        }

        let partial = directory.appendingPathComponent(".\(pkg.name).\(UUID().uuidString).part", isDirectory: false)
        defer { try? fileManager.removeItem(at: partial) }
        progress(0)
        let result = try await perform(request, sink: .file(partial, expectedSize: pkg.size, progress: progress))
        guard result.bytesWritten == pkg.size else { throw UpdateError.sizeMismatch }
        try UpdateClient.verifyPackage(at: partial, matches: pkg)
        guard rename(partial.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            throw UpdateError.installFailed("Die Update-Datei konnte nicht abgelegt werden (\(reason))")
        }
        return destination
    }

    /// Prüft Größe und SHA-256 einer Paketdatei.
    /// - Throws: ``UpdateError/sizeMismatch``, ``UpdateError/checksumMismatch`` bzw.
    ///   ``UpdateError/installFailed(_:)``, wenn die Datei nicht lesbar ist.
    public static func verifyPackage(at url: URL, matches pkg: UpdateManifest.Package) throws {
        guard let size = fileSize(at: url) else {
            throw UpdateError.installFailed("Die Update-Datei „\(url.lastPathComponent)“ fehlt")
        }
        guard size == pkg.size else { throw UpdateError.sizeMismatch }
        let digest: String
        do {
            digest = try SHA256Hasher.hexDigest(ofFileAt: url)
        } catch {
            throw UpdateError.installFailed("Die Update-Datei „\(url.lastPathComponent)“ ist nicht lesbar")
        }
        guard digest == pkg.sha256.lowercased() else { throw UpdateError.checksumMismatch }
    }

    // MARK: - Intern: Release finden

    private func fetchLatest() async throws -> (manifest: UpdateManifest, assetURL: URL?) {
        guard source.isValid, let manifestURL = source.latestManifestURL, let apiURL = source.latestReleaseAPIURL else {
            throw UpdateError.invalidManifest(
                "Das Repository „\(source.repository)“ ist ungültig (erwartet „Besitzer/Name“)")
        }
        if let token = source.effectiveToken {
            return try await fetchLatest(apiURL: apiURL, token: token)
        }
        let result = try await perform(makeRequest(manifestURL, accept: "application/octet-stream, application/json"),
                                       sink: .memory(limit: UpdateClient.manifestLimit))
        return (try UpdateManifest.decode(result.body), nil)
    }

    /// Release über die REST-API (privates Repository).
    private func fetchLatest(apiURL: URL, token: String) async throws -> (manifest: UpdateManifest, assetURL: URL?) {
        let releaseResult = try await perform(apiRequest(apiURL, token: token, accept: "application/vnd.github+json"),
                                              sink: .memory(limit: UpdateClient.releaseLimit))
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: releaseResult.body)
        } catch {
            throw UpdateError.invalidManifest("Die Release-Beschreibung von GitHub ist unverständlich")
        }
        guard let manifestAsset = release.assets.first(where: { $0.name == UpdateManifest.assetName }) else {
            throw UpdateError.notPublished
        }
        let manifestResult = try await perform(
            apiRequest(UpdateClient.validatedAssetURL(manifestAsset.url), token: token, accept: "application/octet-stream"),
            sink: .memory(limit: UpdateClient.manifestLimit))
        let manifest = try UpdateManifest.decode(manifestResult.body)
        guard let pkgAsset = release.assets.first(where: { $0.name == manifest.pkg.name }) else {
            throw UpdateError.invalidManifest("Das Paket „\(manifest.pkg.name)“ fehlt im Release")
        }
        if let size = pkgAsset.size, size != manifest.pkg.size {
            throw UpdateError.invalidManifest("Die Größe des Pakets „\(manifest.pkg.name)“ passt nicht zu den Update-Informationen")
        }
        return (manifest, try UpdateClient.validatedAssetURL(pkgAsset.url))
    }

    /// Antwort von `GET /repos/{owner}/{repo}/releases/latest` (nur die benötigten Felder).
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var url: URL
            var size: Int?
        }
        var assets: [Asset]
    }

    /// API-Adresse eines Assets: nur `https://api.github.com/…` (dorthin geht der Token).
    static func validatedAssetURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.github.com",
              url.user == nil, url.password == nil else {
            throw UpdateError.invalidManifest("Unzulässige Asset-Adresse „\(url.absoluteString)“")
        }
        return url
    }

    // MARK: - Intern: HTTP

    private func makeRequest(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("\(LabelWerkKitInfo.productName)/\(LabelWerkKitInfo.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func apiRequest(_ url: URL, token: String, accept: String) -> URLRequest {
        var request = makeRequest(url, accept: accept)
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if UpdateRedirectPolicy.mayCarryToken(url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Führt `request` aus, folgt Weiterleitungen nach ``UpdateRedirectPolicy`` und wirft bei
    /// Statuscodes außerhalb 2xx.
    private func perform(_ request: URLRequest, sink: UpdateTransferDelegate.Sink) async throws -> UpdateHTTPResult {
        var current = request
        for _ in 0...UpdateRedirectPolicy.maximumRedirects {
            if Task.isCancelled { throw UpdateError.cancelled }
            let result = try await transfer(current, sink: sink)
            let status = result.response.statusCode
            if [301, 302, 303, 307, 308].contains(status) {
                guard let location = result.response.value(forHTTPHeaderField: "Location"),
                      let target = URL(string: location, relativeTo: result.response.url ?? current.url)?.absoluteURL,
                      let next = UpdateRedirectPolicy.redirect(from: current, to: target) else {
                    throw UpdateError.network("Der Server hat auf eine unzulässige Adresse weitergeleitet")
                }
                current = next
                continue
            }
            try UpdateClient.check(result)
            return result
        }
        throw UpdateError.network("Zu viele Weiterleitungen")
    }

    /// Eine einzelne Anfrage mit eigener Session (Delegate für Weiterleitung, Fortschritt, Abbruch).
    private func transfer(_ request: URLRequest, sink: UpdateTransferDelegate.Sink) async throws -> UpdateHTTPResult {
        let delegate = UpdateTransferDelegate(sink: sink)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    /// Ordnet HTTP-Statuscodes außerhalb 2xx einem ``UpdateError`` zu.
    static func check(_ result: UpdateHTTPResult) throws {
        let response = result.response
        let status = response.statusCode
        switch status {
        case 200..<300:
            return
        case 404, 410:
            throw UpdateError.notPublished
        case 401:
            throw UpdateError.unauthorized
        case 429:
            throw UpdateError.rateLimited
        case 403:
            let body = String(decoding: result.body.prefix(4096), as: UTF8.self).lowercased()
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil
                || body.contains("rate limit") {
                throw UpdateError.rateLimited
            }
            throw UpdateError.unauthorized
        default:
            throw UpdateError.network("Der Server meldet HTTP-Status \(status)")
        }
    }

    private static func fileSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        switch attributes[.size] {
        case let value as Int: return value
        case let value as UInt64: return Int(exactly: value)
        case let value as Int64: return Int(exactly: value)
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }
}

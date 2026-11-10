import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LabelWerkKit

// MARK: - HTTP-Attrappe (URLProtocol)

/// Antwort der HTTP-Attrappe.
struct UpdateStubReply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// Inhalt in Stücken dieser Größe ausliefern (Fortschritt).
    var chunkSize: Int?
    /// Nach dem ersten Stück so lange warten (Abbruch-Test).
    var pauseAfterFirstChunk: TimeInterval?

    static func ok(_ body: Data, chunkSize: Int? = nil) -> UpdateStubReply {
        UpdateStubReply(status: 200, headers: ["Content-Type": "application/octet-stream"], body: body, chunkSize: chunkSize)
    }

    static func json(_ text: String) -> UpdateStubReply {
        UpdateStubReply(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    static func redirect(_ location: String, status: Int = 302) -> UpdateStubReply {
        UpdateStubReply(status: status, headers: ["Location": location], body: Data("<html>moved</html>".utf8))
    }
}

/// Eine von der Attrappe empfangene Anfrage.
struct UpdateStubRequest: Sendable {
    var url: URL
    var headers: [String: String]

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Routen (exakte URL → Antwort) und Protokoll aller Anfragen. Jeder Test verwendet eigene,
/// eindeutige URLs (Kennung im Pfad) – die Tests können daher parallel laufen.
final class UpdateStub: @unchecked Sendable {
    static let shared = UpdateStub()

    private let lock = NSLock()
    private var routes: [String: UpdateStubReply] = [:]
    private var log: [UpdateStubRequest] = []

    func route(_ url: String, _ reply: UpdateStubReply) {
        lock.lock(); defer { lock.unlock() }
        routes[url] = reply
    }

    func reply(for request: URLRequest) -> UpdateStubReply {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url else { return UpdateStubReply(status: 400) }
        log.append(UpdateStubRequest(url: url, headers: request.allHTTPHeaderFields ?? [:]))
        return routes[url.absoluteString]
            ?? UpdateStubReply(status: 418, body: Data("keine Route für \(url.absoluteString)".utf8))
    }

    func requests(containing marker: String) -> [UpdateStubRequest] {
        lock.lock(); defer { lock.unlock() }
        return log.filter { $0.url.absoluteString.contains(marker) }
    }
}

/// Überträgt nicht-sendbare Werte in verzögerte Blöcke der Attrappe.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// URLProtocol, das Antworten aus ``UpdateStub`` liefert. Weiterleitungen (3xx) werden als
/// gewöhnliche Antworten ausgeliefert; der Client folgt ihnen selbst.
final class UpdateStubProtocol: URLProtocol {
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = UpdateStub.shared.reply(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers.merging(["Content-Length": "\(reply.body.count)"]) { a, _ in a })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = max(1, reply.chunkSize ?? reply.body.count)
        var chunks: [Data] = []
        var offset = 0
        while offset < reply.body.count {
            chunks.append(reply.body.subdata(in: offset..<min(reply.body.count, offset + size)))
            offset += size
        }
        if let pause = reply.pauseAfterFirstChunk, let first = chunks.first {
            client?.urlProtocol(self, didLoad: first)
            let rest = Array(chunks.dropFirst())
            let box = UncheckedBox(value: self)
            DispatchQueue.global().asyncAfter(deadline: .now() + pause) {
                box.value.deliver(rest)
            }
            return
        }
        deliver(chunks)
    }

    private func deliver(_ chunks: [Data]) {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped else { return }
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

/// Sammelt Fortschrittswerte (aus beliebigen Threads).
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
}

/// Testumgebung mit eindeutigem Repository und eigener Attrappen-Session.
struct UpdateStubEnvironment {
    let id = "t" + UUID().uuidString.prefix(8).lowercased()
    let session: URLSession
    let directory: URL

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubProtocol.self]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-update-\(UUID().uuidString)", isDirectory: true)
    }

    var repo: String { "lwtest/repo-\(id)" }
    var manifestURL: String { "https://github.com/\(repo)/releases/latest/download/labelwerk-update.json" }
    var releaseAPIURL: String { "https://api.github.com/repos/\(repo)/releases/latest" }
    func assetURL(_ number: Int) -> String { "https://api.github.com/repos/\(repo)/releases/assets/\(number)" }
    func downloadURL(tag: String, name: String) -> String { "https://github.com/\(repo)/releases/download/\(tag)/\(name)" }
    func cdnURL(_ name: String, host: String = "objects.githubusercontent.com") -> String {
        "https://\(host)/\(id)/\(name)?X-Amz-Signature=abc123&X-Amz-Expires=300"
    }

    func client(token: String? = nil) -> UpdateClient {
        UpdateClient(source: UpdateSource(repository: repo, token: token), session: session)
    }

    func route(_ url: String, _ reply: UpdateStubReply) {
        UpdateStub.shared.route(url, reply)
    }

    var requests: [UpdateStubRequest] { UpdateStub.shared.requests(containing: id) }

    func filesInDirectory() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Paketinhalt (deterministisch).
    static func payload(count: Int = 200_000) -> Data {
        var data = Data(count: count)
        for index in data.indices { data[index] = UInt8(truncatingIfNeeded: (index &* 131) ^ (index >> 9)) }
        return data
    }

    /// Update-Informationen im CI-Format.
    func manifestJSON(version: String = "1.1.0", build: Int = 58, payload: Data,
                      pkgURL: String? = nil, minimumSystemVersion: String = "14.0") -> String {
        let tag = "v\(version)-b\(build)"
        let name = "LabelWerk-\(version)-\(build).pkg"
        let url = pkgURL ?? downloadURL(tag: tag, name: name)
        return """
        {"schema":1,"version":"\(version)","build":\(build),"tag":"\(tag)",\
        "pkg":{"name":"\(name)","url":"\(url)","size":\(payload.count),"sha256":"\(SHA256Hasher.hexDigest(payload))"},\
        "minimumSystemVersion":"\(minimumSystemVersion)","publishedAt":"2026-11-10T12:00:00Z",\
        "notes":"## Änderungen\\n\\n- Update-Dienst"}
        """
    }

    /// Öffentlicher Weg: latest/download → download/<tag> → CDN.
    func routePublicManifest(_ json: String, tag: String = "v1.1.0-b58") {
        route(manifestURL, .redirect(downloadURL(tag: tag, name: "labelwerk-update.json")))
        route(downloadURL(tag: tag, name: "labelwerk-update.json"), .redirect(cdnURL("manifest")))
        route(cdnURL("manifest"), .json(json))
    }

    /// Release-Beschreibung der REST-API.
    func releaseJSON(manifestAssetURL: String? = nil, pkgName: String = "LabelWerk-1.1.0-58.pkg",
                     pkgSize: Int, includeManifest: Bool = true, includePkg: Bool = true) -> String {
        var assets: [String] = []
        if includeManifest {
            assets.append("""
            {"id":1,"name":"labelwerk-update.json","url":"\(manifestAssetURL ?? assetURL(1))",\
            "browser_download_url":"\(downloadURL(tag: "v1.1.0-b58", name: "labelwerk-update.json"))","size":512}
            """)
        }
        if includePkg {
            assets.append("""
            {"id":2,"name":"\(pkgName)","url":"\(assetURL(2))",\
            "browser_download_url":"\(downloadURL(tag: "v1.1.0-b58", name: pkgName))","size":\(pkgSize)}
            """)
        }
        return "{\"tag_name\":\"v1.1.0-b58\",\"name\":\"LabelWerk 1.1.0 (Build 58)\",\"assets\":[\(assets.joined(separator: ","))]}"
    }
}

// MARK: - Tests

/// UpdateClient gegen eine HTTP-Attrappe: öffentlicher Weg, REST-API mit Token, Weiterleitungen,
/// Fehlercodes, Prüfung und Ablage geladener Pakete, Abbruch.
@Suite("Update-Dienst: UpdateClient")
struct UpdateClientTests {

    static let old = AppVersion(version: "1.0.0", build: 12)
    static let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    // MARK: Öffentliches Repository

    @Test("Öffentlich: Update finden (mit Weiterleitungen), laden, prüfen, ablegen")
    func publicFlow() async throws {
        let env = try UpdateStubEnvironment()
        defer { env.cleanUp() }
        let payload = UpdateStubEnvironment.payload()
        env.routePublicManifest(env.manifestJSON(payload: payload))
        let client = env.client()

        let update = try #require(try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma))
        #expect(update.version == AppVersion(version: "1.1.0", build: 58))
        #expect(update.current == Self.old)
        #expect(update.id == "v1.1.0-b58")
        #expect(update.assetURL == nil)
        #expect(update.manifest.notes.hasPrefix("## Änderungen"))
        let checks = env.requests
        #expect(checks.map(\.url.absoluteString) == [env.manifestURL,
                                                     env.downloadURL(tag: "v1.1.0-b58", name: "labelwerk-update.json"),
                                                     env.cdnURL("manifest")])
        #expect(checks.allSatisfy { $0.header("Authorization") == nil })
        #expect(checks.first?.header("User-Agent") == "LabelWerk/\(LabelWerkKitInfo.version)")

        // Paket: relative Weiterleitung auf github.com, dann CDN, in Stücken.
        let pkgURL = env.downloadURL(tag: "v1.1.0-b58", name: "LabelWerk-1.1.0-58.pkg")
        env.route(pkgURL, .redirect("/\(env.repo)/cdn-redirect/LabelWerk-1.1.0-58.pkg"))
        env.route("https://github.com/\(env.repo)/cdn-redirect/LabelWerk-1.1.0-58.pkg", .redirect(env.cdnURL("pkg")))
        env.route(env.cdnURL("pkg"), .ok(payload, chunkSize: 16_384))
        let progress = ProgressLog()
        let file = try await client.download(update, to: env.directory) { progress.record($0) }
        #expect(file == env.directory.appendingPathComponent("LabelWerk-1.1.0-58.pkg"))
        #expect(try Data(contentsOf: file) == payload)
        #expect(env.filesInDirectory() == ["LabelWerk-1.1.0-58.pkg"])      // keine Teildateien
        let values = progress.values
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.count >= 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(env.requests.allSatisfy { $0.header("Authorization") == nil })

        // Bereits geladen und geprüft → keine weitere Anfrage.
        let before = env.requests.count
        let again = ProgressLog()
        #expect(try await client.download(update, to: env.directory) { again.record($0) } == file)
        #expect(env.requests.count == before)
        #expect(again.values == [1])
    }

    @Test("Versionsvergleich: gleich oder neuer → kein Update, höherer Build → Update")
    func versionComparison() async throws {
        let env = try UpdateStubEnvironment()
        env.routePublicManifest(env.manifestJSON(payload: Data("x".utf8)))
        let client = env.client()
        #expect(try await client.checkForUpdate(current: AppVersion(version: "1.1.0", build: 58), systemVersion: Self.sonoma) == nil)
        #expect(try await client.checkForUpdate(current: AppVersion(version: "1.1", build: 58), systemVersion: Self.sonoma) == nil)
        #expect(try await client.checkForUpdate(current: AppVersion(version: "1.2.0", build: 1), systemVersion: Self.sonoma) == nil)
        let newer = try await client.checkForUpdate(current: AppVersion(version: "1.1.0", build: 57), systemVersion: Self.sonoma)
        #expect(newer?.version.build == 58)
        #expect(try await client.latestManifest().tag == "v1.1.0-b58")
    }

    @Test("Zu altes macOS: Fehler nur, wenn das Update neuer ist")
    func systemTooOld() async throws {
        let env = try UpdateStubEnvironment()
        env.routePublicManifest(env.manifestJSON(payload: Data("x".utf8), minimumSystemVersion: "15.2"))
        let client = env.client()
        await #expect(throws: UpdateError.systemTooOld(required: "15.2")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        #expect(try await client.checkForUpdate(current: AppVersion(version: "2.0", build: 1), systemVersion: Self.sonoma) == nil)
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
        #expect(try await client.checkForUpdate(current: Self.old, systemVersion: sequoia) != nil)
    }

    @Test("HTTP-Fehler werden zugeordnet", arguments: [
        (UpdateStubReply(status: 404, body: Data("Not Found".utf8)), UpdateError.notPublished),
        (UpdateStubReply(status: 410), UpdateError.notPublished),
        (UpdateStubReply(status: 401), UpdateError.unauthorized),
        (UpdateStubReply(status: 403, body: Data("{\"message\":\"Resource not accessible\"}".utf8)), UpdateError.unauthorized),
        (UpdateStubReply(status: 403, headers: ["X-RateLimit-Remaining": "0"]), UpdateError.rateLimited),
        (UpdateStubReply(status: 403, body: Data("{\"message\":\"API rate limit exceeded\"}".utf8)), UpdateError.rateLimited),
        (UpdateStubReply(status: 429, headers: ["Retry-After": "60"]), UpdateError.rateLimited),
        (UpdateStubReply(status: 500), UpdateError.network("Der Server meldet HTTP-Status 500")),
    ])
    func statusCodes(reply: UpdateStubReply, expected: UpdateError) async throws {
        for token in [nil, "github_pat_TEST"] as [String?] {
            let env = try UpdateStubEnvironment()
            env.route(env.manifestURL, reply)
            env.route(env.releaseAPIURL, reply)
            await #expect(throws: expected) {
                try await env.client(token: token).checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
            }
            #expect(env.requests.count == 1)
        }
    }

    @Test("Ungültige Update-Informationen werden abgelehnt")
    func invalidManifest() async throws {
        let env = try UpdateStubEnvironment()
        let client = env.client()
        let payload = Data("x".utf8)

        env.routePublicManifest(env.manifestJSON(payload: payload, pkgURL: "https://evil.example.com/\(env.id)/LabelWerk.pkg"))
        await #expect(throws: UpdateError.invalidManifest(
            "Paketadresse „https://evil.example.com/\(env.id)/LabelWerk.pkg“ ist nicht erlaubt (nur HTTPS auf GitHub)")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        env.routePublicManifest(env.manifestJSON(payload: payload, pkgURL: "http://github.com/\(env.repo)/x.pkg"))
        await #expect(throws: UpdateError.self) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        env.routePublicManifest("<!DOCTYPE html><html>Sign in</html>")
        await #expect(throws: UpdateError.invalidManifest("JSON nicht lesbar")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        env.routePublicManifest(String(repeating: " ", count: (1 << 20) + 1))
        await #expect(throws: UpdateError.invalidManifest("Die Antwort des Servers ist zu groß")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        #expect(!env.requests.contains { $0.url.host == "evil.example.com" })
    }

    @Test("Ungültiges Repository: Fehler ohne Netzwerkzugriff")
    func invalidRepository() async throws {
        let env = try UpdateStubEnvironment()
        let client = UpdateClient(source: UpdateSource(repository: "kein-repo-\(env.id)"), session: env.session)
        await #expect(throws: UpdateError.invalidManifest(
            "Das Repository „kein-repo-\(env.id)“ ist ungültig (erwartet „Besitzer/Name“)")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        #expect(env.requests.isEmpty)
    }

    @Test("Weiterleitungen: kein HTTP, nicht endlos, nur mit Ziel")
    func redirectLimits() async throws {
        let env = try UpdateStubEnvironment()
        let client = env.client()
        env.route(env.manifestURL, .redirect("http://github.com/\(env.repo)/unsicher.json"))
        await #expect(throws: UpdateError.network("Der Server hat auf eine unzulässige Adresse weitergeleitet")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        #expect(!env.requests.contains { $0.url.scheme == "http" })

        let loop = "https://github.com/\(env.repo)/schleife"
        env.route(env.manifestURL, .redirect(loop))
        env.route(loop, .redirect(loop, status: 307))
        await #expect(throws: UpdateError.network("Zu viele Weiterleitungen")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }

        env.route(env.manifestURL, UpdateStubReply(status: 302))
        await #expect(throws: UpdateError.network("Der Server hat auf eine unzulässige Adresse weitergeleitet")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
    }

    // MARK: Privates Repository (REST-API mit Token)

    @Test("Mit Token: REST-API, Asset-Downloads, Token nie an fremde Hosts")
    func tokenFlow() async throws {
        let env = try UpdateStubEnvironment()
        defer { env.cleanUp() }
        let payload = UpdateStubEnvironment.payload(count: 150_001)
        let token = "github_pat_TEST_\(env.id)"
        // Umbenanntes Repository: API leitet innerhalb von api.github.com weiter (Token bleibt).
        let movedAPI = "https://api.github.com/repositories/\(env.id)/releases/latest"
        env.route(env.releaseAPIURL, .redirect(movedAPI, status: 301))
        env.route(movedAPI, .json(env.releaseJSON(pkgSize: payload.count)))
        env.route(env.assetURL(1), .redirect(env.cdnURL("manifest")))
        env.route(env.cdnURL("manifest"), .json(env.manifestJSON(payload: payload)))
        env.route(env.assetURL(2), .redirect(env.cdnURL("pkg", host: "release-assets.githubusercontent.com")))
        env.route(env.cdnURL("pkg", host: "release-assets.githubusercontent.com"), .ok(payload, chunkSize: 10_000))

        let client = env.client(token: "  \(token)\n")
        let update = try #require(try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma))
        #expect(update.assetURL?.absoluteString == env.assetURL(2))
        #expect(update.downloadURL.absoluteString == env.assetURL(2))
        #expect(update.version == AppVersion(version: "1.1.0", build: 58))

        let progress = ProgressLog()
        let file = try await client.download(update, to: env.directory) { progress.record($0) }
        #expect(try Data(contentsOf: file) == payload)
        #expect(progress.values.last == 1)

        let requests = env.requests
        #expect(requests.map(\.url.absoluteString) == [
            env.releaseAPIURL, movedAPI, env.assetURL(1), env.cdnURL("manifest"),
            env.assetURL(2), env.cdnURL("pkg", host: "release-assets.githubusercontent.com"),
        ])
        for request in requests {
            let host = request.url.host ?? ""
            if host == "api.github.com" {
                #expect(request.header("Authorization") == "Bearer \(token)", "\(request.url)")
                #expect(request.header("X-GitHub-Api-Version") == "2022-11-28")
            } else {
                #expect(request.header("Authorization") == nil, "Token an \(host) gesendet")
            }
        }
        #expect(requests[0].header("Accept") == "application/vnd.github+json")
        #expect(requests[1].header("Accept") == "application/vnd.github+json")
        #expect(requests[2].header("Accept") == "application/octet-stream")
        #expect(requests[4].header("Accept") == "application/octet-stream")
        // Die öffentlichen Adressen werden mit Token nicht verwendet.
        #expect(!requests.contains { $0.url.absoluteString == env.manifestURL })
    }

    @Test("Mit Token: fehlende oder fremde Assets")
    func tokenFlowErrors() async throws {
        let env = try UpdateStubEnvironment()
        let payload = Data("paket".utf8)
        let client = env.client(token: "github_pat_TEST")
        env.route(env.assetURL(1), .json(env.manifestJSON(payload: payload)))

        env.route(env.releaseAPIURL, .json(env.releaseJSON(pkgSize: payload.count, includeManifest: false)))
        await #expect(throws: UpdateError.notPublished) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }

        env.route(env.releaseAPIURL, .json(env.releaseJSON(pkgSize: payload.count, includePkg: false)))
        await #expect(throws: UpdateError.invalidManifest("Das Paket „LabelWerk-1.1.0-58.pkg“ fehlt im Release")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }

        env.route(env.releaseAPIURL, .json(env.releaseJSON(pkgSize: payload.count + 1)))
        await #expect(throws: UpdateError.self) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }

        let evil = "https://evil.example.com/\(env.id)/assets/1"
        env.route(env.releaseAPIURL, .json(env.releaseJSON(manifestAssetURL: evil, pkgSize: payload.count)))
        await #expect(throws: UpdateError.invalidManifest("Unzulässige Asset-Adresse „\(evil)“")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        #expect(!env.requests.contains { $0.url.host == "evil.example.com" })

        env.route(env.releaseAPIURL, .json("{\"message\":\"oops\"}"))
        await #expect(throws: UpdateError.invalidManifest("Die Release-Beschreibung von GitHub ist unverständlich")) {
            try await client.checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }

        // Asset-Adresse ohne Token → Zugriff verweigert, ohne Anfrage.
        let manifest = try UpdateManifest.decode(Data(env.manifestJSON(payload: payload).utf8))
        let update = AvailableUpdate(manifest: manifest, current: Self.old, assetURL: URL(string: env.assetURL(2)))
        let count = env.requests.count
        await #expect(throws: UpdateError.unauthorized) {
            try await env.client().download(update, to: env.directory) { _ in }
        }
        #expect(env.requests.count == count)
        env.cleanUp()
    }

    // MARK: Prüfung der Pakete

    @Test("Falsche Prüfsumme oder Größe: Fehler, keine Datei bleibt liegen")
    func downloadVerification() async throws {
        let env = try UpdateStubEnvironment()
        defer { env.cleanUp() }
        let payload = UpdateStubEnvironment.payload(count: 50_000)
        let manifest = try UpdateManifest.decode(Data(env.manifestJSON(payload: payload).utf8))
        let update = AvailableUpdate(manifest: manifest, current: Self.old)
        let pkgURL = manifest.pkg.url.absoluteString
        let client = env.client()

        var corrupted = payload
        corrupted[123] ^= 0xFF
        env.route(pkgURL, .ok(corrupted, chunkSize: 8192))
        await #expect(throws: UpdateError.checksumMismatch) {
            try await client.download(update, to: env.directory) { _ in }
        }
        #expect(env.filesInDirectory().isEmpty)

        env.route(pkgURL, .ok(payload.prefix(49_999), chunkSize: 8192))
        await #expect(throws: UpdateError.sizeMismatch) {
            try await client.download(update, to: env.directory) { _ in }
        }
        #expect(env.filesInDirectory().isEmpty)

        env.route(pkgURL, .ok(payload + Data(repeating: 0, count: 10_000), chunkSize: 8192))
        await #expect(throws: UpdateError.sizeMismatch) {
            try await client.download(update, to: env.directory) { _ in }
        }
        #expect(env.filesInDirectory().isEmpty)

        env.route(pkgURL, UpdateStubReply(status: 404))
        await #expect(throws: UpdateError.notPublished) {
            try await client.download(update, to: env.directory) { _ in }
        }
        #expect(env.filesInDirectory().isEmpty)

        // Eine beschädigte Datei am Ziel wird ersetzt.
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        let destination = env.directory.appendingPathComponent(manifest.pkg.name)
        try Data("alt und kaputt".utf8).write(to: destination)
        env.route(pkgURL, .ok(payload))
        #expect(try await client.download(update, to: env.directory) { _ in } == destination)
        #expect(try Data(contentsOf: destination) == payload)
        #expect(env.filesInDirectory() == [manifest.pkg.name])

        #expect(throws: Never.self) { try UpdateClient.verifyPackage(at: destination, matches: manifest.pkg) }
        var wrongSize = manifest.pkg
        wrongSize.size += 1
        #expect(throws: UpdateError.sizeMismatch) { try UpdateClient.verifyPackage(at: destination, matches: wrongSize) }
        var wrongHash = manifest.pkg
        wrongHash.sha256 = String(repeating: "0", count: 64)
        #expect(throws: UpdateError.checksumMismatch) { try UpdateClient.verifyPackage(at: destination, matches: wrongHash) }
        #expect(throws: UpdateError.self) {
            try UpdateClient.verifyPackage(at: env.directory.appendingPathComponent("fehlt.pkg"), matches: manifest.pkg)
        }
    }

    @Test("Abbruch während des Ladens")
    func cancellation() async throws {
        let env = try UpdateStubEnvironment()
        defer { env.cleanUp() }
        let payload = UpdateStubEnvironment.payload(count: 100_000)
        let manifest = try UpdateManifest.decode(Data(env.manifestJSON(payload: payload).utf8))
        let update = AvailableUpdate(manifest: manifest, current: Self.old)
        var reply = UpdateStubReply.ok(payload, chunkSize: 10_000)
        reply.pauseAfterFirstChunk = 5
        env.route(manifest.pkg.url.absoluteString, reply)
        let client = env.client()
        let progress = ProgressLog()
        let directory = env.directory
        let task = Task {
            try await client.download(update, to: directory) { progress.record($0) }
        }
        // Warten, bis die Anfrage bei der Attrappe angekommen ist (erstes Stück unterwegs).
        let deadline = Date().addingTimeInterval(10)
        while env.requests.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(env.requests.count == 1)
        let started = Date()
        task.cancel()
        await #expect(throws: UpdateError.cancelled) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(env.filesInDirectory().isEmpty)

        // Bereits abgebrochener Task: gar keine Anfrage.
        let other = try UpdateStubEnvironment()
        other.routePublicManifest(other.manifestJSON(payload: payload))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await other.client().checkForUpdate(current: Self.old, systemVersion: Self.sonoma)
        }
        await #expect(throws: UpdateError.cancelled) {
            try await cancelled.value
        }
        #expect(other.requests.isEmpty)
    }

    // MARK: Weiterleitungsregeln

    @Test("Weiterleitungsregel: Token nur für api.github.com und github.com, nur HTTPS")
    func redirectPolicy() throws {
        var original = URLRequest(url: URL(string: "https://api.github.com/repos/a/b/releases/assets/2")!)
        original.setValue("Bearer geheim", forHTTPHeaderField: "Authorization")
        original.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        for host in ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "evil.example.com",
                     "github.com.evil.example", "api.github.com.evil.example"] {
            let next = try #require(UpdateRedirectPolicy.redirect(from: original, to: URL(string: "https://\(host)/x?sig=1")!))
            #expect(next.value(forHTTPHeaderField: "Authorization") == nil, "\(host)")
            #expect(next.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
            #expect(next.url?.host == host)
        }
        for host in ["api.github.com", "github.com", "API.GitHub.com"] {
            let next = try #require(UpdateRedirectPolicy.redirect(from: original, to: URL(string: "https://\(host)/x")!))
            #expect(next.value(forHTTPHeaderField: "Authorization") == "Bearer geheim", "\(host)")
        }
        #expect(UpdateRedirectPolicy.redirect(from: original, to: URL(string: "http://api.github.com/x")!) == nil)
        #expect(UpdateRedirectPolicy.redirect(from: original, to: URL(string: "file:///etc/passwd")!) == nil)

        // Von URLSession vorgeschlagene Anfrage, die den Token schon übernommen hat.
        var proposed = URLRequest(url: URL(string: "https://objects.githubusercontent.com/y")!)
        proposed.setValue("Bearer geheim", forHTTPHeaderField: "Authorization")
        let sanitized = try #require(UpdateRedirectPolicy.redirect(from: original, to: proposed))
        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Session-Delegate (willPerformHTTPRedirection) entfernt den Token")
    func delegateRedirect() async throws {
        let delegate = UpdateTransferDelegate(sink: .memory(limit: 1024))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/a/b/releases/assets/2")!)
        request.setValue("Bearer geheim", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request)
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Location": "https://objects.githubusercontent.com/z"]))
        var proposed = URLRequest(url: URL(string: "https://objects.githubusercontent.com/z")!)
        proposed.setValue("Bearer geheim", forHTTPHeaderField: "Authorization")

        let forwarded = UncheckedBox(value: ResultBox())
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { next in
            forwarded.value.set(next)
        }
        let result = try #require(forwarded.value.get())
        #expect(result.url?.host == "objects.githubusercontent.com")
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)

        let insecure = URLRequest(url: URL(string: "http://objects.githubusercontent.com/z")!)
        let refused = UncheckedBox(value: ResultBox())
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: insecure) { next in
            refused.value.set(next)
        }
        #expect(refused.value.wasCalled && refused.value.get() == nil)
        task.cancel()
    }

    final class ResultBox {
        private(set) var wasCalled = false
        private var request: URLRequest?
        func set(_ request: URLRequest?) { wasCalled = true; self.request = request }
        func get() -> URLRequest? { request }
    }

    #if !canImport(FoundationNetworking)
    /// Nur Apple-Plattformen: Dort meldet das URLProtocol die Weiterleitung an URLSession, die den
    /// Delegate fragt. Der Token darf auch auf diesem Weg nicht beim CDN ankommen.
    @Test("macOS: Weiterleitung über URLSession erreicht das CDN ohne Token", .timeLimit(.minutes(1)))
    func systemRedirectStripsToken() async throws {
        let env = try UpdateStubEnvironment()
        defer { env.cleanUp() }
        let payload = UpdateStubEnvironment.payload(count: 4096)
        let manifest = try UpdateManifest.decode(Data(env.manifestJSON(payload: payload).utf8))
        let update = AvailableUpdate(manifest: manifest, current: Self.old, assetURL: URL(string: env.assetURL(2)))
        UpdateRedirectingStubProtocol.redirects[env.assetURL(2)] = env.cdnURL("pkg")
        env.route(env.cdnURL("pkg"), .ok(payload))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateRedirectingStubProtocol.self, UpdateStubProtocol.self]
        let client = UpdateClient(source: UpdateSource(repository: env.repo, token: "github_pat_TEST"),
                                  session: URLSession(configuration: configuration))
        let file = try await client.download(update, to: env.directory) { _ in }
        #expect(try Data(contentsOf: file) == payload)
        let cdn = env.requests.filter { $0.url.host == "objects.githubusercontent.com" }
        #expect(cdn.count == 1)
        #expect(cdn.allSatisfy { $0.header("Authorization") == nil })
    }
    #endif
}

#if !canImport(FoundationNetworking)
/// Nur Apple-Plattformen: meldet Weiterleitungen über `wasRedirectedTo` an URLSession.
final class UpdateRedirectingStubProtocol: URLProtocol {
    nonisolated(unsafe) static var redirects: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        return redirects[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let target = Self.redirects[url.absoluteString].flatMap(URL.init(string:)),
              let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                             headerFields: ["Location": target.absoluteString]) else { return }
        _ = UpdateStub.shared.reply(for: request)       // protokollieren
        var next = request
        next.url = target
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
    }

    override func stopLoading() {}
}
#endif

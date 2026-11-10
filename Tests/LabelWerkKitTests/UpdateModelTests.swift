import Foundation
import Testing
@testable import LabelWerkKit

/// Versionen, Update-Informationen (`labelwerk-update.json`), Quelle und Zeitplan des Update-Dienstes.
@Suite("Update-Dienst: Versionen, Update-Informationen, Zeitplan")
struct UpdateModelTests {

    // MARK: - AppVersion

    @Test("Beschreibung „1.1.0 (Build 58)“ und Tag „v1.1.0-b58“")
    func versionDescription() {
        let version = AppVersion(version: "1.1.0", build: 58)
        #expect(version.description == "1.1.0 (Build 58)")
        #expect("\(version)" == "1.1.0 (Build 58)")
        #expect(version.tag == "v1.1.0-b58")
        #expect(AppVersion(tag: "v1.1.0-b58") == version)
        #expect(AppVersion(tag: "1.2-b7") == AppVersion(version: "1.2", build: 7))
        #expect(AppVersion(tag: "v1.1.0") == nil)
        #expect(AppVersion(tag: "v1.1.0-bx") == nil)
        #expect(AppVersion(tag: "v-b5") == nil)
    }

    @Test("Vergleich: numerisch je Bestandteil, dann Build-Nummer")
    func versionOrdering() {
        func v(_ text: String, _ build: Int) -> AppVersion { AppVersion(version: text, build: build) }
        #expect(v("1.1.0", 57) < v("1.1.0", 58))
        #expect(v("1.1.0", 999) < v("1.1.1", 1))
        #expect(v("1.9.3", 100) < v("1.10.0", 1))      // numerisch, nicht lexikalisch
        #expect(v("1.2", 5) < v("1.10", 1))
        #expect(v("2.0.0", 1) > v("1.99.99", 9999))
        #expect(v("1.1", 3) == v("1.1.0", 3))          // fehlende Bestandteile = 0
        #expect(v("1.1", 3).hashValue == v("1.1.0", 3).hashValue)
        #expect(!(v("1.1", 3) < v("1.1.0", 3)) && !(v("1.1.0", 3) < v("1.1", 3)))
        #expect(v("1.1.0", 3) != v("1.1.0", 4))
        #expect(v("1.1.0-beta", 3) == v("1.1.0", 3))   // Anhänge werden ignoriert
        #expect(v(" 1.1.0 ", 3).version == "1.1.0")
        let sorted = [v("1.10.0", 1), v("1.2.0", 9), v("1.2.0", 10), v("0.9", 1)].sorted()
        #expect(sorted.map(\.description) == ["0.9 (Build 1)", "1.2.0 (Build 9)", "1.2.0 (Build 10)", "1.10.0 (Build 1)"])
    }

    @Test("Version aus dem Info-Wörterbuch (CFBundleShortVersionString, CFBundleVersion)")
    func versionFromInfo() {
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "58"])
                == AppVersion(version: "1.1.0", build: 58))
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": 7])?.build == 7)
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "1.1.0"]) == nil)
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "58.1"]) == nil)
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "", "CFBundleVersion": "1"]) == nil)
        #expect(AppVersion(infoDictionary: [:]) == nil)
        // Test-Bundles haben keine App-Versionsangaben → nil statt Absturz.
        _ = AppVersion.current()
    }

    @Test("AppVersion ist Codable")
    func versionCodable() throws {
        let version = AppVersion(version: "1.1.0", build: 58)
        let data = try JSONEncoder().encode(version)
        #expect(try JSONDecoder().decode(AppVersion.self, from: data) == version)
    }

    // MARK: - UpdateManifest

    static let sampleSHA = String(repeating: "ab", count: 32)

    static func sampleJSON(repo: String = "Jecuro1/Zebra-MacOS-Treiber-Software", extra: String = "") -> String {
        """
        {"schema":1,"version":"1.1.0","build":58,"tag":"v1.1.0-b58",\
        "pkg":{"name":"LabelWerk-1.1.0-58.pkg",\
        "url":"https://github.com/\(repo)/releases/download/v1.1.0-b58/LabelWerk-1.1.0-58.pkg",\
        "size":123456,"sha256":"\(sampleSHA.uppercased())"},\
        "minimumSystemVersion":"14.0","publishedAt":"2026-11-10T12:34:56Z",\
        "notes":"## Änderungen\\n\\n- Update-Dienst\\n- Fehlerbehebungen"\(extra)}
        """
    }

    @Test("Manifest im CI-Format (Schema 1) lesen")
    func decodeSample() throws {
        let manifest = try UpdateManifest.decode(Data(Self.sampleJSON().utf8))
        #expect(manifest.schema == 1)
        #expect(manifest.appVersion == AppVersion(version: "1.1.0", build: 58))
        #expect(manifest.tag == "v1.1.0-b58")
        #expect(manifest.pkg.name == "LabelWerk-1.1.0-58.pkg")
        #expect(manifest.pkg.url.absoluteString
                == "https://github.com/Jecuro1/Zebra-MacOS-Treiber-Software/releases/download/v1.1.0-b58/LabelWerk-1.1.0-58.pkg")
        #expect(manifest.pkg.size == 123_456)
        #expect(manifest.pkg.sha256 == Self.sampleSHA)          // auf Kleinbuchstaben normalisiert
        #expect(manifest.minimumSystemVersion == "14.0")
        #expect(manifest.publishedAt == Date(timeIntervalSince1970: 1_794_314_096))
        #expect(manifest.notes.hasPrefix("## Änderungen\n\n- Update-Dienst"))
    }

    @Test("Manifest: Rundreise, Zeitpunkt mit Sekundenbruchteilen, fehlende optionale Felder, neuere Schemata")
    func manifestCodable() throws {
        let manifest = try UpdateManifest.decode(Data(Self.sampleJSON().utf8))
        let data = try manifest.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"publishedAt\":\"2026-11-10T12:34:56Z\""))
        #expect(text.contains("\"url\":\"https://github.com/Jecuro1/"))     // ohne maskierte Schrägstriche
        #expect(try UpdateManifest.decode(data) == manifest)
        // Bequemlichkeitseigenschaft appVersion lässt sich auch setzen.
        var changed = manifest
        changed.appVersion = AppVersion(version: "1.2.0", build: 60)
        #expect(changed.version == "1.2.0" && changed.build == 60)

        let fractional = Self.sampleJSON().replacingOccurrences(of: "12:34:56Z", with: "12:34:56.250Z")
        #expect(try UpdateManifest.decode(Data(fractional.utf8)).publishedAt.timeIntervalSince1970 == 1_794_314_096.25)

        let minimal = """
        {"schema":1,"version":"1.1.0","build":58,"tag":"v1.1.0-b58",\
        "pkg":{"name":"LabelWerk-1.1.0-58.pkg","url":"https://github.com/a/b/releases/download/v1.1.0-b58/LabelWerk-1.1.0-58.pkg",\
        "size":1,"sha256":"\(Self.sampleSHA)"},"publishedAt":"2026-11-10T12:34:56+01:00"}
        """
        let decoded = try UpdateManifest.decode(Data(minimal.utf8))
        #expect(decoded.minimumSystemVersion == "14.0")
        #expect(decoded.notes == "")
        #expect(decoded.publishedAt == Date(timeIntervalSince1970: 1_794_314_096 - 3600))

        let future = Self.sampleJSON(extra: ",\"delta\":{\"from\":57}").replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2")
        #expect(try UpdateManifest.decode(Data(future.utf8)).schema == 2)
    }

    @Test("Manifest: unzulässige Werte werden abgelehnt", arguments: [
        ("\"schema\":1", "\"schema\":0"),
        ("\"version\":\"1.1.0\"", "\"version\":\"1.x\""),
        ("\"build\":58", "\"build\":0"),
        ("\"tag\":\"v1.1.0-b58\"", "\"tag\":\"\""),
        ("https://github.com/", "http://github.com/"),
        ("https://github.com/", "https://evil.example.com/"),
        ("https://github.com/", "https://user:pw@github.com/"),
        ("\"name\":\"LabelWerk-1.1.0-58.pkg\"", "\"name\":\"../LabelWerk.pkg\""),
        ("\"name\":\"LabelWerk-1.1.0-58.pkg\"", "\"name\":\"LabelWerk.dmg\""),
        ("\"name\":\"LabelWerk-1.1.0-58.pkg\"", "\"name\":\".pkg\""),
        ("\"size\":123456", "\"size\":0"),
        ("\"size\":123456", "\"size\":-5"),
        ("\"minimumSystemVersion\":\"14.0\"", "\"minimumSystemVersion\":\"Sonoma\""),
        ("\"publishedAt\":\"2026-11-10T12:34:56Z\"", "\"publishedAt\":\"gestern\""),
        ("\"build\":58", "\"build\":\"58\""),
        ("\"tag\":\"v1.1.0-b58\",", ""),
    ])
    func manifestRejects(original: String, replacement: String) throws {
        let json = Self.sampleJSON().replacingOccurrences(of: original, with: replacement)
        #expect(json != Self.sampleJSON())
        #expect {
            try UpdateManifest.decode(Data(json.utf8))
        } throws: { error in
            guard case UpdateError.invalidManifest(let reason) = error else { return false }
            return !reason.isEmpty
        }
    }

    @Test("Manifest: falsche Prüfsummen und kaputtes JSON werden abgelehnt")
    func manifestRejectsChecksumAndJSON() {
        for sha in ["abc", String(repeating: "g", count: 64), String(repeating: "ａ", count: 64)] {
            let json = Self.sampleJSON().replacingOccurrences(of: Self.sampleSHA.uppercased(), with: sha)
            #expect(throws: UpdateError.invalidManifest("SHA-256-Prüfsumme „\(sha.lowercased())“ ist ungültig")) {
                try UpdateManifest.decode(Data(json.utf8))
            }
        }
        #expect(throws: UpdateError.invalidManifest("JSON nicht lesbar")) {
            try UpdateManifest.decode(Data("<html>Not Found</html>".utf8))
        }
        let missing = Self.sampleJSON().replacingOccurrences(of: "\"sha256\":\"\(Self.sampleSHA.uppercased())\"", with: "\"x\":1")
        #expect(throws: UpdateError.invalidManifest("Angabe „pkg.sha256“ fehlt")) {
            try UpdateManifest.decode(Data(missing.utf8))
        }
        #expect(UpdateManifest.isAllowedPackageURL(URL(string: "https://objects.githubusercontent.com/x")!))
        #expect(UpdateManifest.isAllowedPackageURL(URL(string: "https://API.GitHub.com/x")!))
        #expect(!UpdateManifest.isAllowedPackageURL(URL(string: "https://github.com.evil.example/x")!))
        #expect(!UpdateManifest.isAllowedPackageURL(URL(string: "ftp://github.com/x")!))
    }

    @Test("macOS-Mindestversion")
    func minimumSystem() throws {
        var manifest = try UpdateManifest.decode(Data(Self.sampleJSON().utf8))
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let sonoma6 = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)
        #expect(manifest.isSupported(on: sonoma) && manifest.isSupported(on: sequoia))
        manifest.minimumSystemVersion = "14.6.1"
        #expect(!manifest.isSupported(on: sonoma) && manifest.isSupported(on: sonoma6))
        manifest.minimumSystemVersion = "15"
        #expect(!manifest.isSupported(on: sonoma6) && manifest.isSupported(on: sequoia))
        manifest.minimumSystemVersion = "26.0"
        #expect(!manifest.isSupported(on: sequoia))
    }

    // MARK: - UpdateSource & AvailableUpdate

    @Test("Repository-Angabe und Adressen")
    func source() {
        let source = UpdateSource(repository: "Jecuro1/Zebra-MacOS-Treiber-Software")
        #expect(source.isValid)
        #expect(source.token == nil && source.effectiveToken == nil)
        #expect(source.latestManifestURL?.absoluteString
                == "https://github.com/Jecuro1/Zebra-MacOS-Treiber-Software/releases/latest/download/labelwerk-update.json")
        #expect(source.latestReleaseAPIURL?.absoluteString
                == "https://api.github.com/repos/Jecuro1/Zebra-MacOS-Treiber-Software/releases/latest")
        #expect(source.releasesPageURL?.absoluteString == "https://github.com/Jecuro1/Zebra-MacOS-Treiber-Software/releases")
        #expect(UpdateSource(repository: "a/b", token: "  \n").effectiveToken == nil)
        #expect(UpdateSource(repository: "a/b", token: " github_pat_x\n").effectiveToken == "github_pat_x")
        for invalid in ["", "abc", "a/b/c", "/b", "a/", "a b/c", "a/../b", "a/..", "a/.", "a?/b", "ä/b", "a/b#x"] {
            #expect(!UpdateSource.isValidRepository(invalid), "\(invalid)")
            #expect(UpdateSource(repository: invalid).latestManifestURL == nil)
        }
        for valid in ["a/b", "owner-1/repo.name_2", "Jecuro1/Zebra-MacOS-Treiber-Software"] {
            #expect(UpdateSource.isValidRepository(valid), "\(valid)")
        }
        #expect(UpdateSource.infoPlistKey == "LWUpdateRepository")
        // Test-Bundles haben keinen LWUpdateRepository-Eintrag.
        #expect(UpdateSource.configuredRepository() == nil)
    }

    @Test("AvailableUpdate: Kennung, Version, Download-Adresse, Codable")
    func availableUpdate() throws {
        let manifest = try UpdateManifest.decode(Data(Self.sampleJSON().utf8))
        let current = AppVersion(version: "1.0.0", build: 12)
        let update = AvailableUpdate(manifest: manifest, current: current)
        #expect(update.id == "v1.1.0-b58")
        #expect(update.version == AppVersion(version: "1.1.0", build: 58))
        #expect(update.downloadURL == manifest.pkg.url)
        let asset = URL(string: "https://api.github.com/repos/a/b/releases/assets/9")!
        let viaAPI = AvailableUpdate(manifest: manifest, current: current, assetURL: asset)
        #expect(viaAPI.downloadURL == asset)
        let data = try JSONEncoder().encode(viaAPI)
        #expect(try JSONDecoder().decode(AvailableUpdate.self, from: data) == viaAPI)
    }

    // MARK: - UpdateError

    @Test("Fehlermeldungen sind deutsch und erklären den 404-Fall")
    func errorTexts() {
        let notPublished = UpdateError.notPublished.localizedDescription
        #expect(notPublished.contains("noch keine") && notPublished.contains("privat") && notPublished.contains("Zugriffstoken"))
        #expect(UpdateError.systemTooOld(required: "15.0").errorDescription == "Dieses Update benötigt macOS 15.0 oder neuer.")
        #expect(UpdateError.network("Zeitüberschreitung").errorDescription
                == "Der Update-Server ist nicht erreichbar: Zeitüberschreitung")
        #expect(UpdateError.installFailed(" ").errorDescription == "Das Update konnte nicht installiert werden.")
        let all: [UpdateError] = [.notPublished, .unauthorized, .rateLimited, .network("x"), .invalidManifest("y"),
                                  .checksumMismatch, .sizeMismatch, .systemTooOld(required: "15.0"),
                                  .installFailed("z"), .cancelled]
        for error in all {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
        #expect(Set(all.compactMap(\.errorDescription)).count == all.count)
    }

    // MARK: - UpdateSchedule

    @Test("Zeitplan: alle 6 Stunden, erste Suche nach 10 s")
    func schedule() {
        let schedule = UpdateSchedule()
        #expect(schedule.checkInterval == 6 * 3600)
        #expect(schedule.launchDelay == 10)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(schedule.isDue(lastCheck: nil, now: now))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-(6 * 3600 - 1)), now: now))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-6 * 3600), now: now))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(30), now: now))          // kleine Uhrabweichung
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))         // Uhr zurückgestellt
        #expect(schedule.nextCheck(lastCheck: nil, now: now) == now)
        #expect(schedule.nextCheck(lastCheck: now.addingTimeInterval(-3600), now: now) == now.addingTimeInterval(5 * 3600))
        #expect(schedule.delayUntilNextCheck(lastCheck: now.addingTimeInterval(-3600), now: now) == 5 * 3600)
        #expect(schedule.delayUntilNextCheck(lastCheck: now.addingTimeInterval(-7 * 3600), now: now) == 0)
        let custom = UpdateSchedule(checkInterval: 3600, launchDelay: -1)
        #expect(custom.checkInterval == 3600 && custom.launchDelay == 0)
        #expect(custom.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateSchedule(checkInterval: 1).checkInterval == 60)
    }
}

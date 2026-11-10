import Foundation

/// Update-Informationen eines Releases (`labelwerk-update.json`, Schema 1), von der CI zu jedem
/// Release hochgeladen:
///
/// ```json
/// {"schema":1,"version":"1.1.0","build":58,"tag":"v1.1.0-b58",
///  "pkg":{"name":"LabelWerk-1.1.0-58.pkg",
///         "url":"https://github.com/<repo>/releases/download/v1.1.0-b58/LabelWerk-1.1.0-58.pkg",
///         "size":12345678,"sha256":"<64 Hexziffern>"},
///  "minimumSystemVersion":"14.0","publishedAt":"2026-11-10T12:00:00Z","notes":"## Änderungen\n…"}
/// ```
///
/// Neuere Schema-Versionen dürfen nur Felder ergänzen; ältere Apps lesen sie weiter. Fehlen
/// `minimumSystemVersion` oder `notes`, gelten „14.0“ bzw. ein leerer Text.
public struct UpdateManifest: Codable, Sendable, Equatable {

    /// Schema-Version, die diese Implementierung schreibt.
    public static let currentSchema = 1
    /// Dateiname der Update-Informationen im Release.
    public static let assetName = "labelwerk-update.json"
    /// Hosts, von denen ein Update-Paket geladen werden darf (nur HTTPS).
    public static let allowedPackageHosts: Set<String> = [
        "github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    /// Größte zulässige Paketgröße (4 GiB).
    public static let maximumPackageSize = 4 << 30

    /// Das Installationspaket des Releases.
    public struct Package: Codable, Sendable, Equatable {
        /// Dateiname, z. B. „LabelWerk-1.1.0-58.pkg“.
        public var name: String
        /// Download-Adresse (Release-Asset auf GitHub).
        public var url: URL
        /// Größe in Bytes.
        public var size: Int
        /// SHA-256 der Datei (64 Hexziffern, klein).
        public var sha256: String

        public init(name: String, url: URL, size: Int, sha256: String) {
            self.name = name
            self.url = url
            self.size = size
            self.sha256 = sha256.lowercased()
        }

        private enum CodingKeys: String, CodingKey { case name, url, size, sha256 }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            let urlText = try container.decode(String.self, forKey: .url)
            guard let url = URL(string: urlText) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: container,
                                                       debugDescription: "Ungültige Adresse „\(urlText)“")
            }
            self.url = url
            size = try container.decode(Int.self, forKey: .size)
            sha256 = try container.decode(String.self, forKey: .sha256).lowercased()
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(url.absoluteString, forKey: .url)
            try container.encode(size, forKey: .size)
            try container.encode(sha256, forKey: .sha256)
        }
    }

    public var schema: Int
    /// Marketing-Version, z. B. „1.1.0“.
    public var version: String
    /// Build-Nummer, z. B. 58.
    public var build: Int
    /// Release-Tag, z. B. „v1.1.0-b58“.
    public var tag: String
    /// Das Installationspaket.
    public var pkg: Package
    /// Kleinste unterstützte macOS-Version, z. B. „14.0“.
    public var minimumSystemVersion: String
    /// Veröffentlichungszeitpunkt.
    public var publishedAt: Date
    /// Änderungen (Markdown).
    public var notes: String

    /// Version und Build als ``AppVersion``.
    public var appVersion: AppVersion {
        get { AppVersion(version: version, build: build) }
        set {
            version = newValue.version
            build = newValue.build
        }
    }

    public init(schema: Int = UpdateManifest.currentSchema, version: String, build: Int, tag: String,
                pkg: Package, minimumSystemVersion: String = "14.0", publishedAt: Date, notes: String = "") {
        self.schema = schema
        self.version = version
        self.build = build
        self.tag = tag
        self.pkg = pkg
        self.minimumSystemVersion = minimumSystemVersion
        self.publishedAt = publishedAt
        self.notes = notes
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case schema, version, build, tag, pkg, minimumSystemVersion, publishedAt, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        version = try container.decode(String.self, forKey: .version)
        build = try container.decode(Int.self, forKey: .build)
        tag = try container.decode(String.self, forKey: .tag)
        pkg = try container.decode(Package.self, forKey: .pkg)
        minimumSystemVersion = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion) ?? "14.0"
        let published = try container.decode(String.self, forKey: .publishedAt)
        guard let date = UpdateManifest.parseDate(published) else {
            throw DecodingError.dataCorruptedError(forKey: .publishedAt, in: container,
                                                   debugDescription: "Ungültiger Zeitpunkt „\(published)“")
        }
        publishedAt = date
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(version, forKey: .version)
        try container.encode(build, forKey: .build)
        try container.encode(tag, forKey: .tag)
        try container.encode(pkg, forKey: .pkg)
        try container.encode(minimumSystemVersion, forKey: .minimumSystemVersion)
        try container.encode(UpdateManifest.formatDate(publishedAt), forKey: .publishedAt)
        try container.encode(notes, forKey: .notes)
    }

    // MARK: - Lesen & Prüfen

    /// Liest und prüft Update-Informationen.
    /// - Throws: ``UpdateError/invalidManifest(_:)`` bei unlesbarem JSON oder unzulässigen Werten.
    public static func decode(_ data: Data) throws -> UpdateManifest {
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch let error as DecodingError {
            throw UpdateError.invalidManifest(describe(error))
        } catch {
            throw UpdateError.invalidManifest("JSON nicht lesbar")
        }
        try manifest.validate()
        return manifest
    }

    /// Prüft alle Werte (Schema, Version, Paketname, HTTPS-Adresse auf GitHub, Größe, Prüfsumme).
    /// - Throws: ``UpdateError/invalidManifest(_:)`` mit dem ersten gefundenen Problem.
    public func validate() throws {
        func fail(_ reason: String) -> UpdateError { .invalidManifest(reason) }
        guard schema >= 1 else { throw fail("Schema \(schema) wird nicht unterstützt") }
        guard AppVersion.isNumericVersion(version) else { throw fail("Version „\(version)“ ist ungültig") }
        guard build > 0 else { throw fail("Build-Nummer \(build) ist ungültig") }
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty, trimmedTag == tag, tag.count <= 200 else { throw fail("Tag „\(tag)“ ist ungültig") }
        guard AppVersion.isNumericVersion(minimumSystemVersion) else {
            throw fail("macOS-Mindestversion „\(minimumSystemVersion)“ ist ungültig")
        }
        guard UpdateManifest.isPlainPackageName(pkg.name) else {
            throw fail("Paketname „\(pkg.name)“ ist ungültig")
        }
        guard UpdateManifest.isAllowedPackageURL(pkg.url) else {
            throw fail("Paketadresse „\(pkg.url.absoluteString)“ ist nicht erlaubt (nur HTTPS auf GitHub)")
        }
        guard pkg.size > 0, pkg.size <= UpdateManifest.maximumPackageSize else {
            throw fail("Paketgröße \(pkg.size) ist ungültig")
        }
        guard pkg.sha256.count == 64, pkg.sha256.allSatisfy(\.isASCIIHexDigit) else {
            throw fail("SHA-256-Prüfsumme „\(pkg.sha256)“ ist ungültig")
        }
    }

    /// `true`, wenn das Update auf dieser macOS-Version läuft.
    public func isSupported(on systemVersion: OperatingSystemVersion) -> Bool {
        let required = AppVersion(version: minimumSystemVersion, build: 0).numericComponents
        let current = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
        for index in 0..<max(required.count, current.count) {
            let need = index < required.count ? required[index] : 0
            let have = index < current.count ? current[index] : 0
            if have != need { return have > need }
        }
        return true
    }

    /// JSON wie von der CI geschrieben (sortierte Schlüssel, ohne maskierte Schrägstriche).
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: - Hilfen

    /// Nur HTTPS, ohne Benutzerangaben, auf einem der ``allowedPackageHosts``.
    public static func isAllowedPackageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedPackageHosts.contains(host),
              url.user == nil, url.password == nil
        else { return false }
        return true
    }

    /// Reiner Dateiname mit Endung `.pkg` (keine Pfadtrenner, kein führender Punkt).
    static func isPlainPackageName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255,
              !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.lowercased().hasSuffix(".pkg"), name.count > 4,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }
        return true
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "" : " („\(keys.joined(separator: "."))“)"
        }
        switch error {
        case .keyNotFound(let key, let context):
            let keys = (context.codingPath + [key]).map(\.stringValue)
            return "Angabe „\(keys.joined(separator: "."))“ fehlt"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "Falscher Datentyp\(path(context))"
        case .dataCorrupted(let context):
            let detail = context.debugDescription
            return context.codingPath.isEmpty ? "JSON nicht lesbar" : detail + path(context)
        @unknown default:
            return "JSON nicht lesbar"
        }
    }
}

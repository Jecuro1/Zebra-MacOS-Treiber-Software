import Foundation

/// Woher Updates kommen: die GitHub-Releases eines Repositorys („Besitzer/Name“), bei privaten
/// Repositorys mit Zugriffstoken (Fine-grained Token mit Lesezugriff auf „Contents“).
///
/// Ohne Token lädt der ``UpdateClient`` über die öffentlichen Release-Adressen
/// (`github.com/<repo>/releases/latest/download/…`), mit Token über die REST-API
/// (`api.github.com`). Der Token wird nur an `api.github.com` bzw. `github.com` gesendet.
public struct UpdateSource: Sendable, Equatable {

    /// Info.plist-Schlüssel mit dem Repository der App (`LWUpdateRepository`).
    public static let infoPlistKey = "LWUpdateRepository"

    /// Repository, z. B. „Jecuro1/Zebra-MacOS-Treiber-Software“.
    public var repository: String
    /// Zugriffstoken für private Repositorys (`nil` = öffentlich).
    public var token: String?

    public init(repository: String, token: String? = nil) {
        self.repository = repository
        self.token = token
    }

    /// Repository aus der `Info.plist` eines Bundles (`LWUpdateRepository`), falls gültig.
    public static func configuredRepository(bundle: Bundle = .main) -> String? {
        guard let value = (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              isValidRepository(value) else { return nil }
        return value
    }

    /// `true`, wenn ``repository`` die Form „Besitzer/Name“ hat.
    public var isValid: Bool { UpdateSource.isValidRepository(repository) }

    /// Token ohne Leerraum; `nil`, wenn keiner angegeben ist.
    public var effectiveToken: String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Prüft „Besitzer/Name“: Besitzer aus Buchstaben, Ziffern und „-“, Name zusätzlich mit „.“ und „_“.
    public static func isValidRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let owner = parts[0], name = parts[1]
        func allowed(_ part: Substring, extra: Set<Character>) -> Bool {
            !part.isEmpty && part.count <= 100
                && part.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || extra.contains($0) }
        }
        return allowed(owner, extra: ["-"]) && allowed(name, extra: ["-", ".", "_"]) && name != "." && name != ".."
    }

    /// Öffentliche Adresse der Update-Informationen des neuesten Releases.
    public var latestManifestURL: URL? {
        guard isValid else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/latest/download/\(UpdateManifest.assetName)")
    }

    /// REST-API-Adresse des neuesten Releases (für private Repositorys mit Token).
    public var latestReleaseAPIURL: URL? {
        guard isValid else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// Release-Seite des Repositorys (für „Im Browser öffnen“).
    public var releasesPageURL: URL? {
        guard isValid else { return nil }
        return URL(string: "https://github.com/\(repository)/releases")
    }
}

/// Ein gefundenes, neueres Update.
public struct AvailableUpdate: Sendable, Equatable, Identifiable, Codable {
    /// Update-Informationen des Releases.
    public var manifest: UpdateManifest
    /// Installierte Version zum Zeitpunkt der Suche.
    public var current: AppVersion
    /// REST-API-Adresse des Paket-Assets (nur bei Zugriff mit Token, sonst `nil`).
    public var assetURL: URL?

    public var id: String { manifest.tag }

    public init(manifest: UpdateManifest, current: AppVersion, assetURL: URL? = nil) {
        self.manifest = manifest
        self.current = current
        self.assetURL = assetURL
    }

    /// Version des Updates.
    public var version: AppVersion { manifest.appVersion }

    /// Adresse, von der das Paket geladen wird.
    public var downloadURL: URL { assetURL ?? manifest.pkg.url }
}

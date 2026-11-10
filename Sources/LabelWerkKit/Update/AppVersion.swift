import Foundation

/// Version eines LabelWerk-Builds: Marketing-Version (`CFBundleShortVersionString`, z. B. „1.1.0“)
/// und fortlaufende Build-Nummer (`CFBundleVersion`, in der CI die Laufnummer).
///
/// Verglichen wird numerisch je Versionsbestandteil („1.10.0“ > „1.9.3“, fehlende Bestandteile
/// zählen als 0: „1.1“ == „1.1.0“), danach nach Build-Nummer. Damit ist jeder neue CI-Build
/// derselben Marketing-Version ein Update. Nichtnumerische Anhänge eines Bestandteils
/// („0-beta“) werden ignoriert.
public struct AppVersion: Comparable, Codable, Hashable, Sendable, CustomStringConvertible {

    /// Marketing-Version, z. B. „1.1.0“.
    public var version: String
    /// Build-Nummer, z. B. 58.
    public var build: Int

    public init(version: String, build: Int) {
        self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.build = build
    }

    /// Liest Version und Build aus der `Info.plist` eines Bundles.
    /// - Returns: `nil`, wenn eine der Angaben fehlt oder die Build-Nummer keine Ganzzahl ist
    ///   (z. B. bei `swift run` ohne App-Bundle).
    public static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let info = bundle.infoDictionary else { return nil }
        return AppVersion(infoDictionary: info)
    }

    /// Liest `CFBundleShortVersionString` und `CFBundleVersion` aus einem Info-Wörterbuch.
    public init?(infoDictionary: [String: Any]) {
        guard let version = (infoDictionary["CFBundleShortVersionString"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty,
              let build = AppVersion.parseBuild(infoDictionary["CFBundleVersion"])
        else { return nil }
        self.init(version: version, build: build)
    }

    /// Liest eine Version aus einem Release-Tag der Form `v1.1.0-b58`.
    public init?(tag: String) {
        var text = Substring(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        guard let marker = text.range(of: "-b", options: .backwards) else { return nil }
        let version = String(text[..<marker.lowerBound])
        let buildText = text[marker.upperBound...]
        guard !version.isEmpty, AppVersion.isNumericVersion(version),
              !buildText.isEmpty, buildText.allSatisfy(\.isASCIIDigit),
              let build = Int(buildText) else { return nil }
        self.init(version: version, build: build)
    }

    /// Release-Tag dieser Version, z. B. `v1.1.0-b58` (wie ihn die CI vergibt).
    public var tag: String { "v\(version)-b\(build)" }

    /// „1.1.0 (Build 58)“.
    public var description: String { "\(version) (Build \(build))" }

    /// Numerische Versionsbestandteile ohne abschließende Nullen („1.1.0“ → [1, 1]).
    public var numericComponents: [Int] {
        var parts = version.split(separator: ".", omittingEmptySubsequences: false).map { part -> Int in
            let digits = part.prefix(while: \.isASCIIDigit)
            guard !digits.isEmpty else { return 0 }
            return Int(digits) ?? Int.max
        }
        while parts.last == 0 { parts.removeLast() }
        return parts
    }

    // MARK: - Vergleich

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let a = lhs.numericComponents, b = rhs.numericComponents
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return lhs.build < rhs.build
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.numericComponents == rhs.numericComponents && lhs.build == rhs.build
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(numericComponents)
        hasher.combine(build)
    }

    // MARK: - Hilfen

    /// `true`, wenn `text` nur aus Ziffern und Punkten besteht („1.1.0“).
    static func isNumericVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCIIDigit) }
    }

    private static func parseBuild(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 18, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }
}

extension Character {
    /// Ziffer 0–9 (ohne andere Unicode-Ziffern).
    var isASCIIDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 0x30 && ascii <= 0x39
    }
}

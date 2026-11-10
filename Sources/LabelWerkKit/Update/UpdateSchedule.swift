import Foundation

/// Wann automatisch nach Updates gesucht wird: kurz nach dem Start (``launchDelay``) und danach
/// alle ``checkInterval`` Sekunden (Standard: 6 Stunden).
public struct UpdateSchedule: Sendable, Equatable, Codable {

    /// Standardabstand zwischen zwei automatischen Suchen (6 Stunden).
    public static let defaultCheckInterval: TimeInterval = 6 * 60 * 60

    /// Abstand zwischen zwei automatischen Suchen in Sekunden.
    public var checkInterval: TimeInterval
    /// Wartezeit nach dem Programmstart bis zur ersten Suche in Sekunden.
    public var launchDelay: TimeInterval

    public init(checkInterval: TimeInterval = UpdateSchedule.defaultCheckInterval, launchDelay: TimeInterval = 10) {
        self.checkInterval = max(60, checkInterval)
        self.launchDelay = max(0, launchDelay)
    }

    /// `true`, wenn eine automatische Suche fällig ist: noch nie gesucht, die letzte Suche liegt
    /// mindestens ``checkInterval`` zurück, oder sie liegt (wegen einer verstellten Uhr) mehr als
    /// eine Minute in der Zukunft.
    public func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        if elapsed < -60 { return true }
        return elapsed >= checkInterval
    }

    /// Zeitpunkt der nächsten automatischen Suche (frühestens `now`).
    public func nextCheck(lastCheck: Date?, now: Date = Date()) -> Date {
        guard let lastCheck, !isDue(lastCheck: lastCheck, now: now) else { return now }
        return lastCheck.addingTimeInterval(checkInterval)
    }

    /// Sekunden bis zur nächsten automatischen Suche (0 = jetzt fällig).
    public func delayUntilNextCheck(lastCheck: Date?, now: Date = Date()) -> TimeInterval {
        max(0, nextCheck(lastCheck: lastCheck, now: now).timeIntervalSince(now))
    }
}

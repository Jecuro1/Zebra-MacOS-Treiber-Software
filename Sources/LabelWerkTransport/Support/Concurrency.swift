import Foundation

// MARK: - Sperren

extension NSLock {
    /// Führt `body` unter der Sperre aus.
    ///
    /// Eigener Name statt `withLock`, weil `NSLocking.withLock` nicht auf allen
    /// Foundation-Versionen (macOS 14 / swift-corelibs-foundation) identisch verfügbar ist.
    @inline(__always)
    func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Ein durch eine `NSLock` geschützter Wert, sicher zwischen Threads und Tasks teilbar.
///
/// Alle Zugriffe laufen über `withLock`, daher ist die Konformität zu `Sendable` korrekt,
/// solange der gespeicherte Wert selbst `Sendable` ist.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    /// Liest oder verändert den Wert atomar.
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.locked { try body(&storage) }
    }

    /// Momentaufnahme des Werts.
    var value: Value {
        lock.locked { storage }
    }

    /// Ersetzt den Wert.
    func set(_ newValue: Value) {
        lock.locked { storage = newValue }
    }
}

/// Hülle für Objekte aus Apple-Frameworks, die (noch) nicht als `Sendable` annotiert sind.
///
/// Wird nur dort verwendet, wo der Zugriff nachweislich serialisiert ist (eigene
/// `DispatchQueue`, `MainActor`) oder das Objekt laut Dokumentation threadsicher ist.
struct UncheckedSendable<Wrapped>: @unchecked Sendable {
    let value: Wrapped
    init(_ value: Wrapped) { self.value = value }
}

// MARK: - Abbruch blockierender Operationen

/// Threadsichere Abbruchmarke für blockierende Systemaufrufe.
///
/// Blockierende Schleifen (z. B. `poll()` in kurzen Zeitscheiben) prüfen die Marke regelmäßig;
/// `withTaskCancellationHandler` setzt sie, sobald der aufrufende Task abgebrochen wird.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.locked { cancelled } }

    func cancel() { lock.locked { cancelled = true } }

    /// Wirft `CancellationError`, falls abgebrochen wurde.
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Brücke zwischen Swift-Concurrency und blockierenden Aufrufen.
///
/// Blockierende Systemaufrufe (Socket-I/O, `getaddrinfo`, IOKit, Prozesse) dürfen den
/// kooperativen Thread-Pool nicht belegen. Sie laufen deshalb auf einer eigenen `DispatchQueue`;
/// der aufrufende Task wartet per Continuation.
enum BlockingIO {
    /// Liefert eine neue serielle Queue für eine einzelne blockierende Aufgabe.
    ///
    /// Serielle Queues laufen in libdispatch auf dem „overcommit“-Pool, der bei blockierten
    /// Threads zusätzliche Threads startet. Globale bzw. nebenläufige Queues sind dagegen auf die
    /// Zahl der CPU-Kerne begrenzt und könnten durch blockierende Aufrufe (DNS, Prozesse,
    /// `poll()`) ausgehungert werden.
    static func makeQueue(_ label: String = "de.labelwerk.transport.blocking") -> DispatchQueue {
        DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Führt `body` auf `queue` (Standard: eigene serielle Queue) aus und liefert das Ergebnis asynchron.
    ///
    /// Wird der aufrufende Task abgebrochen, wird die übergebene `CancellationFlag` gesetzt;
    /// `body` sollte sie in Warteschleifen prüfen und dann `CancellationError` werfen.
    static func run<T: Sendable>(
        on queue: DispatchQueue? = nil,
        _ body: @escaping @Sendable (CancellationFlag) throws -> T
    ) async throws -> T {
        let flag = CancellationFlag()
        let target = queue ?? makeQueue()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                target.async {
                    continuation.resume(with: Result { try body(flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Wartet, bis alle bisher in `queues` eingereihten Arbeiten erledigt sind (Reihenfolge wie übergeben).
    static func drain(_ queues: [DispatchQueue]) async {
        for queue in queues {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
        }
    }
}

// MARK: - Zeitdauern

extension Duration {
    /// Dauer in Sekunden als `TimeInterval`.
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Dauer in ganzen Millisekunden (aufgerundet, begrenzt auf `Int32.max`, nie negativ).
    var clampedMilliseconds: Int32 {
        let parts = components
        if parts.seconds < 0 || (parts.seconds == 0 && parts.attoseconds <= 0) { return 0 }
        if parts.seconds >= Int64(Int32.max / 1000) { return Int32.max }
        let millis = parts.seconds * 1000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: millis)
    }

    /// Erzeugt eine Dauer aus einem `TimeInterval` (negative Werte → 0).
    static func interval(_ seconds: TimeInterval) -> Duration {
        guard seconds.isFinite, seconds > 0 else { return .zero }
        return .nanoseconds(Int64(min(seconds, 9_000_000_000) * 1e9))
    }
}

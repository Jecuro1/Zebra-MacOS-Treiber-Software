import Foundation

/// Threadsicherer Empfangspuffer für ereignisgesteuerte Transporte (Bluetooth RFCOMM, BLE).
///
/// Delegate-Rückrufe (beliebiger Thread) legen Daten mit `append(_:)` ab; `read(timeout:)`
/// wartet asynchron – ohne Threads zu blockieren – bis Daten eintreffen, die Frist abläuft,
/// der Task abgebrochen wird oder der Puffer per `fail(_:)` beendet wurde.
final class IncomingDataBuffer: @unchecked Sendable {
    /// Ein wartender Leser. Zustand wird ausschließlich unter `lock` des Puffers verändert.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var signalled = false
    }

    private let lock = NSLock()
    private var pending = Data()
    private var failure: TransportError?
    private var waiters: [ObjectIdentifier: Waiter] = [:]
    /// Obergrenze für ungelesene Daten; ältere Bytes werden verworfen, wenn niemand liest.
    private let capacity: Int

    init(capacity: Int = 8 * 1024 * 1024) {
        self.capacity = max(1, capacity)
    }

    /// Anzahl ungelesener Bytes.
    var bufferedByteCount: Int { lock.locked { pending.count } }

    /// Fügt empfangene Daten an und weckt wartende Leser.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let woken: [Waiter] = lock.locked {
            pending.append(data)
            if pending.count > capacity {
                pending = Data(pending.suffix(capacity))
            }
            return takeAllWaitersLocked()
        }
        resume(woken)
    }

    /// Beendet den Puffer: Nach den noch gepufferten Daten wirft `read` den Fehler.
    func fail(_ error: TransportError) {
        let woken: [Waiter] = lock.locked {
            failure = error
            return takeAllWaitersLocked()
        }
        resume(woken)
    }

    /// Setzt den Puffer für eine neue Verbindung zurück (Daten und Fehlerzustand werden verworfen).
    func reset() {
        lock.locked {
            pending = Data()
            failure = nil
        }
    }

    /// Wartet höchstens `timeout` auf Daten; liefert alles Verfügbare oder leere Daten.
    func read(timeout: Duration) async throws -> Data {
        if let available = try takeAvailable() { return available }
        guard timeout > .zero else { return Data() }
        try Task.checkCancellation()

        let waiter = Waiter()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.signal(waiter)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(waiter, continuation)
            }
        } onCancel: {
            self.signal(waiter)
        }
        timer.cancel()
        try Task.checkCancellation()
        return try takeAvailable() ?? Data()
    }

    // MARK: Intern

    private func takeAvailable() throws -> Data? {
        try lock.locked {
            if !pending.isEmpty {
                let data = pending
                pending = Data()
                return data
            }
            if let failure { throw failure }
            return nil
        }
    }

    private func register(_ waiter: Waiter, _ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = lock.locked {
            if waiter.signalled || !pending.isEmpty || failure != nil {
                return true
            }
            waiter.continuation = continuation
            waiters[ObjectIdentifier(waiter)] = waiter
            return false
        }
        if resumeNow { continuation.resume() }
    }

    private func signal(_ waiter: Waiter) {
        let continuation: CheckedContinuation<Void, Never>? = lock.locked {
            waiter.signalled = true
            waiters[ObjectIdentifier(waiter)] = nil
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func takeAllWaitersLocked() -> [Waiter] {
        let all = Array(waiters.values)
        waiters.removeAll()
        for waiter in all { waiter.signalled = true }
        return all
    }

    private func resume(_ woken: [Waiter]) {
        for waiter in woken {
            let continuation: CheckedContinuation<Void, Never>? = lock.locked {
                let continuation = waiter.continuation
                waiter.continuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }
}

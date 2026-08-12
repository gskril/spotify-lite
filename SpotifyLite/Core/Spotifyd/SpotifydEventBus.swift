import Foundation

final class SpotifydEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SpotifydEvent>.Continuation] = [:]

    func stream() -> AsyncStream<SpotifydEvent> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            lock.withLock {
                continuations[identifier] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.continuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    func send(_ event: SpotifydEvent) {
        let listeners = lock.withLock { Array(continuations.values) }
        for listener in listeners {
            listener.yield(event)
        }
    }
}

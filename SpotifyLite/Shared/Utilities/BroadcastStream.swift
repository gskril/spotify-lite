import Foundation

/// Fans each sent event out to every live subscriber. Subscribers only see events sent after
/// they call `stream()`, and each keeps at most `bufferSize` undelivered events.
final class BroadcastStream<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferSize: Int
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    init(bufferSize: Int) {
        self.bufferSize = bufferSize
    }

    func stream() -> AsyncStream<Event> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
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

    func send(_ event: Event) {
        let listeners = lock.withLock { Array(continuations.values) }
        for listener in listeners {
            listener.yield(event)
        }
    }
}

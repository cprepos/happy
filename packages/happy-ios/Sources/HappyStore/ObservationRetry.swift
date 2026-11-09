import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Where sync and observation failures are said: never a message body or
/// a key, only what failed and why.
public enum SyncLog {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "app.happy", category: "Sync")
    public static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    #else
    public static func error(_ message: String) { print("[Sync] \(message)") }
    #endif
}

/// A database observation that fails is subscribed again after a pause
/// instead of ending: a feed that ends for good leaves its screen frozen
/// until the app is relaunched.
public enum ObservationRetry {
    /// The pause before subscribing again after `failures` failures in a
    /// row: 250 ms, doubling, at most 10 s.
    public static func delay(afterFailures failures: Int) -> Duration {
        let doublings = min(max(failures, 1) - 1, 6)
        return min(.milliseconds(250 * (1 << doublings)), .seconds(10))
    }

    /// The values of `subscribe()`'s streams, one after another. A stream
    /// that throws is logged and subscribed again after `delay`. The result
    /// ends only when its consumer stops listening, or when a stream ends
    /// without an error.
    public static func stream<Value: Sendable>(
        _ label: String,
        _ subscribe: @escaping @Sendable () -> AsyncThrowingStream<Value, Error>
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached {
                var failures = 0
                while !Task.isCancelled {
                    do {
                        for try await value in subscribe() {
                            guard !Task.isCancelled else { break }
                            failures = 0
                            continuation.yield(value)
                        }
                        break
                    } catch {
                        guard !Task.isCancelled else { break }
                        failures += 1
                        SyncLog.error("\(label) observation failed, subscribing again: \(error)")
                        try? await Task.sleep(for: delay(afterFailures: failures))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

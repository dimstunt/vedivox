import Foundation

/// Deduplicates concurrent async work behind a single in-flight `Task`.
///
/// Parallel `run(_:)` callers share one execution: the first starts the
/// operation, the rest await the same `Task`. A successful result is cached so
/// later callers skip the work entirely; a thrown error is **not** cached, so
/// the next call retries from scratch.
///
/// Used to keep first-run model downloads from firing twice when `warmUp()` and
/// the first `processMeeting()` race: the ~500 MB HuggingFace
/// download runs once, not once per caller.
actor SingleFlight<Value: Sendable> {
    private var inFlight: Task<Value, Error>?
    private var cached: Value?

    /// How many times the underlying operation actually started. Stays at 1
    /// across any number of concurrent callers; increments again only after a
    /// failure forces a retry. Exposed for tests and diagnostics.
    private(set) var runCount = 0

    /// Runs `operation` unless a cached value exists or another call is already
    /// in flight, in which case the existing result/Task is reused.
    func run(_ operation: @Sendable @escaping () async throws -> Value) async throws -> Value {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }

        runCount += 1
        let task = Task { try await operation() }
        inFlight = task
        do {
            let value = try await task.value
            cached = value
            inFlight = nil
            return value
        } catch {
            // Do not cache failures — a later call must be able to retry
            // (e.g. the network came back).
            inFlight = nil
            throw error
        }
    }

    /// True once a successful result has been cached.
    var isLoaded: Bool { cached != nil }
}

import Foundation
import os

/// Runs an async call, or throws `TimedOut` at a limit — whichever comes first.
///
/// Not a task group: a group waits for its children, and a call blocked in
/// Core Audio never comes back to be cancelled (the mic engine hung
/// for good in `AVAudioNode.inputFormat`). The operation is left running; the
/// caller decides what to do with whatever it still holds.
enum Deadline {
    struct TimedOut: Error {}

    static func run<T: Sendable>(
        limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        @Sendable func finish(_ result: Result<T, any Error>) {
            pending.withLock { continuation in
                continuation?.resume(with: result)
                continuation = nil
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            let timer = Task {
                try? await Task.sleep(for: limit)
                finish(.failure(TimedOut()))
            }
            Task {
                do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
                timer.cancel()
            }
        }
    }
}

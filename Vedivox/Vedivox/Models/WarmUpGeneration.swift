import Foundation

/// Decides whether a model warm-up progress report still describes the current
/// run (an earlier change).
///
/// FluidAudio's progress handlers fire on an unspecified queue, so every report
/// hops to the main actor through its own unawaited task. Those hops can land
/// after the run that produced them already finished: the old code then wrote
/// stale progress back into `AppState` and left it there for the rest of the
/// session, so the next attempt started by showing the previous one's numbers.
///
/// Each run takes a token; a report is written only while its token is still
/// the active one. Ending a run drops the token, so a finished run accepts
/// nothing — including its own late reports.
struct WarmUpGeneration: Equatable {
    private var counter = 0

    /// Token of the run in progress, or nil when no run is active.
    private(set) var activeToken: Int?

    /// Starts a run and returns its token, invalidating any earlier one.
    mutating func begin() -> Int {
        counter += 1
        activeToken = counter
        return counter
    }

    /// Ends the run identified by `token`. A no-op if a newer run already
    /// started — that run owns the state now.
    mutating func end(_ token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
    }

    /// Whether a report tagged with `token` may still be written.
    func accepts(_ token: Int) -> Bool {
        activeToken == token
    }
}

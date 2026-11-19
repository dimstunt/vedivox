import Foundation

/// Formats a running duration for display — the dictation HUD's clock
///
/// Lives here rather than in the view because the HUD itself can only be
/// checked by hand: it is a non-activating panel over other apps, and Views do
/// not compile into the headless test target.
enum ElapsedTimeLabel {

    /// `m:ss`, growing to `h:mm:ss` past the hour. Seconds are truncated, not
    /// rounded: a clock that shows 0:01 before one second has passed reads as
    /// running ahead of the recording.
    ///
    /// A negative or non-finite input yields the zero label — a clock is never
    /// the right place to surface that something went wrong.
    static func text(for seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

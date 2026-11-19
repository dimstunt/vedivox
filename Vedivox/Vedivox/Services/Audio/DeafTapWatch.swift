import Foundation

/// Decides when a system tap that hears only digital zero while a call plays
/// gets rebuilt.
///
/// On 2026-11-19 a Zoom call went to digital zero on the tap for 25 minutes
/// mid-recording: callbacks flowed, sounds started later by other processes
/// (systemsoundserverd) still came through, only Zoom's stream was lost —
/// the 18.11 chop taken to the end. A fresh tap heard the call at once. Real
/// silence looks the same from inside (everyone on a break, Zoom still
/// outputting), so the rebuild has to be cheap when wrong: ~0.1 s of the
/// track filled with silence by the timeline, at waits that double while the
/// zero goes on — 60, 120, 240 … 600 s, 8 rebuilds in a silent hour.
///
/// No Core Audio inside: seconds and flags in, a yes/no out.
struct DeafTapWatch {
    /// Zero seconds in a row before the first rebuild.
    /// shortcut: one incident; the loss per deaf episode is about this long,
    /// lower it if the log shows rebuilds bringing the call back.
    static let threshold: TimeInterval = 60
    static let maxWait: TimeInterval = 600

    private(set) var wait: TimeInterval = DeafTapWatch.threshold

    /// `zeroRun`: seconds of all-zero callbacks in a row on the current
    /// stream (a rebuild starts it over). `heardSinceRebuild`: a non-zero
    /// sample came since the last rebuild — the wait starts over too.
    /// `callOutputting`: a meeting app or browser plays now.
    mutating func shouldRebuild(zeroRun: TimeInterval, heardSinceRebuild: Bool, callOutputting: Bool) -> Bool {
        if heardSinceRebuild { wait = Self.threshold }
        guard callOutputting, zeroRun >= wait else { return false }
        wait = min(wait * 2, Self.maxWait)
        return true
    }
}

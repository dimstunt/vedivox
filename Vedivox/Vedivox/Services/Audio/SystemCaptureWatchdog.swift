import Foundation

/// Decides when the system-audio tap is dead and how often to look.
///
/// With `TapAutoStart = false` the aggregate runs on the host clock from the
/// first second: callbacks come every 512 frames (~10.7 ms at 48 kHz) whether
/// or not anything plays. So "no callback for 2 s" is never silence — it is a
/// dead aggregate, and a dead aggregate leaves the tap idle, which hangs the
/// next process that opens the microphone (Zoom, `0x3C` every 14 s). The
/// owner (`SystemAudioCapture`) tears the tap+aggregate down and builds fresh
/// ones on the same writer; the timeline fills the hole by the wall clock.
///
/// No Core Audio inside: every decision is a function of seconds, so the
/// sequence "callbacks flow / stop / rebuild / stop again" is a unit test.
struct SystemCaptureWatchdog {
    /// Dead when no callback arrived for this long after the later of the
    /// last callback and the last (re)start. One threshold for both: the
    /// first callback after an eager start comes within 0.1 s (measured
    /// 2026-09-28: 0.038–0.062 s), so 2 s is ~190 missed callbacks either way.
    static let stallThreshold: TimeInterval = 2.0
    /// Same pace and cap as the microphone watchdog: a rebuild that keeps
    /// failing must not hammer coreaudiod.
    static let interval: Duration = MicrophoneCapture.watchdogInterval
    static let maxInterval: Duration = MicrophoneCapture.watchdogMaxInterval
    /// `defaults write com.dimstunt.Vedivox systemWatchdogRebuild -bool true`
    /// forces one rebuild on the next tick — the live-acceptance handle for
    /// the recovery path without killing coreaudiod.
    static let manualRebuildDefaultsKey = "systemWatchdogRebuild"

    private(set) var currentInterval: Duration = SystemCaptureWatchdog.interval
    private var lastCallbacks = -1

    /// Seconds in; zero means "never happened".
    static func isStalled(
        now: Double, lastCallback: Double, lastStart: Double, threshold: Double = stallThreshold
    ) -> Bool {
        let reference = max(lastCallback, lastStart)
        guard reference > 0 else { return false }
        return now - reference >= threshold
    }

    /// One watchdog tick. Returns the age of the stream when it is dead (the
    /// caller rebuilds), nil when alive. Pace doubles while stalled and
    /// returns to base only once real callbacks advanced — the grace period
    /// after a rebuild must not reset it by itself.
    mutating func tick(now: Double, lastCallback: Double, lastStart: Double, callbacks: Int) -> Double? {
        let stalled = Self.isStalled(now: now, lastCallback: lastCallback, lastStart: lastStart)
        currentInterval = MicrophoneCapture.nextWatchdogInterval(
            current: currentInterval, stalled: stalled, framesAdvanced: callbacks > lastCallbacks
        )
        lastCallbacks = callbacks
        return stalled ? now - max(lastCallback, lastStart) : nil
    }
}

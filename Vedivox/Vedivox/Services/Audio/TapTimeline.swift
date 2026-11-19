import Foundation

/// Where each system-audio tap callback lands on the file timeline: how much
/// silence goes in before it, and why. Pure bookkeeping — `SystemAudioWriter`
/// turns the events into file writes and log lines.
///
/// Why a value type and not a flag in the writer: the "first callback" used to
/// be recognised by `nextExpectedSample < 0`, and the aggregate's stream starts
/// at a negative sample time (−911 measured 2026-09-02), so the second callback
/// was "first" again and the leading silence went in twice. Keeping
/// the position logic here makes that sequence a unit test instead of a
/// bloated recording.
struct TapTimeline {
    enum Event: Equatable {
        /// First callback of the stream; silence covers capture start → here.
        case first(silenceFrames: Int)
        /// The counter continued where the previous callback ended.
        case contiguous
        /// The counter jumped forward: `counted` by the counter, `fill`
        /// actually inserted — bounded by the wall clock.
        case gap(fill: Int, counted: Int)
        /// The counter jumped backward (a fresh stream); the wall-clock idle
        /// time between the two streams is filled.
        case backward(frames: Int, fill: Int)
    }

    let sampleRate: Double
    let captureStartHostNanos: UInt64
    private(set) var started = false
    private var nextExpectedSample: Double = 0
    /// Host time of the previous callback — the wall-clock bound for gaps.
    private var lastHostNanos: UInt64 = 0
    /// Host time where the previous buffer ended — the reference for the tail.
    private var lastBufferEndHostNanos: UInt64 = 0

    init(sampleRate: Double, captureStartHostNanos: UInt64) {
        self.sampleRate = sampleRate
        self.captureStartHostNanos = captureStartHostNanos
    }

    /// The next callback belongs to a fresh stream (tap+aggregate rebuilt by
    /// the watchdog). The counter restarts near −900, which `advance` only
    /// recognises as a jump when the old stream ran for over a second; the
    /// flag makes the idle time between streams a wall-clock fill regardless.
    mutating func expectRestart() {
        restartPending = true
    }

    private var restartPending = false

    mutating func advance(sampleTime: Double, hostNanos: UInt64, frames: Int) -> Event {
        defer {
            // Consumed by whichever callback comes next — a stream that never
            // delivered before the rebuild gets its `.first` from the anchor.
            restartPending = false
            nextExpectedSample = sampleTime + Double(frames)
            lastHostNanos = hostNanos
            lastBufferEndHostNanos = hostNanos + Self.nanos(frames: frames, sampleRate: sampleRate)
        }

        guard started else {
            started = true
            // A callback stamped before the capture start owes nothing.
            let elapsed = hostNanos > captureStartHostNanos
                ? Double(hostNanos - captureStartHostNanos) / 1_000_000_000
                : 0
            return .first(silenceFrames: Int(elapsed * sampleRate))
        }

        let gap = sampleTime - nextExpectedSample
        let wallSeconds = hostNanos > lastHostNanos
            ? Double(hostNanos - lastHostNanos) / 1_000_000_000
            : 0

        if gap > 1 {
            let fill = SystemAudioCapture.gapFillFrames(
                sampleTimeGap: gap, hostElapsedSeconds: wallSeconds, sampleRate: sampleRate
            )
            return .gap(fill: fill, counted: Int(gap))
        }
        if restartPending || gap < -sampleRate {
            // A fresh stream restarts near −900; the only honest measure of
            // what was missed between the two streams is the wall clock.
            let wallFrames = wallSeconds * sampleRate
            let fill = SystemAudioCapture.gapFillFrames(
                sampleTimeGap: wallFrames, hostElapsedSeconds: wallSeconds, sampleRate: sampleRate
            )
            return .backward(frames: Int(-gap), fill: fill)
        }
        return .contiguous
    }

    /// Silence owed at stop: from the end of the last buffer — or from capture
    /// start, when the stream never delivered a frame (nothing played, output
    /// never changed) — up to `nowHostNanos`.
    func finish(nowHostNanos: UInt64) -> Int {
        let reference = started ? lastBufferEndHostNanos : captureStartHostNanos
        guard nowHostNanos > reference else { return 0 }
        return Int(Double(nowHostNanos - reference) / 1_000_000_000 * sampleRate)
    }

    private static func nanos(frames: Int, sampleRate: Double) -> UInt64 {
        guard sampleRate > 0, frames > 0 else { return 0 }
        return UInt64(Double(frames) / sampleRate * 1_000_000_000)
    }
}

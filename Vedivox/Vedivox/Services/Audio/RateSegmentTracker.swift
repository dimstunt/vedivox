import Foundation

/// One contiguous run of a recording captured at a single effective sample rate.
struct RateSegment: Equatable, Sendable {
    /// File frame position (frames written so far) where this segment starts.
    let startFrame: Int64
    /// Effective sample rate of this segment in frames per wall-clock second.
    let rate: Double
}

/// Detects mid-recording changes of the effective sample rate from IOProc timing.
///
/// The Core Audio tap keeps delivering frames after the output device is
/// re-created with a different clock (e.g. Bluetooth A2DP→HFP switch drops
/// 48000→24000 Hz when Zoom grabs the headset mic), but the file header keeps
/// the original rate — those frames play speed- and pitch-shifted. See
/// one meeting.
///
/// The tracker measures frames-per-wall-second over ~1s windows and commits a
/// new segment once two consecutive windows agree on a rate that deviates >5%
/// from the current segment's rate. A single anomalous window (scheduling
/// hiccup, buffer burst) never commits.
struct RateSegmentTracker {
    /// Deviation from the current segment rate (relative to header rate) that
    /// counts as a change candidate. Matches the 5% threshold used by the
    /// existing end-of-recording verification.
    private static let changeThreshold = 0.05
    /// Two consecutive candidate windows must agree within this tolerance.
    private static let agreementTolerance = 0.03

    private let headerRate: Double
    private let minWindowSeconds: Double

    private(set) var segments: [RateSegment]

    private var windowStartNanos: UInt64?
    private var windowStartFrame: Int64 = 0
    private var pendingRate: Double?
    private var pendingStartFrame: Int64 = 0

    init(headerRate: Double, minWindowSeconds: Double = 1.0) {
        self.headerRate = headerRate
        self.minWindowSeconds = minWindowSeconds
        self.segments = [RateSegment(startFrame: 0, rate: headerRate)]
    }

    var currentRate: Double { segments[segments.count - 1].rate }
    var hasRateChange: Bool { segments.count > 1 }

    /// Feed one IOProc callback. `framePosition` is the total frames written
    /// after this callback; `hostNanos` is wall clock in nanoseconds.
    /// Returns the new segment when a rate change is committed (for logging).
    mutating func addCallback(hostNanos: UInt64, framePosition: Int64) -> RateSegment? {
        guard let start = windowStartNanos else {
            windowStartNanos = hostNanos
            windowStartFrame = framePosition
            return nil
        }
        guard hostNanos > start else { return nil }
        let elapsed = Double(hostNanos - start) / 1_000_000_000
        guard elapsed >= minWindowSeconds else { return nil }

        let windowRate = Double(framePosition - windowStartFrame) / elapsed
        let windowFirstFrame = windowStartFrame
        windowStartNanos = hostNanos
        windowStartFrame = framePosition
        return evaluate(windowRate: windowRate, windowFirstFrame: windowFirstFrame)
    }

    /// Call when frames are inserted out-of-band (silence prepend / gap fill):
    /// the current window's frames-per-second no longer reflects the device
    /// clock, so the window is discarded instead of poisoning the measurement.
    mutating func noteDiscontinuity(framePosition: Int64) {
        windowStartNanos = nil
        windowStartFrame = framePosition
        pendingRate = nil
    }

    private mutating func evaluate(windowRate: Double, windowFirstFrame: Int64) -> RateSegment? {
        let deviation = abs(windowRate - currentRate) / headerRate
        guard deviation > Self.changeThreshold else {
            pendingRate = nil
            return nil
        }
        if let pending = pendingRate,
           abs(windowRate - pending) / headerRate <= Self.agreementTolerance {
            let segment = RateSegment(startFrame: pendingStartFrame, rate: (pending + windowRate) / 2)
            segments.append(segment)
            pendingRate = nil
            return segment
        }
        pendingRate = windowRate
        pendingStartFrame = windowFirstFrame
        return nil
    }
}

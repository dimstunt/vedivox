import Foundation

/// The device's real sample rate, measured once from the first callbacks of
/// one continuous stream: frames by the device's counter over host time.
///
/// The counter restarts with every stream (a watchdog rebuild, an excluded app
/// appearing) and jumps when the device changes. A measurement that spanned
/// such a break divided one stream's frames by both streams' time and came out
/// as a believable wrong rate — 32 kHz, 8 kHz — which then went into the
/// header of a correct 48 kHz file: the whole call track played slowed down
/// and its transcript was noise. guarded only against rates no clock
/// can have.
struct RateMeasurement {
    /// Callbacks one measurement spans (about a second of audio).
    static let callbackCount = 100

    struct Result: Equatable {
        let rate: Double
        let seconds: Double
        let frames: Double
    }

    private var start: (sampleTime: Double, hostNanos: UInt64)?
    private var counted = 0
    private var done = false

    /// The stream broke: what was counted cannot be compared with what follows.
    mutating func restart() {
        guard !done else { return }
        start = nil
        counted = 0
    }

    /// Feed one callback. Returns the result on the callback that completes
    /// the measurement, nil on every other one.
    mutating func add(sampleTime: Double, hostNanos: UInt64) -> Result? {
        guard !done else { return nil }
        guard let start else {
            self.start = (sampleTime, hostNanos)
            counted = 1
            return nil
        }
        counted += 1
        guard counted == Self.callbackCount else { return nil }
        done = true
        guard hostNanos > start.hostNanos else { return nil }
        let seconds = Double(hostNanos - start.hostNanos) / 1_000_000_000
        let frames = sampleTime - start.sampleTime
        return Result(rate: frames / seconds, seconds: seconds, frames: frames)
    }
}

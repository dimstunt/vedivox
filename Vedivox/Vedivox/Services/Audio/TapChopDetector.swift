import Foundation

/// Recognizes call audio reaching the system tap "chopped".
///
/// On 2026-11-18 a Zoom call reached the tap for 31 minutes as ~64 ms of
/// sound and ~96 ms of digital zero in a strict 160 ms cycle (6 of every 15
/// buffers of 512 frames were all zero): ~12 zero↔sound transitions a second,
/// where a normal recording has a few a minute (pauses in a call that sends
/// digital silence, the start and end of a sound). Nothing else noticed:
/// callbacks flowed, the track had sound. The signature is the transition
/// rate held for seconds: `transitionsPerSecond` and more for `onsetSeconds`
/// in a row.
///
/// Fed once per tap callback with integer facts only (the callback must not
/// allocate or wait); seconds are counted in frames of the stream, not by the
/// clock. No Core Audio inside, so the sequences are unit tests.
struct TapChopDetector {
    /// Checked on the stored tracks (AAC, 24 kHz, 256-frame blocks = the same
    /// 10.7 ms): 18.11 gives runs of 8+ up to 28 s and the first onset 36 s
    /// into the chop; 15 other recordings never reach a run of 10, the closest
    /// is 7 s (one meeting at 0:07:20, gated speech or a short chop of its own).
    /// shortcut: one incident and a compressed copy, not the raw tap; adjust
    /// if the log shows a chop missed or a call flagged for nothing.
    static let transitionsPerSecond = 8
    static let onsetSeconds = 10
    /// Seconds of sound without the signature before the chop counts as gone.
    /// All-zero seconds (the call fell silent) neither prove nor break it.
    /// Inside the 18.11 chop other sound hid the holes for up to 16 s in a
    /// row; at 10 the state flapped 22 times in 31 min and every flap would
    /// reset the rebuild count before the owner heard of it.
    static let clearSeconds = 60

    enum Event: Equatable {
        /// `onsetSeconds` chopped seconds in a row. `again`: the chop was
        /// already up — it is still there after a restart of the stream.
        case chopped(again: Bool, transitions: Int, zeroBuffers: Int)
        case cleared
    }

    private let framesPerSecond: Int
    /// The chop is up: raised by `.chopped`, dropped by `.cleared` only — a
    /// restart of the stream keeps it, so a rebuild that did not help shows.
    private(set) var chopped = false
    /// Running totals since the last `takeCounts()`, for the periodic log line.
    private var zeroBuffers = 0
    private var transitions = 0

    private var lastZero: Bool?
    private var frames = 0
    private var secondTransitions = 0
    private var secondZeroBuffers = 0
    private var secondSounded = false
    private var choppedRun = 0
    private var cleanRun = 0

    init(sampleRate: Double) {
        framesPerSecond = max(1, Int(sampleRate))
    }

    /// One callback: whether every sample of it was zero, and its length.
    mutating func add(zero: Bool, frames count: Int) -> Event? {
        if zero {
            zeroBuffers += 1
            secondZeroBuffers += 1
        } else {
            secondSounded = true
        }
        if let lastZero, lastZero != zero {
            transitions += 1
            secondTransitions += 1
        }
        lastZero = zero
        frames += count
        guard frames >= framesPerSecond else { return nil }
        frames -= framesPerSecond

        let (secondTransitions, secondZeroBuffers, secondSounded) = (secondTransitions, secondZeroBuffers, secondSounded)
        self.secondTransitions = 0
        self.secondZeroBuffers = 0
        self.secondSounded = false

        if secondTransitions >= Self.transitionsPerSecond {
            choppedRun += 1
            cleanRun = 0
            guard choppedRun == Self.onsetSeconds else { return nil }
            let again = chopped
            chopped = true
            return .chopped(again: again, transitions: secondTransitions, zeroBuffers: secondZeroBuffers)
        }
        choppedRun = 0
        guard secondSounded else { return nil }
        cleanRun += 1
        guard chopped, cleanRun >= Self.clearSeconds else { return nil }
        chopped = false
        cleanRun = 0
        return .cleared
    }

    /// The stream restarts (tap rebuilt): forget the half-counted second and
    /// the runs, keep `chopped`.
    mutating func restart() {
        lastZero = nil
        frames = 0
        secondTransitions = 0
        secondZeroBuffers = 0
        secondSounded = false
        choppedRun = 0
        cleanRun = 0
    }

    /// Zero buffers and transitions since the last call.
    mutating func takeCounts() -> (zeroBuffers: Int, transitions: Int) {
        defer { (zeroBuffers, transitions) = (0, 0) }
        return (zeroBuffers, transitions)
    }

    /// Rebuilds of the tap per chop before the owner is told. A rebuild costs
    /// a ~0.1 s hole and work in coreaudiod; the detector needs `onsetSeconds`
    /// of a new stream to call it again, so they come at least that far apart.
    static let maxRebuilds = 3

    static let bannerTitle = "Call audio is coming through chopped"
    static let bannerMessage = "The other participants reach the recording in short pieces, so their words are being lost, and restarting the capture did not help. In the call app, switch the speaker to another device and back."
    /// The menu bar's status line while the warning is up.
    static let menuLine = "Call audio chopped — switch the call's speaker and back"
    /// The pipeline's attention name for the meeting afterwards.
    static let attention = "system chopped"
}

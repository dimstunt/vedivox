import Foundation

/// Where to cut the audio waiting for live recognition into a window the
/// offline model transcribes whole.
///
/// Cuts go to pauses: a window that ends mid-word costs that word twice, once
/// at the end of this window and once at the start of the next. Thresholds are
/// relative to the loudness of the window itself, so there is no absolute
/// level to calibrate per microphone.
enum LiveWindowCutter {
    static let sampleRate = 16000
    /// The model reads a short window worse: on a real call, windows from 2 s
    /// strayed from the final transcript in 13.9 % of the words, from 6 s in
    /// 11.3 % (VedivoxBench/LiveModelChoiceBench, 2026-11-09). After a silence the
    /// silence itself fills this, so a lone question still comes at its pause.
    static let minWindow = 6 * sampleRate
    /// Parakeet takes 15 s in one pass; 12 s leaves room and bounds the delay
    /// of a speaker who never pauses. Longer did not read better in the bench.
    static let maxWindow = 12 * sampleRate

    private static let frame = sampleRate / 50 // 20 ms
    /// A phrase is over when this much of the tail is quiet.
    private static let pauseFrames = 25 // 0.5 s
    /// Quiet means 20 dB below the loud part of the window.
    private static let quietRatio: Float = 0.1
    /// Without a pause, the cut goes to the quietest spot of the last 4 s.
    private static let searchFrames = 200

    /// How many leading samples to transcribe now, or nil to wait for more.
    /// The limits are parameters for the bench that chose them.
    static func cut(
        _ samples: [Float],
        minWindow: Int = LiveWindowCutter.minWindow,
        maxWindow: Int = LiveWindowCutter.maxWindow
    ) -> Int? {
        guard samples.count >= minWindow else { return nil }
        let levels = frameLevels(samples)
        // The fifth loudest frame: 100 ms of sound is enough to count as
        // speech («да»), one click is not.
        let loud = levels.sorted(by: >)[4]

        // A pause after speech: the phrase is over, do not wait for the limit.
        // The cut sits in the middle of the pause, away from both words.
        if loud > 0, let tailPeak = levels.suffix(pauseFrames).max(), tailPeak < loud * quietRatio {
            return (levels.count - pauseFrames / 2) * frame
        }
        guard samples.count >= maxWindow else { return nil }

        let from = max(levels.count - searchFrames, minWindow / frame)
        let quietest = (from ..< levels.count).min { levels[$0] < levels[$1] } ?? levels.count - 1
        return (quietest + 1) * frame
    }

    /// Digital silence — a system track with nothing playing. Not worth a
    /// model call, and nothing a microphone ever produces.
    static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { abs($0) > 1e-4 }
    }

    /// RMS of each whole 20 ms frame.
    private static func frameLevels(_ samples: [Float]) -> [Float] {
        (0 ..< samples.count / frame).map { index in
            var sum: Float = 0
            for sample in samples[index * frame ..< (index + 1) * frame] { sum += sample * sample }
            return (sum / Float(frame)).squareRoot()
        }
    }
}

import Foundation

/// Detects whether the mic channel picked up system audio played through
/// speakers (vs. headphones) — the precondition for echo suppression.
///
/// Method (verified 2026-04-09 on 42 recordings, 100% accuracy, see
///): RMS energy envelopes in 25 ms frames,
/// Pearson correlation over 10 s windows. Speaker playback couples the two
/// envelopes (+0.47..+0.70 global corr, 73% of windows above 0.3), headphones
/// do not (-0.25..+0.01, 0-13%). Decision threshold: >20% of windows above 0.3.
enum EchoDetector {
    struct Config {
        var frameDuration: Double = 0.025 // RMS frame, seconds
        var windowDuration: Double = 10.0 // correlation window, seconds
        var corrThreshold: Float = 0.3 // per-window "high correlation"
        var highCorrFraction: Double = 0.2 // fraction of windows → speaker mode
        /// Windows where either envelope is near-constant (silence) carry no
        /// signal about coupling and are excluded from the denominator.
        var minVariance: Float = 1e-10
    }

    struct Result {
        let isSpeakerMode: Bool
        let highCorrFraction: Double
        let validWindows: Int
    }

    static func detectSpeakerBleed(
        micSamples: [Float],
        systemSamples: [Float],
        sampleRate: Int = 16000,
        config: Config = Config()
    ) -> Result {
        let frameLen = max(1, Int(config.frameDuration * Double(sampleRate)))
        let count = min(micSamples.count, systemSamples.count)
        guard count >= frameLen else {
            return Result(isSpeakerMode: false, highCorrFraction: 0, validWindows: 0)
        }

        let micEnv = rmsEnvelope(micSamples, count: count, frameLen: frameLen)
        let sysEnv = rmsEnvelope(systemSamples, count: count, frameLen: frameLen)

        let framesPerWindow = max(2, Int(config.windowDuration / config.frameDuration))
        var validWindows = 0
        var highWindows = 0

        var start = 0
        while start < micEnv.count {
            let end = min(start + framesPerWindow, micEnv.count)
            defer { start += framesPerWindow }
            // Skip trailing windows shorter than half the nominal length.
            guard end - start >= framesPerWindow / 2 else { continue }

            let mic = Array(micEnv[start ..< end])
            let sys = Array(sysEnv[start ..< end])
            guard let corr = pearson(mic, sys, minVariance: config.minVariance) else { continue }

            validWindows += 1
            if corr > config.corrThreshold {
                highWindows += 1
            }
        }

        guard validWindows > 0 else {
            return Result(isSpeakerMode: false, highCorrFraction: 0, validWindows: 0)
        }
        let fraction = Double(highWindows) / Double(validWindows)
        return Result(
            isSpeakerMode: fraction > config.highCorrFraction,
            highCorrFraction: fraction,
            validWindows: validWindows
        )
    }

    // MARK: - Internals

    private static func rmsEnvelope(_ samples: [Float], count: Int, frameLen: Int) -> [Float] {
        let frames = count / frameLen
        var env = [Float](repeating: 0, count: frames)
        for f in 0 ..< frames {
            var sum: Float = 0
            let base = f * frameLen
            for i in base ..< (base + frameLen) {
                sum += samples[i] * samples[i]
            }
            env[f] = (sum / Float(frameLen)).squareRoot()
        }
        return env
    }

    /// Pearson correlation; nil when either side is (near-)constant.
    private static func pearson(_ a: [Float], _ b: [Float], minVariance: Float) -> Float? {
        let n = Float(a.count)
        guard n > 1 else { return nil }
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covAB: Float = 0
        var varA: Float = 0
        var varB: Float = 0
        for i in 0 ..< a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            covAB += da * db
            varA += da * da
            varB += db * db
        }
        guard varA > minVariance, varB > minVariance else { return nil }
        return covAB / (varA.squareRoot() * varB.squareRoot())
    }
}

import XCTest

/// envelope-correlation speaker-vs-headphones autodetect.
/// Synthetic signals reproduce the two regimes from the 2026-04-09 study:
/// speaker playback couples the mic envelope to the system envelope,
/// headphones leave them independent.
final class EchoDetectorTests: XCTestCase {
    private let sampleRate = 16000

    /// Deterministic noise (seeded LCG) so the suite never flakes.
    private struct SeededNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(truncatingIfNeeded: state >> 33)) / Float(Int64.max >> 33) * 0.5
        }
    }

    /// Noise with a burst envelope: `on` seconds of speech-level noise,
    /// `off` seconds near silence, repeated.
    private func burstNoise(
        seconds: Int, onSeconds: Double, offSeconds: Double,
        amplitude: Float, seed: UInt64, phaseShift: Double = 0
    ) -> [Float] {
        var noise = SeededNoise(seed: seed)
        let n = seconds * sampleRate
        let period = onSeconds + offSeconds
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / Double(sampleRate) + phaseShift
            let inBurst = t.truncatingRemainder(dividingBy: period) < onSeconds
            out[i] = noise.next() * (inBurst ? amplitude : amplitude * 0.02)
        }
        return out
    }

    func test_speakerBleed_detected() {
        // System: talk bursts. Mic: attenuated copy of system (the bleed)
        // plus a small independent noise floor — classic no-headphones call.
        let system = burstNoise(seconds: 40, onSeconds: 3, offSeconds: 2, amplitude: 0.5, seed: 1)
        var micNoise = SeededNoise(seed: 2)
        let mic = system.map { $0 * 0.35 + micNoise.next() * 0.01 }

        let result = EchoDetector.detectSpeakerBleed(
            micSamples: mic, systemSamples: system, sampleRate: sampleRate
        )
        XCTAssertTrue(result.isSpeakerMode, "coupled envelopes must read as speaker mode")
        XCTAssertGreaterThan(result.highCorrFraction, 0.5)
        XCTAssertGreaterThan(result.validWindows, 0)
    }

    func test_headphones_notDetected() {
        // Turn-taking: the mic hears only the user, who talks in the system
        // audio's pauses — envelopes are anti-correlated, like a real
        // headphones call (0-13% high-corr windows in the 2026-04-09 study).
        let system = burstNoise(seconds: 60, onSeconds: 3, offSeconds: 2, amplitude: 0.5, seed: 3)
        let mic = burstNoise(
            seconds: 60, onSeconds: 2, offSeconds: 3,
            amplitude: 0.4, seed: 4, phaseShift: 2
        )

        let result = EchoDetector.detectSpeakerBleed(
            micSamples: mic, systemSamples: system, sampleRate: sampleRate
        )
        XCTAssertFalse(result.isSpeakerMode, "turn-taking envelopes must read as headphones")
        XCTAssertLessThanOrEqual(result.highCorrFraction, 0.2)
    }

    func test_silence_notDetected() {
        let silence = [Float](repeating: 0, count: 30 * sampleRate)
        let result = EchoDetector.detectSpeakerBleed(
            micSamples: silence, systemSamples: silence, sampleRate: sampleRate
        )
        XCTAssertFalse(result.isSpeakerMode)
        XCTAssertEqual(result.validWindows, 0, "constant envelopes carry no correlation signal")
    }

    func test_tooShortInput_notDetected() {
        let blip = [Float](repeating: 0.1, count: 100)
        let result = EchoDetector.detectSpeakerBleed(
            micSamples: blip, systemSamples: blip, sampleRate: sampleRate
        )
        XCTAssertFalse(result.isSpeakerMode)
    }
}

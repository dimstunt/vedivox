import XCTest

/// The amplitude-to-display mapping behind the HUD's level bars.
///
/// Worth pinning because both failure modes are silent and look like a broken
/// microphone: a mapping that never leaves zero, and one that pins at full for
/// any input at all.
final class AudioLevelMeterTests: XCTestCase {

    func testSilenceReadsZero() {
        XCTAssertEqual(AudioLevelMeter.instantLevel(of: [Float](repeating: 0, count: 512)), 0)
        XCTAssertEqual(AudioLevelMeter.instantLevel(of: []), 0)
    }

    /// Room tone must not light up the bars, or «is it hearing me» becomes
    /// unanswerable — the display would look the same whether or not anyone
    /// is speaking.
    func testNoiseFloorStaysSilent() {
        let hiss = (0 ..< 512).map { _ in Float.random(in: -0.0015 ... 0.0015) }
        XCTAssertEqual(AudioLevelMeter.instantLevel(of: hiss), 0)
    }

    func testFullScaleReadsOne() {
        let loud = (0 ..< 512).map { i in i.isMultiple(of: 2) ? Float(1) : Float(-1) }
        XCTAssertEqual(AudioLevelMeter.instantLevel(of: loud), 1, accuracy: 0.001)
    }

    /// Speech sits far below full scale in amplitude. The whole reason for the
    /// dB mapping is that this lands in the visible upper half rather than
    /// hugging zero the way a linear scale would.
    func testSpeechLevelLandsInUpperHalf() {
        let speech = [Float](repeating: 0.05, count: 512)
        let level = AudioLevelMeter.instantLevel(of: speech)
        XCTAssertGreaterThan(level, 0.5)
        XCTAssertLessThan(level, 1)
    }

    func testLouderInputReadsHigher() {
        let quiet = AudioLevelMeter.instantLevel(of: [Float](repeating: 0.01, count: 512))
        let loud = AudioLevelMeter.instantLevel(of: [Float](repeating: 0.2, count: 512))
        XCTAssertGreaterThan(loud, quiet)
    }

    /// Smoothing must approach the target rather than jump — the jump is what
    /// makes bars flicker on every buffer.
    func testSmoothingRampsTowardsTheTarget() {
        var meter = AudioLevelMeter()
        let loud = [Float](repeating: 0.2, count: 512)
        let target = AudioLevelMeter.instantLevel(of: loud)

        let first = meter.append(loud)
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, target)

        var latest = first
        for _ in 0 ..< 20 { latest = meter.append(loud) }
        XCTAssertEqual(latest, target, accuracy: 0.02)
        XCTAssertGreaterThan(latest, first)
    }

    func testSmoothingFallsBackToSilence() {
        var meter = AudioLevelMeter()
        for _ in 0 ..< 20 { meter.append([Float](repeating: 0.2, count: 512)) }
        XCTAssertGreaterThan(meter.level, 0.5)

        for _ in 0 ..< 40 { meter.append([Float](repeating: 0, count: 512)) }
        XCTAssertLessThan(meter.level, 0.05)
    }

    /// A NaN out of a misbehaving converter must not poison every later frame.
    func testNonFiniteSamplesAreIgnored() {
        let level = AudioLevelMeter.instantLevel(of: [.nan, .infinity, 0.05, 0.05])
        XCTAssertTrue(level.isFinite)
    }
}

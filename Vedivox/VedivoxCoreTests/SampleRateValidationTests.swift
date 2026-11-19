import XCTest

final class SampleRateValidationTests: XCTestCase {

    // Regression: a sampleTime counter reset mid-measurement produced
    // measured=-136494458 Hz, which the corrector clamped to 8000 Hz and
    // rewrote a valid 48 kHz recording as 8 kHz (one meeting).
    func testNegativeMeasuredRateIsImplausible() {
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(-136_494_458))
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(-1))
    }

    func testZeroAndNonFiniteRatesAreImplausible() {
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(0))
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(.nan))
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(.infinity))
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(-.infinity))
    }

    func testStandardRatesArePlausible() {
        for rate: Double in [8000, 16000, 44100, 48000, 96000, 192000] {
            XCTAssertTrue(SystemAudioCapture.isPlausibleMeasuredRate(rate), "\(rate) should be plausible")
        }
    }

    func testSlightlyOffClockRatesArePlausible() {
        // Real drifted clocks: a 44.1 kHz device while the header says 48 kHz.
        XCTAssertTrue(SystemAudioCapture.isPlausibleMeasuredRate(44_099.7))
        XCTAssertTrue(SystemAudioCapture.isPlausibleMeasuredRate(48_012.3))
    }

    func testAbsurdMagnitudesAreImplausible() {
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(500_000))
        XCTAssertFalse(SystemAudioCapture.isPlausibleMeasuredRate(3_000))
    }
}

final class RateMeasurementTests: XCTestCase {
    /// One tap callback: 512 frames, 10.67 ms at 48 kHz.
    private static let frames = 512.0
    private static let stepNanos = UInt64(512.0 / 48000 * 1_000_000_000)

    /// Feeds `count` callbacks of a stream whose counter starts at −911 (as
    /// the aggregate's does) and returns the last result.
    private func feed(_ measurement: inout RateMeasurement, count: Int, fromNanos: UInt64) -> RateMeasurement.Result? {
        var last: RateMeasurement.Result?
        for i in 0 ..< count {
            last = measurement.add(
                sampleTime: -911 + Double(i) * Self.frames,
                hostNanos: fromNanos + UInt64(i) * Self.stepNanos
            ) ?? last
        }
        return last
    }

    func testAContinuousStreamMeasuresItsRate() {
        var measurement = RateMeasurement()
        let result = feed(&measurement, count: 100, fromNanos: 1_000_000_000)
        XCTAssertEqual(result?.rate ?? 0, 48000, accuracy: 50)
    }

    /// An excluded app appeared 0.5 s into the recording: the tap was rebuilt
    /// and the counter started over. Counting the 100 callbacks across the
    /// rebuild gave 53 callbacks of frames over 1.3 s — about 21 kHz, which
    /// passes the plausibility gate and rewrote a 48 kHz header as 22.05 kHz.
    func testARestartedStreamIsMeasuredOnItsOwn() {
        var measurement = RateMeasurement()
        XCTAssertNil(feed(&measurement, count: 47, fromNanos: 1_000_000_000))

        measurement.restart()
        let afterRebuild: UInt64 = 1_000_000_000 + 47 * Self.stepNanos + 200_000_000
        XCTAssertNil(feed(&measurement, count: 99, fromNanos: afterRebuild), "no result may span the break")

        let result = measurement.add(
            sampleTime: -911 + 99 * Self.frames, hostNanos: afterRebuild + 99 * Self.stepNanos
        )
        XCTAssertEqual(result?.rate ?? 0, 48000, accuracy: 50)
    }
}

final class GapFillTests: XCTestCase {

    // Regression: an output-device switch rebuilt the aggregate device and
    // mSampleTime jumped ~37.9M frames over ~8 wall-clock seconds; the old
    // code wrote all of it as silence (one meeting grew 8 min → 40 min).
    func testCounterJumpIsBoundedByWallClock() {
        let fill = SystemAudioCapture.gapFillFrames(
            sampleTimeGap: 37_927_323, hostElapsedSeconds: 8.5, sampleRate: 48000
        )
        XCTAssertEqual(fill, Int(8.5 * 48000))
    }

    func testGenuineIdleGapIsFilledFully() {
        // IOProc went idle for 5 s (silence not delivered): counter advance
        // matches wall clock, so the whole gap is real.
        let fill = SystemAudioCapture.gapFillFrames(
            sampleTimeGap: 240_000, hostElapsedSeconds: 5.0, sampleRate: 48000
        )
        XCTAssertEqual(fill, 240_000)
    }

    func testSmallSchedulingJitterIsTrusted() {
        // Gap slightly above wall-clock estimate is normal jitter — fill as counted.
        let fill = SystemAudioCapture.gapFillFrames(
            sampleTimeGap: 50_000, hostElapsedSeconds: 1.0, sampleRate: 48000
        )
        XCTAssertEqual(fill, 50_000)
    }

    func testBackwardOrZeroGapFillsNothing() {
        XCTAssertEqual(SystemAudioCapture.gapFillFrames(
            sampleTimeGap: -246_847_180, hostElapsedSeconds: 1.8, sampleRate: 48000
        ), 0)
        XCTAssertEqual(SystemAudioCapture.gapFillFrames(
            sampleTimeGap: 0, hostElapsedSeconds: 0.011, sampleRate: 48000
        ), 0)
    }

    func testJumpWithZeroWallClockFillsNothing() {
        // Host clock says no time passed — nothing real to fill regardless of jump size.
        XCTAssertEqual(SystemAudioCapture.gapFillFrames(
            sampleTimeGap: 90_000_000, hostElapsedSeconds: 0, sampleRate: 48000
        ), 0)
    }
}

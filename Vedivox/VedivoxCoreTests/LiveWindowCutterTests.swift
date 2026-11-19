import XCTest

/// Where live audio is cut into windows for the offline model (live-transcript
/// D1): at a pause when there is one, at the quietest spot when there is not.
final class LiveWindowCutterTests: XCTestCase {

    private func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0 ..< Int(seconds * 16000)).map { amplitude * sinf(2 * .pi * 220 * Float($0) / 16000) }
    }

    /// Room noise, not digital silence: a microphone never gives zeros.
    private func quiet(_ seconds: Double, amplitude: Float = 0.002) -> [Float] {
        (0 ..< Int(seconds * 16000)).map { amplitude * sinf(2 * .pi * 50 * Float($0) / 16000) }
    }

    private func seconds(_ samples: Int?) -> Double? {
        samples.map { Double($0) / 16000 }
    }

    func testTooShortToCut() {
        XCTAssertNil(LiveWindowCutter.cut(speech(3) + quiet(2.9)))
    }

    func testAPauseAfterSpeechCutsInsideThePause() throws {
        let cut = try XCTUnwrap(seconds(LiveWindowCutter.cut(speech(7) + quiet(0.6))))
        XCTAssertGreaterThan(cut, 7.0)
        XCTAssertLessThan(cut, 7.6)
    }

    /// A lone «да» after a silence: the silence fills the shortest window, so
    /// the word comes at its own pause, not at the 12 s limit.
    func testAShortWordAfterASilenceIsCutAtItsPause() throws {
        let cut = try XCTUnwrap(seconds(LiveWindowCutter.cut(quiet(5.3) + speech(0.2) + quiet(0.6))))
        XCTAssertGreaterThan(cut, 5.5)
        XCTAssertLessThan(cut, 6.1)
    }

    func testAPhraseShorterThanTheShortestWindowWaits() {
        XCTAssertNil(LiveWindowCutter.cut(speech(3) + quiet(1)))
    }

    func testSpeechWithoutAPauseWaits() {
        XCTAssertNil(LiveWindowCutter.cut(speech(5)))
        XCTAssertNil(LiveWindowCutter.cut(speech(11.9)))
    }

    /// A pause shorter than the pause rule (a breath) is still where the cut
    /// goes once the window is full.
    func testAFullWindowIsCutAtItsQuietestRecentSpot() throws {
        let cut = try XCTUnwrap(seconds(LiveWindowCutter.cut(speech(10) + quiet(0.1) + speech(1.9))))
        XCTAssertEqual(cut, 10.05, accuracy: 0.06)
    }

    func testAFullWindowOfEvenNoiseIsStillCut() throws {
        let cut = try XCTUnwrap(seconds(LiveWindowCutter.cut(quiet(12))))
        XCTAssertGreaterThanOrEqual(cut, 6)
        XCTAssertLessThanOrEqual(cut, 12)
    }

    /// Noise has no «quiet tail» relative to itself: silence must not be
    /// chopped into a model call every two seconds.
    func testNoiseAloneIsNotAPause() {
        XCTAssertNil(LiveWindowCutter.cut(quiet(9)))
    }

    func testCutIsAWholeNumberOfFramesWithinTheAudio() throws {
        let audio = speech(7) + quiet(0.6) + speech(0.013)
        let cut = try XCTUnwrap(LiveWindowCutter.cut(audio))
        XCTAssertEqual(cut % 320, 0)
        XCTAssertLessThanOrEqual(cut, audio.count)
    }

    /// The limits the bench swept are parameters, not a second code path.
    func testLimitsCanBeOverridden() throws {
        XCTAssertNil(LiveWindowCutter.cut(speech(3) + quiet(0.6)))
        XCTAssertNotNil(LiveWindowCutter.cut(speech(3) + quiet(0.6), minWindow: 2 * 16000))
        XCTAssertNil(LiveWindowCutter.cut(speech(12.5), maxWindow: 14 * 16000))
    }

    func testDigitalSilenceIsToldFromAQuietRoom() {
        XCTAssertTrue(LiveWindowCutter.isSilent([Float](repeating: 0, count: 16000)))
        XCTAssertTrue(LiveWindowCutter.isSilent([Float](repeating: 0.00001, count: 16000)))
        XCTAssertFalse(LiveWindowCutter.isSilent(quiet(1)))
    }
}

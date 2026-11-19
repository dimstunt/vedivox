import XCTest

/// Covers the one part of the dictation HUD that a headless suite can reach
/// The panel behaviour itself —
/// not stealing focus, showing over a full-screen app — is verifiable only by
/// hand, so the clock at least is pinned here.
final class ElapsedTimeLabelTests: XCTestCase {

    func testZeroAndSubSecond() {
        XCTAssertEqual(ElapsedTimeLabel.text(for: 0), "0:00")
        XCTAssertEqual(ElapsedTimeLabel.text(for: 0.9), "0:00")
    }

    /// Truncation, not rounding: at 0.9 s the recording has not reached one
    /// second, and a clock that says otherwise runs ahead of the audio.
    func testSecondsTruncate() {
        XCTAssertEqual(ElapsedTimeLabel.text(for: 7.99), "0:07")
        XCTAssertEqual(ElapsedTimeLabel.text(for: 59.99), "0:59")
    }

    func testMinuteBoundary() {
        XCTAssertEqual(ElapsedTimeLabel.text(for: 60), "1:00")
        XCTAssertEqual(ElapsedTimeLabel.text(for: 61), "1:01")
        XCTAssertEqual(ElapsedTimeLabel.text(for: 3599), "59:59")
    }

    /// Dictations are short, but the HUD also runs while a long one is being
    /// held open — the label must not silently wrap to 0:00 at the hour.
    func testHourBoundary() {
        XCTAssertEqual(ElapsedTimeLabel.text(for: 3600), "1:00:00")
        XCTAssertEqual(ElapsedTimeLabel.text(for: 3661), "1:01:01")
        XCTAssertEqual(ElapsedTimeLabel.text(for: 7322), "2:02:02")
    }

    func testInvalidInputFallsBackToZero() {
        XCTAssertEqual(ElapsedTimeLabel.text(for: -5), "0:00")
        XCTAssertEqual(ElapsedTimeLabel.text(for: .nan), "0:00")
        XCTAssertEqual(ElapsedTimeLabel.text(for: .infinity), "0:00")
    }
}

import XCTest

/// The star card shows once, after the fifth processed meeting, never over work in progress.
final class StarPromptTests: XCTestCase {
    func testWaitsForTheFifthMeeting() {
        XCTAssertFalse(StarPrompt.shouldShow(processedMeetings: 4, dismissed: false, busy: false))
        XCTAssertTrue(StarPrompt.shouldShow(processedMeetings: 5, dismissed: false, busy: false))
        XCTAssertTrue(StarPrompt.shouldShow(processedMeetings: 120, dismissed: false, busy: false))
    }

    func testNeverAgainOnceDismissed() {
        XCTAssertFalse(StarPrompt.shouldShow(processedMeetings: 9, dismissed: true, busy: false))
    }

    func testNeverWhileRecordingOrProcessing() {
        XCTAssertFalse(StarPrompt.shouldShow(processedMeetings: 9, dismissed: false, busy: true))
    }
}

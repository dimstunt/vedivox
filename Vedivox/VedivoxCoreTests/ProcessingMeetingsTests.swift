import XCTest

final class ProcessingMeetingsTests: XCTestCase {
    private func meeting(_ id: String, _ status: MeetingStatus) -> Meeting {
        var meeting = Meeting(id: id, title: id)
        meeting.status = status
        return meeting
    }

    func testCountsProcessingAndStoppedRecordingsButNotTheLiveOne() {
        let meetings = [
            meeting("live", .recording), meeting("stopped", .recording),
            meeting("a", .transcribing), meeting("b", .diarizing),
            meeting("done", .done), meeting("err", .error), meeting("attn", .needsAttention),
        ]
        XCTAssertEqual(ProcessingMeetings.of(meetings, recordingId: "live").map(\.id), ["stopped", "a", "b"])
        XCTAssertEqual(ProcessingMeetings.of(meetings, recordingId: nil).map(\.id), ["live", "stopped", "a", "b"])
    }

    func testLabel() {
        XCTAssertEqual(ProcessingMeetings.label(1), "Processing 1 meeting…")
        XCTAssertEqual(ProcessingMeetings.label(3), "Processing 3 meetings…")
    }
}

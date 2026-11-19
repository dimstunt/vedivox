import XCTest

/// The status badge's tooltip: plain words per reason, honest about
/// meetings whose reason was never stored.
final class MeetingStatusReasonTests: XCTestCase {

    func testEveryReasonHasItsOwnPlainExplanation() {
        let texts = MeetingStatusReason.allCases.map {
            MeetingStatusReason.help(status: .needsAttention, stored: $0.rawValue)
        }
        for (reason, text) in zip(MeetingStatusReason.allCases, texts) {
            XCTAssertEqual(text, reason.explanation, "\(reason)")
            XCTAssertFalse(reason.explanation.contains(reason.rawValue + " "), "the code leaks into the text: \(reason)")
        }
        XCTAssertEqual(Set(texts).count, texts.count, "two reasons share one text")
    }

    /// The codes the pipeline produces today, as it logs them.
    func testPipelineCodesAreKnown() {
        for code in ["mic", "system", "system diarization", "diarization", "mic compression", "system compression"] {
            XCTAssertNotNil(MeetingStatusReason(rawValue: code), code)
        }
    }

    /// The silent-call warning names its reason in another file; the tooltip must know that string.
    func testSilentCallTrackReasonHasATooltip() {
        XCTAssertEqual(MeetingStatusReason.systemSilentDuringCall.rawValue, SilentCallTrack.attention)
        XCTAssertEqual(MeetingStatusReason.systemChopped.rawValue, TapChopDetector.attention)
    }

    func testSeveralReasonsAreListedInOrderWithoutRepeats() {
        let stored = MeetingStatusReason.stored(["system", "mic compression", "system"])
        XCTAssertEqual(stored, "system, mic compression, system")
        XCTAssertEqual(
            MeetingStatusReason.help(status: .needsAttention, stored: stored),
            MeetingStatusReason.systemLost.explanation + "\n" + MeetingStatusReason.micCompression.explanation
        )
        XCTAssertNil(MeetingStatusReason.stored([]))
    }

    func testMeetingsProcessedBeforeReasonsWereKeptSaySo() {
        XCTAssertEqual(MeetingStatusReason.help(status: .needsAttention, stored: nil), MeetingStatusReason.notSaved)
        XCTAssertEqual(MeetingStatusReason.help(status: .needsAttention, stored: ""), MeetingStatusReason.notSaved)
        XCTAssertEqual(MeetingStatusReason.help(status: .error, stored: nil), MeetingStatusReason.unknownFailure)
    }

    func testUnknownCodeDoesNotInventAReason() {
        XCTAssertEqual(
            MeetingStatusReason.help(status: .needsAttention, stored: "something new"),
            MeetingStatusReason.unknownAttention
        )
    }

    func testOtherStatusesHaveNoTooltip() {
        for status in [MeetingStatus.done, .recording, .transcribing, .diarizing] {
            XCTAssertNil(MeetingStatusReason.help(status: status, stored: "mic"), "\(status)")
        }
    }

    /// The reason belongs to the status it came with: the next status clears it.
    func testUpdateStatusStoresAndClearsTheReason() async throws {
        let repo = MeetingRepository(db: try makeTestDB())
        let meeting = Meeting(title: "m")
        try await repo.save(meeting)

        try await repo.updateStatus(meeting.id, status: .needsAttention, reason: "system")
        var found = try await repo.find(meeting.id)
        XCTAssertEqual(found?.status, .needsAttention)
        XCTAssertEqual(found?.statusReason, "system")

        try await repo.updateStatus(meeting.id, status: .transcribing)
        found = try await repo.find(meeting.id)
        XCTAssertNil(found?.statusReason)
    }
}

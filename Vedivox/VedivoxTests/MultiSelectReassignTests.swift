import XCTest
import GRDB
@testable import Vedivox

/// Tests for multi-select segment speaker reassignment.
final class MultiSelectReassignTests: XCTestCase {

    private var db: DatabaseManager!
    private var speakerRepo: SpeakerRepository!
    private var meetingRepo: MeetingRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        speakerRepo = SpeakerRepository(db: db)
        meetingRepo = MeetingRepository(db: db)
    }

    // MARK: - MeetingRepository.updateSegmentsSpeaker (batch)

    /// Batch update should change speakerId and speakerLabel for specified segment IDs only.
    func testBatchUpdateSegmentsSpeaker_updatesOnlySpecifiedIds() async throws {
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let alice = makeSpeaker(name: "Alice")
        let bob = makeSpeaker(name: "Bob")
        try await speakerRepo.save(alice)
        try await speakerRepo.save(bob)

        let seg1 = makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "Hello")
        let seg2 = makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", startTime: 5, endTime: 10, text: "World")
        let seg3 = makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", startTime: 10, endTime: 15, text: "Foo")
        try await meetingRepo.saveSegments([seg1, seg2, seg3])

        let segments = try await meetingRepo.segments(for: meeting.id)
        let idsToUpdate = [segments[0].id!, segments[2].id!]

        // Reassign segments 0 and 2 to Bob
        try await meetingRepo.updateSegmentsSpeaker(
            ids: idsToUpdate,
            meetingId: meeting.id,
            speakerId: bob.id,
            speakerLabel: "Bob"
        )

        let updated = try await meetingRepo.segments(for: meeting.id)

        // Segment 0 → Bob
        XCTAssertEqual(updated[0].speakerId, bob.id)
        XCTAssertEqual(updated[0].speakerLabel, "Bob")

        // Segment 1 → still Alice (not in selection)
        XCTAssertEqual(updated[1].speakerId, alice.id)
        XCTAssertEqual(updated[1].speakerLabel, "Alice")

        // Segment 2 → Bob
        XCTAssertEqual(updated[2].speakerId, bob.id)
        XCTAssertEqual(updated[2].speakerLabel, "Bob")
    }

    /// Batch update with empty IDs should be a no-op.
    func testBatchUpdateSegmentsSpeaker_emptyIdsIsNoop() async throws {
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let alice = makeSpeaker(name: "Alice")
        try await speakerRepo.save(alice)

        let seg = makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", text: "Hello")
        try await meetingRepo.saveSegments([seg])

        // Empty batch — should not crash or change anything
        try await meetingRepo.updateSegmentsSpeaker(
            ids: [],
            meetingId: meeting.id,
            speakerId: "bogus",
            speakerLabel: "Bogus"
        )

        let segments = try await meetingRepo.segments(for: meeting.id)
        XCTAssertEqual(segments[0].speakerLabel, "Alice")
    }

    /// Batch update should not affect segments in other meetings even if IDs match hypothetically.
    func testBatchUpdateSegmentsSpeaker_scopedToMeeting() async throws {
        let meeting1 = makeMeeting(title: "M1")
        let meeting2 = makeMeeting(title: "M2")
        try await meetingRepo.save(meeting1)
        try await meetingRepo.save(meeting2)

        let alice = makeSpeaker(name: "Alice")
        let bob = makeSpeaker(name: "Bob")
        try await speakerRepo.save(alice)
        try await speakerRepo.save(bob)

        let seg1 = makeSegment(meetingId: meeting1.id, speakerId: alice.id, speakerLabel: "Alice", text: "M1 seg")
        let seg2 = makeSegment(meetingId: meeting2.id, speakerId: alice.id, speakerLabel: "Alice", text: "M2 seg")
        try await meetingRepo.saveSegments([seg1, seg2])

        let m1Segments = try await meetingRepo.segments(for: meeting1.id)
        let m2Segments = try await meetingRepo.segments(for: meeting2.id)

        // Try to update m2's segment using m1's meetingId — should not change it
        try await meetingRepo.updateSegmentsSpeaker(
            ids: [m2Segments[0].id!],
            meetingId: meeting1.id,
            speakerId: bob.id,
            speakerLabel: "Bob"
        )

        let m2After = try await meetingRepo.segments(for: meeting2.id)
        XCTAssertEqual(m2After[0].speakerLabel, "Alice", "Segment in other meeting should not be affected")

        let m1After = try await meetingRepo.segments(for: meeting1.id)
        XCTAssertEqual(m1After[0].speakerLabel, "Alice", "M1 segment should not be affected either")
    }

    // MARK: - ViewModel selection state

    func testClearSelection_emptiesSet() async {
        let vm = await MeetingDetailViewModel()
        await MainActor.run {
            vm.selectedSegmentIds = [1, 2, 3]
            vm.clearSelection()
            XCTAssertTrue(vm.selectedSegmentIds.isEmpty)
        }
    }
}

import XCTest

final class MicLinkingTests: XCTestCase {

    // MARK: - linkMicSegmentsToSpeaker

    func testLinkMicSegmentsToSpeaker_updatesAllMeSegments() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let meSpeaker = makeSpeaker(name: "Захар", isMe: true)
        try await speakerRepo.save(meSpeaker)

        // Save mic segments with label "me" and no speakerId
        let seg1 = makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 0, endTime: 5)
        let seg2 = makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 5, endTime: 10)
        let seg3 = makeSegment(meetingId: meeting.id, speakerLabel: "speaker_1", source: .system, startTime: 0, endTime: 10)
        try await meetingRepo.saveSegments([seg1, seg2, seg3])

        // Act
        try await meetingRepo.linkMicSegmentsToSpeaker(
            meetingId: meeting.id,
            speakerId: meSpeaker.id,
            speakerLabel: "Захар"
        )

        // Assert
        let segments = try await meetingRepo.segments(for: meeting.id)
        let micSegments = segments.filter { $0.source == .mic }
        let systemSegments = segments.filter { $0.source == .system }

        XCTAssertEqual(micSegments.count, 2)
        for seg in micSegments {
            XCTAssertEqual(seg.speakerId, meSpeaker.id, "Mic segment should be linked to isMe speaker")
            XCTAssertEqual(seg.speakerLabel, "Захар", "Mic segment label should be updated")
        }

        // System segment should not be affected
        XCTAssertEqual(systemSegments.count, 1)
        XCTAssertNil(systemSegments[0].speakerId, "System segment should not be changed")
        XCTAssertEqual(systemSegments[0].speakerLabel, "speaker_1")
    }

    func testLinkMicSegments_noMeSegments_noop() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let speaker = makeSpeaker(name: "Someone")
        try await speakerRepo.save(speaker)

        let seg = makeSegment(meetingId: meeting.id, speakerLabel: "speaker_1", source: .system)
        try await meetingRepo.saveSegments([seg])

        // Should not throw or change anything
        try await meetingRepo.linkMicSegmentsToSpeaker(
            meetingId: meeting.id,
            speakerId: speaker.id,
            speakerLabel: "Someone"
        )

        let segments = try await meetingRepo.segments(for: meeting.id)
        XCTAssertEqual(segments[0].speakerLabel, "speaker_1", "Non-me segments should not be changed")
    }

    // MARK: - segmentsWithSource

    func testSegmentsWithSource_filtersBySource() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let micSeg = makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 0, endTime: 5)
        let sysSeg = makeSegment(meetingId: meeting.id, speakerLabel: "speaker_1", source: .system, startTime: 0, endTime: 5)
        try await meetingRepo.saveSegments([micSeg, sysSeg])

        let micOnly = try await meetingRepo.segmentsWithSource(meetingId: meeting.id, source: .mic)
        XCTAssertEqual(micOnly.count, 1)
        XCTAssertEqual(micOnly[0].speakerLabel, "me")

        let sysOnly = try await meetingRepo.segmentsWithSource(meetingId: meeting.id, source: .system)
        XCTAssertEqual(sysOnly.count, 1)
        XCTAssertEqual(sysOnly[0].speakerLabel, "speaker_1")
    }

    // MARK: - Foreign-voice decision (foreign-voices-on-mic, решение 6)

    /// The decision is a meeting property that can be flipped after recording,
    /// and it takes effect without a reprocess — it governs display, not
    /// recognition.
    func testForeignVoiceDecisionFlipsAfterRecording() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        let before = try await meetingRepo.find(meeting.id)?.foreignVoiceDecision
        XCTAssertEqual(before, .undecided, "по умолчанию — не решено")

        try await meetingRepo.updateForeignVoiceDecision(meeting.id, .kept)
        let after = try await meetingRepo.find(meeting.id)?.foreignVoiceDecision
        XCTAssertEqual(after, .kept)
    }

    // MARK: - updateSegmentSpeaker

    func testUpdateSegmentSpeaker_updatesSingleSegment() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let speaker = makeSpeaker(name: "Борис")
        try await speakerRepo.save(speaker)

        let seg1 = makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 0, endTime: 5)
        let seg2 = makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 5, endTime: 10)
        try await meetingRepo.saveSegments([seg1, seg2])

        let segments = try await meetingRepo.segments(for: meeting.id)
        let firstId = segments[0].id!

        try await meetingRepo.updateSegmentSpeaker(
            segmentId: firstId,
            speakerId: speaker.id,
            speakerLabel: "Борис",
            embedding: nil
        )

        let updated = try await meetingRepo.segments(for: meeting.id)
        let first = updated.first { $0.id == firstId }!
        let second = updated.first { $0.id != firstId }!

        XCTAssertEqual(first.speakerId, speaker.id)
        XCTAssertEqual(first.speakerLabel, "Борис")
        XCTAssertEqual(second.speakerLabel, "me", "Other segment should not be affected")
    }
}

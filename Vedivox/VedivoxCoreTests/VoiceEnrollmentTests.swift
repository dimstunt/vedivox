import GRDB
import XCTest

/// owner-voice-enrollment: pinning the enrollment meeting to "me", the
/// replace-previous semantics, and the identity invariant on a foreign voice.
final class VoiceEnrollmentTests: XCTestCase {
    private var db: DatabaseManager!
    private var meetingRepo: MeetingRepository!
    private var speakerRepo: SpeakerRepository!

    private let dim = 256

    override func setUp() async throws {
        db = try makeTestDB()
        meetingRepo = MeetingRepository(db: db)
        speakerRepo = SpeakerRepository(db: db)
    }

    private func axisVector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        return v
    }

    /// An "enrollment" meeting: offline space, one anonymous diarized voice,
    /// 10 × 2.5s segments carrying the given embedding (25s clears the 10s
    /// canonical floor).
    private func makeEnrollmentMeeting(axis: Int) async throws -> (Meeting, Speaker) {
        var meeting = makeMeeting(title: VoiceEnrollment.meetingTitle)
        meeting.diarizer = "offline"
        try await meetingRepo.save(meeting)

        let anon = makeSpeaker(name: "speaker_1")
        try await speakerRepo.save(anon)
        try await speakerRepo.assignSpeakerToMeeting(
            meetingId: meeting.id, speakerId: anon.id, diarizationLabel: "SPEAKER_00"
        )

        let embedding = Speaker.encodeEmbedding(axisVector(axis))
        var segments: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_1",
                startTime: Double(i) * 2.5, endTime: Double(i) * 2.5 + 2.5,
                text: "enrollment take"
            )
            seg.embedding = embedding
            segments.append(seg)
        }
        try await meetingRepo.saveSegments(segments)
        return (meeting, anon)
    }

    private func canonicalV2(of speakerId: String) async throws -> [Float]? {
        try await db.reader.read { db in
            let data: Data? = try Data.fetchOne(
                db, sql: "SELECT embeddingV2 FROM speakers WHERE id = ?", arguments: [speakerId]
            ) ?? nil
            return data.map { Speaker.decodeEmbedding($0) }
        }
    }

    /// Сценарий «Первый запуск на пустой базе»: claim mints "me", pins the
    /// segments, and the v2 canonical is built from the recording.
    func testClaimCreatesMeAndBuildsCanonOnEmptyBase() async throws {
        let (meeting, anon) = try await makeEnrollmentMeeting(axis: 0)

        try await VoiceEnrollment.claimSegmentsForMe(
            meetingId: meeting.id, meetingRepo: meetingRepo, speakerRepo: speakerRepo
        )

        let me = try await speakerRepo.findMe()
        XCTAssertNotNil(me, "claim must mint a 'me' record on a fresh base")
        XCTAssertTrue(me!.isConfirmed)

        let rows: [(String?, String?)] = try await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT speakerId, speakerLabel FROM transcript_segments WHERE meetingId = ?
                """, arguments: [meeting.id]).map { ($0["speakerId"], $0["speakerLabel"]) }
        }
        XCTAssertEqual(rows.count, 10)
        for (speakerId, label) in rows {
            XCTAssertEqual(speakerId, me!.id, "every segment belongs to me")
            XCTAssertEqual(label, me!.displayName)
        }

        let canon = try await canonicalV2(of: me!.id)
        XCTAssertNotNil(canon, "v2 canonical must be built from the recording")
        XCTAssertGreaterThan(canon![0], 0.9, "canonical points at the recorded voice")

        // The anonymous per-meeting record lost its segments and association.
        let anonAlive = try await speakerRepo.find(anon.id)
        let anonMeetings = try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_speakers WHERE speakerId = ?",
                             arguments: [anon.id]) ?? 0
        }
        XCTAssertTrue(anonAlive == nil || anonMeetings == 0)
    }

    /// Сценарий «Повторная запись»: the previous enrollment meeting dies with
    /// its segments, and the canonical follows the new take only.
    func testRepeatRecordingReplacesPrevious() async throws {
        let (first, _) = try await makeEnrollmentMeeting(axis: 0)
        try await VoiceEnrollment.claimSegmentsForMe(
            meetingId: first.id, meetingRepo: meetingRepo, speakerRepo: speakerRepo
        )
        let canonAfterFirst = try await canonicalV2(of: (try await speakerRepo.findMe())!.id)
        XCTAssertGreaterThan(canonAfterFirst![0], 0.9)

        // Replace: delete the old take, record a new one (different voice axis
        // stands in for a fresh recording), claim again.
        try await VoiceEnrollment.deleteEnrollmentMeeting(first.id, meetingRepo: meetingRepo)
        let (second, _) = try await makeEnrollmentMeeting(axis: 1)
        try await VoiceEnrollment.claimSegmentsForMe(
            meetingId: second.id, meetingRepo: meetingRepo, speakerRepo: speakerRepo
        )

        let firstGone = try await meetingRepo.find(first.id)
        XCTAssertNil(firstGone, "previous enrollment meeting must be deleted")
        let firstSegments = try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE meetingId = ?",
                             arguments: [first.id]) ?? 0
        }
        XCTAssertEqual(firstSegments, 0, "its segments die with it")

        let me = try await speakerRepo.findMe()!
        let canon = try await canonicalV2(of: me.id)!
        XCTAssertGreaterThan(canon[1], 0.9, "canonical follows the new take")
        XCTAssertLessThan(canon[0], 0.1, "old take no longer contributes")
    }

    /// Сценарий «Чужой голос в записи»: the recalc collides with another
    /// confirmed speaker's canonical and refuses the update — "me" keeps no
    /// canonical, the neighbor keeps theirs.
    func testForeignVoiceInRecordingKeepsCanonicalsIntact() async throws {
        // Alice is a real confirmed speaker: her own offline meeting with
        // segments builds her v2 canonical through the standard recalc.
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        try await speakerRepo.save(alice)
        var aliceMeeting = makeMeeting(title: "Alice call")
        aliceMeeting.diarizer = "offline"
        try await meetingRepo.save(aliceMeeting)
        try await speakerRepo.assignSpeakerToMeeting(
            meetingId: aliceMeeting.id, speakerId: alice.id, diarizationLabel: "SPEAKER_00"
        )
        let aliceEmbedding = Speaker.encodeEmbedding(axisVector(0))
        var aliceSegments: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: aliceMeeting.id, speakerId: alice.id, speakerLabel: "Alice",
                startTime: Double(i) * 2.5, endTime: Double(i) * 2.5 + 2.5
            )
            seg.embedding = aliceEmbedding
            aliceSegments.append(seg)
        }
        try await meetingRepo.saveSegments(aliceSegments)
        try await speakerRepo.recalculateEmbedding(speakerId: alice.id)
        let alicePrecondition = try await canonicalV2(of: alice.id)
        XCTAssertNotNil(alicePrecondition, "precondition: Alice has a v2 canonical")

        // The "enrollment" recording is actually Alice's voice.
        let (meeting, _) = try await makeEnrollmentMeeting(axis: 0)
        try await VoiceEnrollment.claimSegmentsForMe(
            meetingId: meeting.id, meetingRepo: meetingRepo, speakerRepo: speakerRepo
        )

        let me = try await speakerRepo.findMe()!
        let meCanon = try await canonicalV2(of: me.id)
        XCTAssertNil(meCanon, "identity invariant must reject the colliding canonical")

        let aliceAfter = try await canonicalV2(of: alice.id)!
        XCTAssertGreaterThan(aliceAfter[0], 0.9, "Alice's canonical is untouched")
    }
}

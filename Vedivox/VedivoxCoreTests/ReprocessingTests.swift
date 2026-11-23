import XCTest
import GRDB

/// Tests that verify reprocessing correctly cleans up old speakers via
/// `MeetingRepository.deleteSegmentsAndSpeakers(for:)`.
final class ReprocessingTests: XCTestCase {

    private var db: DatabaseManager!
    private var meetingRepo: MeetingRepository!
    private var speakerRepo: SpeakerRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        meetingRepo = MeetingRepository(db: db)
        speakerRepo = SpeakerRepository(db: db)
    }

    // MARK: - Import Reprocessing

    /// The pipeline's own speaker step over the saved segments: links only the
    /// labels that actually appear in them, never the raw diarization output.
    private func runPipelineSpeakerStep(meetingId: String) async throws {
        let segments = try await meetingRepo.segments(for: meetingId)
        try await TranscriptionPipeline(db: db).createSpeakersFromDiarization(
            segments, meetingId: meetingId, speakerEmbeddings: [:], labelToDbId: [:]
        )
    }

    /// Simulates what processImportedFile does for segments: saves transcript segments
    /// with speaker labels from diarization.
    private func simulateImportSegments(
        meetingId: String,
        speakerLabels: [String]
    ) async throws {
        var time: Double = 0
        for label in speakerLabels {
            let seg = makeSegment(
                meetingId: meetingId,
                speakerLabel: label,
                source: .import,
                startTime: time,
                endTime: time + 5,
                text: "Text from \(label)"
            )
            try await meetingRepo.saveSegments([seg])
            time += 5
        }
    }

    /// Reprocessing an import cleans up old speakers and produces exactly the right count.
    func testImportReprocess_noDuplicateSpeakers() async throws {
        let meeting = makeMeeting(title: "Imported Meeting", status: .done)
        try await meetingRepo.save(meeting)

        // --- First import processing ---
        try await simulateImportSegments(meetingId: meeting.id, speakerLabels: ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
        try await runPipelineSpeakerStep(meetingId: meeting.id)

        let speakersAfterFirst = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakersAfterFirst.count, 2, "First process: 2 speakers")

        // --- Reprocess: atomic cleanup of segments + speakers ---
        try await meetingRepo.deleteSegmentsAndSpeakers(for: meeting.id)

        let segmentsAfterDelete = try await meetingRepo.segments(for: meeting.id)
        XCTAssertTrue(segmentsAfterDelete.isEmpty)

        let speakersAfterCleanup = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertTrue(speakersAfterCleanup.isEmpty, "meeting_speakers cleaned up")

        let allSpeakersAfterCleanup = try await speakerRepo.all()
        XCTAssertTrue(allSpeakersAfterCleanup.isEmpty, "Orphaned speakers deleted")

        // --- Second processing creates fresh speakers ---
        try await simulateImportSegments(meetingId: meeting.id, speakerLabels: ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
        try await runPipelineSpeakerStep(meetingId: meeting.id)

        let speakersAfterSecond = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakersAfterSecond.count, 2, "Exactly 2 speakers after reprocess")

        let allSpeakersAfterSecond = try await speakerRepo.all()
        XCTAssertEqual(allSpeakersAfterSecond.count, 2, "Only 2 speaker records total")
    }

    // MARK: - Recording Reprocessing

    /// Reprocessing a recording cleans up old meeting_speakers links and orphan speakers.
    func testRecordingReprocess_oldMeetingSpeakersCleaned() async throws {
        let meeting = makeMeeting(title: "Recorded Meeting", status: .done)
        try await meetingRepo.save(meeting)

        // User manually assigned speakers after first recording
        let alice = makeSpeaker(name: "Alice")
        let bob = makeSpeaker(name: "Bob")
        try await speakerRepo.save(alice)
        try await speakerRepo.save(bob)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: alice.id, diarizationLabel: "SPEAKER_00")
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: bob.id, diarizationLabel: "SPEAKER_01")

        // Save segments with speaker references
        let seg1 = makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "Hello")
        let seg2 = makeSegment(meetingId: meeting.id, speakerId: bob.id, speakerLabel: "Bob", startTime: 5, endTime: 10, text: "Hi")
        try await meetingRepo.saveSegments([seg1, seg2])

        // --- Reprocess: atomic cleanup ---
        try await meetingRepo.deleteSegmentsAndSpeakers(for: meeting.id)

        // Old meeting_speakers are cleaned up
        let speakers = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertTrue(speakers.isEmpty, "Old meeting_speakers links cleaned up")

        // Orphan speakers deleted
        let allSpeakers = try await speakerRepo.all()
        XCTAssertTrue(allSpeakers.isEmpty, "Orphan speakers deleted")

        // New segments from re-transcription have raw diarization labels
        let newSeg1 = makeSegment(meetingId: meeting.id, speakerLabel: "SPEAKER_00", source: .system, startTime: 0, endTime: 5, text: "Hello again")
        let newSeg2 = makeSegment(meetingId: meeting.id, speakerLabel: "SPEAKER_01", source: .system, startTime: 5, endTime: 10, text: "Hi again")
        try await meetingRepo.saveSegments([newSeg1, newSeg2])

        let segments = try await meetingRepo.segments(for: meeting.id)
        XCTAssertTrue(segments.allSatisfy { $0.speakerId == nil },
                      "New segments have no speakerId — fresh diarization labels")
    }

    // MARK: - Reprocessing preserves speakers shared across meetings

    /// When a speaker is linked to multiple meetings, reprocessing one meeting
    /// should not delete the speaker — only the meeting_speakers link for that meeting.
    func testReprocess_preservesSpeakerUsedInOtherMeetings() async throws {
        let m1 = makeMeeting(title: "Meeting 1")
        let m2 = makeMeeting(title: "Meeting 2")
        try await meetingRepo.save(m1)
        try await meetingRepo.save(m2)

        // Alice is in both meetings
        let alice = makeSpeaker(name: "Alice")
        try await speakerRepo.save(alice)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: m1.id, speakerId: alice.id, diarizationLabel: nil)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: m2.id, speakerId: alice.id, diarizationLabel: nil)

        // Reprocess m1 using the new atomic method
        try await meetingRepo.deleteSegmentsAndSpeakers(for: m1.id)

        // Alice should NOT be deleted — she's still in m2
        let info = try await speakerRepo.speakersWithMeetingCounts()
        let aliceInfo = info.first(where: { $0.speaker.id == alice.id })
        XCTAssertNotNil(aliceInfo, "Alice should still exist")
        XCTAssertEqual(aliceInfo?.meetingCount, 1, "Alice linked to 1 remaining meeting")

        // m2 still has Alice
        let m2Speakers = try await speakerRepo.speakersForMeeting(m2.id)
        XCTAssertEqual(m2Speakers.count, 1)
        XCTAssertEqual(m2Speakers[0].speaker.id, alice.id)
    }

    // MARK: - Reprocessing with user-renamed speakers

    /// When a user renamed "SPEAKER_00" → "Alice" and then reprocesses,
    /// the old renamed speakers are cleaned up and only fresh ones remain.
    func testImportReprocess_userRenamedSpeakersCleanedUp() async throws {
        let meeting = makeMeeting(title: "Meeting", status: .done)
        try await meetingRepo.save(meeting)

        // First processing
        try await simulateImportSegments(meetingId: meeting.id, speakerLabels: ["SPEAKER_00", "SPEAKER_01"])
        try await runPipelineSpeakerStep(meetingId: meeting.id)

        // User renames speakers
        let speakers = try await speakerRepo.speakersForMeeting(meeting.id)
        let sp0 = speakers.first(where: { $0.label == "SPEAKER_00" })!.speaker
        let sp1 = speakers.first(where: { $0.label == "SPEAKER_01" })!.speaker
        try await speakerRepo.rename(sp0.id, name: "Alice")
        try await speakerRepo.rename(sp1.id, name: "Bob")

        // Reprocess with atomic cleanup
        try await meetingRepo.deleteSegmentsAndSpeakers(for: meeting.id)
        try await simulateImportSegments(meetingId: meeting.id, speakerLabels: ["SPEAKER_00", "SPEAKER_01"])
        try await runPipelineSpeakerStep(meetingId: meeting.id)

        let allSpeakers = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertEqual(allSpeakers.count, 2, "Exactly 2 speakers — no stale renamed ones")

        let names = Set(allSpeakers.map(\.speaker.nameEn))
        XCTAssertEqual(names, ["SPEAKER_00", "SPEAKER_01"],
                       "Only fresh diarization labels, renamed speakers cleaned up")
    }

    /// A speaker the user named (confirmed) or `isMe`, present only in this
    /// meeting, survives reprocess — only its link goes. An unconfirmed
    /// `speaker_N` next to it is still cleaned up.
    func testReprocess_keepsConfirmedAndMeSpeakers() async throws {
        let meeting = makeMeeting(title: "Meeting", status: .done)
        try await meetingRepo.save(meeting)

        let named = makeSpeaker(name: "Alice")
        let me = makeSpeaker(name: "Me", isMe: true)
        let auto = makeSpeaker(name: "speaker_3")
        for speaker in [named, me, auto] {
            try await speakerRepo.save(speaker)
            try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: speaker.id, diarizationLabel: speaker.nameEn)
        }
        try await speakerRepo.confirmSpeaker(named.id)

        try await meetingRepo.deleteSegmentsAndSpeakers(for: meeting.id)

        let remaining = Set(try await speakerRepo.all().map(\.id))
        XCTAssertEqual(remaining, [named.id, me.id], "Confirmed and isMe kept, unconfirmed speaker_N deleted")
        let links = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertTrue(links.isEmpty, "Links are still cleared")
    }

    // MARK: - Verdicts survive reprocess (listen-queue 2.2–2.3)

    private func confirmed(_ name: String) async throws -> Speaker {
        let speaker = Speaker(nameEn: name, isConfirmed: true)
        try await speakerRepo.save(speaker)
        return speaker
    }

    /// The pipeline's output after a pass: fresh segments under a fresh
    /// anonymous row, linked to the meeting the way the pipeline links them.
    private func simulatePass(meetingId: String, owner: Speaker, bounds: [(Double, Double)]) async throws {
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meetingId, speakerId: owner.id, diarizationLabel: owner.nameEn)
        try await meetingRepo.saveSegments(bounds.map {
            makeSegment(meetingId: meetingId, speakerId: owner.id, speakerLabel: owner.nameEn,
                        source: .system, startTime: $0.0, endTime: $0.1)
        })
    }

    /// 2.2: a verdict over an anonymous row's interval hands its segments to
    /// the target, the emptied anonymous row is gone, the target is linked.
    func testApplyVerdicts_movesAnonymousSegmentsToTarget() async throws {
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let alice = try await confirmed("Alice")
        let anon = makeSpeaker(name: "speaker_4")
        try await speakerRepo.save(anon)
        try await simulatePass(meetingId: meeting.id, owner: anon, bounds: [(0, 10), (10, 20)])
        let marks = MarkRepository(db: db)
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 20, track: .system,
                                        kind: .speaker, speakerId: alice.id))

        let result = try await marks.applyVerdicts(meetingId: meeting.id)

        let owners = Set(try await meetingRepo.segments(for: meeting.id).map(\.speakerId))
        XCTAssertEqual(owners, [alice.id])
        let anonLeft = try await speakerRepo.find(anon.id)
        XCTAssertNil(anonLeft, "анонимная запись без реплик удалена")
        let linked = try await speakerRepo.speakersForMeeting(meeting.id).map(\.speaker.id)
        XCTAssertEqual(linked, [alice.id])
        XCTAssertEqual(result.segments, 2)
        XCTAssertEqual(result.overrode, 2)
        XCTAssertEqual(result.fromConfirmed, 0)
        XCTAssertEqual(result.matchedNothing, 0)
    }

    /// 2.3, the whole loop: verdict → reprocess wipes the segments → a new pass
    /// with other boundaries and anonymous attribution → verdicts re-applied.
    func testReprocess_verdictSurvivesNewSegmentation() async throws {
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let alice = try await confirmed("Alice")
        let anon1 = makeSpeaker(name: "speaker_1")
        try await speakerRepo.save(anon1)
        try await simulatePass(meetingId: meeting.id, owner: anon1, bounds: [(0, 10), (10, 20), (30, 40)])
        let marks = MarkRepository(db: db)
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 20, track: .system,
                                        kind: .speaker, speakerId: alice.id))

        try await meetingRepo.deleteSegmentsAndSpeakers(for: meeting.id)
        let anon2 = makeSpeaker(name: "speaker_2")
        try await speakerRepo.save(anon2)
        try await simulatePass(meetingId: meeting.id, owner: anon2, bounds: [(0, 7), (7, 18), (18, 26), (30, 40)])
        try await marks.applyVerdicts(meetingId: meeting.id)

        let byStart = Dictionary(uniqueKeysWithValues: try await meetingRepo.segments(for: meeting.id).map { ($0.startTime, $0.speakerId) })
        XCTAssertEqual(byStart[0], alice.id)
        XCTAssertEqual(byStart[7], alice.id)
        XCTAssertEqual(byStart[18], anon2.id, "вердикт покрывает 2 с из 8 — реплика остаётся у пайплайна")
        XCTAssertEqual(byStart[30], anon2.id)
    }

    /// verdicts made over the old merged transcript carry
    /// track=merged; the reprocessed meeting has mic and system lines only, and
    /// they used to match nothing. The owner's go to the mic, anyone else's to
    /// the call track — crosstalk on the other track stays with the pipeline.
    func testReprocess_mergedVerdictsGoToTheTrackOfTheirSpeaker() async throws {
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let owner = Speaker(nameEn: "Owner", isMe: true, isConfirmed: true)
        try await speakerRepo.save(owner)
        let alice = try await confirmed("Alice")
        let micAnon = makeSpeaker(name: "speaker_1")
        let callAnon = makeSpeaker(name: "speaker_2")
        try await speakerRepo.save(micAnon)
        try await speakerRepo.save(callAnon)
        let marks = MarkRepository(db: db)
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 20, track: .merged,
                                        kind: .speaker, speakerId: owner.id))
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 30, endTime: 40, track: .merged,
                                        kind: .speaker, speakerId: alice.id))
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: micAnon.id, source: .mic, startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: callAnon.id, source: .system, startTime: 5, endTime: 15),
            makeSegment(meetingId: meeting.id, speakerId: micAnon.id, source: .mic, startTime: 31, endTime: 35),
            makeSegment(meetingId: meeting.id, speakerId: callAnon.id, source: .system, startTime: 30, endTime: 40),
        ])

        let result = try await marks.applyVerdicts(meetingId: meeting.id)

        let byTrack = Dictionary(uniqueKeysWithValues: try await meetingRepo.segments(for: meeting.id)
            .map { ("\($0.source.rawValue)@\(Int($0.startTime))", $0.speakerId) })
        XCTAssertEqual(byTrack["mic@0"], owner.id)
        XCTAssertEqual(byTrack["system@5"], callAnon.id, "the owner's verdict does not take the call track")
        XCTAssertEqual(byTrack["system@30"], alice.id)
        XCTAssertEqual(byTrack["mic@31"], micAnon.id, "a remote speaker's verdict does not take the mic")
        XCTAssertEqual(result.matchedNothing, 0)
    }

    /// A meeting still on the merged transcript keeps matching its merged
    /// verdicts as they are.
    func testApplyVerdicts_mergedVerdictStillMatchesMergedLines() async throws {
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let alice = try await confirmed("Alice")
        let anon = makeSpeaker(name: "speaker_1")
        try await speakerRepo.save(anon)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: anon.id, source: .merged, startTime: 0, endTime: 10),
        ])
        let marks = MarkRepository(db: db)
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 10, track: .merged,
                                        kind: .speaker, speakerId: alice.id))

        try await marks.applyVerdicts(meetingId: meeting.id)

        let owners = try await meetingRepo.segments(for: meeting.id).map(\.speakerId)
        XCTAssertEqual(owners, [alice.id])
    }

    /// The pipeline confidently named another confirmed speaker: the verdict
    /// still wins, and the result counts the overridden confirmed seconds.
    func testApplyVerdicts_beatsAConfirmedMatch_andCountsIt() async throws {
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let alice = try await confirmed("Alice")
        let other = try await confirmed("Dana")
        try await simulatePass(meetingId: meeting.id, owner: other, bounds: [(0, 10)])
        let marks = MarkRepository(db: db)
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 10, track: .system,
                                        kind: .speaker, speakerId: alice.id))
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 100, endTime: 110, track: .system,
                                        kind: .speaker, speakerId: alice.id))

        let result = try await marks.applyVerdicts(meetingId: meeting.id)

        let owners = try await meetingRepo.segments(for: meeting.id).map(\.speakerId)
        XCTAssertEqual(owners, [alice.id])
        XCTAssertEqual(result.fromConfirmed, 1)
        XCTAssertEqual(result.fromConfirmedSeconds, 10)
        XCTAssertEqual(result.matchedNothing, 1)
        let otherKept = try await speakerRepo.find(other.id)
        XCTAssertNotNil(otherKept, "подтверждённый остаётся, даже потеряв реплики")
    }

    /// A verdict's speaker with no segments anywhere is between passes, not an
    /// orphan: the global sweep must not delete it (and its verdicts with it).
    func testOrphanSweep_keepsASpeakerNamedByAVerdict() async throws {
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let lonely = makeSpeaker(name: "Lonely")
        try await speakerRepo.save(lonely)
        try await MarkRepository(db: db).add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 10,
                                                         track: .system, kind: .speaker, speakerId: lonely.id))

        try await speakerRepo.cleanupOrphanedMeetingSpeakers(meetingId: meeting.id)

        let kept = try await speakerRepo.find(lonely.id)
        XCTAssertNotNil(kept)
    }

    // MARK: - Phantom Speaker Filtering

    /// Diarization returns 10 labels but only 2 appear in final segments — no phantoms created.
    func testImportProcess_noPhantomSpeakers() async throws {
        let meeting = makeMeeting(title: "Phantom Test", status: .done)
        try await meetingRepo.save(meeting)

        // Segments only reference S2 and S5 (out of 10 diarization labels)
        try await simulateImportSegments(
            meetingId: meeting.id,
            speakerLabels: ["S2", "S5", "S2", "S5", "S2"]
        )

        // Speaker creation uses segment labels, not raw diarization
        try await runPipelineSpeakerStep(meetingId: meeting.id)

        let speakers = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakers.count, 2, "Only 2 speakers created — S2 and S5")

        let names = Set(speakers.map(\.speaker.nameEn))
        XCTAssertEqual(names, ["S2", "S5"], "No phantom speakers S1, S3, S4, S6-S10")

        let allSpeakers = try await speakerRepo.all()
        XCTAssertEqual(allSpeakers.count, 2, "Only 2 speaker records total")
    }

    /// Two-stream creates speakers from merged segments, skipping "me".
    func testTwoStreamProcess_createsSpeakers() async throws {
        let meeting = makeMeeting(title: "Two-Stream Test", status: .done)
        try await meetingRepo.save(meeting)

        // Simulate merged segments from two-stream: "me" from mic, "S1"/"S2" from system
        let segments = [
            makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 0, endTime: 5, text: "My words"),
            makeSegment(meetingId: meeting.id, speakerLabel: "S1", source: .system, startTime: 1, endTime: 6, text: "Speaker 1"),
            makeSegment(meetingId: meeting.id, speakerLabel: "S2", source: .system, startTime: 6, endTime: 11, text: "Speaker 2"),
            makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic, startTime: 7, endTime: 12, text: "More of me"),
        ]
        try await meetingRepo.saveSegments(segments)

        try await runPipelineSpeakerStep(meetingId: meeting.id)

        let speakers = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakers.count, 2, "S1 and S2 created")

        let names = Set(speakers.map(\.speaker.nameEn))
        XCTAssertEqual(names, ["S1", "S2"], "Only S1 and S2 — not 'me'")
    }

    // MARK: - The old transcript goes only when the new one arrives

    /// a pass that fails mid-pipeline (here the ASR step) leaves the
    /// meeting in `.error`, rethrows, and keeps the previous transcript.
    func testProcessMeeting_failedPassMarksErrorAndKeepsOldTranscript() async throws {
        let mic = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_mic_30s", withExtension: "wav"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        try await meetingRepo.saveSegments([makeSegment(meetingId: meeting.id, speakerLabel: "me", source: .mic,
                                                        startTime: 0, endTime: 5, text: "old")])
        let pipeline = TranscriptionPipeline(db: db, audioRoot: root, compressAudio: false, skipWarmUp: true)

        do {
            try await pipeline.processMeeting(meetingId: meeting.id, micAudioURL: mic)
            XCTFail("an unloaded ASR must fail the pass")
        } catch {}

        let status = try await meetingRepo.find(meeting.id)?.status
        XCTAssertEqual(status, .error)
        let texts = try await meetingRepo.segments(for: meeting.id).map(\.text)
        XCTAssertEqual(texts, ["old"], "a failed pass must not touch the old transcript")
    }

    /// A track that cannot be read fails the pass the same way.
    func testProcessMeeting_unreadableAudioMarksError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = makeMeeting(status: .done)
        try await meetingRepo.save(meeting)
        let pipeline = TranscriptionPipeline(db: db, audioRoot: root, compressAudio: false, skipWarmUp: true)

        do {
            try await pipeline.processMeeting(meetingId: meeting.id, micAudioURL: root.appendingPathComponent("missing.wav"))
            XCTFail("a missing track must fail the pass")
        } catch {}

        let status = try await meetingRepo.find(meeting.id)?.status
        XCTAssertEqual(status, .error)
    }


    /// An old transcript with one anonymous speaker of its own and one named person.
    private func makeProcessedMeeting() async throws -> (meeting: Meeting, anonymous: Speaker, named: Speaker) {
        let meeting = makeMeeting(title: "Processed", status: .done)
        try await meetingRepo.save(meeting)
        let anonymous = makeSpeaker(name: "speaker_1")
        let named = makeSpeaker(name: "Alice")
        for speaker in [anonymous, named] {
            try await speakerRepo.save(speaker)
            try await speakerRepo.assignSpeakerToMeeting(
                meetingId: meeting.id, speakerId: speaker.id, diarizationLabel: speaker.nameEn
            )
        }
        try await speakerRepo.confirmSpeaker(named.id)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: anonymous.id, speakerLabel: "speaker_1", text: "old one"),
            makeSegment(meetingId: meeting.id, speakerId: named.id, speakerLabel: "Alice", startTime: 5, endTime: 9, text: "old two, edited by hand"),
        ])
        return (meeting, anonymous, named)
    }

    func testReplaceSegments_swapsTheOldTranscriptForTheNew() async throws {
        let (meeting, anonymous, named) = try await makeProcessedMeeting()

        try await meetingRepo.replaceSegments(for: meeting.id, with: [
            makeSegment(meetingId: meeting.id, speakerLabel: "SPEAKER_00", text: "new"),
        ])

        let texts = try await meetingRepo.segments(for: meeting.id).map(\.text)
        XCTAssertEqual(texts, ["new"])
        let links = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertTrue(links.isEmpty, "the previous run's speaker links go with its segments")
        let anonymousAfter = try await speakerRepo.find(anonymous.id)
        let namedAfter = try await speakerRepo.find(named.id)
        XCTAssertNil(anonymousAfter, "an anonymous speaker nobody else has goes too")
        XCTAssertNotNil(namedAfter, "a named person outlives the meeting")
    }

    /// A reprocess that cannot save its result must leave the meeting as it
    /// was: it used to delete first, so any failure left the meeting empty.
    func testReplaceSegments_keepsTheOldTranscriptWhenTheNewOneCannotBeSaved() async throws {
        let (meeting, anonymous, _) = try await makeProcessedMeeting()

        do {
            try await meetingRepo.replaceSegments(for: meeting.id, with: [
                makeSegment(meetingId: meeting.id, speakerId: "no-such-speaker", text: "new"),
            ])
            XCTFail("a segment of a speaker that does not exist cannot be saved")
        } catch {}

        let texts = try await meetingRepo.segments(for: meeting.id).map(\.text)
        XCTAssertEqual(texts, ["old one", "old two, edited by hand"])
        let links = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertEqual(links.count, 2)
        let anonymousAfter = try await speakerRepo.find(anonymous.id)
        XCTAssertNotNil(anonymousAfter)
    }

    /// While a meeting is reprocessed its old segments are still there; they
    /// must not vouch for a speaker the new pass is about to match against.
    func testSegmentCounts_canLeaveOutTheMeetingBeingReprocessed() async throws {
        let (meeting, _, named) = try await makeProcessedMeeting()
        let other = makeMeeting(title: "Other", status: .done)
        try await meetingRepo.save(other)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: other.id, speakerId: named.id, speakerLabel: "Alice", text: "elsewhere"),
            makeSegment(meetingId: other.id, speakerId: named.id, speakerLabel: "Alice", startTime: 5, endTime: 9, text: "elsewhere too"),
        ])

        let all = try await speakerRepo.segmentCounts(for: [named.id])
        let withoutThisMeeting = try await speakerRepo.segmentCounts(for: [named.id], excludingMeeting: meeting.id)

        XCTAssertEqual(all[named.id], 3)
        XCTAssertEqual(withoutThisMeeting[named.id], 2)
    }

    /// A confirmed person whose every line sits in the meeting being
    /// reprocessed stays a candidate: dropped, their lines went anonymous for good.
    func testEnrolledCandidates_countTheLinesOfTheMeetingBeingReprocessed() async throws {
        let (meeting, _, named) = try await makeProcessedMeeting()
        let more = (0 ..< 5).map { n -> TranscriptSegment in
            let start = Double(20 + n * 5)
            return makeSegment(meetingId: meeting.id, speakerId: named.id, speakerLabel: "Alice",
                               startTime: start, endTime: start + 4, text: "more \(n)")
        }
        try await meetingRepo.saveSegments(more)
        let voice = Speaker.encodeEmbedding([Float](repeating: 0.1, count: 256))
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET embedding = ?, embeddingV2 = ? WHERE id = ?",
                           arguments: [voice, voice, named.id])
        }

        let pool = try await TranscriptionPipeline.enrolledCandidates(db: db)

        XCTAssertEqual(pool.first { $0.speakerId == named.id }?.segmentCount, 6)
    }
}

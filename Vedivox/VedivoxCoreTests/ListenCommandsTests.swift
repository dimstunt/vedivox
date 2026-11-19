import XCTest

/// The app side of `vedivox queue`, `segment set --from --to` and
/// `meeting pin-speakers` (listen-queue 6.1–6.3).
final class ListenCommandsTests: XCTestCase {

    private var db: DatabaseManager!
    private var meetingRepo: MeetingRepository!
    private var speakerRepo: SpeakerRepository!
    private var meeting: Meeting!
    private var anon: Speaker!
    private var alice: Speaker!

    override func setUp() async throws {
        db = try makeTestDB()
        meetingRepo = MeetingRepository(db: db)
        speakerRepo = SpeakerRepository(db: db)
        var canonical = [Float](repeating: 0, count: 256)
        canonical[0] = 1
        alice = Speaker(nameEn: "Alice", isConfirmed: true, embedding: Speaker.encodeEmbedding(canonical))
        try await speakerRepo.save(alice)
        meeting = makeMeeting(title: "ABC")
        try await meetingRepo.save(meeting)
        anon = makeSpeaker(name: "speaker_4")
        try await speakerRepo.save(anon)
        var voice = [Float](repeating: 0, count: 256)
        voice[0] = 0.8
        voice[1] = 0.6
        var lines: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var line = makeSegment(meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_4",
                                   source: .system, startTime: Double(i) * 20, endTime: Double(i) * 20 + 10,
                                   text: "line \(i)")
            line.embedding = Speaker.encodeEmbedding(voice)
            lines.append(line)
        }
        lines.append(makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice",
                                 source: .mic, startTime: 0, endTime: 30))
        try await meetingRepo.saveSegments(lines)
    }

    private func run(_ command: String, _ params: [String: String]) async -> AppCommandResponse {
        await ListenCommands.handle(AppCommandRequest(command: command, params: params), db: db)
    }

    func testList_snakeCaseRowsInQueueOrder() async throws {
        let response = await run(AppCommandName.listListenQueue, [:])
        XCTAssertTrue(response.ok, response.message)
        let json = try XCTUnwrap(response.data?["items"])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, "\(meeting.id):\(anon.id)")
        XCTAssertEqual(rows[0]["best_similarity"] as? Double, 0.8)
        XCTAssertEqual(rows[0]["speaker_label"] as? String, "speaker_4")
        let candidates = try XCTUnwrap(rows[0]["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.first?["speaker_id"] as? String, alice.id)
        XCTAssertNotNil(rows[0]["fragment"] as? [String: Any])
    }

    func testAssignVoice_movesEveryLine() async throws {
        let response = await run(AppCommandName.assignVoice,
                                 ["meeting_id": meeting.id, "speaker_id": anon.id, "target_speaker_id": alice.id])
        XCTAssertTrue(response.ok, response.message)
        XCTAssertTrue(response.message.contains("canonical"), "ответ называет исход пересчёта")
        let owners = Set(try await meetingRepo.segments(for: meeting.id).map(\.speakerId))
        XCTAssertEqual(owners, [alice.id])
    }

    func testAssignVoice_goneAfterReprocess_isNotFound() async throws {
        let response = await run(AppCommandName.assignVoice,
                                 ["meeting_id": meeting.id, "speaker_id": "gone", "name": "Ella"])
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.notFound.rawValue)
        let marks = try await MarkRepository(db: db).verdicts(for: meeting.id)
        XCTAssertTrue(marks.isEmpty, "ничего не изменилось")
    }

    func testAssignVoice_bothTargets_isInvalid() async {
        let response = await run(AppCommandName.assignVoice, [
            "meeting_id": meeting.id, "speaker_id": anon.id, "target_speaker_id": alice.id, "name": "X",
        ])
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
    }

    func testSkipVoice_hidesItFromTheQueue() async {
        let response = await run(AppCommandName.skipVoice, ["meeting_id": meeting.id, "speaker_id": anon.id])
        XCTAssertTrue(response.ok, response.message)
        let listed = await run(AppCommandName.listListenQueue, [:])
        XCTAssertEqual(listed.data?["items"], "[]")
        let skipped = await run(AppCommandName.listListenQueue, ["skipped": "1"])
        XCTAssertNotEqual(skipped.data?["items"], "[]")
    }

    /// 6.2: lines of the track covered ≥ 50 % go to the speaker; the verdict
    /// lies exactly on [from, to].
    func testAssignRange_coveredLinesAndExactVerdict() async throws {
        // Lines at 0–10, 20–30, 40–50: [5, 45] covers 50 %, 100 %, 50 %.
        let response = await run(AppCommandName.assignRange, [
            "meeting_id": meeting.id, "from": "5", "to": "45", "track": "system", "speaker_id": alice.id,
        ])
        XCTAssertTrue(response.ok, response.message)
        let moved = try await meetingRepo.segments(for: meeting.id)
            .filter { $0.source == .system && $0.speakerId == alice.id }.map(\.startTime)
        XCTAssertEqual(moved, [0, 20, 40])
        let marks = try await MarkRepository(db: db).verdicts(for: meeting.id)
        XCTAssertEqual(marks.map { [$0.startTime, $0.endTime ?? -1] }, [[5, 45]])
        XCTAssertEqual(marks.first?.track, .system)
    }

    func testAssignRange_toNotAfterFrom_isInvalid() async {
        let response = await run(AppCommandName.assignRange,
                                 ["meeting_id": meeting.id, "from": "10", "to": "10", "speaker_id": alice.id])
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
    }

    /// 6.3: a dry run writes nothing; a real one writes one pin per contiguous
    /// run of each confirmed speaker.
    func testPinSpeakers_dryRunThenPin() async throws {
        let dry = await run(AppCommandName.pinSpeakers, ["meeting_ids": meeting.id, "dry_run": "1"])
        XCTAssertTrue(dry.ok, dry.message)
        let none = try await MarkRepository(db: db).verdicts(for: meeting.id)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(dry.data?["pins"]?.contains("\"seconds\":30") ?? false, dry.data?["pins"] ?? "")

        _ = await run(AppCommandName.assignVoice,
                      ["meeting_id": meeting.id, "speaker_id": anon.id, "name": "Ella"])
        let pinned = await run(AppCommandName.pinSpeakers, ["meeting_ids": meeting.id])
        XCTAssertTrue(pinned.ok, pinned.message)
        let pins = try await MarkRepository(db: db).verdicts(for: meeting.id).filter { $0.source == .pin }
        // Alice: one mic run. Ella: ten separate system lines → ten runs.
        XCTAssertEqual(pins.filter { $0.speakerId == alice.id }.count, 1)
        XCTAssertEqual(pins.filter { $0.speakerId != alice.id }.count, 10)
    }

    func testPinSpeakers_unknownMeeting_isNotFound() async {
        let response = await run(AppCommandName.pinSpeakers, ["meeting_ids": "nope"])
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.notFound.rawValue)
    }
}

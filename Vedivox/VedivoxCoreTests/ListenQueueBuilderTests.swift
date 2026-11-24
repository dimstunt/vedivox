import XCTest

/// The «almost known» source of the listen queue (listen-queue 4.1–4.2).
final class ListenQueueBuilderTests: XCTestCase {

    private var db: DatabaseManager!
    private var meetingRepo: MeetingRepository!
    private var speakerRepo: SpeakerRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        meetingRepo = MeetingRepository(db: db)
        speakerRepo = SpeakerRepository(db: db)
    }

    /// A unit vector in `axis` tilted towards axis 0 so its cosine with e0 is `sim`.
    private func voice(sim: Float, axis: Int = 1) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[0] = sim
        v[axis] = (1 - sim * sim).squareRoot()
        return v
    }

    private func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    @discardableResult
    private func confirmed(_ name: String, v1: [Float]? = nil, v2: [Float]? = nil) async throws -> Speaker {
        var speaker = Speaker(nameEn: name, isConfirmed: true)
        speaker.embedding = v1.map(Speaker.encodeEmbedding)
        try await speakerRepo.save(speaker)
        if let v2 {
            // The model carries one space; v2 lives in its own column.
            let id = speaker.id
            try await db.writer.write { db in
                try db.execute(sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?",
                               arguments: [Speaker.encodeEmbedding(v2), id])
            }
        }
        return speaker
    }

    /// A meeting with one anonymous voice speaking `seconds` in 10-second lines.
    @discardableResult
    private func meetingWithAnon(
        seconds: Double, embedding: [Float], status: MeetingStatus = .done, diarizer: String? = nil,
        title: String = "M"
    ) async throws -> (Meeting, Speaker) {
        var meeting = makeMeeting(title: title, status: status)
        meeting.diarizer = diarizer
        try await meetingRepo.save(meeting)
        let anon = makeSpeaker(name: "speaker_4")
        try await speakerRepo.save(anon)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: anon.id, diarizationLabel: "speaker_4")
        var lines: [TranscriptSegment] = []
        var t = 0.0
        while t < seconds {
            var line = makeSegment(meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_4",
                                   source: .system, startTime: t, endTime: min(t + 10, seconds), text: "line \(Int(t))")
            line.embedding = Speaker.encodeEmbedding(embedding)
            lines.append(line)
            t += 20 // a 10-second pause between lines
        }
        try await meetingRepo.saveSegments(lines)
        return (meeting, anon)
    }

    // MARK: 4.1

    func testAlmostKnownVoice_isQueuedWithThatCandidateFirst() async throws {
        let alice = try await confirmed("Alice", v1: basis(0))
        try await confirmed("Carol", v1: basis(5))
        let (meeting, anon) = try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71))

        let queue = try await ListenQueueBuilder(db: db).build()

        XCTAssertEqual(queue.count, 1)
        let item = try XCTUnwrap(queue.first)
        XCTAssertEqual(item.members, [.init(meetingId: meeting.id, speakerId: anon.id)])
        XCTAssertEqual(item.candidates.first?.speakerId, alice.id)
        XCTAssertEqual(item.candidates.first?.similarity ?? 0, 0.71, accuracy: 0.001)
        XCTAssertEqual(item.seconds, 420, "7 минут речи: 42 строки по 10 с")
        XCTAssertEqual(item.reason, .almostKnown(bestSim: item.candidates[0].similarity))
        XCTAssertEqual(item.segmentIds.count, 42)
    }

    func testShortVoice_orUnlikeVoice_isNotQueued() async throws {
        try await confirmed("Alice", v1: basis(0))
        try await meetingWithAnon(seconds: 70, embedding: voice(sim: 0.71)) // 40 s of speech
        try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.5))

        let queue = try await ListenQueueBuilder(db: db).build()
        XCTAssertTrue(queue.isEmpty)
    }

    func testMeetingInProcessing_isNotQueued() async throws {
        try await confirmed("Alice", v1: basis(0))
        try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71), status: .transcribing)

        let queue = try await ListenQueueBuilder(db: db).build()
        XCTAssertTrue(queue.isEmpty)
    }

    func testSkippedVoice_staysHiddenAfterReprocess() async throws {
        try await confirmed("Alice", v1: basis(0))
        let (meeting, anon) = try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71))
        let item = try await ListenQueueBuilder(db: db).build().first!
        try await SpeakerVerdicts(db: db).skip(meetingId: meeting.id, segmentIds: item.segmentIds)

        // Reprocess: lines and the anonymous row are recreated with new ids.
        let old = try await meetingRepo.segments(for: meeting.id)
        try await meetingRepo.deleteSegmentsAndSpeakers(for: meeting.id)
        let fresh = makeSpeaker(name: "speaker_7")
        try await speakerRepo.save(fresh)
        try await meetingRepo.saveSegments(old.map {
            var line = $0
            line.id = nil
            line.speakerId = fresh.id
            line.speakerLabel = fresh.nameEn
            return line
        })
        let gone = try await speakerRepo.find(anon.id)
        XCTAssertNil(gone)

        let queue = try await ListenQueueBuilder(db: db).build()
        XCTAssertTrue(queue.isEmpty)
        let skipped = try await ListenQueueBuilder(db: db).build(skipped: true)
        XCTAssertEqual(skipped.map(\.members.first?.speakerId), [fresh.id])
        XCTAssertEqual(skipped.first?.isSkipped, true)
    }

    func testV1Meeting_comparesOnlyWithV1Canonicals() async throws {
        // Alice's v2 canonical matches the voice exactly, her v1 one does not.
        try await confirmed("Alice", v1: basis(9), v2: voice(sim: 0.71))
        try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71))

        let v1Queue = try await ListenQueueBuilder(db: db).build()
        XCTAssertTrue(v1Queue.isEmpty)

        try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71), diarizer: "offline")
        let queue = try await ListenQueueBuilder(db: db).build()
        XCTAssertEqual(queue.count, 1, "v2-встреча находит v2-слепок")
    }

    func testOrderedBySecondsDescending() async throws {
        try await confirmed("Alice", v1: basis(0))
        try await meetingWithAnon(seconds: 300, embedding: voice(sim: 0.7), title: "short")
        try await meetingWithAnon(seconds: 900, embedding: voice(sim: 0.7), title: "long")

        let titles = try await ListenQueueBuilder(db: db).build().map(\.meetingTitle)
        XCTAssertEqual(titles, ["long", "short"])
    }

    func testMeetingFilter() async throws {
        try await confirmed("Alice", v1: basis(0))
        let (wanted, _) = try await meetingWithAnon(seconds: 300, embedding: voice(sim: 0.7))
        try await meetingWithAnon(seconds: 900, embedding: voice(sim: 0.7))

        let queue = try await ListenQueueBuilder(db: db).build(meetingId: wanted.id)
        XCTAssertEqual(queue.map(\.members.first?.meetingId), [wanted.id])
    }

    // MARK: 4.2

    /// Interleaved speakers: the voice's lines glue across short pauses but
    /// never across another person's line on the same track.
    func testFragments_runsSplitByOtherSpeakerOrLongPause() {
        func line(_ who: String, _ start: Double, _ end: Double, _ track: SegmentSource = .system) -> TranscriptSegment {
            makeSegment(meetingId: "m", speakerId: who, source: track, startTime: start, endTime: end, text: "\(who)\(Int(start))")
        }
        let segments = [
            line("a", 0, 4), line("a", 4.5, 9), // glued: 0.5 s gap → 0–9
            line("b", 9.2, 9.8), // someone else in between
            line("a", 10, 12), // new run 10–12
            line("a", 14, 30), // 2 s gap → new run 14–30
            line("a", 31, 33, .mic), // other track: its own run
        ]

        let fragments = ListenQueueBuilder.fragments(of: "a", in: segments, gap: 1.0)

        XCTAssertEqual(fragments.map { [$0.start, $0.end] }, [[14, 30], [0, 9], [10, 12], [31, 33]])
        XCTAssertEqual(fragments[1].text, "a0 a4")
        XCTAssertEqual(fragments[3].track, .mic)
    }

    func testCandidateSample_isTheirLongestLineInTheLatestOtherMeeting() async throws {
        let alice = try await confirmed("Alice", v1: basis(0))
        for (offset, length) in [(-86_400.0 * 2, 40.0), (-86_400.0, 12.0)] {
            let other = makeMeeting(startTime: Date().addingTimeInterval(offset))
            try await meetingRepo.save(other)
            try await meetingRepo.saveSegments([
                makeSegment(meetingId: other.id, speakerId: alice.id, source: .system, startTime: 0, endTime: 5),
                makeSegment(meetingId: other.id, speakerId: alice.id, source: .system, startTime: 10, endTime: 10 + length),
            ])
        }
        try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71))

        let sample = try await ListenQueueBuilder(db: db).build().first?.candidates.first?.sample
        XCTAssertEqual(sample?.start, 10)
        XCTAssertEqual(sample?.end, 22, "самая свежая встреча, а в ней — самая длинная реплика")
    }

    /// Through the database, where everyone else's lines come without speaker
    /// or text: another person's line still splits a fragment, a hidden one
    /// does not.
    func testBuild_fragmentsSplitOnAnotherSpeakersLine_notOnAHiddenOne() async throws {
        try await confirmed("Alice", v1: basis(0))
        let (meeting, anon) = try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71))
        let other = makeSpeaker(name: "speaker_9")
        try await speakerRepo.save(other)
        func line(_ who: Speaker, _ start: Double, _ end: Double, hidden: Bool = false) -> TranscriptSegment {
            var line = makeSegment(meetingId: meeting.id, speakerId: who.id, source: .system, startTime: start, endTime: end,
                                   text: "\(who.nameEn) \(Int(start))")
            line.isExcluded = hidden
            return line
        }
        try await meetingRepo.saveSegments([
            line(anon, 1000, 1004), line(anon, 1004.5, 1009), // glued: 1000–1009
            line(other, 1009.2, 1009.8), // someone else
            line(anon, 1010, 1012), // a run of its own
            line(anon, 1020, 1024), line(other, 1024.2, 1024.4, hidden: true), line(anon, 1024.5, 1029), // 1020–1029
        ])

        let item = try await ListenQueueBuilder(db: db).build().first
        let late = (item?.fragments ?? []).filter { $0.start >= 1000 }.sorted { $0.start < $1.start }

        XCTAssertEqual(late.map { [$0.start, $0.end] }, [[1000, 1009], [1010, 1012], [1020, 1029]])
        XCTAssertEqual(late.first?.text, "speaker_4 1000 speaker_4 1004")
        XCTAssertEqual(item?.segmentIds.count, 42 + 5, "только свои видимые реплики")
    }

    func testCandidateSample_skipsTheItemsOwnMeetingAndHiddenLines() async throws {
        let alice = try await confirmed("Alice", v1: basis(0))
        let (meeting, _) = try await meetingWithAnon(seconds: 840, embedding: voice(sim: 0.71))
        // Alice also speaks in the item's meeting, the latest one of all.
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: alice.id, source: .system, startTime: 900, endTime: 960),
        ])
        let earlier = makeMeeting(startTime: Date().addingTimeInterval(-86_400))
        try await meetingRepo.save(earlier)
        var hidden = makeSegment(meetingId: earlier.id, speakerId: alice.id, source: .system, startTime: 0, endTime: 50)
        hidden.isExcluded = true
        try await meetingRepo.saveSegments([
            hidden,
            makeSegment(meetingId: earlier.id, speakerId: alice.id, source: .mic, startTime: 60, endTime: 68),
        ])

        let sample = try await ListenQueueBuilder(db: db).build().first?.candidates.first?.sample

        XCTAssertEqual(sample?.meetingId, earlier.id)
        XCTAssertEqual(sample?.start, 60, "скрытая реплика длиннее, но образцом не будет")
        XCTAssertEqual(sample?.track, .mic)
    }

    // MARK: Count

    func testCount_isTheLengthOfTheQueue_withoutSkipped_andPerMeeting() async throws {
        try await confirmed("Alice", v1: basis(0))
        let (first, _) = try await meetingWithAnon(seconds: 300, embedding: voice(sim: 0.7))
        try await meetingWithAnon(seconds: 900, embedding: voice(sim: 0.7))
        try await meetingWithAnon(seconds: 70, embedding: voice(sim: 0.7)) // too short
        try await meetingWithAnon(seconds: 900, embedding: voice(sim: 0.5)) // unlike anyone
        let builder = ListenQueueBuilder(db: db)

        let all = try await builder.count()
        let one = try await builder.count(meetingId: first.id)
        XCTAssertEqual(all, 2)
        XCTAssertEqual(one, 1)

        let skipped = try await builder.build(meetingId: first.id)[0]
        try await SpeakerVerdicts(db: db).skip(meetingId: first.id, segmentIds: skipped.segmentIds)
        let left = try await builder.count()
        let queue = try await builder.build()
        XCTAssertEqual(left, 1)
        XCTAssertEqual(left, queue.count)
    }

    // MARK: Recurring voices

    /// `count` meetings, each with an anonymous record of the same v2 voice.
    @discardableResult
    private func recurring(_ embedding: [Float], in count: Int, seconds: Double = 300) async throws -> [(Meeting, Speaker)] {
        var made: [(Meeting, Speaker)] = []
        for n in 0 ..< count {
            made.append(try await meetingWithAnon(seconds: seconds + Double(n) * 100, embedding: embedding,
                                                  diarizer: "offline", title: "R\(n)"))
        }
        return made
    }

    func testVoiceLikeNoOne_inThreeMeetings_isOneItem() async throws {
        try await confirmed("Alice", v2: basis(0))
        let made = try await recurring(basis(7), in: 3)

        let queue = try await ListenQueueBuilder(db: db).build()

        XCTAssertEqual(queue.count, 1)
        let item = try XCTUnwrap(queue.first)
        XCTAssertEqual(item.reason, .recurring(meetings: 3))
        XCTAssertEqual(Set(item.members.map(\.speakerId)), Set(made.map(\.1.id)))
        XCTAssertEqual(item.meetingTitle, "R2", "якорь — запись с самой длинной речью")
        XCTAssertEqual(Set(item.fragments.map(\.meetingId)).count, 3, "по фрагменту из каждой встречи")
        XCTAssertEqual(item.candidates.map(\.name), ["Alice"], "подсказка остаётся, хоть и далёкая")
        XCTAssertEqual(item.segmentIds.count, 15 + 20 + 25)
        XCTAssertEqual(Set(item.meetingTitles.values), ["R0", "R1", "R2"])
        XCTAssertEqual(item.heading, "Unnamed voice in 3 meetings")
    }

    func testVoiceLikeNoOne_inTwoMeetings_orTwoVoices_groupApart() async throws {
        try await recurring(basis(7), in: 2)
        try await recurring(basis(8), in: 3)
        try await recurring(basis(9), in: 3)

        let queue = try await ListenQueueBuilder(db: db).build()

        XCTAssertEqual(queue.map(\.reason), [.recurring(meetings: 3), .recurring(meetings: 3)])
    }

    func testRecurringVoice_assignedOnce_movesEveryMeeting() async throws {
        let made = try await recurring(basis(7), in: 3)
        let item = try await ListenQueueBuilder(db: db).build()[0]

        let outcomes = try await SpeakerVerdicts(db: db)
            .assign(meetingIds: item.meetingIds, segmentIds: item.segmentIds, to: .new(name: "Zoe"))

        XCTAssertEqual(Set(outcomes.map(\.speaker.id)).count, 1, "одна персона на все встречи")
        for (meeting, anon) in made {
            let lines = try await meetingRepo.segments(for: meeting.id)
            XCTAssertTrue(lines.allSatisfy { $0.speakerId == outcomes[0].speaker.id })
            let gone = try await speakerRepo.find(anon.id)
            XCTAssertNil(gone)
        }
        let left = try await ListenQueueBuilder(db: db).build()
        XCTAssertTrue(left.isEmpty)
    }

    func testRecurringVoice_skipped_comesBackWithANewMeeting() async throws {
        try await recurring(basis(7), in: 3)
        let item = try await ListenQueueBuilder(db: db).build()[0]
        try await SpeakerVerdicts(db: db).skip(meetingIds: item.meetingIds, segmentIds: item.segmentIds)

        let hidden = try await ListenQueueBuilder(db: db).build()
        let skipped = try await ListenQueueBuilder(db: db).build(skipped: true)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(skipped.map(\.reason), [.recurring(meetings: 3)])

        try await meetingWithAnon(seconds: 300, embedding: basis(7), diarizer: "offline")
        let back = try await ListenQueueBuilder(db: db).build()
        XCTAssertEqual(back.map(\.reason), [.recurring(meetings: 4)])
    }

    // MARK: Split

    func testSplit_givesEachLineToTheCloserPerson_unclearStays() async throws {
        let alice = try await confirmed("Alice", v2: basis(0))
        let bob = try await confirmed("Bob", v2: basis(1))
        var meeting = makeMeeting(title: "Mixed", status: .done)
        meeting.diarizer = "offline"
        try await meetingRepo.save(meeting)
        let anon = makeSpeaker(name: "speaker_1")
        try await speakerRepo.save(anon)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: anon.id, diarizationLabel: "speaker_1")
        var even = basis(0)
        even[1] = 1 // as close to Bob as to Alice
        // A third voice: much closer to Alice than to Bob, but like neither (0.3).
        let stranger = voice(sim: 0.3, axis: 7)
        let voices = [basis(0), basis(1), basis(0), even, stranger]
        try await meetingRepo.saveSegments(voices.enumerated().map { n, voice in
            var line = makeSegment(meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_1", source: .system,
                                   startTime: Double(n * 10), endTime: Double(n * 10 + 5), text: "line \(n)")
            line.embedding = Speaker.encodeEmbedding(voice)
            return line
        })
        let ids = try await meetingRepo.segments(for: meeting.id).compactMap(\.id)

        let outcome = try await SpeakerVerdicts(db: db).split(meetingIds: [meeting.id], segmentIds: ids, between: [alice.id, bob.id])

        XCTAssertEqual(outcome.unclear, 2)
        let owners = try await meetingRepo.segments(for: meeting.id).map(\.speakerId)
        XCTAssertEqual(owners, [alice.id, bob.id, alice.id, anon.id, anon.id], "чужой голос не уходит к тому, кто просто ближе")
    }

    func testSkip_doesNotRepeatMarksAlreadyThere() async throws {
        try await recurring(basis(7), in: 3)
        let item = try await ListenQueueBuilder(db: db).build()[0]
        try await SpeakerVerdicts(db: db).skip(meetingIds: item.meetingIds, segmentIds: item.segmentIds)
        let first = try await db.reader.read { try MeetingMark.fetchCount($0) }
        try await SpeakerVerdicts(db: db).skip(meetingIds: item.meetingIds, segmentIds: item.segmentIds)
        let second = try await db.reader.read { try MeetingMark.fetchCount($0) }
        XCTAssertEqual(first, second)
    }

    func testMultiMeetingAssign_leavesOutAStaleMeeting() async throws {
        let made = try await recurring(basis(7), in: 2)
        var ids: [Int64] = []
        for (meeting, _) in made { ids += try await meetingRepo.segments(for: meeting.id).compactMap(\.id) }
        let outcomes = try await SpeakerVerdicts(db: db).assign(
            meetingIds: [made[0].0.id, "no-such-meeting", made[1].0.id], segmentIds: ids, to: .new(name: "Zoe"))
        XCTAssertEqual(outcomes.count, 2)
    }

    func testClosest_needsTheMargin() {
        let pool = [(id: "a", canonical: basis(0)), (id: "b", canonical: basis(1))]
        XCTAssertEqual(SpeakerVerdicts.closest(voice(sim: 0.9), among: pool, margin: 0.05, minSimilarity: 0.7), "a")
        var near = basis(0)
        near[1] = 0.95
        XCTAssertNil(SpeakerVerdicts.closest(near, among: pool, margin: 0.05, minSimilarity: 0.7), "0.72 против 0.69 — меньше перевеса")
        XCTAssertNil(SpeakerVerdicts.closest(voice(sim: 0.6, axis: 7), among: pool, margin: 0.05, minSimilarity: 0.7),
                     "ближе к a (0.6 против 0), но на a не похож")
    }

    func testGroups_averageLinkage() {
        let a = basis(1), b = basis(2)
        var nearA = a
        nearA[3] = 0.3
        // a, b and nearA: a and nearA join (0.96), b stays apart (0).
        let groups = ListenQueueBuilder.groups([a, b, nearA], threshold: 0.7).map { $0.sorted() }.sorted { $0[0] < $1[0] }
        XCTAssertEqual(groups, [[0, 2], [1]])
    }
}

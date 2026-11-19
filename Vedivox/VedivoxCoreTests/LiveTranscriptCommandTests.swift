import XCTest

/// The document `live_transcript` answers with (live-transcript D6): its shape
/// on the wire, the window, and that excluded speech never leaves the app.
final class LiveTranscriptCommandTests: XCTestCase {

    private func snapshot(
        _ pieces: [(Double, Double, String, SegmentSource)],
        readiness: MeetingLiveTranscript.Readiness = .ready,
        elapsed: TimeInterval = 100,
        dropped: TimeInterval = 0
    ) -> MeetingLiveTranscript.Snapshot {
        var log = LiveTranscriptLog()
        for (start, end, text, track) in pieces {
            log.add(LivePiece(start: start, end: end, text: text), track: track)
        }
        return .init(log: log, speakers: [], readiness: readiness, elapsed: elapsed, droppedSeconds: dropped)
    }

    private typealias Speaker = LiveTranscriptCommand.Speaker

    private func rows(_ response: AppCommandResponse) throws -> [LiveTranscriptCommand.Row] {
        let json = try XCTUnwrap(response.data?["turns"])
        return try JSONDecoder().decode([LiveTranscriptCommand.Row].self, from: Data(json.utf8))
    }

    private func respond(
        _ snapshot: MeetingLiveTranscript.Snapshot,
        last: TimeInterval? = nil,
        marks: [MeetingMark] = [],
        vocabulary: TermNormalizer.Vocabulary = .parse("")
    ) -> AppCommandResponse {
        LiveTranscriptCommand.response(
            meetingId: "M1", snapshot: snapshot, last: last, marks: marks, vocabulary: vocabulary
        )
    }

    func testDocumentNamesMeetingStateClockLossAndTurns() throws {
        let response = respond(snapshot(
            [(36.04, 40, "какой у нас срок", .system), (42, 46.26, "до пятницы", .mic)],
            elapsed: 50.04, dropped: 1.5
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.data?["meeting_id"], "M1")
        XCTAssertEqual(response.data?["state"], "ready")
        XCTAssertEqual(response.data?["elapsed"], "50.0")
        XCTAssertEqual(response.data?["dropped_seconds"], "1.5")
        XCTAssertEqual(try rows(response), [
            .init(speaker: Speaker(.others), track: "system", from: 36, to: 40, text: "какой у нас срок"),
            .init(speaker: Speaker(.me), track: "mic", from: 42, to: 46.3, text: "до пятницы"),
        ])
    }

    // MARK: Speakers

    func testEveryKindOfSpeakerHasItsShapeOnTheWire() throws {
        var log = LiveTranscriptLog()
        log.add(LivePiece(start: 0, end: 4, text: "знакомый"), track: .system, speaker: 0)
        log.add(LivePiece(start: 4, end: 8, text: "незнакомый"), track: .system, speaker: 1)
        log.add(LivePiece(start: 30, end: 31, text: "кто-то"), track: .system)
        log.add(LivePiece(start: 60, end: 64, text: "владелец"), track: .mic)
        let response = respond(.init(
            log: log,
            speakers: [
                LiveSpeaker(kind: .known, name: "Alice", confidence: 0.8249),
                LiveSpeaker(kind: .unknown, name: "Speaker 2"),
            ],
            readiness: .ready, elapsed: 100, droppedSeconds: 0
        ))

        let speakers = try rows(response).map(\.speaker)
        XCTAssertEqual(speakers.map(\.kind), ["known", "unknown", "unknown", "me"])
        XCTAssertEqual(speakers.map(\.name), ["Alice", "Speaker 2", "others", "me"])
        XCTAssertEqual(speakers.map(\.confidence), [0.82, nil, nil, nil])
        // A reader that looks for the key must not find a null where there is no name.
        let json = try XCTUnwrap(response.data?["turns"])
        XCTAssertEqual(json.components(separatedBy: "\"confidence\"").count - 1, 1)
        XCTAssertTrue(json.contains(#""confidence":0.82"#), json)
    }

    func testNoSpeechIsAnEmptyListNotAFailure() throws {
        let response = respond(snapshot([], readiness: .loading))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.data?["state"], "loading")
        XCTAssertEqual(try rows(response), [])
    }

    func testWindowKeepsOnlyTheLastSeconds() throws {
        let response = respond(
            snapshot([(5, 10, "давно", .mic), (85, 90, "сейчас", .mic)], elapsed: 100),
            last: 30
        )
        XCTAssertEqual(try rows(response).map(\.text), ["сейчас"])
    }

    func testSpeechUnderAnOpenExclusionNeverLeaves() throws {
        let open = MeetingMark(
            meetingId: "M1", startTime: 30, endTime: nil, track: .mic, kind: .excluded, source: .zoomMute
        )
        let response = respond(
            snapshot([(36, 40, "в комнату", .mic), (37, 41, "в звонке", .system)]),
            marks: [open]
        )
        XCTAssertEqual(try rows(response).map(\.text), ["в звонке"])
    }

    func testTermsAreNormalisedInTheAnswer() throws {
        let vocabulary = TermNormalizer.Vocabulary.parse("Lakehouse: лейкхаус")
        let response = respond(snapshot([(1, 5, "смотри в лейкхаус", .mic)]), vocabulary: vocabulary)
        XCTAssertEqual(try rows(response).map(\.text), ["смотри в Lakehouse"])
    }

    /// the window reads the whole log every second; the vocabulary
    /// pass (levenshtein per word) ran over all of it each time, so its cost
    /// grew with the recording. Only a turn whose text changed is passed again.
    func testTheWindowNormalisesOnlyTurnsWhoseTextChanged() {
        let normaliser = LiveTranscriptCommand.Normaliser(vocabulary: .parse("Lakehouse: лейкхаус"))
        var pieces: [(Double, Double, String, SegmentSource)] = [
            (1, 5, "смотри в лейкхаус", .mic), (30, 34, "вижу", .system), (60, 64, "и ещё", .mic),
        ]
        let read = { LiveTranscriptCommand.turns(snapshot: self.snapshot(pieces), last: nil, marks: [], normaliser: normaliser) }

        XCTAssertEqual(read().map(\.text), ["смотри в Lakehouse", "вижу", "и ещё"])
        XCTAssertEqual(normaliser.passes, 3)

        XCTAssertEqual(read().map(\.text), ["смотри в Lakehouse", "вижу", "и ещё"])
        XCTAssertEqual(normaliser.passes, 3, "nothing changed — nothing passed again")

        pieces.append((65, 68, "в лейкхаус", .mic))
        XCTAssertEqual(read().map(\.text), ["смотри в Lakehouse", "вижу", "и ещё в Lakehouse"])
        XCTAssertEqual(normaliser.passes, 4, "only the turn that grew")
    }
}

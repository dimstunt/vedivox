import XCTest

/// A precise pass over the tail of a running recording (change
/// `live-speakers`, design D2, D4, D5): what the import analysis of a tail
/// becomes, and how passes add up in the live text. No model: segments are
/// made by hand.
final class LiveTailAnalysisTests: XCTestCase {

    private func segment(
        _ label: String?, _ start: Double, _ end: Double, _ text: String, _ vector: [Float]? = nil
    ) -> TranscriptSegment {
        var segment = TranscriptSegment(
            meetingId: "", speakerLabel: label, source: .import, startTime: start, endTime: end, text: text
        )
        segment.embedding = vector.map(Speaker.encodeEmbedding)
        return segment
    }

    private let pool = [
        SpeakerMatcher.Candidate(speakerId: "a", displayName: "Alice", canonical: [1, 0, 0], segmentCount: 100),
    ]

    // MARK: From the import analysis

    func testLinesMoveToTheRecordingsClockAndKeepTheirLabels() {
        let (track, _) = LiveTailAnalysis.system(
            segments: [
                segment("Alice", 2, 6, "вопрос", [1, 0, 0]),
                segment("speaker_1", 6, 9, "ответ", [0, 1, 0]),
                segment("UNKNOWN", 9, 9.5, "угу"),
                segment("Alice", 10, 11, "  "),
            ],
            labelToDbId: ["Alice": "a"], pool: pool, from: 120, duration: 60
        )
        XCTAssertEqual(track.from, 120)
        XCTAssertEqual(track.to, 180)
        XCTAssertEqual(track.lines.map(\.start), [122, 126, 129])
        XCTAssertEqual(track.lines.map(\.label), ["Alice", "speaker_1", nil], "UNKNOWN is nobody in particular")
        XCTAssertEqual(track.lines.map(\.text), ["вопрос", "ответ", "угу"], "blank text is not a line")
    }

    func testAVoiceIsTheMeanOfItsSegmentsAndCarriesThePassVerdict() throws {
        let (_, voices) = LiveTailAnalysis.system(
            segments: [
                segment("Alice", 0, 6, "раз", [1, 0, 0]),
                segment("Alice", 10, 12, "два", [0, 1, 0]),
                segment("speaker_1", 20, 25, "три", [0, 0, 2]),
            ],
            labelToDbId: ["Alice": "a"], pool: pool, from: 0, duration: 30
        )
        let alice = try XCTUnwrap(voices["Alice"])
        XCTAssertEqual(alice.seconds, 8)
        // Six seconds along the first axis, two along the second.
        XCTAssertEqual(alice.centroid, [6, 2, 0])
        XCTAssertEqual(alice.identity?.speakerId, "a")
        XCTAssertEqual(alice.identity?.name, "Alice")
        XCTAssertEqual(try XCTUnwrap(alice.identity?.confidence), 6 / sqrtf(40), accuracy: 1e-5)

        let stranger = try XCTUnwrap(voices["speaker_1"])
        XCTAssertNil(stranger.identity)
        XCTAssertEqual(stranger.centroid, [0, 0, 5], "vectors count by their direction, not their length")
    }

    func testALabelWithoutAVectorIsNotAVoice() {
        let (track, voices) = LiveTailAnalysis.system(
            segments: [segment("speaker_1", 0, 5, "без вектора")],
            labelToDbId: [:], pool: [], from: 0, duration: 10
        )
        XCTAssertEqual(voices, [:])
        XCTAssertEqual(track.lines.map(\.label), ["speaker_1"], "the line stays; it reads as nobody in particular")
    }

    // MARK: Passes add up

    private func pass(
        from: Double, to: Double, _ lines: [(Double, Double, String, String?)], _ voices: [String: LiveTailAnalysis.Voice]
    ) -> LiveTailAnalysis {
        var analysis = LiveTailAnalysis()
        analysis.system = .init(from: from, to: to, lines: lines.map { .init(start: $0.0, end: $0.1, text: $0.2, label: $0.3) })
        analysis.voices = voices
        return analysis
    }

    private func voice(_ vector: [Float], _ seconds: Double = 30, _ name: String? = nil) -> LiveTailAnalysis.Voice {
        .init(centroid: vector, seconds: seconds, identity: name.map { .init(speakerId: $0, name: $0, confidence: 0.8) })
    }

    private func names(_ log: LiveTranscriptLog, _ book: LiveSpeakerBook) -> [String] {
        log.turns(speakers: book.speakers, mergeGap: 0).map { "\($0.speaker.name): \($0.text)" }
    }

    /// Each pass numbers its own clusters; the reader sees one Speaker 2.
    func testTheSameVoiceKeepsItsLabelFromPassToPass() {
        var log = LiveTranscriptLog()
        var book = LiveSpeakerBook()
        pass(from: 0, to: 60, [(5, 10, "первый", "speaker_1"), (20, 25, "второй", "speaker_2")],
             ["speaker_1": voice([1, 0, 0]), "speaker_2": voice([0, 1, 0])]).apply(to: &log, speakers: &book)
        // The next tail: the pass happened to number the same two people the other way round.
        pass(from: 60, to: 120, [(70, 75, "второй снова", "speaker_1"), (90, 95, "первый снова", "speaker_2")],
             ["speaker_1": voice([0, 1, 0]), "speaker_2": voice([1, 0, 0])]).apply(to: &log, speakers: &book)

        XCTAssertEqual(names(log, book), [
            "Speaker 1: первый", "Speaker 2: второй", "Speaker 2: второй снова", "Speaker 1: первый снова",
        ])
    }

    func testANameFromALaterPassRenamesWhatTheVoiceSaidBeforeItsTail() {
        var log = LiveTranscriptLog()
        var book = LiveSpeakerBook()
        pass(from: 0, to: 60, [(5, 10, "рано", "speaker_1")], ["speaker_1": voice([1, 0, 0], 5)])
            .apply(to: &log, speakers: &book)
        XCTAssertEqual(names(log, book), ["Speaker 1: рано"])

        // A tail that no longer reaches the first phrase, with enough speech for a name.
        pass(from: 60, to: 180, [(70, 100, "позже", "Alice")], ["Alice": voice([1, 0, 0], 30, "Alice")])
            .apply(to: &log, speakers: &book)
        XCTAssertEqual(names(log, book), ["Alice: рано", "Alice: позже"])
    }

    func testSpeakersAreNumberedInTheOrderTheyAreFirstHeard() {
        var log = LiveTranscriptLog()
        var book = LiveSpeakerBook()
        pass(from: 0, to: 60, [(5, 10, "первым заговорил", "speaker_2"), (20, 25, "вторым", "speaker_1")],
             ["speaker_1": voice([1, 0, 0]), "speaker_2": voice([0, 1, 0])]).apply(to: &log, speakers: &book)
        XCTAssertEqual(names(log, book), ["Speaker 1: первым заговорил", "Speaker 2: вторым"])
    }

    func testTheMicrophoneOfAPassIsTheOwner() {
        var log = LiveTranscriptLog()
        var book = LiveSpeakerBook()
        log.add(LivePiece(start: 5, end: 9, text: "быстрый"), track: .mic)
        var analysis = LiveTailAnalysis()
        analysis.mic = .init(from: 0, to: 60, lines: [.init(start: 5, end: 9, text: "точный")])
        analysis.apply(to: &log, speakers: &book)

        XCTAssertEqual(names(log, book), ["me: точный"])
        XCTAssertEqual(book.speakers, [])
    }

    /// A track the pass could not refine keeps its quick text.
    func testATrackThePassDidNotCoverIsLeftAlone() {
        var log = LiveTranscriptLog()
        var book = LiveSpeakerBook()
        log.add(LivePiece(start: 5, end: 9, text: "быстрый"), track: .system)
        LiveTailAnalysis().apply(to: &log, speakers: &book)
        XCTAssertEqual(names(log, book), ["others: быстрый"])
    }
}

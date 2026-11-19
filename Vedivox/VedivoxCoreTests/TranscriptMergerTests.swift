import FluidAudio
import XCTest

/// Unit tests for `TranscriptMerger.assembleByDiarization` (
/// diar-aligned segment reassembly from raw ASR tokens).
///
/// Two cases drive the scenarios:
/// - «Понимаешь меня?» — a token group straddled a Ирма→Тимур change and
///   max-overlap gave the whole phrase to Тимур.
/// - «прогресс?» — a short interjection was glued by TokenGrouper's
///   merge-tiny step into the previous (long, other-speaker) segment.
final class TranscriptMergerTests: XCTestCase {

    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
    }

    private func diar(
        _ speaker: String, _ start: Double, _ end: Double, embedding: [Float] = [1, 0]
    ) -> DiarizationService.DiarizationSegment {
        DiarizationService.DiarizationSegment(start: start, end: end, speaker: speaker, embedding: embedding)
    }

    private func assemble(
        tokens: [TokenTiming],
        diarization: [DiarizationService.DiarizationSegment]
    ) -> [TranscriptSegment]? {
        TranscriptMerger.assembleByDiarization(
            tokens: tokens, diarization: diarization, meetingId: "m", source: .system
        )
    }

    /// The first case: tokens cross a speaker boundary mid-group → two
    /// segments, each under its own speaker.
    func testSplitsAcrossSpeakerBoundary() throws {
        let tokens = [
            token(" Понимаешь", 0.0, 0.4),
            token(" меня?", 0.4, 0.7),
            token(" Да,", 1.0, 1.3),
            token(" конечно", 1.3, 1.8),
        ]
        let diarization = [diar("Ирма", 0.0, 0.8), diar("Тимур", 0.9, 2.0)]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speakerLabel, "Ирма")
        XCTAssertEqual(segments[0].text, "Понимаешь меня?")
        XCTAssertEqual(segments[1].speakerLabel, "Тимур")
        XCTAssertEqual(segments[1].text, "Да, конечно")
    }

    /// The second case: a short interjection by B inside A's long stretch keeps
    /// its own speaker instead of being glued to A.
    func testShortInterjectionKeepsOwnSpeaker() throws {
        let tokens = [
            token(" мы", 0.0, 0.5),
            token(" продолжаем", 0.5, 1.4),
            token(" прогресс?", 2.0, 2.9),
            token(" и", 3.5, 3.8),
            token(" дальше", 3.8, 4.4),
        ]
        let diarization = [
            diar("Ирма", 0.0, 1.8),
            diar("Ира", 1.9, 3.1),
            diar("Ирма", 3.3, 5.0),
        ]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.map(\.speakerLabel), ["Ирма", "Ира", "Ирма"])
        XCTAssertEqual(segments[1].text, "прогресс?")
    }

    /// A punctuation-only run (boundary "?" drifting onto the next speaker's
    /// side) glues back to the utterance it terminates.
    func testPunctuationOnlyRunGluesToPrevious() throws {
        let tokens = [
            token(" вопрос", 0.0, 0.8),
            token("?", 1.05, 1.1), // overlaps B's segment
            token(" ответ", 1.5, 2.0),
        ]
        let diarization = [diar("A", 0.0, 1.0), diar("B", 1.0, 2.5)]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speakerLabel, "A")
        XCTAssertEqual(segments[0].text, "вопрос?")
        XCTAssertEqual(segments[1].speakerLabel, "B")
    }

    /// one meeting «По про / центную»: a speaker change between the
    /// subword tokens of one word cut it in two. A token without a leading
    /// space continues the current word and stays with it.
    func testSpeakerChangeNeverSplitsAWord() throws {
        let tokens = [
            token(" По", 0.0, 0.3),
            token(" про", 0.3, 0.6),
            token("цент", 0.65, 0.85), // overlaps B's segment
            token("ную", 0.85, 1.1),
            token(" фиш.", 1.2, 1.6),
        ]
        let diarization = [diar("A", 0.0, 0.7), diar("B", 0.7, 2.0)]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.map(\.text), ["По процентную", "фиш."])
        XCTAssertEqual(segments.map(\.speakerLabel), ["A", "B"])
    }

    /// TTS3 «rollo / ut.», «Okay /. So»: TDT emits a word's last
    /// subword or its punctuation late, and TokenGrouper's gap split cut there.
    /// Segments may only break before a word start.
    func testSilenceGapNeverSplitsAWord() throws {
        let tokens = [
            token(" staged", 0.0, 0.4),
            token(" rol", 0.4, 0.6),
            token("lo", 0.6, 0.8),
            token("ut", 1.2, 1.5), // 0.4 s gap mid-word
            token(".", 1.5, 1.8),
            token(" Okay", 3.0, 3.5),
            token(".", 3.9, 4.0), // 0.4 s gap before punctuation
            token(" So", 4.0, 4.3),
            token(" um", 4.3, 4.6),
        ]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: [diar("A", 0.0, 5.0)]))

        XCTAssertEqual(segments.map(\.text), ["staged rollout.", "Okay.", "So um"])
    }

    /// A tiny utterance after a long silence stays its own segment: the
    /// merge-tiny step glued it back across the silence (bench M5: a 99 s mic
    /// segment over 95 s of nothing).
    func testTinySegmentAfterLongSilenceIsNotMergedBack() throws {
        let tokens = [
            token(" Это", 0.0, 0.6),
            token(" всё.", 0.6, 1.2),
            token(" Да", 20.0, 20.3),
        ]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: [diar("A", 0.0, 21.0)]))

        XCTAssertEqual(segments.map(\.text), ["Это всё.", "Да"])
        XCTAssertEqual(segments.last?.startTime, 20.0)
    }

    /// bench M4 «?» 98,6–184,8 s: FluidAudio gives a zero-duration
    /// TDT token endTime = the next token's start, so the token before a pause
    /// spans the whole silence and the segment ends where speech resumes.
    func testZeroDurationTokenDoesNotStretchSegmentOverSilence() {
        let tokens = [
            token(" Ну", 98.0, 98.3),
            token(" что", 98.3, 98.6),
            token("?", 98.6, 184.8), // duration 0 → end = next start
            token(" Да", 184.8, 185.1),
        ]
        let segments = TokenGrouper.group(tokens)

        XCTAssertEqual(segments.map(\.text), [" Ну что?", " Да"])
        XCTAssertLessThan(segments[0].endTime, 99.5)
    }

    /// The same stretched token must not vote for the speaker who talks after
    /// the pause: its 60 s of fake overlap outweighed its real 0.3 s.
    func testStretchedTokenKeepsItsOwnSpeaker() throws {
        let tokens = [
            token(" Ага", 10.0, 70.0), // duration 0 → end = next start
            token(" Слушай", 70.0, 70.5),
        ]
        let diarization = [diar("A", 9.8, 10.5), diar("B", 40.0, 71.0)]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.map(\.text), ["Ага", "Слушай"])
        XCTAssertEqual(segments.map(\.speakerLabel), ["A", "B"])
        XCTAssertLessThan(segments[0].endTime, 11.0)
    }

    /// Tokens outside every diarization segment become an UNKNOWN segment —
    /// same vocabulary the legacy max-overlap path produced.
    func testTokensInDiarizationGapBecomeUnknown() throws {
        let tokens = [
            token(" речь", 0.0, 0.5),
            token(" шум", 5.0, 5.5),
        ]
        let diarization = [diar("A", 0.0, 1.0)]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speakerLabel, "A")
        XCTAssertEqual(segments[1].speakerLabel, "UNKNOWN")
    }

    /// Long same-speaker runs still subdivide by silence gaps (TokenGrouper
    /// semantics preserved within a run).
    func testLongRunStillSplitsOnSilence() throws {
        let tokens = [
            token(" первая", 0.0, 0.6),
            token(" фраза.", 0.6, 1.0),
            token(" вторая", 3.0, 3.6), // 2s gap
            token(" фраза", 3.6, 4.0),
        ]
        let diarization = [diar("A", 0.0, 5.0)]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.speakerLabel), ["A", "A"])
    }

    /// Missing inputs → nil, caller falls back to the legacy path.
    func testFallbackWhenInputsMissing() {
        XCTAssertNil(assemble(tokens: [], diarization: [diar("A", 0, 1)]))
        XCTAssertNil(assemble(tokens: [token("x", 0, 1)], diarization: []))
    }

    /// Segments carry the diarization segment's embedding, unit-length (the
    /// rescue and the canonical recalc read it downstream).
    func testSegmentsCarryDiarEmbedding() throws {
        let emb: [Float] = [0.6, 0.8]
        let segments = try XCTUnwrap(assemble(
            tokens: [token(" слово", 0.0, 0.5)],
            diarization: [diar("A", 0.0, 1.0, embedding: emb)]
        ))
        XCTAssertEqual(segments[0].embedding, Speaker.encodeEmbedding(emb))
    }

    /// merge() must keep each segment's originating track: track-scoped
    /// exclusion marks (track='mic') match on it, and the old `.merged` stamp
    /// silently made every mark miss every segment of a two-stream meeting.
    func testMergePreservesTrackOrigin() {
        let mic = TranscriptSegment(
            meetingId: "m", speakerLabel: "me", source: .mic,
            startTime: 5, endTime: 10, text: "mic"
        )
        let system = TranscriptSegment(
            meetingId: "m", source: .system,
            startTime: 0, endTime: 4, text: "system"
        )

        let merged = TranscriptMerger.merge(micSegments: [mic], systemSegments: [system])

        XCTAssertEqual(merged.map(\.source), [.system, .mic], "сортировка по времени, дорожки сохранены")
    }

    /// segment-own-voice § 2: a run crossing two diarization segments of one
    /// cluster gives each reply the vector of the segment under it, not the
    /// vector of the run's first segment.
    func testRunThroughTwoSegmentsGivesRepliesTheirOwnVectors() throws {
        let tokens = [
            token(" первая.", 0.0, 1.0),
            token(" вторая", 5.0, 6.0),
        ]
        let diarization = [
            diar("A", 0.0, 2.0, embedding: [1, 0]),
            diar("A", 4.5, 7.0, embedding: [0, 1]),
        ]
        let segments = try XCTUnwrap(assemble(tokens: tokens, diarization: diarization))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].embedding, Speaker.encodeEmbedding([1, 0]))
        XCTAssertEqual(segments[1].embedding, Speaker.encodeEmbedding([0, 1]))
    }
}

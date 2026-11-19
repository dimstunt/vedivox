import XCTest

/// What the live transcript gives out and in what shape (live-transcript
/// D5/D6): turns in time order, the window, and the exclusion rule.
final class LiveTranscriptLogTests: XCTestCase {

    private func mark(_ start: Double, _ end: Double?, track: SegmentSource = .mic) -> MeetingMark {
        MeetingMark(
            meetingId: "m", startTime: start, endTime: end, track: track,
            kind: .excluded, source: .manual, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func log(_ pieces: [(Double, Double, String, SegmentSource)]) -> LiveTranscriptLog {
        var log = LiveTranscriptLog()
        for (start, end, text, track) in pieces {
            log.add(LivePiece(start: start, end: end, text: text), track: track)
        }
        return log
    }

    // MARK: Entries

    func testAPieceBecomesAnEntryOfItsTrack() {
        let log = log([(3, 7.5, " какой срок? ", .system)])
        XCTAssertEqual(log.entries, [.init(track: .system, start: 3, end: 7.5, text: "какой срок?")])
    }

    func testBlankTextIsNotAnEntry() {
        let log = log([(0, 4, "", .mic), (4, 8, "  \n", .mic)])
        XCTAssertEqual(log.entries, [])
    }

    // MARK: Turns

    func testTurnsOfTwoTracksGoInTimeOrder() {
        // Added mic first, as the feed loop does, though the question came first.
        let turns = log([(6, 8, "ответ", .mic), (2, 5, "вопрос", .system)]).turns()
        XCTAssertEqual(turns.map(\.text), ["вопрос", "ответ"])
        XCTAssertEqual(turns.map(\.track), [.system, .mic])
    }

    func testNeighbouringEntriesOfOneTrackMergeAndAPauseSplitsThem() {
        let turns = log([(0, 2, "раз", .mic), (2, 4, "два", .mic), (40, 42, "три", .mic)]).turns()
        XCTAssertEqual(turns.map(\.text), ["раз два", "три"])
        XCTAssertEqual(turns.first?.start, 0)
        XCTAssertEqual(turns.first?.end, 4)
    }

    func testAMonologueIsSplitIntoTurnsOfAboutAMinute() {
        let pieces = stride(from: 0.0, to: 150, by: 10).map { ($0, $0 + 10, "слово", SegmentSource.system) }
        let turns = log(pieces).turns()
        XCTAssertEqual(turns.count, 3)
        XCTAssertTrue(turns.allSatisfy { $0.end - $0.start <= 60 })
    }

    func testCutoffDropsWhatEndedBeforeIt() {
        let log = log([(5, 10, "старое", .mic), (95, 100, "новое", .mic)])
        XCTAssertEqual(log.turns(after: 50).map(\.text), ["новое"])
        XCTAssertEqual(log.turns(after: 100).map(\.text), [])
    }

    // MARK: Exclusion

    func testOpenMicMarkHidesMicSpeechAndKeepsTheSystemTrack() {
        let log = log([(8, 12, "в комнату", .mic), (8, 12, "в звонке", .system)])
        XCTAssertEqual(log.turns(marks: [mark(5, nil)]).map(\.text), ["в звонке"])
    }

    func testClosedMarkHidesOnlyWhatItCovers() {
        let log = log([(2, 5, "до", .mic), (12, 15, "внутри", .mic), (28, 30, "после", .mic)])
        XCTAssertEqual(log.turns(marks: [mark(10, 20)]).map(\.text), ["до", "после"])
    }

    /// The transcript's own rule: at least half of the entry under the mark.
    func testAnEntryMostlyOutsideTheMarkStays() {
        let log = log([(0, 10, "почти всё до мьюта", .mic)])
        XCTAssertEqual(log.turns(marks: [mark(8, nil)]).count, 1)
        XCTAssertEqual(log.turns(marks: [mark(4, nil)]).count, 0)
    }

    func testNoMarksGiveBothTracks() {
        XCTAssertEqual(log([(0, 3, "я", .mic), (3, 6, "они", .system)]).turns().count, 2)
    }

    // MARK: Speakers

    private let one = LiveSpeaker(kind: .unknown, name: "Speaker 1")
    private let two = LiveSpeaker(kind: .unknown, name: "Speaker 2")

    /// The call track as a precise pass leaves it: lines with the key the
    /// book gave each voice (nil — too short for a voice).
    private func call(_ pieces: [(Double, Double, String, Int?)]) -> LiveTranscriptLog {
        var log = LiveTranscriptLog()
        log.refine(track: .system, from: 0, to: 100_000, with: pieces.map {
            (LivePiece(start: $0.0, end: $0.1, text: $0.2), $0.3)
        })
        return log
    }

    /// Quick text has not been listened to for a voice: it waits for a pass
    /// as `others` instead of borrowing the label of whoever spoke before.
    func testQuickTextNobodyRefinedYetDoesNotTakeANeighboursLabel() {
        var log = call([(0, 4, "уточнённое", 0)])
        log.add(LivePiece(start: 100_001, end: 100_003, text: "только что"), track: .system)
        let turns = log.turns(speakers: [one], mergeGap: 0)
        XCTAssertEqual(turns.map(\.speaker), [one, .others])
    }

    func testWithoutABookTheCallTrackIsOthersAndTheMicrophoneIsMe() {
        let turns = log([(0, 3, "я", .mic), (3, 6, "они", .system)]).turns()
        XCTAssertEqual(turns.map(\.speaker), [.me, .others])
    }

    func testTwoSpeakersInARowAreTwoTurns() {
        let turns = call([(0, 4, "вопрос", 0), (4, 8, "ответ", 1), (8, 10, "и ещё", 1)]).turns(speakers: [one, two])
        XCTAssertEqual(turns.map(\.text), ["вопрос", "ответ и ещё"])
        XCTAssertEqual(turns.map(\.speaker), [one, two])
    }

    func testAPieceWithoutAVoiceTakesTheLabelOfThePieceBeforeIt() {
        let turns = call([(0, 4, "длинная фраза", 0), (5, 5.4, "угу", nil), (5.6, 6, "да", nil)])
            .turns(speakers: [one, two])
        XCTAssertEqual(turns.map(\.text), ["длинная фраза угу да"])
        XCTAssertEqual(turns.map(\.speaker), [one])
    }

    func testWithNobodyBeforeItTakesTheLabelOfThePieceAfterIt() {
        let turns = call([(10, 10.4, "так", nil), (11, 15, "давайте начнём", 1)]).turns(speakers: [one, two])
        XCTAssertEqual(turns.map(\.speaker), [two])
        XCTAssertEqual(turns.map(\.text), ["так давайте начнём"])
    }

    func testThePieceBeforeWinsOverThePieceAfter() {
        let turns = call([(0, 4, "первый", 0), (4.5, 5, "ага", nil), (5.5, 9, "второй", 1)]).turns(speakers: [one, two])
        XCTAssertEqual(turns.map(\.text), ["первый ага", "второй"])
    }

    func testAPieceWithNoNeighbourInTimeStaysOthers() {
        let turns = call([(0, 4, "раньше", 0), (30, 30.5, "алло", nil), (60, 64, "позже", 1)]).turns(speakers: [one, two])
        XCTAssertEqual(turns.map(\.speaker), [one, .others, two])
    }

    func testAVoiceRecognisedLaterRenamesWhatItSaidBefore() {
        let log = call([(0, 4, "привет", 0), (4, 8, "как дела", 0)])
        XCTAssertEqual(log.turns(speakers: [one]).map(\.speaker.name), ["Speaker 1"])

        let named = LiveSpeaker(kind: .known, name: "Alice", confidence: 0.82)
        XCTAssertEqual(log.turns(speakers: [named]).map(\.speaker), [named])
    }

    func testTwoClustersOfOneNamedVoiceMergeIntoOneTurnWithTheHigherConfidence() {
        let turns = call([(0, 4, "раз", 0), (4, 8, "два", 1)]).turns(speakers: [
            LiveSpeaker(kind: .known, name: "Alice", confidence: 0.74),
            LiveSpeaker(kind: .known, name: "Alice", confidence: 0.81),
        ])
        XCTAssertEqual(turns.map(\.text), ["раз два"])
        XCTAssertEqual(turns.first?.speaker.confidence, 0.81)
    }

    func testTheMicrophoneIsNeverLabelledByANeighbour() {
        var log = call([(0, 4, "они", 0)])
        log.add(LivePiece(start: 4.2, end: 4.6, text: "я"), track: .mic)
        XCTAssertEqual(log.turns(speakers: [one]).map(\.speaker), [one, .me])
    }

    /// Who said a piece must not depend on how far back the reader looks.
    func testAnInheritedLabelSurvivesTheCutoffHidingItsNeighbour() {
        let log = call([(0, 4, "длинная фраза", 0), (5, 9, "хвост без голоса", nil)])
        XCTAssertEqual(log.turns(after: 4.5, speakers: [one]).map(\.speaker), [one])
    }

    // MARK: Precise passes

    private func line(_ start: Double, _ end: Double, _ text: String, _ key: Int? = nil) -> (piece: LivePiece, speaker: Int?) {
        (LivePiece(start: start, end: end, text: text), key)
    }

    func testAPassReplacesTheQuickTextOfItsStretchAndNothingElse() {
        var log = LiveTranscriptLog()
        for (start, end, text) in [(0.0, 5.0, "до хвоста"), (10, 15, "быстрый текст"), (16, 20, "ещё быстрый")] {
            log.add(LivePiece(start: start, end: end, text: text), track: .system)
        }
        log.add(LivePiece(start: 11, end: 14, text: "микрофон"), track: .mic)

        log.refine(track: .system, from: 8, to: 22, with: [line(10, 20, "точный текст", 0)])

        let turns = log.turns(speakers: [one], mergeGap: 0)
        XCTAssertEqual(turns.map(\.text), ["до хвоста", "точный текст", "микрофон"])
        XCTAssertEqual(turns.map(\.speaker), [.others, one, .me])
    }

    func testQuickTextForAMomentAlreadyRefinedIsNotWanted() {
        var log = LiveTranscriptLog()
        log.refine(track: .system, from: 0, to: 60, with: [line(50, 58, "точный", 0)])
        // The quick window that was still waiting for its pause when the pass ran.
        log.add(LivePiece(start: 52, end: 58, text: "быстрый дубль"), track: .system)
        log.add(LivePiece(start: 59, end: 65, text: "новое"), track: .system)
        log.add(LivePiece(start: 52, end: 58, text: "микрофон не уточнялся"), track: .mic)

        XCTAssertEqual(log.entries.map(\.text), ["точный", "новое", "микрофон не уточнялся"])
    }

    /// A tail starts mid-phrase: where an earlier pass already put precise
    /// text, the head of the next tail keeps it.
    func testTheHeadOfATailDoesNotChopTextAnEarlierPassRefined() {
        var log = LiveTranscriptLog()
        log.refine(track: .system, from: 0, to: 120, with: [line(58, 62, "целая фраза", 0), line(70, 75, "дальше", 0)])

        log.refine(track: .system, from: 60, to: 180, with: [line(60, 62, "обрубок", 1), line(70, 76, "дальше точнее", 1)])

        XCTAssertEqual(
            log.turns(speakers: [one, two], mergeGap: 0).map(\.text), ["целая фраза", "дальше точнее"]
        )
    }

    /// A turn can last a minute. The seam goes to a boundary both passes
    /// heard, so neither half of such a turn is lost.
    func testALongTurnAcrossTheHeadOfTheNextTailIsKeptWhole() {
        var log = LiveTranscriptLog()
        log.refine(track: .system, from: 0, to: 120, with: [line(50, 100, "длинная реплика целиком", 0), line(105, 118, "ответ", 1)])

        log.refine(track: .system, from: 60, to: 180, with: [
            line(60, 100.2, "реплика без начала", 0), line(104.8, 118, "ответ точнее", 1), line(130, 140, "новое", 0),
        ])

        XCTAssertEqual(
            log.turns(speakers: [one, two], mergeGap: 0).map(\.text),
            ["длинная реплика целиком", "ответ точнее", "новое"]
        )
    }

    /// Nobody paused where both passes could agree: the earlier text stays,
    /// and the next pass gets its chance.
    func testWithoutASharedBoundaryTheEarlierTextIsLeftAlone() {
        var log = LiveTranscriptLog()
        log.refine(track: .system, from: 0, to: 120, with: [line(10, 119, "монолог", 0)])
        log.refine(track: .system, from: 60, to: 180, with: [line(60, 179, "монолог без начала", 0)])
        XCTAssertEqual(log.entries.map(\.text), ["монолог"])
        XCTAssertEqual(log.refinedUntil[.system], 180)
    }

    func testTheFirstPassOverAStretchTakesItsHeadToo() {
        var log = LiveTranscriptLog()
        log.add(LivePiece(start: 61, end: 62, text: "быстрый"), track: .system)
        log.refine(track: .system, from: 60, to: 180, with: [line(60, 63, "точный с начала", 0)])
        XCTAssertEqual(log.entries.map(\.text), ["точный с начала"])
    }

    func testAMarkHidesRefinedTextToo() {
        var log = LiveTranscriptLog()
        log.refine(track: .mic, from: 0, to: 60, with: [line(10, 14, "не для записи"), line(30, 34, "для записи")])
        XCTAssertEqual(log.turns(marks: [mark(5, 20)]).map(\.text), ["для записи"])
    }

    func testAKeyTheTableDoesNotKnowReadsAsOthers() {
        XCTAssertEqual(call([(0, 4, "кто-то", 7)]).turns(speakers: [one]).map(\.speaker), [.others])
    }
}

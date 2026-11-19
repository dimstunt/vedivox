import XCTest
import GRDB

/// Foreign voices on the mic track: who counts as foreign, what the default
/// does with them, and what a decision protects (`foreign-voices-on-mic`).
final class ForeignVoicePolicyTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture {
        let db: DatabaseManager
        let meeting: Meeting
        let owner: Speaker
        let guest: Speaker
        let policy: ForeignVoicePolicy
        var meetingRepo: MeetingRepository { MeetingRepository(db: db) }
    }

    /// A meeting with the owner speaking on the mic, a named neighbour also on
    /// the mic, an unidentified stretch on the mic, and the far side on the
    /// system track.
    private func makeFixture(withOwner: Bool = true) async throws -> Fixture {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        // Always stored (segments reference it); `isMe` is what the rule keys on.
        let owner = makeSpeaker(name: "Захар", isMe: withOwner)
        try await speakerRepo.save(owner)
        let guest = makeSpeaker(name: "Ирма")
        try await speakerRepo.save(guest)
        let farSide = makeSpeaker(name: "Борис")
        try await speakerRepo.save(farSide)

        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: owner.id, speakerLabel: "Захар",
                        source: .mic, startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 10, endTime: 20),
            makeSegment(meetingId: meeting.id, speakerId: nil, speakerLabel: "UNKNOWN",
                        source: .mic, startTime: 20, endTime: 30),
            makeSegment(meetingId: meeting.id, speakerId: farSide.id, speakerLabel: "Борис",
                        source: .system, startTime: 0, endTime: 30),
        ])

        return Fixture(db: db, meeting: meeting, owner: owner, guest: guest, policy: ForeignVoicePolicy(db: db))
    }

    private func segments(_ f: Fixture) async throws -> [TranscriptSegment] {
        try await f.meetingRepo.segments(for: f.meeting.id)
    }

    private func decision(_ f: Fixture) async throws -> ForeignVoiceDecision? {
        try await f.meetingRepo.find(f.meeting.id)?.foreignVoiceDecision
    }

    private func excludedLabels(_ f: Fixture) async throws -> Set<String> {
        Set(try await segments(f).filter(\.isExcluded).compactMap(\.speakerLabel))
    }

    // MARK: - 5.1–5.4: what counts as foreign

    /// 5.3 — a neighbour the system knows by name is foreign just like an
    /// unidentified one. 5.4 — the far side on the system track never is.
    func testForeignSegments_namedAndUnknownOnMic_notTheSystemTrack() async throws {
        let f = try await makeFixture()
        let all = try await segments(f)
        let foreign = ForeignVoicePolicy.foreignSegments(all, ownerId: f.owner.id)

        XCTAssertEqual(Set(foreign.compactMap(\.speakerLabel)), ["Ирма", "UNKNOWN"])
        XCTAssertFalse(foreign.contains { $0.source == .system },
                       "на системной дорожке собеседники, ради которых встреча и записывалась")
    }

    /// 5.5 — without a speaker marked «это я» everyone would be foreign, so the
    /// rule does not apply at all.
    func testForeignSegments_withoutOwner_isEmpty() async throws {
        let f = try await makeFixture(withOwner: false)
        let all = try await segments(f)
        XCTAssertTrue(ForeignVoicePolicy.foreignSegments(all, ownerId: nil).isEmpty)
    }

    /// 5.4 — and the default never touches the system track either.
    func testApplyDefault_leavesTheSystemTrackAlone() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)

        let system = try await segments(f).filter { $0.source == .system }
        XCTAssertFalse(system.contains(where: \.isExcluded))
    }

    /// 5.5 — no isMe speaker: the default applies nothing, silently.
    func testApplyDefault_withoutOwner_doesNothing() async throws {
        let f = try await makeFixture(withOwner: false)
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)

        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(ruling, .undecided)
    }

    // MARK: - 6.5: all four values

    func testDefault_hideSilently_hidesAndClosesTheQuestion() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)

        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertEqual(hidden, ["Ирма", "UNKNOWN"])
        XCTAssertEqual(ruling, .hidden, "вопрос не задаётся — встреча решена")
    }

    func testDefault_askHiding_hidesButKeepsTheQuestionOpen() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)

        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertEqual(hidden, ["Ирма", "UNKNOWN"])
        XCTAssertEqual(ruling, .undecided, "скрыто, но человека ещё спросят")
    }

    func testDefault_askKeeping_leavesVisibleAndKeepsTheQuestionOpen() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askKeeping)

        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(ruling, .undecided)
    }

    func testDefault_keepSilently_leavesVisibleAndClosesTheQuestion() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .keepSilently)

        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(ruling, .kept)
    }

    /// The four values are two independent axes, not three glued variants.
    func testDefault_axesAreIndependent() {
        XCTAssertEqual(ForeignVoiceDefault.allCases.count, 4)
        XCTAssertEqual(ForeignVoiceDefault.fallback, .askHiding)
        XCTAssertEqual(ForeignVoiceDefault.allCases.filter(\.hides), [.askHiding, .hideSilently])
        XCTAssertEqual(ForeignVoiceDefault.allCases.filter(\.asks), [.askHiding, .askKeeping])
    }

    // MARK: - 6.3, 6.4, 6.6: a decision outranks the setting

    /// 6.4 / 6.6 — a meeting already ruled on is not replayed when the setting
    /// changes and processing runs again.
    func testDecidedMeeting_survivesASettingChange() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .keepSilently)
        let firstRuling = try await decision(f)
        XCTAssertEqual(firstRuling, .kept)

        // The user switches the default to «скрывать без вопроса» and the
        // meeting is reprocessed.
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)

        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertTrue(hidden.isEmpty,
                      "уже прочитанную встречу настройка задним числом не переписывает")
        XCTAssertEqual(ruling, .kept)
    }

    /// 8.3 — a recording started as «несколько людей на микрофоне» carries
    /// «оставлять без вопроса» from the start, whatever the setting says.
    func testMultiSpeakerRecording_neverHidesForeignVoices() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        var meeting = makeMeeting()
        meeting.foreignVoiceDecision = .kept
        try await meetingRepo.save(meeting)

        let owner = makeSpeaker(name: "Захар", isMe: true)
        try await speakerRepo.save(owner)
        let guest = makeSpeaker(name: "Ирма")
        try await speakerRepo.save(guest)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: owner.id, speakerLabel: "Захар",
                        source: .mic, startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 10, endTime: 20),
        ])

        try await ForeignVoicePolicy(db: db)
            .applyDefault(meetingId: meeting.id, setting: .hideSilently)

        let hidden = try await meetingRepo.segments(for: meeting.id).filter(\.isExcluded)
        XCTAssertTrue(hidden.isEmpty, "режим пришпилен встрече и старше настройки")
    }

    // MARK: - an in-person meeting through one mic

    /// Everyone in the room on the mic, the system track silent (it is always
    /// captured, but nobody is on a call), started the ordinary way — no
    /// «Multi-Speaker Mic», the setting at its fallback.
    private func makeInPersonMeeting(ownerSpeaks: Bool) async throws -> (DatabaseManager, Meeting) {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        let owner = makeSpeaker(name: "Захар", isMe: true)
        try await speakerRepo.save(owner)
        let guest = makeSpeaker(name: "Ирма")
        try await speakerRepo.save(guest)

        var segments = [
            makeSegment(meetingId: meeting.id, speakerId: guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 10, endTime: 20),
            makeSegment(meetingId: meeting.id, speakerId: nil, speakerLabel: "UNKNOWN",
                        source: .mic, startTime: 20, endTime: 30),
        ]
        if ownerSpeaks {
            segments.append(makeSegment(meetingId: meeting.id, speakerId: owner.id, speakerLabel: "Захар",
                                        source: .mic, startTime: 0, endTime: 10))
        }
        try await meetingRepo.saveSegments(segments)
        return (db, meeting)
    }

    /// CJM 2026-10-02: the owner did not speak, and every segment was hidden.
    func testInPersonMeeting_ownerSilent_keepsTheWholeTranscript() async throws {
        let (db, meeting) = try await makeInPersonMeeting(ownerSpeaks: false)
        try await ForeignVoicePolicy(db: db).applyDefault(meetingId: meeting.id, setting: .fallback)

        let hidden = try await MeetingRepository(db: db).segments(for: meeting.id).filter(\.isExcluded)
        XCTAssertTrue(hidden.isEmpty, "очная встреча через один микрофон не превращается в пустой транскрипт")
    }

    /// The same meeting with the owner talking: the people in the room are the
    /// meeting, not background, so they stay next to the owner.
    func testInPersonMeeting_ownerSpeaks_keepsTheOthers() async throws {
        let (db, meeting) = try await makeInPersonMeeting(ownerSpeaks: true)
        try await ForeignVoicePolicy(db: db).applyDefault(meetingId: meeting.id, setting: .fallback)

        let hidden = try await MeetingRepository(db: db).segments(for: meeting.id).filter(\.isExcluded)
        XCTAssertEqual(hidden.compactMap(\.speakerLabel), [], "собеседники в комнате — участники, а не фон")
    }

    // MARK: - foreign-voice-reprocess: a decision re-derives, it does not freeze

    /// Reprocessing replaces every segment; auto marks left from the previous
    /// segmentation would cover whatever now sits at those seconds. A meeting
    /// ruled `hidden` re-derives them against the new segments, and the setting
    /// in force at the time does not get to overrule the ruling.
    func testDecidedHidden_reDerivesAutoMarksAgainstTheNewSegmentation() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)
        let firstRuling = try await decision(f)
        let firstMarks = try await autoIntervals(f)
        XCTAssertEqual(firstRuling, .hidden)
        XCTAssertEqual(firstMarks.map(\.0), [10])

        // The reprocess: the same voices, five seconds later on the clock.
        try await f.meetingRepo.deleteSegments(for: f.meeting.id)
        try await f.meetingRepo.saveSegments([
            makeSegment(meetingId: f.meeting.id, speakerId: f.owner.id, speakerLabel: "Захар",
                        source: .mic, startTime: 0, endTime: 15),
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 15, endTime: 35),
            makeSegment(meetingId: f.meeting.id, speakerId: nil, speakerLabel: "Борис",
                        source: .system, startTime: 0, endTime: 35),
        ])
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askKeeping)

        let intervals = try await autoIntervals(f)
        let hidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.0, 15, "метка построена по новым сегментам")
        XCTAssertEqual(intervals.first?.1, 35)
        XCTAssertEqual(hidden, ["Ирма"], "речь владельца не задета")
        XCTAssertEqual(ruling, .hidden, "настройка не переписывает решение")
    }

    /// The mirror case: a meeting ruled `kept` drops the auto marks a previous
    /// pass left behind instead of keeping them alive forever.
    func testDecidedKept_dropsTheAutoMarksOfAnEarlierPass() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)
        let hiddenFirst = try await autoIntervals(f)
        XCTAssertFalse(hiddenFirst.isEmpty)

        try await f.meetingRepo.updateForeignVoiceDecision(f.meeting.id, .kept)
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)

        let leftover = try await autoIntervals(f)
        let stillHidden = try await excludedLabels(f)
        XCTAssertTrue(leftover.isEmpty)
        XCTAssertTrue(stillHidden.isEmpty, "возвращённое остаётся видимым")
    }

    /// Foreign voices gone from the new segmentation is not a reason to keep
    /// the old marks: the early return used to skip `deleteAuto` entirely.
    func testForeignVoicesGone_dropsTheStaleAutoMarks() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)
        let derivedFirst = try await autoIntervals(f)
        XCTAssertFalse(derivedFirst.isEmpty)

        try await f.meetingRepo.deleteSegments(for: f.meeting.id)
        try await f.meetingRepo.saveSegments([
            makeSegment(meetingId: f.meeting.id, speakerId: f.owner.id, speakerLabel: "Захар",
                        source: .mic, startTime: 0, endTime: 30),
        ])
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)

        let leftover = try await autoIntervals(f)
        let hidden = try await excludedLabels(f)
        XCTAssertTrue(leftover.isEmpty)
        XCTAssertTrue(hidden.isEmpty, "владелец не скрыт чужой разметкой")
    }

    // MARK: - 7.4: flipping the answer takes effect immediately

    /// Bringing foreign speech back is a display change: `included` marks over
    /// the same stretches, no reprocess, no re-diarization.
    func testBringingBackForeignSpeech_takesEffectWithoutReprocessing() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)
        let hiddenAtFirst = try await excludedLabels(f)
        XCTAssertEqual(hiddenAtFirst, ["Ирма", "UNKNOWN"])

        let markRepo = MarkRepository(db: f.db)
        let hidden = try await segments(f).filter(\.isExcluded)
        for interval in ForeignVoicePolicy.coalescedIntervals(of: hidden) {
            try await markRepo.add(MeetingMark(
                meetingId: f.meeting.id,
                startTime: interval.start,
                endTime: interval.end,
                track: interval.track,
                kind: .included,
                source: .manual
            ))
        }
        try await markRepo.reprojectAndRecalc(meetingId: f.meeting.id)
        try await f.meetingRepo.updateForeignVoiceDecision(f.meeting.id, .kept)

        let stillHidden = try await excludedLabels(f)
        let ruling = try await decision(f)
        let count = try await segments(f).count
        XCTAssertTrue(stillHidden.isEmpty, "видно сразу, без переобработки")
        XCTAssertEqual(ruling, .kept)
        XCTAssertEqual(count, 4, "сегменты не пересоздавались")
    }

    /// Reprocessing an undecided meeting re-derives the auto marks instead of
    /// piling a second copy on top.
    func testAutoMarksAreReDerivedNotAccumulated() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)

        let marks = try await MarkRepository(db: f.db).marks(for: f.meeting.id)
        XCTAssertEqual(marks.count, 1, "смежные «Ирма» и UNKNOWN склеены в одну полосу")
        XCTAssertTrue(marks.allSatisfy { $0.source == .auto && $0.track == .mic })
    }

    // MARK: - exclusion-marks-fixes: auto marks stay off the user's intervals

    private func autoIntervals(_ f: Fixture) async throws -> [(Double, Double)] {
        try await MarkRepository(db: f.db).marks(for: f.meeting.id)
            .filter { $0.source == .auto }
            .map { ($0.startTime, $0.endTime ?? -1) }
            .sorted { $0.0 < $1.0 }
    }

    private func addMark(_ f: Fixture, _ start: Double, _ end: Double?, kind: MarkKind, source: MarkSource) async throws {
        _ = try await MarkRepository(db: f.db).add(MeetingMark(
            meetingId: f.meeting.id, startTime: start, endTime: end,
            track: .mic, kind: kind, source: source
        ))
    }

    /// Spec «Чужая речь внутри кнопочного интервала»: the button interval
    /// keeps its single mark, auto covers only what lies outside it.
    func testAutoMarks_skipTheButtonInterval() async throws {
        let f = try await makeFixture()
        try await f.meetingRepo.saveSegments([
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 150, endTime: 160),
        ])
        try await addMark(f, 0, 100, kind: .excluded, source: .button)

        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)

        let auto = try await autoIntervals(f)
        XCTAssertEqual(auto.count, 1)
        XCTAssertEqual(auto.first?.0, 150)
        XCTAssertEqual(auto.first?.1, 160)
        let marks = try await MarkRepository(db: f.db).marks(for: f.meeting.id)
        XCTAssertEqual(marks.filter { $0.source == .button }.count, 1, "кнопочная метка одна, без auto поверх")
    }

    /// Spec «Возвращённый кусок переживает повторную обработку»: a manual
    /// `included` inside a foreign run splits the auto marks around it, and a
    /// second derivation leaves the returned segment visible.
    func testManualIncluded_splitsAutoMarks_andSurvivesReDerivation() async throws {
        let f = try await makeFixture()
        try await f.meetingRepo.saveSegments([
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 40, endTime: 50),
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма-возвращённая",
                        source: .mic, startTime: 50, endTime: 60),
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 60, endTime: 70),
        ])
        try await addMark(f, 50, 60, kind: .included, source: .manual)

        for pass in 1 ... 2 {
            try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)
            let auto = try await autoIntervals(f)
            XCTAssertEqual(auto.map { $0.0 }, [10, 40, 60], "проход \(pass)")
            XCTAssertEqual(auto.map { $0.1 }, [30, 50, 70], "проход \(pass)")
            let hidden = try await excludedLabels(f)
            XCTAssertTrue(hidden.contains("Ирма"), "проход \(pass)")
            XCTAssertFalse(hidden.contains("Ирма-возвращённая"), "проход \(pass): возвращённый кусок видим")
        }
    }

    /// Spec «Незакрытый кнопочный интервал»: an open end reaches the end of
    /// the track.
    func testOpenButtonInterval_blocksAutoMarksToTheEnd() async throws {
        let f = try await makeFixture()
        try await f.meetingRepo.saveSegments([
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 40, endTime: 50),
        ])
        try await addMark(f, 25, nil, kind: .excluded, source: .button)

        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)

        let auto = try await autoIntervals(f)
        XCTAssertEqual(auto.map { $0.0 }, [10])
        XCTAssertEqual(auto.map { $0.1 }, [25])
    }

    func testSubtracting_cutsOnlyTheSameTrack() {
        let auto: [(track: SegmentSource, start: Double, end: Double)] = [(.mic, 10, 70), (.system, 10, 70)]
        let user: [(track: SegmentSource, start: Double, end: Double?)] = [(.mic, 30, 40), (.mic, 65, nil)]
        let result = ForeignVoicePolicy.subtracting(userIntervals: user, from: auto)
        XCTAssertEqual(result.map { "\($0.track.rawValue) \($0.start)-\($0.end)" },
                       ["mic 10.0-30.0", "mic 40.0-65.0", "system 10.0-70.0"])
    }

    // MARK: - unnamed, but the owner's best guess

    private func ownerLikelyWindows(_ f: Fixture) async throws -> [Double] {
        try await MarkRepository(db: f.db).marks(for: f.meeting.id)
            .filter { $0.kind == .ownerLikely }.map(\.startTime)
    }

    /// «Не опознан» is not «уверенно чужой»: the unnamed stretch inside an
    /// owner-likely window stays, the neighbour known by name is still hidden,
    /// and the window outlives the pass that re-derives the auto marks.
    func testOwnerLikelyWindow_keepsTheUnnamedVoice_hidesTheNamedOne() async throws {
        let f = try await makeFixture()
        try await MarkRepository(db: f.db).replaceOwnerLikely(meetingId: f.meeting.id, with: [(20, 30)])
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)

        let hidden = try await excludedLabels(f)
        let windows = try await ownerLikelyWindows(f)
        let all = try await segments(f)
        let marks = try await MarkRepository(db: f.db).marks(for: f.meeting.id)
        XCTAssertEqual(hidden, ["Ирма"])
        XCTAssertEqual(windows, [20], "окно не автопометка скрытия — проход политики его не стирает")
        XCTAssertEqual(
            ForeignVoicePolicy.foreignSegments(all, ownerId: f.owner.id, marks: marks).compactMap(\.speakerLabel),
            ["Ирма"], "окно встречи спрашивает про тех же, кого скрыла обработка"
        )
    }

    /// Reprocessing replaces every segment, so the windows of the previous
    /// pass go too; the user's own marks are not theirs to touch.
    func testReplaceOwnerLikely_dropsThePreviousPassOnly() async throws {
        let f = try await makeFixture()
        let repo = MarkRepository(db: f.db)
        try await addMark(f, 0, 5, kind: .excluded, source: .manual)
        try await repo.replaceOwnerLikely(meetingId: f.meeting.id, with: [(20, 30)])
        try await repo.replaceOwnerLikely(meetingId: f.meeting.id, with: [(40, 50), (60, 70)])

        let windows = try await ownerLikelyWindows(f)
        let manual = try await repo.marks(for: f.meeting.id).filter { $0.source == .manual }
        XCTAssertEqual(windows, [40, 60])
        XCTAssertEqual(manual.count, 1)

        try await repo.replaceOwnerLikely(meetingId: f.meeting.id, with: [])
        let cleared = try await ownerLikelyWindows(f)
        XCTAssertEqual(cleared, [])
    }

    /// The live case of 2026-09-04, on synthetic voices: the owner's main mic
    /// cluster, 54 s, scores 0.542 against his 0.55. The matcher still refuses
    /// the name and the labeler still mints `speaker_1` — and the default no
    /// longer hides those 54 seconds as somebody else's.
    func testOwnerClusterJustUnderTheThreshold_staysVisible() async throws {
        let f = try await makeFixture()
        let pool = [
            SpeakerMatcher.Candidate(speakerId: f.owner.id, displayName: "Захар", canonical: [1, 0, 0, 0], segmentCount: 100),
            SpeakerMatcher.Candidate(speakerId: f.guest.id, displayName: "Ирма", canonical: [0, 0, 1, 0], segmentCount: 100),
        ]
        let nearMiss: [Float] = [0.542, (1 - 0.542 * 0.542).squareRoot(), 0, 0]
        let diarization = stride(from: 40.0, to: 94.0, by: 2.0).map {
            DiarizationService.DiarizationSegment(start: $0, end: $0 + 2, speaker: "S5", embedding: nearMiss)
        } + [DiarizationService.DiarizationSegment(start: 10, end: 20, speaker: "S2", embedding: [0, 0, 1, 0])]
        let clusters = Dictionary(grouping: diarization, by: \.speaker)

        let matcher = SpeakerMatcher(config: .mic(ownerId: f.owner.id))
        let results = matcher.matchAllWithAffinity(clusterToSegments: clusters, pool: pool)
        let labeled = ClusterLabeler(config: .default).apply(
            diarization,
            speakerEmbeddings: ["S5": nearMiss, "S2": [0, 0, 1, 0]],
            matchResults: results
        )
        XCTAssertEqual(Set(labeled.segments.map(\.speaker)), ["speaker_1", "Ирма"], "имя владельца кластер не получает")

        // What the pipeline stores for the mic track: the cluster as its own speaker.
        let minted = makeSpeaker(name: "speaker_1")
        try await SpeakerRepository(db: f.db).save(minted)
        try await f.meetingRepo.saveSegments(stride(from: 40.0, to: 94.0, by: 6.0).map {
            makeSegment(meetingId: f.meeting.id, speakerId: minted.id, speakerLabel: "speaker_1",
                        source: .mic, startTime: $0, endTime: $0 + 6)
        })
        let micReplies = try await segments(f).filter { $0.source == .mic }

        let likely = MicAttribution.ownerLikelySegments(
            micReplies,
            clusters: diarization,
            labeled: labeled.segments,
            ownerLikelyClusters: matcher.ownerLikelyClusters(clusterToSegments: clusters, pool: pool, results: results),
            labelToDbId: labeled.labelToDbId
        )
        try await MarkRepository(db: f.db).replaceOwnerLikely(
            meetingId: f.meeting.id,
            with: ForeignVoicePolicy.coalescedIntervals(of: likely).map { ($0.start, $0.end) }
        )
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .fallback)

        let hidden = try await excludedLabels(f)
        XCTAssertEqual(hidden, ["Ирма", "UNKNOWN"], "54 секунды владельца видны; сосед и обрывок без кандидата скрыты, как раньше")
    }

    // MARK: - the speaker filter says who is hidden

    private func filterTitles(_ f: Fixture, questionOpen: Bool) async throws -> [String] {
        let all = try await segments(f)
        let foreign = ForeignVoicePolicy.foreignSegments(all, ownerId: f.owner.id)
        return ForeignVoicePolicy.speakerFilterTitles(all, undecided: questionOpen ? foreign : []).map(\.title)
    }

    /// Nothing hidden: the filter lists plain names, as before.
    func testSpeakerFilterTitles_nothingHidden_plainNames() async throws {
        let f = try await makeFixture()
        let titles = try await filterTitles(f, questionOpen: true)
        XCTAssertEqual(titles, ["UNKNOWN", "Борис", "Захар", "Ирма"])
    }

    /// Hidden by the default with the question still open: the list says the
    /// speaker is hidden and that the participant-or-background answer is due.
    func testSpeakerFilterTitles_hiddenAndUndecided_asksTheBannerQuestion() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .askHiding)
        let titles = try await filterTitles(f, questionOpen: true)
        XCTAssertEqual(titles, [
            "UNKNOWN — hidden · participant or background?",
            "Борис",
            "Захар",
            "Ирма — hidden · participant or background?",
        ])
    }

    /// Hidden with the question closed (ruled background, or hidden by hand):
    /// still marked, nothing left to ask.
    func testSpeakerFilterTitles_hiddenAndDecided_justHidden() async throws {
        let f = try await makeFixture()
        try await f.policy.applyDefault(meetingId: f.meeting.id, setting: .hideSilently)
        let titles = try await filterTitles(f, questionOpen: false)
        XCTAssertEqual(titles, ["UNKNOWN — hidden", "Борис", "Захар", "Ирма — hidden"])
    }

    /// An unnamed voice reads "Speaker 3" in the list; the label it filters by stays raw.
    func testSpeakerFilterTitles_autoLabelReadsAsSpeakerN() {
        let segment = TranscriptSegment(id: 1, meetingId: "m", speakerLabel: "speaker_3", source: .mic,
                                        startTime: 0, endTime: 5, text: "", isExcluded: true)
        let titles = ForeignVoicePolicy.speakerFilterTitles([segment], undecided: [])
        XCTAssertEqual(titles.map(\.label), ["speaker_3"])
        XCTAssertEqual(titles.map(\.title), ["Speaker 3 — hidden"])
        XCTAssertEqual(Speaker.windowLabel("speaker_12"), "Speaker 12")
        XCTAssertEqual(Speaker.windowLabel("speaker_x"), "speaker_x")
    }

    /// One visible segment is enough to stay a plain name: the filter shows it.
    func testSpeakerFilterTitles_partlyHidden_plainName() async throws {
        let f = try await makeFixture()
        try await addMark(f, 0, 30, kind: .excluded, source: .manual)
        try await MarkRepository(db: f.db).reproject(meetingId: f.meeting.id)
        try await f.meetingRepo.saveSegments([
            makeSegment(meetingId: f.meeting.id, speakerId: f.guest.id, speakerLabel: "Ирма",
                        source: .mic, startTime: 40, endTime: 50),
        ])
        let titles = try await filterTitles(f, questionOpen: false)
        XCTAssertEqual(titles, ["UNKNOWN — hidden", "Борис", "Захар — hidden", "Ирма"])
    }

    // MARK: - 2.4: pool hygiene still guards minting

    /// The guard that makes minting on the mic track safe: a freshly minted,
    /// unnamed `speaker_N` never joins the pool the next meeting matches
    /// against. Naming the person restores membership.
    func testFreshlyMintedSpeakerStaysOutOfTheMatchingPool() async throws {
        let db = try makeTestDB()
        let speakerRepo = SpeakerRepository(db: db)

        let embedding = Data(repeating: 0, count: 4 * 192)
        var minted = makeSpeaker(name: "speaker_7")
        minted.embedding = embedding
        minted.isConfirmed = false
        try await speakerRepo.save(minted)

        var named = makeSpeaker(name: "Ирма")
        named.embedding = embedding
        named.isConfirmed = true
        try await speakerRepo.save(named)

        let pool = try await speakerRepo.speakersWithEmbeddings(space: .v1)
            .filter(\.isEligibleForMatchingPool)

        XCTAssertEqual(pool.map(\.displayName), ["Ирма"])
        XCTAssertFalse(minted.isEligibleForMatchingPool)

        minted.isConfirmed = true
        XCTAssertTrue(minted.isEligibleForMatchingPool, "названного человека пул принимает")
    }
}

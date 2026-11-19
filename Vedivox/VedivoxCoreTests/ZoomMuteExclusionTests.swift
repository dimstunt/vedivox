import XCTest

/// Zoom-mute periods become mic-track exclusion marks (zoom-mute-exclusion).
final class ZoomMuteExclusionTests: XCTestCase {

    // MARK: Tracker (design D3)

    private func run(_ observations: [(MuteState, TimeInterval)]) -> (closed: [ClosedRange<TimeInterval>], tracker: StateIntervalTracker) {
        var tracker = StateIntervalTracker(.muted)
        var closed: [ClosedRange<TimeInterval>] = []
        for (state, at) in observations {
            if let range = tracker.observe(state, at: at) { closed.append(range) }
        }
        return (closed, tracker)
    }

    private func polls(_ state: MuteState, from start: TimeInterval, to end: TimeInterval) -> [(MuteState, TimeInterval)] {
        stride(from: start, through: end, by: 0.5).map { (state, $0) }
    }

    func testMutePeriodSpansFirstToLastMutedObservation() {
        let (closed, _) = run(polls(.unmuted, from: 0, to: 119.5) + polls(.muted, from: 120, to: 179.5) + [(.unmuted, 180)])
        XCTAssertEqual(closed, [120.0 ... 179.5])
    }

    func testRecordingStartedWhileMuted() {
        let (closed, _) = run(polls(.muted, from: 0.3, to: 39.8) + [(.unmuted, 40.3)])
        XCTAssertEqual(closed, [0.3 ... 39.8], "начало — первое наблюдение")
    }

    func testSignalLossClosesOnLastMuted() {
        let (closed, _) = run(polls(.muted, from: 10, to: 20) + [(.unknown, 20.5), (.muted, 21)])
        XCTAssertEqual(closed, [10.0 ... 20.0], "пропадание сигнала закрывает интервал, новое наблюдение — новый период")
    }

    func testMuteShorterThanOneStepYieldsNothing() {
        var (closed, tracker) = run([(.unmuted, 0), (.muted, 0.5), (.unmuted, 1)])
        XCTAssertEqual(closed, [])
        XCTAssertNil(tracker.finish())
    }

    func testStopWhileMutedClosesPeriod() {
        var (closed, tracker) = run(polls(.muted, from: 5, to: 9))
        XCTAssertEqual(closed, [])
        XCTAssertEqual(tracker.finish(), 5.0 ... 9.0)
        XCTAssertNil(tracker.finish(), "закрытый период не отдаётся дважды")
    }

    /// What the live transcript hides by before any mark is written.
    func testOpenPeriodIsKnownFromItsFirstObservationUntilItCloses() {
        var tracker = StateIntervalTracker(.muted)
        XCTAssertNil(tracker.openStart)

        _ = tracker.observe(.unmuted, at: 1)
        XCTAssertNil(tracker.openStart)

        _ = tracker.observe(.muted, at: 2)
        _ = tracker.observe(.muted, at: 2.5)
        XCTAssertEqual(tracker.openStart, 2)

        _ = tracker.observe(.unmuted, at: 3)
        XCTAssertNil(tracker.openStart, "an unmute closes it")

        _ = tracker.observe(.muted, at: 4)
        _ = tracker.finish()
        XCTAssertNil(tracker.openStart, "so does the end of the recording")
    }

    func testEnabledByDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "zoom-mute-\(UUID().uuidString)"))
        XCTAssertTrue(MuteMonitor.isEnabled(defaults: defaults))
        defaults.set(false, forKey: MuteMonitor.enabledKey)
        XCTAssertFalse(MuteMonitor.isEnabled(defaults: defaults))
    }

    // MARK: Marks (design D4)

    func testZoomMuteMarkHidesMicOnlyAndSurvivesReprocess() async throws {
        let db = try makeTestDB()
        let meetings = MeetingRepository(db: db)
        let marks = MarkRepository(db: db)
        let meeting = makeMeeting()
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 120, endTime: 130),
            makeSegment(meetingId: meeting.id, source: .system, startTime: 120, endTime: 130),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 200, endTime: 210),
        ])
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 120, endTime: 179.5,
            track: .mic, kind: .excluded, source: .zoomMute
        ))

        // Reprocess drops only the re-derived marks.
        try await marks.deleteAuto(meetingId: meeting.id)
        _ = try await marks.reproject(meetingId: meeting.id)

        let segments = try await meetings.segments(for: meeting.id)
        let micInside = try XCTUnwrap(segments.first { $0.source == .mic && $0.startTime == 120 })
        let systemInside = try XCTUnwrap(segments.first { $0.source == .system })
        let micOutside = try XCTUnwrap(segments.first { $0.startTime == 200 })
        XCTAssertTrue(micInside.isExcluded, "сказанное на мьюте скрыто")
        XCTAssertFalse(systemInside.isExcluded, "участники звонка видимы")
        XCTAssertFalse(micOutside.isExcluded)
    }

    /// A row written by a newer build must not make the meeting unopenable.
    func testUnknownKindAndSourceStillLoad() async throws {
        let db = try makeTestDB()
        let meetings = MeetingRepository(db: db)
        let marks = MarkRepository(db: db)
        let meeting = makeMeeting()
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 10, endTime: 20),
        ])
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO meeting_marks (meetingId, startTime, endTime, track, kind, source) VALUES (?, 10, 20, 'mic', 'fromTheFuture', 'futureSource')",
                arguments: [meeting.id]
            )
        }

        let loaded = try await marks.marks(for: meeting.id)
        XCTAssertEqual(loaded.map(\.kind.rawValue), ["fromTheFuture"])
        XCTAssertEqual(loaded.map(\.source.rawValue), ["futureSource"])
        _ = try await marks.reproject(meetingId: meeting.id)
        let segments = try await meetings.segments(for: meeting.id)
        XCTAssertFalse(try XCTUnwrap(segments.first).isExcluded, "незнакомый вид не скрывает")
    }

    func testUserReturnOverridesZoomMuteMark() async throws {
        let db = try makeTestDB()
        let meetings = MeetingRepository(db: db)
        let marks = MarkRepository(db: db)
        let meeting = makeMeeting()
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 120, endTime: 130),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 140, endTime: 150),
        ])
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 120, endTime: 179.5,
            track: .mic, kind: .excluded, source: .zoomMute
        ))
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 140, endTime: 150,
            track: .mic, kind: .included, source: .manual
        ))
        _ = try await marks.reproject(meetingId: meeting.id)

        let segments = try await meetings.segments(for: meeting.id)
        XCTAssertTrue(try XCTUnwrap(segments.first { $0.startTime == 120 }).isExcluded)
        XCTAssertFalse(try XCTUnwrap(segments.first { $0.startTime == 140 }).isExcluded, "возврат пользователя сильнее мьюта")
    }

    // MARK: Unmuted windows (zoom-unmuted-keeps-mic)

    func testUnmutedTrackerClosesOnMute() {
        var tracker = StateIntervalTracker(.unmuted)
        var closed: [ClosedRange<TimeInterval>] = []
        for (state, at) in [(MuteState.muted, 390.5), (.unmuted, 391.2), (.unmuted, 391.7), (.unmuted, 392.7), (.muted, 393.3)] {
            if let range = tracker.observe(state, at: at) { closed.append(range) }
        }
        XCTAssertEqual(closed, [391.2 ... 392.7])
    }

    private func mark(_ kind: MarkKind, _ start: Double, _ end: Double, source: MarkSource = .zoomMute, createdAt: Date = Date()) -> MeetingMark {
        MeetingMark(meetingId: "m", startTime: start, endTime: end, track: .mic, kind: kind, source: source, createdAt: createdAt)
    }

    func testUnmutedWindowNeverChangesVisibility() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        let userExclusion = mark(.excluded, 0, 60, source: .button, createdAt: earlier)
        let window = mark(.zoomUnmuted, 0, 100, createdAt: later)
        XCTAssertTrue(ExclusionProjection.isExcluded(segmentStart: 10, segmentEnd: 20, track: .mic, marks: [userExclusion, window]),
                      "более позднее окно анмьюта не перебивает ручное скрытие")
        XCTAssertFalse(ExclusionProjection.isExcluded(segmentStart: 70, segmentEnd: 80, track: .mic, marks: [userExclusion, window]))
    }

    func testSpeechInUnmutedWindowIsNotForeign() {
        let owner = "me"
        let inside = makeSegment(meetingId: "m", speakerId: "other", source: .mic, startTime: 391.3, endTime: 392.5)
        let outside = makeSegment(meetingId: "m", speakerId: "other", source: .mic, startTime: 500, endTime: 502)
        let mostlyOutside = makeSegment(meetingId: "m", speakerId: "other", source: .mic, startTime: 392.0, endTime: 394.0)
        // A call: turns the rule off for meetings with no system speech.
        let call = makeSegment(meetingId: "m", speakerId: "far", source: .system, startTime: 380, endTime: 385)
        let window = mark(.zoomUnmuted, 391.2, 392.7)

        let foreign = ForeignVoicePolicy.foreignSegments([call, inside, outside, mostlyOutside], ownerId: owner, marks: [window])
        XCTAssertEqual(foreign.map(\.startTime), [500, 392.0], "внутри окна — не чужая; покрыто 35 % — чужая")
        XCTAssertEqual(ForeignVoicePolicy.foreignSegments([call, inside], ownerId: owner).count, 1, "без окон всё как раньше")
    }
}

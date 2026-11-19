import XCTest

/// The recording-time toggle only writes rows in `meeting_marks` — lookback
/// on activation, close on deactivation/stop, auto-expiry against the
/// forgotten-off failure mode (transcript-exclusion-marks, group 5).
@MainActor
final class ExclusionToggleTests: XCTestCase {
    private var db: DatabaseManager!
    private var marks: MarkRepository!
    private var toggle: ExclusionToggle!
    private var meetingId: String!

    override func setUp() async throws {
        db = try makeTestDB()
        marks = MarkRepository(db: db)
        toggle = ExclusionToggle(markRepo: marks)
        let meeting = makeMeeting()
        try await MeetingRepository(db: db).save(meeting)
        meetingId = meeting.id
    }

    func testActivateOpensIntervalWithLookback() async throws {
        toggle.config.lookback = 15
        await toggle.activate(meetingId: meetingId, elapsed: 60)

        XCTAssertTrue(toggle.isActive)
        let all = try await marks.marks(for: meetingId)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].startTime, 45, "старт — на lookback раньше нажатия")
        XCTAssertNil(all[0].endTime, "интервал открыт, пока режим активен")
        XCTAssertEqual(all[0].source, .button)
        XCTAssertEqual(all[0].kind, .excluded)
        XCTAssertEqual(all[0].track, .mic)
    }

    func testLookbackClampsToRecordingStart() async throws {
        toggle.config.lookback = 15
        await toggle.activate(meetingId: meetingId, elapsed: 5)

        let all = try await marks.marks(for: meetingId)
        XCTAssertEqual(all.first?.startTime, 0)
    }

    func testDeactivateClosesInterval() async throws {
        await toggle.activate(meetingId: meetingId, elapsed: 30)
        await toggle.deactivate(elapsed: 90)

        XCTAssertFalse(toggle.isActive)
        let all = try await marks.marks(for: meetingId)
        XCTAssertEqual(all.first?.endTime, 90)
    }

    func testRecordingStopClosesAndSummarises() async throws {
        toggle.config.lookback = 0
        await toggle.activate(meetingId: meetingId, elapsed: 100)

        let excluded = await toggle.recordingStopped(meetingId: meetingId, duration: 160)
        XCTAssertFalse(toggle.isActive)
        XCTAssertEqual(excluded, 60, accuracy: 0.001, "сводка считает закрытый интервал 100–160")

        let all = try await marks.marks(for: meetingId)
        XCTAssertEqual(all.first?.endTime, 160)
    }

    func testAutoExpiryClosesIntervalAndNotifies() async throws {
        toggle.config.lookback = 0
        toggle.config.autoExpiry = 0.1

        let expired = expectation(description: "auto-expire fired")
        toggle.onAutoExpire = { expired.fulfill() }

        await toggle.activate(meetingId: meetingId, elapsed: 10)
        await fulfillment(of: [expired], timeout: 2)

        XCTAssertFalse(toggle.isActive)
        let all = try await marks.marks(for: meetingId)
        XCTAssertEqual(all.first?.endTime ?? -1, 10.1, accuracy: 0.001, "интервал закрыт на момент экспирации")
    }

    // MARK: - exclusion-marks-fixes: the limit is a setting, 0 = never

    func testStoredAutoExpiry_defaultsToThirtyMinutes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExclusionToggleTests-\(UUID().uuidString)"))
        XCTAssertEqual(ExclusionToggle.Config.storedAutoExpiry(defaults: defaults), 1800)
    }

    func testStoredAutoExpiry_readsTheKey_zeroMeansNever() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExclusionToggleTests-\(UUID().uuidString)"))
        defaults.set(0, forKey: ExclusionToggle.Config.autoExpiryKey)
        XCTAssertEqual(ExclusionToggle.Config.storedAutoExpiry(defaults: defaults), 0)
        defaults.set(2700.0, forKey: ExclusionToggle.Config.autoExpiryKey)
        XCTAssertEqual(ExclusionToggle.Config.storedAutoExpiry(defaults: defaults), 2700)
    }

    func testAutoExpiryZero_keepsTheIntervalOpen() async throws {
        toggle.config.lookback = 0
        toggle.config.autoExpiry = 0
        var fired = false
        toggle.onAutoExpire = { fired = true }

        await toggle.activate(meetingId: meetingId, elapsed: 10)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(toggle.isActive, "без лимита режим живёт, пока его не выключат")
        XCTAssertFalse(fired)
        let all = try await marks.marks(for: meetingId)
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.endTime, "интервал остаётся открытым")
    }

    func testAutoExpiryIsReadAtActivation() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExclusionToggleTests-\(UUID().uuidString)"))
        toggle.config.lookback = 0
        toggle.config.defaults = defaults
        var expiredCount = 0
        toggle.onAutoExpire = { expiredCount += 1 }

        defaults.set(0, forKey: ExclusionToggle.Config.autoExpiryKey)
        await toggle.activate(meetingId: meetingId, elapsed: 10)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(toggle.isActive, "Never in Settings — no expiry")
        await toggle.deactivate(elapsed: 12)

        // Changed after the toggle was created: the next activation honours it.
        defaults.set(0.1, forKey: ExclusionToggle.Config.autoExpiryKey)
        await toggle.activate(meetingId: meetingId, elapsed: 20)
        // Polled, not a fixed sleep: a loaded machine may fire the 0.1 s timer late.
        for _ in 0 ..< 250 where toggle.isActive { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(toggle.isActive)
        XCTAssertEqual(expiredCount, 1)
    }

    func testDeactivateCancelsExpiry() async throws {
        toggle.config.autoExpiry = 0.1
        var fired = false
        toggle.onAutoExpire = { fired = true }

        await toggle.activate(meetingId: meetingId, elapsed: 10)
        await toggle.deactivate(elapsed: 12)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(fired, "закрытый вручную интервал не должен экспирировать")
    }
}

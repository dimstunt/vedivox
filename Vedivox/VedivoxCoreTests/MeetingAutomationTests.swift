import XCTest

/// Start/stop decisions around a detected meeting.
final class MeetingAutomationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testDefaultsKeepNotificationsOnly() {
        let defaults = UserDefaults(suiteName: "MeetingAutomationTests-\(UUID())")!
        let automation = MeetingAutomation.load(from: defaults)
        XCTAssertFalse(automation.autoStart)
        XCTAssertFalse(automation.autoStop)
        XCTAssertEqual(automation.endThreshold, 15)
        XCTAssertEqual(automation.reminderInterval, 60)
        XCTAssertFalse(automation.shouldAutoStart(isRecording: false, lastManualStop: nil, now: t0))
    }

    /// Settings and `startDetection()` must agree on an unset key: Settings
    /// once showed «on» while a fresh install detected nothing.
    func testDetectionIsOptIn() {
        let defaults = UserDefaults(suiteName: "MeetingAutomationTests-\(UUID())")!
        XCTAssertFalse(MeetingAutomation.detectionEnabledByDefault)
        XCTAssertEqual(MeetingAutomation.isDetectionEnabled(in: defaults), MeetingAutomation.detectionEnabledByDefault)
        defaults.set(true, forKey: MeetingAutomation.detectionEnabledKey)
        XCTAssertTrue(MeetingAutomation.isDetectionEnabled(in: defaults))
    }

    func testLoadsStoredValues() {
        let defaults = UserDefaults(suiteName: "MeetingAutomationTests-\(UUID())")!
        defaults.set(true, forKey: MeetingAutomation.autoStartKey)
        defaults.set(true, forKey: MeetingAutomation.autoStopKey)
        defaults.set(30.0, forKey: MeetingAutomation.endThresholdKey)
        defaults.set(120.0, forKey: MeetingAutomation.reminderIntervalKey)
        XCTAssertEqual(
            MeetingAutomation.load(from: defaults),
            MeetingAutomation(autoStart: true, autoStop: true, endThreshold: 30, reminderInterval: 120)
        )
    }

    func testAutoStartOnlyWhenEnabledAndIdle() {
        let on = MeetingAutomation(autoStart: true)
        XCTAssertTrue(on.shouldAutoStart(isRecording: false, lastManualStop: nil, now: t0))
        XCTAssertFalse(on.shouldAutoStart(isRecording: true, lastManualStop: nil, now: t0))
    }

    func testManualStopBlocksAutoStartForAWhile() {
        let on = MeetingAutomation(autoStart: true)
        XCTAssertFalse(on.shouldAutoStart(isRecording: false, lastManualStop: t0, now: at(60)))
        XCTAssertTrue(on.shouldAutoStart(isRecording: false, lastManualStop: t0, now: at(600)))
    }

    func testFirstReminderAtOnceThenOncePerInterval() {
        let notify = MeetingAutomation()
        XCTAssertEqual(notify.afterMeetingEnded(lastReminder: nil, lastSpeech: nil, now: t0), .remind)
        XCTAssertEqual(notify.afterMeetingEnded(lastReminder: t0, lastSpeech: nil, now: at(55)), .none)
        XCTAssertEqual(notify.afterMeetingEnded(lastReminder: t0, lastSpeech: nil, now: at(60)), .remind)
    }

    func testSpeechHoldsBackRepeatsButNotTheFirstReminder() {
        let notify = MeetingAutomation()
        XCTAssertEqual(notify.afterMeetingEnded(lastReminder: nil, lastSpeech: t0, now: t0), .remind)
        XCTAssertEqual(notify.afterMeetingEnded(lastReminder: t0, lastSpeech: at(65), now: at(70)), .none)
        XCTAssertEqual(notify.afterMeetingEnded(lastReminder: t0, lastSpeech: at(60), now: at(70)), .remind)
    }

    func testAutoStopWarnsFirstAndStopsAfterOneInterval() {
        let auto = MeetingAutomation(autoStop: true)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: nil, lastSpeech: nil, now: t0), .remind)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: nil, now: at(30)), .none)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: nil, now: at(60)), .stop)
    }

    func testSpeechPostponesAutoStop() {
        let auto = MeetingAutomation(autoStop: true)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: at(58), now: at(60)), .none)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: at(58), now: at(70)), .stop)
    }

    func testCountdownReachesZeroWhenTheLoopStops() {
        let auto = MeetingAutomation(autoStop: true, reminderInterval: 30)
        func left(_ speech: Date?, _ now: TimeInterval) -> Int? {
            auto.endedIndicator(tick: 0, lastReminder: t0, lastSpeech: speech, now: at(now), reduceMotion: false).secondsLeft
        }
        XCTAssertEqual(left(nil, 0), 30)
        XCTAssertEqual(left(nil, 29.5), 1)
        XCTAssertEqual(left(nil, 30), 0)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: nil, now: at(30)), .stop)
        // Speech at 28 s holds the stop until 38 s, and the countdown says so.
        XCTAssertEqual(left(at(28), 30), 8)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: at(28), now: at(37)), .none)
        XCTAssertEqual(left(at(28), 38), 0)
        XCTAssertEqual(auto.afterMeetingEnded(lastReminder: t0, lastSpeech: at(28), now: at(38)), .stop)
    }

    func testNoCountdownWithoutAutoStop() {
        let notify = MeetingAutomation()
        XCTAssertNil(notify.endedIndicator(tick: 0, lastReminder: t0, lastSpeech: nil, now: at(5), reduceMotion: false).secondsLeft)
        XCTAssertNil(notify.autoStopDue(lastReminder: t0, lastSpeech: nil))
    }

    func testBlinksEverySecondUnlessReduceMotion() {
        let auto = MeetingAutomation(autoStop: true)
        let phases = (0..<4).map {
            auto.endedIndicator(tick: $0, lastReminder: t0, lastSpeech: nil, now: t0, reduceMotion: false).highlighted
        }
        XCTAssertEqual(phases, [true, false, true, false])
        XCTAssertTrue(auto.endedIndicator(tick: 1, lastReminder: t0, lastSpeech: nil, now: t0, reduceMotion: true).highlighted)
    }
}

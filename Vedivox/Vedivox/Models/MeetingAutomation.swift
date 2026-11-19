import Foundation

/// What Vedivox does on its own when a detected meeting starts and ends.
///
/// Start and stop are separate switches because one call often runs straight
/// into the next: a recording started automatically may still be one the user
/// wants to stop by hand. Both are off by default — only notifications, as
/// before the setting existed.
///
/// Pure: the caller feeds clocks in and acts on the answer, so the timing rules
/// are testable without a detector, a recording or a notification centre.
struct MeetingAutomation: Equatable {
    enum Action: Equatable {
        case none
        /// «Meeting appears to have ended — stop?» (in auto-stop mode it also
        /// warns that the recording is about to stop).
        case remind
        case stop
    }

    /// The status item while a recording outlives its meeting: it blinks so the
    /// end is noticed where the recording is controlled, not only in a banner.
    struct EndedIndicator: Equatable {
        /// Blink phase: the attention icon or the plain recording one. Always
        /// on under Reduce Motion.
        var highlighted: Bool
        /// Seconds to the auto stop; nil when the stop is the user's to make.
        var secondsLeft: Int?
    }

    /// Meeting detection itself is opt-in: an unset key means off,
    /// so the browser Apple Events and notification prompts never fire on a fresh
    /// install. The one place for that default — Settings shows the same value.
    static let detectionEnabledKey = "meetingDetectionEnabled"
    static let detectionEnabledByDefault = false

    static func isDetectionEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: detectionEnabledKey) as? Bool ?? detectionEnabledByDefault
    }

    static let autoStartKey = "meetingAutoStart"
    static let autoStopKey = "meetingAutoStop"
    static let endThresholdKey = "meetingEndThreshold"
    static let reminderIntervalKey = "meetingEndReminderInterval"

    /// Quiet meeting-app mic this long reads as «the meeting ended». Was a fixed
    /// 30 s, which with the 5 s poll put the first reminder 35–40 s after the call.
    static let defaultEndThreshold: TimeInterval = 15
    /// Was a fixed 3 min between reminders.
    static let defaultReminderInterval: TimeInterval = 60
    /// Mic speech this recent means the conversation goes on (offline, or in an
    /// app the detector does not watch): no repeat reminder, no auto stop.
    static let speechHold: TimeInterval = 10
    /// A recording the user stopped by hand this recently blocks an auto start:
    /// a muted call that drops out and comes back is a «new» detection, and it
    /// must not restart a recording the user just stopped. The fallback is the
    /// plain «Meeting detected» notification.
    static let manualStopCooldown: TimeInterval = 600

    var autoStart = false
    var autoStop = false
    var endThreshold = defaultEndThreshold
    var reminderInterval = defaultReminderInterval

    static func load(from defaults: UserDefaults = .standard) -> MeetingAutomation {
        MeetingAutomation(
            autoStart: defaults.bool(forKey: autoStartKey),
            autoStop: defaults.bool(forKey: autoStopKey),
            endThreshold: positive(defaults.double(forKey: endThresholdKey)) ?? defaultEndThreshold,
            reminderInterval: positive(defaults.double(forKey: reminderIntervalKey)) ?? defaultReminderInterval
        )
    }

    /// A meeting was just detected: start recording without asking?
    func shouldAutoStart(isRecording: Bool, lastManualStop: Date?, now: Date) -> Bool {
        guard autoStart, !isRecording else { return false }
        guard let lastManualStop else { return true }
        return now.timeIntervalSince(lastManualStop) >= Self.manualStopCooldown
    }

    /// One tick while a recording outlives its meeting. The first reminder goes
    /// out at once; after that one per `reminderInterval`, held back while the
    /// mic hears speech. In auto-stop mode the second due reminder is the stop,
    /// so a room change or a reconnect gets `endThreshold + reminderInterval`
    /// before anything is cut.
    func afterMeetingEnded(lastReminder: Date?, lastSpeech: Date?, now: Date) -> Action {
        guard let lastReminder else { return .remind }
        guard now.timeIntervalSince(lastReminder) >= reminderInterval else { return .none }
        if let lastSpeech, now.timeIntervalSince(lastSpeech) < Self.speechHold { return .none }
        return autoStop ? .stop : .remind
    }

    /// When `afterMeetingEnded` will answer `.stop`: one reminder interval after
    /// the warning, pushed back while the mic hears speech. Nil without auto stop
    /// or before the warning went out.
    func autoStopDue(lastReminder: Date?, lastSpeech: Date?) -> Date? {
        guard autoStop, let lastReminder else { return nil }
        let due = lastReminder.addingTimeInterval(reminderInterval)
        guard let lastSpeech else { return due }
        return max(due, lastSpeech.addingTimeInterval(Self.speechHold))
    }

    /// What the status item shows on the `tick`-th second of the after-meeting loop.
    func endedIndicator(
        tick: Int, lastReminder: Date?, lastSpeech: Date?, now: Date, reduceMotion: Bool
    ) -> EndedIndicator {
        let left = autoStopDue(lastReminder: lastReminder, lastSpeech: lastSpeech)
            .map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
        return EndedIndicator(highlighted: reduceMotion || tick.isMultiple(of: 2), secondsLeft: left)
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }
}

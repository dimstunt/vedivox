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
    static let autoStopDelayKey = "meetingAutoStopDelay"
    static let speechHoldKey = "meetingEndSpeechHold"

    /// Quiet meeting-app mic this long reads as «the meeting ended». Was a fixed
    /// 30 s, which with the 5 s poll put the first reminder 35–40 s after the call.
    static let defaultEndThreshold: TimeInterval = 15
    /// Was a fixed 3 min between reminders.
    static let defaultReminderInterval: TimeInterval = 60
    /// With auto stop: quiet call to stopped recording. Was the end threshold
    /// plus one reminder interval, ~80 s; a call is usually just left (#5).
    static let defaultAutoStopDelay: TimeInterval = 10
    /// With auto stop the detector calls the end after this much of `autoStopDelay`;
    /// the rest is the warning with its countdown and «Keep recording».
    static let autoStopDebounce: TimeInterval = 3
    /// Mic speech this recent means the conversation goes on (offline, or in an
    /// app the detector does not watch): no repeat reminder, no auto stop. 0 is off.
    static let defaultSpeechHold: TimeInterval = 10
    /// A call that comes back this soon after an auto stop records again even
    /// with auto start off: the stop was a reconnect or a room change, not the
    /// end. The logs had 7 of 85 ends back within 5–31 s.
    static let autoStopRestartWindow: TimeInterval = 120
    /// A recording the user stopped by hand this recently blocks an auto start:
    /// a muted call that drops out and comes back is a «new» detection, and it
    /// must not restart a recording the user just stopped. The fallback is the
    /// plain «Meeting detected» notification.
    static let manualStopCooldown: TimeInterval = 600

    var autoStart = false
    var autoStop = false
    var endThreshold = defaultEndThreshold
    var reminderInterval = defaultReminderInterval
    var autoStopDelay = defaultAutoStopDelay
    var speechHold = defaultSpeechHold

    static func load(from defaults: UserDefaults = .standard) -> MeetingAutomation {
        MeetingAutomation(
            autoStart: defaults.bool(forKey: autoStartKey),
            autoStop: defaults.bool(forKey: autoStopKey),
            endThreshold: positive(defaults.double(forKey: endThresholdKey)) ?? defaultEndThreshold,
            reminderInterval: positive(defaults.double(forKey: reminderIntervalKey)) ?? defaultReminderInterval,
            autoStopDelay: positive(defaults.double(forKey: autoStopDelayKey)) ?? defaultAutoStopDelay,
            // 0 is a value here (off), so an unset key is told apart from it.
            speechHold: (defaults.object(forKey: speechHoldKey) as? Double).map { max(0, $0) } ?? defaultSpeechHold
        )
    }

    /// Quiet this long and the detector reports the end: the whole wait in
    /// remind mode, a short debounce of `autoStopDelay` in auto-stop mode.
    var detectorThreshold: TimeInterval {
        autoStop ? min(Self.autoStopDebounce, autoStopDelay) : endThreshold
    }

    /// From the first reminder to the next one, or to the auto stop.
    var waitAfterReminder: TimeInterval {
        autoStop ? autoStopDelay - detectorThreshold : reminderInterval
    }

    /// A meeting was just detected: start recording without asking? A call
    /// back soon after an auto stop always is (`autoStopRestartWindow`),
    /// unless the user stopped a recording by hand since.
    func shouldAutoStart(isRecording: Bool, lastManualStop: Date?, lastAutoStop: Date? = nil, now: Date) -> Bool {
        guard !isRecording else { return false }
        if let lastAutoStop, now.timeIntervalSince(lastAutoStop) < Self.autoStopRestartWindow,
           lastManualStop.map({ $0 < lastAutoStop }) ?? true {
            return true
        }
        guard autoStart else { return false }
        guard let lastManualStop else { return true }
        return now.timeIntervalSince(lastManualStop) >= Self.manualStopCooldown
    }

    /// One tick while a recording outlives its meeting. The first reminder goes
    /// out at once; after that one per `waitAfterReminder`, held back while the
    /// mic hears speech. In auto-stop mode the second due reminder is the stop,
    /// so a room change or a reconnect gets `autoStopDelay` before anything is
    /// cut, and a call back soon after records again (`shouldAutoStart`).
    func afterMeetingEnded(lastReminder: Date?, lastSpeech: Date?, now: Date) -> Action {
        guard let lastReminder else { return .remind }
        guard now.timeIntervalSince(lastReminder) >= waitAfterReminder else { return .none }
        if let lastSpeech, now.timeIntervalSince(lastSpeech) < speechHold { return .none }
        return autoStop ? .stop : .remind
    }

    /// When `afterMeetingEnded` will answer `.stop`: `waitAfterReminder` after
    /// the warning, pushed back while the mic hears speech. Nil without auto stop
    /// or before the warning went out.
    func autoStopDue(lastReminder: Date?, lastSpeech: Date?) -> Date? {
        guard autoStop, let lastReminder else { return nil }
        let due = lastReminder.addingTimeInterval(waitAfterReminder)
        guard let lastSpeech else { return due }
        return max(due, lastSpeech.addingTimeInterval(speechHold))
    }

    /// What the status item shows on the `tick`-th second of the after-meeting loop.
    func endedIndicator(
        tick: Int, lastReminder: Date?, lastSpeech: Date?, now: Date, reduceMotion: Bool
    ) -> EndedIndicator {
        let left = autoStopDue(lastReminder: lastReminder, lastSpeech: lastSpeech)
            .map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
        return EndedIndicator(highlighted: reduceMotion || tick.isMultiple(of: 2), secondsLeft: left)
    }

    /// The mic speech that holds a meeting open: not the user's own dictation,
    /// which goes out of the meeting anyway (#5: «left the call and dictated»).
    static func meetingSpeech(lastMicSpeech: Date?, dictating: Bool, lastDictationEnd: Date?) -> Date? {
        guard !dictating, let lastMicSpeech else { return nil }
        // 1 s: the meeting tap still reports the last dictated words after the hotkey is let go.
        if let lastDictationEnd, lastMicSpeech <= lastDictationEnd.addingTimeInterval(1) { return nil }
        return lastMicSpeech
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }
}

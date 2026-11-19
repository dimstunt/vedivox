import AppKit
import UserNotifications

/// Manages meeting detection and recording notifications.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let startRecordingAction = "START_RECORDING"
    static let keepRecordingAction = "KEEP_RECORDING"
    static let meetingDetectedCategory = "MEETING_DETECTED"
    static let meetingEndedCategory = "MEETING_ENDED"
    /// Fixed identifier: each reminder replaces the previous one instead of
    /// piling up in Notification Center, and cancel can remove it by id.
    private static let meetingEndedIdentifier = "meeting-ended-reminder"

    var onStartRecordingRequested: (@MainActor () -> Void)?
    /// Every second of the after-the-meeting loop, then nil when it ends: the
    /// status item blinks, counts down and offers Keep Recording.
    var onMeetingEndedIndicator: (@MainActor (MeetingAutomation.EndedIndicator?) -> Void)?

    /// Repeats the "stop recording?" reminder while a recording outlives its meeting.
    private var endedReminderTask: Task<Void, Never>?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // No .foreground option: actions must fire without activating Vedivox so
        // the user stays in whatever app they are in.
        let startAction = UNNotificationAction(
            identifier: Self.startRecordingAction,
            title: "Start Recording",
            options: []
        )

        let keepAction = UNNotificationAction(
            identifier: Self.keepRecordingAction,
            title: "Keep Recording",
            options: []
        )

        let detectedCategory = UNNotificationCategory(
            identifier: Self.meetingDetectedCategory,
            actions: [startAction],
            intentIdentifiers: []
        )
        let endedCategory = UNNotificationCategory(
            identifier: Self.meetingEndedCategory,
            // One action: macOS shows it as a button, two go under Options.
            // Stop lives in the menu bar.
            actions: [keepAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([detectedCategory, endedCategory])
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func notifyMeetingDetected(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = name
        content.sound = .default
        content.categoryIdentifier = Self.meetingDetectedCategory

        let request = UNNotificationRequest(
            identifier: "meeting-detected-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Reports a dictation that did not land in a text field.
    ///
    /// This is the only channel that reaches the user here. The HUD is gone by
    /// the time insertion is attempted — it goes away with the recording — and
    /// the main-window banner is invisible because dictation happens with Vedivox
    /// in the background, a mistake already made twice in this project
    ///
    /// `textInClipboard` decides whether the notification offers a way out.
    /// Promising «paste it with ⌘V» when nothing was recognised would send the
    /// user after text that does not exist.
    func notifyDictationFailed(reason: String, textInClipboard: Bool) {
        let content = UNMutableNotificationContent()
        content.title = textInClipboard ? "Text not inserted" : "Dictation failed"
        content.body = textInClipboard
            ? "\(reason). The text is on the clipboard — paste with ⌘V"
            : reason
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dictation-not-inserted-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        Log.info("Dictation: notified «\(reason)»")
    }

    /// The recording hotkey could not start a meeting. The window may be
    /// hidden, and silence would read as a dead key.
    func notifyRecordingFailed(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording did not start"
        content.body = reason
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "recording-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        Log.info("Recording toggle: notified «\(reason)»")
    }

    /// The exclude hotkey was pressed with no meeting recording running.
    /// Explicit feedback: a global hotkey that silently does nothing reads
    /// as broken, not as idle.
    func notifyExclusionUnavailable() {
        let content = UNMutableNotificationContent()
        content.title = "No recording to exclude from"
        content.body = "The exclude toggle marks mic audio during a meeting recording — start one first"

        let request = UNNotificationRequest(
            identifier: "exclusion-unavailable-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// The «не в транскрипт» toggle auto-expired: the user must learn the mic
    /// is back in the transcript, or the forgotten-off failure mode silently
    /// inverts into its opposite (transcript-exclusion-marks, risk M3).
    func notifyExclusionAutoExpired() {
        let content = UNMutableNotificationContent()
        content.title = "Exclude mode turned off"
        content.body = "The interval auto-expired — the mic is back in the transcript"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "exclusion-expired-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Run the after-the-meeting loop: the first «stop recording?» reminder now,
    /// then whatever `automation` decides every few seconds — repeats, or the
    /// automatic stop. Call only while a recording is actually running — the
    /// caller owns that check (never nag when there is nothing to stop).
    func startMeetingEndedReminders(
        automation: MeetingAutomation,
        lastSpeech: @escaping @MainActor () -> Date?,
        onAutoStop: @escaping @MainActor () -> Void
    ) {
        endedReminderTask?.cancel()
        endedReminderTask = Task { [weak self] in
            var lastReminder: Date?
            var tick = 0
            while !Task.isCancelled {
                let speech = lastSpeech()
                switch automation.afterMeetingEnded(lastReminder: lastReminder, lastSpeech: speech, now: Date()) {
                case .remind:
                    self?.notifyMeetingEnded(autoStop: automation.autoStop, interval: automation.reminderInterval)
                    lastReminder = Date()
                case .stop:
                    onAutoStop()
                    return
                case .none:
                    break
                }
                self?.onMeetingEndedIndicator?(automation.endedIndicator(
                    tick: tick, lastReminder: lastReminder, lastSpeech: speech, now: Date(),
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ))
                tick += 1
                // Each second: the blink and the countdown are driven from here.
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Log.info("Meeting-ended reminders started (every \(Int(automation.reminderInterval))s, auto stop \(automation.autoStop))")
    }

    /// Stop the reminder loop and clear any delivered reminder from Notification Center.
    func cancelMeetingEndedReminders() {
        guard endedReminderTask != nil else { return }
        endedReminderTask?.cancel()
        endedReminderTask = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingEndedIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingEndedIdentifier])
        onMeetingEndedIndicator?(nil)
        Log.info("Meeting-ended reminders cancelled")
    }

    /// «Don't stop»: ends the reminders and the auto stop for this meeting. The
    /// loop only restarts from the detector's next «meeting ended», which needs a
    /// new detection first — so the next call that comes and goes is watched again.
    func keepRecording() {
        guard endedReminderTask != nil else { return }
        Log.info("Meeting ended: keep recording — no reminders or auto stop until the next meeting ends")
        cancelMeetingEndedReminders()
    }

    private func notifyMeetingEnded(autoStop: Bool, interval: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting appears to have ended"
        content.body = autoStop
            ? "Recording stops in \(Int(interval)) s unless the meeting resumes"
            : "Recording is still running — stop it from the menu bar"
        content.sound = .default
        content.categoryIdentifier = Self.meetingEndedCategory

        let request = UNNotificationRequest(
            identifier: Self.meetingEndedIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// A detected meeting started a recording by itself: the user
    /// must know the mic is being recorded.
    func notifyRecordingAutoStarted(name: String) {
        post(title: "Recording started", body: name, id: "recording-auto-started")
    }

    /// Any process of the user can start a recording through the command
    /// socket; this is how the user hears about one they did not start.
    func notifyRecordingStartedFromCommandLine() {
        post(
            title: "Recording started from the command line",
            body: "If you did not start it, stop it from the menu bar",
            id: "recording-command-started"
        )
    }

    func notifyRecordingAutoStopped() {
        post(title: "Recording stopped", body: "The meeting ended", id: "recording-auto-stopped")
    }

    /// The call plays, the system track is zero: the window may be closed.
    func notifyCallTrackSilent() {
        post(title: SilentCallTrack.bannerTitle, body: SilentCallTrack.bannerMessage, id: "call-track-silent")
    }

    /// The call audio comes through chopped and rebuilding the tap did not help.
    func notifyCallAudioChopped() {
        post(title: TapChopDetector.bannerTitle, body: TapChopDetector.bannerMessage, id: "call-audio-chopped")
    }

    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionId = response.actionIdentifier
        await MainActor.run {
            switch actionId {
            case Self.startRecordingAction:
                onStartRecordingRequested?()
            case Self.keepRecordingAction:
                keepRecording()
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

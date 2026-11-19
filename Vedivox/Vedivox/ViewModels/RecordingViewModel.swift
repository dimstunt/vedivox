import Foundation
import SwiftUI

@MainActor
@Observable
final class RecordingViewModel {
    enum RecordingState: Equatable {
        case idle
        case recording
        case processing
        case done
        case error(String)
    }

    var state: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var currentMeetingId: String?
    /// True when a recording started but the system-audio tap couldn't be
    /// created (permission denied / unavailable) — surfaced as a banner so the
    /// user isn't silently left with a mic-only recording.
    var systemAudioUnavailable = false
    /// The call plays but the system track is digital zero: the
    /// grant is probably off. Banner, menu bar line, one notification.
    var systemAudioSilent = false
    @ObservationIgnored private var silentCallTrack = SilentCallTrack()
    @ObservationIgnored private var silentCheckRunning = false
    /// The call audio comes through chopped and the capture could not fix it
    /// banner, menu bar line, one notification per recording.
    var systemAudioChopped = false
    /// The chop warning was up at some point: the meeting gets its «!».
    @ObservationIgnored private var choppedCallSeen = false

    private let audioSession: any AudioSessionProtocol
    private let meetingRepo: MeetingRepository

    init(audioSession: any AudioSessionProtocol = AudioSessionManager(), meetingRepo: MeetingRepository = MeetingRepository()) {
        self.audioSession = audioSession
        self.meetingRepo = meetingRepo
    }

    private var timer: Timer?
    private var isStopping = false
    private(set) var recordingStartTime: Date?
    /// Live text of the recording in progress; nil
    /// outside a recording and when `liveTranscriptEnabled` is off.
    @ObservationIgnored private(set) var liveTranscript: MeetingLiveTranscript?
    private var micAudioURL: URL?
    private var systemAudioURL: URL?

    var isRecording: Bool {
        state == .recording
    }

    var isProcessing: Bool {
        state == .processing
    }

    /// The last stop that was not the after-the-meeting auto stop: it holds
    /// back an auto start for a while (`MeetingAutomation.manualStopCooldown`).
    private(set) var lastManualStopAt: Date?

    var lastMicSpeechAt: Date? { audioSession.lastMicSpeechAt }

    /// Returns the id of the meeting this call created, or nil when it did not
    /// start (already recording, or capture failed — see `state`). Allowed from
    /// `.error`: the error belongs to the previous meeting.
    @discardableResult
    func startRecording(
        title: String = "Recording",
        calendarEvent: CalendarService.CalendarEvent? = nil,
        foreignVoiceDecision: ForeignVoiceDecision = .undecided,
        appState: AppState
    ) async -> String? {
        guard state != .recording else { return nil }
        resetState()
        // Block re-entry before the first await: a second caller (two
        // `vedivox record start` at once) must see .recording, or both start the
        // same capture and each gets its own meeting.
        state = .recording
        await audioSession.reset() // Ensure audio session is .idle before starting

        let meetingId = UUID().uuidString
        // Before the captures start: a tap takes its live sink when installed.
        let live = MeetingLiveTranscript.isEnabled()
            ? MeetingLiveTranscript(
                mic: LiveWindowRecogniser(pipeline: appState.pipeline),
                system: LiveWindowRecogniser(pipeline: appState.pipeline)
            )
            : nil
        await audioSession.setLiveSinks(mic: live?.micSink, system: live?.systemSink)
        do {
            let (micURL, systemURL) = try await audioSession.startRecording(meetingId: meetingId)

            var seriesId: String?
            if let calendarEvent {
                seriesId = try? await SeriesRepository().resolveCalendarSeries(for: calendarEvent)?.id
            }
            // Save meeting with micAudioPath so crash recovery can find the file
            let meeting = Meeting(
                id: meetingId,
                title: title,
                calendarEventId: calendarEvent?.calendarItemIdentifier,
                seriesId: seriesId,
                source: .recording,
                micAudioPath: micURL.path,
                systemAudioPath: systemURL?.path,
                status: .recording,
                foreignVoiceDecision: foreignVoiceDecision
            )
            try await meetingRepo.create(meeting)

            self.currentMeetingId = meetingId
            self.micAudioURL = micURL
            self.systemAudioURL = systemURL
            // systemAudioEnabled is always true (Phase 2), so a nil systemURL
            // here means the tap failed — usually a missing permission.
            self.systemAudioUnavailable = (systemURL == nil)
            let recordingStart = Date()
            self.recordingStartTime = recordingStart
            // Same instant as the marks' clock, so exclusion hides the right speech.
            self.liveTranscript = live
            // Precise passes read the tails of the files this recording writes.
            await live?.setRefiner { [pipeline = appState.pipeline] tail in
                await pipeline.refineLiveTail(mic: micURL, system: systemURL, last: tail)
            }
            await live?.begin()
            appState.muteMonitor.recordingStarted(meetingId: meetingId, recordingStart: recordingStart)

            await appState.loadMeetings()
            appState.selectedMeetingId = meetingId

            appState.notificationService.cancelMeetingEndedReminders()
            appState.menuBarController.setMultiSpeaker(foreignVoiceDecision == .kept)
            appState.menuBarController.updateState(.recording(duration: 0))

            // Start duration timer
            startTimer(appState: appState)
            return meetingId
        } catch {
            // Audio may already be running when `meetingRepo.save` throws — a
            // recording nobody can see or stop must not keep going.
            if await audioSession.state == .recording {
                _ = await audioSession.stopRecording()
            }
            await audioSession.setLiveSinks(mic: nil, system: nil)
            state = .error(error.localizedDescription)
            return nil
        }
    }

    /// Returns false when there was nothing to stop or another stop got there
    /// first: the state turns `.processing` only after several
    /// awaits, so the re-entry block is a flag set before the first one.
    @discardableResult
    func stopRecording(appState: AppState, automatic: Bool = false) async -> Bool {
        guard state == .recording, !isStopping else { return false }
        isStopping = true
        defer { isStopping = false }
        if !automatic { lastManualStopAt = Date() }

        appState.notificationService.cancelMeetingEndedReminders()
        stopTimer()
        let startTime = recordingStartTime
        recordingStartTime = nil
        let silentCall = silentCallTrack.warning
        let choppedCall = choppedCallSeen
        appState.menuBarController.setStatusLine(nil)

        let result = await audioSession.stopRecording()
        let endTime = Date()
        // Off the stop path: processing must not wait for the live model to
        // finish its last chunk. The text is dropped — the pipeline below
        // produces the transcript from the files, as before.
        if let live = liveTranscript {
            liveTranscript = nil
            Task { await live.end() }
        }
        await audioSession.setLiveSinks(mic: nil, system: nil)
        let duration = startTime.map { endTime.timeIntervalSince($0) } ?? 0

        guard let meetingId = currentMeetingId else { return true }

        // Close any open «не в транскрипт» interval. No summary notification:
        // the meeting window reports what is hidden, and with the default
        // hiding foreign voices a notification would fire on every meeting.
        _ = await appState.exclusionToggle.recordingStopped(
            meetingId: meetingId, duration: duration
        )
        // Before the pipeline: a mute period still open becomes its mark now.
        await appState.muteMonitor.recordingStopped()
        appState.menuBarController.setExcluding(false)
        appState.menuBarController.setMultiSpeaker(false)

        // Update meeting with end time
        try? await meetingRepo.updateEndTime(meetingId, endTime: endTime, duration: duration)

        // Update meeting with audio paths
        if let micURL = result.micAudioURL {
            var meeting = try? await meetingRepo.find(meetingId)
            meeting?.micAudioPath = micURL.path
            meeting?.endTime = endTime
            meeting?.durationSeconds = duration
            if let systemURL = result.systemAudioURL {
                meeting?.systemAudioPath = systemURL.path
            }
            if let meeting {
                try? await meetingRepo.save(meeting)
            }
        } else {
            Log.error("Mic recording for \(meetingId) is empty — marking the meeting as needing attention")
            try? await meetingRepo.updateStatus(
                meetingId, status: .needsAttention, reason: MeetingStatusReason.micEmpty.rawValue
            )
        }

        state = .processing
        appState.menuBarController.updateState(.idle)
        await appState.loadMeetings()

        // Start transcription pipeline in background.
        // Capture meetingId so the completion callback only updates state
        // if we haven't started a new recording in the meantime.
        let processingMeetingId = meetingId
        Task {
            do {
                if let micURL = result.micAudioURL {
                    try await appState.pipeline.processMeeting(
                        meetingId: meetingId,
                        micAudioURL: micURL,
                        systemAudioURL: result.systemAudioURL,
                        justRecorded: true,
                        silentCallTrack: silentCall,
                        choppedCallAudio: choppedCall
                    )
                }
                await MainActor.run {
                    if self.currentMeetingId == processingMeetingId {
                        self.state = .done
                    }
                    // Processing loaded the models: a failed-load banner is stale.
                    if result.micAudioURL != nil { appState.modelLoadError = nil }
                    appState.transcriptVersion += 1
                }
                await appState.loadMeetings()
            } catch {
                Log.error("Transcription failed for \(processingMeetingId): \(error)")
                try? await self.meetingRepo.updateStatus(processingMeetingId, status: .error)
                await MainActor.run {
                    if self.currentMeetingId == processingMeetingId {
                        self.state = .error(error.localizedDescription)
                    }
                    appState.processingFailureReasons[processingMeetingId] = error.localizedDescription
                    appState.transcriptVersion += 1
                }
                await appState.loadMeetings()
            }
        }
        return true
    }

    /// Clears a finished state (done / error) back to idle. Never during a
    /// recording: the «Transcript ready» auto-dismiss fires 2 s late, and a
    /// recording started in between lost its state — the next start opened a
    /// second meeting on the same capture (live check).
    func reset() {
        guard state != .recording else { return }
        resetState()
        Task { await audioSession.reset() }
    }

    private func resetState() {
        state = .idle
        recordingDuration = 0
        currentMeetingId = nil
        micAudioURL = nil
        systemAudioURL = nil
        systemAudioUnavailable = false
        systemAudioSilent = false
        silentCallTrack = SilentCallTrack()
        systemAudioChopped = false
        choppedCallSeen = false
        recordingStartTime = nil
    }

    // MARK: - Timer

    private func startTimer(appState: AppState) {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak appState] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
                appState?.menuBarController.updateState(.recording(duration: self.recordingDuration))
                if let appState, Int(self.recordingDuration) % 5 == 0 {
                    self.checkCallTrack(appState: appState)
                    self.checkChoppedCall(appState: appState)
                }
            }
        }
    }

    /// One `SilentCallTrack` tick: never on the main thread for Core Audio,
    /// never two at once, nothing once the track has sounded.
    private func checkCallTrack(appState: AppState) {
        guard systemAudioURL != nil, !silentCallTrack.heard, !silentCheckRunning else { return }
        silentCheckRunning = true
        Task {
            defer { silentCheckRunning = false }
            let heard = await audioSession.systemHeardSound()
            let outputting = heard ? false : await Task.detached { SilentCallTrack.callAppsOutputting() }.value
            guard state == .recording else { return }
            silentCallTrack.tick(heard: heard, callOutputting: outputting, now: Date())
            let warning = silentCallTrack.warning
            guard warning != systemAudioSilent else { return }
            systemAudioSilent = warning
            appState.menuBarController.setStatusLine(warning ? SilentCallTrack.menuLine : nil)
            if warning {
                Log.warning("System track silent for \(Int(silentCallTrack.callOutputSeconds)) s of call output — system audio access is probably off")
                appState.notificationService.notifyCallTrackSilent()
            } else {
                Log.info("System track sounded — silent call warning cleared")
            }
        }
    }

    /// Polls the capture's chop verdict; the capture itself has
    /// already tried rebuilding the tap.
    private func checkChoppedCall(appState: AppState) {
        guard systemAudioURL != nil else { return }
        Task {
            let chopped = await audioSession.systemCallAudioChopped()
            guard state == .recording, chopped != systemAudioChopped else { return }
            systemAudioChopped = chopped
            appState.menuBarController.setStatusLine(chopped ? TapChopDetector.menuLine : nil)
            guard chopped, !choppedCallSeen else { return }
            choppedCallSeen = true
            appState.notificationService.notifyCallAudioChopped()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var formattedDuration: String {
        let mins = Int(recordingDuration) / 60
        let secs = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

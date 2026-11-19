import AVFoundation
import Foundation
import os

/// Coordinates microphone and system audio capture lifecycle.
actor AudioSessionManager: AudioSessionProtocol {
    /// Replaced when a start hangs: the stuck one is never usable again.
    private var micCapture = MicrophoneCapture()
    private let systemCapture = SystemAudioCapture()
    private var meetingId: String?
    /// System audio capture is disabled until Phase 2 (two-stream + diarization)
    var systemAudioEnabled = true

    private(set) var state: CaptureState = .idle

    /// Written from the audio tap, read by the after-the-meeting reminders.
    private let micSpeech = OSAllocatedUnfairLock<Date?>(initialState: nil)
    nonisolated var lastMicSpeechAt: Date? { micSpeech.withLock { $0 } }
    /// Smoothed `AudioLevelMeter` level (≈ −36 dBFS) that counts as speech.
    /// shortcut: not calibrated on real rooms, and loud typing or music in the
    /// room also counts; tune when the reminders turn out to be held back for nothing.
    private static let speechLevel: Float = 0.35
    /// The live transcript's consumer of the microphone, while a recording has one.
    private var liveMicSink: LiveAudioSink?

    func systemHeardSound() async -> Bool {
        await systemCapture.heardSound
    }

    func systemCallAudioChopped() async -> Bool {
        await systemCapture.callAudioChopped
    }

    /// Start recording mic (and optionally system) audio.
    /// Both tracks pad from one start anchor taken after the permission
    /// dialogs, so they line up whichever delivers frames first.
    func startRecording(meetingId: String) async throws -> (micURL: URL, systemURL: URL?) {
        guard state != .recording else { throw AudioSessionError.alreadyRecording }

        // Wait the mic prompt out before taking the anchor, so the dialog's
        // time is in neither track (design D2 of tap-eager-start). The
        // system-audio prompt blocks too, inside the tap's AudioDeviceStart
        // after the anchor (2.1 s on 2026-11-17): the welcome wizard asks it
        // ahead (SystemAudioCapture.check).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        // Without access the input still opens and delivers digital silence:
        // the timer ran, the icon was red, and every meeting came out without
        // the owner's voice, with nothing said anywhere. Refuse, with the way
        // to fix it — before the meeting's directory exists.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioSessionError.microphoneAccessDenied
        }

        let audioDir = try DatabaseManager.audioDirectory(for: meetingId)
        let startHostTime = mach_absolute_time()

        var systemURL: URL?
        if systemAudioEnabled {
            let sysURL = audioDir.appendingPathComponent("system.wav")
            do {
                Log.info("Starting system audio capture to \(sysURL.path)")
                try await systemCapture.start(outputURL: sysURL, startHostTime: startHostTime)
                systemURL = sysURL
                Log.info("System audio capture started OK")
            } catch {
                Log.error("System audio capture FAILED: \(error)")
            }
        } else {
            Log.info("System audio disabled, skipping")
        }

        // Start mic capture. The selected microphone is applied inside
        // MicrophoneCapture by binding the engine to the device; the system
        // default is untouched. If it fails, undo what already happened above:
        // the system tap must not outlive a recording that never started.
        let micURL = audioDir.appendingPathComponent("mic.wav")
        micSpeech.withLock { $0 = nil }
        await micCapture.setLiveSink(micTapSink())
        do {
            try await MicrophoneCapture.start(micCapture, outputURL: micURL, startHostTime: startHostTime)
        } catch {
            Log.error("Mic capture FAILED: \(error) — stopping system capture")
            if case MicrophoneCapture.MicCaptureError.startTimedOut = error { micCapture = MicrophoneCapture() }
            if systemURL != nil { _ = await systemCapture.stop() }
            // No meeting row points at it: a system.wav left here is never picked up.
            try? FileManager.default.removeItem(at: audioDir)
            throw error
        }

        self.meetingId = meetingId
        self.state = .recording

        return (micURL, systemURL)
    }

    /// The one sink the microphone tap gets when a recording starts: the live
    /// transcript's consumer, if there is one, with the reminders' speech
    /// clock on the same conversion.
    ///
    /// The tap has a single slot. Installing the speech clock over the live
    /// transcript's sink (build 1375) left a real recording without a word
    /// from the microphone in its live text, while the system track worked.
    func micTapSink() -> LiveAudioSink {
        let speech = micSpeech
        let onLevel: @Sendable (Float) -> Void = { level in
            if level >= Self.speechLevel { speech.withLock { $0 = Date() } }
        }
        return liveMicSink?.reporting(level: onLevel) ?? LiveAudioSink(onSamples: { _ in }, onLevel: onLevel)
    }

    /// Live consumers of the two tracks (the meeting's live transcript), or
    /// nil to detach. The taps pick them up when a capture starts, so this
    /// goes before `startRecording`.
    func setLiveSinks(mic: LiveAudioSink?, system: LiveAudioSink?) async {
        liveMicSink = mic
        await micCapture.setLiveSink(mic)
        await systemCapture.setLiveSink(system)
    }

    /// Stop all recording and return file URLs.
    func stopRecording() async -> RecordingResult {
        let micURL = await micCapture.stop()
        let systemURL = systemAudioEnabled ? await systemCapture.stop() : nil

        self.state = .stopped
        self.meetingId = nil

        return RecordingResult(micAudioURL: micURL, systemAudioURL: systemURL)
    }

    func reset() {
        state = .idle
        meetingId = nil
    }

    enum AudioSessionError: Error, LocalizedError {
        case alreadyRecording
        case microphoneAccessDenied

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "Audio session is already recording"
            case .microphoneAccessDenied:
                "Vedivox has no access to the microphone. Allow it in System Settings → Privacy & Security → Microphone, then start the recording again."
            }
        }
    }
}

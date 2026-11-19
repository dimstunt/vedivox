import AVFoundation
import Foundation

/// Owner voice enrollment (owner-voice-enrollment): a short recording made in
/// Settings becomes a regular meeting whose segments are pinned to the "me"
/// speaker, so the canonical gains a healthy meeting voice through the
/// standard recalc — additive, never a bypass of the identity invariant.
enum VoiceEnrollment {
    /// Canonical needs ≥10s of speech per meeting; 20s leaves headroom for
    /// pauses and VAD trimming (design § решение 3).
    static let minimumSeconds: TimeInterval = 20
    static let meetingTitle = "Voice enrollment"
    private static let defaultsKey = "enrollmentMeetingId"

    /// The one enrollment meeting whose voice feeds the canonical.
    /// ponytail: UserDefaults, no DB migration — wiped defaults just leave the
    /// old take behind as an ordinary meeting (design § решение 2).
    static var enrollmentMeetingId: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Pin every diarized voice of the enrollment meeting to "me" via the
    /// existing reassign path (labels, meeting link, confirm, recalc). On a
    /// fresh base the "me" record is minted here. The recalc runs the identity
    /// invariant, so a take dominated by somebody else's voice cannot
    /// overwrite an existing canonical (spec: «Чужой голос в записи»).
    static func claimSegmentsForMe(
        meetingId: String,
        meetingRepo: MeetingRepository = MeetingRepository(),
        speakerRepo: SpeakerRepository = SpeakerRepository()
    ) async throws {
        let me: Speaker
        if let existing = try await speakerRepo.findMe() {
            me = existing
        } else {
            // Fresh install: nobody is "me" yet — mint the owner record.
            me = try await speakerRepo.createSpeaker(name: "Me", isMe: true)
        }

        for label in try await meetingRepo.distinctSpeakerLabels(meetingId: meetingId)
            where label != me.displayName {
            try await meetingRepo.renameSpeakerInMeeting(
                meetingId: meetingId,
                oldLabel: label,
                newLabel: me.displayName,
                speakerId: me.id
            )
        }

        try await speakerRepo.assignSpeakerToMeeting(
            meetingId: meetingId, speakerId: me.id, diarizationLabel: nil
        )
        try await speakerRepo.confirmSpeaker(me.id)
        try await speakerRepo.cleanupOrphanedMeetingSpeakers(meetingId: meetingId)
        try await speakerRepo.recalculateEmbedding(speakerId: me.id, config: .automatic)
    }

    /// Re-recording replaces the previous take: exactly one enrollment
    /// meeting feeds the canonical (spec: «Повторная запись»).
    static func deleteEnrollmentMeeting(
        _ id: String,
        meetingRepo: MeetingRepository = MeetingRepository()
    ) async throws {
        _ = try? DatabaseManager.trashAudioDirectory(for: id)
        try await meetingRepo.delete(id)
    }
}

/// Thin AVAudioRecorder wrapper: one m4a take in the temp directory, level
/// metering for the Settings UI. ponytail: no pause/resume — a 30s take is
/// re-recorded, not edited.
@MainActor
final class VoiceEnrollmentRecorder: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    var reachedMinimum: Bool { elapsed >= VoiceEnrollment.minimumSeconds }

    struct RecorderStartError: Error {}

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-enrollment-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecorderStartError() }

        recorder = rec
        elapsed = 0
        level = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard let rec = recorder else { return }
        elapsed = rec.currentTime
        rec.updateMeters()
        // averagePower is dBFS (−160…0); map −50…0 dB onto 0…1 for the bar.
        let db = Double(rec.averagePower(forChannel: 0))
        level = max(0, min(1, (db + 50) / 50))
    }

    /// Stops and returns the recorded file. The UI keeps Stop disabled until
    /// `reachedMinimum`, so a too-short take never leaves the recorder.
    func stop() -> URL? {
        guard let rec = recorder else { return nil }
        rec.stop()
        cleanupState()
        return rec.url
    }

    func cancel() {
        guard let rec = recorder else { return }
        rec.stop()
        rec.deleteRecording()
        cleanupState()
    }

    private func cleanupState() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        level = 0
    }
}

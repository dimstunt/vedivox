import Foundation

/// Capture lifecycle state.
enum CaptureState {
    case idle
    case recording
    case stopped
}

/// Result of a completed recording session.
struct RecordingResult {
    let micAudioURL: URL?
    let systemAudioURL: URL?
}

/// Protocol for audio session management, enabling dependency injection and testing.
protocol AudioSessionProtocol: Actor {
    var state: CaptureState { get }
    var systemAudioEnabled: Bool { get set }
    func setLiveSinks(mic: LiveAudioSink?, system: LiveAudioSink?) async
    func startRecording(meetingId: String) async throws -> (micURL: URL, systemURL: URL?)
    func stopRecording() async -> RecordingResult
    func reset() async
    /// When the mic of the running recording last heard speech, nil before any.
    nonisolated var lastMicSpeechAt: Date? { get }
    /// Whether the running recording's system track has had any non-zero
    /// sample; digital zero all along is what a refusal records.
    func systemHeardSound() async -> Bool
    /// The call audio comes through chopped and rebuilding the tap did not
    /// fix it.
    func systemCallAudioChopped() async -> Bool
}

extension AudioSessionProtocol {
    nonisolated var lastMicSpeechAt: Date? { nil }
    func systemHeardSound() async -> Bool { true }
    func systemCallAudioChopped() async -> Bool { false }
}

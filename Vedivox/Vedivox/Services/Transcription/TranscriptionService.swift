import FluidAudio
import Foundation

/// Actor wrapping FluidAudio AsrManager for on-device transcription.
/// Uses Parakeet v3 model on Apple Neural Engine (ANE) for ~190x realtime speed.
actor TranscriptionService {
    // AsrManager is not Sendable but we ensure single-threaded access via actor isolation
    private nonisolated(unsafe) var asrManager: AsrManager?
    private var isInitialized = false
    /// Dedups the model download across concurrent `initialize()` callers
    /// (warm-up vs first processMeeting) so the ~download runs once.
    private let modelLoader = SingleFlight<AsrModels>()

    struct TranscriptionResult {
        let text: String
        let segments: [TokenGrouper.Segment]
        /// Raw per-token timings from Parakeet — the input `segments` were
        /// grouped from. Kept so the merger can REASSEMBLE segments along
        /// diarization boundaries instead of inheriting groupings
        /// that may straddle a speaker change. Empty when the model returned
        /// no timings (then `segments` is the single-fallback-segment shape).
        let tokenTimings: [TokenTiming]
        let duration: TimeInterval
        let elapsed: TimeInterval
    }

    /// Initialize the FluidAudio model. First run downloads and compiles CoreML model (~14.7s).
    /// Subsequent runs load from cache (~0.2s).
    ///
    /// `onProgress` reports download/compile fraction in [0, 1] for the loading
    /// banner.
    func initialize(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if isInitialized { return }
        ModelPins.apply()

        let models = try await modelLoader.run {
            let handler: ProgressHandler?
            if let onProgress {
                handler = { @Sendable progress in onProgress(progress.fractionCompleted) }
            } else {
                handler = nil
            }
            return try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
        }
        // 0.13.7: AsrManager takes models in init; the separate initialize(models:)
        // step is gone.
        if asrManager == nil {
            asrManager = AsrManager(config: Self.asrConfig, models: models)
            isInitialized = true
        }
    }

    /// Long-form decoding as FluidAudio 0.15 did it. The 0.16+
    /// defaults — no mel context on v3, the seam-gap/leading-span repair pass,
    /// seam timing realignment — re-decode "empty" stretches and make text out
    /// of digital silence: M5's muted mic (−79 dB) got a 14 s segment of English
    /// junk, credited to the owner. The bench lost 12–50 s of false alarm per
    /// meeting to them (owner listened 2026-11-19: no quiet voices there).
    static let asrConfig = ASRConfig(melChunkContext: true, seamGapRepair: false, seamTimingRealignment: false)

    /// Transcribe an audio file and return grouped segments.
    func transcribe(_ audioURL: URL) async throws -> TranscriptionResult {
        guard let asrManager else {
            throw TranscriptionError.notInitialized
        }

        let start = Date()
        // 0.13.7: the per-source decoder states (source: .system/.microphone) are
        // gone — the caller owns TdtDecoderState. We transcribe whole files, so a
        // fresh state per file gives the same isolation the source split provided.
        var decoderState = TdtDecoderState.make()
        let result = try await asrManager.transcribe(audioURL, decoderState: &decoderState)
        let elapsed = Date().timeIntervalSince(start)

        let segments = Self.segments(timings: result.tokenTimings, text: result.text, duration: result.duration)

        return TranscriptionResult(
            text: result.text,
            segments: segments,
            tokenTimings: result.tokenTimings ?? [],
            duration: result.duration,
            elapsed: elapsed
        )
    }

    /// Transcribe 16 kHz mono samples of one live window (change
    /// `live-transcript`): up to 15 s, which the model takes in a single pass.
    ///
    /// Shares the loaded model with file transcription and may run while a
    /// meeting is being processed: the decoder state is the caller's, fresh per
    /// call, and the manager already runs its own chunks of a long file in
    /// parallel on the same models.
    ///
    /// Returns the segments a file would give, timed from the window's start:
    /// live text is then hidden by exclusion marks in the same units, by the
    /// same rule, as the final transcript.
    func transcribe(samples: [Float]) async throws -> [TokenGrouper.Segment] {
        guard let asrManager else {
            throw TranscriptionError.notInitialized
        }
        var decoderState = TdtDecoderState.make()
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        return Self.segments(timings: result.tokenTimings, text: result.text, duration: result.duration)
    }

    /// Token timings grouped into segments; without timings, the text as one segment over the file.
    /// No text means no segments: an empty row would only clutter the transcript.
    static func segments(timings: [TokenTiming]?, text: String, duration: Double) -> [TokenGrouper.Segment] {
        if let timings, !timings.isEmpty { return TokenGrouper.group(timings) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [TokenGrouper.Segment(startTime: 0, endTime: duration, text: text, confidence: nil)]
    }

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .notInitialized: "Transcription service not initialized. Call initialize() first."
            }
        }
    }
}

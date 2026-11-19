import Foundation

/// A piece of live text and the stretch of the recording it was heard in,
/// in seconds from the recording's start.
struct LivePiece: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// What the meeting's live transcript needs from one track's recogniser. A
/// protocol so the feed loop is testable without a model: `LiveWindowRecogniser`
/// is the only real implementation.
protocol LiveRecognising: Actor {
    var readiness: MeetingLiveTranscript.Readiness { get }
    func prepare() async
    /// Takes audio whose last sample was captured `elapsed` seconds into the
    /// recording and returns whatever became text because of it.
    func append(_ samples: [Float], endingAt elapsed: TimeInterval) async -> [LivePiece]
}

/// Live recognition of one track on the model that makes the final transcript:
/// Parakeet over windows cut at pauses.
///
/// The streaming model that drafts dictation answers in two seconds, but loses
/// verbs and garbles abbreviations in Russian — and this text is for checking
/// what was just asked. A window is late by its own length instead, and reads
/// like the final transcript.
actor LiveWindowRecogniser: LiveRecognising {
    private(set) var readiness: MeetingLiveTranscript.Readiness = .loading

    private let load: @Sendable () async throws -> Void
    /// Segments of a window, timed from its start.
    private let transcribe: @Sendable ([Float]) async throws -> [TokenGrouper.Segment]
    private var pending: [Float] = []

    /// The pipeline's own model: already loaded for processing, never a second copy.
    init(pipeline: TranscriptionPipeline) {
        self.init(
            load: { try await pipeline.prepareLive() },
            transcribe: { try await pipeline.transcribeLive($0) }
        )
    }

    init(
        load: @escaping @Sendable () async throws -> Void,
        transcribe: @escaping @Sendable ([Float]) async throws -> [TokenGrouper.Segment]
    ) {
        self.load = load
        self.transcribe = transcribe
    }

    func prepare() async {
        do {
            try await load()
            readiness = .ready
        } catch {
            Log.error("Live transcript unavailable: \(error.localizedDescription)")
            readiness = .unavailable
        }
    }

    func append(_ samples: [Float], endingAt elapsed: TimeInterval) async -> [LivePiece] {
        pending.append(contentsOf: samples)
        let rate = Double(LiveWindowCutter.sampleRate)
        var pieces: [LivePiece] = []
        while let count = LiveWindowCutter.cut(pending) {
            let window = Array(pending.prefix(count))
            // The newest waiting sample is at `elapsed`; count back from it.
            let start = max(0, elapsed - Double(pending.count) / rate)
            pending.removeFirst(count)
            guard !LiveWindowCutter.isSilent(window) else { continue }
            do {
                // Each segment keeps its own time inside the window: a window
                // can open with seconds of room noise, and a phrase stretched
                // over them would slip past an exclusion mark.
                pieces += try await transcribe(window).map {
                    LivePiece(start: start + $0.startTime, end: start + $0.endTime, text: $0.text)
                }
            } catch {
                // The window is lost to live text; the recording is not.
                Log.error("Live transcript: window dropped — \(error.localizedDescription)")
            }
        }
        return pieces
    }
}

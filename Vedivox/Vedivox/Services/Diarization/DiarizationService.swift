import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// OfflineDiarizerManager is non-Sendable but documents its own thread safety
/// (models are written only during initialization, read-only afterwards); our
/// access is additionally serialized by the DiarizationService actor. Needed so
/// its async process() can be awaited from actor isolation under Swift 6.
extension OfflineDiarizerManager: @unchecked @retroactive Sendable {}

/// Speaker diarization using FluidAudio's DiarizerManager with speaker enrollment.
actor DiarizationService {

    struct DiarizationSegment {
        let start: Double
        let end: Double
        let speaker: String
        /// The segment's own voice: on the offline path the mean of its
        /// cluster's chunk windows (segment-own-voice), on the online path
        /// FluidAudio's per-segment vector.
        let embedding: [Float]
        /// Offline path: the cluster centroid FluidAudio stamped on the segment
        /// before `embedding` was replaced by its own voice. Stage 2 matches on
        /// it while `SubClusterSplitter.Config.useOwnVectors` is off.
        var clusterEmbedding: [Float]?
    }

    struct KnownSpeaker {
        let id: String
        let name: String
        let embedding: [Float]
    }

    struct DiarizationResult {
        let segments: [DiarizationSegment]
        let speakerEmbeddings: [String: [Float]]
        /// Chunk-level (~2-10s window) WeSpeaker embeddings keyed to cluster ids
        /// offline path only: the Stage-2.5 rescue input and the
        /// source of each segment's own vector (segment-own-voice).
        let chunkEmbeddings: [ChunkEmbedding]?

        init(
            segments: [DiarizationSegment],
            speakerEmbeddings: [String: [Float]],
            chunkEmbeddings: [ChunkEmbedding]? = nil
        ) {
            self.segments = segments
            self.speakerEmbeddings = speakerEmbeddings
            self.chunkEmbeddings = chunkEmbeddings
        }
    }

    private nonisolated(unsafe) var diarizer: DiarizerManager?
    private var isModelLoaded = false
    private nonisolated(unsafe) var offlineDiarizer: OfflineDiarizerManager?
    /// Dedups model loads across concurrent warm-up / processing callers so the
    /// ~download runs once per diarizer variant.
    private let onlineLoader = SingleFlight<DiarizerModels>()
    private let offlineLoader = SingleFlight<OfflineDiarizerManager>()

    /// Feature flag: route diarization through FluidAudio's
    /// OfflineDiarizerManager (pyannote stack: powerset segmentation + WeSpeaker
    /// embedder + VBx clustering) instead of the online DiarizerManager.
    /// Env override (bench: TEST_RUNNER_VEDIVOX_USE_OFFLINE_DIARIZER=1) wins over the
    /// UserDefaults toggle.
    ///
    /// Default ON since the enrolled pool is migrated to WeSpeaker
    /// canonicals (speakers.embeddingV2), unblocking Stage-2 on the offline path
    /// (−39..80% confusion vs online, the bench notes). `defaults write com.dimstunt.Vedivox
    /// useOfflineDiarizer -bool NO` switches back — the v1 pool is kept intact.
    static var useOfflineDiarizer: Bool {
        if let raw = ProcessInfo.processInfo.environment["VEDIVOX_USE_OFFLINE_DIARIZER"] {
            return raw == "1" || raw == "true"
        }
        if UserDefaults.standard.object(forKey: "useOfflineDiarizer") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "useOfflineDiarizer")
    }

    /// CoreML compute units for the diarizer models. Default (`nil` env) keeps
    /// FluidAudio's own default (.all — CoreML schedules ANE/GPU/CPU per run,
    /// which is a nondeterminism source). The bench sets VEDIVOX_DIARIZER_COMPUTE_UNITS
    /// to pin scheduling and measure run-to-run variance.
    private static func modelConfiguration() -> MLModelConfiguration? {
        guard let raw = ProcessInfo.processInfo.environment["VEDIVOX_DIARIZER_COMPUTE_UNITS"] else {
            return nil
        }
        let config = MLModelConfiguration()
        switch raw {
        case "cpuOnly": config.computeUnits = .cpuOnly
        case "cpuAndNeuralEngine": config.computeUnits = .cpuAndNeuralEngine
        case "cpuAndGPU": config.computeUnits = .cpuAndGPU
        case "all": config.computeUnits = .all
        default:
            Log.warning("Unknown VEDIVOX_DIARIZER_COMPUTE_UNITS '\(raw)' — using FluidAudio default")
            return nil
        }
        Log.info("Diarizer compute units pinned: \(raw)")
        return config
    }

    /// Warm up whichever diarizer will actually run — the offline stack by
    /// default — so the first meeting doesn't download models
    /// mid-processing. `onProgress` reports fraction in [0, 1], or nil for the
    /// offline stage whose `prepareModels` exposes no progress handler.
    func prewarm(onProgress: (@Sendable (Double?) -> Void)? = nil) async throws {
        if Self.useOfflineDiarizer {
            _ = try await ensureOfflineDiarizer(onProgress: onProgress)
        } else {
            try await initialize(onProgress: onProgress)
        }
    }

    func initialize(onProgress: (@Sendable (Double?) -> Void)? = nil) async throws {
        if isModelLoaded { return }

        Log.info("Preparing diarizer models...")

        let models = try await onlineLoader.run {
            let handler: ProgressHandler?
            if let onProgress {
                handler = { @Sendable progress in onProgress(progress.fractionCompleted) }
            } else {
                handler = nil
            }
            return try await DiarizerModels.download(
                configuration: Self.modelConfiguration(),
                progressHandler: handler
            )
        }
        if diarizer == nil {
            let config = DiarizerConfig(clusteringThreshold: 0.7)
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            diarizer = manager
            isModelLoaded = true
            Log.info("Models ready")
        }
    }

    func diarize(
        audioURL: URL,
        knownSpeakers: [KnownSpeaker] = []
    ) async throws -> DiarizationResult {
        if Self.useOfflineDiarizer {
            return try await diarizeOffline(audioURL: audioURL, knownSpeakers: knownSpeakers)
        }

        if !isModelLoaded {
            try await initialize()
        }

        guard let diarizer else {
            throw DiarizationError.notInitialized
        }

        // Reset speaker manager and enroll known speakers
        diarizer.speakerManager.reset()
        if !knownSpeakers.isEmpty {
            // 0.15.x: Speaker is a struct with a public init — construct directly.
            // Contextual `.init` lets the parameter type ([FluidAudio.Speaker])
            // pick the right Speaker: the name is unqualifiable here (Vedivox.Speaker
            // shadows it, and `FluidAudio.` resolves to a TYPE in that module, not
            // the module). The old JSON round-trip workaround is gone.
            diarizer.initializeKnownSpeakers(knownSpeakers.map { s in
                .init(
                    id: s.id,
                    name: s.name,
                    currentEmbedding: s.embedding,
                    isPermanent: true
                )
            })
            Log.info("Enrolled \(knownSpeakers.count) known speakers")
        }

        Log.info("Processing \(audioURL.lastPathComponent)")

        let samples = try loadSamples(from: audioURL)
        let result = try diarizer.performCompleteDiarization(samples)

        let segments = result.segments.map { seg in
            DiarizationSegment(
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                speaker: seg.speakerId,
                embedding: seg.embedding
            )
        }

        let allSpeakers = diarizer.speakerManager.getAllSpeakers()
        let speakerEmbeddings = allSpeakers.reduce(into: [String: [Float]]()) { result, entry in
            result[entry.key] = entry.value.currentEmbedding
        }

        Log.info("Found \(segments.count) segments, speakers: \(Set(segments.map(\.speaker)).sorted().joined(separator: ", "))")

        return DiarizationResult(segments: segments, speakerEmbeddings: speakerEmbeddings)
    }

    // MARK: - Offline Diarizer

    /// Lazily builds + loads the offline diarizer, deduped via `offlineLoader`
    /// so warm-up and the first `diarize()` can't both download the pyannote
    /// stack. `prepareModels` exposes no progress handler, so
    /// `onProgress` fires once with nil to mark the stage as indeterminate.
    private func ensureOfflineDiarizer(
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> OfflineDiarizerManager {
        let manager = try await offlineLoader.run {
            Log.info("Preparing offline diarizer models (pyannote stack)...")
            let offline = OfflineDiarizerManager(config: Self.makeOfflineConfig())
            onProgress?(nil)
            try await offline.prepareModels(configuration: Self.modelConfiguration())
            Log.info("Offline diarizer models ready")
            return offline
        }
        if offlineDiarizer == nil { offlineDiarizer = manager }
        return manager
    }

    /// Bench-tuned offline diarizer config (Tier-1 sweep), with
    /// env overrides for future sweeps. Extracted so warm-up and processing
    /// build an identical config.
    static func makeOfflineConfig() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        // 0.75 instead of the community default 0.6: the bench
        // sweep over 0.45–0.85 found a wide plateau at 0.70–0.85 where the
        // 5-speaker M4 stops under-clustering (confusion 87.8s → 15.0s) with
        // M1/M2/M3 unchanged; 0.75 is the plateau middle. Sweep table in the
        // the bench notes. Env knob kept for future sweeps.
        // FluidAudio ≥ 0.16 (#802) cuts the AHC dendrogram at the value itself;
        // ≤ 0.15 read it as a cosine similarity and cut at sqrt(2 − 2t). The
        // sweep ran on the old reading, so 0.75 is carried over as its cut,
        // 0.7071. The env knob takes the new reading.
        config.clustering.threshold = (2 - 2 * 0.75).squareRoot()
        // Tier-1 sweep winners (2026-06-12, deterministic seeded bench;
        // table the bench notes). Σconfusion M1-M5 93.6s → 70.2s,
        // short-utterance recall up across the board (M2 84→96%, M5 82→90%):
        // - minSegmentDuration 1.0 → 0.5: stop killing sub-second diar
        //   segments in sanitize() — the single biggest confusion win
        //   (M1 4.2→1.0, M2 12.0→4.4, M5 52.7→45.3).
        // - exclusiveSegments false: don't hand overlap tails to the
        // earlier speaker; the per-token merger resolves
        //   overlapping diar segments correctly on its own.
        // - warmStartFa 0.07 → 0.2: more acoustic evidence vs prior in VBx
        //   repairs the M3 false-alarm side effect of minSegmentDuration
        //   (148s → 90.5s, back to baseline). 0.3 over-fragments M2.
        config.embedding.minSegmentDurationSeconds = 0.5
        config.postProcessing.exclusiveSegments = false
        config.clustering.warmStartFa = 0.2
        // Bench-sweep knobs override the values above; winners get
        // hardcoded here like the 0.75 threshold (precedent).
        let env = ProcessInfo.processInfo.environment
        var overrides: [String] = []
        if let v = env["VEDIVOX_OFFLINE_CLUSTERING_THRESHOLD"].flatMap(Double.init) {
            config.clustering.threshold = v
            overrides.append("threshold=\(v)")
        }
        if let v = env["VEDIVOX_OFFLINE_STEP_RATIO"].flatMap(Double.init) {
            config.segmentation.stepRatio = v
            overrides.append("stepRatio=\(v)")
        }
        if let v = env["VEDIVOX_OFFLINE_MIN_SEGMENT_DURATION"].flatMap(Double.init) {
            config.embedding.minSegmentDurationSeconds = v
            overrides.append("minSegmentDuration=\(v)")
        }
        if let v = env["VEDIVOX_OFFLINE_MIN_DURATION_OFF"].flatMap(Double.init) {
            config.segmentation.minDurationOff = v
            overrides.append("minDurationOff=\(v)")
        }
        if let v = env["VEDIVOX_OFFLINE_EXCLUSIVE_SEGMENTS"] {
            config.postProcessing.exclusiveSegments = v == "1" || v == "true"
            overrides.append("exclusiveSegments=\(config.postProcessing.exclusiveSegments)")
        }
        if let v = env["VEDIVOX_OFFLINE_FA"].flatMap(Double.init) {
            config.clustering.warmStartFa = v
            overrides.append("Fa=\(v)")
        }
        if let v = env["VEDIVOX_OFFLINE_FB"].flatMap(Double.init) {
            config.clustering.warmStartFb = v
            overrides.append("Fb=\(v)")
        }
        if !overrides.isEmpty {
            Log.info("Offline diarizer config overrides: \(overrides.joined(separator: ", "))")
        }
        // Chunk-window embeddings feed the Stage-2.5 rescue.
        config.exposeChunkEmbeddings = true
        return config
    }

    /// Same DiarizationResult contract as the online path — downstream code
    /// (TranscriptMerger, SpeakerMatcher Stage 2) doesn't know which ran.
    private func diarizeOffline(
        audioURL: URL,
        knownSpeakers: [KnownSpeaker]
    ) async throws -> DiarizationResult {
        if !knownSpeakers.isEmpty {
            // No prod call site passes knownSpeakers (identity is Stage-2's job
            // since 036); the offline pipeline has no enrollment API.
            Log.warning("Offline diarizer ignores \(knownSpeakers.count) known speakers (no enrollment API)")
        }

        let offline = try await ensureOfflineDiarizer()

        Log.info("Processing \(audioURL.lastPathComponent) [offline diarizer]")
        let result = try await offline.process(audioURL)

        let clusterSegments = result.segments.map { seg in
            DiarizationSegment(
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                speaker: seg.speakerId,
                embedding: seg.embedding
            )
        }

        // Offline pipelines populate speakerDatabase; fall back to per-speaker
        // centroid means from the (centroid-stamped) segments if absent.
        let speakerEmbeddings: [String: [Float]]
        if let db = result.speakerDatabase, !db.isEmpty {
            speakerEmbeddings = db
        } else {
            speakerEmbeddings = Dictionary(grouping: clusterSegments, by: \.speaker)
                .compactMapValues { segs -> [Float]? in
                    guard let dim = segs.first?.embedding.count, dim > 0 else { return nil }
                    var mean = [Float](repeating: 0, count: dim)
                    for seg in segs where seg.embedding.count == dim {
                        for i in 0 ..< dim { mean[i] += seg.embedding[i] }
                    }
                    let n = Float(segs.count)
                    return mean.map { $0 / n }
                }
        }

        // segment-own-voice § 1: each segment's own vector from its cluster's
        // windows instead of the centroid copy FluidAudio stamps on all of them.
        var trace = PerfTrace("ownVectors(\(audioURL.lastPathComponent))")
        let own = SegmentVoice.ownVectors(clusterSegments, chunks: result.chunkEmbeddings ?? [])
        trace.checkpoint("\(clusterSegments.count) segments × \(result.chunkEmbeddings?.count ?? 0) windows")
        trace.finish()
        let segments = own.segments

        Log.info("Found \(segments.count) segments [offline] (own voice: \(own.nearestWindow) on nearest window, \(own.centroid) on centroid), speakers: \(Set(segments.map(\.speaker)).sorted().joined(separator: ", "))")

        return DiarizationResult(
            segments: segments,
            speakerEmbeddings: speakerEmbeddings,
            chunkEmbeddings: result.chunkEmbeddings
        )
    }

    // MARK: - Audio Loading

    private func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DiarizationError.processFailed("Failed to create audio buffer")
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw DiarizationError.processFailed("No audio channel data")
        }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }

    enum DiarizationError: Error, LocalizedError {
        case notInitialized
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: "Diarization model not initialized"
            case .processFailed(let msg): "Diarization failed: \(msg)"
            }
        }
    }
}

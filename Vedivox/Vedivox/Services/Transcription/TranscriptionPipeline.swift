import AVFoundation
import FluidAudio
import Foundation

/// Orchestrates the full transcription pipeline:
/// capture → convert → transcribe (parallel) → diarize with enrollment → merge → save to DB.
actor TranscriptionPipeline {
    private let transcriptionService = TranscriptionService()
    private let diarizationService = DiarizationService()
    private let meetingRepo: MeetingRepository

    /// Injected DB handle. Defaults to the shared production database; the scenario
    /// benchmark passes an isolated instance so a run never touches real data.
    private let db: DatabaseManager
    /// When set, per-meeting working directories live under this root instead of
    /// `~/Library/Application Support/Vedivox/audio/`. Keeps benchmark intermediates
    /// out of the real audio folder.
    private let audioRoot: URL?
    /// When false, skip the final WAV→AAC compression pass. The benchmark feeds
    /// fixture `.m4a` files directly and must not rewrite them.
    private let compressAudio: Bool

    private var isModelLoaded = false

    /// `skipWarmUp`: tests only — no model is loaded, so the ASR step throws
    /// `notInitialized` mid-pipeline, the way a real transcription failure does.
    init(db: DatabaseManager = .shared, audioRoot: URL? = nil, compressAudio: Bool = true, skipWarmUp: Bool = false) {
        self.db = db
        self.audioRoot = audioRoot
        self.compressAudio = compressAudio
        self.isModelLoaded = skipWarmUp
        self.meetingRepo = MeetingRepository(db: db)
    }

    /// Post-processes segments before they hit the database: restores «ё» (which
    /// Parakeet's vocabulary cannot represent at all) and rewrites transliterated
    /// technical terms to canonical spelling. See `TermNormalizer`.
    private func postProcess(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // Read on every pass, so an edit reaches the next processing without
        // a relaunch; the file is a few KB.
        let vocabulary = TermNormalizer.loadVocabulary()
        let result = TermNormalizer.apply(to: segments, vocabulary: vocabulary)
        let changed = zip(segments, result).filter { $0.text != $1.text }.count
        if changed > 0 {
            Log.info("Post-processing rewrote \(changed)/\(segments.count) segments")
        }
        // ASR yields an empty segment for a stretch of silence; saved, it
        // showed as a speaker card with no text (#6).
        return result.filter { !$0.text.isEmpty }
    }

    /// Pre-load transcription + diarization models so first run is fast.
    ///
    /// `onProgress` receives per-stage download/compile progress for the loading
    /// banner. Warms up the diarizer that will actually run — the
    /// offline stack by default — so the first meeting doesn't download models
    /// mid-processing. Concurrent callers can't double-download: each service
    /// dedups its load through `SingleFlight`.
    func warmUp(onProgress: (@Sendable (ModelLoadProgress) -> Void)? = nil) async throws {
        if isModelLoaded { return }

        let txProgress: (@Sendable (Double) -> Void)?
        let diProgress: (@Sendable (Double?) -> Void)?
        if let onProgress {
            txProgress = { fraction in onProgress(ModelLoadProgress(stage: .transcription, fraction: fraction)) }
            diProgress = { fraction in onProgress(ModelLoadProgress(stage: .diarization, fraction: fraction)) }
        } else {
            txProgress = nil
            diProgress = nil
        }

        try await transcriptionService.initialize(onProgress: txProgress)
        try await diarizationService.prewarm(onProgress: diProgress)
        isModelLoaded = true
    }

    // MARK: - Live windows

    /// Loads the ASR model if it is not loaded yet — the same one, not a copy.
    /// `nonisolated`, like `transcribeLive`: a meeting being processed holds
    /// this actor for long stretches, and live text of the next recording must
    /// not queue behind it.
    nonisolated func prepareLive() async throws {
        try await transcriptionService.initialize()
    }

    /// Segments of one window (up to 15 s of 16 kHz mono) of a running
    /// recording, timed from the window's start. Nothing is stored.
    nonisolated func transcribeLive(_ samples: [Float]) async throws -> [TokenGrouper.Segment] {
        try await transcriptionService.transcribe(samples: samples)
    }

    /// Transcribes a short dictation clip and returns post-processed plain text.
    ///
    /// Deliberately reuses this pipeline's `TranscriptionService` rather than
    /// standing up a second one: the model is already warm from `warmUp()`, and
    /// a separate `AsrManager` would duplicate it in memory for no benefit.
    ///
    /// Nothing is written to the database — dictation is not a meeting.
    func transcribeDictation(_ audioURL: URL) async throws -> String {
        // The recognizer only — not `warmUp()`, which also loads the diarizer.
        // Dictation does not diarize, and on a first run it waited through the
        // diarizer's download, or failed with it, for nothing.
        try await transcriptionService.initialize()
        let result = try await transcriptionService.transcribe(audioURL)

        // Read on every pass, so an edit reaches the next processing without
        // a relaunch; the file is a few KB.
        let vocabulary = TermNormalizer.loadVocabulary()
        return TermNormalizer
            .normalize(result.text, vocabulary: vocabulary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Process a recorded meeting: transcribe mic + system audio, diarize with enrollment, merge, save.
    /// `suppressEcho`: true/false — explicit choice; nil — autodetect speaker bleed.
    /// `justRecorded`: a recording this install has just made, so a sounding
    /// system track proves the permission (Settings → Privacy);
    /// a reprocess of an older one proves nothing.
    /// `silentCallTrack`: the recording ended with `SilentCallTrack`'s warning
    /// up — the call played, the system track stayed zero.
    /// `choppedCallAudio`: the chopped-call warning was up during the recording.
    func processMeeting(
        meetingId: String,
        micAudioURL: URL,
        systemAudioURL: URL? = nil,
        suppressEcho: Bool? = nil,
        justRecorded: Bool = false,
        silentCallTrack: Bool = false,
        choppedCallAudio: Bool = false
    ) async throws {
        try await meetingRepo.updateStatus(meetingId, status: .transcribing)

        do {
            try await warmUp()

            // Tracks that sounded but produced no transcript, or whose compressed
            // copy failed verification (audio-integrity). Non-empty → the meeting
            // is not `done`, it needs attention.
            var attention = silentCallTrack ? [SilentCallTrack.attention] : []
            if choppedCallAudio { attention.append(TapChopDetector.attention) }
            if let systemAudioURL {
                attention += try await processTwoStream(
                    meetingId: meetingId,
                    micAudioURL: micAudioURL,
                    systemAudioURL: systemAudioURL,
                    suppressEcho: suppressEcho,
                    justRecorded: justRecorded
                )
            } else {
                attention += try await processMicOnly(
                    meetingId: meetingId,
                    micAudioURL: micAudioURL
                )
            }

            // Compress WAV → AAC 128kbps mono for storage (~33x smaller)
            if compressAudio {
                attention += try await compressAudioFiles(
                    meetingId: meetingId,
                    micAudioURL: micAudioURL,
                    systemAudioURL: systemAudioURL
                )
            }

            // Hand verdicts win over this pass (listen-queue § 4); the
            // foreign-voice rule must see the corrected attribution.
            try await MarkRepository(db: db).applyVerdicts(meetingId: meetingId)

            // Решение 7: the default applies when the meeting is processed,
            // not when its window is opened — otherwise MCP and the CLI would
            // see a different picture than the app does.
            try await ForeignVoicePolicy(db: db).applyDefault(meetingId: meetingId)

            try await meetingRepo.updateStatus(
                meetingId,
                status: Self.finalStatus(attention, meetingId: meetingId),
                reason: MeetingStatusReason.stored(attention)
            )
        } catch {
            try await meetingRepo.updateStatus(meetingId, status: .error)
            throw error
        }
    }

    // MARK: - Mic Only (Phase 1 path)

    /// Returns the names of tracks that need attention (see `processMeeting`).
    private func processMicOnly(meetingId: String, micAudioURL: URL) async throws -> [String] {
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        let micConvertedURL = audioDir.appendingPathComponent("mic_16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: micAudioURL, output: micConvertedURL)
        var micStats = try AudioConverter.verify(source: micAudioURL, result: micConvertedURL)

        let result = try await transcriptionService.transcribe(micConvertedURL)
        let attention = [Self.lostTrack("mic", stats: micStats, texts: result.segments.map(\.text))].compactMap { $0 }

        let segments = result.segments.map { seg in
            TranscriptSegment(
                meetingId: meetingId,
                speakerLabel: "me",
                source: .mic,
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: seg.confidence
            )
        }

        try await meetingRepo.replaceSegments(for: meetingId, with: postProcess(segments))

        // Project exclusion marks BEFORE speaker linking: recalculateEmbedding
        // filters on isExcluded, so the cache must be set by the time any
        // recalc below runs.
        try await MarkRepository(db: db).reproject(meetingId: meetingId)

        // Link mic "me" segments to the isMe speaker record
        try await linkMicToMeSpeaker(
            meetingId: meetingId,
            micConvertedURL: micConvertedURL,
            candidates: []
        )

        cleanupTempFiles([micConvertedURL])
        return attention
    }

    // MARK: - Two-Stream (Phase 2)

    private func processTwoStream(
        meetingId: String,
        micAudioURL: URL,
        systemAudioURL: URL,
        suppressEcho: Bool? = nil,
        justRecorded: Bool
    ) async throws -> [String] {
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        let systemConvertedURL = audioDir.appendingPathComponent("system_16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: systemAudioURL, output: systemConvertedURL)
        let systemStats = try AudioConverter.verify(source: systemAudioURL, result: systemConvertedURL)
        if justRecorded, systemStats.sounded { PermissionFacts.noteSystemAudioHeard() }

        let micConvertedURL = audioDir.appendingPathComponent("mic_16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: micAudioURL, output: micConvertedURL)
        var micStats = try AudioConverter.verify(source: micAudioURL, result: micConvertedURL)
        var attention: [String] = []

        // Echo suppression: gate mic audio where system audio is active.
        // Explicit true/false comes from the reprocess UI / MCP; nil (fresh
        // recordings) autodetects speaker bleed via envelope correlation.
        let suppressedM4A = audioDir.appendingPathComponent("mic_suppressed.m4a")
        let suppressedWAV = audioDir.appendingPathComponent("mic_suppressed_16k.wav")
        var micTranscriptionURL = micConvertedURL

        var preloadedMic: [Float]?
        var preloadedSys: [Float]?
        var applySuppression: Bool
        if let explicit = suppressEcho {
            applySuppression = explicit
        } else {
            do {
                let micSamples = try AudioGate.loadSamples(from: micConvertedURL)
                let sysSamples = try AudioGate.loadSamples(from: systemConvertedURL)
                let detection = EchoDetector.detectSpeakerBleed(
                    micSamples: micSamples,
                    systemSamples: sysSamples,
                    sampleRate: 16000
                )
                applySuppression = detection.isSpeakerMode
                preloadedMic = micSamples
                preloadedSys = sysSamples
                Log.info("Echo autodetect: \(Int(detection.highCorrFraction * 100))% high-corr windows (\(detection.validWindows) valid) → \(detection.isSpeakerMode ? "SPEAKER, applying gate" : "headphones, no gate")")
            } catch {
                Log.error("Echo autodetect failed, assuming headphones: \(error.localizedDescription)")
                applySuppression = false
            }
        }

        if applySuppression {
            Log.info("Applying echo suppression gate")
            do {
                let micSamples = try preloadedMic ?? AudioGate.loadSamples(from: micConvertedURL)
                let sysSamples = try preloadedSys ?? AudioGate.loadSamples(from: systemConvertedURL)
                Log.info("Gate input: mic=\(micSamples.count) samples, sys=\(sysSamples.count) samples")

                let gated = AudioGate.apply(
                    micSamples: micSamples,
                    systemSamples: sysSamples,
                    sampleRate: 16000
                )

                let zeroCount = gated.filter { $0 == 0.0 }.count
                Log.info("Gate result: \(zeroCount)/\(gated.count) samples zeroed (\(gated.count > 0 ? zeroCount * 100 / gated.count : 0)%)")

                try AudioGate.writeSamples(gated, to: suppressedWAV)
                // The gate removes energy on purpose; only the duration is checked.
                try AudioConverter.verify(source: micConvertedURL, result: suppressedWAV, requireEnergy: false)
                micTranscriptionURL = suppressedWAV
                // «Sounded but no transcript» must look at what is transcribed:
                // a mic the gate emptied as a copy of the system track is not a
                // lost track (three BlackHole loopback runs went needsAttention).
                micStats = try AudioConverter.trackStats(of: suppressedWAV)

                try await AudioConverter.compressToAAC(input: suppressedWAV, output: suppressedM4A)
                Log.info("Echo suppression complete")
            } catch {
                Log.error("Echo suppression failed, using original mic: \(error.localizedDescription)")
            }
        } else {
            // Remove old suppressed files (idempotent reprocess)
            try? FileManager.default.removeItem(at: suppressedM4A)
            try? FileManager.default.removeItem(at: suppressedWAV)
        }

        // Two-stage diarization: Stage 1 runs FluidAudio with NO
        // enrollment so within-meeting clustering is purely acoustic. Enrolled
        // identities are matched against cluster centroids in Stage 2 below.
        let candidates = try await Self.enrolledCandidates(db: db)
        Log.info("Two-stage: \(candidates.count) enrolled candidates loaded [\(candidates.map(\.displayName).joined(separator: ", "))]")

        // Diarize system audio (Stage 1, no enrollment) — parallel with mic transcription.
        async let diarizationTask = diarizationService.diarize(
            audioURL: systemConvertedURL,
            knownSpeakers: []
        )

        let micResult = try await transcriptionService.transcribe(micTranscriptionURL)
        if let lost = Self.lostTrack("mic", stats: micStats, texts: micResult.segments.map(\.text)) {
            attention.append(lost)
        }

        // A step of the call track that fails on audio that sounded is a loss,
        // not a finished meeting: without the mark below the meeting went
        // `done` with nobody but the owner in it, or with every remote voice
        // unnamed, and the failure was a line in the log.
        var diarizationResult: DiarizationService.DiarizationResult?
        // the diarizer doubles as the speech detector of the system track.
        var systemHasNoSpeech = false
        do {
            diarizationResult = try await diarizationTask
            systemHasNoSpeech = diarizationResult?.segments.isEmpty == true
        } catch {
            systemHasNoSpeech = Self.isNoSpeech(error)
            // A quiet call track is a normal meeting, not an error (#11).
            if systemHasNoSpeech {
                Log.info("System track has no speech — no speaker labels from it")
            } else {
                Log.error("Diarization failed (continuing without speaker labels): \(error.localizedDescription)")
            }
            if let loss = Self.diarizationLoss(error, stats: systemStats) { attention.append(loss) }
        }

        // Transcribe system audio
        var systemSegments: [TranscriptSegment] = []
        var systemTokens: [TokenTiming] = []
        do {
            let systemResult = try await transcriptionService.transcribe(systemConvertedURL)
            if let lost = Self.lostTrack(
                "system", stats: systemStats, texts: systemResult.segments.map(\.text), noSpeech: systemHasNoSpeech
            ) {
                attention.append(lost)
            }
            systemTokens = systemResult.tokenTimings
            systemSegments = systemResult.segments.map { seg in
                TranscriptSegment(
                    meetingId: meetingId,
                    source: .system,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: seg.confidence
                )
            }
        } catch {
            Log.error("System audio transcription failed (continuing with mic only): \(error.localizedDescription)")
            if let lost = Self.lostTrack("system", stats: systemStats, texts: []) { attention.append(lost) }
        }

        try await meetingRepo.updateStatus(meetingId, status: .diarizing)
        // Space marker BEFORE segments land: recalculateEmbedding attributes this
        // meeting's segment embeddings to a canonical pool via meetings.diarizer.
        try await meetingRepo.setDiarizer(
            meetingId,
            kind: DiarizationService.useOfflineDiarizer ? "offline" : "online"
        )

        let micSegments = micResult.segments.map { seg in
            TranscriptSegment(
                meetingId: meetingId,
                speakerLabel: "me",
                source: .mic,
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: seg.confidence
            )
        }

        // Stage 2: per-segment canonical affinity, falling back to
        // cluster centroid match. See `SubClusterSplitter` for why.
        let diarization = diarizationResult?.segments ?? []
        let speakerEmbeddings = diarizationResult?.speakerEmbeddings ?? [:]

        let matcher = SpeakerMatcher()
        let matchResults = matcher.matchAllWithAffinity(
            clusterToSegments: clusterToSegmentsMap(diarization),
            pool: candidates
        )

        let (remappedDiarization, labelToDbId) = applyMatcherResults(
            diarization,
            speakerEmbeddings: speakerEmbeddings,
            matchResults: matchResults
        )

        // rebuild segments from tokens along diarization boundaries so
        // a token group can't straddle a speaker change; legacy group-then-label
        // path remains the fallback (no tokens / no diarization).
        var labeledSystemSegments: [TranscriptSegment]
        if remappedDiarization.isEmpty {
            labeledSystemSegments = systemSegments
        } else if let assembled = TranscriptMerger.assembleByDiarization(
            tokens: systemTokens,
            diarization: remappedDiarization,
            meetingId: meetingId,
            source: .system
        ) {
            labeledSystemSegments = assembled
            Log.info("Diar-aligned reassembly: \(systemSegments.count) grouped → \(assembled.count) segments")
        } else {
            labeledSystemSegments = TranscriptMerger.mapSpeakerLabels(segments: systemSegments, diarization: remappedDiarization)
        }

        // Stage 2.5: rescue minority speakers merged into foreign
        // clusters, using chunk-window embeddings against the enrolled pool.
        var fullLabelToDbId = labelToDbId
        let rescueOutcome = applySegmentRescue(
            to: labeledSystemSegments,
            chunkEmbeddings: diarizationResult?.chunkEmbeddings,
            matchResults: matchResults,
            pool: candidates,
            clusterCentroids: speakerEmbeddings,
            boundLabels: labelToDbId,
            clusterMass: Self.clusterMass(diarization)
        )
        labeledSystemSegments = rescueOutcome.segments
        fullLabelToDbId.merge(rescueOutcome.labelToDbId) { current, _ in current }

        // Log speaker distribution
        let speakerCounts = Dictionary(grouping: labeledSystemSegments, by: { $0.speakerLabel ?? "?" }).mapValues(\.count)
        Log.info("Two-stage: speaker distribution in system segments: \(speakerCounts.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value) segs" }.joined(separator: ", "))")

        let merged = TranscriptMerger.merge(
            micSegments: micSegments,
            systemSegments: labeledSystemSegments
        )

        try await meetingRepo.replaceSegments(for: meetingId, with: postProcess(merged))

        // Project exclusion marks BEFORE speaker attribution: recalculateEmbedding
        // filters on isExcluded, so the cache must be set by the time any
        // recalc below runs.
        try await MarkRepository(db: db).reproject(meetingId: meetingId)

        try await createSpeakersFromDiarization(
            merged,
            meetingId: meetingId,
            speakerEmbeddings: speakerEmbeddings,
            labelToDbId: fullLabelToDbId
        )

        // Link mic "me" segments to the isMe speaker record
        try await linkMicToMeSpeaker(
            meetingId: meetingId,
            micConvertedURL: micConvertedURL,
            candidates: candidates
        )

        // Cleanup ghost links and orphaned temp speakers
        let speakerRepoCleanup = SpeakerRepository(db: db)
        try await speakerRepoCleanup.cleanupGhostLinks(meetingId: meetingId)

        var tempFiles = [micConvertedURL, systemConvertedURL]
        if FileManager.default.fileExists(atPath: suppressedWAV.path) {
            tempFiles.append(suppressedWAV)
        }
        cleanupTempFiles(tempFiles)
        return attention
    }

    // MARK: - Audio integrity (fix-multichannel-audio-loss)

    /// A track that sounded but produced no transcript is a loss, not silence.
    /// Unless what sounded was not speech: with `noSpeech` — the
    /// diarizer found none on the track — music or a notification sound
    /// honestly transcribes to nothing.
    static func lostTrack(
        _ name: String, stats: AudioConverter.TrackStats, texts: [String], noSpeech: Bool = false
    ) -> String? {
        let hasText = texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard stats.sounded, !hasText else { return nil }
        let level = String(format: "%.1f", stats.rmsDBFS)
        guard !noSpeech else {
            Log.info("\(name) track sounded (\(level) dBFS) without speech — the empty transcript is expected")
            return nil
        }
        Log.error("\(name) track sounded (\(level) dBFS) but produced no transcript")
        return name
    }

    /// The diarizer's verdict that a track carries no speech at all. Any other
    /// failure is no verdict: the track is then judged by its energy alone.
    static func isNoSpeech(_ error: Error) -> Bool {
        if case OfflineDiarizationError.noSpeechDetected = error { return true }
        return false
    }

    /// The diarizer failing on a call track that sounded is a loss — unless
    /// its failure is the verdict that there is no speech (music on
    /// the call track went needsAttention after the «expected» line).
    static func diarizationLoss(_ error: Error, stats: AudioConverter.TrackStats) -> String? {
        stats.sounded && !isNoSpeech(error) ? "system diarization" : nil
    }

    private static func finalStatus(_ attention: [String], meetingId: String) -> MeetingStatus {
        guard !attention.isEmpty else { return .done }
        Log.error("Meeting \(meetingId) needs attention: \(attention.joined(separator: ", "))")
        return .needsAttention
    }

    // MARK: - Import

    /// Process an imported file: extract audio, transcribe, diarize with enrollment, save.
    func processImportedFile(meetingId: String, fileURL: URL) async throws {
        try await meetingRepo.updateStatus(meetingId, status: .transcribing)

        do {
            try await warmUp()

            let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)

            let playbackURL = audioDir.appendingPathComponent("mic.wav")
            if fileURL.standardizedFileURL != playbackURL.standardizedFileURL {
                if FileManager.default.fileExists(atPath: playbackURL.path) {
                    try FileManager.default.removeItem(at: playbackURL)
                }
                try await AudioConverter.extractAudioToWAV(input: fileURL, output: playbackURL)
            }

            if var meeting = try await meetingRepo.find(meetingId) {
                meeting.micAudioPath = playbackURL.path
                if let audioFile = try? AVAudioFile(forReading: playbackURL) {
                    let dur = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                    meeting.durationSeconds = dur
                    meeting.endTime = meeting.startTime.addingTimeInterval(dur)
                }
                try await meetingRepo.save(meeting)
            }

            let analysis = try await analyzeImportAudio(
                playbackURL: playbackURL,
                workDir: audioDir,
                meetingId: meetingId,
                onDiarizing: {
                    try await self.meetingRepo.updateStatus(meetingId, status: .diarizing)
                    try await self.meetingRepo.setDiarizer(
                        meetingId,
                        kind: DiarizationService.useOfflineDiarizer ? "offline" : "online"
                    )
                }
            )
            var attention = analysis.attention
            let convertedURL = analysis.convertedURL
            let segments = analysis.segments

            try await meetingRepo.replaceSegments(for: meetingId, with: postProcess(segments))

            // Same ordering contract as the recorded paths: exclusion cache
            // first, then anything that recalculates canonicals.
            try await MarkRepository(db: db).reproject(meetingId: meetingId)

            try await createSpeakersFromDiarization(
                segments,
                meetingId: meetingId,
                speakerEmbeddings: analysis.speakerEmbeddings,
                labelToDbId: analysis.labelToDbId
            )

            // Cleanup ghost links and orphaned temp speakers
            let speakerRepoCleanup = SpeakerRepository(db: db)
            try await speakerRepoCleanup.cleanupGhostLinks(meetingId: meetingId)

            if compressAudio {
                attention += try await compressAudioFiles(
                    meetingId: meetingId,
                    micAudioURL: playbackURL,
                    systemAudioURL: nil
                )
            }

            var tempFiles = [convertedURL]
            if var meeting = try await meetingRepo.find(meetingId),
               let sourcePath = meeting.sourceFilePath {
                tempFiles.append(URL(fileURLWithPath: sourcePath))
                meeting.sourceFilePath = nil
                try await meetingRepo.save(meeting)
            }
            cleanupTempFiles(tempFiles)

            try await MarkRepository(db: db).applyVerdicts(meetingId: meetingId)

            try await meetingRepo.updateStatus(
                meetingId,
                status: Self.finalStatus(attention, meetingId: meetingId),
                reason: MeetingStatusReason.stored(attention)
            )
        } catch {
            try await meetingRepo.updateStatus(meetingId, status: .error)
            throw error
        }
    }

    /// Transcribes and diarizes a file without leaving a trace: no
    /// meeting row, no speaker rows, no canonical recalculation, no stored
    /// audio. Known speakers are still recognized — the pool is only read.
    func transcribeTransient(fileURL: URL) async throws -> [TranscriptSegment] {
        try await warmUp()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-transcribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let playbackURL = workDir.appendingPathComponent("mic.wav")
        try await AudioConverter.extractAudioToWAV(input: fileURL, output: playbackURL)
        let analysis = try await analyzeImportAudio(
            playbackURL: playbackURL, workDir: workDir, meetingId: "", onDiarizing: {}
        )
        return postProcess(analysis.segments)
    }

    /// A precise look at the tail of a running recording (change
    /// `live-speakers`, design D2): the call track through the compute half
    /// of an import — the same recognition, diarization and Stage 2 the final
    /// transcript gets — and the microphone through recognition alone, its
    /// speaker being the owner. Reads the speaker pool, writes nothing.
    ///
    /// Each tail is a finished audio file with the second of the recording it
    /// starts at.
    func analyzeLiveTail(
        mic: (url: URL, from: TimeInterval)?, system: (url: URL, from: TimeInterval)?
    ) async throws -> LiveTailAnalysis {
        let started = Date()
        try await warmUp()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-live-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var analysis = LiveTailAnalysis()
        if let system {
            let duration = (try? AVAudioFile(forReading: system.url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
            do {
                let heard = try await analyzeImportAudio(
                    playbackURL: system.url, workDir: workDir, meetingId: "", onDiarizing: {}
                )
                let pool = try await Self.enrolledCandidates(db: db)
                let (track, voices) = LiveTailAnalysis.system(
                    segments: heard.segments, labelToDbId: heard.labelToDbId, pool: pool,
                    from: system.from, duration: duration
                )
                analysis.system = track
                analysis.voices = voices
            } catch {
                // Not refined: the quick text of this stretch stays as it is.
                Log.error("Live tail: call track not refined — \(error.localizedDescription)")
            }
        }
        if let mic {
            let converted = workDir.appendingPathComponent("mic_16k.wav")
            try await AudioConverter.convertTo16kHzMonoWAV(input: mic.url, output: converted)
            let duration = (try? AVAudioFile(forReading: mic.url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
            do {
                let lines = try await transcriptionService.transcribe(converted).segments.map {
                    LiveTailAnalysis.Line(start: mic.from + $0.startTime, end: mic.from + $0.endTime, text: $0.text)
                }
                analysis.mic = .init(from: mic.from, to: mic.from + duration, lines: lines)
            } catch {
                Log.error("Live tail: microphone not refined — \(error.localizedDescription)")
            }
        }
        analysis.elapsed = Date().timeIntervalSince(started)
        return analysis
    }

    /// A precise pass over the last `tail` seconds of the files a recording is
    /// writing: their tails are copied out read-only (`RecordingTail`), then
    /// analysed. nil when neither track could be read or the pass failed —
    /// the quick text stays as it is.
    nonisolated func refineLiveTail(mic: URL?, system: URL?, last tail: TimeInterval) async -> LiveTailAnalysis? {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-live-tail-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            func copy(_ recording: URL?, _ name: String) -> (url: URL, from: TimeInterval)? {
                guard let recording else { return nil }
                let output = workDir.appendingPathComponent(name)
                // A track with no audio yet, or lost, is simply not refined.
                guard let copied = try? RecordingTail.copy(last: tail, of: recording, to: output) else { return nil }
                return (output, copied.from)
            }
            let micTail = copy(mic, "mic.wav")
            let systemTail = copy(system, "system.wav")
            guard micTail != nil || systemTail != nil else { return nil }
            return try await analyzeLiveTail(mic: micTail, system: systemTail)
        } catch {
            Log.error("Live tail: pass failed — \(error.localizedDescription)")
            return nil
        }
    }

    private struct ImportAnalysis {
        let segments: [TranscriptSegment]
        let speakerEmbeddings: [String: [Float]]
        let labelToDbId: [String: String]
        let attention: [String]
        let convertedURL: URL
    }

    /// The compute half of an import — convert, ASR, two-stage diarization,
    /// assembly, rescue. Reads the speaker pool, writes nothing to the DB;
    /// `onDiarizing` is where the import path reports its status.
    private func analyzeImportAudio(
        playbackURL: URL,
        workDir: URL,
        meetingId: String,
        onDiarizing: () async throws -> Void
    ) async throws -> ImportAnalysis {
        let convertedURL = workDir.appendingPathComponent("converted_16k.wav")
        if FileManager.default.fileExists(atPath: convertedURL.path) {
            try FileManager.default.removeItem(at: convertedURL)
        }
        try await AudioConverter.convertTo16kHzMonoWAV(input: playbackURL, output: convertedURL)
        let micStats = try AudioConverter.verify(source: playbackURL, result: convertedURL)

        let result = try await transcriptionService.transcribe(convertedURL)
        var attention = [Self.lostTrack("mic", stats: micStats, texts: result.segments.map(\.text))].compactMap { $0 }

        var segments = result.segments.map { seg in
            TranscriptSegment(
                meetingId: meetingId,
                source: .import,
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: seg.confidence
            )
        }

        // Two-stage diarization — see processTwoStream for the rationale.
        try await onDiarizing()

        let candidates = try await Self.enrolledCandidates(db: db)
        Log.info("Two-stage: \(candidates.count) enrolled candidates loaded [\(candidates.map(\.displayName).joined(separator: ", "))]")
        var diarizationResult: DiarizationService.DiarizationResult?
        do {
            diarizationResult = try await diarizationService.diarize(
                audioURL: convertedURL,
                knownSpeakers: []
            )
        } catch {
            Log.error("Diarization failed (continuing without speaker labels): \(error.localizedDescription)")
            if micStats.sounded { attention.append("diarization") }
        }

        let diarization = diarizationResult?.segments ?? []
        let speakerEmbeddings = diarizationResult?.speakerEmbeddings ?? [:]

        let matcher = SpeakerMatcher()
        let matchResults = matcher.matchAllWithAffinity(
            clusterToSegments: clusterToSegmentsMap(diarization),
            pool: candidates
        )

        let (remappedDiarization, labelToDbId) = applyMatcherResults(
            diarization,
            speakerEmbeddings: speakerEmbeddings,
            matchResults: matchResults
        )

        if !remappedDiarization.isEmpty {
            // same diar-aligned reassembly as the two-stream flow.
            if let assembled = TranscriptMerger.assembleByDiarization(
                tokens: result.tokenTimings,
                diarization: remappedDiarization,
                meetingId: meetingId,
                source: .import
            ) {
                Log.info("Diar-aligned reassembly: \(segments.count) grouped → \(assembled.count) segments")
                segments = assembled
            } else {
                segments = TranscriptMerger.mapSpeakerLabels(segments: segments, diarization: remappedDiarization)
            }
        }

        // Stage 2.5 — same rescue as the two-stream flow.
        var fullLabelToDbId = labelToDbId
        let rescueOutcome = applySegmentRescue(
            to: segments,
            chunkEmbeddings: diarizationResult?.chunkEmbeddings,
            matchResults: matchResults,
            pool: candidates,
            clusterCentroids: speakerEmbeddings,
            boundLabels: labelToDbId,
            clusterMass: Self.clusterMass(diarization)
        )
        segments = rescueOutcome.segments
        fullLabelToDbId.merge(rescueOutcome.labelToDbId) { current, _ in current }

        // Log speaker distribution
        let speakerCounts = Dictionary(grouping: segments, by: { $0.speakerLabel ?? "?" }).mapValues(\.count)
        Log.info("Two-stage: speaker distribution: \(speakerCounts.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value) segs" }.joined(separator: ", "))")

        return ImportAnalysis(
            segments: segments,
            speakerEmbeddings: speakerEmbeddings,
            labelToDbId: fullLabelToDbId,
            attention: attention,
            convertedURL: convertedURL
        )
    }

    // MARK: - Audio Compression

    /// The WAV is deleted only after the AAC copy is verified against it. A copy
    /// that fails verification is dropped, the WAV stays as the meeting's audio,
    /// and the track is reported for attention (design § решение 6).
    private func compressAudioFiles(
        meetingId: String,
        micAudioURL: URL,
        systemAudioURL: URL?
    ) async throws -> [String] {
        guard try await meetingRepo.find(meetingId) != nil else { return [] }
        var attention: [String] = []

        for (name, url) in [("mic", micAudioURL), ("system", systemAudioURL)] {
            guard let url, url.pathExtension.lowercased() == "wav" else { continue }
            let aacURL = url.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try await AudioConverter.compressAndReplace(wav: url, m4a: aacURL)
            } catch {
                // Any failure, not only a failed verification: the WAV goes
                // only after its copy is verified, so it is still the audio.
                // Other errors used to end the whole meeting in `error` after
                // the transcript was complete — and after mic.wav was already
                // replaced, with the row still pointing at it.
                Log.error("\(name).m4a not made, keeping \(name).wav: \(error.localizedDescription)")
                attention.append("\(name) compression")
                continue
            }
            // Per track, and only this column (see `updateAudioPaths`).
            try await meetingRepo.updateAudioPaths(
                meetingId,
                mic: name == "mic" ? aacURL.path : nil,
                system: name == "system" ? aacURL.path : nil
            )
        }
        return attention
    }

    // MARK: - Cleanup

    private func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Speaker Enrollment

    /// Stage 2 input — enrolled speakers eligible for matching, with segment counts.
    /// Filters out speakers with no embedding. The matcher itself further filters by
    /// `minSegmentsForCanonical` (default 5).
    ///
    /// The counts include the meeting being reprocessed: its old lines are
    /// still in the database, and leaving them out dropped every confirmed
    /// person whose lines all sat in that meeting — the new pass could not
    /// find them, and their lines went to an anonymous voice for good.
    ///
    /// Static, so the live transcript reads the same pool when a recording
    /// starts without waiting for this actor.
    static func enrolledCandidates(db: DatabaseManager = .shared) async throws -> [SpeakerMatcher.Candidate] {
        // Dual-pool: cluster centroids live in the active diarizer's
        // embedder space, so the canonical pool must come from the same space.
        let space: EmbeddingSpace = DiarizationService.useOfflineDiarizer ? .v2 : .v1
        let speakerRepo = SpeakerRepository(db: db)
        let speakers = try await speakerRepo.speakersWithEmbeddings(space: space)
        Log.info("Two-stage: candidate pool space \(space) (\(speakers.count) speakers)")
        // Pool hygiene — see `Speaker.isEligibleForMatchingPool`.
        let withEmbeddings = speakers.filter(\.isEligibleForMatchingPool)
        let counts = try await speakerRepo.segmentCounts(for: withEmbeddings.map(\.id))
        return withEmbeddings.map { speaker in
            SpeakerMatcher.Candidate(
                speakerId: speaker.id,
                displayName: speaker.displayName,
                canonical: speaker.embeddingArray ?? [],
                segmentCount: counts[speaker.id] ?? 0
            )
        }
    }

    /// Stage 2.5: run the per-window rescue over labeled segments.
    /// No-op when chunk embeddings are absent (online diarizer), when the pass
    /// is disabled via VEDIVOX_RESCUE_DISABLED, or when nothing clears the
    /// thresholds. `matchResults` provides cluster→enrolled ownership so the
    /// margin guard knows the incumbent; `clusterCentroids` stand in for it
    /// where no enrolled owner was found.
    private func applySegmentRescue(
        to segments: [TranscriptSegment],
        chunkEmbeddings: [ChunkEmbedding]?,
        matchResults: [String: SpeakerMatcher.Resolution],
        pool: [SpeakerMatcher.Candidate],
        clusterCentroids: [String: [Float]],
        boundLabels: [String: String],
        clusterMass: [String: Double]
    ) -> (segments: [TranscriptSegment], labelToDbId: [String: String]) {
        guard let chunkEmbeddings, !chunkEmbeddings.isEmpty,
              let config = SegmentRescue.Config.fromEnvironment()
        else {
            return (segments, [:])
        }

        let owners = matchResults.compactMapValues { resolution -> String? in
            if case .matched(let speakerId, _, _) = resolution { return speakerId }
            return nil
        }
        let rescue = SegmentRescue(config: config)
        let moves = rescue.planMoves(
            chunks: chunkEmbeddings,
            clusterOwners: owners,
            pool: pool,
            clusterCentroids: clusterCentroids,
            clusterMass: clusterMass
        )
        let outcome = rescue.apply(moves: moves, to: segments, boundLabels: boundLabels)
        // Seconds taken out of clusters nobody was identified in — the path
        // that used to feed lookalike canonicals. Logged even at zero.
        let unownedSeconds = moves.filter { owners[$0.fromCluster] == nil }
            .reduce(0) { $0 + $1.end - $1.start }
        let targets = Set(moves.map(\.toDisplayName)).sorted().joined(separator: ", ")
        Log.info(String(
            format: "Stage-2.5 rescue: %d windows, %.1fs of segments moved → [%@]; %.1fs of windows from unowned clusters",
            moves.count, outcome.movedSeconds, targets, unownedSeconds
        ))
        return (outcome.segments, outcome.labelToDbId)
    }

    /// Translate FluidAudio's anonymous within-meeting cluster ids ("1", "2", ...)
    /// to display-friendly labels using two-stage matcher decisions. The actual
    /// logic (including the micro-cluster persona policy) lives in
    /// `ClusterLabeler` so it is unit-testable without a database.
    /// Internal (not private) so `SpeakerMintTests` can verify the
    /// reserved-labels wiring without a full pipeline run.
    func applyMatcherResults(
        _ segments: [DiarizationService.DiarizationSegment],
        speakerEmbeddings: [String: [Float]],
        matchResults: [String: SpeakerMatcher.Resolution],
        reservedLabels: Set<String> = [],
        boundLabels: [String: String] = [:]
    ) -> (segments: [DiarizationService.DiarizationSegment], labelToDbId: [String: String]) {
        let config = ClusterLabeler.Config.fromEnvironment()
        let out = ClusterLabeler(config: config).apply(
            segments,
            speakerEmbeddings: speakerEmbeddings,
            matchResults: matchResults,
            reservedLabels: reservedLabels,
            boundLabels: boundLabels
        )
        return (segments: out.segments, labelToDbId: out.labelToDbId)
    }

    /// Speech seconds per Stage-1 cluster — the ownerless-rescue guards' input.
    static func clusterMass(_ segments: [DiarizationService.DiarizationSegment]) -> [String: Double] {
        segments.reduce(into: [:]) { $0[$1.speaker, default: 0] += max(0, Double($1.end - $1.start)) }
    }

    /// Group diarization segments by their FluidAudio cluster id. Keys are
    /// preserved exactly as they came from Stage 1.
    private func clusterToSegmentsMap(
        _ segments: [DiarizationService.DiarizationSegment]
    ) -> [String: [DiarizationService.DiarizationSegment]] {
        var out: [String: [DiarizationService.DiarizationSegment]] = [:]
        for seg in segments {
            out[seg.speaker, default: []].append(seg)
        }
        return out
    }

    /// Create or link speaker records from diarization results.
    /// Sets speakerId on transcript segments. Saves embeddings.
    /// Internal (not private) so `SpeakerMintTests` can drive it directly.
    func createSpeakersFromDiarization(
        _ segments: [TranscriptSegment],
        meetingId: String,
        speakerEmbeddings: [String: [Float]],
        labelToDbId: [String: String]
    ) async throws {
        let speakerRepo = SpeakerRepository(db: db)
        let labels = Set(segments.compactMap(\.speakerLabel)).subtracting(["me", "UNKNOWN"])
        var labelToSpeakerId = labelToDbId

        for label in labels {
            if let dbId = labelToDbId[label] {
                // Known speaker — link to meeting, set speakerId on segments
                Log.info("Enrollment: matched known speaker '\(label)' (id: \(dbId))")
                try await speakerRepo.assignSpeakerToMeeting(
                    meetingId: meetingId,
                    speakerId: dbId,
                    diarizationLabel: label
                )
                try await meetingRepo.renameSpeakerInMeeting(
                    meetingId: meetingId,
                    oldLabel: label,
                    newLabel: label,
                    speakerId: dbId
                )
            } else {
                // Dedupe by any name field. Auto `speaker_N`
                // labels never bind by name — the guard inside
                // findOrCreateSpeaker mints a fresh row for them
                // (speaker-row-per-mint), covering the UI paths too.
                let speaker = try await speakerRepo.findOrCreateSpeaker(name: label)
                Log.info("Two-stage: linked label '\(label)' to speaker \(speaker.id) (existing or newly created)")
                labelToSpeakerId[label] = speaker.id
                try await speakerRepo.assignSpeakerToMeeting(
                    meetingId: meetingId,
                    speakerId: speaker.id,
                    diarizationLabel: label
                )
                try await meetingRepo.renameSpeakerInMeeting(
                    meetingId: meetingId,
                    oldLabel: label,
                    newLabel: label,
                    speakerId: speaker.id
                )
            }
        }

        // Recalculate embeddings for all speakers in this meeting
        for label in labels {
            guard let speakerId = labelToSpeakerId[label] else { continue }
            try await speakerRepo.recalculateEmbedding(speakerId: speakerId, config: .automatic)
        }
    }

    // MARK: - Mic → isMe Speaker Linking

    /// Link mic segments to speakers.
    ///
    /// Recognition does not depend on any mode or setting
    /// (`foreign-voices-on-mic`, решения 1–3): the mic track is diarized
    /// whenever there is audio, unmatched voices that clear the mass floor
    /// become their own speakers, and the whole track goes to the owner only
    /// when exactly one voice was told apart. Whether foreign voices are then
    /// shown or hidden is `ForeignVoicePolicy`'s business, not this one's.
    private func linkMicToMeSpeaker(
        meetingId: String,
        micConvertedURL: URL?,
        candidates: [SpeakerMatcher.Candidate]
    ) async throws {
        let speakerRepo = SpeakerRepository(db: db)
        // the windows of the previous pass describe segments that no longer exist.
        try await MarkRepository(db: db).replaceOwnerLikely(meetingId: meetingId, with: [])
        guard let meSpeaker = try await speakerRepo.findMe() else {
            Log.info("No isMe speaker — mic segments stay as 'me'")
            return
        }

        // Ensure isMe speaker is linked to this meeting
        try? await speakerRepo.assignSpeakerToMeeting(
            meetingId: meetingId,
            speakerId: meSpeaker.id,
            diarizationLabel: meSpeaker.displayName
        )

        // The me-canonical must come from the active diarizer's space
        // meSpeaker.embeddingArray is always the v1 column.
        let micSpace: EmbeddingSpace = DiarizationService.useOfflineDiarizer ? .v2 : .v1
        let meCanonical = try await speakerRepo.canonicalArray(speakerId: meSpeaker.id, space: micSpace)
        let ownerIdentifiable = meCanonical != nil

        // Diarization needs no fingerprint: it tells voices apart, it does not
        // recognize them. The old `meCanonical != nil` gate stood on the wrong
        // question and cost us the fact that several people spoke.
        var distinctClusters = 0
        var diarized: (
            remapped: [DiarizationService.DiarizationSegment],
            labelToDbId: [String: String],
            speakerEmbeddings: [String: [Float]]
        )?
        // Stage-1 segments and the unnamed clusters whose best candidate is the owner.
        var ownerLikely: (clusters: [DiarizationService.DiarizationSegment], ids: Set<String>) = ([], [])
        if let micURL = micConvertedURL {
            do {
                // Two-stage matching also for mic — Stage 1 with no enrollment, Stage 2
                // matches cluster centroids against the candidate pool. Always include
                // isMe so mic-bleed clusters can be confidently routed back to "me".
                var micPool = candidates
                let alreadyInPool = micPool.contains { $0.speakerId == meSpeaker.id }
                if !alreadyInPool, let meEmbedding = meCanonical {
                    let meSegmentCount = (try? await speakerRepo
                        .segmentCounts(for: [meSpeaker.id])[meSpeaker.id]) ?? 0
                    micPool.append(SpeakerMatcher.Candidate(
                        speakerId: meSpeaker.id,
                        displayName: meSpeaker.displayName,
                        canonical: meEmbedding,
                        segmentCount: max(meSegmentCount, SpeakerMatcher.Config.default.minSegmentsForCanonical)
                    ))
                }

                Log.info("Two-stage (mic): diarizing with \(micPool.count) candidates in pool")
                let micDiarResult = try await diarizationService.diarize(
                    audioURL: micURL,
                    knownSpeakers: []
                )

                // Owner keeps the old thresholds, everyone else the system-track rules (stage2-mic-owner).
                let matcher = SpeakerMatcher(config: .mic(ownerId: meSpeaker.id))
                let micMatchResults = matcher.matchAllWithAffinity(
                    clusterToSegments: clusterToSegmentsMap(micDiarResult.segments),
                    pool: micPool
                )
                ownerLikely = (micDiarResult.segments, matcher.ownerLikelyClusters(
                    clusterToSegments: clusterToSegmentsMap(micDiarResult.segments),
                    pool: micPool,
                    results: micMatchResults
                ))

                // Minting is on: pool hygiene keeps unconfirmed `speaker_N` out
                // of the matching pool, and echo is already gone from the audio
                // by the time diarization sees it (решение 2). The mass floor
                // (10s / 2.5%) stays the only filter.
                // Labels the system track already used in this meeting — the
                // mic mint continues numbering after them so `speaker_N` stays
                // unique within the meeting (speaker-row-per-mint).
                let reservedLabels = try await meetingRepo.distinctSpeakerLabels(meetingId: meetingId)
                // Records the system track already bound here — a mic voice
                // matched to a namesake gets a distinct label (stage2-out-of-pool).
                let boundLabels = try await meetingRepo.speakerLabelBindings(meetingId: meetingId)
                let (remapped, labelToDbId) = applyMatcherResults(
                    micDiarResult.segments,
                    speakerEmbeddings: micDiarResult.speakerEmbeddings,
                    matchResults: micMatchResults,
                    reservedLabels: reservedLabels,
                    boundLabels: boundLabels
                )
                distinctClusters = Set(remapped.map(\.speaker)).count
                if !remapped.isEmpty {
                    diarized = (remapped, labelToDbId, micDiarResult.speakerEmbeddings)
                }
                Log.info("Mic diarization: \(distinctClusters) distinct voice(s), owner fingerprint: \(ownerIdentifiable)")
            } catch {
                // Unknown, not "several people": keep the pre-existing fallback
                // rather than demoting a whole healthy track to UNKNOWN.
                Log.error("Mic diarization failed, falling back to simple link: \(error)")
            }
        }

        let micSegments = try await meetingRepo.segmentsWithLabel(
            meetingId: meetingId, speakerLabel: "me"
        )

        switch MicAttribution.plan(
            hasMicAudio: micConvertedURL != nil,
            distinctClusters: distinctClusters
        ) {
        case .skip:
            Log.info("No mic audio — nothing to attribute on the mic track")
            return

        case .perSegment:
            guard let diarized, !micSegments.isEmpty else { break }
            let voicesByLabel = TranscriptMerger.timedVoicesByLabel(diarized.remapped)
            for segment in micSegments {
                guard let segId = segment.id else { continue }
                let match = TranscriptMerger.findBestMatch(
                    start: segment.startTime,
                    end: segment.endTime,
                    diarization: diarized.remapped
                )
                let attribution = MicAttribution.attribute(
                    matchedLabel: match.speaker,
                    overlap: match.overlap,
                    ownerIdentifiable: ownerIdentifiable,
                    ownerId: meSpeaker.id,
                    ownerDisplayName: meSpeaker.displayName,
                    labelToDbId: diarized.labelToDbId
                )
                // segment-own-voice § 2: the reply's own voice, not the vector
                // of its best-overlapping diarization segment.
                let embedding = match.overlap > 0
                    ? TranscriptMerger.ownEmbedding(
                        start: segment.startTime, end: segment.endTime,
                        voices: voicesByLabel[match.speaker] ?? []
                    )
                    : nil
                try await meetingRepo.updateSegmentSpeaker(
                    segmentId: segId,
                    speakerId: attribution.speakerId,
                    speakerLabel: attribution.label,
                    embedding: embedding
                )
            }

            // an unnamed voice whose best candidate is the owner is
            // not foreign — ForeignVoicePolicy reads these windows.
            let likelyOwn = MicAttribution.ownerLikelySegments(
                micSegments,
                clusters: ownerLikely.clusters,
                labeled: diarized.remapped,
                ownerLikelyClusters: ownerLikely.ids,
                labelToDbId: diarized.labelToDbId
            )
            try await MarkRepository(db: db).replaceOwnerLikely(
                meetingId: meetingId,
                with: ForeignVoicePolicy.coalescedIntervals(of: likelyOwn).map { ($0.start, $0.end) }
            )

            // Create speaker records for new speakers from mic diarization
            let updatedMicSegments = try await meetingRepo.segments(for: meetingId)
                .filter { $0.speakerLabel != nil && $0.speakerLabel != "UNKNOWN" }
            try await createSpeakersFromDiarization(
                updatedMicSegments,
                meetingId: meetingId,
                speakerEmbeddings: diarized.speakerEmbeddings,
                labelToDbId: diarized.labelToDbId
            )

            Log.info("Mic diarization applied: \(distinctClusters) speakers found")
            return

        case .assignWholeTrackToOwner:
            break
        }

        try await meetingRepo.linkMicSegmentsToSpeaker(
            meetingId: meetingId,
            speakerId: meSpeaker.id,
            speakerLabel: meSpeaker.displayName
        )
        Log.info("Linked all mic segments to isMe '\(meSpeaker.displayName)'")
    }
}

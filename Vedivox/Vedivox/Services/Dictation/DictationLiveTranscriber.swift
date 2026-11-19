import AVFoundation
import FluidAudio
import Foundation

/// Live draft transcript for dictation, on FluidAudio's streaming Nemotron
///
/// What it is **not**: the text that gets pasted. This model mishears where
/// Parakeet does not — the difference is of the kind «Отчёт не мог
/// согласование… пять дней с УПД ждать» against «Отчёт не получит
/// согласование… 5 дней ЭЦП ждать» — so the insertion stays with Parakeet
/// and this produces a draft, shown while the user is still speaking.
///
/// What holds regardless: the draft is never rewritten under the user.
/// `getPartialTranscript()` and `finish()` decode the same accumulating token
/// array, so text once shown only ever gets appended to.
///
/// An actor, and fed straight from the audio tap: `DictationController` is
/// `@MainActor`, and routing ~50 buffers/second through the main actor is what
/// made live text arrive in bursts at the end of the recording for pindrop.
actor DictationLiveTranscriber {

    enum State: Sendable, Equatable {
        case idle
        /// Model is being fetched. `fraction` is nil while the size is unknown.
        case downloading(fraction: Double?)
        case ready
        /// Live text is off for this dictation; recording and insertion are not
        /// affected. The reason is for the user, not for the log.
        case unavailable(reason: String)
    }

    private(set) var state: State = .idle

    private var manager: StreamingNemotronMultilingualAsrManager?
    private var loadedChunkSize: DictationChunkSize?
    private var vocabulary: TermNormalizer.Vocabulary?
    private var loading: Task<Void, Never>?
    /// Counts what actually reached the model this dictation. Without it,
    /// «no live text» is indistinguishable between «audio never arrived» and
    /// «the model heard it and produced nothing».
    private var fedChunks = 0
    private var fedSamples = 0
    /// Every call into the model goes through `serialized`. An actor is
    /// reentrant at each `await`: without this, `endDictation()` (finish +
    /// reset) ran while an `append()` was still inside `processChunk`, and the
    /// two interleaved chunks shared one CoreML output backing for `logits` —
    /// `findMaxIndex` then read past the end of it (SIGSEGV in
    /// `vDSP_maxvi`). The chain keeps at most one model call in flight.
    private var chain: Task<Void, Never>?

    private func serialized(_ body: @escaping @Sendable () async -> Void) async {
        let previous = chain
        let task = Task {
            await previous?.value
            await body()
        }
        chain = task
        await task.value
    }

    /// Prepares the model for `chunkSize`, downloading it if needed.
    ///
    /// Safe to call on every dictation: it returns immediately once the right
    /// variant is loaded. Changing the chunk size drops the old model and
    /// fetches another — each variant is a separate 640 MB download.
    func prepare(chunkSize: DictationChunkSize, onState: @escaping @Sendable (State) -> Void) async {
        // Per dictation, so a vocabulary edit applies without a relaunch.
        vocabulary = TermNormalizer.loadVocabulary()
        if loadedChunkSize == chunkSize, let manager {
            // Clear the previous dictation's tokens before anything is fed in,
            // or this draft opens with the last one's words.
            await serialized { await manager.reset() }
            set(.ready, notify: onState)
            return
        }

        // A dictation started while loading is already in flight must not kick
        // off a parallel 640 MB fetch — it joins the one running. Report the
        // current state first: the caller is showing a HUD right now and would
        // otherwise see nothing until the load finishes ~17 s later.
        if let loading {
            set(state, notify: onState)
            await loading.value
            if let manager { await serialized { await manager.reset() } }
            set(state, notify: onState)
            return
        }

        manager = nil
        loadedChunkSize = nil

        let task = Task { [chunkSize] in
            await self.load(chunkSize: chunkSize, onState: onState)
        }
        loading = task
        await task.value
        loading = nil
    }

    private func load(chunkSize: DictationChunkSize, onState: @escaping @Sendable (State) -> Void) async {
        set(.downloading(fraction: nil), notify: onState)
        ModelPins.apply()
        do {
            let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "auto",
                chunkMs: chunkSize.milliseconds,
                progressHandler: { [weak self] progress in
                    Task { await self?.set(.downloading(fraction: progress.fractionCompleted), notify: onState) }
                }
            )
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: directory)

            self.manager = manager
            self.loadedChunkSize = chunkSize
            set(.ready, notify: onState)
            Log.info("Live transcript: model ready (\(chunkSize.milliseconds) ms chunk)")
        } catch {
            manager = nil
            loadedChunkSize = nil
            Log.error("Live transcript unavailable: \(error.localizedDescription)")
            set(.unavailable(reason: "Live text unavailable"), notify: onState)
        }
    }

    /// Feeds 16 kHz mono samples. Errors are swallowed on purpose: a failing
    /// draft must not disturb a recording that is going fine.
    func append(_ samples: [Float]) async {
        guard let manager, case .ready = state else { return }
        await serialized {
            do {
                _ = try await manager.process(samples: samples)
                // Counted inside the chain, so `endDictation` sees every chunk
                // queued before it and none of the next dictation's.
                await self.noteFed(samples.count)
            } catch {
                Log.error("Live transcript: chunk dropped — \(error.localizedDescription)")
            }
        }
    }

    private func noteFed(_ sampleCount: Int) {
        fedChunks += 1
        fedSamples += sampleCount
    }

    private func logAndResetCounters() {
        Log.info(
            "Live transcript: fed \(fedChunks) chunks, "
                + String(format: "%.1f s of audio", Double(fedSamples) / 16000.0)
        )
        fedChunks = 0
        fedSamples = 0
    }

    /// The draft as it stands, normalised the same way the final text will be
    /// so that «дашборд» does not read differently in the HUD than in the
    /// pasted result.
    func draft() async -> String {
        guard let manager, case .ready = state else { return "" }
        let text = await manager.getPartialTranscript()
        guard !text.isEmpty, let vocabulary else { return text }
        return TermNormalizer.normalize(text, vocabulary: vocabulary)
    }

    /// Ends the dictation and drops its audio from the model's buffer. The
    /// resulting text is discarded — Parakeet produces what gets pasted.
    func endDictation() async {
        guard let manager else { return }
        await serialized {
            await self.logAndResetCounters()
            _ = try? await manager.finish()
            await manager.reset()
        }
    }

    private func set(_ newState: State, notify: @escaping @Sendable (State) -> Void) {
        state = newState
        notify(newState)
    }
}

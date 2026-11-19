import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌘⇧2 by default. Carbon-backed, so registering it costs no TCC
    /// permission — see the note on the KeyboardShortcuts package in project.yml.
    ///
    /// Was ⌥Space in the first cut; see `migrateLegacyShortcutIfNeeded`.
    static let toggleDictation = Self(
        "toggleDictation",
        default: .init(.two, modifiers: [.command, .shift])
    )
}

/// System-wide dictation: press the hotkey, speak, press again — the text lands
/// in whatever text field has focus.
///
/// Runs entirely beside the meeting pipeline. `RecordingViewModel` and
/// `AudioSessionManager` are untouched: those carry meeting bookkeeping (a
/// `Meeting` row, notifications, system-audio capture) that dictation has no
/// use for, and `AudioSessionManager` sleeps 500 ms on device changes.
///
/// A floating HUD shows state, duration and a live draft: `AppState` puts up
/// `DictationHUDController` while this controller is in `.recording` and takes
/// it down as recording ends. The draft comes from `DictationLiveTranscriber`
/// and is **not** what gets pasted — insertion stays with Parakeet, which is
/// measurably more accurate.
///
/// Still absent: **pause.** `MicrophoneCapture` exposes start/stop and nothing
/// between.
@MainActor
final class DictationController {

    enum State: Equatable {
        case idle
        /// The hotkey was pressed and the input is opening: the HUD is already
        /// up, `engine.start()` has not returned yet — 0.1 s on the built-in
        /// mic, 2.5–4.3 s on a Continuity iPhone.
        case starting
        case recording
        case processing
    }

    enum Notice: Equatable {
        /// Recognised, but not delivered into a text field. Usually recoverable
        /// — the text is on the clipboard — but not always: a failed clipboard
        /// write is itself one of the reasons, and telling the user to press ⌘V
        /// then would paste whatever they had there before.
        case insertionFailed(reason: String, textInClipboard: Bool)
        /// Nothing was recognised. The clipboard is left alone: replacing it
        /// with an empty string would destroy whatever the user had there.
        case nothingRecognized
        case recordingFailed
        case transcriptionFailed
        case cancelled
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Notifies the menu bar. Set by `AppState`.
    var onStateChange: ((State) -> Void)?
    /// Something the user should know about this dictation. Typed rather than a
    /// string because the cases need different channels: a failed insertion has
    /// to reach a user whose Vedivox window is closed, while a cancellation does not
    /// need to interrupt anyone.
    var onNotice: ((Notice) -> Void)?
    /// A finished (not cancelled) dictation: wall-clock bounds of the speech
    /// and the recognized text, possibly empty. `AppState` turns one made
    /// during a meeting recording into a mark on its mic track.
    var onFinished: ((_ start: Date, _ end: Date, _ text: String) -> Void)?
    private var recordingStartedAt: Date?
    /// `capture.start()` has not returned yet. Outlives `.starting` when Escape
    /// cancels it: a new dictation must not start on the same capture until
    /// the old one is back and stopped.
    private var isOpeningInput = false
    /// Raised when insertion failed for lack of Accessibility permission — the
    /// one failure the user can fix, so it gets a persistent surface rather than
    /// a passing notice.
    var onNeedsAccessibility: (() -> Void)?
    /// Draft transcript while speaking. Not what gets pasted — see
    /// `DictationLiveTranscriber`.
    var onLiveDraft: ((String) -> Void)?
    /// Whether a live draft is available at all, and why not when it is not.
    var onLiveState: ((DictationLiveTranscriber.State) -> Void)?
    /// Smoothed microphone level, 0…1, ~25 times a second while recording.
    var onLevel: ((Float) -> Void)?
    /// The Escape tap could not be created (no Accessibility permission), so
    /// Escape cancels the dictation **and** reaches the app underneath. Raised
    /// once per launch: the state is permanent until the user grants access, and
    /// repeating it on every dictation would be noise.
    var onEscapePassesThrough: (() -> Void)?
    private var escapePassThroughReported = false

    /// Replaced when a start hangs: the stuck one is never usable again.
    private var capture = MicrophoneCapture()
    /// Pauses or mutes background sound while recording. `AppState` tells it
    /// whether a meeting is being recorded.
    let backgroundAudio = BackgroundAudio()
    private let pipeline: TranscriptionPipeline
    private var currentClipURL: URL?

    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var escapeTap: CFMachPort?
    private var escapeTapSource: CFRunLoopSource?
    fileprivate static let escapeKeyCode: UInt16 = 53

    private let dictationRepo = DictationRepository()
    private let liveTranscriber = DictationLiveTranscriber()
    private var liveTask: Task<Void, Never>?
    private var draftPoll: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var sampleFeed: AsyncStream<[Float]>.Continuation?
    /// How often the draft is read. The model emits nothing between chunks
    /// anyway, so polling faster would just burn hops for identical strings.
    private static let draftPollInterval: Duration = .milliseconds(250)

    /// Parakeet rejects anything shorter than 0.3 s with `invalidAudioData`, so
    /// an accidental double-press must not reach it.
    private static let minimumClipDuration: TimeInterval = 0.4
    /// `leftoverClips` finds what a killed run left by this prefix.
    private nonisolated static let clipPrefix = "vox-dictation-"

    init(pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
    }

    // MARK: - Hotkey wiring

    func registerHotkey() {
        Self.migrateLegacyShortcutIfNeeded()
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            guard let self else { return }
            Task { await self.toggle() }
        }
        let bound = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        Log.info("Dictation: hotkey registered (\(bound?.description ?? "none"))")
    }

    /// The first cut shipped ⌥Space, and KeyboardShortcuts **persists** the
    /// resolved shortcut to UserDefaults. So changing `default:` alone reaches
    /// nobody who already launched that build — their stored ⌥Space keeps
    /// winning, and the change looks like it did nothing.
    ///
    /// Reset only when the stored value is still the old default: anyone who
    /// deliberately picked their own shortcut keeps it.
    private static func migrateLegacyShortcutIfNeeded() {
        let flag = "dictationShortcutMigratedFromOptionSpace"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        defer { UserDefaults.standard.set(true, forKey: flag) }

        let legacy = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        guard KeyboardShortcuts.getShortcut(for: .toggleDictation) == legacy else { return }

        KeyboardShortcuts.reset(.toggleDictation)
        Log.info("Dictation: migrated hotkey off the legacy ⌥Space default")
    }

    func unregisterHotkey() {
        KeyboardShortcuts.disable(.toggleDictation)
    }

    // MARK: - Flow

    func toggle() async {
        // Timestamped here and nowhere else: everything else in the log starts
        // at `capture.start()`, so the gap between the key press and the first
        // visible sign of life — which is the part a user actually feels — was
        // not measurable at all. Reported 2026-08-10 as «задержка, которую
        // визуально ничто не показывает».
        Log.info("Dictation: hotkey fired in state \(state)")
        switch state {
        case .idle where isOpeningInput: break // cancelled start still opening the input
        case .idle: await startRecording()
        case .recording: await finishRecording()
        case .starting, .processing: break // already busy — ignore
        }
    }

    /// Drops the recording without transcribing or inserting anything.
    ///
    /// Until this there was no way out of a dictation once started: the hotkey
    /// only ever ended it, and ending it inserted the text. Escape is the exit.
    func cancelRecording() async {
        switch state {
        case .recording:
            _ = await capture.stop()
            backgroundAudio.end()
        case .starting:
            // start() cannot be interrupted; startRecording() sees the state
            // change when it returns — at the latest at
            // `MicrophoneCapture.startLimit` — and lets the input go (design D2).
            break
        case .idle, .processing:
            return
        }
        Log.info("Dictation: cancelled")
        cleanup()
        onNotice?(.cancelled)
    }

    /// A quit or a logout mid-dictation: the audio goes to history
    /// awaiting recognition at the next launch, and nothing is inserted — the
    /// field it was meant for may be gone by then. A dictation already being
    /// recognized is left to finish; if the quit beats it, its clip stays in
    /// the temporary folder and the next launch adopts it.
    func saveForLater() async {
        switch state {
        case .recording:
            let stopped = await capture.stop()
            if let clipURL = stopped ?? currentClipURL {
                Log.info("Dictation: quitting mid-dictation — keeping the audio for the next launch")
                await keep(clipURL, createdAt: recordingStartedAt ?? Date())
            }
            cleanup()
        case .starting:
            await cancelRecording()
        case .idle, .processing:
            return
        }
    }

    /// Clips a previous run left in the temporary folder — it was killed, or
    /// quit before saving them. Called before the hotkey is
    /// registered: a clip found later could be the one being recorded.
    /// Leftover 16 kHz conversions go at once; a recognition redoes them.
    nonisolated static func leftoverClips(in directory: URL = FileManager.default.temporaryDirectory) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(clipPrefix), name.hasSuffix(".wav") else { return nil }
            let stem = name.dropFirst(clipPrefix.count).dropLast(".wav".count)
            let url = directory.appendingPathComponent(name)
            if UUID(uuidString: String(stem)) != nil { return url }
            if stem.hasSuffix(".16k"), UUID(uuidString: String(stem.dropLast(".16k".count))) != nil {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }
    }

    /// Puts leftover clips into history awaiting recognition. A killed writer
    /// never finalized the WAV header, so it is repaired first.
    func adopt(_ clips: [URL]) async {
        for clip in clips {
            do {
                try AudioConverter.repairWAVHeaderIfNeeded(clip)
            } catch {
                Log.error("Dictation: leftover \(clip.lastPathComponent) is unreadable — \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: clip)
                continue
            }
            let created = (try? clip.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            Log.info("Dictation: adopting leftover \(clip.lastPathComponent)")
            await keep(clip, createdAt: created)
        }
    }

    /// History awaiting recognition, or nothing for a clip too short to recognize.
    private func keep(_ clipURL: URL, createdAt: Date) async {
        let seconds = duration(of: clipURL)
        guard seconds >= Self.minimumClipDuration else {
            try? FileManager.default.removeItem(at: clipURL)
            return
        }
        await record(text: "", duration: seconds, clipURL: clipURL, outcome: nil, createdAt: createdAt, awaitingTranscription: true)
    }

    // MARK: - Live draft

    /// Loads the live-draft model ahead of the first dictation.
    ///
    /// Measured: loading it into memory takes ~17.5 s even when the files are
    /// already on disk. Doing that at the first hotkey press means a short
    /// dictation is over before a single word appears — the feature would look
    /// broken while working correctly. So it happens at launch, in the
    /// background, while nobody is waiting.
    func prewarmLiveDraft() {
        let chunkSize = DictationChunkSize.stored()
        let transcriber = liveTranscriber
        Task.detached(priority: .background) {
            await transcriber.prepare(chunkSize: chunkSize) { _ in }
        }
    }

    /// Wires the draft transcript for this dictation and starts loading its
    /// model if needed.
    ///
    /// Nothing here is awaited before recording starts: the model may be a
    /// 640 MB download away, and the recording must not wait on it. Until it is
    /// ready the samples are simply dropped and the dictation behaves exactly as
    /// it did before live text existed.
    private func startLiveDraft() async {
        let chunkSize = DictationChunkSize.stored()
        let transcriber = liveTranscriber

        // Audio must reach the model in the order it was captured. Spawning a
        // Task per buffer does not do that — task start order is not the order
        // they were created in — and out-of-order chunks made the model re-hear
        // the same speech: the draft came out as «выглядит страновато И, кста
        // выглядит страновато И, кстати». A stream keeps the sequence.
        // Unbounded on purpose: .bufferingNewest drops the *oldest* buffers
        // under pressure, which for speech means silently losing a slice of
        // what was said. A dictation is at most minutes long, so the queue
        // cannot grow unreasonably — and falling behind is preferable to
        // transcribing audio with holes in it.
        let (samples, continuation) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .unbounded
        )
        sampleFeed = continuation
        feedTask = Task {
            for await chunk in samples {
                await transcriber.append(chunk)
            }
        }

        await capture.setLiveSink(LiveAudioSink(
            onSamples: { chunk in continuation.yield(chunk) },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.onLevel?(level) }
            }
        ))

        liveTask = Task { [weak self] in
            await transcriber.prepare(chunkSize: chunkSize) { state in
                Task { @MainActor in self?.onLiveState?(state) }
            }
        }

        draftPoll = Task { [weak self] in
            while !Task.isCancelled {
                let draft = await transcriber.draft()
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.onLiveDraft?(draft) }
                try? await Task.sleep(for: Self.draftPollInterval)
            }
        }
    }

    private func stopLiveDraft() {
        draftPoll?.cancel()
        draftPoll = nil
        liveTask?.cancel()
        liveTask = nil
        // Finish rather than cancel: whatever audio is already queued should
        // still reach the model, and the loop ends on its own once drained.
        sampleFeed?.finish()
        sampleFeed = nil
        feedTask = nil
        let transcriber = liveTranscriber
        Task {
            await transcriber.endDictation()
        }
        Task { [capture] in await capture.setLiveSink(nil) }
        onLiveDraft?("")
        onLevel?(0)
    }

    /// Watches for Escape while recording, and swallows it.
    ///
    /// An event tap, not a monitor: a monitor can only observe, and the user
    /// explicitly does not want Escape reaching the app underneath — pressing it
    /// to abandon a dictation should not also close their dialog or leave insert
    /// mode. The tap is installed only while recording, so Escape is stolen for
    /// seconds at a time and never while idle.
    ///
    /// Falls back to observing monitors when the tap cannot be created (no
    /// Accessibility permission): cancelling still works, Escape just also
    /// reaches the app. Losing the cancel entirely would be worse.
    private func startEscapeWatch() {
        stopEscapeWatch()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<DictationController>.fromOpaque(refcon).takeUnretainedValue()

            // The system disables a tap that takes too long; it has to be
            // switched back on or Escape silently stops working mid-dictation.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { controller.reenableEventTap() }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(DictationController.escapeKeyCode)
            else { return Unmanaged.passUnretained(event) }

            MainActor.assumeIsolated {
                Task { await controller.cancelRecording() }
            }
            // nil consumes the event: this is what keeps Escape from reaching
            // the app the user is dictating into.
            return nil
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            escapeTap = tap
            escapeTapSource = source
            return
        }

        Log.error("Dictation: could not create the Escape event tap — falling back to observing monitors")
        if !escapePassThroughReported {
            escapePassThroughReported = true
            onEscapePassesThrough?()
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in await self?.cancelRecording() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            Task { @MainActor in await self?.cancelRecording() }
            return nil
        }
    }

    private func reenableEventTap() {
        guard let escapeTap else { return }
        CGEvent.tapEnable(tap: escapeTap, enable: true)
        Log.info("Dictation: Escape tap re-enabled after being disabled by the system")
    }

    /// Disabling a tap is not enough: CoreGraphics keeps its own references to
    /// the port, so WindowServer holds the registration until the process exits,
    /// and every input event in the system walks the dead entries. One leaked
    /// per dictation, 13 dead entries had piled up in one running Vedivox
    /// (Caldis/Mos#999).
    nonisolated static func removeEventTap(_ tap: CFMachPort, source: CFRunLoopSource?) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func stopEscapeWatch() {
        if let escapeTap {
            Self.removeEventTap(escapeTap, source: escapeTapSource)
        }
        escapeTap = nil
        escapeTapSource = nil

        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        globalEscapeMonitor = nil
        localEscapeMonitor = nil
    }

    private func startRecording() async {
        // Ask before recording, not after: discovering the text cannot be pasted
        // at the end of a 49-second dictation is the worst possible moment.
        //
        // And when the prompt does go up, this dictation is over. The request
        // call returns immediately while the system dialog appears
        // asynchronously, so recording through it means the user talks into the
        // microphone while the screen is busy asking them a question. No notice
        // either — the dialog they are looking at is the explanation.
        guard !TextInserter.requestEventAccessIfNeeded() else {
            Log.info("Dictation: permission prompt shown, not recording this time")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.clipPrefix)\(UUID().uuidString).wav")
        backgroundAudio.begin()
        // The HUD goes up here, before the input opens: a hotkey with no
        // visible answer for seconds gets pressed twice. Escape is watched
        // from here too, so the panel that is already showing can be dismissed.
        state = .starting
        startEscapeWatch()
        isOpeningInput = true
        defer { isOpeningInput = false }
        do {
            await startLiveDraft()
            // The input is picked here; mid-dictation it is only left when it is lost.
            try await MicrophoneCapture.start(capture, outputURL: url, movesUp: false)
        } catch {
            if case MicrophoneCapture.MicCaptureError.startTimedOut = error { capture = MicrophoneCapture() }
            // After Escape the failure is nobody's news.
            guard state == .starting else {
                stopLiveDraft()
                return
            }
            Log.error("Dictation: failed to start capture — \(error.localizedDescription)")
            cleanup()
            onNotice?(.recordingFailed)
            return
        }
        guard state == .starting else {
            // Escape came while the input was opening; its cleanup() may have
            // run before startLiveDraft() wired the draft.
            stopLiveDraft()
            _ = await capture.stop()
            try? FileManager.default.removeItem(at: url)
            return
        }
        currentClipURL = url
        state = .recording
        recordingStartedAt = Date()
        Log.info("Dictation: recording started")
    }

    private func finishRecording() async {
        state = .processing
        let speech = recordingStartedAt.map { ($0, Date()) }
        recordingStartedAt = nil
        // The draft has done its job the moment recording stops — the HUD is
        // already going away, and what gets pasted comes from Parakeet.
        stopLiveDraft()
        let stopped = await capture.stop()
        // Sound comes back the moment speech ends, not after transcription
        // and paste, which add 1–3 s of silence.
        backgroundAudio.end()
        guard let clipURL = stopped ?? currentClipURL else {
            Log.error("Dictation: capture produced no file")
            cleanup()
            return
        }

        defer { cleanup() }

        guard duration(of: clipURL) >= Self.minimumClipDuration else {
            Log.info("Dictation: clip too short, ignoring")
            return
        }

        do {
            let converted = clipURL.deletingPathExtension()
                .appendingPathExtension("16k.wav")
            try await AudioConverter.convertTo16kHzMonoWAV(input: clipURL, output: converted)
            defer { try? FileManager.default.removeItem(at: converted) }

            let text = try await pipeline.transcribeDictation(converted)
            if let speech { onFinished?(speech.0, speech.1, text) }
            guard !text.isEmpty else {
                Log.info("Dictation: empty transcription — keeping the clip in history")
                onNotice?(.nothingRecognized)
                await record(text: "", duration: duration(of: clipURL), clipURL: clipURL, outcome: nil)
                return
            }

            let outcome = await TextInserter.insert(text)
            await record(
                text: text,
                duration: duration(of: clipURL),
                clipURL: clipURL,
                outcome: outcome
            )

            switch outcome {
            case .inserted(let app):
                Log.info("Dictation: inserted \(text.count) characters into \(app ?? "unknown app")")
            case .copiedToClipboard(let reason):
                onNotice?(.insertionFailed(
                    reason: reason.message,
                    textInClipboard: reason.textIsOnClipboard
                ))
                if reason == .missingAccessibilityPermission {
                    onNeedsAccessibility?()
                }
            }
        } catch {
            Log.error("Dictation: \(error.localizedDescription) — keeping the clip in history")
            onNotice?(.transcriptionFailed)
            await record(text: "", duration: duration(of: clipURL), clipURL: clipURL, outcome: nil)
        }
    }

    // MARK: - History

    /// Writes the dictation to history and keeps its audio.
    ///
    /// Written whether or not insertion succeeded: until now the text existed in
    /// exactly one place — the field it landed in — so a paste into the wrong
    /// window meant the text was simply gone.
    ///
    /// Also written when there is no text at all (`outcome == nil`): «nothing
    /// recognized» used to delete the clip, which made it indistinguishable
    /// from recorded silence and left nothing to re-recognize from history.
    ///
    /// Failures here are swallowed. History is a convenience; losing it must not
    /// turn a working dictation into an error the user has to deal with.
    private func record(
        text: String,
        duration: TimeInterval,
        clipURL: URL,
        outcome: TextInserter.Outcome?,
        createdAt: Date = Date(),
        awaitingTranscription: Bool = false
    ) async {
        let id = UUID().uuidString
        let inserted: Bool
        let targetApp: String?
        switch outcome {
        case .inserted(let app)?:
            inserted = true
            targetApp = app
        default:
            inserted = false
            targetApp = nil
        }

        do {
            // Moves the clip out of the temp directory, so `cleanup()` finds
            // nothing left to delete.
            let fileName = try dictationRepo.storeAudio(from: clipURL, id: id)
            try await dictationRepo.save(
                Dictation(
                    id: id,
                    createdAt: createdAt,
                    text: text,
                    durationSeconds: duration,
                    targetApp: targetApp,
                    inserted: inserted,
                    audioFileName: fileName,
                    awaitingTranscription: awaitingTranscription
                )
            )
            try await dictationRepo.enforceRetention()
        } catch {
            Log.error("Dictation history: could not record — \(error.localizedDescription)")
        }
    }

    private func cleanup() {
        backgroundAudio.end()
        stopEscapeWatch()
        stopLiveDraft()
        if let url = currentClipURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentClipURL = nil
        recordingStartedAt = nil
        state = .idle
    }

    private func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

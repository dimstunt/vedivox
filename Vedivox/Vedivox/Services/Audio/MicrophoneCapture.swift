import AVFoundation
import Foundation

/// Records microphone audio in the device's native format for high-quality playback.
/// Conversion to 16kHz mono for transcription is done later by TranscriptionPipeline.
///
/// The input is opened straight on the HAL (`HALInput`): an IOProc
/// on the one device, so the system default input is neither opened nor
/// followed, unless "System default" is what the track is on. "Engine" below
/// is that open input; the word is older than the HAL input.
///
/// Resilience (one meeting: an input can stay
/// open and deliver nothing. So when the device's format changes the input
/// is reopened from scratch, a watchdog reopens it again if frames stop
/// flowing, and time lost between death and recovery is filled with silence
/// so the mic track stays aligned with the system-audio track. The silence
/// goes in at the first frame after a (re)start, measured from the end of the
/// last delivered buffer, so the new input's start-up latency is part of the
/// gap and not a drift.
///
/// Which input: the order of inputs is snapshotted at
/// `start` and `MicSwitchPolicy` keeps the track on the first usable one —
/// the current input lost: the next one at once; a better one connected: that
/// one after a hold. Device events come from HAL listeners, so a lost input
/// is left without waiting for the watchdog. Every move is one "Mic switch"
/// line in the log: from, to, why, and how long the track had no frames.
actor MicrophoneCapture {
    private var input: HALInput?
    private var outputFile: AVAudioFile?
    /// Format the output file was created with; later engine incarnations
    /// convert into it if the hardware format changed.
    private var originalFormat: AVAudioFormat?
    private var isRecording = false
    /// Holds the order of inputs, snapshotted at `start` (UIDs, `nil`: the
    /// system default). A UID is re-resolved to a device ID on every engine
    /// build, because IDs change when a device reconnects.
    private var policy = MicSwitchPolicy(order: [nil], movesUp: true)
    /// The input the engine records from; `nil` is the system default.
    private var currentUID: String?
    /// The audio devices as last seen: refreshed on device events and rebuilds.
    private var devices = AudioDeviceSnapshot()
    /// Stalls in a row with not one frame since the engine (re)started. The
    /// first is a slow open and gets a plain restart, as it always did; at
    /// the second the input is marked failed and the track moves on.
    private var silentStarts = 0
    private var deviceListenersInstalled = false
    private var stallProbe: Task<Void, Never>?

    private var totalFramesWritten: Int64 = 0
    private var callbackCount: Int = 0
    private var consecutiveErrors: Int = 0
    private var tapState: TapState?
    /// Optional second consumer of the mic stream (live dictation transcript).
    /// Set before `start`; the file recording is unaffected either way.
    private var liveSink: LiveAudioSink?
    private var watchdogTask: Task<Void, Never>?
    private var captureStartHostTime: UInt64 = 0
    private var lastRebuildHostTime: UInt64 = 0
    private var rebuildInProgress = false
    private var rebuildCount = 0
    private var debouncer = ConfigChangeDebouncer(quietWindow: MicrophoneCapture.configChangeQuietWindow)

    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(fromHostTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000_000
    }

    static func hostTicks(fromSeconds seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebaseInfo.denom) / Double(timebaseInfo.numer))
    }

    /// How often the watchdog checks the age of the last real frame.
    static let watchdogInterval: Duration = .milliseconds(500)
    /// Watchdog backoff cap while the engine keeps failing to produce frames.
    static let watchdogMaxInterval: Duration = .seconds(30)
    /// The tap is dead when no real frame arrived for this long…
    static let stallFrameThreshold: TimeInterval = 1.0
    /// …unless the engine (re)started less than this long ago, and rebuilding
    /// on a slow start is a fresh IO context for nothing. Counted from the
    /// return of the input's start: with the engine the first frame came
    /// within 0.13 s of that (built-in 76–128 ms, Continuity iPhone ~105 ms,
    /// measured 2026-09-03/04); the seconds the open itself takes are before
    /// the anchor. Not re-measured on the HAL input.
    static let stallStartThreshold: TimeInterval = 2.0
    /// Right after a device event the tap is dead sooner: an input that goes
    /// silent when Bluetooth headphones connect posts nothing at all
    /// (the 1.0 s watchdog saw it after 1.2 s). Calibration knob,
    /// set for the engine's 0.1–0.5 s buffers; the IOProc's are ~10 ms.
    static let stallAfterDeviceEvent: TimeInterval = 0.7
    /// Gaps shorter than this are left as-is (normal restart latency).
    static let minGapToFillSeconds = 0.25
    /// Format notifications arrive in bursts during a Bluetooth profile flip;
    /// the input is reopened once the burst has been quiet for this long.
    /// Calibration knob from the engine's configuration changes (one per
    /// switch on the built-in mic); not re-measured on the HAL input.
    static let configChangeQuietWindow: TimeInterval = 0.1

    /// Attaches a live consumer of the mic stream, or clears it.
    ///
    /// Kept separate from `start` so the recording path stays identical whether
    /// or not anyone is listening — live transcript is an addition, and a
    /// failure in it must never cost the recording.
    func setLiveSink(_ sink: LiveAudioSink?) {
        liveSink = sink
    }

    /// Start recording to a WAV file from the microphone Settings point at
    /// (`MicPriority.captureOrder`: the single picker, or the first connected
    /// entry of the priority list), or from the system default. Records in
    /// the mic's native format (typically 48kHz). The system default input device is never changed.
    /// `startHostTime` is the recording's anchor: a meeting passes the one it
    /// shares with the system track, dictation records from now.
    /// `movesUp`: whether a better input connected mid-recording is taken —
    /// a meeting does, dictation only leaves an input that is lost.
    func start(outputURL: URL, startHostTime: UInt64 = mach_absolute_time(), movesUp: Bool = true) throws {
        guard !isRecording else { return }

        devices = Self.readDevices()
        policy = MicSwitchPolicy(order: MicPriority.captureOrder(connected: devices.inputs), movesUp: movesUp)
        currentUID = nil
        silentStarts = 0

        totalFramesWritten = 0
        callbackCount = 0
        consecutiveErrors = 0
        rebuildCount = 0
        outputFile = nil
        originalFormat = nil

        let state = TapState()
        self.tapState = state
        captureStartHostTime = startHostTime
        lastRebuildHostTime = 0
        state.setCaptureStart(captureStartHostTime)
        state.expectFirstFrame(after: "start")
        isRecording = true
        Log.info("Mic capture start anchor: host ticks \(startHostTime)")

        // Before the input opens: that takes seconds on some devices, and what
        // is plugged or pulled meanwhile must not be missed.
        setDeviceListeners(installed: true)
        do {
            try buildAndStartEngine(outputURL: outputURL)
        } catch {
            setDeviceListeners(installed: false)
            isRecording = false
            tapState = nil
            throw error
        }

        startWatchdog()
        Log.info("Recording started to \(outputURL.lastPathComponent)")
    }

    /// How long the input may take to open: 2.5–4.3 s on a Continuity
    /// iPhone, 4+ s on AirPods in headset mode (measured 2026-09/10).
    static let startLimit: Duration = .seconds(15)

    /// `start` that gives up at `limit` with `MicCaptureError.startTimedOut`
    /// (on BlackHole the engine hung for good in
    /// `AVAudioNode.inputFormat`, and the recording, the CLI and the next
    /// dictation all waited with it). A stuck call cannot be interrupted, so
    /// that capture is given up: its `stop` is queued behind the start and
    /// lets the input go if it ever opens. The caller takes a fresh capture.
    /// shortcut: the stuck start keeps a shared-pool thread for good; give the
    /// actor its own DispatchSerialQueue executor once that is checked live.
    static func start(
        _ capture: MicrophoneCapture, outputURL: URL, startHostTime: UInt64 = mach_absolute_time(),
        movesUp: Bool = true, limit: Duration = startLimit
    ) async throws {
        do {
            try await Deadline.run(limit: limit) {
                try await capture.start(outputURL: outputURL, startHostTime: startHostTime, movesUp: movesUp)
            }
        } catch is Deadline.TimedOut {
            Log.error("Mic: the input did not open in \(limit) — giving up on this capture")
            Task { _ = await capture.stop() }
            throw MicCaptureError.startTimedOut
        }
    }

    /// Stop recording and finalize the WAV file.
    func stop() -> URL? {
        guard isRecording else { return nil }

        watchdogTask?.cancel()
        watchdogTask = nil
        stallProbe?.cancel()
        stallProbe = nil
        setDeviceListeners(installed: false)
        teardownEngine()

        // No more frames from here on — pad up to now, so a tap that died
        // before the watchdog noticed does not leave the track short.
        if let state = tapState, let outputFile, let originalFormat {
            let tail = Self.tailFrames(
                now: Self.seconds(fromHostTicks: mach_absolute_time()),
                lastBufferEnd: Self.seconds(fromHostTicks: state.lastBufferEndHostTime),
                captureStart: Self.seconds(fromHostTicks: state.captureStartHostTime),
                sampleRate: originalFormat.sampleRate
            )
            if tail > 0 {
                let written = Self.writeSilence(frames: Int64(tail), to: outputFile, format: originalFormat)
                state.addSilenceFrames(written)
                Log.info("Mic tail: padded \(written) frames (\(String(format: "%.2f", Double(written) / originalFormat.sampleRate)) sec) at stop")
            }
        }

        // Sync counters from the tap callback thread before reporting
        if let state = tapState {
            syncFromTapState(state)
        }
        tapState = nil

        let url = outputFile?.url
        let sampleRate = originalFormat?.sampleRate ?? 48000

        Log.info("Total frames written: \(totalFramesWritten) (\(String(format: "%.2f", Double(totalFramesWritten) / sampleRate)) sec at \(Int(sampleRate)) Hz), callbacks: \(callbackCount), rebuilds: \(rebuildCount)")

        outputFile = nil
        originalFormat = nil
        isRecording = false

        // An empty file is not a recording: hand back nil so the caller can
        // flag the meeting instead of transcribing silence.
        if totalFramesWritten == 0 {
            Log.error("Zero frames written — mic recording is empty, not handing \(url?.lastPathComponent ?? "?") to the pipeline")
            return nil
        }

        return url
    }

    /// Snapshot of recording health for external monitoring.
    var diagnostics: (framesWritten: Int64, callbacks: Int, errors: Int) {
        (totalFramesWritten, callbackCount, consecutiveErrors)
    }

    var recording: Bool {
        isRecording
    }

    /// Update actor-isolated counters from TapState (called periodically or at stop).
    func syncFromTapState(_ state: TapState) {
        totalFramesWritten = state.framesWritten
        callbackCount = state.callbacks
        consecutiveErrors = state.errors
    }

    // MARK: - Engine lifecycle

    /// Open the first input of the order that will start, and feed its
    /// buffers to the tap.
    /// On the first call (outputURL != nil) the output file is created in the
    /// hardware format; later incarnations convert into that format if the
    /// hardware changed.
    ///
    /// An input that is listed but will not start IO (an Elgato Wave:3 after a
    /// USB re-enumeration answered every start with 'what' until replugged,
    ///) must not cost the recording: the inputs `MicSwitchPolicy`
    /// lists are tried in turn — the usable ones first, the ones that failed
    /// before only when nothing else starts.
    private func buildAndStartEngine(outputURL: URL? = nil) throws {
        let candidates = policy.buildOrder(
            current: currentUID, restarting: outputURL == nil, connected: connectedIDs(),
            now: Self.seconds(fromHostTicks: mach_absolute_time())
        )
        var lastError: (any Error)?
        for uid in candidates {
            do {
                try startInput(uid, outputURL: outputURL)
                if uid != currentUID { silentStarts = 0 }
                currentUID = uid
                if let wanted = policy.order.first, wanted != uid {
                    Log.warning("Mic: \(inputName(wanted)) unavailable — recording from \(inputName(uid))")
                }
                return
            } catch {
                lastError = error
                Log.error("Mic engine on \(inputName(uid)) failed to start: \(error.localizedDescription)")
                policy.markFailed(uid)
            }
        }
        // The system default is always a candidate, so there was an error.
        throw lastError ?? MicCaptureError.inputUnavailable("no input to try")
    }

    // MARK: - Inputs

    /// The connected inputs for the policy, UID → device ID. The current one
    /// counts while its UID still resolves: lost means gone from the system,
    /// not missing from one look at the list — leaving a working input costs
    /// a hole. One that is there but silent is the watchdog's.
    private func connectedIDs() -> [String: AudioDeviceID] {
        var ids = devices.inputIDs
        if let currentUID, ids[currentUID] == nil, let id = AudioObjectID.deviceIDForUID(currentUID) {
            ids[currentUID] = id
        }
        return ids
    }

    /// For the log: the device's name, and for the system default — which device that is now.
    private func inputName(_ uid: String?) -> String {
        guard let uid else { return "System default (\(devices.defaultInput ?? "none"))" }
        return devices.inputs.first { $0.uid == uid }?.name ?? uid
    }

    private static func readDevices() -> AudioDeviceSnapshot {
        let inputs = MicPriority.connectedInputs()
        let ids = inputs.compactMap { input in AudioObjectID.deviceIDForUID(input.uid).map { (input.uid, $0) } }
        return AudioDeviceSnapshot(
            inputs: inputs,
            inputIDs: Dictionary(ids) { first, _ in first },
            defaultInput: AudioObjectID.readDefaultInputDevice()?.readDeviceName(),
            defaultOutput: AudioObjectID.readDefaultOutputDevice()?.readDeviceName()
        )
    }

    /// Takes a fresh look at the devices and says in the log what changed,
    /// by name. Returns whether anything did.
    @discardableResult
    private func refreshDevices() -> Bool {
        let fresh = Self.readDevices()
        guard fresh != devices else { return false }
        if let changes = fresh.changes(from: devices) { Log.info("Audio devices changed: \(changes)") }
        devices = fresh
        return true
    }

    /// The order with priority off (`MicPriority.captureOrder`): the selected
    /// input, then the built-in mic, then the system default. The
    /// built-in mic goes before the default: when a USB mic drops, macOS
    /// often hands the default to AirPods, which take 4+ s to open in headset
    /// mode and degrade the user's playback (measured 2026-10-07: 7.3 s gap).
    /// `nil` is the system default.
    static func inputCandidates(selected: String?) -> [String?] {
        var candidates: [String?] = [selected]
        if selected != builtInMicUID { candidates.append(builtInMicUID) }
        if selected != nil { candidates.append(nil) }
        return candidates
    }

    static let builtInMicUID = "BuiltInMicrophoneDevice"

    /// Opens the input `uid` names (`nil`: whatever the system default input
    /// is now) and starts it. Throws when the device is not there, is not a
    /// microphone, or will not start; the caller moves on to the next input
    /// of the order, so the recording does not fail because of the picker.
    private func startInput(_ uid: String?, outputURL: URL?) throws {
        guard let state = tapState else { return }
        let deviceID: AudioDeviceID
        if let uid {
            guard let found = AudioObjectID.deviceIDForUID(uid) else {
                throw MicCaptureError.inputUnavailable("no device with UID \(uid)")
            }
            // An aggregate is never a microphone a person meant to pick: the
            // picker hides them, but a UID saved earlier still resolves.
            guard !found.isAggregateDevice() else {
                throw MicCaptureError.inputUnavailable("UID \(uid) is an aggregate device")
            }
            deviceID = found
        } else {
            guard let found = AudioObjectID.readDefaultInputDevice() else {
                throw MicCaptureError.inputUnavailable("the system has no default input")
            }
            deviceID = found
        }
        let input = try HALInput(deviceID: deviceID)
        let inputFormat = input.format
        // Said before the start, which is where an input hangs.
        Log.info("Mic input bound to UID=\(uid ?? "system default") (deviceID=\(deviceID)), \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch")

        if outputFile == nil, let outputURL {
            Log.info("Input format: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: !inputFormat.isInterleaved,
            ]
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: inputFormat.isInterleaved
            )
            originalFormat = inputFormat
        }

        guard let outputFile, let originalFormat else { return }

        let tap = try Self.tapBlock(
            from: inputFormat, to: originalFormat, outputFile: outputFile, state: state, liveSink: liveSink
        )
        // Named before the first frame can arrive: the tap writes the
        // "Mic switch" line on it.
        state.willStart(input: inputName(uid))
        try input.start(fillingBreaksUnder: Self.minGapToFillSeconds, onBuffer: tap)
        // Watchdog anchor: the start itself can block while the input opens —
        // 2.5–4.3 s on a Continuity iPhone (measured 2026-09-03, on the
        // engine) — so the start threshold counts from here, not from the hotkey.
        lastRebuildHostTime = mach_absolute_time()
        self.input = input
        setFormatListeners(on: deviceID, installed: true)
        // A rate that moved while the input was opening — a Bluetooth codec
        // settling — was posted before anyone listened.
        if input.formatChanged { Task { await self.handleConfigChange() } }
    }

    private func teardownEngine() {
        guard let input else { return }
        setFormatListeners(on: input.deviceID, installed: false)
        input.stop()
        self.input = nil
        let skipped = input.skipped
        if skipped.frames > 0 {
            Log.warning("Mic input: the device skipped \(skipped.frames) frames in \(skipped.times) breaks (IO overload) — filled with silence")
        }
    }

    /// The track follows the system default input, and that is another
    /// device now. A default that cannot be read says nothing.
    private var defaultInputMoved: Bool {
        guard currentUID == nil, let input, let now = AudioObjectID.readDefaultInputDevice() else { return false }
        return now != input.deviceID
    }

    /// The open input is no longer what the track should be on as it is.
    private var inputIsStale: Bool {
        guard let input else { return true }
        return input.formatChanged || defaultInputMoved
    }

    /// The device's format changed, or the system default input moved under a
    /// track that follows it.
    private func handleConfigChange() async {
        guard isRecording else { return }
        // Notifications also come when nothing of ours changed.
        if !inputIsStale {
            Log.debug("Audio configuration change, the input is as it was — ignoring")
            return
        }
        // Stop now: what the device delivers no longer fits the tap, and at
        // a new rate it would go into the track at the wrong speed.
        teardownEngine()
        // Every notification extends the quiet window; the wait already in
        // progress (if any) sees the extension and rebuilds once after it.
        debouncer.note(at: Self.seconds(fromHostTicks: mach_absolute_time()))
        guard !rebuildInProgress else { return }
        rebuildInProgress = true
        defer { rebuildInProgress = false }

        Log.info("Audio configuration changed — rebuilding mic engine")
        while let wait = debouncer.waitUntilQuiet(at: Self.seconds(fromHostTicks: mach_absolute_time())), wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
        guard debouncer.shouldRebuild(at: Self.seconds(fromHostTicks: mach_absolute_time())) else { return }
        // The watchdog or a device event may have rebuilt it while we waited.
        if !inputIsStale {
            Log.debug("Engine already rebuilt while settling — skipping")
            return
        }
        rebuildEngine(reason: "config change")
    }

    /// Full teardown + fresh input.
    private func rebuildEngine(reason: String) {
        guard isRecording else { return }
        rebuildCount += 1
        Log.info("Rebuilding mic engine (attempt #\(rebuildCount), reason: \(reason))")
        teardownEngine()
        lastRebuildHostTime = mach_absolute_time()
        // The gap is filled by the tap on the first frame of the new engine,
        // so its start-up latency is inside the gap, not lost.
        tapState?.expectFirstFrame(after: "rebuild", why: reason)
        refreshDevices()
        do {
            try buildAndStartEngine()
            Log.info("Mic engine rebuilt and started")
        } catch {
            Log.error("Mic engine rebuild FAILED: \(error.localizedDescription) — watchdog will retry")
        }
    }

    /// Silence owed at stop, in file frames: from the end of the last delivered
    /// buffer — or from capture start, when no buffer ever came — up to `now`.
    /// Gaps shorter than `minGap` are left as-is. Seconds in, so the
    /// arithmetic is testable without mach ticks.
    static func tailFrames(
        now: Double, lastBufferEnd: Double, captureStart: Double, sampleRate: Double,
        minGap: Double = minGapToFillSeconds
    ) -> Int {
        let reference = max(lastBufferEnd, captureStart)
        guard reference > 0, now > reference else { return 0 }
        let gap = now - reference
        guard gap >= minGap else { return 0 }
        return Int(gap * sampleRate)
    }

    /// Writes `frames` of silence in the file's format, 4096 at a time.
    /// Returns what actually went in.
    @discardableResult
    static func writeSilence(frames: Int64, to outputFile: AVAudioFile, format: AVAudioFormat) -> Int64 {
        var written: Int64 = 0
        while written < frames {
            let count = AVAudioFrameCount(min(frames - written, 4096))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            buffer.frameLength = count
            do {
                try outputFile.write(from: buffer)
                written += Int64(count)
            } catch {
                Log.error("Silence fill write error: \(error.localizedDescription)")
                break
            }
        }
        return written
    }

    /// The tap calls this before writing a buffer: on the first frame after a
    /// (re)start it pays the silence owed since the last delivered buffer.
    private static func writeOwedSilence(state: TapState, at hostTime: UInt64, outputFile: AVAudioFile, format: AVAudioFormat) {
        guard let owed = state.silenceOwed(beforeBufferAt: hostTime, sampleRate: format.sampleRate) else { return }
        if owed.reason == TapState.hole {
            // While writes fail (a full disk) every quarter of a second looks
            // like a hole: there is nothing to fill it with, and saying so
            // each time would bury the log.
            guard state.errors == 0 else { return }
        } else {
            // Always say how long the input took to open — the stall thresholds
            // are calibrated against these numbers (AirPods HFP, Continuity).
            Log.info("Mic first frame after \(owed.reason): \(Int(owed.gapSeconds * 1000)) ms")
        }
        var written: Int64 = 0
        if owed.frames > 0 {
            written = writeSilence(frames: Int64(owed.frames), to: outputFile, format: format)
            state.addSilenceFrames(written)
            Log.info("Mic gap: filled \(written) frames (\(String(format: "%.2f", Double(written) / format.sampleRate)) sec) with silence at first frame after \(owed.reason)")
        }
        // The one line that tells a switch whole: from, to, why,
        // how long the track had no frames, how much of that is now silence.
        if let switched = owed.switched {
            Log.info("Mic switch: \(switched), gap \(String(format: "%.2f", owed.gapSeconds)) s, \(String(format: "%.2f", Double(written) / format.sampleRate)) s filled with silence")
        }
    }

    // MARK: - Device events

    private static let deviceEventSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    /// A C callback, not a block: a block listener cannot be removed from
    /// Swift (see `SystemAudioCapture.defaultOutputChanged`). Runs on the HAL
    /// notification thread and only hops onto the actor. The pointer is
    /// unretained: the instance is app-long (`AudioSessionManager`,
    /// `DictationController`), and `stop` removes the listeners.
    private static let deviceEvent: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let capture = Unmanaged<MicrophoneCapture>.fromOpaque(clientData).takeUnretainedValue()
        Task { await capture.handleDeviceEvent() }
        return noErr
    }

    private func setDeviceListeners(installed: Bool) {
        guard installed != deviceListenersInstalled else { return }
        deviceListenersInstalled = installed
        let system = AudioObjectID(kAudioObjectSystemObject)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for selector in Self.deviceEventSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            let err = installed
                ? AudioObjectAddPropertyListener(system, &address, Self.deviceEvent, me)
                : AudioObjectRemovePropertyListener(system, &address, Self.deviceEvent, me)
            if err != noErr {
                Log.error("Mic device listener '\(AudioObjectID.fourCC(selector))' \(installed ? "install" : "removal") failed: \(err)")
            }
        }
    }

    /// Format events of the open device go the way the engine's configuration
    /// change went. A C callback for the same reason as `deviceEvent`.
    private static let formatEvent: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let capture = Unmanaged<MicrophoneCapture>.fromOpaque(clientData).takeUnretainedValue()
        Task { await capture.handleConfigChange() }
        return noErr
    }

    /// Rate and channel layout of the open device: when either changes, what
    /// the IOProc delivers no longer fits the tap built for it.
    private func setFormatListeners(on deviceID: AudioDeviceID, installed: Bool) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let addresses = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for (selector, scope) in addresses {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            let err = installed
                ? AudioObjectAddPropertyListener(deviceID, &address, Self.formatEvent, me)
                : AudioObjectRemovePropertyListener(deviceID, &address, Self.formatEvent, me)
            // Removal from a device that is gone fails, and that is fine.
            if err != noErr, installed {
                Log.error("Mic format listener '\(AudioObjectID.fourCC(selector))' install failed: \(err)")
            }
        }
    }

    /// The device list or a system default changed. A burst of these comes
    /// with one plug: only the first finds a difference, and the stall probe
    /// runs once, after the last.
    private func handleDeviceEvent() {
        guard isRecording else { return }
        let changed = refreshDevices()
        if input == nil {
            // Every input failed earlier: a new device is a reason to try
            // now, not at the watchdog's next slot (up to 30 s away). Only on
            // a real change: one plug is a burst of events. And not while a
            // configuration change is settling — that rebuild is on its way.
            if changed, !rebuildInProgress { rebuildEngine(reason: "input devices changed") }
        } else if !applyPolicy(), defaultInputMoved {
            // The policy first: a lost input is its to name and to leave at
            // once. Then the system default moving under a track that follows it.
            Task { await self.handleConfigChange() }
        }
        stallProbe?.cancel()
        stallProbe = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallAfterDeviceEvent))
            guard !Task.isCancelled else { return }
            await self?.probeStall()
        }
    }

    /// Moves the track when the policy says so, and says whether it did. Only
    /// off a working engine: while every rebuild fails, the watchdog's
    /// backoff owns the retries.
    @discardableResult
    private func applyPolicy() -> Bool {
        let now = Self.seconds(fromHostTicks: mach_absolute_time())
        guard case .move(_, let reason) = policy.decide(current: currentUID, connected: connectedIDs(), now: now) else {
            return false
        }
        rebuildEngine(reason: reason)
        return true
    }

    private func probeStall() {
        guard isRecording, let state = tapState else { return }
        rebuildIfStalled(state, frameThreshold: Self.stallAfterDeviceEvent, reason: "stalled after device change")
    }

    // MARK: - Watchdog

    /// Detects a dead tap (no real frame for a second while recording) and
    /// forces an engine rebuild. Backs off exponentially while rebuilds keep
    /// failing; only a real frame resets the pace.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            var lastCallbacks = -1
            var interval = Self.watchdogInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, let check = await self.watchdogCheck() else { return }
                interval = Self.nextWatchdogInterval(
                    current: interval, stalled: check.stalled, framesAdvanced: check.callbacks > lastCallbacks
                )
                lastCallbacks = check.callbacks
            }
        }
    }

    /// Stalled: no real frame for `frameThreshold`, and the engine was not
    /// (re)started within `startThreshold` — a slow input open is not a death.
    /// Seconds in; zero means "never happened".
    static func isStalled(
        now: Double, lastFrame: Double, lastRebuild: Double, captureStart: Double,
        frameThreshold: Double = stallFrameThreshold, startThreshold: Double = stallStartThreshold
    ) -> Bool {
        let anchor = max(lastRebuild, captureStart)
        guard lastFrame > 0 || anchor > 0 else { return false }
        let sinceFrame = lastFrame > 0 ? now - lastFrame : .infinity
        let sinceStart = anchor > 0 ? now - anchor : .infinity
        return sinceFrame >= frameThreshold && sinceStart >= startThreshold
    }

    /// Doubles while stalled; back to base only once a real frame arrived —
    /// the grace period after a rebuild must not reset the pace by itself.
    static func nextWatchdogInterval(current: Duration, stalled: Bool, framesAdvanced: Bool) -> Duration {
        if stalled { return min(current * 2, watchdogMaxInterval) }
        return framesAdvanced ? watchdogInterval : current
    }

    /// Returns nil when recording has stopped (watchdog exits). A tick that
    /// finds the tap alive asks the policy: that is where the hold of a
    /// better input runs out, and where a replugged input is noticed.
    private func watchdogCheck() -> (callbacks: Int, stalled: Bool)? {
        guard isRecording, let state = tapState else { return nil }
        let stalled = rebuildIfStalled(state, frameThreshold: Self.stallFrameThreshold, reason: "watchdog stall")
        if !stalled, input != nil { applyPolicy() }
        return (state.callbacks, stalled)
    }

    /// Rebuilds the engine when no real frame arrived for `frameThreshold`.
    @discardableResult
    private func rebuildIfStalled(_ state: TapState, frameThreshold: TimeInterval, reason: String) -> Bool {
        let now = mach_absolute_time()
        let lastFrame = state.lastWriteHostTime
        guard Self.isStalled(
            now: Self.seconds(fromHostTicks: now),
            lastFrame: Self.seconds(fromHostTicks: lastFrame),
            lastRebuild: Self.seconds(fromHostTicks: lastRebuildHostTime),
            captureStart: Self.seconds(fromHostTicks: captureStartHostTime),
            frameThreshold: frameThreshold
        ) else { return false }
        let reference = lastFrame > 0 ? lastFrame : max(lastRebuildHostTime, captureStartHostTime)
        let age = Self.seconds(fromHostTicks: now - reference)
        Log.error("Mic watchdog: no frames for \(String(format: "%.1f", age)) s (\(state.framesWritten) total) — rebuilding engine")
        // An engine that started and gave nothing, twice in a row: the input
        // is dead for now. Without this the track stays on it for good —
        // also right after moving up from an input that worked.
        silentStarts = input != nil && lastFrame < lastRebuildHostTime ? silentStarts + 1 : 0
        if silentStarts >= 2 {
            Log.warning("Mic: \(inputName(currentUID)) started twice and delivered no frames — moving on")
            policy.markFailed(currentUID)
            silentStarts = 0
        }
        rebuildEngine(reason: reason)
        return true
    }

    // MARK: - Taps

    /// The tap body for an input in `inputFormat`: pays the silence owed,
    /// brings the buffer to the file's format when the hardware differs from
    /// it, writes. A value, so the file side of a device switch runs in tests
    /// on synthetic buffers, with no engine and no device.
    static func tapBlock(
        from inputFormat: AVAudioFormat,
        to fileFormat: AVAudioFormat,
        outputFile: AVAudioFile,
        state: TapState,
        liveSink: LiveAudioSink? = nil
    ) throws -> AVAudioNodeTapBlock {
        guard inputFormat.sampleRate != fileFormat.sampleRate || inputFormat.channelCount != fileFormat.channelCount else {
            return plainTap(format: inputFormat, outputFile: outputFile, state: state, liveSink: liveSink)
        }
        Log.info("Installing tap with format conversion: \(Int(inputFormat.sampleRate)) Hz \(inputFormat.channelCount)ch → \(Int(fileFormat.sampleRate)) Hz \(fileFormat.channelCount)ch")
        return try convertingTap(
            from: inputFormat, to: fileFormat, outputFile: outputFile, state: state, liveSink: liveSink
        )
    }

    /// A standard audio tap that writes directly to the output file.
    private static func plainTap(
        format: AVAudioFormat,
        outputFile: AVAudioFile,
        state: TapState,
        liveSink: LiveAudioSink?
    ) -> AVAudioNodeTapBlock {
        { buffer, when in
            liveSink?.feed(buffer)
            let at = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            writeOwedSilence(state: state, at: at, outputFile: outputFile, format: format)
            let frames = Int64(buffer.frameLength)
            do {
                try outputFile.write(from: buffer)
                state.addFrames(frames, bufferEndHostTime: at + hostTicks(fromSeconds: Double(frames) / format.sampleRate))
            } catch {
                let errorCount = state.addError()
                if errorCount <= 5 || errorCount % 100 == 0 {
                    Log.error("Write error #\(errorCount): \(error.localizedDescription)")
                }
            }
        }
    }

    /// A tap that converts the hardware format to the file's format.
    ///
    /// Channel count is remapped by hand (`AudioConverter.remapChannels`): the
    /// system converter writes digital zeros for 3ch → 1ch and is only trusted
    /// with the sample rate (fix-multichannel-audio-loss, design § решение 1).
    private static func convertingTap(
        from inputFormat: AVAudioFormat,
        to fileFormat: AVAudioFormat,
        outputFile: AVAudioFile,
        state: TapState,
        liveSink: LiveAudioSink?
    ) throws -> AVAudioNodeTapBlock {
        let ratio = fileFormat.sampleRate / inputFormat.sampleRate
        var converter: AVAudioConverter?
        if inputFormat.sampleRate != fileFormat.sampleRate {
            guard let remappedFormat = AudioConverter.float32Format(
                channels: fileFormat.channelCount, sampleRate: inputFormat.sampleRate,
                layout: fileFormat.channelLayout
            ), let resampler = AVAudioConverter(from: remappedFormat, to: fileFormat) else {
                throw MicCaptureError.converterUnavailable
            }
            converter = resampler
        }
        nonisolated(unsafe) var probed = false

        return { buffer, when in
            liveSink?.feed(buffer)
            let at = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            writeOwedSilence(state: state, at: at, outputFile: outputFile, format: fileFormat)
            if !probed {
                probed = true
                Log.info("Converting tap first buffer: \(buffer.frameLength) frames, RMS per channel: \(AudioConverter.formatDBFS(AudioConverter.channelRMS(buffer))) dBFS")
            }
            guard let remapped = AudioConverter.remapChannels(
                buffer, to: fileFormat.channelCount, layout: fileFormat.channelLayout
            ) else {
                let errorCount = state.addError()
                if errorCount <= 5 { Log.error("Channel remap failed #\(errorCount): \(buffer.format) → \(fileFormat.channelCount)ch") }
                return
            }
            do {
                let toWrite: AVAudioPCMBuffer
                if let converter {
                    let outputFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: outputFrames) else { return }
                    // convert(to:from:) can't resample — it throws -50 on every
                    // buffer (AirPods switching to HFP at 24 kHz, 2026-09-26).
                    var delivered = false
                    var convertError: NSError?
                    converter.convert(to: convertedBuffer, error: &convertError) { _, status in
                        if delivered {
                            status.pointee = .noDataNow
                            return nil
                        }
                        delivered = true
                        status.pointee = .haveData
                        return remapped
                    }
                    if let convertError { throw convertError }
                    toWrite = convertedBuffer
                } else {
                    toWrite = remapped
                }
                try outputFile.write(from: toWrite)
                state.addFrames(
                    Int64(toWrite.frameLength),
                    bufferEndHostTime: at + hostTicks(fromSeconds: Double(buffer.frameLength) / inputFormat.sampleRate)
                )
            } catch {
                let errorCount = state.addError()
                if errorCount <= 5 || errorCount % 100 == 0 {
                    Log.error("Convert+write error #\(errorCount): \(error.localizedDescription)")
                }
            }
        }
    }

    enum MicCaptureError: Error, LocalizedError {
        case inputUnavailable(String)
        case converterUnavailable
        case startTimedOut

        var errorDescription: String? {
            switch self {
            case .inputUnavailable(let why):
                "Microphone unavailable: \(why)"
            case .converterUnavailable:
                "Cannot create audio converter for changed mic format"
            case .startTimedOut:
                "The microphone did not open in time. Try again, or pick another input in Settings → Recording."
            }
        }
    }
}

// MARK: - Thread-safe tap state

/// Tracks write state from the audio tap callback thread.
/// Uses `os_unfair_lock` for minimal overhead on the real-time audio thread.
final class TapState: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _framesWritten: Int64 = 0
    private var _callbacks: Int = 0
    private var _consecutiveErrors: Int = 0
    private var _lastWriteHostTime: UInt64 = 0
    private var _lastBufferEndHostTime: UInt64 = 0
    private var _captureStartHostTime: UInt64 = 0
    /// Set at (re)start; the next real buffer pays the silence owed since the
    /// last one and clears it. Carries the reason for the log line.
    private var _pendingFirstFrame: String?
    /// Why the engine was rebuilt, and the inputs before and after — the
    /// "Mic switch" log line, written on the first frame of the new engine.
    private var _pendingWhy: String?
    private var _input: String?
    private var _pendingInput: String?

    var framesWritten: Int64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _framesWritten
    }

    var callbacks: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _callbacks
    }

    var errors: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _consecutiveErrors
    }

    /// Host time of the last real frame delivery — liveness. Silence fills
    /// never move it: a filled gap must not look like a living tap.
    var lastWriteHostTime: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastWriteHostTime
    }

    /// Host time where the last delivered buffer ended — the timeline
    /// reference for gaps and the tail (not the post-I/O clock).
    var lastBufferEndHostTime: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastBufferEndHostTime
    }

    var captureStartHostTime: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _captureStartHostTime
    }

    func setCaptureStart(_ hostTime: UInt64) {
        os_unfair_lock_lock(&lock)
        _captureStartHostTime = hostTime
        os_unfair_lock_unlock(&lock)
    }

    /// `why`: what caused a rebuild, for the "Mic switch" line; nil at start.
    /// Kept from the first rebuild until a frame arrives: when that rebuild
    /// failed and a later one got through, the line still names the cause.
    func expectFirstFrame(after reason: String, why: String? = nil) {
        os_unfair_lock_lock(&lock)
        _pendingFirstFrame = reason
        _pendingWhy = _pendingWhy ?? why
        os_unfair_lock_unlock(&lock)
    }

    /// Names the input an engine is about to start on. Several may be tried
    /// before one delivers; the switch is from the last input that was
    /// recording to the one whose frame arrives.
    func willStart(input name: String) {
        os_unfair_lock_lock(&lock)
        if _input == nil { _input = name }
        _pendingInput = name
        os_unfair_lock_unlock(&lock)
    }

    /// The reason `silenceOwed` gives for a break in a stream that kept running.
    static let hole = "a hole in the stream"

    /// Silence owed before a buffer that starts at `hostTime`, measured from
    /// the end of the last delivered buffer or from capture start: for the
    /// first buffer after a (re)start — that consumes the pending marker —
    /// and for a hole in a running stream.
    /// `switched`: "from → to (why)" after a rebuild, nil otherwise.
    func silenceOwed(
        beforeBufferAt hostTime: UInt64, sampleRate: Double
    ) -> (frames: Int, reason: String, gapSeconds: Double, switched: String?)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let now = MicrophoneCapture.seconds(fromHostTicks: hostTime)
        let lastBufferEnd = MicrophoneCapture.seconds(fromHostTicks: _lastBufferEndHostTime)
        let captureStart = MicrophoneCapture.seconds(fromHostTicks: _captureStartHostTime)
        guard let reason = _pendingFirstFrame else {
            // An IOProc can pause and come back by itself — the HAL stops and
            // restarts IO around a device reconfiguration — with no rebuild
            // to pay for what it skipped. Shorter breaks are not counted.
            let frames = MicrophoneCapture.tailFrames(
                now: now, lastBufferEnd: lastBufferEnd, captureStart: captureStart, sampleRate: sampleRate
            )
            guard frames > 0 else { return nil }
            // Paid up to here, whether or not this buffer gets written: a
            // run of failed writes must not be paid for again every cycle.
            _lastBufferEndHostTime = hostTime
            return (frames, Self.hole, now - max(lastBufferEnd, captureStart), nil)
        }
        _pendingFirstFrame = nil
        let from = _input
        _input = _pendingInput ?? _input
        let switched = _pendingWhy.map { "\(from ?? "?") → \(_input ?? "?") (\($0))" }
        _pendingWhy = nil
        // The first buffer after `start` is placed at its true distance from
        // the recording's anchor, however short (design D3 of tap-eager-start):
        // the system track pads from the same anchor, and a fast mic start
        // must not put its first frame at position 0. After a rebuild the
        // threshold still hides the normal restart latency.
        let frames = MicrophoneCapture.tailFrames(
            now: now, lastBufferEnd: lastBufferEnd, captureStart: captureStart, sampleRate: sampleRate,
            minGap: reason == "start" ? 0 : MicrophoneCapture.minGapToFillSeconds
        )
        let reference = max(lastBufferEnd, captureStart)
        if frames > 0 { _lastBufferEndHostTime = hostTime }
        return (frames, reason, reference > 0 ? max(0, now - reference) : 0, switched)
    }

    func addFrames(_ count: Int64, bufferEndHostTime: UInt64) {
        os_unfair_lock_lock(&lock)
        _framesWritten += count
        _callbacks += 1
        _consecutiveErrors = 0
        _lastWriteHostTime = mach_absolute_time()
        _lastBufferEndHostTime = bufferEndHostTime
        // Periodic logging
        if _callbacks == 1 {
            os_unfair_lock_unlock(&lock)
            Log.debug("First frame written!")
        } else if _callbacks % 500 == 0 {
            let frames = _framesWritten
            let cbs = _callbacks
            os_unfair_lock_unlock(&lock)
            Log.debug("Callbacks: \(cbs), frames: \(frames)")
        } else {
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Account for silence written to keep the timeline aligned. Liveness and
    /// the buffer-end reference stay where the real audio left them.
    func addSilenceFrames(_ count: Int64) {
        os_unfair_lock_lock(&lock)
        _framesWritten += count
        os_unfair_lock_unlock(&lock)
    }

    /// Returns the new error count.
    @discardableResult
    func addError() -> Int {
        os_unfair_lock_lock(&lock)
        _consecutiveErrors += 1
        _callbacks += 1
        let count = _consecutiveErrors
        os_unfair_lock_unlock(&lock)
        return count
    }
}

// MARK: - Config-change debounce

/// Trailing debounce for the input device's format notifications: every
/// notification extends the quiet window, and the engine is rebuilt once
/// after the window has been quiet — one rebuild per burst, not one per
/// notification. No engine inside, so a burst is a unit test.
struct ConfigChangeDebouncer {
    let quietWindow: TimeInterval
    private var lastNotification: TimeInterval?

    init(quietWindow: TimeInterval) {
        self.quietWindow = quietWindow
    }

    mutating func note(at time: TimeInterval) {
        lastNotification = time
    }

    /// Seconds still to wait before the window is quiet; nil when nothing is pending.
    func waitUntilQuiet(at time: TimeInterval) -> TimeInterval? {
        lastNotification.map { max(0, $0 + quietWindow - time) }
    }

    /// True once — when the window has been quiet — and consumes the pending notification.
    mutating func shouldRebuild(at time: TimeInterval) -> Bool {
        guard let last = lastNotification, time - last >= quietWindow else { return false }
        lastNotification = nil
        return true
    }
}

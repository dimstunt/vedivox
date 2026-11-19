import AudioToolbox
import AVFoundation
import Foundation
import os

/// Captures system audio using Core Audio Taps (macOS 14.4+).
/// Records in the tap's native format (typically 48kHz stereo) for high-quality playback.
/// Conversion to 16kHz mono for transcription is done later by TranscriptionPipeline.
/// Requires NSAudioCaptureUsageDescription in Info.plist — permission is requested
/// automatically on first Core Audio Tap creation.
actor SystemAudioCapture {

    /// Daemons whose output never belongs in a meeting recording. Matched
    /// against `kAudioProcessPropertyBundleID` (bundleless daemons report the
    /// executable name). systemsoundserverd renders notification-banner
    /// sounds for ALL apps (verified experimentally 2026-07-11).
    private static let excludedBundleIDs: Set<String> = [
        "systemsoundserverd",
        "com.apple.audio.systemsoundserverd",
    ]

    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var audioWriter: SystemAudioWriter?
    /// Optional second consumer of the system stream (the meeting's live transcript).
    private var liveSink: LiveAudioSink?
    private var isCapturing = false
    private let ioQueue = DispatchQueue(label: "SystemAudioCapture.io", qos: .userInitiated)
    private var outputListenerInstalled = false
    private var processListListenerInstalled = false
    /// Process objects the current tap excludes, to tell a newly appeared
    /// excluded app from one the tap already leaves out.
    private var excludedObjectIDs: Set<AudioObjectID> = []
    /// A short throwaway capture that brings up macOS's system-audio prompt now
    /// and says whether anything was heard. Creating a tap asks
    /// nothing: the prompt comes with the first start of an aggregate holding
    /// one, and that start waits for the answer (the first recording of
    /// 2026-11-17 spent 2.1 s in AudioDeviceStart while it was up) — so this
    /// runs off the main thread and may take as long as the user does. A
    /// refusal is reported to deliver zeros with noErr everywhere (not seen
    /// live yet), so only a non-zero sample confirms access; silence is
    /// `.silent`, whatever its cause. Same tap and aggregate setup as a
    /// recording, minus the file; never runs during one (callers check).
    static func check(listen: Duration = .milliseconds(1500)) async -> PermissionFacts.SystemAudioCheck {
        await Task.detached(priority: .userInitiated) { () -> PermissionFacts.SystemAudioCheck in
            let myPID = ProcessInfo.processInfo.processIdentifier
            let mine = ((try? AudioObjectID.readAllProcessObjectIDs()) ?? []).filter { $0.readProcessPID() == myPID }
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: mine)
            tapDesc.uuid = UUID()
            tapDesc.muteBehavior = .unmuted
            var tapID: AudioObjectID = kAudioObjectUnknown
            var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
            guard err == noErr else { return .failed(err) }
            defer { AudioHardwareDestroyProcessTap(tapID) }

            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Vedivox-PermissionCheck",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDesc.uuid.uuidString]],
            ]
            var deviceID: AudioObjectID = kAudioObjectUnknown
            err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
            guard err == noErr else { return .failed(err) }
            defer { AudioHardwareDestroyAggregateDevice(deviceID) }

            let heard = OSAllocatedUnfairLock(initialState: false)
            var procID: AudioDeviceIOProcID?
            let queue = DispatchQueue(label: "SystemAudioCapture.check")
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
                if hasSound(input) { heard.withLock { $0 = true } }
            }
            guard err == noErr, let procID else { return .failed(err) }
            defer { AudioDeviceDestroyIOProcID(deviceID, procID) }
            err = AudioDeviceStart(deviceID, procID)
            guard err == noErr else { return .failed(err) }
            try? await Task.sleep(for: listen)
            AudioDeviceStop(deviceID, procID)
            return heard.withLock { $0 } ? .heard : .silent
        }.value
    }

    /// Whether any sample in a Float32 buffer list is not zero. Digital zero
    /// is what a refused tap delivers; any real output — even a quiet room
    /// through a call app — has some non-zero sample.
    static func hasSound(_ list: UnsafePointer<AudioBufferList>) -> Bool {
        peak(list) > 0
    }

    /// The largest absolute sample of a Float32 buffer list; 0 for digital zero.
    static func peak(_ list: UnsafePointer<AudioBufferList>) -> Float {
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            for sample in samples { peak = max(peak, abs(sample)) }
        }
        return peak
    }

    /// Whether the running recording's system track has had a non-zero sample
    /// yet. False before the first callback and with no recording.
    var heardSound: Bool { audioWriter?.heardSound ?? false }

    /// The call audio comes through chopped and `TapChopDetector.maxRebuilds`
    /// rebuilds of the tap did not fix it: the owner is told.
    private(set) var callAudioChopped = false

    /// Attaches a live consumer of the system stream, or clears it. Set before
    /// `start`, like the mic's: the file is written the same either way.
    func setLiveSink(_ sink: LiveAudioSink?) {
        liveSink = sink
    }

    /// `startHostTime` is the recording's anchor (`mach_absolute_time`), shared
    /// with the mic track: the file is padded from it to the first callback.
    func start(outputURL: URL, startHostTime: UInt64) async throws {
        guard !isCapturing else { return }

        Log.info("Starting Core Audio Tap capture... (start anchor: host ticks \(startHostTime))")

        // Rollback for a start that fails halfway. Everything below is created
        // in coreaudiod before `isCapturing` flips, and `stop()` guards on that
        // flag — so a failed aggregate/IOProc step used to leak the tap (and
        // the output listener) for the life of the process.
        var started = false
        defer {
            if !started {
                Log.error("Capture start failed — releasing tap/aggregate/listener")
                releaseHardware()
                audioWriter = nil
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let tapFormat = try createTap()

        // 5. Determine recording format.
        // Use the tap format (kAudioTapPropertyFormat) for the WAV header — it describes the
        // actual data format delivered by the IOProc callback.
        // The aggregate device's nominal sample rate can be unreliable (e.g., 24kHz from
        // Bluetooth HFP negotiation) while the tap still delivers at its original rate.
        // We verify the actual rate from IOProc timing data and fix the header post-recording
        // if needed (see SystemAudioWriter.measuredSampleRate).
        let recordFormat = tapFormat

        // 6. Create output file in the device's actual format (high quality for playback)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordFormat.sampleRate,
            AVNumberOfChannelsKey: recordFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: !recordFormat.isInterleaved,
        ]
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: recordFormat.isInterleaved
        )

        let writer = SystemAudioWriter(
            file: file,
            tapFormat: recordFormat,
            captureStartHostTime: startHostTime,
            liveSink: liveSink
        )
        self.audioWriter = writer

        try startAggregate(writer: writer)

        self.isCapturing = true
        started = true
        rebuildCount = 0
        chopRebuilds = 0
        callAudioChopped = false
        deafWatch = DeafTapWatch()
        outputState = nil
        callAppsPlaying = false
        startWatchdog()
        Log.info("Capture started successfully!")
    }

    /// Steps 1–3: the process tap. Returns its native format. Shared by
    /// `start` and the watchdog rebuild.
    private func createTap() throws -> AVAudioFormat {
        // 1. Build the exclude list: ourselves (so playback of past meetings
        //    doesn't loop into the tap) plus the notification-banner sound
        // daemon (Slack/Telegram dings polluted recordings; the
        //    banner sound is rendered by systemsoundserverd, verified
        //    experimentally 2026-07-11, not by the source app, so call audio
        //    from those apps still gets captured).
        // Plus the user's exclusion list: apps feeding a virtual
        //    mic or playing their own notification sounds.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let allObjectIDs = try AudioObjectID.readAllProcessObjectIDs()
        let myObjectID = allObjectIDs.first { $0.readProcessPID() == myPID }
        var excludeList: [AudioObjectID] = myObjectID.map { [$0] } ?? []
        var excludedDescriptions = ["self=\(myObjectID.map { "#\($0)" } ?? "<not-found>")"]

        let userList = SystemCaptureExclusions.load()
        var userEntriesFound = Set<String>()
        for objectID in allObjectIDs where objectID != myObjectID {
            guard let bundle = objectID.readProcessBundleID(), !bundle.isEmpty else { continue }
            let reason: String
            if Self.excludedBundleIDs.contains(bundle.lowercased()) {
                reason = "sound-daemon"
            } else if let entry = SystemCaptureExclusions.entry(matching: bundle, in: userList) {
                userEntriesFound.insert(entry)
                reason = "user-list"
            } else {
                continue
            }
            excludeList.append(objectID)
            excludedDescriptions.append("\(bundle)=#\(objectID) (\(reason))")
        }
        excludedObjectIDs = Set(excludeList)
        let notRunning = userList.filter { !userEntriesFound.contains($0) }
        Log.info("Tap mode: global-exclude; excluded: \(excludedDescriptions.joined(separator: ", ")); user-list not running: \(notRunning.isEmpty ? "none" : notRunning.joined(separator: ", ")); \(allObjectIDs.count) current processes")

        // 2. Create tap description — "tap everything EXCEPT these processes".
        //    This init variant is expected to be dynamic: processes that start
        //    outputting audio after tap creation are automatically included
        //    (unlike initStereoMixdownOfProcesses which snapshots the PID list).
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        var tapID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw SystemAudioError.tapCreationFailed(err)
        }
        self.processTapID = tapID
        self.tapUUID = tapDesc.uuid
        Log.info("Created process tap #\(tapID)")

        // 3. Read the tap's native audio format
        var streamDesc = try tapID.readAudioTapStreamBasicDescription()
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDesc) else {
            throw SystemAudioError.invalidFormat
        }
        Log.info("Tap format: \(Int(tapFormat.sampleRate)) Hz, \(tapFormat.channelCount) ch, interleaved=\(tapFormat.isInterleaved ? 1 : 0)")
        return tapFormat
    }

    /// Steps 4 and 7: the aggregate around the current tap, the IOProc feeding
    /// `writer`, and the start. Shared by `start` and the watchdog rebuild.
    private func startAggregate(writer: SystemAudioWriter) throws {
        // 4. Create an aggregate device made of the tap alone — no real
        // sub-device, no clock device (an earlier change).
        //    A global tap captures process audio whatever hosts the aggregate
        //    (measured 2026-09-02); with a real device as the clock the
        //    aggregate keeps an IO context on it for the whole recording
        //    (AirPods across a profile flip: the second path of the coreaudiod
        //    storm; built-in speakers: held all along). Tap-only runs on the
        //    host clock: first callback 0.06 s in silence, 48 000 frames per
        //    host second, 0 sampleTime breaks over 7 output switches, less
        //    coreaudiod CPU (probes 2026-09-28, probe_tap_only.swift).

        // Install a listener so we learn if the user switches the default
        // output device mid-recording — useful signal when diagnosing dropouts.
        installDefaultOutputDeviceListener()
        installProcessListListener()

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vedivox-SystemTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Start the tap now, not on the first tapped audio. With auto-start
            // the aggregate parks until some process plays; a process that opens
            // input first (Zoom joining audio) then waits for the tap to run
            // while the tap waits for audio that context will never render —
            // coreaudiod times the client out every 14 s (0x3C) and Zoom hangs
            // on "connecting to audio" (macOS 26.3.1, spindump 2026-09-28).
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ],
            ],
        ]

        var aggDeviceID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggDeviceID)
        guard err == noErr else {
            throw SystemAudioError.aggregateDeviceFailed(err)
        }
        self.aggregateDeviceID = aggDeviceID
        Log.info("Created aggregate device #\(aggDeviceID)")
        installOverloadListener()
        if let deviceRate = aggDeviceID.readNominalSampleRate(),
           deviceRate != writer.sampleRate {
            Log.info("Sample rate mismatch: tap=\(Int(writer.sampleRate)) Hz, device=\(Int(deviceRate)) Hz — using tap rate, will verify from IOProc data")
        }

        // 7. Create IOProc callback and start audio flow
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggDeviceID, ioQueue) { _, inInputData, inInputTime, _, _ in
            writer.writeAudio(from: inInputData, inputTime: inInputTime)
        }
        guard err == noErr else {
            throw SystemAudioError.ioProcFailed(err)
        }
        self.deviceProcID = procID

        err = AudioDeviceStart(aggDeviceID, procID)
        guard err == noErr else {
            throw SystemAudioError.startFailed(err)
        }
        lastStartHostTime = mach_absolute_time()
    }

    // MARK: - System watchdog

    private var watchdogTask: Task<Void, Never>?
    private var watchdog = SystemCaptureWatchdog()
    private var lastStartHostTime: UInt64 = 0
    private var rebuildCount = 0
    /// Rebuilds for the current chop; back to zero once it is gone.
    private var chopRebuilds = 0
    private var deafWatch = DeafTapWatch()
    private var tapUUID = UUID()

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdog = SystemCaptureWatchdog()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = await self.watchdogTick() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Returns the next sleep, or nil once capture stopped (watchdog exits).
    private func watchdogTick() -> Duration? {
        guard isCapturing, let writer = audioWriter else { return nil }
        let live = writer.liveness
        let chop = writer.takeChopNews()
        if chop.cleared {
            if chopRebuilds > 0 || callAudioChopped {
                Log.info("chopped call audio: gone after \(chopRebuilds) rebuild(s)\(callAudioChopped ? " — warning cleared" : "")")
            }
            chopRebuilds = 0
            callAudioChopped = false
        }
        if let age = watchdog.tick(
            now: MicrophoneCapture.seconds(fromHostTicks: mach_absolute_time()),
            lastCallback: MicrophoneCapture.seconds(fromHostTicks: live.lastHostTime),
            lastStart: MicrophoneCapture.seconds(fromHostTicks: lastStartHostTime),
            callbacks: live.callbacks
        ) {
            Log.error("system watchdog: no callbacks for \(String(format: "%.1f", age)) s (\(live.callbacks) total) — rebuilding tap+aggregate")
            rebuild(reason: "watchdog stall")
        } else if UserDefaults.standard.bool(forKey: SystemCaptureWatchdog.manualRebuildDefaultsKey) {
            UserDefaults.standard.removeObject(forKey: SystemCaptureWatchdog.manualRebuildDefaultsKey)
            rebuild(reason: "manual (defaults)")
        } else if chop.rebuild {
            if chopRebuilds < TapChopDetector.maxRebuilds {
                chopRebuilds += 1
                rebuild(reason: "chopped call audio, try \(chopRebuilds) of \(TapChopDetector.maxRebuilds)")
            } else if !callAudioChopped {
                callAudioChopped = true
                Log.warning("chopped call audio: still there after \(chopRebuilds) rebuilds — warning the owner (switch the call's speaker and back)")
            }
        } else {
            let deaf = writer.deafness
            if deafWatch.shouldRebuild(zeroRun: deaf.zeroRun, heardSinceRebuild: deaf.heard, callOutputting: callAppsPlaying) {
                Log.warning("system tap deaf: digital zero for \(Int(deaf.zeroRun)) s while a call app plays — rebuilding tap+aggregate, next wait \(Int(deafWatch.wait)) s")
                rebuild(reason: "deaf tap")
            }
        }
        // After the decision: its Core Audio reads block while coreaudiod
        // stalls, and the `live` snapshot above would then call a living tap dead.
        logOutputStateIfChanged()
        return watchdog.currentInterval
    }

    /// Fresh tap + aggregate + IOProc on the same writer and file. The
    /// timeline fills the hole between the streams by the wall clock.
    private func rebuild(reason: String) {
        guard isCapturing, let writer = audioWriter else { return }
        rebuildCount += 1
        Log.warning("system watchdog: rebuilding tap+aggregate (attempt #\(rebuildCount), reason: \(reason))")
        releaseHardware()
        lastStartHostTime = mach_absolute_time()
        writer.expectRestart()
        do {
            let format = try createTap()
            if format.sampleRate != writer.sampleRate || format.channelCount != writer.channelCount {
                // The rate tracker corrects a rate change at stop; the tap is
                // always a stereo mixdown, so the channel count cannot move.
                Log.warning("system watchdog: tap format changed to \(Int(format.sampleRate)) Hz \(format.channelCount) ch, file keeps \(Int(writer.sampleRate)) Hz \(writer.channelCount) ch")
            }
            try startAggregate(writer: writer)
            Log.info("system watchdog: tap+aggregate rebuilt")
        } catch {
            Log.error("system watchdog: rebuild FAILED: \(error.localizedDescription) — will retry with backoff")
            releaseHardware()
        }
    }

    func stop() async -> URL? {
        guard isCapturing else { return nil }

        watchdogTask?.cancel()
        watchdogTask = nil
        let url = audioWriter?.fileURL

        releaseHardware()
        // No more callbacks from here on — pad the file up to now (a stream
        // that never started, or stopped before the IOProc did).
        audioWriter?.finish()

        // 3. Release writer (closes AVAudioFile) and verify sample rate
        var rateSegments: [RateSegment] = []
        var measuredRate: Double?
        var headerRate: Double = 48000
        var channelCount: UInt32 = 2
        if let writer = audioWriter {
            Log.info("Total frames written: \(writer.totalFramesWritten) (\(String(format: "%.2f", Double(writer.totalFramesWritten) / writer.sampleRate)) sec at \(Int(writer.sampleRate)) Hz)")
            rateSegments = writer.rateSegments
            measuredRate = writer.measuredSampleRate
            headerRate = writer.sampleRate
            channelCount = writer.channelCount
        }
        // Release the writer first: the AVAudioFile finalizes its header on
        // deallocation, and the corrector below reopens the file from disk.
        audioWriter = nil
        isCapturing = false

        if rateSegments.count > 1, let fileURL = url {
            // The effective device rate changed mid-recording (e.g. Bluetooth
            // A2DP→HFP). Piecewise-resample the affected segments so the whole
            // file plays at the correct speed.
            let described = rateSegments
                .map { "frame \($0.startFrame) @ \(Int($0.rate)) Hz" }
                .joined(separator: ", ")
            Log.info("Rate changed mid-recording, correcting segments: [\(described)]")
            do {
                let changed = try AudioRateCorrector.correctInPlace(url: fileURL, segments: rateSegments)
                Log.info(changed
                    ? "Piecewise rate correction applied"
                    : "Piecewise rate correction skipped: all segments snap to header rate")
            } catch {
                Log.error("Piecewise rate correction FAILED: \(error) — file left as recorded")
            }
        } else if let measuredRate {
            // Single-rate recording: verify against the early measurement and
            // fix the WAV header if the whole file was off (legacy path).
            let deviation = abs(measuredRate - headerRate) / headerRate
            if deviation > 0.05, !Self.isPlausibleMeasuredRate(measuredRate) {
                Log.warning("SAMPLE RATE CORRECTION skipped: measured \(Int(measuredRate)) Hz is not a plausible clock — keeping header \(Int(headerRate)) Hz")
            } else if deviation > 0.05 {
                let correctedRate = Self.nearestStandardSampleRate(measuredRate)
                Log.info("SAMPLE RATE CORRECTION: header=\(Int(headerRate)) Hz, measured=\(Int(measuredRate)) Hz → correcting to \(Int(correctedRate)) Hz")
                if let fileURL = url {
                    Self.fixWAVSampleRate(url: fileURL, sampleRate: correctedRate, channelCount: channelCount)
                }
            } else {
                Log.info("Sample rate verified: header=\(Int(headerRate)) Hz, measured=\(Int(measuredRate)) Hz")
            }
        }

        Log.info("Capture stopped, file: \(url?.path ?? "nil")")
        return url
    }

    /// Tears down everything `start()` created in coreaudiod: IOProc, aggregate
    /// device, tap, output listener. No `isCapturing` guard — this is also the
    /// rollback for a start that failed halfway, so every step checks its own
    /// handle and is safe to run on a partially built pipeline.
    private func releaseHardware() {
        removeDefaultOutputDeviceListener()
        removeProcessListListener()
        removeOverloadListener()

        // 1. Stop the device (no more IOProc callbacks) and drop the aggregate
        if aggregateDeviceID != kAudioObjectUnknown {
            if let deviceProcID {
                var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
                if err != noErr { Log.error("Stop error: \(err)") }
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { Log.error("DestroyIOProc error: \(err)") }
                self.deviceProcID = nil
            }
            let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr { Log.error("DestroyAggregate error: \(err)") }
            aggregateDeviceID = kAudioObjectUnknown
        }

        // 2. Destroy the process tap
        if processTapID != kAudioObjectUnknown {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr { Log.error("DestroyTap error: \(err)") }
            processTapID = kAudioObjectUnknown
        }
    }

    var capturing: Bool { isCapturing }

    // MARK: - Default Output Device Listener

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// A C callback, deliberately not a block. `AudioObjectRemovePropertyListenerBlock`
    /// returns noErr from Swift yet leaves the listener installed — Swift wraps
    /// the closure into a fresh ObjC block on every call, so the HAL never sees
    /// the one it registered (measured 2026-09-01; storing it as
    /// `@convention(block)` does not help either). A proc + clientData pair is
    /// stable, so removal really removes. Runs on the HAL notification thread:
    /// log only, no actor state.
    private static let defaultOutputChanged: AudioObjectPropertyListenerProc = { _, _, _, _ in
        if let newID = try? AudioObjectID.readDefaultSystemOutputDevice(),
           let newUID = try? newID.readDeviceUID() {
            Log.info("Default system output changed: \(newUID) (id=\(newID))")
        } else {
            Log.info("Default system output changed (read failed)")
        }
        return noErr
    }

    private func installDefaultOutputDeviceListener() {
        var address = Self.defaultOutputAddress
        let err = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.defaultOutputChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if err == noErr {
            outputListenerInstalled = true
        } else {
            Log.error("Failed to install default output listener: \(err)")
        }
    }

    private func removeDefaultOutputDeviceListener() {
        guard outputListenerInstalled else { return }
        var address = Self.defaultOutputAddress
        let err = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.defaultOutputChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if err != noErr { Log.error("Failed to remove default output listener: \(err)") }
        outputListenerInstalled = false
    }

    // MARK: - Process List Listener

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// A C callback for the same reason as `defaultOutputChanged`. Hops onto
    /// the actor; the instance is the app-long `AudioSessionManager` capture.
    private static let processListChanged: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let capture = Unmanaged<SystemAudioCapture>.fromOpaque(clientData).takeUnretainedValue()
        Task { await capture.excludeLateProcesses() }
        return noErr
    }

    /// A process object appears when a process connects to the audio server,
    /// before its first sound (`say`: 0.05 s after launch, 1+ s before audio).
    /// The tap's process list cannot be changed in place (setting
    /// kAudioTapPropertyDescription returns '!hog', spike 2026-09-30), so an
    /// excluded app appearing mid-recording costs a rebuild: ~105 ms hole,
    /// filled with silence by the timeline.
    private func excludeLateProcesses() {
        guard isCapturing, let objectIDs = try? AudioObjectID.readAllProcessObjectIDs() else { return }
        let userList = SystemCaptureExclusions.load()
        let late = objectIDs.filter { objectID in
            guard !excludedObjectIDs.contains(objectID),
                  let bundle = objectID.readProcessBundleID() else { return false }
            return SystemCaptureExclusions.entry(matching: bundle, in: userList) != nil
        }
        guard !late.isEmpty else { return }
        let described = late.map { "\($0.readProcessBundleID() ?? "?")=#\($0)" }.joined(separator: ", ")
        Log.info("excluding late process \(described) (user-list)")
        rebuild(reason: "excluded app appeared")
    }

    private func installProcessListListener() {
        var address = Self.processListAddress
        let err = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.processListChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if err == noErr {
            processListListenerInstalled = true
        } else {
            Log.error("Failed to install process list listener: \(err)")
        }
    }

    private func removeProcessListListener() {
        guard processListListenerInstalled else { return }
        var address = Self.processListAddress
        let err = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.processListChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if err != noErr { Log.error("Failed to remove process list listener: \(err)") }
        processListListenerInstalled = false
    }

    // MARK: - Overload listener and output state

    private var overloadListenerDevice: AudioObjectID = kAudioObjectUnknown

    private static var overloadAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Our aggregate missed an IO cycle. A C callback for the same reason as
    /// `defaultOutputChanged`; log only.
    private static let overloaded: AudioObjectPropertyListenerProc = { device, _, _, _ in
        Log.warning("Vedivox-SystemTap #\(device): processor overload, an IO cycle was skipped")
        return noErr
    }

    private func installOverloadListener() {
        var address = Self.overloadAddress
        let err = AudioObjectAddPropertyListener(aggregateDeviceID, &address, Self.overloaded, nil)
        if err == noErr {
            overloadListenerDevice = aggregateDeviceID
        } else {
            Log.error("Failed to install overload listener: \(err)")
        }
    }

    private func removeOverloadListener() {
        guard overloadListenerDevice != kAudioObjectUnknown else { return }
        var address = Self.overloadAddress
        AudioObjectRemovePropertyListener(overloadListenerDevice, &address, Self.overloaded, nil)
        overloadListenerDevice = kAudioObjectUnknown
    }

    private var outputState: String?
    /// A meeting app or browser plays, as of the last output-state check.
    private var callAppsPlaying = false
    private var outputStateCheckedAt: UInt64 = 0

    /// Every 5 s: the default output's rate and IO buffer and which call apps
    /// play, logged when any of it changes — what 18.11 needed from coreaudiod's
    /// journal, which keeps it for ~1.5 h.
    private func logOutputStateIfChanged() {
        let now = mach_absolute_time()
        guard MicrophoneCapture.seconds(fromHostTicks: now - outputStateCheckedAt) >= 5 else { return }
        outputStateCheckedAt = now
        let device = AudioObjectID.readDefaultOutputDevice()
        let name = device.flatMap { $0.readDeviceName() } ?? "none"
        let rate = device.flatMap { $0.readNominalSampleRate() }.map { "\(Int($0)) Hz" } ?? "? Hz"
        let frames = device.flatMap { $0.readBufferFrameSize() }.map { "\($0)" } ?? "?"
        let apps = SilentCallTrack.callAppsOutputtingIDs()
        callAppsPlaying = !apps.isEmpty
        let state = "\(name), \(rate), IO buffer \(frames) frames; call apps outputting: \(apps.isEmpty ? "none" : apps.joined(separator: ", "))"
        guard state != outputState else { return }
        outputState = state
        Log.info("Output state: \(state)")
    }

    // MARK: - Sample Rate Verification Helpers

    /// Standard audio sample rates for rounding measured values.
    private static let standardSampleRates: [Double] = [
        8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000,
    ]

    /// Round a measured sample rate to the nearest standard value.
    private static func nearestStandardSampleRate(_ measured: Double) -> Double {
        standardSampleRates.min(by: { abs($0 - measured) < abs($1 - measured) }) ?? measured
    }

    /// Whether a measured rate looks like a real audio clock. The device's
    /// sampleTime counter can reset mid-measurement (the aggregate device is
    /// rebuilt when the default output changes), producing negative or absurd
    /// deltas — those must never drive a header correction.
    static func isPlausibleMeasuredRate(_ measured: Double) -> Bool {
        measured.isFinite && measured >= 4000 && measured <= 384_000
    }

    /// How many silence frames to insert for a mid-recording sampleTime gap.
    /// The counter is only continuous while the device lives; across a device
    /// rebuild it jumps to an arbitrary value. Wall-clock elapsed since the
    /// previous callback bounds any real gap, so a jump far beyond it is a
    /// counter discontinuity: fill only the wall-clock gap (keeps the
    /// timeline aligned) instead of the counted one.
    static func gapFillFrames(sampleTimeGap: Double, hostElapsedSeconds: Double, sampleRate: Double) -> Int {
        guard sampleTimeGap > 1 else { return 0 }
        let wallFrames = max(0, hostElapsedSeconds) * sampleRate
        // Trust the counter up to twice the wall-clock gap plus a second of
        // scheduling jitter; beyond that the counter is lying, not the clock.
        if sampleTimeGap <= wallFrames * 2 + sampleRate {
            return Int(sampleTimeGap)
        }
        return Int(wallFrames)
    }

    /// Patch the sample rate and byte rate in a WAV file header without rewriting the file.
    private static func fixWAVSampleRate(url: URL, sampleRate: Double, channelCount: UInt32) {
        guard let handle = try? FileHandle(forUpdating: url) else {
            Log.error("Cannot open file for WAV header fix: \(url.path)")
            return
        }
        defer { try? handle.close() }

        // Read first 100 bytes to find 'fmt ' chunk
        let header = handle.readData(ofLength: 100)
        guard let fmtRange = header.range(of: Data("fmt ".utf8)) else {
            Log.error("'fmt ' chunk not found in WAV header")
            return
        }

        // fmt chunk layout: "fmt " (4) + chunkSize (4) + audioFormat (2) + numChannels (2) + sampleRate (4) + byteRate (4) + ...
        let sampleRateOffset = fmtRange.lowerBound + 4 + 4 + 2 + 2 // +8 from start of fmt data
        let byteRateOffset = sampleRateOffset + 4

        let rate = UInt32(sampleRate)
        let bytesPerSample: UInt32 = 4 // Float32
        let byteRate = rate * channelCount * bytesPerSample

        var rateLE = rate.littleEndian
        var byteRateLE = byteRate.littleEndian

        try? handle.seek(toOffset: UInt64(sampleRateOffset))
        handle.write(Data(bytes: &rateLE, count: 4))

        try? handle.seek(toOffset: UInt64(byteRateOffset))
        handle.write(Data(bytes: &byteRateLE, count: 4))

        Log.info("WAV header fixed: sampleRate=\(rate), byteRate=\(byteRate)")
    }

    enum SystemAudioError: Error, LocalizedError {
        case noAudioProcesses
        case tapCreationFailed(OSStatus)
        case invalidFormat
        case converterFailed
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noAudioProcesses:
                "No audio processes found to capture"
            case .tapCreationFailed(let s):
                "Process tap creation failed (error \(s)). Grant audio capture permission in System Settings."
            case .invalidFormat:
                "Could not read audio format from process tap"
            case .converterFailed:
                "Could not create audio format converter"
            case .aggregateDeviceFailed(let s):
                "Aggregate device creation failed: \(s)"
            case .ioProcFailed(let s):
                "IOProc creation failed: \(s)"
            case .startFailed(let s):
                "Audio device start failed: \(s)"
            }
        }
    }
}

// MARK: - Thread-safe audio writer (native format, no conversion)

private final class SystemAudioWriter: @unchecked Sendable {
    let fileURL: URL
    let sampleRate: Double
    let channelCount: UInt32
    private let file: AVAudioFile
    private let tapFormat: AVAudioFormat
    private let liveSink: LiveAudioSink?
    private let lock = NSLock()

    /// Where each callback lands on the file timeline.
    private var timeline: TapTimeline

    /// mach_absolute_time timebase for converting to seconds.
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Total frames written (for diagnostics).
    private(set) var totalFramesWritten: Int64 = 0

    private var callbackCount = 0

    // MARK: - Sample rate measurement from actual IOProc data

    /// Rate measurement over the first callbacks of one unbroken stream.
    private var measurement = RateMeasurement()

    /// Measured sample rate from IOProc timing data (set after ~100 callbacks).
    private(set) var measuredSampleRate: Double?

    /// Continuous effective-rate monitoring: detects mid-recording sample-rate
    /// changes (device re-created with a different clock) for piecewise
    /// correction at stop.
    private var rateTracker: RateSegmentTracker

    /// Snapshot of detected rate segments (thread-safe).
    var rateSegments: [RateSegment] {
        lock.lock()
        defer { lock.unlock() }
        return rateTracker.segments
    }

    init(file: AVAudioFile, tapFormat: AVAudioFormat, captureStartHostTime: UInt64, liveSink: LiveAudioSink? = nil) {
        self.fileURL = file.url
        self.file = file
        self.tapFormat = tapFormat
        self.liveSink = liveSink
        self.sampleRate = tapFormat.sampleRate
        self.channelCount = tapFormat.channelCount
        self.timeline = TapTimeline(
            sampleRate: tapFormat.sampleRate,
            captureStartHostNanos: Self.hostTimeNanos(captureStartHostTime)
        )
        self.rateTracker = RateSegmentTracker(headerRate: tapFormat.sampleRate)
        self.chop = TapChopDetector(sampleRate: tapFormat.sampleRate)
    }

    /// Convert a mach host time to nanoseconds.
    private static func hostTimeNanos(_ hostTime: UInt64) -> UInt64 {
        UInt64(Double(hostTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom))
    }

    private static func seconds(_ frames: Int, at sampleRate: Double) -> String {
        String(format: "%.3f", Double(frames) / sampleRate)
    }

    /// Liveness for the system watchdog: real callbacks only — silence fills
    /// never move it, a filled hole must not look like a living tap.
    var liveness: (callbacks: Int, lastHostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (callbackCount, lastCallbackHostTime)
    }

    private var lastCallbackHostTime: UInt64 = 0

    /// Latches on the first non-zero sample: until then the track
    /// is digital zero, which is what a refused permission records.
    var heardSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }

    private var heard = false

    /// Chopped call audio, fed from every callback.
    private var chop: TapChopDetector
    private var chopRebuildWanted = false
    private var chopCleared = false
    /// Loudest sample since the last `Callbacks:` line.
    private var peakSinceLine: Float = 0

    /// All-zero frames in a row on the current stream, and whether a non-zero
    /// sample came since the last (re)start.
    private var zeroRunFrames = 0
    private var heardSinceRestart = false
    private var restarted = false

    var deafness: (zeroRun: Double, heard: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (Double(zeroRunFrames) / sampleRate, heardSinceRestart)
    }

    /// What the detector said since the last call, for the watchdog tick.
    func takeChopNews() -> (rebuild: Bool, cleared: Bool) {
        lock.lock()
        defer {
            (chopRebuildWanted, chopCleared) = (false, false)
            lock.unlock()
        }
        return (chopRebuildWanted, chopCleared)
    }

    /// The next callback opens a fresh stream (watchdog rebuild).
    func expectRestart() {
        lock.lock()
        defer { lock.unlock() }
        timeline.expectRestart()
        chop.restart()
        zeroRunFrames = 0
        heardSinceRestart = false
        restarted = true
    }

    /// Pads the file with silence up to now. Called once the IOProc is stopped:
    /// the stream may never have started (nothing played, output never
    /// changed) or may have stopped before the recording did.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        let frames = timeline.finish(nowHostNanos: Self.hostTimeNanos(mach_absolute_time()))
        guard frames > 0 else { return }
        writeSilence(frameCount: frames)
        Log.info("Padded \(frames) silence frames (\(Self.seconds(frames, at: sampleRate)) sec) at stop")
    }

    func writeAudio(from inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        let sampleTime = inputTime.pointee.mSampleTime
        let hostTime = inputTime.pointee.mHostTime

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else { return }

        let inputFrames = Int(buffer.frameLength)

        lock.lock()
        defer { lock.unlock() }

        // Silence first, then the rate tracker: a discontinuity is recorded at
        // the position after the silence, and only when silence really went in.
        switch timeline.advance(sampleTime: sampleTime, hostNanos: Self.hostTimeNanos(hostTime), frames: inputFrames) {
        case .first(let silenceFrames):
            Log.info("First callback after \(Self.seconds(silenceFrames, at: sampleRate)) sec, sampleTime=\(Int(sampleTime)), frames=\(inputFrames)")
            if silenceFrames > 0 {
                writeSilence(frameCount: silenceFrames)
                Log.info("Prepended \(silenceFrames) silence frames (\(Self.seconds(silenceFrames, at: sampleRate)) sec)")
                rateTracker.noteDiscontinuity(framePosition: totalFramesWritten)
            }

        case .contiguous:
            break

        case .gap(let fill, let counted):
            measurement.restart()
            if fill > 0 {
                writeSilence(frameCount: fill)
                rateTracker.noteDiscontinuity(framePosition: totalFramesWritten)
            }
            if fill < counted {
                Log.warning("sampleTime jumped forward by \(counted) frames but wall clock allows only \(fill) (\(Self.seconds(fill, at: sampleRate)) sec) — counter discontinuity (device rebuild?), resynced")
            } else if fill > Int(sampleRate) {
                Log.info("Gap filled: \(fill) silence frames (IOProc idle \(Self.seconds(fill, at: sampleRate)) sec)")
            }

        case .backward(let frames, let fill):
            measurement.restart()
            if fill > 0 {
                writeSilence(frameCount: fill)
                rateTracker.noteDiscontinuity(framePosition: totalFramesWritten)
            }
            Log.warning("sampleTime jumped backward by \(frames) frames — counter discontinuity (device rebuild?), \(fill) silence frames by wall clock, resynced")
        }

        // Write the actual audio data (in native tap format — no conversion)
        if inputFrames > 0 {
            try? file.write(from: buffer)
            totalFramesWritten += Int64(inputFrames)
            let peak = SystemAudioCapture.peak(inputData)
            peakSinceLine = max(peakSinceLine, peak)
            if !heard, peak > 0 {
                heard = true
                Log.info("System track: first sound after \(String(format: "%.1f", Double(totalFramesWritten) / sampleRate)) sec")
            }
            if peak == 0 {
                zeroRunFrames += inputFrames
            } else {
                zeroRunFrames = 0
                if !heardSinceRestart, restarted {
                    Log.info("System track: sound again after the rebuild")
                }
                heardSinceRestart = true
            }
            switch chop.add(zero: peak == 0, frames: inputFrames) {
            case .chopped(let again, let transitions, let zeroBuffers):
                chopRebuildWanted = true
                Log.warning("Chopped call audio\(again ? " still there after the rebuild" : ""): \(transitions) zero↔sound transitions and \(zeroBuffers) all-zero buffers in the last second, \(TapChopDetector.transitionsPerSecond)+ a second for \(TapChopDetector.onsetSeconds) s")
            case .cleared:
                chopCleared = true
                Log.info("Chopped call audio gone: \(TapChopDetector.clearSeconds) s of sound without the signature")
            case nil:
                break
            }
        }

        // Continuous effective-rate monitoring: the tap keeps the
        // header rate even when the underlying device clock changes, so track
        // frames-per-wall-second and record segment boundaries for correction.
        if let newSegment = rateTracker.addCallback(
            hostNanos: Self.hostTimeNanos(hostTime),
            framePosition: totalFramesWritten
        ) {
            let fileSeconds = Double(newSegment.startFrame) / sampleRate
            Log.warning(
                "EFFECTIVE RATE CHANGE at frame \(newSegment.startFrame) "
                    + "(~\(String(format: "%.1f", fileSeconds))s in file): "
                    + "now \(Int(newSegment.rate)) Hz, header \(Int(sampleRate)) Hz — will correct at stop"
            )
        }

        callbackCount += 1
        lastCallbackHostTime = mach_absolute_time()

        // Measure actual sample rate from IOProc timing data, over callbacks
        // of one unbroken stream (the switch above restarts it at a break).
        if callbackCount == 1 { Log.debug("First frame written!") }
        if let measured = measurement.add(sampleTime: sampleTime, hostNanos: Self.hostTimeNanos(hostTime)) {
            if SystemAudioCapture.isPlausibleMeasuredRate(measured.rate) {
                measuredSampleRate = measured.rate
                Log.info("Measured sample rate: \(Int(measured.rate)) Hz (header: \(Int(sampleRate)) Hz, delta: \(String(format: "%.3f", measured.seconds)) sec, \(Int(measured.frames)) samples)")
            } else {
                Log.warning("Sample rate measurement discarded: \(Int(measured.rate)) Hz is not a plausible clock (sampleTime counter reset?), header \(Int(sampleRate)) Hz")
            }
        } else if callbackCount % 500 == 0 {
            let counts = chop.takeCounts()
            let peakDB = peakSinceLine > 0 ? String(format: "%.1f dBFS", 20 * log10(peakSinceLine)) : "zero"
            peakSinceLine = 0
            Log.debug("Callbacks: \(callbackCount), frames: \(totalFramesWritten) (\(String(format: "%.1f", Double(totalFramesWritten) / sampleRate)) sec); zero buffers \(counts.zeroBuffers), zero↔sound \(counts.transitions), peak \(peakDB)")
        }

        // Last on purpose: the file and its bookkeeping never wait for the
        // live consumer (live-transcript D3).
        liveSink?.feed(buffer)
    }

    /// Write silence in the tap's native format.
    private func writeSilence(frameCount: Int) {
        let chunkSize = 4096
        var remaining = frameCount
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, chunkSize))
            guard let silenceBuffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat,
                frameCapacity: count
            ) else { break }
            silenceBuffer.frameLength = count
            // Zero-initialized memory = silence
            try? file.write(from: silenceBuffer)
            totalFramesWritten += Int64(count)
            remaining -= Int(count)
        }
    }
}

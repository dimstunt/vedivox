import AVFoundation
import Foundation
import MediaPlayer

enum AudioTrack: String, CaseIterable, Identifiable {
    case mic = "Mic"
    case system = "System"
    case mix = "Mix"

    var id: String { rawValue }

    /// The track choice belongs to the audio that is actually loaded.
    ///
    /// Carrying «Sys» into a meeting that has no system track leaves the player
    /// in a state nothing can escape: the switcher hides itself when there is
    /// no system audio, so there is no way back; the waveform has no system
    /// peaks and falls back to flat placeholder bars; and `applyTrackVolumes`
    /// mutes the one track that does exist. Same story for «Mic» in a
    /// system-only recording.
    func clamped(hasMic: Bool, hasSystem: Bool) -> AudioTrack {
        switch self {
        case .mic: hasMic ? .mic : .mix
        case .system: hasSystem ? .system : .mix
        case .mix: .mix
        }
    }
}

@MainActor
@Observable
final class AudioPlaybackService {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var activeTrack: AudioTrack = .mix
    var hasSystemAudio = false
    var playbackRate: Float = 1.0
    /// Title shown in Now Playing info (Control Center / Touch Bar).
    var meetingTitle: String = ""

    private static let rateSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let skipInterval: TimeInterval = 15

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var micPlayer: AVAudioPlayerNode?
    private var systemPlayer: AVAudioPlayerNode?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var submixer: AVAudioMixerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var timer: Timer?
    private var seekOffset: TimeInterval = 0
    /// Incremented on each schedule to ignore stale completion callbacks.
    private var playbackGeneration: Int = 0
    /// Incremented on each load() to discard stale in-flight file opens.
    private var loadGeneration: Int = 0
    /// A seek / play that arrived while `load()` was still opening the files —
    /// a link to another meeting lands right after the switch. Without this the
    /// seek clamped to the zero duration and play found no engine.
    private var isLoading = false
    private var pendingSeek: TimeInterval?
    private var pendingPlay = false
    /// `addTarget` stacks: registering twice would make one media-key press
    /// toggle twice. Commands come off at the end of the file and go back on
    /// at the next play().
    private var remoteCommandsRegistered = false
    /// End of a fragment started by `play(from:to:)`; the timer pauses there.
    private var stopAt: TimeInterval?

    /// Box for transferring AVAudioFile across actor boundaries.
    /// AVAudioFile is thread-safe for single-reader use but not marked Sendable in SDK.
    private struct AudioFilesBox: @unchecked Sendable {
        let mic: AVAudioFile?
        let system: AVAudioFile?
    }

    /// Load one or two audio files for playback.
    /// File opens (disk I/O) happen off MainActor so UI rendering isn't blocked.
    func load(micURL: URL?, systemURL: URL? = nil) {
        stop()
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let openStart = CFAbsoluteTimeGetCurrent()
            let box = AudioFilesBox(
                mic: micURL.flatMap { try? AVAudioFile(forReading: $0) },
                system: systemURL.flatMap { try? AVAudioFile(forReading: $0) }
            )
            let openMs = Int((CFAbsoluteTimeGetCurrent() - openStart) * 1000)
            await self?.configureEngine(box: box, generation: generation, openMs: openMs)
        }
    }

    private func configureEngine(box: AudioFilesBox, generation: Int, openMs: Int) {
        guard generation == loadGeneration else { return }
        let engineStart = CFAbsoluteTimeGetCurrent()

        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode

        // Submixer → TimePitch → MainMixer
        let sub = AVAudioMixerNode()
        let tp = AVAudioUnitTimePitch()
        engine.attach(sub)
        engine.attach(tp)
        engine.connect(sub, to: tp, format: nil)
        engine.connect(tp, to: mainMixer, format: nil)
        self.submixer = sub
        self.timePitch = tp

        if let file = box.mic {
            self.micFile = file
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: sub, format: file.processingFormat)
            self.micPlayer = player
            self.duration = max(duration, Double(file.length) / file.processingFormat.sampleRate)
        }

        if let file = box.system {
            self.systemFile = file
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: sub, format: file.processingFormat)
            self.systemPlayer = player
            self.hasSystemAudio = true
            self.duration = max(duration, Double(file.length) / file.processingFormat.sampleRate)
        }

        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        self.currentTime = 0
        self.playbackRate = 1.0
        // Every other piece of load-scoped state is reset by `stop()`; the
        // track choice is the one that used to survive into a meeting that
        // does not have it (see `AudioTrack.clamped`).
        self.activeTrack = activeTrack.clamped(
            hasMic: box.mic != nil, hasSystem: box.system != nil
        )

        // Build the graph but leave the hardware alone: a started-but-idle
        // engine keeps an output IO running in coreaudiod for every open
        // meeting — including the one being recorded, which is auto-selected.
        // `play()` starts it.
        engine.prepare()

        applyTrackVolumes()
        setupRemoteCommands()
        updateNowPlayingInfo()

        let engineMs = Int((CFAbsoluteTimeGetCurrent() - engineStart) * 1000)
        Log.info("[Perf][MeetingSwitch] audio setup: open=\(openMs)ms engine=\(engineMs)ms (off-MainActor for open)")

        isLoading = false
        if let time = pendingSeek { seek(to: time) }
        if pendingPlay { play() }
        pendingSeek = nil
        pendingPlay = false
    }

    /// Whether the engine is driving the output device right now. The
    /// footprint check for the lifecycle test; the UI has no use for it.
    var isEngineRunning: Bool { engine?.isRunning ?? false }

    func play() {
        guard let engine else {
            if isLoading { pendingPlay = true }
            return
        }
        if !isPlaying {
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    Log.error("Failed to start engine: \(error.localizedDescription)")
                    return
                }
            }
            schedulePlayback(from: currentTime)
            isPlaying = true
            startTimer()
            setupRemoteCommands()
            updateNowPlayingInfo()
        }
    }

    /// Plays one stretch and pauses at its end (the listen queue's fragments
    /// and candidate samples).
    func play(from start: TimeInterval, to end: TimeInterval) {
        stopAt = end
        seek(to: start)
        play()
    }

    func pause() {
        stopAt = nil
        micPlayer?.pause()
        systemPlayer?.pause()
        updateCurrentTime()
        // Release the device, keep the graph and the position.
        engine?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        if isLoading {
            pendingSeek = time
            return
        }
        let clamped = max(0, min(time, duration))
        currentTime = clamped
        if isPlaying {
            // Invalidate old completion callbacks before stopping
            playbackGeneration += 1
            micPlayer?.stop()
            systemPlayer?.stop()
            schedulePlayback(from: clamped)
            startTimer()
        }
        updateNowPlayingInfo()
    }

    /// The output device changed under the engine (headphones off, AirPods
    /// gone): macOS stops it and drops the scheduled audio, while the button
    /// kept saying "playing". Restart in place while playing; on
    /// pause the device is already released and `play()` starts it anew.
    func handleConfigurationChange() {
        guard isPlaying, let engine else { return }
        let position = currentTime
        do {
            try engine.start()
        } catch {
            Log.error("Playback: restart after output change failed: \(error.localizedDescription)")
            isPlaying = false
            stopTimer()
            updateNowPlayingInfo()
            return
        }
        seek(to: position)
        Log.info("Playback: output configuration changed — restarting at \(String(format: "%.1f", position)) s")
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        isLoading = false
        pendingSeek = nil
        pendingPlay = false
        stopAt = nil
        micPlayer?.stop()
        systemPlayer?.stop()
        engine?.stop()
        if let micPlayer { engine?.detach(micPlayer) }
        if let systemPlayer { engine?.detach(systemPlayer) }
        if let submixer { engine?.detach(submixer) }
        if let timePitch { engine?.detach(timePitch) }
        engine = nil
        micPlayer = nil
        systemPlayer = nil
        submixer = nil
        timePitch = nil
        micFile = nil
        systemFile = nil
        isPlaying = false
        hasSystemAudio = false
        stopTimer()
        currentTime = 0
        duration = 0
        tearDownRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func setTrack(_ track: AudioTrack) {
        activeTrack = track
        applyTrackVolumes()
    }

    func setRate(_ rate: Float) {
        let clamped = max(Self.rateSteps.first!, min(rate, Self.rateSteps.last!))
        timePitch?.rate = clamped
        playbackRate = clamped
    }

    func cycleRate() {
        guard let nextIndex = Self.rateSteps.firstIndex(where: { $0 > playbackRate }) else {
            setRate(Self.rateSteps.first!)
            return
        }
        setRate(Self.rateSteps[nextIndex])
    }

    // MARK: - Now Playing & Remote Commands

    private func setupRemoteCommands() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seek(to: self.currentTime + Self.skipInterval)
            }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seek(to: self.currentTime - Self.skipInterval)
            }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func tearDownRemoteCommands() {
        remoteCommandsRegistered = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = meetingTitle.isEmpty ? "Vedivox" : meetingTitle
        info[MPMediaItemPropertyArtist] = "Vedivox"
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // On macOS MediaRemote reads «is playing» from here, not from the rate:
        // without it Vedivox never looked like a player dictation could pause.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - Private

    private func schedulePlayback(from time: TimeInterval) {
        playbackGeneration += 1
        seekOffset = time

        if let micPlayer, let micFile {
            micPlayer.stop()
            let sampleRate = micFile.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(time * sampleRate)
            let totalFrames = micFile.length
            let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))
            if framesToPlay > 0 {
                micPlayer.scheduleSegment(
                    micFile,
                    startingFrame: startFrame,
                    frameCount: framesToPlay,
                    at: nil
                )
                micPlayer.play()
            }
        }

        if let systemPlayer, let systemFile {
            systemPlayer.stop()
            let sampleRate = systemFile.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(time * sampleRate)
            let totalFrames = systemFile.length
            let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))
            if framesToPlay > 0 {
                systemPlayer.scheduleSegment(
                    systemFile,
                    startingFrame: startFrame,
                    frameCount: framesToPlay,
                    at: nil
                )
                systemPlayer.play()
            }
        }
    }

    private func applyTrackVolumes() {
        switch activeTrack {
        case .mic:
            micPlayer?.volume = 1.0
            systemPlayer?.volume = 0.0
        case .system:
            micPlayer?.volume = 0.0
            systemPlayer?.volume = 1.0
        case .mix:
            micPlayer?.volume = 1.0
            systemPlayer?.volume = 1.0
        }
    }

    private func updateCurrentTime() {
        // Try mic player first, fall back to system player
        // (mic may finish before system if it's shorter)
        var elapsed: TimeInterval?

        if let micPlayer, let micFile,
           let nodeTime = micPlayer.lastRenderTime,
           nodeTime.isSampleTimeValid,
           let playerTime = micPlayer.playerTime(forNodeTime: nodeTime) {
            elapsed = Double(playerTime.sampleTime) / micFile.processingFormat.sampleRate
        }

        if elapsed == nil,
           let systemPlayer, let systemFile,
           let nodeTime = systemPlayer.lastRenderTime,
           nodeTime.isSampleTimeValid,
           let playerTime = systemPlayer.playerTime(forNodeTime: nodeTime) {
            elapsed = Double(playerTime.sampleTime) / systemFile.processingFormat.sampleRate
        }

        if let elapsed {
            currentTime = seekOffset + max(0, elapsed)
        }

        if let stopAt, currentTime >= stopAt, currentTime < duration {
            pause()
            return
        }

        // Auto-stop when we reach the end
        if currentTime >= duration {
            currentTime = duration
            micPlayer?.stop()
            systemPlayer?.stop()
            isPlaying = false
            stopTimer()
            engine?.pause()
            // At the end there is nothing to resume, so Vedivox gives Now Playing
            // up. Merely «paused», it stayed the source macOS reports even after
            // Spotify resumed, and dictation then paused nothing (2026-10-26).
            // A manual pause keeps it: the media key must still resume Vedivox.
            // play() claims it again. Clearing the info alone was not enough
            // when Spotify kept playing throughout: MediaRemote went on naming
            // Vedivox until Spotify changed state itself — presumably because Vedivox
            // still had command targets, so they come off too.
            tearDownRemoteCommands()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

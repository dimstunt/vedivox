import Foundation

/// Live text of the meeting being recorded.
///
/// Two streams — microphone and system audio — each with a tap sink, a bounded
/// backlog and a recogniser. One loop moves audio from the backlogs to the
/// recognisers and keeps the text they return. Nothing here touches the files
/// being recorded, and nothing is written to the database: the text lives in
/// this object until the recording stops.
actor MeetingLiveTranscript {
    static let enabledKey = "liveTranscriptEnabled"

    /// Settings → Recording → «Live transcript while recording», on by
    /// default. Read when a recording starts.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    /// Why there may be no text: an empty answer from a model still loading
    /// must not read as «nobody spoke».
    enum Readiness: String, Sendable {
        case ready, loading, unavailable
    }

    struct Snapshot: Sendable {
        let log: LiveTranscriptLog
        /// Who each voice key of the log reads as right now.
        let speakers: [LiveSpeaker]
        let readiness: Readiness
        /// Seconds since the recording started.
        let elapsed: TimeInterval
        /// The most audio either track lost to a recogniser that fell behind.
        let droppedSeconds: TimeInterval
    }

    private struct Stream {
        let track: SegmentSource
        let backlog: LiveAudioBacklog
        let recogniser: any LiveRecognising
        var audioSeconds = 0.0
        var modelSeconds = 0.0
        var maxLagSeconds = 0.0
    }

    /// Attached to the captures before they start; see `AudioSessionManager.setLiveSinks`.
    nonisolated let micSink: LiveAudioSink
    nonisolated let systemSink: LiveAudioSink

    /// The loop's period. Text comes a window at a time anyway, and a wake-up
    /// per tap buffer (~100 a second on the system track) would be work for
    /// nothing.
    static let pollInterval: Duration = .milliseconds(250)
    /// At most 5 s of audio per hand-over, so one track catching up on a
    /// backlog does not keep the other waiting.
    static let maxBlockSamples = 5 * 16000
    private static let reportInterval: TimeInterval = 60

    /// A precise pass over the last so many seconds of the recording's files
    /// nil — it could not be made.
    typealias Refiner = @Sendable (_ tail: TimeInterval) async -> LiveTailAnalysis?

    /// How often a precise pass runs by itself, and how far back it looks.
    /// Three minutes name people almost as well as five (94.9 % of the seconds
    /// labelled right against 95.5 %) for 4.7 s of work instead of 7.6 s;
    /// two minutes fall to 92.8 % (VedivoxBench/LiveSpeakersBench, 2026-11-09).
    static let passInterval: Duration = .seconds(60)
    static let tailSeconds: TimeInterval = 180
    /// The longest tail a reader may ask for: a pass must stay a matter of seconds.
    static let maxTailSeconds: TimeInterval = 600

    private var refiner: Refiner?
    private let passInterval: Duration
    private var passLoop: Task<Void, Never>?
    /// The pass in flight: a second one never starts over it.
    private var pass: Task<Void, Never>?
    private var passes = (count: 0, seconds: 0.0, maxSeconds: 0.0)

    private var streams: [Stream]
    private var log = LiveTranscriptLog()
    /// Who is who on the call track, from one precise pass to the next. In
    /// memory only, like the text.
    private var speakers = LiveSpeakerBook()
    private let clock: @Sendable () -> TimeInterval
    private var origin: TimeInterval?
    private var lastReport: TimeInterval = 0
    private var feedLoop: Task<Void, Never>?

    /// `clock` stamps captured audio; monotonic, so a wall-clock jump mid-call
    /// cannot reorder the text.
    init(
        mic: any LiveRecognising,
        system: any LiveRecognising,
        passInterval: Duration = MeetingLiveTranscript.passInterval,
        capacity: Int = LiveAudioBacklog.defaultCapacity,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let backlogs = (mic: LiveAudioBacklog(capacity: capacity), system: LiveAudioBacklog(capacity: capacity))
        micSink = Self.sink(into: backlogs.mic, clock: clock)
        systemSink = Self.sink(into: backlogs.system, clock: clock)
        streams = [
            Stream(track: .mic, backlog: backlogs.mic, recogniser: mic),
            Stream(track: .system, backlog: backlogs.system, recogniser: system),
        ]
        self.passInterval = passInterval
        self.clock = clock
    }

    private static func sink(into backlog: LiveAudioBacklog, clock: @escaping @Sendable () -> TimeInterval) -> LiveAudioSink {
        LiveAudioSink(
            onSamples: { backlog.push($0, capturedAt: clock()) },
            onFeedDuration: { backlog.noteFeed(seconds: $0) }
        )
    }

    /// The recording has started: now is second zero, the clock its marks use.
    func begin() {
        guard feedLoop == nil else { return }
        let now = clock()
        origin = now
        lastReport = now
        for recogniser in streams.map(\.recogniser) {
            Task { await recogniser.prepare() }
        }
        feedLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.drain() != nil else { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        let interval = passInterval
        passLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, await self?.refine(last: Self.tailSeconds) != nil else { return }
            }
        }
    }

    /// How precise passes are made — known once the recording's files exist.
    func setRefiner(_ refiner: @escaping Refiner) {
        self.refiner = refiner
    }

    /// A precise pass now, over the last `tail` seconds: the regular pipeline
    /// reads the tail of the files being recorded, and what it finds replaces
    /// the quick text of that stretch. Returns when the text is in the log.
    /// A pass already running is waited for instead of doubled; a pass that
    /// fails leaves the quick text as it was.
    func refine(last tail: TimeInterval) async {
        if let running = pass {
            await running.value
            return
        }
        guard let refiner, feedLoop != nil else { return }
        let length = min(max(tail, 0), Self.maxTailSeconds)
        let task = Task { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            guard let analysis = await refiner(length) else { return }
            await self?.take(analysis, seconds: ProcessInfo.processInfo.systemUptime - started)
        }
        pass = task
        await task.value
        pass = nil
    }

    private func take(_ analysis: LiveTailAnalysis, seconds: TimeInterval) {
        analysis.apply(to: &log, speakers: &speakers)
        passes.count += 1
        passes.seconds += seconds
        passes.maxSeconds = max(passes.maxSeconds, seconds)
    }

    /// The recording has stopped. Stops the feed and logs what live text cost.
    func end() async {
        guard let loop = feedLoop else { return }
        feedLoop = nil
        loop.cancel()
        passLoop?.cancel()
        passLoop = nil
        // Not waited for: the files are about to be processed whole.
        pass?.cancel()
        await loop.value
        report(always: true)
    }

    func snapshot() async -> Snapshot {
        let dropped = streams.map(\.backlog.snapshot.droppedSamples).max() ?? 0
        return Snapshot(
            log: log,
            speakers: speakers.speakers,
            readiness: await streams[0].recogniser.readiness,
            elapsed: origin.map { max(0, clock() - $0) } ?? 0,
            droppedSeconds: Double(dropped) / LiveAudioBacklog.sampleRate
        )
    }

    /// Moves everything waiting in the backlogs through the recognisers.
    private func drain() async {
        guard let origin else { return }
        for index in streams.indices {
            let stream = streams[index]
            // Not ready: the audio stays queued, bounded, so the first text
            // after the model loads covers the last half-minute, not nothing.
            guard await stream.recogniser.readiness == .ready else { continue }
            while !Task.isCancelled, let block = stream.backlog.pop(maxSamples: Self.maxBlockSamples) {
                let started = clock()
                let pieces = await stream.recogniser.append(
                    block.samples, endingAt: max(0, block.capturedAt - origin)
                )
                let now = clock()
                streams[index].audioSeconds += Double(block.samples.count) / LiveAudioBacklog.sampleRate
                streams[index].modelSeconds += now - started
                streams[index].maxLagSeconds = max(streams[index].maxLagSeconds, now - block.capturedAt)
                // Quick text is labelled by its track; who spoke on the call
                // is what a precise pass adds.
                for piece in pieces {
                    log.add(piece, track: stream.track)
                }
            }
        }
        if clock() - lastReport >= Self.reportInterval {
            report(always: false)
        }
    }

    // MARK: - Load (design D8)

    private func report(always: Bool) {
        lastReport = clock()
        if passes.count > 0 {
            PerfTrace.report(
                "live transcript passes",
                String(
                    format: "%d precise passes, %.1f s total, %.1f s slowest, %d speakers",
                    passes.count, passes.seconds, passes.maxSeconds, speakers.speakers.count
                ),
                always: always
            )
        }
        for stream in streams {
            PerfTrace.report(
                "live transcript \(stream.track.rawValue)",
                Self.summary(
                    backlog: stream.backlog.snapshot,
                    audioSeconds: stream.audioSeconds,
                    modelSeconds: stream.modelSeconds,
                    maxLagSeconds: stream.maxLagSeconds
                ),
                always: always
            )
        }
    }

    /// One track's cost since the recording started: what the recogniser got
    /// and how long it took, how deep the queue went, what was lost, and what
    /// the tap thread paid for the second consumer.
    static func summary(
        backlog: LiveAudioBacklog.Stats,
        audioSeconds: Double,
        modelSeconds: Double,
        maxLagSeconds: Double
    ) -> String {
        let rate = LiveAudioBacklog.sampleRate
        return String(
            format: "recognised %.1f s in %.2f s (%.0fx realtime), lag max %.2f s, "
                + "queue max %.1f s, dropped %.1f s of %.1f s, "
                + "tap %d calls %.1f ms total %.2f ms max",
            audioSeconds, modelSeconds, modelSeconds > 0 ? audioSeconds / modelSeconds : 0, maxLagSeconds,
            Double(backlog.maxPendingSamples) / rate, Double(backlog.droppedSamples) / rate,
            Double(backlog.pushedSamples) / rate,
            backlog.callbacks, backlog.feedSeconds * 1000, backlog.maxFeedSeconds * 1000
        )
    }
}

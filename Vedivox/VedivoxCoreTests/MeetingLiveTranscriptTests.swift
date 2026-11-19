import AVFoundation
import os
import XCTest

/// The feed loop of the meeting's live transcript on a stand-in recogniser
/// (live-transcript D4, D5, D7): what the taps deliver reaches the recogniser
/// whole and in order, waits for a model that is still loading, and is counted
/// when it has to be dropped.
final class MeetingLiveTranscriptTests: XCTestCase {

    /// Says one word for every whole second of audio it has been given, timed
    /// to that second — so what a test feeds decides what it reads back.
    private actor FakeRecogniser: LiveRecognising {
        private(set) var readiness: MeetingLiveTranscript.Readiness
        private(set) var received: [Float] = []
        private(set) var appendSizes: [Int] = []
        private(set) var prepared = false
        private var spoken = 0

        init(_ readiness: MeetingLiveTranscript.Readiness = .ready) {
            self.readiness = readiness
        }

        func become(_ newReadiness: MeetingLiveTranscript.Readiness) {
            readiness = newReadiness
        }

        func prepare() async {
            prepared = true
        }

        func append(_ samples: [Float], endingAt elapsed: TimeInterval) async -> [LivePiece] {
            received.append(contentsOf: samples)
            appendSizes.append(samples.count)
            var pieces: [LivePiece] = []
            while (spoken + 1) * 16000 <= received.count {
                pieces.append(LivePiece(start: elapsed - 1, end: elapsed, text: "слово\(spoken)"))
                spoken += 1
            }
            return pieces
        }
    }

    private final class TestClock: Sendable {
        private let now = OSAllocatedUnfairLock(initialState: 100.0)
        var read: @Sendable () -> TimeInterval { { self.now.withLock { $0 } } }
        func set(_ value: TimeInterval) { now.withLock { $0 = value } }
    }

    private func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    /// 16 kHz mono, the format the sink converts to — so samples pass through unchanged.
    private func feed(_ samples: [Float], to sink: LiveAudioSink, batch: Int = 1600) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        for start in stride(from: 0, to: samples.count, by: batch) {
            let slice = Array(samples[start ..< min(start + batch, samples.count)])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice.count))!
            buffer.frameLength = AVAudioFrameCount(slice.count)
            slice.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
            sink.feed(buffer)
        }
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    func testAudioFedToTheSinkReachesTheRecogniserWholeAndInOrder() async {
        let mic = FakeRecogniser()
        let live = MeetingLiveTranscript(mic: mic, system: FakeRecogniser())
        await live.begin()

        feed(ramp(0 ..< 16000), to: live.micSink)
        await waitUntil("the mic audio") { await mic.received.count == 16000 }

        let received = await mic.received
        XCTAssertEqual(received, ramp(0 ..< 16000))
        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.droppedSeconds, 0)
        XCTAssertEqual(snapshot.readiness, .ready)
        let prepared = await mic.prepared
        XCTAssertTrue(prepared)
        await live.end()
    }

    func testAudioWaitsForARecogniserThatIsStillLoadingAndIsCaughtUpOnce() async {
        let mic = FakeRecogniser(.loading)
        let live = MeetingLiveTranscript(mic: mic, system: FakeRecogniser())
        await live.begin()

        feed(ramp(0 ..< 32000), to: live.micSink)
        try? await Task.sleep(for: .milliseconds(700))
        let whileLoading = await mic.received
        XCTAssertEqual(whileLoading, [], "nothing is fed to a model that is not ready")
        let loading = await live.snapshot()
        XCTAssertEqual(loading.readiness, .loading)

        await mic.become(.ready)
        await waitUntil("the catch-up") { await mic.received.count == 32000 }
        let received = await mic.received
        XCTAssertEqual(received, ramp(0 ..< 32000))
        await live.end()
    }

    func testAudioOfARecogniserThatNeverGetsReadyIsDroppedAndCounted() async {
        let mic = FakeRecogniser(.unavailable)
        let live = MeetingLiveTranscript(mic: mic, system: FakeRecogniser(), capacity: 16000)
        await live.begin()

        feed(ramp(0 ..< 48000), to: live.micSink)
        try? await Task.sleep(for: .milliseconds(400))

        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.droppedSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.readiness, .unavailable)
        let received = await mic.received
        XCTAssertEqual(received, [])
        await live.end()
    }

    func testACatchUpIsFedInBlocksSoOtherStreamsGetTheirTurn() async {
        let mic = FakeRecogniser(.loading)
        let live = MeetingLiveTranscript(mic: mic, system: FakeRecogniser())
        await live.begin()

        feed(ramp(0 ..< 12 * 16000), to: live.micSink)
        await mic.become(.ready)
        await waitUntil("the catch-up") { await mic.received.count == 12 * 16000 }

        let sizes = await mic.appendSizes
        XCTAssertGreaterThan(sizes.count, 1)
        XCTAssertTrue(sizes.allSatisfy { $0 <= MeetingLiveTranscript.maxBlockSamples })
        await live.end()
    }

    func testDraftGrowthBecomesTurnsOnTheRightTrackAndClock() async {
        let clock = TestClock()
        let live = MeetingLiveTranscript(mic: FakeRecogniser(), system: FakeRecogniser(), clock: clock.read)
        await live.begin() // second zero is clock 100

        clock.set(104)
        feed(ramp(0 ..< 16000), to: live.systemSink)
        await waitUntil("the system entry") { await live.snapshot().log.entries.count == 1 }
        clock.set(108)
        feed(ramp(0 ..< 16000), to: live.micSink)
        await waitUntil("the mic entry") { await live.snapshot().log.entries.count == 2 }

        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.elapsed, 8, accuracy: 0.001)
        let turns = snapshot.log.turns()
        XCTAssertEqual(turns.map(\.track), [.system, .mic])
        XCTAssertEqual(turns.map(\.text), ["слово0", "слово0"])
        XCTAssertEqual(turns.map(\.start), [3, 7])
        XCTAssertEqual(turns.map(\.end), [4, 8])
        await live.end()
    }

    // MARK: Precise passes

    /// A pass that found one line of a stranger on the call track.
    private func found(_ text: String, from: Double = 0, to: Double = 60) -> LiveTailAnalysis {
        var analysis = LiveTailAnalysis()
        analysis.system = .init(from: from, to: to, lines: [.init(start: from + 1, end: from + 5, text: text, label: "speaker_1")])
        analysis.voices = ["speaker_1": .init(centroid: [1, 0, 0], seconds: 30)]
        return analysis
    }

    func testAPassOnDemandReplacesTheQuickTextAndNamesTheSpeaker() async {
        let clock = TestClock()
        let live = MeetingLiveTranscript(
            mic: FakeRecogniser(), system: FakeRecogniser(), passInterval: .seconds(3600), clock: clock.read
        )
        let asked = OSAllocatedUnfairLock(initialState: [TimeInterval]())
        let precise = found("точный текст")
        await live.setRefiner { tail in
            asked.withLock { $0.append(tail) }
            return precise
        }
        await live.begin()
        clock.set(104)
        feed(ramp(0 ..< 16000), to: live.systemSink)
        await waitUntil("the quick entry") { await live.snapshot().log.entries.count == 1 }

        await live.refine(last: 5000)

        let snapshot = await live.snapshot()
        XCTAssertEqual(asked.withLock { $0 }, [MeetingLiveTranscript.maxTailSeconds], "a tail is never longer than the limit")
        XCTAssertEqual(
            snapshot.log.turns(speakers: snapshot.speakers).map { "\($0.speaker.name): \($0.text)" },
            ["Speaker 1: точный текст"]
        )
        await live.end()
    }

    func testPassesRunOnTheirOwnWhileTheRecordingRuns() async {
        let live = MeetingLiveTranscript(mic: FakeRecogniser(), system: FakeRecogniser(), passInterval: .milliseconds(30))
        let asked = OSAllocatedUnfairLock(initialState: [TimeInterval]())
        await live.setRefiner { tail in
            asked.withLock { $0.append(tail) }
            return nil
        }
        await live.begin()
        await waitUntil("two passes") { asked.withLock { $0.count } >= 2 }
        XCTAssertEqual(asked.withLock { $0 }.first, MeetingLiveTranscript.tailSeconds)

        await live.end()
        let stopped = asked.withLock { $0.count }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(asked.withLock { $0.count }, stopped + 1, "no passes after the recording stops")
    }

    func testASecondPassDoesNotStartOverOneThatIsRunning() async {
        let live = MeetingLiveTranscript(mic: FakeRecogniser(), system: FakeRecogniser(), passInterval: .seconds(3600))
        let started = OSAllocatedUnfairLock(initialState: 0)
        let precise = found("один раз")
        await live.setRefiner { _ in
            started.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(200))
            return precise
        }
        await live.begin()

        async let first: Void = live.refine(last: 60)
        async let second: Void = live.refine(last: 60)
        _ = await (first, second)

        XCTAssertEqual(started.withLock { $0 }, 1, "the second reader waited for the first pass")
        let entries = await live.snapshot().log.entries
        XCTAssertEqual(entries.map(\.text), ["один раз"], "and both returned with its text in the log")
        await live.end()
    }

    func testAPassThatFailsLeavesTheQuickText() async {
        let clock = TestClock()
        let live = MeetingLiveTranscript(
            mic: FakeRecogniser(), system: FakeRecogniser(), passInterval: .seconds(3600), clock: clock.read
        )
        await live.setRefiner { _ in nil }
        await live.begin()
        clock.set(104)
        feed(ramp(0 ..< 16000), to: live.systemSink)
        await waitUntil("the quick entry") { await live.snapshot().log.entries.count == 1 }

        await live.refine(last: 60)

        let entries = await live.snapshot().log.entries
        XCTAssertEqual(entries.map(\.text), ["слово0"])
        await live.end()
    }

    func testWithoutFilesToReadThereAreNoPasses() async {
        let live = MeetingLiveTranscript(mic: FakeRecogniser(), system: FakeRecogniser(), passInterval: .milliseconds(20))
        await live.begin()
        await live.refine(last: 60)
        try? await Task.sleep(for: .milliseconds(80))
        let entries = await live.snapshot().log.entries
        XCTAssertEqual(entries, [])
        await live.end()
    }

    func testAudioCapturedBeforeTheStartIsNotLostAndSitsAtSecondZero() async {
        let clock = TestClock()
        let mic = FakeRecogniser()
        let live = MeetingLiveTranscript(mic: mic, system: FakeRecogniser(), clock: clock.read)

        clock.set(99.5) // the tap delivers before the recording's start is fixed
        feed(ramp(0 ..< 16000), to: live.micSink)
        clock.set(100)
        await live.begin()

        await waitUntil("the early audio") { await mic.received.count == 16000 }
        await waitUntil("its entry") { await live.snapshot().log.entries.count == 1 }
        let entry = await live.snapshot().log.entries[0]
        XCTAssertEqual(entry.end, 0, "the recogniser is told second zero, not a negative time")
        await live.end()
    }

    func testEndStopsTheFeed() async {
        let mic = FakeRecogniser()
        let live = MeetingLiveTranscript(mic: mic, system: FakeRecogniser())
        await live.begin()
        await live.end()

        feed(ramp(0 ..< 16000), to: live.micSink)
        try? await Task.sleep(for: .milliseconds(400))
        let received = await mic.received
        XCTAssertEqual(received, [])
    }

    func testEnabledUnlessSwitchedOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "live-transcript-\(UUID().uuidString)"))
        XCTAssertTrue(MeetingLiveTranscript.isEnabled(defaults: defaults))
        defaults.set(false, forKey: MeetingLiveTranscript.enabledKey)
        XCTAssertFalse(MeetingLiveTranscript.isEnabled(defaults: defaults))
    }

    func testSummaryNamesLoadQueueLossAndTapCost() {
        let stats = LiveAudioBacklog.Stats(
            callbacks: 1200, feedSeconds: 0.048, maxFeedSeconds: 0.0021,
            pushedSamples: 16000 * 120, droppedSamples: 16000 * 3, maxPendingSamples: 16000 * 30
        )
        let summary = MeetingLiveTranscript.summary(
            backlog: stats, audioSeconds: 117, modelSeconds: 4.5, maxLagSeconds: 0.42
        )
        XCTAssertEqual(
            summary,
            "recognised 117.0 s in 4.50 s (26x realtime), lag max 0.42 s, "
                + "queue max 30.0 s, dropped 3.0 s of 120.0 s, tap 1200 calls 48.0 ms total 2.10 ms max"
        )
    }
}

import AVFoundation
import XCTest

/// `vedivox audio compact` core (compact-meeting-storage § 3): re-encodes 128k tracks in
/// place, never touches the database, skips what is busy or already compact, and keeps
/// the original whenever the copy does not check out.
final class AudioCompactorTests: XCTestCase {
    private var meetings: MeetingRepository!
    private var root: URL!

    override func setUp() async throws {
        meetings = MeetingRepository(db: try makeTestDB())
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-compact-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testTracksAreRecompressedInPlaceAndASecondRunChangesNothing() async throws {
        let meeting = try await saveMeeting(status: .done)
        let before = try await meetings.find(meeting.id)

        let report = await compactor(dryRun: false).run(meetingIds: [meeting.id])

        XCTAssertEqual(report.compacted.count, 2)
        XCTAssertTrue(report.complete)
        XCTAssertLessThan(report.bytesAfter, report.bytesBefore)
        XCTAssertEqual(files(meeting.id), ["mic.m4a", "system.m4a"], "same names, no temp left")
        for name in ["mic.m4a", "system.m4a"] {
            let file = try AVAudioFile(forReading: dir(meeting.id).appendingPathComponent(name))
            XCTAssertEqual(file.fileFormat.sampleRate, 24000)
        }
        let after = try await meetings.find(meeting.id)
        XCTAssertEqual(after?.status, before?.status)
        XCTAssertEqual(after?.micAudioPath, before?.micAudioPath)

        let snapshot = try stamps(meeting.id)
        let again = await compactor(dryRun: false).run(meetingIds: [meeting.id])
        XCTAssertTrue(again.compacted.isEmpty)
        XCTAssertEqual(again.alreadyCompact, 2)
        XCTAssertEqual(try stamps(meeting.id), snapshot)
    }

    func testDryRunChangesNoByte() async throws {
        let meeting = try await saveMeeting(status: .done)
        let snapshot = try stamps(meeting.id)

        let report = await compactor(dryRun: true).run(meetingIds: [meeting.id])

        XCTAssertEqual(report.compacted.count, 2)
        XCTAssertGreaterThan(report.bytesBefore, report.bytesAfter)
        XCTAssertEqual(try stamps(meeting.id), snapshot)
    }

    func testBusyMeetingIsSkipped() async throws {
        let meeting = try await saveMeeting(status: .transcribing)
        let snapshot = try stamps(meeting.id)

        let report = await compactor(dryRun: false).run(meetingIds: [meeting.id])

        XCTAssertEqual(report.meetingsBusy, 1)
        XCTAssertTrue(report.compacted.isEmpty)
        XCTAssertEqual(try stamps(meeting.id), snapshot)
    }

    func testCopyFailingVerificationLeavesTheOriginal() async throws {
        let meeting = try await saveMeeting(status: .done)
        let snapshot = try stamps(meeting.id)
        var broken = compactor(dryRun: false)
        // A copy a third of the length: verify must refuse it.
        broken.compress = { _, output in try Self.writeAAC(seconds: 1, bitrate: 64000, to: output) }

        let report = await broken.run(meetingIds: [meeting.id])

        XCTAssertEqual(report.failed.count, 2)
        XCTAssertFalse(report.complete)
        XCTAssertFalse(report.response.ok)
        XCTAssertEqual(try stamps(meeting.id), snapshot)
        XCTAssertEqual(files(meeting.id), ["mic.m4a", "system.m4a"])
    }

    /// a trim that rewrites the track while its copy is being encoded.
    /// A cut under verify's 5 % tolerance used to pass, and the untrimmed copy
    /// replaced the trimmed track.
    func testTrackRewrittenDuringTheEncodeKeepsTheRewrite() async throws {
        let meeting = try await saveMeeting(status: .done)
        var racing = compactor(dryRun: false)
        racing.compress = { input, output in
            try await AudioConverter.compressToAAC(input: input, output: output)
            // Same audio, newer stamp: what a trim's rewrite looks like to the compactor.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: input.path)
        }

        let report = await racing.run(meetingIds: [meeting.id])

        XCTAssertEqual(report.failed.count, 2)
        XCTAssertTrue(report.compacted.isEmpty)
        XCTAssertEqual(files(meeting.id), ["mic.m4a", "system.m4a"], "no temp left")
        for name in ["mic.m4a", "system.m4a"] {
            let file = try AVAudioFile(forReading: dir(meeting.id).appendingPathComponent(name))
            XCTAssertEqual(file.fileFormat.sampleRate, 48000, "the rewritten track stays, not the copy")
        }
    }

    func testRecordingStopsTheRunAfterTheCurrentTrack() async throws {
        let first = try await saveMeeting(status: .done)
        let second = try await saveMeeting(status: .done)
        let untouched = try stamps(second.id)
        var compactor = compactor(dryRun: false)
        let compressed = Counter()
        compactor.compress = { _ = await compressed.next()
        try await AudioConverter.compressToAAC(input: $0, output: $1) }
        // The recording starts while the first track is being re-encoded.
        compactor.isRecording = { await compressed.count > 0 }

        let report = await compactor.run(meetingIds: [first.id, second.id])

        XCTAssertEqual(report.compacted, ["\(first.id)/mic.m4a"], "system.m4a waits for the next run")
        XCTAssertEqual(report.stoppedWithRemaining, 2, "the first meeting is unfinished")
        XCTAssertEqual(try stamps(second.id), untouched)
        XCTAssertEqual(report.response.reason, "not_ready")
    }

    func testASecondRunWhileOneIsGoingIsRefused() async throws {
        let meeting = try await saveMeeting(status: .done)
        let gate = Gate()
        var slow = compactor(dryRun: false)
        slow.compress = { input, output in
            await gate.pass()
            try await AudioConverter.compressToAAC(input: input, output: output)
        }

        let running = Task { await slow.run(meetingIds: [meeting.id]) }
        await gate.waitUntilReached()
        let second = await compactor(dryRun: false).run(meetingIds: [meeting.id])
        await gate.open()
        let first = await running.value

        XCTAssertTrue(second.alreadyRunning)
        XCTAssertEqual(second.meetingsSeen, 0, "the refused run looks at nothing")
        XCTAssertFalse(second.response.ok)
        XCTAssertEqual(second.response.reason, "not_ready")
        XCTAssertEqual(first.compacted.count, 2)
        XCTAssertEqual(files(meeting.id), ["mic.m4a", "system.m4a"])
    }

    // MARK: - Shift check

    func testShiftedCopyIsCaughtAndAnAlignedOneIsNot() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        let shifted = root.appendingPathComponent("shifted.wav")
        let encoded = root.appendingPathComponent("encoded.m4a")
        try Self.writeSpeechLike(to: source, leadingSilence: 0)
        try Self.writeSpeechLike(to: shifted, leadingSilence: 0.03)
        try await AudioConverter.compressToAAC(input: source, output: encoded)

        let off = try await AudioConverter.shift(of: shifted, against: source)
        let aligned = try await AudioConverter.shift(of: encoded, against: source)

        XCTAssertEqual(off, 0.03, accuracy: 0.0101)
        XCTAssertGreaterThan(abs(off), AudioCompactor.maxShift)
        XCTAssertLessThanOrEqual(abs(aligned), AudioCompactor.maxShift)
    }

    // MARK: - Helpers

    private actor Counter {
        private var value = 0
        var count: Int { value }
        func next() -> Int { defer { value += 1 }
        return value }
    }

    /// Holds `compress` until the test has made its second call.
    private actor Gate {
        private var reached = false
        private var opened = false
        // Bounded at 10 s: a regression fails the assertions instead of hanging the run.
        func pass() async {
            reached = true
            for _ in 0 ..< 1000 where !opened { try? await Task.sleep(for: .milliseconds(10)) }
        }

        func waitUntilReached() async {
            for _ in 0 ..< 1000 where !reached { try? await Task.sleep(for: .milliseconds(10)) }
        }

        func open() { opened = true }
    }

    private func compactor(dryRun: Bool) -> AudioCompactor {
        let repo = meetings!
        return AudioCompactor(
            audioRoot: root, dryRun: dryRun,
            isRecording: { false },
            status: { try? await repo.find($0)?.status }
        )
    }

    private func saveMeeting(status: MeetingStatus) async throws -> Meeting {
        var meeting = makeMeeting(status: status)
        try FileManager.default.createDirectory(at: dir(meeting.id), withIntermediateDirectories: true)
        for name in ["mic.m4a", "system.m4a"] {
            try Self.writeAAC(seconds: 3, bitrate: 128_000, to: dir(meeting.id).appendingPathComponent(name))
        }
        meeting.micAudioPath = dir(meeting.id).appendingPathComponent("mic.m4a").path
        meeting.systemAudioPath = dir(meeting.id).appendingPathComponent("system.m4a").path
        try await meetings.save(meeting)
        return meeting
    }

    private func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func files(_ id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir(id).path)) ?? []).sorted()
    }

    /// Size and mtime of every file: equal snapshots mean no byte was touched.
    private func stamps(_ id: String) throws -> [String] {
        try files(id).map { name in
            let attributes = try FileManager.default.attributesOfItem(atPath: dir(id).appendingPathComponent(name).path)
            return "\(name) \(attributes[.size]!) \((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
    }

    /// Noise at 48 kHz: the encoder spends the whole bitrate on it, like on a real track.
    private static func writeAAC(seconds: Double, bitrate: Int, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ])
        let frames = AVAudioFrameCount(seconds * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0 ..< Int(frames) { buffer.floatChannelData![0][i] = Float.random(in: -0.3 ... 0.3) }
        try file.write(from: buffer)
    }

    /// Noise under a slow, irregular envelope, so 10 ms envelopes have a shape to align.
    private static func writeSpeechLike(to url: URL, leadingSilence: Double) throws {
        let rate = 48000.0
        let lead = Int(leadingSilence * rate)
        let frames = lead + Int(4 * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var seed: UInt32 = 12345
        for i in 0 ..< frames {
            guard i >= lead else { buffer.floatChannelData![0][i] = 0
            continue }
            let t = Double(i - lead) / rate
            let shape = abs(sin(2 * .pi * 1.7 * t) * sin(2 * .pi * 0.43 * t))
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 8) / Float(1 << 24) - 0.5
            buffer.floatChannelData![0][i] = noise * Float(shape)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

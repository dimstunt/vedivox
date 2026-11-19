import FluidAudio
import XCTest

/// What a FluidAudio bump does to the text: Parakeet over every
/// scenario_basic track and the streaming Nemotron over the first minute of
/// each mic track, written to `VEDIVOX_BENCH_DUMP_DIR`, plus how long each model
/// takes to load. Run once per version and diff the dumps with
/// `scripts/asr_drift.py`; Parakeet is deterministic, so any difference is the
/// version. The texts are real meetings — they stay in the dump folder.
///
///     TEST_RUNNER_VEDIVOX_BENCH_DUMP_DIR=<dir> xcodebuild test -project Vedivox/Vedivox.xcodeproj \
///       -scheme VedivoxBench -only-testing:VedivoxBench/AsrDriftBench
final class AsrDriftBench: XCTestCase {
    func testDump() async throws {
        guard let dump = ProcessInfo.processInfo.environment["VEDIVOX_BENCH_DUMP_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_VEDIVOX_BENCH_DUMP_DIR")
        }
        guard ScenarioBenchRunner.fixtureAudioPresent("scenario_basic") else {
            throw XCTSkip("scenario_basic audio not present")
        }
        let out = URL(fileURLWithPath: dump)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let audio = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".backlog/fixtures/scenario_basic/audio")
        let tracks = try FileManager.default.contentsOfDirectory(atPath: audio.path)
            .filter { $0.hasSuffix(".mic.m4a") || $0.hasSuffix(".system.m4a") }
            .sorted()
        var timings: [String] = []

        var started = Date()
        let parakeet = TranscriptionService()
        try await parakeet.initialize()
        timings.append(String(format: "load parakeet %.1f s", Date().timeIntervalSince(started)))

        started = Date()
        let diarizer = DiarizationService()
        try await diarizer.prewarm()
        timings.append(String(format: "load diarizer %.1f s", Date().timeIntervalSince(started)))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-drift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for track in tracks {
            let wav = tmp.appendingPathComponent("\(track).wav")
            try await AudioConverter.convertTo16kHzMonoWAV(input: audio.appendingPathComponent(track), output: wav)
            let result = try await parakeet.transcribe(wav)
            try result.text.write(to: out.appendingPathComponent("parakeet-\(track).txt"), atomically: true, encoding: .utf8)
            timings.append(String(format: "parakeet %@ %.2f s for %.0f s", track, result.elapsed, result.duration))
            // Boundaries, for where the pipeline's speech time comes from (.seg: start end).
            try result.segments.map { String(format: "%.3f %.3f", $0.startTime, $0.endTime) }.joined(separator: "\n")
                .write(to: out.appendingPathComponent("segments-\(track).seg"), atomically: true, encoding: .utf8)
            if track.hasSuffix(".system.m4a") {
                let diarized = try await diarizer.diarize(audioURL: wav)
                try diarized.segments.map { String(format: "%.3f %.3f %@", $0.start, $0.end, $0.speaker) }.joined(separator: "\n")
                    .write(to: out.appendingPathComponent("diar-\(track).seg"), atomically: true, encoding: .utf8)
            }
        }

        started = Date()
        let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: DictationChunkSize.default.milliseconds
        )
        let nemotron = StreamingNemotronMultilingualAsrManager()
        try await nemotron.loadModels(from: directory)
        timings.append(String(format: "load nemotron %.1f s", Date().timeIntervalSince(started)))
        for track in tracks where track.hasSuffix(".mic.m4a") {
            let samples = try LiveModelChoiceBench.samples(of: audio.appendingPathComponent(track), seconds: 60)
            started = Date()
            for offset in stride(from: 0, to: samples.count, by: 4000) {
                _ = try await nemotron.process(samples: Array(samples[offset ..< min(offset + 4000, samples.count)]))
            }
            let text = try await nemotron.finish()
            try text.write(to: out.appendingPathComponent("nemotron-\(track).txt"), atomically: true, encoding: .utf8)
            timings.append(String(format: "nemotron %@ %.2f s for 60 s", track, Date().timeIntervalSince(started)))
            await nemotron.reset()
        }
        await nemotron.cleanup()

        try timings.joined(separator: "\n").write(to: out.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
        print(timings.joined(separator: "\n"))
    }
}

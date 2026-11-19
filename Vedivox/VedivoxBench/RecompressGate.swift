import AVFoundation
import FluidAudio
import Foundation
import XCTest

/// Quality gate for re-encoding the archive with the storage preset
/// (compact-meeting-storage § 1): `scenario_basic` (128k @ 48 kHz) against
/// `scenario_basic_d` — the same tracks passed through `compressToAAC`, exactly
/// what `vedivox audio compact` will do to a stored file.
///
///     # 1.2, once: build the variant next to the original (fixtures are gitignored)
///     TEST_RUNNER_VEDIVOX_BENCH_MAKE_VARIANT=1 xcodebuild test -project Vedivox/Vedivox.xcodeproj \
///       -scheme VedivoxBench -only-testing:VedivoxBench/RecompressGateTests/testMakeVariantFixture \
///       -destination 'platform=macOS'
///     # preset A (64 kbps @ 48 kHz): add TEST_RUNNER_VEDIVOX_BENCH_VARIANT=scenario_basic_a
///     #   TEST_RUNNER_VEDIVOX_BENCH_MAX_RATE=48000
///     # 96 kbps @ 32 kHz: VARIANT=scenario_basic_96k MAX_RATE=32000 TEST_RUNNER_VEDIVOX_BENCH_BITRATE=96000
///     # 1.4 / 1.5: testTranscriptWER, testChunkEmbeddings (skip when the variant is absent)
///
/// DER (1.3) is `ScenarioBenchTests` with TEST_RUNNER_VEDIVOX_BENCH_FIXTURE=scenario_basic_d.
/// Results and the 128k re-encode control (`afconvert -d aac -b 128000`): design § 5.
final class RecompressGateTests: XCTestCase {
    private let original = "scenario_basic"
    /// TEST_RUNNER_VEDIVOX_BENCH_VARIANT: compare against another copy (e.g. a control re-encode).
    private let variant = ProcessInfo.processInfo.environment["VEDIVOX_BENCH_VARIANT"] ?? "scenario_basic_d"
    /// TEST_RUNNER_VEDIVOX_BENCH_MAX_RATE: output-rate cap for testMakeVariantFixture
    /// (48000 builds preset A, `scenario_basic_a`; default is the production preset D).
    private let maxRate = Double(ProcessInfo.processInfo.environment["VEDIVOX_BENCH_MAX_RATE"] ?? "") ?? 24000
    /// TEST_RUNNER_VEDIVOX_BENCH_BITRATE: a bitrate above the production ceiling (64 kbps), for a
    /// candidate preset; the variant is then encoded by `encodeAAC`, not `compressToAAC`.
    private let bitrate = Int(ProcessInfo.processInfo.environment["VEDIVOX_BENCH_BITRATE"] ?? "")

    /// 1.2: copy scenario.json + ground_truth, re-encode every mic/system track.
    func testMakeVariantFixture() async throws {
        guard ProcessInfo.processInfo.environment["VEDIVOX_BENCH_MAKE_VARIANT"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_VEDIVOX_BENCH_MAKE_VARIANT=1 to (re)build \(variant)")
        }
        let fm = FileManager.default
        let src = Self.fixtureDir(original), dst = Self.fixtureDir(variant)
        try fm.createDirectory(at: dst.appendingPathComponent("audio"), withIntermediateDirectories: true)
        for item in ["scenario.json", "ground_truth"] where !fm.fileExists(atPath: dst.appendingPathComponent(item).path) {
            try fm.copyItem(at: src.appendingPathComponent(item), to: dst.appendingPathComponent(item))
        }
        for track in try tracks() {
            let input = src.appendingPathComponent("audio/\(track)")
            let output = dst.appendingPathComponent("audio/\(track)")
            if let bitrate {
                try await Self.encodeAAC(input: input, output: output, rate: maxRate, bitrate: bitrate)
            } else {
                try await AudioConverter.compressToAAC(input: input, output: output, maxOutputRate: maxRate)
            }
            let stats = try AudioConverter.verify(source: input, result: output)
            log(String(format: "%@: %.2f s", track, stats.duration))
        }
    }

    /// 1.4 / 1.7: WER of the variant's transcript against the original's, per track,
    /// over the floor of inaudible perturbations. Parakeet is deterministic (a repeat
    /// gives 0), so the floor is how far an inaudible change of the input moves the
    /// text: the 128k re-encode control, ±0.5 dB and a 1-sample shift of the 16 kHz
    /// WAV the recognizer reads (after peak normalization, which would undo a gain
    /// applied before it). Gate: WER ≤ median of the floor + 2 p.p.
    func testTranscriptWER() async throws {
        try skipUnlessBothPresent()
        let asr = TranscriptionService()
        try await asr.initialize()
        let tmp = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        func wav(_ fixture: String, _ track: String) async throws -> URL {
            let url = tmp.appendingPathComponent("\(fixture)-\(track).wav")
            try await AudioConverter.convertTo16kHzMonoWAV(
                input: Self.fixtureDir(fixture).appendingPathComponent("audio/\(track)"), output: url
            )
            return url
        }
        func words(_ url: URL) async throws -> [Substring] {
            try await asr.transcribe(url).text.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let control = ScenarioBenchRunner.fixtureAudioPresent(Self.control) ? Self.control : nil
        if control == nil { log("\(Self.control) absent — floor without the re-encode control") }

        for track in try tracks() {
            let source = try await wav(original, track)
            let ref = try await words(source)
            var floor: [Double] = []
            for (name, gain, delay) in [("+0.5dB", Float(0.5), 0), ("-0.5dB", -0.5, 0), ("shift1", 0, 1)] {
                let url = tmp.appendingPathComponent("\(name)-\(track).wav")
                try Self.perturb(source, to: url, gainDB: gain, delaySamples: delay)
                floor.append(Self.wer(ref, try await words(url)))
            }
            if let control { floor.append(Self.wer(ref, try await words(try await wav(control, track)))) }
            let median = Self.median(floor)
            let wer = Self.wer(ref, try await words(try await wav(variant, track)))
            log(String(
                format: "%@: %d words, floor %@ (median %.2f%%), WER %.2f%%, over floor %+.2f p.p.",
                track, ref.count, floor.map { String(format: "%.2f%%", $0 * 100) }.joined(separator: " / "),
                median * 100, wer * 100, (wer - median) * 100
            ))
            XCTAssertLessThanOrEqual(wer - median, 0.02, "\(track): WER over the perturbation floor above 2 p.p.")
        }
    }

    /// Diagnostic for the M4 DER jump: ASR tokens longer than 5 s on the original and
    /// the variant. FluidAudio gives a zero-duration TDT token the next token's start
    /// as its end, so a token before a long silence spans all of it, and TokenGrouper
    /// keeps a punctuation token in its segment — the segment then covers the silence.
    func testLongTokens() async throws {
        try skipUnlessBothPresent()
        let asr = TranscriptionService()
        try await asr.initialize()
        let tmp = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for fixture in [original, variant] {
            for track in try tracks() {
                let wav = tmp.appendingPathComponent("\(fixture)-\(track).wav")
                try await AudioConverter.convertTo16kHzMonoWAV(
                    input: Self.fixtureDir(fixture).appendingPathComponent("audio/\(track)"), output: wav
                )
                let result = try await asr.transcribe(wav)
                for t in result.tokenTimings where t.endTime - t.startTime > 5 {
                    let seg = result.segments.first { $0.startTime <= t.startTime && t.endTime <= $0.endTime }
                    log(String(
                        format: "%@/%@: token \"%@\" %.2f–%.2f s conf %.2f; segment %.2f–%.2f \"%@\"",
                        fixture, track, t.token, t.startTime, t.endTime, t.confidence,
                        seg?.startTime ?? -1, seg?.endTime ?? -1, seg?.text ?? "-"
                    ))
                }
            }
        }
    }

    /// 1.5: chunk-window WeSpeaker embeddings (what Stage 2.5 and any future
    /// re-embedding read) of the variant against the original, same `chunkIndex`.
    func testChunkEmbeddings() async throws {
        try skipUnlessBothPresent()
        let diarizer = DiarizationService()
        let tmp = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        func chunks(_ fixture: String, _ track: String) async throws -> [ChunkEmbedding] {
            let wav = tmp.appendingPathComponent("\(fixture)-\(track).wav")
            try await AudioConverter.convertTo16kHzMonoWAV(
                input: Self.fixtureDir(fixture).appendingPathComponent("audio/\(track)"), output: wav
            )
            do {
                return try await diarizer.diarize(audioURL: wav).chunkEmbeddings ?? []
            } catch {
                log("\(fixture)/\(track): \(error)") // a near-silent mic throws noSpeechDetected
                return []
            }
        }

        for track in try tracks() {
            let a = try await chunks(original, track), b = try await chunks(variant, track)
            guard !a.isEmpty, !b.isEmpty else {
                XCTAssertEqual(a.isEmpty, b.isEmpty, "\(track): speech found on one side only")
                continue
            }
            let byIndex = Dictionary(grouping: b, by: \.chunkIndex)
            // A chunk holds up to 3 local-speaker slots whose order may differ between
            // the two runs: pair each original vector with its closest one in the window.
            let pairs = a.compactMap { c in
                byIndex[c.chunkIndex]?.max {
                    cosineSimilarity(c.embedding256, $0.embedding256) < cosineSimilarity(c.embedding256, $1.embedding256)
                }.map { (c, $0) }
            }
            guard !pairs.isEmpty else { XCTFail("\(track): no common chunkIndex")
                continue
            }
            let cos = pairs.map { Double(cosineSimilarity($0.0.embedding256, $0.1.embedding256)) }.sorted()
            let mean = cos.reduce(0, +) / Double(cos.count)
            let p5 = cos[Int(Double(cos.count - 1) * 0.05)]
            // Centroid per original cluster, over the same chunks on both sides.
            let centroids = Dictionary(grouping: pairs, by: { $0.0.speakerId }).mapValues { group in
                (cos: Double(cosineSimilarity(Self.mean(group.map { $0.0.embedding256 }), Self.mean(group.map { $0.1.embedding256 }))),
                 chunks: group.count)
            }
            // 1.7: a 1–4-window "centroid" is one or two windows, not a voice profile.
            let worst = centroids.values.filter { $0.chunks >= Self.minCentroidChunks }.map(\.cos).min() ?? 1
            log(String(
                format: "%@: %d/%d chunks paired, mean %.4f, p5 %.4f, min %.4f; centroids %@",
                track, pairs.count, a.count, mean, p5, cos[0],
                centroids.sorted { $0.key < $1.key }.map { String(format: "%@ %.4f/%d", $0.key, $0.value.cos, $0.value.chunks) }
                    .joined(separator: ", ")
            ))
            XCTAssertGreaterThanOrEqual(mean, 0.98, "\(track): mean chunk cosine")
            XCTAssertGreaterThanOrEqual(p5, 0.95, "\(track): p5 chunk cosine")
            XCTAssertGreaterThanOrEqual(worst, 0.99, "\(track): centroid cosine (clusters ≥ \(Self.minCentroidChunks) windows)")
        }
    }

    // MARK: - Helpers

    /// The 128k re-encode control (`afconvert -d aac -b 128000`), part of the WER floor.
    private static let control = "scenario_basic_r128"
    private static let minCentroidChunks = 10

    /// Copy of a mono Float32 WAV scaled by `gainDB` and delayed by `delaySamples` of silence.
    static func perturb(_ source: URL, to destination: URL, gainDB: Float, delaySamples: Int) throws {
        let src = try AVAudioFile(forReading: source)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length) + AVAudioFrameCount(delaySamples)
        )!
        try src.read(into: buffer)
        let data = buffer.floatChannelData![0], n = Int(buffer.frameLength), gain = pow(10, gainDB / 20)
        for i in stride(from: n - 1, through: 0, by: -1) { data[i + delaySamples] = data[i] * gain }
        for i in 0 ..< delaySamples { data[i] = 0 }
        buffer.frameLength = AVAudioFrameCount(n + delaySamples)
        let dst = try AVAudioFile(
            forWriting: destination, settings: src.processingFormat.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try dst.write(from: buffer)
    }

    /// `AudioConverter.compressToAAC` with the rate and bitrate given as is (same reader,
    /// writer and settings). The system AAC encoder rejects > 64 kbps at 24 kHz mono, so a
    /// 96 kbps candidate runs at 32 kHz.
    static func encodeAAC(input: URL, output: URL, rate: Double, bitrate: Int) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioConverter.AudioConverterError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(trackOutput)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ])
        writer.add(writerInput)
        reader.startReading()
        defer { reader.cancelReading() }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        nonisolated(unsafe) let input_ = writerInput, output_ = trackOutput, writer_ = writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input_.requestMediaDataWhenReady(on: DispatchQueue(label: "vedivox-bench-aac")) {
                while input_.isReadyForMoreMediaData {
                    if let buffer = output_.copyNextSampleBuffer() {
                        input_.append(buffer)
                    } else {
                        input_.markAsFinished()
                        writer_.finishWriting { continuation.resume() }
                        return
                    }
                }
            }
        }
        guard writer_.status == .completed else { throw AudioConverter.AudioConverterError.conversionFailed }
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Word-level Levenshtein distance over the reference length.
    static func wer(_ ref: [Substring], _ hyp: [Substring]) -> Double {
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var prev = Array(0 ... hyp.count)
        for (i, r) in ref.enumerated() {
            var cur = [i + 1] + Array(repeating: 0, count: hyp.count)
            for (j, h) in hyp.enumerated() {
                cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (r == h ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }

    func testWER() {
        XCTAssertEqual(Self.wer(["a", "b", "c", "d"], ["a", "x", "c"]), 0.5) // 1 sub + 1 del
        XCTAssertEqual(Self.wer(["a"], ["a"]), 0)
        XCTAssertEqual(Self.median([0.03, 0, 0.01, 0.02]), 0.015)
        XCTAssertEqual(Self.median([0.03, 0, 0.01]), 0.01)
    }

    func testPerturb() throws {
        let tmp = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let src = tmp.appendingPathComponent("src.wav"), dst = tmp.appendingPathComponent("dst.wav")
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        for (i, v) in [Float(0.1), 0.2, 0.3].enumerated() { buffer.floatChannelData![0][i] = v }
        try AVAudioFile(forWriting: src, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            .write(from: buffer)
        try Self.perturb(src, to: dst, gainDB: 20, delaySamples: 1)
        let out = try AVAudioFile(forReading: dst)
        let read = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: 8)!
        try out.read(into: read)
        let got = (0 ..< Int(read.frameLength)).map { read.floatChannelData![0][$0] }
        XCTAssertEqual(got.count, 4)
        for (g, e) in zip(got, [Float(0), 1, 2, 3]) { XCTAssertEqual(g, e, accuracy: 1e-5) }
    }

    private static func mean(_ vs: [[Float]]) -> [Float] {
        var m = [Float](repeating: 0, count: vs[0].count)
        for v in vs { for i in m.indices { m[i] += v[i] } }
        return m.map { $0 / Float(vs.count) }
    }

    /// `M*.mic.m4a` / `M*.system.m4a` of the original (the `mixed` files are not scenario input).
    private func tracks() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDir(original).appendingPathComponent("audio").path)
            .filter { $0.hasSuffix(".mic.m4a") || $0.hasSuffix(".system.m4a") }
            .sorted()
    }

    private func skipUnlessBothPresent() throws {
        for f in [original, variant] where !ScenarioBenchRunner.fixtureAudioPresent(f) {
            throw XCTSkip("\(f) audio not present — build \(variant) with testMakeVariantFixture")
        }
    }

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fixtureDir(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VedivoxBench
            .deletingLastPathComponent() // Vedivox
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(".backlog/fixtures/\(name)")
    }

    private func log(_ msg: String) { print("[recompress-gate] \(msg)") }
}

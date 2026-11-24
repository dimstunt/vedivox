import AVFoundation
import os
import XCTest

/// Live text of the call track on a file in the format a recording writes.
///
/// `LiveSpeakersBench` cuts its passes out of finished 16 kHz mono files, so
/// nothing it measures goes the way a real call track goes: 48 kHz stereo
/// Float32, interleaved, written in 512-frame tap buffers, each buffer also
/// handed to the live sink, the file read by `RecordingTail` while the sizes
/// in its header are still zero, and folded to mono by the converter.
///
/// Here the sound takes that road, and five texts of it are compared: the
/// quick windows; the live log a reader has at the end (quick text plus a
/// precise pass a minute over the last three); one precise pass over the
/// whole file while it is still open; the regular pipeline over the finished
/// file — what the final transcript says; and the regular pipeline over the
/// same sound as a 16 kHz mono file, the format of the fixtures.
///
///     xcodebuild test -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/LiveFormatBench
///
/// `VEDIVOX_BENCH_AUDIO` adds any recording, reported as numbers only;
/// `VEDIVOX_BENCH_REFERENCE` is a file with the words said in it, if they are
/// known; `VEDIVOX_BENCH_TEXT_DIR` is a directory outside the repository that
/// gets the five texts — the words of a real call never go to the log.
final class LiveFormatBench: XCTestCase {

    func testRussianSynthetic() async throws {
        // Three rounds: longer than the three minutes a pass looks back.
        let script = Array(repeating: LiveModelChoiceBench.script, count: 3).flatMap { $0 }
        let audio = try Self.synthesize(script.joined(separator: " [[slnc 700]] "))
        try await compare(audio, reference: script.joined(separator: " "), label: "synthetic", gate: true)
    }

    func testRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["VEDIVOX_BENCH_AUDIO"] else { throw XCTSkip("set VEDIVOX_BENCH_AUDIO to a recording") }
        let seconds = Double(environment["VEDIVOX_BENCH_SECONDS"] ?? "") ?? 600
        let audio = Array(try LiveRecordingFile.samples(of: URL(fileURLWithPath: path)).prefix(Int(seconds * 48000)))
        let reference = try environment["VEDIVOX_BENCH_REFERENCE"].map { try String(contentsOfFile: $0, encoding: .utf8) }
        try await compare(audio, reference: reference, label: "recording", gate: false)
    }

    // MARK: - Comparison

    private struct Line {
        let start: Double
        let end: Double
        let text: String
    }

    /// A finished file as `analyzeLiveTail` takes it.
    static func prepared(_ url: URL) async throws -> (url: URL, tail: RecordingTail.Tail) {
        let output = url.deletingPathExtension().appendingPathExtension("16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: url, output: output)
        return (output, .init(from: 0, duration: try AudioConverter.trackStats(of: url).duration))
    }

    /// `audio` is 48 kHz mono: what the tap delivers, the same in both channels.
    private func compare(_ audio: [Float], reference: String?, label: String, gate: Bool) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-live-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pipeline = TranscriptionPipeline(db: try DatabaseManager(inMemory: true), audioRoot: scratch, compressAudio: false)
        let recogniser = LiveWindowRecogniser(pipeline: pipeline)
        await recogniser.prepare()
        guard await recogniser.readiness == .ready else { throw XCTSkip("the recognition model is not available") }

        let recording = try LiveRecordingFile(url: scratch.appendingPathComponent("system.wav"), channels: 2)
        // Every tap buffer goes to the file and to the live sink, as
        // `SystemAudioWriter.writeAudio` sends them.
        let tapped = OSAllocatedUnfairLock(initialState: [Float]())
        let sink = LiveAudioSink(onSamples: { samples in tapped.withLock { $0 += samples } })
        var log = LiveTranscriptLog()
        var book = LiveSpeakerBook()
        var quick: [Line] = []
        var heard: [Float] = []
        // The writer pads the start of the file up to the first callback, and
        // the pad never reaches the sink.
        let lead = 36000
        try recording.write([Float](repeating: 0, count: lead)[...])
        // Eight seconds of silence close the last window, as the end of a call does not.
        let sound = audio + [Float](repeating: 0, count: 8 * 48000)
        for start in stride(from: 0, to: sound.count, by: 60 * 48000) {
            try recording.write(sound[start ..< min(start + 60 * 48000, sound.count)]) { sink.feed($0) }
            let minute = tapped.withLock { samples in
                defer { samples = [] }
                return samples
            }
            for offset in stride(from: 0, to: minute.count, by: 4000) {
                let block = Array(minute[offset ..< min(offset + 4000, minute.count)])
                heard += block
                let pieces = await recogniser.append(block, endingAt: Double(lead) / 48000 + Double(heard.count) / 16000)
                quick += pieces.map { Line(start: $0.start, end: $0.end, text: $0.text) }
                for piece in pieces { log.add(piece, track: .system) }
            }
            // The file is open: a reader that trusts its header finds no audio in it.
            XCTAssertEqual(try AVAudioFile(forReading: recording.url).length, 0, "the header is not finished while recording")
            guard let pass = await pipeline.refineLiveTail(
                mic: nil, system: recording.url, last: MeetingLiveTranscript.tailSeconds
            ) else { return XCTFail("no precise pass over the file being written") }
            pass.apply(to: &log, speakers: &book)
        }
        let whole = Double(lead + sound.count) / 48000
        guard let open = await pipeline.refineLiveTail(mic: nil, system: recording.url, last: whole + 60) else {
            return XCTFail("no precise pass over the whole file being written")
        }
        recording.finish()
        let finished = try await pipeline.analyzeLiveTail(mic: nil, system: try await Self.prepared(recording.url))
        // With the pad in front: a file that starts elsewhere is cut into
        // other chunks by the model, and that alone changes words.
        let mono = try Self.write(
            [Float](repeating: 0, count: lead / 3) + heard, to: scratch.appendingPathComponent("fixture.wav")
        )
        let fixture = try await pipeline.analyzeLiveTail(mic: nil, system: try await Self.prepared(mono))

        func lines(_ analysis: LiveTailAnalysis) -> [Line] {
            (analysis.system?.lines ?? []).map { Line(start: $0.start, end: $0.end, text: $0.text) }
        }
        let texts: [(name: String, lines: [Line])] = [
            ("quick windows", quick),
            ("live log", log.entries.filter { $0.track == .system }.sorted { $0.start < $1.start }
                .map { Line(start: $0.start, end: $0.end, text: $0.text) }),
            ("pass over the open file", lines(open)),
            ("finished file", lines(finished)),
            ("16 kHz mono file", lines(fixture)),
        ]
        func text(_ name: String) -> String {
            texts.first { $0.name == name }?.lines.map(\.text).joined(separator: " ") ?? ""
        }
        let final = text("finished file")
        report(label, String(format: "%.1f s of audio, %d words in the finished file", Double(audio.count) / 48000, LiveModelChoiceBench.words(final).count))
        for (name, lines) in texts {
            let joined = lines.map(\.text).joined(separator: " ")
            var line = String(
                format: "%@: differs from the finished file in %.1f %% of words, %d words in Latin script of %d",
                name, LiveModelChoiceBench.wordErrorRate(of: joined, against: final) * 100,
                Self.latinWords(joined), LiveModelChoiceBench.words(joined).count
            )
            if let reference {
                line += String(format: ", WER %.1f %% against what was said", LiveModelChoiceBench.wordErrorRate(of: joined, against: reference) * 100)
            }
            report(label, line)
            // Where the Latin script is: a minute of the recording at a time.
            let minutes = Dictionary(grouping: lines, by: { Int($0.start / 60) })
                .mapValues { Self.latinWords($0.map(\.text).joined(separator: " ")) }
                .filter { $0.value > 0 }
            if !minutes.isEmpty {
                report(label, "  Latin-script words by minute: " + minutes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
            }
        }
        if let directory = ProcessInfo.processInfo.environment["VEDIVOX_BENCH_TEXT_DIR"] {
            for (name, lines) in texts {
                let body = lines.map { String(format: "[%6.1f–%6.1f] %@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
                try body.write(toFile: "\(directory)/\(label) — \(name).txt", atomically: true, encoding: .utf8)
            }
        }

        guard gate else { return }
        // The format changes nothing: the open file reads as the finished one…
        XCTAssertEqual(
            LiveModelChoiceBench.words(text("pass over the open file")), LiveModelChoiceBench.words(final),
            "a pass over the whole file being written is the regular pipeline over that file"
        )
        // …and precise passes do not make the live text worse than quick text.
        // Two points of slack: a three-minute tail starts where the file does
        // not, so the model's chunks fall elsewhere (design D9 of
        // `live-speakers`: two regular passes of one sound differ by more).
        XCTAssertLessThanOrEqual(
            LiveModelChoiceBench.wordErrorRate(of: text("live log"), against: final),
            LiveModelChoiceBench.wordErrorRate(of: text("quick windows"), against: final) + 0.02,
            "the live log after precise passes is no further from the final transcript than quick text"
        )
        XCTAssertLessThanOrEqual(
            Self.latinWords(text("live log")), Self.latinWords(final),
            "precise passes add no words in another script"
        )
    }

    private static func latinWords(_ text: String) -> Int {
        LiveModelChoiceBench.words(text).filter { $0.unicodeScalars.contains { ("a" ... "z").contains($0) } }.count
    }

    private func report(_ label: String, _ value: String) {
        print("[LiveFormat] \(label): \(value)")
    }

    // MARK: - Audio

    private static func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-format-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Milena", "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@48000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("`say -v Milena` failed — is the Russian voice installed?") }
        return try LiveRecordingFile.samples(of: url)
    }

    private static func write(_ samples: [Float], to url: URL) throws -> URL {
        guard let format = AudioConverter.float32Format(channels: 1, sampleRate: 16000),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw XCTSkip("no buffer for \(url.lastPathComponent)") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}

/// A track's file as the capture writes it, the writer still open: 48 kHz
/// Float32 in 512-frame buffers — the call track in two interleaved channels
/// (the log of a real recording: «Tap format: 48000 Hz, 2 ch, interleaved=1»),
/// the microphone in one. Until `finish`, the sizes in its header are zero.
final class LiveRecordingFile {
    let url: URL
    private let format: AVAudioFormat
    private var file: AVAudioFile?

    init(url: URL, channels: AVAudioChannelCount) throws {
        self.url = url
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: channels > 1
        ) else { throw XCTSkip("no \(channels)-channel tap format") }
        self.format = format
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: !format.isInterleaved,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved
        )
    }

    /// Writes 48 kHz mono samples, the same sound in every channel; `tap`
    /// gets each buffer after the file, as the capture's live sink does.
    func write(_ samples: ArraySlice<Float>, tap: ((AVAudioPCMBuffer) -> Void)? = nil) throws {
        let channels = Int(format.channelCount)
        var offset = samples.startIndex
        while offset < samples.endIndex {
            let count = min(512, samples.endIndex - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512),
                  let data = buffer.floatChannelData?[0]
            else { throw XCTSkip("no tap buffer") }
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0 ..< count {
                for channel in 0 ..< channels { data[channels * frame + channel] = samples[offset + frame] }
            }
            try file?.write(from: buffer)
            tap?(buffer)
            offset += count
        }
    }

    /// Closes the writer: the header gets its sizes.
    func finish() {
        file = nil
    }

    /// A whole audio file as 48 kHz mono: what a tap would have delivered of it.
    static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        var mono: [Float] = []
        // In blocks: one read sized to the file stops short of its end.
        while file.framePosition < file.length {
            guard let block = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 65536) else { break }
            try file.read(into: block)
            guard block.frameLength > 0 else { break }
            let folded = source.channelCount > 1 ? AudioConverter.downmixToMono(block) : block
            guard let data = folded.floatChannelData?[0] else { break }
            mono += UnsafeBufferPointer(start: data, count: Int(folded.frameLength))
        }
        guard !mono.isEmpty else { throw XCTSkip("\(url.lastPathComponent) has no audio") }
        return try resampled(mono, from: source.sampleRate, to: 48000)
    }

    private static func resampled(_ mono: [Float], from: Double, to: Double) throws -> [Float] {
        guard from != to, !mono.isEmpty else { return mono }
        guard let source = AudioConverter.float32Format(channels: 1, sampleRate: from),
              let target = AudioConverter.float32Format(channels: 1, sampleRate: to),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(mono.count)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(mono.count) / from * to) + AVAudioFrameCount(to)
              )
        else { throw XCTSkip("no converter from \(Int(from)) to \(Int(to)) Hz") }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

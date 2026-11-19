import AVFoundation
import FluidAudio
import XCTest

/// Which model reads a running recording:
/// the streaming Nemotron that drafts dictation, or Parakeet over windows cut
/// at pauses. Three numbers decide — how wrong the text is, how late it is,
/// and what it costs while a call is on — and none can be reasoned out.
///
/// Speech is synthetic (macOS `say`, a Russian voice), so the reference text is
/// known and nothing recorded from a person is involved. `VEDIVOX_BENCH_AUDIO`
/// adds a real recording, scored against Parakeet over the whole file and
/// reported as numbers only — its words are never printed.
///
///     xcodebuild test -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/LiveModelChoiceBench
final class LiveModelChoiceBench: XCTestCase {

    /// Meeting-shaped Russian: questions, verbs that carry the meaning,
    /// abbreviations and product words — what the streaming model was seen to
    /// lose on real dictation. `[[slnc N]]` is a pause of N ms.
    static let script = [
        "Коллеги, давайте начнём. Сегодня обсуждаем перенос отчётов в новое хранилище.",
        "Первый вопрос: когда команда закончит миграцию таблиц и кто отвечает за проверку данных?",
        "Мы перенесли половину таблиц на прошлой неделе, остальные переедут до конца месяца.",
        "Проверку данных делает аналитик, он сравнивает суммы по дням и пишет в канал, если цифры расходятся.",
        "Хорошо. А что с доступами? Подрядчик не получит ВНЖ до весны, поэтому работать он будет удалённо.",
        "Доступ к API мы выдали вчера, ключ лежит в хранилище секретов, срок действия полгода.",
        "Второй вопрос: почему вырос счёт за запросы? В сентябре мы платили вдвое меньше.",
        "Потому что один дашборд читает всю таблицу событий без фильтра по дате, я исправлю запрос сегодня.",
        "Тогда договорились: запрос чиним сегодня, миграцию заканчиваем до конца месяца, и в пятницу сверяем цифры.",
        "И последнее: не забудьте обновить документацию, иначе новый сотрудник опять спросит, где лежат выгрузки.",
    ]

    func testRussianSynthetic() async throws {
        let samples = try Self.synthesize(Self.script.joined(separator: " [[slnc 700]] "))
        try await compare(samples, reference: Self.script.joined(separator: " "), label: "synthetic", printText: true)
    }

    func testRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["VEDIVOX_BENCH_AUDIO"] else {
            throw XCTSkip("set VEDIVOX_BENCH_AUDIO to a recording")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["VEDIVOX_BENCH_SECONDS"] ?? "") ?? 300
        let samples = try Self.samples(of: URL(fileURLWithPath: path), seconds: seconds)
        try await compare(samples, reference: nil, label: "recording", printText: false)
    }

    // MARK: - Comparison

    private func compare(_ samples: [Float], reference: String?, label: String, printText: Bool) async throws {
        let audioSeconds = Double(samples.count) / 16000
        report(label, String(format: "%.1f s of audio", audioSeconds))

        let parakeet = TranscriptionService()
        try await parakeet.initialize()
        // The first call after a load pays the model's cold start; keep it out
        // of every number below.
        _ = try await parakeet.transcribe(samples: Array(samples.prefix(32000)))

        // Parakeet over the whole audio: what the final transcript will say.
        var started = Date()
        let whole = try await transcribeLong(samples, with: parakeet)
        let wholeSeconds = Date().timeIntervalSince(started)
        let truth = reference ?? whole
        let scoredAgainst = reference == nil ? "Parakeet whole" : "the script"
        report(label, "WER is measured against \(scoredAgainst)")
        line(label, "parakeet whole", text: whole, truth: truth, audio: audioSeconds, model: wholeSeconds, printText: printText)

        // Parakeet over windows cut at pauses — the candidate — at several
        // shortest/longest window lengths: short windows answer sooner, long
        // ones give the model more context. 6–12 s is what ships.
        for (shortest, longest) in [(2, 12), (4, 12), (6, 12), (6, 14), (8, 14), (10, 14)] {
            var pending: [Float] = []
            var pieces: [String] = []
            var windows: [Double] = []
            var worstCall = 0.0
            var modelSeconds = 0.0
            // 250 ms at a time, as the feed loop delivers.
            for offset in stride(from: 0, to: samples.count, by: 4000) {
                pending.append(contentsOf: samples[offset ..< min(offset + 4000, samples.count)])
                while let count = LiveWindowCutter.cut(
                    pending, minWindow: shortest * 16000, maxWindow: longest * 16000
                ) {
                    let window = Array(pending.prefix(count))
                    pending.removeFirst(count)
                    windows.append(Double(count) / 16000)
                    guard !LiveWindowCutter.isSilent(window) else { continue }
                    let callStarted = Date()
                    pieces.append(try await Self.text(parakeet.transcribe(samples: window)))
                    let call = Date().timeIntervalSince(callStarted)
                    modelSeconds += call
                    worstCall = max(worstCall, call)
                }
            }
            if pending.count >= 8000 { pieces.append(try await Self.text(parakeet.transcribe(samples: pending))) }
            line(
                label, "parakeet pause windows \(shortest)–\(longest) s",
                text: pieces.joined(separator: " "), truth: truth, audio: audioSeconds, model: modelSeconds,
                printText: printText && shortest == LiveWindowCutter.minWindow / 16000
                    && longest == LiveWindowCutter.maxWindow / 16000
            )
            report(label, String(
                format: "  %d windows, mean %.1f s, longest %.1f s, slowest call %.0f ms",
                windows.count, windows.reduce(0, +) / Double(max(windows.count, 1)), windows.max() ?? 0, worstCall * 1000
            ))
        }

        // Parakeet over fixed windows: what cutting at pauses buys.
        for length in [10, 14] {
            started = Date()
            var fixed: [String] = []
            for offset in stride(from: 0, to: samples.count, by: length * 16000) {
                let window = Array(samples[offset ..< min(offset + length * 16000, samples.count)])
                if window.count >= 8000 { fixed.append(try await Self.text(parakeet.transcribe(samples: window))) }
            }
            line(
                label, "parakeet fixed \(length) s",
                text: fixed.joined(separator: " "), truth: truth, audio: audioSeconds,
                model: Date().timeIntervalSince(started), printText: printText && length == 10
            )
        }

        // The streaming model, at the chunk size dictation uses.
        let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: DictationChunkSize.default.milliseconds
        )
        let nemotron = StreamingNemotronMultilingualAsrManager()
        try await nemotron.loadModels(from: directory)
        started = Date()
        for offset in stride(from: 0, to: samples.count, by: 4000) {
            _ = try await nemotron.process(samples: Array(samples[offset ..< min(offset + 4000, samples.count)]))
        }
        let streamed = try await nemotron.finish()
        line(
            label, "nemotron \(DictationChunkSize.default.milliseconds) ms",
            text: streamed, truth: truth, audio: audioSeconds,
            model: Date().timeIntervalSince(started), printText: printText
        )
        await nemotron.cleanup()
    }

    /// The whole audio through Parakeet, as the pipeline does with a file.
    private func transcribeLong(_ samples: [Float], with service: TranscriptionService) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-choice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return try await service.transcribe(url).text
    }

    private func line(
        _ label: String, _ candidate: String, text: String, truth: String,
        audio: Double, model: Double, printText: Bool
    ) {
        report(label, String(
            format: "%@: WER %.1f %%, model %.2f s for %.1f s (%.0fx realtime, %.1f %% of one core-second per second)",
            candidate, Self.wordErrorRate(of: text, against: truth) * 100,
            model, audio, audio / max(model, 0.001), model / audio * 100
        ))
        if printText { report(label, "  \(candidate) text: \(text)") }
    }

    /// A window's segments as one line, the way the live transcript joins them.
    private static func text(_ segments: [TokenGrouper.Segment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private func report(_ label: String, _ value: String) {
        print("[LiveChoice] \(label): \(value)")
    }

    // MARK: - Scoring

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    /// Word-level edit distance over the reference length.
    static func wordErrorRate(of text: String, against reference: String) -> Double {
        let hypothesis = words(text)
        let truth = words(reference)
        guard !truth.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0 ... hypothesis.count)
        for (row, word) in truth.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: hypothesis.count)
            for column in 0 ..< hypothesis.count {
                current[column + 1] = min(
                    previous[column] + (word == hypothesis[column] ? 0 : 1),
                    previous[column + 1] + 1,
                    current[column] + 1
                )
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(truth.count)
    }

    // MARK: - Audio

    private static func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-choice-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Milena", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("`say -v Milena` failed — is the Russian voice installed?") }
        return try samples(of: url, seconds: .infinity)
    }

    /// The first `seconds` of a file as 16 kHz mono.
    static func samples(of url: URL, seconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), seconds * source.sampleRate))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else {
            throw XCTSkip("\(url.lastPathComponent) has no audio")
        }
        try file.read(into: input, frameCount: frames)

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let mono = source.channelCount > 1 ? AudioConverter.downmixToMono(input) : input
        guard let converter = AVAudioConverter(from: mono.format, to: target),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(Double(mono.frameLength) / mono.format.sampleRate * 16000) + 16000
              )
        else { throw XCTSkip("no 16 kHz converter for \(url.lastPathComponent)") }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return mono
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

import AVFoundation
import XCTest

/// How well precise passes over the tail of a recording tell who said what
/// and what they cost.
///
/// Every minute of a `scenario_basic` meeting gets a pass of the regular
/// pipeline over the last 2, 3, 5 or 10 minutes, read as the app reads it —
/// from the tail of files in the capture's format with the writers still
/// open (`LiveRecordingFile`); the passes are put together
/// by the code the app uses (`LiveTailAnalysis.apply`: the log, the book of
/// voices) and scored against the ground truth. Each pass runs once and is
/// cached outside the repository — with its text and voice vectors, which
/// never belong in it — so the scoring reruns without the models.
///
///     mkdir ~/caches/vedivox-bench.lock    # one bench at a time; rmdir right after
/// TEST_RUNNER_VEDIVOX_BENCH_FIXTURES=<checkout with the the private fixtures \
///       xcodebuild test -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/LiveSpeakersBench
///
/// `VEDIVOX_LIVE_BENCH_CACHED=1` skips the models and scores the cache alone.
/// Nothing printed names a person or quotes a word.
///
/// The per-window grouping this was first written to measure (design D8) and
/// its bench are in the history of this file, up to commit c5aaf845.
final class LiveSpeakersBench: XCTestCase {

    private static let meetings = ["M1", "M2", "M3", "M4", "M5"]

    struct Score {
        /// Seconds of pieces that fall on somebody's reference speech.
        var scored = 0.0
        /// …whose label stands for that reference speaker.
        var matched = 0.0
        /// …left as `others`.
        var unlabelled = 0.0
        var rightName = 0.0
        var wrongName = 0.0
        /// Seconds of reference speakers who have a voiceprint in the pool.
        var nameable = 0.0
        /// Seconds of pieces outside any reference speech.
        var outside = 0.0
        var people = 0
        var labels = 0
        /// Labels beyond the first for one person, summed over people.
        var extraLabels = 0
        /// People who never got a label of their own.
        var unlabelledPeople = 0

        mutating func add(_ other: Score) {
            scored += other.scored
            matched += other.matched
            unlabelled += other.unlabelled
            rightName += other.rightName
            wrongName += other.wrongName
            nameable += other.nameable
            outside += other.outside
            people += other.people
            labels += other.labels
            extraLabels += other.extraLabels
            unlabelledPeople += other.unlabelledPeople
        }

        var line: String {
            String(
                format: "label right %.1f %% of %.0f s, unlabelled %.1f %%; %d people → %d labels, extra %d (%.2f per person), "
                    + "no own label %d; names right %.0f s of %.0f s nameable, wrong %.0f s; outside reference %.0f s",
                matched / max(scored, 0.001) * 100, scored, unlabelled / max(scored, 0.001) * 100,
                people, labels, extraLabels, Double(extraLabels) / Double(max(people, 1)), unlabelledPeople,
                rightName, nameable, wrongName, outside
            )
        }
    }

    /// Labelled entries of the call track against the reference speakers.
    private static func score(
        _ labelled: [(entry: LiveTranscriptLog.Entry, speaker: LiveSpeaker)], _ reference: Reference, nameable: Set<String>
    ) -> Score {
        var score = Score()
        var byLabel: [String: [String: Double]] = [:]
        var rows: [(label: LiveSpeaker, speaker: String, seconds: Double)] = []
        for (entry, label) in labelled where entry.track == .system {
            let seconds = entry.end - entry.start
            guard let speaker = reference.speaker(entry.start, entry.end) else {
                score.outside += seconds
                continue
            }
            score.scored += seconds
            if nameable.contains(speaker) { score.nameable += seconds }
            rows.append((label, speaker, seconds))
            if label != .others { byLabel["\(label.kind.rawValue):\(label.name)", default: [:]][speaker, default: 0] += seconds }
        }
        let dominant = byLabel.compactMapValues { speakers in
            speakers.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        }
        for row in rows {
            switch row.label.kind {
            case .known:
                if row.label.name == row.speaker {
                    score.rightName += row.seconds
                    score.matched += row.seconds
                } else {
                    score.wrongName += row.seconds
                }
            case .unknown where row.label == .others:
                score.unlabelled += row.seconds
            case .unknown, .me:
                if dominant["\(row.label.kind.rawValue):\(row.label.name)"] == row.speaker { score.matched += row.seconds }
            }
        }
        let heard = Set(rows.map(\.speaker))
        score.people = heard.count
        score.labels = byLabel.count
        for person in heard {
            let own = dominant.values.filter { $0 == person }.count
            score.extraLabels += max(0, own - 1)
            if own == 0 { score.unlabelledPeople += 1 }
        }
        return score
    }

    // MARK: - Level 2: precise passes over the recording's tail (design D9)

    /// The pipelines of a level-2 run: one reads the migrated voiceprints, the
    /// other an empty pool, so every voice stays a «Speaker N».
    private struct Pipelines {
        let seeded: TranscriptionPipeline
        let empty: TranscriptionPipeline
        let scratch: URL
    }

    private static func loadPipelines() async throws -> Pipelines {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-live-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let seededDB = try DatabaseManager(inMemory: true)
        let pool = try seededPool()
        try await seededDB.writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, title, startTime, status)
                VALUES ('SEED', '[SEED] canonical pool', '2000-01-01 00:00:00', 'done')
                """)
            for candidate in pool {
                try db.execute(
                    sql: "INSERT INTO speakers (id, nameEn, isConfirmed, embeddingV2) VALUES (?, ?, 1, ?)",
                    arguments: [candidate.speakerId, candidate.displayName, Speaker.encodeEmbedding(candidate.canonical)]
                )
                for index in 0 ..< 5 {
                    try db.execute(sql: """
                        INSERT INTO transcript_segments (meetingId, speakerId, source, startTime, endTime, text)
                        VALUES ('SEED', ?, 'system', ?, ?, 'seed')
                        """, arguments: [candidate.speakerId, Double(index), Double(index) + 0.1])
                }
            }
        }
        let pipelines = Pipelines(
            seeded: TranscriptionPipeline(db: seededDB, audioRoot: scratch, compressAudio: false),
            empty: TranscriptionPipeline(db: try DatabaseManager(inMemory: true), audioRoot: scratch, compressAudio: false),
            scratch: scratch
        )
        // The first pass pays the models' cold start; keep it out of the numbers.
        let warm = (0 ..< 20 * 16000).map { 0.2 * sinf(2 * .pi * 180 * Float($0) / 16000) }
        let url = try write(warm[...], to: scratch.appendingPathComponent("warm.wav"))
        let warmTail = try await LiveFormatBench.prepared(url)
        for pipeline in [pipelines.seeded, pipelines.empty] {
            _ = try await pipeline.analyzeLiveTail(mic: warmTail, system: warmTail)
        }
        return pipelines
    }

    private static func write(_ samples: ArraySlice<Float>, to url: URL) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw XCTSkip("no buffer for \(url.lastPathComponent)")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? FileManager.default.removeItem(at: url)
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    /// A precise pass as the app makes it: the stretch lies in
    /// files of the capture's format with the writers still open, and the
    /// pass reads their tails. Finished 16 kHz mono files — what this bench
    /// first measured on — never met `RecordingTail` or the stereo fold.
    private static func livePass(
        mic: ArraySlice<Float>, system: ArraySlice<Float>, through pipeline: TranscriptionPipeline, scratch: URL
    ) async throws -> LiveTailAnalysis {
        let micFile = try LiveRecordingFile(url: scratch.appendingPathComponent("mic.wav"), channels: 1)
        try micFile.write(mic)
        let systemFile = try LiveRecordingFile(url: scratch.appendingPathComponent("system.wav"), channels: 2)
        try systemFile.write(system)
        guard let analysis = await pipeline.refineLiveTail(
            mic: micFile.url, system: systemFile.url, last: Double(system.count) / 48000 + 1
        ) else { throw XCTSkip("no pass over the files being written") }
        return analysis
    }

    private struct Tracks {
        let mic: [Float]
        let system: [Float]
        var seconds: Double { Double(min(mic.count, system.count)) / 16000 }
    }

    private func cached<Value: Codable>(_ name: String, _ make: () async throws -> Value) async throws -> Value {
        let url = Self.cacheDirectory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Value.self, from: data) {
            return value
        }
        guard ProcessInfo.processInfo.environment["VEDIVOX_LIVE_BENCH_CACHED"] != "1" else {
            throw XCTSkip("no cache \(name) — run once without VEDIVOX_LIVE_BENCH_CACHED")
        }
        let value = try await make()
        try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url)
        return value
    }

    func testPrecisePasses() async throws {
        var pipelines: Pipelines?
        var audio: [String: Tracks] = [:]
        func tracks(_ meeting: String) throws -> Tracks {
            if let loaded = audio[meeting] { return loaded }
            let directory = Self.fixtures.appendingPathComponent("scenario_basic/audio")
            let system = directory.appendingPathComponent("\(meeting).system.m4a")
            guard FileManager.default.fileExists(atPath: system.path) else {
                throw XCTSkip("scenario_basic audio not present — point VEDIVOX_BENCH_FIXTURES at a checkout that has it")
            }
            let loaded = Tracks(
                mic: try Self.samples(of: directory.appendingPathComponent("\(meeting).mic.m4a")),
                system: try Self.samples(of: system)
            )
            audio[meeting] = loaded
            return loaded
        }
        func ready() async throws -> Pipelines {
            if let pipelines { return pipelines }
            let loaded = try await Self.loadPipelines()
            pipelines = loaded
            return loaded
        }
        /// The fixture as the taps delivered it — 48 kHz — one meeting at a
        /// time: five minutes of it are 58 MB a track.
        var tapped: (meeting: String, mic: [Float], system: [Float])?
        func tapTracks(_ meeting: String) throws -> (mic: [Float], system: [Float]) {
            if let tapped, tapped.meeting == meeting { return (tapped.mic, tapped.system) }
            let directory = Self.fixtures.appendingPathComponent("scenario_basic/audio")
            let loaded = (
                meeting: meeting,
                mic: try LiveRecordingFile.samples(of: directory.appendingPathComponent("\(meeting).mic.m4a")),
                system: try LiveRecordingFile.samples(of: directory.appendingPathComponent("\(meeting).system.m4a"))
            )
            tapped = loaded
            return (loaded.mic, loaded.system)
        }
        /// One pass over [from, to] of a meeting, through the pipeline with or without voiceprints.
        func pass(_ meeting: String, seeded: Bool, from: Double, to: Double) async throws -> Pass {
            try await cached("\(meeting).pass.\(seeded ? "seeded" : "empty").\(Int(from))-\(Int(to)).json") {
                let all = try tapTracks(meeting)
                let pipelines = try await ready()
                let range = Int(from * 48000) ..< Int(to * 48000)
                let analysis = try await Self.livePass(
                    mic: all.mic[range.clamped(to: 0 ..< all.mic.count)],
                    system: all.system[range.clamped(to: 0 ..< all.system.count)],
                    through: seeded ? pipelines.seeded : pipelines.empty, scratch: pipelines.scratch
                )
                // The files hold the stretch alone: the pass timed it from zero.
                return Pass(analysis, from: from, to: to, startingAt: from)
            }
        }
        /// The quick text of level 1, with its words: what a pass replaces.
        func quick(_ meeting: String, _ track: String) async throws -> [Pass.Line] {
            try await cached("\(meeting).\(track).quick.json") {
                let all = try tracks(meeting)
                let pipeline = try await ready().seeded
                let recogniser = LiveWindowRecogniser(pipeline: pipeline)
                await recogniser.prepare()
                let padded = (track == "mic" ? all.mic : all.system) + [Float](repeating: 0, count: 8 * 16000)
                var lines: [Pass.Line] = []
                for offset in stride(from: 0, to: padded.count, by: 4000) {
                    let end = min(offset + 4000, padded.count)
                    lines += await recogniser.append(Array(padded[offset ..< end]), endingAt: Double(end) / 16000)
                        .map { Pass.Line(start: $0.start, end: $0.end, text: $0.text, label: nil) }
                }
                return lines
            }
        }

        let pool = try Self.seededPool()
        let tails: [Double] = [120, 180, 300, 600]
        var totals: [String: Score] = [:]
        var live: [String: Score] = [:]
        var words: [String: (errors: Double, count: Double)] = [:]
        var elapsed: [Double: [Double]] = [:]
        func add(_ key: String, _ text: String, against truth: String) {
            let count = Double(LiveModelChoiceBench.words(truth).count)
            words[key, default: (0, 0)].errors += LiveModelChoiceBench.wordErrorRate(of: text, against: truth) * count
            words[key, default: (0, 0)].count += count
        }

        for meeting in Self.meetings {
            let reference = try Self.reference(meeting)
            let duration = try await cached("\(meeting).seconds.json") { try tracks(meeting).seconds }
            // The final transcript's words: one pass over the whole recording.
            let whole = try await pass(meeting, seeded: true, from: 0, to: duration)
            let truth = (system: whole.system.map(\.text).joined(separator: " "), mic: whole.mic.map(\.text).joined(separator: " "))
            let quickSystem = try await quick(meeting, "system")
            let quickMic = try await quick(meeting, "mic")
            add("level 1 system", quickSystem.map(\.text).joined(separator: " "), against: truth.system)
            add("level 1 mic", quickMic.map(\.text).joined(separator: " "), against: truth.mic)

            let present = Set(reference.others.map(\.speaker))
            var checkpoints = Array(stride(from: 60.0, to: duration, by: 60))
            checkpoints.append(duration)
            for tail in tails {
                for seeded in [false, true] {
                    let variant = seeded ? "voiceprints" : "no voiceprints"
                    let mode = "\(Int(tail / 60)) min tail, \(variant)"
                    let nameable = seeded ? Set(pool.map(\.displayName)).intersection(present) : []
                    var log = LiveTranscriptLog()
                    var book = LiveSpeakerBook()
                    var previous = 0.0
                    for moment in checkpoints {
                        // What quick recognition had put into the log by then.
                        for line in quickSystem where line.end > previous && line.end <= moment {
                            log.add(LivePiece(start: line.start, end: line.end, text: line.text), track: .system)
                        }
                        for line in quickMic where line.end > previous && line.end <= moment {
                            log.add(LivePiece(start: line.start, end: line.end, text: line.text), track: .mic)
                        }
                        previous = moment
                        let heard = try await pass(meeting, seeded: seeded, from: max(0, moment - tail), to: moment)
                        heard.analysis.apply(to: &log, speakers: &book)
                        if seeded { elapsed[min(tail, moment), default: []].append(heard.elapsed) }
                        // What a reader sees right after this pass.
                        live[mode, default: Score()].add(Self.score(log.labelled(book.speakers), reference, nameable: nameable))
                    }
                    let final = Self.score(log.labelled(book.speakers), reference, nameable: nameable)
                    report("\(meeting) [\(mode)] \(final.line)")
                    totals[mode, default: Score()].add(final)
                    if seeded {
                        func text(_ track: SegmentSource) -> String {
                            log.entries.filter { $0.track == track }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
                        }
                        add("\(Int(tail / 60)) min tail system", text(.system), against: truth.system)
                        add("\(Int(tail / 60)) min tail mic", text(.mic), against: truth.mic)
                    }
                }
            }
        }
        report("— level 2, the log at the end of the recording, M1–M5 —")
        for (mode, score) in totals.sorted(by: { $0.key < $1.key }) { report("ALL [\(mode)] \(score.line)") }
        report("— level 2, what a reader sees right after each minute's pass, summed over the passes —")
        for (mode, score) in live.sorted(by: { $0.key < $1.key }) { report("LIVE [\(mode)] \(score.line)") }
        report("— words that differ from one pass over the whole recording —")
        for (key, value) in words.sorted(by: { $0.key < $1.key }) {
            report(String(format: "WORDS [%@] %.1f %% of %.0f words", key, value.errors / max(value.count, 1) * 100, value.count))
        }
        report("— time of a pass over both tracks, by the length of the tail it read —")
        for (length, times) in elapsed.sorted(by: { $0.key < $1.key }) {
            report(String(
                format: "TIME [tail %.0f s] %d passes, mean %.1f s, slowest %.1f s — %.1f %% of a minute between passes",
                length, times.count, times.reduce(0, +) / Double(times.count), times.max() ?? 0,
                times.reduce(0, +) / Double(times.count) / 60 * 100
            ))
        }

        // Ten minutes of tail: longer than any fixture, so two of them back to back. Time only.
        let long = try await cached("M4+M5.pass.600.json") { () -> Pass in
            let first = try tapTracks("M4")
            let second = try tapTracks("M5")
            let pipelines = try await ready()
            return Pass(try await Self.livePass(
                mic: (first.mic + second.mic).prefix(600 * 48000), system: (first.system + second.system).prefix(600 * 48000),
                through: pipelines.seeded, scratch: pipelines.scratch
            ), from: 0, to: 600)
        }
        report(String(format: "TIME [tail 600 s, M4 then M5] one pass over both tracks: %.1f s", long.elapsed))
    }

    // MARK: - Fixtures

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The audio is gitignored and lives in one checkout; a worktree points here.
    private static var fixtures: URL {
        ProcessInfo.processInfo.environment["VEDIVOX_BENCH_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent(".backlog/fixtures")
    }

    /// Voice vectors of real people: never inside the repository. `-v2`:
    /// passes over files in the capture's format; the folder without it
    /// holds the passes over 16 kHz mono files under the same names.
    private static var cacheDirectory: URL {
        ProcessInfo.processInfo.environment["VEDIVOX_LIVE_BENCH_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("caches/vedivox-live-speakers-v2")
    }

    private struct Identities: Decodable {
        var owner = "me"
        var aliases: [String: String] = [:]
    }

    private static func reference(_ meeting: String) throws -> Reference {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let url = fixtures.appendingPathComponent("scenario_basic/ground_truth/\(meeting).gt.json")
        let segments = try decoder.decode(TruthFile.self, from: Data(contentsOf: url)).segments
            .map { ReferenceSegment(start: $0.start, end: $0.end, speaker: $0.realSpeaker) }
        return Reference(others: segments.filter { $0.speaker != "me" })
    }

    /// The migrated production voiceprints the scenario bench seeds, named as
    /// the ground truth names the same people.
    private static func seededPool() throws -> [SpeakerMatcher.Candidate] {
        let identities = (try? JSONDecoder().decode(
            Identities.self, from: Data(contentsOf: repoRoot.appendingPathComponent(".backlog/fixtures/identities.json"))
        )) ?? Identities()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let url = repoRoot.appendingPathComponent(".backlog/audits/wespeaker_migration/canonicals_v2.json")
        return try decoder.decode(CanonicalReport.self, from: Data(contentsOf: url)).speakers
            .filter { $0.status == "ok" && $0.name != identities.owner }
            .compactMap { entry in
                entry.embeddingV2.map {
                    SpeakerMatcher.Candidate(
                        speakerId: entry.speakerId, displayName: identities.aliases[entry.name, default: entry.name],
                        canonical: $0, segmentCount: 100
                    )
                }
            }
    }

    private func report(_ line: String) {
        print("[live-speakers] \(line)")
    }

    /// A whole file as 16 kHz mono.
    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard file.length > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("\(url.lastPathComponent) has no audio")
        }
        try file.read(into: input)

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

// MARK: - Fixture shapes

private struct ReferenceSegment {
    let start: Double
    let end: Double
    let speaker: String
}

private struct Reference {
    /// Without the owner: he is not on the system track.
    let others: [ReferenceSegment]

    static func overlap(_ start: Double, _ end: Double, _ segments: [ReferenceSegment]) -> [String: Double] {
        var seconds: [String: Double] = [:]
        for segment in segments {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > 0 { seconds[segment.speaker, default: 0] += overlap }
        }
        return seconds
    }

    /// Who speaks through most of [start, end], if anybody.
    func speaker(_ start: Double, _ end: Double) -> String? {
        Self.overlap(start, end, others).max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }
}

private struct TruthSegment: Decodable {
    let start: Double
    let end: Double
    let realSpeaker: String
}

private struct TruthFile: Decodable {
    let segments: [TruthSegment]
}

private struct CanonicalEntry: Decodable {
    let speakerId: String
    let name: String
    let status: String
    let embeddingV2: [Float]?
}

private struct CanonicalReport: Decodable {
    let speakers: [CanonicalEntry]
}

/// A pass as the bench keeps it. The text stays in the cache outside the
/// repository: the word error rates are recomputed from it.
private struct Pass: Codable {
    struct Line: Codable {
        let start: Double
        let end: Double
        let text: String
        let label: String?
    }

    struct Voice: Codable {
        let centroid: [Float]
        let seconds: Double
        let speakerId: String?
        let name: String?
        let confidence: Float?
    }

    let from: Double
    let to: Double
    let system: [Line]
    let mic: [Line]
    let voices: [String: Voice]
    let elapsed: Double

    /// `offset` moves the lines of a pass that timed its stretch from zero.
    init(_ analysis: LiveTailAnalysis, from: Double, to: Double, startingAt offset: Double = 0) {
        self.from = from
        self.to = to
        system = (analysis.system?.lines ?? []).map {
            Line(start: $0.start + offset, end: $0.end + offset, text: $0.text, label: $0.label)
        }
        mic = (analysis.mic?.lines ?? []).map { Line(start: $0.start + offset, end: $0.end + offset, text: $0.text, label: nil) }
        voices = analysis.voices.mapValues {
            Voice(centroid: $0.centroid, seconds: $0.seconds, speakerId: $0.identity?.speakerId,
                  name: $0.identity?.name, confidence: $0.identity?.confidence)
        }
        elapsed = analysis.elapsed
    }

    var analysis: LiveTailAnalysis {
        var analysis = LiveTailAnalysis()
        analysis.system = .init(from: from, to: to, lines: system.map {
            .init(start: $0.start, end: $0.end, text: $0.text, label: $0.label)
        })
        analysis.mic = .init(from: from, to: to, lines: mic.map { .init(start: $0.start, end: $0.end, text: $0.text) })
        analysis.voices = voices.mapValues { voice in
            .init(centroid: voice.centroid, seconds: voice.seconds, identity: voice.speakerId.map {
                .init(speakerId: $0, name: voice.name ?? "", confidence: voice.confidence ?? 0)
            })
        }
        analysis.elapsed = elapsed
        return analysis
    }
}

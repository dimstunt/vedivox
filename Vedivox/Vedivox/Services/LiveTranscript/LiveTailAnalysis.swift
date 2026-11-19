import Foundation

/// What a precise pass over the tail of a running recording found (change
/// `live-speakers`, design D2): the text of both tracks as the regular
/// pipeline reads it, and who said what on the call track. Nothing of it is
/// stored anywhere but the live log.
struct LiveTailAnalysis: Sendable {
    /// One voice of the pass — a label of its diarization.
    struct Voice: Equatable, Sendable {
        let centroid: [Float]
        let seconds: Double
        /// The confirmed speaker the pass recognised the voice as, if it did.
        var identity: LiveSpeakerBook.Identity?
    }

    struct Line: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        /// The pass's own label of who said it; nil — nobody in particular.
        var label: String?
    }

    /// One track's tail on the recording's clock.
    struct Track: Equatable, Sendable {
        let from: TimeInterval
        let to: TimeInterval
        var lines: [Line]
    }

    var mic: Track?
    var system: Track?
    /// The call track's voices by label.
    var voices: [String: Voice] = [:]
    /// Seconds the pass took.
    var elapsed: TimeInterval = 0

    /// The call track of a pass from the import analysis of its tail.
    ///
    /// `segments` are timed from the tail's start and labelled with a
    /// confirmed speaker's name, a `speaker_N` of this pass alone, or
    /// `UNKNOWN`; `labelToDbId` says which labels are confirmed speakers.
    /// A voice's vector is the mean of its segments' own vectors.
    static func system(
        segments: [TranscriptSegment], labelToDbId: [String: String], pool: [SpeakerMatcher.Candidate],
        from: TimeInterval, duration: TimeInterval
    ) -> (track: Track, voices: [String: Voice]) {
        func label(_ segment: TranscriptSegment) -> String? {
            segment.speakerLabel.flatMap { $0 == "UNKNOWN" ? nil : $0 }
        }
        let lines = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Line(start: from + $0.startTime, end: from + $0.endTime, text: $0.text, label: label($0)) }

        var voices: [String: Voice] = [:]
        for (name, own) in Dictionary(grouping: segments.filter { label($0) != nil }, by: { label($0) ?? "" }) {
            var sum: [Float] = []
            var seconds = 0.0
            for segment in own {
                let length = max(0, segment.endTime - segment.startTime)
                seconds += length
                guard let vector = segment.embedding.map(Speaker.decodeEmbedding), !vector.isEmpty,
                      sum.isEmpty || sum.count == vector.count
                else { continue }
                let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
                guard norm > 0 else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
                for i in vector.indices { sum[i] += Float(length) * vector[i] / norm }
            }
            guard !sum.isEmpty else { continue }
            let identity = labelToDbId[name].map { speakerId -> LiveSpeakerBook.Identity in
                let canonical = pool.first { $0.speakerId == speakerId && $0.canonical.count == sum.count }?.canonical
                return .init(
                    speakerId: speakerId, name: name,
                    confidence: canonical.map { cosineSimilarity(sum, $0) } ?? 0
                )
            }
            voices[name] = Voice(centroid: sum, seconds: seconds, identity: identity)
        }
        return (Track(from: from, to: from + duration, lines: lines), voices)
    }

    /// Puts the pass into the live text: its voices get the book's keys — the
    /// same key for the same voice in every pass — and its lines replace the
    /// quick pieces of their stretch.
    func apply(to log: inout LiveTranscriptLog, speakers: inout LiveSpeakerBook) {
        // In the order the voices are first heard: «Speaker N» counts up in time.
        let firstHeard = Dictionary(
            (system?.lines ?? []).compactMap { line in line.label.map { ($0, line.start) } },
            uniquingKeysWith: min
        )
        var keys: [String: Int] = [:]
        for name in voices.keys.sorted(by: { (firstHeard[$0] ?? .infinity, $0) < (firstHeard[$1] ?? .infinity, $1) }) {
            guard let voice = voices[name] else { continue }
            keys[name] = speakers.assign(voice: voice.centroid, seconds: voice.seconds, identity: voice.identity)
        }
        if let system {
            log.refine(track: .system, from: system.from, to: system.to, with: system.lines.map { line in
                (LivePiece(start: line.start, end: line.end, text: line.text), line.label.flatMap { keys[$0] })
            })
        }
        if let mic {
            log.refine(track: .mic, from: mic.from, to: mic.to, with: mic.lines.map { line in
                (LivePiece(start: line.start, end: line.end, text: line.text), nil)
            })
        }
    }
}

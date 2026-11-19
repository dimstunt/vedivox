import Foundation

/// A run = consecutive same-speaker segments.
struct SegmentRun: Identifiable {
    /// The first segment's id — anchors ScrollViewReader auto-follow.
    let id: Int64
    let speakerId: String?
    let speakerLabel: String?
    let segments: [TranscriptSegment]

    /// Runs never mix excluded and visible segments (it's part of the group
    /// key), so the first segment speaks for the whole run.
    var isExcluded: Bool { segments.first?.isExcluded ?? false }

    var startTime: Double { segments.first?.startTime ?? 0 }
    var endTime: Double { segments.last?.endTime ?? 0 }
    var duration: Double { endTime - startTime }
    var formattedTimeRange: String {
        "\(TranscriptSegment.formatTime(startTime)) → \(TranscriptSegment.formatTime(endTime))"
    }

    var joinedText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Split a run into display chunks of at least `minDuration` seconds — avoids
    /// per-segment `[MM:SS]` chip spam while keeping navigable anchors inside long monologues.
    /// Trailing short remainder is merged into the last chunk.
    func displayChunks(minDuration: Double = 15) -> [DisplayChunk] {
        var chunks: [DisplayChunk] = []
        var current: [TranscriptSegment] = []
        var chunkStart: Double = 0

        for seg in segments {
            if current.isEmpty {
                chunkStart = seg.startTime
            }
            current.append(seg)
            let chunkDuration = seg.endTime - chunkStart
            if chunkDuration >= minDuration {
                chunks.append(DisplayChunk(startTime: chunkStart, segments: current))
                current = []
            }
        }
        if !current.isEmpty {
            if var tail = chunks.last {
                chunks.removeLast()
                tail.segments.append(contentsOf: current)
                chunks.append(tail)
            } else {
                chunks.append(DisplayChunk(startTime: chunkStart, segments: current))
            }
        }
        return chunks
    }
}

/// Display-only aggregation of adjacent same-speaker segments into ≥N-second chunks.
/// Used for rendering; diarization data itself is untouched.
struct DisplayChunk {
    let startTime: Double
    var segments: [TranscriptSegment]
    var joinedText: String { segments.map(\.text).joined(separator: " ") }
}

enum SegmentGrouping {
    /// Fold consecutive segments with the same speaker into runs.
    /// Key = speakerId when available, else speakerLabel, else a sentinel per-segment
    /// so unknown-speaker segments never glue together.
    static func groupRuns(_ segments: [TranscriptSegment]) -> [SegmentRun] {
        var runs: [SegmentRun] = []
        var current: [TranscriptSegment] = []
        var currentKey: String?

        func flush() {
            guard let first = current.first, let firstId = first.id else {
                current.removeAll()
                currentKey = nil
                return
            }
            runs.append(SegmentRun(
                id: firstId,
                speakerId: first.speakerId,
                speakerLabel: first.speakerLabel,
                segments: current
            ))
            current.removeAll()
            currentKey = nil
        }

        for (idx, seg) in segments.enumerated() {
            var key = seg.speakerId ?? seg.speakerLabel.map { "label:\($0)" } ?? "none:\(idx)"
            // Excluded segments form their own runs so the dimmed style and
            // the «вернуть» menu act on exactly the hidden stretch.
            if seg.isExcluded { key += ":excluded" }
            if key == currentKey {
                current.append(seg)
            } else {
                flush()
                currentKey = key
                current.append(seg)
            }
        }
        flush()
        return runs
    }

    /// Auto-mode decision: does a single speaker dominate > threshold of speaking time?
    /// MVP: whole-meeting view. Revisit with rolling window if perceived differently.
    static func shouldUseSmart(_ segments: [TranscriptSegment], threshold: Double = 0.7) -> Bool {
        guard !segments.isEmpty else { return false }
        var totalByKey: [String: Double] = [:]
        var total: Double = 0
        for seg in segments {
            let key = seg.speakerId ?? seg.speakerLabel ?? "unknown"
            let d = max(0, seg.endTime - seg.startTime)
            totalByKey[key, default: 0] += d
            total += d
        }
        guard total > 0 else { return false }
        let dominant = totalByKey.values.max() ?? 0
        return dominant / total >= threshold
    }
}

/// One row of the transcript list: a speaker run, or a dictation made during
/// the meeting, shown where it happened.
enum TranscriptRow: Identifiable {
    case run(SegmentRun)
    case dictation(MeetingMark)

    var id: String {
        switch self {
        case .run(let run): "run-\(run.id)"
        case .dictation(let mark): "dictation-\(mark.id ?? 0)"
        }
    }

    /// Runs in order, each dictation before the first run starting at or after it.
    static func merge(_ runs: [SegmentRun], dictations: [MeetingMark]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var pending = dictations.sorted { $0.startTime < $1.startTime }[...]
        for run in runs {
            while let next = pending.first, next.startTime <= run.startTime {
                rows.append(.dictation(next))
                pending = pending.dropFirst()
            }
            rows.append(.run(run))
        }
        rows += pending.map(TranscriptRow.dictation)
        return rows
    }
}

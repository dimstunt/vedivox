import FluidAudio
import Foundation

enum TranscriptMerger {

    /// Rebuild transcript segments from raw ASR tokens along diarization
    /// boundaries (WhisperX-style).
    ///
    /// The legacy path (`TokenGrouper.group` + `mapSpeakerLabels`) groups tokens
    /// by silence/length/punctuation FIRST and labels whole groups by
    /// max-overlap SECOND — a group that straddles a speaker change gets one
    /// speaker for both voices ("Понимаешь меня?" → Тимур), and TokenGrouper's
    /// merge-tiny-into-previous step glues short interjections to the previous
    /// speaker ("прогресс?" → Ирма). Reassembly inverts the order: each token is
    /// assigned a speaker by max-overlap of ITS OWN timing, consecutive
    /// same-speaker tokens form runs, and only within a run does TokenGrouper's
    /// silence/length/punctuation logic subdivide further.
    ///
    /// Returns `nil` when tokens or diarization are missing — caller falls back
    /// to the legacy path.
    static func assembleByDiarization(
        tokens: [TokenTiming],
        diarization: [DiarizationService.DiarizationSegment],
        meetingId: String,
        source: SegmentSource
    ) -> [TranscriptSegment]? {
        guard !tokens.isEmpty, !diarization.isEmpty else { return nil }

        // 1. Per-token speaker by max overlap; nil = token outside all
        // diarization segments (silence-adjacent ASR artifacts) → UNKNOWN run,
        // same vocabulary the legacy path produced for unmatched segments.
        // Punctuation-only tokens carry no voice — a boundary "?" whose timing
        // drifted onto the next speaker's side must stay with the utterance it
        // terminates, so they never open or re-key a run. Same for a subword
        // continuation (no leading space): a word belongs to the speaker of its
        // first token, never split across two («По про|центную»).
        struct Run {
            var speaker: String?
            var tokens: [TokenTiming]
        }
        var runs: [Run] = []
        for token in TokenGrouper.clampStretchedEnds(tokens) {
            let text = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctOnly = !text.isEmpty && text.allSatisfy { $0.isPunctuation || $0.isWhitespace }
            let continuesWord = token.token.first.map { !$0.isWhitespace } ?? false
            if punctOnly || continuesWord, var last = runs.last {
                last.tokens.append(token)
                runs[runs.count - 1] = last
                continue
            }
            let speaker = bestDiarMatch(start: token.startTime, end: token.endTime, diarization: diarization)
            if var last = runs.last, last.speaker == speaker {
                last.tokens.append(token)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(speaker: speaker, tokens: [token]))
            }
        }

        // 2. Within a run, reuse the silence/length/punctuation subdivision.
        // Each reply carries its own voice: the overlap-weighted mean of its
        // label's diarization segments, not the first segment of the run
        // (segment-own-voice § 2).
        let voicesByLabel = timedVoicesByLabel(diarization)
        var out: [TranscriptSegment] = []
        for run in runs {
            for grouped in TokenGrouper.group(run.tokens) {
                let text = grouped.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    meetingId: meetingId,
                    speakerLabel: run.speaker ?? "UNKNOWN",
                    source: source,
                    startTime: grouped.startTime,
                    endTime: grouped.endTime,
                    text: text,
                    confidence: grouped.confidence,
                    embedding: run.speaker.flatMap {
                        ownEmbedding(start: grouped.startTime, end: grouped.endTime, voices: voicesByLabel[$0] ?? [])
                    }
                ))
            }
        }
        return out
    }

    /// Diarization segments as timed voices, grouped by speaker label.
    static func timedVoicesByLabel(
        _ diarization: [DiarizationService.DiarizationSegment]
    ) -> [String: [SegmentVoice.Timed]] {
        Dictionary(grouping: diarization, by: \.speaker)
            .mapValues { $0.map { SegmentVoice.Timed(start: $0.start, end: $0.end, vector: $0.embedding) } }
    }

    /// A reply's own vector: overlap-weighted mean of its label's diarization
    /// segments, or the nearest of them when none overlaps.
    static func ownEmbedding(start: Double, end: Double, voices: [SegmentVoice.Timed]) -> Data? {
        SegmentVoice.vector(start: start, end: end, from: voices).map { Speaker.encodeEmbedding($0.vector) }
    }

    /// Map diarization speaker labels and embeddings onto system segments by maximum time overlap.
    static func mapSpeakerLabels(
        segments: [TranscriptSegment],
        diarization: [DiarizationService.DiarizationSegment]
    ) -> [TranscriptSegment] {
        segments.map { segment in
            var mapped = segment
            let match = findBestMatch(
                start: segment.startTime,
                end: segment.endTime,
                diarization: diarization
            )
            mapped.speakerLabel = match.speaker
            mapped.embedding = match.embedding
            return mapped
        }
    }

    /// Merge mic and system segments by interleaving on startTime.
    static func merge(
        micSegments: [TranscriptSegment],
        systemSegments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        // The segments keep their originating track. This used to stamp
        // everything `.merged`, which nothing ever read — and it erased the
        // one signal track-scoped exclusion marks match on, so a mic-track
        // mark could never hide a mic segment of a two-stream meeting
        // (transcript-exclusion-marks, C2).
        (micSegments + systemSegments)
            .sorted { $0.startTime < $1.startTime }
    }

    /// Max-overlap diarization match for a (token-sized) interval. A token with
    /// no overlap at all still attaches to the nearest diarization segment
    /// within `attachTolerance` — ASR token timings routinely stick out past
    /// diarization activity by a few hundred ms, and the legacy group-level
    /// majority silently bridged that (an UNKNOWN here scores as confusion).
    /// Only genuinely isolated tokens return nil.
    private static func bestDiarMatch(
        start: Double,
        end: Double,
        diarization: [DiarizationService.DiarizationSegment],
        attachTolerance: Double = 0.75
    ) -> String? {
        var best: String?
        var bestOverlap = 0.0
        for seg in diarization {
            let overlap = max(0.0, min(end, seg.end) - max(start, seg.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = seg.speaker
            }
        }
        if best == nil {
            var bestDistance = attachTolerance
            for seg in diarization {
                let distance = max(seg.start - end, start - seg.end)
                if distance <= bestDistance {
                    bestDistance = distance
                    best = seg.speaker
                }
            }
        }
        return best
    }

    /// Find the diarization segment with maximum overlap for a time range.
    /// `overlap == 0` means the range had no diarization coverage at all —
    /// distinct from overlapping a segment that is itself labeled UNKNOWN.
    static func findBestMatch(
        start: Double,
        end: Double,
        diarization: [DiarizationService.DiarizationSegment]
    ) -> (speaker: String, embedding: Data?, overlap: Double) {
        var bestSpeaker = "UNKNOWN"
        var bestEmbedding: [Float]?
        var bestOverlap = 0.0

        for seg in diarization {
            let overlapStart = max(start, seg.start)
            let overlapEnd = min(end, seg.end)
            let overlap = max(0.0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = seg.speaker
                bestEmbedding = seg.embedding
            }
        }

        let embeddingData = bestEmbedding.map { Speaker.encodeEmbedding($0) }
        return (speaker: bestSpeaker, embedding: embeddingData, overlap: bestOverlap)
    }
}

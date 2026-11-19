import FluidAudio
import Foundation

/// Groups FluidAudio token timings into transcript segments.
/// Ported from fa-transcribe CLI (transcribe-bench/Sources/FATranscribe/main.swift).
enum TokenGrouper {
    struct Segment {
        let startTime: Double // seconds
        let endTime: Double // seconds
        let text: String
        let confidence: Double?
    }

    /// Groups token timings into segments for transcript display.
    /// Splits on: (1) silence gaps, (2) max duration, (3) sentence-ending punctuation.
    static func group(
        _ tokens: [TokenTiming],
        maxDuration: TimeInterval = 5.0,
        gapThreshold: TimeInterval = 0.3
    ) -> [Segment] {
        let tokens = clampStretchedEnds(tokens)
        guard !tokens.isEmpty else { return [] }

        let punctuation: Set<Character> = [".", "!", "?", "。", "！", "？"]

        var segments: [Segment] = []
        var currentTokens: [TokenTiming] = [tokens[0]]

        for i in 1 ..< tokens.count {
            let prev = tokens[i - 1]
            let curr = tokens[i]
            let gap = curr.startTime - prev.endTime
            let segDuration = curr.endTime - currentTokens.first!.startTime

            let hasGap = gap > gapThreshold
            let tooLong = segDuration > maxDuration
            let prevEndsSentence = prev.token.last.map { punctuation.contains($0) } ?? false

            // Break only before a word start: a token without a leading space is
            // a subword continuation or punctuation, which TDT often emits late —
            // a split there cut "rollo|ut." / "Android 1|2.".
            let startsWord = curr.token.first?.isWhitespace ?? false

            if startsWord, hasGap || tooLong || (prevEndsSentence && segDuration > 1.0) {
                segments.append(makeSegment(from: currentTokens))
                currentTokens = [curr]
            } else {
                currentTokens.append(curr)
            }
        }

        if !currentTokens.isEmpty {
            segments.append(makeSegment(from: currentTokens))
        }

        // Merge tiny segments (< 0.5s) into previous segment
        var merged: [Segment] = []
        for seg in segments {
            let duration = seg.endTime - seg.startTime
            let textTrimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPunctOnly = textTrimmed.allSatisfy { $0.isPunctuation || $0.isWhitespace }
            if duration < 0.5 || (isPunctOnly && !merged.isEmpty) {
                // A tiny segment after a long silence is its own utterance: the
                // merge must not bridge past maxDuration.
                if let prev = merged.last, isPunctOnly || seg.endTime - prev.startTime <= maxDuration {
                    merged[merged.count - 1] = Segment(
                        startTime: prev.startTime,
                        endTime: seg.endTime,
                        text: prev.text + seg.text,
                        confidence: avg(prev.confidence, seg.confidence)
                    )
                    continue
                }
            }
            merged.append(seg)
        }

        return merged
    }

    /// A real TDT token lasts at most 4 encoder frames (0.32 s). FluidAudio gives
    /// a zero-duration token endTime = the next token's start, so the token before
    /// a pause spans the whole silence («?» 98,6–184,8 s, mic segments
    /// up to 1447 s). Anything longer than this is that fallback.
    static let maxTokenDuration: TimeInterval = 0.5

    static func clampStretchedEnds(_ tokens: [TokenTiming]) -> [TokenTiming] {
        tokens.map { t in
            guard t.endTime - t.startTime > maxTokenDuration else { return t }
            return TokenTiming(
                token: t.token, tokenId: t.tokenId, startTime: t.startTime,
                endTime: t.startTime + maxTokenDuration, confidence: t.confidence
            )
        }
    }

    private static func makeSegment(from tokens: [TokenTiming]) -> Segment {
        let text = tokens.map(\.token).joined()
        let avgConfidence = Double(tokens.map(\.confidence).reduce(0.0, +)) / Double(tokens.count)
        return Segment(
            startTime: tokens.first!.startTime,
            endTime: tokens.last!.endTime,
            text: text,
            confidence: avgConfidence
        )
    }

    private static func avg(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (a?, b?): (a + b) / 2.0
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }
}

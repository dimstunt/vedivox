import Foundation

/// The meeting's live text as it accumulates (an earlier change, design
/// D5/D6). Pure and synchronous, so what may be given out and in what shape is
/// testable without audio or a model.
///
/// Times are seconds from the start of the recording — the clock marks live on.
struct LiveTranscriptLog: Sendable {
    struct Entry: Equatable, Sendable {
        let track: SegmentSource
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        /// Key of the voice in `LiveSpeakerBook`; nil — the microphone, or a
        /// piece with no voice to go by.
        var speaker: Int?
        /// Put by a precise pass, not by quick recognition.
        var refined = false
    }

    /// A run of one speaker's entries: the reading unit of the output.
    struct Turn: Equatable, Sendable {
        let track: SegmentSource
        var speaker: LiveSpeaker
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    private(set) var entries: [Entry] = []
    /// How far a precise pass has refined each track (an earlier change,
    /// design D4): quick text for earlier moments is no longer wanted.
    private(set) var refinedUntil: [SegmentSource: TimeInterval] = [:]

    /// A tail cuts speech wherever it starts, so the first phrase of a pass
    /// may be a stump: where an earlier pass already refined the text, the new
    /// one takes over no sooner than this far into its tail.
    static let seamGuard: TimeInterval = 3
    /// Two passes hear the same pause a few tenths of a second apart.
    static let seamSlack: TimeInterval = 0.5

    /// Adds what a recogniser heard on `track`, said by the voice `speaker`
    /// where the book could tell. Blank text is not an entry, and neither is
    /// quick text for a moment a precise pass has already covered.
    mutating func add(_ piece: LivePiece, track: SegmentSource, speaker: Int? = nil) {
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, (piece.start + piece.end) / 2 >= refinedUntil[track] ?? -.infinity else { return }
        entries.append(Entry(
            track: track, start: piece.start, end: max(piece.end, piece.start), text: text, speaker: speaker
        ))
    }

    /// A precise pass over [from, to] of `track` replaces what was there.
    ///
    /// Where an earlier pass refined the head of this stretch, the new pass
    /// takes over at a boundary both heard: the start of its first phrase,
    /// past the guard, that no line of the earlier pass runs across. Lines are
    /// whole turns of a speaker and can last a minute — replacing by position
    /// alone cut such a line in two and lost one half (9 % of the words with a
    /// two-minute tail).
    mutating func refine(
        track: SegmentSource, from: TimeInterval, to: TimeInterval,
        with pieces: [(piece: LivePiece, speaker: Int?)]
    ) {
        let refined = refinedUntil[track] ?? -.infinity
        var cut = from
        if refined > from {
            let earlier = entries.filter { $0.track == track && $0.refined }
            cut = pieces.map(\.piece.start).sorted().first { start in
                start >= from + Self.seamGuard
                    && !earlier.contains { $0.start < start - Self.seamSlack && $0.end > start + Self.seamSlack }
            } ?? to
        }
        // Refined lines go by where they start — the seam is a boundary of
        // theirs; quick pieces, cut at other places, by where their middle is.
        entries.removeAll { entry in
            guard entry.track == track, entry.start < to else { return false }
            return entry.refined ? entry.start >= cut - Self.seamSlack : (entry.start + entry.end) / 2 >= cut
        }
        for (piece, speaker) in pieces where piece.start >= cut - Self.seamSlack && piece.start < to {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            entries.append(Entry(
                track: track, start: piece.start, end: max(piece.end, piece.start), text: text, speaker: speaker,
                refined: true
            ))
        }
        refinedUntil[track] = max(refined, to)
    }

    /// What may be given out: entries that end after `cutoff`, minus those the
    /// exclusion rule would hide from the transcript, merged into turns.
    ///
    /// `marks` are the meeting's marks plus any interval still open; the rule
    /// is the transcript's own (`ExclusionProjection`), so live text and the
    /// final transcript hide the same speech. `speakers` is the book's table
    /// as of now: a voice named since the entry was made reads by its name.
    func turns(
        after cutoff: TimeInterval? = nil,
        marks: [MeetingMark] = [],
        speakers: [LiveSpeaker] = [],
        mergeGap: TimeInterval = 20,
        maxTurn: TimeInterval = 60
    ) -> [Turn] {
        // Labelled before anything is cut away: who said a piece must not
        // depend on how far back the reader asked to look.
        labelled(speakers)
            .filter { entry, _ in cutoff.map { entry.end > $0 } ?? true }
            .filter { entry, _ in
                !ExclusionProjection.isExcluded(
                    // A zero-length entry would never count as covered.
                    segmentStart: entry.start, segmentEnd: max(entry.end, entry.start + 0.01),
                    track: entry.track, marks: marks
                )
            }
            .reduce(into: [Turn]()) { turns, labelled in
                let (entry, speaker) = labelled
                // A monologue still gets a time anchor every minute.
                if let last = turns.last, last.track == entry.track,
                   last.speaker.kind == speaker.kind, last.speaker.name == speaker.name,
                   entry.start - last.end <= mergeGap, entry.end - last.start <= maxTurn {
                    turns[turns.count - 1].end = max(last.end, entry.end)
                    turns[turns.count - 1].text += " " + entry.text
                    // Two clusters of one named voice: the surer of the two.
                    if let confidence = speaker.confidence {
                        turns[turns.count - 1].speaker.confidence = max(last.speaker.confidence ?? confidence, confidence)
                    }
                } else {
                    turns.append(Turn(
                        track: entry.track, speaker: speaker, start: entry.start, end: entry.end, text: entry.text
                    ))
                }
            }
    }

    /// A piece without a voice of its own takes its neighbour's label when one
    /// ended, or starts, within this many seconds of it.
    static let inheritGap: TimeInterval = 2

    /// Every entry in time order with who said it (an earlier change,
    /// design D5): the microphone is the owner; the call track reads its key
    /// in `speakers`. A line a precise pass left without a speaker — too short
    /// for a voice — takes the label of the piece before it, failing that of
    /// the piece after it. Quick text nobody has refined yet stays `others`:
    /// it has not been listened to for a voice at all.
    func labelled(_ speakers: [LiveSpeaker]) -> [(entry: Entry, speaker: LiveSpeaker)] {
        let ordered = entries.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var labels = ordered.map { entry -> LiveSpeaker? in
            guard entry.track == .system else { return .me }
            return entry.speaker.flatMap { speakers.indices.contains($0) ? speakers[$0] : nil }
        }
        // The neighbour before wins over the one after, so a label once
        // inherited does not move when somebody else speaks next.
        var before: (end: TimeInterval, speaker: LiveSpeaker)?
        for index in ordered.indices where ordered[index].track == .system {
            if labels[index] == nil, ordered[index].refined, let before, ordered[index].start - before.end <= Self.inheritGap {
                labels[index] = before.speaker
            }
            if let speaker = labels[index] { before = (ordered[index].end, speaker) }
        }
        var after: (start: TimeInterval, speaker: LiveSpeaker)?
        for index in ordered.indices.reversed() where ordered[index].track == .system {
            if labels[index] == nil, ordered[index].refined, let after, after.start - ordered[index].end <= Self.inheritGap {
                labels[index] = after.speaker
            }
            if let speaker = labels[index] { after = (ordered[index].start, speaker) }
        }
        return zip(ordered, labels).map { ($0, $1 ?? .others) }
    }
}

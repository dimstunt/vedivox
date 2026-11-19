import Foundation

/// The answer to `live_transcript`: one
/// document that says what was heard and how far to trust an empty list.
///
/// Here rather than in `AppState`, so the wire shape and the hiding of excluded
/// speech are tested without an app host.
enum LiveTranscriptCommand {
    /// Who a turn is said by. A live
    /// label: put by a few seconds of voice, never stored.
    struct Speaker: Codable, Equatable {
        /// `me` — the microphone; `known` — a confirmed speaker recognised by
        /// voice; `unknown` — a voice without a name, or nobody in particular.
        let kind: String
        /// `me`, the speaker's name, `Speaker N`, or `others`.
        let name: String
        /// Similarity of the voice to the named speaker's voiceprint; only
        /// with `known`.
        var confidence: Double?

        init(_ speaker: LiveSpeaker) {
            kind = speaker.kind.rawValue
            name = speaker.name
            confidence = speaker.confidence.map { (Double($0) * 100).rounded() / 100 }
        }
    }

    /// One turn on the wire; also the row of `vedivox live --json`.
    struct Row: Codable, Equatable {
        let speaker: Speaker
        let track: String
        let from: Double
        let to: Double
        let text: String
    }

    /// The turns that may leave the log: inside the window asked for, minus
    /// speech an exclusion mark hides, with the vocabulary pass the final
    /// transcript gets. One function for `vedivox live` and for the meeting's
    /// window, so the two cannot show different text.
    ///
    /// - Parameters:
    ///   - last: only what was said in the last `last` seconds; nil for the whole recording.
    ///   - marks: the meeting's marks plus any exclusion interval still open.
    static func turns(
        snapshot: MeetingLiveTranscript.Snapshot,
        last: TimeInterval?,
        marks: [MeetingMark],
        normaliser: Normaliser
    ) -> [LiveTranscriptLog.Turn] {
        normaliser.normalise(
            snapshot.log.turns(after: last.map { snapshot.elapsed - $0 }, marks: marks, speakers: snapshot.speakers)
        )
    }

    /// The vocabulary pass over turns, remembered by their text: the
    /// window reads the whole log every second, and all turns but the one
    /// still growing are the same as a second ago. Not thread-safe — one
    /// reader owns it.
    final class Normaliser {
        let vocabulary: TermNormalizer.Vocabulary
        /// Texts passed through the vocabulary so far — what a test counts.
        private(set) var passes = 0
        private var memo: [String: String] = [:]

        init(vocabulary: TermNormalizer.Vocabulary) {
            self.vocabulary = vocabulary
        }

        func normalise(_ turns: [LiveTranscriptLog.Turn]) -> [LiveTranscriptLog.Turn] {
            // Only this reading's texts are kept, so the growing turn's
            // earlier versions do not pile up over an hour.
            var kept: [String: String] = [:]
            let result = turns.map { turn in
                var normalised = turn
                if let known = kept[turn.text] ?? memo[turn.text] {
                    normalised.text = known
                } else {
                    passes += 1
                    normalised.text = TermNormalizer.normalize(turn.text, vocabulary: vocabulary)
                }
                kept[turn.text] = normalised.text
                return normalised
            }
            memo = kept
            return result
        }
    }

    static func response(
        meetingId: String,
        snapshot: MeetingLiveTranscript.Snapshot,
        last: TimeInterval?,
        marks: [MeetingMark],
        vocabulary: TermNormalizer.Vocabulary
    ) -> AppCommandResponse {
        let rows = turns(
            snapshot: snapshot, last: last, marks: marks, normaliser: Normaliser(vocabulary: vocabulary)
        ).map { turn in
            Row(
                speaker: Speaker(turn.speaker),
                track: turn.track.rawValue,
                from: (turn.start * 10).rounded() / 10,
                to: (turn.end * 10).rounded() / 10,
                text: turn.text
            )
        }
        let json = (try? JSONEncoder().encode(rows)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        return .success(
            "Live transcript: \(rows.count) turn(s), recognition \(snapshot.readiness.rawValue)",
            data: [
                "meeting_id": meetingId,
                "state": snapshot.readiness.rawValue,
                "elapsed": String(format: "%.1f", snapshot.elapsed),
                "dropped_seconds": String(format: "%.1f", snapshot.droppedSeconds),
                "turns": json,
            ]
        )
    }
}

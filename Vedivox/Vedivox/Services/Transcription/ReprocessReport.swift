import Foundation

/// Who spoke when before and after a reprocess, compared by time: how much
/// speech changed hands and how much is anonymous on each side. Logged after
/// every reprocess, so «did it fix the lines I reprocessed for» has an answer
/// without a copy of the database.
struct ReprocessReport: Equatable {
    struct Move: Equatable {
        let from: String
        let to: String
        let seconds: Double
    }

    /// Speech of anonymous voices (`speaker_N`, UNKNOWN, no speaker), hidden lines aside.
    let anonymousBefore: Double
    let anonymousAfter: Double
    /// Speech that changed hands, overlap by time.
    let moved: Double
    /// Speech after the reprocess, hidden lines aside.
    let total: Double
    /// Changed hands, most first; pairs under `minSeconds` are left out.
    let moves: [Move]

    /// `names`: speaker id → display name, gathered before (anonymous rows of
    /// the old transcript are deleted) and after. A line's own label stands in
    /// for an id the map does not know.
    init(before: [TranscriptSegment], after: [TranscriptSegment], names: [String: String], minSeconds: Double = 3) {
        func name(_ line: TranscriptSegment) -> String {
            line.speakerId.flatMap { names[$0] } ?? line.speakerLabel ?? "UNKNOWN"
        }
        func who(_ line: TranscriptSegment) -> String { line.isExcluded ? name(line) + " (hidden)" : name(line) }
        func isAnonymousName(_ name: String) -> Bool { name == "UNKNOWN" || Speaker.isAutoLabel(name) }
        func isAnonymous(_ line: TranscriptSegment) -> Bool { !line.isExcluded && isAnonymousName(name(line)) }
        func speech(_ lines: [TranscriptSegment]) -> Double {
            lines.reduce(0) { $0 + max($1.endTime - $1.startTime, 0) }
        }

        var pairs: [String: [String: Double]] = [:]
        var moved = 0.0
        let old = before.sorted { $0.startTime < $1.startTime }
        for line in after {
            for prior in old {
                guard prior.startTime < line.endTime else { break }
                // A mixed track overlaps either new track; separate tracks only themselves.
                guard prior.endTime > line.startTime,
                      prior.source == line.source || prior.source == .merged || line.source == .merged
                else { continue }
                let (from, to) = (who(prior), who(line))
                // A renumbered anonymous voice changed no hands.
                guard from != to, !(isAnonymousName(name(prior)) && isAnonymousName(name(line))) else { continue }
                let seconds = min(prior.endTime, line.endTime) - max(prior.startTime, line.startTime)
                pairs[from, default: [:]][to, default: 0] += seconds
                // Hidden or shown again, same person: listed, not counted as a change of hands.
                if name(prior) != name(line) { moved += seconds }
            }
        }
        let all = pairs.flatMap { from, targets in targets.map { Move(from: from, to: $0.key, seconds: $0.value) } }
        anonymousBefore = speech(before.filter(isAnonymous))
        anonymousAfter = speech(after.filter(isAnonymous))
        self.moved = moved
        total = speech(after.filter { !$0.isExcluded })
        moves = all.filter { $0.seconds >= minSeconds }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : ($0.from, $0.to) < ($1.from, $1.to) }
    }

    /// One log line: "anonymous 10.2 → 1.1 min, 12.3 of 69.2 min changed hands: speaker_1 → Alice 4.7, …".
    var summary: String {
        func minutes(_ seconds: Double) -> String { String(format: "%.1f", seconds / 60) }
        var line = "anonymous \(minutes(anonymousBefore)) → \(minutes(anonymousAfter)) min, "
            + "\(minutes(moved)) of \(minutes(total)) min changed hands"
        guard !moves.isEmpty else { return line }
        let shown = moves.prefix(15).map { "\($0.from) → \($0.to) \(minutes($0.seconds))" }
        line += ": " + shown.joined(separator: ", ")
        if moves.count > 15 { line += ", … \(moves.count - 15) more" }
        return line
    }
}

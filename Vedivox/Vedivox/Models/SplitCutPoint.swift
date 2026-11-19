import Foundation

/// Where the Split sheet's cut point starts and how it steps: on a
/// two-hour meeting the mouse alone cannot hit a turn boundary, so the cut
/// opens at the turn being played and moves by a second or by a turn.
enum SplitCutPoint {
    /// The start of the segment under `playhead`; the middle when nothing has played.
    static func initial(playhead: Double?, segmentStarts: [Double], duration: Double) -> Double {
        guard let playhead, playhead > 0 else { return clamped((duration / 2).rounded(), duration) }
        return clamped(segmentStarts.last { $0 <= playhead } ?? playhead, duration)
    }

    /// The nearest segment start strictly after (or before) `time`; `time` when there is none.
    static func segmentStep(from time: Double, segmentStarts: [Double], forward: Bool, duration: Double) -> Double {
        let next = forward ? segmentStarts.first { $0 > time } : segmentStarts.last { $0 < time }
        return clamped(next ?? time, duration)
    }

    /// Both halves keep at least a second, as a click on the waveform does.
    static func clamped(_ time: Double, _ duration: Double) -> Double {
        min(max(time, 1), max(1, duration - 1))
    }
}

/// How Trim's two bounds move from the keyboard, the way Split's
/// cut does: by a second, or to the neighbouring turn — starts for the start,
/// ends for the end, so the whole turn stays in. `range` keeps each bound a
/// second from the other.
enum TrimBound {
    /// The nearest stop strictly after (or before) `time`, inside `range`; `time` when there is none.
    static func segmentStep(from time: Double, stops: [Double], forward: Bool, within range: ClosedRange<Double>) -> Double {
        let next = forward ? stops.first { $0 > time } : stops.last { $0 < time }
        return clamped(next ?? time, within: range)
    }

    static func clamped(_ time: Double, within range: ClosedRange<Double>) -> Double {
        min(max(time, range.lowerBound), range.upperBound)
    }

    /// The sheet's «keeps N, deletes M», by the rule of `MeetingRepository.trimMeeting`:
    /// only a turn wholly outside the bounds is deleted, one a bound cuts through stays.
    static func counts(segments: [(start: Double, end: Double)], from: Double, to: Double) -> (keep: Int, remove: Int) {
        let keep = segments.filter { $0.end > from && $0.start < to }.count
        return (keep, segments.count - keep)
    }
}

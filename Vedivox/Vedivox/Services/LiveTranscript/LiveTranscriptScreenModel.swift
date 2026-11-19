import Foundation
import Observation

/// What the window of the meeting being recorded shows in place of a
/// transcript: the live text as it is
/// recognised, read from the same in-memory log `vedivox live` reads.
///
/// Here rather than in a view, so what is shown and when the text follows the
/// speaker is tested without a window.
@MainActor
@Observable
final class LiveTranscriptScreenModel {
    struct Row: Identifiable, Equatable {
        /// Track and start: a turn keeps it while text is appended to it.
        let id: String
        let speaker: LiveSpeaker
        let time: String
        let text: String

        init(_ turn: LiveTranscriptLog.Turn) {
            id = "\(turn.track.rawValue)-\(turn.start)"
            speaker = turn.speaker
            time = LiveTranscriptScreenModel.clock(turn.start)
            text = turn.text
        }
    }

    enum Content: Equatable {
        /// Live transcript is switched off: the transcript comes after the stop.
        case off
        /// Recognition is on and nobody has said anything yet.
        case listening
        case turns([Row])
    }

    /// nil until the first reading, so a window does not flash one state
    /// before settling into another.
    private(set) var content: Content?
    /// The reader is at the end of the text, so new text scrolls into view.
    /// Off once they scroll up to read, on again when they come back down.
    private(set) var followsLatest = true
    /// Changes whenever the view should scroll to the end.
    private(set) var scrollTick = 0

    /// `turns`: the live text so far; nil — this recording has none.
    func show(_ turns: [LiveTranscriptLog.Turn]?) {
        let shown: Content = turns.map { $0.isEmpty ? .listening : .turns($0.map(Row.init)) } ?? .off
        guard shown != content else { return }
        content = shown
        if followsLatest { scrollTick += 1 }
    }

    /// The view reports whether the end of the text is on screen.
    func readerScrolled(atEnd: Bool) {
        followsLatest = atEnd
    }

    /// Reads the live text until the task is cancelled — once a second: text
    /// arrives a phrase at a time, and the reading is a look into memory.
    /// Skips the reading while `visible` says nobody can see it: a closed main
    /// window lingers with its views alive.
    func follow(
        every interval: Duration = .seconds(1),
        while visible: @escaping @MainActor () -> Bool = { true },
        read: @escaping @MainActor () async -> [LiveTranscriptLog.Turn]?
    ) async {
        while !Task.isCancelled {
            if visible() { show(await read()) }
            try? await Task.sleep(for: interval)
        }
    }

    /// Seconds from the start of the recording as 4:07 or 1:04:07.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

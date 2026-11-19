import Foundation

/// The one-time «star Vedivox on GitHub» card in the main window: after the fifth
/// processed meeting, never while something records or processes, and gone
/// for good after either button.
enum StarPrompt {
    static let dismissedKey = "starPromptDismissed"
    static let threshold = 5

    static func shouldShow(processedMeetings: Int, dismissed: Bool, busy: Bool) -> Bool {
        !dismissed && !busy && processedMeetings >= threshold
    }
}

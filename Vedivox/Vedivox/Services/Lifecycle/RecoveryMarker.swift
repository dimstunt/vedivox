import Foundation

/// The meeting whose automatic recovery is running, so a launch can tell a
/// recovery that died from one that has not been tried. The «not processed»
/// banner's Reprocess sets it too (`FailedMeetingsOffer`).
///
/// One automatic attempt per meeting: a recovery that crashed the app left the
/// meeting in progress, and every launch walked into the same crash. A normal
/// termination — Quit in the "still processing" question, a logout — drops
/// the mark, so the next launch runs the recovery again.
struct RecoveryMarker {
    var defaults: UserDefaults = .standard
    private static let key = "recoveringMeetingId"
    private static let crashedKey = "crashedMeetingIds"

    /// Meetings whose processing took the app down. Kept after the mark is
    /// spent: the «not processed» banner leaves them out.
    var crashed: Set<String> { Set(defaults.stringArray(forKey: Self.crashedKey) ?? []) }

    func begin(_ meetingId: String) { defaults.set(meetingId, forKey: Self.key) }

    func end() { defaults.removeObject(forKey: Self.key) }

    /// Whether the recovery of `meetingId` began and never ended. Spends the mark.
    func diedDuring(_ meetingId: String) -> Bool {
        guard defaults.string(forKey: Self.key) == meetingId else { return false }
        end()
        defaults.set(crashed.union([meetingId]).sorted(), forKey: Self.crashedKey)
        return true
    }
}

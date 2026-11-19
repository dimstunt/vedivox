import Foundation
import Observation

/// The «N meetings were not processed» offer: its state and the
/// one run of Reprocess over the meetings it names.
///
/// Held by AppState, not by the banner. The main window is rebuilt on ⌘W and
/// on a palette switch while a run goes on: a banner that kept "running" in
/// its own `@State` came back with Reprocess enabled, and «Not Now» forgotten.
@MainActor @Observable
final class FailedMeetingsOffer {
    /// «Not Now», until the next launch.
    var dismissed = false
    private(set) var isRunning = false
    private let marker: RecoveryMarker

    init(marker: RecoveryMarker = RecoveryMarker()) { self.marker = marker }

    /// The meetings the offer names: the failed ones, minus those whose
    /// processing took the app down. Reprocess over such a meeting is the same
    /// crash again, and the meetings after it in the run are never reached.
    /// Its own Reprocess button stays.
    func candidates(among meetings: [Meeting]) -> [Meeting] {
        let crashed = marker.crashed
        return meetings.filter { $0.status == .error && !crashed.contains($0.id) }
    }

    /// Reprocesses `meetingIds` one at a time: each run loads the whole recording.
    ///
    /// `stillFailed` is asked right before each meeting, not once at the
    /// click: one processed by its own button in the meantime would be
    /// processed again, and the speaker edits made since would be gone.
    func run(
        _ meetingIds: [String],
        stillFailed: @MainActor (String) async -> Bool,
        reprocess: @MainActor (String) async -> Void
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        for id in meetingIds {
            guard await stillFailed(id) else { continue }
            // Marked like a recovery: if this takes the app down, the next
            // launch marks the meeting failed (and `candidates` drops it)
            // instead of walking into the same crash in its automatic recovery.
            // shortcut: the mark holds one meeting, so next to an orphan's recovery only the later of the two is covered (the other gets the old second crash); make the mark a set if that overlap shows up.
            marker.begin(id)
            await reprocess(id)
            marker.end()
        }
    }
}

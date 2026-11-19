import XCTest

/// Crash recovery reprocesses what a previous run left unfinished. Taking this
/// run's own work for that ran a second pipeline over a recording in progress
/// and deleted the WAV under the recorder.
final class OrphanedMeetingsTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 10000)

    private func meeting(_ title: String, _ status: MeetingStatus, createdBeforeLaunch: Bool = true) -> Meeting {
        var meeting = makeMeeting(title: title, status: status)
        meeting.createdAt = launch.addingTimeInterval(createdBeforeLaunch ? -60 : 1)
        return meeting
    }

    func testUnfinishedMeetingsOfAPreviousRunAreOrphans() {
        let all = [
            meeting("recording", .recording), meeting("transcribing", .transcribing),
            meeting("diarizing", .diarizing),
            meeting("done", .done), meeting("failed", .error), meeting("attention", .needsAttention),
        ]

        let orphans = Meeting.orphans(among: all, launchedAt: launch, live: [])

        XCTAssertEqual(orphans.map(\.title), ["recording", "transcribing", "diarizing"])
    }

    func testWorkOfThisRunIsNeverAnOrphan() {
        // Started by a command that arrived while the app was still loading.
        let recordingNow = meeting("recording now", .recording, createdBeforeLaunch: false)
        let importRunning = meeting("import running", .transcribing, createdBeforeLaunch: false)
        // An old meeting this run is reprocessing.
        let reprocessRunning = meeting("reprocess running", .diarizing)
        let crashed = meeting("crashed", .transcribing)

        let orphans = Meeting.orphans(
            among: [recordingNow, importRunning, reprocessRunning, crashed],
            launchedAt: launch, live: [reprocessRunning.id]
        )

        XCTAssertEqual(orphans.map(\.title), ["crashed"])
    }
}

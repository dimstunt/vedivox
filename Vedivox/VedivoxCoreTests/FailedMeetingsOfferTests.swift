import XCTest

/// Reprocess on the «N meetings were not processed» banner.
@MainActor
final class FailedMeetingsOfferTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "FailedMeetingsOfferTests-\(UUID().uuidString)")!

    /// What a launch sees: a new marker over the same defaults.
    private var marker: RecoveryMarker { RecoveryMarker(defaults: defaults) }

    private func offer() -> FailedMeetingsOffer { FailedMeetingsOffer(marker: marker) }

    /// The list is as old as the click. A meeting processed by its own button
    /// since then must not be processed again: the speaker edits made after
    /// its first run would be gone.
    func testMeetingProcessedSinceTheClickIsLeftAlone() async {
        var failed: Set = ["A", "B", "C"]
        var reprocessed: [String] = []

        await offer().run(["A", "B", "C"], stillFailed: { failed.contains($0) }, reprocess: { id in
            reprocessed.append(id)
            failed.remove("B") // its own Reprocess button, while A was running
        })

        XCTAssertEqual(reprocessed, ["A", "C"])
    }

    /// ⌘W and a reopened window mid-run: a new banner over the same offer.
    /// Its Reprocess must not start a second run next to the first.
    func testSecondRunWhileTheFirstIsGoingDoesNothing() async {
        let offer = offer()
        var reprocessed: [String] = []

        await offer.run(["A"], stillFailed: { _ in true }, reprocess: { id in
            reprocessed.append(id)
            XCTAssertTrue(offer.isRunning)
            await offer.run(["B"], stillFailed: { _ in true }, reprocess: { reprocessed.append($0) })
            XCTAssertTrue(offer.isRunning, "the refused click must not end the run in progress")
        })

        XCTAssertEqual(reprocessed, ["A"])
        XCTAssertFalse(offer.isRunning)
    }

    /// A meeting whose processing took the app down is not offered: Reprocess
    /// over it is the same crash, and the meetings after it are never reached.
    func testMeetingThatCrashedTheAppIsNotOffered() {
        let done = makeMeeting(title: "done", status: .done)
        let failed = makeMeeting(title: "failed", status: .error)
        let crasher = makeMeeting(title: "crasher", status: .error)
        marker.begin(crasher.id)
        XCTAssertTrue(marker.diedDuring(crasher.id)) // the launch after the crash

        XCTAssertEqual(offer().candidates(among: [done, failed, crasher]).map(\.title), ["failed"])
    }

    /// The app dies inside the banner's Reprocess. The next launch must take
    /// it for a crash — error at once, not the same crash again in the
    /// automatic recovery — and the meeting is out of the offer from then on.
    func testRunThatDiesIsACrashForTheNextLaunch() async {
        var diedDuringA = false

        await offer().run(["A", "B"], stillFailed: { _ in true }, reprocess: { id in
            // What the next launch would find, had the app died right here.
            if id == "A" { diedDuringA = self.marker.diedDuring("A") }
        })

        XCTAssertTrue(diedDuringA)
        XCTAssertEqual(marker.crashed, ["A"])
        XCTAssertFalse(marker.diedDuring("B"), "a run that finished leaves no mark")
    }
}

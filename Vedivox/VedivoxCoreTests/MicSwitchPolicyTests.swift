import Foundation
import XCTest

/// Which input the mic track moves to mid-recording, and when (
///): down at once when the current one is lost, up only after the
/// better one has stayed connected — a Bluetooth bounce must not cost a hole —
/// and never back onto an input that failed, until it is replugged.
final class MicSwitchPolicyTests: XCTestCase {

    private let hold = MicSwitchPolicy.upHold
    private let lost = MicSwitchPolicy.lostReason
    private let better = MicSwitchPolicy.betterReason

    /// Connected inputs with made-up device IDs; a replug is a new ID.
    private func ids(_ uids: String...) -> [String: UInt32] {
        let known: [String: UInt32] = ["desk": 10, "laptop": 20, "buds": 30, MicrophoneCapture.builtInMicUID: 40]
        return Dictionary(uniqueKeysWithValues: uids.map { ($0, known[$0] ?? 99) })
    }

    /// A policy the way a recording has it after its first engine build:
    /// what is connected then has been there all along.
    private func started(
        _ order: [String?] = ["desk", "laptop", nil], movesUp: Bool = true, connected: [String: UInt32]
    ) -> MicSwitchPolicy {
        var policy = MicSwitchPolicy(order: order, movesUp: movesUp)
        _ = policy.buildOrder(current: nil, restarting: false, connected: connected, now: 0)
        return policy
    }

    // MARK: - Moving a running engine

    func testTheBestInputConnectedStays() {
        var policy = started(connected: ids("desk", "laptop"))
        XCTAssertEqual(policy.decide(current: "desk", connected: ids("desk", "laptop"), now: 1), .stay)
        XCTAssertEqual(policy.decide(current: "desk", connected: ids("desk", "laptop"), now: 60), .stay)
    }

    /// No hold on the way down: there is no working engine to protect.
    func testLosingTheCurrentInputMovesDownAtOnce() {
        var policy = started(connected: ids("desk", "laptop"))
        XCTAssertEqual(
            policy.decide(current: "desk", connected: ids("laptop"), now: 0.5),
            .move(to: "laptop", reason: lost)
        )
    }

    func testNothingElseFromTheListFallsToSystemDefault() {
        var policy = started(connected: ids("desk"))
        XCTAssertEqual(policy.decide(current: "desk", connected: [:], now: 5), .move(to: nil, reason: lost))
    }

    func testABetterInputIsTakenOnlyAfterTheHold() {
        var policy = started(connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("laptop"), now: 5), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 10), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 10 + hold - 0.1), .stay)
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 10 + hold),
            .move(to: "desk", reason: better)
        )
    }

    /// Bluetooth bounce: connected, gone a second later, back again — the
    /// hold starts over, so the track is not moved onto a flickering device.
    func testABounceRestartsTheHold() {
        var policy = started(connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 10), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("laptop"), now: 11), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 12), .stay)
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 10 + hold + 0.1), .stay,
            "the hold counts from the second sight"
        )
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 12 + hold),
            .move(to: "desk", reason: better)
        )
    }

    /// The unplug and the replug both fell between two looks at the devices:
    /// the UID never left, but the device ID is new — the hold starts over.
    func testAReplugBetweenTwoLooksRestartsTheHold() {
        var policy = started(connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 10), .stay)
        var replugged = ids("desk", "laptop")
        replugged["desk"] = 11
        XCTAssertEqual(policy.decide(current: "laptop", connected: replugged, now: 12), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: replugged, now: 10 + hold + 0.1), .stay)
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: replugged, now: 12 + hold),
            .move(to: "desk", reason: better)
        )
    }

    func testALowerInputConnectingChangesNothing() {
        var policy = started(connected: ids("desk"))
        XCTAssertEqual(policy.decide(current: "desk", connected: ids("desk", "laptop"), now: 100), .stay)
        XCTAssertEqual(policy.decide(current: "desk", connected: ids("desk", "laptop"), now: 200), .stay)
    }

    /// From the system default up to a listed input: the same hold.
    func testSystemDefaultMovesUpToAListedInput() {
        var policy = started(connected: [:])
        XCTAssertEqual(policy.decide(current: nil, connected: [:], now: 1), .stay)
        XCTAssertEqual(policy.decide(current: nil, connected: ids("laptop"), now: 5), .stay)
        XCTAssertEqual(
            policy.decide(current: nil, connected: ids("laptop"), now: 5 + hold),
            .move(to: "laptop", reason: better)
        )
    }

    /// What sits below "System default" is never reached while the default works.
    func testInputsBelowSystemDefaultAreNotTaken() {
        var policy = started(["desk", nil, "laptop"], connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: nil, connected: ids("laptop"), now: 100), .stay)
    }

    /// The current input is lost while a better one is still in its hold: the
    /// track goes to an input that has stayed, and up only when the hold is over.
    func testLosingTheCurrentInputDoesNotJumpOntoANewcomer() {
        var policy = started(["desk", "buds", "laptop", nil], connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("laptop"), now: 5), .stay)
        // Still on the laptop mic; the buds show up, then the laptop mic goes.
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("buds", "laptop"), now: 10), .stay)
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: ids("buds"), now: 11),
            .move(to: nil, reason: lost)
        )
        XCTAssertEqual(
            policy.decide(current: nil, connected: ids("buds"), now: 10 + hold),
            .move(to: "buds", reason: better)
        )
    }

    // MARK: - Inputs that failed

    /// listed, but would not start. Not gone back to, however long
    /// it stays connected — until a replug gives it a new device ID.
    func testAFailedInputIsNotGoneBackToUntilItIsReplugged() {
        var policy = started(connected: ids("desk", "laptop"))
        policy.markFailed("desk")
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 100), .stay)

        var replugged = ids("desk", "laptop")
        replugged["desk"] = 11
        XCTAssertEqual(policy.decide(current: "laptop", connected: replugged, now: 200), .stay, "replugged: the hold")
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: replugged, now: 200 + hold),
            .move(to: "desk", reason: better)
        )
    }

    /// The system default would not start and the last resort is in use: no
    /// way back to the default in this recording, whatever it points at now.
    func testAFailedSystemDefaultIsNotGoneBackTo() {
        var policy = started(["desk", nil, "laptop"], connected: ids("laptop"))
        policy.markFailed(nil)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("laptop"), now: 100), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("laptop", "buds"), now: 200), .stay)
    }

    /// Lost, and everything else has failed: nothing to move to. The engine
    /// dies and the rebuild goes through the last resorts.
    func testNothingUsableStays() {
        var policy = started(connected: ids("desk", "laptop"))
        policy.markFailed("laptop")
        policy.markFailed(nil)
        XCTAssertEqual(policy.decide(current: "desk", connected: ids("laptop"), now: 5), .stay)
        XCTAssertEqual(
            policy.buildOrder(current: "desk", restarting: true, connected: ids("laptop"), now: 6),
            ["laptop", nil]
        )
    }

    // MARK: - Dictation and the single picker

    /// Dictation: the input is picked at start; only its loss moves the track.
    func testDictationNeverMovesUp() {
        var policy = started(movesUp: false, connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 1), .stay)
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 100), .stay)
        XCTAssertEqual(
            policy.decide(current: "laptop", connected: ids("desk"), now: 101),
            .move(to: "desk", reason: lost)
        )
    }

    /// Priority off: the single picker, then the built-in mic, then the
    /// system default — the picked mic lost and plugged back in.
    func testPriorityOffLeavesAndReturnsToThePickedMic() {
        let builtIn = MicrophoneCapture.builtInMicUID
        let order = MicrophoneCapture.inputCandidates(selected: "desk")
        XCTAssertEqual(order, ["desk", builtIn, nil])
        var policy = started(order, connected: ids("desk", builtIn))
        XCTAssertEqual(
            policy.decide(current: "desk", connected: ids(builtIn), now: 10),
            .move(to: builtIn, reason: lost)
        )
        XCTAssertEqual(policy.decide(current: builtIn, connected: ids("desk", builtIn), now: 20), .stay)
        XCTAssertEqual(
            policy.decide(current: builtIn, connected: ids("desk", builtIn), now: 20 + hold),
            .move(to: "desk", reason: better)
        )
    }

    // MARK: - What an engine build tries

    func testTheFirstBuildTakesTheListInOrder() {
        var policy = MicSwitchPolicy(order: ["desk", "buds", "laptop", nil], movesUp: true)
        XCTAssertEqual(
            policy.buildOrder(current: nil, restarting: false, connected: ids("laptop", "buds"), now: 0),
            ["buds", "laptop", nil]
        )
    }

    /// The engine died while a better input was still in its hold (Bluetooth
    /// headphones connecting kill the built-in mic's engine): the
    /// rebuild does not jump onto the newcomer.
    func testARebuildKeepsToTheHold() {
        var policy = started(connected: ids("laptop"))
        XCTAssertEqual(
            policy.buildOrder(current: "laptop", restarting: true, connected: ids("desk", "laptop"), now: 10),
            ["laptop", nil, "desk"]
        )
        XCTAssertEqual(
            policy.buildOrder(current: "laptop", restarting: true, connected: ids("desk", "laptop"), now: 10 + hold),
            ["desk", "laptop", nil]
        )
    }

    /// Dictation restarts on the input it has, even with a better one that
    /// has stayed; after losing it, the order decides.
    func testDictationRestartsOnTheInputItHas() {
        var policy = started(movesUp: false, connected: ids("laptop"))
        XCTAssertEqual(policy.decide(current: "laptop", connected: ids("desk", "laptop"), now: 1), .stay)
        XCTAssertEqual(
            policy.buildOrder(current: "laptop", restarting: true, connected: ids("desk", "laptop"), now: 50),
            ["laptop", "desk", nil]
        )
        XCTAssertEqual(
            policy.buildOrder(current: "laptop", restarting: true, connected: ids("desk"), now: 60),
            ["desk", nil]
        )
    }

    /// What failed is tried again only when nothing else starts.
    func testFailedInputsAreTheLastResort() {
        var policy = started(["desk", nil, "laptop"], connected: ids("desk", "laptop"))
        policy.markFailed("desk")
        policy.markFailed(nil)
        XCTAssertEqual(
            policy.buildOrder(current: "desk", restarting: true, connected: ids("desk", "laptop"), now: 5),
            ["laptop", "desk", nil]
        )
    }

    // MARK: - Device change log line

    private let desk = MicPriority.Device(uid: "desk", name: "Desk USB Mic")
    private let laptop = MicPriority.Device(uid: "laptop", name: "Laptop Microphone")
    private let buds = MicPriority.Device(uid: "buds", name: "Wireless Buds")

    func testDeviceChangeIsDescribedByName() {
        let before = AudioDeviceSnapshot(
            inputs: [desk, laptop], inputIDs: ids("desk", "laptop"),
            defaultInput: "Desk USB Mic", defaultOutput: "Laptop Speakers"
        )
        let after = AudioDeviceSnapshot(
            inputs: [laptop, buds], inputIDs: ids("laptop", "buds"),
            defaultInput: "Wireless Buds", defaultOutput: "Wireless Buds"
        )
        XCTAssertEqual(
            after.changes(from: before),
            "inputs +Wireless Buds −Desk USB Mic; default input Desk USB Mic → Wireless Buds; default output Laptop Speakers → Wireless Buds"
        )
    }

    func testOnlyWhatChangedIsDescribed() {
        let before = AudioDeviceSnapshot(
            inputs: [desk, laptop], inputIDs: ids("desk", "laptop"),
            defaultInput: "Laptop Microphone", defaultOutput: "Laptop Speakers"
        )
        var after = before
        XCTAssertNil(after.changes(from: before))
        after.defaultOutput = nil
        XCTAssertEqual(after.changes(from: before), "default output Laptop Speakers → none")

        // Unplugged and plugged back between two looks: same UID, new device ID.
        var replugged = before
        replugged.inputIDs["desk"] = 11
        XCTAssertEqual(replugged.changes(from: before), "inputs ↻Desk USB Mic")
    }
}

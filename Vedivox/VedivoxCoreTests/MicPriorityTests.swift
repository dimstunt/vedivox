import Foundation
import XCTest

/// The microphone priority list: which input the recording opens,
/// and where a device seen for the first time lands.
final class MicPriorityTests: XCTestCase {

    private let desk = MicPriority.Device(uid: "desk-usb", name: "Desk USB Mic")
    private let laptop = MicPriority.Device(uid: "laptop", name: "Laptop Microphone")
    private let buds = MicPriority.Device(uid: "buds", name: "Wireless Buds")
    private let loopback = MicPriority.Device(uid: "loop", name: "Loopback Driver", isVirtual: true)

    func testEverythingConnectedPicksTheFirst() {
        let list = MicPriority(devices: [desk, laptop, MicPriority.systemDefault])
        XCTAssertEqual(list.pick(connected: ["desk-usb", "laptop"]), "desk-usb")
    }

    func testFirstUnavailablePicksTheNextConnected() {
        let list = MicPriority(devices: [desk, laptop, MicPriority.systemDefault])
        XCTAssertEqual(list.pick(connected: ["laptop", "buds"]), "laptop")
    }

    func testNothingFromTheListConnectedFallsToSystemDefault() {
        XCTAssertNil(MicPriority(devices: [desk, laptop, MicPriority.systemDefault]).pick(connected: ["buds"]))
        XCTAssertNil(MicPriority(devices: [desk, laptop]).pick(connected: ["buds"]))
    }

    func testSystemDefaultShadowsWhatIsBelowIt() {
        let list = MicPriority(devices: [desk, MicPriority.systemDefault, laptop])
        XCTAssertNil(list.pick(connected: ["laptop"]))
    }

    func testNewDeviceGoesToTheEndAndIsNotPicked() {
        var list = MicPriority(devices: [desk, MicPriority.systemDefault])
        list.remember([buds])
        XCTAssertEqual(list.devices.map(\.uid), ["desk-usb", "", "buds"])
        XCTAssertNil(list.pick(connected: ["buds"]))
    }

    func testNewRealMicGoesBeforeTrailingVirtualOnes() {
        var list = MicPriority(devices: [desk, MicPriority.systemDefault])
        list.remember([loopback, laptop])
        XCTAssertEqual(list.devices.map(\.uid), ["desk-usb", "", "laptop", "loop"])
    }

    func testKnownDeviceKeepsItsPlaceAndTakesItsCurrentName() {
        var list = MicPriority.seeded(selectedUID: "desk-usb")
        XCTAssertEqual(list.devices.first?.name, "desk-usb")
        list.remember([laptop, desk])
        XCTAssertEqual(list.devices.map(\.uid), ["desk-usb", "", "laptop"])
        XCTAssertEqual(list.devices.first?.name, "Desk USB Mic")
    }

    /// The single picker's choice becomes the head of the list, so turning
    /// priority on opens the same mic as before.
    func testMigrationFromTheSinglePicker() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MicPriorityTests-\(UUID().uuidString)"))
        defaults.set("desk-usb", forKey: "selectedMicDeviceUID")
        XCTAssertEqual(MicPriority.load(defaults).devices.map(\.uid), ["desk-usb", ""])
        XCTAssertEqual(MicPriority.load(defaults).pick(connected: ["desk-usb", "laptop"]), "desk-usb")

        defaults.removeObject(forKey: "selectedMicDeviceUID")
        XCTAssertEqual(MicPriority.load(defaults).devices.map(\.uid), [""])
    }

    func testPriorityOffUsesTheSinglePicker() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MicPriorityTests-\(UUID().uuidString)"))
        let builtIn = MicrophoneCapture.builtInMicUID
        XCTAssertEqual(MicPriority.captureOrder(defaults, connected: []), [nil, builtIn])
        defaults.set("desk-usb", forKey: "selectedMicDeviceUID")
        MicPriority(devices: [laptop, MicPriority.systemDefault]).save(defaults)
        XCTAssertEqual(MicPriority.captureOrder(defaults, connected: [laptop]), ["desk-usb", builtIn, nil])
    }

    /// Priority on: the whole list down to "System default" is the order the
    /// recording follows — connected or not, so a mic plugged in later counts.
    func testPriorityOnFollowsTheListDownToSystemDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MicPriorityTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: MicPriority.enabledKey)
        MicPriority(devices: [desk, buds, MicPriority.systemDefault, laptop]).save(defaults)
        XCTAssertEqual(
            MicPriority.captureOrder(defaults, connected: [buds, loopback]),
            ["desk-usb", "buds", nil, MicrophoneCapture.builtInMicUID]
        )
        XCTAssertEqual(MicPriority.load(defaults).devices.map(\.uid), ["desk-usb", "buds", "", "laptop", "loop"], "seen devices are remembered")
    }

    func testSavedListRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MicPriorityTests-\(UUID().uuidString)"))
        let list = MicPriority(devices: [buds, MicPriority.systemDefault, loopback])
        list.save(defaults)
        XCTAssertEqual(MicPriority.load(defaults), list)
    }
}

import CoreGraphics
import XCTest

/// A removed event tap must leave no registration in WindowServer.
///
/// Disabling a tap without invalidating its port keeps the entry in the system
/// tap table until the process exits; every dictation leaked one. The tap here
/// listens to mouse moves, which needs no Accessibility permission, so the test
/// runs headless — the teardown under test is the same for the Escape tap.
final class EventTapLeakTests: XCTestCase {

    func testRemovedTapLeavesNoRegistration() throws {
        let before = Self.tapCount()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            throw XCTSkip("no window server session (ssh, a headless runner) — no tap to create")
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        XCTAssertEqual(Self.tapCount(), before + 1, "the tap should be registered while installed")

        DictationController.removeEventTap(tap, source: source)

        XCTAssertEqual(Self.tapCount(), before, "a removed tap must not stay registered in WindowServer")
    }

    /// Entries in the system tap table owned by this process, enabled or not.
    private static func tapCount() -> Int {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 16)
        CGGetEventTapList(UInt32(taps.count), &taps, &count)
        return taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }.count
    }
}

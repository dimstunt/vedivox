import XCTest

/// Which physical key carries "v" when ⌘V is synthesized (change
/// `make-dictation-usable`, task 2a.1).
///
/// Both obvious answers are wrong on some machine. A hard-coded 9
/// (`kVK_ANSI_V`) is the position of V only on ANSI-shaped layouts — on Dvorak
/// that key is «.», so the paste goes nowhere. A purely layout-aware lookup
/// breaks on the hybrid «Dvorak — QWERTY ⌘», which switches back to QWERTY
/// exactly while Command is held. Hence: ask the layout what each key produces
/// **under Command**, and keep 9 only as the fallback.
final class PasteKeyCodeTests: XCTestCase {

    /// Stands in for the system layout: a keycode either produces something or
    /// nothing, which is the whole contract `scan` depends on.
    private func layout(_ pairs: [CGKeyCode: String]) -> (CGKeyCode) -> String? {
        { pairs[$0] }
    }

    private final class Probe {
        private(set) var lowest: CGKeyCode = .max
        private(set) var highest: CGKeyCode = .min

        func record(_ code: CGKeyCode) {
            lowest = min(lowest, code)
            highest = max(highest, code)
        }
    }

    func testFindsTheKeyThatProducesV() {
        let dvorak = layout([9: ".", 47: "v"])
        XCTAssertEqual(PasteKeyCode.scan(for: "v", translate: dvorak), 47)
    }

    func testReturnsNothingWhenNoKeyProducesIt() {
        XCTAssertNil(PasteKeyCode.scan(for: "v", translate: layout([9: ".", 47: "w"])))
    }

    /// A layout may report the character in either case; the key is the same one.
    func testMatchesRegardlessOfCase() {
        XCTAssertEqual(PasteKeyCode.scan(for: "v", translate: layout([3: "V"])), 3)
    }

    /// Dead keys and modifiers translate to an empty string.
    func testIgnoresKeysThatProduceNothing() {
        XCTAssertEqual(PasteKeyCode.scan(for: "v", translate: layout([9: "", 47: "v"])), 47)
    }

    /// Ambiguity has to resolve the same way on every launch, or which key gets
    /// pressed would depend on dictionary order.
    func testPrefersTheLowestKeyCode() {
        XCTAssertEqual(PasteKeyCode.scan(for: "v", translate: layout([47: "v", 9: "v"])), 9)
    }

    /// Virtual key codes are a byte. Scanning past 127 asks the layout about
    /// keys that cannot exist, and stopping short of it could miss the real one.
    func testScansEveryRealKeyCode() {
        let asked = Probe()
        _ = PasteKeyCode.scan(for: "v", translate: { code in
            asked.record(code)
            return nil
        })

        XCTAssertEqual(asked.lowest, 0)
        XCTAssertEqual(asked.highest, 127)
    }

    /// Smoke test of the system path: whatever layout this machine has, the
    /// resolver must come back with a usable key rather than crash or hang in
    /// the Text Input Services call.
    func testResolveReturnsAKeyOnWhateverLayoutIsInstalled() {
        let key = PasteKeyCode.resolve()
        XCTAssertLessThanOrEqual(key, 127)
    }
}

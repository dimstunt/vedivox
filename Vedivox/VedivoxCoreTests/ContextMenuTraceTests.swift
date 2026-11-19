import AppKit
import XCTest

/// Which menus get a `[Perf] [ContextMenu]` line, and the delay it reports.
final class ContextMenuTraceTests: XCTestCase {

    func testRightClickCountsFromTheClick() {
        XCTAssertEqual(ContextMenuTrace.latencyMs(type: .rightMouseDown, modifiers: [], clickedAt: 100, now: 100.042), 42)
    }

    func testControlClickIsAContextClick() {
        XCTAssertEqual(ContextMenuTrace.latencyMs(type: .leftMouseDown, modifiers: .control, clickedAt: 5, now: 5.1), 100)
    }

    func testOtherMenusAreNotTraced() {
        XCTAssertNil(ContextMenuTrace.latencyMs(type: .leftMouseDown, modifiers: [], clickedAt: 5, now: 5.1))
        XCTAssertNil(ContextMenuTrace.latencyMs(type: .keyDown, modifiers: .control, clickedAt: 5, now: 5.1))
    }
}

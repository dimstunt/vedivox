import AppKit
import SwiftUI
import XCTest

/// A stand, not a gate: the main window on a copy of a real
/// database, offscreen, right-clicking meeting rows in the sidebar. Per click
/// it logs how long AppKit's `menu(for:)` took to build the menu and how many
/// row bodies SwiftUI evaluated around it; then whether Reveal in Sidebar still
/// reaches the oldest meeting, and what one pass over the whole sidebar costs.
/// The menu is built, never shown: a shown menu lands on the user's screen and
/// holds the keyboard. Skipped unless VEDIVOX_PERF_DB names the copy (recipe in
/// ScreenOpenPerfProbe), e.g.:
///
///     cd Vedivox && TEST_RUNNER_VEDIVOX_DATA_DIR=$(mktemp -d) TEST_RUNNER_VEDIVOX_PERF_DB=<copy> \
///       xcodebuild test -project Vedivox.xcodeproj -scheme VedivoxSnapshotTests -configuration Release \
///       -only-testing:VedivoxSnapshotTests/ContextMenuPerfProbe -destination 'platform=macOS'
@MainActor
final class ContextMenuPerfProbe: XCTestCase {

    func testRightClickOnMeetingRow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["VEDIVOX_PERF_DB"], environment[DataDirectory.environmentKey] != nil else {
            throw XCTSkip("VEDIVOX_PERF_DB and VEDIVOX_DATA_DIR are not set")
        }
        let target = DataDirectory.root.appendingPathComponent("Vedivox-tests.sqlite")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
        Log.level = .debug
        NSApplication.shared.setActivationPolicy(.prohibited)

        let state = AppState()
        await state.loadMeetings()
        await state.loadSeries()
        state.showOnboarding = false
        state.selectedMeetingIds = Set([state.meetings.max { $0.startTime < $1.startTime }?.id].compactMap { $0 })

        let size = CGSize(width: 1400, height: 900)
        let hosting = NSHostingView(rootView: ContentView().environment(state).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = hosting
        _ = try await settle(hosting, for: 3000)
        _ = SidebarMeetingRow.takeBodyCount()

        var clicks = 0
        // Two runs down the column: the second one on rows built by the first.
        for run in [1, 2] {
            _ = try await settle(hosting, for: 150)
            _ = SidebarMeetingRow.takeBodyCount()
            // Down the sidebar column, every 22 pt; a point off a row gets no "Open".
            for y in stride(from: 180.0, through: 860.0, by: 22.0) {
                let point = hosting.convert(CGPoint(x: 120, y: y), to: nil)
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) else { continue }
                var trace = PerfTrace("[Probe] run\(run) y=\(Int(y))")
                // Never `window.sendEvent`: AppKit would pop the menu on the user's
                // screen and its tracking loop would hold the keyboard. `menu(for:)`
                // builds the same menu without showing it.
                var view = hosting.hitTest(hosting.superview?.convert(point, from: nil) ?? point)
                var built: NSMenu?
                var chain: [String] = []
                while let current = view, built == nil {
                    chain.append(String(describing: type(of: current)).prefix(40).description)
                    built = current.menu(for: event)
                    view = current.superview
                }
                trace.checkpoint("menu(for:) bodies \(SidebarMeetingRow.takeBodyCount())")
                guard let menu = built, menu.items.first?.title == "Open" else {
                    print("[Probe] y=\(Int(y)) no meeting menu: \(chain.joined(separator: " < ")) items \(built?.items.map(\.title) ?? [])")
                    continue
                }
                clicks += 1
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.delegate?.menuWillOpen?(menu)
                trace.checkpoint("willOpen bodies \(SidebarMeetingRow.takeBodyCount())")
                let open = try await settle(hosting, for: 150)
                trace.checkpoint("open \(open) bodies \(SidebarMeetingRow.takeBodyCount())")
                menu.delegate?.menuDidClose?(menu)
                let closed = try await settle(hosting, for: 150)
                trace.checkpoint("closed \(closed) bodies \(SidebarMeetingRow.takeBodyCount()) items \(menu.items.count)")
                trace.finish()
            }

        }
        // Reveal of the oldest meeting: the lazy list has not built its day,
        // the sidebar must still scroll to the bottom.
        if let oldest = state.meetings.min(by: { $0.startTime < $1.startTime }) {
            state.selectedMeetingIds = [oldest.id]
            _ = try await settle(hosting, for: 500)
            state.revealInSidebarRequest += 1
            _ = try await settle(hosting, for: 1500)
            var view = hosting.hitTest(hosting.superview?.convert(hosting.convert(CGPoint(x: 120, y: 400), to: nil), from: nil) ?? .zero)
            while let current = view, !(current is NSScrollView) { view = current.superview }
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let visible = scroll.documentVisibleRect
                print(String(format: "[Probe] reveal oldest: visible %.0f–%.0f of %.0f", visible.minY, visible.maxY, document.frame.height))
            }
        }
        // What one pass over the whole sidebar costs: every row reads the
        // shortcut revision (through its menu's Export shortcut).
        for round in 1 ... 5 {
            var trace = PerfTrace("[Probe] sidebar pass \(round)")
            state.shortcutsRevision += 1
            hosting.layoutSubtreeIfNeeded()
            trace.checkpoint("layout bodies \(SidebarMeetingRow.takeBodyCount())")
            trace.finish()
            _ = try await settle(hosting, for: 200)
        }
        print("[Probe] meeting menus built: \(clicks)")
        print("[Probe] ---")
        let log = try String(contentsOf: DataDirectory.logs.appendingPathComponent("vedivox.log"), encoding: .utf8)
        log.split(separator: "\n").filter { $0.contains("[Perf]") }.forEach { print("[Probe] \($0)") }
        window.contentView = nil
        Self.kept.append(hosting)
    }

    /// Views outlive the test, as in ScreenSnapshotTests.
    private static var kept: [NSView] = []

    /// Spins the main run loop for `ms`, forcing layout every 5 ms; returns the
    /// longest stall (a layout pass or a late wake-up), as in ScreenOpenPerfProbe.
    private func settle(_ hosting: NSView, for ms: Double) async throws -> String {
        let end = CFAbsoluteTimeGetCurrent() + ms / 1000
        var longest = 0.0
        var mark = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() < end {
            hosting.layoutSubtreeIfNeeded()
            let laidOut = CFAbsoluteTimeGetCurrent()
            longest = max(longest, (laidOut - mark) * 1000)
            try await Task.sleep(for: .milliseconds(5))
            mark = CFAbsoluteTimeGetCurrent()
            longest = max(longest, (mark - laidOut) * 1000 - 5)
        }
        return String(format: "stall %.0fms", longest)
    }
}

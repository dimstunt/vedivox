import AppKit
import SwiftUI
import XCTest

/// A stand, not a gate: the main window on a copy of a real
/// database, offscreen, switching between Speakers, Series and Listen and back
/// to a meeting, five rounds. Per switch it prints how long the main thread
/// went without turning (the freezes a click feels) and when the screen
/// settled; the screens' own `[Perf] [ScreenOpen]` lines land in the
/// throwaway data directory's log. Skipped unless VEDIVOX_PERF_DB names the copy:
///
///     sqlite3 -readonly Vedivox.sqlite "VACUUM INTO '$TMPDIR/perf/vedivox.sqlite'"
///     cd Vedivox && TEST_RUNNER_VEDIVOX_DATA_DIR=$(mktemp -d) TEST_RUNNER_VEDIVOX_PERF_DB=$TMPDIR/perf/vedivox.sqlite \
///       xcodebuild test -project Vedivox.xcodeproj -scheme VedivoxSnapshotTests -configuration Release \
///       -only-testing:VedivoxSnapshotTests/ScreenOpenPerfProbe -destination 'platform=macOS'
@MainActor
final class ScreenOpenPerfProbe: XCTestCase {

    func testScreenOpening() async throws {
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
        // From the meeting with the most lines, as after reading a long call.
        let longest = try await DatabaseManager.shared.reader.read { db in
            try String.fetchOne(db, sql: """
                SELECT meetingId FROM transcript_segments GROUP BY meetingId ORDER BY COUNT(*) DESC LIMIT 1
                """)
        }
        state.selectedMeetingIds = Set([longest].compactMap { $0 })

        let size = CGSize(width: 1400, height: 900)
        let hosting = NSHostingView(rootView: ContentView().environment(state).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = hosting
        try await run(for: .milliseconds(3000), hosting: hosting)

        var lines: [String] = []
        for round in 1 ... 5 {
            for screen in [AppState.SidebarView.speakers, .series, .listen, .meetings] {
                let start = CFAbsoluteTimeGetCurrent()
                state.view = screen
                let result = try await run(for: .milliseconds(1500), hosting: hosting, start: start)
                lines.append("round \(round) \(screen.rawValue): \(result)")
            }
        }
        print("[Probe] ---")
        lines.forEach { print("[Probe] \($0)") }
        let log = try String(contentsOf: DataDirectory.logs.appendingPathComponent("vedivox.log"), encoding: .utf8)
        log.split(separator: "\n").filter { $0.contains("[ScreenOpen]") || $0.contains("[SpeakersOpen]")
            || $0.contains("ListenQueueBuilder.build") }.forEach { print("[Probe] \($0)") }
        window.contentView = nil
        Self.kept.append(hosting)
    }

    /// Views outlive the test, as in ScreenSnapshotTests.
    private static var kept: [NSView] = []

    /// Spins the main run loop for `duration`, forcing layout every 5 ms. A
    /// stall is a forced layout pass or a late wake-up from the 5 ms sleep
    /// (the main thread was busy with SwiftUI updates or the screen's tasks).
    /// Reports the longest stall, the sum of stalls over 16 ms and when the
    /// last stall over 4 ms ended (the screen settled).
    private func run(
        for duration: Duration, hosting: NSView, start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) async throws -> String {
        var longest = 0.0
        var stalled = 0.0
        var settled = 0.0
        let end = start + Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        var mark = start
        func note(_ ms: Double, at time: CFAbsoluteTime) {
            longest = max(longest, ms)
            if ms > 16 { stalled += ms }
            if ms > 4 { settled = (time - start) * 1000 }
        }
        while CFAbsoluteTimeGetCurrent() < end {
            hosting.layoutSubtreeIfNeeded()
            let laidOut = CFAbsoluteTimeGetCurrent()
            note((laidOut - mark) * 1000, at: laidOut)
            try await Task.sleep(for: .milliseconds(5))
            mark = CFAbsoluteTimeGetCurrent()
            note((mark - laidOut) * 1000 - 5, at: mark)
        }
        return String(format: "longest stall %.0f ms, stalls>16ms %.0f ms, settled %.0f ms", longest, stalled, settled)
    }
}

import AppKit

/// Lightweight performance tracer that records named checkpoints and logs a summary.
/// Usage:
///   var trace = PerfTrace("load(meeting)")
///   // ... work ...
///   trace.checkpoint("db queries")
///   // ... work ...
///   trace.checkpoint("audio load")
///   trace.finish()
///   // → [Perf] load(meeting) 487ms: db queries 42ms, audio load 445ms
struct PerfTrace {
    private let name: String
    private let start: CFAbsoluteTime
    private var lastCheckpoint: CFAbsoluteTime
    private var steps: [(name: String, ms: Int)] = []

    init(_ name: String) {
        self.name = name
        let now = CFAbsoluteTimeGetCurrent()
        self.start = now
        self.lastCheckpoint = now
    }

    mutating func checkpoint(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = Int((now - lastCheckpoint) * 1000)
        steps.append((label, elapsed))
        lastCheckpoint = now
    }

    func finish(fileID: String = #fileID) {
        let total = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let details = steps.map { "\($0.name) \($0.ms)ms" }.joined(separator: ", ")
        Log.debug("[Perf] \(name) \(total)ms: \(details)", fileID: fileID)
    }

    /// A measurement that is not a run of checkpoints: counters gathered over
    /// a stretch of work, e.g. a whole recording. Same `[Perf]` line in the
    /// same log. `always` writes it without debug logging — for the one
    /// summary that has to be there after a real meeting.
    static func report(_ name: String, _ details: String, always: Bool = false, fileID: String = #fileID) {
        if always {
            Log.info("[Perf] \(name): \(details)", fileID: fileID)
        } else {
            Log.debug("[Perf] \(name): \(details)", fileID: fileID)
        }
    }
}

/// One opening of a section of the main window (Speakers, Series, Listen):
/// click → the screen's task starts (`mount`) → its data is in (`data`) → the
/// first frame showing it is committed (`paint`). One `[Perf] [ScreenOpen]`
/// line; calls after the line is written are ignored.
@MainActor
final class ScreenOpenTrace {
    private var trace: PerfTrace
    private var finished = false

    init(_ screen: String) {
        trace = PerfTrace("[ScreenOpen] \(screen)")
    }

    func checkpoint(_ label: String) {
        guard !finished else { return }
        trace.checkpoint(label)
    }

    /// Ends the line once the run loop has committed the frame the screen's
    /// latest state change produced: a one-shot `beforeWaiting` observer,
    /// ordered after SwiftUI's update and Core Animation's commit.
    func finishAfterPaint() {
        guard !finished else { return }
        finished = true
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { [self] _, _ in
            MainActor.assumeIsolated {
                trace.checkpoint("paint")
                trace.finish()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// A context menu's opening: from the right-click (or Control-click) that
/// asked for it to AppKit starting to track the menu on screen. One
/// `[Perf] [ContextMenu]` line per menu, with its item count and never its
/// titles (they can be a speaker's or a series' name); the event's
/// own timestamp counts the wait in the queue too, so it is the delay the
/// user sees. Installed once at launch.
@MainActor
enum ContextMenuTrace {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let event = NSApp.currentEvent,
                      let ms = latencyMs(
                          type: event.type, modifiers: event.modifierFlags,
                          clickedAt: event.timestamp, now: ProcessInfo.processInfo.systemUptime
                      ) else { return }
                PerfTrace.report("[ContextMenu] \(menu?.items.count ?? 0) items", "click→shown \(ms)ms")
            }
        }
    }

    /// nil for a menu not opened by a context click (the menu bar, a pop-up button).
    nonisolated static func latencyMs(
        type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, clickedAt: TimeInterval, now: TimeInterval
    ) -> Int? {
        let contextClick = type == .rightMouseDown || (type == .leftMouseDown && modifiers.contains(.control))
        return contextClick ? Int(((now - clickedAt) * 1000).rounded()) : nil
    }
}

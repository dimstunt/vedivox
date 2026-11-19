import AppKit
import ApplicationServices
import Foundation
import os

/// A call app's mute state as one poll saw it (zoom-mute-exclusion, design D1).
enum MuteState: Equatable, Sendable {
    case muted
    case unmuted
    /// No signal: the app not running or not in a call, no Accessibility, the
    /// app not answering, or a label we do not know. Never hides speech.
    case unknown
}

/// Reads one call app's mute state, read only: it never presses anything.
/// Holds AX elements, so it stays on the polling task that created it.
protocol MuteReader: AnyObject {
    /// For the log: "Zoom", "Teams".
    var appName: String { get }
    /// The `source` of the marks this app's periods become.
    var markSource: MarkSource { get }
    /// The last control label that was not a known one, for the log.
    var unknownLabel: String? { get }
    func read() -> MuteState
}

/// Turns polled observations of one state into closed intervals
/// (zoom-mute-exclusion D3, zoom-unmuted-keeps-mic D3).
///
/// An interval runs from the first to the last observation of `state`: the
/// state began no later than the first and lasted at least until the last, so
/// polling uncertainty always shrinks the interval and never stretches it. A
/// single observation spans no time and yields nothing.
struct StateIntervalTracker {
    let state: MuteState
    private var first: TimeInterval?
    private var last: TimeInterval?

    init(_ state: MuteState) {
        self.state = state
    }

    /// The interval this observation closed, if it ended a period of `state`.
    mutating func observe(_ observed: MuteState, at elapsed: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard observed == state else { return finish() }
        if first == nil { first = elapsed }
        last = elapsed
        return nil
    }

    /// When the period still open was first seen; nil outside one. The live
    /// transcript hides mic speech from here on, before any mark exists.
    var openStart: TimeInterval? { first }

    /// Closes a period still open when the recording stops.
    mutating func finish() -> ClosedRange<TimeInterval>? {
        defer {
            first = nil
            last = nil
        }
        guard let start = first, let end = last, end > start else { return nil }
        return start ... end
    }
}

/// Reads Zoom's mute state from the Meeting menu item `onMuteAudio:` — read
/// only, it never presses anything (design D1). The item's title names the
/// action: "Mute audio" while sound goes to the call, "Unmute audio" while
/// muted. Unlike the participant tiles, the menu answers whatever Space the
/// Zoom window is on.
///
final class ZoomMuteReader: MuteReader {
    static let bundleId = "us.zoom.xos"
    static let timeout: Float = 0.25
    let appName = "Zoom"
    let markSource = MarkSource.zoomMute

    private var item: AXUIElement?
    private var pid: pid_t?
    private(set) var unknownLabel: String?

    func read() -> MuteState {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first
        else {
            item = nil
            return .unknown
        }
        if pid != app.processIdentifier {
            pid = app.processIdentifier
            item = nil
        }
        // The cached item dies with the call (the Meeting menu goes away);
        // a failed read looks it up again.
        if let item, let title = Self.string(item, kAXTitleAttribute) {
            return state(for: title)
        }
        item = Self.findMuteItem(pid: app.processIdentifier)
        guard let item, let title = Self.string(item, kAXTitleAttribute) else { return .unknown }
        return state(for: title)
    }

    private func state(for title: String) -> MuteState {
        switch title {
        case "Unmute audio": return .muted
        case "Mute audio": return .unmuted
        default:
            unknownLabel = title
            return .unknown
        }
    }

    /// Only the English "Meeting" menu is searched: a localized Zoom has other
    /// titles anyway, and scanning every menu each poll costs ~150 AX calls.
    private static func findMuteItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let bar = element(app, kAXMenuBarAttribute),
              let meeting = children(bar).first(where: { string($0, kAXTitleAttribute) == "Meeting" })
        else { return nil }
        for menu in children(meeting) {
            for item in children(menu) where string(item, "AXIdentifier") == "onMuteAudio:" {
                AXUIElementSetMessagingTimeout(item, timeout)
                return item
            }
        }
        return nil
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        value(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let ref = value(element, name), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}

/// Polls the call apps' mute state while a meeting records and writes each
/// muted period as a «не в транскрипт» mark on the mic track
/// (zoom-mute-exclusion). The first app with a known state wins: two calls at
/// once is not a case worth arbitrating.
///
/// Marks are written closed only (design D3): an open mark extends to the end
/// of the meeting, so a crash mid-mute would hide everything after it. Losing
/// an unfinished period instead leaves the speech visible.
@MainActor
final class MuteMonitor {
    /// Named after Zoom, the first reader; the stored key stays as users have it.
    nonisolated static let enabledKey = "zoomMuteExclusionEnabled"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    // ponytail: a push-to-talk tap shorter than one step can go unseen; poll faster if that shows up live.
    nonisolated static let pollInterval: Duration = .milliseconds(500)

    private let markRepo: MarkRepository
    private var task: Task<Void, Never>?
    private var stopRequested: OSAllocatedUnfairLock<Bool>?
    private let openMute = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// Recording-elapsed second at which the mute period going on right now was
    /// first observed; nil when not muted, not known, or not recording. Marks
    /// are written closed only, so until the period ends this is the one place
    /// that knows about it (live-transcript D6).
    var openMuteStart: TimeInterval? { openMute.withLock { $0 } }

    init(markRepo: MarkRepository = MarkRepository()) {
        self.markRepo = markRepo
    }

    /// `recordingStart` is the clock marks live on (`RecordingViewModel.recordingStartTime`).
    func recordingStarted(meetingId: String, recordingStart: Date) {
        guard task == nil, Self.isEnabled() else { return }
        let stop = OSAllocatedUnfairLock(initialState: false)
        stopRequested = stop
        task = Task.detached(priority: .utility) { [markRepo, openMute] in
            await Self.poll(
                meetingId: meetingId, recordingStart: recordingStart, stop: stop, markRepo: markRepo, openMute: openMute
            )
            openMute.withLock { $0 = nil }
        }
    }

    /// Closes a period still open and waits for its mark, so the pipeline that
    /// runs next sees it. Stops by flag, not cancellation: GRDB aborts a write
    /// made from a cancelled task.
    func recordingStopped() async {
        guard let task else { return }
        stopRequested?.withLock { $0 = true }
        await task.value
        self.task = nil
        stopRequested = nil
    }

    private nonisolated static func poll(
        meetingId: String,
        recordingStart: Date,
        stop: OSAllocatedUnfairLock<Bool>,
        markRepo: MarkRepository,
        openMute: OSAllocatedUnfairLock<TimeInterval?>
    ) async {
        let readers: [any MuteReader] = [ZoomMuteReader(), TeamsMuteReader()]
        // Muted periods hide mic speech; unmuted ones keep the foreign-voice
        // rule off it, since that speech went into the call.
        var trackers = [(StateIntervalTracker(.muted), MarkKind.excluded), (StateIntervalTracker(.unmuted), MarkKind.zoomUnmuted)]
        var last: MuteState?
        // The app of the last known state: a period closing on `.unknown` is still its.
        var source = MarkSource.zoomMute
        var loggedLabel: Set<String> = []
        while !stop.withLock({ $0 }) {
            let (state, from) = read(readers)
            if let from { source = from }
            let elapsed = Date().timeIntervalSince(recordingStart)
            if state != last {
                Log.info("Call mute: \(state) at \(String(format: "%.1f", elapsed))s source=\(source.rawValue) meeting=\(meetingId)")
                last = state
            }
            for reader in readers where !loggedLabel.contains(reader.appName) {
                guard let label = reader.unknownLabel else { continue }
                Log.info("\(reader.appName) mute: control label not recognized: \(label)")
                loggedLabel.insert(reader.appName)
            }
            for index in trackers.indices {
                if let range = trackers[index].0.observe(state, at: elapsed) {
                    await write(range, kind: trackers[index].1, source: source, meetingId: meetingId, markRepo: markRepo)
                }
            }
            let mutedSince = trackers[0].0.openStart
            openMute.withLock { $0 = mutedSince }
            try? await Task.sleep(for: pollInterval)
        }
        for index in trackers.indices {
            if let range = trackers[index].0.finish() {
                await write(range, kind: trackers[index].1, source: source, meetingId: meetingId, markRepo: markRepo)
            }
        }
    }

    /// The first reader with a known state wins; nil source while none has one.
    nonisolated static func read(_ readers: [any MuteReader]) -> (state: MuteState, source: MarkSource?) {
        for reader in readers {
            let state = reader.read()
            if state != .unknown { return (state, reader.markSource) }
        }
        return (.unknown, nil)
    }

    private nonisolated static func write(
        _ range: ClosedRange<TimeInterval>,
        kind: MarkKind,
        source: MarkSource,
        meetingId: String,
        markRepo: MarkRepository
    ) async {
        do {
            try await markRepo.add(MeetingMark(
                meetingId: meetingId,
                startTime: range.lowerBound,
                endTime: range.upperBound,
                track: .mic,
                kind: kind,
                source: source
            ))
        } catch {
            Log.error("Call mute: failed to write mark: \(error)")
        }
    }
}

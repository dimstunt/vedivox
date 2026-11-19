import Foundation

/// Recording-time check for a call track that records nothing.
///
/// A refused system-audio grant still records: every call returns noErr and
/// the track is digital zero. Silence alone proves nothing — nothing may be
/// playing — so the warning needs both: a call app has been outputting sound
/// for `threshold` seconds of this recording, and the system track has not
/// had one non-zero sample in all that time. With the grant on, a call's
/// first minute always has some sample above zero (the join chime, a hello,
/// the comfort noise of the call app), and the first one clears the warning
/// for good.
struct SilentCallTrack {
    /// Seconds of call-app output with a zero track before the warning.
    /// shortcut: chosen by reasoning, not measured on calls; raise it if a
    /// webinar waiting room (output on, nothing playing) ever trips it.
    static let threshold: TimeInterval = 60
    /// A longer gap between ticks counts as this much: a stalled main thread
    /// must not count minutes it did not watch.
    static let maxStep: TimeInterval = 10

    private(set) var callOutputSeconds: TimeInterval = 0
    private(set) var heard = false
    private var lastTick: Date?

    /// The warning is up: the call plays, the track hears nothing.
    var warning: Bool { !heard && callOutputSeconds >= Self.threshold }

    /// `heard`: the system track has had a non-zero sample in this recording.
    /// `callOutputting`: a meeting app or a browser is outputting sound now.
    mutating func tick(heard: Bool, callOutputting: Bool, now: Date) {
        defer { lastTick = now }
        if heard { self.heard = true }
        guard let lastTick, callOutputting else { return }
        callOutputSeconds += min(max(now.timeIntervalSince(lastTick), 0), Self.maxStep)
    }

    static let bannerTitle = "No sound from the call"
    static let bannerMessage = "A call app has been playing sound for a minute, but the system audio track is pure silence — system audio access is probably off. Turn Vedivox on in \(PermissionFacts.systemAudioSettingsPath), then stop and start the recording again."
    /// The menu bar's status line while the warning is up.
    static let menuLine = "No sound from the call — system audio access?"
    /// The pipeline's attention name for the meeting afterwards.
    static let attention = "system silent during call"
}

extension SilentCallTrack {
    /// Whether a meeting app or a browser is outputting sound now — the same
    /// process flags meeting detection reads. Core Audio queries: off the main thread.
    static func callAppsOutputting() -> Bool {
        !callAppsOutputtingIDs().isEmpty
    }

    /// The bundle IDs of those apps, sorted, without repeats.
    static func callAppsOutputtingIDs() -> [String] {
        let apps = MeetingDetector.allTargetAppIds.union(ProcessMonitor.browserApps)
        let ids = AudioActivityMonitor().activeAudioProcesses().compactMap { info -> String? in
            guard info.isRunningOutput, let bundleId = info.bundleIdentifier else { return nil }
            let normalized = MeetingDetector.normalizeHelperBundleId(bundleId)
            return apps.contains(normalized) ? normalized : nil
        }
        return Set(ids).sorted()
    }
}

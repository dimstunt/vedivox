import Foundation

/// Info about a detected meeting, passed to the UI layer.
struct DetectedMeetingInfo: Sendable {
    let appBundleId: String
    let appName: String
    /// The series is resolved only when a recording starts: resolving it on
    /// detection left an empty series for every call that was not recorded.
    let calendarEvent: CalendarService.CalendarEvent?

    var displayName: String {
        calendarEvent?.title ?? appName
    }
}

/// Orchestrates meeting detection from process, audio, and browser signals.
///
/// Polls every 5 seconds (every second around a native-app call, see
/// ``pollInterval(now:)``), combining signals from ``AudioActivityMonitor``,
/// ``ProcessMonitor``, and ``BrowserTabDetector``. When a meeting app (or
/// a Meet or Telemost tab in a browser) is both running and actively using audio, fires
/// ``onMeetingDetected``. After `silenceThreshold` of silence (a setting,
/// ``MeetingAutomation/endThreshold``), fires ``onMeetingEnded``.
actor MeetingDetector {
    private let audioMonitor = AudioActivityMonitor()
    private let browserDetector = BrowserTabDetector()
    private var scriptHealth = BrowserScriptHealth()
    private let calendarService: CalendarService

    private var pollTask: Task<Void, Never>?
    private var currentDetection: DetectedMeetingInfo?
    private var silenceSince: Date?
    private var silenceThreshold = MeetingAutomation.defaultEndThreshold
    private var lastEndedAt: Date?

    /// Callbacks fired on MainActor when detection state changes.
    private var onMeetingDetected: (@MainActor @Sendable (DetectedMeetingInfo) -> Void)?
    private var onMeetingEnded: (@MainActor @Sendable () -> Void)?

    /// All known meeting app bundle IDs.
    static let allTargetAppIds = Set(ProcessMonitor.targetApps.keys)

    static let googleMeetId = WebMeetingService.googleMeet.id

    /// Browsers worth asking about a call tab: none while every tab-detected
    /// service is switched off in Settings, otherwise the ones playing audio.
    static func meetCandidateBrowsers(
        activeBundleIds: Set<String>,
        runningBrowsers: Set<String>,
        enabledApps: Set<String>
    ) -> Set<String> {
        guard WebMeetingService.all.contains(where: { enabledApps.contains($0.id) }) else { return [] }
        return activeBundleIds.intersection(runningBrowsers)
    }

    private static let targetAppNames = ProcessMonitor.targetApps

    private static let browserApps = ProcessMonitor.browserApps

    /// Every service id a Settings toggle can enable: the apps and the tab-detected services.
    static let allServiceIds = allTargetAppIds.union(WebMeetingService.all.map(\.id))

    /// Configuration (set from user settings).
    var enabledApps: Set<String> = MeetingDetector.allServiceIds
    var watchedCalendarIDs: [String] = []
    var isEnabled: Bool = true

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    /// Update detection configuration from user settings.
    func updateConfig(enabledApps: Set<String>, watchedCalendarIDs: [String], endThreshold: TimeInterval) {
        self.enabledApps = enabledApps
        self.watchedCalendarIDs = watchedCalendarIDs
        self.silenceThreshold = endThreshold
    }

    func setCallbacks(
        onDetected: @escaping @MainActor @Sendable (DetectedMeetingInfo) -> Void,
        onEnded: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onMeetingDetected = onDetected
        self.onMeetingEnded = onEnded
    }

    func start(processMonitor: ProcessMonitor) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.pollInterval(now: Date()) else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await self.poll(processMonitor: processMonitor)
            }
        }
    }

    /// 1 s during a native-app call and for a minute after its end, so a short
    /// auto stop is not 5 s late and a call that comes back is seen at once.
    /// Browser calls stay at 5 s: each poll asks every tab over Apple Events.
    private func pollInterval(now: Date) -> Int {
        if let currentDetection { return Self.allTargetAppIds.contains(currentDetection.appBundleId) ? 1 : 5 }
        if let lastEndedAt, now.timeIntervalSince(lastEndedAt) < 60 { return 1 }
        return 5
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        currentDetection = nil
        silenceSince = nil
    }

    // MARK: - Polling

    private func poll(processMonitor: ProcessMonitor) async {
        guard isEnabled else { return }

        let activeAudio = audioMonitor.activeAudioProcesses()

        // Build sets of active bundle IDs, normalized from helpers to parent apps.
        // For native meeting apps we require microphone (input) activity to avoid
        // false positives from video/audio playback inside Slack/Zoom.
        var activeBundleIds = Set<String>()
        var activeInputBundleIds = Set<String>()
        for info in activeAudio {
            guard let bid = info.bundleIdentifier else { continue }
            let normalized = Self.normalizeHelperBundleId(bid)
            activeBundleIds.insert(normalized)
            if info.isRunningInput {
                activeInputBundleIds.insert(normalized)
            }
        }

        // Read MainActor-isolated properties.
        let runningTargets = await processMonitor.runningTargetApps
        let runningBrowsers = await processMonitor.runningBrowsers

        // Check native meeting apps (Zoom, Slack, etc.)
        // Require input (microphone) activity — output-only means video playback, not a call.
        var detectedApp: (bundleId: String, name: String)?
        for bid in runningTargets {
            guard enabledApps.contains(bid), activeInputBundleIds.contains(bid) else { continue }
            detectedApp = (bid, Self.targetAppNames[bid] ?? bid)
            break
        }

        // Check Meet and Telemost in a browser (browser audio + tab URL confirmation).
        if detectedApp == nil {
            let pollStart = Date()
            let audioBrowsers = Self.meetCandidateBrowsers(
                activeBundleIds: activeBundleIds,
                runningBrowsers: runningBrowsers,
                enabledApps: enabledApps
            ).filter { scriptHealth.shouldAsk($0, now: pollStart) }
            if !audioBrowsers.isEmpty {
                let detector = browserDetector
                let browsers = audioBrowsers
                let enabled = enabledApps
                let scan = await Task.detached {
                    detector.detect(runningBrowsers: browsers, enabledIds: enabled)
                }.value
                for answer in scan.asked {
                    let line = scriptHealth.record(
                        bundleId: answer.bundleId, name: answer.name, error: answer.error, now: Date()
                    )
                    guard let line else { continue }
                    if answer.error == nil {
                        Log.info(line)
                    } else {
                        Log.error(line)
                    }
                }
                if let found = scan.meeting {
                    detectedApp = (found.service.id, found.service.name)
                }
            }
        }

        if let app = detectedApp {
            silenceSince = nil
            if currentDetection == nil {
                // New meeting detected -- resolve calendar event.
                let calEvent = await calendarService.matchCurrentEvent(
                    watchedCalendarIDs: watchedCalendarIDs
                )
                // stop() may have run during any await above: a cancelled sleep still lets
                // one poll through, and the actor is reentrant at each await.
                guard !Task.isCancelled else { return }
                let detection = DetectedMeetingInfo(
                    appBundleId: app.bundleId,
                    appName: app.name,
                    calendarEvent: calEvent
                )
                currentDetection = detection
                Log.info("Meeting detected: \(app.bundleId) (\(calEvent?.title ?? "no calendar event"))")
                if let callback = onMeetingDetected {
                    await callback(detection)
                }
            }
        } else if currentDetection != nil {
            // Meeting app went silent -- start or check silence timer.
            if silenceSince == nil {
                silenceSince = Date()
            } else if let since = silenceSince,
                      Date().timeIntervalSince(since) >= silenceThreshold {
                Log.info("Meeting ended: \(currentDetection?.appBundleId ?? "?") quiet for \(Int(silenceThreshold)) s")
                lastEndedAt = Self.allTargetAppIds.contains(currentDetection?.appBundleId ?? "") ? Date() : nil
                currentDetection = nil
                silenceSince = nil
                if let callback = onMeetingEnded {
                    await callback()
                }
            }
        }
    }

    /// All known app bundle IDs for normalization (union of targets + browsers).
    private static let allKnownApps: Set<String> = {
        var apps = browserApps
        for bid in allTargetAppIds { apps.insert(bid) }
        return apps
    }()

    /// Maps helper-process bundle IDs back to their parent app.
    /// e.g. "com.tinyspeck.slackmacgap.helper" → "com.tinyspeck.slackmacgap"
    ///       "company.thebrowser.browser.helper" → "company.thebrowser.Browser"
    static func normalizeHelperBundleId(_ bundleId: String) -> String {
        // Note: com.apple.WebKit.GPU is shared by many apps (DeepL, Raycast, etc.)
        // so we cannot map it to Safari — it would cause false positives.

        // Native meeting apps: any sub-bundle maps to the app — Teams' helper
        // ids are not the suffixes below (e.g. com.microsoft.teams2.<x>).
        let lowered = bundleId.lowercased()
        for knownBid in allTargetAppIds where lowered.hasPrefix(knownBid.lowercased() + ".") {
            return knownBid
        }

        // Common suffixes for app helper processes
        let helperSuffixes = [".helper", ".GPU", ".Renderer", ".Plugin"]
        for suffix in helperSuffixes {
            if bundleId.hasSuffix(suffix) {
                let base = String(bundleId.dropLast(suffix.count))
                for knownBid in allKnownApps {
                    if base.caseInsensitiveCompare(knownBid) == .orderedSame {
                        return knownBid
                    }
                }
            }
        }
        return bundleId
    }

}

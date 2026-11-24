import AppKit
import Foundation

/// Which meeting apps and browsers are running right now.
@MainActor
final class ProcessMonitor {
    /// Bundle IDs of native meeting apps to watch, with the name a detected meeting gets.
    nonisolated static let targetApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.microsoft.teams2": "Microsoft Teams",
        // Qt app; its id comes from the Homebrew cask `yandextelemost` (telemost-support D1).
        "ru.yandex.desktop.telemost": "Yandex Telemost",
    ]

    /// Bundle IDs of browsers whose tabs are checked for web calls (Meet, Telemost).
    nonisolated static let browserApps = Set(BrowserTabDetector.browsers.map(\.bundleId))

    /// Read from the live process list on every poll rather than kept from launch/terminate
    /// notifications: after a crash and relaunch the old instance's terminate can arrive after
    /// the new one's launch, and a set keyed by bundle ID then drops an app that is running.
    var runningTargetApps: Set<String> { Self.running(among: Set(Self.targetApps.keys)) }
    var runningBrowsers: Set<String> { Self.running(among: Self.browserApps) }

    private static func running(among ids: Set<String>) -> Set<String> {
        // No isTerminated filter: it costs ms per app on the main thread and changes on the same run loop turn as the list.
        Set(NSWorkspace.shared.runningApplications.lazy.compactMap(\.bundleIdentifier).filter(ids.contains))
    }
}

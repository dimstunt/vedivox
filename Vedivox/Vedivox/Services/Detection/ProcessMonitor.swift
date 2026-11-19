import AppKit
import Foundation

/// Monitors target app launches and terminations via NSWorkspace.
@MainActor @Observable
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

    private(set) var runningTargetApps: Set<String> = []
    private(set) var runningBrowsers: Set<String> = []

    private var launchObserver: (any NSObjectProtocol)?
    private var terminateObserver: (any NSObjectProtocol)?

    func start() {
        // Snapshot current running apps
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            if Self.targetApps.keys.contains(bid) {
                runningTargetApps.insert(bid)
            }
            if Self.browserApps.contains(bid) {
                runningBrowsers.insert(bid)
            }
        }

        let center = NSWorkspace.shared.notificationCenter

        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                if Self.targetApps.keys.contains(bid) {
                    self?.runningTargetApps.insert(bid)
                }
                if Self.browserApps.contains(bid) {
                    self?.runningBrowsers.insert(bid)
                }
            }
        }

        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                self?.runningTargetApps.remove(bid)
                self?.runningBrowsers.remove(bid)
            }
        }
    }

    func stop() {
        if let obs = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        launchObserver = nil
        terminateObserver = nil
    }
}

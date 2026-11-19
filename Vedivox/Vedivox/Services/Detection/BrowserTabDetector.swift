import Foundation

/// A call service recognized by the address of a browser tab (telemost-support D2).
struct WebMeetingService: Sendable {
    /// The id in the detector's `enabledApps`; Meet's predates this type and stays as users have it.
    let id: String
    let name: String
    let isRoom: @Sendable (_ host: String, _ path: String) -> Bool

    static let googleMeet = WebMeetingService(id: "meet.google.com", name: "Google Meet") { host, path in
        // Room codes look like abc-defg-hij; the homepage, landing and settings do not.
        host == "meet.google.com" && path.contains(#/^/[a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}/?$/#)
    }

    /// Rooms are telemost[.360].yandex.<zone>/j/<digits>; the call itself runs in
    /// /private-join/<digits>, some links use /@/j/<digits> (design D3).
    static let telemost = WebMeetingService(id: "telemost.yandex.ru", name: "Yandex Telemost") { host, path in
        // Yandex's own zones only: a free `[a-z]+` zone let telemost.yandex.evil.com in.
        host.contains(#/^telemost\.(360\.)?yandex\.(ru|com|com\.tr|by|kz|uz|az|com\.am|com\.ge|co\.il|md|tj|tm|ee|lv|lt|fr|eu)$/#)
            && path.contains(#/^/(j|@/j|private-join)/[0-9]+/?$/#)
    }

    static let all = [googleMeet, telemost]

    /// The first enabled service with a room among `urls`, in the order of `all`.
    static func first(in urls: [String], enabledIds: Set<String>) -> WebMeetingService? {
        let rooms = urls.compactMap { URLComponents(string: $0) }.compactMap { url -> (String, String)? in
            guard let host = url.host?.lowercased() else { return nil }
            return (host, url.path)
        }
        return all.first { service in
            enabledIds.contains(service.id) && rooms.contains { service.isRoom($0.0, $0.1) }
        }
    }
}

/// Reads browser tab addresses via AppleScript.
struct BrowserTabDetector: Sendable {

    struct DetectedBrowserMeeting: Sendable {
        let service: WebMeetingService
        let browserName: String
    }

    /// Bundle id → the name AppleScript addresses. All of them share Chrome's
    /// `windows`/`tabs`/`URL` dictionary (Brave: checked against its `scripting.sdef`).
    static let browsers: [(bundleId: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.apple.Safari", "Safari"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave Browser"),
    ]

    /// Every tab's URL, one per line; a tab that does not answer (an empty
    /// Safari tab) is skipped instead of failing the whole script.
    private static func script(for app: String) -> String {
        """
        set out to ""
        tell application "\(app)"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set out to out & (URL of t) & linefeed
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
    }

    /// Why a browser did not answer the tab script: -1743 Automation refused, -1712 timed out.
    struct ScriptError: Error, Equatable {
        let code: Int
        let message: String
    }

    /// One pass over the browsers: the call found, and every browser asked with its error, if any.
    struct Scan: Sendable {
        var meeting: DetectedBrowserMeeting?
        var asked: [(bundleId: String, name: String, error: ScriptError?)] = []
    }

    /// The tab addresses of one browser, or why it did not answer. Replaced in
    /// tests: there are no live Apple Events there.
    var readTabs: @Sendable (_ browserName: String) -> Result<[String], ScriptError> = { run(script(for: $0)) }

    /// The lines a script returns, or the error AppleScript reports for it.
    static func run(_ source: String) -> Result<[String], ScriptError> {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error {
            return .failure(ScriptError(
                code: error[NSAppleScript.errorNumber] as? Int ?? 0,
                message: error[NSAppleScript.errorMessage] as? String ?? ""
            ))
        }
        return .success(output?.split(separator: "\n").map(String.init) ?? [])
    }

    /// The first enabled call service open in a tab of these browsers. Call only
    /// while a browser plays audio: each one asked is an Apple Event round trip.
    func detect(runningBrowsers: Set<String>, enabledIds: Set<String>) -> Scan {
        var scan = Scan()
        for browser in Self.browsers where runningBrowsers.contains(browser.bundleId) {
            switch readTabs(browser.name) {
            case .failure(let error):
                scan.asked.append((browser.bundleId, browser.name, error))
            case .success(let urls):
                scan.asked.append((browser.bundleId, browser.name, nil))
                if let service = WebMeetingService.first(in: urls, enabledIds: enabledIds) {
                    scan.meeting = DetectedBrowserMeeting(service: service, browserName: browser.name)
                    return scan
                }
            }
        }
        return scan
    }
}

/// What each browser last answered to the tab script: a failure is logged once
/// per change, and a browser that refuses Automation is asked once a minute
/// instead of on every poll.
struct BrowserScriptHealth {
    static let refusedRetryInterval: TimeInterval = 60
    /// errAEEventNotPermitted: the user refused Vedivox under Automation.
    private static let refused = -1743

    private var lastCode: [String: Int] = [:]
    private var retryAt: [String: Date] = [:]

    func shouldAsk(_ bundleId: String, now: Date) -> Bool {
        retryAt[bundleId].map { now >= $0 } ?? true
    }

    /// Records one answer (`error` nil: the script ran) and returns the log line
    /// when the browser's state changed.
    mutating func record(bundleId: String, name: String, error: BrowserTabDetector.ScriptError?, now: Date) -> String? {
        // Only a refusal backs off: it lasts until System Settings change. Any other
        // error can be momentary, and skipped polls would delay the start of a call.
        let isRefused = error?.code == Self.refused
        retryAt[bundleId] = isRefused ? now.addingTimeInterval(Self.refusedRetryInterval) : nil
        guard lastCode[bundleId] != error?.code else { return nil }
        lastCode[bundleId] = error?.code
        guard let error else { return "\(name) answers the tab script again" }
        let advice = isRefused ? "; allow Vedivox in System Settings → Privacy & Security → Automation (asked again once a minute)" : ""
        return "\(name) did not answer the tab script (\(error.code): \(error.message)), "
            + "Meet and Telemost calls in it are not detected\(advice)"
    }
}

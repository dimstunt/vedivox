import Foundation

/// A semantic version as Vedivox tags its releases: `0.4.2`, `v0.5.0`,
/// `1.0.0-beta.2`. Anything else is nil, so a garbage tag never reads as newer.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers (`beta.2` → ["beta", "2"]); empty for a release.
    let prerelease: [String]

    init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        if let plus = core.firstIndex(of: "+") { core = core[..<plus] } // build metadata never orders
        var pre: [String] = []
        if let dash = core.firstIndex(of: "-") {
            pre = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
            core = core[..<dash]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        (self.major, self.minor, self.patch, self.prerelease) = (major, minor, patch, pre)
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// semver.org §11: a release outranks its pre-releases; pre-release
    /// identifiers compare numerically when both are numbers, else as text,
    /// and numbers rank below text.
    static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// Asks GitHub once a day whether a newer Vedivox is out, and only tells.
///
/// shortcut: только уведомление, без установки; заменить на Sparkle после Developer ID
/// (the design notes).
///
/// The one request is an anonymous GET of the latest release; nothing about
/// the Mac or its data goes with it. Failures stay in the debug log — an
/// offline Mac is not news.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Codable, Equatable {
        let version: String
        let notes: String
        let page: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, failed
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let enabledKey = "checkForUpdates"
    static let lastCheckKey = "updateLastCheck"
    static let latestKey = "updateLatestRelease"
    static let interval: TimeInterval = 24 * 3600

    /// Newer than the running app; nil when there is nothing to offer.
    private(set) var available: Release?
    private(set) var status: Status = .idle

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        // The last answer survives a relaunch; the next request may be a day away.
        if let data = defaults.data(forKey: Self.latestKey),
           let release = try? JSONDecoder().decode(Release.self, from: data) {
            available = newer(release)
        }
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// At launch, then hourly ticks that request only once a day has passed.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func checkIfDue() async {
        guard isEnabled else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now().timeIntervalSince(last) < Self.interval { return }
        await check()
    }

    /// One request now, regardless of the daily limit and of the switch:
    /// Settings → Check Now calls this directly, and the press is the consent.
    func check() async {
        guard status != .checking else { return }
        status = .checking
        // Stamped before the request: a failing network must not turn into a retry every hour.
        defaults.set(now(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: VedivoxLinks.latestReleaseAPI, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetch(request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // 404 until the first release is published; 403 when rate-limited.
                Log.debug("Update check: HTTP \(code)")
                status = .failed
                return
            }
            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let version = SemanticVersion(latest.tag_name), let page = URL(string: latest.html_url) else {
                Log.debug("Update check: unusable tag \(latest.tag_name)")
                status = .failed
                return
            }
            let release = Release(version: version.description, notes: latest.body ?? "", page: page)
            defaults.set(try JSONEncoder().encode(release), forKey: Self.latestKey)
            available = newer(release)
            status = available == nil ? .upToDate : .idle
        } catch {
            Log.debug("Update check failed: \(error.localizedDescription)")
            status = .failed
        }
    }

    private func newer(_ release: Release) -> Release? {
        guard let latest = SemanticVersion(release.version), let current = SemanticVersion(currentVersion),
              current < latest else { return nil }
        return release
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
    }
}

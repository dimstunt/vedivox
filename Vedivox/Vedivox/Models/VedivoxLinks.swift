import Foundation

/// The public names, in one place. The Makefile's `GITHUB_REPO` and
/// `CASK_TOKEN` are the only other copies (release zips, the Homebrew cask);
/// rename both together.
enum VedivoxLinks {
    static let repo = "dimstunt/vedivox"
    static let caskToken = "vedivox"

    static let repository = URL(string: "https://github.com/\(repo)")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// The cask lives in the owner's tap (`<owner>/homebrew-tap`); the full
    /// name also works before the tap is trusted.
    static let brewUpgradeCommand = "brew upgrade --cask \(repo.split(separator: "/")[0])/tap/\(caskToken)"

    /// The app's own link scheme: `vedivox://meeting/<id>?t=<seconds>`.
    static let scheme = "vedivox"

    /// A link to a meeting, and optionally to a moment in it.
    struct MeetingLink: Equatable {
        var meetingId: String
        var seekTime: Double?
    }

    /// Reads a meeting link. Links copied before the rename carry the old
    /// scheme and live on in notes and task lists, so that one is read too;
    /// new links are only ever written with `scheme`.
    static func meetingLink(_ url: URL) -> MeetingLink? {
        guard let linkScheme = url.scheme?.lowercased(),
              linkScheme == scheme || linkScheme == LegacyNames.urlScheme,
              url.host == "meeting" else { return nil }
        let meetingId = url.pathComponents.dropFirst().joined(separator: "/")
        guard !meetingId.isEmpty else { return nil }
        let seekTime = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "t" }
            .flatMap { Double($0.value ?? "") }
        return MeetingLink(meetingId: meetingId, seekTime: seekTime)
    }
}

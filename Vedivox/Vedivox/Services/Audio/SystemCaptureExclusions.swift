import Foundation

/// The user's list of apps kept out of the system-audio tap:
/// an app feeding a virtual mic (OBS → BlackHole) would otherwise put the
/// user's voice into both tracks, and apps playing their own notification
/// sounds (a terminal, a chat app) would leak into the recording.
///
/// Stored as a JSON array of bundle ids, like `watchedCalendarIDs`. A missing
/// key means the defaults; removing an entry writes the key, so a removed
/// default stays removed.
enum SystemCaptureExclusions {
    static let defaultsKey = "systemCaptureExcludedBundleIDs"
    static let defaultBundleIDs = ["com.obsproject.obs-studio"]
    static let defaultJSON = encode(defaultBundleIDs)

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        guard let json = defaults.string(forKey: defaultsKey) else { return defaultBundleIDs }
        return decode(json)
    }

    static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    static func encode(_ ids: [String]) -> String {
        (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The list entry a process belongs to: its bundle id equals the entry or
    /// is a helper under it (`<entry>.…`). Case-insensitive, as CoreAudio
    /// reports bundle ids with the app's own casing.
    static func entry(matching bundleID: String, in list: [String]) -> String? {
        let bundle = bundleID.lowercased()
        return list.first {
            let entry = $0.lowercased()
            return bundle == entry || bundle.hasPrefix(entry + ".")
        }
    }
}

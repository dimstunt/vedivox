import Foundation

/// Defaults that changed for the public release (items 1.3 and
/// 2.10): the palette was Ink, and cmux sat in the system-audio
/// exclusions. An untouched setting is not stored, so a new default alone
/// would quietly change an install that never chose; this writes the old
/// value there, once, before anything reads it.
enum PreviousDefaults {
    static let pinnedKey = "previousDefaultsPinned"

    static var values: [String: String] {
        [
            "voxPalette": "ink",
            SystemCaptureExclusions.defaultsKey: SystemCaptureExclusions.encode(
                ["com.obsproject.obs-studio", "com.cmuxterm.app"]
            ),
        ]
    }

    /// Runs on every launch, acts on the first one of this build: a finished
    /// onboarding means an install from before it; a new install only marks itself.
    /// `legacy` is the settings domain of the app under its old name: an install
    /// that came over finished onboarding there, and that flag stays
    /// behind on purpose (`LegacySettings.leftBehind`).
    static func pinIfNeeded(_ defaults: UserDefaults = .standard, legacy: [String: Any]? = nil) {
        guard !defaults.bool(forKey: pinnedKey) else { return }
        defer { defaults.set(true, forKey: pinnedKey) }
        guard defaults.bool(forKey: "onboardingCompleted") || legacy?["onboardingCompleted"] as? Bool == true else { return }
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

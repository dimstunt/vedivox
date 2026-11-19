import Foundation

/// What dictation does to sound already playing.
///
/// Pause is the default because it loses nothing: a muted podcast keeps going
/// and the user misses a piece of it. Mute stays as the fallback that needs no
/// private API — pausing reads the Now Playing state through a path Apple has
/// already closed once for third-party processes.
enum DictationBackgroundAudio: String, CaseIterable, Identifiable, Sendable {
    case pause
    case mute
    case off

    var id: String { rawValue }

    static let `default`: DictationBackgroundAudio = .pause

    var title: String {
        switch self {
        case .pause: "Pause playback"
        case .mute: "Mute sound"
        case .off: "Do nothing"
        }
    }

    var explanation: String {
        switch self {
        case .pause: "Whatever is playing pauses while you dictate and resumes when you stop. Calls are never paused"
        case .mute: "System output is muted while you dictate; playback keeps running silently"
        case .off: "Background sound is left alone"
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "dictationBackgroundAudio"

    /// Reads the stored choice, falling back to the default for a missing or
    /// unrecognised value.
    static func stored(in defaults: UserDefaults = .standard) -> DictationBackgroundAudio {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .default
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

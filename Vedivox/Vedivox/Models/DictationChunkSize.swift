import Foundation

/// How much audio the live recogniser digests at a time.
///
/// Measured on a 30 s recording (VedivoxBench/NemotronMemoryBench, removed; in git history): the delay before
/// any live text appears equals the chunk length, and quality rises with it.
/// There is no winner — 560 ms shows «ришли сами или помог перенос» almost
/// at once, 4480 ms shows a clean sentence but a short dictation is over before
/// it says anything. So the user picks.
///
/// Each option is a separate 640 MB model download, kept under
/// `<lang>/<chunkMs>ms` — switching behaves like a first install, not a toggle.
enum DictationChunkSize: Int, CaseIterable, Identifiable, Sendable {
    case ms560 = 560
    case ms1120 = 1120
    case ms2240 = 2240
    case ms4480 = 4480

    var id: Int { rawValue }

    /// The library's own recommendation, and the middle of the measured
    /// trade-off: first text at ~2.2 s with sentences that hold together.
    static let `default`: DictationChunkSize = .ms2240

    var milliseconds: Int { rawValue }

    var title: String {
        switch self {
        case .ms560: "0.6 s"
        case .ms1120: "1.1 s"
        case .ms2240: "2.2 s"
        case .ms4480: "4.5 s"
        }
    }

    /// Says what the choice costs, not just what it is — the numbers come from
    /// the bench, so the user is choosing between measured outcomes.
    var explanation: String {
        switch self {
        case .ms560: "Text appears almost instantly, but words get badly garbled"
        case .ms1120: "Faster, but clarity suffers"
        case .ms2240: "A reasonable balance: coherent phrases after a couple of seconds"
        case .ms4480: "The most accurate draft, but a short dictation may end sooner"
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "dictationChunkMs"

    /// Reads the stored choice, falling back to the default for a missing or
    /// unrecognised value — a stale number must not disable live text.
    static func stored(in defaults: UserDefaults = .standard) -> DictationChunkSize {
        guard let raw = defaults.object(forKey: defaultsKey) as? Int,
              let size = DictationChunkSize(rawValue: raw)
        else { return .default }
        return size
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

import Foundation

/// Which model is being fetched/compiled during warm-up.
enum ModelLoadStage: Sendable, Equatable {
    case transcription
    case diarization
}

/// Progress snapshot surfaced to the UI while models download on first run.
///
/// `fraction` is nil when the underlying loader can't report percentages — the
/// offline diarizer's `prepareModels` has no progress handler, so the UI shows
/// an indeterminate spinner for that stage instead of a percentage.
struct ModelLoadProgress: Sendable, Equatable {
    let stage: ModelLoadStage
    /// Completion in [0, 1], or nil for an indeterminate stage.
    let fraction: Double?

    var localizedTitle: String {
        switch stage {
        case .transcription: "Loading transcription model…"
        case .diarization: "Preparing diarization model…"
        }
    }
}

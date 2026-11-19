import Foundation

/// Decides whose audio to drop when the dictation history grows
///
/// A pure function on purpose: this is the one part of the history where a
/// mistake is both easy and silent — deleting audio the user still wanted, or
/// never deleting any and letting the folder grow without bound. Neither shows
/// up in the interface until it is too late.
///
/// The invariant it protects: **only audio is ever removed, never text.** A
/// dictation whose audio is gone still shows what was said; it just cannot be
/// re-transcribed.
enum DictationRetention {

    /// How many recent dictations keep their audio. Text is kept for all of
    /// them regardless.
    static let defaultAudioLimit = 20

    /// Returns the records whose audio should be deleted now: everything with
    /// audio beyond the `limit` most recent.
    ///
    /// Order is by `createdAt`, newest first. Records without audio do not
    /// occupy a slot — otherwise a long tail of already-trimmed dictations would
    /// push recent audio out for no benefit.
    static func audioToDelete(from dictations: [Dictation], limit: Int = defaultAudioLimit) -> [Dictation] {
        guard limit >= 0 else { return [] }

        // Audio still owed a recognition is the only copy of what was said.
        let withAudio = dictations
            .filter { $0.hasAudio && !$0.awaitingTranscription }
            .sorted { $0.createdAt > $1.createdAt }

        guard withAudio.count > limit else { return [] }
        return Array(withAudio.dropFirst(limit))
    }
}

import FluidAudio

/// Hugging Face commits the models are fetched at, instead of the moving
/// `main`. Each is the revision the owner's cache was verified
/// against file by file, so FluidAudio adopts an existing cache by hash and
/// downloads nothing. The diarizer is pinned by FluidAudio itself
/// (`Repo.diarizer.revision`). Bumping one is a bench run, like a version bump.
enum ModelPins {
    static let revisions: [String: String] = [
        // 2026-04-30; later `main` adds Encoder_v2 and a bigger config.json.
        Repo.parakeetV3.remotePath: "aed02740059203c4a87495924f685de3722ae9ce",
        // 2026-07-03; later commits add opt-in encoders in other folders.
        Repo.nemotronMultilingual.remotePath: "1a41b75758b0337ff67db7d5408280aaaf23074e",
    ]

    /// Call before any model download. FluidAudio's override table is an
    /// unguarded static, and Parakeet and dictation load concurrently at launch:
    /// a lazy static runs the write exactly once, every caller waiting for it.
    static func apply() { _ = written }

    private static let written: Void = {
        ModelRegistry.revisionOverrides.merge(revisions) { _, pinned in pinned }
    }()
}

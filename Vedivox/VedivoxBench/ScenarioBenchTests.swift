import XCTest

/// Headless diarization benchmark. Runs the real `TranscriptionPipeline` over the
/// scenario_basic fixture against an isolated in-memory DB + temp audio root, scores
/// DER vs the gold ground truth, and checks cross-meeting speaker consistency.
///
/// Lives in its own `VedivoxBench` target/scheme so the normal logic-test suite never
/// triggers it (it loads CoreML models and processes ~20 min of audio). Skips
/// gracefully when the gitignored fixture audio isn't present (fresh clone).
///
///     xcodebuild test -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/ScenarioBenchTests/testScenarioBasic
final class ScenarioBenchTests: XCTestCase {
    /// TEST_RUNNER_VEDIVOX_BENCH_FIXTURE swaps scenario_basic for a variant with the same
    /// scenario.json and ground truth (e.g. scenario_basic_d, re-encoded audio).
    private let basic = ProcessInfo.processInfo.environment["VEDIVOX_BENCH_FIXTURE"] ?? "scenario_basic"

    /// End-to-end: accumulating enrolled pool + cross-meeting consistency checks.
    func testScenarioBasic() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent(basic) else {
            throw XCTSkip("\(basic) audio not present (gitignored) — cut it first, see RUNBOOK")
        }
        try await ScenarioBenchRunner(fixtureName: basic).run()
    }

    /// Stage-1 isolation: no enrollment, pure within-meeting clustering DER —
    /// the metric a FluidAudio version bump should move (review finding H3).
    func testScenarioBasicStage1() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent(basic) else {
            throw XCTSkip("\(basic) audio not present (gitignored) — cut it first, see RUNBOOK")
        }
        try await ScenarioBenchRunner(fixtureName: basic, enrollAcrossMeetings: false).run()
    }

    /// People outside the pool (stage2-out-of-pool): seeded with the 56 migrated
    /// canonicals minus every reference speaker, so most clusters are newcomers
    /// facing a big pool. Read wrong_name / false_assign, not confusion.
    func testScenarioBasicSeededAbsent() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent(basic) else {
            throw XCTSkip("\(basic) audio not present (gitignored) — cut it first, see RUNBOOK")
        }
        var runner = ScenarioBenchRunner(fixtureName: basic)
        runner.excludeReferenceSpeakersFromSeed = true
        try await runner.run()
    }

    /// Today's pool (stage2-dead-zone): seeded with the read-only live snapshot
    /// instead of the June migration.
    func testScenarioBasicSeededLive() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent(basic) else {
            throw XCTSkip("\(basic) audio not present (gitignored) — cut it first, see RUNBOOK")
        }
        guard ScenarioBenchRunner.liveSnapshotPresent() else {
            throw XCTSkip("live snapshot not present (local only) — uv run scripts/export_live_canonicals.py")
        }
        var runner = ScenarioBenchRunner(fixtureName: basic)
        runner.seedLiveSnapshot = true
        try await runner.run()
    }

    /// Recording tail (stage2-dead-zone): a voice message whose tail windows
    /// Stage 2.5 moved to an outlier profile. Read wrong_name, not DER.
    func testScenarioTailSeededLive() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent("scenario_tail"), ScenarioBenchRunner.liveSnapshotPresent() else {
            throw XCTSkip("scenario_tail audio or live snapshot not present — see .backlog/fixtures/scenario_tail/RUNBOOK.md")
        }
        var runner = ScenarioBenchRunner(fixtureName: "scenario_tail")
        runner.seedLiveSnapshot = true
        try await runner.run()
    }

    /// Mic track (stage2-mic-owner): today's pool with the owner as isMe, so the
    /// mic is diarized and matched as in prod.
    func testScenarioBasicSeededLiveMe() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent(basic), ScenarioBenchRunner.liveSnapshotPresent() else {
            throw XCTSkip("\(basic) audio or live snapshot not present (both local only)")
        }
        var runner = ScenarioBenchRunner(fixtureName: basic)
        runner.seedLiveSnapshot = true
        runner.seedOwnerAsMe = true
        try await runner.run()
    }

    /// Mic speech handed to an outlier profile on 2026-11-01 (stage2-mic-owner).
    /// Read seconds per track from the stage-2 dump, not DER.
    func testScenarioMicOutlier() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent("scenario_mic_outlier"), ScenarioBenchRunner.liveSnapshotPresent() else {
            throw XCTSkip("scenario_mic_outlier audio or live snapshot not present — see its RUNBOOK.md")
        }
        // Meetings stay independent (no confirm-all between them): the pool is the
        // snapshot alone, as in prod, where minted speaker_N never enter it.
        var runner = ScenarioBenchRunner(fixtureName: "scenario_mic_outlier", enrollAcrossMeetings: false)
        runner.seedLiveSnapshot = true
        runner.seedOwnerAsMe = true
        try await runner.run()
    }

    /// Lookalike voices (bench-lookalike-fixture): Stage-1 only — purity and
    /// pred/ref speaker count show two people merged into one cluster.
    func testScenarioLookalikeStage1() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent("scenario_lookalike") else {
            throw XCTSkip("scenario_lookalike audio not present — uv run .backlog/fixtures/scenario_lookalike/prepare.py")
        }
        try await ScenarioBenchRunner(fixtureName: "scenario_lookalike", enrollAcrossMeetings: false).run()
    }

    /// The same four lookalike women across four meetings
    /// (separability-invariant): cross-meeting identity while every canonical
    /// recalc faces three similar voices. Read cross_meeting_ok, REJECTED
    /// and `[Perf] separability` lines in the run's vedivox.log.
    func testScenarioLookalikeSeriesCrossMeeting() async throws {
        guard ScenarioBenchRunner.fixtureAudioPresent("scenario_lookalike_series") else {
            throw XCTSkip("scenario_lookalike_series audio not present — uv run .backlog/fixtures/scenario_lookalike/prepare.py --series")
        }
        Log.level = .debug // PerfTrace lines
        defer { Log.level = .info }
        try await ScenarioBenchRunner(fixtureName: "scenario_lookalike_series").run()
    }
}

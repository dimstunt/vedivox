import XCTest

/// Background sound during dictation: the
/// stored mode, and the ownership rules of the pause — who resumes what, in
/// which order. `osascript` is replaced by a fake step, so no real player is
/// touched.
@MainActor
final class DictationBackgroundAudioTests: XCTestCase {

    // MARK: - Stored mode

    // Unique per run: one fixed name is one domain for every xctest process on
    // the machine, and a parallel `make test` in another worktree rewrites it.
    private let suiteName = "DictationBackgroundAudioTests-\(UUID().uuidString)"

    func testStoredModeDefaultsToPauseAndSurvivesJunk() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!

        XCTAssertEqual(DictationBackgroundAudio.stored(in: defaults), .pause)
        for mode in DictationBackgroundAudio.allCases {
            mode.store(in: defaults)
            XCTAssertEqual(DictationBackgroundAudio.stored(in: defaults), mode)
        }
        defaults.set("loud", forKey: DictationBackgroundAudio.defaultsKey)
        XCTAssertEqual(DictationBackgroundAudio.stored(in: defaults), .pause)
    }

    // MARK: - Pause ownership

    private actor Calls {
        var all: [String] = []
        func add(_ call: String) { all.append(call) }
    }

    private let spotify = "com.spotify.client"

    /// A player that is `playing` when asked; the pause step takes `delay`.
    private func step(_ calls: Calls, playing: Bool, delay: Duration = .zero) -> BackgroundAudio.Step {
        let app = spotify
        return { mode, ids in
            if mode == "pause" { try? await Task.sleep(for: delay) }
            await calls.add(mode == "pause" ? "pause" : "play \(ids.first ?? "")")
            return .init(app: app, playing: playing, sent: mode == "pause" ? playing : true)
        }
    }

    private func settle(_ calls: Calls, until count: Int) async -> [String] {
        for _ in 0 ..< 200 {
            if await calls.all.count >= count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Give a wrong extra call the chance to show up.
        try? await Task.sleep(for: .milliseconds(50))
        return await calls.all
    }

    func testPausedPlayerIsResumed() async {
        let calls = Calls()
        let audio = BackgroundAudio(step: step(calls, playing: true))
        audio.begin(mode: .pause)
        _ = await settle(calls, until: 1)
        audio.end()
        let result = await settle(calls, until: 2)
        XCTAssertEqual(result, ["pause", "play \(spotify)"])
    }

    func testNothingPlayingIsNeverStarted() async {
        let calls = Calls()
        let audio = BackgroundAudio(step: step(calls, playing: false))
        audio.begin(mode: .pause)
        audio.end()
        let result = await settle(calls, until: 1)
        XCTAssertEqual(result, ["pause"])
    }

    func testMeetingRecordingIsNeverPaused() async {
        let calls = Calls()
        let audio = BackgroundAudio(step: step(calls, playing: true))
        audio.isRecordingMeeting = { true }
        audio.begin(mode: .pause)
        audio.end()
        let result = await settle(calls, until: 0)
        XCTAssertEqual(result, [])
    }

    /// Stopped before the pause step answered: the pause still lands, so the
    /// resume must wait for it rather than leave the music paused.
    func testStopBeforePauseAnsweredStillResumes() async {
        let calls = Calls()
        let audio = BackgroundAudio(step: step(calls, playing: true, delay: .milliseconds(100)))
        audio.begin(mode: .pause)
        audio.end()
        let result = await settle(calls, until: 2)
        XCTAssertEqual(result, ["pause", "play \(spotify)"])
    }

    /// The quit path: when `endAndWait` returns, the resume has already gone out.
    func testEndAndWaitReturnsAfterTheResume() async {
        let calls = Calls()
        let audio = BackgroundAudio(step: step(calls, playing: true, delay: .milliseconds(100)))
        audio.begin(mode: .pause)
        await audio.endAndWait()
        let result = await calls.all
        XCTAssertEqual(result, ["pause", "play \(spotify)"])
    }

    /// A new dictation before the previous resume went out keeps the pause:
    /// no play-then-pause blip, one resume at the very end.
    func testBackToBackDictationsInheritThePause() async {
        let calls = Calls()
        let audio = BackgroundAudio(step: step(calls, playing: true))
        audio.begin(mode: .pause)
        _ = await settle(calls, until: 1)
        audio.end()
        audio.begin(mode: .pause)
        let between = await settle(calls, until: 1)
        XCTAssertEqual(between, ["pause"])
        audio.end()
        audio.end() // cleanup() calls it again — must not resume twice
        let result = await settle(calls, until: 2)
        XCTAssertEqual(result, ["pause", "play \(spotify)"])
    }
}

import Foundation

/// What ⌘Q, a logout or a restart does to a meeting in progress.
/// Without it a quit was a crash: tracks left open, no end time, the
/// transcript only after the next launch.
@MainActor
enum QuitGuard {
    enum Decision: Equatable {
        case quitNow
        /// Close both tracks and write the end, and save a dictation for the
        /// next launch, then quit; the next launch processes and recognizes them.
        case stopFirst
        /// Processing restarts from scratch on the next launch, so the user decides.
        case askAboutProcessing
        /// A quit stops the dictation before it is inserted, so the user decides;
        /// its audio is saved either way.
        case askAboutDictation
    }

    static func decide(recording: Bool, processing: Bool, dictating: Bool, poweringOff: Bool) -> Decision {
        // A logout has nobody to answer the question. Otherwise the dictation
        // asks even during a recording (item 10): the owner wants to
        // finish it; after Quit it is saved first, then the recording stops.
        if dictating, !poweringOff { return .askAboutDictation }
        if recording || dictating { return .stopFirst }
        // Recovery resumes the processing after a logout.
        if poweringOff { return .quitNow }
        if processing { return .askAboutProcessing }
        return .quitNow
    }

    /// Runs `stop`, then answers `reply(true)` — or at `limit`, whichever comes
    /// first, exactly once: a stuck stop must not hang a logout. What the stop
    /// did not finish, the next launch recovers.
    static func stopThenQuit(
        limit: Duration = .seconds(10),
        stop: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        let once = Once(reply)
        Task { @MainActor in
            await stop()
            once.fire(timedOut: false)
        }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            once.fire(timedOut: true)
        }
    }

    @MainActor
    private final class Once {
        private var reply: ((Bool) -> Void)?

        init(_ reply: @escaping @MainActor (Bool) -> Void) { self.reply = reply }

        func fire(timedOut: Bool) {
            guard let reply else { return }
            self.reply = nil
            if timedOut { Log.error("Quit: the recording did not stop in time, quitting anyway (the next launch recovers it)") }
            reply(true)
        }
    }
}

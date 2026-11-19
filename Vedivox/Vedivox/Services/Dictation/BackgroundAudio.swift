import AudioToolbox
import Foundation

/// Pauses or mutes background sound for the length of a dictation and puts it
/// back afterwards.
///
/// Pause goes through `/usr/bin/osascript`, not through MediaRemote in this
/// process: since macOS 15.4 MediaRemote answers only Apple-signed clients.
/// Measured 2026-10-21 on 26.3.1 — a locally built binary gets `pid: 0` and no
/// info, the same query from `osascript` names Spotify in ~40 ms. Checking and
/// commanding happen in one script run so nothing changes in between, and the
/// commands are explicit pause/play rather than the Play/Pause media key: a
/// toggle on stale state pauses what the user just started, and with no player
/// at all it launches Music.
@MainActor
final class BackgroundAudio {

    struct Reply: Decodable, Equatable, Sendable, CustomStringConvertible {
        let app: String?
        let playing: Bool
        let sent: Bool
        /// How long `play` waited for the earlier pause to land.
        var waitedMs: Int?

        var description: String {
            "app=\(app ?? "none") playing=\(playing) sent=\(sent)" + (waitedMs.map { " waited=\($0)ms" } ?? "")
        }
    }

    /// One Now Playing step: `pause` with the bundle ids never to pause, or
    /// `play` with the one bundle id to resume. Injected so tests can drive the
    /// ownership rules without touching real playback.
    typealias Step = @Sendable (_ mode: String, _ ids: [String]) async -> Reply?

    /// Set by `AppState`. Pausing during a meeting recording could pause the
    /// call itself — a Meet tab publishes a media session like any player.
    var isRecordingMeeting: () -> Bool = { false }

    private let step: Step
    private var mode: DictationBackgroundAudio = .off
    private var active = false
    /// Resolves to the bundle id this controller paused. Kept until the resume
    /// actually goes out, so a dictation started in between inherits it instead
    /// of letting a split second of music through.
    private var pausing: Task<String?, Never>?
    private var resuming: Task<Void, Never>?

    init(step: @escaping Step = BackgroundAudio.osascript) {
        self.step = step
    }

    /// Called as recording starts. Returns at once: the recording must not
    /// wait for `osascript`.
    func begin(mode: DictationBackgroundAudio = .stored()) {
        guard !active else { return }
        active = true
        self.mode = mode
        switch mode {
        case .off: break
        case .mute: OutputMute.mute()
        case .pause: beginPause()
        }
    }

    /// Called as soon as recording stops, however it stops. Idempotent, so
    /// `cleanup()` can call it again as a safety net.
    func end() {
        guard active else { return }
        active = false
        switch mode {
        case .off: break
        case .mute: OutputMute.restore()
        case .pause: endPause()
        }
    }

    /// `end()`, then waits until the resume has gone out: on quit, a resume
    /// left running dies with the process and the music stays paused.
    func endAndWait() async {
        end()
        await resuming?.value
    }

    private func beginPause() {
        if let resuming, pausing != nil {
            resuming.cancel()
            self.resuming = nil
            Log.info("Background audio: new dictation keeps the previous pause")
            return
        }
        guard !isRecordingMeeting() else {
            Log.info("Background audio: a meeting is recording, not pausing")
            return
        }
        // One script at a time: a pause query racing the previous dictation's
        // play would read the state from before that play landed.
        let previous = resuming
        let step = self.step
        pausing = Task {
            await previous?.value
            guard let reply = await step("pause", Array(MeetingDetector.allTargetAppIds)) else {
                Log.info("Background audio: Now Playing state unavailable, not pausing")
                return nil
            }
            Log.info("Background audio: pause — \(reply)")
            return reply.sent ? reply.app : nil
        }
    }

    private func endPause() {
        guard let pausing else { return }
        let step = self.step
        resuming = Task { [weak self] in
            let owned = await pausing.value
            // Cancelled means the next dictation took the pause over.
            guard !Task.isCancelled else { return }
            self?.pausing = nil
            guard let owned else { return }
            // `play` is idempotent: if the user already restarted it, nothing
            // happens; if another player took over, the script sends nothing.
            let reply = await step("play", [owned])
            Log.info("Background audio: resume \(owned) — \(reply.map { "\($0)" } ?? "state unavailable")")
        }
    }

    // MARK: - osascript

    nonisolated static let osascript: Step = { mode, ids in
        await Task.detached { BackgroundAudio.run(arguments: [mode] + ids) }.value
    }

    private nonisolated static func run(arguments: [String]) -> Reply? {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("Background audio: osascript did not start — \(error.localizedDescription)")
            return nil
        }
        let pid = process.processIdentifier
        let timeout = DispatchWorkItem { kill(pid, SIGTERM) }
        // Above the script's own 1.5 s wait for a pause to land.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard process.terminationStatus == 0,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else {
            Log.info("Background audio: osascript failed after \(ms) ms, status \(process.terminationStatus)")
            return nil
        }
        Log.debug("Background audio: osascript \(arguments.first ?? "") took \(ms) ms")
        return reply
    }

    /// `run(argv)`: `pause <never-pause ids…>` or `play <bundle id>`.
    ///
    /// The source is the parent app when there is one — Safari plays through a
    /// WebKit helper. After a command the run loop turns for 150 ms: the command
    /// leaves over XPC asynchronously and an `osascript` that exits at once
    /// sometimes loses it (`mediaremote-adapter` waits for the same reason).
    private nonisolated static let script = """
        function run(argv) {
            ObjC.import("Foundation");
            $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
            const request = $.NSClassFromString("MRNowPlayingRequest");
            const path = request.localNowPlayingPlayerPath;
            let app = null;
            if (!path.isNil()) {
                const client = path.client;
                const parent = client.respondsToSelector("parentApplicationBundleIdentifier")
                    ? client.parentApplicationBundleIdentifier : $();
                const own = client.bundleIdentifier;
                app = !parent.isNil() && parent.js ? parent.js : (own.isNil() ? null : own.js);
            }
            const playing = request.localIsPlaying === true;
            const [mode, ...ids] = argv;
            const act = mode === "pause"
                ? playing && app !== null && !ids.includes(app)
                : app !== null && app === ids[0];
            let sent = false;
            let waited = 0;
            if (act && mode === "play") {
                // A pause sent a moment ago may not have landed yet: Spotify
                // still reports playing for ~0.3 s, a play sent then is a no-op,
                // and the late pause leaves the music stopped (seen 2026-10-22
                // on Escape right after start). Wait for it, bounded.
                const started = Date.now();
                while (request.localIsPlaying === true && Date.now() - started < 1500) {
                    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
                }
                waited = Date.now() - started;
            }
            if (act) {
                ObjC.bindFunction("MRMediaRemoteSendCommand", ["bool", ["int", "id"]]);
                sent = $.MRMediaRemoteSendCommand(mode === "pause" ? 1 : 0, $()) === true;
                $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.15));
            }
            return JSON.stringify({ app: app, playing: playing, sent: sent, waitedMs: waited });
        }
        """
}

/// Output mute for the «Mute sound» mode.
///
/// The muted device is remembered by UID in UserDefaults, not by
/// `AudioDeviceID` in memory: the ID changes when AirPods reconnect, and a Vedivox
/// that dies mid-dictation must not leave the Mac silent — `restore()` also
/// runs at launch and on quit.
enum OutputMute {
    static let defaultsKey = "dictationMutedOutputUID"

    static func mute() {
        guard let device = AudioObjectID.readDefaultOutputDevice(),
              let uid = try? device.readDeviceUID()
        else {
            Log.info("Background audio: no output device, not muting")
            return
        }
        switch device.readOutputMute() {
        case nil:
            Log.info("Background audio: \(uid) has no mute control, leaving sound alone")
        case true?:
            Log.info("Background audio: \(uid) already muted, leaving it")
        case false?:
            guard device.writeOutputMute(true) else {
                Log.info("Background audio: \(uid) refused mute, leaving sound alone")
                return
            }
            UserDefaults.standard.set(uid, forKey: defaultsKey)
            Log.info("Background audio: muted \(uid)")
        }
    }

    static func restore() {
        guard let uid = UserDefaults.standard.string(forKey: defaultsKey) else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        guard let device = AudioObjectID.deviceIDForUID(uid) else {
            Log.info("Background audio: muted output \(uid) is gone")
            return
        }
        guard device.readOutputMute() == true else { return }
        Log.info("Background audio: unmuted \(uid), ok=\(device.writeOutputMute(false))")
    }
}

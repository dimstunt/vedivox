import Foundation

/// Which input the mic track should be on while a recording runs (
///): the first usable entry of `order`, always. The current input
/// gone — move at once. A better one showed up — move once it has stayed
/// connected for `upHold`: a Bluetooth device flickers while it connects, and
/// every move is a hole in the track. An input that failed is not gone back
/// to until it is replugged. Facts in, decision out — no Core Audio here.
struct MicSwitchPolicy {
    /// Inputs by preference; `nil` is the system default.
    let order: [String?]
    /// False for dictation: it picks an input at start and only leaves a lost one.
    let movesUp: Bool
    /// Connected inputs: the device ID each was last seen under, and since
    /// when. A reconnect gives a new ID and starts the hold over, even when
    /// no look at the devices fell between the unplug and the replug.
    private var seen: [String: (id: UInt32, since: TimeInterval)] = [:]
    /// Inputs that would not bind, would not start, or started and stayed
    /// silent, with the device ID they had. Under that ID they are only a
    /// last resort: every failed attempt tears down a working engine and
    /// leaves a gap. A replug gives a new ID.
    private var failed: [String: UInt32] = [:]
    /// The system default has no ID of its own: once failed, a last resort
    /// for the rest of the recording.
    private var systemDefaultFailed = false

    static let upHold: TimeInterval = 2.5
    static let lostReason = "current input lost"
    static let betterReason = "higher-priority input connected"

    enum Decision: Equatable {
        case stay
        case move(to: String?, reason: String)
    }

    init(order: [String?], movesUp: Bool) {
        self.order = order
        self.movesUp = movesUp
    }

    mutating func markFailed(_ uid: String?) {
        guard let uid else {
            systemDefaultFailed = true
            return
        }
        failed[uid] = seen[uid]?.id ?? 0
    }

    /// Whether the running engine should move, and where. `current`: the
    /// input it records from. `connected`: UID → device ID of the inputs
    /// that are there now.
    mutating func decide(current: String?, connected: [String: UInt32], now: TimeInterval) -> Decision {
        note(connected, since: now)
        let usable = order.filter(isUsable)
        if let current, seen[current] == nil {
            guard let next = settledFirst(usable, now: now).first else { return .stay }
            return .move(to: next, reason: Self.lostReason)
        }
        guard movesUp, let best = usable.first, best != current,
              rank(best) < rank(current), isSettled(best, now: now)
        else { return .stay }
        return .move(to: best, reason: Self.betterReason)
    }

    /// The inputs an engine build tries, in turn. `restarting` is false for
    /// the first build of a recording: what is connected then has been there
    /// all along. A rebuild keeps to the hold as well — an input that just
    /// showed up goes after the ones that have stayed. With `movesUp` off a
    /// restart stays on `current` while it is usable: it is not a reason to
    /// move. What failed before comes last.
    mutating func buildOrder(
        current: String?, restarting: Bool, connected: [String: UInt32], now: TimeInterval
    ) -> [String?] {
        note(connected, since: restarting ? now : -.infinity)
        var candidates = settledFirst(order.filter(isUsable), now: now)
        if restarting, !movesUp, let index = candidates.firstIndex(of: current) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        return candidates + order.filter { isConnected($0) && !isUsable($0) }
    }

    private mutating func note(_ connected: [String: UInt32], since: TimeInterval) {
        seen = seen.filter { connected[$0.key] == $0.value.id }
        for (uid, id) in connected where seen[uid] == nil { seen[uid] = (id, since) }
    }

    private func isConnected(_ uid: String?) -> Bool {
        guard let uid else { return true }
        return seen[uid] != nil
    }

    /// Connected, and not known to fail under the device ID it has now.
    private func isUsable(_ uid: String?) -> Bool {
        guard let uid else { return !systemDefaultFailed }
        guard let id = seen[uid]?.id else { return false }
        return failed[uid] != id
    }

    private func isSettled(_ uid: String?, now: TimeInterval) -> Bool {
        guard let uid else { return true }
        return seen[uid].map { now - $0.since >= Self.upHold } ?? false
    }

    private func settledFirst(_ inputs: [String?], now: TimeInterval) -> [String?] {
        inputs.filter { isSettled($0, now: now) } + inputs.filter { !isSettled($0, now: now) }
    }

    private func rank(_ uid: String?) -> Int {
        order.firstIndex(of: uid) ?? order.count
    }
}

/// The audio devices as the mic capture last saw them — to say in the log
/// what a device event changed, by name.
struct AudioDeviceSnapshot: Equatable {
    var inputs: [MicPriority.Device] = []
    /// UID → device ID of `inputs`; a replug changes the ID.
    var inputIDs: [String: UInt32] = [:]
    /// Names of the system default devices; nil when there is none.
    var defaultInput: String?
    var defaultOutput: String?

    /// What is different from `old`, for one log line; nil when nothing is.
    func changes(from old: AudioDeviceSnapshot) -> String? {
        var parts: [String] = []
        let before = Set(old.inputs.map(\.uid))
        let after = Set(inputs.map(\.uid))
        let added = inputs.filter { !before.contains($0.uid) }.map { "+\($0.name)" }
        let removed = old.inputs.filter { !after.contains($0.uid) }.map { "−\($0.name)" }
        let replugged = inputs
            .filter { before.contains($0.uid) && old.inputIDs[$0.uid] != inputIDs[$0.uid] }
            .map { "↻\($0.name)" }
        let names = added + removed + replugged
        if !names.isEmpty { parts.append("inputs \(names.joined(separator: " "))") }
        if defaultInput != old.defaultInput {
            parts.append("default input \(old.defaultInput ?? "none") → \(defaultInput ?? "none")")
        }
        if defaultOutput != old.defaultOutput {
            parts.append("default output \(old.defaultOutput ?? "none") → \(defaultOutput ?? "none")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

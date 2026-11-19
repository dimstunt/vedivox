import Foundation

/// Recording-time «не в транскрипт» toggle (design D6).
///
/// The only thing it ever does is insert and close rows in `meeting_marks` —
/// audio capture is never touched, so the button cannot break a recording or
/// desync the tracks. Times are recording-elapsed seconds, the same clock the
/// segments live on.
@MainActor
final class ExclusionToggle {
    struct Config {
        /// Retroactive coverage on activation: people press the button after
        /// the foreign conversation has already started (risk M4).
        var lookback: TimeInterval = 15
        /// A forgotten toggle auto-expires so it cannot silently eat the rest
        /// of the meeting (risk M3). `exclusionAutoExpiry` in UserDefaults
        /// (Settings → Recording), seconds; unset → 30 min, 0 → never. The old
        /// hard-coded 5 min fired four times in one 99-minute meeting
        /// (2026-09-04). nil reads the setting at each activation, so a change
        /// applies without a relaunch; tests pin a value.
        var autoExpiry: TimeInterval?
        var defaults: UserDefaults = .standard

        static let autoExpiryKey = "exclusionAutoExpiry"
        static let defaultAutoExpiry: TimeInterval = 1800

        static func storedAutoExpiry(defaults: UserDefaults = .standard) -> TimeInterval {
            (defaults.object(forKey: autoExpiryKey) as? NSNumber)?.doubleValue ?? defaultAutoExpiry
        }
    }

    private(set) var isActive = false
    var config = Config()
    /// Fired on auto-expiry — the app turns it into a user notification.
    var onAutoExpire: (() -> Void)?

    private let markRepo: MarkRepository
    private var meetingId: String?
    private var expiryTask: Task<Void, Never>?

    init(markRepo: MarkRepository = MarkRepository()) {
        self.markRepo = markRepo
    }

    func toggle(meetingId: String, elapsed: TimeInterval) async {
        if isActive {
            await deactivate(elapsed: elapsed)
        } else {
            await activate(meetingId: meetingId, elapsed: elapsed)
        }
    }

    func activate(meetingId: String, elapsed: TimeInterval) async {
        guard !isActive else { return }
        do {
            try await markRepo.add(MeetingMark(
                meetingId: meetingId,
                startTime: max(0, elapsed - config.lookback),
                endTime: nil,
                track: .mic,
                kind: .excluded,
                source: .button
            ))
        } catch {
            Log.error("Exclusion toggle: failed to open interval: \(error)")
            return
        }
        self.meetingId = meetingId
        isActive = true
        scheduleExpiry(activatedAt: elapsed)
    }

    func deactivate(elapsed: TimeInterval) async {
        guard isActive, let meetingId else { return }
        expiryTask?.cancel()
        expiryTask = nil
        do {
            try await markRepo.closeOpenButtonMarks(meetingId: meetingId, at: elapsed)
        } catch {
            Log.error("Exclusion toggle: failed to close interval: \(error)")
        }
        isActive = false
    }

    /// Recording stopped: close whatever is still open and report how much
    /// time ended up excluded — the stop summary (spec: «сводка после стопа»).
    /// Safe to call unconditionally; projection happens in the pipeline.
    func recordingStopped(meetingId: String, duration: TimeInterval) async -> TimeInterval {
        expiryTask?.cancel()
        expiryTask = nil
        isActive = false
        self.meetingId = nil
        _ = try? await markRepo.closeOpenButtonMarks(meetingId: meetingId, at: duration)
        let marks = (try? await markRepo.marks(for: meetingId)) ?? []
        return marks
            .filter { $0.kind == .excluded }
            .reduce(0.0) { total, mark in
                guard let end = mark.endTime else { return total }
                return total + max(0, end - mark.startTime)
            }
    }

    private func scheduleExpiry(activatedAt elapsed: TimeInterval) {
        expiryTask?.cancel()
        let expiry = config.autoExpiry ?? Config.storedAutoExpiry(defaults: config.defaults)
        guard expiry > 0 else {
            Log.info("Exclusion toggle: on, auto-expiry off")
            return
        }
        Log.info("Exclusion toggle: on, auto-expiry in \(Int(expiry))s")
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(expiry))
            guard !Task.isCancelled, let self, self.isActive else { return }
            // Drop the handle BEFORE deactivating: deactivate cancels
            // `expiryTask`, and cancelling the task we are running in makes
            // GRDB abort the closing write with CancellationError.
            self.expiryTask = nil
            await self.deactivate(elapsed: elapsed + expiry)
            Log.info("Exclusion toggle auto-expired after \(Int(expiry))s")
            self.onAutoExpire?()
        }
    }
}

import Foundation

/// The Listen section (listen-queue § 7): the queue, the selected voice, its
/// fragments, and a player of its own that stops when the section goes away.
/// One per app (`AppState.listen`): the list of the last visit is on screen
/// the moment the section opens, and the sidebar badge is counted here.
@MainActor
@Observable
final class ListenViewModel {
    /// Only the first seconds of a fragment play; → goes to the next one.
    static let fragmentCap: TimeInterval = 15

    var items: [ListenQueueItem] = []
    var selectedId: String?
    var fragmentIndex = 0
    var meetingFilter: String?
    var showSkipped = false
    /// The last decision, one line, with the canonical recalc outcome.
    var outcome: String?
    /// False until a queue has arrived: the section says «looking», never
    /// «nothing», while it does not know yet.
    private(set) var isLoaded = false
    var isApplying = false
    /// Voices waiting, for the sidebar badge; nil hides it.
    private(set) var count: Int?
    let player = AudioPlaybackService()
    private var loadedMeetingId: String?
    private let db: DatabaseManager

    typealias Build = @MainActor (_ meetingId: String?, _ skipped: Bool) async throws -> [ListenQueueItem]
    typealias Count = @MainActor () async throws -> Int
    private let build: Build
    private let countVoices: Count
    private let pause: Duration
    private let minInterval: Duration

    /// The section is on screen. Off screen a change of data recounts the
    /// badge and leaves the queue alone.
    private var isOpen = false
    /// Tells a rebuild that a newer one has started since.
    private var generation = 0
    private var isStale = false
    private var refreshLoop: Task<Void, Never>?
    private var lastRefresh: ContinuousClock.Instant?

    /// `build` and `count` are the queue builder unless a test counts calls.
    init(
        db: DatabaseManager = .shared,
        pause: Duration = .milliseconds(400),
        minInterval: Duration = .seconds(2),
        build: Build? = nil,
        count: Count? = nil
    ) {
        self.db = db
        self.pause = pause
        self.minInterval = minInterval
        self.build = build ?? { try await ListenQueueBuilder(db: db).build(meetingId: $0, skipped: $1) }
        countVoices = count ?? { try await ListenQueueBuilder(db: db).count() }
    }

    var selected: ListenQueueItem? { items.first { $0.id == selectedId } }

    var fragment: ListenQueueItem.Fragment? {
        guard let fragments = selected?.fragments, fragments.indices.contains(fragmentIndex) else { return nil }
        return fragments[fragmentIndex]
    }

    var totalSeconds: Double { items.reduce(0) { $0 + $1.seconds } }

    /// Meetings that have items, for the filter menu.
    var meetings: [(id: String, title: String)] {
        var seen = Set<String>()
        return items.compactMap { item in
            let id = item.members[0].meetingId
            return seen.insert(id).inserted ? (id, item.meetingTitle) : nil
        }
    }

    // MARK: Refresh

    /// The section came on screen: what the last visit left stays up while
    /// the queue is rebuilt behind it. Another filter is another list.
    func open(meetingFilter filter: String?) async {
        isOpen = true
        if filter != meetingFilter {
            meetingFilter = filter
            items = []
            selectedId = nil
            isLoaded = false
        }
        await reload()
    }

    /// Rebuilds the queue for the current filter. A newer rebuild wins; a
    /// cancelled or failed one leaves the list as it was.
    func reload() async {
        generation += 1
        let mine = generation
        do {
            // Not the view task's to cancel: leaving the section mid-build
            // logged an error and emptied the queue.
            let (meetingId, skipped) = (meetingFilter, showSkipped)
            let fresh = try await uncancelled { [build] in try await build(meetingId, skipped) }
            guard mine == generation else { return }
            items = fresh
        } catch is CancellationError {
            return
        } catch {
            Log.error("Listen queue failed to build: \(error)")
            guard mine == generation else { return }
        }
        isLoaded = true
        if let fragments = selected?.fragments {
            fragmentIndex = min(fragmentIndex, max(fragments.count - 1, 0))
        } else {
            select(items.first?.id, autoplay: false)
        }
    }

    /// The data changed: a decision here, a command, a processed meeting. A
    /// burst of changes costs one refresh — `pause` after its first change and
    /// no sooner than `minInterval` after the previous refresh; changes that
    /// arrive while it runs get one more. The queue is rebuilt only while the
    /// section is on screen, otherwise the badge alone is recounted — save
    /// the first refresh since launch, which builds it once ahead of the visit.
    func dataChanged() {
        isStale = true
        guard refreshLoop == nil else { return }
        refreshLoop = Task {
            while isStale {
                let earliest = lastRefresh.map { $0 + minInterval } ?? .now
                try? await Task.sleep(until: max(.now + pause, earliest), clock: .continuous)
                isStale = false
                lastRefresh = .now
                // Off screen only the first time since launch: the first open then
                // shows a list instead of waiting ~1 s for a cold build.
                if isOpen || !isLoaded { await reload() }
                if let voices = try? await countVoices() { count = voices > 0 ? voices : nil }
            }
            refreshLoop = nil
        }
    }

    // MARK: Navigation

    func select(_ id: String?, autoplay: Bool = true) {
        selectedId = id
        fragmentIndex = 0
        player.pause()
        if autoplay { playFragment() }
    }

    func moveItem(by step: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedId } ?? -1
        let next = min(max(current + step, 0), items.count - 1)
        select(items[next].id)
    }

    func moveFragment(by step: Int) {
        guard let count = selected?.fragments.count, count > 0 else { return }
        fragmentIndex = min(max(fragmentIndex + step, 0), count - 1)
        playFragment()
    }

    /// Whether the step lands on another fragment — the navigator's arrows.
    func canMoveFragment(by step: Int) -> Bool {
        selected?.fragments.indices.contains(fragmentIndex + step) ?? false
    }

    // MARK: Playback

    func togglePlay() {
        if player.isPlaying { player.pause() } else { playFragment() }
    }

    func playFragment() {
        guard let fragment else { return }
        play(fragment)
    }

    /// The candidate's sample: their longest line in another meeting.
    func hearCandidate(_ index: Int) {
        guard let candidates = selected?.candidates, candidates.indices.contains(index),
              let sample = candidates[index].sample else { return }
        play(sample)
    }

    private func play(_ fragment: ListenQueueItem.Fragment) {
        Task {
            guard await load(meetingId: fragment.meetingId) else { return }
            let track: AudioTrack = switch fragment.track {
            case .mic: .mic
            case .system: .system
            case .merged, .import: .mix
            }
            player.setTrack(track)
            player.play(from: fragment.start, to: min(fragment.end, fragment.start + Self.fragmentCap))
        }
    }

    private func load(meetingId: String) async -> Bool {
        if loadedMeetingId == meetingId { return true }
        guard let meeting = try? await MeetingRepository(db: db).find(meetingId) else { return false }
        let existing: (String?) -> URL? = { path in
            path.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        }
        var micURL = existing(meeting.micAudioPath)
        // Same preference as the meeting player: the echo-suppressed mic.
        if let dir = try? DatabaseManager.audioDirectory(for: meetingId) {
            let suppressed = dir.appendingPathComponent("mic_suppressed.m4a")
            if FileManager.default.fileExists(atPath: suppressed.path) { micURL = suppressed }
        }
        let systemURL = existing(meeting.systemAudioPath)
        guard micURL != nil || systemURL != nil else {
            outcome = "No audio for “\(meeting.title)”"
            return false
        }
        player.meetingTitle = meeting.title
        player.load(micURL: micURL, systemURL: systemURL)
        loadedMeetingId = meetingId
        return true
    }

    /// Leaving the section: one player at a time (design § 7).
    func leave() {
        isOpen = false
        player.stop()
        loadedMeetingId = nil
    }

    // MARK: Decisions

    func assignCandidate(_ index: Int) async {
        guard let candidates = selected?.candidates, candidates.indices.contains(index) else { return }
        await decide(.existing(speakerId: candidates[index].speakerId))
    }

    func assign(_ target: SpeakerVerdicts.Target) async {
        await decide(target)
    }

    func skip() async {
        guard let item = selected else { return }
        await apply(item) {
            let intervals = try await SpeakerVerdicts(db: db).skip(meetingIds: item.meetingIds, segmentIds: item.segmentIds)
            return "skipped \(item.heading) · \(intervals) interval(s)"
        }
    }

    /// A voice that is two people: each line to whichever of the first two candidates it sounds closer to.
    func splitTopTwo() async {
        guard let item = selected, item.candidates.count >= 2 else { return }
        await apply(item) {
            let result = try await SpeakerVerdicts(db: db).split(
                meetingIds: item.meetingIds, segmentIds: item.segmentIds,
                between: item.candidates.prefix(2).map(\.speakerId)
            )
            let moved = result.assigned.map { "\($0.speaker.displayName) \($0.segments)" }.joined(separator: ", ")
            return "⇆ \(item.heading) → \(moved.isEmpty ? "nobody" : moved) · \(result.unclear) unclear left"
        }
    }

    private func decide(_ target: SpeakerVerdicts.Target) async {
        guard let item = selected else { return }
        await apply(item) {
            let results = try await SpeakerVerdicts(db: db).assign(
                meetingIds: item.meetingIds, segmentIds: item.segmentIds, to: target
            )
            guard let result = results.last else { return "nothing moved" }
            return "✓ \(item.heading) → \(result.speaker.displayName) · "
                + SpeakerRepository.RecalcOutcome.summary(result.target)
        }
    }

    /// Applies a decision, drops the item at once and plays the next; the
    /// list is rebuilt behind it with the new canonicals (design § 5), once
    /// for a run of quick decisions.
    private func apply(_ item: ListenQueueItem, _ body: () async throws -> String) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            outcome = try await body()
        } catch {
            outcome = "Failed: \(error.localizedDescription)"
            Log.error("Listen decision on \(item.id) failed: \(error)")
            return
        }
        let index = items.firstIndex { $0.id == item.id } ?? 0
        items.removeAll { $0.id == item.id }
        select(items.isEmpty ? nil : items[min(index, items.count - 1)].id)
        dataChanged()
    }

    /// Confirmed people for «other speaker…», by display name.
    func confirmedSpeakers() async -> [Speaker] {
        ((try? await SpeakerRepository(db: db).all()) ?? [])
            .filter(\.isConfirmed)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

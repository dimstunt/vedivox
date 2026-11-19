import Foundation

/// Bounded hand-off between an audio callback and the live recogniser (change
/// `live-transcript`, design D4).
///
/// The callback only appends a batch under a short lock. When the recogniser
/// falls behind, the oldest audio is dropped and counted: live text gets a
/// hole, the recording — which never passes through here — does not.
///
/// Whole batches with a moving head, not a flat sample array: dropping from
/// the front of 30 s of samples on every callback would memmove megabytes on
/// the audio thread.
final class LiveAudioBacklog: @unchecked Sendable {
    struct Block: Equatable {
        let samples: [Float]
        /// When its last sample was captured, on the `systemUptime` clock.
        let capturedAt: TimeInterval
    }

    /// What the queue has seen — the numbers behind «live text did not cost
    /// the recording» (design D8).
    struct Stats: Equatable, Sendable {
        var callbacks = 0
        /// Time the tap thread spent converting and queueing, total and worst.
        var feedSeconds = 0.0
        var maxFeedSeconds = 0.0
        var pushedSamples = 0
        var droppedSamples = 0
        var maxPendingSamples = 0
    }

    static let sampleRate = 16000.0
    /// 30 s of 16 kHz mono, 1.9 MB: enough to catch up after a model that was
    /// still loading when the recording started.
    static let defaultCapacity = 30 * 16000

    private let capacity: Int
    private let lock = NSLock()
    private var batches: [Block] = []
    private var head = 0
    private var pendingSamples = 0
    private var stats = Stats()

    init(capacity: Int = LiveAudioBacklog.defaultCapacity) {
        self.capacity = capacity
    }

    /// Called on the audio thread.
    func push(_ samples: [Float], capturedAt: TimeInterval) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        batches.append(Block(samples: samples, capturedAt: capturedAt))
        pendingSamples += samples.count
        stats.pushedSamples += samples.count
        // Never the batch just added: the newest audio is what live text is for.
        while pendingSamples > capacity, head < batches.count - 1 {
            let lost = batches[head].samples.count
            pendingSamples -= lost
            stats.droppedSamples += lost
            release(head)
            head += 1
        }
        stats.maxPendingSamples = max(stats.maxPendingSamples, pendingSamples)
    }

    /// The oldest whole batches, about `maxSamples` of them and at least one;
    /// nil when nothing is waiting.
    func pop(maxSamples: Int) -> Block? {
        lock.lock()
        defer { lock.unlock() }
        guard head < batches.count else { return nil }
        var samples: [Float] = []
        var capturedAt = 0.0
        while head < batches.count, samples.isEmpty || samples.count + batches[head].samples.count <= maxSamples {
            samples.append(contentsOf: batches[head].samples)
            capturedAt = batches[head].capturedAt
            release(head)
            head += 1
        }
        pendingSamples -= samples.count
        if head == batches.count {
            batches.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 512 {
            batches.removeFirst(head)
            head = 0
        }
        return Block(samples: samples, capturedAt: capturedAt)
    }

    /// One tap callback took `seconds` to convert and queue its buffer.
    func noteFeed(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        stats.callbacks += 1
        stats.feedSeconds += seconds
        stats.maxFeedSeconds = max(stats.maxFeedSeconds, seconds)
    }

    var snapshot: Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Frees a consumed batch's samples now; its slot goes at the next compaction.
    private func release(_ index: Int) {
        batches[index] = Block(samples: [], capturedAt: 0)
    }
}
